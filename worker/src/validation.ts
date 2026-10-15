/**
 * Bank validation — a TypeScript port of ../src/Shared/Ocean/BankSpec.luau.
 *
 * The design thesis carried over unchanged: THE AI PROPOSES, THE SIMULATION
 * ARBITRATES. Nothing the model emits is trusted; it is *repaired* against the
 * deterministic simulation's own rules before it may exist in the world.
 *
 * Porting rules (do not break them):
 *   - Repair, not reject: out-of-range numbers are clamped, unknown species
 *     are dropped, a bad name falls back. Only "nothing salvageable"
 *     (non-object, unknown habitat, empty mix) is a hard rejection.
 *   - Total determinism given input: no randomness, no clock, no I/O — the
 *     same model output always produces the same bank, on any replica.
 *
 * Semantics mirror the Luau exactly, including its quirks: the name charset
 * also admits commas (the Luau pattern `[%w %-%'%.,]` allows them), and a
 * species entry with weight 0 is silently omitted rather than counted as
 * dropped.
 */

import { getSpecies, type Habitat, type Species } from "./species";

export const VALID_HABITATS: readonly Habitat[] = [
	"kelp",
	"reef",
	"sand",
	"mud",
	"open",
	"estuary",
] as const;

export const VALID_HAZARDS: readonly string[] = [
	"none",
	"rip_current",
	"rocky_bottom",
	"deep_water",
	"kelp_tangle",
	"seabird_activity",
	"debris_field",
	"cold_drain",
] as const;

// A blunt first line of defence against model-authored names — not a
// substitute for Roblox's own moderation, but a bank name is rendered in the
// UI and should never be the thing that trips a filter. Substring match on
// the lowered name, exactly like the Luau.
const BLOCKED_NAME_TOKENS: readonly string[] = [
	"fuck",
	"shit",
	"cunt",
	"nigg",
	"faggot",
	"rape",
	"nazi",
	"kill yourself",
	"suicide",
];

export interface SpeciesMixEntry {
	speciesId: string;
	weight: number;
}

export interface BankSpec {
	id: string;
	name: string;
	habitat: Habitat;
	depth: number;
	richness: number;
	salinity: number;
	speciesMix: SpeciesMixEntry[];
	hazard: string | null;
	origin: "composed" | "procedural";
}

export interface ValidationReport {
	ok: boolean;
	bank: BankSpec | null;
	repairs: string[];
	rejections: string[];
}

function clampNumber(
	value: unknown,
	min: number,
	max: number,
	fallback: number,
): number {
	if (typeof value !== "number" || !Number.isFinite(value)) return fallback;
	return Math.min(Math.max(value, min), max);
}

/**
 * Clean a model-authored name: strip control characters, collapse whitespace,
 * enforce 3..42 chars, blocklisted tokens, and the allowed charset.
 * Returns [name, ok]; on any failure the caller uses the fallback name.
 */
export function sanitizeName(
	raw: unknown,
	fallback: string,
): [name: string, ok: boolean] {
	if (typeof raw !== "string") return [fallback, false];

	// The Luau strips %c (control chars) to spaces, collapses runs of
	// whitespace, and trims — anything else survives to the checks below.
	const cleaned = raw
		.replace(/[\x00-\x1f\x7f]/g, " ")
		.replace(/\s+/g, " ")
		.trim();

	if (cleaned.length < 3 || cleaned.length > 42) return [fallback, false];

	const lowered = cleaned.toLowerCase();
	for (const token of BLOCKED_NAME_TOKENS) {
		if (lowered.includes(token)) return [fallback, false];
	}

	// Letters, digits, spaces, hyphens, apostrophes, periods — and commas,
	// which the Luau pattern `[%w %-%'%.,]` admits. ASCII only.
	if (!/^[A-Za-z0-9 '\-.,]+$/.test(cleaned)) return [fallback, false];

	return [cleaned, true];
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null;
}

function isHabitat(value: unknown): value is Habitat {
	return (
		typeof value === "string" &&
		(VALID_HABITATS as readonly string[]).includes(value)
	);
}

/**
 * Validate and repair a model-authored bank. Returns a report rather than a
 * bare bank: the repair telemetry is how the prompt gets tuned (a high repair
 * rate means the model is drifting).
 */
export function validateBank(raw: unknown, fallbackId: string): ValidationReport {
	const report: ValidationReport = {
		ok: false,
		bank: null,
		repairs: [],
		rejections: [],
	};

	if (!isPlainObject(raw)) {
		report.rejections.push("payload was not an object");
		return report;
	}

	// Habitat must be a known value: guessing which of six habitats was meant
	// would be guessing at the game's core structure, so this one is a
	// rejection rather than a repair.
	const habitat: Habitat | undefined = isHabitat(raw.habitat)
		? raw.habitat
		: undefined;
	if (habitat === undefined) {
		report.rejections.push("unknown or missing habitat");
		return report;
	}

	// Depth is clamped rather than rejected: a model asking for 1200m meant
	// "very deep", and 900m is a perfectly good fishing bank.
	const depth = clampNumber(raw.depth, 5, 900, 60);
	if (depth !== raw.depth) report.repairs.push("depth clamped into 5..900");

	const richness = clampNumber(raw.richness, 0.5, 1.5, 1.0);
	if (richness !== raw.richness) report.repairs.push("richness clamped into 0.5..1.5");

	const salinity = clampNumber(raw.salinity, 18, 36, 32);
	if (salinity !== raw.salinity) report.repairs.push("salinity clamped into 18..36");

	// Species mix: unknown species are dropped, not fatal. The mix is a
	// suggestion about what lives here; the simulation decides what survives.
	// The Luau iterates any table (array or map) by value, so a JSON object
	// whose values are entries is accepted the same way.
	const mix: SpeciesMixEntry[] = [];
	const rawMix: unknown = raw.speciesMix;
	if (Array.isArray(rawMix)) {
		collectMixEntries(rawMix.values(), mix, report);
	} else if (isPlainObject(rawMix)) {
		collectMixEntries(Object.values(rawMix), mix, report);
	}

	if (mix.length === 0) {
		report.rejections.push("no valid species in mix");
		return report;
	}

	// Normalise so downstream code can assume weights sum to 1.
	const totalWeight = mix.reduce((sum, entry) => sum + entry.weight, 0);
	if (totalWeight > 0) {
		for (const entry of mix) entry.weight = entry.weight / totalWeight;
	}

	const [name, nameOk] = sanitizeName(raw.name, "Unnamed Ground");
	if (!nameOk) report.repairs.push("bank name rejected, using fallback");

	let hazard: string | null = null;
	if (
		typeof raw.hazard === "string" &&
		(VALID_HAZARDS as readonly string[]).includes(raw.hazard)
	) {
		hazard = raw.hazard;
	}

	report.bank = {
		id: fallbackId,
		name,
		habitat,
		depth,
		richness,
		salinity,
		speciesMix: mix,
		hazard,
		origin: "composed",
	};
	report.ok = true;
	return report;
}

function collectMixEntries(
	entries: Iterable<unknown>,
	mix: SpeciesMixEntry[],
	report: ValidationReport,
): void {
	let dropped = 0;
	for (const entry of entries) {
		if (!isPlainObject(entry) || typeof entry.speciesId !== "string") continue;
		if (getSpecies(entry.speciesId) === null) {
			dropped++;
			continue;
		}
		const weight = clampNumber(entry.weight, 0.0, 10.0, 1.0);
		if (weight > 0) mix.push({ speciesId: entry.speciesId, weight });
	}
	if (dropped > 0) report.repairs.push(`dropped ${dropped} unknown species`);
}

/**
 * Convert a validated bank into the region shape the ocean stores. The
 * species mix is NOT applied as a hard override — it becomes a richness nudge
 * (rarer species imply a richer, more specialised ground), compressed into
 * the playable band. The simulation still decides what actually lives there.
 */
export function bankToRegion(bank: BankSpec): {
	id: string;
	name: string;
	habitat: Habitat;
	depth: number;
	salinity: number;
	richness: number;
	origin: "procedural" | "composed";
} {
	let weightedRichness = 0;
	for (const entry of bank.speciesMix) {
		const species: Species | null = getSpecies(entry.speciesId);
		if (species) {
			weightedRichness += (1 / Math.max(species.rarity, 0.01)) * entry.weight;
		}
	}

	const richness = Math.min(Math.max(0.6 + weightedRichness / 40, 0.5), 1.5);

	return {
		id: bank.id,
		name: bank.name,
		habitat: bank.habitat,
		depth: bank.depth,
		salinity: bank.salinity,
		richness,
		origin: bank.origin,
	};
}
