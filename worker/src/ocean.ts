/**
 * The deterministic heart of the ocean, ported from
 * ../src/Shared/Ocean/OceanSim.luau.
 *
 * Everything here is a pure function of its inputs — no I/O, no randomness
 * (the tick's run-inflow jitter is a parameter that the SQL port fixes at its
 * expected value of 1.0). Purity is what lets the exact same arithmetic be
 * expressed in SQLite inside one transaction: src/sql.ts re-states the tick
 * formula in SQL so biomass updates stay atomic against concurrent harvests,
 * and the integration test asserts the two never disagree.
 */

import { CONFIG } from "./config";
import { type Habitat, type Species, isRunning } from "./species";

export interface Region {
	id: string;
	name: string;
	habitat: Habitat;
	depth: number;
	salinity: number;
	/** 0.5..1.5, scales effective carrying capacity. */
	richness: number;
	origin: "procedural" | "composed";
}

export interface HarvestOutcome {
	yielded: number;
	remaining: number;
	abundanceBefore: number;
	abundanceAfter: number;
	depleted: boolean;
	contested: boolean;
}

// Row is [regionHabitat][speciesHabitat]; adjacent habitats are degraded but
// not zero — a rockfish on a reef thrives, on a mud bottom it barely holds on.
const ADJACENCY: Record<Habitat, Record<Habitat, number>> = {
	open: { open: 1.0, estuary: 0.6, kelp: 0.55, sand: 0.35, reef: 0.3, mud: 0.25 },
	estuary: { estuary: 1.0, open: 0.6, kelp: 0.4, sand: 0.45, reef: 0.25, mud: 0.5 },
	kelp: { kelp: 1.0, open: 0.55, reef: 0.5, estuary: 0.4, sand: 0.3, mud: 0.2 },
	reef: { reef: 1.0, kelp: 0.5, sand: 0.35, open: 0.3, mud: 0.25, estuary: 0.25 },
	sand: { sand: 1.0, open: 0.35, estuary: 0.45, mud: 0.5, reef: 0.35, kelp: 0.3 },
	mud: { mud: 1.0, open: 0.25, sand: 0.5, reef: 0.25, estuary: 0.5, kelp: 0.2 },
};

export function habitatAffinity(speciesHabitat: Habitat, regionHabitat: Habitat): number {
	if (speciesHabitat === regionHabitat) return 1.0;
	return ADJACENCY[regionHabitat][speciesHabitat] ?? 0.2;
}

/**
 * A species' effective carrying capacity in a region: baseline capacity,
 * scaled by richness, habitat affinity, a depth-band gate, and (for
 * anadromous species) the run bonus while the run is on.
 */
export function effectiveCapacity(
	species: Species,
	region: Region,
	month: number,
): number {
	let affinity = habitatAffinity(species.habitat, region.habitat);

	// Depth compatibility is a hard-ish gate: outside the band the species
	// can barely persist here.
	if (region.depth < species.minDepth || region.depth > species.maxDepth) {
		affinity *= 0.15;
	}

	const base = species.capacity * region.richness * affinity;

	let bonus = 1.0;
	if (affinity >= 0.95) {
		bonus += CONFIG.IDEAL_CAPACITY_BONUS - 1.0;
	}
	if (species.anadromous && isRunning(species, month)) {
		bonus += CONFIG.RUN_CAPACITY_BONUS * species.runStrength;
	}

	return Math.max(base * bonus, 0);
}

/**
 * One tick of the population model for a single (region, species) stock:
 * logistic growth, a collapse-recovery penalty, anadromous run inflow, the
 * extirpation floor, and the 1.15·K overshoot clamp — in the same order as
 * OceanSim.tick so the two cannot drift.
 *
 * `runJitter` stands in for the per-region noise OceanSim draws from its RNG
 * (0.7 + 0.6·f, expected value 1.0). The worker is the authority so its tick
 * is deterministic.
 */
export function tickStock(
	species: Species,
	region: Region,
	month: number,
	biomass: number,
	runJitter = 1.0,
): { biomass: number; capacity: number } {
	const cap = effectiveCapacity(species, region, month);
	if (cap <= 0) return { biomass: 0, capacity: 0 };

	let growth = species.growthRate * biomass * (1 - biomass / cap);
	if (biomass / cap < CONFIG.COLLAPSE_THRESHOLD) {
		growth *= CONFIG.COLLAPSE_RECOVERY_PENALTY;
	}

	let inflow = 0;
	if (species.anadromous && isRunning(species, month)) {
		inflow =
			cap * CONFIG.RUN_CAPACITY_BONUS * species.runStrength * 0.35 * runJitter;
	}

	let next = biomass + growth + inflow;
	// Extirpation floor: fishing alone cannot drive a stock to literal zero —
	// it recolonises. Without this one over-fishing crew scars a region forever.
	if (next < cap * CONFIG.EXTIRPATION_FLOOR) {
		next = cap * CONFIG.EXTIRPATION_FLOOR;
	}

	return { biomass: clamp(next, 0, cap * 1.15), capacity: cap };
}

/**
 * The harvest arbitration, ported from OceanSim.harvest. `windowHarvested` is
 * the total biomass already taken from the region inside the contention
 * window — the contested signal is how one crew learns another was just here.
 *
 * Because the take is capped against CAPACITY rather than current stock,
 * sustained pressure genuinely collapses a stock; that collapse is what the
 * scarcity economy keys off.
 */
export function computeHarvest(
	biomass: number,
	capacity: number,
	effort: number,
	windowHarvested: number,
): HarvestOutcome {
	const abundanceBefore = capacity > 0 ? biomass / capacity : 0;

	if (capacity <= 0) {
		// The region exists, but this species cannot live here at all.
		return {
			yielded: 0,
			remaining: biomass,
			abundanceBefore: 0,
			abundanceAfter: 0,
			depleted: true,
			contested: false,
		};
	}

	const request = Math.max(effort, 0);
	const ceiling = capacity * CONFIG.MAX_HARVEST_FRACTION;
	const take = Math.min(request, ceiling);

	// Yield degrades with abundance but keeps a floor, so a picked-out ground
	// is poor rather than pointless.
	const yieldFactor =
		CONFIG.MIN_YIELD_FACTOR +
		(1 - CONFIG.MIN_YIELD_FACTOR) * clamp(abundanceBefore, 0, 1);
	const yielded = take * yieldFactor;

	const remaining = Math.max(biomass - yielded, 0);
	const abundanceAfter = remaining / capacity;

	return {
		yielded,
		remaining,
		abundanceBefore,
		abundanceAfter,
		depleted: abundanceAfter < CONFIG.COLLAPSE_THRESHOLD,
		contested: windowHarvested > capacity * CONFIG.CONTEST_THRESHOLD,
	};
}

/** Global abundance: total supply over total capacity; 1.0 when absent. */
export function globalAbundance(supply: number, capacity: number): number {
	if (capacity <= 0) return 1.0;
	return supply / capacity;
}

/**
 * Sim calendar from the tick counter (12 ticks/day, 4 days/month,
 * 12 months/year), matching OceanSim.advanceDay's wrap-around arithmetic.
 */
export function calendarFromTick(tick: number): { month: number; day: number } {
	const day = (Math.floor(tick / CONFIG.TICKS_PER_DAY) % CONFIG.DAYS_PER_MONTH) + 1;
	const month =
		(Math.floor(tick / (CONFIG.TICKS_PER_DAY * CONFIG.DAYS_PER_MONTH)) %
			CONFIG.MONTHS_PER_YEAR) +
		1;
	return { month, day };
}

export function clamp(value: number, min: number, max: number): number {
	return Math.min(Math.max(value, min), max);
}
