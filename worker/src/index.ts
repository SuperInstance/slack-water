/**
 * Slack Water worker — the authoritative ocean.
 *
 * Roblox servers run OceanSim.luau locally for smooth prediction, but D1 is
 * what every server harvests against, so the fishery is genuinely shared:
 * what one crew takes, every other crew no longer finds. The routes below
 * arbitrate every mutation through the deterministic rules ported from the
 * Luau — nothing a client sends (effort, candidates, "prices") is trusted
 * as-is.
 */

import type { ExportedHandler } from "@cloudflare/workers-types";
import {
	CONFIG,
	HARVEST_WINDOW_SECONDS,
	MARKET_CACHE_TTL_SECONDS,
	MARKET_HISTORY_MIN_GAP_SECONDS,
	MAX_CATCHES_PER_REQUEST,
	MAX_TICKS_PER_INVOCATION,
} from "./config";
import { composeBanks, DEFAULT_MODEL } from "./composer";
import { type Env, VERSION } from "./env";
import { scarcityMultiplier, stepPrice } from "./market";
import { calendarFromTick, computeHarvest, globalAbundance } from "./ocean";
import { Router, jsonResponse } from "./router";
import {
	type BankInsertInput,
	type HarvestCatchRow,
	buildBankInsertBatch,
	buildHarvestBatch,
	buildTickStatements,
} from "./sql";
import { SPECIES, getSpecies } from "./species";
import { bankToRegion, validateBank } from "./validation";

const router = new Router<Env>();

//=============================================================================
// Helpers
//=============================================================================

async function readJsonBody(req: Request): Promise<Record<string, unknown> | null> {
	try {
		const body: unknown = await req.json();
		return typeof body === "object" && body !== null
			? (body as Record<string, unknown>)
			: null;
	} catch {
		return null;
	}
}

async function sha256Hex(text: string): Promise<string> {
	const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
	return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function placeholders(count: number): string {
	return Array.from({ length: count }, () => "?").join(", ");
}

function roundTo(value: number, decimals: number): number {
	const factor = 10 ** decimals;
	return Math.round(value * factor) / factor;
}

function makeBankId(): string {
	return `bk_${crypto.randomUUID().replace(/-/g, "").slice(0, 12)}`;
}

/** Run a list of statement plans as ONE D1 transaction. */
function submitBatch(env: Env, plans: { sql: string; params: (string | number | null)[] }[]) {
	return env.DB.batch(plans.map((plan) => env.DB.prepare(plan.sql).bind(...plan.params)));
}

//=============================================================================
// GET /health
//=============================================================================

router.add("GET", "/health", async ({ env }) => {
	const row = await env.DB.prepare("SELECT COUNT(*) AS n FROM regions").first<{ n: number }>();
	return jsonResponse(200, {
		ok: true,
		regions: row?.n ?? 0,
		species: SPECIES.length,
		version: VERSION,
	});
});

//=============================================================================
// GET /ocean/snapshot
//=============================================================================

router.add("GET", "/ocean/snapshot", async ({ env }) => {
	const state = await env.DB
		.prepare("SELECT tick, updated_at AS updatedAt FROM ocean_state WHERE id = 1")
		.first<{ tick: number; updatedAt: string }>();
	const regionRows = await env.DB
		.prepare(`SELECT id, name, habitat, depth, salinity, richness, origin
		          FROM regions ORDER BY created_at, id`)
		.all<{ id: string; name: string; habitat: string; depth: number; salinity: number; richness: number; origin: string }>();
	const stockRows = await env.DB
		.prepare(`SELECT region_id AS regionId, species_id AS speciesId, biomass, capacity
		          FROM region_stocks ORDER BY region_id, species_id`)
		.all<{ regionId: string; speciesId: string; biomass: number; capacity: number }>();

	const stocksByRegion = new Map<string, { speciesId: string; biomass: number; capacity: number; abundance: number }[]>();
	for (const row of stockRows.results) {
		const list = stocksByRegion.get(row.regionId) ?? [];
		list.push({
			speciesId: row.speciesId,
			biomass: row.biomass,
			capacity: row.capacity,
			abundance: row.capacity > 0 ? row.biomass / row.capacity : 0,
		});
		stocksByRegion.set(row.regionId, list);
	}

	const tick = state?.tick ?? 0;
	const { month, day } = calendarFromTick(tick);

	return jsonResponse(200, {
		ok: true,
		tick,
		month,
		day,
		updatedAt: state?.updatedAt ?? null,
		regions: regionRows.results.map((region) => ({
			...region,
			stocks: stocksByRegion.get(region.id) ?? [],
		})),
	});
});

//=============================================================================
// POST /ocean/harvest — idempotent, transactional
//=============================================================================

interface CatchInput {
	regionId: string;
	speciesId: string;
	effort: number;
}

type CatchResult =
	| {
			ok: true;
			regionId: string;
			speciesId: string;
			yielded: number;
			remaining: number;
			abundanceBefore: number;
			abundanceAfter: number;
			depleted: boolean;
			contested: boolean;
	  }
	| { ok: false; regionId: string; speciesId: string; reason: string };

router.add("POST", "/ocean/harvest", async ({ req, env }) => {
	const body = await readJsonBody(req);
	if (body === null) {
		return jsonResponse(400, { ok: false, error: "body must be JSON" });
	}

	const requestIdRaw =
		typeof body.requestId === "string" ? body.requestId
		: typeof body.request_id === "string" ? body.request_id
		: req.headers.get("idempotency-key");
	if (requestIdRaw === null || requestIdRaw.length === 0 || requestIdRaw.length > 128) {
		return jsonResponse(400, {
			ok: false,
			error: "a requestId of 1..128 characters is required so harvests are exactly-once",
		});
	}
	const requestId = requestIdRaw;

	if (!Array.isArray(body.catches) || body.catches.length === 0) {
		return jsonResponse(400, { ok: false, error: "catches must be a non-empty array" });
	}
	if (body.catches.length > MAX_CATCHES_PER_REQUEST) {
		return jsonResponse(400, {
			ok: false,
			error: `at most ${MAX_CATCHES_PER_REQUEST} catches per request`,
		});
	}

	const catches: CatchInput[] = [];
	for (const entry of body.catches) {
		if (typeof entry !== "object" || entry === null) {
			return jsonResponse(400, { ok: false, error: "each catch must be an object" });
		}
		const record = entry as Record<string, unknown>;
		if (typeof record.regionId !== "string" || typeof record.speciesId !== "string") {
			return jsonResponse(400, { ok: false, error: "regionId and speciesId must be strings" });
		}
		if (typeof record.effort !== "number" || !Number.isFinite(record.effort)) {
			return jsonResponse(400, { ok: false, error: "effort must be a finite number" });
		}
		catches.push({ regionId: record.regionId, speciesId: record.speciesId, effort: record.effort });
	}

	const payloadHash = await sha256Hex(JSON.stringify({ catches }));

	// Fast-path replay: this exact request already committed.
	const stored = await env.DB
		.prepare("SELECT payload_hash AS hash, response_json AS response FROM harvest_requests WHERE request_id = ?")
		.bind(requestId)
		.first<{ hash: string; response: string }>();
	if (stored) {
		if (stored.hash !== payloadHash) {
			return jsonResponse(409, {
				ok: false,
				error: "requestId was already used with a different payload",
			});
		}
		return new Response(stored.response, {
			status: 200,
			headers: { "content-type": "application/json; charset=utf-8", "x-idempotent-replay": "true" },
		});
	}

	// Read phase: current stocks, region existence, and the contention window.
	const regionIds = [...new Set(catches.map((c) => c.regionId))];
	const knownRegions = new Set(
		(
			await env.DB
				.prepare(`SELECT id FROM regions WHERE id IN (${placeholders(regionIds.length)})`)
				.bind(...regionIds)
				.all<{ id: string }>()
		).results.map((row) => row.id),
	);

	const pairKey = (regionId: string, speciesId: string) => `${regionId} ${speciesId}`;
	const pairList = [...new Set(catches.map((c) => pairKey(c.regionId, c.speciesId)))];
	const stockRows = await env.DB
		.prepare(`SELECT region_id AS regionId, species_id AS speciesId, biomass, capacity
		          FROM region_stocks
		          WHERE (region_id, species_id) IN (VALUES ${pairList.map(() => "(?,?)").join(", ")})`)
		.bind(...pairList.flatMap((pair) => pair.split(" ")))
		.all<{ regionId: string; speciesId: string; biomass: number; capacity: number }>();
	const stocks = new Map(
		stockRows.results.map((row) => [
			pairKey(row.regionId, row.speciesId),
			{ biomass: row.biomass, capacity: row.capacity },
		]),
	);

	const since = new Date(Date.now() - HARVEST_WINDOW_SECONDS * 1000).toISOString();
	const windowRows = await env.DB
		.prepare(`SELECT region_id AS regionId, SUM(yielded) AS total
		          FROM catch_events
		          WHERE created_at >= ? AND region_id IN (${placeholders(regionIds.length)})
		          GROUP BY region_id`)
		.bind(since, ...regionIds)
		.all<{ regionId: string; total: number }>();
	const windowHarvest = new Map(windowRows.results.map((row) => [row.regionId, row.total]));

	// Compute phase: sequential, carrying biomass forward so two catches of
	// the same stock inside one request see each other, exactly as
	// OceanSim.harvest would applied twice.
	const results: CatchResult[] = [];
	const applied: HarvestCatchRow[] = [];
	for (const catchInput of catches) {
		const { regionId, speciesId, effort } = catchInput;
		if (!knownRegions.has(regionId)) {
			results.push({ ok: false, regionId, speciesId, reason: "unknown region" });
			continue;
		}
		if (getSpecies(speciesId) === null) {
			results.push({ ok: false, regionId, speciesId, reason: "unknown species" });
			continue;
		}

		const key = pairKey(regionId, speciesId);
		const stock = stocks.get(key) ?? { biomass: 0, capacity: 0 };
		const outcome = computeHarvest(
			stock.biomass,
			stock.capacity,
			effort,
			windowHarvest.get(regionId) ?? 0,
		);
		stocks.set(key, { biomass: outcome.remaining, capacity: stock.capacity });
		windowHarvest.set(regionId, (windowHarvest.get(regionId) ?? 0) + outcome.yielded);

		results.push({ ok: true, regionId, speciesId, ...outcome });
		applied.push({
			regionId,
			speciesId,
			effort,
			yielded: outcome.yielded,
			abundanceBefore: outcome.abundanceBefore,
			abundanceAfter: outcome.abundanceAfter,
		});
	}

	const responseBody = JSON.stringify({ ok: true, requestId, results });
	const createdAt = new Date().toISOString();

	// Write phase: one transaction. If a concurrent duplicate claimed the
	// requestId first, the PK violation rolls back everything and we serve
	// their stored response — the ocean can never partially double-apply.
	try {
		await submitBatch(env, buildHarvestBatch(requestId, payloadHash, responseBody, createdAt, applied));
	} catch (error) {
		const winner = await env.DB
			.prepare("SELECT payload_hash AS hash, response_json AS response FROM harvest_requests WHERE request_id = ?")
			.bind(requestId)
			.first<{ hash: string; response: string }>();
		if (winner) {
			if (winner.hash !== payloadHash) {
				return jsonResponse(409, {
					ok: false,
					error: "requestId was already used with a different payload",
				});
			}
			return new Response(winner.response, {
				status: 200,
				headers: { "content-type": "application/json; charset=utf-8", "x-idempotent-replay": "true" },
			});
		}
		console.error("harvest batch failed", error);
		return jsonResponse(500, { ok: false, error: "harvest failed, no changes applied" });
	}

	return new Response(responseBody, {
		status: 200,
		headers: { "content-type": "application/json; charset=utf-8", "x-request-id": requestId },
	});
});

//=============================================================================
// Market
//=============================================================================

interface MarketEntry {
	speciesId: string;
	displayName: string;
	price: number;
	baseValue: number;
	scarcityMultiplier: number;
	globalAbundance: number;
	direction: "rising" | "falling" | "flat";
}

/**
 * Recompute prices for every species off live global abundance, step each
 * price one inertia move, and persist. Prices are derived on read from
 * region_stocks — a harvest is already reflected in the very next /market.
 */
async function refreshMarket(env: Env): Promise<MarketEntry[]> {
	const sumRows = await env.DB
		.prepare(`SELECT species_id AS speciesId, SUM(biomass) AS supply, SUM(capacity) AS capacity
		          FROM region_stocks GROUP BY species_id`)
		.all<{ speciesId: string; supply: number; capacity: number }>();
	const supplyBySpecies = new Map(
		sumRows.results.map((row) => [row.speciesId, { supply: row.supply, capacity: row.capacity }]),
	);

	const priceRows = await env.DB
		.prepare("SELECT species_id AS speciesId, price FROM market_prices")
		.all<{ speciesId: string; price: number }>();
	const priceBySpecies = new Map(priceRows.results.map((row) => [row.speciesId, row.price]));

	const historyRows = await env.DB
		.prepare(`SELECT species_id AS speciesId, MAX(recorded_at) AS lastAt
		          FROM market_price_history GROUP BY species_id`)
		.all<{ speciesId: string; lastAt: string }>();
	const lastHistoryAt = new Map(historyRows.results.map((row) => [row.speciesId, row.lastAt]));

	const now = new Date().toISOString();
	const entries: MarketEntry[] = [];
	const updates: { sql: string; params: (string | number | null)[] }[] = [];

	for (const species of SPECIES) {
		const totals = supplyBySpecies.get(species.id) ?? { supply: 0, capacity: 0 };
		const abundance = globalAbundance(totals.supply, totals.capacity);
		const multiplier = scarcityMultiplier(abundance);
		const { price, direction } = stepPrice(
			priceBySpecies.get(species.id) ?? 0,
			species.baseValue,
			multiplier,
		);

		entries.push({
			speciesId: species.id,
			displayName: species.displayName,
			price: roundTo(price, 2),
			baseValue: species.baseValue,
			scarcityMultiplier: roundTo(multiplier, 4),
			globalAbundance: roundTo(abundance, 4),
			direction,
		});

		updates.push({
			sql: `UPDATE market_prices SET price = ?1, abundance = ?2, updated_at = ?3 WHERE species_id = ?4`,
			params: [price, abundance, now, species.id],
		});

		// Throttle history rows so a burst of reads doesn't flood the table.
		const lastAt = lastHistoryAt.get(species.id);
		if (lastAt === undefined || now >= addSeconds(lastAt, MARKET_HISTORY_MIN_GAP_SECONDS)) {
			updates.push({
				sql: `INSERT INTO market_price_history (species_id, price, abundance, recorded_at)
				      VALUES (?1, ?2, ?3, ?4)`,
				params: [species.id, price, abundance, now],
			});
		}
	}

	if (updates.length > 0) await submitBatch(env, updates);
	return entries;
}

function addSeconds(iso: string, seconds: number): string {
	return new Date(new Date(iso).getTime() + seconds * 1000).toISOString();
}

router.add("GET", "/market", async ({ env }) => {
	const cached = await env.OCEAN_KV.get("market:v1");
	if (cached !== null) {
		return new Response(cached, {
			status: 200,
			headers: { "content-type": "application/json; charset=utf-8", "x-cache": "hit" },
		});
	}

	const entries = await refreshMarket(env);
	const body = JSON.stringify({ ok: true, entries });
	// KV enforces a 60s minimum TTL; the market steps slowly (inertia 0.82),
	// so a minute of staleness in the listing is well inside the noise.
	await env.OCEAN_KV.put("market:v1", body, { expirationTtl: Math.max(MARKET_CACHE_TTL_SECONDS, 60) });
	return new Response(body, {
		status: 200,
		headers: { "content-type": "application/json; charset=utf-8", "x-cache": "miss" },
	});
});

router.add("GET", "/market/:speciesId", async ({ env, params }) => {
	const species = getSpecies(params.speciesId ?? "");
	if (species === null) {
		return jsonResponse(404, { ok: false, error: "unknown species" });
	}

	const totals = await env.DB
		.prepare(`SELECT SUM(biomass) AS supply, SUM(capacity) AS capacity
		          FROM region_stocks WHERE species_id = ?`)
		.bind(species.id)
		.first<{ supply: number | null; capacity: number | null }>();
	const priceRow = await env.DB
		.prepare("SELECT price FROM market_prices WHERE species_id = ?")
		.bind(species.id)
		.first<{ price: number }>();

	const abundance = globalAbundance(totals?.supply ?? 0, totals?.capacity ?? 0);
	const multiplier = scarcityMultiplier(abundance);
	const { price, direction } = stepPrice(priceRow?.price ?? 0, species.baseValue, multiplier);

	const now = new Date().toISOString();
	await submitBatch(env, [
		{
			sql: `UPDATE market_prices SET price = ?1, abundance = ?2, updated_at = ?3 WHERE species_id = ?4`,
			params: [price, abundance, now, species.id],
		},
	]);

	const historyRows = await env.DB
		.prepare(`SELECT price, abundance, recorded_at AS recordedAt
		          FROM market_price_history WHERE species_id = ?
		          ORDER BY recorded_at DESC LIMIT 100`)
		.bind(species.id)
		.all<{ price: number; abundance: number; recordedAt: string }>();

	return jsonResponse(200, {
		ok: true,
		speciesId: species.id,
		displayName: species.displayName,
		price: roundTo(price, 2),
		baseValue: species.baseValue,
		scarcityMultiplier: roundTo(multiplier, 4),
		globalAbundance: roundTo(abundance, 4),
		direction,
		history: historyRows.results.reverse(),
	});
});

//=============================================================================
// Banks — AI-composed, validation-arbitrated
//=============================================================================

router.add("POST", "/banks/compose", async ({ req, env }) => {
	const body = await readJsonBody(req);
	const requested = typeof body?.count === "number" && Number.isFinite(body.count)
		? Math.floor(body.count)
		: CONFIG.BANKS_PER_ROUND;
	const count = Math.max(1, Math.min(requested, 8));

	const bankCountRow = await env.DB.prepare("SELECT COUNT(*) AS n FROM banks").first<{ n: number }>();
	const existingBanks = bankCountRow?.n ?? 0;

	if (existingBanks >= CONFIG.MAX_BANKS) {
		// At the ceiling the round still answers, with the current grounds.
		const rows = await env.DB
			.prepare(`SELECT id, name, habitat, depth, salinity, richness, hazard, species_mix AS speciesMix, origin, created_at AS createdAt
			          FROM banks ORDER BY created_at DESC LIMIT ?`)
			.bind(count)
			.all<Record<string, unknown>>();
		return jsonResponse(200, {
			ok: true,
			capped: true,
			usedModel: false,
			modelError: null,
			rejections: ["bank ceiling reached"],
			banks: rows.results,
		});
	}

	const state = await env.DB
		.prepare("SELECT tick, month FROM ocean_state WHERE id = 1")
		.first<{ tick: number; month: number }>();
	const tick = state?.tick ?? 0;
	const month = state?.month ?? calendarFromTick(tick).month;

	// Seed varies by round (minute) and world state so rounds differ, but is
	// recorded in the response for reproducibility.
	const seed = Math.floor(Date.now() / 60_000) ^ ((existingBanks + 1) * 2654435761);
	const composed = await composeBanks({
		ai: env.ai,
		model: env.AI_MODEL ?? DEFAULT_MODEL,
		count,
		seed,
		makeId: makeBankId,
	});

	const createdAt = new Date().toISOString();
	const persisted: unknown[] = [];
	for (const { bank } of composed.banks) {
		const insert: BankInsertInput = {
			bank: {
				id: bank.id,
				name: bank.name,
				habitat: bank.habitat,
				depth: bank.depth,
				salinity: bank.salinity,
				richness: bank.richness,
				hazard: bank.hazard,
				speciesMix: bank.speciesMix,
				origin: bank.origin,
			},
			region: bankToRegion(bank),
			month,
			createdAt,
		};
		try {
			// One transaction per bank: a failed insert (id collision, ceiling
			// race) costs that bank only, never the round.
			await submitBatch(env, buildBankInsertBatch(insert));
			persisted.push({ ...bank, speciesMix: bank.speciesMix, createdAt });
		} catch (error) {
			console.error("bank insert failed", bank.id, error);
			composed.rejections.push(`bank ${bank.id} could not be persisted`);
		}
	}

	return jsonResponse(200, {
		ok: true,
		usedModel: composed.usedModel,
		modelError: composed.modelError,
		seed,
		rejections: composed.rejections,
		banks: persisted,
	});
});

router.add("POST", "/banks/validate", async ({ req }) => {
	const body = await readJsonBody(req);
	if (body === null) {
		return jsonResponse(400, { ok: false, error: "body must be a JSON bank candidate" });
	}
	const fallbackId = typeof body.id === "string" && body.id.length > 0 ? body.id : "bk_uncommitted";
	const report = validateBank(body, fallbackId);
	return jsonResponse(200, {
		ok: report.ok,
		bank: report.bank,
		region: report.ok && report.bank ? bankToRegion(report.bank) : null,
		repairs: report.repairs,
		rejections: report.rejections,
	});
});

//=============================================================================
// Simulation tick — cron-driven, also callable for ops
//=============================================================================

async function runTicks(env: Env, requested: number): Promise<{ applied: number; tick: number; month: number; day: number }> {
	let applied = 0;
	for (let i = 0; i < requested; i++) {
		const state = await env.DB
			.prepare("SELECT tick FROM ocean_state WHERE id = 1")
			.first<{ tick: number }>();
		const nextTick = (state?.tick ?? 0) + 1;
		const { month, day } = calendarFromTick(nextTick);
		try {
			// tick_log's PK makes this claim-or-fail: if another invocation
			// (cron racing a manual call) already advanced the ocean, the
			// whole batch rolls back and we stop here.
			await submitBatch(env, buildTickStatements(nextTick, month, day, new Date().toISOString()));
			applied++;
		} catch (error) {
			console.error("tick failed (lost race or db error)", error);
			break;
		}
	}

	const final = await env.DB
		.prepare("SELECT tick, month, day FROM ocean_state WHERE id = 1")
		.first<{ tick: number; month: number; day: number }>();
	const tick = final?.tick ?? 0;
	const calendar = calendarFromTick(tick);
	return { applied, tick, month: calendar.month, day: calendar.day };
}

router.add("POST", "/ocean/tick", async ({ req, env }) => {
	// Ops escape hatch; normally the cron drives this. Protect it with an
	// admin token when one is configured.
	if (typeof env.ADMIN_TOKEN === "string" && env.ADMIN_TOKEN.length > 0) {
		if (req.headers.get("x-admin-token") !== env.ADMIN_TOKEN) {
			return jsonResponse(401, { ok: false, error: "admin token required" });
		}
	}
	const body = await readJsonBody(req);
	const requested =
		typeof body?.ticks === "number" && Number.isFinite(body.ticks)
			? Math.floor(body.ticks)
			: 1;
	const outcome = await runTicks(env, Math.max(1, Math.min(requested, MAX_TICKS_PER_INVOCATION)));
	return jsonResponse(200, { ok: true, ...outcome });
});

//=============================================================================
// Entry points
//=============================================================================

const handler: ExportedHandler<Env> = {
	async fetch(req, env, ctx) {
		try {
			return await router.handle(req, env, ctx);
		} catch (error) {
			console.error("unhandled route error", error);
			return jsonResponse(500, { ok: false, error: "internal error" });
		}
	},
	async scheduled(_controller, env, ctx) {
		// One tick per minute: 12 ticks/day and 4 days/month (the Config.luau
		// calendar), so a full in-game year takes 9.6 wall-clock hours and
		// salmon runs arrive on schedule without any server doing work.
		ctx.waitUntil(runTicks(env, 1));
	},
};

export default handler;
