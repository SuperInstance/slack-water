/**
 * Statement plans for the mutation paths (harvest, tick, bank persistence).
 * Plans are plain {sql, params} data that index.ts submits through D1's
 * batch() — a batch runs as a single transaction, so either every statement
 * lands or none does. Keeping them as data is what lets the integration tests
 * replay the exact production statements against a real SQLite database.
 *
 * Why the tick is one big statement: D1 batches have practical statement
 * limits, and a chunked tick would only be atomic per chunk. A single
 * UPDATE ... FROM recomputes every stock's growth against the CURRENT row
 * inside one transaction — a harvest committed moments earlier still has its
 * biomass subtracted before growth applies, in either order.
 *
 * The capacity/growth expressions here are the SQL rendering of
 * effectiveCapacity() and tickStock() in ocean.ts (which mirror the Luau).
 * tests/integration.test.ts asserts the two never disagree.
 */

import { CONFIG } from "./config";
import { type Region } from "./ocean";

export interface StatementPlan {
	sql: string;
	params: (string | number | null)[];
}

export interface HarvestCatchRow {
	regionId: string;
	speciesId: string;
	effort: number;
	yielded: number;
	abundanceBefore: number;
	abundanceAfter: number;
}

/**
 * The atomic harvest transaction:
 *   1. Claim the request id. A concurrent replay of the same requestId hits
 *      the PRIMARY KEY, the whole batch rolls back, and the caller serves the
 *      stored response instead — no partial or double application, ever.
 *   2. Subtract each catch from its stock (relative to the current row, so a
 *      racing harvest is never "refunded").
 *   3. Append the catch log rows.
 *
 * Statement count is 1 + 2·catches; the 40-catch request cap keeps every
 * batch well inside D1's practical batch size.
 */
export function buildHarvestBatch(
	requestId: string,
	payloadHash: string,
	responseJson: string,
	createdAt: string,
	catches: readonly HarvestCatchRow[],
): StatementPlan[] {
	const plans: StatementPlan[] = [
		{
			sql: `INSERT INTO harvest_requests (request_id, payload_hash, response_json, created_at)
			      VALUES (?1, ?2, ?3, ?4)`,
			params: [requestId, payloadHash, responseJson, createdAt],
		},
	];

	for (const row of catches) {
		plans.push({
			sql: `UPDATE region_stocks
			      SET biomass = MAX(biomass - ?1, 0.0)
			      WHERE region_id = ?2 AND species_id = ?3`,
			params: [row.yielded, row.regionId, row.speciesId],
		});
		plans.push({
			sql: `INSERT INTO catch_events
			      (request_id, region_id, species_id, effort, yielded, abundance_before, abundance_after, created_at)
			      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)`,
			params: [
				requestId,
				row.regionId,
				row.speciesId,
				row.effort,
				row.yielded,
				row.abundanceBefore,
				row.abundanceAfter,
				createdAt,
			],
		});
	}

	return plans;
}

/**
 * The atomic tick: claim tick N+1 in tick_log (its PRIMARY KEY makes a
 * concurrent tick fail and roll back wholesale), advance the calendar, and
 * step every stock in one UPDATE.
 *
 * Params: ?1 month, ?2 ideal-habitat bonus delta (0.35), ?3 run bonus (0.85),
 * ?4 collapse threshold, ?5 collapse recovery penalty, ?6 extirpation floor,
 * ?7 overshoot clamp (1.15). The run-inflow jitter is fixed at its expected
 * value of 1.0 — the worker is the authority, so its tick is deterministic.
 *
 * capacity is never zero here by construction (affinity bottoms out at
 * 0.2·0.15 and richness at 0.5), so the divisions below are safe; the Luau's
 * `cap <= 0` guard is unreachable in practice.
 */
export const TICK_SQL = `WITH gated AS (
  SELECT
    rs.region_id AS region_id,
    rs.species_id AS species_id,
    sp.growth_rate AS rate,
    sp.run_strength AS run_strength,
    ha.affinity * (CASE WHEN r.depth >= sp.min_depth AND r.depth <= sp.max_depth THEN 1.0 ELSE 0.15 END) AS eff_affinity,
    sp.base_capacity * r.richness
      * ha.affinity
      * (CASE WHEN r.depth >= sp.min_depth AND r.depth <= sp.max_depth THEN 1.0 ELSE 0.15 END) AS scaled_base,
    -- Gate on the PRESENCE OF A RUN WINDOW, not on the anadromous column.
    -- Pacific herring aggregate to spawn in spring but never return to
    -- freshwater, so they carry run months with anadromous = 0; an anadromous
    -- gate meant their run never fired. Mirrors OceanSim.luau.
    CASE WHEN EXISTS (
      SELECT 1 FROM species_run_months m WHERE m.species_id = sp.id AND m.month = ?1
    ) THEN 1 ELSE 0 END AS running
  FROM region_stocks rs
  JOIN regions r ON r.id = rs.region_id
  JOIN species sp ON sp.id = rs.species_id
  JOIN habitat_affinity ha ON ha.region_habitat = r.habitat AND ha.species_habitat = sp.habitat
),
capped AS (
  SELECT region_id, species_id, rate, run_strength, running,
    scaled_base * (1.0
      + CASE WHEN eff_affinity >= 0.95 THEN ?2 ELSE 0.0 END
      + CASE WHEN running = 1 THEN ?3 * run_strength ELSE 0.0 END) AS cap
  FROM gated
),
final AS (
  SELECT region_id, species_id, rate, cap,
    CASE WHEN running = 1 THEN cap * ?3 * run_strength * 0.35 ELSE 0.0 END AS inflow
  FROM capped
)
UPDATE region_stocks AS rs
SET
  capacity = f.cap,
  biomass = MIN(
    MAX(
      CASE
        WHEN rs.biomass / f.cap < ?4 THEN
          rs.biomass + (f.rate * rs.biomass * (1.0 - rs.biomass / f.cap)) * ?5 + f.inflow
        ELSE
          rs.biomass + f.rate * rs.biomass * (1.0 - rs.biomass / f.cap) + f.inflow
      END,
      f.cap * ?6
    ),
    f.cap * ?7
  )
FROM final f
WHERE rs.region_id = f.region_id AND rs.species_id = f.species_id`;

export function buildTickStatements(
	nextTick: number,
	month: number,
	day: number,
	updatedAt: string,
): StatementPlan[] {
	return [
		{ sql: `INSERT INTO tick_log (tick) VALUES (?1)`, params: [nextTick] },
		{
			sql: `UPDATE ocean_state SET tick = ?1, month = ?2, day = ?3, updated_at = ?4 WHERE id = 1`,
			params: [nextTick, month, day, updatedAt],
		},
		{
			sql: TICK_SQL,
			params: [
				month,
				CONFIG.IDEAL_CAPACITY_BONUS - 1.0,
				CONFIG.RUN_CAPACITY_BONUS,
				CONFIG.COLLAPSE_THRESHOLD,
				CONFIG.COLLAPSE_RECOVERY_PENALTY,
				CONFIG.EXTIRPATION_FLOOR,
				1.15,
			],
		},
	];
}

/**
 * Persist one validated bank: the composed spec, the region it becomes
 * (richness derived from the mix via bankToRegion), and stocks seeded to the
 * healthy 0.82·K fraction OceanSim.addRegion uses — regions start stocked so
 * players have somewhere to fish before they have earned the right to
 * deplete it. One bank per batch keeps batches small and a failed insert
 * (e.g. id collision) costs only that bank, never the round.
 *
 * Params: ?1 region id, ?2 ideal bonus delta, ?3 month, ?4 run bonus.
 */
export const BANK_STOCK_SEED_SQL = `INSERT INTO region_stocks (region_id, species_id, biomass, capacity)
SELECT f.region_id, f.species_id, f.cap * 0.82, f.cap
FROM (
  SELECT ?1 AS region_id, sp.id AS species_id,
    sp.base_capacity * r.richness
      * ha.affinity
      * (CASE WHEN r.depth >= sp.min_depth AND r.depth <= sp.max_depth THEN 1.0 ELSE 0.15 END)
      * (1.0
         + CASE WHEN ha.affinity * (CASE WHEN r.depth >= sp.min_depth AND r.depth <= sp.max_depth THEN 1.0 ELSE 0.15 END) >= 0.95 THEN ?2 ELSE 0.0 END
         + CASE WHEN EXISTS (
             SELECT 1 FROM species_run_months m WHERE m.species_id = sp.id AND m.month = ?3
           ) THEN ?4 * sp.run_strength ELSE 0.0 END) AS cap
  FROM species sp
  JOIN regions r ON r.id = ?1
  JOIN habitat_affinity ha ON ha.region_habitat = r.habitat AND ha.species_habitat = sp.habitat
) f`;

export interface BankInsertInput {
	bank: {
		id: string;
		name: string;
		habitat: string;
		depth: number;
		salinity: number;
		richness: number;
		hazard: string | null;
		speciesMix: { speciesId: string; weight: number }[];
		origin: string;
	};
	region: Region;
	month: number;
	createdAt: string;
}

export function buildBankInsertBatch(
	input: BankInsertInput,
): StatementPlan[] {
	const { bank, region, month, createdAt } = input;
	return [
		{
			sql: `INSERT INTO banks
			      (id, name, habitat, depth, salinity, richness, hazard, species_mix, origin, created_at)
			      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)`,
			params: [
				bank.id,
				bank.name,
				bank.habitat,
				bank.depth,
				bank.salinity,
				bank.richness,
				bank.hazard,
				JSON.stringify(bank.speciesMix),
				bank.origin,
				createdAt,
			],
		},
		{
			sql: `INSERT INTO regions (id, name, habitat, depth, salinity, richness, origin, created_at)
			      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)`,
			params: [
				region.id,
				region.name,
				region.habitat,
				region.depth,
				region.salinity,
				region.richness,
				region.origin,
				createdAt,
			],
		},
		{
			sql: BANK_STOCK_SEED_SQL,
			params: [
				region.id,
				CONFIG.IDEAL_CAPACITY_BONUS - 1.0,
				month,
				CONFIG.RUN_CAPACITY_BONUS,
			],
		},
	];
}
