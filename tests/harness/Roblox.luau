--!nonstrict
--[[
	Roblox.luau — a strict stand-in Roblox engine for the server boot smoke test.

	WHAT THIS IS
	The smallest engine that lets src/Server/** execute outside Studio: a fake
	DataModel (game, workspace, the services the boot path touches), an Instance
	implementation with a real parent/child tree, the datatypes WorldGen builds
	geometry with, and a task scheduler that runs deterministically instead of on
	a wall clock.

	STRICTNESS POLICY (read this before trusting a green run)
	This stub used to accept whatever the code under test happened to do: it grew
	an `.Event` field on RemoteEvent, accepted `Model:SetPrimaryPart(...)`,
	allowed writing `Lighting.Technology`, and returned nil for missing children.
	Each of those hid a shipped showstopper, and each was discovered in Studio,
	not here. The stub now enforces real member rules instead:

	- Reading or writing a property the instance's class does not have raises
	  `X is not a valid member of Class "Name"` — including dot-access to a
	  child that is not there, which in Studio is an error, never nil.
	- Methods that real Roblox does not have raise the same error
	  (`SetPrimaryPart`, `GetPrimaryPart`, `RemoteEvent.Event`, ...).
	- Property writes are type-checked: `part.Anchored = 5` raises
	  `unable to assign property Anchored. boolean expected, got number`.
	- Script Security properties (Lighting.Technology) refuse writes with the
	  Studio capability error.
	- HttpService:RequestAsync has the real single-options-table signature.
	- A destroyed instance's Parent is locked, as in Studio.

	The boot suite asserts this strictness itself (the "harness fidelity" suite
	in tests/boot-tests.luau), so a regression toward rubber-stamping is red,
	not silent. See docs/HARNESS-FIDELITY.md for the full account: what is
	modelled exactly, what is approximate on purpose, and what is UNVERIFIED.

	WHAT THIS IS NOT
	- No physics, no rendering, no streaming. A part that "exists" here is a row
	  in a table; whether a player would really stand on it is asserted by the
	  smoke test reading CanCollide/Anchored/CFrame, never simulated.
	- Unset properties read as nil, not as their Roblox class defaults. This is
	  deliberate: it is what lets the tests detect "that tuning is dead code".
	  Code that relies on a default (part.Transparency == 0) sees nil instead.
	- CFrame tracks position only. Composition adds positions, which is exact
	  for every expression in this repo (rotations are only ever built with a
	  zero position, via CFrame.Angles, and multiplied in once on the right). A
	  rotation-dependent expression silently gets a wrong LookVector.
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
	if type(fn) ~= "function" then
		error(
			string.format("invalid argument #1 to 'Connect' (function expected, got %s)", type(fn)),
			2
		)
	end
	local entry = { fn = fn, connected = true }
	table.insert(self._handlers, entry)
	local connection = setmetatable({}, {
		__index = function(_self: any, k: string)
			if k == "Connected" then
				return entry.connected
			end
			return nil
		end,
		__newindex = function()
			error("harness: RBXScriptConnection is read-only (call Disconnect)", 0)
		end,
	})
	rawset(connection, "Disconnect", function()
		entry.connected = false
	end)
	return connection
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
-- Real Roblox Vector3 exposes .Magnitude as a number. Modelling it as a plain
-- table field would let a metatable-indexed helper look like it compiled when
-- it had actually errored on every call.
Vector3.__index = function(t, k)
	if k == "Magnitude" then
		return math.sqrt(t.X * t.X + t.Y * t.Y + t.Z * t.Z)
	end
	return Vector3[k]
end

function Vector3.new(x: number?, y: number?, z: number?): any
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, Vector3)
end

Vector3.__add = function(a, b)
	return Vector3.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
Vector3.__sub = function(a, b)
	return Vector3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
Vector3.__mul = function(a, b)
	if type(a) == "number" then
		return Vector3.new(a * b.X, a * b.Y, a * b.Z)
	end
	if type(b) == "number" then
		return Vector3.new(a.X * b, a.Y * b, a.Z * b)
	end
	error("Vector3 can only be multiplied by a number", 2)
end
Vector3.__tostring = function(v)
	return string.format("%.3f, %.3f, %.3f", v.X, v.Y, v.Z)
end

local CFrame = {}
CFrame.__index = CFrame

local function isVector3(v: any): boolean
	return type(v) == "table" and getmetatable(v) == Vector3
end

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
	if getmetatable(b) ~= CFrame then
		error("CFrame can only be multiplied by a CFrame (got " .. type(b) .. ")", 2)
	end
	return CFrame.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
-- Real Roblox: CFrame + Vector3 translates the CFrame. Anything else errors.
CFrame.__add = function(a, b)
	if not isVector3(b) then
		error("CFrame can only be added to a Vector3", 2)
	end
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
-- The class registry
--
-- Every Instance is a member of exactly one registered class, and every
-- property/method/signal it may have is declared here. Anything not declared
-- raises `X is not a valid member of Class "Name"`, which is what Studio does.
-- If the boot path legitimately needs a real Roblox member this table lacks,
-- add it — after checking the real API, not the code under test.
--=============================================================================

local CLASS_PARENTS: { [string]: string } = {
	-- geometry
	Part = "BasePart",
	SpawnLocation = "Part",
	WedgePart = "BasePart",
	MeshPart = "BasePart",
	Terrain = "BasePart",
	BasePart = "PVInstance",
	Model = "PVInstance",
	Workspace = "Model",
	PVInstance = "Instance",
	-- containers and scripts
	Folder = "Instance",
	ModuleScript = "Instance",
	Script = "Instance",
	LocalScript = "Instance",
	-- networking
	RemoteEvent = "Instance",
	RemoteFunction = "Instance",
	-- gui (real hierarchy is deeper; Instance-parented here is equivalent for
	-- every member the boot path touches)
	BillboardGui = "Instance",
	TextLabel = "Instance",
	-- lighting effects
	Atmosphere = "Instance",
	Clouds = "Instance",
	-- services
	Lighting = "Instance",
	Players = "Instance",
	ReplicatedStorage = "Instance",
	ServerScriptService = "Instance",
	RunService = "Instance",
	HttpService = "Instance",
	DataStoreService = "Instance",
	-- actors
	Player = "Instance",
	Humanoid = "Instance",
	-- server-side signalling and value objects: not used by the boot path
	-- today, but real current API and the natural material for fixing the
	-- region-listener bug, so the harness must not falsely reject them
	BindableEvent = "Instance",
	BindableFunction = "Instance",
	IntValue = "Instance",
	NumberValue = "Instance",
	StringValue = "Instance",
	BoolValue = "Instance",
	ObjectValue = "Instance",
}

-- Classes Instance.new will actually construct. Abstract chain entries
-- (BasePart, PVInstance, Instance) are refused, as Studio refuses them.
local CREATABLE_CLASSES: { [string]: boolean } = {
	Part = true,
	SpawnLocation = true,
	WedgePart = true,
	MeshPart = true,
	Terrain = true,
	Model = true,
	Workspace = true,
	Folder = true,
	ModuleScript = true,
	Script = true,
	LocalScript = true,
	RemoteEvent = true,
	RemoteFunction = true,
	BillboardGui = true,
	TextLabel = true,
	Atmosphere = true,
	Clouds = true,
	Lighting = true,
	Players = true,
	ReplicatedStorage = true,
	ServerScriptService = true,
	RunService = true,
	HttpService = true,
	DataStoreService = true,
	Player = true,
	Humanoid = true,
	BindableEvent = true,
	BindableFunction = true,
	IntValue = true,
	NumberValue = true,
	StringValue = true,
	BoolValue = true,
	ObjectValue = true,
}

local function inheritsClass(className: string, ancestor: string): boolean
	local cls: string? = className
	while cls do
		if cls == ancestor then
			return true
		end
		cls = CLASS_PARENTS[cls]
	end
	return false
end

local function isInstance(v: any): boolean
	return type(v) == "table" and rawget(v, "__class") ~= nil
end

--- The name Roblox would print for a value in a property type error.
local function describeValue(value: any): string
	local t = type(value)
	if t ~= "table" then
		return t
	end
	if isInstance(value) then
		return tostring(value.__class)
	end
	local mt = getmetatable(value)
	if mt == Vector3 or mt == CFrame or mt == Color3 or mt == UDim2 then
		local names =
			{ [Vector3] = "Vector3", [CFrame] = "CFrame", [Color3] = "Color3", [UDim2] = "UDim2" }
		return names[mt]
	elseif type(value.EnumType) == "string" then
		return "EnumItem"
	end
	return "table"
end

local function displayExpected(expected: string): string
	if string.sub(expected, 1, 5) == "Enum:" then
		return "Enum." .. string.sub(expected, 6)
	end
	if string.sub(expected, -1) == "?" then
		return string.sub(expected, 1, -2)
	end
	return expected
end

local function valueMatches(expected: string, value: any): boolean
	if expected == "string" or expected == "number" or expected == "boolean" then
		return type(value) == expected
	elseif
		expected == "Vector3"
		or expected == "CFrame"
		or expected == "Color3"
		or expected == "UDim2"
	then
		local mts: { [string]: any } = {
			Vector3 = Vector3,
			CFrame = CFrame,
			Color3 = Color3,
			UDim2 = UDim2,
		}
		return type(value) == "table" and getmetatable(value) == mts[expected]
	elseif string.sub(expected, 1, 5) == "Enum:" then
		local enumType = string.sub(expected, 6)
		return type(value) == "table"
			and type(value.EnumType) == "string"
			and value.EnumType == enumType
	elseif expected == "Instance?" then
		return value == nil or isInstance(value)
	elseif expected == "Model?" then
		return value == nil or (isInstance(value) and inheritsClass(value.__class, "Model"))
	elseif expected == "BasePart?" then
		return value == nil or (isInstance(value) and inheritsClass(value.__class, "BasePart"))
	elseif expected == "function?" then
		return value == nil or type(value) == "function"
	elseif expected == "position" then
		return isVector3(value)
	end
	error("harness: unknown property type " .. expected, 0)
end

--=============================================================================
-- Instance methods (declared before the registry that names them)
--=============================================================================

local BASE_PART_CLASSES = {
	Part = true,
	SpawnLocation = true,
	WedgePart = true,
	MeshPart = true,
	Terrain = true,
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
		table.insert(parts, 1, tostring(node.__values.Name))
		node = rawget(node, "__parent")
	end
	return table.concat(parts, ".")
end

local function notAValidMember(key: string, inst: any): string
	return string.format(
		'%s is not a valid member of %s "%s"',
		tostring(key),
		tostring(inst.__class),
		tostring(inst.__values.Name)
	)
end

local InstanceMethods = {}

function InstanceMethods:FindFirstChild(name: string, recursive: boolean?): any
	for _, child in self.__children do
		if child.__values.Name == name then
			return child
		end
	end
	if recursive then
		local descendants = {}
		collectDescendants(self, descendants)
		for _, inst in descendants do
			if inst.__values.Name == name then
				return inst
			end
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

function InstanceMethods:FindFirstChildWhichIsA(className: string, recursive: boolean?): any
	for _, child in self.__children do
		if inheritsClass(child.__class, className) then
			return child
		end
	end
	if recursive then
		local descendants = {}
		collectDescendants(self, descendants)
		for _, inst in descendants do
			if inheritsClass(inst.__class, className) then
				return inst
			end
		end
	end
	return nil
end

function InstanceMethods:GetChildren(): { any }
	return table.clone(self.__children)
end

function InstanceMethods:GetDescendants(): { any }
	local out = {}
	collectDescendants(self, out)
	return out
end

function InstanceMethods:WaitForChild(name: string): any
	local found = self:FindFirstChild(name)
	if found == nil then
		-- Real Roblox yields forever (with an "Infinite yield possible" warn).
		-- A harness that hangs proves nothing, so this is a deliberate
		-- divergence: a missing child is a loud error, not a parked test.
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

function InstanceMethods:ClearAllChildren(): ()
	for _, child in table.clone(self.__children) do
		child:Destroy()
	end
end

function InstanceMethods:Destroy(): ()
	if rawget(self, "__destroyed") then
		return
	end
	local parent = rawget(self, "__parent")
	if parent then
		for i, child in parent.__children do
			if child == self then
				table.remove(parent.__children, i)
				break
			end
		end
	end
	-- Real Destroy takes the descendants with it.
	local descendants = {}
	collectDescendants(self, descendants)
	rawset(self, "__children", {})
	rawset(self, "__destroyed", true)
	rawset(self, "__parent", nil)
	self.__values.Parent = nil
	for _, inst in descendants do
		rawset(inst, "__destroyed", true)
		rawset(inst, "__parent", nil)
		inst.__values.Parent = nil
	end
end

function InstanceMethods:SetAttribute(key: string, value: any): ()
	self.__attributes[key] = value
end

function InstanceMethods:GetAttribute(key: string): any
	return self.__attributes[key]
end

function InstanceMethods:IsA(className: string): boolean
	if type(className) ~= "string" then
		error(
			string.format("invalid argument #1 to 'IsA' (string expected, got %s)", type(className)),
			2
		)
	end
	return inheritsClass(self.__class, className)
end

function InstanceMethods:GetPropertyChangedSignal(prop: string): any
	if type(prop) ~= "string" then
		error(
			string.format(
				"invalid argument #1 to 'GetPropertyChangedSignal' (string expected, got %s)",
				type(prop)
			),
			2
		)
	end
	local pcs = rawget(self, "__pcs")
	if pcs == nil then
		pcs = {}
		rawset(self, "__pcs", pcs)
	end
	local sig = pcs[prop]
	if sig == nil then
		sig = Signal.new(self.__class .. "." .. prop .. ".PropertyChanged")
		pcs[prop] = sig
	end
	return sig
end

--- Internal writer used by the harness's own machinery (PivotTo translating
--- parts, world building). Same rules as a game-code write, minus nothing.
local function setPropertyValue(inst: any, key: string, value: any)
	local old = inst.__values[key]
	inst.__values[key] = value
	if old ~= value then
		local pcs = rawget(inst, "__pcs")
		if pcs then
			local sig = pcs[key]
			if sig then
				-- Real property-changed callbacks receive no arguments.
				sig:Fire()
			end
		end
	end
end

-- PVInstance pivots. Real Roblox puts GetPivot/PivotTo on every PVInstance
-- (models AND parts); a Folder has neither.
local function translateCFrame(inst: any, dx: number, dy: number, dz: number)
	local cf = inst.__values.CFrame
	if cf ~= nil then
		setPropertyValue(inst, "CFrame", CFrame.new(cf.X + dx, cf.Y + dy, cf.Z + dz))
	end
end

function InstanceMethods:GetPivot(): any
	local stored = rawget(self, "__pivot")
	if stored ~= nil then
		return stored
	end
	if inheritsClass(self.__class, "Model") then
		local pp = self.__values.PrimaryPart
		if pp ~= nil and pp.__values.CFrame ~= nil then
			return pp.__values.CFrame
		end
		return CFrame.new(0, 0, 0)
	end
	local cf = self.__values.CFrame
	if cf ~= nil then
		return cf
	end
	return CFrame.new(0, 0, 0)
end

function InstanceMethods:PivotTo(target: any): ()
	if type(target) ~= "table" or getmetatable(target) ~= CFrame then
		error(
			string.format(
				"invalid argument #1 to 'PivotTo' (CFrame expected, got %s)",
				describeValue(target)
			),
			2
		)
	end
	local from = self:GetPivot()
	local dx, dy, dz = target.X - from.X, target.Y - from.Y, target.Z - from.Z
	rawset(self, "__pivot", target)
	if dx == 0 and dy == 0 and dz == 0 then
		return
	end
	if inheritsClass(self.__class, "Model") then
		local descendants = {}
		collectDescendants(self, descendants)
		for _, inst in descendants do
			if BASE_PART_CLASSES[inst.__class] then
				translateCFrame(inst, dx, dy, dz)
			end
		end
	else
		translateCFrame(self, dx, dy, dz)
	end
end

-- RemoteEvent behaviour. FireAllClients/FireClient deliver to clients only:
-- in real Roblox the server's own OnServerEvent connections do NOT fire from
-- its own outgoing fires, and this harness models exactly that (a past version
-- fired a fake `.Event` here, which hid the region-listener bug for weeks).
--
-- sentToAll/sentToPlayers are harness TELEMETRY, not Roblox members: the
-- outgoing-fire log the boot suite asserts on. They are read-only from Luau
-- and documented as an approximation in docs/HARNESS-FIDELITY.md.
local function remoteFireAllClients(self: any, ...: any): ()
	table.insert(self.__values.sentToAll, { ... })
end

local function remoteFireClient(self: any, player: any, ...: any): ()
	if not (isInstance(player) and player.__class == "Player") then
		error(
			string.format(
				"invalid argument #1 to 'FireClient' (Player expected, got %s)",
				describeValue(player)
			),
			2
		)
	end
	table.insert(self.__values.sentToPlayers, { player = player, args = { ... } })
end

local function clientOnlyCall(name: string): ()
	error(
		"harness: RemoteEvent:"
			.. name
			.. " is a client-only call and cannot be modelled server-side",
		2
	)
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

--- HttpService.JSONEncode as a spec'd method (self is the service instance).
local function httpJSONEncode(_self: any, value: any): string
	return jsonEncode(value)
end

--=============================================================================
-- The registry itself
--=============================================================================

local function mergeMethods(base: { [string]: any }, extra: { [string]: any }): { [string]: any }
	local merged = table.clone(base)
	for k, v in extra do
		merged[k] = v
	end
	return merged
end

local CLASS_SPECS: { [string]: any } = {}
local MEMBER_CACHE: { [string]: { [string]: any } } = {}
local SIGNALS_CACHE: { [string]: { [string]: boolean } } = {}

-- spec fields:
--   props         [name] = type string          — writable, type-checked
--   readOnly      [name] = true                 — readable, not assignable
--   scriptSecurity [name] = true                — readable, write -> capability error
--   signals       [name] = true                 — readable signal, Connect-only
--   callbacks     [name] = type string          — writable callback ("function?")
--   methods       [name] = fn                   — callable members
local BASE_PROPS: { [string]: string } = {
	Name = "string",
	Parent = "Instance?",
}

local function classSignals(className: string): { [string]: boolean }
	local cached = SIGNALS_CACHE[className]
	if cached ~= nil then
		return cached
	end
	local merged: { [string]: boolean } = {}
	local cls: string? = className
	while cls do
		local spec = CLASS_SPECS[cls]
		if spec and spec.signals then
			for name in spec.signals do
				merged[name] = true
			end
		end
		cls = CLASS_PARENTS[cls]
	end
	SIGNALS_CACHE[className] = merged
	return merged
end

--- Resolve a member key against a class and its ancestors. Returns a table
--- with kind + type, or nil when no class in the chain declares the key.
--- Methods win over properties (names never collide in the real API), and
--- every member wins over children — `folder.FindFirstChild` is the method
--- even if a child is named "FindFirstChild", as in Studio.
local function memberInfo(className: string, key: string): any?
	local byKey = MEMBER_CACHE[className]
	if byKey == nil then
		byKey = {}
		MEMBER_CACHE[className] = byKey
	end
	local hit = byKey[key]
	if hit ~= nil then
		return hit
	end
	local cls: string? = className
	while cls do
		local spec = CLASS_SPECS[cls]
		if spec then
			if spec.methods and spec.methods[key] ~= nil then
				hit = { kind = "method", value = spec.methods[key] }
				break
			end
			if spec.props and spec.props[key] ~= nil then
				hit = { kind = "prop", typeName = spec.props[key] }
				break
			end
			if spec.callbacks and spec.callbacks[key] ~= nil then
				hit = { kind = "callback", typeName = spec.callbacks[key] }
				break
			end
			if spec.readOnly and spec.readOnly[key] then
				hit = { kind = "readOnly" }
				break
			end
			if spec.scriptSecurity and spec.scriptSecurity[key] then
				hit = { kind = "scriptSecurity" }
				break
			end
			if spec.signals and spec.signals[key] then
				hit = { kind = "signal" }
				break
			end
		end
		cls = CLASS_PARENTS[cls]
	end
	byKey[key] = hit or false
	return hit
end

local SCRIPT_SECURITY_WRITE = "The current thread cannot write 'Technology' (lacking capability)"

--=============================================================================
-- The Instance metatable
--=============================================================================

local InstanceMt
InstanceMt = {
	-- Property reads resolve in Roblox order: class members (methods, then
	-- properties/signals), then CHILDREN BY NAME (script.Parent.OceanService
	-- and Shared.Ocean.OceanSim are both child-via-property reads). A key that
	-- is neither a member nor a child is an ERROR in Studio, not nil — this is
	-- the rule whose absence once let `Shared.Ocean.Config` (which does not
	-- exist; Config lives in Shared/) pass every headless test and kill the
	-- whole server boot in Studio.
	__index = function(self: any, key: string)
		if type(key) ~= "string" or string.sub(key, 1, 2) == "__" then
			return rawget(self, key)
		end
		local m = memberInfo(self.__class, key)
		if m then
			if m.kind == "method" then
				return m.value
			end
			if m.typeName == "position" then
				local cf = self.__values.CFrame
				if cf == nil then
					return nil
				end
				return Vector3.new(cf.X, cf.Y, cf.Z)
			end
			return self.__values[key]
		end
		for _, child in self.__children do
			if child.__values.Name == key then
				return child
			end
		end
		error(notAValidMember(key, self), 0)
	end,
	__newindex = function(self: any, key: string, value: any)
		if key == "Parent" then
			if rawget(self, "__destroyed") then
				error(
					string.format(
						'The Parent property of %s "%s" is locked',
						tostring(self.__class),
						tostring(self.__values.Name)
					),
					0
				)
			end
			if value ~= nil and not isInstance(value) then
				error(
					string.format(
						"unable to assign property Parent. Instance expected, got %s",
						describeValue(value)
					),
					0
				)
			end
			if value ~= nil then
				local node: any = value
				while node do
					if node == self then
						error(
							string.format(
								'harness: cannot parent %s "%s" to itself or its descendant',
								tostring(self.__class),
								tostring(self.__values.Name)
							),
							0
						)
					end
					node = rawget(node, "__parent")
				end
			end
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
				self.__values.Parent = value
			end
			return
		end
		if type(key) ~= "string" or string.sub(key, 1, 2) == "__" then
			-- "__"-prefixed keys are the harness's own storage channel. Game
			-- code has no business writing them; the harness has no other way
			-- to keep internal state off the member-validated surface.
			rawset(self, key, value)
			return
		end
		local m = memberInfo(self.__class, key)
		if not m then
			error(notAValidMember(key, self), 0)
		end
		if m.kind == "method" then
			error(
				string.format(
					'harness: "%s" is a method of %s and cannot be assigned',
					tostring(key),
					tostring(self.__class)
				),
				0
			)
		end
		if m.kind == "scriptSecurity" then
			error(SCRIPT_SECURITY_WRITE, 0)
		end
		if m.kind == "readOnly" or m.kind == "signal" then
			local hint = if m.kind == "signal" then " (Connect to the signal instead)" else ""
			error(
				string.format(
					"unable to assign property %s. Property is read only%s",
					tostring(key),
					hint
				),
				0
			)
		end
		local expected = m.typeName
		if not valueMatches(expected, value) then
			error(
				string.format(
					"unable to assign property %s. %s expected, got %s",
					tostring(key),
					displayExpected(expected),
					describeValue(value)
				),
				0
			)
		end
		if expected == "position" then
			local cf = CFrame.new(value.X, value.Y, value.Z)
			setPropertyValue(self, "CFrame", cf)
			return
		end
		setPropertyValue(self, key, value)
	end,
	__tostring = function(self: any)
		return self.__class .. ' "' .. tostring(self.__values.Name) .. '"'
	end,
}

local function makeInstance(className: string, parent: any?): any
	if not CREATABLE_CLASSES[className] then
		if CLASS_PARENTS[className] ~= nil or className == "Instance" then
			error("harness Instance.new: " .. className .. " is an abstract base class", 0)
		end
		error(
			'harness Instance.new: "'
				.. tostring(className)
				.. '" is not a class this harness knows — if it is a real current Roblox class, teach the registry; if it is not, the code is inventing classes',
			0
		)
	end
	local inst = setmetatable({}, InstanceMt)
	rawset(inst, "__class", className)
	rawset(inst, "__children", {})
	rawset(inst, "__attributes", {})
	rawset(inst, "__values", { Name = className, ClassName = className })
	for signalName in classSignals(className) do
		inst.__values[signalName] = Signal.new(className .. "." .. signalName)
	end
	if className == "RemoteEvent" then
		inst.__values.sentToAll = {}
		inst.__values.sentToPlayers = {}
	end
	if parent ~= nil then
		inst.Parent = parent
	end
	return inst
end

--=============================================================================
-- Service behaviour beyond the member registry
--=============================================================================

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

--- typeof as Roblox defines it: fake instances are "Instance", the stub
--- datatypes report their Roblox names, everything else falls through.
local function robloxTypeof(v: any): string
	if type(v) == "table" then
		if rawget(v, "__class") ~= nil then
			return "Instance"
		end
		local mt = getmetatable(v)
		if mt == Vector3 then
			return "Vector3"
		elseif mt == CFrame then
			return "CFrame"
		elseif mt == Color3 then
			return "Color3"
		elseif mt == UDim2 then
			return "UDim2"
		elseif type(v.EnumType) == "string" then
			return "EnumItem"
		end
	end
	return type(v)
end

--=============================================================================
-- Spec declarations (after every function they name)
--=============================================================================

local METHODS_BASE: { [string]: any } = {
	FindFirstChild = InstanceMethods.FindFirstChild,
	FindFirstChildOfClass = InstanceMethods.FindFirstChildOfClass,
	FindFirstChildWhichIsA = InstanceMethods.FindFirstChildWhichIsA,
	GetChildren = InstanceMethods.GetChildren,
	GetDescendants = InstanceMethods.GetDescendants,
	WaitForChild = InstanceMethods.WaitForChild,
	Destroy = InstanceMethods.Destroy,
	ClearAllChildren = InstanceMethods.ClearAllChildren,
	SetAttribute = InstanceMethods.SetAttribute,
	GetAttribute = InstanceMethods.GetAttribute,
	IsA = InstanceMethods.IsA,
	GetPropertyChangedSignal = InstanceMethods.GetPropertyChangedSignal,
}

local METHODS_PV = mergeMethods(METHODS_BASE, {
	GetPivot = InstanceMethods.GetPivot,
	PivotTo = InstanceMethods.PivotTo,
})

local METHODS_REMOTE_EVENT = mergeMethods(METHODS_BASE, {
	FireAllClients = remoteFireAllClients,
	FireClient = remoteFireClient,
	FireServer = function()
		clientOnlyCall("FireServer")
	end,
})

local METHODS_REMOTE_FUNCTION = mergeMethods(METHODS_BASE, {
	InvokeServer = function()
		error(
			"harness: RemoteFunction:InvokeServer is a client-only call and cannot be modelled server-side",
			2
		)
	end,
	InvokeClient = function()
		error("harness: RemoteFunction:InvokeClient is not modelled (deprecated surface)", 2)
	end,
})

local METHODS_PLAYERS = mergeMethods(METHODS_BASE, {
	GetPlayers = function(self: any): { any }
		local list = {}
		for _, child in self.__children do
			if child.__class == "Player" then
				table.insert(list, child)
			end
		end
		return list
	end,
})

local METHODS_RUN_SERVICE = mergeMethods(METHODS_BASE, {
	IsServer = function()
		return true
	end,
	IsClient = function()
		return false
	end,
	IsStudio = function()
		return false
	end,
})

local METHODS_HTTP = mergeMethods(METHODS_BASE, {
	JSONEncode = httpJSONEncode,
	JSONDecode = function(_self: any, _text: string): any
		error(
			"harness: HttpService:JSONDecode is not stubbed (requests never succeed here, so it is unreachable)",
			2
		)
	end,
	RequestAsync = function(_self: any, options: any): any
		-- The real API is HttpService:RequestAsync(options) with ONE table
		-- carrying Url/Method/Headers/Body. Anything else is a Studio error.
		if type(options) ~= "table" then
			error(
				string.format(
					"invalid argument #1 to 'RequestAsync' (table expected, got %s)",
					type(options)
				),
				2
			)
		end
		if type(options.Url) ~= "string" then
			error(
				"harness: HttpService:RequestAsync — options.Url must be a string (the real API takes ONE options table: Url, Method, Headers, Body)",
				2
			)
		end
		-- Always fails, pcall'd by the caller (OceanClient). The game must
		-- degrade to a locally-simulated ocean — that is the property under
		-- test, so the harness must not "help" by succeeding.
		error("harness: no network in the boot smoke test", 2)
	end,
})

local METHODS_DATASTORE = mergeMethods(METHODS_BASE, {
	GetDataStore = function(_self: any, name: any)
		if type(name) ~= "string" then
			error(
				string.format(
					"invalid argument #1 to 'GetDataStore' (string expected, got %s)",
					type(name)
				),
				2
			)
		end
		return makeDataStore()
	end,
})

local BASEPART_PROPS: { [string]: string } = {
	Size = "Vector3",
	CFrame = "CFrame",
	Position = "position",
	Anchored = "boolean",
	CanCollide = "boolean",
	CanTouch = "boolean",
	CanQuery = "boolean",
	CastShadow = "boolean",
	Material = "Enum:Material",
	Color = "Color3",
	Transparency = "number",
	Reflectance = "number",
	TopSurface = "Enum:SurfaceType",
	BottomSurface = "Enum:SurfaceType",
}

CLASS_SPECS["Instance"] = {
	props = BASE_PROPS,
	readOnly = { ClassName = true },
	methods = METHODS_BASE,
}

CLASS_SPECS["PVInstance"] = {
	methods = METHODS_PV,
}

CLASS_SPECS["BasePart"] = {
	props = BASEPART_PROPS,
	methods = METHODS_PV,
}

CLASS_SPECS["Part"] = {
	props = { Shape = "Enum:PartType" },
	methods = METHODS_PV,
}

CLASS_SPECS["SpawnLocation"] = {
	props = { Neutral = "boolean", Duration = "number" },
	methods = METHODS_PV,
}

CLASS_SPECS["MeshPart"] = {
	props = { MeshId = "string" },
	methods = METHODS_PV,
}

CLASS_SPECS["Terrain"] = {
	methods = METHODS_PV,
}

CLASS_SPECS["Model"] = {
	props = { PrimaryPart = "BasePart?" },
	methods = METHODS_PV,
}

CLASS_SPECS["Workspace"] = {
	readOnly = { Terrain = true },
	methods = METHODS_PV,
}

CLASS_SPECS["Folder"] = {}
CLASS_SPECS["ModuleScript"] = {}
CLASS_SPECS["Script"] = {}
CLASS_SPECS["LocalScript"] = {}
CLASS_SPECS["Humanoid"] = {}

-- BindableEvent fires its own .Event synchronously from :Fire() — this IS
-- real Roblox behaviour (unlike RemoteEvent, where the server never observes
-- its own outgoing fires). That asymmetry is the whole reason a BindableEvent
-- is the correct tool for the region-discovered listener.
CLASS_SPECS["BindableEvent"] = {
	signals = { Event = true },
	methods = mergeMethods(METHODS_BASE, {
		Fire = function(self: any, ...: any): ()
			self.__values.Event:Fire(...)
		end,
	}),
}

CLASS_SPECS["BindableFunction"] = {
	callbacks = { OnInvoke = "function?" },
	methods = mergeMethods(METHODS_BASE, {
		Invoke = function(self: any, ...: any): any
			local cb = self.__values.OnInvoke
			if type(cb) ~= "function" then
				error("harness: BindableFunction:Invoke — OnInvoke is not set", 2)
			end
			return cb(...)
		end,
	}),
}

CLASS_SPECS["IntValue"] = {
	props = { Value = "number" },
}
CLASS_SPECS["NumberValue"] = {
	props = { Value = "number" },
}
CLASS_SPECS["StringValue"] = {
	props = { Value = "string" },
}
CLASS_SPECS["BoolValue"] = {
	props = { Value = "boolean" },
}
CLASS_SPECS["ObjectValue"] = {
	props = { Value = "Instance?" },
}

CLASS_SPECS["RemoteEvent"] = {
	signals = { OnServerEvent = true, OnClientEvent = true },
	-- Harness telemetry (see remoteFireAllClients above): readable so test
	-- files can assert on what was broadcast, read-only so game code cannot
	-- forge a log. Not Roblox members; the one deliberate naming compromise.
	readOnly = { sentToAll = true, sentToPlayers = true },
	methods = METHODS_REMOTE_EVENT,
}

CLASS_SPECS["RemoteFunction"] = {
	callbacks = { OnServerInvoke = "function?", OnClientInvoke = "function?" },
	methods = METHODS_REMOTE_FUNCTION,
}

CLASS_SPECS["BillboardGui"] = {
	props = {
		Size = "UDim2",
		StudsOffset = "Vector3",
		AlwaysOnTop = "boolean",
		MaxDistance = "number",
		Enabled = "boolean",
	},
}

CLASS_SPECS["TextLabel"] = {
	props = {
		Size = "UDim2",
		Text = "string",
		Font = "Enum:Font",
		TextColor3 = "Color3",
		TextStrokeTransparency = "number",
		TextScaled = "boolean",
		BackgroundTransparency = "number",
		BackgroundColor3 = "Color3",
		TextSize = "number",
		RichText = "boolean",
		Visible = "boolean",
	},
}

CLASS_SPECS["Atmosphere"] = {
	props = {
		Density = "number",
		Offset = "number",
		Color = "Color3",
		Decay = "Color3",
		Glare = "number",
		Haze = "number",
	},
}

CLASS_SPECS["Clouds"] = {
	props = {
		Cover = "number",
		Density = "number",
		Color = "Color3",
		Enabled = "boolean",
	},
}

CLASS_SPECS["Lighting"] = {
	props = {
		Ambient = "Color3",
		OutdoorAmbient = "Color3",
		Brightness = "number",
		ExposureCompensation = "number",
		FogColor = "Color3",
		FogStart = "number",
		FogEnd = "number",
		ClockTime = "number",
		GlobalShadows = "boolean",
	},
	scriptSecurity = { Technology = true },
}

CLASS_SPECS["Players"] = {
	signals = { PlayerAdded = true, PlayerRemoving = true },
	methods = METHODS_PLAYERS,
}

CLASS_SPECS["Player"] = {
	props = { UserId = "number", Character = "Model?" },
	signals = { CharacterAdded = true },
}

CLASS_SPECS["RunService"] = {
	signals = { Heartbeat = true, PreSimulation = true, PostSimulation = true },
	methods = METHODS_RUN_SERVICE,
}

CLASS_SPECS["HttpService"] = {
	methods = METHODS_HTTP,
}

CLASS_SPECS["DataStoreService"] = {
	methods = METHODS_DATASTORE,
}

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

	-- Terrain exists (as a property, which is how the boot test probes it) but
	-- has no Water child — exactly what a fresh Studio place gives.
	local terrain = makeInstance("Terrain")
	terrain.Name = "Terrain"
	workspace.__values.Terrain = terrain

	local lighting = makeInstance("Lighting")
	lighting.Name = "Lighting"

	local replicatedStorage = makeInstance("ReplicatedStorage")
	replicatedStorage.Name = "ReplicatedStorage"

	local serverScriptService = makeInstance("ServerScriptService")
	serverScriptService.Name = "ServerScriptService"

	local players = makeInstance("Players")
	players.Name = "Players"

	local runService = makeInstance("RunService")
	runService.Name = "RunService"

	local dataStoreService = makeInstance("DataStoreService")
	dataStoreService.Name = "DataStoreService"

	local httpService = makeInstance("HttpService")
	httpService.Name = "HttpService"

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

	local gameImpl = { __closeCallbacks = {} }
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
	function gameImpl:BindToClose(fn: any)
		table.insert(self.__closeCallbacks, fn)
	end
	setmetatable(gameImpl, {
		-- game.Workspace / game.Players etc. are real DataModel properties;
		-- anything else on game is an error, as in Studio.
		__index = function(_self: any, key: string)
			local service = services[key]
			if service == nil then
				error(
					string.format('%s is not a valid member of DataModel "game"', tostring(key)),
					0
				)
			end
			return service
		end,
		__newindex = function()
			error(
				"harness: game is read-only (GetService and BindToClose are its callable surface)",
				0
			)
		end,
	})

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
	world.typeof = robloxTypeof
	world.services = services
	world.taskErrors = Task.errors
	world.flushTasks = Task.flush
	world.allSignals = allSignals

	--- A player with just enough surface for Main/ProfileService/CastService.
	function world.makePlayer(userId: number, name: string): any
		local player = makeInstance("Player")
		player.Name = name
		player.UserId = userId
		return player
	end

	--- A character whose HumanoidRootPart Main can reposition. PrimaryPart is
	--- set with the modern property form — the SetPrimaryPart() method was
	--- removed from Roblox and the harness rejects it.
	function world.makeCharacter(): any
		local character = makeInstance("Model")
		character.Name = "SmokeCharacter"
		local root = makeInstance("Part")
		root.Name = "HumanoidRootPart"
		root.CFrame = CFrame.new(0, 0, 0)
		root.Parent = character
		character.PrimaryPart = root
		return character
	end

	return world
end

return Roblox
