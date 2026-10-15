--!strict
--[[
	TideStrip — the game's rhythm, at a glance.

	A small horizontal tide curve for the next twelve game hours with a marker
	for "now", plus the next slack-water window and a real-time countdown to
	it. Slack water is what the game is named for: it is the interval when a
	small boat can safely work shallow ground, so this strip is the thing
	players plan their session around.

	The curve is computed with the Shared Tide module — pure functions, no
	state — for DISPLAY ONLY. The server remains the only authority on time
	(see Ui.GameClock); this script never feeds a tide number back into
	anything.

	Readability rules for a 390x844 phone:
	- two hours of lookback so "now" sits inside the curve, not on its edge —
	  a skipper wants to see where the water just was
	- slack stretches of the curve are gold, everything else is water blue;
	  colour carries the meaning, no legend needed
	- the countdown is in REAL seconds. "Slack in 0:40" must mean forty real
	  seconds or it is useless.
]]

local Ui = require(script and script.Parent.Ui or "./Ui")

local DEFAULT_SECONDS_PER_TICK = 20 -- matches OceanService._TICK_INTERVAL

local LOOKBACK_HOURS = 2
local FORWARD_HOURS = 12
local WINDOW_HOURS = LOOKBACK_HOURS + FORWARD_HOURS
local BAR_COUNT = 42
local SCAN_STEP = 0.05 -- game hours between slack-window scan samples
local BARS_REFRESH = 0.25
local SLOW_REFRESH = 1 -- slack window + high/low water (the pricier scans)

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
	-- Build
	-- ---------------------------------------------------------------------------

	local gui = Ui.screenGui("SlackWaterTideStrip", 1, playerGui)
	local root = Ui.frame(gui, { name = "Root", transparency = 1 })
	Ui.autoScale(root)

	-- sits directly under the HUD (12 + 80 + 8 = 100 logical px)
	local panel = Ui.frame(root, {
		name = "Panel",
		size = UDim2.new(1, -24, 0, 96),
		pos = UDim2.fromOffset(12, 100),
		color = "panel",
		transparency = 0.08,
		corner = 10,
		strokeColor = "deep",
		strokeWidth = 1,
	})

	local plot = Ui.frame(panel, {
		name = "Plot",
		size = UDim2.new(0.64, -14, 1, -36),
		pos = UDim2.fromOffset(10, 6),
		transparency = 1,
	})

	-- 42 bars, reused every refresh — never rebuilt, so the strip costs the
	-- same after an hour of play as on frame one
	local bars: { Frame } = {}
	for i = 1, BAR_COUNT do
		local bar = Ui.frame(plot, {
			name = "Bar",
			size = UDim2.fromScale(0.7 / BAR_COUNT, 0.5),
			pos = UDim2.fromScale((i - 0.5) / BAR_COUNT, 1),
			anchor = Vector2.new(0.5, 1),
			color = "water",
			transparency = 0.25,
			corner = 1,
		})
		bars[i] = bar
	end

	-- the "now" marker: a hair to the right of centre-left, exactly where the
	-- lookback ends
	local nowLine = Ui.frame(plot, {
		name = "Now",
		size = UDim2.new(0, 2, 1, 0),
		pos = UDim2.fromScale(LOOKBACK_HOURS / WINDOW_HOURS, 0),
		anchor = Vector2.new(0.5, 0),
		color = "white",
		transparency = 0.25,
		zindex = 3,
	})

	-- relative hour labels under the curve; "now" is gold and bold
	local axis = Ui.frame(panel, {
		name = "Axis",
		size = UDim2.new(0.64, -14, 0, 16),
		pos = UDim2.new(0, 10, 1, -20),
		transparency = 1,
	})
	local marks: { { fraction: number, text: string, strong: boolean } } = {
		{ fraction = 0, text = "-2h", strong = false },
		{ fraction = LOOKBACK_HOURS / WINDOW_HOURS, text = "now", strong = true },
		{ fraction = 6 / WINDOW_HOURS, text = "+4h", strong = false },
		{ fraction = 10 / WINDOW_HOURS, text = "+8h", strong = false },
		{ fraction = 1, text = "+12h", strong = false },
	}
	for _, mark in marks do
		local xalign = Enum.TextXAlignment.Center
		local xPos = UDim2.fromScale(mark.fraction, 0)
		if mark.fraction == 0 then
			xalign = Enum.TextXAlignment.Left
		elseif mark.fraction == 1 then
			xalign = Enum.TextXAlignment.Right
		end
		Ui.label(axis, {
			text = mark.text,
			size = UDim2.new(0, 44, 1, 0),
			pos = xPos,
			anchor = Vector2.new(0.5, 0),
			color = if mark.strong then "gold" else "dim",
			textSize = 10,
			font = if mark.strong then Enum.Font.GothamBold else Enum.Font.GothamMedium,
			xalign = xalign,
		})
	end

	-- right column: the decision itself — when is the water still?
	local info = Ui.frame(panel, {
		name = "Info",
		size = UDim2.new(0.34, -10, 1, -14),
		pos = UDim2.new(1, -10, 0, 7),
		anchor = Vector2.new(1, 0),
		transparency = 1,
	})
	local caption = Ui.label(info, {
		text = "NEXT SLACK",
		size = UDim2.new(1, 0, 0, 12),
		color = "dim",
		textSize = 10,
		font = Enum.Font.GothamBold,
	})
	local bigLabel = Ui.label(info, {
		text = "—",
		size = UDim2.new(1, 0, 0, 26),
		pos = UDim2.fromOffset(0, 12),
		textSize = 22,
		font = Enum.Font.GothamBold,
		color = "gold",
	})
	local subLabel = Ui.label(info, {
		text = "",
		size = UDim2.new(1, 0, 0, 14),
		pos = UDim2.fromOffset(0, 38),
		color = "dim",
		textSize = 11,
	})
	local eventsLabel = Ui.label(info, {
		text = "",
		size = UDim2.new(1, 0, 0, 12),
		pos = UDim2.new(0, 0, 1, -12),
		color = "dim",
		textSize = 10,
	})

	local placeholder = Ui.label(panel, {
		text = "reading the chart…",
		size = UDim2.new(1, -20, 0, 16),
		pos = UDim2.new(0, 10, 0.5, -8),
		color = "dim",
		textSize = 12,
	})

	-- ---------------------------------------------------------------------------
	-- Slack window
	--
	-- Tide.hoursToSlack only reports the START of the next window and reads 0
	-- when one is already running; the strip also needs the END so it can say
	-- "ends 0:35". Hence a small forward scan. Pure display maths on a pure
	-- module — nothing here touches game state.
	-- ---------------------------------------------------------------------------

	local function nextSlackWindow(hour: number): { active: boolean, startsIn: number, endsIn: number }
		local searchLimit = 10 -- game hours; longer than any gap between slacks
		local startT: number? = nil

		if Tide.isSlack(hour) then
			startT = hour
		else
			local t = hour
			while t < hour + searchLimit do
				if Tide.isSlack(t) then
					startT = t
					break
				end
				t += SCAN_STEP
			end
		end
		if startT == nil then
			return { active = false, startsIn = -1, endsIn = -1 }
		end

		local endT = startT
		while endT < startT + 6 do
			if not Tide.isSlack(endT) then
				break
			end
			endT += SCAN_STEP
		end

		return { active = startT <= hour, startsIn = startT - hour, endsIn = endT - hour }
	end

	-- ---------------------------------------------------------------------------
	-- Server payloads
	-- ---------------------------------------------------------------------------

	local function onOceanSync(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		local p = payload :: Types.OceanSyncPayload
		Ui.clockSync(clock, p.month or 1, p.day or 1, p.tick or 0)
	end

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

	-- ---------------------------------------------------------------------------
	-- Render
	-- ---------------------------------------------------------------------------

	local heights: { number } = table.create(BAR_COUNT, 0)

	local function renderBars(hour: number)
		local base = hour - LOOKBACK_HOURS

		-- normalise over the visible window so a neap week still shows a
		-- readable curve instead of a flat line near the top
		local lo = math.huge
		local hi = -math.huge
		for i = 1, BAR_COUNT do
			local t = base + (i - 0.5) / BAR_COUNT * WINDOW_HOURS
			local h = Tide.heightAt(t)
			heights[i] = h
			if h < lo then
				lo = h
			end
			if h > hi then
				hi = h
			end
		end
		local span = if hi - lo > 0.05 then hi - lo else 1

		for i = 1, BAR_COUNT do
			local t = base + (i - 0.5) / BAR_COUNT * WINDOW_HOURS
			local norm = (heights[i] - lo) / span
			local bar = bars[i]
			bar.Size = UDim2.fromScale(0.7 / BAR_COUNT, 0.12 + 0.82 * norm)
			if Tide.isSlack(t) then
				bar.BackgroundColor3 = Ui.color("gold")
				bar.BackgroundTransparency = 0.05
			else
				bar.BackgroundColor3 = Ui.color("water")
				bar.BackgroundTransparency = 0.25
			end
		end

		nowLine.Position = UDim2.fromScale(LOOKBACK_HOURS / WINDOW_HOURS, 0)
	end

	local function renderSlack(hour: number)
		local perGameHour = Ui.clockSecondsPerGameHour(clock)
		local window = nextSlackWindow(hour)

		if window.active then
			caption.Text = "SLACK WATER"
			caption.TextColor3 = Ui.color("gold")
			bigLabel.Text = "NOW"
			subLabel.Text = "ends in " .. Ui.countdown(window.endsIn * perGameHour)
		elseif window.startsIn >= 0 then
			caption.Text = "NEXT SLACK"
			caption.TextColor3 = Ui.color("dim")
			bigLabel.Text = Ui.countdown(window.startsIn * perGameHour)
			subLabel.Text = "opens " .. Ui.clockFace(hour + window.startsIn)
		else
			-- no slack found inside the scan: show the honest dash, never 0:00
			caption.Text = "NEXT SLACK"
			bigLabel.Text = "—"
			subLabel.Text = ""
		end

		local events = Tide.nextEvents(hour)
		eventsLabel.Text = string.format(
			"HW %s · LW %s",
			Ui.clockFace(events.highTime),
			Ui.clockFace(events.lowTime)
		)
	end

	local fastClock = 0
	local slowClock = 0

	local heartbeat = RunService.Heartbeat:Connect(function(dt: number)
		fastClock += dt
		slowClock += dt
		if fastClock < BARS_REFRESH then
			return
		end
		fastClock = 0

		if not clock.synced then
			placeholder.Visible = true
			placeholder.TextTransparency = 0.45 + 0.3 * math.abs(math.sin(os.clock() * 2.5))
			return
		end
		placeholder.Visible = false

		local hour = Ui.clockHour(clock)
		renderBars(hour)
		if slowClock >= SLOW_REFRESH then
			slowClock = 0
			renderSlack(hour)
		end
	end)
	table.insert(connections, heartbeat)

	Ui.connect(connections, gui.Destroying, function()
		Ui.disconnectAll(connections)
	end)
end

-- Standalone interpreter: no Roblox runtime, stop before touching any global
-- so `luau <file>` is a clean syntax gate (scripts-check.sh).
if game == nil then
	return
end

main()
