/**
 * Validation port tests — the spec-mandated behaviours: repair-don't-reject
 * for numbers, hard reject for unknown habitat / empty mix, unknown species
 * dropped, name sanitization including the blocked-token list.
 *
 * These mirror the semantics of ../src/Shared/Ocean/BankSpec.luau; when a
 * case here changes, check whether the Luau should change too.
 */

import { describe, expect, it } from "vitest";
import { bankToRegion, sanitizeName, validateBank } from "../src/validation";

function validCandidate(): Record<string, unknown> {
	return {
		name: "Bishop Shoal",
		habitat: "reef",
		depth: 80,
		richness: 1.0,
		salinity: 32,
		hazard: "rip_current",
		speciesMix: [
			{ speciesId: "lingcod", weight: 1.5 },
			{ speciesId: "rockfish", weight: 2.5 },
		],
	};
}

describe("validateBank: numeric repair", () => {
	it("clamps an out-of-range depth into 5..900 and records the repair", () => {
		const report = validateBank({ ...validCandidate(), depth: 1200 }, "bk_x");
		expect(report.ok).toBe(true);
		expect(report.bank?.depth).toBe(900);
		expect(report.repairs).toContain("depth clamped into 5..900");
	});

	it("clamps a too-shallow depth up to the 5m floor", () => {
		const report = validateBank({ ...validCandidate(), depth: -40 }, "bk_x");
		expect(report.bank?.depth).toBe(5);
	});

	it("falls back to 60m when depth is not a finite number", () => {
		for (const depth of ["eighty", null, Number.NaN, Infinity, undefined]) {
			const report = validateBank({ ...validCandidate(), depth }, "bk_x");
			expect(report.bank?.depth).toBe(60);
		}
	});

	it("clamps richness into 0.5..1.5", () => {
		const tooRich = validateBank({ ...validCandidate(), richness: 9 }, "bk_x");
		expect(tooRich.bank?.richness).toBe(1.5);
		expect(tooRich.repairs).toContain("richness clamped into 0.5..1.5");

		const tooPoor = validateBank({ ...validCandidate(), richness: 0.1 }, "bk_x");
		expect(tooPoor.bank?.richness).toBe(0.5);
	});

	it("clamps salinity into 18..36 and falls back to 32", () => {
		const salty = validateBank({ ...validCandidate(), salinity: 50 }, "bk_x");
		expect(salty.bank?.salinity).toBe(36);
		expect(salty.repairs).toContain("salinity clamped into 18..36");

		const fresh = validateBank({ ...validCandidate(), salinity: 2 }, "bk_x");
		expect(fresh.bank?.salinity).toBe(18);

		const missing = validateBank({ ...validCandidate(), salinity: "brackish" }, "bk_x");
		expect(missing.bank?.salinity).toBe(32);
	});

	it("leaves in-range values untouched with no repairs", () => {
		const report = validateBank(validCandidate(), "bk_x");
		expect(report.ok).toBe(true);
		expect(report.repairs).toEqual([]);
		expect(report.rejections).toEqual([]);
	});
});

describe("validateBank: habitat", () => {
	it("hard-rejects an unknown habitat", () => {
		const report = validateBank({ ...validCandidate(), habitat: "trench" }, "bk_x");
		expect(report.ok).toBe(false);
		expect(report.bank).toBeNull();
		expect(report.rejections).toContain("unknown or missing habitat");
	});

	it("hard-rejects a missing or non-string habitat", () => {
		for (const habitat of [undefined, 42, null]) {
			const report = validateBank({ ...validCandidate(), habitat }, "bk_x");
			expect(report.ok).toBe(false);
			expect(report.rejections).toContain("unknown or missing habitat");
		}
	});

	it("accepts every habitat in the vocabulary", () => {
		for (const habitat of ["kelp", "reef", "sand", "mud", "open", "estuary"]) {
			const report = validateBank({ ...validCandidate(), habitat }, "bk_x");
			expect(report.ok, habitat).toBe(true);
			expect(report.bank?.habitat).toBe(habitat);
		}
	});

	it("rejects non-object payloads", () => {
		for (const raw of ["bank", 42, null, true]) {
			const report = validateBank(raw, "bk_x");
			expect(report.ok).toBe(false);
			expect(report.rejections).toContain("payload was not an object");
		}
	});
});

describe("validateBank: species mix", () => {
	it("drops unknown species and records how many", () => {
		const report = validateBank(
			{
				...validCandidate(),
				speciesMix: [
					{ speciesId: "halibut", weight: 2 },
					{ speciesId: "kraken", weight: 3 },
					{ speciesId: "nessie", weight: 4 },
				],
			},
			"bk_x",
		);
		expect(report.ok).toBe(true);
		expect(report.repairs).toContain("dropped 2 unknown species");
		expect(report.bank?.speciesMix.map((e) => e.speciesId)).toEqual(["halibut"]);
	});

	it("hard-rejects when nothing valid remains in the mix", () => {
		const allUnknown = validateBank(
			{ ...validCandidate(), speciesMix: [{ speciesId: "kraken", weight: 1 }] },
			"bk_x",
		);
		expect(allUnknown.ok).toBe(false);
		expect(allUnknown.rejections).toContain("no valid species in mix");

		const noMix = validateBank({ ...validCandidate(), speciesMix: undefined }, "bk_x");
		expect(noMix.ok).toBe(false);
		expect(noMix.rejections).toContain("no valid species in mix");
	});

	it("normalises weights to sum to 1", () => {
		const report = validateBank(
			{
				...validCandidate(),
				speciesMix: [
					{ speciesId: "halibut", weight: 1 },
					{ speciesId: "cod", weight: 3 },
				],
			},
			"bk_x",
		);
		const weights = report.bank?.speciesMix.map((e) => e.weight) ?? [];
		expect(weights[0]).toBeCloseTo(0.25, 12);
		expect(weights[1]).toBeCloseTo(0.75, 12);
		expect(weights.reduce((a, b) => a + b, 0)).toBeCloseTo(1, 12);
	});

	it("clamps absurd weights to 10 before normalising", () => {
		const report = validateBank(
			{
				...validCandidate(),
				speciesMix: [
					{ speciesId: "halibut", weight: 1000 },
					{ speciesId: "cod", weight: 10 },
				],
			},
			"bk_x",
		);
		const weights = report.bank?.speciesMix.map((e) => e.weight) ?? [];
		expect(weights[0]).toBeCloseTo(0.5, 12);
		expect(weights[1]).toBeCloseTo(0.5, 12);
	});

	it("silently omits zero-weight entries and defaults missing weights to 1", () => {
		const report = validateBank(
			{
				...validCandidate(),
				speciesMix: [
					{ speciesId: "halibut" },
					{ speciesId: "cod", weight: 0 },
					{ speciesId: "skate", weight: 0 },
				],
			},
			"bk_x",
		);
		// cod dropped for zero weight (not "unknown"), halibut defaults to 1
		expect(report.bank?.speciesMix.map((e) => e.speciesId)).toEqual(["halibut"]);
		expect(report.repairs).not.toContain("dropped 1 unknown species");
	});
});

describe("name sanitization", () => {
	it("keeps a plain chart-style name", () => {
		const [name, ok] = sanitizeName("  Bishop   Shoal ", "Unnamed Ground");
		expect(ok).toBe(true);
		expect(name).toBe("Bishop Shoal");
	});

	it("falls back on every blocked token, case-insensitively and as substring", () => {
		for (const bad of [
			"Shitness Cove",
			"Scunthorpe Fcuk Bank",
			"Cunt Shoal",
			"Nigg Point",
			"Faggot Reef",
			"Rape Shoal",
			"Nazi Bank",
			"Kill Yourself Flats",
			"Suicide Pass",
		]) {
			const [name, ok] = sanitizeName(bad, "Unnamed Ground");
			expect(ok, bad).toBe(false);
			expect(name).toBe("Unnamed Ground");
		}
	});

	it("rejects too-short and too-long names", () => {
		expect(sanitizeName("Ab", "F")[1]).toBe(false);
		expect(sanitizeName("x".repeat(43), "F")[1]).toBe(false);
		expect(sanitizeName("x".repeat(42), "F")[1]).toBe(true);
	});

	it("allows only word chars, space, hyphen, apostrophe, period, comma", () => {
		const allowed = ["St. George Flats", "O'Brien's Grounds", "Cape-Scott Ridge", "Dodge, Bishop"];
		for (const name of allowed) {
			expect(sanitizeName(name, "F")[1], name).toBe(true);
		}
		const forbidden = ["Bishop & Son", "Reef #7", "Cove (West)", "Grün Bank", "Bishop!"];
		for (const name of forbidden) {
			expect(sanitizeName(name, "F")[1], JSON.stringify(name)).toBe(false);
		}
	});

	it("strips control characters and collapses whitespace before checking", () => {
		// per the Luau: %c chars become spaces, so these are CLEANED, not rejected
		const [newlineName, newlineOk] = sanitizeName("Shoal\nBank", "F");
		expect(newlineOk).toBe(true);
		expect(newlineName).toBe("Shoal Bank");

		const [name, ok] = sanitizeName("Bishop\u0007\t Sho\u0001al", "F");
		expect(ok).toBe(true);
		expect(name).toBe("Bishop Sho al");
	});

	it("falls back on a non-string name and reports the repair", () => {
		const report = validateBank({ ...validCandidate(), name: 42 }, "bk_x");
		expect(report.bank?.name).toBe("Unnamed Ground");
		expect(report.repairs).toContain("bank name rejected, using fallback");
	});
});

describe("validateBank: hazard and identity", () => {
	it("keeps a whitelisted hazard and nulls anything else without a repair", () => {
		const good = validateBank({ ...validCandidate(), hazard: "kelp_tangle" }, "bk_x");
		expect(good.bank?.hazard).toBe("kelp_tangle");

		const bad = validateBank({ ...validCandidate(), hazard: "sharks" }, "bk_x");
		expect(bad.bank?.hazard).toBeNull();
		expect(bad.repairs).toEqual([]);

		const missing = validateBank({ ...validCandidate(), hazard: undefined }, "bk_x");
		expect(missing.bank?.hazard).toBeNull();
	});

	it("stamps the fallback id and composed origin on the repaired bank", () => {
		const report = validateBank(validCandidate(), "bk_abc123");
		expect(report.bank?.id).toBe("bk_abc123");
		expect(report.bank?.origin).toBe("composed");
	});
});

describe("bankToRegion", () => {
	it("compresses the rarity signal into the 0.5..1.5 richness band", () => {
		const report = validateBank(validCandidate(), "bk_x");
		const region = bankToRegion(report.bank!);
		expect(region.richness).toBeGreaterThanOrEqual(0.5);
		expect(region.richness).toBeLessThanOrEqual(1.5);
		expect(region.id).toBe("bk_x");
		expect(region.origin).toBe("composed");
	});

	it("gives a king-crab-only ground more richness than a herring-only ground", () => {
		const crab = bankToRegion(
			validateBank({ ...validCandidate(), speciesMix: [{ speciesId: "kingcrab", weight: 1 }] }, "bk_x").bank!,
		);
		const herring = bankToRegion(
			validateBank({ ...validCandidate(), speciesMix: [{ speciesId: "herring", weight: 1 }] }, "bk_y").bank!,
		);
		expect(crab.richness).toBeGreaterThan(herring.richness);
	});
});
