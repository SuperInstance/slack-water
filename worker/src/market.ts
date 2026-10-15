/**
 * Market pricing — an exact port of src/Shared/Market.luau.
 *
 * Prices key off GLOBAL abundance (Σbiomass / Σcapacity across every region).
 * That is what makes the ocean one shared economy rather than a per-server shop.
 *
 * THIS FILE IS NOT A LOOSE REIMPLEMENTATION. D1 is the truth players actually
 * harvest against, so every number here must match the Luau simulation exactly
 * or servers will disagree about what a fish is worth. `tests/parity.test.ts`
 * enforces that against `shared/economy-vectors.json`, which is generated from
 * the Luau side.
 *
 * A previous version of this file used `1 / abundance` and a minimum-move rule
 * that exist in neither version of the Luau implementation. Its own tests
 * passed. That is exactly the failure this port-and-verify setup prevents.
 */

import { CONFIG } from "./config";

/**
 * Scarcity multiplier.
 *
 * 1 / (SCARCITY_FLOOR + (1 − SCARCITY_FLOOR) · abundance), clamped to
 * [1, MAX_SCARCITY_MULTIPLIER].
 *
 * At full abundance this is exactly 1 — fish are worth base value. As abundance
 * falls it rises, reaching the cap somewhere below 0.05. The floor in the
 * denominator is what bounds the curve: without it the multiplier would diverge
 * at zero abundance and a wiped stock would become an infinite money printer.
 */
export function scarcityMultiplier(abundance: number): number {
	const a = clamp(abundance, 0.0, 1.0);
	const floor = CONFIG.SCARCITY_FLOOR;
	const multiplier = 1.0 / (floor + (1.0 - floor) * a);
	return clamp(multiplier, 1.0, CONFIG.MAX_SCARCITY_MULTIPLIER);
}

/** The price a species would trade at right now, with no inertia applied. */
export function targetPrice(baseValue: number, abundance: number): number {
	return baseValue * scarcityMultiplier(abundance);
}

export type PriceDirection = "rising" | "falling" | "flat";

export interface SteppedPrice {
	price: number;
	direction: PriceDirection;
}

/**
 * Move `prevPrice` one inertia step toward baseValue · multiplier.
 *
 * A straight `(1 − INERTIA)` fraction of the gap. There is deliberately NO
 * minimum-move rule here: the Luau side does not have one, and adding one is
 * what made the two implementations disagree. Direction is then read off the
 * result using a relative threshold OR an absolute one, so a low-priced species
 * that moved meaningfully does not read as flat.
 */
export function stepPrice(prevPrice: number, baseValue: number, multiplier: number): SteppedPrice {
	const target = baseValue * multiplier;

	if (!(prevPrice > 0)) {
		// A species the market has never priced lands straight on target.
		return { price: target, direction: "flat" };
	}

	const next = prevPrice + (target - prevPrice) * (1.0 - CONFIG.PRICE_INERTIA);
	const price = Math.max(next, 1.0);

	const relativeMove = (price - prevPrice) / prevPrice;
	const absoluteMove = price - prevPrice;

	let direction: PriceDirection = "flat";
	if (relativeMove > CONFIG.PRICE_FLOOR_MOVE || absoluteMove > 0.5) {
		direction = "rising";
	} else if (relativeMove < -CONFIG.PRICE_FLOOR_MOVE || absoluteMove < -0.5) {
		direction = "falling";
	}

	return { price, direction };
}

/** True when a stock is scarce enough to tell players to go find it elsewhere. */
export function isScarce(globalAbundance: number): boolean {
	return globalAbundance < CONFIG.COLLAPSE_THRESHOLD * 1.4;
}

function clamp(value: number, min: number, max: number): number {
	return Math.min(Math.max(value, min), max);
}