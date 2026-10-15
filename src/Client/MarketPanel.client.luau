--!strict
--[[
	MarketPanel — the live price list, the balance, and the hold.

	Renders MarketSync verbatim: price, scarcity multiplier, global abundance
	and direction all arrive from the server; this script sorts and badges
	them, nothing more. A modified client must not be able to derive a price
	the ocean did not send (house rule 2), so there is no maths here beyond
	rounding for display.

	The callouts are the point. A row that is RISING or SCARCE is highlighted
	because "where do I go next" is the only decision the market exists to
	support: a species everyone is catching is worthless, a thin one pays.

	Above the prices sit the wallet's two answers: the BALANCE (the server's
	authoritative number, off WalletSync — never a client-side sum of catch
	values) and the HOLD — fish kept from catch cards, each sellable here at
	whatever the market pays at the moment the server processes the request.
	The sell buttons send a catchId and nothing else; the paid amount is
	rendered from SellResult when it comes back.
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
	local Species = require(Shared:WaitForChild("Species") :: ModuleScript)

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
	-- Wallet state — balance and hold, as last sent by the server
	-- ---------------------------------------------------------------------------

	type HoldEntry = {
		catchId: string,
		speciesId: string,
		weightKg: number,
	}

	type WalletState = { balanceCents: number?, hold: { HoldEntry } }

	-- cents -> credits, for display only — division and formatting, never
	-- valuation (house rule 2)
	local function formatMoney(cents: number): string
		local c = math.floor(Ui.tonum(cents, 0) + 0.5)
		local whole = math.floor(c / 100)
		local rest = c - whole * 100
		if rest == 0 then
			return Ui.formatInt(whole)
		end
		return string.format("%d.%02d", whole, rest)
	end

	local function normalizeWallet(raw: any): WalletState
		local out: WalletState = { balanceCents = nil, hold = {} }
		if typeof(raw) ~= "table" then
			return out
		end
		if type(raw.balanceCents) == "number" and raw.balanceCents >= 0 then
			out.balanceCents = raw.balanceCents
		end
		if typeof(raw.hold) == "table" then
			for _, entry in raw.hold do
				if
					typeof(entry) == "table"
					and type(entry.catchId) == "string"
					and #entry.catchId > 0
				then
					table.insert(out.hold, {
						catchId = entry.catchId,
						speciesId = if type(entry.speciesId) == "string"
							then entry.speciesId
							else "",
						weightKg = Ui.tonum(entry.weightKg, 0),
					})
				end
			end
		end
		return out
	end

	local wallet: WalletState = normalizeWallet(nil)
	local sellRequestRemote: RemoteEvent? = nil

	-- ---------------------------------------------------------------------------
	-- Rows
	-- ---------------------------------------------------------------------------

	local rows: { Frame } = {}
	-- connections that belong to built rows (hold-row sell buttons) rather
	-- than to the panel; they die with the rows on every rebuild
	local rowConns: Ui.Conns = {}
	-- live hold rows by catchId, so a SellResult can find the row it answers
	local holdRows: { [string]: { button: TextButton, note: TextLabel } } = {}
	-- catchIds with a sell in flight, so a row cannot double-fire
	local pendingSell: { [string]: boolean } = {}

	local function destroyRows(): ()
		Ui.disconnectAll(rowConns)
		table.clear(rowConns)
		table.clear(holdRows)
		for _, row in rows do
			row:Destroy()
		end
		table.clear(rows)
	end

	-- entries are normalized on arrival (Ui.normalizeMarketEntries), so every
	-- field read here is a finite number or a known string; partial payloads
	-- and wrong-typed fields were dropped or defaulted before rendering.
	-- The wallet section above the prices is last-known server state — the
	-- balance does not decay when a feed stutters, so it renders even while
	-- the market rows are being stale-gated.
	local function rebuild(entries: { Ui.MarketRow }): ()
		destroyRows()
		emptyLabel.Text = "waiting for the market…"

		local order = 0

		if wallet.balanceCents ~= nil then
			order += 1
			local balanceRow = Ui.frame(scroll, {
				name = "BalanceRow",
				size = UDim2.new(1, 0, 0, 38),
				color = "deep",
				transparency = 0.1,
				corner = 8,
				strokeColor = "gold",
				strokeWidth = 1,
				layoutOrder = order,
			})
			Ui.label(balanceRow, {
				text = "BALANCE",
				textSize = 10,
				font = Enum.Font.GothamBold,
				color = "dim",
				size = UDim2.new(1, -96, 0, 14),
				pos = UDim2.fromOffset(10, 6),
			})
			Ui.label(balanceRow, {
				text = formatMoney(wallet.balanceCents),
				textSize = 17,
				font = Enum.Font.GothamBold,
				color = "gold",
				size = UDim2.fromOffset(86, 20),
				pos = UDim2.new(1, -10, 0, 5),
				anchor = Vector2.new(1, 0),
				xalign = Enum.TextXAlignment.Right,
			})
			table.insert(rows, balanceRow)
		end

		if #wallet.hold > 0 then
			order += 1
			local header = Ui.frame(scroll, {
				name = "HoldHeader",
				size = UDim2.new(1, 0, 0, 16),
				transparency = 1,
				layoutOrder = order,
			})
			Ui.label(header, {
				text = "YOUR HOLD — " .. tostring(#wallet.hold) .. " to sell",
				textSize = 9.5,
				font = Enum.Font.GothamBold,
				color = "dim",
			})

			for _, held in wallet.hold do
				local species = if #held.speciesId > 0 then Species.get(held.speciesId) else nil
				order += 1
				local row = Ui.frame(scroll, {
					name = "Hold" .. tostring(order),
					size = UDim2.new(1, 0, 0, 46),
					color = "deep",
					transparency = 0.2,
					corner = 8,
					strokeColor = "gold",
					strokeWidth = 1,
					layoutOrder = order,
				})
				Ui.label(row, {
					text = "🐟 " .. (if species
						then species.displayName
						elseif #held.speciesId > 0 then held.speciesId
						else "something in the hold"),
					textSize = 13,
					font = Enum.Font.GothamBold,
					size = UDim2.new(1, -96, 0, 16),
					pos = UDim2.fromOffset(10, 5),
				})
				local note = Ui.label(row, {
					text = Ui.formatWeight(held.weightKg) .. " · sell at the market's price now",
					textSize = 10.5,
					color = "dim",
					size = UDim2.new(1, -96, 0, 13),
					pos = UDim2.fromOffset(10, 24),
				})
				local sellBtn = Ui.button(row, {
					name = "Sell",
					text = "SELL",
					textSize = 11,
					textColor = "deep",
					bgColor = "gold",
					corner = 6,
					size = UDim2.fromOffset(70, 26),
					pos = UDim2.new(1, -10, 0.5, 0),
					anchor = Vector2.new(1, 0.5),
				})

				local catchId = held.catchId
				holdRows[catchId] = { button = sellBtn, note = note }
				table.insert(rows, row)

				Ui.connect(rowConns, sellBtn.Activated, function()
					if pendingSell[catchId] then
						return
					end
					local remote = sellRequestRemote
					if not remote then
						note.Text = "wallet not connected yet"
						return
					end

					pendingSell[catchId] = true
					sellBtn.Active = false
					sellBtn.AutoButtonColor = false
					sellBtn.Text = "…"
					note.Text = "waiting on the server…"

					-- the server answers every sell, but a dropped remote must
					-- not leave the row's button disabled forever
					task.delay(6, function()
						if pendingSell[catchId] then
							pendingSell[catchId] = nil
							if sellBtn.Parent then
								sellBtn.Active = true
								sellBtn.AutoButtonColor = true
								sellBtn.Text = "SELL"
								note.Text = "no answer — try again"
							end
						end
					end)

					remote:FireServer({ catchId = catchId })
				end)
			end
		end

		if #entries == 0 and wallet.balanceCents == nil then
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
				-- price rows sort below the wallet section
				layoutOrder = 100 + index,
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

	local function onWalletSync(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		wallet = normalizeWallet(payload)
		if wallet.balanceCents ~= nil then
			-- the sheet's subtitle carries the balance everywhere the sheet
			-- goes; it is the server's number, never a local sum
			sheet:setSubtitle("balance " .. formatMoney(wallet.balanceCents))
		end
		if sheet.isOpen then
			renderCurrent()
		end
	end

	local function onSellResult(payload: any)
		if typeof(payload) ~= "table" or type(payload.catchId) ~= "string" then
			return
		end
		local entry = holdRows[payload.catchId]
		if entry == nil then
			-- the row was rebuilt away, or the sale came from a catch card
			return
		end

		if payload.ok == true and type(payload.paidCents) == "number" then
			pendingSell[payload.catchId] = nil
			-- stay disabled; the WalletSync that follows removes the row
			entry.note.Text = "✓ sold for " .. formatMoney(Ui.tonum(payload.paidCents, 0))
			return
		end

		pendingSell[payload.catchId] = nil
		entry.button.Active = true
		entry.button.AutoButtonColor = true
		entry.button.Text = "SELL"
		local reason = if type(payload.reason) == "string" then payload.reason else ""
		entry.note.Text = if reason == "no such catch"
			then "already sold — or the hold lost it"
			elseif reason == "too fast" then "too quick — try again"
			elseif reason == "malformed request" then "that sale never went out"
			else "the server refused that sale"
		task.delay(3, function()
			if entry.note.Parent and pendingSell[payload.catchId] == nil then
				entry.note.Text = "sell at the market's price now"
			end
		end)
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
	task.spawn(function()
		for _ = 1, 15 do
			local walletSync = Ui.awaitRemote(Types.REMOTE_FOLDER, Types.WalletSync, 10)
			if walletSync then
				Ui.connect(connections, walletSync.OnClientEvent, onWalletSync)
				break
			end
			task.wait(2)
		end
	end)
	task.spawn(function()
		for _ = 1, 15 do
			local sellResult = Ui.awaitRemote(Types.REMOTE_FOLDER, Types.SellResult, 10)
			if sellResult then
				Ui.connect(connections, sellResult.OnClientEvent, onSellResult)
				break
			end
			task.wait(2)
		end
	end)
	task.spawn(function()
		for _ = 1, 15 do
			local sellRequest = Ui.awaitRemote(Types.REMOTE_FOLDER, Types.SellRequest, 10)
			if sellRequest then
				sellRequestRemote = sellRequest
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
