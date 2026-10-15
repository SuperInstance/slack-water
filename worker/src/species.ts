/**
 * The species roster, ported verbatim from ../src/Shared/Species.luau.
 *
 * This list is the authority on what may exist in the ocean: validation drops
 * any species id that is not in it, and the composer prompt forbids the model
 * from inventing ids outside it. Adding a species means changing both files.
 *
 * Fields left out (weightRange, harvestDifficulty, scientificName) are pure
 * client-side flavour — the worker never prices or simulates off them.
 */

export type Habitat = "kelp" | "reef" | "sand" | "mud" | "open" | "estuary";

export interface Species {
	id: string;
	displayName: string;
	habitat: Habitat;
	minDepth: number;
	maxDepth: number;
	capacity: number;
	growthRate: number;
	baseValue: number;
	anadromous: boolean;
	runMonths: readonly number[] | null;
	runStrength: number;
	rarity: number;
}

const SPECIES_LIST: readonly Species[] = [
	{
		id: "chinook",
		displayName: "Chinook Salmon",
		habitat: "open",
		minDepth: 30,
		maxDepth: 300,
		capacity: 900,
		growthRate: 0.09,
		baseValue: 220,
		anadromous: true,
		runMonths: [3, 4, 5, 6],
		runStrength: 1.0,
		rarity: 0.18,
	},
	{
		id: "coho",
		displayName: "Coho Salmon",
		habitat: "open",
		minDepth: 20,
		maxDepth: 200,
		capacity: 1100,
		growthRate: 0.11,
		baseValue: 120,
		anadromous: true,
		runMonths: [8, 9, 10],
		runStrength: 0.85,
		rarity: 0.26,
	},
	{
		id: "sockeye",
		displayName: "Sockeye Salmon",
		habitat: "open",
		minDepth: 100,
		maxDepth: 320,
		capacity: 800,
		growthRate: 0.1,
		baseValue: 95,
		anadromous: true,
		runMonths: [8, 9, 10],
		runStrength: 0.9,
		rarity: 0.28,
	},
	{
		id: "pink",
		displayName: "Pink Salmon",
		habitat: "estuary",
		minDepth: 5,
		maxDepth: 120,
		capacity: 2400,
		growthRate: 0.16,
		baseValue: 40,
		anadromous: true,
		runMonths: [7, 8, 9],
		runStrength: 1.35,
		rarity: 0.42,
	},
	{
		id: "chum",
		displayName: "Chum Salmon",
		habitat: "estuary",
		minDepth: 10,
		maxDepth: 180,
		capacity: 1300,
		growthRate: 0.12,
		baseValue: 60,
		anadromous: true,
		runMonths: [8, 9, 10, 11],
		runStrength: 0.8,
		rarity: 0.34,
	},
	{
		id: "halibut",
		displayName: "Pacific Halibut",
		habitat: "sand",
		minDepth: 200,
		maxDepth: 900,
		capacity: 420,
		growthRate: 0.045,
		baseValue: 460,
		anadromous: false,
		runMonths: null,
		runStrength: 0,
		rarity: 0.12,
	},
	{
		id: "sablefish",
		displayName: "Sablefish",
		habitat: "mud",
		minDepth: 300,
		maxDepth: 800,
		capacity: 380,
		growthRate: 0.04,
		baseValue: 340,
		anadromous: false,
		runMonths: null,
		runStrength: 0,
		rarity: 0.15,
	},
	{
		id: "cod",
		displayName: "Pacific Cod",
		habitat: "mud",
		minDepth: 90,
		maxDepth: 300,
		capacity: 950,
		growthRate: 0.07,
		baseValue: 130,
		anadromous: false,
		runMonths: null,
		runStrength: 0,
		rarity: 0.3,
	},
	{
		id: "pollock",
		displayName: "Alaska Pollock",
		habitat: "open",
		minDepth: 80,
		maxDepth: 300,
		capacity: 1800,
		growthRate: 0.14,
		baseValue: 55,
		anadromous: false,
		runMonths: null,
		runStrength: 0,
		rarity: 0.44,
	},
	{
		id: "lingcod",
		displayName: "Lingcod",
		habitat: "reef",
		minDepth: 90,
		maxDepth: 300,
		capacity: 620,
		growthRate: 0.06,
		baseValue: 175,
		anadromous: false,
		runMonths: null,
		runStrength: 0,
		rarity: 0.22,
	},
	{
		id: "rockfish",
		displayName: "Black Rockfish",
		habitat: "reef",
		minDepth: 25,
		maxDepth: 120,
		capacity: 1100,
		growthRate: 0.08,
		baseValue: 145,
		anadromous: false,
		runMonths: null,
		runStrength: 0,
		rarity: 0.32,
	},
	{
		id: "yelloweye",
		displayName: "Yelloweye Rockfish",
		habitat: "reef",
		minDepth: 40,
		maxDepth: 180,
		capacity: 300,
		growthRate: 0.035,
		baseValue: 395,
		anadromous: false,
		runMonths: null,
		runStrength: 0,
		rarity: 0.11,
	},
	{
		id: "herring",
		displayName: "Pacific Herring",
		habitat: "kelp",
		minDepth: 15,
		maxDepth: 110,
		capacity: 2600,
		growthRate: 0.18,
		baseValue: 30,
		anadromous: false,
		runMonths: [3, 4, 5],
		runStrength: 0.6,
		rarity: 0.52,
	},
	{
		id: "flounder",
		displayName: "Starry Flounder",
		habitat: "sand",
		minDepth: 15,
		maxDepth: 150,
		capacity: 1200,
		growthRate: 0.1,
		baseValue: 75,
		anadromous: false,
		runMonths: null,
		runStrength: 0,
		rarity: 0.38,
	},
	{
		id: "skate",
		displayName: "Big Skate",
		habitat: "sand",
		minDepth: 60,
		maxDepth: 400,
		capacity: 480,
		growthRate: 0.05,
		baseValue: 210,
		anadromous: false,
		runMonths: null,
		runStrength: 0,
		rarity: 0.19,
	},
	{
		id: "dungeness",
		displayName: "Dungeness Crab",
		habitat: "reef",
		minDepth: 15,
		maxDepth: 200,
		capacity: 760,
		growthRate: 0.07,
		baseValue: 190,
		anadromous: false,
		runMonths: null,
		runStrength: 0,
		rarity: 0.24,
	},
	{
		id: "kingcrab",
		displayName: "Red King Crab",
		habitat: "mud",
		minDepth: 200,
		maxDepth: 500,
		capacity: 260,
		growthRate: 0.03,
		baseValue: 580,
		anadromous: false,
		runMonths: null,
		runStrength: 0,
		rarity: 0.09,
	},
] as const;

const BY_ID: ReadonlyMap<string, Species> = new Map(
	SPECIES_LIST.map((s) => [s.id, s]),
);

export const SPECIES: readonly Species[] = SPECIES_LIST;

export function getSpecies(id: string): Species | null {
	return BY_ID.get(id) ?? null;
}

export function isRunning(species: Species, month: number): boolean {
	return species.runMonths?.includes(month) ?? false;
}

/** Species whose depth band contains `depth` (hard filter; affinity is separate). */
export function candidatesAtDepth(depth: number): Species[] {
	return SPECIES_LIST.filter((s) => depth >= s.minDepth && depth <= s.maxDepth);
}

export function speciesByHabitat(habitat: Habitat): Species[] {
	return SPECIES_LIST.filter((s) => s.habitat === habitat);
}

export const HABITATS: readonly Habitat[] = [
	"kelp",
	"reef",
	"sand",
	"mud",
	"open",
	"estuary",
] as const;
