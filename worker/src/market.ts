/**
 * Market pricing. Prices key off GLOBAL abundance (Σbiomass / Σcapacity
 * across every region) — that is what makes the ocean one shared economy
 * rather than per-server shops.
 *
 * There is no Market.luau to port; these functions implement the behaviour
 * the Config.luau market constants describe: an inverse-abundance scarcity
 * multiplier capped at MAX_SCARCITY_MULTIPLIER, inertia so the market doesn't
 * ping-pong on small catches, and a minimum move so small volume still nudges
 * the price.
 */

import { CONFIG } from "./config";

/**
 * Scarcity multiplier: 1/abundance, clamped to [1, MAX]. At full abundance
 * fish are worth base value; at 1/6th abundance the cap bites, so a collapsed
 * species becomes valuable but never an instant money printer.
 */
export function scarcityMultiplier(abundance: number): number {
	if (abundance <= 0) return CONFIG.MAX_SCARCITY_MULTIPLIER;
	return clamp(1 / abundance, 1.0, CONFIG.MAX_SCARCITY_MULTIPLIER);
}

export type PriceDirection = "rising" | "falling" | "flat";

export interface SteppedPrice {
	price: number;
	direction: PriceDirection;
}

/**
 * Move `prevPrice` one inertia step toward baseValue·multiplier.
 *
 * The step is (1 − INERTIA) of the gap, but never smaller than
 * PRICE_FLOOR_MOVE·prevPrice while a gap exists, and never large enough to
 * overshoot the target (which would make the price oscillate around it).
 */
export function stepPrice(
	prevPrice: number,
	baseValue: number,
	multiplier: number,
): SteppedPrice {
	const target = baseValue * multiplier;
	if (prevPrice <= 0) {
		// First pricing of a freshly seeded species: jump straight to target.
		return { price: target, direction: "flat" };
	}

	const delta = target - prevPrice;
	if (delta === 0) return { price: prevPrice, direction: "flat" };

	const inertiaMove = delta * (1 - CONFIG.PRICE_INERTIA);
	const minMove = prevPrice * CONFIG.PRICE_FLOOR_MOVE;
	const move =
		delta > 0
			? Math.min(Math.max(inertiaMove, minMove), delta)
			: Math.max(Math.min(inertiaMove, -minMove), delta);

	const price = prevPrice + move;
	return {
		price,
		direction: move > 0 ? "rising" : move < 0 ? "falling" : "flat",
	};
}

function clamp(value: number, min: number, max: number): number {
	return Math.min(Math.max(value, min), max);
}
