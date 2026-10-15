--!strict
--[[
	CatchCard — the cast result.

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

	Tap anywhere to dismiss; cards auto-dismiss faster when they are bad news
	and hang around when they are worth looking at.
]]

local Ui = require(script and script.Parent.Ui or "./Ui")

local HOLD_NORMAL = 4.0
local HOLD_CELEBRATE = 6.5
local HOLD_FAILURE = 2.6

-- plain-language forms of the server's machine reasons
local REASON_TEXT: { [string]: string } = {
	["malformed request"] = "That cast never went out.",
	["unknown species"] = "That fish is not in these waters.",
	["unknown region"] = "That ground is not on your chart.",
	["nothing here"] = "Nothing biting — the ground is spent.",
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

	-- ---------------------------------------------------------------------------
	-- Card construction
	-- ---------------------------------------------------------------------------

	-- a token invalidates the previous card's pending auto-dismiss, so a new
	-- cast mid-display swaps cards cleanly instead of fighting a timer
	local cardToken = 0
	local currentCard: Frame? = nil
	local currentCardConns: Ui.Conns? = nil

	local function destroyCurrent(): ()
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

		-- what it is worth — both numbers straight off the wire
		Ui.label(card, {
			text = Ui.formatWeight(Ui.tonum(p.weightKg, 0)),
			textSize = 12,
			color = "dim",
			size = UDim2.new(1, 0, 0, 14),
			xalign = Enum.TextXAlignment.Center,
		})
		Ui.label(card, {
			text = "+ " .. Ui.formatInt(Ui.tonum(p.value, 0)),
			textSize = 20,
			font = Enum.Font.GothamBold,
			color = "gold",
			size = UDim2.new(1, 0, 0, 24),
			xalign = Enum.TextXAlignment.Center,
		})

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

		Ui.label(card, {
			text = "tap to dismiss",
			textSize = 9,
			color = "dim",
			size = UDim2.new(1, 0, 0, 12),
			xalign = Enum.TextXAlignment.Center,
		})

		-- the whole card is the dismiss target: nobody aims at a small ✕ with
		-- a thumb
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

		currentCardConns = cardConns
		currentCard = card

		task.delay(if celebrate then HOLD_CELEBRATE else HOLD_NORMAL, function()
			if token == cardToken then
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
