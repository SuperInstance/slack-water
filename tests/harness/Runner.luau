--!nonstrict
--[[
	Runner.luau — load the real server sources under the fake Roblox engine.

	THE MECHANISM (this is the part worth understanding)

	The luau CLI runs each script in its own sandbox and its builtin require
	gives every module a fresh environment, so a module loaded the normal way
	can never see stubbed globals like `game`. This runner therefore bypasses
	the builtin require for everything under src/:

	  1. tests/run-boot.sh feeds every source file into the process as program
	     arguments (path, contents) pairs — the CLI has no file I/O, but it
	     passes arguments through byte-exact.
	  2. Each module is compiled with loadstring and given an environment with
	     setfenv: the Roblox stubs from harness/Roblox.luau as globals, a fake
	     `script` instance from a fake DataModel tree, and everything else
	     falling through to the real standard library.
	  3. The custom `require` in that environment resolves fake instances from
	     the tree back to embedded paths, so `require(script.Parent.OceanService)`
	     and `require(Shared.Ocean.OceanSim)` work exactly as they do in Studio.

	Modules are cached by path, so a module's identity is stable across requires
	(OceanService's singleton depends on this).

	The fake tree mirrors default.project.json: ServerScriptService.Server <-
	src/Server and ReplicatedStorage.Shared <- src/Shared.
]]

local Runner = {}
Runner.__index = Runner

local SERVER_PREFIX = "src/Server/"
local SHARED_PREFIX = "src/Shared/"

function Runner.new(sources, roblox): any
	local self = setmetatable({}, Runner)
	self.sources = sources
	self.roblox = roblox
	self.cache = {}
	self.captured = {}
	self.modules = {}

	local serverFolder = roblox.Instance.new("Folder")
	serverFolder.Name = "Server"
	serverFolder.Parent = roblox.services.ServerScriptService

	local sharedFolder = roblox.Instance.new("Folder")
	sharedFolder.Name = "Shared"
	sharedFolder.Parent = roblox.services.ReplicatedStorage

	local paths = {}
	for path in sources do
		table.insert(paths, path)
	end
	table.sort(paths)

	for _, path in paths do
		self:attachModule(serverFolder, sharedFolder, path)
	end

	return self
end

--- Create the fake ModuleScript instance for one source file (and any folders
--- leading to it). "Main.server.luau" becomes a node named "Main", matching
--- rojo's naming.
function Runner:attachModule(serverFolder, sharedFolder, path: string): ()
	local root, rest
	if string.sub(path, 1, #SERVER_PREFIX) == SERVER_PREFIX then
		root = serverFolder
		rest = string.sub(path, #SERVER_PREFIX + 1)
	elseif string.sub(path, 1, #SHARED_PREFIX) == SHARED_PREFIX then
		root = sharedFolder
		rest = string.sub(path, #SHARED_PREFIX + 1)
	else
		error("harness: source path is under neither src/Server nor src/Shared: " .. path, 0)
	end

	if string.sub(path, -5) ~= ".luau" then
		error("harness: expected a .luau source path: " .. path, 0)
	end
	rest = string.sub(rest, 1, -6)

	local segments = string.split(rest, "/")
	local fileName = segments[#segments]

	local folder = root
	for i = 1, #segments - 1 do
		local name = segments[i]
		local existing = folder:FindFirstChild(name)
		if existing == nil then
			existing = self.roblox.Instance.new("Folder")
			existing.Name = name
			existing.Parent = folder
		end
		folder = existing
	end

	local node = self.roblox.Instance.new("ModuleScript")
	node.Name = string.gsub(fileName, "%.server$", "")
	node.__path = path
	node.Parent = folder
	self.modules[path] = node
end

--- The environment a loaded module executes in. Built per module because
--- `script` differs per module; everything else is shared.
function Runner:makeEnv(path: string): any
	local runner = self
	local roblox = self.roblox
	local captured = self.captured

	local function tee(kind: string, real: any): any
		return function(...: any)
			local parts = {}
			for i = 1, select("#", ...) do
				parts[i] = tostring((select(i, ...)))
			end
			local line = table.concat(parts, "\t")
			table.insert(captured, { kind = kind, text = line })
			real(line)
		end
	end

	return setmetatable({
		script = self.modules[path],
		require = function(ref: any)
			if type(ref) == "table" and ref.__path ~= nil then
				return runner:load(ref.__path)
			elseif type(ref) == "string" then
				-- Studio-style relative require ("./Sibling", "../Parent/X").
				-- This is real current Roblox behaviour, not a test-only
				-- convenience: require-by-string shipped in January 2025 and
				-- src/Shared uses it throughout. It resolves against the
				-- requiring module's own location, as Studio resolves it.
				return runner:load(runner:resolveRelative(path, ref))
			end
			error(
				"harness require: expected a fake module instance or a relative path string, got "
					.. tostring(ref),
				0
			)
		end,
		game = roblox.game,
		workspace = roblox.workspace,
		Instance = roblox.Instance,
		Vector3 = roblox.Vector3,
		CFrame = roblox.CFrame,
		Color3 = roblox.Color3,
		UDim2 = roblox.UDim2,
		Enum = roblox.Enum,
		task = roblox.task,
		-- Roblox's typeof, so `typeof(x) == "Instance"` behaves as in Studio
		-- (the bare CLI typeof would say "table").
		typeof = roblox.typeof,
		print = tee("print", print),
		warn = tee("warn", warn),
	}, { __index = getfenv(1) })
end

--- Resolve a Studio-style relative require against the requiring module's
--- own path, so "../Config" from src/Shared/Ocean/Chart.luau finds
--- src/Shared/Config.luau.
function Runner:resolveRelative(fromPath: string, ref: string): string
	local dir = string.gsub(fromPath, "/[^/]*$", "")
	local stack = string.split(dir, "/")
	for _, seg in string.split(ref, "/") do
		if seg == ".." then
			if #stack == 0 then
				error(
					"harness require: '"
						.. ref
						.. "' from "
						.. fromPath
						.. " escapes the source tree",
					0
				)
			end
			table.remove(stack)
		elseif seg ~= "." and seg ~= "" then
			table.insert(stack, seg)
		end
	end
	local resolved = table.concat(stack, "/")
	if self.sources[resolved .. ".luau"] ~= nil then
		return resolved .. ".luau"
	end
	if self.sources[resolved] ~= nil then
		return resolved
	end
	error("harness require: cannot resolve '" .. ref .. "' relative to " .. fromPath, 0)
end

--- Compile and run one module under its fake environment. Errors propagate to
--- the caller — a module that throws on require is a failed boot, not a skip.
function Runner:load(path: string): any
	local cached = self.cache[path]
	if cached ~= nil then
		return cached
	end

	local source = self.sources[path]
	if source == nil then
		error("harness: no embedded source for " .. path .. " — was it passed to run-boot.sh?", 0)
	end

	local chunk, parseErr = loadstring(source, "=" .. path)
	if chunk == nil then
		error("harness: " .. path .. " does not parse: " .. tostring(parseErr), 0)
	end

	setfenv(chunk, self:makeEnv(path))
	local module = chunk()
	if module == nil then
		error("harness: " .. path .. " returned nil", 0)
	end

	self.cache[path] = module
	return module
end

--- Every captured print/warn line whose text contains the needle.
function Runner:linesContaining(needle: string): { string }
	local found = {}
	for _, entry in self.captured do
		if string.find(entry.text, needle, 1, true) then
			table.insert(found, entry.text)
		end
	end
	return found
end

function Runner:flushTasks(): ()
	self.roblox.flushTasks()
end

return Runner
