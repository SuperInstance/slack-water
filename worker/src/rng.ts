/**
 * Park-Miller "minimal standard" PRNG, ported from
 * ../src/Shared/Ocean/Rng.luau.
 *
 * The procedural bank fallback must be deterministic given a seed — that is
 * what makes a "composed round" reproducible in tests and post-mortems, and it
 * rules out Math.random().
 */

const MODULUS = 2147483647; // 2^31 - 1
const MULTIPLIER = 16807;

export interface Rng {
	nextInt(): number;
	nextFloat(): number;
	range(min: number, max: number): number;
	int(min: number, max: number): number;
	pick<T>(list: readonly T[]): T;
	chance(p: number): boolean;
}

export function makeRng(seed: number): Rng {
	// Park-Miller cannot escape a zero state; fold the seed in and warm the
	// recurrence so nearby seeds do not produce near-identical streams.
	let state = (Math.abs(Math.floor(seed)) % (MODULUS - 1)) + 1;
	for (let i = 0; i < 4; i++) {
		state = (state * MULTIPLIER) % MODULUS;
	}

	const nextInt = (): number => {
		state = (state * MULTIPLIER) % MODULUS;
		return state;
	};

	const nextFloat = (): number => nextInt() / MODULUS;

	return {
		nextInt,
		nextFloat,
		range: (min, max) => min + (max - min) * nextFloat(),
		int(min, max) {
			if (max <= min) return min;
			const span = max - min + 1;
			return min + (nextInt() % span);
		},
		pick<T>(list: readonly T[]): T {
			const item = list[this.int(0, list.length - 1)];
			if (item === undefined) {
				throw new Error("rng.pick on empty list");
			}
			return item;
		},
		chance: (p) => nextFloat() < p,
	};
}
