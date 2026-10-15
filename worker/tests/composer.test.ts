/**
 * Composer tests: defensive parsing of model output (prose, fences, weird
 * shapes), the never-empty guarantee, and determinism of the procedural
 * fallback. Uses a fake AiRunner — no network, no Cloudflare account.
 */

import { describe, expect, it } from "vitest";
import {
	composeBanks,
	extractBankCandidates,
	proceduralCandidate,
	type AiRunner,
} from "../src/composer";
import { makeRng } from "../src/rng";
import { validateBank } from "../src/validation";

function okBank(name: string): Record<string, unknown> {
	return {
		name,
		habitat: "reef",
		depth: 80,
		richness: 1.0,
		salinity: 32,
		hazard: "none",
		speciesMix: [{ speciesId: "lingcod", weight: 1 }],
	};
}

describe("extractBankCandidates", () => {
	it("parses a clean JSON object wrapper", () => {
		const payload = { response: JSON.stringify({ banks: [okBank("A"), okBank("B")] }) };
		expect(extractBankCandidates(payload)).toHaveLength(2);
	});

	it("parses a fenced ```json block with prose around it", () => {
		const text =
			"Sure! Here are the banks you asked for:\n```json\n" +
			JSON.stringify({ banks: [okBank("Fenced Bank")] }) +
			"\n```\nLet me know if you need more.";
		expect(extractBankCandidates({ response: text })).toHaveLength(1);
	});

	it("parses a bare JSON array dropped in prose", () => {
		const text = `Here you go: [${JSON.stringify(okBank("Bare Bank"))}] — enjoy!`;
		expect(extractBankCandidates(text)).toHaveLength(1);
	});

	it("accepts an already-parsed object (structured mode)", () => {
		expect(extractBankCandidates({ banks: [okBank("Direct Bank")] })).toHaveLength(1);
		expect(extractBankCandidates([okBank("Array Bank")])).toHaveLength(1);
		expect(extractBankCandidates(okBank("Singleton Bank"))).toHaveLength(1);
	});

	it("handles an OpenAI-style choices payload", () => {
		const payload = {
			choices: [{ message: { content: JSON.stringify({ banks: [okBank("Choices Bank")] }) } }],
		};
		expect(extractBankCandidates(payload)).toHaveLength(1);
	});

	it("returns an empty list for garbage instead of throwing", () => {
		for (const junk of [null, "", "I love fishing", "{broken", "[]]", 42, { nope: true }]) {
			expect(extractBankCandidates(junk), JSON.stringify(junk)).toEqual([]);
		}
	});
});

describe("procedural fallback", () => {
	it("produces valid banks for every seed — nothing skips arbitration", () => {
		for (let seed = 1; seed <= 300; seed++) {
			const rng = makeRng(seed);
			const candidate = proceduralCandidate(rng);
			const report = validateBank(candidate, `bk_seed_${seed}`);
			expect(report.ok, `seed ${seed}: ${JSON.stringify(candidate)} → ${report.rejections.join()}`).toBe(true);
		}
	});

	it("picks depths inside the habitat's band", () => {
		for (let seed = 1; seed <= 100; seed++) {
			const candidate = proceduralCandidate(makeRng(seed * 7919)) as {
				depth: number;
				speciesMix: { speciesId: string }[];
			};
			expect(candidate.depth).toBeGreaterThanOrEqual(5);
			expect(candidate.depth).toBeLessThanOrEqual(900);
			expect(candidate.speciesMix.length).toBeGreaterThanOrEqual(2);
		}
	});
});

describe("composeBanks", () => {
	const countingId = () => {
		let n = 0;
		return () => `bk_id_${n++}`;
	};

	it("uses model banks when they validate", async () => {
		const ai: AiRunner = {
			run: async () => ({
				response: JSON.stringify({
					banks: [okBank("Model Shoal"), { ...okBank("Bad"), habitat: "trench" }],
				}),
			}),
		};
		const result = await composeBanks({ ai, count: 2, seed: 42, makeId: countingId() });
		expect(result.banks.map((b) => b.bank.name)).toEqual(["Model Shoal", expect.any(String)]);
		expect(result.usedModel).toBe(true);
		expect(result.banks).toHaveLength(2); // invalid one replaced procedurally
		expect(result.rejections).toContain("unknown or missing habitat");
	});

	it("NEVER fails and NEVER returns an empty list when the model is unusable", async () => {
		const cases: (AiRunner | null)[] = [
			null, // binding missing
			{ run: async () => "happy to help, but no JSON here" },
			{ run: async () => { throw new Error("rate limited"); } },
			{ run: async () => ({ response: "{ truncated" }) },
			{ run: async () => ({ banks: [{ habitat: "trench" }] }) },
		];
		for (const ai of cases) {
			const result = await composeBanks({ ai, count: 4, seed: 7, makeId: countingId() });
			expect(result.banks, String(ai)).toHaveLength(4);
			expect(result.usedModel).toBe(false);
			expect(result.modelError).not.toBeNull();
			for (const { bank } of result.banks) {
				expect(bank.origin).toBe("procedural");
				expect(bank.speciesMix.length).toBeGreaterThan(0);
				const weightSum = bank.speciesMix.reduce((sum, e) => sum + e.weight, 0);
				expect(weightSum).toBeCloseTo(1, 9);
			}
		}
	});

	it("is deterministic for a given seed (same ids, same banks)", async () => {
		const run = () =>
			composeBanks({ ai: null, count: 4, seed: 1234, makeId: countingId() });
		const a = await run();
		const b = await run();
		expect(a.banks.map((x) => x.bank.id)).toEqual(b.banks.map((x) => x.bank.id));
		expect(a.banks.map((x) => x.bank.name)).toEqual(b.banks.map((x) => x.bank.name));
		expect(a.banks.map((x) => x.bank.depth)).toEqual(b.banks.map((x) => x.bank.depth));
	});

	it("fills the shortfall when the model returns fewer usable banks than asked", async () => {
		const ai: AiRunner = {
			run: async () => ({ response: JSON.stringify({ banks: [okBank("Only One")] }) }),
		};
		const result = await composeBanks({ ai, count: 4, seed: 99, makeId: countingId() });
		expect(result.banks).toHaveLength(4);
		expect(result.usedModel).toBe(true);
		expect(result.banks[0]!.bank.name).toBe("Only One");
		expect(result.banks.filter((b) => b.bank.origin === "procedural")).toHaveLength(3);
	});
});
