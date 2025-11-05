--- flexspan-AST.lua
-- This Pandoc Lua filter extends Markdown with custom inline span elements,
-- allowing users to define arbitrary delimiters (e.g., `[[...]]`, `{{...}}`)
-- that will be transformed into `pandoc.Span` elements with specific classes
-- and attributes. This enables flexible custom styling and semantic tagging
-- directly within your Markdown source.
--
-- This filter finds text enclosed in custom placeholders (e.g., [[text]])
--          and converts it to a Span. It also supports parsing optional
--          arguments (e.g., [[text]](args)) associated with these placeholders.
--
-- In the case of latex/beamer output, the span is transformed into a LaTeX command.
-- The definitions for placeholders and their corresponding span classes (LaTeX commands) are configured via the document's metadata.
-- --- ## Example Metadata
---
--- ```yaml
--- ---
--- title: My Document
--- flexspan:
---   - left: "[["
---     right: "]]"
---     command: "highlight"
---     options: "color=red"
---   - left: "{{"
---     right: "}}"
---     command: "tooltip"
---   - left: "~~"
---     right: "~~"
---     command: "strikethrough"
---     exact: true
---   - left: "(("
---     right: "))"
---     command: "custom-content-box"
---     content: "Important Note!"
--- ---
--- ```
---
--- ## Metadata Object Keys
---
--- Each object in the `flexspan` list supports the following keys:
---
--- * **`left` (Required, string):**
---     The opening delimiter for the custom span. This will be escaped
---     internally, so you can use characters that have special meaning
---     in Lua patterns (e.g., `[`, `(`, `*`) directly.
---     *Example:* `left: "[["`, `left: "{{"`
---
--- * **`right` (Required, string):**
---     The closing delimiter for the custom span. Similar to `left`,
---     it will be escaped internally.
---     *Example:* `right: "]]"`, `right: "}}"`
---
--- * **`command` (Required, string):**
---     The class name that will be assigned to the generated `pandoc.Span`
---     element. This class can then be targeted by CSS for styling.
---     *Example:* `command: "highlight"`, `command: "tooltip"`
---
--- * **`options` (Optional, string):**
---     A comma-separated string of default key-value pairs or single keys
---     to be added as attributes to the `pandoc.Span`. These apply if
---     no specific arguments are provided after the closing delimiter in
---     the Markdown.
---     *Example:* `options: "color=blue,background=lightblue"`
---     *Markdown:* `[[My Text]]` will get `color="blue"` and `background="lightblue"`.
---
--- * **`content` (Optional, string):**
---     If provided, this string will **override** any content found
---     between the `left` and `right` delimiters. Useful for creating
---     predefined "boxes" or labels.
---     *Example:* `content: "Important Note!"`
---     *Markdown:* `((Any text here is ignored))` will become
---     `<span class="custom-content-box">Important Note!</span>`.
---
--- * **`exact` (Optional, boolean):**
---     If `true`, the filter will look for an **exact and contiguous**
---     match of the `left` and `right` delimiters (e.g., `~~content~~`)
---     within a single `Str` element. This is useful for delimiters
---     that are part of regular words or don't typically enclose other
---     inline elements. When `exact: true`, the content between the
---     delimiters must be simple text, not complex inline structures.
---     *Example:* `exact: true` for `left: "~~"` and `right: "~~"`.
---
--- # Markdown Examples based on the above YAML
---
--- * `This is a [[highlighted]] word.`
---     -> `<span class="highlight" color="red">highlighted</span>`
--- * `A {{word with a (more info)}} tooltip.`
---     -> `<span class="tooltip">word with a (more info)</span>`
--- * `Strike ~~this~~ out.`
---     -> `<span class="strikethrough">this</span>`
--- * `((Some discarded text))`
---     -> `<span class="custom-content-box">Important Note!</span>`
--- * `You can also [[highlight something](bg=yellow)] specific.`
---     -> `<span class="highlight" bg="yellow">highlight something</span>`
---     (Note: inline arguments override `options` defaults.)
---
--
-- Author: Georgios Pappas Jr
--         Universidade de Brasília (UnB) - Brasil
-- Last modified: November, 2025
-- Version: 2.0.0
------------------------------------------------------------------

-- ░░░░░░░░░░░░░░░░░░░░░░░░░░░░┤ Start the code ├░░░░░░░░░░░░░░░░░░░░░░░░░░░░

-- For debugging purposes
-- require("mobdebug").start()

-- The prefix to skip inline code
local SKIP_CLASS = "skipspan"

-- ┤ The filters that are defined in the Metadata ├░░░░░░░░░░░░░░░░░░░░░░░
local filters = {}
-- ┤ The valid commands inside the filters        ├░░░░░░░░░░░░░░░░░░░░░░░
local _commands = {}

-- ┅┅┅┅┅┅┅┅┤ The name of the metadata key to define the span mappings ├┅┅┅┅┅┅┅
local META_NAME = "flexspan"

-- ░░………………………………………………………………………………………………General lua functions {{{1

local tostring = pandoc.utils.stringify

-- ░░…………………………………………………………………………………………………………………………………………░ escape_pattern {{{2
-- Helper function to escape characters that are special in Lua patterns.
-- This is necessary because the user-defined delimiters might contain
-- characters like '[', '(', '*', etc.
local function escape_pattern(s)
	return s:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
end

--- Escapes special LaTeX characters in a string, mimicking Pandoc's default behavior
-- for LaTeX output.
-- @param s The input string to escape.
-- @return The string with special LaTeX characters replaced by their corresponding commands.
function escape_latex_special_chars(s)
	local escape_map = {
		["#"] = "\\#",
		["$"] = "\\$",
		["%"] = "\\%",
		["&"] = "\\&",
		["~"] = "\\textasciitilde{}",
		["_"] = "\\_",
		["^"] = "\\textasciicircum{}",
		["{"] = "\\{",
		["}"] = "\\}",
		["\\"] = "\\textbackslash{}",
		["|"] = "\\textbar{}",
		["<"] = "\\textless",
		[">"] = "\\textgreater",
	}

	-- The pattern captures any of the characters present as keys in the escape_map
	return s:gsub("[#$%%&~_^{}\\\\|<>]", escape_map)
end

-- ░░………………………………………………………………………………………………………………………………………░ table_intersect {{{2
local function table_intersect(table1, table2)
	-- Check for the first key in the second list that exists in the lookup table
	for _, key in ipairs(table2) do
		if table1[key] then
			return key -- Return the first intersection key found
		end
	end

	return nil -- Return nil if no intersection is found
end

-- ░░…………………………………………………………………………………………………………………………………………………………………░ slice {{{2
--- Splits a pandoc.List based on start and end indexes.
-- Takes a table or List and extracts the element.
-- @param lst The original table or List.
-- @param start_idx The start index.
-- @param end_idx The end index.
-- @return a pandoc.List containing the elements from start_idx to end_idx.
local function slice(lst, start_idx, end_idx)
	-- Handle negative indices (count from end) and default values
	local n = #lst
	start_idx = start_idx or 1
	-- A special case. If start >#length return nil
	-- flagging that the operation is not possible
	if start_idx and start_idx > n then
		return nil
	end
	end_idx = end_idx or n

	-- Convert negative indices to positive
	if start_idx < 0 then
		start_idx = n + start_idx + 1
	end
	if end_idx < 0 then
		end_idx = n + end_idx + 1
	end

	-- Clamp indices to valid range
	start_idx = math.max(1, math.min(start_idx, n))

	-- end_idx = math.max(1, math.min(end_idx, n))

	-- Return empty list if indices are invalid
	if start_idx > end_idx then
		return pandoc.List:new()
	end

	-- Create sliced list
	local sliced = pandoc.List:new()
	for i = start_idx, end_idx do
		sliced:insert(lst[i])
	end

	return sliced
end

-- ░░………………………………………………………………………………………………Pattern Matching {{{1

-- ░░………………………………………………………………………………………………………░ replace_unquoted_separators {{{2
--- Replaces specified separator characters with a given delimiter in parts of a string
-- that are *not* enclosed in double or single quotes. Quoted sections are preserved.
-- Search for chunks that are NOT quoted strings, and replace separators within them.
--
-- This function iterates through the input string, identifying and skipping over
-- quoted segments (enclosed in "" or ''). In the unquoted segments, it replaces
-- all occurrences of `sep_chars` with the `delimiter`.
--
-- @param s The input string to process.
-- @param delimiter The string to replace the `sep_chars` with in unquoted segments.
-- @param sep_chars A Lua pattern (string) representing the separator characters to be replaced.
--                  For example, `"[ ,;]+"` to replace spaces, commas, or semicolons.
-- @return A new string with separators replaced in unquoted sections, and quoted sections preserved.
local function replace_unquoted_separators(s, delimiter, sep_chars)
	local last_end = 1
	local new_str = {}
	-- Pattern to find quoted strings or balanced parentheses.
	-- This pattern finds any quoted text OR a standard non-quoted component.
	-- This is simplified for typical KV attributes (no balanced parentheses needed here, just quotes)
	-- Iterate through the string, finding quoted blocks first.
	for start_q, end_q, quoted_match in s:gmatch("()()%b\"\"|()()%b''") do
		-- Check the segment BEFORE the quoted match for unquoted separators
		local unquoted_segment = s:sub(last_end, start_q - 1)
		-- Replace all separators in the unquoted segment with the delimiter
		local processed_segment = unquoted_segment:gsub(sep_chars, delimiter)
		table.insert(new_str, processed_segment)
		-- Insert the quoted match untouched
		table.insert(new_str, quoted_match)
		last_end = end_q + 1
	end
	-- Process the final segment after the last quoted match (or the whole string if no quotes)
	local last_segment = s:sub(last_end, #s)
	local processed_last_segment = last_segment:gsub(sep_chars, delimiter)
	table.insert(new_str, processed_last_segment)

	return table.concat(new_str)
end

-- ▶………………………░ Split Key Value Pairs (Using %b pattern) {{{2 ░
-- Splits a comma or tab separated list of key-value pairs, respecting quotes
-- using the balanced-pattern feature of Lua.
-- @param input_str The string containing key-value pairs (e.g., 'key=val, "k,2"="v,2"')
-- @param separators A string containing all possible separators (e.g., ", \t").
-- @return A string containing the split components separated by spaces and the corresponding table with key=val entries.
local function split_key_value_pairs(input_str, separators)
	if not input_str or #input_str == 0 then
		return nil, {}
	end
	-- Mock character for safely replacing the separators not in quotes
	local delimiter = "\0" -- Use null character as a guaranteed safe delimiter
	local sep_chars = "[" .. separators .. "]"

	-- Step 1: Replace unquoted separators with a safe delimiter (\0)
	local delimited_str = replace_unquoted_separators(input_str, delimiter, sep_chars)

	-- Step 2: Split the delimited string by the delimiter and clean up components
	-- Using string.gmatch to grab chunks separated by the delimiter
	local final_result = {}
	for component in delimited_str:gmatch("([^\0]*)") do
		-- Trim and clean up the component (e.g., remove leading/trailing spaces around the delimiter)
		local trimmed_component = component:gsub("^%s*(.-)%s*$", "%1")
		if #trimmed_component > 0 then
			table.insert(final_result, trimmed_component)
		end
	end

	-- Splitting at the equal sign
	-- key1=val1,key2=vol2 --> {key1=val1,key2=val2}
	local kv_table = {}
	local kv_count = 0
	-- First try is to have a list of key=val pairs. The presence of '=' is the key
	for i = 1, #final_result do
		for key, val in final_result[i]:gmatch("(.-)=(.*)$") do
			kv_table[string.format("%s", key)] = val
			kv_count = kv_count + 1
		end
	end

	-- In case of having only keys
	if kv_count == 0 then
		-- ┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┤ Fill the table with the keys and no values ├┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅
		for i = 1, #final_result do
			kv_table[string.format("%s", final_result[i])] = ""
		end
	end
	-- Return components joined by a single space
	return table.concat(final_result, " "), kv_table
end

--find_pattern_in_str{{{2
-- Searches for a pattern within a string with flexible matching options.
-- Note: The `pattern` parameter is expected to be a plain string or already escaped
-- if it contains Lua magic characters, as `escape_pattern` is commented out.
--
-- @param s The string to search within.
-- @param pattern The pattern string to find.
-- @param is_right A boolean flag that finds the string from the begining (left) or end (right)
--    In the rightmost part (is_right = true) the pattern can followed by balanced parentheses `()`,
--                 If true, it first attempts to find the pattern followed by balanced parentheses `()`,
--                 then attempts to find the pattern at the end of the string.
--                 If false, it performs a standard `string.find` from the beginning of the string.
-- @param is_exact A boolean flag that treats the match as exact, i.e. the input s is the same as the pattern. This avoids partial matches that can confound the matching process
-- @return If a match is found:
--   - `start_pos` (number): The starting index of the match in `s`.
--   - `end_pos` (number): The ending index of the match in `s`.
--   - `args` (string or nil): If the pattern was followed by `()`, this contains the content inside the parentheses. Otherwise, it's `nil`.
-- @return If no match is found, returns `nil`.
local function find_pattern_in_str(s, pattern, is_right, is_exact)
	-- In an exact match, the pattern should be matched from its begining
	if is_exact then
		pattern = "^" .. pattern
		-- Exact match was found
		if s == pattern then
			return 1, #s, nil
		elseif s:find("^" .. pattern .. "%s*(%b())") then
			local start_pos, end_pos, args = s:find(pattern .. "%s*(%b())")
			return start_pos, end_pos, args and args:sub(2, -2) or ""
		end
	end
	-- local pattern = escape_pattern(pattern)
	if is_right then
		-- Find pattern followed by ()
		local start_pos, end_pos, args = s:find(pattern .. "%s*(%b())")
		-- If found, then we have options
		if start_pos then
			return start_pos, end_pos, args and args:sub(2, -2) or ""
		end
		-- Find pattern at the end
		local start_pos_end, end_pos_end = s:find(pattern .. "$")
		if start_pos_end then
			return start_pos_end, end_pos_end, nil
		end
	else
		return s:find(pattern, 1)
	end
	return nil
end

-- ░░………………………………………………………………………………………………AST inspection ░{{{1
--
--[[find_non_matching_ranges{{{2
 -   ▄┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈▄
 -   ░ Scans a list of inlines and finds contiguous ranges of       ░
 -   ░ elements whose types are not in a given set of types to skip ░
 -   ▀┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈▀
]]
-- @param inlines A pandoc.List of inline elements.
-- @param start_idx The index to start scanning from.
-- @param skip_types A table of inline element types to skip (e.g., {"Code", "RawInline"}).
-- @return A table of tables, where each inner table is a range {start=s, end=e}.
local function find_non_matching_ranges(inlines, start_idx, skip_types)
	local ranges = {}
	local current_pos = start_idx or 1
	local n = #inlines

	-- For efficient lookup, convert the list of types to a set
	local skip_set = {}
	for _, v in ipairs(skip_types) do
		skip_set[v] = true
	end

	while current_pos <= n do
		-- Skip elements whose types are in skip_set
		while current_pos <= n and skip_set[inlines[current_pos].t] do
			current_pos = current_pos + 1
		end

		-- Found the start of a non-matching range
		if current_pos <= n then
			local range_start = current_pos
			-- Find the end of the range
			while current_pos <= n and not skip_set[inlines[current_pos].t] do
				current_pos = current_pos + 1
			end
			local range_end = current_pos - 1
			table.insert(ranges, { start = range_start, last = range_end })
		end
	end
	if #ranges == 0 then
		ranges = { { start = 1, last = #inlines } }
	end

	return ranges
end

-- ▶………………………░ get_attributes Extract and Format pandoc Attributes {{{2 ░………………………
-- Extracts all non-class, non-identifier attributes and formats them as a
-- comma-separated list of key=value pairs.
-- @param attrs The pandoc.Attr object (spanEl.attr)
-- @return A string containing key=value pairs separated by commas.
local function get_attributes(attrs, separator)
	separator = separator or ","
	local attr_list = {}
	local attributes = attrs.attributes or {}

	for key, value in pairs(attributes) do
		-- Format as key=value and append to the list
		if value and #value > 0 then
			table.insert(attr_list, string.format("%s=%s", key, tostring(value)))
		else
			table.insert(attr_list, string.format("%s", key))
		end
	end

	return table.concat(attr_list, separator)
end

-- ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░┤ AST manipulation {{{1
--
-- ▶………………………░ Wraps a slice of pandoc inlines in a pandoc.Span {{{2
-- @param inlines A pandoc.List of inline elements.
-- @param start_idx The starting index of the slice to wrap.
-- @param end_idx The ending index of the slice to wrap.
-- @param filter A table containing the filter class/command and contents
-- @param attributes A table of attributes for the new Span.
-- @return A new pandoc.List of inlines with the specified elements wrapped in a Span.
local function wrap_inlines_span(inlines, start_idx, end_idx, filter, attributes)
	attributes = attributes or {}

	local span_class = filter.command
	local span_contents = filter.content

	local before_slice = slice(inlines, 1, start_idx - 1)
	-- local before_slice = slice(inlines, 1, start_idx - 1)
	local inside_span = slice(inlines, start_idx, end_idx)
	local after_slice = slice(inlines, end_idx + 1, #inlines)
	-- local after_slice = slice(inlines, end_idx + 1, #inlines)

	-- 1. Create the new Span element
	if type(attributes) == "string" then
		local _, attr_table = split_key_value_pairs(attributes, ",")
		attributes = attr_table
	end
	-- Creating the attributes, id=string, classes={}, other attributes={}
	local pandoc_attr = pandoc.Attr("", { span_class }, attributes)
	-- Creating the span
	local span = pandoc.Span(inside_span, pandoc_attr)
	if span_contents then
		span = pandoc.Span(span_contents, pandoc_attr)
	end

	-- 2. Build the final result list by combining the three parts
	local result = before_slice

	-- Insert the single new Span element
	result:insert(span)

	-- Insert all elements from the after_slice list
	if after_slice then
		for _, el in ipairs(after_slice) do
			result:insert(el)
		end
	end

	return result
end

--- Finds a pattern within the Str elements of an inlines list.
-- @param inlines A pandoc.List of inline elements.
-- @param pattern The string pattern to search for.
-- @param is_right Boolean, if true, searches from the end of the string
-- @return If a match is found, returns:
--   - index of the Str element.
--   - captured arguments from inside () if any.
--   - the Str element itself.
--   - start position of the match within the string.
--   - end position of the match within the string.
-- @return If no match is found, returns nil.
local function find_pattern_in_inlines(inlines, pattern, start_idx, is_right, is_exact)
	start_idx = start_idx or 1
	-- Check if out of bounds
	if start_idx > #inlines then
		return nil
	end
	for i = start_idx, #inlines do
		-- for i, el in ipairs(merged_inlines) do
		local el = inlines[i]
		if el.t == "Str" then
			local start_pos, end_pos, opts = find_pattern_in_str(el.text, pattern, is_right, is_exact)
			if start_pos then
				return i, opts, start_pos, end_pos, el
			end
		end
	end
	return nil
end

--- Replaces matched placeholder patterns within a list of inline elements with a `pandoc.Span`.
-- This function is central to the flexspan filter's functionality. It identifies
-- user-defined opening and closing delimiters (e.g., `[[` and `]]`), extracts
-- their contained content and optional arguments, and transforms them into
-- a `pandoc.Span` element with specified classes and attributes.
--
-- @param inlines pandoc.List of pandoc.Inline elements: The current list of inline elements being processed.
-- @param filter table: Configuration for the specific placeholder, including `left`, `right`, `command`, and optional `options`, `content`, or `exact`.
-- @return pandoc.List: The potentially modified list of inline elements.
-- @return boolean: `true` if a replacement occurred, `false` otherwise.
local function replace_span(inlines, filter)
	local current_pos = 1
	-- ┅┅┅┅┅┅┅┅┅┅┅┅┅┤ Finding all the pattern matches in the inlines ├┅┅┅┅┅┅┅┅┅┅┅┅
	-- ░░░░░░┤ Iterating over the matches and performing the span changes ├░░░░░░
	while current_pos <= #inlines do
		local left_pos, left_match_pos
		local right_pos, right_match_pos
		local opts

		-- If the filter exact option is set, then the
		-- left and right placeholders are joined and the match is exact, without
		-- the possibility of a text inside. However, options are allowed after the
		-- patterns.
		-- left="-" right=":", then -: or -:(fg=red) are valid
		if filter.exact then
			local joined_placeholders = filter.left .. filter.right
			left_pos, opts, left_match_pos, left_match_end, _ =
				find_pattern_in_inlines(inlines, joined_placeholders, current_pos, true, true)

			-- In this case the placeholders were joined and left and right_pos are the same
			if left_pos then
				right_pos = left_pos
				left_match_pos = 1
				-- imposing a difference between, only to comply with the processing below and avoid
				-- this match being identified as to the left placeholder only
				right_match_pos = #filter.left + 1
			else
				return inlines, false
			end
		else --if not filter.exact then
			-- ┅┤ Trying to find the left pattern ├┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅
			left_pos, _, left_match_pos = find_pattern_in_inlines(inlines, filter.left, current_pos)
			if not left_pos then
				-- Return unmodified
				return inlines, false
			end

			-- ┅┤ Trying to find the right pattern ├┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅

			-- Special handling if the inlines are a single element in the inlines list
			if #inlines == 1 then
				-- Finding the right_match
				right_pos, opts, right_match_pos, _, _ = find_pattern_in_inlines(inlines, filter.right, left_pos, true)
				-- ┅┅┅┅┅┅┅┅┅┅┅┤ Skipping because the match is in the same position ├┅┅┅┅┅┅┅┅┅┅
				-- Avoids the problem of placeholders being the same text. If right_match_pos
				-- is equal to left_match_pos, the match occur in the opening placeholder, and there is no closing one
				if right_pos and left_match_pos >= right_match_pos then
					right_pos = nil
				end
			else
				right_pos, opts, right_match_pos = find_pattern_in_inlines(inlines, filter.right, left_pos, true)
				-- Matches of left and right positions are the same. Begin matching after the left_pos
				if left_pos == right_pos and left_match_pos == right_match_pos then
					right_pos, opts, right_match_pos =
						find_pattern_in_inlines(inlines, filter.right, left_pos + 1, true)
				end
			end
		end

		-- Found a match. Forward the iteration past the right position
		if left_pos and right_pos then
			current_pos = right_pos + 1
		else
			break
		end

		--[[
		-   ▄┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈▄
		-   ░ Found a match. Process it                                    ░
		-   ▀┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈▀
		]]
		if left_pos and right_pos then
			local end_pattern = "$" -- Regex to mark end of the line
			local attr_table
			if opts then
				end_pattern = "%s*(%b())"
			else
				-- Use the options defined in the metadata, in case no options provided
				-- it stil can be nil
				opts = filter.options
			end
			-- Getting the span attributes table
			_, attr_table = split_key_value_pairs(opts, ",")
			-- Handle special case of a single Str element containing the left and right placeholders
			local new_span
			local new_inlines = {}
			-- This is a special case, where the user discards the
			-- text inside the span and forces to use the provided content
			local filter_content = filter.content
			-- The left and right placeholders are in a single string
			if left_pos == right_pos then
				-- First remove the placeholders
				local txt = inlines[left_pos].text
				if filter_content then
					txt = txt:gsub("^" .. filter.left .. "(.-)" .. filter.right .. end_pattern, filter_content, 1)
				else
					txt = txt:gsub("^" .. filter.left .. "(.-)" .. filter.right .. end_pattern, "%1", 1)
				end
				inlines[left_pos].text = txt
				-- new_span = wrap_inlines_span(inlines, left_pos, right_pos, opts)
				-- Creating the attributes, id=string, classes={}, other attributes={}
				local pandoc_attr = pandoc.Attr("", { filter.command }, attr_table)
				new_span = pandoc.Span(inlines[left_pos], pandoc_attr)
				new_inlines = inlines
				new_inlines[left_pos] = new_span
				-- table.insert(new_inlines, left_pos, new_span)
			else
				-- Creating the span
				local txt = inlines[left_pos].text
				txt = txt:gsub("^" .. filter.left, "", 1)
				inlines[left_pos].text = txt
				txt = inlines[right_pos].text
				txt = txt:gsub(filter.right .. end_pattern, "", 1)
				inlines[right_pos].text = txt

				-- Now modifying the inlines to add the span between left and right pos
				new_inlines = wrap_inlines_span(inlines, left_pos, right_pos, filter, opts)
				-- new_inlines = splice_table(inlines, left_pos, right_pos)
				-- Inserting the span back
				-- table.insert(new_inlines, left_pos, new_span)
			end
			-- return new_inlines, true
			inlines = new_inlines
		end
	end

	return inlines, false
end

-- ░░………………………………………………………………………………………………░ AST modification {{{1

-- ▶……………………………………………………………………………………………………………………………………………………………………░ Meta {{{2
-- Reading the Metadata for setting the placeholders
-- flexspan:
--   - left: "[["
--     right: "]]"
--     command: "mycustombox"
--   - left: "<<"
--     right: ">>"
--     command: "anothercommand"
function Meta(meta)
	if not meta[META_NAME] then
		return
	end

	-- Some aliases that could be used in the metadata
	-- to describe the placeholders, command and options
	local left_aliases = { "left", "pre", "before" }
	local right_aliases = { "right", "pos", "after" }
	local command_aliases = { "command", "cmd", "class" }
	local opts_aliases = { "opts", "opt", "options" }
	local content_aliases = { "content", "val", "contents", "arg" }
	local exact_aliases = { "exact", "single", "one", "join", "contiguous" }

	for _, definition in ipairs(meta[META_NAME]) do
		-- Finding the first key in the definition that matches one of the left_aliases
		local left_key = table_intersect(definition, left_aliases)
		local right_key = table_intersect(definition, right_aliases)

		-- Set the left placeholder given the existent alias
		local left = definition[left_key] and pandoc.utils.stringify(definition[left_key])
		local right = definition[right_key] and pandoc.utils.stringify(definition[right_key])

		-- The right placeholder can be ommited. In this case, it will be the same as the left
		right = right or left

		-- The command (name of the span class or latex command)
		local command_key = table_intersect(definition, command_aliases)
		local command = definition[command_key] and pandoc.utils.stringify(definition[command_key])
		-- Options to be passed to the command. (not mandatory)
		local opts_key = table_intersect(definition, opts_aliases)
		local opts = definition[opts_key] and pandoc.utils.stringify(definition[opts_key])

		-- Contents to be passed to the command. Totally overcomes the span content
		local content_key = table_intersect(definition, content_aliases)
		local content = definition[content_key] and pandoc.utils.stringify(definition[content_key])
		-- Flag that indicates that the left/right match should be exact, and in a single Str
		local exact_key = table_intersect(definition, exact_aliases)
		local exact = definition[exact_key] and pandoc.utils.stringify(definition[exact_key])

		-- If the placeholders and command are set, then
		-- fill the filters table
		if left and right and command then
			left = escape_pattern(left)
			right = escape_pattern(right)
			-- left = escape_latex_special_chars(left)
			-- right = escape_latex_special_chars(right)

			table.insert(filters, {
				left = left, -- left placeholder
				right = right, -- right placeholder
				command = command, -- class name of the span. Transformed to latex command
				options = opts, -- Default options for the filter
				content = content, -- Default content. Overrides text between left and right placeholders
				exact = exact, -- Indicates that the match should occur exactly and in a single string
			})
			-- Table with valid commands. Latex substitution will take place for these commands
			table.insert(_commands, command)
		end
	end
	-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┫ Sort the table ┣━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
	-- Now we want to process first the filters that have exact matches
	-- After that we want to perform a descending sort of the left placeholder
	-- With these two sorts we process these filters before the others, trying to
	-- avoid that substrings in the placeholders match a lengthier pattern
	-- For example left="--" and left="---"
	-- The tag --- text --- would be recognized by both left placeholders. We want that
	-- the larger placeholder takes precedence

	-- Sort: exact=true first, then by length of left (descending)
	table.sort(filters, function(a, b)
		-- First criterion: exact=true comes first
		if a.exact and not b.exact then
			return true
		elseif not a.exact and b.exact then
			return false
		end

		-- Second criterion: longer left string comes first (descending length)
		if #a.left ~= #b.left then
			return #a.left > #b.left
		end

		-- Tertiary criterion (if lengths are equal): maintain original order
		-- Since table.sort isn't stable by default, we could add another criterion
		-- For example, alphabetical by left string
		return a.left < b.left
		-- -- Primary sort: exact=true first
		-- if a.exact ~= b.exact then
		-- 	return a.exact
		-- end
		--
		-- -- Secondary sort: longer left string first
		-- local len_a = #(a.left or "")
		-- local len_b = #(b.left or "")
		-- if len_a ~= len_b then
		-- 	return len_a > len_b
		-- end
	end)
	-- Transforming table to pandoc List
	_commands = pandoc.List(_commands)
end

-- ░░………………………………………………………………………………………………………………………………………░ process_inlines ░{{{2
-- AST transformation function that processes inlines, scanning for the
-- presence of the placeholders and substituting the matches by Span elements
-- The AST is transformed by adding the Span enclosing the match
local function process_inlines(inline)
	if #filters == 0 then
		print("*** NO PLACEHOLDERS DEFINED. Skipping")
		return nil
	end

	local inlines = inline.content

	--[[
	-   ▄┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈▄
	-   ░ Skip inline Code                                             ░
	-   ▀┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈▀
	]]
	local skipped_types = { "Code", "RawInline" }
	local included_positions = find_non_matching_ranges(inlines, 1, skipped_types)
	-- Checks if a element to skip is found
	local found_skipped = not (included_positions[1].start == 1 and included_positions[1].last == #inlines)
	-- ┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┤ Iterating over the filters ├┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅
	for _, filter in ipairs(filters) do
		local filter_name = filter.command
		if not filter_name then
			break
		end

		for _, pos in ipairs(included_positions) do
			-- -- ┅┤ Trying to find the left pattern ├┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅
			-- returns new inlines with the span added, if the left and right
			-- patterns were found
			inlines, modified = replace_span(inlines, filter)
		end
		-- Recalculating positions of skipped elements, since inlines were modified
		if found_skipped and modified then
			included_positions = find_non_matching_ranges(inlines, 1, skipped_types)
		end
	end
	inline.content = inlines
	return inline
end

-- ░░░░░ write_latex_commands {{{2
-- Emits a custom command for latex based on the class of a Span
-- if attributes are named
---  opts="a,b,c" then it transforms to \command[a,b,c]{...}"
---  opts are inside [] or optional arguments for \command
local function write_latex_commands(spanEl)
	if FORMAT == "beamer" or FORMAT == "latex" then
		if not spanEl.attr.classes then
			return nil
		end
		if spanEl.attr.classes:includes(SKIP_CLASS) then
			print("flexspan.lua: Skipping Span because it has class " .. SKIP_CLASS)
			return spanEl
		end
		local class_name = nil
		-- If no class name, then return untouched
		if spanEl.attr and spanEl.attr.classes[1] then
			class_name = spanEl.attr.classes[1]
		else
			return nil
		end

		--[[
		-   ▄┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈▄
		-   ░ Skip writing LaTeX code if class not specified in flexspan   ░
		-   ░ commands                                                     ░
		-   ▀┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈▀
		]]
		if not _commands:find(class_name) then
			return nil
		end

		-- resolve the begin command
		local beginCommand = "\\" .. pandoc.utils.stringify(class_name)
		-- check if custom options or arguments are present
		-- and add them to the environment accordingly. They are added as a single
		-- optional argument to the latex command
		-- [text]{.myclass bg=white fg=red} -> \myclass[bg=white,fg=red]{text}
		local opts = spanEl.attr.attributes and get_attributes(spanEl.attr)
		if opts then
			opts = tostring(opts)
			if #opts > 0 then
				beginCommand = beginCommand .. string.format("[%s]", opts)
			end
		end

		local beginCommandRaw = pandoc.RawInline("latex", beginCommand .. "{")

		-- the end command
		local endCommandRaw = pandoc.RawInline("latex", "}")

		-- attach the raw inlines to the span contents
		local result = spanEl.content
		table.insert(result, 1, beginCommandRaw)
		table.insert(result, endCommandRaw)

		return result
	else
		return spanEl
	end
end

--[[
 -   ▄┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈▄
 -   ░ Apply the filters {{{1                                       ░
 -   ▀┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈▀
]]
return {
	{ Meta = Meta }, -- Process first the metadata
	{ Para = process_inlines }, -- Scans the paragraphs
	{ Plain = process_inlines }, -- Scans the paragraphs
	{ Span = write_latex_commands }, -- Processes LaTeX spans
}
