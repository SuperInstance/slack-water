/**
 * The composer: asks Workers AI to propose new fishing banks, then forces
 * every candidate through validation.ts before it can exist.
 *
 * Two invariants the endpoint relies on:
 *   1. NEVER fail — the AI binding may be misconfigured, rate-limited, or
 *      return prose; every failure path falls through to procedural banks.
 *   2. NEVER return an empty list — the game schedules a settlement round and
 *      expects water to come back.
 *
 * The procedural fallback is deterministic given a seed (Park-Miller, ported
 * from Rng.luau) so a round is reproducible in tests and post-mortems.
 */

import { CONFIG, AI_TIMEOUT_MS } from "./config";
import { type Rng, makeRng } from "./rng";
import { HABITATS, type Habitat, candidatesAtDepth } from "./species";
import { VALID_HAZARDS, type BankSpec, validateBank } from "./validation";

/** Minimal structural slice of the Workers AI binding, for testability. */
export interface AiRunner {
	run(model: string, input: unknown): Promise<unknown>;
}

export interface ComposedBank {
	bank: BankSpec;
	repairs: string[];
}

export interface ComposeResult {
	banks: ComposedBank[];
	/** True if at least one persisted bank came from the model. */
	usedModel: boolean;
	/** Why the model was unusable, if it was; surfaced for prompt tuning. */
	modelError: string | null;
	/** Aggregate rejections across all candidates, for prompt tuning. */
	rejections: string[];
}

export const DEFAULT_MODEL = "@cf/meta/llama-3.3-70b-instruct-fp8-fast";

const SYSTEM_PROMPT = `You are the hydrographer for a commercial fishing simulation set in the real North Pacific, from the Strait of Georgia to the Gulf of Alaska. You chart new fishing banks — named grounds a fishing captain would recognise on a chart.

Vocabulary you must use — nothing else exists in this world:

SPECIES (use these ids verbatim, never invent a species id, never translate, never pluralise): chinook, coho, sockeye, pink, chum (salmon, anadromous, 5-320m, run in spring and autumn), halibut (sand, 200-900m), sablefish (mud, 300-800m), cod (mud, 90-300m), pollock (open water, 80-300m), lingcod (reef, 90-300m), rockfish (reef, 25-120m), yelloweye (deep reef, 40-180m), herring (kelp, 15-110m), flounder (sand, 15-150m), skate (sand, 60-400m), dungeness (crab, reef, 15-200m), kingcrab (crab, mud, 200-500m).

HABITATS (exactly one of): kelp, reef, sand, mud, open, estuary.

HAZARDS (optional, exactly one of): none, rip_current, rocky_bottom, deep_water, kelp_tangle, seabird_activity, debris_field, cold_drain.

Rules of the water: depth is 5-900 metres and must suit the species you place there (halibut are deep, herring are shallow, salmon run through open water and estuaries); salinity is 18 (brackish estuary) to 36 (open ocean) PSU, richness 0.5-1.5. Names read like real North Pacific grounds: "Bishop Shoal", "Cape Naden Grounds", "Whale Channel Flats" — plain words, 3-42 characters.

Respond with STRICT JSON only, no prose, no markdown: {"banks": [{"name": string, "habitat": string, "depth": number, "richness": number, "salinity": number, "hazard": string, "speciesMix": [{"speciesId": string, "weight": number}]}]}. speciesMix has 2-5 entries whose species plausibly hold on that ground.`;

// Real North Pacific chart vocabulary for the procedural fallback — real
// captain-facing words, no invented species or habitats possible.
const NAME_PREFIXES: readonly string[] = [
	"Bishop", "Bonilla", "Browning", "Cape Scott", "Carmanah", "Chatham",
	"Cole", "Danger", "Dodge", "Egg", "Goose", "Grenville", "Hector",
	"Inverness", "Kluk", "McIntyre", "Morrie", "Naden", "Pachena", "Pinkerton",
	"Rainbow", "Sartine", "Silver", "Spencer", "Tripp", "Tyee", "Whale",
] as const;

const NAME_FEATURES: readonly string[] = [
	"Bank", "Channel", "Fingers", "Flats", "Grounds", "Hole", "Ledge", "Pass",
	"Pocket", "Point", "Reef", "Ridge", "Shoal", "Shoulder",
] as const;

// Depth bands per habitat, modelled on where those grounds actually sit on a
// North Pacific chart; the procedural generator never proposes a kelp forest
// at 400m.
const HABITAT_DEPTH: Record<Habitat, [min: number, max: number]> = {
	kelp: [10, 45],
	reef: [15, 220],
	sand: [20, 350],
	mud: [90, 600],
	open: [60, 450],
	estuary: [5, 60],
};

export function makeComposePrompt(count: number): string {
	return `Chart exactly ${count} new fishing banks in the North Pacific as STRICT JSON.`;
}

/**
 * Defensive extraction of bank candidates from whatever the model returned.
 * Models return prose, fenced code blocks, or a bare object despite JSON
 * mode — this survives all of it and hands back an array of raw candidates.
 */
export function extractBankCandidates(payload: unknown): unknown[] {
	const parsed = parsePayload(payload);
	return normaliseToBankList(parsed);
}

function parsePayload(payload: unknown): unknown {
	if (payload == null) return null;

	// Already a parsed array (a model or proxy that returned raw JSON body).
	if (Array.isArray(payload)) return payload;

	// Workers AI chat models answer with { response: "..." }; some return an
	// OpenAI-ish { choices: [...] }; a structured-mode reply may already be
	// the object itself.
	if (typeof payload === "object") {
		const record = payload as Record<string, unknown>;
		if (typeof record.response === "string") return parseJsonText(record.response);
		if (record.response != null && typeof record.response === "object") {
			return record.response;
		}
		const choices = record.choices;
		if (Array.isArray(choices) && choices.length > 0) {
			const first = choices[0] as Record<string, unknown> | undefined;
			const message = first?.message as Record<string, unknown> | undefined;
			if (message && typeof message.content === "string") {
				return parseJsonText(message.content);
			}
		}
		return payload;
	}

	if (typeof payload === "string") return parseJsonText(payload);
	return null;
}

function parseJsonText(text: string): unknown {
	const trimmed = text.trim();
	if (trimmed === "") return null;

	try {
		return JSON.parse(trimmed);
	} catch {
		// fall through to the more aggressive recovery below
	}

	// The classic shape: a fenced ```json block around the payload.
	const fence = trimmed.match(/```(?:json)?\s*([\s\S]*?)```/i);
	if (fence?.[1] != null) {
		try {
			return JSON.parse(fence[1].trim());
		} catch {
			// keep trying
		}
	}

	// Prose around the JSON: take the outermost brace-to-bracket span.
	const start = Math.min(
		...[trimmed.indexOf("{"), trimmed.indexOf("[")].filter((i) => i >= 0),
	);
	const end = Math.max(trimmed.lastIndexOf("}"), trimmed.lastIndexOf("]"));
	if (Number.isFinite(start) && end > start) {
		try {
			return JSON.parse(trimmed.slice(start, end + 1));
		} catch {
			return null;
		}
	}
	return null;
}

function normaliseToBankList(parsed: unknown): unknown[] {
	if (parsed == null) return [];
	if (Array.isArray(parsed)) return parsed;
	if (typeof parsed === "object") {
		const record = parsed as Record<string, unknown>;
		if (Array.isArray(record.banks)) return record.banks;
		// A single bare bank object instead of the requested wrapper.
		if ("habitat" in record || "speciesMix" in record) return [record];
	}
	return [];
}

/**
 * Generate one bank procedurally. Deterministic given the rng state, and
 * shaped so validation passes without repairs (the fallback should not look
 * broken in telemetry — model drift is the thing repairs measure).
 */
export function proceduralCandidate(rng: Rng): Record<string, unknown> {
	const habitat = rng.pick(HABITATS);
	const [minDepth, maxDepth] = HABITAT_DEPTH[habitat];
	const depth = Math.round(rng.range(minDepth, maxDepth));
	const salinity =
		habitat === "estuary" ? rng.range(18, 28) : rng.range(30, 34.5);

	const candidates = candidatesAtDepth(depth);
	// At an extreme depth (e.g. 5m) only one species may be in band; a mix of
	// one is valid but uninteresting, so borrow the 60m community instead.
	const pool = [...(candidates.length >= 2 ? candidates : candidatesAtDepth(60))];
	const chosenCount = Math.min(pool.length, rng.int(2, Math.min(5, pool.length)));
	// splice-pick without replacement: no species appears twice in a mix
	const speciesMix: { speciesId: string; weight: number }[] = [];
	for (let i = 0; i < chosenCount; i++) {
		const picked = pool.splice(rng.int(0, pool.length - 1), 1)[0];
		if (picked === undefined) break;
		speciesMix.push({ speciesId: picked.id, weight: rng.range(0.3, 1.0) });
	}

	const hazard =
		rng.chance(0.5) ? "none" : rng.pick(VALID_HAZARDS.filter((h) => h !== "none"));

	return {
		name: `${rng.pick(NAME_PREFIXES)} ${rng.pick(NAME_FEATURES)}`,
		habitat,
		depth,
		richness: rng.range(0.6, 1.4),
		salinity: Math.round(salinity * 10) / 10,
		hazard,
		speciesMix,
	};
}

export interface ComposeOptions {
	ai: AiRunner | null;
	model?: string;
	count?: number;
	/** Seed for the procedural fallback; derive it from the round. */
	seed: number;
	/** Supplies bank ids; injectable so tests stay deterministic. */
	makeId: () => string;
}

export async function composeBanks(options: ComposeOptions): Promise<ComposeResult> {
	const count = Math.max(1, Math.min(options.count ?? CONFIG.BANKS_PER_ROUND, 8));
	const rng = makeRng(options.seed);

	const out: ComposedBank[] = [];
	const rejections: string[] = [];
	let modelError: string | null = null;
	let usedModel = false;

	if (options.ai != null) {
		try {
			const input = {
				messages: [
					{ role: "system", content: SYSTEM_PROMPT },
					{ role: "user", content: makeComposePrompt(count) },
				],
				// Structured-output request; models that ignore it are still
				// handled by the defensive parser.
				response_format: { type: "json_object" },
				max_tokens: 2048,
				temperature: 0.8,
			};
			const raw = await withTimeout(
				options.ai.run(options.model ?? DEFAULT_MODEL, input),
				AI_TIMEOUT_MS,
			);
			for (const candidate of extractBankCandidates(raw)) {
				if (out.length >= count) break;
				const report = validateBank(candidate, options.makeId());
				if (report.ok && report.bank != null) {
					out.push({ bank: report.bank, repairs: report.repairs });
					usedModel = true;
				} else {
					rejections.push(...report.rejections);
				}
			}
			if (out.length === 0) {
				modelError = "model returned no usable banks";
			}
		} catch (error) {
			modelError = error instanceof Error ? error.message : String(error);
		}
	} else {
		modelError = "ai binding unavailable";
	}

	// Fill any shortfall procedurally so the result is never short, never
	// empty. Procedural banks are valid by construction but still pass
	// through validation — nothing skips arbitration.
	while (out.length < count) {
		const report = validateBank(proceduralCandidate(rng), options.makeId());
		if (report.ok && report.bank != null) {
			report.bank.origin = "procedural";
			out.push({ bank: report.bank, repairs: report.repairs });
		}
	}

	return { banks: out, usedModel, modelError, rejections };
}

function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
	return new Promise<T>((resolve, reject) => {
		const timer = setTimeout(() => reject(new Error(`ai call timed out after ${ms}ms`)), ms);
		promise.then(
			(value) => {
				clearTimeout(timer);
				resolve(value);
			},
			(error) => {
				clearTimeout(timer);
				reject(error);
			},
		);
	});
}
