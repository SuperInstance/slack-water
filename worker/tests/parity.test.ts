/**
 * Cross-language parity.
 *
 * D1 is the truth players actually harvest against; the Roblox server simulates
 * locally for smoothness. If those two implementations disagree by even a
 * rounding error, every server tells its players a different price for the same
 * fish and the shared economy is a lie.
 *
 * These tests read `shared/economy-vectors.json`, which is generated FROM THE
 * LUAU SIDE (`luau tests/generate-vectors.luau`) and therefore authoritative,
 * and assert this codebase reproduces it exactly.
 *
 * This exists because a previous version of `market.ts` shipped a scarcity
 * curve (`1 / abundance`) that matched neither version of the Luau one, and
 * its own tests passed — they only tested itself. A green suite proved nothing.
 */

import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

import { scarcityMultiplier, targetPrice, stepPrice } from "../src/market";
import { effectiveCapacity, computeHarvest } from "../src/ocean";
import { getSpecies } from "../src/species";
import { CONFIG } from "../src/config";
import type { Habitat } from "../src/species";

const HERE = dirname(fileURLToPath(import.meta.url));
const VECTORS = JSON.parse(
	readFileSync(resolve(HERE, "../../shared/economy-vectors.json"), "utf8"),
) as {
	config: Record<string, number>;
	scarcity: { abundance: number; multiplier: number }[];
	prices: { speciesId: string; abundance: number; targetPrice: number }[];
	inertia: {
		step?: number;
		abundance?: number;
		price?: number;
		direction?: string;
		settledPrice?: number;
		settledAbundance?: number;
	}[];
	harvest: {
		speciesId: string;
		effort: number;
		capacity: number;
		abundanceBefore: number;
		yielded: number;
		abundanceAfter: number;
		depleted: boolean;
	}[];
	capacity: { speciesId: string; habitat: string; depth: number; richness: number; capacity: number }[];
	regions: { index: number; id: string; name: string; habitat: string; depth: number; richness: number }[];
};

describe("config parity", () => {
	it("every economic constant matches the Luau source of truth", () => {
		// A number changed on one side only is the exact failure this guards.
		expect(CONFIG.MAX_SCARCITY_MULTIPLIER).toBe(VECTORS.config.MAX_SCARCITY_MULTIPLIER);
		expect(CONFIG.SCARCITY_FLOOR).toBe(VECTORS.config.SCARCITY_FLOOR);
		expect(CONFIG.PRICE_INERTIA).toBe(VECTORS.config.PRICE_INERTIA);
		expect(CONFIG.MAX_HARVEST_FRACTION).toBe(VECTORS.config.MAX_HARVEST_FRACTION);
		expect(CONFIG.MIN_YIELD_FACTOR).toBe(VECTORS.config.MIN_YIELD_FACTOR);
		expect(CONFIG.COLLAPSE_THRESHOLD).toBe(VECTORS.config.COLLAPSE_THRESHOLD);
	});
});

describe("scarcity curve parity", () => {
	it("reproduces every Luau scarcity multiplier", () => {
		for (const v of VECTORS.scarcity) {
			expect(scarcityMultiplier(v.abundance)).toBeCloseTo(v.multiplier, 6);
		}
	});

	it("is exactly 1 at full abundance", () => {
		expect(scarcityMultiplier(1.0)).toBeCloseTo(1.0, 9);
	});

	it("hits the cap at zero abundance rather than diverging", () => {
		expect(scarcityMultiplier(0)).toBeCloseTo(CONFIG.MAX_SCARCITY_MULTIPLIER, 6);
		expect(Number.isFinite(scarcityMultiplier(0))).toBe(true);
	});
});

describe("target price parity", () => {
	it("reproduces every Luau target price", () => {
		for (const v of VECTORS.prices) {
			const species = getSpecies(v.speciesId);
			expect(species, `unknown species ${v.speciesId}`).toBeDefined();
			expect(targetPrice(species!.baseValue, v.abundance)).toBeCloseTo(v.targetPrice, 3);
		}
	});
});

describe("market inertia parity", () => {
	it("follows the same price path as the Luau simulation", () => {
		const halibut = getSpecies("halibut")!;

		// Start from halibut's base value, exactly as Market.new() does, then
		// step eight times at abundance 0.2.
		let price = halibut.baseValue;
		for (const step of VECTORS.inertia) {
			if (step.step === undefined) continue;
			const result = stepPrice(price, halibut.baseValue, scarcityMultiplier(step.abundance ?? 1));
			expect(result.price, `price at step ${step.step}`).toBeCloseTo(step.price!, 3);
			expect(result.direction, `direction at step ${step.step}`).toBe(step.direction);
			price = result.price;
		}
	});
});

describe("capacity parity", () => {
	it("reproduces every Luau effective capacity", () => {
		for (const v of VECTORS.capacity) {
			const species = getSpecies(v.speciesId);
			expect(species, `unknown species ${v.speciesId}`).toBeDefined();
			const capacity = effectiveCapacity(species!, {
				id: "vectorRegion",
				name: "Vector Region",
				habitat: v.habitat as Habitat,
				depth: v.depth,
				salinity: 32,
				richness: v.richness,
				origin: "procedural",
			}, 1);
			expect(capacity, `capacity for ${v.speciesId}`).toBeCloseTo(v.capacity, 2);
		}
	});
});

describe("harvest parity", () => {
	it("reproduces every Luau yield", () => {
		for (const v of VECTORS.harvest) {
			const species = getSpecies(v.speciesId);
			expect(species, `unknown species ${v.speciesId}`).toBeDefined();

			const outcome = computeHarvest(
				v.abundanceBefore * v.capacity,
				v.capacity,
				v.effort,
				0,
			);

			expect(outcome.yielded, `yield at effort ${v.effort}`).toBeCloseTo(v.yielded, 2);
			expect(outcome.depleted, `depleted flag at effort ${v.effort}`).toBe(v.depleted);
		}
	});

	it("never exceeds the capacity cap even for absurd effort", () => {
		const max = VECTORS.harvest.find((h) => h.effort === 100000);
		expect(max).toBeDefined();
		const outcome = computeHarvest(
			max!.abundanceBefore * max!.capacity,
			max!.capacity,
			1e9,
			0,
		);
		expect(outcome.yielded).toBeLessThanOrEqual(max!.capacity * CONFIG.MAX_HARVEST_FRACTION + 1e-6);
	});
});