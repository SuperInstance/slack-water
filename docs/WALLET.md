# WALLET — money, and the loop that moves it

Written 2026-10-15 by the economy pass. **Verification level: headless tests
only.** Everything below that has a test is pinned by `tests/wallet-tests.luau`
(41 tests: the pure money rules plus the real `CastService` → `WalletService`
path under the fake Roblox engine in `tests/harness/`). Nothing here was run
in Studio, and no UI was seen; the client scripts parse, follow the house
rules, and are exercised only to the extent the harness mocks allow.

## The loop this closes

Before: a cast produced a fish with a `value` number attached and nothing
else. The HUD summed those numbers client-side into a fake "session total"
— the server tracked no money at all, and the client was computing value
(house rule 2, broken in the one place it most matters).

Now:

```
cast ──> OceanService.harvest        stock deducted, market refreshed
     ──> CastResult                  catchId + valueCents (a QUOTE)
     ──> WalletService.recordCatch   the fish enters the server-side HOLD
     ──> WalletSync                  balance + hold, to that one client

sell (card or market panel)
     ──> SellRequest                 { catchId } — and nothing else
     ──> server prices it            Market.priceOf * yielded -> cents
     ──> Wallet.sell                 hold shrinks, balance rises, atomically
     ──> SellResult + WalletSync     the paid amount and the new balance
```

KEEP is not an action, it is the default: the fish is held from the instant
it lands, so doing nothing (or dismissing the card, or logging off) keeps
it. The catch card says so. Selling later from the market panel is the
"hold into a rising market" play.

## Money model

- **Integer cents, everywhere the wallet is involved.** Floats accumulate
  rounding error into exploits; the market above the wallet is floats (the
  existing economy contract with the Worker — unchanged by this pass), so
  there is exactly one conversion point, `Wallet.saleCents(price, yielded)`,
  deterministic and pinned by tests against the real interpreter.
- 100 cents = 1 credit. Gear prices and market prices stay in credits;
  client displays show credits (`12.40`), derived from server-sent cents by
  division and formatting only.
- Hard ceiling `Wallet.MAX_BALANCE_CENTS = 9e15`, below 2^53, so no integer
  balance can ever round on addition. A credit that would cross it is
  rejected and the fish stays held.
- **Rejection, never clamping.** A debit larger than the balance fails with
  "insufficient funds" and the balance is untouched. A refused sale leaves
  the catch in the hold. Every mutating function validates fully before it
  mutates.
- **Nothing worthless enters the hold.** `Wallet.recordCatch` refuses a
  catch with zero (or non-finite) biomass — harvest can answer ok with
  `yielded == 0` for a species with no capacity at the region, and a
  zero-yield fish could never be sold. The cast result then carries no
  `catchId` and no quote.

## Where the fish is accounted for — exactly once

`OceanService.harvest` deducts the stock and refreshes the market BEFORE the
`CastResult` is sent. Selling therefore never touches ocean state again: a
sale converts an already-landed catch into money. Taxing the stock a second
time at sale would charge the ocean twice for one fish. Pinned by test:
stock after cast == stock after sell.

## The wire (src/Shared/Types.luau)

| Remote | Direction | Payload |
| --- | --- | --- |
| `SellRequest` | client → server | `{ catchId: string }` |
| `SellResult` | server → client | `{ ok, reason?, catchId, speciesId?, paidCents, balanceCents }` |
| `WalletSync` | server → client | `{ balanceCents, hold: { { catchId, speciesId, weightKg } } }` |

`CastResultPayload` gained two optional fields (set only when `ok == true`):
`catchId` and `valueCents` (the quote at catch time). `CastRequestPayload`
gained `performance: number` — the fight minigame already sent it; the
contract now admits it, and the handler defaults a missing one to a mid
roll instead of crashing (that crash was a documented PLAYLOOP defect).

The sell request carries **a catchId and nothing else** — no species, no
quantity, no price. Those fields do not exist on the wire, so a modified
client cannot claim them. The server looks the id up in its own record for
that player, derives the species and the biomass from what it finds, and
prices the sale against the live market at the moment it processes the
request. A stale client price is not a handled case; it is an inexpressible
one. The harness test fires a sale with `speciesId`/`price`/`quantity`
spoofs included and asserts the paid amount equals the market-derived
quote, byte for byte.

`WalletSync.hold` entries carry identity and weight but **not `yielded`** —
biomass stays server-side so the wire never carries enough to value a fish
client-side (house rule 2).

## Failure cases

- **Sold twice / stale card / restart-wiped hold / another player's fish:**
  all collapse to "no such catch" — the id is not in THIS player's hold, and
  the client gets no information about why. Idempotency is consumption: a
  successful sale removes the catch, so the replay fails and the balance is
  credited exactly once (tested through the wire).
- **Two sells racing:** RemoteEvent handlers run serially and the handler
  never yields between reading the hold and mutating it, so they resolve in
  order — first wins, second is refused.
- **Server restart mid-sale:** the sale is one synchronous mutation
  (remove-from-hold + credit), and the snapshot persists balance and hold
  together in a single `UpdateAsync`. A crash therefore lands wholly on one
  side: never money without the fish leaving the hold, never the fish gone
  without the money. What a crash CAN do is lose the last ≤120 s of unsaved
  play (the autosave window, same as xp today) — a player may see "sold"
  and find the fish back in the hold after a restart. That is a lost sale,
  not a duplicated one; it is the direction that cannot mint money.
- **Dropped remote / no answer:** the catch card and each market-panel hold
  row run a watchdog that re-enables the button and says the fish is still
  held. Rate-limited sells are ANSWERED with a failure result (unlike
  rate-limited casts, which drop silently) because a pending sale is visibly
  waiting on an answer.

## Persistence

Money lives in its own DataStore, `slack-water-wallets-v1`, keyed
`player_<UserId>` — not in the profile store. The reason: the profile is
`Progression.luau`'s closed shape (`snapshot` whitelists xp/gear and would
silently drop foreign fields), and that file belongs to another change. The
wallet service copies ProfileService's proven lifecycle instead: pcall'd
loads/saves, load-race-keeps-session, autosave every 120 s, save on leave,
bounded `BindToClose` flush. The round-trip that matters —
`Wallet.snapshot` → `Wallet.restore` → money intact, junk repaired
downward, duplicated ids deduped, the id sequence raised past any held id so
a rollback cannot resurrect a sold catch's id — is pinned by unit tests
against the exact bytes `UpdateAsync` writes.

## What this pass did NOT do

- **The HUD session total is still a client-side sum of `CastResult.value`**
  (`src/Client/HUD.client.luau:183`, `earnedTotal += Ui.tonum(p.value, 0)`).
  That file is owned by a concurrent agent and was not touched. The honest
  replacement exists and is one line away: subscribe `WalletSync` and render
  `balanceCents` (format cents → credits for display, as CatchCard and
  MarketPanel already do). Until that switch happens, the HUD number is
  still a client invention and should not be believed; the card's old
  "+ value" line (which implied money was credited) is gone from
  CatchCard, which now shows the server's quote as a quote.
- **Gear purchases are not wired.** `Progression.buy(profile, gearId, funds)`
  already expects a caller-owned funds store; the wallet is that store
  (`Wallet.debit(gear.price * 100)` — prices are credits). No purchase
  remote exists yet.
- **No economy constant or formula changed**, so `shared/economy-vectors.json`
  did not need regenerating and Worker parity is untouched.
- Nothing ran in Studio. The `Environment`/region-listener boot defects that
  `docs/PLAYLOOP.md` documents (in files this pass does not own) were still
  open when this was written; the wallet suites boot the cast path directly
  and do not exercise `Main.server.luau`'s full stage list.
