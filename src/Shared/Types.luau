--!strict
--[[
	Types — the wire contract.

	Client and server are developed separately (and may be written by different
	agents in parallel), so every remote name and payload shape is pinned here.
	Renaming a field here is a breaking change; treat this file as the API
	contract, not as a convenience.

	Every payload is plain data. No Instances, no functions, no Roblox types —
	anything crossing a RemoteEvent has to survive a JSON round trip, because
	the same shapes are mirrored by the Cloudflare Worker.
]]

local Types = {}

--=============================================================================
-- Remotes
--
-- Created by the server at runtime and placed under ReplicatedStorage.Remotes.
-- Clients must wait for them rather than assuming they exist on join.
--=============================================================================

Types.CastRequest = "CastRequest" -- client -> server: start fishing at a region
Types.CastResult = "CastResult" -- server -> client: outcome of a cast
Types.OceanSync = "OceanSync" -- server -> client: periodic world state broadcast
Types.MarketSync = "MarketSync" -- server -> client: price list
Types.RegionDiscovered = "RegionDiscovered" -- server -> client: a newly composed bank
Types.Notify = "Notify" -- server -> client: a one-line toast
Types.SellRequest = "SellRequest" -- client -> server: sell one held catch
Types.SellResult = "SellResult" -- server -> client: outcome of a sale
Types.WalletSync = "WalletSync" -- server -> client: authoritative balance + hold

Types.REMOTE_FOLDER = "Remotes"

--=============================================================================
-- Payloads
--=============================================================================

--- client -> server
export type CastRequestPayload = {
	regionId: string,
	speciesId: string,
	effort: number, -- gear/skill term; server clamps and re-derives everything else
	depth: number, -- where the player dropped the line, within the species' band
	-- how well the fight minigame went, 0..1. Sent by Casting; the server
	-- clamps it and defaults to a mid roll when absent, so a payload that
	-- matches only the fields above still resolves instead of throwing.
	performance: number,
}

--- server -> client
export type CastResultPayload = {
	ok: boolean,
	reason: string?, -- set when ok == false
	speciesId: string,
	regionId: string,

	yielded: number,
	remaining: number,
	abundanceBefore: number,
	abundanceAfter: number,

	depleted: boolean,
	contested: boolean,

	-- rolled weight in kg, derived from species range and yield quality
	weightKg: number,
	-- what it is worth at the current market price
	value: number,
	-- the game rolled a rare catch — UI should celebrate this
	rare: boolean,
	-- a salmon run is active on this species at this region right now
	inRun: boolean,
	-- 0..1, how good the tide was for this catch (1 at dead slack). Lets the
	-- UI connect cause and effect: "you fought it at slack water" is a much
	-- better moment than a bare number.
	tideQuality: number,

	-- Set only when ok == true. The catch is in the server-side hold from the
	-- moment it lands; this id is the ONLY thing a sell request may send
	-- about it.
	catchId: string?,
	-- the catch's worth in integer cents at the moment of the cast — a quote,
	-- not a payment. The price actually paid is computed at sale time and
	-- arrives in SellResultPayload.paidCents.
	valueCents: number?,
}

--- server -> client, on every OceanSync
export type TideState = {
	hour: number,
	height: number,
	current: number,
	isSlack: boolean,
	phase: string,
	nextHigh: number,
	nextHighTime: number,
	nextLow: number,
	nextLowTime: number,
	hoursToSlack: number,
}

--- server -> client, periodic
export type OceanSyncPayload = {
	month: number,
	day: number,
	tick: number,

	-- the clock. Every screen that shows "where can I go right now" reads this.
	tide: TideState,

	-- fraction of the chart backed by real soundings (0..1). Surfacing this is
	-- deliberate: a player who can see the chart is 60% surveyed has a real
	-- reason to want to go survey the rest.
	chartCoverage: number,

	regions: {
		{
			id: string,
			name: string,
			habitat: string,
			depth: number,
			-- depth as charted at MLLW, which is what the tide is measured against
			chartedDepth: number,
			abundances: { [string]: number }, -- speciesId -> 0..1+
			contested: { [string]: boolean },
			species: { string }, -- what is actually present to fish here
			-- false when there is not enough water over the ground right now
			accessible: boolean,
			waterDepth: number,
			quality: number, -- 0..1, how good the tide makes this ground
			-- "measured" | "grown" | "composed" — how much this ground is trusted
			provenance: string,
		}
	},
}

export type MarketSyncPayload = {
	entries: {
		{
			speciesId: string,
			displayName: string,
			price: number,
			baseValue: number,
			scarcityMultiplier: number,
			globalAbundance: number,
			direction: "rising" | "falling" | "flat",
		}
	},
}

export type RegionDiscoveredPayload = {
	id: string,
	name: string,
	habitat: string,
	depth: number,
	richness: number,
	hazard: string?,
	species: { string },
	origin: string,
	latitude: number?,
	longitude: number?,
	expiresAt: number?,
}

export type NotifyPayload = {
	kind: "run" | "scarcity" | "contest" | "market" | "discover",
	text: string,
	speciesId: string?,
	regionId: string?,
}

--=============================================================================
-- Wallet
--
-- The sell channel carries intent and nothing else. A sale request is ONE
-- server-minted catchId — no species, no quantity, and above all no price.
-- Everything a modified client might want to claim about a fish is absent
-- from the wire, so it cannot be claimed. The server prices the sale from
-- the live market at the moment it processes the request; a stale price is
-- therefore not a case to handle, it is a case that cannot exist.
--=============================================================================

--- client -> server
export type SellRequestPayload = {
	catchId: string,
}

--- server -> client
export type SellResultPayload = {
	ok: boolean,
	reason: string?, -- set when ok == false
	catchId: string,
	speciesId: string?, -- the fish the server says this id was
	paidCents: number, -- what the sale actually paid — always server-derived
	balanceCents: number, -- the authoritative balance after this sale
}

--- server -> client, on change and on join
export type WalletSyncPayload = {
	balanceCents: number,
	hold: { WalletHoldEntry },
}

--- One fish in the hold, as the client may see it: identity and weight.
--- No yielded, no price — the wire never carries enough to value a fish
--- client-side (house rule 2).
export type WalletHoldEntry = {
	catchId: string,
	speciesId: string,
	weightKg: number,
}

--=============================================================================
-- Gear
--
-- `effort` is the only player-controlled input to the simulation. Everything
-- else — cap, yield factor, abundance — is derived server-side so a modified
-- client cannot lie its way into a bigger catch.
--=============================================================================

export type Gear = {
	id: string,
	displayName: string,
	effort: number,
	price: number,
	unlockLevel: number,
}

Types.Gear = {
	handline = { id = "handline", displayName = "Handline", effort = 6, price = 0, unlockLevel = 1 },
	rod = { id = "rod", displayName = "Fishing Rod", effort = 14, price = 250, unlockLevel = 2 },
	gi = { id = "gi", displayName = "Barbed Hook", effort = 22, price = 1200, unlockLevel = 5 },
	longline = {
		id = "longline",
		displayName = "Longline Rig",
		effort = 38,
		price = 6500,
		unlockLevel = 9,
	},
	crab_pot = {
		id = "crab_pot",
		displayName = "Crab Pot",
		effort = 30,
		price = 4200,
		unlockLevel = 7,
	},
	trawler = {
		id = "trawler",
		displayName = "Trawler Gear",
		effort = 60,
		price = 28000,
		unlockLevel = 14,
	},
} :: { [string]: Gear }

return Types
