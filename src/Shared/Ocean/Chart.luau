--!strict
--[[
	Chart — bathymetry with provenance.

	Three ideas are borrowed wholesale from SuperInstance/shoalwater, and they
	are the reason this file exists:

	1. **The world is measured, not imagined.** Wherever a real sounding exists,
	   the game uses it. Everything else is explicitly labelled as grown, so the
	   player (and we) always know which ground is real.

	2. **Grow the forest, don't count the trees.** Where soundings are thin, we
	   do not pretend to have detail. We generate a plausible region from
	   measured statistics and mark it low-confidence, rather than drawing a
	   fake-precise coastline.

	3. **Ground truth is a practice, not a dataset.** The game's chart gets
	   better the same way a real chart does — by somebody going out in a boat.
	   `Chart.survey` is that gesture, and it is the intended path for turning
	   generated water into measured water over time.

	PROVENANCE IS NOT COSMETIC

	Every region carries one of three provenances, and the distinction is
	load-bearing:

	| provenance  | meaning                                    | trust |
	| ----------- | ------------------------------------------ | ----- |
	| `measured`  | a real sounding, verified                   | high  |
	| `grown`     | generated from statistics, plausible only  | low   |
	| `composed`  | proposed by the language model, validated   | model |

	Only `measured` water should ever be presented to players as fact. The
	difference between "this is a shoal at 3.1 m" and "the model thinks there
	might be a shoal here" is the difference between a chart and a guess, and
	the game should never blur it.

	DATA SHAPE

	`toJson` / `loadFromJson` use a flat, stable schema so that real sounding
	data can be converted into it by a script rather than by hand. Soundings
	arrive as CSB (crowdsourced boat soundings) — the same input format
	shoalwater's toolchain already normalises — or from a NOAA tide/sounding
	export.

	A note carried over from that repo, because it is the kind of error that
	poisons a whole dataset silently: the widely-copied NOAA pack "9452210
	Sitka" is actually **Juneau**. Sitka is **9451600**, Port Alexander is
	9451054. Verify the station before trusting any tide or datum metadata.
]]

local scriptParent = script and script.Parent
local Config = require(scriptParent and script.Parent.Config or "../Config")
local Rng = require(scriptParent and scriptParent.Rng or "./Rng")

type Habitat = "kelp" | "reef" | "sand" | "mud" | "open" | "estuary"

export type Provenance = "measured" | "grown" | "composed"

export type BottomType = "sand" | "mud" | "gravel" | "rock" | "shell" | "kelp"

export type Sounding = {
	id: string,
	name: string,
	habitat: Habitat,

	-- position. Regions without real coordinates carry NaN-free defaults and
	-- are flagged via `hasPosition`, so nothing downstream mistakes a synthetic
	-- region for a surveyed one.
	lat: number,
	lon: number,
	hasPosition: boolean,

	-- depth in metres at MLLW — the same datum the tide is measured against, so
	-- chart depth plus current tide height is the water actually over the ground.
	chartedDepth: number,

	bottomType: BottomType,
	provenance: Provenance,

	-- 0..1. How much this should be trusted. A measured sounding is high; a
	-- grown region interpolating between two soundings is lower.
	confidence: number,

	-- when the survey was taken, if it came from one
	surveyedAt: number?,
	source: string?,
}

export type Chart = {
	soundings: { [string]: Sounding },
	order: { string },
}

local Chart = {}

--=============================================================================
-- Construction
--=============================================================================

function Chart.new(): Chart
	return { soundings = {}, order = {} }
end

function Chart.add(chart: Chart, sounding: Sounding): ()
	if chart.soundings[sounding.id] then
		-- re-adding an id replaces it, which is how a survey upgrades a region
		chart.soundings[sounding.id] = sounding
		return
	end
	chart.soundings[sounding.id] = sounding
	table.insert(chart.order, sounding.id)
end

function Chart.get(chart: Chart, id: string): Sounding?
	return chart.soundings[id]
end

function Chart.count(chart: Chart): number
	return #chart.order
end

--=============================================================================
-- Provenance helpers
--=============================================================================

--- Fraction of the chart backed by real soundings, weighted by confidence.
---
--- This is the game's honesty metric. It is worth surfacing in the UI — a
--- player who can see that the chart is 60% surveyed has a real reason to
--- want to go survey the other 40%.
function Chart.coverage(chart: Chart): number
	if #chart.order == 0 then
		return 0.0
	end

	local total = 0.0
	for _, id in chart.order do
		local s = chart.soundings[id]
		if s then
			total += if s.provenance == "measured" then s.confidence else s.confidence * 0.25
		end
	end

	return math.clamp(total / #chart.order, 0.0, 1.0)
end

--- Counts by provenance, for telemetry and for the UI's chart legend.
function Chart.provenanceBreakdown(chart: Chart): { [string]: number }
	local out: { [string]: number } = { measured = 0, grown = 0, composed = 0 }
	for _, id in chart.order do
		local s = chart.soundings[id]
		if s then
			out[s.provenance] = (out[s.provenance] or 0) + 1
		end
	end
	return out
end

--=============================================================================
-- Surveying
--=============================================================================

--- Record a real observation against an existing sounding.
---
--- This is the in-game gesture behind "ground truth is a practice". A region
--- that was generated or model-composed becomes measured, and the coverage
--- metric moves. In production this is fed by actual survey passes; here it is
--- the API that a survey pipeline would call.
function Chart.survey(
	chart: Chart,
	id: string,
	measurements: {
		chartedDepth: number,
		bottomType: BottomType?,
		habitat: Habitat?,
		lat: number?,
		lon: number?,
		source: string?,
	}
): Sounding?
	local existing = chart.soundings[id]
	if not existing then
		return nil
	end

	existing.chartedDepth = math.clamp(measurements.chartedDepth, 0.1, 900)
	existing.provenance = "measured"
	existing.confidence = 1.0
	existing.surveyedAt = os.time()

	if measurements.bottomType then
		existing.bottomType = measurements.bottomType
	end
	if measurements.habitat then
		existing.habitat = measurements.habitat
	end
	if measurements.lat ~= nil and measurements.lon ~= nil then
		existing.lat = measurements.lat
		existing.lon = measurements.lon
		existing.hasPosition = true
	end
	if measurements.source then
		existing.source = measurements.source
	end

	return existing
end

--=============================================================================
-- Conversion
--=============================================================================

--- A sounding as an OceanSim region.
---
--- Note what is NOT passed: the species mix. Charted depth and bottom type
--- describe the *seabed*, and OceanSim derives which species can live there
--- from those. That keeps one authority over population — see BankSpec for the
--- same reasoning applied to model-proposed banks.
function Chart.toRegion(chart: Chart, id: string): any?
	local s = chart.soundings[id]
	if not s then
		return nil
	end

	-- bottom type predicts habitat, and richer (harder) bottoms hold fewer but
	-- more valuable species — which OceanSim's habitat affinity already models.
	local richness = 0.8 + s.confidence * 0.6

	return {
		id = s.id,
		name = s.name,
		habitat = s.habitat,
		depth = s.chartedDepth,
		salinity = 32.0,
		richness = math.clamp(richness, 0.5, 1.5),
		origin = if s.provenance == "composed" then "composed" else "procedural",
	}
end

function Chart.toRegionArray(chart: Chart): { any }
	local out: { any } = {}
	for _, id in chart.order do
		local region = Chart.toRegion(chart, id)
		if region then
			table.insert(out, region)
		end
	end
	return out
end

--=============================================================================
-- Serialisation
--=============================================================================

--- Flat, stable serialisable form of the chart.
---
--- This returns a plain table rather than a JSON string on purpose: encoding
--- needs HttpService, which is a Roblox global, and `Shared/` must stay pure
--- Luau so the chart can be loaded and tested headlessly. The server layer
--- calls HttpService:JSONEncode on this.
function Chart.toChartArray(chart: Chart): { any }
	local array = {}
	for _, id in chart.order do
		local s = chart.soundings[id]
		if s then
			table.insert(array, s)
		end
	end
	return array
end

--- Load a chart previously written by `toJson`.
---
--- Accepts the raw decoded value rather than a string, because Roblox's
--- JSONDecode is the only way to get here in-game and doing it twice would
--- just be a way to fail.
function Chart.loadFromChart(chart: Chart, decoded: any): number
	if typeof(decoded) ~= "table" then
		return 0
	end

	local entries = decoded.soundings or decoded
	if typeof(entries) ~= "table" then
		return 0
	end

	local loaded = 0
	for _, raw in entries do
		if typeof(raw) == "table" and typeof(raw.id) == "string" then
			-- Everything loaded from disk is trusted only as far as it claims to
			-- be. An unknown provenance string is treated as grown, never as
			-- measured; otherwise anyone could ship a chart full of fabricated
			-- "surveyed" ground.
			local provenance: Provenance = "grown"
			if raw.provenance == "measured" then
				provenance = "measured"
			elseif raw.provenance == "composed" then
				provenance = "composed"
			end

			Chart.add(chart, {
				id = raw.id,
				name = if typeof(raw.name) == "string" then raw.name else raw.id,
				habitat = raw.habitat or "open",
				lat = raw.lat or 0,
				lon = raw.lon or 0,
				hasPosition = raw.hasPosition == true,
				chartedDepth = math.clamp(tonumber(raw.chartedDepth) or 10, 0.1, 900),
				bottomType = raw.bottomType or "sand",
				provenance = provenance,
				confidence = math.clamp(tonumber(raw.confidence) or 0.5, 0.0, 1.0),
				surveyedAt = raw.surveyedAt,
				source = raw.source,
			})
			loaded += 1
		end
	end

	return loaded
end

Chart._MAX_REGIONS = Config.MAX_BANKS

return Chart