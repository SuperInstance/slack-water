--!strict
--[[
	Remotes — the runtime remote registry.

	Types.luau is the wire contract, but it is owned by a separate change, so
	remotes that progression needs TODAY are created here instead. Everything
	in this file is a pending Types.luau addition, deliberately kept in one
	place so folding it into the contract later is a copy, not a hunt:

	  Types.GearRequest = "GearRequest"  -- client -> server: work different gear
	  Types.ProfileSync  = "ProfileSync"  -- server -> client: that player's profile

	The payload shapes they carry are documented in ProfileService.server.luau
	and GearBar.client.luau respectively.

	build() is idempotent and mirrors OceanService's own remote bootstrap
	(same folder, same find-or-create), so the two can run in either order
	and never fight over ReplicatedStorage.Remotes.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)

local Remotes = {}

-- Pending Types.luau additions; see the module header.
Remotes.GearRequest = "GearRequest"
Remotes.ProfileSync = "ProfileSync"

--- Find-or-create the shared remotes folder and the progression remotes in
--- it. Returns a name -> RemoteEvent map in the same shape as
--- OceanService's `svc.remotes`, so callers can index it identically.
function Remotes.build(): { [string]: any }
	local folder = ReplicatedStorage:FindFirstChild(Types.REMOTE_FOLDER)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = Types.REMOTE_FOLDER
		folder.Parent = ReplicatedStorage
	end

	local remotes: { [string]: any } = {}
	local names = {
		Remotes.GearRequest,
		Remotes.ProfileSync,
	}

	for _, name in names do
		local existing = folder:FindFirstChild(name)
		if not existing then
			existing = Instance.new("RemoteEvent")
			existing.Name = name
			existing.Parent = folder
		end
		remotes[name] = existing
	end

	return remotes
end

return Remotes
