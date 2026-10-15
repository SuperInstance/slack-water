--!strict
--[[
	Notify — toasts.

	One-line messages from the server: a run starting, a ground thinning out,
	a market moving, a newly charted bank. They stack under the tide strip,
	fade in, hold long enough to read, and get out of the way — the centre of
	the screen belongs to the water.

	Kind carries the colour and the icon so a player learns to read a toast
	from the corner of their eye: gold means a run (drop what you are doing),
	amber means consequence, blue means money moved.
]]

local Ui = require(script and script.Parent.Ui or "./Ui")

local HOLD_SECONDS = 3.5
local FADE_SECONDS = 0.35
local MAX_TOASTS = 4

local KIND_STYLE: { [string]: { icon: string, color: string } } = {
	run = { icon = "🐟", color = "gold" },
	scarcity = { icon = "⚠️", color = "amber" },
	contest = { icon = "⚔️", color = "amber" },
	market = { icon = "📈", color = "water" },
	discover = { icon = "🗺️", color = "teal" },
}

local function main(): ()
	local Players = game:GetService("Players")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")

	local player = Players.LocalPlayer
	if not player then
		return
	end
	local playerGui = player:WaitForChild("PlayerGui")

	local Shared = ReplicatedStorage:WaitForChild("Shared")
	local Types = require(Shared:WaitForChild("Types") :: ModuleScript)

	local connections: Ui.Conns = {}

	local gui = Ui.screenGui("SlackWaterNotify", 10, playerGui)
	local root = Ui.frame(gui, { name = "Root", transparency = 1 })
	Ui.autoScale(root)

	-- directly under the tide strip (ends at 196 logical px), centred, never
	-- wider than the strip itself
	local stack = Ui.frame(root, {
		name = "Stack",
		size = UDim2.new(1, -48, 0, 0),
		pos = UDim2.new(0.5, 0, 0, 204),
		anchor = Vector2.new(0.5, 0),
		transparency = 1,
	})
	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, 6)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = stack

	-- ---------------------------------------------------------------------------
	-- Toasts
	-- ---------------------------------------------------------------------------

	local counter = 0
	-- oldest first, so the cap evicts the right one
	local live: { Frame } = {}

	local function push(kind: string, text: string)
		local style = KIND_STYLE[kind] or { icon = "•", color = "dim" }

		counter += 1
		local order = counter

		-- newest on top: lower LayoutOrder sorts first and the counter only
		-- grows, so this is a monotonic newest-first ordering for free
		local toast = Ui.frame(stack, {
			name = "Toast",
			size = UDim2.new(1, 0, 0, 36),
			color = "deep",
			transparency = 0.06,
			corner = 9,
			strokeColor = style.color,
			strokeWidth = 1,
			layoutOrder = -order,
		})
		Ui.label(toast, {
			text = style.icon,
			textSize = 15,
			size = UDim2.fromOffset(26, 36),
			pos = UDim2.fromOffset(10, 0),
			xalign = Enum.TextXAlignment.Center,
		})
		local body = Ui.label(toast, {
			text = text,
			textSize = 12,
			size = UDim2.new(1, -56, 0, 36),
			pos = UDim2.fromOffset(40, 0),
		})

		-- the stroke is a child instance with its own transparency; fading a
		-- toast means fading all three pieces together
		local stroke = toast:FindFirstChildWhichIsA("UIStroke", true)

		table.insert(live, toast)
		if #live > MAX_TOASTS then
			local oldest = table.remove(live, 1)
			oldest:Destroy()
		end

		toast.BackgroundTransparency = 1
		body.TextTransparency = 1
		if stroke then
			stroke.Transparency = 1
		end
		Ui.tween(toast, FADE_SECONDS, { BackgroundTransparency = 0.06 })
		Ui.tween(body, FADE_SECONDS, { TextTransparency = 0 })
		if stroke then
			Ui.tween(stroke, FADE_SECONDS, { Transparency = 0 })
		end

		local gone = false
		local function dismiss()
			if gone then
				return
			end
			gone = true
			Ui.tween(toast, FADE_SECONDS, { BackgroundTransparency = 1 })
			Ui.tween(body, FADE_SECONDS, { TextTransparency = 1 })
			if stroke then
				Ui.tween(stroke, FADE_SECONDS, { Transparency = 1 })
			end
			task.delay(FADE_SECONDS + 0.05, function()
				toast:Destroy()
			end)
		end

		task.delay(HOLD_SECONDS, dismiss)
	end

	-- ---------------------------------------------------------------------------
	-- Server payloads
	-- ---------------------------------------------------------------------------

	local function onNotify(payload: any)
		if typeof(payload) ~= "table" or type(payload.text) ~= "string" then
			return
		end
		local p = payload :: Types.NotifyPayload
		push(type(p.kind) == "string" and p.kind or "market", p.text)
	end

	-- a newly composed bank is exactly the news a toast exists for; the
	-- RegionDiscovered payload becomes a discover-kind line
	local function onRegionDiscovered(payload: any)
		if typeof(payload) ~= "table" or type(payload.name) ~= "string" then
			return
		end
		local p = payload :: Types.RegionDiscoveredPayload
		local line = string.format("New ground charted: %s", p.name)
		if type(p.habitat) == "string" then
			line ..= string.format(" · %s", p.habitat)
		end
		if type(p.depth) == "number" then
			line ..= string.format(" · %d m", math.floor(p.depth))
		end
		push("discover", line)
	end

	task.spawn(function()
		for _ = 1, 15 do
			local notify = Ui.awaitRemote(Types.REMOTE_FOLDER, Types.Notify, 10)
			if notify then
				Ui.connect(connections, notify.OnClientEvent, onNotify)
				break
			end
			task.wait(2)
		end
	end)
	task.spawn(function()
		for _ = 1, 15 do
			local discovered = Ui.awaitRemote(Types.REMOTE_FOLDER, Types.RegionDiscovered, 10)
			if discovered then
				Ui.connect(connections, discovered.OnClientEvent, onRegionDiscovered)
				break
			end
			task.wait(2)
		end
	end)

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
