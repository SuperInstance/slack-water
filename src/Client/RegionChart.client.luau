--!strict
--[[
	RegionChart — the grounds, as the ocean actually is.

	OceanSync-driven: name, habitat, charted depth, what is present, and — the
	routing decision — how picked-over each ground is. Abundance comes straight
	from the server; the bar width is rendering, not computing (house rule 2).

	Grounds are sorted richest-first and colour-coded against the simulation's
	own collapse threshold, so a player can route around empties at a glance
	instead of learning a number. A ground below the threshold says so in
	words, because "PICKED OVER" is a decision and "0.21" is not.
]]

local Ui = require(script and script.Parent.Ui or "./Ui")

-- habitat identity colours as rich-text hex (labels can't tint substrings
-- from Color3 values, and the habitat word shares a label with the depth)
local HABITAT_HEX: { [string]: string } = {
	kelp = "#60be8a",
	reef = "#de845e",
	sand = "#d6c08a",
	mud = "#96785f",
	open = "#4a8ac7",
	estuary = "#48b2ba",
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
	local Config = require(Shared:WaitForChild("Config") :: ModuleScript)

	local connections: Ui.Conns = {}

	local gui = Ui.screenGui("SlackWaterGrounds", 5, playerGui)
	local root = Ui.frame(gui, { name = "Root", transparency = 1 })
	Ui.autoScale(root)

	local sheet = Ui.makeSheet({
		root = root,
		tracker = connections,
		playerGui = playerGui,
		key = "grounds",
		icon = "🗺️",
		caption = "grounds",
		title = "GROUNDS",
		subtitle = "sorted by what is left",
		width = 320,
		height = 500,
		yScale = 0.58,
	})

	local scroll = Ui.scroll(sheet.body, { name = "Rows", size = UDim2.fromScale(1, 1) })
	local emptyLabel = Ui.label(scroll, {
		text = "reading the grounds…",
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

	-- regions are normalized on arrival (Ui.normalizeRegions): ids are
	-- strings, numbers are finite, provenance is one of the three honest
	-- labels. Nothing below has to defend against the wire again.
	local function regionAverageAbundance(region: Ui.RegionRow): number
		local present = region.species
		if #present == 0 then
			return 0
		end
		local total = 0
		for _, speciesId in present do
			total += region.abundances[speciesId] or 0
		end
		return total / #present
	end

	local function hasContested(region: Ui.RegionRow): boolean
		for _, flag in region.contested do
			if flag == true then
				return true
			end
		end
		return false
	end

	local function speciesSummary(region: Ui.RegionRow): string
		local present = region.species
		if #present == 0 then
			return "nothing holding here — let it rest"
		end
		local names: { string } = {}
		for _, speciesId in present do
			local species = Species.get(speciesId)
			table.insert(names, if species then species.displayName else speciesId)
			if #names == 3 then
				break
			end
		end
		local text = table.concat(names, " · ")
		if #present > 3 then
			text ..= string.format(" +%d more", #present - 3)
		end
		return text
	end

	local function rebuild(regions: { Ui.RegionRow }): ()
		destroyRows()
		emptyLabel.Text = "reading the grounds…"

		if #regions == 0 then
			emptyLabel.Visible = true
			return
		end
		emptyLabel.Visible = false

		-- richest first: the top of the list is where you go next
		local scored: { { region: Ui.RegionRow, avg: number } } = {}
		for _, region in regions do
			table.insert(scored, { region = region, avg = regionAverageAbundance(region) })
		end
		table.sort(scored, function(a, b)
			return a.avg > b.avg
		end)

		for index, item in scored do
			local region = item.region
			local avg = item.avg
			local collapse = Config.COLLAPSE_THRESHOLD
			local contested = hasContested(region)
			local inaccessible = region.accessible ~= true
			-- "~" is the chart convention for approximate: only measured
			-- ground is shown as surveyed fact (house rule 6)
			local unsurveyed = region.provenance ~= "measured"

			local row = Ui.frame(scroll, {
				name = "Row" .. tostring(index),
				size = UDim2.new(1, 0, 0, 64),
				color = "deep",
				-- a ground the tide has cut off recedes like a locked row
				transparency = if inaccessible then 0.45 else 0.2,
				corner = 8,
				layoutOrder = index,
			})

			Ui.label(row, {
				text = if unsurveyed then region.name .. " ~" else region.name,
				textSize = 13.5,
				font = Enum.Font.GothamBold,
				size = UDim2.new(1, -70, 0, 16),
				pos = UDim2.fromOffset(10, 5),
			})
			Ui.label(row, {
				text = string.format("%d m", math.floor(region.chartedDepth)),
				textSize = 11,
				color = "dim",
				size = UDim2.fromOffset(56, 14),
				pos = UDim2.new(1, -10, 0, 6),
				anchor = Vector2.new(1, 0),
				xalign = Enum.TextXAlignment.Right,
			})

			-- habitat keeps its colour everywhere it appears (see Ui theme)
			local habitatHex = HABITAT_HEX[region.habitat] or "#8c9eaf"
			local habitatText = if #region.habitat > 0 then string.upper(region.habitat) else "—"
			Ui.label(row, {
				text = string.format('<font color="%s">%s</font>', habitatHex, habitatText),
				textSize = 10,
				font = Enum.Font.GothamBold,
				rich = true,
				size = UDim2.fromOffset(66, 13),
				pos = UDim2.fromOffset(10, 23),
			})
			Ui.label(row, {
				text = speciesSummary(region),
				textSize = 10.5,
				color = "dim",
				size = UDim2.new(1, -206, 0, 13),
				pos = UDim2.fromOffset(80, 23),
			})

			-- the status word wins over the number: this is the routing call
			local statusText = ""
			local statusColor = "dim"
			if contested then
				statusText = "⚔ CONTESTED"
				statusColor = "amber"
			elseif avg < collapse then
				statusText = "PICKED OVER"
				statusColor = "danger"
			elseif inaccessible then
				statusText = "WAIT FOR TIDE"
				statusColor = "amber"
			end
			if statusText ~= "" then
				Ui.label(row, {
					text = statusText,
					textSize = 10,
					font = Enum.Font.GothamBold,
					color = statusColor,
					size = UDim2.fromOffset(120, 13),
					pos = UDim2.new(1, -10, 0, 23),
					anchor = Vector2.new(1, 0),
					xalign = Enum.TextXAlignment.Right,
				})
			end

			-- abundance bar: green is worth the trip, amber is thinning, red
			-- is at or below the simulation's collapse threshold
			local barColor = "good"
			if avg < collapse then
				barColor = "danger"
			elseif avg < 0.5 then
				barColor = "amber"
			end
			local meter = Ui.meter(row, barColor, {
				name = "Abundance",
				size = UDim2.new(1, -20, 0, 5),
				pos = UDim2.fromOffset(10, 42),
				color = "panel",
				transparency = 0,
				corner = 2,
			})
			Ui.setMeter(meter, avg)

			table.insert(rows, row)
		end
	end

	-- ---------------------------------------------------------------------------
	-- Server payloads
	-- ---------------------------------------------------------------------------

	local OCEAN_STALE_AFTER = 12 -- the ocean broadcast runs every 5 s
	local latest: { Ui.RegionRow } = {}
	local lastSyncAt = 0

	local function feedStale(): boolean
		return lastSyncAt > 0 and os.clock() - lastSyncAt > OCEAN_STALE_AFTER
	end

	local function renderCurrent(): ()
		if feedStale() then
			destroyRows()
			emptyLabel.Text = "lost the ocean — showing nothing"
			emptyLabel.Visible = true
			return
		end
		rebuild(latest)
	end

	local function onOceanSync(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		local p = payload :: Types.OceanSyncPayload
		lastSyncAt = os.clock()
		latest = Ui.normalizeRegions(p.regions)

		-- how much of the chart real soundings back: the server's own honesty
		-- number, repeated verbatim as the sheet's subtitle
		local coverage = math.clamp(Ui.tonum((p :: any).chartCoverage, 0), 0, 1)
		sheet.setSubtitle(
			sheet,
			string.format(
				"sorted by what is left · %d%% of the chart surveyed",
				math.floor(coverage * 100 + 0.5)
			)
		)

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

	-- while open, a dead feed switches the sheet to its lost state instead of
	-- leaving the last grounds reading as current
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
			local oceanSync = Ui.awaitRemote(Types.REMOTE_FOLDER, Types.OceanSync, 10)
			if oceanSync then
				Ui.connect(connections, oceanSync.OnClientEvent, onOceanSync)
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
