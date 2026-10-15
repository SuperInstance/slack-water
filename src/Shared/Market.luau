--!strict
--[[
	Market — prices that respond to what people actually catch.

	This module is the feedback loop that makes the whole game cohere:

		players fish a ground
		    -> that ground's stock falls
		        -> global abundance for the species falls
		            -> scarcity multiplier climbs
		                -> price climbs
		                    -> the species becomes worth going somewhere else for

	Nothing here is a developer-written price table reacting to a script. The
	market only knows one number per species — global abundance — and derives
	the rest. That is why fishing the same species everywhere makes it worthless
	without anyone scripting that outcome.

	Two behaviours matter for how the game *feels*:

	- Inertia. Prices do not snap. A single big catch nudges the market, but it
	  does not teleport it, so players can read and plan around a trend.

	- The scarcity curve is bounded. A collapsed species gets expensive, not
	  infinite. Otherwise the optimal strategy would be to wipe a stock out
	  entirely and farm the rebound, which is exactly the degenerate play the
	  design is trying to prevent.
]]

local scriptParent = script and script.Parent
local Config = require(scriptParent and scriptParent.Config or "./Config")
local Species = require(scriptParent and scriptParent.Species or "./Species")

export type Direction = "rising" | "falling" | "flat"

export type PriceEntry = {
	speciesId: string,
	price: number,
	baseValue: number,
	scarcityMultiplier: number,
	globalAbundance: number,
	direction: Direction,
}

export type Market = {
	entries: { [string]: PriceEntry },
	order: { string },
	day: number,
}

local Market = {}

--=============================================================================
-- Construction
--=============================================================================

function Market.new(): Market
	local entries: { [string]: PriceEntry } = {}
	local order: { string } = {}

	for _, species in Species.list do
		-- start at fair value: every species abundant, every price at base
		entries[species.id] = {
			speciesId = species.id,
			price = species.baseValue,
			baseValue = species.baseValue,
			scarcityMultiplier = 1.0,
			globalAbundance = 1.0,
			direction = "flat",
		}
		table.insert(order, species.id)
	end

	return { entries = entries, order = order, day = 0 }
end

--=============================================================================
-- Scarcity
--=============================================================================

--- Convert a global abundance ratio into a price multiplier.
---
--- At abundance 1.0 the multiplier is exactly 1. As abundance falls toward
--- zero the multiplier rises toward 1/SCARCITY_FLOOR, and is clamped at
--- MAX_SCARCITY_MULTIPLIER so a collapsed stock stays merely valuable rather
--- than becoming a money printer.
function Market.scarcityMultiplier(abundance: number): number
	local a = math.clamp(abundance, 0.0, 1.0)
	local floor = Config.SCARCITY_FLOOR
	local multiplier = 1.0 / (floor + (1.0 - floor) * a)
	return math.clamp(multiplier, 1.0, Config.MAX_SCARCITY_MULTIPLIER)
end

--- The price a species *would* trade at right now, with no inertia applied.
function Market.targetPrice(baseValue: number, abundance: number): number
	return baseValue * Market.scarcityMultiplier(abundance)
end

--=============================================================================
-- Update
--=============================================================================

--- Refresh one species from its current global abundance.
function Market.updateSpecies(
	market: Market,
	speciesId: string,
	globalAbundance: number
): PriceEntry?
	local entry = market.entries[speciesId]
	if not entry then
		return nil
	end

	local species = Species.get(speciesId)
	if not species then
		return nil
	end

	local previous = entry.price
	local target = Market.targetPrice(species.baseValue, globalAbundance)

	-- Inertia: the market drifts toward the target rather than teleporting.
	local next = previous + (target - previous) * (1.0 - Config.PRICE_INERTIA)

	entry.globalAbundance = globalAbundance
	entry.scarcityMultiplier = Market.scarcityMultiplier(globalAbundance)
	entry.price = math.max(next, 1.0)

	-- Direction uses both relative change and an absolute floor, so a species
	-- that is moving a meaningful percentage does not read as flat just because
	-- its price happens to be small.
	local relativeMove = if previous > 0.0 then (entry.price - previous) / previous else 0.0
	local absoluteMove = entry.price - previous

	if relativeMove > Config.PRICE_FLOOR_MOVE or absoluteMove > 0.5 then
		entry.direction = "rising"
	elseif relativeMove < -Config.PRICE_FLOOR_MOVE or absoluteMove < -0.5 then
		entry.direction = "falling"
	else
		entry.direction = "flat"
	end

	return entry
end

--- Refresh every species from a table of speciesId -> globalAbundance.
function Market.updateAll(market: Market, abundances: { [string]: number }): ()
	for _, speciesId in market.order do
		local abundance = abundances[speciesId] or 1.0
		Market.updateSpecies(market, speciesId, abundance)
	end
end

--=============================================================================
-- Queries
--=============================================================================

function Market.get(market: Market, speciesId: string): PriceEntry?
	return market.entries[speciesId]
end

--- Current price of one species, or its base value if the market has never
--- seen it. Used by the server to value a catch without a nil-check dance.
function Market.priceOf(market: Market, speciesId: string): number
	local entry = market.entries[speciesId]
	if entry then
		return entry.price
	end
	local species = Species.get(speciesId)
	return if species then species.baseValue else 0.0
end

function Market.snapshot(market: Market): { PriceEntry }
	local out: { PriceEntry } = {}
	for _, speciesId in market.order do
		local entry = market.entries[speciesId]
		if entry then
			table.insert(out, entry)
		end
	end
	return out
end

--- Is this species scarce enough that the game should tell players to go find
--- it elsewhere? Drives the scarcity badge and the toast.
function Market.isScarce(entry: PriceEntry): boolean
	return entry.globalAbundance < Config.COLLAPSE_THRESHOLD * 1.4
end

--- Most valuable species per unit of abundance right now. The market's own
--- "where should I go" suggestion, used to nudge players toward grounds that
--- have not been picked over.
function Market.bestOpportunity(market: Market): PriceEntry?
	local best: PriceEntry? = nil
	for _, speciesId in market.order do
		local entry = market.entries[speciesId]
		if entry then
			if not best or entry.price > best.price then
				best = entry
			end
		end
	end
	return best
end

return Market
