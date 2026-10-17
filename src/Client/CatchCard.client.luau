--!strict
--[[
	CatchCard — the cast result, and the keep-or-sell decision.

	Every number on the card came from the server's CastResult payload; this
	script only lays it out. The four flags each get their own treatment
	because they mean different things:

	- inRun     celebrate — a salmon run is live and runs are the headline
	            event of the game's calendar
	- rare      celebrate — a small, frequent reward, not a lottery
	- contested a warning — another crew was just on this water; the shared
	            ocean is the whole game, so this is information, not noise
	- depleted  a quiet gut-punch — the player themselves thinned this ground
	            out, and it will fish poorly until it recovers. It is never
	            rendered as a bare number; the flag says what the number did.

	The decision row is the point of the card: SELL pays the server's quote
	now, KEEP leaves the fish in the hold (it is held server-side from the
	instant it landed — doing nothing keeps it, and the card says so). The
	quote is CastResult.valueCents, a server number; the price actually paid
	arrives later in SellResult and is rendered verbatim, even when the
	market moved between quote and sale. The market line (direction, scarcity
	multiplier, straight off MarketSync) is there so the choice reads as a
	judgement about a live market, not a button.

	Tap-to-dismiss remains for cards without a decision (failures, payloads
	from before the wallet existed); cards auto-dismiss faster when they are
	bad news and hang around when they are worth looking at.
]]

local Ui = require(script and script.Parent.Ui or "./Ui")

local HOLD_NORMAL = 4.0
local HOLD_CELEBRATE = 6.5
local HOLD_FAILURE = 2.6
local HOLD_SOLD = 2.2
local SELL_WATCHDOG = 6.0

-- plain-language forms of the server's machine reasons
local REASON_TEXT: { [string]: string } = {
	["malformed request"] = "That cast never went out.",
	["unknown species"] = "That fish is not in these waters.",
	["unknown region"] = "That ground is not on your chart.",
	["nothing here"] = "Nothing biting — the ground is spent.",
}

-- plain-language forms of the wallet's sell refusals
local SELL_REASON_TEXT: { [string]: string } = {
	["malformed request"] = "That sale never went out.",
	["no such catch"] = "Already sold — or the hold lost it.",
	["too fast"] = "Too quick — give the market a breath.",
	["bad price"] = "The market could not price that fish.",
	["balance overflow"] = "The bank refuses — that balance is too large.",
	["the market is not running"] = "The market is not running.",
	["sale refused"] = "The sale was refused.",
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
	local Species = require(Shared:WaitForChild("Species") :: ModuleScript)

	local connections: Ui.Conns = {}

	local gui = Ui.screenGui("SlackWaterCatchCard", 8, playerGui)
	local root = Ui.frame(gui, { name = "Root", transparency = 1 })
	Ui.autoScale(root)

	local regionNames: { [string]: string } = {}

	-- latest market rows by speciesId, refreshed by every MarketSync. The
	-- card renders direction and scarcity from these server numbers so
	-- keep-or-sell is a read of a live market; nothing here derives a price.
	local marketBySpecies: { [string]: Ui.MarketRow } = {}

	-- the SellResult router: set by the card that has a sale in flight,
	-- cleared when that card goes away. A result for a dismissed card finds
	-- no handler and is dropped.
	local sellFinish: ((payload: any) -> ())? = nil

	-- the SellRequest remote, once found; cards fire it, this panel owns it
	local sellRequestRemote: RemoteEvent? = nil

	-- cents -> credits, for display only. The amounts are always the
	-- server's; this is division and string formatting, not valuation.
	local function formatMoney(cents: number): string
		local c = math.floor(Ui.tonum(cents, 0) + 0.5)
		local whole = math.floor(c / 100)
		local rest = c - whole * 100
		if rest == 0 then
			return Ui.formatInt(whole)
		end
		return string.format("%d.%02d", whole, rest)
	end

	-- ---------------------------------------------------------------------------
	-- Card construction
	-- ---------------------------------------------------------------------------

	-- a token invalidates the previous card's pending auto-dismiss, so a new
	-- cast mid-display swaps cards cleanly instead of fighting a timer
	local cardToken = 0
	local currentCard: Frame? = nil
	local currentCardConns: Ui.Conns? = nil

	local function destroyCurrent(): ()
		-- a card going away takes its pending sale routing with it
		sellFinish = nil
		-- the dismiss connection belongs to the card, not the panel: without
		-- this, a long session accumulates connections to destroyed cards
		local conns = currentCardConns
		currentCardConns = nil
		if conns then
			Ui.disconnectAll(conns)
		end
		local card = currentCard
		currentCard = nil
		if card then
			card:Destroy()
		end
	end

	local function banner(parent: Instance, text: string, colorName: string, filled: boolean): Frame
		local f = Ui.frame(parent, {
			name = "Banner",
			size = UDim2.new(1, 0, 0, 26),
			color = if filled then colorName else "deep",
			transparency = if filled then 0.78 else 0.2,
			corner = 8,
			strokeColor = if filled then nil else colorName,
			strokeWidth = if filled then nil else 1,
		})
		Ui.label(f, {
			text = text,
			color = colorName,
			textSize = 11.5,
			font = Enum.Font.GothamBold,
			xalign = Enum.TextXAlignment.Center,
		})
		return f
	end

	local function showFailure(reason: string?)
		destroyCurrent()
		cardToken += 1
		local token = cardToken

		local card = Ui.frame(root, {
			name = "CatchCard",
			size = UDim2.fromOffset(280, 0),
			pos = UDim2.fromScale(0.5, 0.4),
			anchor = Vector2.new(0.5, 0.5),
			color = "deep",
			transparency = 0.05,
			corner = 12,
			strokeColor = "danger",
			strokeWidth = 1,
		})
		card.AutomaticSize = Enum.AutomaticSize.Y
		local list = Instance.new("UIListLayout")
		list.Padding = UDim.new(0, 6)
		list.Parent = card
		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0, 14)
		pad.PaddingBottom = UDim.new(0, 12)
		pad.PaddingLeft = UDim.new(0, 14)
		pad.PaddingRight = UDim.new(0, 14)
		pad.Parent = card

		Ui.label(card, {
			text = "Nothing biting",
			textSize = 17,
			font = Enum.Font.GothamBold,
			color = "danger",
			size = UDim2.new(1, 0, 0, 20),
			xalign = Enum.TextXAlignment.Center,
		})
		Ui.label(card, {
			text = REASON_TEXT[reason or ""] or (reason or "The cast came back empty."),
			textSize = 12,
			color = "dim",
			size = UDim2.new(1, 0, 0, 30),
			wrapped = true,
			xalign = Enum.TextXAlignment.Center,
		})

		currentCard = card

		task.delay(HOLD_FAILURE, function()
			if token == cardToken then
				destroyCurrent()
			end
		end)
	end

	local function showCatch(p: Types.CastResultPayload)
		destroyCurrent()
		cardToken += 1
		local token = cardToken
		local cardConns: Ui.Conns = {}

		local speciesId = if type(p.speciesId) == "string" then p.speciesId else nil
		local species = if speciesId then Species.get(speciesId) else nil

		-- career fields are pending Types.luau additions, so they are read
		-- untyped and rendered only when present; command-bar fixtures and
		-- older payloads still lay out cleanly
		local add: any = p
		local levelUp = type(add.level) == "number"
			and type(add.unlockedGear) == "table"
			and #add.unlockedGear > 0

		-- wallet fields are contract-optional (set only when ok == true):
		-- the id the sale will point at, and the quote in cents
		local catchId = if type(add.catchId) == "string" then add.catchId else nil
		local hasDecision = catchId ~= nil and #catchId > 0
		local quotedCents = if type(add.valueCents) == "number" then add.valueCents else nil

		-- idle | waiting | gone | done — guards double-fires and lets the
		-- auto-dismiss timer stand down while a sale is in flight
		local sellState = "idle"

		local celebrate = p.rare == true or p.inRun == true or levelUp

		local card = Ui.frame(root, {
			name = "CatchCard",
			size = UDim2.fromOffset(320, 0),
			pos = UDim2.fromScale(0.5, 0.4),
			anchor = Vector2.new(0.5, 0.5),
			color = "panel",
			transparency = 0.03,
			corner = 14,
			strokeColor = if celebrate then "gold" else "deep",
			strokeWidth = if celebrate then 1.5 else 1,
		})
		card.AutomaticSize = Enum.AutomaticSize.Y
		local list = Instance.new("UIListLayout")
		list.Padding = UDim.new(0, 6)
		list.Parent = card
		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0, 14)
		pad.PaddingBottom = UDim.new(0, 10)
		pad.PaddingLeft = UDim.new(0, 16)
		pad.PaddingRight = UDim.new(0, 16)
		pad.Parent = card

		local pop = Instance.new("UIScale")
		pop.Scale = 0.92
		pop.Parent = card
		Ui.tween(pop, 0.18, { Scale = 1 })

		-- what it is
		Ui.label(card, {
			text = "🐟",
			textSize = 26,
			size = UDim2.new(1, 0, 0, 30),
			xalign = Enum.TextXAlignment.Center,
		})
		Ui.label(card, {
			text = if species
				then species.displayName
				elseif speciesId then speciesId
				else "something took the line",
			textSize = 21,
			font = Enum.Font.GothamBold,
			size = UDim2.new(1, 0, 0, 24),
			xalign = Enum.TextXAlignment.Center,
		})
		if species then
			Ui.label(card, {
				text = species.scientificName,
				textSize = 11,
				color = "dim",
				size = UDim2.new(1, 0, 0, 14),
				xalign = Enum.TextXAlignment.Center,
			})
		end
		local regionName = regionNames[p.regionId]
		if regionName then
			Ui.label(card, {
				text = "at " .. regionName,
				textSize = 11,
				color = "dim",
				size = UDim2.new(1, 0, 0, 14),
				xalign = Enum.TextXAlignment.Center,
			})
		end

		-- what the market is doing to this species right now — direction and
		-- scarcity off the latest MarketSync, so the decision below is a read
		-- of live information. Server numbers, laid out.
		local marketRow = if speciesId then marketBySpecies[speciesId] else nil
		if marketRow then
			local dirText = "market flat"
			local dirColor = "dim"
			if marketRow.direction == "rising" then
				dirText = "market rising ▲"
				dirColor = "gold"
			elseif marketRow.direction == "falling" then
				dirText = "market falling ▼"
				dirColor = "amber"
			end
			Ui.label(card, {
				text = string.format(
					"%s · ×%.1f scarcity",
					dirText,
					marketRow.scarcityMultiplier
				),
				textSize = 11,
				font = Enum.Font.GothamBold,
				color = dirColor,
				size = UDim2.new(1, 0, 0, 14),
				xalign = Enum.TextXAlignment.Center,
			})
		end

		-- what it is worth — the server's cents quote when the payload has
		-- one, the legacy value line when it does not. Either way this is a
		-- QUOTE, not a payment: the money moves only when the server answers
		-- a sell.
		Ui.label(card, {
			text = Ui.formatWeight(Ui.tonum(p.weightKg, 0)),
			textSize = 12,
			color = "dim",
			size = UDim2.new(1, 0, 0, 14),
			xalign = Enum.TextXAlignment.Center,
		})
		if quotedCents ~= nil then
			Ui.label(card, {
				text = "worth about " .. formatMoney(quotedCents),
				textSize = 20,
				font = Enum.Font.GothamBold,
				color = "gold",
				size = UDim2.new(1, 0, 0, 24),
				xalign = Enum.TextXAlignment.Center,
			})
		else
			Ui.label(card, {
				text = "+ " .. Ui.formatInt(Ui.tonum(p.value, 0)),
				textSize = 20,
				font = Enum.Font.GothamBold,
				color = "gold",
				size = UDim2.new(1, 0, 0, 24),
				xalign = Enum.TextXAlignment.Center,
			})
		end

		-- what the catch taught the skipper, next to what it paid
		if type(add.xpGained) == "number" and add.xpGained > 0 then
			Ui.label(card, {
				text = "+" .. Ui.formatInt(add.xpGained) .. " xp",
				textSize = 11.5,
				color = "dim",
				size = UDim2.new(1, 0, 0, 14),
				xalign = Enum.TextXAlignment.Center,
			})
		end

		if levelUp then
			local names: { string } = {}
			for _, id in add.unlockedGear do
				local gear = Types.Gear[id]
				table.insert(names, if gear then gear.displayName else id)
			end
			banner(
				card,
				("LEVEL %d — %s within reach"):format(
					math.floor(add.level),
					table.concat(names, ", ")
				),
				"gold",
				true
			)
		end

		-- the flags, each in its own voice
		if p.inRun == true then
			banner(card, "🐟 SALMON RUN — the run is on", "gold", true)
		end
		if p.rare == true then
			banner(card, "★ Rare catch", "gold", false)
		end
		if p.contested == true then
			banner(card, "⚔ Another crew just worked this ground", "amber", true)
		end

		-- ground impact: the bar shows where abundance AFTER landed, the pale
		-- tick marks where it was BEFORE the cast. Rendering server numbers,
		-- nothing more.
		local abundanceAfter = math.clamp(Ui.tonum(p.abundanceAfter, 0), 0, 1)
		local abundanceBefore = math.clamp(Ui.tonum(p.abundanceBefore, 0), 0, 1)
		local captionRow = Ui.frame(card, {
			name = "GroundCaption",
			size = UDim2.new(1, 0, 0, 14),
			transparency = 1,
		})
		Ui.label(captionRow, {
			text = "THIS GROUND",
			textSize = 9,
			font = Enum.Font.GothamBold,
			color = "dim",
		})
		local pctLeft = math.floor(abundanceAfter * 100 + 0.5)
		Ui.label(captionRow, {
			text = tostring(pctLeft) .. "% left",
			textSize = 9,
			font = Enum.Font.GothamBold,
			color = if p.depleted then "danger" else "dim",
			pos = UDim2.fromScale(1, 0),
			anchor = Vector2.new(1, 0),
			xalign = Enum.TextXAlignment.Right,
		})
		local meter = Ui.meter(card, if p.depleted then "danger" else "water", {
			name = "GroundMeter",
			size = UDim2.new(1, 0, 0, 6),
			color = "deep",
			corner = 3,
		})
		Ui.setMeter(meter, abundanceAfter)
		Ui.frame(meter.track, {
			name = "Before",
			size = UDim2.new(0, 2, 1, 0),
			pos = UDim2.fromScale(abundanceBefore, 0),
			anchor = Vector2.new(0.5, 0),
			color = "white",
			transparency = 0.35,
			zindex = 3,
		})

		if p.depleted == true then
			banner(card, "You thinned this ground out", "danger", false)
			Ui.label(card, {
				text = "it will fish poorly until it recovers",
				textSize = 10,
				color = "dim",
				size = UDim2.new(1, 0, 0, 12),
				xalign = Enum.TextXAlignment.Center,
			})
		end

		local status = Ui.label(card, {
			text = "",
			textSize = 10,
			color = "dim",
			size = UDim2.new(1, 0, 0, 13),
			xalign = Enum.TextXAlignment.Center,
		})

		if hasDecision then
			-- the decision. The fish is already in the server-side hold, so
			-- KEEP (or doing nothing, or the auto-dismiss) simply leaves it
			-- there to sell later from the market panel; SELL asks the server
			-- to convert it now, at whatever the market pays at that moment.
			local decision = Ui.frame(card, {
				name = "Decision",
				size = UDim2.new(1, 0, 0, 38),
				transparency = 1,
			})
			local keepBtn = Ui.button(decision, {
				name = "Keep",
				text = "KEEP",
				textSize = 13.5,
				textColor = "text",
				bgColor = "deep",
				transparency = 0.25,
				corner = 8,
				size = UDim2.new(0.48, -2, 1, 0),
				pos = UDim2.fromScale(0, 0),
			})
			local sellBtn = Ui.button(decision, {
				name = "Sell",
				text = "SELL",
				textSize = 13.5,
				textColor = "deep",
				bgColor = "gold",
				corner = 8,
				size = UDim2.new(0.52, -2, 1, 0),
				pos = UDim2.fromScale(0.48, 0),
			})

			status.Text = "sell now, or it goes to your hold"

			local function setDecisionEnabled(enabled: boolean, sellText: string?)
				keepBtn.Active = enabled
				sellBtn.Active = enabled
				keepBtn.AutoButtonColor = enabled
				sellBtn.AutoButtonColor = enabled
				sellBtn.Text = sellText or "SELL"
			end

			Ui.connect(cardConns, keepBtn.Activated, function()
				if token == cardToken and sellState ~= "waiting" then
					destroyCurrent()
				end
			end)

			Ui.connect(cardConns, sellBtn.Activated, function()
				if token ~= cardToken or sellState ~= "idle" then
					return
				end
				local remote = sellRequestRemote
				if not remote then
					status.Text = "wallet not connected yet — kept in the hold"
					status.Color3 = Ui.color("amber")
					return
				end

				sellState = "waiting"
				setDecisionEnabled(false, "SELL …")
				status.Text = "waiting on the server…"
				status.Color3 = Ui.color("dim")

				sellFinish = function(payload: any)
					if token ~= cardToken or typeof(payload) ~= "table" then
						return
					end
					if payload.ok == true and type(payload.paidCents) == "number" then
						sellState = "done"
						setDecisionEnabled(false, "SOLD")
						local paid = Ui.tonum(payload.paidCents, 0)
						local line = "sold for " .. formatMoney(paid)
						-- the drift note compares the server's paid price to
						-- the server's quoted price — both off the wire; the
						-- client only phrases the difference
						if quotedCents ~= nil then
							local delta = paid - quotedCents
							if delta > 0 then
								line ..= " ▲ the market moved your way"
							elseif delta < 0 then
								line ..= " ▼ the market slipped"
							end
						end
						if type(payload.balanceCents) == "number" then
							line ..= " · balance " .. formatMoney(
								Ui.tonum(payload.balanceCents, 0)
							)
						end
						status.Text = line
						status.Color3 = Ui.color("good")
						task.delay(HOLD_SOLD, function()
							if token == cardToken then
								destroyCurrent()
							end
						end)
						return
					end

					local reason = if type(payload.reason) == "string" then payload.reason else ""
					if reason == "no such catch" then
						-- the fish is gone (sold twice, stale card after a
						-- restart): nothing left to decide, only acknowledge
						sellState = "gone"
						setDecisionEnabled(false, "GONE")
						status.Text = SELL_REASON_TEXT[reason]
					else
						sellState = "idle"
						setDecisionEnabled(true, "SELL")
						status.Text = SELL_REASON_TEXT[reason] or "the server refused that sale"
						-- re-arm a short dismiss: the original timer stood
						-- down when the sale went in flight
						task.delay(HOLD_FAILURE + 1, function()
							if token == cardToken and sellState ~= "waiting" then
								destroyCurrent()
							end
						end)
					end
					status.Color3 = Ui.color("danger")
				end

				-- the server answers every sell, but a dropped remote must
				-- not leave the card stuck waiting forever
				task.delay(SELL_WATCHDOG, function()
					if token == cardToken and sellState == "waiting" then
						sellState = "idle"
						sellFinish = nil
						setDecisionEnabled(true, "SELL")
						status.Text = "no answer from the server — the fish is still in your hold"
						status.Color3 = Ui.color("danger")
					end
				end)

				remote:FireServer({ catchId = catchId })
			end)
		else
			-- no catch id (failure payloads predate the wallet; legacy cards
			-- can only be dismissed): the whole card is the dismiss target —
			-- nobody aims at a small ✕ with a thumb
			status.Text = "tap to dismiss"
			local overlay = Ui.button(card, {
				name = "Dismiss",
				size = UDim2.fromScale(1, 1),
				pos = UDim2.fromScale(0, 0),
				transparency = 1,
				zindex = 30,
			})
			Ui.connect(cardConns, overlay.Activated, function()
				if token == cardToken then
					destroyCurrent()
				end
			end)
		end

		currentCardConns = cardConns
		currentCard = card

		-- the auto-dismiss is an implicit KEEP — the fish stays in the hold
		-- either way — so it stands down only while a sale is in flight
		task.delay(if celebrate then HOLD_CELEBRATE else HOLD_NORMAL, function()
			if token == cardToken and sellState ~= "waiting" then
				destroyCurrent()
			end
		end)
	end

	-- ---------------------------------------------------------------------------
	-- Server payloads
	-- ---------------------------------------------------------------------------

	local function onCastResult(payload: any)
		if typeof(payload) ~= "table" then
			return
		end

		local p = payload :: Types.CastResultPayload
		if p.ok == true then
			showCatch(p)
		else
			showFailure(p.reason)
		end
	end

	local function onOceanSync(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		local p = payload :: Types.OceanSyncPayload
		for _, region in Ui.normalizeRegions(p.regions) do
			regionNames[region.id] = region.name
		end
	end

	local function onMarketSync(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		local p = payload :: Types.MarketSyncPayload
		for _, entry in Ui.normalizeMarketEntries((p :: any).entries) do
			marketBySpecies[entry.speciesId] = entry
		end
	end

	local function onSellResult(payload: any)
		-- routed to whichever card has a sale in flight; a result with no
		-- waiting card (the card was kept, dismissed, replaced) is dropped
		local fn = sellFinish
		if fn then
			fn(payload)
		end
	end

	-- Casting owns the CastResult remote and checks the answer against the cast
	-- it belongs to before anyone else hears about it, so the card listens to
	-- that checked answer rather than the wire. This is a LocalScript sibling
	-- and LocalScripts cannot require each other, which is why this is a bus
	-- message and not a call (docs/CASTING.md, defect 1).
	task.spawn(function()
		for _ = 1, 15 do
			local bus = playerGui:WaitForChild("SlackWaterCastBus", 10)
			if bus and bus:IsA("BindableEvent") then
				Ui.connect(connections, (bus :: BindableEvent).Event, function(msg: any)
					if typeof(msg) == "table" and msg.kind == "fight" and msg.event == "result" then
						onCastResult(msg.data)
					end
				end)
				break
			end
			task.wait(2)
		end
	end)
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
		Ui.disconnectAll(connections)
	end)
end

-- Standalone interpreter: no Roblox runtime, stop before touching any global
-- so `luau <file>` is a clean syntax gate (scripts-check.sh).
if game == nil then
	return
end

main()
