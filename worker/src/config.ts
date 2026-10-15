/**
 * Tuning constants for the worker-side ocean.
 *
 * The simulation-tuning half of this file is a mirror of
 * ../src/Shared/Config.luau. The client simulates locally for smoothness but
 * D1 is the truth players actually harvest against, so the two files MUST stay
 * in sync — a mismatch silently desyncs every Roblox server from the worker.
 * If you change a number here, change it there in the same commit.
 */

export const CONFIG = {
	// Calendar (sim time; the cron ticks once per minute)
	MONTHS_PER_YEAR: 12,
	DAYS_PER_MONTH: 4,
	TICKS_PER_DAY: 12,

	// Population dynamics
	IDEAL_CAPACITY_BONUS: 1.35,
	RUN_CAPACITY_BONUS: 0.85,
	COLLAPSE_THRESHOLD: 0.25,
	COLLAPSE_RECOVERY_PENALTY: 0.6,
	EXTIRPATION_FLOOR: 0.02,

	// Market
	MAX_SCARCITY_MULTIPLIER: 6.0,
	PRICE_INERTIA: 0.82,
	PRICE_FLOOR_MOVE: 0.015,

	// Harvesting
	MAX_HARVEST_FRACTION: 0.12,
	MIN_YIELD_FACTOR: 0.25,
	CONTEST_THRESHOLD: 0.05,

	// Banking
	BANKS_PER_ROUND: 4,
	MAX_BANKS: 4096,
} as const;

// Worker-only tunables (no Config.luau counterpart).

/** How long a catch log counts toward the "contested" signal for a region. */
export const HARVEST_WINDOW_SECONDS = 60;

/** Cap on catches per harvest request; keeps one batch bounded. */
export const MAX_CATCHES_PER_REQUEST = 64;

/** Ticks the manual/cron tick endpoint may apply in one invocation. */
export const MAX_TICKS_PER_INVOCATION = 12;

/** Cache lifetime for the /market listing in KV. */
export const MARKET_CACHE_TTL_SECONDS = 10;

/**
 * Minimum gap between market_price_history rows per species, so a burst of
 * /market reads doesn't flood the history table with near-identical rows.
 */
export const MARKET_HISTORY_MIN_GAP_SECONDS = 60;

/** Wall-clock budget for one Workers AI composition call. */
export const AI_TIMEOUT_MS = 25_000;
