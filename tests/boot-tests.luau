--!strict
--[[
	Slack Water — server boot smoke test.

	Run via the wrapper, which feeds the sources in:
		./tests/run-boot.sh

	Unlike the suites that only exercise src/Shared, this file executes the REAL
	server boot path: Main.server.luau's stage list, world generation, the
	simulation loop, a player joining and one full cast — against the fake Roblox
	engine in tests/harness/. It exists because three showstoppers shipped past
	172 passing unit tests that never once ran the server.

	Main.start() wraps every stage in pcall and merely PRINTS failures, so a
	broken stage used to scroll past. Here, a failed stage fails the suite: the
	harness tees every print/warn the server makes and the first suite scans that
	capture for the FAILED marker.

	HISTORY THIS SUITE PINS: while it was being written, the water-surface test
	was RED against the live tree (Environment.apply() configured a Water
	instance that never existed — showstopper #3). The OceanSurface fix landed
	concurrently and turned it green. If it is red again, the ocean really has
	no water. See docs/TESTING.md for the full known-red policy.
]]

--=============================================================================
-- Sources arrive as (path, contents) pairs through program arguments
--=============================================================================

-- selene does not model the main chunk's varargs, hence the allowance below.
-- selene: allow(undefined_variable)
local programArgs = { ... }
local argCount = #programArgs
if argCount == 0 then
	error("no embedded sources — run via ./tests/run-boot.sh, which feeds them in", 0)
end
if argCount % 2 ~= 0 then
	error("embedded sources are malformed (odd argument count) — run via ./tests/run-boot.sh", 0)
end

local sources: { [string]: string } = {}
for i = 1, argCount, 2 do
	local path = programArgs[i]
	local contents = programArgs[i + 1]
	if type(path) ~= "string" or type(contents) ~= "string" then
		error(
			"embedded sources are malformed at pair "
				.. tostring(i)
				.. " — run via ./tests/run-boot.sh",
			0
		)
	end
	sources[path] = contents
end

--=============================================================================
-- Tiny test framework (same shape as run-tests.luau)
--=============================================================================

local passed = 0
local failed = 0
local failures: { string } = {}
local currentSuite = ""

local function suite(name: string, fn: () -> ())
	currentSuite = name
	print("")
	print("== " .. name .. " ==")
	fn()
end

local function test(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if ok then
		passed += 1
		print("  PASS  " .. name)
	else
		failed += 1
		local msg = tostring(err)
		table.insert(failures, currentSuite .. " / " .. name .. ": " .. msg)
		print("  FAIL  " .. name .. "\n        " .. msg)
	end
end

local function assertEq(actual: any, expected: any, msg: string?)
	if actual ~= expected then
		error(
			(msg or "values differ")
				.. " — expected "
				.. tostring(expected)
				.. ", got "
				.. tostring(actual),
			2
		)
	end
end

local function assertTrue(cond: boolean, msg: string?)
	if not cond then
		error(msg or "expected true", 2)
	end
end

--=============================================================================
-- Boot the server for real
--=============================================================================

local Roblox = require("./harness/Roblox")
local Runner = require("./harness/Runner")

-- Pure Shared modules, pulled the ordinary way for inspection only. They are
-- stateless, so a second instance of them beside the ones inside the server
-- environment cannot drift.
local OceanSim = require("./../src/Shared/Ocean/OceanSim")
local Species = require("./../src/Shared/Species")
local Config = require("./../src/Shared/Config")
local Types = require("./../src/Shared/Types")

local roblox = Roblox.new()
local runner = Runner.new(sources, roblox)

local bootOk, bootErr = pcall(function()
	return runner:load("src/Server/Main.server.luau")
end)

if not bootOk then
	print("")
	print("===========================================")
	print("BOOT FAILED OUTRIGHT — the server boot path threw:")
	print(tostring(bootErr))
	print("===========================================")
	error("server boot path threw: " .. tostring(bootErr), 0)
end

-- Loaded (i.e. required, cached) after boot — same module identities the server
-- itself uses.
local OceanService = runner:load("src/Server/OceanService.luau")
local ProfileService = runner:load("src/Server/ProfileService.luau")
local Environment = runner:load("src/Server/Environment.luau")

local svc = OceanService.get()
local ocean: any = svc.ocean
local workspace: any = roblox.workspace

--=============================================================================
-- Helpers over the built world
--=============================================================================

--- Every descendant of `node`, depth-first.
local function allDescendants(node: any): { any }
	local out = {}
	local function walk(current: any)
		for _, child in current:GetChildren() do
			table.insert(out, child)
			walk(child)
		end
	end
	walk(node)
	return out
end

--- Parts are the things with a CFrame that a player could stand on or fall
--- through. Guis and labels are excluded on purpose.
local function isPart(inst: any): boolean
	return inst.__class == "Part" or inst.__class == "SpawnLocation"
end

local function hasNaN(v: number): boolean
	return v ~= v
end

local function markerModels(folder: any): { any }
	local markers = {}
	for _, child in folder:GetChildren() do
		if child.__class == "Model" and child:GetAttribute("regionId") ~= nil then
			table.insert(markers, child)
		end
	end
	return markers
end

--- Depth-first name search, because the spawn now lives INSIDE the boat model
--- (it rides the tide with the boat) rather than loose in the Ocean folder.
local function findDescendant(node: any, name: string): any
	for _, inst in allDescendants(node) do
		if inst.Name == name then
			return inst
		end
	end
	return nil
end

--=============================================================================
-- Suites
--=============================================================================

suite("boot — every stage of Main.start() must complete", function()
	test("Main.server.luau loaded and returned a module", function()
		local Main = runner:load("src/Server/Main.server.luau")
		assertTrue(type(Main) == "table", "Main did not return a module table")
		assertTrue(type(Main.start) == "function", "Main.start is missing")
	end)

	test("no boot stage reported failure (Main only prints these)", function()
		local failedLines = runner:linesContaining("FAILED ->")
		if #failedLines > 0 then
			local joined = failedLines[1]
			for i = 2, #failedLines do
				joined = joined .. "\n        " .. failedLines[i]
			end
			error("boot stage(s) failed and Main.start() only printed it:\n        " .. joined, 0)
		end
	end)

	test("boot reached '[slack-water] ready'", function()
		local lines = runner:linesContaining("[slack-water] ready")
		assertEq(#lines, 1, "Main.start() did not reach its final line")
	end)

	test("worldgen announced the initial regions", function()
		local expected = string.format("[slack-water] worldgen: %d region(s) placed", #ocean.order)
		local lines = runner:linesContaining(expected)
		assertTrue(#lines >= 1, "expected output '" .. expected .. "' was never printed")
	end)
end)

suite("worldgen — a player can stand in this world", function()
	local oceanFolder = workspace:FindFirstChild("Ocean")
	assertTrue(oceanFolder ~= nil, "no Ocean folder in Workspace — worldgen never built")

	test("the boat deck exists and is solid under a player", function()
		local boat = oceanFolder:FindFirstChild("FVEileen")
		assertTrue(boat ~= nil, "the boat model 'FVEileen' was never built")
		local deck = boat:FindFirstChild("Deck")
		assertTrue(deck ~= nil, "the boat has no Deck part")
		assertEq(
			deck.CanCollide,
			true,
			"Deck.CanCollide must be true or the player falls out of the world (showstopper #2)"
		)
		assertEq(deck.Anchored, true, "Deck.Anchored must be true")
		assertTrue(deck.Size.X > 0 and deck.Size.Y > 0 and deck.Size.Z > 0, "Deck has a zero size")
	end)

	test("the boat is a boat, not a slab", function()
		-- The world used to put a 24x24 brown box in the water whose entire
		-- purpose was to stop the player falling out of the world. Every test
		-- in this file passed while that was all the boat was.
		--
		-- These assertions are the ones that would have failed. They are here
		-- so "somebody simplified the boat back to a placeholder" is a red
		-- test rather than something nobody notices for another month.
		local boat = findDescendant(oceanFolder, "FVEileen")
		assertTrue(boat ~= nil, "no FVEileen model in the world")

		for _, required in { "Deck", "Deckhouse", "Pilothouse", "Mast", "NetReel" } do
			assertTrue(
				findDescendant(boat, required) ~= nil,
				"the boat has no " .. required .. " — it is back to being a slab"
			)
		end

		local parts = boat:GetChildren()
		assertTrue(
			#parts >= 15,
			"the boat has only " .. tostring(#parts) .. " parts; that is a slab, not a working boat"
		)

		-- The hull must be long enough to read as a vessel from the water.
		local deck = findDescendant(boat, "Deck")
		assertTrue(deck.Size.X >= 40, "the deck is too short to read as a boat")
	end)

	test("a spawn location exists on the boat", function()
		local spawn = findDescendant(oceanFolder, "Spawn")
		assertTrue(spawn ~= nil, "no Spawn anywhere in the built world")
		assertEq(spawn.__class, "SpawnLocation", "Spawn is not a SpawnLocation")
		assertEq(spawn.CanCollide, true, "Spawn.CanCollide must be true")
	end)

	test("a sea floor exists far below everything", function()
		local floor = oceanFolder:FindFirstChild("SeaFloor")
		assertTrue(floor ~= nil, "no SeaFloor — a player who falls has nothing to land on")
		assertTrue(floor.CFrame.Y < 0, "SeaFloor should sit below the water line")
	end)

	test("there is actually water on the ocean", function()
		-- This is the assertion that was missing when the game shipped with no
		-- water at all. The checks above could all pass on a world with a
		-- boat, a spawn, a floor and ground discs — which is exactly what a
		-- player would see and reasonably describe as "a blank slate".
		--
		-- Without this, "the water renders" was only ever verifiable by a human
		-- pressing Play and looking. Now it is a test.
		local surface = oceanFolder:FindFirstChild("Surface")
		assertTrue(
			surface ~= nil,
			"no Surface folder — OceanSurface never built. The ocean has no water."
		)

		local tiles = surface:GetChildren()
		assertTrue(
			#tiles > 1,
			"Surface has " .. tostring(#tiles) .. " children; a sea needs more than that"
		)

		-- Every tile must be finite and at a sane depth, or the player is
		-- looking at NaN geometry.
		for _, tile in tiles do
			local y = tile.CFrame.Y
			assertTrue(
				y == y and y > -400 and y < 100,
				"a water tile has an insane Y (" .. tostring(y) .. ")"
			)
		end
	end)

	test("one marker model per simulated region", function()
		local markers = markerModels(oceanFolder)
		assertEq(
			#markers,
			#ocean.order,
			"the built world does not match the simulation's region list"
		)
		for _, regionId in ocean.order do
			assertTrue(
				oceanFolder:FindFirstChild(regionId) ~= nil,
				regionId .. " exists in the ocean but was never built into the world"
			)
		end
	end)

	test("no generated part has a NaN CFrame", function()
		for _, inst in allDescendants(workspace) do
			if isPart(inst) then
				local cf = inst.CFrame
				assertTrue(cf ~= nil, inst.Name .. " has no CFrame at all")
				assertTrue(
					not hasNaN(cf.X) and not hasNaN(cf.Y) and not hasNaN(cf.Z),
					inst.Name .. " has a NaN position: " .. tostring(cf)
				)
			end
		end
	end)

	test("there is solid, collidable ground near the spawn", function()
		-- The player spawns near the origin. If nothing collidable and anchored
		-- has a walkable top near origin height, the first frame is a fall
		-- through the world — showstopper #2, which green UI tests sailed past.
		local found = false
		for _, inst in allDescendants(workspace) do
			if isPart(inst) and inst.CanCollide == true and inst.Anchored == true then
				local topY = inst.CFrame.Y + inst.Size.Y / 2
				local nearOrigin = math.abs(inst.CFrame.X) <= 20 and math.abs(inst.CFrame.Z) <= 20
				if nearOrigin and topY >= -5 and topY <= 15 then
					found = true
					break
				end
			end
		end
		assertTrue(
			found,
			"no anchored, collidable part with a walkable top near the origin — the spawn is a void"
		)
	end)

	test("the ocean has a water surface", function()
		-- This is the assertion that pinned showstopper #3: Environment.apply()
		-- looked up a Terrain Water instance that was never created, and
		-- nothing else in the world provided water. It failed on the tree as
		-- found; the fix (OceanSurface's tile grid) landed while this suite
		-- was being written. It accepts any honest renderer: a Terrain Water
		-- child, parts of Enum.Material.Water, or the transparent tile grid
		-- OceanSurface builds under Ocean/Surface.
		local terrain = workspace.Terrain
		local water = terrain ~= nil and terrain:FindFirstChildOfClass("Water") or nil

		local materialWater = false
		for _, inst in allDescendants(workspace) do
			if isPart(inst) and inst.Material == roblox.Enum.Material.Water then
				materialWater = true
				break
			end
		end

		local surfaceTiles = 0
		local surfaceFolder = oceanFolder:FindFirstChild("Surface")
		if surfaceFolder ~= nil then
			for _, inst in allDescendants(surfaceFolder) do
				if isPart(inst) and inst.Transparency ~= nil and inst.Transparency > 0.3 then
					surfaceTiles += 1
				end
			end
		end

		if water == nil and not materialWater and surfaceTiles < 2 then
			error(
				"no water anywhere in Workspace: Terrain has no Water child, no part uses Enum.Material.Water,"
					.. " and there is no transparent surface tile grid — a fishing game whose world has no ocean (showstopper #3)",
				0
			)
		end

		if water ~= nil then
			assertTrue(
				water.WaterColor ~= nil,
				"a Water instance exists but nothing ever set WaterColor on it — water styling is dead code"
			)
		end
	end)
end)

suite("environment — the look of the place", function()
	local lighting: any = roblox.services.Lighting

	test("an Atmosphere was created and tuned", function()
		local atmosphere = lighting:FindFirstChildOfClass("Atmosphere")
		assertTrue(atmosphere ~= nil, "no Atmosphere under Lighting")
		-- The atmosphere values are inline literals in Environment.apply(), so
		-- the check is "was set at all" — nil means that tuning is dead code.
		assertTrue(atmosphere.Density ~= nil, "Atmosphere.Density was never set")
		assertTrue(atmosphere.Haze ~= nil, "Atmosphere.Haze was never set")
	end)

	test("Clouds were created and tuned", function()
		local clouds = lighting:FindFirstChildOfClass("Clouds")
		assertTrue(clouds ~= nil, "no Clouds under Lighting")
		assertEq(clouds.Cover, Environment.TUNING.cloudsCover, "Clouds.Cover")
	end)

	test("Lighting got the overcast morning", function()
		assertEq(lighting.ClockTime, Environment.TUNING.timeOfDay, "Lighting.ClockTime")
		assertEq(lighting.FogEnd, Environment.TUNING.fogEnd, "Lighting.FogEnd")
	end)
end)

suite("ocean service — the shared simulation boots", function()
	local replicatedStorage: any = roblox.services.ReplicatedStorage

	test("the starting ocean has the configured number of regions", function()
		assertEq(#ocean.order, Config.INITIAL_REGIONS, "initial region count")
	end)

	test("every remote exists in ReplicatedStorage", function()
		local folder = replicatedStorage:FindFirstChild(Types.REMOTE_FOLDER)
		assertTrue(folder ~= nil, "no '" .. Types.REMOTE_FOLDER .. "' folder in ReplicatedStorage")
		for _, name in
			{
				Types.CastRequest,
				Types.CastResult,
				Types.OceanSync,
				Types.MarketSync,
				Types.RegionDiscovered,
				Types.Notify,
			}
		do
			assertTrue(
				folder:FindFirstChild(name) ~= nil,
				"remote '" .. name .. "' was never created"
			)
		end
	end)

	test("the market priced every species on day one", function()
		for _, species in Species.list do
			local entry = svc.market.entries[species.id]
			assertTrue(entry ~= nil, species.id .. " has no market entry at boot")
			assertTrue(entry.price > 0, species.id .. " has a non-positive price at boot")
		end
	end)

	test("the first OceanSync broadcast already went out", function()
		local remote = svc.remotes[Types.OceanSync]
		assertTrue(
			#remote.sentToAll >= 1,
			"no OceanSync was ever fired — clients would see nothing"
		)
		local payload = remote.sentToAll[1][1]
		assertEq(#payload.regions, Config.INITIAL_REGIONS, "first broadcast region count")
	end)
end)

suite("heartbeat — the simulation actually ticks", function()
	local tickBefore = ocean.tickCount
	local hourBefore = svc.hour
	local regionsBefore = #ocean.order

	test("three pumped heartbeats tick the simulation three times", function()
		for _ = 1, 3 do
			roblox.services.RunService.Heartbeat:Fire(20)
		end
		runner:flushTasks()
		assertEq(ocean.tickCount, tickBefore + 3, "tickCount")
		assertEq(svc.hour, hourBefore + 3, "service hour clock")
	end)

	test("day-one composition admitted procedural banks every tick", function()
		-- The calendar starts on day 1 of an odd month, so every tick composes.
		-- With the backend unreachable the filler must keep the ocean growing.
		assertEq(svc.round, 3, "composition rounds run")
		assertEq(
			#ocean.order,
			regionsBefore + 3 * Config.BANKS_PER_ROUND,
			"regions after composition"
		)
	end)

	test("RegionDiscovered was broadcast for the new grounds", function()
		local remote = svc.remotes[Types.RegionDiscovered]
		assertEq(#remote.sentToAll, 3 * Config.BANKS_PER_ROUND, "RegionDiscovered broadcasts")
	end)

	test("discovered grounds are built into the world", function()
		local oceanFolder = workspace:FindFirstChild("Ocean")
		local markers = markerModels(oceanFolder)
		assertEq(
			#markers,
			#ocean.order,
			"the ocean has grown but the built world has not — the RegionDiscovered listener in Main.start() never rebuilds WorldGen"
		)
	end)
end)

suite("players — joining, being placed, getting a profile", function()
	local player = roblox.makePlayer(4242, "smoke_test")
	player.Character = roblox.makeCharacter()
	player.Parent = roblox.services.Players

	roblox.services.Players.PlayerAdded:Fire(player)
	runner:flushTasks()

	test("the player was stamped with a join time", function()
		assertTrue(player:GetAttribute("joinedAt") ~= nil, "Main never set joinedAt on the player")
	end)

	test("the player was placed above the boat, not at the void origin", function()
		local root = player.Character:FindFirstChild("HumanoidRootPart")
		assertTrue(root ~= nil, "character has no HumanoidRootPart")
		local y = root.CFrame.Y
		assertTrue(
			not hasNaN(y) and y > 10 and y < 200,
			"spawn placement put the player at Y="
				.. tostring(y)
				.. " — they would fall out of the world"
		)
	end)

	test("a profile exists for the player", function()
		local profiles = ProfileService.get()
		assertTrue(
			profiles ~= nil and profiles.profiles[player] ~= nil,
			"no profile was created on join"
		)
	end)

	test("ProfileSync reached the client with level data", function()
		local remote = roblox.services.ReplicatedStorage
			:FindFirstChild(Types.REMOTE_FOLDER)
			:FindFirstChild("ProfileSync")
		assertTrue(#remote.sentToPlayers >= 1, "ProfileSync was never fired")
		local payload = remote.sentToPlayers[#remote.sentToPlayers].args[1]
		assertTrue(payload.level ~= nil and payload.level >= 1, "ProfileSync carried no level")
	end)
end)

suite("cast — one full round trip through the server", function()
	-- Pick, deterministically, the deepest region and a species that actually
	-- lives there at meaningful abundance.
	local deepestRegionId, deepestDepth = nil, -1
	for _, regionId in ocean.order do
		local region = OceanSim.getRegion(ocean, regionId)
		if region and region.depth > deepestDepth then
			deepestRegionId, deepestDepth = regionId, region.depth
		end
	end
	local speciesId = nil
	for _, species in Species.list do
		if
			species.minDepth <= deepestDepth
			and deepestDepth <= species.maxDepth
			and OceanSim.abundance(ocean, deepestRegionId, species.id) > 0.05
		then
			speciesId = species.id
			break
		end
	end

	local player = roblox.services.Players:GetPlayers()[1]
	assertTrue(player ~= nil, "no player from the previous suite — suites must run in order")

	test("a cast request produces exactly one cast result", function()
		assertTrue(deepestRegionId ~= nil, "no region to cast at")
		assertTrue(
			speciesId ~= nil,
			"no species lives at the deepest region — fixture problem, not a game bug"
		)

		local remote = svc.remotes[Types.CastRequest]
		remote.OnServerEvent:Fire(player, {
			regionId = deepestRegionId,
			speciesId = speciesId,
			effort = 0,
			performance = 0.7,
		})
		runner:flushTasks()

		local castRemote = svc.remotes[Types.CastResult]
		assertEq(#castRemote.sentToPlayers, 1, "a cast must produce exactly one CastResult")
		local payload = castRemote.sentToPlayers[1].args[1]
		assertTrue(payload.ok == true, "cast failed: " .. tostring(payload.reason))
		assertTrue(payload.yielded > 0, "a healthy deep ground yielded nothing")
		assertTrue(payload.weightKg > 0, "the catch has no weight")
		assertTrue(
			payload.level ~= nil and payload.level >= 1,
			"the cast result carries no career state"
		)
	end)

	test("the catch was credited to the skipper's career", function()
		local remote = roblox.services.ReplicatedStorage
			:FindFirstChild(Types.REMOTE_FOLDER)
			:FindFirstChild("ProfileSync")
		local syncsForPlayer = 0
		for _, sent in remote.sentToPlayers do
			if sent.player == player then
				syncsForPlayer += 1
			end
		end
		assertTrue(
			syncsForPlayer >= 2,
			"expected a join sync and a catch sync, saw " .. tostring(syncsForPlayer)
		)
	end)

	test("no background task or event handler ever errored", function()
		local problems = {}
		for _, err in roblox.taskErrors do
			table.insert(problems, err)
		end
		for _, signal in roblox.allSignals do
			for _, err in signal.errors do
				table.insert(problems, err)
			end
		end
		if #problems > 0 then
			error(#problems .. " background error(s), first: " .. tostring(problems[1]), 0)
		end
	end)
end)

--=============================================================================
-- Summary
--=============================================================================

print("")
print("===========================================")
print(string.format("passed: %d   failed: %d", passed, failed))
if failed > 0 then
	print("")
	print("Failures:")
	for _, f in failures do
		print("  - " .. f)
	end
	print("===========================================")
	error(string.format("%d test(s) failed", failed), 0)
end
print("all green")
print("===========================================")
