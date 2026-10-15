--!strict
--[[
	CastBar — the way in.

	Until this file existed the game had a fight minigame and no way to start
	it (docs/PLAYLOOP.md, defect 1): `Casting.start()` was called by nothing,
	there was no ground picker, no species picker, no depth control and no
	cast button. A player could not fish.

	This panel owns the bottom edge of the screen: a big CAST button (reachable
	with one thumb on a phone), a rig sheet for choosing ground / species /
	depth, the fight readout while the line is out, and honest failure — a cast
	the tide refuses says so, and says when the ground opens.

	BOUNDARIES (house rule 2)

	This panel computes nothing the server owns. Grounds, species presence,
	abundances and the tide hour are OceanSync data, normalized by
	Ui.normalizeRegions before anything here reads them. Depth legality and
	tide access are computed ONLY to decide which options to offer and how to
	caption them; the server arbitrates every outcome. A client that lies
	through this UI gets exactly one thing — a cast the server will judge on
	its own numbers.

	DRIVING THE MINIGAME

	Rojo maps `.client.luau` files as LocalScripts, and LocalScripts cannot
	require each other, so this panel talks to `Casting.client.luau` through
	the `SlackWaterCastBus` BindableEvent that Casting publishes in PlayerGui
	at boot. Message shapes are pinned in docs/CASTING.md.

	The pure half of this file (everything above `main`) is unit-tested by
	tests/cast-loop-tests.luau under the standalone interpreter; the UI half
	needs Studio and has never been run there by its author.
]]

local Ui = require(script and script.Parent.Ui or "./Ui")

--=============================================================================
-- Tuning
--=============================================================================

-- Refresh cadence of the bar itself (cooldown text, status fading). The
-- fight meters repaint per fight update; the picker rows only rebuild on
-- open / sync-while-closed / selection change, never under a finger.
local PULSE_SECONDS = 0.25

-- How far ahead "when does the tide open this ground" may look. One mixed
-- semidiurnal cycle fits inside 26 h, so a ground that has not opened by then
-- is not going to; the honest caption says so instead of a spinner.
local ACCESS_LOOKAHEAD_HOURS = 26

-- Depth snaps to this many metres while dragging: a ~300 px track across a
-- 700 m band resolves coarser than a metre, and an unrounded number flickers.
local DEPTH_STEP = 5

-- Seconds a status line stays up before fading back to nothing.
local STATUS_HOLD = 7

-- Mirror of the HUD's feed-staleness bound (OCEAN_STALE_AFTER): past it the
-- tide captions stop claiming to be current.
local FEED_STALE_AFTER = 12

-- If the fight never begins after a cast message (the Casting boot block
-- dead or errored), give up on the guard after this many seconds rather than
-- locking the button forever.
local RIG_SILENCE = 5

-- Second belt over Casting's own resolve timeout: if "waiting" has outlived
-- this, release the guard no matter what the state machine thinks.
local WAIT_WATCHDOG = 16

local DEFAULT_HOURS_PER_SECOND = 1 / 20 -- one game hour per 20 s, as OceanService runs

--=============================================================================
-- Pure selection logic
--
-- Everything below runs identically under the standalone interpreter and in
-- Studio, takes plain data (Ui.RegionRow / the Shared species roster shape)
-- and injectable dependencies (the Tide module), and decides nothing the
-- server owns: these rules choose which intents to OFFER.
--=============================================================================

export type SpeciesInfo = {
	id: string,
	minDepth: number,
	maxDepth: number,
}

export type RegionInfo = {
	id: string,
	chartedDepth: number,
	species: { string },
	abundances: { [string]: number },
}

export type Selection = {
	regionId: string?,
	speciesId: string?, -- nil = "whatever's there"
	depth: number?, -- nil = mid-band, the informed default Casting applies
}

--- The depth window a species can be fished at over a ground: its biological
--- band, capped by the charted floor. A line set deeper than the floor is not
--- fishing, it is dragging anchor. Returns nil, nil when the window is empty
--- (the ground is too shallow for the species to ever be in it).
function CastBar_depthWindow(chartedDepth: number, species: SpeciesInfo): (number?, number?)
	local ceiling = math.min(species.maxDepth, chartedDepth)
	if ceiling < species.minDepth then
		return nil, nil
	end
	return species.minDepth, ceiling
end

--- Why this species cannot be targeted at this ground right now, or nil when
--- it can. Presence is the server's own list; depth is chart honesty.
function CastBar_speciesBlockReason(region: RegionInfo, species: SpeciesInfo): string?
	if not table.find(region.species, species.id) then
		return "not in these waters"
	end
	local lo, hi = CastBar_depthWindow(region.chartedDepth, species)
	if lo == nil or hi == nil then
		return "lives deeper than this ground"
	end
	return nil
end

--- Present species with a legal depth window, most abundant first. The order
--- is a pure function of the payload: abundance desc, id asc as tie-break,
--- and the input is the server's ordered array, never a hash.
function CastBar_legalPresentSpecies(
	region: RegionInfo,
	speciesById: (string) -> SpeciesInfo?
): { { id: string, abundance: number } }
	local out: { { id: string, abundance: number } } = {}
	for _, id in region.species do
		local species = speciesById(id)
		if species then
			local lo = CastBar_depthWindow(region.chartedDepth, species)
			if lo ~= nil then
				table.insert(out, { id = id, abundance = Ui.tonum(region.abundances[id], 0) })
			end
		end
	end
	table.sort(out, function(a, b)
		if a.abundance ~= b.abundance then
			return a.abundance > b.abundance
		end
		return a.id < b.id
	end)
	return out
end

--- "Whatever's there": the species a blind cast will actually target, taken
--- from the server's own abundance list. The client is choosing where to
--- point intent, not what lands — the server rolls the catch.
function CastBar_blindPick(region: RegionInfo, speciesById: (string) -> SpeciesInfo?): string?
	local legal = CastBar_legalPresentSpecies(region, speciesById)
	if #legal == 0 then
		return nil
	end
	return legal[1].id
end

--- Full pre-flight check of a selection. Structural only — the tide is a
--- moving gate and belongs to whoever holds the clock. Returns
--- (true, resolvedSpeciesId) when the cast may go out, else (false, reason).
--- A blind selection still resolves to a concrete species id here, because
--- the wire contract has no "anything" payload.
function CastBar_validateSelection(
	region: RegionInfo?,
	speciesById: (string) -> SpeciesInfo?,
	selection: Selection
): (boolean, string)
	if not region then
		return false, "choose a ground first"
	end

	local speciesId = selection.speciesId
	if speciesId == nil then
		local picked = CastBar_blindPick(region, speciesById)
		if picked == nil then
			return false, "nothing here worth a cast"
		end
		return true, picked
	end

	local species = speciesById(speciesId)
	if not species then
		return false, "that fish is not in these waters"
	end

	local blockReason = CastBar_speciesBlockReason(region, species)
	if blockReason then
		return false, blockReason
	end

	local lo, hi = CastBar_depthWindow(region.chartedDepth, species)
	if lo == nil or hi == nil then
		return false, "no depth works here"
	end

	if selection.depth ~= nil then
		-- wire-junk depths take a value no window can contain, never a crash
		local depth = Ui.tonum(selection.depth, math.huge)
		if depth < lo or depth > hi then
			return false, string.format("set the depth inside %d-%d m", lo, hi)
		end
	end

	return true, speciesId
end

--- Hours until the tide floats the boat over this ground, walking the same
--- harmonic sum the server gates casts with (Tide.accessAt). Returns nil when
--- the ground does not open within `lookaheadHours`. Display math only: the
--- server's gate at resolve time is the one that counts.
function CastBar_hoursUntilAccessible(
	tide: any,
	chartedDepth: number,
	fromHour: number,
	lookaheadHours: number
): number?
	local t = 0
	while t <= lookaheadHours do
		if tide.accessAt(chartedDepth, fromHour + t) then
			return t
		end
		t += 0.1
	end
	return nil
end

--- The caption for a closed ground: when it opens, on the clock the player
--- is actually looking at, and how far away that is.
function CastBar_opensText(hoursUntil: number?, fromHour: number): string
	if hoursUntil == nil then
		return "dry at every tide we can see"
	end
	if hoursUntil <= 0.05 then
		return "opening now"
	end
	return string.format("opens ~%s · in %.1f h", Ui.clockFace(fromHour + hoursUntil), hoursUntil)
end

--=============================================================================
-- The double-cast guard
--
-- One cast at a time, and the server's cooldown honoured from the moment its
-- answer came back. All timing is injected (`now`), so the rules are testable
-- and deterministic.
--=============================================================================

export type Guard = {
	busy: boolean,
	beganAt: number,
	waitingSince: number?,
	lastResultAt: number?,
}

function CastBar_newGuard(): Guard
	return { busy = false, beganAt = 0, waitingSince = nil, lastResultAt = nil }
end

--- May a new cast begin? A press while the line is out is ignored, not
--- queued; a press inside the cooldown is refused until the server would
--- accept the request.
function CastBar_guardTryBegin(guard: Guard, now: number, cooldown: number): boolean
	if guard.busy then
		return false
	end
	local last = guard.lastResultAt
	if last ~= nil and now - last < cooldown then
		return false
	end
	guard.busy = true
	guard.beganAt = now
	guard.waitingSince = nil
	return true
end

--- The server answered (result, success or refusal): the cooldown clock
--- starts here, at the moment the request actually resolved.
function CastBar_guardResult(guard: Guard, now: number): ()
	guard.busy = false
	guard.lastResultAt = now
	guard.waitingSince = nil
end

--- The cast ended without asking the server (line parted, reeled in,
--- refused before it began): no cooldown is owed.
function CastBar_guardEnd(guard: Guard): ()
	guard.busy = false
	guard.waitingSince = nil
end

--- Has a resolve waited past all patience? Belt over Casting's own timeout,
--- so a lost event can never lock the button.
function CastBar_guardWaitExpired(guard: Guard, now: number, waitTimeout: number): boolean
	local since = guard.waitingSince
	return guard.busy and since ~= nil and now - since > waitTimeout
end

--- Seconds of cooldown left to show on the button. Zero while a cast runs —
--- the button is showing the fight then, not a countdown.
function CastBar_cooldownRemaining(guard: Guard, now: number, cooldown: number): number
	local last = guard.lastResultAt
	if guard.busy or last == nil then
		return 0
	end
	return math.max(0, cooldown - (now - last))
end

function CastBar_cooldownText(remaining: number): string
	if remaining <= 0.05 then
		return "ready"
	end
	return string.format("%.1fs", remaining)
end

-- Exported surface for tests (the local names keep the call sites short).
local CastBar = {
	depthWindow = CastBar_depthWindow,
	speciesBlockReason = CastBar_speciesBlockReason,
	legalPresentSpecies = CastBar_legalPresentSpecies,
	blindPick = CastBar_blindPick,
	validateSelection = CastBar_validateSelection,
	hoursUntilAccessible = CastBar_hoursUntilAccessible,
	opensText = CastBar_opensText,
	newGuard = CastBar_newGuard,
	guardTryBegin = CastBar_guardTryBegin,
	guardResult = CastBar_guardResult,
	guardEnd = CastBar_guardEnd,
	guardWaitExpired = CastBar_guardWaitExpired,
	cooldownRemaining = CastBar_cooldownRemaining,
	cooldownText = CastBar_cooldownText,
}

--=============================================================================
-- The panel
--=============================================================================

--- The "begin" event's payload is the initial state blob, not a snapshot;
--- synthesize the one shape `onFightUpdate` reads so the meters start honest
--- instead of jumping a frame later.
local function snapshotFromBegin(beginData: any): any
	local stamina = 1
	if typeof(beginData) == "table" then
		stamina = Ui.tonum(beginData.stamina, 1)
	end
	return { tension01 = 0, progress = 0, stamina = stamina }
end

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
	local Species = require(Shared:WaitForChild("Species") :: ModuleScript)
	local Config = require(Shared:WaitForChild("Config") :: ModuleScript)
	local Tide = require(Shared:WaitForChild("Tide") :: ModuleScript)

	local connections: Ui.Conns = {}
	local clock = Ui.newClock(DEFAULT_HOURS_PER_SECOND)

	local regions: { Ui.RegionRow } = {}
	local lastSyncAt = 0
	local selection: Selection = { regionId = nil, speciesId = nil, depth = nil }
	local guard = CastBar.newGuard()
	local pickerOpen = false
	local pickerDirty = false
	local rigAlive = false -- did the CastBus answer with at least one fight event
	local statusUntil = 0
	local fightShown = false

	-- ---------------------------------------------------------------------------
	-- Build: the bar
	-- ---------------------------------------------------------------------------

	local gui = Ui.screenGui("SlackWaterCastBar", 6, playerGui)
	local root = Ui.frame(gui, { name = "Root", transparency = 1 })
	Ui.autoScale(root)

	local bar = Ui.frame(root, {
		name = "Bar",
		size = UDim2.fromOffset(366, 100),
		pos = UDim2.new(0.5, 0, 1, -12),
		anchor = Vector2.new(0.5, 1),
		color = "panel",
		transparency = 0.08,
		corner = 12,
		strokeColor = "deep",
		strokeWidth = 1,
	})

	-- --- idle face: status line, CAST, rig summary ----------------------------

	local idle = Ui.frame(bar, {
		name = "Idle",
		size = UDim2.fromScale(1, 1),
		transparency = 1,
	})

	local statusLabel = Ui.label(idle, {
		name = "Status",
		text = "",
		size = UDim2.new(1, -24, 0, 20),
		pos = UDim2.fromOffset(12, 4),
		color = "dim",
		textSize = 10.5,
		wrapped = true,
	})

	local castButton = Ui.button(idle, {
		name = "Cast",
		text = "CAST",
		size = UDim2.fromOffset(150, 54),
		pos = UDim2.fromOffset(12, 32),
		bgColor = "water",
		textColor = "white",
		corner = 12,
		textSize = 22,
	})

	local summary = Ui.button(idle, {
		name = "Summary",
		text = "",
		size = UDim2.new(1, -186, 0, 54),
		pos = UDim2.new(1, -12, 0, 32),
		anchor = Vector2.new(1, 0),
		bgColor = "deep",
		transparency = 0.2,
		corner = 12,
	})

	local summaryGround = Ui.label(summary, {
		name = "Ground",
		text = "no ground chosen",
		size = UDim2.new(1, -16, 0, 18),
		pos = UDim2.fromOffset(10, 7),
		textSize = 13,
		font = Enum.Font.GothamBold,
	})

	local summaryRig = Ui.label(summary, {
		name = "Rig",
		text = "tap to rig the line",
		size = UDim2.new(1, -16, 0, 14),
		pos = UDim2.fromOffset(10, 27),
		color = "dim",
		textSize = 10.5,
	})

	-- --- fight face: what the minigame is doing --------------------------------

	local fight = Ui.frame(bar, {
		name = "Fight",
		size = UDim2.fromScale(1, 1),
		transparency = 1,
		visible = false,
	})

	local fightName = Ui.label(fight, {
		name = "Species",
		text = "—",
		size = UDim2.new(1, -96, 0, 16),
		pos = UDim2.fromOffset(12, 6),
		textSize = 13.5,
		font = Enum.Font.GothamBold,
	})

	local giveUp = Ui.button(fight, {
		name = "GiveUp",
		text = "✕ reel in",
		textSize = 10,
		textColor = "dim",
		size = UDim2.fromOffset(74, 20),
		pos = UDim2.new(1, -10, 0, 4),
		anchor = Vector2.new(1, 0),
		bgColor = "deep",
		transparency = 0.2,
		corner = 7,
	})

	local fightHint = Ui.label(fight, {
		name = "Hint",
		text = "hold anywhere to reel · release to give line",
		size = UDim2.new(1, -24, 0, 12),
		pos = UDim2.fromOffset(12, 84),
		color = "dim",
		textSize = 9.5,
	})

	local function meterRow(caption: string, y: number): Ui.Meter
		Ui.label(fight, {
			text = caption,
			textSize = 8.5,
			font = Enum.Font.GothamBold,
			color = "dim",
			size = UDim2.fromOffset(52, 14),
			pos = UDim2.fromOffset(12, y),
		})
		return Ui.meter(fight, "good", {
			name = caption,
			size = UDim2.new(1, -96, 0, 8),
			pos = UDim2.new(1, -12, 0, y + 2),
			anchor = Vector2.new(1, 0),
			color = "deep",
			corner = 4,
		})
	end

	local tensionMeter = meterRow("TENSION", 26)
	local progressMeter = meterRow("CATCH", 46)
	local staminaMeter = meterRow("STAMINA", 66)

	-- the safe band on the tension track is the whole game: inside it you are
	-- neither snapping the line nor wasting the fish (0.55..0.92, as Casting
	-- defines "in band")
	Ui.frame(tensionMeter.track, {
		name = "Band",
		size = UDim2.fromScale(0.37, 1),
		pos = UDim2.fromScale(0.55, 0),
		color = "white",
		transparency = 0.86,
		corner = 4,
	})

	-- ---------------------------------------------------------------------------
	-- Build: the rig sheet
	-- ---------------------------------------------------------------------------

	local picker = Ui.frame(root, {
		name = "Picker",
		size = UDim2.fromOffset(366, 470),
		pos = UDim2.new(0.5, 0, 1, -124),
		anchor = Vector2.new(0.5, 1),
		color = "panel",
		transparency = 0.04,
		corner = 12,
		strokeColor = "deep",
		strokeWidth = 1,
		visible = false,
	})

	Ui.label(picker, {
		text = "RIG THE LINE",
		textSize = 14,
		font = Enum.Font.GothamBold,
		size = UDim2.new(1, -48, 0, 18),
		pos = UDim2.fromOffset(12, 10),
	})

	local pickerClose = Ui.button(picker, {
		name = "Close",
		text = "✕",
		textSize = 14,
		textColor = "dim",
		size = UDim2.fromOffset(26, 26),
		pos = UDim2.new(1, -8, 0, 6),
		anchor = Vector2.new(1, 0),
		bgColor = "deep",
		transparency = 0.2,
		corner = 8,
	})

	local pickerBody = Ui.scroll(picker, {
		name = "Body",
		size = UDim2.new(1, -24, 1, -56),
		pos = UDim2.fromOffset(12, 36),
	})

	local pickerConns: Ui.Conns = {}

	-- ---------------------------------------------------------------------------
	-- State helpers
	-- ---------------------------------------------------------------------------

	local bus: BindableEvent? = nil

	local function currentRegion(): Ui.RegionRow?
		local id = selection.regionId
		if id == nil then
			return nil
		end
		for _, region in regions do
			if region.id == id then
				return region
			end
		end
		return nil
	end

	local function feedStale(): boolean
		return lastSyncAt == 0 or os.clock() - lastSyncAt > FEED_STALE_AFTER
	end

	local function showStatus(text: string, colorName: string)
		statusLabel.Text = text
		statusLabel.TextColor3 = Ui.color(colorName)
		statusUntil = os.clock() + STATUS_HOLD
	end

	local function publishSelection()
		if not bus then
			return
		end
		local region = currentRegion()
		bus:Fire({
			kind = "selection",
			regionId = selection.regionId,
			regionName = if region then region.name else nil,
		})
	end

	-- ---------------------------------------------------------------------------
	-- Picker construction (rebuilt wholesale; see the tuning note above)
	-- ---------------------------------------------------------------------------

	local function setFightShown(shown: boolean)
		fightShown = shown
		idle.Visible = not shown
		fight.Visible = shown
	end

	local function refreshBar()
		local region = currentRegion()
		if region then
			summaryGround.Text = region.name
			if selection.speciesId == nil then
				local hint = CastBar_blindPick(region, Species.get)
				local hintName = if hint
					then (Species.get(hint) :: any).displayName
					else "nothing biting"
				summaryRig.Text = "whatever's there · auto depth · ≈ " .. hintName
			else
				local species = Species.get(selection.speciesId)
				local depthText = if selection.depth == nil
					then "auto depth"
					else string.format("%d m", selection.depth :: number)
				summaryRig.Text = if species
					then species.displayName .. " · " .. depthText
					else selection.speciesId .. " · " .. depthText
			end
		else
			summaryGround.Text = "no ground chosen"
			summaryRig.Text = "tap to rig the line"
		end
	end

	local function rebuildPicker()
		Ui.disconnectAll(pickerConns)
		for _, child in pickerBody:GetChildren() do
			child:Destroy()
		end
		pickerDirty = false

		local layout = Instance.new("UIListLayout")
		layout.Padding = UDim.new(0, 4)
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = pickerBody

		local order = 0
		local function nextOrder(): number
			order += 1
			return order
		end

		local function sectionLabel(text: string)
			Ui.label(pickerBody, {
				text = text,
				textSize = 10,
				font = Enum.Font.GothamBold,
				color = "dim",
				size = UDim2.new(1, 0, 0, 18),
				layoutOrder = nextOrder(),
			})
		end

		local function selectGround(regionId: string)
			if selection.regionId == regionId then
				return
			end
			selection.regionId = regionId
			selection.speciesId = nil
			selection.depth = nil
			publishSelection()
			refreshBar()
			rebuildPicker()
		end

		local function selectSpecies(speciesId: string?)
			if selection.speciesId == speciesId then
				return
			end
			selection.speciesId = speciesId
			selection.depth = nil -- mid-band is the informed default; the slider makes it explicit
			refreshBar()
			rebuildPicker()
		end

		-- GROUNDS ------------------------------------------------------------
		local stale = feedStale()
		sectionLabel(
			if stale and #regions > 0 then "GROUNDS — feed lost, times may lie" else "GROUNDS"
		)

		if #regions == 0 then
			Ui.label(pickerBody, {
				text = "reading the chart…",
				color = "dim",
				textSize = 11,
				size = UDim2.new(1, 0, 0, 16),
				layoutOrder = nextOrder(),
			})
		end

		-- order: open grounds first by server-sent quality, then closed grounds
		-- by how soon the tide reopens them; the id is the final tie-break so
		-- the order is a pure function of the data
		local hour = Ui.clockHour(clock)
		local access: { [string]: { open: boolean, opensIn: number? } } = {}
		local ordered: { Ui.RegionRow } = {}
		for _, region in regions do
			table.insert(ordered, region)
			if stale then
				access[region.id] = { open = region.accessible, opensIn = nil }
			else
				local open = Tide.accessAt(region.chartedDepth, hour)
				local opensIn = if open
					then 0
					else CastBar_hoursUntilAccessible(
						Tide,
						region.chartedDepth,
						hour,
						ACCESS_LOOKAHEAD_HOURS
					)
				access[region.id] = { open = open, opensIn = opensIn }
			end
		end
		table.sort(ordered, function(a, b)
			local aa = access[a.id]
			local bb = access[b.id]
			if aa.open ~= bb.open then
				return aa.open
			end
			if aa.open then
				if a.quality ~= b.quality then
					return a.quality > b.quality
				end
			else
				local ao = aa.opensIn or math.huge
				local bo = bb.opensIn or math.huge
				if ao ~= bo then
					return ao < bo
				end
			end
			return a.id < b.id
		end)

		for _, region in ordered do
			local info = access[region.id]
			local row = Ui.button(pickerBody, {
				name = region.id,
				text = "",
				size = UDim2.new(1, 0, 0, 44),
				bgColor = "deep",
				transparency = 0.2,
				corner = 8,
				layoutOrder = nextOrder(),
			})
			if selection.regionId == region.id then
				Ui.frame(row, {
					name = "Selected",
					size = UDim2.new(0, 3, 1, -10),
					pos = UDim2.fromOffset(0, 5),
					color = "gold",
					corner = 2,
				})
			end
			Ui.label(row, {
				text = region.name,
				textSize = 12.5,
				font = Enum.Font.GothamBold,
				size = UDim2.new(1, -110, 0, 16),
				pos = UDim2.fromOffset(10, 5),
			})
			Ui.label(row, {
				text = string.format(
					"%s · charted %d m%s",
					region.habitat,
					region.chartedDepth,
					if region.provenance ~= "measured" then " ~" else ""
				),
				textSize = 9.5,
				color = "dim",
				size = UDim2.new(1, -110, 0, 12),
				pos = UDim2.fromOffset(10, 22),
			})
			if info.open then
				Ui.label(row, {
					text = string.format("%d%% now", math.floor(region.quality * 100 + 0.5)),
					textSize = 11,
					font = Enum.Font.GothamBold,
					color = "teal",
					size = UDim2.fromOffset(96, 14),
					pos = UDim2.new(1, -8, 0, 5),
					anchor = Vector2.new(1, 0),
					xalign = Enum.TextXAlignment.Right,
				})
			else
				Ui.label(row, {
					text = "WAIT FOR TIDE",
					textSize = 9.5,
					font = Enum.Font.GothamBold,
					color = "amber",
					size = UDim2.fromOffset(96, 12),
					pos = UDim2.new(1, -8, 0, 5),
					anchor = Vector2.new(1, 0),
					xalign = Enum.TextXAlignment.Right,
				})
				Ui.label(row, {
					text = if info.opensIn ~= nil
						then CastBar_opensText(info.opensIn, hour)
						else "…",
					textSize = 9,
					color = "dim",
					size = UDim2.fromOffset(96, 12),
					pos = UDim2.new(1, -8, 0, 18),
					anchor = Vector2.new(1, 0),
					xalign = Enum.TextXAlignment.Right,
				})
			end
			Ui.connect(pickerConns, row.Activated, function()
				selectGround(region.id)
			end)
		end

		-- TARGET --------------------------------------------------------------
		local region = currentRegion()
		if not region then
			sectionLabel("TARGET & DEPTH — pick a ground first")
		else
			sectionLabel("TARGET")

			local blindRow = Ui.button(pickerBody, {
				name = "Blind",
				text = "",
				size = UDim2.new(1, 0, 0, 36),
				bgColor = "deep",
				transparency = if selection.speciesId == nil then 0.1 else 0.35,
				corner = 8,
				layoutOrder = nextOrder(),
			})
			if selection.speciesId == nil then
				Ui.frame(blindRow, {
					name = "Selected",
					size = UDim2.new(0, 3, 1, -8),
					pos = UDim2.fromOffset(0, 4),
					color = "gold",
					corner = 2,
				})
			end
			Ui.label(blindRow, {
				text = "Whatever's there",
				textSize = 12,
				font = Enum.Font.GothamBold,
				size = UDim2.new(1, -120, 0, 16),
				pos = UDim2.fromOffset(10, 4),
			})
			local blindTarget = CastBar_blindPick(region, Species.get)
			Ui.label(blindRow, {
				text = if blindTarget
					then "≈ " .. (Species.get(blindTarget) :: any).displayName
					else "nothing here",
				textSize = 10,
				color = "dim",
				size = UDim2.fromOffset(110, 14),
				pos = UDim2.new(1, -8, 0, 6),
				anchor = Vector2.new(1, 0),
				xalign = Enum.TextXAlignment.Right,
			})
			Ui.connect(pickerConns, blindRow.Activated, function()
				selectSpecies(nil)
			end)

			local legalIds = {}
			for _, entry in CastBar_legalPresentSpecies(region, Species.get) do
				legalIds[entry.id] = true
				local species = Species.get(entry.id) :: any
				local row = Ui.button(pickerBody, {
					name = entry.id,
					text = "",
					size = UDim2.new(1, 0, 0, 36),
					bgColor = "deep",
					transparency = if selection.speciesId == entry.id then 0.1 else 0.35,
					corner = 8,
					layoutOrder = nextOrder(),
				})
				if selection.speciesId == entry.id then
					Ui.frame(row, {
						name = "Selected",
						size = UDim2.new(0, 3, 1, -8),
						pos = UDim2.fromOffset(0, 4),
						color = "gold",
						corner = 2,
					})
				end
				Ui.label(row, {
					text = species.displayName,
					textSize = 12,
					font = Enum.Font.GothamBold,
					size = UDim2.new(1, -150, 0, 16),
					pos = UDim2.fromOffset(10, 4),
				})
				Ui.label(row, {
					text = string.rep("●", species.harvestDifficulty)
						.. string.rep("○", 5 - species.harvestDifficulty),
					textSize = 9,
					color = "amber",
					size = UDim2.fromOffset(50, 12),
					pos = UDim2.new(1, -118, 0, 7),
					anchor = Vector2.new(1, 0),
					xalign = Enum.TextXAlignment.Right,
				})
				local meter = Ui.meter(row, "water", {
					name = "Abundance",
					size = UDim2.fromOffset(48, 4),
					pos = UDim2.new(1, -64, 0, 9),
					anchor = Vector2.new(1, 0),
					color = "deep",
					corner = 2,
				})
				Ui.setMeter(meter, math.clamp(entry.abundance, 0, 1))
				Ui.connect(pickerConns, row.Activated, function()
					selectSpecies(entry.id)
				end)
			end

			for _, species in Species.list do
				if legalIds[species.id] then
					continue
				end
				local reason = CastBar_speciesBlockReason(region, species)
				local row = Ui.frame(pickerBody, {
					name = species.id,
					size = UDim2.new(1, 0, 0, 26),
					color = "deep",
					transparency = 0.55,
					corner = 6,
					layoutOrder = nextOrder(),
				})
				Ui.label(row, {
					text = species.displayName,
					textSize = 10.5,
					color = "dim",
					size = UDim2.new(1, -130, 0, 14),
					pos = UDim2.fromOffset(10, 6),
				})
				Ui.label(row, {
					text = reason,
					textSize = 9,
					color = "dim",
					size = UDim2.fromOffset(120, 12),
					pos = UDim2.new(1, -8, 0, 7),
					anchor = Vector2.new(1, 0),
					xalign = Enum.TextXAlignment.Right,
				})
			end

			-- DEPTH -----------------------------------------------------------
			sectionLabel("DEPTH")
			local selectedSpecies = if selection.speciesId
				then Species.get(selection.speciesId)
				else nil
			-- multiple returns cannot come out of an if-expression (the second
			-- value would be silently dropped), so assign through an explicit
			-- block
			local lo: number? = nil
			local hi: number? = nil
			if selectedSpecies then
				lo, hi = CastBar_depthWindow(region.chartedDepth, selectedSpecies)
			end

			if selection.speciesId == nil then
				Ui.label(pickerBody, {
					text = "auto — set to the middle of whatever takes the line",
					textSize = 10,
					color = "dim",
					size = UDim2.new(1, 0, 0, 16),
					layoutOrder = nextOrder(),
				})
			elseif lo == nil or hi == nil then
				Ui.label(pickerBody, {
					text = "no depth works here",
					textSize = 10,
					color = "danger",
					size = UDim2.new(1, 0, 0, 16),
					layoutOrder = nextOrder(),
				})
			elseif hi - lo < DEPTH_STEP then
				selection.depth = lo
				Ui.label(pickerBody, {
					text = string.format("only %d m of water suits them here", lo),
					textSize = 10,
					color = "dim",
					size = UDim2.new(1, 0, 0, 16),
					layoutOrder = nextOrder(),
				})
			else
				if selection.depth == nil or selection.depth < lo or selection.depth > hi then
					selection.depth = math.floor((lo + hi) / 2 / DEPTH_STEP + 0.5) * DEPTH_STEP
				end

				local depthHead = Ui.frame(pickerBody, {
					name = "DepthHead",
					size = UDim2.new(1, 0, 0, 16),
					transparency = 1,
					layoutOrder = nextOrder(),
				})
				Ui.label(depthHead, {
					text = string.format("window %d-%d m", lo, hi),
					textSize = 9.5,
					color = "dim",
				})
				local valueLabel = Ui.label(depthHead, {
					text = string.format("%d m", selection.depth :: number),
					textSize = 12,
					font = Enum.Font.GothamBold,
					color = "gold",
					pos = UDim2.fromScale(1, 0),
					anchor = Vector2.new(1, 0),
					xalign = Enum.TextXAlignment.Right,
				})

				local track = Ui.frame(pickerBody, {
					name = "DepthTrack",
					size = UDim2.new(1, 0, 0, 28),
					color = "deep",
					transparency = 0.2,
					corner = 8,
					layoutOrder = nextOrder(),
				})
				local fill = Ui.frame(track, {
					name = "Fill",
					size = UDim2.fromScale(0, 0.4),
					pos = UDim2.fromScale(0, 0.3),
					color = "water",
					corner = 8,
				})
				local handle = Ui.frame(track, {
					Name = "Handle",
					size = UDim2.fromOffset(18, 18),
					pos = UDim2.new(0, -9, 0.5, 0),
					anchor = Vector2.new(0, 0.5),
					color = "white",
					corner = 9,
				})

				local function applyDepth(depth: number)
					selection.depth = depth
					local span = hi - lo
					local fraction = if span > 0 then (depth - lo) / span else 0
					fill.Size = UDim2.fromScale(math.clamp(fraction, 0, 1), 0.4)
					handle.Position = UDim2.new(math.clamp(fraction, 0, 1), -9, 0.5, 0)
					valueLabel.Text = string.format("%d m", depth)
				end
				applyDepth(selection.depth :: number)

				local dragging = false
				local function depthFromX(x: number)
					local fraction =
						math.clamp((x - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
					local raw = lo + fraction * (hi - lo)
					applyDepth(math.clamp(math.floor(raw / DEPTH_STEP + 0.5) * DEPTH_STEP, lo, hi))
					refreshBar()
				end
				Ui.connect(pickerConns, track.InputBegan, function(input: InputObject)
					if
						input.UserInputType == Enum.UserInputType.Touch
						or input.UserInputType == Enum.UserInputType.MouseButton1
					then
						dragging = true
						depthFromX(input.Position.X)
					end
				end)
				Ui.connect(pickerConns, track.InputChanged, function(input: InputObject)
					if dragging then
						depthFromX(input.Position.X)
					end
				end)
				Ui.connect(pickerConns, track.InputEnded, function(input: InputObject)
					if
						input.UserInputType == Enum.UserInputType.Touch
						or input.UserInputType == Enum.UserInputType.MouseButton1
					then
						dragging = false
					end
				end)
			end
		end
	end

	local function setPickerOpen(open: boolean)
		if pickerOpen == open then
			return
		end
		pickerOpen = open
		if open then
			if pickerDirty then
				rebuildPicker()
			end
			picker.Visible = true
			-- yield the screen to any open right-edge sheet through the shared
			-- attribute channel (Ui.makeSheet); no cross-script references
			playerGui:SetAttribute("SlackWaterOpenPanel", nil)
		else
			picker.Visible = false
		end
	end

	-- ---------------------------------------------------------------------------
	-- Casting
	-- ---------------------------------------------------------------------------

	local function onCastPressed()
		setPickerOpen(false)

		if not bus then
			showStatus("the rig is not answering", "danger")
			return
		end

		local region = currentRegion()
		local ok, answer = CastBar_validateSelection(region, Species.get, selection)
		if not ok then
			showStatus(answer, "danger")
			setPickerOpen(true)
			return
		end

		-- The tide pre-gate: offer the cast only when the water floats the
		-- boat. This is display math on the same harmonic sum the server
		-- gates with; the server's check at resolve time is the real one.
		if clock.synced and region and not feedStale() then
			local hour = Ui.clockHour(clock)
			if not Tide.accessAt(region.chartedDepth, hour) then
				local opensIn = CastBar_hoursUntilAccessible(
					Tide,
					region.chartedDepth,
					hour,
					ACCESS_LOOKAHEAD_HOURS
				)
				showStatus(
					("The tide has this ground under you — %s."):format(
						CastBar_opensText(opensIn, hour)
					),
					"amber"
				)
				return
			end
		end

		local now = os.clock()
		if not CastBar_guardTryBegin(guard, now, Config.CAST_COOLDOWN) then
			if guard.busy then
				showStatus("the line is already out", "dim")
			else
				showStatus(
					"too soon — "
						.. CastBar_cooldownText(
							CastBar_cooldownRemaining(guard, now, Config.CAST_COOLDOWN)
						),
					"dim"
				)
			end
			return
		end

		rigAlive = false
		bus:Fire({
			kind = "cast",
			regionId = selection.regionId,
			speciesId = answer,
			depth = selection.depth,
		})
	end

	local function onFightUpdate(snapshot: any)
		if typeof(snapshot) ~= "table" then
			return
		end
		local tension01 = math.clamp(Ui.tonum(snapshot.tension01, 0), 0, 1)
		Ui.setMeter(tensionMeter, tension01)
		tensionMeter.fill.BackgroundColor3 = if tension01 > 0.92
			then Ui.color("danger")
			elseif tension01 < 0.55 then Ui.color("dim")
			else Ui.color("good")
		Ui.setMeter(progressMeter, math.clamp(Ui.tonum(snapshot.progress, 0) / 100, 0, 1))
		Ui.setMeter(staminaMeter, math.clamp(Ui.tonum(snapshot.stamina, 0) / 2, 0, 1))
	end

	local function onBus(msg: any)
		if typeof(msg) ~= "table" or msg.kind ~= "fight" then
			return
		end
		local event = msg.event
		local data = msg.data

		if event == "begin" then
			rigAlive = true
			local species = if typeof(data) == "table" then data.species else nil
			fightName.Text = if typeof(species) == "table"
				then species.displayName
				else "something took the line"
			onFightUpdate(snapshotFromBegin(data))
			setFightShown(true)
		elseif event == "update" then
			onFightUpdate(data)
		elseif event == "landed" then
			-- the fight is won; the server now decides what it was worth
			guard.waitingSince = os.clock()
			fightHint.Text = "landed — the shore is weighing it…"
		elseif event == "lost" then
			local reason = if typeof(data) == "table" and type(data.reason) == "string"
				then data.reason
				else "the line came back empty"
			CastBar_guardEnd(guard)
			fightHint.Text = "hold anywhere to reel · release to give line"
			setFightShown(false)
			refreshBar()
			showStatus(reason, "danger")
		elseif event == "result" then
			CastBar_guardResult(guard, os.clock())
			fightHint.Text = "hold anywhere to reel · release to give line"
			setFightShown(false)
			refreshBar()
			if typeof(data) == "table" then
				if data.ok == true then
					local note = ""
					if Ui.tonum(data.tideQuality, 0) >= 0.8 then
						note = " · fought at slack water"
					end
					showStatus(
						string.format("landed · %s%s", Ui.formatInt(Ui.tonum(data.value, 0)), note),
						"gold"
					)
				else
					local reason = if type(data.reason) == "string"
						then data.reason
						else "the cast came back empty"
					showStatus(reason, "danger")
				end
			else
				showStatus("the cast came back empty", "danger")
			end
		elseif event == "cancel" then
			CastBar_guardEnd(guard)
			fightHint.Text = "hold anywhere to reel · release to give line"
			setFightShown(false)
			refreshBar()
			showStatus("reeled in", "dim")
		elseif event == "error" then
			local reason = if typeof(data) == "table" and type(data.reason) == "string"
				then data.reason
				else "that cast never went out"
			CastBar_guardEnd(guard)
			setFightShown(false)
			refreshBar()
			showStatus(reason, "danger")
		end
	end

	-- ---------------------------------------------------------------------------
	-- Server payloads and the bus
	-- ---------------------------------------------------------------------------

	local function onOceanSync(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		local p = payload :: any
		lastSyncAt = os.clock()

		local tideHour = if typeof(p.tide) == "table" then p.tide.hour else nil
		Ui.clockSync(clock, p.month, p.day, p.tick, tideHour)

		regions = Ui.normalizeRegions(p.regions)

		-- a selection that left the chart (expired ground, server restart) is
		-- honestly gone
		if selection.regionId ~= nil and currentRegion() == nil then
			selection = { regionId = nil, speciesId = nil, depth = nil }
			publishSelection()
			refreshBar()
			showStatus("your ground left the chart", "amber")
		end

		-- the picker rebuilds on the next open, never under a finger
		pickerDirty = true
		refreshBar()
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

	task.spawn(function()
		local found = playerGui:WaitForChild("SlackWaterCastBus", 10)
		if found and found:IsA("BindableEvent") then
			bus = found
			Ui.connect(connections, found.Event, onBus)
		else
			showStatus("the rig is not answering — cannot cast", "danger")
		end
	end)

	-- ---------------------------------------------------------------------------
	-- Wire up
	-- ---------------------------------------------------------------------------

	Ui.connect(connections, castButton.Activated, onCastPressed)
	Ui.connect(connections, summary.Activated, function()
		setPickerOpen(not pickerOpen)
	end)
	Ui.connect(connections, pickerClose.Activated, function()
		setPickerOpen(false)
	end)
	Ui.connect(connections, giveUp.Activated, function()
		if bus then
			bus:Fire({ kind = "abort" })
		end
	end)

	-- when a right-edge sheet opens, this sheet yields the screen through the
	-- same shared attribute the sheets coordinate with
	Ui.connect(connections, playerGui:GetAttributeChangedSignal("SlackWaterOpenPanel"), function()
		if playerGui:GetAttribute("SlackWaterOpenPanel") ~= nil and pickerOpen then
			setPickerOpen(false)
		end
	end)

	-- ---------------------------------------------------------------------------
	-- Render loop
	-- ---------------------------------------------------------------------------

	local uiClock = 0

	local heartbeat = RunService.Heartbeat:Connect(function(dt: number)
		uiClock += dt
		if uiClock < PULSE_SECONDS then
			return
		end
		uiClock = 0
		local now = os.clock()

		-- status lines fade; failures stay for their hold, then the bar goes
		-- quiet rather than nagging
		if statusUntil > 0 and now > statusUntil then
			statusUntil = 0
			statusLabel.Text = ""
		end

		-- the cooldown on the button: the server would refuse, so the button
		-- says so first
		if not fightShown then
			local remaining = CastBar_cooldownRemaining(guard, now, Config.CAST_COOLDOWN)
			if remaining > 0.05 then
				castButton.Text = "WAIT " .. CastBar_cooldownText(remaining)
			else
				castButton.Text = "CAST"
			end
		end

		-- watchdogs: a cast that never began, and a resolve that outlived all
		-- patience, must never lock the verb
		if guard.busy then
			if not rigAlive and now - guard.beganAt > RIG_SILENCE then
				CastBar_guardEnd(guard)
				setFightShown(false)
				showStatus("the rig is not answering", "danger")
			elseif CastBar_guardWaitExpired(guard, now, WAIT_WATCHDOG) then
				CastBar_guardEnd(guard)
				setFightShown(false)
				showStatus("the landing never resolved", "danger")
			end
		end
	end)
	table.insert(connections, heartbeat)

	refreshBar()
	rebuildPicker()

	Ui.connect(connections, gui.Destroying, function()
		Ui.disconnectAll(connections)
		Ui.disconnectAll(pickerConns)
	end)
end

-- The standalone interpreter has no Roblox runtime; stop before any global
-- is touched so `luau <file>` and the test suite's require stay clean
-- (scripts-check.sh), and hand the pure half to the tests.
if game == nil then
	return CastBar
end

main()

return CastBar
