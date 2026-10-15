/**
 * Worker bindings and request-scoped shared types.
 */

import type { Ai, D1Database, KVNamespace } from "@cloudflare/workers-types";

export interface Env {
	/** Workers AI — proposes bank candidates that validation then arbitrates. */
	ai: Ai;
	/** Short-TTL read caches (market listing). D1 stays the source of truth. */
	OCEAN_KV: KVNamespace;
	/** The shared ocean: regions, stocks, market, banks, catch log. */
	DB: D1Database;
	/** Overrides the composer model without a code change. */
	AI_MODEL?: string;
}

export const VERSION = "1.0.0";

export interface Json {
	ok: boolean;
	[key: string]: unknown;
}
