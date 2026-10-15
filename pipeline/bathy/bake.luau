--!strict
--[[
	bake — regenerate shared/bathy/fallback-depth.json.

	Run from the repo root:

		luau pipeline/bathy/bake.luau > shared/bathy/fallback-depth.json

	Fully deterministic (fixed seed, pinned timestamp), so re-running it on an
	unmodified fallback.luau reproduces the committed file byte for byte.
	That property is asserted by tests/run-bathy.sh.
]]

local Fallback = require("./fallback")
local Json = require("./json")

print(Json.encode(Fallback.build()))
