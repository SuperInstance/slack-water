--!strict
--[[
	HUD — the persistent top-left readout.

	Region, tide phase, calendar, and the session's running total. Everything
	on it either came from the server (OceanSync, CastResult) or is derived
	from the Shared Tide module purely for display. The client never decides
	what anything is worth — house rule 2.

	Before the first OceanSync the HUD shows a "reading the chart" state rather
	than zeroes or an error: a fishing game that opens with an empty box reads
	as broken, and the first sync is only a few seconds away.
]]

-- Dual-target require, same idiom as src/Shared: `script` resolves in Studio,
-- the relative path resolves under the standalone interpreter.
local Ui = require(script and script.Parent.Ui or "./Ui")

-- 20 s matches OceanService._TICK_INTERVAL; the clock replaces it with a
-- measured rate after two syncs.
local DEFAULT_SECONDS_PER_TICK = 20

local PULSE_SECONDS = 0.25 -- UI refresh cadence
local PHASE_SECONDS = 1 -- tide phase text refresh (phaseName is the costly call)

local function main(): ()
	local Players = game:GetService("Players")
	local RunService = game:GetService("RunService")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")

	local player = Players.LocalPlayer
	if not player then
		return
	end
	local playerGui = player:WaitForChild("PlayerGui")

	local Shared = ReplicatedStorage:WaitForChild("Shared")
	local Types = require(Shared:WaitForChild("Types") :: ModuleScript)
	local Tide = require(Shared:WaitForChild("Tide") :: ModuleScript)
	local Config = require(Shared:WaitForChild("Config") :: ModuleScript)

	local connections: Ui.Conns = {}
	local clock = Ui.newClock(Config.HOURS_PER_DAY / Config.TICKS_PER_DAY, DEFAULT_SECONDS_PER_TICK)

	-- ---------------------------------------------------------------------------
	-- State. Everything here is a copy of what the server sent, plus the id of
	-- the ground the player last cast at — there is no server-side notion of
	-- "where the boat is" yet, so the last cast is the honest answer.
	-- ---------------------------------------------------------------------------

	local regionNames: { [string]: string } = {}
	local currentRegionId: string? = nil
	local earnedTotal = 0
	local catchCount = 0

	-- ---------------------------------------------------------------------------
	-- Build
	-- ---------------------------------------------------------------------------

	local gui = Ui.screenGui("SlackWaterHUD", 1, playerGui)
	local root = Ui.frame(gui, { name = "Root", transparency = 1 })
	Ui.autoScale(root)

	local panel = Ui.frame(root, {
		name = "Panel",
		size = UDim2.fromOffset(300, 80),
		pos = UDim2.fromOffset(12, 12),
		color = "panel",
		transparency = 0.08,
		corner = 10,
		strokeColor = "deep",
		strokeWidth = 1,
	})

	local regionLabel = Ui.label(panel, {
		text = "Reading the chart",
		size = UDim2.new(1, -96, 0, 20),
		pos = UDim2.fromOffset(12, 8),
		textSize = 16,
		font = Enum.Font.GothamBold,
	})

	local dateLabel = Ui.label(panel, {
		text = "—",
		size = UDim2.fromOffset(84, 16),
		pos = UDim2.new(1, -12, 0, 10),
		anchor = Vector2.new(1, 0),
		color = "dim",
		textSize = 11,
		xalign = Enum.TextXAlignment.Right,
	})

	local phaseLabel = Ui.label(panel, {
		text = "—",
		size = UDim2.new(1, -104, 0, 16),
		pos = UDim2.fromOffset(12, 32),
		color = "dim",
		textSize = 13,
	})

	local slackChip = Ui.label(panel, {
		text = "SLACK NOW",
		size = UDim2.fromOffset(84, 14),
		pos = UDim2.new(1, -12, 0, 34),
		anchor = Vector2.new(1, 0),
		color = "gold",
		textSize = 11,
		font = Enum.Font.GothamBold,
		xalign = Enum.TextXAlignment.Right,
		visible = false,
	})

	local earnedLabel = Ui.label(panel, {
		text = "no catch yet",
		size = UDim2.new(1, -24, 0, 16),
		pos = UDim2.fromOffset(12, 54),
		color = "dim",
		textSize = 13,
		rich = true,
	})

	-- ---------------------------------------------------------------------------
	-- Server payloads
	-- ---------------------------------------------------------------------------

	local function onOceanSync(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		local p = payload :: Types.OceanSyncPayload
		Ui.clockSync(clock, p.month or 1, p.day or 1, p.tick or 0)

		regionNames = {}
		local regions = p.regions or {}
		for _, region in regions do
			if type(region.id) == "string" then
				regionNames[region.id] = tostring(region.name)
			end
		end
	end

	local function onCastResult(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		local p = payload :: Types.CastResultPayload
		-- even a failed cast tells us where the player is working
		if type(p.regionId) == "string" and p.regionId ~= "" then
			currentRegionId = p.regionId
		end
		if p.ok == true and type(p.value) == "number" then
			earnedTotal += p.value
			catchCount += 1
		end
	end

	-- Remotes appear when the server builds them. Retry gently instead of
	-- yielding forever so a missing remote leaves the "reading the chart"
	-- state rather than a stuck coroutine.
	task.spawn(function()
		for _ = 1, 15 do
			local oceanSync = Ui.awaitRemote(Types.REMOTE_FOLDER, Types.OceanSync, 10)
			if oceanSync then
				Ui.connect(connections, oceanSync.OnClientEvent, onOceanSync)
				break
			end
			task.wait(2)
		end
	end)
	task.spawn(function()
		for _ = 1, 15 do
			local castResult = Ui.awaitRemote(Types.REMOTE_FOLDER, Types.CastResult, 10)
			if castResult then
				Ui.connect(connections, castResult.OnClientEvent, onCastResult)
				break
			end
			task.wait(2)
		end
	end)

	-- ---------------------------------------------------------------------------
	-- Render loop
	--
	-- One Heartbeat with accumulators: text at 4 Hz, tide phase at 1 Hz (it
	-- calls Tide.nextEvents internally, which is the expensive part), pulse
	-- only while unsynced. No waits anywhere.
	-- ---------------------------------------------------------------------------

	local uiClock = 0
	local phaseClock = 0

	local heartbeat = RunService.Heartbeat:Connect(function(dt: number)
		uiClock += dt
		phaseClock += dt
		if uiClock < PULSE_SECONDS then
			return
		end
		uiClock = 0

		if not clock.synced then
			-- gentle breathing dot rather than a spinner: the sea is slow
			regionLabel.TextTransparency = 0.45 + 0.3 * math.abs(math.sin(os.clock() * 2.5))
			return
		end
		regionLabel.TextTransparency = 0

		local monthName = Ui.MONTHS[clock.month] or "?"
		dateLabel.Text = string.format("%s · day %d/%d", monthName, clock.day, Config.DAYS_PER_MONTH)

		if currentRegionId then
			regionLabel.Text = regionNames[currentRegionId] or currentRegionId
			regionLabel.TextColor3 = Ui.color("text")
		else
			regionLabel.Text = "no ground chosen"
			regionLabel.TextColor3 = Ui.color("dim")
		end

		if phaseClock >= PHASE_SECONDS then
			phaseClock = 0
			local hour = Ui.clockHour(clock)
			local phase = Tide.phaseName(hour)
			phaseLabel.Text = (phase:sub(1, 1):upper() .. phase:sub(2))
				.. " · " .. Ui.clockFace(hour)
			local slack = Tide.isSlack(hour)
			phaseLabel.TextColor3 = if slack then Ui.color("gold") else Ui.color("dim")
			slackChip.Visible = slack
		end

		if catchCount > 0 then
			earnedLabel.Text = string.format(
				"🐟 %d fish · <font color=\"#f0c24f\">%s</font>",
				catchCount,
				Ui.formatInt(earnedTotal)
			)
		end
	end)
	table.insert(connections, heartbeat)

	-- PlayerGui clears on teardown; follow it down and stop everything this
	-- script started (the "disconnect cleanly" house rule).
	Ui.connect(connections, gui.Destroying, function()
		Ui.disconnectAll(connections)
	end)
end

-- The standalone `luau` interpreter has no Roblox runtime; bail before any
-- global is touched so `luau <file>` is a clean syntax gate (scripts-check.sh).
if game == nil then
	return
end

main()
