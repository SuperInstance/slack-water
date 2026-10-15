--!strict
--[[
	Remotes — the runtime remote registry.

	Types.luau is the wire contract, but the remotes OceanService itself
	creates are only the six it bootstraps. Two sets live here instead:

	1. Remotes progression needs TODAY, still pending their Types.luau fold
	   (that fold belongs to the progression change, not this one):

	     Types.GearRequest = "GearRequest"  -- client -> server: work different gear
	     Types.ProfileSync  = "ProfileSync"  -- server -> client: that player's profile

	   The payload shapes they carry are documented in ProfileService.luau
	   and GearBar.client.luau respectively.

	2. The wallet remotes. These ARE in the contract (Types.luau declares
	   SellRequest / SellResult / WalletSync); they are created here because
	   the other creation site, OceanService.buildRemotes, is not this
	   change's to edit. Once it folds them in, this half of the list can go.

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

-- Contract-declared wallet remotes; see the module header.
Remotes.SellRequest = Types.SellRequest
Remotes.SellResult = Types.SellResult
Remotes.WalletSync = Types.WalletSync

--- Find-or-create the shared remotes folder and the remotes registered here
--- in it. Returns a name -> RemoteEvent map in the same shape as
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
		Remotes.SellRequest,
		Remotes.SellResult,
		Remotes.WalletSync,
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
