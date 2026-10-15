/**
 * Integration tests against a real SQLite database (node:sqlite): apply the
 * actual migration, then replay the exact statement plans src/sql.ts builds
 * for harvests, ticks, and bank inserts.
 *
 * This is where the two renderings of the simulation meet: the TypeScript
 * port (src/ocean.ts) and the SQL executed inside D1 transactions must agree
 * to floating-point tolerance, and the idempotency guarantees must actually
 * hold under the real engine — a PK violation must roll back the whole
 * "transaction", never leave a partial catch behind.
 */

import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { beforeEach, describe, expect, it } from "vitest";
import {
	calendarFromTick,
	computeHarvest,
	effectiveCapacity,
	tickStock,
	type Region,
} from "../src/ocean";
import {
	buildBankInsertBatch,
	buildHarvestBatch,
	buildTickStatements,
	type StatementPlan,
} from "../src/sql";
import { SPECIES, getSpecies, type Habitat } from "../src/species";
import { bankToRegion, validateBank } from "../src/validation";

interface StockRow {
	region_id: string;
	species_id: string;
	biomass: number;
	capacity: number;
}

interface RegionRow {
	id: string;
	name: string;
	habitat: Habitat;
	depth: number;
	salinity: number;
	richness: number;
	origin: "procedural" | "composed";
}

let db: DatabaseSync;

function migrate(): void {
	const sql = readFileSync(new URL("../migrations/0001_ocean.sql", import.meta.url), "utf-8");
	db.exec(sql);
}

/** Replay statement plans as ONE transaction, the way D1's batch() does. */
function runPlans(plans: readonly StatementPlan[]): void {
	db.exec("BEGIN");
	try {
		for (const plan of plans) {
			db.prepare(plan.sql).run(...(plan.params as (string | number | null)[]));
		}
		db.exec("COMMIT");
	} catch (error) {
		db.exec("ROLLBACK");
		throw error;
	}
}

function all<T>(sql: string, ...params: (string | number | null)[]): T[] {
	return db.prepare(sql).all(...(params as never[])) as unknown as T[];
}

function get<T>(sql: string, ...params: (string | number | null)[]): T | null {
	return (db.prepare(sql).get(...(params as never[])) ?? null) as unknown as T | null;
}

function loadRegions(): Map<string, RegionRow> {
	return new Map(all<RegionRow>("SELECT id, name, habitat, depth, salinity, richness, origin FROM regions").map((r) => [r.id, r]));
}

function regionRowToRegion(row: RegionRow): Region {
	return {
		id: row.id,
		name: row.name,
		habitat: row.habitat,
		depth: row.depth,
		salinity: row.salinity,
		richness: row.richness,
		origin: row.origin,
	};
}

beforeEach(() => {
	db = new DatabaseSync(":memory:");
	migrate();
});

describe("migration", () => {
	it("seeds the reference data and one stocked ground per habitat", () => {
		expect(all("SELECT id FROM species")).toHaveLength(17);
		expect(all("SELECT * FROM species_run_months")).toHaveLength(20);
		expect(all("SELECT * FROM habitat_affinity")).toHaveLength(36);
		expect(all("SELECT id FROM regions")).toHaveLength(6);
		expect(all("SELECT * FROM region_stocks")).toHaveLength(6 * 17);
		expect(all("SELECT * FROM market_prices")).toHaveLength(17);
		expect(get<{ tick: number }>("SELECT tick FROM ocean_state")?.tick).toBe(0);
	});

	it("seeds market prices at base value against the 0.82 start abundance", () => {
		const rows = all<{ species_id: string; price: number; abundance: number }>(
			"SELECT species_id, price, abundance FROM market_prices",
		);
		for (const row of rows) {
			const species = getSpecies(row.species_id)!;
			expect(row.price, row.species_id).toBeCloseTo(species.baseValue, 6);
			expect(row.abundance).toBeCloseTo(0.82, 6);
		}
	});
});

describe("seed arithmetic parity (SQL vs OceanSim.addRegion)", () => {
	it("stocks every region at effectiveCapacity·0.82, month 1", () => {
		const regions = loadRegions();
		const rows = all<StockRow>(
			"SELECT region_id, species_id, biomass, capacity FROM region_stocks",
		);
		for (const row of rows) {
			const species = getSpecies(row.species_id)!;
			const region = regionRowToRegion(regions.get(row.region_id)!);
			const expectedCap = effectiveCapacity(species, region, 1);
			expect(row.capacity, `${row.region_id}/${row.species_id} capacity`).toBeCloseTo(expectedCap, 9);
			expect(row.biomass).toBeCloseTo(expectedCap * 0.82, 9);
		}
	});
});

describe("harvest transaction", () => {
	it("subtracts the yield, logs the catch, and stores the idempotent response", () => {
		const before = get<StockRow>(
			"SELECT region_id, species_id, biomass, capacity FROM region_stocks WHERE region_id = 'r_georgia_open' AND species_id = 'halibut'",
		)!;
		const outcome = computeHarvest(before.biomass, before.capacity, 500, 0);
		const responseJson = JSON.stringify({ ok: true, results: [] });

		runPlans(
			buildHarvestBatch("req-1", "hash-1", responseJson, new Date().toISOString(), [
				{
					regionId: "r_georgia_open",
					speciesId: "halibut",
					effort: 500,
					yielded: outcome.yielded,
					abundanceBefore: outcome.abundanceBefore,
					abundanceAfter: outcome.abundanceAfter,
				},
			]),
		);

		const after = get<{ biomass: number }>(
			"SELECT biomass FROM region_stocks WHERE region_id = 'r_georgia_open' AND species_id = 'halibut'",
		)!;
		expect(after.biomass).toBeCloseTo(before.biomass - outcome.yielded, 9);
		expect(all("SELECT * FROM catch_events")).toHaveLength(1);

		const stored = get<{ payload_hash: string; response_json: string }>(
			"SELECT payload_hash, response_json FROM harvest_requests WHERE request_id = 'req-1'",
		);
		expect(stored?.payload_hash).toBe("hash-1");
		expect(stored?.response_json).toBe(responseJson);
	});

	it("replaying the same requestId rolls back wholesale — no double application", () => {
		const before = get<{ biomass: number; capacity: number }>(
			"SELECT biomass, capacity FROM region_stocks WHERE region_id = 'r_georgia_open' AND species_id = 'halibut'",
		)!;
		const outcome = computeHarvest(before.biomass, before.capacity, 500, 0);
		const plans = buildHarvestBatch("req-dup", "hash", "{}", new Date().toISOString(), [
			{
				regionId: "r_georgia_open",
				speciesId: "halibut",
				effort: 500,
				yielded: outcome.yielded,
				abundanceBefore: 1,
				abundanceAfter: 1,
			},
		]);

		runPlans(plans);
		const afterFirst = get<{ biomass: number }>(
			"SELECT biomass FROM region_stocks WHERE region_id = 'r_georgia_open' AND species_id = 'halibut'",
		)!;
		expect(afterFirst.biomass).toBeCloseTo(before.biomass - outcome.yielded, 9);

		// The concurrent duplicate: the requestId INSERT violates the PK and
		// the ENTIRE batch must roll back, leaving exactly one catch applied.
		expect(() => runPlans(plans)).toThrow();
		const afterSecond = get<{ biomass: number }>(
			"SELECT biomass FROM region_stocks WHERE region_id = 'r_georgia_open' AND species_id = 'halibut'",
		)!;
		expect(afterSecond.biomass).toBeCloseTo(afterFirst.biomass, 12);
		expect(all("SELECT * FROM catch_events")).toHaveLength(1);
		expect(all("SELECT * FROM harvest_requests")).toHaveLength(1);
	});

	it("is all-or-nothing when a statement fails mid-batch", () => {
		const before = get<{ biomass: number }>(
			"SELECT biomass FROM region_stocks WHERE region_id = 'r_saddle_reef' AND species_id = 'rockfish'",
		)!;
		const plans = [
			...buildHarvestBatch("req-partial", "hash", "{}", new Date().toISOString(), [
				{ regionId: "r_saddle_reef", speciesId: "rockfish", effort: 100, yielded: 10, abundanceBefore: 1, abundanceAfter: 0.9 },
				{ regionId: "r_saddle_reef", speciesId: "lingcod", effort: 100, yielded: 10, abundanceBefore: 1, abundanceAfter: 0.9 },
			]),
			{ sql: "INSERT INTO no_such_table VALUES (1)", params: [] }, // poison
		];
		expect(() => runPlans(plans)).toThrow();
		const after = get<{ biomass: number }>(
			"SELECT biomass FROM region_stocks WHERE region_id = 'r_saddle_reef' AND species_id = 'rockfish'",
		)!;
		expect(after.biomass).toBeCloseTo(before.biomass, 12); // nothing applied
		expect(all("SELECT * FROM catch_events")).toHaveLength(0);
	});

	it("supports the row-values IN query the handler uses for stock reads", () => {
		const rows = all<{ species_id: string }>(
			`SELECT region_id, species_id FROM region_stocks
			 WHERE (region_id, species_id) IN (VALUES (?,?),(?,?))`,
			"r_saddle_reef", "rockfish", "r_nanaimo_mud", "sablefish",
		);
		expect(rows.map((r) => r.species_id).sort()).toEqual(["rockfish", "sablefish"]);
	});

	it("computes the contention window only from recent catches", () => {
		const now = new Date();
		db.prepare(
			"INSERT INTO catch_events (request_id, region_id, species_id, effort, yielded, abundance_before, abundance_after, created_at) VALUES (?,?,?,?,?,?,?,?)",
		).run("r-a", "r_saddle_reef", "rockfish", 10, 60, 1, 0.9, now.toISOString());
		db.prepare(
			"INSERT INTO catch_events (request_id, region_id, species_id, effort, yielded, abundance_before, abundance_after, created_at) VALUES (?,?,?,?,?,?,?,?)",
		).run("r-b", "r_saddle_reef", "rockfish", 10, 999, 1, 0.9, new Date(now.getTime() - 120_000).toISOString());

		const since = new Date(now.getTime() - 60_000).toISOString();
		const row = get<{ total: number }>(
			`SELECT SUM(yielded) AS total FROM catch_events
			 WHERE created_at >= ? AND region_id IN (?) GROUP BY region_id`,
			since,
			"r_saddle_reef",
		);
		expect(row?.total).toBeCloseTo(60, 9); // the 120s-old catch is outside
	});
});

describe("tick", () => {
	it("matches tickStock() for every stock, month 1", () => {
		const regions = loadRegions();
		const before = all<StockRow>("SELECT region_id, species_id, biomass, capacity FROM region_stocks");
		runPlans(buildTickStatements(1, 1, 1, new Date().toISOString()));

		for (const stock of before) {
			const species = getSpecies(stock.species_id)!;
			const region = regionRowToRegion(regions.get(stock.region_id)!);
			const expected = tickStock(species, region, 1, stock.biomass);
			const actual = get<{ biomass: number; capacity: number }>(
				"SELECT biomass, capacity FROM region_stocks WHERE region_id = ? AND species_id = ?",
				stock.region_id,
				stock.species_id,
			)!;
			expect(actual.biomass, `${stock.region_id}/${stock.species_id}`).toBeCloseTo(expected.biomass, 9);
			expect(actual.capacity, `${stock.region_id}/${stock.species_id}`).toBeCloseTo(expected.capacity, 9);
		}
	});

	it("matches tickStock() inside the chinook run (month 3: capacity and inflow move)", () => {
		runPlans(buildTickStatements(1, 1, 1, new Date().toISOString())); // settle into tick 1
		const regions = loadRegions();
		const before = all<StockRow>("SELECT region_id, species_id, biomass FROM region_stocks");
		runPlans(buildTickStatements(2, 3, 1, new Date().toISOString())); // jump the calendar to month 3

		for (const stock of before) {
			const species = getSpecies(stock.species_id)!;
			const region = regionRowToRegion(regions.get(stock.region_id)!);
			const expected = tickStock(species, region, 3, stock.biomass);
			const actual = get<{ biomass: number }>(
				"SELECT biomass FROM region_stocks WHERE region_id = ? AND species_id = ?",
				stock.region_id,
				stock.species_id,
			)!;
			expect(actual.biomass, `${stock.region_id}/${stock.species_id} (month 3)`).toBeCloseTo(expected.biomass, 9);
		}
		// sanity: the chinook run actually inflates open-water capacity in month 3
		const openCap = get<{ capacity: number }>(
			"SELECT capacity FROM region_stocks WHERE region_id = 'r_georgia_open' AND species_id = 'chinook'",
		)!;
		const chinook = getSpecies("chinook")!;
		const georgia = regionRowToRegion(loadRegions().get("r_georgia_open")!);
		expect(openCap.capacity).toBeCloseTo(effectiveCapacity(chinook, georgia, 3), 9);
	});

	it("advances the calendar and refuses to double-tick", () => {
		runPlans(buildTickStatements(1, 1, 1, new Date().toISOString()));
		expect(() => runPlans(buildTickStatements(1, 1, 1, new Date().toISOString()))).toThrow();

		const state = get<{ tick: number; month: number; day: number }>(
			"SELECT tick, month, day FROM ocean_state",
		)!;
		expect(state.tick).toBe(1);
		expect(state.month).toBe(calendarFromTick(1).month);
		expect(state.day).toBe(calendarFromTick(1).day);
		expect(all("SELECT * FROM tick_log")).toHaveLength(1);
	});
});

describe("catch log", () => {
	it("is append-only: UPDATE and DELETE are aborted by triggers", () => {
		db.prepare(
			"INSERT INTO catch_events (request_id, region_id, species_id, effort, yielded, abundance_before, abundance_after) VALUES (?,?,?,?,?,?,?)",
		).run("r", "x", "halibut", 1, 1, 1, 1);
		expect(() => db.exec("UPDATE catch_events SET yielded = 0")).toThrow(/append-only/);
		expect(() => db.exec("DELETE FROM catch_events")).toThrow(/append-only/);
	});
});

describe("bank persistence", () => {
	it("stores the bank, its region, and 17 stocks seeded at 0.82·K", () => {
		const report = validateBank(
			{
				name: "Bishop Shoal",
				habitat: "reef",
				depth: 80,
				richness: 1.0,
				salinity: 32,
				hazard: "rip_current",
				speciesMix: [
					{ speciesId: "lingcod", weight: 1 },
					{ speciesId: "rockfish", weight: 3 },
				],
			},
			"bk_test_1",
		);
		expect(report.ok).toBe(true);
		const region = bankToRegion(report.bank!);

		runPlans(
			buildBankInsertBatch({
				bank: report.bank!,
				region,
				month: 1,
				createdAt: new Date().toISOString(),
			}),
		);

		expect(get("SELECT id FROM banks WHERE id = 'bk_test_1'")).not.toBeNull();
		expect(get("SELECT id FROM regions WHERE id = 'bk_test_1'")).not.toBeNull();

		const stocks = all<StockRow>(
			"SELECT region_id, species_id, biomass, capacity FROM region_stocks WHERE region_id = 'bk_test_1'",
		);
		expect(stocks).toHaveLength(SPECIES.length);
		for (const stock of stocks) {
			const species = getSpecies(stock.species_id)!;
			const expectedCap = effectiveCapacity(species, region, 1);
			expect(stock.capacity, `${stock.species_id}`).toBeCloseTo(expectedCap, 9);
			expect(stock.biomass).toBeCloseTo(expectedCap * 0.82, 9);
		}
	});
});
