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

	-- entries are normalized on arrival (Ui.normalizeMarketEntries), so every
	-- field read here is a finite number or a known string; partial payloads
	-- and wrong-typed fields were dropped or defaulted before rendering
	local function rebuild(entries: { Ui.MarketRow }): ()
		destroyRows()
		emptyLabel.Text = "waiting for the market…"

		if #entries == 0 then
			emptyLabel.Visible = true
			return
		end
		emptyLabel.Visible = false

		-- richest first: the top of the list is the answer to "what pays"
		local sorted = table.clone(entries)
		table.sort(sorted, function(a, b)
			return a.price > b.price
		end)

		for index, entry in sorted do
			local rising = entry.direction == "rising"
			local scarce = Market.isScarce({
				speciesId = entry.speciesId,
				displayName = entry.displayName,
				price = entry.price,
				baseValue = entry.baseValue,
				scarcityMultiplier = entry.scarcityMultiplier,
				globalAbundance = entry.globalAbundance,
				direction = entry.direction :: any,
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
				text = entry.displayName,
				textSize = 13,
				font = Enum.Font.GothamBold,
				size = UDim2.new(1, -84, 0, 16),
				pos = UDim2.fromOffset(10, 5),
			})
			Ui.label(row, {
				text = Ui.formatInt(entry.price),
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
			local pct = math.clamp(math.floor(entry.globalAbundance * 100 + 0.5), 0, 100)
			Ui.label(row, {
				text = string.format(
					"×%.1f scarcity · %d%% of the ocean",
					entry.scarcityMultiplier,
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
	-- a hidden panel has no business churning instances every sync. A feed
	-- that stops arriving must not leave its last prices reading as live.
	-- ---------------------------------------------------------------------------

	local MARKET_STALE_AFTER = 30 -- MarketSync rides the same 5 s broadcast loop
	local latest: { Ui.MarketRow } = {}
	local lastSyncAt = 0

	local function feedStale(): boolean
		return lastSyncAt > 0 and os.clock() - lastSyncAt > MARKET_STALE_AFTER
	end

	local function renderCurrent(): ()
		if feedStale() then
			destroyRows()
			emptyLabel.Text = "market out of date — showing nothing"
			emptyLabel.Visible = true
			return
		end
		rebuild(latest)
	end

	local function onMarketSync(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		local p = payload :: Types.MarketSyncPayload
		lastSyncAt = os.clock()
		latest = Ui.normalizeMarketEntries((p :: any).entries)
		if sheet.isOpen then
			renderCurrent()
		end
	end

	local open = sheet.open
	local sheetOpen = function(self: Ui.Sheet)
		open(self)
		renderCurrent()
	end
	sheet.open = sheetOpen

	-- while the sheet is open, a dead feed switches it to its out-of-date
	-- state without waiting for the player to close and reopen it
	local alive = true
	task.spawn(function()
		while alive do
			task.wait(5)
			if alive and sheet.isOpen and feedStale() then
				renderCurrent()
			end
		end
	end)

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
		alive = false
		Ui.disconnectAll(connections)
	end)
end

-- Standalone interpreter: no Roblox runtime, stop before touching any global
-- so `luau <file>` is a clean syntax gate (scripts-check.sh).
if game == nil then
	return
end

main()
