/**
 * Ocean dynamics tests: effective capacity (habitat affinity, depth gate,
 * run bonus), the per-stock tick (logistic growth, collapse penalty,
 * extirpation floor, overshoot clamp), and the sim calendar.
 */

import { describe, expect, it } from "vitest";
import {
	calendarFromTick,
	effectiveCapacity,
	habitatAffinity,
	tickStock,
	type Region,
} from "../src/ocean";
import { getSpecies } from "../src/species";

function region(overrides: Partial<Region> = {}): Region {
	return {
		id: "r_test",
		name: "Test Ground",
		habitat: "reef",
		depth: 60,
		salinity: 33,
		richness: 1.0,
		origin: "procedural",
		...overrides,
	};
}

describe("habitatAffinity", () => {
	it("is 1.0 on the matching habitat", () => {
		for (const habitat of ["kelp", "reef", "sand", "mud", "open", "estuary"] as const) {
			expect(habitatAffinity(habitat, habitat)).toBe(1.0);
		}
	});

	it("degrades on adjacent habitats per the OceanSim matrix", () => {
		expect(habitatAffinity("reef", "mud")).toBe(0.25);
		expect(habitatAffinity("kelp", "mud")).toBe(0.2);
		expect(habitatAffinity("sand", "mud")).toBe(0.5);
		expect(habitatAffinity("open", "estuary")).toBe(0.6);
	});
});

describe("effectiveCapacity", () => {
	it("gives an in-band species on its home habitat the ideal bonus", () => {
		const rockfish = getSpecies("rockfish")!;
		const cap = effectiveCapacity(rockfish, region({ habitat: "reef", depth: 60 }), 1);
		// 1100 * 1.0 * 1.0 affinity * 1.35 ideal bonus
		expect(cap).toBeCloseTo(1100 * 1.35, 9);
	});

	it("scales with regional richness", () => {
		const rockfish = getSpecies("rockfish")!;
		const cap = effectiveCapacity(rockfish, region({ richness: 0.5 }), 1);
		expect(cap).toBeCloseTo(1100 * 0.5 * 1.35, 9);
	});

	it("drops out-of-band species to 15% of their habitat affinity", () => {
		const rockfish = getSpecies("rockfish")!; // band 25..120
		const cap = effectiveCapacity(rockfish, region({ depth: 5 }), 1);
		// affinity 1.0 * 0.15 gate, below 0.95 → no ideal bonus
		expect(cap).toBeCloseTo(1100 * 0.15, 9);
	});

	it("applies the run bonus to anadromous species inside their run window only", () => {
		const chinook = getSpecies("chinook")!;
		const openWater = region({ habitat: "open", depth: 100 });
		const running = effectiveCapacity(chinook, openWater, 4); // run months 3-6
		const notRunning = effectiveCapacity(chinook, openWater, 1);
		// base 900 · bonus (1 + 0.35 ideal + 0.85·1.0 run) = 900 · 2.2
		expect(running).toBeCloseTo(900 * 2.2, 9);
		expect(notRunning).toBeCloseTo(900 * 1.35, 9);
	});

	it("gives a mismatched-habitat species the adjacency value", () => {
		const halibut = getSpecies("halibut")!; // sand species, band 200..900
		const cap = effectiveCapacity(halibut, region({ habitat: "reef", depth: 300 }), 1);
		// reef region, sand species: affinity 0.35, in band, below 0.95 → no bonus
		expect(cap).toBeCloseTo(420 * 0.35, 9);
	});
});

describe("tickStock", () => {
	it("grows a stock logistically toward its capacity", () => {
		const cod = getSpecies("cod")!;
		const ground = region({ habitat: "mud", depth: 150 });
		const cap = effectiveCapacity(cod, ground, 1);
		const biomass = cap * 0.5;
		const out = tickStock(cod, ground, 1, biomass);
		const expectedGrowth = 0.07 * biomass * (1 - biomass / cap);
		expect(out.capacity).toBeCloseTo(cap, 9);
		expect(out.biomass).toBeCloseTo(biomass + expectedGrowth, 9);
	});

	it("recovers a collapsed stock at 60% speed", () => {
		const cod = getSpecies("cod")!;
		const ground = region({ habitat: "mud", depth: 150 });
		const cap = effectiveCapacity(cod, ground, 1);
		const healthy = cap * 0.6;
		const collapsed = cap * 0.1; // below the 0.25 threshold

		const healthyGrowth = tickStock(cod, ground, 1, healthy).biomass - healthy;
		const collapsedGrowth = tickStock(cod, ground, 1, collapsed).biomass - collapsed;
		const ratio = collapsedGrowth / healthyGrowth;
		// both linear in biomass around these levels, so the penalty shows directly
		expect(ratio).toBeCloseTo(0.6 * (collapsed * (1 - 0.1)) / (healthy * (1 - 0.6)), 6);
	});

	it("floors an extirpated stock at 2% of capacity — fishing cannot zero it", () => {
		const cod = getSpecies("cod")!;
		const ground = region({ habitat: "mud", depth: 150 });
		const cap = effectiveCapacity(cod, ground, 1);
		const out = tickStock(cod, ground, 1, cap * 0.001);
		expect(out.biomass).toBeCloseTo(cap * 0.02, 9);
	});

	it("clamps overshoot at 115% of capacity", () => {
		const cod = getSpecies("cod")!;
		const ground = region({ habitat: "mud", depth: 150 });
		const cap = effectiveCapacity(cod, ground, 1);
		const out = tickStock(cod, ground, 1, cap * 1.5); // run-inflow-free species
		expect(out.biomass).toBeCloseTo(cap * 1.15, 9);
	});

	it("adds run inflow during the run window and decays it after", () => {
		const chinook = getSpecies("chinook")!;
		const openWater = region({ habitat: "open", depth: 100 });
		const cap = effectiveCapacity(chinook, openWater, 4);
		const biomass = cap * 0.5;

		const during = tickStock(chinook, openWater, 4, biomass);
		const after = tickStock(chinook, openWater, 7, biomass);

		const growth = 0.09 * biomass * (1 - biomass / cap);
		const inflow = cap * 0.85 * 1.0 * 0.35; // runStrength 1.0, jitter 1.0
		expect(during.biomass).toBeCloseTo(biomass + growth + inflow, 9);
		// month 7 uses the non-run capacity, growth only
		const capAfter = effectiveCapacity(chinook, openWater, 7);
		const growthAfter = 0.09 * biomass * (1 - biomass / capAfter);
		expect(after.biomass).toBeCloseTo(biomass + growthAfter, 9);
	});
});

describe("calendarFromTick", () => {
	it("derives day (12 ticks) and month (4 days) exactly as advanceDay does", () => {
		expect(calendarFromTick(0)).toEqual({ month: 1, day: 1 });
		expect(calendarFromTick(11)).toEqual({ month: 1, day: 1 });
		expect(calendarFromTick(12)).toEqual({ month: 1, day: 2 });
		expect(calendarFromTick(47)).toEqual({ month: 1, day: 4 });
		expect(calendarFromTick(48)).toEqual({ month: 2, day: 1 });
		expect(calendarFromTick(575)).toEqual({ month: 12, day: 4 });
		expect(calendarFromTick(576)).toEqual({ month: 1, day: 1 }); // new year
	});
});
