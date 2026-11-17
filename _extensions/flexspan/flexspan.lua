--- flexspan.lua
-- Pandoc/Quarto Lua filter that turns user-defined delimiters into styled
-- inline text. Delimiters ("placeholders") are declared in the document
-- metadata under the `flexspan` key.
--
-- ## Metadata
--
-- ```yaml
-- flexspan:
--   - left: "!!"            # opening delimiter (required)
--     right: "!!"           # closing delimiter (default: same as left)
--     color: red            # text colour       -> works in every format
--     bg: yellow            # background colour -> works in every format
--     bold: true            # also: italic, underline, strike
--   - left: "%["            # code: true -> inline code, like backticks
--     right: "]"            #   %[ls -la]
--     code: true
--   - left: "-="            # no style at all: colour comes from the options
--     right: "=-"           #   -=some text=-(blue)   -=text=-(red, bold)
--   - left: "++"
--     command: hlcode       # named style: \hlcode[opts]{..} in LaTeX,
--     opts: "fg=red"        #   #hlcode(fg: "red")[..] in Typst,
--                           #   <span class="hlcode" data-fg="red"> in HTML,
--                           #   character style "hlcode" in docx
--   - left: "-"
--     right: "\\>"          # `exact` rules have no content: the delimiters
--     command: iconarrow    #   are written together ( -> ). Characters that
--     exact: true           #   are markdown syntax on their own need "\\"
--   - left: "(("
--     right: "))"
--     class: note           # HTML class / docx character style only
--     content: "Note!"      # fixed content, replaces the enclosed text
-- ```
--
-- | key       | aliases                         | meaning                                   |
-- |-----------|---------------------------------|-------------------------------------------|
-- | left      | pre, before, open               | opening delimiter                         |
-- | right     | pos, post, after, close         | closing delimiter (default: left)         |
-- | color     | fg                              | text colour (CSS name, #hex, or native)   |
-- | bg        | background                      | background colour                         |
-- | bold, italic, underline, strike           | booleans                                  |
-- | code      |                                 | boolean: inline code, like backticks      |
-- | command   | cmd                             | LaTeX command / Typst function (+ class)  |
-- | class     |                                 | HTML class / docx character style         |
-- | opts      | opt, options                    | default options                           |
-- | content   | contents, val, arg              | fixed content                             |
-- | exact     | single, one, join, contiguous   | delimiters must be adjacent, no content   |
-- | latex, html, typst, docx, beamer, revealjs | map of the keys above, used only  |
-- |           |                                 | for that output format (see below)        |
--
-- ## Format blocks
--
-- A rule can mean something different in each output format:
--
-- ```yaml
--   - left: "::"
--     right: ":*"
--     exact: true
--     content: "●"          # every format ...
--     latex:                # ... except LaTeX/beamer: \iconbullet{}
--       command: iconbullet
--       content: ""
-- ```
--
-- `html` covers every format that is not latex, typst or docx. `beamer` and
-- `revealjs` apply to that writer only, on top of `latex` / `html`. An empty
-- value removes `command`, `class`, `opts`, `color` or `bg`.
--
-- ## Options
--
-- Options are written in parentheses right after the closing delimiter:
-- `!!text!!(blue)`. They replace the default `opts` of the rule.
--   * rule WITH a `command`: options are handed to the command untouched.
--   * rule WITHOUT a `command`: options are style options. A bare word is a
--     colour; `bg=...`, `color=...`, `bold`, `italic`, `underline`, `strike`
--     are recognised: `-=text=-(white, bg=navy, bold)`.
--
-- ## Notes
--
--   * Works anywhere inline text occurs: paragraphs, headings, lists, tables,
--     captions, footnotes, and inside bold/emphasis/links.
--   * An opening delimiter must not follow a letter or digit, a closing one
--     must not be followed by a letter or digit ("Wow!! Great!!" is untouched).
--   * Code and math are never touched. Wrap text in a span or div with class
--     `skipspan` to protect it: `[!!literal!!]{.skipspan}`.
--   * Hand-written spans `[text]{.name key=val}` whose class is a `command`
--     of some rule become that command in LaTeX/Typst output.
--
-- Author: Georgios Pappas Jr
--         Universidade de Brasília (UnB) - Brasil
-- Version: 2.1.0
------------------------------------------------------------------

local META_NAME = "flexspan"
-- Spans/Divs with this class are left untouched
local SKIP_CLASS = "skipspan"

local List = pandoc.List
local stringify = pandoc.utils.stringify

-- ░░ Output family ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░{{{1
-- "latex", "typst" and "docx" need format specific code; everything else
-- (html, revealjs, epub, markdown, ...) gets a Span with class/style attributes.
local KIND = "html"
if FORMAT:match("latex") or FORMAT:match("beamer") then
	KIND = "latex"
elseif FORMAT:match("typst") then
	KIND = "typst"
elseif FORMAT:match("docx") then
	KIND = "docx"
end

-- ░░ State filled from the metadata ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░{{{1
local COMMANDS = {} -- set of command names (for hand-written spans)
local FIRST = {} -- first byte of a delimiter -> tokens starting with it (longest first)
local HAS_RULES = false

local warned = {}
local function warn(msg)
	if not warned[msg] then
		warned[msg] = true
		io.stderr:write("[flexspan] " .. msg .. "\n")
	end
end

-- ░░ Colours ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░{{{1
-- CSS named colours. They are converted to hex outside HTML so that a colour
-- looks the same in every output format.
local CSS_COLORS = {
	aliceblue = "F0F8FF", antiquewhite = "FAEBD7", aqua = "00FFFF", aquamarine = "7FFFD4",
	azure = "F0FFFF", beige = "F5F5DC", bisque = "FFE4C4", black = "000000",
	blanchedalmond = "FFEBCD", blue = "0000FF", blueviolet = "8A2BE2", brown = "A52A2A",
	burlywood = "DEB887", cadetblue = "5F9EA0", chartreuse = "7FFF00", chocolate = "D2691E",
	coral = "FF7F50", cornflowerblue = "6495ED", cornsilk = "FFF8DC", crimson = "DC143C",
	cyan = "00FFFF", darkblue = "00008B", darkcyan = "008B8B", darkgoldenrod = "B8860B",
	darkgray = "A9A9A9", darkgreen = "006400", darkgrey = "A9A9A9", darkkhaki = "BDB76B",
	darkmagenta = "8B008B", darkolivegreen = "556B2F", darkorange = "FF8C00",
	darkorchid = "9932CC", darkred = "8B0000", darksalmon = "E9967A", darkseagreen = "8FBC8F",
	darkslateblue = "483D8B", darkslategray = "2F4F4F", darkslategrey = "2F4F4F",
	darkturquoise = "00CED1", darkviolet = "9400D3", deeppink = "FF1493", deepskyblue = "00BFFF",
	dimgray = "696969", dimgrey = "696969", dodgerblue = "1E90FF", firebrick = "B22222",
	floralwhite = "FFFAF0", forestgreen = "228B22", fuchsia = "FF00FF", gainsboro = "DCDCDC",
	ghostwhite = "F8F8FF", gold = "FFD700", goldenrod = "DAA520", gray = "808080",
	green = "008000", greenyellow = "ADFF2F", grey = "808080", honeydew = "F0FFF0",
	hotpink = "FF69B4", indianred = "CD5C5C", indigo = "4B0082", ivory = "FFFFF0",
	khaki = "F0E68C", lavender = "E6E6FA", lavenderblush = "FFF0F5", lawngreen = "7CFC00",
	lemonchiffon = "FFFACD", lightblue = "ADD8E6", lightcoral = "F08080", lightcyan = "E0FFFF",
	lightgoldenrodyellow = "FAFAD2", lightgray = "D3D3D3", lightgreen = "90EE90",
	lightgrey = "D3D3D3", lightpink = "FFB6C1", lightsalmon = "FFA07A", lightseagreen = "20B2AA",
	lightskyblue = "87CEFA", lightslategray = "778899", lightslategrey = "778899",
	lightsteelblue = "B0C4DE", lightyellow = "FFFFE0", lime = "00FF00", limegreen = "32CD32",
	linen = "FAF0E6", magenta = "FF00FF", maroon = "800000", mediumaquamarine = "66CDAA",
	mediumblue = "0000CD", mediumorchid = "BA55D3", mediumpurple = "9370DB",
	mediumseagreen = "3CB371", mediumslateblue = "7B68EE", mediumspringgreen = "00FA9A",
	mediumturquoise = "48D1CC", mediumvioletred = "C71585", midnightblue = "191970",
	mintcream = "F5FFFA", mistyrose = "FFE4E1", moccasin = "FFE4B5", navajowhite = "FFDEAD",
	navy = "000080", oldlace = "FDF5E6", olive = "808000", olivedrab = "6B8E23",
	orange = "FFA500", orangered = "FF4500", orchid = "DA70D6", palegoldenrod = "EEE8AA",
	palegreen = "98FB98", paleturquoise = "AFEEEE", palevioletred = "DB7093",
	papayawhip = "FFEFD5", peachpuff = "FFDAB9", peru = "CD853F", pink = "FFC0CB",
	plum = "DDA0DD", powderblue = "B0E0E6", purple = "800080", rebeccapurple = "663399",
	red = "FF0000", rosybrown = "BC8F8F", royalblue = "4169E1", saddlebrown = "8B4513",
	salmon = "FA8072", sandybrown = "F4A460", seagreen = "2E8B57", seashell = "FFF5EE",
	sienna = "A0522D", silver = "C0C0C0", skyblue = "87CEEB", slateblue = "6A5ACD",
	slategray = "708090", slategrey = "708090", snow = "FFFAFA", springgreen = "00FF7F",
	steelblue = "4682B4", tan = "D2B48C", teal = "008080", thistle = "D8BFD8", tomato = "FF6347",
	turquoise = "40E0D0", violet = "EE82EE", wheat = "F5DEB3", white = "FFFFFF",
	whitesmoke = "F5F5F5", yellow = "FFFF00", yellowgreen = "9ACD32",
}

--- Returns "RRGGBB" for #hex values and CSS colour names, nil otherwise.
local function color_hex(c)
	local h = c:match("^#(%x%x%x%x%x%x)$")
	if h then
		return h:upper()
	end
	local r, g, b = c:match("^#(%x)(%x)(%x)$")
	if r then
		return (r .. r .. g .. g .. b .. b):upper()
	end
	return CSS_COLORS[c:lower()]
end

-- ░░ Small helpers ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░{{{1
local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function copy(t)
	local new = {}
	for k, v in pairs(t) do
		new[k] = v
	end
	return new
end

local TRUE_WORDS = { ["true"] = true, yes = true, on = true, ["1"] = true }
local function as_bool(v)
	if type(v) == "boolean" then
		return v
	end
	return TRUE_WORDS[stringify(v):lower()] or false
end

--- Is this code point part of a word (letter or digit)?
local function is_word(cp)
	if not cp then
		return false
	end
	if cp < 128 then
		return (cp >= 48 and cp <= 57) or (cp >= 65 and cp <= 90) or (cp >= 97 and cp <= 122)
	end
	-- Latin-1 symbols, general punctuation/arrows/symbols, CJK punctuation
	if cp < 0xC0 or cp == 0xD7 or cp == 0xF7 then
		return false
	end
	if (cp >= 0x2000 and cp <= 0x2BFF) or (cp >= 0x3000 and cp <= 0x303F) then
		return false
	end
	return true
end

--- Code point of the character ending right before byte `s`
local function char_before(text, s)
	local i = s - 1
	if i < 1 then
		return nil
	end
	while i > 1 and text:byte(i) >= 0x80 and text:byte(i) < 0xC0 do
		i = i - 1
	end
	return utf8.codepoint(text, i)
end

--- Code point of the character starting at byte `s`
local function char_at(text, s)
	if s > #text then
		return nil
	end
	return utf8.codepoint(text, s)
end

-- ░░ Options ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░{{{1
--- Splits "a, k=v, k2='x, y'" into an ordered list of {key, value} items.
-- Bare words have no value (`{ "a" }`). Commas inside quotes are kept.
local function parse_opts(s)
	local items, buf, quote = {}, {}, nil
	local function flush()
		local item = trim(table.concat(buf))
		buf = {}
		if item == "" then
			return
		end
		local k, v = item:match("^([^=]-)%s*=%s*(.*)$")
		if k and k ~= "" then
			v = v:match('^"(.*)"$') or v:match("^'(.*)'$") or v
			table.insert(items, { k, v })
		else
			table.insert(items, { item })
		end
	end
	for ch in s:gmatch(".") do
		if quote then
			if ch == quote then
				quote = nil
			end
			table.insert(buf, ch)
		elseif ch == '"' or ch == "'" then
			quote = ch
			table.insert(buf, ch)
		elseif ch == "," then
			flush()
		else
			table.insert(buf, ch)
		end
	end
	flush()
	return items
end

--- Reads "(...)" starting at byte `p` of the Str at position `i`.
-- The options may continue over the following Str/Space elements.
-- @return options string, next element index, next byte offset (or nil)
local function read_opts(list, i, p)
	if list[i].text:sub(p, p) ~= "(" then
		return nil
	end
	local depth, buf = 0, {}
	for k = i, #list do
		local el = list[k]
		if el.t == "Str" then
			local text = el.text
			for s = (k == i) and p or 1, #text do
				local ch = text:sub(s, s)
				if ch == "(" then
					depth = depth + 1
					if depth > 1 then
						table.insert(buf, ch)
					end
				elseif ch == ")" then
					depth = depth - 1
					if depth == 0 then
						return trim(table.concat(buf)), k, s + 1
					end
					table.insert(buf, ch)
				else
					table.insert(buf, ch)
				end
			end
		elseif el.t == "Space" or el.t == "SoftBreak" then
			table.insert(buf, " ")
		else
			return nil
		end
	end
	return nil
end

-- ░░ Metadata ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░{{{1
local KEY_ALIASES = {
	left = { "left", "pre", "before", "open" },
	right = { "right", "pos", "post", "after", "close" },
	command = { "command", "cmd" },
	class = { "class" },
	opts = { "opts", "opt", "options" },
	content = { "content", "contents", "val", "arg" },
	exact = { "exact", "single", "one", "join", "contiguous" },
	color = { "color", "fg" },
	bg = { "bg", "background" },
	bold = { "bold" },
	italic = { "italic" },
	underline = { "underline" },
	strike = { "strike" },
	code = { "code" },
	disable = { "disable", "disabled", "off" },
}
local CANONICAL = {}
for name, aliases in pairs(KEY_ALIASES) do
	for _, alias in ipairs(aliases) do
		CANONICAL[alias] = name
	end
end
local BOOLEAN_KEYS =
	{ exact = true, bold = true, italic = true, underline = true, strike = true, code = true, disable = true }

-- Format blocks: a rule may hold a map named after an output format; its keys
-- replace those of the rule when rendering to that format.
--   latex, html, typst, docx : output families (see KIND)
--   beamer, revealjs         : one writer only, applied after its family
local FORMAT_KEYS = { latex = true, html = true, typst = true, docx = true, beamer = true, revealjs = true }
-- Delimiters and matching are the same in every format
local NOT_IN_BLOCK = { left = true, right = true, exact = true }

local function is_map(v)
	return type(v) == "table" and pandoc.utils.type(v) == "table"
end

--- Format blocks that apply to the current output, least specific first.
local function active_blocks()
	local names = { KIND }
	for name in pairs(FORMAT_KEYS) do
		if name ~= KIND and FORMAT == name then
			names[#names + 1] = name
		end
	end
	return names
end

--- Turns one metadata definition into a rule table (or nil if invalid).
local function read_rule(def, n)
	if type(def) ~= "table" or pandoc.utils.type(def) == "Inlines" then
		warn(("rule #%d is not a map of keys (left, right, ...); ignored"):format(n))
		return nil
	end
	local rule = { n = n }
	--- Copies the keys of `map` into the rule. `block` is the name of the
	-- format block being read, nil for the rule itself.
	local function apply(map, block)
		local where = block and (" (in '" .. block .. "')") or ""
		for key, value in pairs(map) do
			local name = CANONICAL[key]
			if not block and FORMAT_KEYS[key] then
				if not is_map(value) then
					warn(("rule #%d: '%s' must be a map of rule keys; ignored"):format(n, key))
				end
			elseif not name then
				warn(("rule #%d: unknown key '%s' ignored%s"):format(n, tostring(key), where))
			elseif block and NOT_IN_BLOCK[name] then
				warn(("rule #%d: '%s' cannot change per format; ignored%s"):format(n, key, where))
			elseif BOOLEAN_KEYS[name] then
				rule[name] = as_bool(value)
			else
				-- Delimiters are parsed as markdown by pandoc, exactly like the
				-- document text, so "--" in both places becomes the same en-dash.
				rule[name] = stringify(value)
				if rule[name] == "" and (name == "left" or name == "right") then
					warn(
						("rule #%d: '%s' is empty once parsed as markdown; escape special characters, e.g. \"\\\\>\""):format(
							n,
							key
						)
					)
				end
			end
		end
	end
	apply(def)
	for _, block in ipairs(active_blocks()) do
		if is_map(def[block]) then
			apply(def[block], block)
		end
	end
	if not rule.left or rule.left == "" then
		warn(("rule #%d has no 'left' delimiter; ignored"):format(n))
		return nil
	end
	if not rule.right or rule.right == "" then
		rule.right = rule.left
	end
	for _, key in ipairs({ "command", "class", "opts", "color", "bg" }) do
		if rule[key] == "" then
			rule[key] = nil
		end
	end
	return rule
end

-- Built-in rules, active unless the document sets `flexspan-defaults: false`.
-- They are written as YAML and read like document metadata, so delimiters go
-- through the same markdown parsing as rules written by the user.
local DEFAULTS_YAML = [[
---
flexspan:
  - left: "!!"            # !!warning!!          red, bold
    color: red
    bold: true
  - left: "=="            # ==highlight==        yellow background
    bg: yellow
  - left: "%["            # %[ls -la]            inline code
    right: "]"
    code: true
  - left: "-="            # -=text=-(blue)       style given as options
    right: "=-"
  - left: "-="            # -=text=-r            shortcuts: bold + colour
    right: "=-r"
    opts: "red, bold"
  - left: "-="
    right: "=-g"
    opts: "green, bold"
  - left: "-="
    right: "=-b"
    opts: "blue, bold"
  - left: "-="
    right: "=-c"
    opts: "aqua, bold"
  - left: "-="
    right: "=-p"
    opts: "purple, bold"
  - left: "-="
    right: "=-o"
    opts: "orange, bold"
  - left: "+-"            # +-underline-+
    right: "-+"
    underline: true
  - left: "!-"            # !-strike-out-!
    right: "-!"
    strike: true
    color: gray
  - left: "(("            # ((note))             class "note", blue italic
    right: "))"
    class: note
    color: "#1e90ff"
    italic: true
---
]]

--- The built-in rules as a list of metadata maps.
local function default_defs()
	local ok, doc = pcall(pandoc.read, DEFAULTS_YAML, "markdown")
	if not ok or not doc.meta[META_NAME] then
		warn("could not read the built-in rules; only the document rules are used")
		return {}
	end
	return doc.meta[META_NAME]
end

local function read_meta(meta)
	-- Layers, least specific first: built-in rules, then the metadata list.
	-- Quarto puts a format's rules (e.g. from unb-slides) before those of the
	-- project and the document, so the document has the last word.
	local layers = {}
	local use_defaults = meta[META_NAME .. "-defaults"]
	if use_defaults == nil or as_bool(use_defaults) then
		table.insert(layers, { defs = default_defs(), builtin = true })
	end
	local defs = meta[META_NAME]
	if defs then
		-- A single rule written without the leading dash
		if pandoc.utils.type(defs) ~= "List" then
			defs = { defs }
		end
		table.insert(layers, { defs = defs })
	end

	-- A rule with the same delimiters as an earlier one replaces it; with
	-- `disable: true` it removes it.
	local by_id, order = {}, {}
	local seq = 0
	for _, layer in ipairs(layers) do
		for n, def in ipairs(layer.defs) do
			local rule = read_rule(def, n)
			if rule then
				seq = seq + 1
				local id = rule.left .. "\0" .. rule.right
				if not by_id[id] then
					table.insert(order, id)
				end
				if rule.disable then
					by_id[id] = false
				else
					rule.n = seq
					rule.builtin = layer.builtin
					by_id[id] = rule
				end
			end
		end
	end

	local tokens, groups = {}, {}
	for _, id in ipairs(order) do
		local rule = by_id[id]
		if rule then
			local n = rule.n
			if rule.command then
				COMMANDS[rule.command] = true
			end
			if rule.exact then
				table.insert(tokens, { text = rule.left .. rule.right, exact = rule, n = n })
			else
				-- Rules sharing a left delimiter are tried together
				local group = groups[rule.left]
				if not group then
					group = { text = rule.left, rules = {}, n = n }
					groups[rule.left] = group
					table.insert(tokens, group)
				end
				table.insert(group.rules, rule)
			end
		end
	end

	-- Longer delimiters win over shorter ones ("---" before "--")
	for _, group in pairs(groups) do
		table.sort(group.rules, function(a, b)
			if #a.right ~= #b.right then
				return #a.right > #b.right
			end
			return a.n < b.n
		end)
	end
	table.sort(tokens, function(a, b)
		if #a.text ~= #b.text then
			return #a.text > #b.text
		end
		return a.n < b.n
	end)
	for _, token in ipairs(tokens) do
		local byte = token.text:byte(1)
		FIRST[byte] = FIRST[byte] or {}
		table.insert(FIRST[byte], token)
	end
	HAS_RULES = #tokens > 0
end

-- ░░ Format specific output ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░{{{1
local function xml_escape(s)
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

--- A Word run carrying all the formatting of the current context.
-- Word has no "coloured span": the colour must be set on every run, together
-- with the bold/italic/... inherited from the enclosing elements.
local function docx_run(ctx, text)
	local p = {}
	if ctx.rstyle then
		p[#p + 1] = '<w:rStyle w:val="' .. ctx.rstyle .. '"/>'
	end
	if ctx.bold then
		p[#p + 1] = "<w:b/><w:bCs/>"
	end
	if ctx.italic then
		p[#p + 1] = "<w:i/><w:iCs/>"
	end
	if ctx.smallcaps then
		p[#p + 1] = "<w:smallCaps/>"
	end
	if ctx.strike then
		p[#p + 1] = "<w:strike/>"
	end
	if ctx.color then
		p[#p + 1] = '<w:color w:val="' .. ctx.color .. '"/>'
	end
	if ctx.underline then
		p[#p + 1] = '<w:u w:val="single"/>'
	end
	if ctx.bg then
		p[#p + 1] = '<w:shd w:val="clear" w:color="auto" w:fill="' .. ctx.bg .. '"/>'
	end
	if ctx.sup or ctx.sub then
		p[#p + 1] = '<w:vertAlign w:val="' .. (ctx.sup and "superscript" or "subscript") .. '"/>'
	end
	return pandoc.RawInline(
		"openxml",
		"<w:r><w:rPr>"
			.. table.concat(p)
			.. '</w:rPr><w:t xml:space="preserve">'
			.. xml_escape(text)
			.. "</w:t></w:r>"
	)
end

local function docx_color(c)
	local hex = color_hex(c)
	if not hex then
		warn(("colour '%s' is not a CSS name or #hex value; ignored in docx output"):format(c))
	end
	return hex
end

local function latex_color(c)
	local hex = color_hex(c)
	return hex and ("[HTML]{" .. hex .. "}") or ("{" .. c .. "}")
end

local function typst_color(c)
	local hex = color_hex(c)
	return hex and ('rgb("#' .. hex:lower() .. '")') or c
end

local function typst_string(s)
	return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

--- Surrounds a list of inlines with raw code of the output format
local function wrap(body, before, after)
	body:insert(1, pandoc.RawInline(KIND, before))
	body:insert(pandoc.RawInline(KIND, after))
	return body
end

--- Wraps inlines in a LaTeX command or Typst function call.
-- @param items ordered list of {key, value} / {word} options
-- @param raw_opts the options exactly as typed (LaTeX only, optional)
local function wrap_command(body, command, items, raw_opts)
	if KIND == "latex" then
		local opts = raw_opts
		if not opts then
			local parts = {}
			for _, item in ipairs(items) do
				parts[#parts + 1] = item[2] and (item[1] .. "=" .. item[2]) or item[1]
			end
			opts = table.concat(parts, ",")
		end
		local open = "\\" .. command .. (opts ~= "" and ("[" .. opts .. "]") or "") .. "{"
		return wrap(body, open, "}")
	end
	-- Typst: bare words are positional strings, key=value are named strings
	local positional, named = {}, {}
	for _, item in ipairs(items) do
		if item[2] then
			named[#named + 1] = item[1] .. ": " .. typst_string(item[2])
		else
			positional[#positional + 1] = typst_string(item[1])
		end
	end
	for _, arg in ipairs(named) do
		positional[#positional + 1] = arg
	end
	local args = #positional > 0 and ("(" .. table.concat(positional, ", ") .. ")") or ""
	-- The ";" stops Typst from reading a following "(" or "[" as more arguments
	return wrap(body, "#" .. command .. args .. "[", "];")
end

-- ░░ Scanning ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░{{{1
local process -- forward declaration

local STYLE_FLAGS = { bold = "bold", italic = "italic", underline = "underline", strike = "strike", code = "code" }

-- Pandoc's typography, undone inside `code` placeholders
local SMART_CHARS = {
	["“"] = '"',
	["”"] = '"',
	["‘"] = "'",
	["’"] = "'",
	["–"] = "--",
	["—"] = "---",
	["…"] = "...",
	["\u{a0}"] = " ",
}

--- The plain text of a list of inlines, as close as possible to what was typed.
-- Markdown is parsed before the filter runs, so markup such as *emphasis*
-- inside the placeholder is already gone; only the text is left.
local function code_text(content)
	local text = stringify(pandoc.Inlines(content))
	return (text:gsub(utf8.charpattern, SMART_CHARS))
end
local STYLE_KEYS = { color = "color", fg = "color", bg = "bg", background = "bg" }

--- Builds the output for one matched placeholder.
-- @param rule the rule that matched
-- @param content pandoc.List of the enclosed inlines (delimiters removed)
-- @param inline_opts options typed after the closing delimiter, or nil
-- @param ctx formatting context of the enclosing elements
-- @return pandoc.List of inlines
local function render(rule, content, inline_opts, ctx)
	local raw_opts = inline_opts
	if not raw_opts or raw_opts == "" then
		raw_opts = rule.opts
	end
	local items = raw_opts and parse_opts(raw_opts) or {}

	local style = {
		color = rule.color,
		bg = rule.bg,
		bold = rule.bold,
		italic = rule.italic,
		underline = rule.underline,
		strike = rule.strike,
		code = rule.code,
	}
	local attrs = {}
	if rule.command then
		-- Options belong to the command
		for _, item in ipairs(items) do
			attrs[#attrs + 1] = { item[1], item[2] or "" }
		end
	else
		-- Options are style options; a bare word is the text colour
		for _, item in ipairs(items) do
			local key, value = item[1], item[2]
			local lower = key:lower()
			if value == nil then
				if STYLE_FLAGS[lower] then
					style[STYLE_FLAGS[lower]] = true
				else
					style.color = key
				end
			elseif STYLE_KEYS[lower] then
				style[STYLE_KEYS[lower]] = value
			elseif STYLE_FLAGS[lower] then
				style[STYLE_FLAGS[lower]] = as_bool(value)
			else
				attrs[#attrs + 1] = { key, value }
			end
		end
	end

	if rule.content then
		content = List({})
		if rule.content ~= "" then
			content:insert(pandoc.Str(rule.content))
		end
	end

	-- bold/italic/underline/strike/code use pandoc's own elements: every format knows them
	if style.code then
		content = List({ pandoc.Code(code_text(content)) })
	end
	local body = content
	if style.strike then
		body = List({ pandoc.Strikeout(body) })
	end
	if style.underline then
		body = List({ pandoc.Underline(body) })
	end
	if style.italic then
		body = List({ pandoc.Emph(body) })
	end
	if style.bold then
		body = List({ pandoc.Strong(body) })
	end

	local inner_ctx = ctx
	if KIND == "docx" then
		local color = style.color and docx_color(style.color)
		local bg = style.bg and docx_color(style.bg)
		if color or bg then
			inner_ctx = copy(ctx)
			inner_ctx.styled = true
			inner_ctx.color = color or ctx.color
			inner_ctx.bg = bg or ctx.bg
		end
	end
	-- Nested placeholders and nested formatting
	body = process(body, inner_ctx)

	local name = rule.class or rule.command

	if KIND == "latex" or KIND == "typst" then
		if style.color then
			if KIND == "latex" then
				wrap(body, "\\textcolor" .. latex_color(style.color) .. "{", "}")
			else
				wrap(body, "#text(fill: " .. typst_color(style.color) .. ")[", "];")
			end
		end
		if style.bg then
			if KIND == "latex" then
				wrap(body, "\\colorbox" .. latex_color(style.bg) .. "{", "}")
			else
				wrap(body, "#highlight(fill: " .. typst_color(style.bg) .. ")[", "];")
			end
		end
		if rule.command then
			return wrap_command(body, rule.command, items, raw_opts)
		elseif rule.class then
			return List({ pandoc.Span(body, pandoc.Attr("", { rule.class })) })
		end
		return body
	end

	if KIND == "docx" then
		if name then
			-- Character style: define it in the reference document to style it
			return List({ pandoc.Span(body, pandoc.Attr("", { name }, { { "custom-style", name } })) })
		end
		return body
	end

	-- HTML and all other formats
	local css = {}
	if style.color then
		css[#css + 1] = "color: " .. style.color
	end
	if style.bg then
		css[#css + 1] = "background-color: " .. style.bg
	end
	if #css > 0 then
		table.insert(attrs, 1, { "style", table.concat(css, "; ") .. ";" })
	end
	if name or #attrs > 0 then
		return List({ pandoc.Span(body, pandoc.Attr("", name and { name } or {}, attrs)) })
	end
	return body
end

--- Looks for the closing delimiter of any rule of `group`, starting at byte
-- `from` of element `i`. The nearest one wins; at the same place the longest.
-- @return element index, first byte, last byte, rule (or nil)
local function find_close(list, i, from, group)
	for j = i, #list do
		local el = list[j]
		if el.t == "Str" then
			local text = el.text
			for s = (j == i) and from or 1, #text do
				for _, rule in ipairs(group.rules) do
					local e = s + #rule.right - 1
					if text:sub(s, e) == rule.right and not is_word(char_at(text, e + 1)) then
						return j, s, e, rule
					end
				end
			end
		end
	end
	return nil
end

--- Tries to match a placeholder starting at byte `s` of the Str at index `i`.
-- @return table {rule, content, opts, next_i, next_p} or nil
local function match_at(list, i, s)
	local text = list[i].text
	local tokens = FIRST[text:byte(s)]
	if not tokens or is_word(char_before(text, s)) then
		return nil
	end
	-- An exact rule and a regular rule may both match here ("====" against
	-- "===" ... "==="): the one covering more text wins.
	local exact = nil
	for _, token in ipairs(tokens) do
		local e = s + #token.text - 1
		if text:sub(s, e) == token.text then
			if token.exact then
				if not exact and not is_word(char_at(text, e + 1)) then
					local opts, ni, np = read_opts(list, i, e + 1)
					exact = {
						rule = token.exact,
						content = List({}),
						opts = opts,
						next_i = ni or i,
						next_p = np or (e + 1),
					}
				end
			else
				local j, cs, ce, rule = find_close(list, i, e + 1, token)
				if j then
					local content = List({})
					if j == i then
						if cs > e + 1 then
							content:insert(pandoc.Str(text:sub(e + 1, cs - 1)))
						end
					else
						if e < #text then
							content:insert(pandoc.Str(text:sub(e + 1)))
						end
						for k = i + 1, j - 1 do
							content:insert(list[k])
						end
						if cs > 1 then
							content:insert(pandoc.Str(list[j].text:sub(1, cs - 1)))
						end
					end
					local opts, ni, np = read_opts(list, j, ce + 1)
					local m = {
						rule = rule,
						content = content,
						opts = opts,
						next_i = ni or j,
						next_p = np or (ce + 1),
					}
					if exact and (m.next_i < exact.next_i or (m.next_i == exact.next_i and m.next_p <= exact.next_p)) then
						return exact
					end
					return m
				end
			end
		end
	end
	return exact
end

-- Inline elements whose content is scanned, and the formatting they add
local CONTAINERS = {
	Emph = "italic",
	Strong = "bold",
	Underline = "underline",
	Strikeout = "strike",
	SmallCaps = "smallcaps",
	Superscript = "sup",
	Subscript = "sub",
	Quoted = false,
	Cite = false,
	Link = false,
	Span = false,
}

local walk_blocks -- forward declaration

--- Scans a list of inlines, replacing placeholders, and descends into nested
-- inline elements. `ctx` carries the formatting of the enclosing elements;
-- it is only needed for docx, where coloured text is written as raw runs.
process = function(list, ctx)
	local out = List({})
	local styled = KIND == "docx" and ctx.styled
	local pending = nil -- text of the docx run being built

	local function flush()
		if pending then
			out:insert(docx_run(ctx, pending))
			pending = nil
		end
	end

	local function put_text(s)
		if styled then
			pending = (pending or "") .. s
		else
			out:insert(pandoc.Str(s))
		end
	end

	local function put(el)
		local t = el.t
		if styled and (t == "Space" or t == "SoftBreak") then
			pending = (pending or "") .. " "
			return
		end
		flush()
		if styled and t == "LineBreak" then
			out:insert(pandoc.RawInline("openxml", "<w:r><w:br/></w:r>"))
		elseif styled and t == "Code" then
			local code_ctx = copy(ctx)
			code_ctx.rstyle = "VerbatimChar"
			out:insert(docx_run(code_ctx, el.text))
		elseif styled and t == "Quoted" then
			local single = el.quotetype == "SingleQuote"
			local quoted = List({ pandoc.Str(single and "‘" or "“") })
			quoted:extend(el.content)
			quoted:insert(pandoc.Str(single and "’" or "”"))
			out:extend(process(quoted, ctx))
		elseif t == "Note" then
			el.content = walk_blocks(el.content)
			out:insert(el)
		elseif CONTAINERS[t] ~= nil then
			if t == "Span" and el.classes:includes(SKIP_CLASS) then
				out:insert(el)
				return
			end
			local child_ctx = ctx
			local flag = CONTAINERS[t]
			if flag then
				child_ctx = copy(ctx)
				child_ctx[flag] = true
			elseif KIND == "docx" and t == "Link" then
				child_ctx = copy(ctx)
				child_ctx.rstyle = "Hyperlink"
			end
			el.content = process(el.content, child_ctx)
			-- Hand-written span whose class is a command: [text]{.command opt=1}
			local class = t == "Span" and el.classes[1]
			if class and COMMANDS[class] and (KIND == "latex" or KIND == "typst") then
				local items = {}
				for key, value in pairs(el.attributes) do
					items[#items + 1] = value ~= "" and { key, value } or { key }
				end
				out:extend(wrap_command(el.content, class, items))
			else
				if class and COMMANDS[class] and KIND == "docx" and not el.attributes["custom-style"] then
					el.attributes["custom-style"] = class
				end
				out:insert(el)
			end
		else
			out:insert(el)
		end
	end

	local i, from = 1, 1 -- current element, first byte of its text not yet written
	while i <= #list do
		local el = list[i]
		if el.t ~= "Str" then
			put(el)
			i, from = i + 1, 1
		else
			local text = el.text
			local m, s = nil, from
			while s <= #text do
				m = match_at(list, i, s)
				if m then
					break
				end
				s = s + 1
			end
			if m then
				if s > from then
					put_text(text:sub(from, s - 1))
				end
				flush()
				out:extend(render(m.rule, m.content, m.opts, ctx))
				i, from = m.next_i, m.next_p
			else
				if from <= #text then
					put_text(text:sub(from))
				end
				i, from = i + 1, 1
			end
		end
	end
	flush()
	return out
end

walk_blocks = function(blocks)
	return blocks:walk({
		traverse = "topdown",
		-- `false` stops pandoc from descending: process() does it itself
		Inlines = function(inlines)
			return process(inlines, {}), false
		end,
		Div = function(div)
			if div.classes:includes(SKIP_CLASS) then
				return div, false
			end
		end,
	})
end

-- ░░ Entry point ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░{{{1
return {
	{
		Pandoc = function(doc)
			read_meta(doc.meta)
			if not HAS_RULES then
				return nil
			end
			doc.blocks = walk_blocks(doc.blocks)
			return doc
		end,
	},
}
