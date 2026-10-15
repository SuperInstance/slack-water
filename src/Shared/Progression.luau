--!strict
--[[
	Progression — the skipper's career.

	Effort is the only client-influenced input to the simulation: CastService
	clamps a claimed effort to what the player's gear actually provides, and
	OceanSim converts that effort into yield against the ground's current
	abundance. Gear matters — but a better rod does not multiply abundance. It
	takes a bigger bite before a ground is picked over.

	That is the whole progression problem: a career built out of taking bites
	from a *shared* ocean must not reward the players who take the biggest,
	dumbest ones. Three shaping rules, and nothing else:

	1. XP is keyed to the ground's abundance BEFORE the cast, not to the
	   catch's value. The market pays more for scarce fish — that is its job.
	   If xp tracked value, progression would reward strip-mining grounds,
	   which is the exact opposite of the game's thesis. Combined with the
	   yield curve's own abundance factor, a picked-over ground pays roughly
	   an order of magnitude less xp per cast than a fresh one.

	2. Finesse. XP per unit of biomass landed falls as effort rises. A
	   trawler still out-levels a handline per cast — big gear is fast — but
	   a handline earns more xp per fish killed. When a ground is stressed,
	   restraint is the efficient way to level. That is what the handline is
	   still for at endgame, and why switching back to light tackle is a
	   first-class verb rather than an apology.

	3. Skill and slack water pay a little. Harder species
	   (harvestDifficulty) and casting at slack water (the game's clock) add
	   small multipliers, so moment-to-moment play has a slope on it.

	Determinism: no randomness anywhere, no wall clock, and every iteration
	whose result escapes this module is reduced under a total order, so hash
	iteration order can never leak into output. Level is *derived* from total
	xp and never stored, so a profile cannot contradict itself. Persisted
	data is untrusted and repaired on restore, never believed.
]]

local Types = require("./Types")
local Species = require("./Species")

export type Gear = typeof(Types.Gear.handline)

export type Profile = {
	-- total xp ever earned; the ONLY source of level
	xp: number,
	-- which owned gear is being worked right now
	currentGearId: string,
	-- gearId -> owned. Buying checks the level gate, and level never
	-- decreases, so owned gear is always legal to work.
	ownedGear: { [string]: boolean },
}

--- What the server hands to `recordCatch` after OceanSim has arbitraged the
--- cast. Every field is server-derived; the client never contributes.
export type CatchRecord = {
	speciesId: string,
	-- biomass actually landed (HarvestResult.yielded)
	yielded: number,
	-- effort the server actually applied — the clamped value, not the claim
	effortUsed: number,
	-- the ground's abundance fraction before the cast
	abundanceBefore: number,
	-- 0..1, how good the tide window was (CastResult.tideQuality); optional
	tideQuality: number?,
}

export type CatchOutcome = {
	xpGained: number,
	level: number,
	levelsGained: number,
	-- gear newly reachable at the new level, sorted by unlock level.
	-- Reachable is NOT granted: ownership is still bought.
	unlockedGear: { Gear },
}

export type LevelProgress = {
	level: number,
	intoLevel: number,
	needed: number,
	fraction: number,
}

local Progression = {}

--=============================================================================
-- Tuning
--
-- By house convention these belong in Config.luau; that file is owned by
-- another change, so they live here — exported, commented, and never to be
-- inlined at a call site. Same discipline, different shelf.
--=============================================================================

-- xp per unit of biomass landed, before any shaping
Progression.XP_PER_YIELD = 3.0

-- floor of the abundance weight: xp at zero abundance relative to a fresh
-- ground. 0.15 makes the xp curve fall considerably faster than the yield
-- curve does, so a hammered ground is a poor place to *learn*, not merely a
-- poor place to earn.
Progression.XP_ABUNDANCE_FLOOR = 0.15

-- species skill weight = base + scale * harvestDifficulty
-- (herring 0.76 ... halibut and king crab 1.40)
Progression.XP_DIFFICULTY_BASE = 0.6
Progression.XP_DIFFICULTY_SCALE = 0.16

-- extra xp fraction at perfect slack water (tideQuality == 1). Small on
-- purpose: the tide already shapes the catch; this just keeps the clock
-- visible in the career.
Progression.XP_TIDE_BONUS = 0.25

-- how fast xp efficiency per biomass falls as effort rises. 0 disables the
-- finesse mechanic (effort is pure power); 1 flattens it entirely (every
-- gear equally xp-efficient per cast, upgrades stop mattering).
Progression.FINESSE_EXPONENT = 0.35

-- xp to advance from level L to L+1 is BASE * L ^ EXPONENT
Progression.XP_LEVEL_BASE = 60.0
Progression.XP_LEVEL_EXPONENT = 1.6

-- no gear unlocks past level 14 today; the headroom above it is for future
-- tiers. Past MAX_LEVEL xp still accrues but the level pins.
Progression.MAX_LEVEL = 20

--=============================================================================
-- Starter gear
--=============================================================================

-- The starting gear is derived, not hardcoded: whichever row sits at the
-- lowest unlock level, ties broken by effort. Types.Gear iterates in no
-- guaranteed order, but a minimum under a total order is order-independent,
-- so this stays byte-identical across interpreters.
local function betterStarter(candidate: Gear, incumbent: Gear?): Gear
	if incumbent == nil then
		return candidate
	end
	if candidate.unlockLevel ~= incumbent.unlockLevel then
		return if candidate.unlockLevel < incumbent.unlockLevel then candidate else incumbent
	end
	return if candidate.effort < incumbent.effort then candidate else incumbent
end

local starter: Gear? = nil
for _, gear in Types.Gear do
	starter = betterStarter(gear, starter)
end
if starter == nil then
	error("Progression: Types.Gear is empty — the game has no starting gear", 0)
end

local STARTER: Gear = starter :: Gear
Progression.STARTER_GEAR = STARTER

-- the effort at which finesse is exactly 1: the lightest touch in the game
local FINESSE_REFERENCE = math.max(STARTER.effort, 1.0)

--=============================================================================
-- Levels
--=============================================================================

--- Total xp required to advance from `level` to `level + 1`.
function Progression.xpToNext(level: number): number
	local l = math.max(math.floor(level), 1)
	return Progression.XP_LEVEL_BASE * l ^ Progression.XP_LEVEL_EXPONENT
end

-- cumulative thresholds: TOTAL_XP[L] is the total xp needed to REACH level L
local TOTAL_XP: { number } = { 0.0 }
for level = 1, Progression.MAX_LEVEL do
	TOTAL_XP[level + 1] = TOTAL_XP[level] + Progression.xpToNext(level)
end

--- Total xp needed to have reached `level`. Level 1 costs nothing.
function Progression.totalXpForLevel(level: number): number
	local l = math.clamp(math.floor(level), 1, Progression.MAX_LEVEL)
	return TOTAL_XP[l]
end

--- The level a profile's total xp has earned. Derived, never stored.
function Progression.levelOf(profile: Profile): number
	local level = 1
	while level < Progression.MAX_LEVEL and profile.xp >= TOTAL_XP[level + 1] do
		level += 1
	end
	return level
end

--- Level and progress-bar data for the UI.
function Progression.levelProgress(profile: Profile): LevelProgress
	local level = Progression.levelOf(profile)
	local intoLevel = profile.xp - TOTAL_XP[level]
	local needed = TOTAL_XP[level + 1] - TOTAL_XP[level]
	local fraction = if needed > 0.0 then math.clamp(intoLevel / needed, 0.0, 1.0) else 0.0
	return {
		level = level,
		intoLevel = intoLevel,
		needed = needed,
		fraction = fraction,
	}
end

--=============================================================================
-- Earning xp
--=============================================================================

--- The xp a single catch is worth.
---
---	xp = XP_PER_YIELD * yielded * skill * abundance * finesse * tide
---
--- `yielded` already carries OceanSim's own abundance factor, so the
--- abundance term here is a second, steeper application — that is the
--- anti-strip-mining shaping. Finesse divides xp per biomass as effort
--- rises; see the module header for why the handline must stay the
--- efficient tool per fish killed.
function Progression.xpForCatch(rec: CatchRecord): number
	if rec.yielded <= 0.0 then
		return 0.0
	end

	local species = Species.get(rec.speciesId)
	-- an unknown species still pays out at mid skill rather than crashing
	local difficulty = if species then species.harvestDifficulty else 3
	local skill = Progression.XP_DIFFICULTY_BASE + Progression.XP_DIFFICULTY_SCALE * difficulty

	local a = math.clamp(rec.abundanceBefore, 0.0, 1.0)
	local abundance = Progression.XP_ABUNDANCE_FLOOR + (1.0 - Progression.XP_ABUNDANCE_FLOOR) * a

	-- effort at or below the reference earns no bonus above 1; effort above
	-- it earns progressively less per unit of biomass taken
	local effort = math.max(rec.effortUsed, 0.0)
	local finesse = (FINESSE_REFERENCE / math.max(effort, FINESSE_REFERENCE))
		^ Progression.FINESSE_EXPONENT

	local tide = if rec.tideQuality ~= nil then math.clamp(rec.tideQuality, 0.0, 1.0) else 0.0
	local tideWeight = 1.0 + Progression.XP_TIDE_BONUS * tide

	return Progression.XP_PER_YIELD * rec.yielded * skill * abundance * finesse * tideWeight
end

--- Credit a catch to a profile and resolve any level-ups.
---
--- Level-ups report newly reachable gear but never grant it: ownership is
--- bought, and the level gate is checked at purchase time.
function Progression.recordCatch(profile: Profile, rec: CatchRecord): CatchOutcome
	local before = Progression.levelOf(profile)
	local gained = Progression.xpForCatch(rec)
	profile.xp += gained
	local now = Progression.levelOf(profile)
	return {
		xpGained = gained,
		level = now,
		levelsGained = now - before,
		unlockedGear = Progression.newlyUnlocked(before, now),
	}
end

--=============================================================================
-- Gear
--=============================================================================

--- Does the skipper own this gear?
function Progression.owns(profile: Profile, gearId: string): boolean
	return profile.ownedGear[gearId] == true
end

--- Is this gear reachable at the profile's current level?
--- Reachable is not owned — see `buy`.
function Progression.isUnlocked(profile: Profile, gearId: string): boolean
	local gear = Types.Gear[gearId]
	if gear == nil then
		return false
	end
	return Progression.levelOf(profile) >= gear.unlockLevel
end

local function gearOrder(a: Gear, b: Gear): boolean
	if a.unlockLevel ~= b.unlockLevel then
		return a.unlockLevel < b.unlockLevel
	end
	return a.id < b.id
end

--- Every gear reachable at the profile's level, sorted by unlock level.
--- Types.Gear iterates unordered; the sort is what makes this deterministic.
function Progression.availableGear(profile: Profile): { Gear }
	local level = Progression.levelOf(profile)
	local out: { Gear } = {}
	for _, gear in Types.Gear do
		if gear.unlockLevel <= level then
			table.insert(out, gear)
		end
	end
	table.sort(out, gearOrder)
	return out
end

--- Gear that became reachable by advancing from one level to another.
function Progression.newlyUnlocked(fromLevel: number, toLevel: number): { Gear }
	local out: { Gear } = {}
	if toLevel <= fromLevel then
		return out
	end
	for _, gear in Types.Gear do
		if gear.unlockLevel > fromLevel and gear.unlockLevel <= toLevel then
			table.insert(out, gear)
		end
	end
	table.sort(out, gearOrder)
	return out
end

--- Buy gear: validates level and funds, then grants ownership.
---
--- Does NOT equip, and does NOT touch any wallet — the caller deducts
--- `gear.price` from its own funds store only when this returns true, so
--- money has exactly one owner.
function Progression.buy(profile: Profile, gearId: string, funds: number): (boolean, string?)
	local gear = Types.Gear[gearId]
	if gear == nil then
		return false, "unknown gear"
	end
	if profile.ownedGear[gearId] then
		return false, "already owned"
	end
	if Progression.levelOf(profile) < gear.unlockLevel then
		return false, "locked"
	end
	if funds < gear.price then
		return false, "not enough funds"
	end
	profile.ownedGear[gearId] = true
	return true, nil
end

--- Work a different owned gear. Switching back to light tackle is the
--- stewardship verb, so it must always be available: the starter is owned
--- from birth and re-equippable for free, forever.
function Progression.equip(profile: Profile, gearId: string): (boolean, string?)
	if not Progression.owns(profile, gearId) then
		return false, "not owned"
	end
	profile.currentGearId = gearId
	return true, nil
end

--- The equipped gear row, defensively: a corrupt id falls back to the starter.
function Progression.equippedGear(profile: Profile): Gear
	local gear = Types.Gear[profile.currentGearId]
	if gear == nil then
		return Progression.STARTER_GEAR
	end
	return gear
end

--- The effort CastService should clamp a cast claim to for this profile.
function Progression.effortFor(profile: Profile): number
	return Progression.equippedGear(profile).effort
end

--=============================================================================
-- Persistence
--=============================================================================

--- Plain-data snapshot for saving. `ownedGear` serialises as a sorted id
--- array so the same profile always produces the same bytes.
function Progression.snapshot(profile: Profile): { [string]: any }
	local owned: { string } = {}
	for id, isOwned in profile.ownedGear do
		if isOwned then
			table.insert(owned, id)
		end
	end
	table.sort(owned)
	return {
		xp = profile.xp,
		currentGearId = profile.currentGearId,
		ownedGear = owned,
	}
end

--- Rebuild a profile from persisted data. Nothing is trusted:
---   - junk of any shape degrades to a fresh starter profile
---   - xp must be a sane non-negative finite number
---   - gear above the xp-earned level is dropped, so a tampered save cannot
---     smuggle a trawler onto a level-2 skipper
---   - level is never read back; it is always derived from xp
function Progression.restore(data: any): Profile
	if type(data) ~= "table" then
		return Progression.new()
	end

	local xp = tonumber(data.xp)
	if xp == nil or xp ~= xp or xp < 0.0 then
		xp = 0.0
	end

	local level = Progression.levelOf({ xp = xp, currentGearId = "", ownedGear = {} })

	local owned: { [string]: boolean } = {}
	local list = data.ownedGear
	if type(list) == "table" then
		for _, id in list do
			if type(id) == "string" then
				local gear = Types.Gear[id]
				if gear ~= nil and gear.unlockLevel <= level then
					owned[id] = true
				end
			end
		end
	end
	owned[STARTER.id] = true

	local currentGearId = STARTER.id
	if type(data.currentGearId) == "string" and owned[data.currentGearId] then
		currentGearId = data.currentGearId
	end

	return {
		xp = xp,
		currentGearId = currentGearId,
		ownedGear = owned,
	}
end

--- A brand-new skipper: no xp, working the starter gear.
function Progression.new(): Profile
	return {
		xp = 0.0,
		currentGearId = STARTER.id,
		ownedGear = { [STARTER.id] = true },
	}
end

return Progression
