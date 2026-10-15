--!strict
--[[
	Tide — the clock the whole game runs on.

	Borrowed directly from the engine principle in SuperInstance/shoalwater:

		"The tide is the clock... A cove that is a harbor at high water is a
		 mudflat with a winding channel at low water, and a boat can only
		 leave when the tide says so. No invented puzzles: seamanship is
		 the game mechanic."

	That principle is better than anything else in the design and it solves a
	problem this game had. Fishing on demand has no rhythm — a player fishes
	whenever they log in, the ocean is a static resource, and there is no reason
	to be anywhere at a particular time. The tide supplies all three: it gates
	*where* you can fish, it changes *how well*, and it gives the day a shape.

	It is also the game's name. Slack water is the still interval between tides,
	and this module is what produces it.

	IMPLEMENTATION

	The tide is summed from real harmonic constituents rather than shaped with a
	sine wave. That matters: a single sine gives a clock, but the real sum of
	M2, S2, N2, K1 and O1 gives Southeast Alaska's characteristic *mixed
	semidiurnal* pattern, with unequal successive heights ("diurnal inequality")
	and slack water that arrives at genuinely different times each day. Players
	notice that without ever being told.

	ACCURACY — READ THIS

	The amplitudes below are ESTIMATED, not measured. They are plausible for
	an exposed Alaskan sound and they produce the right *shape*, but they are
	not Sitka's tide. The authoritative source is NOAA station 9451600 (Sitka).
	Careful: the widely-copied NOAA pack "9452210 Sitka" is actually Juneau —
	that error is documented in SuperInstance/shoalwater and is exactly why this
	project verifies rather than copies.

	Someone with the real harmonic constants should replace the table in
	CONSTITUENTS and nothing else needs to change. Until then these numbers are
	a design tool, and Config.luau's TIDE_* levers are where the game is tuned.
]]

local Config = require("./Config")

export type Constituent = {
	name: string,
	amplitude: number, -- metres
	periodHours: number,
}

--- Harmonic constituents for a mixed semidiurnal tide.
--- See the accuracy note above before trusting these numbers.
local CONSTITUENTS: { Constituent } = {
	-- principal lunar semidiurnal — the dominant constituent almost everywhere
	{ name = "M2", amplitude = 1.34, periodHours = 12.4206 },
	-- principal solar semidiurnal — the one that beats against M2 to give the
	-- fortnightly spring/neap cycle
	{ name = "S2", amplitude = 0.38, periodHours = 12.0000 },
	-- larger lunar elliptic — another semidiurnal, slightly out of step
	{ name = "N2", amplitude = 0.29, periodHours = 12.6583 },
	-- lunisolar diurnal
	{ name = "K1", amplitude = 0.34, periodHours = 23.9345 },
	-- principal lunar diurnal
	{ name = "O1", amplitude = 0.22, periodHours = 25.8193 },
}

--- Chart datum offsets, in metres above MLLW (mean lower low water).
--- The seafloor is baked at MLLW, so every depth on this chart is read from
--- that same zero.
local DATUM = {
	MLLW = 0.0,
	MLL = 0.55,
	MSL = 1.02,
	MHW = 1.62,
	-- mean higher high water: above this, a normally-dry shoal is under water
	MHHW = 2.05,
}

local Tide = {}

Tide.CONSTITUENTS = CONSTITUENTS
Tide.DATUM = DATUM

--=============================================================================
-- Height
--=============================================================================

--- Tide height in metres above MLLW at an absolute hour.
---
--- Summing the constituents rather than using one period is what produces
--- diurnal inequality and an irregular slack-water schedule. Players learn
--- "slack is around four, but sometimes five" without being taught anything.
function Tide.heightAt(hour: number): number
	local height = 0.0
	for _, c in CONSTITUENTS do
		local angle = 2.0 * math.pi * (hour / c.periodHours)
		height += c.amplitude * math.cos(angle)
	end
	return height
end

--- Local extrema of the tide around a given hour, by bisection over the
--- derivative. Returns { high, highTime, low, lowTime } — the next high water
--- and the next low water — which is what a skipper actually plans around.
function Tide.nextEvents(
	hour: number
): { high: number, highTime: number, low: number, lowTime: number }
	-- derivative sign tells us which way the curve is moving
	local function rising(at: number): boolean
		return Tide.heightAt(at + 0.02) > Tide.heightAt(at - 0.02)
	end

	local function bisectHeight(lo: number, hi: number, wantHigh: boolean): number
		for _ = 1, 40 do
			local mid = (lo + hi) / 2
			if rising(mid) == wantHigh then
				lo = mid
			else
				hi = mid
			end
		end
		return (lo + hi) / 2
	end

	--- Walk forward until the slope flips, then refine. The flip must occur
	--- STRICTLY AFTER `from`: sampling at `from` itself and bisecting backwards
	--- would happily return an extremum in the past, which would tell a skipper
	--- they had already missed the slack water they were standing in.
	local function findNextExtremum(from: number, wantHigh: boolean): (number, number)
		local step = 0.25
		local prev = from
		local t = from + step

		for _ = 1, 1600 do
			local wasRising = rising(prev)
			local isRising = rising(t)

			if wantHigh and wasRising and not isRising then
				local at = bisectHeight(prev, t, true)
				return Tide.heightAt(at), at
			end
			if (not wantHigh) and not wasRising and isRising then
				local at = bisectHeight(prev, t, false)
				return Tide.heightAt(at), at
			end

			prev = t
			t += step
		end

		return 0.0, from
	end

	local high, highTime = findNextExtremum(hour, true)
	local low, lowTime = findNextExtremum(hour, false)

	return { high = high, highTime = highTime, low = low, lowTime = lowTime }
end

--=============================================================================
-- Current
--=============================================================================

--- Tidal current strength, normalised to roughly [0, 1].
---
--- Current is strongest at mid-tide and slack at the extremes — that is real,
--- and it is what makes the game's name mean something. Slack water is the
--- window where a small boat can safely work shallow water.
function Tide.currentAt(hour: number): number
	-- current is proportional to the slope of the tide curve
	local slope = (Tide.heightAt(hour + 0.05) - Tide.heightAt(hour - 0.05)) / 0.1
	return math.clamp(math.abs(slope) / Config.TIDE_CURRENT_SLOPE_REF, 0.0, 1.0)
end

--- Are we in slack water — the still interval this game is named for?
function Tide.isSlack(hour: number): boolean
	return Tide.currentAt(hour) <= Config.TIDE_SLACK_THRESHOLD
end

--- Hours until the next slack window opens. Used to schedule a return trip.
function Tide.hoursToSlack(hour: number): number
	local step = 0.1
	local t = hour
	for _ = 1, 2000 do
		if Tide.isSlack(t) then
			return t - hour
		end
		t += step
	end
	return 0.0
end

--=============================================================================
-- Access
--=============================================================================

--- Can a vessel work a ground at all right now?
---
--- This is the whole point. A shoal charted at 2.0 m is dry rock at low water
--- and fishable at high water. Chart depth plus current tide height is the
--- water actually over the ground, and if that is not enough to float a boat
--- you simply cannot go there.
---
--- Returns (accessible, waterDepth) so callers can render why.
function Tide.accessAt(chartedDepth: number, hour: number): (boolean, number)
	local water = chartedDepth + Tide.heightAt(hour)
	local needed = Config.TIDE_MIN_DRAUGHT
	return water >= needed, water
end

--- How good the fishing is right now at a ground, as a 0..1 multiplier.
---
--- Two forces combine: there must be water over the ground, and slack water
--- helps. Peak conditions are a ground with adequate depth near slack — which
--- is the entire skill of the game.
function Tide.fishingQuality(chartedDepth: number, hour: number): number
	local accessible, water = Tide.accessAt(chartedDepth, hour)
	if not accessible then
		return 0.0
	end

	local current = Tide.currentAt(hour)
	-- dead slack is best; heavy current makes everything harder
	local condition = 1.0 - current

	-- being slightly deeper than the minimum is better than scraping it
	local margin =
		math.clamp((water - Config.TIDE_MIN_DRAUGHT) / Config.TIDE_DEPTH_MARGIN, 0.0, 1.0)

	return math.clamp(condition * (0.55 + 0.45 * margin), 0.0, 1.0)
end

--- A human-readable state for the HUD. Players do not need numbers, they need
--- to know whether to go now or wait.
function Tide.phaseName(hour: number): string
	local height = Tide.heightAt(hour)
	local events = Tide.nextEvents(hour)

	if height >= events.high - 0.12 then
		return "high slack"
	elseif height <= events.low + 0.12 then
		return "low slack"
	elseif Tide.currentAt(hour) > 0.6 then
		return if height > DATUM.MSL then "flooding" else "ebbing"
	end

	return "making"
end

Tide._DATUM = DATUM

return Tide
