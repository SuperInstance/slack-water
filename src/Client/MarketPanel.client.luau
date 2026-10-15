--!strict
--[[
	MarketPanel — the live price list.

	Renders MarketSync verbatim: price, scarcity multiplier, global abundance
	and direction all arrive from the server; this script sorts and badges
	them, nothing more. A modified client must not be able to derive a price
	the ocean did not send (house rule 2), so there is no maths here beyond
	rounding for display.

	The callouts are the point. A row that is RISING or SCARCE is highlighted
	because "where do I go next" is the only decision the market exists to
	support: a species everyone is catching is worthless, a thin one pays.
]]

local Ui = require(script and script.Parent.Ui or "./Ui")

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
	local Market = require(Shared:WaitForChild("Market") :: ModuleScript)

	local connections: Ui.Conns = {}

	local gui = Ui.screenGui("SlackWaterMarket", 5, playerGui)
	local root = Ui.frame(gui, { name = "Root", transparency = 1 })
	Ui.autoScale(root)

	local sheet = Ui.makeSheet({
		root = root,
		tracker = connections,
		playerGui = playerGui,
		key = "market",
		icon = "💰",
		caption = "market",
		title = "MARKET",
		subtitle = "prices answer to the whole ocean",
		width = 320,
		height = 440,
		yScale = 0.4,
	})

	local scroll = Ui.scroll(sheet.body, { name = "Rows", size = UDim2.fromScale(1, 1) })
	local emptyLabel = Ui.label(scroll, {
		text = "waiting for the market…",
		color = "dim",
		textSize = 12,
		size = UDim2.new(1, 0, 0, 20),
		layoutOrder = 0,
	})

	-- ---------------------------------------------------------------------------
	-- Rows
	-- ---------------------------------------------------------------------------

	local rows: { Frame } = {}

	local function destroyRows(): ()
		for _, row in rows do
			row:Destroy()
		end
		table.clear(rows)
	end

	-- entries arrive over the wire, so they are typed as `{ any }` exactly like
	-- the server's own remote handlers; every field read below is guarded
	local function rebuild(entries: { any }): ()
		destroyRows()

		if #entries == 0 then
			emptyLabel.Visible = true
			return
		end
		emptyLabel.Visible = false

		-- richest first: the top of the list is the answer to "what pays"
		local sorted = table.clone(entries)
		table.sort(sorted, function(a, b)
			return (a.price or 0) > (b.price or 0)
		end)

		for index, entry in sorted do
			local rising = entry.direction == "rising"
			local scarce = Market.isScarce({
				speciesId = entry.speciesId,
				price = entry.price,
				baseValue = entry.baseValue,
				scarcityMultiplier = entry.scarcityMultiplier,
				globalAbundance = entry.globalAbundance,
				direction = entry.direction,
			})

			local row = Ui.frame(scroll, {
				name = "Row" .. tostring(index),
				size = UDim2.new(1, 0, 0, 46),
				color = "deep",
				transparency = 0.2,
				corner = 8,
				-- the gold edge IS the callout for a rising price
				strokeColor = if rising then "gold" else nil,
				strokeWidth = if rising then 1 else nil,
				layoutOrder = index,
			})

			Ui.label(row, {
				text = entry.displayName or entry.speciesId,
				textSize = 13,
				font = Enum.Font.GothamBold,
				size = UDim2.new(1, -84, 0, 16),
				pos = UDim2.fromOffset(10, 5),
			})
			Ui.label(row, {
				text = Ui.formatInt(entry.price or 0),
				textSize = 13.5,
				font = Enum.Font.GothamBold,
				color = if rising then "gold" else "text",
				size = UDim2.fromOffset(70, 16),
				pos = UDim2.new(1, -80, 0, 5),
				anchor = Vector2.new(1, 0),
				xalign = Enum.TextXAlignment.Right,
			})

			-- the multiplier is the market's story: ×1 is plenty, ×6 is a
			-- collapse someone is still being paid for
			local pct = math.clamp(math.floor((entry.globalAbundance or 0) * 100 + 0.5), 0, 100)
			Ui.label(row, {
				text = string.format(
					"×%.1f scarcity · %d%% of the ocean",
					entry.scarcityMultiplier or 1,
					pct
				),
				textSize = 10.5,
				color = "dim",
				size = UDim2.new(1, -150, 0, 13),
				pos = UDim2.fromOffset(10, 24),
			})
			if scarce then
				Ui.chip(row, "SCARCE", "danger", {
					pos = UDim2.new(1, -84, 0, 25),
					anchor = Vector2.new(1, 0),
				})
			end
			if rising then
				Ui.chip(row, "RISING ▲", "gold", {
					pos = UDim2.new(1, -10, 0, 25),
					anchor = Vector2.new(1, 0),
				})
			end

			table.insert(rows, row)
		end
	end

	-- ---------------------------------------------------------------------------
	-- Server payloads
	--
	-- Rows are only rebuilt while the sheet is closed-open cycles stay cheap;
	-- a hidden panel has no business churning instances every sync.
	-- ---------------------------------------------------------------------------

	local latest: { any } = {}

	local function onMarketSync(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		local p = payload :: Types.MarketSyncPayload
		latest = p.entries or {}
		if sheet.isOpen then
			rebuild(latest)
		end
	end

	local open = sheet.open
	local sheetOpen = function(self: Ui.Sheet)
		open(self)
		rebuild(latest)
	end
	sheet.open = sheetOpen

	task.spawn(function()
		for _ = 1, 15 do
			local marketSync = Ui.awaitRemote(Types.REMOTE_FOLDER, Types.MarketSync, 10)
			if marketSync then
				Ui.connect(connections, marketSync.OnClientEvent, onMarketSync)
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
