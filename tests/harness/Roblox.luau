--!nonstrict
--[[
	Roblox.luau — a fake Roblox engine for the server boot smoke test.

	WHAT THIS IS
	The smallest stand-in that lets src/Server/** execute outside Studio: a fake
	DataModel (game, workspace, the services the boot path touches), an Instance
	implementation with a real parent/child tree, the datatypes WorldGen builds
	geometry with, and a task scheduler that runs deterministically instead of on
	a wall clock.

	WHAT THIS IS NOT (read this before trusting a green run)
	- No physics, no rendering, no streaming. A part that "exists" here is a row
	  in a table; whether a player would really stand on it is asserted by the
	  smoke test reading CanCollide/Anchored/CFrame, never simulated.
	- CFrame tracks position only. Composition adds positions, which is exact
	  for every expression in this repo (rotations are only ever built with a
	  zero position, via CFrame.Angles, and multiplied in once on the right). A
	  rotation-dependent expression would silently get a wrong LookVector.
	- task.wait yields forever and nothing resumes it, so a loop that waits is a
	  loop that parks. Time advances only when the test fires RunService.Heartbeat
	  and flushes the task.defer queue itself.
	- DataStores answer every read with nil: the Studio-without-API-access
	  degradation path, never persistence.
	- HttpService encodes JSON for real but every request errors, so the backend
	  is always unreachable and the game must run locally — which is exactly the
	  property under test.
]]

local Roblox = {}

--=============================================================================
-- Signals
--=============================================================================

-- Every signal ever created registers here so the smoke test can assert that
-- no handler anywhere errored (an error inside a Connect callback is silent in
-- this harness unless something looks).
local allSignals: { any } = {}

local Signal = {}
Signal.__index = Signal

function Signal.new(name: string): any
	local self = setmetatable({
		name = name,
		_handlers = {},
		errors = {},
	}, Signal)
	table.insert(allSignals, self)
	return self
end

function Signal:Connect(fn: any): any
	local entry = { fn = fn, connected = true }
	table.insert(self._handlers, entry)
	return {
		Disconnect = function()
			entry.connected = false
		end,
	}
end

function Signal:Fire(...: any): ()
	for _, entry in self._handlers do
		if entry.connected then
			local ok, err = pcall(entry.fn, ...)
			if not ok then
				table.insert(self.errors, self.name .. ": " .. tostring(err))
			end
		end
	end
end

function Signal:Wait(): any
	-- The harness never resumes a waiting coroutine. Tests must supply data up
	-- front (e.g. set player.Character before firing PlayerAdded) so that Wait
	-- is never reached; if it is reached, the calling task parks harmlessly.
	return coroutine.yield()
end

--=============================================================================
-- Datatypes
--=============================================================================

local Vector3 = {}
Vector3.__index = Vector3

function Vector3.new(x: number?, y: number?, z: number?): any
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, Vector3)
end

Vector3.__add = function(a, b)
	return Vector3.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
Vector3.__sub = function(a, b)
	return Vector3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
Vector3.__tostring = function(v)
	return string.format("%.3f, %.3f, %.3f", v.X, v.Y, v.Z)
end

local CFrame = {}
CFrame.__index = CFrame

function CFrame.new(x: number?, y: number?, z: number?): any
	local cf = setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, CFrame)
	-- Roblox parts expose .Position; alias it onto the CFrame itself.
	cf.Position = cf
	return cf
end

function CFrame.Angles(_rx: number, _ry: number, _rz: number): any
	-- Rotation is not tracked; see the header. Angles contributes no position,
	-- which is the only thing composition uses.
	return CFrame.new(0, 0, 0)
end

function CFrame.lookAt(from: any, to: any): any
	local dx, dy, dz = to.X - from.X, to.Y - from.Y, to.Z - from.Z
	local len = math.sqrt(dx * dx + dy * dy + dz * dz)
	local cf = CFrame.new(from.X, from.Y, from.Z)
	if len > 0 then
		cf.LookVector = { X = dx / len, Y = dy / len, Z = dz / len }
	end
	return cf
end

CFrame.__mul = function(a, b)
	return CFrame.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
CFrame.__tostring = function(cf)
	return string.format("%.3f, %.3f, %.3f", cf.X, cf.Y, cf.Z)
end

local Color3 = {}
Color3.__index = Color3

function Color3.new(r: number?, g: number?, b: number?): any
	return setmetatable({ R = r or 0, G = g or 0, B = b or 0 }, Color3)
end

function Color3.fromRGB(r: number, g: number, b: number): any
	return Color3.new(r / 255, g / 255, b / 255)
end
Color3.__tostring = function(c)
	return string.format("%.3f, %.3f, %.3f", c.R, c.G, c.B)
end

local UDim2 = {}
UDim2.__index = UDim2

local function udim(scale: number, offset: number)
	return { Scale = scale, Offset = offset }
end

function UDim2.new(xs: number?, xo: number?, ys: number?, yo: number?): any
	return setmetatable({ X = udim(xs or 0, xo or 0), Y = udim(ys or 0, yo or 0) }, UDim2)
end

function UDim2.fromOffset(x: number, y: number): any
	-- this IS fromOffset; the lint suggestion to "use fromOffset" does not apply
	-- selene: allow(roblox_manual_fromscale_or_fromoffset)
	return UDim2.new(0, x, 0, y)
end

function UDim2.fromScale(x: number, y: number): any
	-- selene: allow(roblox_manual_fromscale_or_fromoffset)
	return UDim2.new(x, 0, y, 0)
end

-- Enum auto-vivifies any EnumType.ItemName lookup to a memoized token, so
-- `part.Material == Enum.Material.Water` compares by identity, as in Roblox.
-- A typo'd enum item is indistinguishable from a real one here; that is an
-- accepted limit of the stub, not a promise.
local enumItems: { [string]: any } = {}

-- NOTE: Enum must be declared before the metatable is attached; a closure in
-- its own initializer would otherwise capture the outer (nil) global.
local Enum = {}
setmetatable(Enum, {
	__index = function(_self, enumType: string)
		local items = setmetatable({}, {
			__index = function(_items, itemName: string)
				local key = enumType .. "." .. itemName
				local item = enumItems[key]
				if item == nil then
					item = { EnumType = enumType, Name = itemName }
					enumItems[key] = item
				end
				return item
			end,
		})
		rawset(Enum, enumType, items)
		return items
	end,
})

--=============================================================================
-- task — deterministic scheduling
--=============================================================================

-- Module-level on purpose: one scheduler per process. The smoke test builds
-- exactly one world per run; a second Roblox.new() would share this state.
local Task = {}
Task.errors = {}

local deferQueue: { any } = {}

function Task.spawn(fn: any, ...: any): ()
	local co = coroutine.wrap(function(...)
		local ok, err = pcall(fn, ...)
		if not ok then
			table.insert(Task.errors, "task.spawn: " .. tostring(err))
		end
	end)
	co(...)
end

function Task.defer(fn: any, ...: any): ()
	table.insert(deferQueue, { fn = fn, args = { ... } })
end

function Task.wait(_seconds: number?): any
	-- Yields forever; nothing resumes. See the header.
	return coroutine.yield()
end

--- Run everything deferred so far, including tasks deferred while draining.
--- The smoke test calls this at deterministic points instead of letting a real
--- scheduler decide ordering.
function Task.flush(): ()
	local passes = 0
	while #deferQueue > 0 do
		passes += 1
		if passes > 1000 then
			error(
				"harness: the task.defer queue never drained — a deferred task defers again forever",
				0
			)
		end
		local batch = deferQueue
		deferQueue = {}
		for _, entry in batch do
			local ok, err = pcall(entry.fn, unpack(entry.args))
			if not ok then
				table.insert(Task.errors, "task.defer: " .. tostring(err))
			end
		end
	end
end

--=============================================================================
-- Instances
--=============================================================================

local InstanceMethods = {}

local BASE_PART_CLASSES = {
	Part = true,
	SpawnLocation = true,
	WedgePart = true,
	MeshPart = true,
}

local function collectDescendants(node: any, out: { any })
	for _, child in node.__children do
		table.insert(out, child)
		collectDescendants(child, out)
	end
end

local function instancePath(inst: any): string
	local parts = {}
	local node = inst
	while node do
		table.insert(parts, 1, tostring(node.Name))
		node = node.Parent
	end
	return table.concat(parts, ".")
end

function InstanceMethods:FindFirstChild(name: string): any
	for _, child in self.__children do
		if child.Name == name then
			return child
		end
	end
	return nil
end

function InstanceMethods:FindFirstChildOfClass(className: string): any
	for _, child in self.__children do
		if child.__class == className then
			return child
		end
	end
	return nil
end

function InstanceMethods:GetChildren(): { any }
	return table.clone(self.__children)
end

function InstanceMethods:WaitForChild(name: string): any
	local found = self:FindFirstChild(name)
	if found == nil then
		error(
			string.format(
				"harness WaitForChild: %q is not a child of %s — the fake DataModel tree is incomplete",
				name,
				instancePath(self)
			),
			0
		)
	end
	return found
end

function InstanceMethods:Destroy(): ()
	local parent = self.__parent
	if parent then
		for i, child in parent.__children do
			if child == self then
				table.remove(parent.__children, i)
				break
			end
		end
	end
	self.__parent = nil
	rawset(self, "Parent", nil)
	self.__destroyed = true
end

function InstanceMethods:SetAttribute(key: string, value: any): ()
	self.__attributes[key] = value
end

function InstanceMethods:GetAttribute(key: string): any
	return self.__attributes[key]
end

function InstanceMethods:IsA(className: string): boolean
	if self.__class == className then
		return true
	end
	if className == "BasePart" then
		return BASE_PART_CLASSES[self.__class] == true
	end
	return false
end

function InstanceMethods:SetPrimaryPart(part: any): ()
	self.__primaryPart = part
	-- Roblox exposes PrimaryPart as a property; OceanSurface reads it.
	rawset(self, "PrimaryPart", part)
end

function InstanceMethods:GetPrimaryPart(): any
	return self.__primaryPart
end

--- A model's pivot: the stored pivot, else its primary part, else the origin.
--- Rotation is never tracked (see the header), so a pivot is a position.
function InstanceMethods:GetPivot(): any
	local stored = self.__pivot
	if stored ~= nil then
		return stored
	end
	local pp = self.PrimaryPart
	if pp ~= nil and pp.CFrame ~= nil then
		return pp.CFrame
	end
	return CFrame.new(0, 0, 0)
end

--- Move the whole model by the delta between its current pivot and `target`,
--- translating every part CFrame inside it. OceanSurface uses this to float
--- the boat on the tide.
function InstanceMethods:PivotTo(target: any): ()
	local from = self:GetPivot()
	local dx, dy, dz = target.X - from.X, target.Y - from.Y, target.Z - from.Z
	self.__pivot = target
	if dx == 0 and dy == 0 and dz == 0 then
		return
	end
	local descendants = {}
	collectDescendants(self, descendants)
	for _, inst in descendants do
		local cf = inst.CFrame
		if cf ~= nil and BASE_PART_CLASSES[inst.__class] then
			inst.CFrame = CFrame.new(cf.X + dx, cf.Y + dy, cf.Z + dz)
		end
	end
end

local InstanceMt
InstanceMt = {
	-- Property reads resolve in Roblox order: set properties, then member
	-- methods, then CHILDREN BY NAME (script.Parent.OceanService and
	-- Shared.Ocean.OceanSim are both child-via-property reads).
	__index = function(self: any, key: string)
		local method = InstanceMethods[key]
		if method ~= nil then
			return method
		end
		for _, child in self.__children do
			if child.Name == key then
				return child
			end
		end
		return nil
	end,
	__newindex = function(self: any, key: string, value: any)
		if key == "Parent" then
			local old = rawget(self, "__parent")
			if old ~= value then
				if old then
					for i, child in old.__children do
						if child == self then
							table.remove(old.__children, i)
							break
						end
					end
				end
				if value then
					table.insert(value.__children, self)
				end
				rawset(self, "__parent", value)
				rawset(self, "Parent", value)
			end
		else
			rawset(self, key, value)
		end
	end,
	__tostring = function(self: any)
		return self.__class .. ' "' .. tostring(self.Name) .. '"'
	end,
}

local function makeInstance(className: string): any
	local inst = setmetatable({}, InstanceMt)
	inst.__class = className
	inst.__children = {}
	inst.__attributes = {}
	inst.Name = className
	inst.ClassName = className

	if className == "RemoteEvent" or className == "RemoteFunction" then
		inst.OnServerEvent = Signal.new(className .. ".OnServerEvent")
		inst.OnClientEvent = Signal.new(className .. ".OnClientEvent")
		inst.sentToAll = {}
		inst.sentToPlayers = {}
		-- RemoteEvent exposes `.Event` (an RBXScriptSignal); RemoteFunction does
		-- NOT — it uses `.OnServerEvent`/`.OnClientEvent` instead. Modelling that
		-- difference matters, because `remote.Event:Connect` vs `remote:Connect`
		-- is exactly the distinction Main.server.luau got wrong.
		if className == "RemoteEvent" then
			inst.Event = Signal.new(className .. ".Event")
		end
		function inst:FireAllClients(...: any)
			table.insert(self.sentToAll, { ... })
			-- Real Roblox fires server-side `.Event` connections from the
			-- server's own FireAllClients/FireClient, not just OnClientEvent on
			-- the far end. Main.server.luau's region listener depends on that
			-- to rebuild the world, so the harness has to model it or the test
			-- would be asserting behaviour Roblox does not have.
			if self.Event then
				self.Event:Fire(...)
			end
		end
		function inst:FireClient(player: any, ...: any)
			table.insert(self.sentToPlayers, { player = player, args = { ... } })
			if self.Event then
				self.Event:Fire(...)
			end
		end
	end

	return inst
end

--=============================================================================
-- Services with real behaviour
--=============================================================================

local function jsonEncode(value: any): string
	local t = type(value)
	if t == "string" then
		local escaped = (
			string.gsub(value, '[%c"\\]', function(c: string)
				if c == '"' then
					return '\\"'
				elseif c == "\\" then
					return "\\\\"
				elseif c == "\n" then
					return "\\n"
				elseif c == "\r" then
					return "\\r"
				elseif c == "\t" then
					return "\\t"
				end
				return string.format("\\u%04x", string.byte(c))
			end)
		)
		return '"' .. escaped .. '"'
	elseif t == "boolean" then
		return value and "true" or "false"
	elseif t == "number" then
		return string.format("%.14g", value)
	elseif t ~= "table" then
		return "null"
	end

	local n = #value
	if n > 0 then
		local parts = {}
		for i = 1, n do
			parts[i] = jsonEncode(value[i])
		end
		return "[" .. table.concat(parts, ",") .. "]"
	end

	local keys = {}
	for k in value do
		table.insert(keys, tostring(k))
	end
	table.sort(keys)
	local parts = {}
	for _, k in keys do
		table.insert(parts, jsonEncode(k) .. ":" .. jsonEncode(value[k]))
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

--- Studio without API access: reads are nil, writes "succeed" into nothing.
local function makeDataStore()
	return {
		GetAsync = function()
			return nil
		end,
		SetAsync = function()
			return true
		end,
		UpdateAsync = function(_key: string, transform: any)
			return transform()
		end,
		RemoveAsync = function()
			return nil
		end,
	}
end

--=============================================================================
-- The world
--=============================================================================

function Roblox.new(): any
	local world = {}

	local workspace = makeInstance("Workspace")
	workspace.Name = "Workspace"

	-- default.project.json ships Workspace with an empty Ocean folder; WorldGen
	-- expects to clear it and build into it.
	local oceanFolder = makeInstance("Folder")
	oceanFolder.Name = "Ocean"
	oceanFolder.Parent = workspace

	-- Terrain exists (as a property, which is how Environment reads it) but has
	-- no Water child — exactly what a fresh Studio place gives.
	local terrain = makeInstance("Terrain")
	terrain.Name = "Terrain"
	workspace.Terrain = terrain

	local lighting = makeInstance("Lighting")
	lighting.Name = "Lighting"
	lighting.PropertyChangedSignal = Signal.new("Lighting.PropertyChangedSignal")

	local replicatedStorage = makeInstance("ReplicatedStorage")
	replicatedStorage.Name = "ReplicatedStorage"

	local serverScriptService = makeInstance("ServerScriptService")
	serverScriptService.Name = "ServerScriptService"

	local players = makeInstance("Players")
	players.Name = "Players"
	players.PlayerAdded = Signal.new("Players.PlayerAdded")
	players.PlayerRemoving = Signal.new("Players.PlayerRemoving")
	function players:GetPlayers(): { any }
		local list = {}
		for _, child in self.__children do
			if child.__class == "Player" then
				table.insert(list, child)
			end
		end
		return list
	end

	local runService = { Heartbeat = Signal.new("RunService.Heartbeat") }

	local dataStoreService = {}
	function dataStoreService:GetDataStore(_name: string)
		return makeDataStore()
	end

	local httpService = {}
	function httpService:JSONEncode(value: any): string
		return jsonEncode(value)
	end
	function httpService:JSONDecode(_text: string): any
		error(
			"harness: HttpService:JSONDecode is not stubbed (requests never succeed here, so it is unreachable)",
			2
		)
	end
	function httpService:RequestAsync(_url: string, _options: any): any
		-- Always fails, pcall'd by the caller (OceanClient). The game must
		-- degrade to a locally-simulated ocean — that is the property under
		-- test, so the harness must not "help" by succeeding.
		error("harness: no network in the boot smoke test", 2)
	end

	local services = {
		Workspace = workspace,
		ReplicatedStorage = replicatedStorage,
		ServerScriptService = serverScriptService,
		Lighting = lighting,
		Players = players,
		RunService = runService,
		DataStoreService = dataStoreService,
		HttpService = httpService,
	}

	local gameImpl = {}
	function gameImpl:GetService(name: string): any
		local service = services[name]
		if service == nil then
			error(
				"harness: game:GetService(" .. tostring(name) .. ") — service is not stubbed",
				0
			)
		end
		return service
	end
	gameImpl.__closeCallbacks = {}
	function gameImpl:BindToClose(fn: any)
		table.insert(self.__closeCallbacks, fn)
	end

	world.game = gameImpl
	world.workspace = workspace
	world.terrain = terrain
	world.Instance = { new = makeInstance }
	world.Vector3 = Vector3
	world.CFrame = CFrame
	world.Color3 = Color3
	world.UDim2 = UDim2
	world.Enum = Enum
	world.task = Task
	world.services = services
	world.taskErrors = Task.errors
	world.flushTasks = Task.flush
	world.allSignals = allSignals

	--- A player with just enough surface for Main/ProfileService/CastService.
	function world.makePlayer(userId: number, name: string): any
		local player = makeInstance("Player")
		player.Name = name
		player.UserId = userId
		player.CharacterAdded = Signal.new("Player.CharacterAdded")
		return player
	end

	--- A character whose HumanoidRootPart Main can reposition.
	function world.makeCharacter(): any
		local character = makeInstance("Model")
		character.Name = "SmokeCharacter"
		local root = makeInstance("Part")
		root.Name = "HumanoidRootPart"
		root.CFrame = CFrame.new(0, 0, 0)
		root.Parent = character
		character:SetPrimaryPart(root)
		return character
	end

	return world
end

return Roblox
