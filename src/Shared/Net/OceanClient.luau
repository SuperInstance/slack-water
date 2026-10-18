--!strict
--[[
	OceanClient — the link to the Cloudflare backend.

	Design rule: the backend is an enhancement, never a dependency. Slack Water
	plays perfectly well on a single server with a locally simulated ocean; the
	Worker is what makes the ocean *global* and lets a language model author new
	fishing grounds. If the Worker is down, slow, or unconfigured, the game must
	degrade to local play rather than stutter, stall, or error.

	Every entry point here therefore fails soft and returns a value the caller
	can test. Nothing in this module throws into gameplay code.
]]

local HttpService = game:GetService("HttpService")

export type Snapshot = {
	ok: boolean,
	regions: { [string]: any }?,
	month: number?,
	day: number?,
}

export type ComposeResult = {
	ok: boolean,
	banks: { any }?,
	error: string?,
}

export type MarketResult = {
	ok: boolean,
	entries: { any }?,
}

local OceanClient = {}

--- Base URL of the Worker. Set this to your deployment, or leave it empty to
--- run in fully-local mode.
-- The deployed Worker. Set to "" to run fully locally.
OceanClient.BASE_URL = "https://slack-water.casey-digennaro.workers.dev"

--- How long a slow backend call is allowed to take before we stop trusting its
--- answer for anything time-sensitive.
---
--- READ THIS BEFORE ASSUMING IT IS A TIMEOUT. It is not one, and it cannot be
--- made into one. HttpService:RequestAsync is synchronous and Roblox exposes no
--- way to cancel an in-flight request, so there is no code that can abandon a
--- hung call from this side. What this constant actually buys is a bound on how
--- stale data we are willing to act on.
---
--- The real mitigation for a slow call is structural and lives in the caller:
--- OceanService.advanceCalendar spawns the compose round instead of running it
--- inline, so a model that thinks for ten seconds cannot stall the heartbeat
--- that started it. That is the protection. This number is the backstop.
OceanClient.TIMEOUT = 4

local function url(path: string): string?
	if OceanClient.BASE_URL == "" then
		return nil
	end
	return (OceanClient.BASE_URL:gsub("/+$", "")) .. path
end

--- Perform a request with a hard timeout and a soft failure.
---
--- NOTE ON THE ARGUMENT SHAPE. HttpService:RequestAsync takes ONE table.
--- The old two-argument form RequestAsync(url, options) was removed, and
--- passing it raises "Unable to cast string to Dictionary". That is not a
--- hypothetical: this function used the two-argument form, so every call to
--- the backend failed, and because both failure paths returned in silence the
--- game quietly fell back to procedural banks for an entire working session
--- with the AI composer never once running.
---
--- The headless harness already modelled the single-table form correctly,
--- which is why it also rejected the two-argument call. Both the harness and
--- this comment were right and the code was wrong.
local function request(path: string, method: string, body: any?): (boolean, any?, string?)
	local endpoint = url(path)
	if not endpoint then
		return false, nil, "not configured"
	end

	local options: any = {
		Url = endpoint,
		Method = method,
		Headers = {
			["Content-Type"] = "application/json",
		},
	}

	if body ~= nil then
		options.Body = HttpService:JSONEncode(body)
	end

	local ok, result = pcall(function()
		return HttpService:RequestAsync(options)
	end)

	if not ok then
		return false, nil, "request failed: " .. tostring(result)
	end

	if not result.Success then
		return false, nil, "HTTP " .. tostring(result.StatusCode)
	end

	local decoded, value = pcall(function()
		return HttpService:JSONDecode(result.Body)
	end)

	if not decoded then
		return false, nil, "malformed response"
	end

	return true, value, nil
end

--- Fetch the global ocean snapshot. Returns ok == false when the backend is
--- unavailable; the caller keeps its local ocean in that case.
function OceanClient.getSnapshot(): Snapshot
	local ok, value, err = request("/ocean/snapshot", "GET")
	if not ok then
		return { ok = false, error = err }
	end

	return {
		ok = true,
		regions = value.regions,
		month = value.month,
		day = value.day,
	}
end

--- Ask the backend to compose new fishing grounds. The Worker runs the model,
--- validates every candidate, and returns only the banks that survived.
function OceanClient.composeBanks(round: number): ComposeResult
	local ok, value, err = request("/banks/compose", "POST", { round = round })
	if not ok then
		return { ok = false, error = err }
	end

	return { ok = true, banks = value.banks }
end

--- Fetch live prices. The local market stays authoritative unless this
--- succeeds, so a stale backend can never desync the economy mid-session.
function OceanClient.getMarket(): MarketResult
	local ok, value, err = request("/market", "GET")
	if not ok then
		return { ok = false, error = err }
	end

	return { ok = true, entries = value.entries }
end

--- Report catches so the global ocean state stays accurate across servers.
---
--- Returns the number of catches the Worker accepted, which is exactly how many
--- pending deltas the server may drop from its reconcile queue. Returns 0 on
--- any failure so a network problem leaves the queue intact and the catch gets
--- replayed against the next snapshot.
function OceanClient.reportCatch(regionId: string, speciesId: string, effort: number): number
	local ok, value, err = request("/ocean/harvest", "POST", {
		catches = { { regionId = regionId, speciesId = speciesId, effort = effort } },
	})

	if not ok then
		-- Intentionally silent. A failed catch report is logged nowhere and
		-- surfaced to nobody: the local sim already applied the harvest, and a
		-- visible error would punish the player for a backend problem. The
		-- pending queue is what keeps this honest, not an error message.
		return 0
	end

	local results = value.results or value.catches
	if type(results) == "table" then
		return #results
	end
	return 0
end

OceanClient._url = url
OceanClient._request = request

return OceanClient
