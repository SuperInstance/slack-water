--!strict
--[[
	GearBar — the skipper's career and tackle.

	A right-edge sheet (same kit as MARKET and GROUNDS) showing the level and
	xp the server sent, the gear roster, and what is locked behind which level.
	Every stateful number here arrived in a ProfileSync; the gear names, prices
	and unlock levels are the static Types.Gear catalogue. Nothing computes
	effort, yield or value, and nothing predicts the outcome of a gear change:
	tapping an owned row sends a GearRequest and the next ProfileSync — the
	server's answer — is what moves (house rule 2).

	The remote names below mirror src/Server/Remotes.server.luau, which owns
	them until they are folded into Types.luau.
]]

local Ui = require(script and script.Parent.Ui or "./Ui")

-- pending Types.luau additions; keep in step with src/Server/Remotes.server.luau
local GEAR_REQUEST = "GearRequest"
local PROFILE_SYNC = "ProfileSync"

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

	local gui = Ui.screenGui("SlackWaterGear", 6, playerGui)
	local root = Ui.frame(gui, { name = "Root", transparency = 1 })
	Ui.autoScale(root)

	local sheet = Ui.makeSheet({
		root = root,
		tracker = connections,
		playerGui = playerGui,
		key = "gear",
		icon = "🎣",
		caption = "gear",
		title = "SKIPPER",
		subtitle = "the career is the tackle",
		width = 320,
		height = 470,
		yScale = 0.76,
	})

	-- ---------------------------------------------------------------------------
	-- Career summary — level, xp bar, all straight off the last ProfileSync
	-- ---------------------------------------------------------------------------

	local summary = Ui.frame(sheet.body, {
		name = "Summary",
		size = UDim2.new(1, 0, 0, 58),
		color = "deep",
		transparency = 0.2,
		corner = 8,
		layoutOrder = 0,
	})

	local levelLabel = Ui.label(summary, {
		text = "—",
		textSize = 22,
		font = Enum.Font.GothamBold,
		color = "gold",
		size = UDim2.fromOffset(74, 26),
		pos = UDim2.fromOffset(10, 6),
	})

	local xpLabel = Ui.label(summary, {
		text = "reading the logbook…",
		textSize = 10,
		color = "dim",
		size = UDim2.new(1, -96, 0, 14),
		pos = UDim2.new(1, -10, 0, 10),
		anchor = Vector2.new(1, 0),
		xalign = Enum.TextXAlignment.Right,
	})

	local xpMeter = Ui.meter(summary, "gold", {
		name = "XpMeter",
		size = UDim2.new(1, -20, 0, 6),
		pos = UDim2.new(0, 10, 1, -18),
		color = "panel",
		corner = 3,
	})

	local equipErrorLabel = Ui.label(summary, {
		text = "",
		textSize = 10,
		color = "danger",
		size = UDim2.new(1, -20, 0, 12),
		pos = UDim2.new(0, 10, 1, -10),
		anchor = Vector2.new(0, 1),
		visible = false,
	})

	-- the level rides on the edge toggle so the career is visible while closed
	local badgeChip = Ui.chip(sheet.toggle, "LV 1", "gold", {
		pos = UDim2.new(0.5, 0, 0, -14),
		anchor = Vector2.new(0.5, 1),
	})
	local badgeText = badgeChip:FindFirstChild("Label")
	if badgeText and badgeText:IsA("TextLabel") then
		badgeText.TextSize = 9
	end
	badgeChip.Visible = false

	-- ---------------------------------------------------------------------------
	-- Gear rows — static catalogue, ownership and equipping from the server
	-- ---------------------------------------------------------------------------

	local scroll = Ui.scroll(sheet.body, {
		name = "Rows",
		size = UDim2.new(1, 0, 1, -66),
		pos = UDim2.fromOffset(0, 62),
	})
	local emptyLabel = Ui.label(scroll, {
		text = "reading the logbook…",
		color = "dim",
		textSize = 12,
		size = UDim2.new(1, 0, 0, 20),
		layoutOrder = 0,
	})

	local rows: { Frame } = {}
	-- equip-overlay connections belong to the rows, not the panel: rebuilds
	-- happen on every ProfileSync while the sheet is open, and connections to
	-- destroyed rows would otherwise pile up in the panel tracker forever
	local rowConns: Ui.Conns = {}

	-- filled by the remote-wait loop below; a tap before the server has
	-- built the remote simply does nothing rather than yielding a handler
	local gearRequestRemote: RemoteEvent? = nil

	local function destroyRows(): ()
		Ui.disconnectAll(rowConns)
		for _, row in rows do
			row:Destroy()
		end
		table.clear(rows)
	end

	local PLAIN_LANGUAGE: { [string]: string } = {
		["not owned"] = "you do not hold this gear",
	}

	local function rebuild(profile: any): ()
		destroyRows()

		local level = tonumber(profile.level) or 1
		local currentGearId = profile.currentGearId
		local owned: { [string]: boolean } = {}
		local ownedList = profile.ownedGear
		if typeof(ownedList) == "table" then
			for _, id in ownedList do
				if type(id) == "string" then
					owned[id] = true
				end
			end
		end

		-- the catalogue in unlock order, so the ladder reads top to bottom
		local catalogue: { any } = {}
		for _, gear in Types.Gear do
			table.insert(catalogue, gear)
		end
		table.sort(catalogue, function(a, b)
			if a.unlockLevel ~= b.unlockLevel then
				return a.unlockLevel < b.unlockLevel
			end
			return a.id < b.id
		end)

		emptyLabel.Visible = false

		for index, gear in catalogue do
			local isOwned = owned[gear.id] == true
			local isCurrent = currentGearId == gear.id
			local isLocked = level < gear.unlockLevel

			local row = Ui.frame(scroll, {
				name = "Row" .. tostring(index),
				size = UDim2.new(1, 0, 0, 46),
				color = "deep",
				-- a locked row recedes; the working row is the only gold thing
				transparency = if isLocked then 0.45 else 0.2,
				corner = 8,
				strokeColor = if isCurrent then "gold" else nil,
				strokeWidth = if isCurrent then 1 else nil,
				layoutOrder = index,
			})

			Ui.label(row, {
				text = gear.displayName,
				textSize = 13,
				font = Enum.Font.GothamBold,
				color = if isLocked then "dim" else "text",
				size = UDim2.new(1, -90, 0, 16),
				pos = UDim2.fromOffset(10, 5),
			})

			local subText: string
			if isLocked then
				subText = "🔒 reached at level "
					.. tostring(gear.unlockLevel)
					.. " · price "
					.. Ui.formatInt(gear.price)
			elseif isOwned then
				subText = "effort " .. tostring(gear.effort)
			else
				subText = "within reach · price " .. Ui.formatInt(gear.price)
			end
			Ui.label(row, {
				text = subText,
				textSize = 10.5,
				color = "dim",
				size = UDim2.new(1, -90, 0, 13),
				pos = UDim2.fromOffset(10, 24),
			})

			if isCurrent then
				Ui.chip(row, "WORKING", "gold", {
					pos = UDim2.new(1, -10, 0, 25),
					anchor = Vector2.new(1, 0),
				})
			elseif isOwned then
				Ui.chip(row, "HELD", "dim", {
					pos = UDim2.new(1, -10, 0, 25),
					anchor = Vector2.new(1, 0),
				})

				-- the whole row is the tap target (a thumb does not aim at
				-- small UI): send the request, render whatever comes back
				local overlay = Ui.button(row, {
					name = "Equip",
					text = "",
					size = UDim2.fromScale(1, 1),
					transparency = 1,
					zindex = 3,
				})
				local gearId = gear.id
				Ui.connect(rowConns, overlay.Activated, function()
					local request = gearRequestRemote
					if request then
						request:FireServer({ gearId = gearId })
					end
				end)
			end

			table.insert(rows, row)
		end
	end

	-- ---------------------------------------------------------------------------
	-- Server payloads
	-- ---------------------------------------------------------------------------

	local latest: any = nil
	local errorToken = 0

	local function onProfileSync(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		latest = payload

		-- summary is cheap enough to keep current even while closed
		local level = tonumber(payload.level)
		if level then
			local badge = "LV " .. tostring(math.floor(level))
			levelLabel.Text = badge
			if badgeText and badgeText:IsA("TextLabel") then
				badgeText.Text = badge
			end
			badgeChip.Visible = true
		end

		local into = tonumber(payload.levelInto)
		local needed = tonumber(payload.levelNeeded)
		if into and needed then
			xpLabel.Text = Ui.formatInt(into) .. " / " .. Ui.formatInt(needed) .. " xp"
		end
		Ui.setMeter(xpMeter, math.clamp(tonumber(payload.fraction) or 0, 0, 1))

		-- a refusal is explained once, then fades; a clean sync does not
		-- interrupt the explanation mid-read
		if type(payload.equipError) == "string" then
			errorToken += 1
			local token = errorToken
			equipErrorLabel.Text = PLAIN_LANGUAGE[payload.equipError] or payload.equipError
			equipErrorLabel.Visible = true
			task.delay(3, function()
				if token == errorToken then
					equipErrorLabel.Visible = false
				end
			end)
		end

		if sheet.isOpen then
			rebuild(latest)
		end
	end

	local open = sheet.open
	local sheetOpen = function(self: Ui.Sheet)
		open(self)
		if latest then
			rebuild(latest)
		end
	end
	sheet.open = sheetOpen

	task.spawn(function()
		for _ = 1, 15 do
			local profileSync = Ui.awaitRemote(Types.REMOTE_FOLDER, PROFILE_SYNC, 10)
			if profileSync then
				Ui.connect(connections, profileSync.OnClientEvent, onProfileSync)
				break
			end
			task.wait(2)
		end
	end)
	task.spawn(function()
		for _ = 1, 15 do
			local gearRequest = Ui.awaitRemote(Types.REMOTE_FOLDER, GEAR_REQUEST, 10)
			if gearRequest then
				gearRequestRemote = gearRequest
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
