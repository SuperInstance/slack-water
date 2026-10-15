--!strict
--[[
	Rng — deterministic, seedable pseudo-randomness.

	The ocean simulation must be perfectly reproducible: a server restart, a
	region regeneration, or a test run all have to produce the same ocean from
	the same seed. `Math.random` cannot do that, and it is also shared global
	state that makes the simulation untestable in isolation.

	This is the Park-Miller "minimal standard" generator:

		state = (state * 16807) mod (2^31 - 1)

	It is deliberately written with plain arithmetic and no bitwise operators.
	The standalone `luau` interpreter used by the test suite does not parse
	`<<`, `>>` or `~`, so an xorshift implementation would run in Studio and
	fail headlessly. This version is byte-identical in both. The largest
	intermediate product is about 3.6e13, comfortably inside the 2^53 range
	that doubles represent exactly, so no precision is lost.

	Not used for anything security-sensitive.
]]

export type Rng = {
	state: number,
}

local MODULUS = 2147483647 -- 2^31 - 1
local MULTIPLIER = 16807

local Rng = {}

function Rng.new(seed: number): Rng
	-- Park-Miller cannot escape a zero state, and negative/oversized seeds
	-- have to be folded in. Decorrelate nearby seeds by running the recurrence
	-- a few times so 41 and 42 do not produce near-identical streams.
	local s = math.abs(math.floor(seed)) % (MODULUS - 1) + 1
	for _ = 1, 4 do
		s = (s * MULTIPLIER) % MODULUS
	end
	return { state = s }
end

--- Next raw state value in [1, MODULUS).
function Rng.nextInt(rng: Rng): number
	rng.state = (rng.state * MULTIPLIER) % MODULUS
	return rng.state
end

--- Float in [0, 1).
function Rng.nextFloat(rng: Rng): number
	return Rng.nextInt(rng) / MODULUS
end

--- Float in [min, max).
function Rng.range(rng: Rng, min: number, max: number): number
	return min + (max - min) * Rng.nextFloat(rng)
end

--- Integer in [min, max] inclusive.
function Rng.int(rng: Rng, min: number, max: number): number
	if max <= min then
		return min
	end
	local span = max - min + 1
	return min + (Rng.nextInt(rng) % span)
end

--- Uniform pick from a list.
function Rng.pick<T>(rng: Rng, list: { T }): T?
	if #list == 0 then
		return nil
	end
	return list[Rng.int(rng, 1, #list)]
end

--- True with probability p.
function Rng.chance(rng: Rng, p: number): boolean
	return Rng.nextFloat(rng) < p
end

--- Weighted pick. `weights` must be the same length as `list` and sum to > 0.
function Rng.pickWeighted<T>(rng: Rng, list: { T }, weights: { number }): T?
	if #list == 0 or #list ~= #weights then
		return nil
	end

	local total = 0.0
	for _, w in weights do
		if w > 0.0 then
			total += w
		end
	end
	if total <= 0.0 then
		return nil
	end

	local roll = Rng.nextFloat(rng) * total
	local cumulative = 0.0
	for i, item in list do
		local w = weights[i]
		if w > 0.0 then
			cumulative += w
			if roll <= cumulative then
				return item
			end
		end
	end

	return list[#list]
end

--- Fisher-Yates, in place.
function Rng.shuffle<T>(rng: Rng, list: { T }): { T }
	for i = #list, 2, -1 do
		local j = Rng.int(rng, 1, i)
		list[i], list[j] = list[j], list[i]
	end
	return list
end

--- Derive an independent generator from this one plus a label, so each region
--- can draw from its own stream without the whole simulation sharing one
--- sequence. FNV-1a over the label, mixed with the current state.
function Rng.fork(rng: Rng, label: string): Rng
	local hash = 2166136261
	for i = 1, #label do
		local byte = label:byte(i)
		-- arithmetic multiply-add, kept inside double precision
		hash = (hash + byte) % 4294967296
		hash = (hash * 16777619) % 4294967296
		-- fold the high bits down so we stay in a sane range
		hash = (hash % 65521) + 1
	end
	return Rng.new(hash + rng.state)
end

--- Current state, for snapshotting a generator alongside an ocean.
function Rng.getState(rng: Rng): number
	return rng.state
end

function Rng.setState(rng: Rng, state: number): ()
	rng.state = (math.floor(math.abs(state)) % (MODULUS - 1)) + 1
end

Rng._MODULUS = MODULUS

return Rng
