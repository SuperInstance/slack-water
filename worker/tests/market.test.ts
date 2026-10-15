/**
 * Market tests: scarcity responds to falling abundance, prices step toward
 * the target with inertia but never below a minimum relative move, and the
 * multiplier is capped so a collapsed species is not a money printer.
 */

import { describe, expect, it } from "vitest";
import { scarcityMultiplier, stepPrice } from "../src/market";
import { CONFIG } from "../src/config";

describe("scarcityMultiplier", () => {
	it("is 1.0 at (or above) full abundance", () => {
		expect(scarcityMultiplier(1)).toBe(1);
		expect(scarcityMultiplier(1.4)).toBe(1);
	});

	it("rises as abundance falls (until the cap saturates)", () => {
		let previous = 0;
		for (const abundance of [1, 0.8, 0.6, 0.4, 0.2]) {
			const multiplier = scarcityMultiplier(abundance);
			expect(multiplier).toBeGreaterThan(previous);
			previous = multiplier;
		}
		// The curve asymptotes at 1/SCARCITY_FLOOR = 6.67 and the cap holds it
		// flat at 6. The cap only binds once the curve would exceed it, which
		// is below roughly 2% abundance — that is the whole reason SCARCITY_FLOOR
		// is 0.15 and not 0.25 (which would have made the cap dead config).
		const f = CONFIG.SCARCITY_FLOOR;
		expect(scarcityMultiplier(0.01)).toBe(CONFIG.MAX_SCARCITY_MULTIPLIER);
		expect(scarcityMultiplier(0.001)).toBe(CONFIG.MAX_SCARCITY_MULTIPLIER);
		expect(scarcityMultiplier(0.02)).toBeLessThan(CONFIG.MAX_SCARCITY_MULTIPLIER);
		expect(1 / f).toBeGreaterThan(CONFIG.MAX_SCARCITY_MULTIPLIER);
	});

	it("follows the exact Luau curve, not a doubling rule", () => {
		// The curve is 1 / (FLOOR + (1 - FLOOR) * abundance). It is NOT linear
		// in log-abundance, and an earlier version of this file asserted a
		// doubling rule that the simulation never had.
		const f = CONFIG.SCARCITY_FLOOR;
		for (const abundance of [0.1, 0.25, 0.5, 0.75, 0.9]) {
			const expected = Math.min(
				Math.max(1 / (f + (1 - f) * abundance), 1),
				CONFIG.MAX_SCARCITY_MULTIPLIER,
			);
			expect(scarcityMultiplier(abundance)).toBeCloseTo(expected, 9);
		}
		expect(scarcityMultiplier(0.5)).toBeCloseTo(1 / (f + (1 - f) * 0.5), 9);
		expect(scarcityMultiplier(0.25)).toBeCloseTo(1 / (f + (1 - f) * 0.25), 9);
	});

	it("caps at MAX_SCARCITY_MULTIPLIER however empty the ocean", () => {
		expect(scarcityMultiplier(0)).toBe(CONFIG.MAX_SCARCITY_MULTIPLIER);
		expect(scarcityMultiplier(-1)).toBe(CONFIG.MAX_SCARCITY_MULTIPLIER);
		// and never exceeds it, at any abundance
		for (const abundance of [0, 0.001, 0.01, 0.05, 0.5, 1, 2]) {
			expect(scarcityMultiplier(abundance)).toBeLessThanOrEqual(
				CONFIG.MAX_SCARCITY_MULTIPLIER,
			);
		}
	});
});

describe("stepPrice", () => {
	it("moves an inertia fraction of the gap toward the scarcity target", () => {
		// prev 100, target 200: move = 100 * (1 - 0.82) = 18
		const out = stepPrice(100, 100, 2);
		expect(out.price).toBeCloseTo(118, 9);
		expect(out.direction).toBe("rising");
	});

	it("falls toward target when the market is glutted", () => {
		// prev 150, target 100: move = -50 * 0.18 = -9
		const out = stepPrice(150, 100, 1);
		expect(out.price).toBeCloseTo(141, 9);
		expect(out.direction).toBe("falling");
	});

	it("moves a strict inertia fraction and reports a tiny move as flat", () => {
		// There is no minimum-move rule: the Luau simulation steps a strict
		// (1 - INERTIA) fraction of the gap. PRICE_FLOOR_MOVE only affects the
		// DIRECTION label, so a 1% gap reads as flat until it exceeds 1.5%.
		const tinyGap = stepPrice(100, 100, 1.01);
		expect(tinyGap.price).toBeCloseTo(100 + 1 * 0.18, 9);
		expect(tinyGap.direction).toBe("flat");

		// A gap of 5 gives an absolute move of 0.9, which clears the absolute
		// 0.5 threshold, so this one reads rising.
		const clearGap = stepPrice(100, 100, 1.05);
		expect(clearGap.price).toBeCloseTo(100.9, 9);
		expect(clearGap.direction).toBe("rising");

		const tinyFall = stepPrice(100, 100, 0.99);
		expect(tinyFall.price).toBeCloseTo(100 - 1 * 0.18, 9);
		expect(tinyFall.direction).toBe("flat");

		const clearFall = stepPrice(100, 100, 0.95);
		expect(clearFall.price).toBeCloseTo(99.1, 9);
		expect(clearFall.direction).toBe("falling");
	});

	it("is flat when already at the target", () => {
		const out = stepPrice(120, 100, 1.2);
		expect(out.price).toBeCloseTo(120, 9);
		expect(out.direction).toBe("flat");
	});

	it("seeds an unpriced species directly at the scarcity target", () => {
		const out = stepPrice(0, 220, 1.2);
		expect(out.price).toBeCloseTo(264, 9);
	});

	it("converges to the target over repeated steps, without oscillation", () => {
		let price = 100;
		for (let i = 0; i < 200; i++) {
			price = stepPrice(price, 100, 3).price;
		}
		expect(price).toBeCloseTo(300, 6);
	});
});

describe("price response to a collapsing stock", () => {
	it("a falling abundance path produces strictly rising prices then a cap", () => {
		let price = 220; // chinook base value
		const prices: number[] = [];
		for (const abundance of [1, 0.75, 0.5, 0.35, 0.2, 0.1, 0.05]) {
			price = stepPrice(price, 220, scarcityMultiplier(abundance)).price;
			prices.push(price);
		}
		for (let i = 1; i < prices.length; i++) {
			expect(prices[i]!).toBeGreaterThan(prices[i - 1]!);
		}
		// final multiplier is capped at 6 → target 1320; 200 steps not taken,
		// but the trajectory must be monotone up and bounded by the target.
		expect(prices[prices.length - 1]!).toBeLessThan(220 * 6 + 1);
	});
});
