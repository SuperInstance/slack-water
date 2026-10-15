--!strict
--[[
	Waves — the moving surface of the sea, as pure arithmetic.

	Same design lineage as the tide (see Tide.luau): the water is not a
	texture, it is a clock you can stand next to. This module is the chop ON
	TOP of the tide. The tide stays in Tide.luau and remains the dominant
	vertical signal; the renderer (Server/OceanSurface.luau) composes them:

		surfaceY = DATUM_Y
			+ Tide.heightAt(hour) * STUDS_PER_METRE   -- the game's clock
			+ baseOffset(seaState)                    -- wind setup, small
			+ heightAt(x, z, t, amp, dir)             -- this module

	SEA STATE

	There is no weather simulation to hang waves on — OceanSim tracks fish
	populations, not wind — so sea state is derived deterministically from
	the calendar day index. The same date always has the same sea, on every
	server, forever, which is the same bargain the rest of the simulation
	makes with randomness. A blow arrives and leaves with the day rollover:
	weather you can plan a trip around, which suits a game whose clock is
	the tide.

	UNITS

	Studs throughout, because this module exists to be drawn. The vertical
	scale for everything wet is STUDS_PER_METRE below — one constant, one
	place, so the tide, the wave heights and the ground depths can never
	disagree about how tall a metre is.

	HONESTY

	- Amplitudes and periods are gameplay-tuned, not physical. Real
	  deep-water dispersion makes a 170-stud swell march far too fast for
	  a renderer that refreshes a few times a second; the periods here are
	  deliberately slow and spread well above that refresh rate.
	- The sea-state bands are "Douglas-ish". They read right; they are not
	  a forecast model.
]]

local Rng = require("./Rng")
local Config = require("../Config")

local Waves = {}

-- How many studs a metre of tide, wave or charted depth occupies. Chosen so
-- a full tidal cycle swings the surface by roughly +/-8 studs — visibly a
-- different ocean at high and low water without swamping the boat scene.
Waves.STUDS_PER_METRE = 3.0

--=============================================================================
-- Wave components
--=============================================================================

-- A small fixed set of summed sinusoids ("Gerstner-lite" without the
-- horizontal displacement, which a part grid cannot show anyway). Varying
-- wavelength, amplitude and direction is what keeps the sum from reading as
-- one obvious ripple.
--
-- ampFrac MUST sum to 1.0: that bound is what lets callers trust
-- |heightAt| <= amp, and a test pins it.
--
-- Metre equivalents in comments use STUDS_PER_METRE (1 stud ~= 0.33 m).
local COMPONENTS: { { wavelength: number, ampFrac: number, dirX: number, dirZ: number, period: number, phase: number } } =
	{
		-- the long swell (~57 m, 0.7 m at sea state 3)
		{ wavelength = 170.0, ampFrac = 0.42, dirX = 1.0, dirZ = 0.20, period = 9.5, phase = 0.0 },
		-- cross-sea (~32 m)
		{ wavelength = 96.0, ampFrac = 0.26, dirX = 0.55, dirZ = -0.84, period = 6.8, phase = 1.9 },
		-- wind sea (~18 m)
		{ wavelength = 54.0, ampFrac = 0.18, dirX = 0.28, dirZ = 0.96, period = 5.1, phase = 4.2 },
		-- chop (~10 m)
		{
			wavelength = 31.0,
			ampFrac = 0.10,
			dirX = -0.62,
			dirZ = -0.78,
			period = 4.0,
			phase = 2.6,
		},
		-- ripple (~6 m) — mostly a colour dither; smaller than one surface tile
		{ wavelength = 19.0, ampFrac = 0.04, dirX = 0.90, dirZ = -0.44, period = 3.2, phase = 5.5 },
	}

local TWO_PI = 2.0 * math.pi

--- Surface displacement in studs at a world position and moment.
---
--- `amp` is the total one-sided amplitude in studs (wave HEIGHT is 2*amp);
--- `dir` is the wind direction in radians that all components are rotated
--- by, so one number steers the whole sea.
---
--- Pure and deterministic: the same five arguments always give the same
--- height, on every server, forever. No RNG, no clock, no Roblox globals.
function Waves.heightAt(x: number, z: number, t: number, amp: number, dir: number): number
	-- A NaN anywhere would poison a CFrame write downstream, so it is
	-- stopped here rather than debugged in the renderer.
	if x ~= x or z ~= z or t ~= t or amp ~= amp or dir ~= dir then
		return 0.0
	end
	if amp <= 0.0 then
		return 0.0
	end

	local cosDir = math.cos(dir)
	local sinDir = math.sin(dir)

	local h = 0.0
	for _, c in COMPONENTS do
		local dx = c.dirX * cosDir - c.dirZ * sinDir
		local dz = c.dirX * sinDir + c.dirZ * cosDir
		local k = TWO_PI / c.wavelength
		local w = TWO_PI / c.period
		h += (c.ampFrac * amp) * math.sin(k * (x * dx + z * dz) - w * t + c.phase)
	end
	return h
end

--=============================================================================
-- Sea state
--=============================================================================

-- Probability of each sea state, 0..6. Calm-to-slight dominates because
-- most days on a fishing ground are workable; the top bands are rare but
-- not once-a-year rare, so players get to see a real blow.
local SEA_STATE_WEIGHTS: { number } = { 0.14, 0.26, 0.24, 0.17, 0.10, 0.06, 0.03 }

local SEA_STATE_NAMES: { string } = {
	"calm",
	"smooth",
	"slight",
	"moderate",
	"rough",
	"very rough",
	"high",
}

-- One entry per sea state 0..6. Amplitudes are one-sided, in studs (the
-- metre column is the significant-ish wave height for orientation).
-- baseOffset is wind setup — water piled up against a blow — kept SMALL so
-- the tide stays the dominant vertical signal (full tide range is about
-- +/-7.5 studs; setup never exceeds ~2.1).
local CONDITIONS: { { amplitude: number, baseOffset: number, name: string } } = {
	{ amplitude = 0.15, baseOffset = 0.0, name = "calm (glassy)" }, -- ~0.1 m
	{ amplitude = 0.45, baseOffset = 0.15, name = "smooth" }, -- ~0.3 m
	{ amplitude = 0.90, baseOffset = 0.30, name = "slight" }, -- ~0.6 m
	{ amplitude = 1.50, baseOffset = 0.60, name = "moderate" }, -- ~1.0 m
	{ amplitude = 2.55, baseOffset = 1.05, name = "rough" }, -- ~1.7 m
	{ amplitude = 3.90, baseOffset = 1.50, name = "very rough" }, -- ~2.6 m
	{ amplitude = 6.00, baseOffset = 2.10, name = "high" }, -- ~4.0 m
}

--- Absolute day index of a (month, day) on the simulation calendar.
--- The sea is a function of this number and nothing else.
function Waves.dayIndex(month: number, day: number): number
	local m = math.clamp(math.floor(month), 1, Config.MONTHS_PER_YEAR)
	local d = math.clamp(math.floor(day), 1, Config.DAYS_PER_MONTH)
	return (m - 1) * Config.DAYS_PER_MONTH + d
end

--- Sea state 0..6 for an absolute day index. Deterministic: the Rng is
--- seeded by the day itself, drawn once, discarded — no shared state.
function Waves.seaState(dayIndex: number): number
	local rng = Rng.new(dayIndex + 7919)
	return Rng.pickWeighted(rng, { 0, 1, 2, 3, 4, 5, 6 }, SEA_STATE_WEIGHTS) or 2
end

--- Wind direction in radians for a day index. Deterministic for the same
--- reason as seaState.
function Waves.windDir(dayIndex: number): number
	local rng = Rng.new(dayIndex * 2654435761 + 17)
	return Rng.nextFloat(rng) * TWO_PI
end

--- Amplitude, wind setup and a display name for a sea state.
--- Out-of-range states are clamped onto the table.
function Waves.conditions(state: number): { amplitude: number, baseOffset: number, name: string }
	local i = math.clamp(math.floor(state), 0, #CONDITIONS - 1)
	return CONDITIONS[i + 1]
end

Waves.SEA_STATE_NAMES = SEA_STATE_NAMES
Waves.COMPONENTS = COMPONENTS

--=============================================================================
-- Chart depth to display depth
--=============================================================================

-- Display depth compression: MAX_DISPLAY_DEPTH is the deepest a ground can
-- sit below the datum; DISPLAY_COMPRESS_K is the linear half-saturation.
-- See depthToStuds.
Waves.MAX_DISPLAY_DEPTH = 46.0
Waves.DISPLAY_COMPRESS_K = 40.0

--- Chart depth in metres -> display depth in studs below the datum.
---
--- A 1:1 map would put a 500 m mud basin at -1500 studs, under the fog and
--- pointless. So the map is honest where it matters and compressed where
--- nobody can check: near the surface it is effectively linear (a 2 m shoal
--- sits within ~0.1 studs of its true 6-stud depth, which is what lets the
--- tide genuinely expose it), and it saturates smoothly toward
--- MAX_DISPLAY_DEPTH so every deep ground is still visible from the boat.
---
--- Monotonic for all depths >= 0 — a deeper chart always draws lower.
function Waves.depthToStuds(depthMetres: number): number
	if depthMetres <= 0.0 or depthMetres ~= depthMetres then
		return 0.0
	end
	local linear = depthMetres * Waves.STUDS_PER_METRE
	local maxD = Waves.MAX_DISPLAY_DEPTH
	local k = Waves.DISPLAY_COMPRESS_K
	return maxD * linear / (linear + k)
end

return Waves
