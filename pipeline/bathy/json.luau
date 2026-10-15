--!strict
--[[
	Json — minimal, deterministic JSON *encoder* for the bathymetry pipeline.

	The standalone `luau` CLI has no JSON library in either direction — that is
	why tests/fixtures/worker-snapshot.json ships with a hand-maintained .luau
	twin. This module exists so the pipeline can EMIT JSON without growing a
	dependency. It encodes only, deliberately: decoding happens in the two
	places that already own a parser — Roblox's HttpService:JSONDecode at
	runtime, and ordinary tooling (jq, the worker, a text editor) on the CLI.
	Writing a decoder here would just be a second parser to keep correct.

	Determinism: object keys are emitted in sorted order and floats go through
	%.14g, so the same table always serialises to the same bytes. The grids
	themselves are integer arrays (decimetres), which are exact.
]]

local Json = {}

local function encodeString(s: string): string
	local parts = { '"' }
	for i = 1, #s do
		local b = s:byte(i)
		if b == 34 then
			table.insert(parts, '\\"')
		elseif b == 92 then
			table.insert(parts, "\\\\")
		elseif b == 8 then
			table.insert(parts, "\\b")
		elseif b == 9 then
			table.insert(parts, "\\t")
		elseif b == 10 then
			table.insert(parts, "\\n")
		elseif b == 12 then
			table.insert(parts, "\\f")
		elseif b == 13 then
			table.insert(parts, "\\r")
		elseif b < 32 then
			table.insert(parts, string.format("\\u%04x", b))
		else
			table.insert(parts, s:sub(i, i))
		end
	end
	table.insert(parts, '"')
	return table.concat(parts)
end

local function encodeNumber(n: number): string
	if n ~= n or n == math.huge or n == -math.huge then
		error("Json: refusing to encode a non-finite number", 0)
	end
	if math.floor(n) == n and math.abs(n) < 1e15 then
		return string.format("%d", math.floor(n))
	end
	return string.format("%.14g", n)
end

local function isArray(t: any): boolean
	if type(t) ~= "table" then
		return false
	end
	local n = #t
	if n == 0 then
		return next(t) == nil -- {} encodes as []; we never need an empty object
	end
	for i = 1, n do
		if t[i] == nil then
			return false
		end
	end
	for k in t do
		if type(k) ~= "number" or math.floor(k) ~= k or k < 1 or k > n then
			return false
		end
	end
	return true
end

local function encodeValue(v: any, out: { string }): ()
	local t = type(v)
	if t == "string" then
		table.insert(out, encodeString(v))
	elseif t == "number" then
		table.insert(out, encodeNumber(v))
	elseif t == "boolean" then
		table.insert(out, if v then "true" else "false")
	elseif t == "table" then
		if isArray(v) then
			table.insert(out, "[")
			for i = 1, #v do
				if i > 1 then
					table.insert(out, ",")
				end
				encodeValue(v[i], out)
			end
			table.insert(out, "]")
		else
			local keys: { string } = {}
			for k in v do
				if type(k) ~= "string" then
					error("Json: object keys must be strings, got " .. type(k), 0)
				end
				table.insert(keys, k)
			end
			table.sort(keys)
			table.insert(out, "{")
			for i, k in keys do
				if i > 1 then
					table.insert(out, ",")
				end
				table.insert(out, encodeString(k))
				table.insert(out, ":")
				encodeValue(v[k], out)
			end
			table.insert(out, "}")
		end
	else
		error("Json: cannot encode value of type " .. t, 0)
	end
end

--- Encode a table as a compact JSON string.
function Json.encode(value: any): string
	local out: { string } = {}
	encodeValue(value, out)
	return table.concat(out)
end

return Json
