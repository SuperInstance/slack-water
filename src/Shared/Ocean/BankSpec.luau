--!strict
--[[
	BankSpec — the boundary between the model and the simulation.

	This file encodes the project's central thesis:

		THE AI PROPOSES. THE SIMULATION ARBITRATES.

	A language model running in a Cloudflare Worker is allowed to invent new
	fishing banks — their habitat, depth, which species hold there, what the
	place is called. That is genuinely useful content generation, and it is why
	the game never runs out of new water to discover.

	But none of it is trusted. Everything the model returns arrives here as
	untyped, unvalidated JSON, and it is *repaired* against the deterministic
	simulation's own rules before it is allowed to exist in the world. The model
	authors surface; `OceanSim` decides truth.

	Two properties make this safe to put in front of players:

	1. Repair, not reject. A bank that is 95% sensible gets clamped into range
	   rather than thrown away. Only a bank with nothing salvageable is
	   discarded, and the caller then falls back to procedural generation. This
	   keeps the AI's output usable without ever letting it be authoritative.

	2. Total determinism given input. Validation contains no randomness, so the
	   same model output always produces the same bank. The simulation stays
	   reproducible even though its content came from a language model.

	The alternative — trusting the model — is how you ship a game where a
	surplus halibut appears at 5 metres because the model thought that was
	poetic.
]]

local scriptParent = script and script.Parent
local Config = require(scriptParent and scriptParent.Parent.Config or "../Config")
local Species = require(scriptParent and scriptParent.Parent.Species or "../Species")

type Habitat = "kelp" | "reef" | "sand" | "mud" | "open" | "estuary"

export type SpeciesMixEntry = {
	speciesId: string,
	weight: number,
}

export type BankSpec = {
	id: string,
	name: string,
	habitat: Habitat,
	depth: number,
	richness: number,
	salinity: number,
	speciesMix: { SpeciesMixEntry },
	hazard: string?,
	origin: "composed" | "procedural",
}

export type ValidationReport = {
	ok: boolean,
	bank: BankSpec?,
	repairs: { string },
	rejections: { string },
}

local BankSpec = {}

--=============================================================================
-- Whitelists
--=============================================================================

local VALID_HAZARDS: { [string]: boolean } = {
	none = true,
	rip_current = true,
	rocky_bottom = true,
	deep_water = true,
	kelp_tangle = true,
	seabird_activity = true,
	debris_field = true,
	cold_drain = true,
}

local VALID_HABITATS: { [string]: boolean } = {
	kelp = true,
	reef = true,
	sand = true,
	mud = true,
	open = true,
	estuary = true,
}

-- Names arrive from a language model, which will occasionally produce
-- something obscene, enormous, or empty. This is a blunt first line of
-- defence, not a substitute for Roblox's own moderation — but a bank name is
-- rendered in the UI and should never be the thing that trips a filter.
local BLOCKED_NAME_TOKENS = {
	"fuck",
	"shit",
	"cunt",
	"nigg",
	"faggot",
	"rape",
	"nazi",
	"kill yourself",
	"suicide",
}

--=============================================================================
-- Helpers
--=============================================================================

local function clampNumber(value: any, min: number, max: number, fallback: number): number
	if type(value) ~= "number" then
		return fallback
	end
	if value ~= value then -- NaN
		return fallback
	end
	if value == math.huge or value == -math.huge then
		return fallback
	end
	return math.clamp(value, min, max)
end

local function sanitizeName(raw: any, fallback: string): (string, boolean)
	if type(raw) ~= "string" then
		return fallback, false
	end

	-- collapse whitespace, strip control characters
	local cleaned = raw:gsub("[%c]", " "):gsub("%s+", " "):match("^ *(.-) *$") or ""

	if #cleaned < 3 or #cleaned > 42 then
		return fallback, #cleaned >= 3 and #cleaned <= 42
	end

	local lowered = string.lower(cleaned)
	for _, token in BLOCKED_NAME_TOKENS do
		if string.find(lowered, token, 1, true) then
			return fallback, false
		end
	end

	-- letters, digits, spaces, hyphens, apostrophes and periods only
	if string.find(cleaned, "^[%w %-%'%.,]+$") == nil then
		return fallback, false
	end

	return cleaned, true
end

--=============================================================================
-- Validation
--=============================================================================

--- Validate and repair a model-authored bank.
---
--- Returns a report rather than a bare bank: callers want to know what was
--- repaired, because that telemetry is how we tune the prompt. A high repair
--- rate means the model is drifting and the prompt needs work.
function BankSpec.validate(raw: any, fallbackId: string): ValidationReport
	local report: ValidationReport = {
		ok = false,
		bank = nil,
		repairs = {},
		rejections = {},
	}

	if type(raw) ~= "table" then
		table.insert(report.rejections, "payload was not an object")
		return report
	end

	-- Habitat: must be a known value. An unknown one is a rejection rather than
	-- a repair, because guessing which of six habitats was meant would be
	-- guessing at the game's core structure.
	local habitat = raw.habitat
	if type(habitat) ~= "string" or not VALID_HABITATS[habitat] then
		table.insert(report.rejections, "unknown or missing habitat")
		return report
	end

	-- Depth is clamped rather than rejected: a model asking for 1200m meant
	-- "very deep", and 900m is a perfectly good fishing bank.
	local depth = clampNumber(raw.depth, 5, 900, 60)
	if depth ~= raw.depth then
		table.insert(report.repairs, "depth clamped into 5..900")
	end

	local richness = clampNumber(raw.richness, 0.5, 1.5, 1.0)
	if richness ~= raw.richness then
		table.insert(report.repairs, "richness clamped into 0.5..1.5")
	end

	local salinity = clampNumber(raw.salinity, 18, 36, 32)
	if salinity ~= raw.salinity then
		table.insert(report.repairs, "salinity clamped into 18..36")
	end

	-- Species mix: unknown species are dropped, not fatal. The mix is a
	-- suggestion about what lives here; the simulation will simply find that
	-- half of it cannot survive at this depth and adjust capacity.
	local mix: { SpeciesMixEntry } = {}
	local rawMix = raw.speciesMix
	if type(rawMix) == "table" then
		local dropped = 0
		for _, entry in rawMix do
			if type(entry) == "table" and type(entry.speciesId) == "string" then
				local species = Species.get(entry.speciesId)
				if species then
					local weight = clampNumber(entry.weight, 0.0, 10.0, 1.0)
					if weight > 0.0 then
						table.insert(mix, { speciesId = species.id, weight = weight })
					end
				else
					dropped += 1
				end
			end
		end
		if dropped > 0 then
			table.insert(report.repairs, "dropped " .. dropped .. " unknown species")
		end
	end

	if #mix == 0 then
		table.insert(report.rejections, "no valid species in mix")
		return report
	end

	-- Normalise so downstream code can assume weights sum to 1.
	local totalWeight = 0.0
	for _, entry in mix do
		totalWeight += entry.weight
	end
	if totalWeight > 0.0 then
		for _, entry in mix do
			entry.weight = entry.weight / totalWeight
		end
	end

	local name, nameOk = sanitizeName(raw.name, "Unnamed Ground")
	if not nameOk then
		table.insert(report.repairs, "bank name rejected, using fallback")
	end

	local hazard: string? = nil
	if type(raw.hazard) == "string" and VALID_HAZARDS[raw.hazard] then
		hazard = raw.hazard
	end

	report.bank = {
		id = fallbackId,
		name = name,
		habitat = habitat,
		depth = depth,
		richness = richness,
		salinity = salinity,
		speciesMix = mix,
		hazard = hazard,
		origin = "composed",
	}
	report.ok = true
	return report
end

--- Convert a validated bank into the region shape `OceanSim.addRegion` takes.
--- The species mix is *not* applied as a hard override — it becomes a richness
--- nudge. The simulation still decides what actually lives there, which is the
--- entire point of the arbitration rule.
function BankSpec.toRegion(bank: BankSpec): any
	local weightedRichness = 0.0
	for _, entry in bank.speciesMix do
		local species = Species.get(entry.speciesId)
		if species then
			-- rarer species imply a richer, more specialised ground
			weightedRichness += (1.0 / math.max(species.rarity, 0.01)) * entry.weight
		end
	end

	-- compress the (wildly skewed) rarity signal into the playable band
	local richness = math.clamp(0.6 + (weightedRichness / 40.0), 0.5, 1.5)

	return {
		id = bank.id,
		name = bank.name,
		habitat = bank.habitat,
		depth = bank.depth,
		salinity = bank.salinity,
		richness = richness,
		origin = bank.origin,
	}
end

--- Ceiling on banks per settlement round, enforced by the caller.
BankSpec.MAX_BANKS = Config.MAX_BANKS

return BankSpec