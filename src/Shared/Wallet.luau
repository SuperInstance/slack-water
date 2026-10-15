--!strict
--[[
	Wallet — money rules, and nothing else.

	The wallet is integer cents end to end. The market above it is floats (that
	is the economy's existing contract with the Worker, and changing it would
	drift the two implementations), so there is exactly ONE conversion point —
	`Wallet.saleCents` — where a float valuation becomes integer cents. Floats
	accumulate rounding error into exploits; integers cannot. A balance is
	therefore always exactly representable and every add is exact.

	Every mutating function validates FIRST and mutates LAST, so a rejected
	operation leaves the record untouched — there is no partial sale, no
	clamped debit, no "best effort" money. Rejection is explicit: callers get
	(false, reason) and must decide what to tell the player.

	The other thing this module owns is the hold: a catch that has left the
	water but not yet been sold. The hold is an ARRAY, not a hash — iteration
	order is insertion order on every interpreter, which is what determinism
	(house rule 4) requires of anything that affects state.

	What this module deliberately does NOT know: the market, the ocean, prices
	at any moment, Roblox. `sell` takes the price as an integer the CALLER
	derived from the live market, so the pricing rule stays in one place (the
	server service) and the money rules stay here, testable headlessly.
]]

local Species = require("./Species")

export type HeldCatch = {
	catchId: string,
	speciesId: string,
	regionId: string,
	-- rolled body weight; display only, never priced
	weightKg: number,
	-- biomass units the catch carries; the term the sale price multiplies
	yielded: number,
}

--- What the server hands to `recordCatch` after a cast has been arbitrated.
--- Every field is server-derived; the client never contributes.
export type CatchInfo = {
	speciesId: string,
	regionId: string,
	weightKg: number,
	yielded: number,
}

export type WalletRecord = {
	balanceCents: number,
	hold: { HeldCatch },
	nextCatchSeq: number,
}

export type SaleOutcome = {
	catchId: string,
	speciesId: string,
	paidCents: number,
	balanceCents: number,
}

local Wallet = {}

--=============================================================================
-- Tuning
--
-- By house convention these belong in Config.luau; that file is owned by
-- another change, so they live here — exported, commented, and never to be
-- inlined at a call site. Same discipline, different shelf (see
-- Progression.luau for the precedent).
--=============================================================================

--- Cents per credit. The game's existing numbers — gear prices, market
--- prices, CastResult.value — are credits; the wallet keeps cents so money is
--- exact. 100 keeps every displayed price two decimal places honest.
Wallet.CENTS_PER_CREDIT = 100

--- The divisor the cast value formula has always applied
--- (`yielded * price / 10`). Owned here now so the quote a catch card shows
--- and the price a sale pays can never drift apart on units.
Wallet.VALUE_DIVISOR = 10.0

--- Hard ceiling on any balance. Doubles represent every integer up to 2^53
--- exactly; 9e15 sits below it, so `balance + paid` cannot silently round.
--- A credit economy that reaches 90 trillion credits has other problems.
Wallet.MAX_BALANCE_CENTS = 9e15

--=============================================================================
-- Validation
--=============================================================================

--- Is this an amount the wallet may hold: a number, integral, finite, within
--- [0, MAX_BALANCE_CENTS]. NaN fails `n ~= n`; infinities fail the `% 1`
--- check (inf % 1 is nan in Luau).
function Wallet.isCents(n: any): boolean
	if type(n) ~= "number" then
		return false
	end
	if n ~= n then
		return false
	end
	return n >= 0 and n <= Wallet.MAX_BALANCE_CENTS and n % 1 == 0
end

--=============================================================================
-- The one float -> int boundary
--=============================================================================

--- What a catch is worth in cents at a given market price.
---
--- Deterministic for the same inputs (floor of x + 0.5 on the actual IEEE
--- result — pinned by tests against the real interpreter, including the
--- half-cent cases, so "rounds up" is a fact and not an intention).
function Wallet.saleCents(price: number, yielded: number): number
	local credits = yielded * price / Wallet.VALUE_DIVISOR
	return math.floor(credits * Wallet.CENTS_PER_CREDIT + 0.5)
end

--=============================================================================
-- Balance arithmetic
--=============================================================================

--- Credit the balance. Rejects anything that is not positive integer cents
--- and any credit that would overflow the ceiling — with the balance left
--- exactly as it was.
function Wallet.credit(record: WalletRecord, cents: number): (boolean, string?)
	if not Wallet.isCents(cents) or cents <= 0 then
		return false, "not integer cents"
	end
	local next = record.balanceCents + cents
	if next > Wallet.MAX_BALANCE_CENTS then
		return false, "balance overflow"
	end
	record.balanceCents = next
	return true, nil
end

--- Debit the balance. Insufficient funds is a REJECTION, never a clamp: a
--- clamped debit silently destroys money and teaches players not to trust
--- the number on screen.
function Wallet.debit(record: WalletRecord, cents: number): (boolean, string?)
	if not Wallet.isCents(cents) or cents <= 0 then
		return false, "not integer cents"
	end
	if cents > record.balanceCents then
		return false, "insufficient funds"
	end
	record.balanceCents = record.balanceCents - cents
	return true, nil
end

--=============================================================================
-- The hold
--=============================================================================

--- Mint the next catch id. `"c" .. n` with a persisted counter, so ids stay
--- unique across server restarts for as long as the wallet record persists —
--- a reused id after a rollback would be a resurrection bug (a sold fish
--- back from the dead, sellable twice).
function Wallet.nextCatchId(record: WalletRecord): string
	local id = "c" .. tostring(record.nextCatchSeq)
	record.nextCatchSeq += 1
	return id
end

--- A fish that has left the water enters the hold the moment it is landed —
--- not when the player chooses. The choice (sell now / keep it for later) is
--- a decision about a fish the server already knows it owns.
---
--- Refuses (returns nil) a catch with no positive, finite biomass: harvest
--- can answer ok with yielded == 0 for a species with no capacity at the
--- region, and a zero-yield fish could never be sold — it would sit in the
--- hold forever. Nothing came out of the water, so nothing is held.
function Wallet.recordCatch(record: WalletRecord, info: CatchInfo): HeldCatch?
	local y = info.yielded
	if type(y) ~= "number" or y ~= y or y == math.huge or y <= 0 then
		return nil
	end
	local held: HeldCatch = {
		catchId = Wallet.nextCatchId(record),
		speciesId = info.speciesId,
		regionId = info.regionId,
		weightKg = info.weightKg,
		yielded = y,
	}
	table.insert(record.hold, held)
	return held
end

--- Find a held catch by id, or nil. Linear over the array; holds are short
--- (a boat only carries so much) and the scan is deterministic.
function Wallet.findCatch(record: WalletRecord, catchId: string): HeldCatch?
	for _, held in record.hold do
		if held.catchId == catchId then
			return held
		end
	end
	return nil
end

--- Sell one held catch for `paidCents`.
---
--- All validation happens before any mutation, so the record is never left
--- half-sold:
---   - unknown catchId  -> "no such catch" (already sold, a stale card after
---     a server restart, or someone else's fish — the caller cannot tell and
---     does not need to)
---   - a price that is not positive integer cents -> "bad price" (defensive;
---     the server service derives the price itself and this must never pass)
---   - a credit that would overflow the ceiling -> "balance overflow", with
---     the catch STILL HELD — better a fish you cannot sell than money that
---     silently rounded
---
--- Idempotency is consumption: a successful sale removes the catch, so the
--- same request again fails with "no such catch" and the balance is credited
--- exactly once.
function Wallet.sell(
	record: WalletRecord,
	catchId: string,
	paidCents: number
): (SaleOutcome?, string?)
	if type(catchId) ~= "string" or catchId == "" then
		return nil, "no such catch"
	end

	local index = 0
	for i, held in record.hold do
		if held.catchId == catchId then
			index = i
			break
		end
	end
	if index == 0 then
		return nil, "no such catch"
	end

	if not Wallet.isCents(paidCents) or paidCents <= 0 then
		return nil, "bad price"
	end

	local next = record.balanceCents + paidCents
	if next > Wallet.MAX_BALANCE_CENTS then
		return nil, "balance overflow"
	end

	local held = table.remove(record.hold, index) :: HeldCatch
	record.balanceCents = next

	return {
		catchId = catchId,
		speciesId = held.speciesId,
		paidCents = paidCents,
		balanceCents = next,
	},
		nil
end

--=============================================================================
-- Replication payload
--=============================================================================

--- The plain-data WalletSync payload. Deliberately narrow: the wire carries
--- what a UI needs to RENDER the hold (which fish, how heavy) and nothing it
--- could price with. `yielded` stays server-side on purpose — biomass on the
--- wire would invite client-side valuation, which is exactly the habit this
--- economy exists to break.
function Wallet.syncPayload(record: WalletRecord): { [string]: any }
	local hold: { { [string]: any } } = {}
	for _, held in record.hold do
		table.insert(hold, {
			catchId = held.catchId,
			speciesId = held.speciesId,
			weightKg = held.weightKg,
		})
	end
	return {
		balanceCents = record.balanceCents,
		hold = hold,
	}
end

--=============================================================================
-- Persistence
--=============================================================================

--- Plain-data snapshot for saving. The hold is deep-copied in array order so
--- the snapshot shares no tables with the live record and the same record
--- always produces the same bytes.
function Wallet.snapshot(record: WalletRecord): { [string]: any }
	local hold: { { [string]: any } } = {}
	for _, held in record.hold do
		table.insert(hold, {
			catchId = held.catchId,
			speciesId = held.speciesId,
			regionId = held.regionId,
			weightKg = held.weightKg,
			yielded = held.yielded,
		})
	end
	return {
		balanceCents = record.balanceCents,
		hold = hold,
		nextCatchSeq = record.nextCatchSeq,
	}
end

--- Rebuild a record from persisted data. Nothing is believed:
---   - junk of any shape degrades to a fresh wallet
---   - a fractional balance floors toward zero — repair never mints money
---   - a negative balance is zero; an over-ceiling balance clamps to the
---     ceiling (unreachable by play, so clamping loses nothing real)
---   - hold entries need a catchId and a species on the roster; anything
---     else is dropped, because an unpriceable fish is unpayable anyway
---   - duplicated catchIds keep only the first occurrence — a duplicated id
---     would be a double-sell vector
---   - nextCatchSeq is raised past any id still in the hold, so a tampered
---     or rolled-back sequence can never re-mint an id a live catch wears
---
--- The hold is restored in persisted (array) order. A hand-tampered
--- non-array save has no guaranteed order, and nothing downstream depends on
--- hold order: pricing is per-catch and sales are by id.
function Wallet.restore(data: any): WalletRecord
	if type(data) ~= "table" then
		return Wallet.new()
	end

	local balance = tonumber(data.balanceCents)
	if balance == nil or balance ~= balance or balance < 0 then
		balance = 0
	end
	if balance % 1 ~= 0 then
		balance = math.floor(balance)
	end
	if balance > Wallet.MAX_BALANCE_CENTS then
		balance = Wallet.MAX_BALANCE_CENTS
	end

	local seq = tonumber(data.nextCatchSeq)
	if seq == nil or seq ~= seq or seq < 1 or seq % 1 ~= 0 then
		seq = 1
	end

	local hold: { HeldCatch } = {}
	local seen: { [string]: boolean } = {}
	local list = data.hold
	if type(list) == "table" then
		for _, entry in list do
			if
				type(entry) == "table"
				and type(entry.catchId) == "string"
				and entry.catchId ~= ""
				and type(entry.speciesId) == "string"
				and Species.get(entry.speciesId) ~= nil
				and not seen[entry.catchId]
			then
				seen[entry.catchId] = true

				local weightKg = tonumber(entry.weightKg)
				local yielded = tonumber(entry.yielded)

				table.insert(hold, {
					catchId = entry.catchId,
					speciesId = entry.speciesId,
					regionId = if type(entry.regionId) == "string" then entry.regionId else "",
					weightKg = if weightKg ~= nil
							and weightKg == weightKg
							and weightKg > 0
						then weightKg
						else 0.0,
					yielded = if yielded ~= nil
							and yielded == yielded
							and yielded > 0
						then yielded
						else 0.0,
				})

				local n = tonumber(string.match(entry.catchId, "^c(%d+)$"))
				if n ~= nil and n >= seq then
					seq = n + 1
				end
			end
		end
	end

	return {
		balanceCents = balance,
		hold = hold,
		nextCatchSeq = seq,
	}
end

--- A brand-new skipper: no money, an empty hold, ids starting at c1.
function Wallet.new(): WalletRecord
	return {
		balanceCents = 0,
		hold = {},
		nextCatchSeq = 1,
	}
end

return Wallet
