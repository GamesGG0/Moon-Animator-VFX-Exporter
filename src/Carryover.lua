--!strict
-- Keeps the Functions people add to exported cues when the animation is exported again.
--
-- Reads the previous export's source, finds each cue's `Function = ...` (by scanning Lua tokens,
-- so strings, comments and nested code don't confuse it), and hands the text back so the new
-- export can write it onto the matching cue.

local Carryover = {}

export type Found = {
	Key: string, -- the cue key as written, e.g. "27" or "0.45"
	Effect: string?, -- the Effect value as written, quotes included
	Text: string, -- the Function's source
}

type Token = { Kind: string, Text: string, S: number, E: number }

local function lex(src: string): { Token }
	local tokens = {}
	local i, n = 1, #src

	local function push(kind: string, s: number, e: number)
		table.insert(tokens, { Kind = kind, Text = string.sub(src, s, e), S = s, E = e })
	end

	while i <= n do
		local c = string.sub(src, i, i)
		if string.match(c, "%s") then
			i += 1
		elseif string.sub(src, i, i + 1) == "--" then
			local level = string.match(src, "^%[(=*)%[", i + 2)
			if level then
				local close = "]" .. level .. "]"
				local e = string.find(src, close, i + 4 + #level, true)
				i = if e then e + #close else n + 1
			else
				local e = string.find(src, "\n", i, true)
				i = (e or n) + 1
			end
		elseif c == '"' or c == "'" or c == "`" then
			local j = i + 1
			while j <= n do
				local d = string.sub(src, j, j)
				if d == "\\" then
					j += 2
				elseif d == c or (d == "\n" and c ~= "`") then
					break
				else
					j += 1
				end
			end
			push("string", i, math.min(j, n))
			i = j + 1
		elseif c == "[" and string.match(src, "^%[=*%[", i) then
			local level = string.match(src, "^%[(=*)%[", i) :: string
			local close = "]" .. level .. "]"
			local e = string.find(src, close, i + 2 + #level, true)
			local stop = if e then e + #close - 1 else n
			push("string", i, stop)
			i = stop + 1
		elseif string.match(c, "[%a_]") then
			local e = (string.find(src, "[^%w_]", i) or n + 1) - 1
			push("name", i, e)
			i = e + 1
		elseif string.match(c, "%d") or (c == "." and string.match(string.sub(src, i + 1, i + 1), "%d")) then
			local e = select(2, string.find(src, "^[%w%.]*[eEpP][%+%-][%w%.]*", i))
				or select(2, string.find(src, "^[%w%.]+", i))
				or i
			push("number", i, e)
			i = e + 1
		else
			push("punct", i, i)
			i += 1
		end
	end

	return tokens
end

-- An `if` is an if-expression (no `end`) when it's where a value is expected.
local VALUE_BEFORE = {
	["="] = true, ["("] = true, [","] = true, ["{"] = true, ["["] = true,
	["return"] = true, ["in"] = true, ["and"] = true, ["or"] = true, ["not"] = true,
	["+"] = true, ["-"] = true, ["*"] = true, ["/"] = true, ["%"] = true, ["^"] = true,
	["<"] = true, [">"] = true, ["#"] = true, ["."] = true, ["~"] = true,
}

local function isBlockOpener(tokens: { Token }, i: number): boolean
	local t = tokens[i]
	if t.Kind ~= "name" then
		return false
	end
	if t.Text == "function" or t.Text == "do" or t.Text == "repeat" then
		return true
	end
	if t.Text == "if" then
		local prev = tokens[i - 1]
		return not (prev and VALUE_BEFORE[prev.Text])
	end
	return false
end

local function isBlockCloser(t: Token): boolean
	return t.Kind == "name" and (t.Text == "end" or t.Text == "until")
end

-- Index of the token closing the table/paren opened at `open`.
local function matching(tokens: { Token }, open: number): number?
	local depth = 0
	for i = open, #tokens do
		local text = tokens[i].Text
		if tokens[i].Kind == "punct" then
			if text == "{" or text == "(" or text == "[" then
				depth += 1
			elseif text == "}" or text == ")" or text == "]" then
				depth -= 1
				if depth == 0 then
					return i
				end
			end
		end
	end
	return nil
end

-- The comment the formatter keeps orphaned Functions in.
Carryover.ORPHAN_MARKER = "These Functions were on cues that are gone since the last export."

-- Every cue's Function in a previous export's source, including ones kept in the orphan comment.
-- Cues without one are skipped.
function Carryover.extract(src: string): { Found }
	local found = Carryover.extractCues(src)

	local marker = string.find(src, Carryover.ORPHAN_MARKER, 1, true)
	if marker then
		local open, openEnd, level = string.find(src, "%-%-%[(=*)%[", marker)
		if open and openEnd then
			local close = string.find(src, "]" .. level .. "]", openEnd + 1, true)
			if close then
				local body = string.sub(src, openEnd + 1, close - 1)
				for _, entry in Carryover.extractCues("Cues = {" .. body .. "}") do
					table.insert(found, entry)
				end
			end
		end
	end

	return found
end

function Carryover.extractCues(src: string): { Found }
	local found = {}
	local tokens = lex(src)

	-- The `Cues = {` table.
	local cuesOpen
	for i = 1, #tokens - 2 do
		if tokens[i].Text == "Cues" and tokens[i + 1].Text == "=" and tokens[i + 2].Text == "{" then
			cuesOpen = i + 2
			break
		end
	end
	if not cuesOpen then
		return found
	end
	local cuesClose = matching(tokens, cuesOpen)
	if not cuesClose then
		return found
	end

	local i = cuesOpen + 1
	while i < cuesClose do
		-- An entry: [key] = { ... }
		if tokens[i].Text == "[" then
			local keyClose = matching(tokens, i)
			local eq = keyClose and tokens[keyClose + 1]
			local open = keyClose and keyClose + 2
			if keyClose and eq and eq.Text == "=" and open and tokens[open] and tokens[open].Text == "{" then
				local close = matching(tokens, open)
				if not close then
					break
				end

				local key = string.sub(src, tokens[i + 1].S, tokens[keyClose - 1].E)
				local effect: string? = nil
				local text: string? = nil

				-- Top-level fields of the entry.
				local j = open + 1
				local depth = 0
				while j < close do
					local t = tokens[j]
					if t.Kind == "punct" and (t.Text == "{" or t.Text == "(" or t.Text == "[") then
						depth += 1
					elseif t.Kind == "punct" and (t.Text == "}" or t.Text == ")" or t.Text == "]") then
						depth -= 1
					elseif depth == 0 and t.Kind == "name" and tokens[j + 1] and tokens[j + 1].Text == "=" then
						if t.Text == "Effect" and tokens[j + 2] and tokens[j + 2].Kind == "string" then
							effect = tokens[j + 2].Text
						elseif t.Text == "Function" then
							-- The value runs to the next top-level `,` or the entry's `}`.
							local first = j + 2
							local k = first
							local nest, blocks = 0, 0
							while k < close do
								local v = tokens[k]
								if v.Kind == "punct" and (v.Text == "{" or v.Text == "(" or v.Text == "[") then
									nest += 1
								elseif v.Kind == "punct" and (v.Text == "}" or v.Text == ")" or v.Text == "]") then
									nest -= 1
								elseif isBlockOpener(tokens, k) then
									blocks += 1
								elseif isBlockCloser(v) then
									blocks -= 1
								elseif nest == 0 and blocks == 0 and (v.Text == "," or v.Text == ";") and v.Kind == "punct" then
									break
								end
								k += 1
							end
							if k > first and nest == 0 and blocks == 0 then
								text = string.sub(src, tokens[first].S, tokens[k - 1].E)
							end
							j = k - 1
						end
					end
					j += 1
				end

				if text then
					table.insert(found, { Key = key, Effect = effect, Text = text })
				end
				i = close + 1
				continue
			end
		end
		i += 1
	end

	return found
end

-- Gives each new cue the Function its previous version had: matched by key, or by effect name
-- when that's unambiguous. `keyOf` returns a cue's key as the new export writes it. Returns the
-- Functions that no longer have a cue.
function Carryover.apply(found: { Found }, cues: { any }, keyOf: (any) -> string): { Found }
	local byKey: { [number]: any } = {}
	local byEffect: { [string]: { any } } = {}
	for _, cue in cues do
		local key = tonumber(keyOf(cue))
		if key then
			byKey[key] = cue
		end
		local effect = string.format("%q", cue.Effect)
		byEffect[effect] = byEffect[effect] or {}
		table.insert(byEffect[effect], cue)
	end

	local leftover = {}
	for _, entry in found do
		local cue = byKey[tonumber(entry.Key) or math.huge]
		if not cue or cue.Function then
			local sameEffect = entry.Effect and byEffect[entry.Effect]
			cue = if sameEffect and #sameEffect == 1 and not sameEffect[1].Function then sameEffect[1] else nil
		end

		if cue then
			cue.Function = entry.Text
		else
			table.insert(leftover, entry)
		end
	end

	return leftover
end

return Carryover
