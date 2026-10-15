--!strict
--[[
	Water — colour and foam for the surface, as pure arithmetic.

	Given the wave displacement at a point, the current wave amplitude, and
	the depth of the water column under that point, decide what the water
	looks like: a blended colour and a foam intensity in [0, 1].

	Two rules do the work, and both are real observations rather than
	decoration:

	- foam appears on wave CRESTS, but only once the sea is strong enough
	  to break (whitecaps need wind; a calm sea has shiny crests, not white
	  ones);
	- foam appears in SHALLOW water, where the same energy is squeezed into
	  less depth — the surf line over a shoal.

	The palette is the same cool North Pacific overcast family as
	Environment.luau's lighting: grey-green water, slightly grey foam. A
	tropical blue would waste the premise exactly the way a postcard sky
	would.

	Pure Luau on purpose: no Color3, no Roblox globals, so the same rule
	runs headlessly in tests and authoritatively on the server. All returns
	are multiple values (r, g, b, foam) rather than tables — the renderer
	calls this per tile per pass and should not pay for garbage.
]]

local Water = {}

--=============================================================================
-- Palette anchors, r/g/b in [0, 1]
--=============================================================================

local DEEP = { 0.07, 0.16, 0.22 } -- open water under overcast
local SHALLOW = { 0.20, 0.34, 0.33 } -- grey-green over a shoal
local CREST = { 0.52, 0.62, 0.66 } -- light catching the wave top
local TROUGH = { 0.04, 0.10, 0.15 } -- the back of a wave, in shadow
local FOAM = { 0.86, 0.90, 0.92 } -- North Pacific foam, not laundry white

-- Depth (studs) over which the shallow-to-deep colour blend saturates.
local DEPTH_FADE = 14.0

-- Water shallower than SHALLOW_FOAM_END is fully in the surf zone; deeper
-- than SHALLOW_FOAM_START, depth contributes no foam at all.
local SHALLOW_FOAM_START = 16.0
local SHALLOW_FOAM_END = 5.0

-- Whitecaps need wind: below this wave amplitude (studs) crests shine but
-- do not break; at and above WHITECAP_FULL they all do.
local WHITECAP_MIN_AMP = 0.6
local WHITECAP_FULL_AMP = 2.4

-- How strongly foam replaces the water colour, and the crest/trough terms.
local FOAM_MIX = 0.85
local CREST_LIGHTEN = 0.35
local TROUGH_DARKEN = 0.22

--=============================================================================
-- Helpers
--=============================================================================

local function clamp01(v: number): number
	if v ~= v then -- NaN folds to 0 rather than propagating
		return 0.0
	end
	return math.clamp(v, 0.0, 1.0)
end

local function smoothstep(edge0: number, edge1: number, x: number): number
	local t = clamp01((x - edge0) / (edge1 - edge0))
	return t * t * (3.0 - 2.0 * t)
end

local function mix(a: number, b: number, t: number): number
	return a + (b - a) * t
end

--=============================================================================
-- Appearance
--=============================================================================

--- The colour and foam at one point of the surface.
---
--- Inputs (all studs, same scale as Waves):
---   heightAboveMean — the wave displacement at this point (from
---                     Waves.heightAt), NOT including tide or datum;
---   amplitude        — the current total wave amplitude (scales what a
---                      "crest" means and gates whitecaps);
---   waterDepth       — surface height minus the floor height under it.
---                      Negative means the ground stands above the water:
---                      a drying shoal.
---
--- Returns r, g, b, foam — all clamped to [0, 1].
function Water.appearance(heightAboveMean: number, amplitude: number, waterDepth: number)
	-- crest/trough position within [-1, 1]; amplitude 0 makes it 0 so calm
	-- water is a flat colour with no divide-by-zero
	local crestFrac = if amplitude > 0.0 then clamp01(heightAboveMean / amplitude) else 0.0

	-- base colour by depth: shallow shoal water is lighter and greener
	local depthT = smoothstep(0.0, DEPTH_FADE, waterDepth)
	local r = mix(SHALLOW[1], DEEP[1], depthT)
	local g = mix(SHALLOW[2], DEEP[2], depthT)
	local b = mix(SHALLOW[3], DEEP[3], depthT)

	-- crest lightening and trough darkening are what make a sum of sines
	-- read as shape instead of texture
	local up = clamp01(crestFrac)
	local down = clamp01(-crestFrac)
	r = mix(r, CREST[1], CREST_LIGHTEN * up * up)
	g = mix(g, CREST[2], CREST_LIGHTEN * up * up)
	b = mix(b, CREST[3], CREST_LIGHTEN * up * up)
	r = mix(r, TROUGH[1], TROUGH_DARKEN * down)
	g = mix(g, TROUGH[2], TROUGH_DARKEN * down)
	b = mix(b, TROUGH[3], TROUGH_DARKEN * down)

	-- whitecaps: crest foam only where there is enough energy to break
	local whitecap =
		clamp01((amplitude - WHITECAP_MIN_AMP) / (WHITECAP_FULL_AMP - WHITECAP_MIN_AMP))
	local crestFoam = smoothstep(0.45, 0.95, crestFrac) * 0.85 * whitecap

	-- surf: shallow water foams regardless of the sea state
	local shallowFoam = smoothstep(SHALLOW_FOAM_START, SHALLOW_FOAM_END, waterDepth)

	-- a drying shoal is all surf line
	if waterDepth <= 0.0 then
		shallowFoam = 1.0
	end

	local foam = clamp01(math.max(crestFoam, shallowFoam))

	r = mix(r, FOAM[1], foam * FOAM_MIX)
	g = mix(g, FOAM[2], foam * FOAM_MIX)
	b = mix(b, FOAM[3], foam * FOAM_MIX)

	return clamp01(r), clamp01(g), clamp01(b), foam
end

Water.DEEP = DEEP
Water.SHALLOW = SHALLOW

return Water
