--!strict
--[[
	Casting — the minigame. This is where the game is won or lost.

	Everything else in this project is a simulation that is already working.
	Whether Slack Water is *good* depends entirely on whether a cast feels like
	fighting a fish.

	THE SHAPE

	One button. That is the whole control scheme, and it is deliberate: Roblox
	is roughly 80% mobile, and a two-axis tension/depth game is unplayable with a
	thumb. Hold to reel — the fish comes up but the line loads. Release to give
	— tension bleeds off but you lose ground.

	The fish has stamina. Manage it and you land it. Spike the tension and the
	part snaps. There is no other verb.

	DIFFICULTY IS THE SPECIES

	`harvestDifficulty` (1..5, see Species.luau) is not a stat that scales a
	damage number. It changes the *character* of the fight:

		difficulty 1  herring     a token pull, over almost immediately
		difficulty 2  pollock     short, manageable
		difficulty 3  rockfish    a real fight with a failure state
		difficulty 4  sablefish   long, heavy, the safe band narrows
		difficulty 5  yelloweye   a genuine contest; you will lose some

	A yelloweye must not feel like a herring with a bigger number on it. Longer,
	stronger, twitchier, with a thinner margin for error.

	DEPTH IS THE SKILL BEFORE THE FIGHT

	Choosing a depth inside the species' band is not flavour. The closer you
	get to the middle of its range, the better the fish you hook. That is the
	whole of seamanship as a mechanic, and it is knowable: the range is on the
	species card.

	SERVER AUTHORITY

	This module never computes what was caught, what it weighs or what it is
	worth. It computes *performance* — how well the player fought — and sends
	that with intent. The server decides the outcome, because the ocean is
	shared and a modified client must not be able to fill its own net.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local Species = require(Shared.Species)

--=============================================================================
-- Tuning
--
-- Everything difficulty-shaped is expressed relative to difficulty 1..5 rather
-- than as separate hand-tuned tables, so adding a species or re-tuning the
-- curve does not mean editing a dozen numbers.
--=============================================================================

local FIGHT = {
	-- tension rises this fast per second while reeling, scaled by pull strength
	reelGain = 26,
	-- tension bleeds off this fast per second when giving line
	releaseRelief = 17,

	-- snapping the line
	maxTension = 100,

	-- progress toward landing the fish, per second of correct play
	reelProgress = 30,
	-- progress lost per second while giving line
	releaseDrift = 9,

	-- stamina: how hard the fish fights, and how long it lasts
	baseStamina = 1.0,
	staminaPerDifficulty = 0.42,
	-- how fast stamina drains while reeling (the fight) vs giving line (rest)
	drainWhileReeling = 0.42,
	drainWhileGiving = 0.12,

	-- pulling strength scales with difficulty; this is the per-level multiplier
	pullPerDifficulty = 0.34,

	-- how close to the ideal depth the player must be for full quality
	depthTolerance = 0.30,
}

export type CastState = "idle" | "aiming" | "fighting" | "waiting" | "landed" | "lost"

export type Casting = {
	state: CastState,
	species: any,
	regionId: string,
	depth: number,
	minDepth: number,
	maxDepth: number,
	tension: number,
	progress: number,
	stamina: number,
	performance: number,
	holding: boolean,
	_listeners: { [(string | number)]: any },
	_connection: any,
	_castToken: number,
	pendingResolve: any,
}

local Casting = {}

local instance: Casting? = nil

--=============================================================================
-- Construction
--=============================================================================

local function newListenerStore(): { [any]: { any } }
	local store = {}
	return setmetatable(store, {
		__index = function(self, key)
			local list = rawget(self, key)
			if not list then
				list = {}
				rawset(self, key, list)
			end
			return list
		end,
	})
end

function Casting.get(): Casting?
	return instance
end

function Casting.start(): Casting
	if instance then
		return instance
	end

	local casting: Casting = {
		state = "idle",
		species = nil,
		regionId = "",
		depth = 0,
		minDepth = 0,
		maxDepth = 0,
		tension = 0,
		progress = 0,
		stamina = 1,
		performance = 0,
		holding = false,
		_listeners = newListenerStore(),
		_connection = nil,
		_castToken = 0,
		pendingResolve = nil,
	}

	instance = casting
	Casting._bindInput(casting)
	return casting
end

--=============================================================================
-- Input
--
-- Both paths are supported because Roblox fires genuinely different events for
-- a mouse and a phone, and a fishing game that cannot be played on a phone is
-- a fishing game for nobody.
--=============================================================================

local function setHolding(casting: Casting, held: boolean): ()
	if casting.holding == held then
		return
	end
	casting.holding = held
	Casting._emit(casting, "holding", held)
end

function Casting._bindInput(casting: Casting): ()
	-- Touch: hold anywhere that is not a UI element to reel.
	casting._touchConn = UserInputService.InputBegan:Connect(
		function(input: any, processed: boolean)
			if processed then
				return
			end
			if input.UserInputType == Enum.UserInputType.Touch then
				setHolding(casting, true)
			end
		end
	)

	casting._touchEnd = UserInputService.InputEnded:Connect(
		function(input: any, _processed: boolean)
			if input.UserInputType == Enum.UserInputType.Touch then
				setHolding(casting, false)
			end
		end
	)

	-- Mouse/trackpad: hold the left button, but only over the play area.
	casting._mouseConn = UserInputService.InputBegan:Connect(
		function(input: any, processed: boolean)
			if processed then
				return
			end
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				setHolding(casting, true)
			end
		end
	)

	casting._mouseUp = UserInputService.InputEnded:Connect(function(input: any, _processed: boolean)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			setHolding(casting, false)
		end
	end)

	-- Space bar for keyboard players.
	casting._keyConn = UserInputService.InputBegan:Connect(function(input: any, processed: boolean)
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.Space then
			setHolding(casting, true)
		end
	end)

	casting._keyUp = UserInputService.InputEnded:Connect(function(input: any, _processed: boolean)
		if input.KeyCode == Enum.KeyCode.Space then
			setHolding(casting, false)
		end
	end)
end

--=============================================================================
-- Events
--=============================================================================

function Casting._on(casting: Casting, event: string, fn: any): ()
	table.insert(casting._listeners[event], fn)
end

function Casting._emit(casting: Casting, event: string, payload: any?): ()
	for _, fn in casting._listeners[event] do
		fn(payload)
	end
end

function Casting.on(casting: Casting, event: string, fn: any): ()
	Casting._on(casting, event, fn)
end

--=============================================================================
-- Depth selection
--=============================================================================

--- How good this depth is for the species: 1 at dead centre of its band, 0 at
--- either edge. This is the only place depth matters, and it is deliberately
--- knowable rather than hidden.
function Casting.depthQuality(casting: Casting): number
	local span = casting.maxDepth - casting.minDepth
	if span <= 0 then
		return 1
	end

	local t = (casting.depth - casting.minDepth) / span
	local fromCentre = math.abs(t - 0.5) * 2 -- 0 at centre, 1 at either edge
	return math.clamp(1 - fromCentre / FIGHT.depthTolerance, 0, 1)
end

function Casting.setDepth(casting: Casting, depth: number): ()
	if casting.state ~= "aiming" then
		return
	end
	casting.depth = math.clamp(depth, casting.minDepth, casting.maxDepth)
	Casting._emit(casting, "depth", casting.depth)
end

--=============================================================================
-- The fight
--=============================================================================

--- Begin a fight against a species at a region.
---
--- Returns immediately; drive it with `update` and listen for the outcome.
function Casting.beginFight(
	casting: Casting,
	regionId: string,
	speciesId: string,
	depth: number?
): boolean
	local species = Species.get(speciesId)
	if not species then
		return false
	end

	casting.species = species
	casting.regionId = regionId
	casting.minDepth = species.minDepth
	casting.maxDepth = species.maxDepth
	-- Default to the middle of the band: the *default* position should be the
	-- informed one, and the player should have to work to do worse.
	casting.depth = if depth
		then math.clamp(depth, species.minDepth, species.maxDepth)
		else (species.minDepth + species.maxDepth) / 2

	casting.tension = 0
	casting.progress = 0
	casting.holding = false
	casting.state = "fighting"
	casting.performance = Casting.depthQuality(casting)

	local d = species.harvestDifficulty
	casting.stamina = FIGHT.baseStamina + FIGHT.staminaPerDifficulty * (d - 1)
	casting._pull = FIGHT.pullPerDifficulty * (d - 1)
	casting._drain = FIGHT.drainWhileReeling + 0.06 * (d - 1)

	Casting._emit(casting, "begin", {
		species = species,
		minDepth = casting.minDepth,
		maxDepth = casting.maxDepth,
		depth = casting.depth,
		stamina = casting.stamina,
	})

	return true
end

--- Advance the fight. Called from a RenderStepped/Heartbeat connection owned by
--- whoever starts the minigame, so the pacing stays in one place.
function Casting.update(casting: Casting, dt: number): ()
	if casting.state ~= "fighting" or not casting.species then
		return
	end

	local reeling = casting.holding

	if reeling then
		casting.tension += (FIGHT.reelGain + casting._pull * 18) * dt
		casting.progress += FIGHT.reelProgress * dt
		casting.stamina -= casting._drain * dt
	else
		casting.tension -= FIGHT.releaseRelief * dt
		casting.progress -= FIGHT.releaseDrift * dt
		-- the fish rests too, which is why giving line is a real strategy and
		-- not just a way to stall
		casting.stamina -= FIGHT.drainWhileGiving * dt
	end

	casting.tension = math.clamp(casting.tension, 0, FIGHT.maxTension)
	casting.progress = math.clamp(casting.progress, 0, 100)
	casting.stamina = math.clamp(casting.stamina, 0, 2)

	if casting.tension >= FIGHT.maxTension then
		Casting.lose(casting, "The line parted.")
		return
	end

	if casting.stamina <= 0 or casting.progress >= 100 then
		Casting.land(casting)
		return
	end

	Casting._emit(casting, "update", Casting.snapshot(casting))
end

--- The public read model, for the UI. One shape, used by every widget.
function Casting.snapshot(casting: Casting): any
	local tension01 = casting.tension / FIGHT.maxTension
	local inBand = tension01 > 0.55 and tension01 < 0.92

	return {
		state = casting.state,
		speciesId = if casting.species then casting.species.id else "",
		regionId = casting.regionId,
		depth = casting.depth,
		minDepth = casting.minDepth,
		maxDepth = casting.maxDepth,
		tension = casting.tension,
		tension01 = tension01,
		progress = casting.progress,
		stamina = casting.stamina,
		performance = casting.performance,
		-- the safe band is the whole game: inside it you are neither snapping
		-- the line nor wasting the fish
		inBand = inBand,
		holding = casting.holding,
	}
end

--- Score the fight as the player fights it, so a sloppy win is worth less than
--- a controlled one even though both land a fish.
local function foldPerformance(casting: Casting): number
	local depth = Casting.depthQuality(casting)
	-- tension discipline: how close to the middle of the band the player kept
	-- it. Spiking the line and coasting both count against you.
	local spent = math.clamp(casting.tension / FIGHT.maxTension, 0, 1)
	local discipline = 1 - math.abs(spent - 0.72) / 0.72

	casting.performance = math.clamp(depth * 0.45 + math.clamp(discipline, 0, 1) * 0.55, 0, 1)
	return casting.performance
end

function Casting.land(casting: Casting): ()
	if casting.state ~= "fighting" then
		return
	end

	local performance = foldPerformance(casting)
	Casting._emit(casting, "landed", {
		speciesId = casting.species.id,
		regionId = casting.regionId,
		depth = casting.depth,
		performance = performance,
	})

	Casting._resolveOnServer(casting, performance)
end

function Casting.lose(casting: Casting, reason: string): ()
	if casting.state ~= "fighting" then
		return
	end

	casting.state = "lost"
	setHolding(casting, false)
	Casting._emit(casting, "lost", { reason = reason })
end

function Casting.cancel(casting: Casting): ()
	if casting.state == "fighting" then
		Casting.lose(casting, "You reeled in.")
		return
	end
	casting.state = "idle"
	Casting._emit(casting, "cancel", nil)
end

--=============================================================================
-- Server round trip
--=============================================================================

-- Seconds to wait for the server's CastResult before declaring the landing
-- unresolved. The round trip is normally well under a second; anything past
-- this is a dropped request (the server's rate limiter replies to nothing),
-- and a fight that never ends would block the player from ever casting again.
local RESOLVE_TIMEOUT = 12

--- Send the catch and resolve with whatever the server says.
---
--- Deliberately fire-and-await rather than optimistic: the client has no idea
--- what the shared ocean was worth a moment ago, and guessing would be a lie.
function Casting._resolveOnServer(casting: Casting, performance: number): ()
	if casting.state ~= "fighting" and casting.state ~= "lost" then
		return
	end

	casting.state = "waiting"
	casting._castToken += 1
	local token = casting._castToken

	local remotes = ReplicatedStorage:WaitForChild(Types.REMOTE_FOLDER)
	local request = remotes:WaitForChild(Types.CastRequest)
	local result = remotes:WaitForChild(Types.CastResult)

	local function onResult(payload: any)
		if token ~= casting._castToken then
			return -- a stale reply from an abandoned cast
		end

		if typeof(payload) ~= "table" then
			casting.state = "idle"
			return
		end

		casting.state = if payload.ok then "landed" else "lost"
		Casting._emit(casting, "result", payload)
	end

	local conn
	conn = result.OnClientEvent:Connect(function(payload: any)
		conn:Disconnect()
		onResult(payload)
	end)

	request:FireServer({
		regionId = casting.regionId,
		speciesId = casting.species.id,
		effort = 0, -- the server derives this from gear; the client does not get to say
		depth = casting.depth,
		performance = performance,
	})

	-- Never wait forever. A cast the server silently dropped (rate limit,
	-- dead handler) still has to end, or the player is locked out of the
	-- game's only verb.
	task.delay(RESOLVE_TIMEOUT, function()
		if casting.state == "waiting" and token == casting._castToken then
			casting.state = "lost"
			setHolding(casting, false)
			Casting._emit(casting, "lost", {
				reason = "The landing never resolved — no answer from the shore.",
			})
		end
	end)
end

--=============================================================================
-- Auto-drive
--=============================================================================

--- Run the fight loop for as long as it lasts. Convenience for scripts that
--- just want to fire and forget.
function Casting.beginAuto(casting: Casting, regionId: string, speciesId: string, depth: number?)
	if not Casting.beginFight(casting, regionId, speciesId, depth) then
		return
	end

	if casting._connection then
		casting._connection:Disconnect()
	end

	casting._connection = RunService.Heartbeat:Connect(function(dt)
		Casting.update(casting, dt)
		if casting.state ~= "fighting" and casting.state ~= "waiting" then
			casting._connection:Disconnect()
			casting._connection = nil
		end
	end)
end

Casting._FIGHT = FIGHT

--=============================================================================
-- Boot — the way in
--
-- Rojo maps this file as a LocalScript, and LocalScripts cannot be required
-- by their siblings, so `Casting.start()` used to be a function no other
-- script could reach: the whole fishing loop was built and unplayable
-- (docs/PLAYLOOP.md, defect 1).
--
-- In Studio this file RUNS, so it boots itself and publishes the rendezvous
-- the other client scripts drive it through: a BindableEvent in PlayerGui.
-- That single named instance is the whole contract between LocalScripts —
-- exact message shapes are pinned in docs/CASTING.md.
--=============================================================================

local BUS_NAME = "SlackWaterCastBus"

if game ~= nil then
	local player = game:GetService("Players").LocalPlayer
	if player then
		local playerGui = player:WaitForChild("PlayerGui")
		local bus = playerGui:FindFirstChild(BUS_NAME) :: BindableEvent?
		if not bus then
			local event = Instance.new("BindableEvent")
			event.Name = BUS_NAME
			event.Parent = playerGui
			bus = event
		end

		local casting = Casting.start()

		local function reply(eventName: string, data: any)
			bus:Fire({ kind = "fight", event = eventName, data = data })
		end

		for _, eventName in { "begin", "update", "landed", "lost", "result", "cancel" } do
			Casting.on(casting, eventName, function(data: any)
				reply(eventName, data)
			end)
		end

		bus.Event:Connect(function(msg: any)
			if typeof(msg) ~= "table" then
				return
			end

			if msg.kind == "cast" then
				-- One line in the water at a time: a cast already running must
				-- not be joined by a second. This is the server-facing half of
				-- the double-cast guard; the CastBar owns the button half.
				if casting.state == "fighting" or casting.state == "waiting" then
					return
				end

				local regionId = msg.regionId
				local speciesId = msg.speciesId
				local depth = msg.depth
				if type(depth) ~= "number" then
					depth = nil -- nil = mid-band, the informed default
				end
				if type(regionId) ~= "string" or type(speciesId) ~= "string" then
					reply("error", { reason = "That cast never went out." })
					return
				end

				if not Casting.beginFight(casting, regionId, speciesId, depth) then
					reply("error", { reason = "That fish is not in these waters." })
					return
				end

				if casting._connection then
					casting._connection:Disconnect()
					casting._connection = nil
				end
				casting._connection = RunService.Heartbeat:Connect(function(dt: number)
					Casting.update(casting, dt)
					if casting.state ~= "fighting" and casting.state ~= "waiting" then
						casting._connection:Disconnect()
						casting._connection = nil
					end
				end)
			elseif msg.kind == "abort" then
				Casting.cancel(casting)
			end
			-- "selection" messages are CastBar -> HUD traffic, not for us.
		end)
	end
end

return Casting
