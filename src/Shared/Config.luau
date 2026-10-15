--!strict
--[[
	Config — global tuning for Slack Water.

	Every constant here is a design lever, not an implementation detail. If a
	number in this file is wrong, the whole economy is wrong: population
	pressure, price response, and the seasonal run cadence all key off these.
]]

local Config = {}

--=============================================================================
-- Calendar
--=============================================================================

-- Twelve months per in-game year, kept aligned to the real calendar on purpose.
-- Salmon run in spring and autumn in the actual North Pacific, and the whole
-- game leans on that: the run windows in Species.luau are real months, so the
-- sim's calendar has to speak the same language or the runs fire in the wrong
-- season.
Config.MONTHS_PER_YEAR = 12
Config.DAYS_PER_MONTH = 4 -- sim days per in-game month (compressed year)
Config.TICKS_PER_DAY = 12 -- sim ticks that make up one in-game day

--=============================================================================
-- Population dynamics
--=============================================================================

-- Carrying capacity multiplier applied on top of a species' base capacity when
-- a region is ideal for it (habitat affinity == 1.0).
Config.IDEAL_CAPACITY_BONUS = 1.35

-- Extra capacity granted while an anadromous species is in its run window.
Config.RUN_CAPACITY_BONUS = 0.85

-- A stock that drops below this fraction of capacity is considered "collapsed"
-- and begins a slow recovery penalty — you cannot just vacuum a ground empty.
Config.COLLAPSE_THRESHOLD = 0.25
Config.COLLAPSE_RECOVERY_PENALTY = 0.6

-- Minimum viable stock. Below this the population is functionally extirpated
-- from the region and must be recolonised by migration.
Config.EXTIRPATION_FLOOR = 0.02

--=============================================================================
-- Market
--=============================================================================

-- Price multiplier at zero abundance would be unbounded; this caps it so a
-- collapsed species becomes valuable but not an instant money printer.
Config.MAX_SCARCITY_MULTIPLIER = 6.0

-- The denominator floor of the scarcity curve. Lowering it makes scarcity bite
-- harder as a stock approaches zero; raising it makes the premium gentler. At
-- 0.15 the curve's asymptote (1 / 0.15 = 6.67) sits just above
-- MAX_SCARCITY_MULTIPLIER, so the cap is actually reachable — otherwise the
-- cap is dead configuration that can never bind.
Config.SCARCITY_FLOOR = 0.15

-- Price inertia: how much of the previous day's price carries forward.
-- High inertia stops the market ping-ponging on small catches.
Config.PRICE_INERTIA = 0.82

-- Minimum relative price change per day, so small catch volume still nudges
-- the market rather than leaving it perfectly flat.
Config.PRICE_FLOOR_MOVE = 0.015

--=============================================================================
-- Harvesting
--=============================================================================

-- Catch is only credited up to this fraction of a region's *carrying capacity*
-- in one event, not of its current stock. This distinction matters: capping
-- against current stock makes yield fall off quadratically once a ground is
-- depleted, which quietly caps how far a stock can ever be driven and means
-- "collapse" is unreachable. Capping against capacity lets sustained pressure
-- actually deplete a ground, which is the whole point of the economy.
Config.MAX_HARVEST_FRACTION = 0.12

-- A depleted ground still yields *something* — this floor is what stops a
-- player from sitting on an empty ground forever, without making a picked-out
-- ground worthless.
Config.MIN_YIELD_FACTOR = 0.25

-- A ground that has already lost this much of its capacity to fishing within a
-- single tick reads as contested to anyone who tries it. This is the game's
-- social-pressure signal: it is how one crew learns another was just here.
Config.CONTEST_THRESHOLD = 0.05

--=============================================================================
-- Tide
--
-- The tide is the clock: it gates which grounds are reachable, how well they
-- fish, and gives the day a shape. See src/Shared/Tide.luau — including the
-- note there about the harmonic constants being ESTIMATED rather than measured.
--=============================================================================

-- Metres of water a working boat needs over a ground before it can fish it.
-- At low water a 2 m shoal is dry rock; at high water it is fishable.
Config.TIDE_MIN_DRAUGHT = 1.8

-- How much extra depth beyond the minimum counts as "comfortably fished".
-- Beyond this the bonus saturates — being over a shoal in ten fathoms of water
-- is not better fishing, it is just deep water.
Config.TIDE_DEPTH_MARGIN = 2.5

-- Tide-curve slope treated as "full current" for normalisation purposes. This
-- is a divisor, so it calibrates the current scale against the estimated
-- harmonic amplitudes. If those amplitudes are replaced with real ones, this
-- must be recalibrated against them.
Config.TIDE_CURRENT_SLOPE_REF = 0.45

-- Current strength at or below which the water counts as slack. The game is
-- named for this interval.
Config.TIDE_SLACK_THRESHOLD = 0.25

-- Game hours between in-game days. The tide runs in real time inside a day;
-- this only controls how fast days pass relative to real seconds.
Config.HOURS_PER_DAY = 24

--=============================================================================
-- Regions
--=============================================================================

Config.INITIAL_REGIONS = 14
Config.BANKS_PER_ROUND = 2

return Config