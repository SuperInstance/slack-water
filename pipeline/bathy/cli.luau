--!strict
--[[
	cli — argument parsing for the bathymetry converter.

	Invoked indirectly: convert.sh embeds the input file's text into a
	generated wrapper script (the standalone luau CLI cannot read files), and
	that wrapper calls `run(INPUT_TEXT, argv)`. Kept separate from convert.luau
	so tests can drive the parsing/gridding maths directly without spawning
	processes.

	Errors go to stderr (via error before anything is printed to stdout), so
	bash can redirect stdout straight into the output file.
]]

local Convert = require("./convert")

local Cli = {}

local USAGE = [[
convert soundings -> shared/bathy/<name>.json

usage (via convert.sh):
  pipeline/bathy/convert.sh INPUT [options]

options:
  --units m|ft|fm        REQUIRED. Depth units of the input file. Never guessed.
  --surveyed             Operator assertion that the input is real survey data.
                         Off by default; the output then carries surveyed:false.
  --cell METRES          Grid cell size in metres (default 50).
  --radius CELLS         Sounding search radius in cells (default 3).
  --coords geographic|projected
                         Input columns are lon/lat degrees or metres. Default:
                         detected and reported in the output.
  --anchor-lon V --anchor-lat V
                         Real-world coordinate that maps to world origin (0,0).
                         Default: centre of the survey's own bounds.
  --studs-per-metre V    World scale (default 1).
  --depth-sign down|up   Positive depths (default) or positive elevations.
  --name NAME            Output name (default: input file name minus extension).
  --source "TEXT"        Free-text source description, recorded verbatim.
  --out FILE             Output path (default shared/bathy/<name>.json).
  --timestamp ISO        Pinned convertedAt timestamp, for reproducible output.
]]

local FLAGWithValue: { [string]: boolean } = {
	["--units"] = true,
	["--cell"] = true,
	["--radius"] = true,
	["--coords"] = true,
	["--anchor-lon"] = true,
	["--anchor-lat"] = true,
	["--studs-per-metre"] = true,
	["--depth-sign"] = true,
	["--name"] = true,
	["--source"] = true,
	["--source-file"] = true,
	["--out"] = true,
	["--timestamp"] = true,
}

--- Parse `--flag value` / `--flag=value` tokens into an options table.
--- Keys are camelCased with a capital first letter: --studs-per-metre -> StudsPerMetre.
function Cli.parseArgs(argv: { string }): any
	local opts: any = {}
	local i = 1
	while i <= #argv do
		local a = argv[i]
		local flag, inlineValue = a:match("^%-%-([%w-]+)=(.*)$")
		if flag == nil then
			flag = a:match("^%-%-([%w-]+)$")
		end
		if flag == nil then
			error("cli: unexpected argument " .. a .. "\n" .. USAGE, 0)
		end

		local camel = flag:gsub("%-(%w)", function(c: string)
			return c:upper()
		end)
		local key = camel:sub(1, 1):upper() .. camel:sub(2)

		if FLAGWithValue["--" .. flag] then
			local value = inlineValue
			if value == nil then
				i += 1
				value = argv[i]
				if value == nil then
					error("cli: " .. a .. " needs a value\n" .. USAGE, 0)
				end
			end
			opts[key] = value
		elseif inlineValue ~= nil then
			error("cli: " .. a .. " does not take a value\n" .. USAGE, 0)
		elseif flag == "surveyed" then
			opts[key] = true
		elseif flag == "help" then
			error(USAGE, 0)
		else
			error("cli: unknown flag " .. a .. "\n" .. USAGE, 0)
		end
		i += 1
	end
	return opts
end

local function toNumber(v: any, flag: string): number?
	if v == nil then
		return nil
	end
	local n = tonumber(v)
	if n == nil then
		error("cli: " .. flag .. " must be a number, got " .. tostring(v), 0)
	end
	return n
end

--- Build the grid document and return it as a JSON string. `outPath` is
--- carried in the report line, not the JSON, so identical inputs with a
--- different --out still produce identical bytes.
function Cli.run(inputText: string, argv: { string }): string
	local args = Cli.parseArgs(argv)

	if args.Units == nil then
		error("cli: --units is required; depth units are never guessed\n" .. USAGE, 0)
	end

	return Convert.toJson(Convert.buildGrid(inputText, {
		units = args.Units,
		depthSign = args.DepthSign,
		coords = args.Coords,
		cellMetres = toNumber(args.Cell, "--cell"),
		anchorLon = toNumber(args.AnchorLon, "--anchor-lon"),
		anchorLat = toNumber(args.AnchorLat, "--anchor-lat"),
		studsPerMetre = toNumber(args.StudsPerMetre, "--studs-per-metre"),
		radiusCells = toNumber(args.Radius, "--radius"),
		name = args.Name,
		sourceFile = args.SourceFile,
		sourceDescription = args.Source,
		surveyed = args.Surveyed == true,
		convertedAt = args.Timestamp,
	}))
end

return Cli
