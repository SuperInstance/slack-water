--!strict
--[[
	Slack Water — cast loop test suite.

	Run headlessly:
		luau tests/cast-loop-tests.luau

	Covers the pure half of the cast loop's client: the selection rules in
	CastBar.client.luau (depth windows, blocked species, blind resolution, the
	double-cast guard, cooldown presentation, tide-open timing) plus the
	cross-file contracts the loop leans on — Config.CAST_COOLDOWN existing,
	the Tide access gate answering, the species roster staying shaped the way
	the picker assumes, and OceanSync payloads surviving normalization into the
	selection rules.

	These tests exist because the loop they pin was dead on arrival once
	already: `Casting.start()` had no caller (docs/PLAYLOOP.md defect 1) and
	`Config.CAST_COOLDOWN` did not exist (defect 2 — every cast threw
	server-side). Both classes are pinned here. The UI half of CastBar needs
	Studio and is not covered by anything in this repo.
]]

local Ui = require("./../src/Client/Ui")
local Tide = require("./../src/Shared/Tide")
local Config = require("./../src/Shared/Config")
local Species = require("./../src/Shared/Species")
local CastBar = require("./../src/Client/CastBar.client")

--=============================================================================
-- Tiny test framework (same shape as tests/client-tests.luau)
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

local function assertNear(actual: number, expected: number, tol: number, msg: string?)
	if math.abs(actual - expected) > tol then
		error(
			(msg or "not within tolerance")
				.. " — expected "
				.. tostring(expected)
				.. " +/- "
				.. tostring(tol)
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
-- Fixtures
--
-- Real roster species wherever possible: the picker's windows are only as
-- honest as the roster it reads. GROUND mirrors one normalized OceanSync
-- region (the shape Ui.normalizeRegions emits), junk on purpose in the
-- places wire data is junk.
--=============================================================================

local GROUND = {
	id = "g1",
	chartedDepth = 40,
	species = { "rockfish", "herring", "halibut" },
	abundances = { rockfish = 0.4, herring = 0.9, halibut = 0.8 },
}

local HALIBUT_ONLY = {
	id = "g2",
	chartedDepth = 40,
	species = { "halibut" },
	abundances = { halibut = 0.9 },
}

local function realSpecies(id: string)
	return Species.get(id)
end

--=============================================================================
-- Depth windows
--=============================================================================

suite("CastBar.depthWindow — the legal water", function()
	test("caps the species band at the charted floor", function()
		local lo, hi = CastBar.depthWindow(40, realSpecies("rockfish")) -- 25..120 m band
		assertEq(lo, 25)
		assertEq(hi, 40)
	end)

	test("a ground at the band's shallow edge leaves a single legal depth", function()
		local lo, hi = CastBar.depthWindow(15, realSpecies("herring")) -- 15..110 m band
		assertEq(lo, 15)
		assertEq(hi, 15)
	end)

	test("a ground shallower than the species' floor has no window at all", function()
		local lo, hi = CastBar.depthWindow(40, realSpecies("halibut")) -- 200..900 m band
		assertEq(lo, nil)
		assertEq(hi, nil)
	end)

	test("deep grounds keep the species' own ceiling", function()
		local lo, hi = CastBar.depthWindow(500, realSpecies("sablefish")) -- 300..800 m band
		assertEq(lo, 300)
		assertEq(hi, 500)
	end)
end)

--=============================================================================
-- Species blocking
--=============================================================================

suite("CastBar.speciesBlockReason — why this target is refused", function()
	test("a species the server does not list says so", function()
		assertEq(CastBar.speciesBlockReason(GROUND, realSpecies("cod")), "not in these waters")
	end)

	test("a present species that lives deeper than the ground says so", function()
		assertEq(
			CastBar.speciesBlockReason(GROUND, realSpecies("halibut")),
			"lives deeper than this ground"
		)
	end)

	test("a present, in-range species gives no reason", function()
		assertEq(CastBar.speciesBlockReason(GROUND, realSpecies("rockfish")), nil)
		assertEq(CastBar.speciesBlockReason(GROUND, realSpecies("herring")), nil)
	end)
end)

--=============================================================================
-- Blind targeting
--=============================================================================

suite("CastBar.legalPresentSpecies / blindPick — what a blind cast targets", function()
	test("orders by the server's abundances, window legality first", function()
		local legal = CastBar.legalPresentSpecies(GROUND, realSpecies)
		assertEq(#legal, 2, "halibut is present and abundant but has no window at 40 m")
		assertEq(legal[1].id, "herring") -- 0.9
		assertEq(legal[2].id, "rockfish") -- 0.4
	end)

	test("the blind pick is the most abundant legal species", function()
		assertEq(CastBar.blindPick(GROUND, realSpecies), "herring")
	end)

	test("abundance ties break by id, so the order is a pure function of the payload", function()
		local region = {
			id = "tie",
			chartedDepth = 300,
			species = { "pollock", "cod" },
			abundances = { pollock = 0.5, cod = 0.5 },
		}
		local legal = CastBar.legalPresentSpecies(region, realSpecies)
		assertEq(legal[1].id, "cod")
		assertEq(legal[2].id, "pollock")
		assertEq(CastBar.blindPick(region, realSpecies), "cod")
	end)

	test("junk or missing abundances count as zero, never as a crash", function()
		local region = {
			id = "bare",
			chartedDepth = 300,
			species = { "cod", "pollock" },
			abundances = { cod = "lots", pollock = 0 / 0 },
		}
		local legal = CastBar.legalPresentSpecies(region, realSpecies)
		assertEq(#legal, 2)
		assertEq(legal[1].abundance, 0)
		assertEq(legal[2].abundance, 0)
	end)

	test("a ground with nothing legal offers nothing", function()
		assertEq(#CastBar.legalPresentSpecies(HALIBUT_ONLY, realSpecies), 0)
		assertEq(CastBar.blindPick(HALIBUT_ONLY, realSpecies), nil)
	end)
end)

--=============================================================================
-- Selection validation
--=============================================================================

suite("CastBar.validateSelection — the pre-flight check", function()
	test("no ground chosen is refused honestly", function()
		local ok, answer = CastBar.validateSelection(
			nil,
			realSpecies,
			{ regionId = nil, speciesId = nil, depth = nil }
		)
		assertTrue(not ok)
		assertEq(answer, "choose a ground first")
	end)

	test("a blind selection resolves to a concrete species for the wire", function()
		local ok, answer = CastBar.validateSelection(
			GROUND,
			realSpecies,
			{ regionId = "g1", speciesId = nil, depth = nil }
		)
		assertTrue(ok)
		assertEq(answer, "herring")
	end)

	test("blind with nothing legal is refused", function()
		local ok, answer = CastBar.validateSelection(
			HALIBUT_ONLY,
			realSpecies,
			{ regionId = "g2", speciesId = nil, depth = nil }
		)
		assertTrue(not ok)
		assertEq(answer, "nothing here worth a cast")
	end)

	test("a species off the roster is refused", function()
		local ok, answer = CastBar.validateSelection(
			GROUND,
			realSpecies,
			{ regionId = "g1", speciesId = "unicorn", depth = nil }
		)
		assertTrue(not ok)
		assertEq(answer, "that fish is not in these waters")
	end)

	test("a blocked species surfaces its reason", function()
		local ok, answer = CastBar.validateSelection(
			GROUND,
			realSpecies,
			{ regionId = "g1", speciesId = "halibut", depth = 250 }
		)
		assertTrue(not ok)
		assertEq(answer, "lives deeper than this ground")
	end)

	test("a depth outside the window names the window", function()
		local ok, answer = CastBar.validateSelection(
			GROUND,
			realSpecies,
			{ regionId = "g1", speciesId = "rockfish", depth = 50 }
		)
		assertTrue(not ok)
		assertTrue(
			answer:find("25", 1, true) ~= nil and answer:find("40", 1, true) ~= nil,
			"reason should name the 25-40 m window, got: " .. answer
		)
	end)

	test("a depth inside the window passes", function()
		local ok, answer = CastBar.validateSelection(
			GROUND,
			realSpecies,
			{ regionId = "g1", speciesId = "rockfish", depth = 30 }
		)
		assertTrue(ok)
		assertEq(answer, "rockfish")
	end)

	test("a NaN depth is refused, never a crash", function()
		local ok, _ = CastBar.validateSelection(
			GROUND,
			realSpecies,
			{ regionId = "g1", speciesId = "rockfish", depth = 0 / 0 }
		)
		assertTrue(not ok)
	end)

	test("a nil depth passes — mid-band is the informed default Casting applies", function()
		local ok, answer = CastBar.validateSelection(
			GROUND,
			realSpecies,
			{ regionId = "g1", speciesId = "rockfish", depth = nil }
		)
		assertTrue(ok)
		assertEq(answer, "rockfish")
	end)
end)

--=============================================================================
-- The tide gate
--=============================================================================

suite("CastBar.hoursUntilAccessible — the tide gate on the real harmonics", function()
	test("deep water is open at every hour", function()
		for _, hour in { 0, 6.3, 12.7, 19.1, 23.9 } do
			assertEq(
				CastBar.hoursUntilAccessible(Tide, 200, hour, 26),
				0,
				"open at hour " .. tostring(hour)
			)
		end
	end)

	test("a shoal that is dry now opens later, and the stated hour is really open", function()
		-- a 2 m shoal against a 1.8 m draught is dry whenever the tide drops
		-- a fifth of a metre below MLLW — finding such an hour at all is part
		-- of the assertion: if the harmonics broke, this fails
		local dryHour: number? = nil
		local h = 0
		while h < 26 and dryHour == nil do
			if not Tide.accessAt(2.0, h) then
				dryHour = h
			end
			h += 0.25
		end
		assertTrue(
			dryHour ~= nil,
			"the mixed tide must go dry over a 2 m shoal sometime in a cycle"
		)

		local opensIn = CastBar.hoursUntilAccessible(Tide, 2.0, dryHour :: number, 26)
		assertTrue(opensIn ~= nil, "a real tide reopens every shoal within a cycle")
		assertTrue((opensIn :: number) > 0, "it was dry, so the opening must be in the future")
		assertTrue(
			Tide.accessAt(2.0, (dryHour :: number) + (opensIn :: number)),
			"the stated opening hour must really float the boat"
		)
	end)

	test("water that can never float the boat returns nil, not a hang", function()
		assertEq(CastBar.hoursUntilAccessible(Tide, -2.0, 3.0, 26), nil)
	end)

	test("already-accessible water returns zero", function()
		assertEq(CastBar.hoursUntilAccessible(Tide, 200, 7.7, 26), 0)
	end)
end)

suite("CastBar.opensText — when the ground opens", function()
	test("no opening in sight says so", function()
		assertEq(CastBar.opensText(nil, 10), "dry at every tide we can see")
	end)

	test("an opening within the resolution step reads as now", function()
		assertEq(CastBar.opensText(0.01, 10), "opening now")
	end)

	test("gives the clock face and the distance", function()
		local text = CastBar.opensText(2.5, 10)
		assertTrue(
			text:find("12:30", 1, true) ~= nil,
			"should carry the 12:30 opening, got: " .. text
		)
		assertTrue(text:find("2.5 h", 1, true) ~= nil, "should carry the distance, got: " .. text)
	end)

	test("wraps past midnight like the clock face does", function()
		local text = CastBar.opensText(1.0, 23.5)
		assertTrue(text:find("0:30", 1, true) ~= nil, "should wrap to 0:30, got: " .. text)
	end)
end)

--=============================================================================
-- The double-cast guard
--=============================================================================

suite("CastBar guard — one line in the water at a time", function()
	test("a fresh guard lets the first cast through", function()
		assertTrue(CastBar.guardTryBegin(CastBar.newGuard(), 10, 2))
	end)

	test("a second cast while one is running is refused (the double-cast guard)", function()
		local g = CastBar.newGuard()
		assertTrue(CastBar.guardTryBegin(g, 10, 2))
		assertTrue(not CastBar.guardTryBegin(g, 10.5, 2))
		assertTrue(not CastBar.guardTryBegin(g, 30, 2), "still busy much later")
	end)

	test("a fight that never asked the server owes no cooldown", function()
		local g = CastBar.newGuard()
		CastBar.guardTryBegin(g, 10, 2)
		CastBar.guardEnd(g)
		assertTrue(CastBar.guardTryBegin(g, 10.1, 2))
	end)

	test("the cooldown runs from the server's answer, boundary included", function()
		local g = CastBar.newGuard()
		CastBar.guardTryBegin(g, 100, 2)
		CastBar.guardResult(g, 200)
		assertTrue(not CastBar.guardTryBegin(g, 201, 2), "inside the cooldown")
		assertTrue(CastBar.guardTryBegin(g, 202, 2), "exactly cooldown seconds later is allowed")
	end)

	test("the wait watchdog fires only while busy AND waiting", function()
		local g = CastBar.newGuard()
		assertTrue(not CastBar.guardWaitExpired(g, 100, 16), "idle guard never expires")
		CastBar.guardTryBegin(g, 0, 2)
		assertTrue(not CastBar.guardWaitExpired(g, 100, 16), "busy but not waiting does not expire")
		g.waitingSince = 50
		assertTrue(not CastBar.guardWaitExpired(g, 66, 16))
		assertTrue(CastBar.guardWaitExpired(g, 66.1, 16))
	end)

	test("cooldownRemaining reads zero while busy and clamps at zero after", function()
		local g = CastBar.newGuard()
		CastBar.guardTryBegin(g, 0, 2)
		assertNear(CastBar.cooldownRemaining(g, 10, 2), 0, 1e-9, "busy shows no countdown")
		CastBar.guardEnd(g)
		assertNear(CastBar.cooldownRemaining(g, 10, 2), 0, 1e-9, "no result means no cooldown")
		CastBar.guardResult(g, 100)
		assertNear(CastBar.cooldownRemaining(g, 100.5, 2), 1.5, 1e-9)
		assertNear(CastBar.cooldownRemaining(g, 103, 2), 0, 1e-9)
	end)

	test("cooldownText formats honestly at both ends", function()
		assertEq(CastBar.cooldownText(0), "ready")
		assertEq(CastBar.cooldownText(0.04), "ready")
		assertEq(CastBar.cooldownText(1.23), "1.2s")
		assertEq(CastBar.cooldownText(2), "2.0s")
	end)
end)

--=============================================================================
-- Cross-file contracts the loop leans on
--=============================================================================

suite("the loop's contracts — these fail when the plumbing rots", function()
	test("Config.CAST_COOLDOWN exists as a usable number", function()
		-- this exact constant was once missing and every cast in the game
		-- threw `number < nil` server-side (PLAYLOOP defect 2)
		assertTrue(
			type(Config.CAST_COOLDOWN) == "number",
			"CAST_COOLDOWN must exist and be a number"
		)
		assertTrue(Config.CAST_COOLDOWN > 0, "a non-positive cooldown gates nothing")
		assertTrue(
			Config.CAST_COOLDOWN <= 60,
			"a minute-long cooldown would read as a broken button"
		)
	end)

	test("Tide.accessAt answers (boolean, number) across a cycle", function()
		for _, hour in { 0, 4.4, 9.1, 13.8, 18.2, 22.6 } do
			local ok, water = Tide.accessAt(10, hour)
			assertEq(type(ok), "boolean")
			assertEq(type(water), "number")
			assertTrue(not (water ~= water), "water depth must never be NaN")
		end
	end)

	test("the roster keeps the shape the picker assumes", function()
		local seen = {}
		for _, species in Species.list do
			assertTrue(type(species.id) == "string" and #species.id > 0, "every species has an id")
			assertTrue(seen[species.id] == nil, "duplicate species id: " .. species.id)
			seen[species.id] = true
			assertTrue(species.minDepth < species.maxDepth, species.id .. " has an inverted band")
			local d = species.harvestDifficulty
			assertTrue(
				d == math.floor(d) and d >= 1 and d <= 5,
				species.id .. " difficulty must be an integer 1..5"
			)
		end
	end)

	test(
		"an OceanSync-shaped payload flows through normalization into the selection rules",
		function()
			local rows = Ui.normalizeRegions({
				{
					id = "r1",
					name = "Test Ground",
					habitat = "reef",
					depth = 40,
					chartedDepth = 40,
					abundances = { rockfish = 0.5 },
					contested = {},
					species = { "rockfish" },
					accessible = true,
					waterDepth = 41.2,
					quality = 0.6,
					provenance = "measured",
				},
			})
			assertEq(#rows, 1)
			assertEq(rows[1].chartedDepth, 40)
			local ok, answer = CastBar.validateSelection(
				rows[1],
				realSpecies,
				{ regionId = "r1", speciesId = "rockfish", depth = 30 }
			)
			assertTrue(ok, answer)
			assertEq(answer, "rockfish")
		end
	)

	test("chartedDepth falls back to the unsounded depth", function()
		local rows = Ui.normalizeRegions({
			{
				id = "r2",
				name = "Seeded Ground",
				habitat = "sand",
				depth = 33,
				species = { "flounder" },
			},
		})
		assertEq(rows[1].chartedDepth, 33)
		local lo, hi = CastBar.depthWindow(rows[1].chartedDepth, realSpecies("flounder")) -- 15..150 m band
		assertEq(lo, 15)
		assertEq(hi, 33)
	end)
end)

--=============================================================================
-- End-to-end: the real client loop, executed
--
-- Everything above tests CastBar's rules as pure functions. The suite below
-- goes further: it loads the REAL CastBar.client.luau, Casting.client.luau
-- and HUD.client.luau under a fake client Roblox engine — the same
-- loadstring + setfenv technique tests/harness/Runner.luau uses for the
-- server, rebuilt here for the client surface (PlayerGui, UserInputService,
-- BindableEvents, UI instances) because the shared harness is server-only —
-- and drives one full loop:
--
--   OceanSync in -> ground/species/depth chosen through the actual UI
--   instances -> CAST pressed -> the fight won through the real input
--   signals -> the CastRequest payload captured off the fake remote ->
--   CastResult fired back -> the guard released.
--
-- The sources must be fed in as program arguments (tests/run.sh does this);
-- run plain, the suite reports itself skipped. It is one scenario, not
-- independent tests: each step builds on the state the previous one left.
--=============================================================================

-- selene does not model the main chunk's varargs, hence the allowance below.
-- selene: allow(undefined_variable)
local programArgs = { ... }
local clientSources: { [string]: string }? = nil
if #programArgs > 0 then
	if #programArgs % 2 ~= 0 then
		error("client harness: embedded sources are malformed (odd argument count)", 0)
	end
	local parsed: { [string]: string } = {}
	for i = 1, #programArgs, 2 do
		local path = programArgs[i]
		local contents = programArgs[i + 1]
		if type(path) ~= "string" or type(contents) ~= "string" then
			error("client harness: embedded sources are malformed at pair " .. tostring(i), 0)
		end
		parsed[path] = contents
	end
	clientSources = parsed
end

if clientSources == nil then
	print("")
	print(
		"(client end-to-end suite skipped — run via ./tests/run.sh, which feeds the sources in)"
	)
else
	local sources = clientSources :: { [string]: string }

	-- ---------------------------------------------------------------------------
	-- The fake client engine
	-- ---------------------------------------------------------------------------

	local function newSignal(name: string): any
		local signal = { __name = name, __handlers = {} }
		function signal:Connect(fn: any): any
			local handlers = self.__handlers
			table.insert(handlers, fn)
			local index = #handlers
			local conn = {}
			function conn.Disconnect()
				-- a tombstone, not a remove: Fire is walking this list
				handlers[index] = false
			end
			return conn
		end
		function signal:Fire(...: any)
			local args = { ... }
			for _, fn in self.__handlers do
				if type(fn) == "function" then
					fn(table.unpack(args))
				end
			end
		end
		return signal
	end

	-- signals every GuiObject-ish instance gets whether it needs them or not
	local INSTANCE_SIGNALS =
		{ "Activated", "InputBegan", "InputChanged", "InputEnded", "Destroying", "OnClientEvent" }

	local castRequests: { any } = {}

	local function newInstance(className: string): any
		local signals: { [string]: any } = {}
		for _, signalName in INSTANCE_SIGNALS do
			signals[signalName] = newSignal(className .. "." .. signalName)
		end
		local propertySignals: { [string]: any } = {}
		local attributes: { [string]: any } = {}

		local inst = {
			__class = className,
			__children = {},
			__signals = signals,
			Name = className,
			AbsoluteSize = { X = 390, Y = 844 },
			AbsolutePosition = { X = 0, Y = 0 },
		}

		local function detachFromParent()
			local old = rawget(inst, "__parent")
			if old ~= nil then
				for i, child in old.__children do
					if child == inst then
						table.remove(old.__children, i)
						break
					end
				end
			end
		end

		function inst:FindFirstChild(name: string): any
			for _, child in self.__children do
				if child.Name == name then
					return child
				end
			end
			return nil
		end
		function inst:WaitForChild(name: string, _timeout: number?): any
			-- no yielding in the fake engine: found now or never
			return self:FindFirstChild(name)
		end
		function inst:GetChildren(): { any }
			return table.clone(self.__children)
		end
		function inst:IsA(class: string): boolean
			return self.__class == class
		end
		function inst:Destroy()
			detachFromParent()
			rawset(self, "__parent", nil)
			self.__signals.Destroying:Fire()
		end
		function inst:GetAttribute(name: string): any
			return attributes[name]
		end
		function inst:SetAttribute(name: string, value: any)
			attributes[name] = value
			local signal = propertySignals["@attr"]
			if signal ~= nil then
				signal:Fire()
			end
		end
		function inst:GetAttributeChangedSignal(name: string): any
			local key = "@attr:" .. name
			if propertySignals[key] == nil then
				propertySignals[key] = newSignal(className .. "." .. name .. "Changed")
			end
			return propertySignals[key]
		end
		function inst:GetPropertyChangedSignal(name: string): any
			local key = "@prop:" .. name
			if propertySignals[key] == nil then
				propertySignals[key] = newSignal(className .. "." .. name .. "Changed")
			end
			return propertySignals[key]
		end
		function inst:FireServer(payload: any)
			table.insert(castRequests, payload)
		end

		setmetatable(inst, {
			__newindex = function(self, key, value)
				if key == "Parent" then
					detachFromParent()
					rawset(self, "__parent", value)
					if value ~= nil then
						table.insert(value.__children, self)
					end
				else
					rawset(self, key, value)
				end
			end,
			__index = function(self, key)
				if key == "Parent" then
					return rawget(self, "__parent")
				end
				local signal = signals[key]
				if signal ~= nil then
					return signal
				end
				-- dot-access resolves children, so `Shared.Types` and
				-- `script.Parent.Ui` work the way the real DataModel does
				return self:FindFirstChild(key)
			end,
		})

		if className == "BindableEvent" then
			rawset(inst, "Event", newSignal(className .. ".Event"))
			function inst:Fire(...: any)
				(self :: any).Event:Fire(...)
			end
		end

		return inst
	end

	local mockEnum = {
		Font = { GothamBold = "GothamBold", GothamMedium = "GothamMedium" },
		TextXAlignment = { Left = "Left", Center = "Center", Right = "Right" },
		TextYAlignment = { Center = "Center", Top = "Top", Bottom = "Bottom" },
		TextTruncate = { AtEnd = "AtEnd" },
		ScrollingDirection = { Y = "Y" },
		SortOrder = { LayoutOrder = "LayoutOrder" },
		AutomaticSize = { X = "X" },
		ApplyStrokeMode = { Border = "Border" },
		UserInputType = { Touch = "Touch", MouseButton1 = "MouseButton1" },
		KeyCode = { Space = "Space" },
	}

	-- pre-declared: the table's own methods close over it (a `local x = { f =
	-- function() x end }` initializer would capture a nil global instead)
	local mockUDim2
	mockUDim2 = {
		new = function(xs: number, xo: number, ys: number, yo: number)
			return { X = { Scale = xs, Offset = xo }, Y = { Scale = ys, Offset = yo } }
		end,
		fromOffset = function(x: number, y: number)
			return mockUDim2.new(0, x, 0, y)
		end,
		fromScale = function(x: number, y: number)
			return mockUDim2.new(x, 0, y, 0)
		end,
	}

	local delayed: { any } = {}
	local mockTask = {
		spawn = function(fn: any, ...: any)
			fn(...)
		end,
		wait = function()
			return 0
		end,
		defer = function(fn: any, ...: any)
			fn(...)
		end,
		delay = function(_seconds: number, fn: any)
			table.insert(delayed, fn)
		end,
	}
	local function flushDelayed()
		local queue = delayed
		delayed = {}
		for _, fn in queue do
			fn()
		end
	end

	-- the fake DataModel: PlayerGui with a LocalPlayer, ReplicatedStorage with
	-- the Shared tree and the Remotes folder the panels wait on
	local playerGui = newInstance("PlayerGui")
	playerGui.Name = "PlayerGui"

	local player = newInstance("Player")
	player.Name = "LocalPlayer"
	playerGui.Parent = player

	local replicatedStorage = newInstance("ReplicatedStorage")
	replicatedStorage.Name = "ReplicatedStorage"

	local remotesFolder = newInstance("Folder")
	remotesFolder.Name = "Remotes"
	remotesFolder.Parent = replicatedStorage
	local function newRemote(name: string)
		local remote = newInstance("RemoteEvent")
		remote.Name = name
		remote.Parent = remotesFolder
		return remote
	end
	local oceanSyncRemote = newRemote("OceanSync")
	local castResultRemote = newRemote("CastResult")
	local _castRequestRemote = newRemote("CastRequest")

	local inputBegan = newSignal("UserInputService.InputBegan")
	local inputEnded = newSignal("UserInputService.InputEnded")
	local userInputService = { InputBegan = inputBegan, InputEnded = inputEnded }
	local heartbeat = newSignal("RunService.Heartbeat")

	local services = {
		Players = { LocalPlayer = player },
		ReplicatedStorage = replicatedStorage,
		RunService = { Heartbeat = heartbeat },
		UserInputService = userInputService,
	}
	local mockGame = {}
	function mockGame:GetService(name: string): any
		local service = services[name]
		if service == nil then
			error("client harness: game:GetService(" .. tostring(name) .. ") is not stubbed", 0)
		end
		return service
	end

	-- ---------------------------------------------------------------------------
	-- Module loading (paths in, fake instances out)
	-- ---------------------------------------------------------------------------

	local moduleNodes: { [string]: any } = {}
	local moduleCache: { [string]: any } = {}

	local sharedFolder = newInstance("Folder")
	sharedFolder.Name = "Shared"
	sharedFolder.Parent = replicatedStorage
	local clientFolder = newInstance("Folder")
	clientFolder.Name = "Client"

	local function nodeFor(path: string): any
		local existing = moduleNodes[path]
		if existing ~= nil then
			return existing
		end
		-- Lua patterns have no alternation, so strip each prefix explicitly
		local base = string.gsub(path, "^src/Shared/", "")
		base = string.gsub(base, "^src/Client/", "")
		base = string.gsub(base, "%.luau$", "")
		base = string.gsub(base, "%.client$", "")
		local segments = string.split(base, "/")
		local parent = if string.sub(path, 1, 10) == "src/Shared"
			then sharedFolder
			else clientFolder
		for i = 1, #segments - 1 do
			local folder = parent:FindFirstChild(segments[i])
			if folder == nil then
				folder = newInstance("Folder")
				folder.Name = segments[i]
				folder.Parent = parent
			end
			parent = folder
		end
		local node = newInstance("ModuleScript")
		node.Name = segments[#segments]
		rawset(node, "__path", path)
		node.Parent = parent
		moduleNodes[path] = node
		return node
	end

	-- every source gets its fake instance up front, before anything loads:
	-- `require(Shared.Types)` must find the node even though Types itself has
	-- not been loaded yet (the server Runner does the same)
	for path in sources do
		nodeFor(path)
	end

	local function resolveRelative(fromPath: string, ref: string): string
		local dir = string.gsub(fromPath, "/[^/]*$", "")
		local stack = string.split(dir, "/")
		for _, seg in string.split(ref, "/") do
			if seg == ".." then
				table.remove(stack)
			elseif seg ~= "." and seg ~= "" then
				table.insert(stack, seg)
			end
		end
		local resolved = table.concat(stack, "/")
		if sources[resolved .. ".luau"] ~= nil then
			return resolved .. ".luau"
		end
		error("client harness: cannot resolve '" .. ref .. "' relative to " .. fromPath, 0)
	end

	local function loadModule(path: string): any
		local cached = moduleCache[path]
		if cached ~= nil then
			return cached
		end
		local source = sources[path]
		if source == nil then
			error("client harness: no embedded source for " .. path, 0)
		end
		local chunk, parseErr = loadstring(source, "=" .. path)
		if chunk == nil then
			error("client harness: " .. path .. " does not parse: " .. tostring(parseErr), 0)
		end
		local modulePath = path
		setfenv(
			chunk,
			setmetatable({
				script = nodeFor(modulePath),
				require = function(ref: any)
					if type(ref) == "table" and rawget(ref, "__path") ~= nil then
						return loadModule(rawget(ref, "__path") :: string)
					elseif type(ref) == "string" then
						return loadModule(resolveRelative(modulePath, ref))
					end
					error(
						"client harness require: expected a module instance or a relative path",
						0
					)
				end,
				game = mockGame,
				Instance = { new = newInstance },
				Vector2 = {
					new = function(x: number, y: number)
						return { X = x, Y = y }
					end,
				},
				UDim = {
					new = function(s: number, o: number)
						return { Scale = s, Offset = o }
					end,
				},
				UDim2 = mockUDim2,
				Color3 = {
					fromRGB = function(r: number, g: number, b: number)
						return { R = r, G = g, B = b }
					end,
					new = function(r: number, g: number, b: number)
						return { R = r, G = g, B = b }
					end,
				},
				Enum = mockEnum,
				task = mockTask,
				print = print,
				warn = warn,
			}, { __index = getfenv(1) })
		)
		local module = chunk()
		moduleCache[path] = module
		return module
	end

	-- ---------------------------------------------------------------------------
	-- UI spelunking helpers
	-- ---------------------------------------------------------------------------

	local function findDescendant(inst: any, predicate: (any) -> boolean): any
		if predicate(inst) then
			return inst
		end
		for _, child in inst:GetChildren() do
			local found = findDescendant(child, predicate)
			if found ~= nil then
				return found
			end
		end
		return nil
	end

	local function byName(name: string)
		return function(inst: any)
			return inst.Name == name
		end
	end

	local function labelWithText(root: any, text: string): any
		return findDescendant(root, function(inst)
			return inst.__class == "TextLabel" and inst.Text == text
		end)
	end

	-- ---------------------------------------------------------------------------
	-- The scenario
	-- ---------------------------------------------------------------------------

	local CastingModule, castBarGui, hudGui, castingInst

	suite("the loop, executed — real sources under a fake client engine", function()
		test("the client scripts boot and publish the rendezvous", function()
			-- Casting first: its boot block creates the bus the others wait on
			CastingModule = loadModule("src/Client/Casting.client.luau")
			castingInst = CastingModule.get()
			assertTrue(castingInst ~= nil, "Casting.start() must have run at boot")
			assertTrue(
				playerGui:FindFirstChild("SlackWaterCastBus") ~= nil,
				"the CastBus BindableEvent must exist in PlayerGui"
			)

			loadModule("src/Client/CastBar.client.luau")
			loadModule("src/Client/HUD.client.luau")

			castBarGui = playerGui:FindFirstChild("SlackWaterCastBar")
			hudGui = playerGui:FindFirstChild("SlackWaterHUD")
			assertTrue(castBarGui ~= nil, "CastBar mounted its ScreenGui")
			assertTrue(hudGui ~= nil, "HUD mounted its ScreenGui")

			-- test pacing: the real 2 s cooldown would make the multi-cast
			-- scenario sleep between casts. This zeroes the loaded copy's
			-- CLIENT-side pacing only — the server keeps its own real gate,
			-- and nothing here asserts cooldown behaviour (the pure suite
			-- above does, against the real Config).
			local loadedConfig = loadModule("src/Shared/Config.luau")
			loadedConfig.CAST_COOLDOWN = 0
		end)

		test("an OceanSync populates the rig sheet through the real remote path", function()
			oceanSyncRemote.__signals.OnClientEvent:Fire({
				month = 1,
				day = 2,
				tick = 5,
				shared = false,
				tide = { hour = 6.0 },
				chartCoverage = 0.5,
				regions = {
					{
						id = "r1",
						name = "Test Ground",
						habitat = "reef",
						depth = 40,
						chartedDepth = 40,
						abundances = { rockfish = 0.6 },
						contested = {},
						species = { "rockfish" },
						accessible = true,
						waterDepth = 41.2,
						quality = 0.7,
						provenance = "measured",
					},
				},
			})

			-- open the picker through its real button
			local summary = findDescendant(castBarGui, byName("Summary"))
			assertTrue(summary ~= nil, "the rig summary button exists")
			summary.__signals.Activated:Fire()

			local groundRow = findDescendant(castBarGui, byName("r1"))
			assertTrue(groundRow ~= nil, "the synced ground rendered as a selectable row")
		end)

		test("choosing a ground publishes the selection the HUD renders", function()
			local groundRow = findDescendant(castBarGui, byName("r1"))
			groundRow.__signals.Activated:Fire()

			-- let the HUD's render loop run past its pulse cadence
			for _ = 1, 6 do
				heartbeat:Fire(0.3)
			end
			assertTrue(
				labelWithText(hudGui, "bound for Test Ground") ~= nil,
				"the HUD should show where the player is rigged for"
			)
		end)

		test("species and depth choose through the real rows and slider", function()
			local speciesRow = findDescendant(castBarGui, byName("rockfish"))
			assertTrue(speciesRow ~= nil, "the present species rendered as a row")
			speciesRow.__signals.Activated:Fire()

			local track = findDescendant(castBarGui, byName("DepthTrack"))
			assertTrue(track ~= nil, "the depth slider rendered")
			-- track defaults: AbsolutePosition.X = 0, AbsoluteSize.X = 390.
			-- x = 117 -> fraction 0.3 -> 25 + 0.3*15 = 29.5 -> snaps to 30 m
			track.__signals.InputBegan:Fire({
				UserInputType = mockEnum.UserInputType.MouseButton1,
				Position = { X = 117, Y = 0 },
			})

			local valueLabel = findDescendant(castBarGui, function(inst)
				return inst.__class == "TextLabel" and inst.Text == "30 m"
			end)
			assertTrue(valueLabel ~= nil, "the slider should read the snapped depth")
		end)

		test("CAST drives a real fight; a second press mid-fight is refused", function()
			local castButton = findDescendant(castBarGui, byName("Cast"))
			castButton.__signals.Activated:Fire()
			assertEq(castingInst.state, "fighting", "the bus must have started the minigame")

			-- mid-fight: a second press must not start a second cast
			castButton.__signals.Activated:Fire()
			assertEq(#castRequests, 0, "the refused press must not reach the remote")
			local status = findDescendant(castBarGui, byName("Status"))
			assertEq(status.Text, "the line is already out", "the refusal says why")

			-- fight policy: hold while the tension is under 70, give above it.
			-- This cannot snap the line and always lands eventually, which is
			-- the point: we are testing the loop, not the difficulty tuning.
			local held = false
			local steps = 0
			while castingInst.state == "fighting" and steps < 4000 do
				local wantHold = castingInst.tension < 70
				if wantHold ~= held then
					held = wantHold
					if held then
						inputBegan:Fire({ UserInputType = mockEnum.UserInputType.Touch })
					else
						inputEnded:Fire({ UserInputType = mockEnum.UserInputType.Touch })
					end
				end
				heartbeat:Fire(0.05)
				steps += 1
			end
			assertEq(
				castingInst.state,
				"waiting",
				"the fight must resolve to the server round trip"
			)
			assertTrue(steps < 4000, "the fight must end, not orbit")

			assertEq(#castRequests, 1, "exactly one CastRequest reached the remote")
			local request = castRequests[1]
			assertEq(request.regionId, "r1")
			assertEq(request.speciesId, "rockfish")
			assertEq(request.effort, 0, "the client does not claim effort; the server derives it")
			assertEq(request.depth, 30, "the slider depth travels verbatim")
			assertTrue(
				type(request.performance) == "number"
					and request.performance >= 0
					and request.performance <= 1,
				"performance is the fight's 0..1 score"
			)

			-- abandon the unanswered resolve: reeling in from "waiting" ends
			-- the cast without a server round trip
			local giveUp = findDescendant(castBarGui, byName("GiveUp"))
			giveUp.__signals.Activated:Fire()
			assertEq(castingInst.state, "idle", "aborting a waiting cast returns to idle")
			assertEq(#castRequests, 1, "an abandoned resolve never asks the server")
		end)

		test("giving up a live fight loses it without asking the server", function()
			local castButton = findDescendant(castBarGui, byName("Cast"))
			castButton.__signals.Activated:Fire()
			assertEq(castingInst.state, "fighting")

			local giveUp = findDescendant(castBarGui, byName("GiveUp"))
			giveUp.__signals.Activated:Fire()
			assertEq(castingInst.state, "lost")
			local status = findDescendant(castBarGui, byName("Status"))
			assertEq(status.Text, "You reeled in.", "the loss surfaces its reason")
			assertEq(#castRequests, 1, "an aborted fight never asks the server")
		end)

		test("the server's result lands the fish and frees the guard", function()
			local castButton = findDescendant(castBarGui, byName("Cast"))
			castButton.__signals.Activated:Fire()
			assertEq(castingInst.state, "fighting")

			local held = false
			local steps = 0
			while castingInst.state == "fighting" and steps < 4000 do
				local wantHold = castingInst.tension < 70
				if wantHold ~= held then
					held = wantHold
					if held then
						inputBegan:Fire({ UserInputType = mockEnum.UserInputType.Touch })
					else
						inputEnded:Fire({ UserInputType = mockEnum.UserInputType.Touch })
					end
				end
				heartbeat:Fire(0.05)
				steps += 1
			end
			assertEq(castingInst.state, "waiting")

			castResultRemote.__signals.OnClientEvent:Fire({
				ok = true,
				speciesId = "rockfish",
				regionId = "r1",
				yielded = 3,
				remaining = 297,
				abundanceBefore = 0.6,
				abundanceAfter = 0.59,
				depleted = false,
				contested = false,
				weightKg = 4.2,
				value = 123,
				rare = false,
				inRun = false,
				tideQuality = 0.9,
			})

			assertEq(castingInst.state, "landed")
			local status = findDescendant(castBarGui, byName("Status"))
			assertTrue(
				string.find(status.Text, "landed", 1, true) ~= nil
					and string.find(status.Text, "123", 1, true) ~= nil,
				"the bar should echo the landed value, got: " .. tostring(status.Text)
			)
			assertTrue(
				string.find(status.Text, "slack water", 1, true) ~= nil,
				"a high server-sent tideQuality should be called out, got: "
					.. tostring(status.Text)
			)
		end)

		test("a resolve the server never answers times out honestly", function()
			local castButton = findDescendant(castBarGui, byName("Cast"))
			castButton.__signals.Activated:Fire()
			local held = false
			local steps = 0
			while castingInst.state == "fighting" and steps < 4000 do
				local wantHold = castingInst.tension < 70
				if wantHold ~= held then
					held = wantHold
					if held then
						inputBegan:Fire({ UserInputType = mockEnum.UserInputType.Touch })
					else
						inputEnded:Fire({ UserInputType = mockEnum.UserInputType.Touch })
					end
				end
				heartbeat:Fire(0.05)
				steps += 1
			end
			assertEq(
				castingInst.state,
				"waiting",
				"landed, now waiting on a server that will not answer"
			)

			-- Casting's own resolve timeout is a task.delay; run it due
			flushDelayed()

			assertEq(castingInst.state, "lost", "the timeout must end the cast")
			local status = findDescendant(castBarGui, byName("Status"))
			assertTrue(
				string.find(status.Text, "never resolved", 1, true) ~= nil,
				"the timeout should say what happened, got: " .. tostring(status.Text)
			)

			-- and the guard is free again: a fresh press starts a fresh fight
			castButton.__signals.Activated:Fire()
			assertEq(castingInst.state, "fighting", "the timeout must not lock the verb")
			local giveUp = findDescendant(castBarGui, byName("GiveUp"))
			giveUp.__signals.Activated:Fire()
		end)
	end)
end

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
