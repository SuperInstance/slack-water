/**
 * Harvest arithmetic tests — the cap (12% of CAPACITY per event) and the
 * yield floor (25% + 75%·abundance), ported from OceanSim.harvest. These two
 * numbers are the whole economy: get them wrong and either the ocean can
 * never collapse or it collapses on one cast.
 */

import { describe, expect, it } from "vitest";
import { computeHarvest } from "../src/ocean";

describe("harvest cap", () => {
	it("caps an absurd effort at 12% of the region's CAPACITY, not its stock", () => {
		const out = computeHarvest(900, 1000, 1_000_000, 0);
		// take = min(1e6, 1000*0.12) = 120; factor at abundance 0.9 is 0.925
		expect(out.yielded).toBeCloseTo(120 * 0.925, 9);
		expect(out.remaining).toBeCloseTo(900 - 111, 9);
	});

	it("still takes the full capped amount from a nearly empty ground", () => {
		const out = computeHarvest(10, 1000, 999_999, 0);
		// abundance 0.01 → factor 0.25 + 0.75*0.01; the cap is against capacity
		const take = 120;
		expect(out.yielded).toBeCloseTo(take * (0.25 + 0.75 * 0.01), 9);
		expect(out.remaining).toBe(0);
	});

	it("does not cap a modest effort below the ceiling", () => {
		const out = computeHarvest(500, 1000, 50, 0);
		expect(out.yielded).toBeCloseTo(50 * (0.25 + 0.75 * 0.5), 9);
	});

	it("treats negative effort as zero", () => {
		const out = computeHarvest(500, 1000, -100, 0);
		expect(out.yielded).toBe(0);
		expect(out.remaining).toBe(500);
	});

	it("reports a zero-capacity species as depleted with no yield", () => {
		const out = computeHarvest(0, 0, 100, 0);
		expect(out.yielded).toBe(0);
		expect(out.depleted).toBe(true);
		expect(out.contested).toBe(false);
	});
});

describe("yield floor", () => {
	it("never lets the yield factor fall below 25%", () => {
		const out = computeHarvest(0, 1000, 1_000_000, 0);
		expect(out.yielded).toBeCloseTo(120 * 0.25, 9);
	});

	it("interpolates linearly between the floor and full yield", () => {
		// abundance 0 → 0.25, 0.5 → 0.625, 1 → 1.0
		const atZero = computeHarvest(0, 1000, 40, 0);
		const atHalf = computeHarvest(500, 1000, 40, 0);
		const atFull = computeHarvest(1000, 1000, 40, 0);
		expect(atZero.yielded).toBeCloseTo(10, 9);
		expect(atHalf.yielded).toBeCloseTo(25, 9);
		expect(atFull.yielded).toBeCloseTo(40, 9);
	});

	it("clamps abundance above 1 so an overshooting stock yields no bonus", () => {
		const over = computeHarvest(1150, 1000, 40, 0);
		expect(over.yielded).toBeCloseTo(40, 9);
	});
});

describe("abundance, depleted, contested", () => {
	it("reports abundance before and after the take", () => {
		const out = computeHarvest(400, 1000, 100, 0);
		expect(out.abundanceBefore).toBeCloseTo(0.4, 9);
		// yielded = 100 * (0.25 + 0.75*0.4) = 55
		expect(out.abundanceAfter).toBeCloseTo(0.345, 9);
	});

	it("flags depleted when the post-harvest abundance is under the collapse threshold", () => {
		const out = computeHarvest(200, 1000, 200, 0);
		// yielded = 120 * (0.25+0.75*0.2) = 48 → after 0.152 < 0.25
		expect(out.abundanceAfter).toBeCloseTo(0.152, 9);
		expect(out.depleted).toBe(true);
	});

	it("flags contested when the window already lost more than 5% of capacity", () => {
		const contested = computeHarvest(500, 1000, 10, 60);
		expect(contested.contested).toBe(true);

		const boundary = computeHarvest(500, 1000, 10, 50);
		expect(boundary.contested).toBe(false); // strictly greater, per the Luau
	});
});
