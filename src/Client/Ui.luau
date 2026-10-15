--!strict
--[[
	Ui — the client construction kit.

	Every panel script in src/Client builds its interface out of the same small
	parts, so the game reads as one HUD rather than six unrelated overlays. The
	kit is deliberately dumb: it creates instances, formats numbers and
	normalizes wire payloads, and nothing else. All game knowledge — prices,
	tides, regions — stays in the panel scripts, which only ever render what
	the server sent (house rule 2).

	This module keeps its top level free of Roblox globals (no Color3/UDim2/Enum
	constants at load time) so `luau src/Client/Ui.luau` runs clean under the
	standalone interpreter and the repo's parse gate stays meaningful. Roblox
	values are constructed lazily inside functions, which only ever run inside
	Studio.
]]

local Ui = {}

--=============================================================================
-- Theme
--
-- Colours live here as plain RGB triples so this file's top level stays pure;
-- Ui.color turns them into Color3 values once, on first use in Studio.
--
-- The palette is nautical on purpose: deep-water backgrounds, one warm gold
-- reserved for slack water and for celebration, and a red that only ever means
-- "this ground is hurt".
--=============================================================================

local THEME_RGB: { [string]: { number } } = {
	panel = { 13, 22, 33 },
	deep = { 9, 16, 26 },
	text = { 230, 238, 245 },
	dim = { 140, 158, 175 },
	gold = { 240, 194, 79 },
	amber = { 235, 146, 60 },
	danger = { 211, 84, 70 },
	good = { 96, 190, 138 },
	water = { 74, 138, 199 },
	teal = { 72, 178, 186 },
	white = { 255, 255, 255 },

	-- habitat identity colours, shared by the HUD, the grounds list and any
	-- future chart: a habitat should always be the same colour everywhere
	kelp = { 96, 190, 138 },
	reef = { 222, 132, 94 },
	sand = { 214, 192, 138 },
	mud = { 150, 122, 96 },
	open = { 74, 138, 199 },
	estuary = { 72, 178, 186 },
}

local themeCache: { [string]: Color3 }? = nil

function Ui.color(name: string): Color3
	if not themeCache then
		themeCache = {}
		for key, rgb in THEME_RGB do
			themeCache[key] = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
		end
	end
	local cached = themeCache
	return cached[name] or cached.text
end

Ui.MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

--=============================================================================
-- Formatting (pure, safe everywhere)
--=============================================================================

--- 1234567 -> "1,234,567". Catch values get large, and ungrouped digits are
--- unreadable at a glance on a phone.
---
--- The digits come from string.format("%d"), not tostring: tostring goes
--- scientific at 1e15 ("1e+15"), which the grouping loop below would shred
--- into "1e,15" on the HUD. NaN and infinities degrade to fixed text rather
--- than reaching a format string.
function Ui.formatInt(n: number): string
	if n ~= n then
		return "0"
	end
	if n == math.huge then
		return "∞"
	end
	if n == -math.huge then
		return "-∞"
	end
	local rounded = math.floor(n + 0.5)
	local sign = if rounded < 0 then "-" else ""
	local digits = string.format("%d", math.abs(rounded))
	local grouped = ""
	while #digits > 3 do
		grouped = "," .. digits:sub(-3) .. grouped
		digits = digits:sub(1, -4)
	end
	return sign .. digits .. grouped
end

--- An absolute game hour as a clock face ("13:40"). "Hour 61.3" is navigator
--- talk; the HUD speaks to players.
function Ui.clockFace(hour: number): string
	local h0 = if hour ~= hour then 0 else hour
	local dayHour = h0 % 24
	local h = math.floor(dayHour)
	local m = math.floor((dayHour - h) * 60 + 0.5)
	if m == 60 then
		h += 1
		m = 0
	end
	if h == 24 then
		h = 0
	end
	return string.format("%d:%02d", h, m)
end

--- mm:ss for a countdown in real seconds. Slack windows are short in real
--- time, so minutes-and-seconds is always the right unit here.
function Ui.countdown(seconds: number): string
	local s0 = if seconds ~= seconds then 0 else seconds
	local s = math.max(0, math.floor(s0 + 0.5))
	return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

--- Weight the way a deckhand says it: little fish keep their decimals.
function Ui.formatWeight(kg: number): string
	local k = if kg ~= kg then 0 else math.clamp(kg, 0, 1e6)
	if k >= 100 then
		return string.format("%.0f kg", k)
	elseif k >= 10 then
		return string.format("%.1f kg", k)
	end
	return string.format("%.2f kg", k)
end

--- Wire values are trusted by no panel: coerce to a finite number or take
--- the fallback. Strings, bools, nil, NaN and infinities all degrade instead
--- of reaching a format string or a comparison.
function Ui.tonum(value: any, fallback: number): number
	local n = tonumber(value)
	if n == nil or n ~= n or n == math.huge or n == -math.huge then
		return fallback
	end
	return n
end

--=============================================================================
-- Wire normalization
--
-- Everything a remote handler receives is untrusted shape until proven
-- otherwise: a partial payload, a dev fixture fired from the command bar, or
-- a field renamed on the server only. Each panel funnels its payload through
-- one of these pure passes so every field read downstream is typed and
-- finite. Non-table entries are dropped, never guessed at — the client may
-- not invent values it was not sent (house rule 2).
--=============================================================================

export type RegionRow = {
	id: string,
	name: string,
	habitat: string,
	depth: number,
	chartedDepth: number,
	species: { string },
	abundances: { [string]: number },
	contested: { [string]: boolean },
	accessible: boolean,
	waterDepth: number,
	quality: number,
	provenance: string,
}

--- Normalize the `regions` array of an OceanSync. A region without a string
--- id is dropped; a missing name falls back to the id (never the string
--- "nil"); an unrecognised provenance downgrades to "grown", mirroring the
--- rule in Shared/Ocean/Chart.luau so the client can never be talked into
--- presenting composed water as surveyed.
function Ui.normalizeRegions(raw: any): { RegionRow }
	local out: { RegionRow } = {}
	if typeof(raw) ~= "table" then
		return out
	end
	for _, entry in raw do
		if typeof(entry) ~= "table" then
			continue
		end
		local id = entry.id
		if type(id) ~= "string" or #id == 0 then
			continue
		end

		local name = entry.name
		if type(name) ~= "string" or #name == 0 then
			name = id
		end
		local habitat = if type(entry.habitat) == "string" then entry.habitat else ""

		local depth = Ui.tonum(entry.depth, 0)
		local chartedDepth = Ui.tonum(entry.chartedDepth, depth)

		local species: { string } = {}
		if typeof(entry.species) == "table" then
			for _, speciesId in entry.species do
				if type(speciesId) == "string" and #speciesId > 0 then
					table.insert(species, speciesId)
				end
			end
		end

		local abundances: { [string]: number } = {}
		if typeof(entry.abundances) == "table" then
			for speciesId, value in entry.abundances do
				if type(speciesId) == "string" then
					local n = Ui.tonum(value, -1)
					if n >= 0 then
						abundances[speciesId] = n
					end
				end
			end
		end

		local contested: { [string]: boolean } = {}
		if typeof(entry.contested) == "table" then
			for speciesId, flag in entry.contested do
				if type(speciesId) == "string" and flag == true then
					contested[speciesId] = true
				end
			end
		end

		local provenance = entry.provenance
		if provenance ~= "measured" and provenance ~= "grown" and provenance ~= "composed" then
			provenance = "grown"
		end

		table.insert(out, {
			id = id,
			name = name,
			habitat = habitat,
			depth = depth,
			chartedDepth = chartedDepth,
			species = species,
			abundances = abundances,
			contested = contested,
			accessible = entry.accessible ~= false,
			waterDepth = Ui.tonum(entry.waterDepth, 0),
			quality = Ui.tonum(entry.quality, 0),
			provenance = provenance,
		})
	end
	return out
end

export type MarketRow = {
	speciesId: string,
	displayName: string,
	price: number,
	baseValue: number,
	scarcityMultiplier: number,
	globalAbundance: number,
	direction: string,
}

--- Normalize the `entries` array of a MarketSync. Defaults keep every display
--- format and the isScarce comparison fed with finite numbers even when a
--- field is missing or the wrong type.
function Ui.normalizeMarketEntries(raw: any): { MarketRow }
	local out: { MarketRow } = {}
	if typeof(raw) ~= "table" then
		return out
	end
	for _, entry in raw do
		if typeof(entry) ~= "table" then
			continue
		end
		local id = entry.speciesId
		if type(id) ~= "string" or #id == 0 then
			continue
		end

		local displayName = entry.displayName
		if type(displayName) ~= "string" or #displayName == 0 then
			displayName = id
		end
		local direction = entry.direction
		if direction ~= "rising" and direction ~= "falling" and direction ~= "flat" then
			direction = "flat"
		end

		table.insert(out, {
			speciesId = id,
			displayName = displayName,
			price = Ui.tonum(entry.price, 0),
			baseValue = Ui.tonum(entry.baseValue, 0),
			scarcityMultiplier = Ui.tonum(entry.scarcityMultiplier, 1),
			globalAbundance = Ui.tonum(entry.globalAbundance, 1),
			direction = direction,
		})
	end
	return out
end

--=============================================================================
-- Instance builders
--
-- Prop tables use explicit optional fields rather than a dynamic key loop so
-- `--!strict` can actually check what is assigned.
--=============================================================================

export type FrameProps = {
	name: string?,
	size: UDim2?,
	pos: UDim2?,
	anchor: Vector2?,
	transparency: number?,
	color: string?,
	corner: number?,
	strokeColor: string?,
	strokeWidth: number?,
	zindex: number?,
	layoutOrder: number?,
	visible: boolean?,
}

function Ui.frame(parent: Instance, props: FrameProps): Frame
	local f = Instance.new("Frame")
	f.Name = props.name or "Frame"
	f.BackgroundTransparency = props.transparency or 0
	f.BackgroundColor3 = Ui.color(props.color or "panel")
	f.BorderSizePixel = 0
	f.Size = props.size or UDim2.fromScale(1, 1)
	f.Position = props.pos or UDim2.new(0, 0, 0, 0)
	if props.anchor then
		f.AnchorPoint = props.anchor
	end
	if props.corner then
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, props.corner)
		c.Parent = f
	end
	if props.strokeColor and props.strokeWidth then
		local s = Instance.new("UIStroke")
		s.Color = Ui.color(props.strokeColor)
		s.Thickness = props.strokeWidth
		s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		s.Parent = f
	end
	if props.zindex then
		f.ZIndex = props.zindex
	end
	if props.layoutOrder then
		f.LayoutOrder = props.layoutOrder
	end
	if props.visible ~= nil then
		f.Visible = props.visible
	end
	f.Parent = parent
	return f
end

export type LabelProps = {
	name: string?,
	text: string?,
	size: UDim2?,
	pos: UDim2?,
	anchor: Vector2?,
	color: string?,
	textSize: number?,
	font: Enum.Font?,
	xalign: Enum.TextXAlignment?,
	yalign: Enum.TextYAlignment?,
	wrapped: boolean?,
	rich: boolean?,
	transparency: number?,
	zindex: number?,
	layoutOrder: number?,
	visible: boolean?,
}

function Ui.label(parent: Instance, props: LabelProps): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = props.name or "Label"
	l.BackgroundTransparency = 1
	l.Font = props.font or Enum.Font.GothamMedium
	l.Text = props.text or ""
	l.TextColor3 = Ui.color(props.color or "text")
	l.TextSize = props.textSize or 13
	l.TextXAlignment = props.xalign or Enum.TextXAlignment.Left
	l.TextYAlignment = props.yalign or Enum.TextYAlignment.Center
	l.TextWrapped = props.wrapped or false
	l.TextTruncate = Enum.TextTruncate.AtEnd
	l.RichText = props.rich or false
	l.Size = props.size or UDim2.fromScale(1, 1)
	l.Position = props.pos or UDim2.new(0, 0, 0, 0)
	if props.anchor then
		l.AnchorPoint = props.anchor
	end
	if props.transparency then
		l.TextTransparency = props.transparency
	end
	if props.zindex then
		l.ZIndex = props.zindex
	end
	if props.layoutOrder then
		l.LayoutOrder = props.layoutOrder
	end
	if props.visible ~= nil then
		l.Visible = props.visible
	end
	l.Parent = parent
	return l
end

export type ButtonProps = {
	name: string?,
	text: string?,
	textColor: string?,
	bgColor: string?,
	transparency: number?,
	size: UDim2?,
	pos: UDim2?,
	anchor: Vector2?,
	corner: number?,
	textSize: number?,
	font: Enum.Font?,
	zindex: number?,
	visible: boolean?,
}

function Ui.button(parent: Instance, props: ButtonProps): TextButton
	local b = Instance.new("TextButton")
	b.Name = props.name or "Button"
	b.Text = props.text or ""
	b.Font = props.font or Enum.Font.GothamBold
	b.TextColor3 = Ui.color(props.textColor or "text")
	b.TextSize = props.textSize or 13
	b.BackgroundColor3 = Ui.color(props.bgColor or "panel")
	b.BackgroundTransparency = props.transparency or 0
	b.BorderSizePixel = 0
	b.AutoButtonColor = true
	b.Size = props.size or UDim2.fromScale(1, 1)
	b.Position = props.pos or UDim2.new(0, 0, 0, 0)
	if props.anchor then
		b.AnchorPoint = props.anchor
	end
	if props.corner then
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, props.corner)
		c.Parent = b
	end
	if props.zindex then
		b.ZIndex = props.zindex
	end
	if props.visible ~= nil then
		b.Visible = props.visible
	end
	b.Parent = parent
	return b
end

--- A horizontal progress bar. The fraction is set by callers from numbers the
--- server sent — a bar width is rendering, not computing (house rule 2).
export type Meter = { track: Frame, fill: Frame }

function Ui.meter(parent: Instance, fillColor: string, props: FrameProps): Meter
	local track = Ui.frame(parent, props)
	track.Name = props.name or "Meter"
	local fill = Ui.frame(track, {
		name = "Fill",
		size = UDim2.fromScale(0, 1),
		color = fillColor,
		corner = if props.corner then props.corner else nil,
		zindex = props.zindex,
	})
	return { track = track, fill = fill }
end

function Ui.setMeter(meter: Meter, fraction: number): ()
	meter.fill.Size = UDim2.fromScale(math.clamp(fraction, 0, 1), 1)
end

--- Small coloured badge (SCARCE, RISING, REEF...). Auto-width so the text
--- decides the size and no panel hand-tunes chip widths.
function Ui.chip(parent: Instance, text: string, colorName: string, props: FrameProps): Frame
	local chip = Ui.frame(parent, {
		name = props.name or "Chip",
		size = UDim2.fromOffset(0, 16),
		pos = props.pos,
		anchor = props.anchor,
		color = colorName,
		transparency = 0.82,
		corner = 4,
		zindex = props.zindex,
		layoutOrder = props.layoutOrder,
		visible = props.visible,
	})
	chip.AutomaticSize = Enum.AutomaticSize.X
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 6)
	pad.PaddingRight = UDim.new(0, 6)
	pad.Parent = chip
	-- the label must grow to its own text first; a scale-sized label
	-- contributes no width, and the chip's AutomaticSize would collapse
	local chipText = Ui.label(chip, {
		text = text,
		color = colorName,
		textSize = 10,
		font = Enum.Font.GothamBold,
		size = UDim2.fromScale(0, 1),
	})
	chipText.AutomaticSize = Enum.AutomaticSize.X
	return chip
end

--- Vertical list scroller for the sheet bodies.
function Ui.scroll(parent: Instance, props: FrameProps): ScrollingFrame
	local s = Instance.new("ScrollingFrame")
	s.Name = props.name or "Scroll"
	s.BackgroundTransparency = 1
	s.BorderSizePixel = 0
	s.Size = props.size or UDim2.fromScale(1, 1)
	s.Position = props.pos or UDim2.new(0, 0, 0, 0)
	s.CanvasSize = UDim2.new(0, 0, 0, 0)
	s.AutomaticCanvasSize = Enum.AutomaticSize.Y
	s.ScrollingDirection = Enum.ScrollingDirection.Y
	s.ScrollBarThickness = 4
	s.ScrollBarImageColor3 = Ui.color("dim")
	if props.zindex then
		s.ZIndex = props.zindex
	end
	s.Parent = parent
	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, 4)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = s
	return s
end

--=============================================================================
-- Scaling
--
-- Every panel is laid out once at a 390x844 logical viewport (the phone the
-- whole HUD is designed against — Roblox is ~80% mobile) and scaled to the
-- real viewport with one UIScale. Listening on the root's AbsoluteSize means
-- no dependency on workspace.CurrentCamera, which can be nil briefly.
--=============================================================================

function Ui.autoScale(root: Frame): UIScale
	local scale = Instance.new("UIScale")
	scale.Name = "AutoScale"
	scale.Parent = root

	local function apply(): ()
		local size = root.AbsoluteSize
		-- clamped: 0.75 keeps small phones readable, 1.5 stops tablets and
		-- desktop from turning the HUD into billboard text
		local s = math.min(size.X / 390, size.Y / 720)
		scale.Scale = math.clamp(s, 0.75, 1.5)
	end

	apply()
	root:GetPropertyChangedSignal("AbsoluteSize"):Connect(apply)
	return scale
end

function Ui.screenGui(name: string, displayOrder: number, playerGui: Instance): ScreenGui
	-- a same-named GUI can be left behind by a previous dev-session connect;
	-- replacing it keeps at most one of each panel on screen
	local existing = playerGui:FindFirstChild(name)
	if existing then
		existing:Destroy()
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.ResetOnSpawn = false -- StarterPlayerScripts run once per join; the HUD must survive respawns
	gui.DisplayOrder = displayOrder
	gui.IgnoreGuiInset = false
	gui.Parent = playerGui
	return gui
end

function Ui.tween(inst: Instance, seconds: number, goal: { [string]: any }): Tween
	local TweenService = game:GetService("TweenService")
	local info = TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local tween = TweenService:Create(inst, info, goal)
	tween:Play()
	return tween
end

--=============================================================================
-- Connection tracking
--
-- Panels collect every connection in one table and disconnect all of it when
-- their ScreenGui is destroyed, so nothing leaks past the UI that owned it.
--=============================================================================

export type Conns = { RBXScriptConnection }

function Ui.connect(tracker: Conns, signal: RBXScriptSignal, fn: (any) -> ()): RBXScriptConnection
	local conn = signal:Connect(fn)
	table.insert(tracker, conn)
	return conn
end

function Ui.disconnectAll(tracker: Conns): ()
	for _, conn in tracker do
		conn:Disconnect()
	end
	table.clear(tracker)
end

--- Guarded remote lookup. Remotes are created by the server at runtime, so a
--- joining client must never assume they exist on the first frames (see the
--- note in Types.luau). Returns nil after `timeout` instead of yielding
--- forever, so a missing remote degrades to a "still reading" HUD rather than
--- a stuck coroutine.
function Ui.awaitRemote(folderName: string, name: string, timeout: number): RemoteEvent?
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local folder = ReplicatedStorage:WaitForChild(folderName, timeout)
	if not folder then
		return nil
	end
	local remote = folder:WaitForChild(name, timeout)
	if not remote then
		return nil
	end
	return remote :: RemoteEvent
end

--=============================================================================
-- GameClock
--
-- The server is the only authority on time; the client extrapolates. Every
-- OceanSync carries the server's own tide hour (`tide.hour`, see
-- OceanService.tideState) plus month/day, and the clock anchors on THAT —
-- never on a client-side conversion of the tick count. The tick conversion
-- once ran the tide at twice the server's speed: Config's TICKS_PER_DAY
-- implied 2 game hours per tick while the service advances its hour by 1.0,
-- so the HUD promised slack water the server had not reached.
--
-- Between syncs the clock coasts on os.clock so the tide curve moves smoothly
-- instead of stepping every sync. The rate (game hours per real second) is
-- MEASURED from consecutive server hours rather than hard-coded, so
-- countdowns stay honest if the server cadence is retuned; the default
-- matches OceanService: one game hour per _TICK_INTERVAL tick (20 s). The
-- 24-hour rollover is unwrapped so coasting stays continuous, and an hour
-- that jumps backwards beyond a wrap (a server restart) drops the measured
-- rate and re-anchors instead of extrapolating across the reset.
--=============================================================================

export type GameClock = {
	defaultHoursPerSecond: number,
	hoursPerSecond: number,
	anchorHour: number,
	anchorAt: number,
	prevServerHour: number,
	prevContinuousHour: number,
	rateAnchorHour: number,
	rateAnchorAt: number,
	month: number,
	day: number,
	synced: boolean,
}

function Ui.newClock(defaultHoursPerSecond: number): GameClock
	return {
		defaultHoursPerSecond = defaultHoursPerSecond,
		hoursPerSecond = defaultHoursPerSecond,
		anchorHour = 0,
		anchorAt = 0,
		prevServerHour = -1,
		prevContinuousHour = 0,
		rateAnchorHour = 0,
		rateAnchorAt = 0,
		month = 1,
		day = 1,
		synced = false,
	}
end

--- Absorb an OceanSync. Every argument is wire data and is validated here: a
--- malformed month, day, tick or hour degrades to a default instead of
--- poisoning the clock (a NaN hour would blank every panel that renders it).
---
--- `serverHour` is the authoritative `tide.hour`. When it is missing the
--- clock falls back to the tick count at the server's actual rate of one
--- game hour per tick (OceanService.tickOcean advances `svc.hour` by 1.0).
function Ui.clockSync(
	clock: GameClock,
	month: any,
	day: any,
	tick: any,
	serverHour: any,
	now: number?
): ()
	local at = if now ~= nil then now else os.clock()

	local hour = Ui.tonum(serverHour, -1)
	if hour < 0 then
		-- no usable server hour: fall back to the tick count
		hour = Ui.tonum(tick, 0) % 24
	else
		hour %= 24
	end

	local monthN = Ui.tonum(month, 1)
	clock.month = math.clamp(math.floor(monthN), 1, #Ui.MONTHS)
	clock.day = math.max(1, math.floor(Ui.tonum(day, 1)))

	local delta = 0
	if clock.synced then
		delta = hour - clock.prevServerHour
		-- unwrap the midnight rollover in whichever direction it happened
		if delta < -12 then
			delta += 24
		elseif delta > 12 then
			delta -= 24
		end
	end

	local continuous = if clock.synced then clock.prevContinuousHour + delta else hour

	if clock.synced then
		-- The rate is measured over a ROLLING WINDOW: from the last sync
		-- whose hour actually moved, not from consecutive syncs. The server
		-- steps its hour once per tick while broadcasting several times per
		-- tick, so per-sync measurement would capture the step's own speed
		-- (four times the true average here) and the coast between syncs
		-- would sprint and snap back.
		local moved = continuous - clock.rateAnchorHour
		local span = at - clock.rateAnchorAt
		if math.abs(moved) >= 0.5 and span > 0.25 then
			local rate = moved / span
			if moved < 0 or rate ~= rate or rate > 0.25 then
				-- backwards past a wrap, or a leap no real cadence allows:
				-- the server restarted or stuttered, re-anchor on the default
				clock.hoursPerSecond = clock.defaultHoursPerSecond
			else
				clock.hoursPerSecond = rate
			end
			clock.rateAnchorHour = continuous
			clock.rateAnchorAt = at
		end
	else
		clock.rateAnchorHour = continuous
		clock.rateAnchorAt = at
	end

	clock.prevServerHour = hour
	clock.prevContinuousHour = continuous
	clock.anchorHour = continuous
	clock.anchorAt = at
	clock.synced = true
end

function Ui.clockHour(clock: GameClock, now: number?): number
	local at = if now ~= nil then now else os.clock()
	return clock.anchorHour + (at - clock.anchorAt) * clock.hoursPerSecond
end

--- Real seconds per game hour. Countdowns must speak real time — "slack in
--- 0:40" that secretly means four real minutes is worse than no countdown.
function Ui.clockSecondsPerGameHour(clock: GameClock): number
	if clock.hoursPerSecond > 0 then
		return 1 / clock.hoursPerSecond
	end
	return 1 / clock.defaultHoursPerSecond
end

--=============================================================================
-- Sheets
--
-- MarketPanel and RegionChart are both right-edge sheets behind a round edge
-- toggle, and only one should cover the screen at a time. They coordinate
--- through a single PlayerGui attribute rather than any cross-script
--- reference, so neither file knows the other exists.
--=============================================================================

export type Sheet = {
	frame: Frame,
	body: Frame,
	toggle: TextButton,
	isOpen: boolean,
	open: (Sheet) -> (),
	close: (Sheet) -> (),
	setSubtitle: (Sheet, string) -> (),
}

local OPEN_PANEL_ATTRIBUTE = "SlackWaterOpenPanel"

function Ui.makeSheet(
	opts: {
		root: Frame,
		tracker: Conns,
		playerGui: Instance,
		key: string, -- unique among sheets; written to the coordination attribute
		icon: string, -- emoji on the edge toggle
		caption: string, -- tiny caption under the icon
		title: string,
		subtitle: string,
		width: number,
		height: number,
		yScale: number, -- vertical position of the edge toggle, 0..1
	}
): Sheet
	local root = opts.root

	local toggle = Ui.button(root, {
		name = opts.key .. "Toggle",
		size = UDim2.fromOffset(54, 54),
		pos = UDim2.new(1, -8, opts.yScale, 0),
		anchor = Vector2.new(1, 0.5),
		bgColor = "panel",
		transparency = 0.08,
		corner = 14,
		strokeColor = "deep",
		strokeWidth = 1,
		zindex = 4,
	})
	local icon = Ui.label(toggle, {
		text = opts.icon,
		textSize = 20,
		size = UDim2.new(1, 0, 0, 24),
		pos = UDim2.fromOffset(0, 6),
		yalign = Enum.TextYAlignment.Center,
		xalign = Enum.TextXAlignment.Center,
	})
	icon.Name = "Icon"
	Ui.label(toggle, {
		text = opts.caption,
		textSize = 9,
		color = "dim",
		size = UDim2.new(1, -4, 0, 12),
		pos = UDim2.new(0, 0, 1, -16),
		xalign = Enum.TextXAlignment.Center,
	})

	local frame = Ui.frame(root, {
		name = opts.key .. "Sheet",
		size = UDim2.fromOffset(opts.width, opts.height),
		pos = UDim2.new(1, opts.width + 40, 0.5, 0),
		anchor = Vector2.new(1, 0.5),
		color = "panel",
		transparency = 0.04,
		corner = 12,
		strokeColor = "deep",
		strokeWidth = 1,
		zindex = 5,
		visible = false,
	})
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 12)
	padding.PaddingLeft = UDim.new(0, 12)
	padding.PaddingRight = UDim.new(0, 12)
	padding.Parent = frame

	Ui.label(frame, {
		text = opts.title,
		textSize = 16,
		font = Enum.Font.GothamBold,
		size = UDim2.new(1, -40, 0, 20),
	})
	local subtitleLabel = Ui.label(frame, {
		name = "Subtitle",
		text = opts.subtitle,
		textSize = 10,
		color = "dim",
		size = UDim2.new(1, 0, 0, 14),
		pos = UDim2.fromOffset(0, 22),
	})

	local close = Ui.button(frame, {
		name = "Close",
		text = "✕",
		textSize = 14,
		textColor = "dim",
		size = UDim2.fromOffset(26, 26),
		pos = UDim2.fromScale(1, 0),
		anchor = Vector2.new(1, 0),
		bgColor = "deep",
		transparency = 0.2,
		corner = 8,
		zindex = 6,
	})

	-- panels mount their scrolling content in here
	local body = Ui.frame(frame, {
		name = "Body",
		size = UDim2.new(1, 0, 1, -48),
		pos = UDim2.fromOffset(0, 40),
		transparency = 1,
		zindex = 5,
	})

	local sheet = {
		frame = frame,
		body = body,
		toggle = toggle,
		isOpen = false,
		open = function() end,
		close = function() end,
		setSubtitle = function(_: Sheet, text: string)
			subtitleLabel.Text = text
		end,
	}

	local parkedPos = UDim2.new(1, opts.width + 40, 0.5, 0)
	local restPos = UDim2.new(1, -12, 0.5, 0)

	function sheet.open(_: Sheet)
		if sheet.isOpen then
			return
		end
		sheet.isOpen = true
		opts.playerGui:SetAttribute(OPEN_PANEL_ATTRIBUTE, opts.key)
		frame.Position = parkedPos
		frame.Visible = true
		toggle.Visible = false
		Ui.tween(frame, 0.22, { Position = restPos })
	end

	function sheet.close(_: Sheet)
		if not sheet.isOpen then
			return
		end
		sheet.isOpen = false
		if opts.playerGui:GetAttribute(OPEN_PANEL_ATTRIBUTE) == opts.key then
			opts.playerGui:SetAttribute(OPEN_PANEL_ATTRIBUTE, nil)
		end
		toggle.Visible = true
		local slide = Ui.tween(frame, 0.18, { Position = parkedPos })
		slide.Completed:Once(function()
			if not sheet.isOpen then
				frame.Visible = false
			end
		end)
	end

	Ui.connect(opts.tracker, toggle.Activated, function()
		sheet.open(sheet)
	end)
	Ui.connect(opts.tracker, close.Activated, function()
		sheet.close(sheet)
	end)
	-- when another sheet opens, this one yields the screen
	Ui.connect(
		opts.tracker,
		opts.playerGui:GetAttributeChangedSignal(OPEN_PANEL_ATTRIBUTE),
		function()
			if opts.playerGui:GetAttribute(OPEN_PANEL_ATTRIBUTE) ~= opts.key and sheet.isOpen then
				sheet.close(sheet)
			end
		end
	)

	return sheet
end

return Ui
