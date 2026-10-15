--!strict
--[[
	HUD — the persistent top-left readout.

	Region, tide phase, calendar, and the session's running total. Everything
	on it either came from the server (OceanSync, CastResult) or is derived
	from the Shared Tide module purely for display. The client never decides
	what anything is worth — house rule 2.

	Before the first OceanSync the HUD shows a "reading the chart" state rather
	than zeroes or an error: a fishing game that opens with an empty box reads
	as broken, and the first sync is only a few seconds away. If no sync ever
	comes the breathing stops for an explicit "no ocean" line, and if syncs
	stop arriving the panel says so and blanks its numbers rather than
	presenting a stale tide as live.
]]

-- Dual-target require, same idiom as src/Shared: `script` resolves in Studio,
-- the relative path resolves under the standalone interpreter.
local Ui = require(script and script.Parent.Ui or "./Ui")

-- One game hour per 20 s: OceanService advances its hour by 1.0 per
-- _TICK_INTERVAL tick. Only the fallback rate; the clock measures the real
-- rate from consecutive server tide hours after the second sync.
local DEFAULT_HOURS_PER_SECOND = 1 / 20

-- The server broadcasts every 5 s (OceanService._SYNC_INTERVAL). Past two
-- missed broadcasts the data on screen is stale and must not read as live;
-- past CONNECT_FAIL_AFTER with no sync at all there is no ocean to read.
local OCEAN_STALE_AFTER = 12
local CONNECT_FAIL_AFTER = 30

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
	local clock = Ui.newClock(DEFAULT_HOURS_PER_SECOND)

	-- ---------------------------------------------------------------------------
	-- State. Everything here is a copy of what the server sent, plus the id of
	-- the ground the player last cast at — there is no server-side notion of
	-- "where the boat is" yet, so the last cast is the honest answer.
	-- ---------------------------------------------------------------------------

	local regionNames: { [string]: string } = {}
	local currentRegionId: string? = nil
	local earnedTotal = 0
	local catchCount = 0
	local isSharedOcean = false
	local lastOceanSyncAt = 0
	local startedAt = os.clock()

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

	-- whether this server is describing the shared ocean or its own; the
	-- server sends the claim, the HUD merely repeats it
	local sharedLabel = Ui.label(panel, {
		text = "",
		size = UDim2.fromOffset(110, 12),
		pos = UDim2.new(1, -12, 1, -6),
		anchor = Vector2.new(1, 1),
		color = "teal",
		textSize = 9,
		font = Enum.Font.GothamBold,
		xalign = Enum.TextXAlignment.Right,
		visible = false,
	})

	-- ---------------------------------------------------------------------------
	-- Server payloads
	-- ---------------------------------------------------------------------------

	local function onOceanSync(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		local p = payload :: Types.OceanSyncPayload
		lastOceanSyncAt = os.clock()

		-- the server's own tide hour is the authority; a tick-derived hour
		-- once ran the client tide at twice the server's speed
		local tideHour = if typeof(p.tide) == "table" then (p.tide :: any).hour else nil
		Ui.clockSync(clock, p.month, p.day, p.tick, tideHour)

		isSharedOcean = (p :: any).shared == true

		regionNames = {}
		for _, region in Ui.normalizeRegions(p.regions) do
			regionNames[region.id] = region.name
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
		if p.ok == true then
			earnedTotal += Ui.tonum(p.value, 0)
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

		-- The ocean must never silently read as live when it is not answering.
		-- Cold start and a dead feed are both legible states, and no number
		-- stays on screen that the server is not currently vouching for.
		if not clock.synced then
			slackChip.Visible = false
			sharedLabel.Visible = false
			dateLabel.Text = "—"
			phaseLabel.Text = "—"
			regionLabel.TextColor3 = Ui.color("danger")
			regionLabel.TextTransparency = 0
			if os.clock() - startedAt > CONNECT_FAIL_AFTER then
				regionLabel.Text = "no ocean — server not answering"
			else
				regionLabel.Text = "Reading the chart"
				-- gentle breathing dot rather than a spinner: the sea is slow
				regionLabel.TextTransparency = 0.45 + 0.3 * math.abs(math.sin(os.clock() * 2.5))
			end
			return
		end
		if os.clock() - lastOceanSyncAt > OCEAN_STALE_AFTER then
			regionLabel.Text = "lost the ocean — waiting on the server"
			regionLabel.TextColor3 = Ui.color("amber")
			regionLabel.TextTransparency = 0
			dateLabel.Text = "—"
			phaseLabel.Text = "—"
			slackChip.Visible = false
			sharedLabel.Visible = false
			return
		end

		regionLabel.TextTransparency = 0

		local monthName = Ui.MONTHS[clock.month] or "?"
		dateLabel.Text =
			string.format("%s · day %d/%d", monthName, clock.day, Config.DAYS_PER_MONTH)

		if currentRegionId then
			regionLabel.Text = regionNames[currentRegionId] or currentRegionId
			regionLabel.TextColor3 = Ui.color("text")
		else
			regionLabel.Text = "no ground chosen"
			regionLabel.TextColor3 = Ui.color("dim")
		end

		if isSharedOcean then
			sharedLabel.Text = "SHARED OCEAN"
			sharedLabel.TextColor3 = Ui.color("teal")
		else
			sharedLabel.Text = "LOCAL WATER"
			sharedLabel.TextColor3 = Ui.color("dim")
		end
		sharedLabel.Visible = true

		if phaseClock >= PHASE_SECONDS then
			phaseClock = 0
			local hour = Ui.clockHour(clock)
			local phase = Tide.phaseName(hour)
			phaseLabel.Text = (phase:sub(1, 1):upper() .. phase:sub(2))
				.. " · "
				.. Ui.clockFace(hour)
			local slack = Tide.isSlack(hour)
			phaseLabel.TextColor3 = if slack then Ui.color("gold") else Ui.color("dim")
			slackChip.Visible = slack
		end

		if catchCount > 0 then
			earnedLabel.Text = string.format(
				'🐟 %d fish · <font color="#f0c24f">%s</font>',
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
