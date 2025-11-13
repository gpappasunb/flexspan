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

-- For debugging purposes{{{1
require("mobdebug").start()

-- The prefix to skip inline code
local SKIP_CLASS = "skipspan"

-- ┤ The filters that are defined in the Metadata ├░░░░░░░░░░░░░░░░░░░░░░░
local FILTERS = {}
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

-- ░░………………………………………………………………………………………………………………………………………░ table_keys {{{2
--- Extracts the keys of a table
-- @param tbl The table to be queried
-- @return table with the keys
local function table_keys(tbl)
	if type(tbl) ~= "table" then
		return {}
	end
	local keys = {}
	for key, _ in pairs(tbl) do
		table.insert(keys, key)
	end
	return keys
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
--
-- ◣…………………………………………………………………………………………………………◢ table_first_common_element {{{2
--- Finds the first value that is present in both input tables (treated as collections of values).
-- This works for tables structured as lists (e.g., { "a", "b" }) or maps (e.g., { k = "a", j = "b" }),
-- as it compares the *values* within the tables.
-- @tparam table table1 The first table (e.g., { "a", "b", "c" } or { x = "a", y = "b" }).
-- @tparam table table2 The second table (e.g., { "x", "b", "z" } or { i = "x", j = "b" }).
-- @return The first common *value* found across both tables, or `nil` if no common values exist.
local function table_first_common_element(tbl1, tbl2)
	-- Create a lookup table for values in table2 for O(1) average time complexity checks
	local lookup2 = {}
	for _, v in pairs(tbl2) do
		lookup2[v] = true
	end

	-- Iterate through table1's values
	for _, v in pairs(tbl1) do
		-- Check if the current value from table1 exists as a key in the lookup table of table2's values
		if lookup2[v] then
			-- Return the first common value found
			return v
		end
	end

	-- Return nil if no common value is found after checking all values
	return nil
end


-- ◣…………………………………………………………………………………………………………………………………◢ table_filter_keys {{{2
--- Filters a table, keeping only key-value pairs where the key exists in a given list of keys.
-- @param table original_table The table to be filtered (e.g., { a = 1, b = 2, c = 3 }).
-- @param table keys_to_keep A table containing the keys to retain (e.g., { "a", "c" }).
-- @return table A new table with only the specified key-value pairs (e.g., { a = 1, c = 3 }).
local function table_filter_keys(original_table, keys_to_keep)
	local filtered_table = {}
	-- Iterate through the list of keys to keep
	for _, key in ipairs(keys_to_keep) do
		-- If the key exists in the original table, add it to the filtered table
		if original_table[key] ~= nil then
			filtered_table[key] = original_table[key]
		end
	end
	return filtered_table
end

--- Filters a table of nested tables by a specific key, returning a list of unique values for that key.
-- @param table nested_table The table containing nested tables (e.g., { { id = 1 }, { id = 2 }, { id = 1 } }).
-- @param string key The key name to look for in the nested tables (e.g., "id").
-- @return table A new table containing the unique values found under the specified key (e.g., { 1, 2 }).
local function table_get_inner_key(tbl, key)
	local seen_values = {} -- Use a table to track which values have been encountered
	local unique_values = {} -- The final list of unique values

	for _, inner_table in pairs(tbl) do
		if type(inner_table) == "table" then
			local value = inner_table[key]
			-- Only add the value if it hasn't been seen before and is not nil
			if value ~= nil and not seen_values[value] then
				seen_values[value] = true -- Mark the value as seen
				table.insert(unique_values, value)
			end
		end
	end

	return unique_values
end

-- ◣……………………………………………………………………………………………………………………◢ table_filter_inner_key {{{2
local function table_filter_inner_key(tbl, key, value, index)
	local filtered = {} -- The final list of unique values

	for tbl_key, inner_table in pairs(tbl) do
		for i, filt in ipairs(inner_table) do
			-- if index and type(inner_table[index]) == "table" then
			-- 	inner_table = inner_table[index]
			-- end
			if type(filt) == "table" then
				local inner_value = filt[key]
				-- Only add the value if it hasn't been seen before and is not nil
				if inner_value ~= nil and inner_value == value then
					-- table.insert(filtered, inner_table)
					-- table.insert(filtered[tbl_key], filt)
					filtered[tbl_key] = { filt }
				end
			end
		end
	end

	return filtered
end

-- ◣…………………………………………………………………………………………………………………………………………………◢ table_clone {{{2
-- Clones a table
-- @param table original table as indices
-- @return table exact table copy
function table_clone(tbl)
	local clone = {}
	for i, value in ipairs(tbl) do
		clone[i] = value
	end
	return clone
end

function table_remove_nil(tbl)
	local result = {}
	for _, value in ipairs(tbl) do
		if value ~= nil then
			table.insert(result, value)
		end
	end
	return result
end

-- ░░………………………………………………………………………………………………………………………………………░ filter_intersect {{{2
--- Finds the first filter object that exists in two separate lists of filters.
-- The comparison is based on the `left`, `right`, and `command` attributes
-- of the filter objects.
-- @param filters1 The first list of filter objects.
-- @param filters2 The second list of filter objects.
-- @return The first filter object from `filters1` that has a matching object
--         in `filters2`, or `nil` if no match is found.
local function filter_intersect(filters1, filters2)
	-- Iterate through the first list of filters
	for _, filter1 in ipairs(filters1) do
		-- For each filter in the first list, iterate through the second list
		for _, filter2 in ipairs(filters2) do
			-- Check if the required attributes are the same
			if
				filter1.left == filter2.left
				and filter1.right == filter2.right
				and filter1.command == filter2.command
			then
				-- A match is found. Return the filter from the first list.
				return filter1
			end
		end
	end

	-- If no match is found after checking all combinations, return nil.
	return nil
end
-- ◣…………………………………………………………………………………………………………………………………………………◢ filter_find {{{2
-- Finds the filter with the given left and right patterns
-- @param str the left placeholder
-- @param str the right placeholder
-- @retrun table Filter found. nil if not found
local function filter_find(_left, _right)
	for i, f in FILTERS do
		if f.left == _left and f.right == _right then
			return f
		end
	end
	return nil
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

-- ░░………………………………………………………………………………………………░ create_placeholder_command_map {{{2
--- Creates a lookup table mapping placeholder strings (left or right delimiters)
-- to a list of their corresponding command names.
-- This is necessary because multiple filters can share the same placeholder.
-- This function should be called after the `filters` table has been populated by `Meta`.
-- @return A table where keys are placeholder strings (e.g., "[[") and values
--         are tables containing the list of command strings (e.g., {"highlight", "red-box"}).
local function create_command_map(filters, is_left)
	local placeholder_type = "left"
	if not is_left then
		placeholder_type = "right"
	end
	local placeholder_map = {}

	local function add_to_map(placeholder, element)
		if not placeholder or not element then
			return
		end

		-- If the placeholder is not yet a key in the map, create an empty table for it
		if not placeholder_map[placeholder] then
			placeholder_map[placeholder] = {}
		end
		-- Add the command to the list of commands for this placeholder
		table.insert(placeholder_map[placeholder], element)
	end

	for _, filter in ipairs(filters) do
		add_to_map(filter[placeholder_type], filter)
	end

	return placeholder_map
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
	local start_pos, end_pos, args
	if is_exact then
		pattern = "^" .. pattern
		-- Exact match was found
		if s == pattern then
			return 1, #s, nil
		elseif s:find("^" .. pattern .. "$") then -- Match entire line, but accepts escaped chars
			return 1, #s, nil
		elseif s:find("^" .. pattern .. "%s*(%b())") then
			start_pos, end_pos, args = s:find(pattern .. "%s*(%b())")
			return start_pos, end_pos, args and args:sub(2, -2) or ""
		end
	end
	-- local pattern = escape_pattern(pattern)
	if is_right ~= nil then
		-- The string is eaual to right placeholder
		if s == pattern then
			return 1, #s, nil
		end
		-- Now search from the end
		if s:find(pattern .. "$") then
			start_pos, end_pos = s:find(pattern .. "$")
		else
			-- Finds exact match, starting from the end
			-- start_pos, end_pos = s:find(pattern .. "$", is_right + 1)
			--TODO: FIX
			start_pos, end_pos = s:find(pattern .. "$", 2)
		end
		if start_pos then
			return start_pos, end_pos, nil
		end
		-- Find pattern followed by ()
		local start_pos, end_pos, args = s:find(pattern .. "%s*(%b())")
		-- If found, then we have options
		if start_pos then
			return start_pos, end_pos, args and args:sub(2, -2) or ""
		end
		-- Find pattern containing a single punctuation at the end
		-- local start_pos_end, end_pos_end, punctuation = s:find(pattern .. "([.;:?!-]?)$", 2)
		-- --TODO: FIX is_right
		-- local start_pos_end, end_pos_end, punctuation = s:find(pattern .. "(%p?)$", is_right + 1)
		local start_pos_end, end_pos_end, punctuation = s:find(pattern .. "(%p?)$", 2)
		if start_pos_end then
			if #punctuation == 0 then
				punctuation = nil
			end
			return start_pos_end, end_pos_end, punctuation
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
-- @return A new pandoc.List of inlines with the specified elements wrapped in a Span. Also, the position in the list where the span was inserted
local function wrap_inlines_span(_inlines, start_idx, end_idx, filter, opts, end_pattern)
	-- opts = opts or {}
	end_pattern = end_pattern or "$"
	local span_class = filter.command
	local punctuation = nil

	-- ┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┤ Processing the options, if provided ├┅┅┅┅┅┅┅┅┅┅┅┅┅┅
	if opts then
		-- Checking if opts is a punctuation symbol
		-- local p_start, _, p = opts:find("^([.;:?!-]?)$")
		local p_start, _, p = opts:find("^(%p?)$")
		if p_start then
			-- Creating a Str for the punctuation after the placeholder
			punctuation = pandoc.Str(p)
			end_pattern = p .. "$"
			opts = nil
		else
			end_pattern = "%s*(%b())"
		end
	else
		-- Use the options defined in the metadata, in case no options provided
		-- it stil can be nil
		opts = filter.options
	end
	-- ┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┤ Processing the left placeholder ├┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅
	-- Getting the left placeholder text
	local left_txt = _inlines[start_idx].text
	-- Cleaning the placeholders in the range
	-- 	-- Both placeholders are in the same element
	if start_idx == end_idx then
		-- For exact filters, both are joined in the left_txt, and are simply erased
		if filter.exact then
			left_txt = filter.content or ""
		else -- This case there are contents inside the placeholders, that will be kept
			left_txt = left_txt:gsub("^" .. filter.left .. "(.-)" .. filter.right .. end_pattern, "%1", 1)
		end
	else -- Placeholders in different elements. Remove the left and right placeholders
		left_txt = left_txt:gsub("^" .. filter.left, "", 1)
		local right_txt = _inlines[end_idx].text
		right_txt = right_txt:gsub(filter.right .. end_pattern, "", 1)
		_inlines[end_idx].text = right_txt
	end
	_inlines[start_idx].text = left_txt

	-- ┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┤ Elements inside the span ├┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅
	local inside_span = slice(_inlines, start_idx, end_idx)

	-- 1. Create the new Span element
	if type(opts) == "string" then
		local _, attr_table = split_key_value_pairs(opts, ",")
		opts = attr_table
	end
	-- Creating the attributes, id=string, classes={}, other attributes={}
	local pandoc_attr = pandoc.Attr("", { span_class }, opts)
	-- Creating the span
	local span = pandoc.Span(inside_span, pandoc_attr)
	-- This is a special case, where the user discards the
	-- text inside the span and forces to use the provided content
	if filter.content then
		span = pandoc.Span(filter.content, pandoc_attr)
	end

	-- -- 2. Build the final result list by combining the three parts
	-- local result = before_slice
	--
	-- -- Insert the single new Span element
	-- result:insert(span)
	-- -- Position where the span was inserted
	-- local span_pos = #result
	-- -- Insert all elements from the after_slice list
	-- if after_slice then
	-- 	for _, el in ipairs(after_slice) do
	-- 		result:insert(el)
	-- 	end
	-- end

	-- return result, span_pos
	return span, punctuation
end

-- ░░………………………………………………………………………………………………░ create_exact_filters_map {{{2
--- Creates a lookup table for filters that have the `exact` field set to true.
-- The keys of the table are the concatenation of the `left` and `right` placeholder strings,
-- and the values are the filter tables themselves.
-- This function should be called after the `filters` table has been populated by `Meta`.
-- @param table with the processed filters in Meta
-- @return A table where keys are concatenated placeholder strings (e.g., "~~")
--         and values are the full filter tables.
local function create_exact_filters_map(filters)
	local exact_filters_map = {}

	for _, filter in ipairs(filters) do
		if filter.exact then
			local key = filter.left .. filter.right
			exact_filters_map[key] = filter
		end
	end

	return exact_filters_map
end

--- Finds a pattern within the Str elements of an inlines list.
-- @param inlines A pandoc.List of inline elements.
-- @param pattern The string pattern to search for.
-- @param is_right Boolean, if true, searches from the end of the string
-- @return If a match is found, returns:
--   - index of the Str element.
--   - Options captured arguments from inside () if any.
--   - The filter table
--   - start position of the match within the string.
--   - end position of the match within the string.
--   - the Str element itself.
-- @return If no match is found, returns nil.
local function find_pattern_in_inlines(inlines, start_idx, is_right, is_exact)
	start_idx = start_idx or 1
	-- if is_right == nil then
	-- 	is_right = 0
	-- end
	-- Check if out of bounds
	if start_idx > #inlines then
		return nil
	end
	for i = start_idx, #inlines do
		-- for i, el in ipairs(merged_inlines) do
		local el = inlines[i]
		if el.t == "Str" then
			local start_pos, end_pos, opts
			if is_right == nil then --Left pattern
				for pat, _filt in pairs(PLACEHOLDERS_LEFT) do
					start_pos, end_pos, opts = find_pattern_in_str(el.text, pat, is_right, is_exact)
					if start_pos then
						return i, opts, _filt, start_pos, end_pos, el
					end
				end
			else
				for pat, _filt in pairs(PLACEHOLDERS_RIGHT) do
					start_pos, end_pos, opts = find_pattern_in_str(el.text, pat, is_right, is_exact)
					if start_pos then
						return i, opts, _filt, start_pos, end_pos, el
					end
				end
			end
		end
	end
	return nil
end

--[[
local function NEWfind_pattern_in_inlines(inlines, placeholders, start_idx, is_right, is_exact)
	start_idx = start_idx or 1
	-- if is_right == nil then
	-- 	is_right = 0
	-- end
	-- Check if out of bounds
	if start_idx > #inlines then
		return nil
	end
	for i = start_idx, #inlines do
		-- for i, el in ipairs(merged_inlines) do
		local el = inlines[i]
		if el.t == "Str" then
			local start_pos, end_pos, opts
			for pat, _filt in pairs(placeholders) do
				start_pos, end_pos, opts = find_pattern_in_str(el.text, pat, is_right, is_exact)
				if start_pos then
					return i, opts, _filt, start_pos, end_pos, el
				end
			end
		end
	end
	return nil
end
]]

--- Finds a pattern within the Str elements of an inlines list.
-- @param inlines A pandoc.List of inline elements.
-- @param pattern The string pattern to search for.
-- @param is_right Boolean, if true, searches from the end of the string
-- @return If a match is found, returns:
--   - index of the Str element.
--   - Options captured arguments from inside () if any.
--   - The filter table
--   - start position of the match within the string.
--   - end position of the match within the string.
--   - the Str element itself.
-- @return If no match is found, returns nil.
local function NEWfind_pattern_in_inlines(inlines, placeholders, start_idx, is_right, is_exact)
	local results = {}
	start_idx = start_idx or 1
	-- if is_right == nil then
	-- 	is_right = 0
	-- end
	-- Check if out of bounds
	if start_idx > #inlines then
		return nil
	end

	for i = start_idx, #inlines do
		-- for i, el in ipairs(merged_inlines) do
		local el = inlines[i]
		if el.t == "Str" then
			local start_pos, end_pos, opts
			for pat, _filt in pairs(placeholders) do
				start_pos, end_pos, opts = find_pattern_in_str(el.text, pat, is_right, is_exact)
				if start_pos then
					table.insert(results, {
						inline_pos = i,
						opts = opts,
						filter = _filt,
						match_start = start_pos,
						match_end = end_pos,
						pattern = pat,
					})
				end
			end
		end
	end
	if #results then
		-- Sort the table by inline_pos and match_start
		table.sort(results, function(a, b)
			if a.inline_pos == b.inline_pos then
				return a.match_start < b.match_start
			else
				return a.inline_pos < b.inline_pos
			end
		end)
		return results
	else
		return nil
	end
end

local function find_common_filter(_left, _right)
	local common = table_first_common_element(_left, _right)
	return common

	--[[
	for _, r in ipairs(_right) do
		local rfilter = r.filter
		for _, l in ipairs(_left) do
			local lfilter = l.filter
			if lfilter == rfilter then
				return lfilter
			end
		end
	end
	return nil
	]]
end


local function find_match_pair(_left, _right)
	local final_matches = {
		-- left = nil,
		-- right = nil,
		-- filter = nil,
	}

	-- Find the common filter between the left and right matches
	-- if not common_filter then
	-- 	return nil
	-- end
	for i, rmatch in ipairs(_right) do
		if _left.inline_pos == rmatch.inline_pos then
			if _left.match_end >= rmatch.match_start then
				goto continue
			end
		elseif _left.inline_pos > rmatch.inline_pos then
			goto continue
		end
		local common_filter = find_common_filter(_left.filter, rmatch.filter)
		final_matches.left = _left.inline_pos
		final_matches.right = rmatch.inline_pos
		final_matches.filter = common_filter --rmatch.filter -- filter_find(_left.pattern, rmatch.pattern)
		final_matches.opts = rmatch.opts
		if final_matches.filter then
			return final_matches
		end

		::continue::
	end
	-- if final_matches.filter then
	-- 	return final_matches
	-- else
	return nil
	-- end
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
		local left_pos, left_match_pos, left_filter
		local right_pos, right_match_pos, right_filter
		local opts

		-- If the filter exact option is set, then the
		-- left and right placeholders are joined and the match is exact, without
		-- the possibility of a text inside. However, options are allowed after the
		-- patterns.
		-- left="-" right=":", then -: or -:(fg=red) are valid
		-- if filter.exact then
		if nil then
			-- local joined_placeholders = filter.left .. filter.right
			-- left_pos, opts, left_filter, left_match_pos, left_match_end, _ =
			-- 	find_pattern_in_inlines(inlines, joined_placeholders, current_pos, 1, true)
			--
			-- -- In this case the placeholders were joined and left and right_pos are the same
			-- if left_pos then
			-- 	right_pos = left_pos
			-- 	left_match_pos = 1
			-- 	-- imposing a difference between, only to comply with the processing below and avoid
			-- 	-- this match being identified as to the left placeholder only
			-- 	right_match_pos = #filter.left + 1
			-- else
			-- 	return inlines, false
			-- end
		else --if not filter.exact then
			-- ┅┤ Trying to find the left pattern ├┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅
			left_pos, _, left_filter, left_match_pos = find_pattern_in_inlines(inlines, current_pos)

			xpat = NEWfind_pattern_in_inlines(inlines, PLACEHOLDERS_LEFT, current_pos)
			local left_patterns = table_get_inner_key(xpat, "pattern")

			local right_pattern_available = table_filter_keys(PLACEHOLDERS_LEFT, left_patterns)
			local X = table_filter_inner_key(PLACEHOLDERS_RIGHT, "left", xpat[1].pattern, 1)

			-- left_pos, _, left_filter, left_match_pos = find_pattern_in_inlines(inlines, filter.left, current_pos)
			if not left_pos then
				-- Return unmodified
				return inlines, false
			end

			-- ┅┤ Trying to find the right pattern ├┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅

			-- Special handling if the inlines are a single element in the inlines list
			if #inlines == 1 then
				-- Finding the right_match
				right_pos, opts, right_filter, right_match_pos, _, _ =
					find_pattern_in_inlines(inlines, left_pos, left_match_pos)
				-- right_pos, opts, right_filter, right_match_pos, _, _ = find_pattern_in_inlines(inlines, filter.right, left_pos, #filter.left)
				-- ┅┅┅┅┅┅┅┅┅┅┅┤ Skipping because the match is in the same position ├┅┅┅┅┅┅┅┅┅┅
				-- Avoids the problem of placeholders being the same text. If right_match_pos
				-- is equal to left_match_pos, the match occur in the opening placeholder, and there is no closing one
				if right_pos and left_match_pos >= right_match_pos then
					right_pos = nil
				end
			else
				right_pos, opts, right_filter, right_match_pos =
					find_pattern_in_inlines(inlines, left_pos, left_match_pos)

				xpat_right = NEWfind_pattern_in_inlines(inlines, right_pattern_available, left_pos, left_match_pos)
				xpat_right = NEWfind_pattern_in_inlines(inlines, X, left_pos, left_match_pos)
				-- right_pos, opts, right_filter, right_match_pos = find_pattern_in_inlines(inlines, filter.right, left_pos, #filter.left)
				-- Matches of left and right positions are the same. Begin matching after the left_pos
				if left_pos == right_pos and left_match_pos == right_match_pos then
					right_pos, opts, right_filter, right_match_pos = find_pattern_in_inlines(inlines, left_pos + 1)
					-- right_pos, opts, right_filter, right_match_pos = find_pattern_in_inlines(inlines, filter.right, left_pos + 1, #filter.left)
				end
			end
		end

		local applied_filter = nil
		-- Found a match. Forward the iteration past the right position
		if left_pos and right_pos then
			current_pos = right_pos + 1
			applied_filter = filter_intersect(left_filter, right_filter)
			filter = applied_filter
		else
			break
		end

		if filter.exact then
			if left_pos ~= right_pos then
				break
			end
			if inlines[left_pos] ~= filter.left .. filter.right then
				break
			end
		end
		--[[
		-   ▄┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈▄
		-   ░ Found a match. Process it                                    ░
		-   ▀┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈▀
		]]
		if left_pos and right_pos then
			local end_pattern = "$" -- Regex to mark end of the line
			local attr_table
			local punctuation = nil
			if opts then
				-- Checking if opts is a punctuation symbol
				-- local p_start, _, p = opts:find("^([.;:?!-]?)$")
				local p_start, _, p = opts:find("^(%p?)$")
				if p_start then
					-- Creating a Str for the punctuation after the placeholder
					punctuation = pandoc.Str(p)
					end_pattern = p .. "$"
					opts = nil
				else
					end_pattern = "%s*(%b())"
				end
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
				-- If a punctuation character is found after the right placeholder, then add it back as a pandoc.Str
				if punctuation then
					table.insert(new_inlines, left_pos + 1, punctuation)
				end
			else
				-- Creating the span
				local txt = inlines[left_pos].text
				txt = txt:gsub("^" .. filter.left, "", 1)
				inlines[left_pos].text = txt
				txt = inlines[right_pos].text
				txt = txt:gsub(filter.right .. end_pattern, "", 1)
				inlines[right_pos].text = txt

				-- Now modifying the inlines to add the span between left and right pos
				new_inlines, span_pos = wrap_inlines_span(inlines, left_pos, right_pos, filter, opts)
				-- Adding the punctuation
				if punctuation then
					table.insert(new_inlines, span_pos + 1, punctuation)
				end
			end
			-- return new_inlines, true
			inlines = new_inlines
		end
	end

	return inlines, false
end

local function NEWreplace_span(inlines, filter)
	local current_pos = 1
	-- ┅┅┅┅┅┅┅┅┅┅┅┅┅┤ Finding all the pattern matches in the inlines ├┅┅┅┅┅┅┅┅┅┅┅┅
	-- ░░░░░░┤ Iterating over the matches and performing the span changes ├░░░░░░
	local left_pos, left_match_pos, left_filter
	local right_pos, right_match_pos, right_filter
	local opts

	-- ┅┤ Trying to find the left pattern ├┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅

	-- Returns a list of all matching inline positions
	-- containing a match to the left placeholders
	local left_matches = NEWfind_pattern_in_inlines(inlines, PLACEHOLDERS_LEFT)

	--[[
	local exact_matches = NEWfind_pattern_in_inlines(inlines, EXACT_FILTERS, 1, 1, true)
	if #exact_matches then
		for i, match in ipairs(exact_matches) do
			local pos = match.inline_pos
			left_pos = match.left
			right_pos = match.right
			filter = match.filter
			opts = match.opts
			if opts then
				-- Checking if opts is a punctuation symbol
				-- local p_start, _, p = opts:find("^([.;:?!-]?)$")
				local p_start, _, p = opts:find("^(%p?)$")
				if p_start then
					-- Creating a Str for the punctuation after the placeholder
					punctuation = pandoc.Str(p)
					end_pattern = p .. "$"
					opts = nil
				else
					end_pattern = "%s*(%b())"
				end
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

			-- ░░░░░░░░░░░░░░░┤ Wraping the inlines range inside a Span ├░░░░░░░░░░░░
			-- Getting the new Span
			new_span = wrap_inlines_span(inlines, pos, pos, filter, attr_table)
			inlines[pos] = new_span
		end
	end
]]

	-- left_pos, _, left_filter, left_match_pos = find_pattern_in_inlines(inlines, filter.left, current_pos)
	if #left_matches == 0 then
		-- Return unmodified
		return inlines, false
	end

	-- ┅┤ Trying to find the right pattern ├┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅
	--
	-- Finding the right matches for each left_match
	--
	local matching_locations = {}
	for i, _lmatch in ipairs(left_matches) do
		local right_matches_local = NEWfind_pattern_in_inlines(inlines, PLACEHOLDERS_RIGHT, i, true)
		-- left_matches[i]["right_match"] = find_match_pair(_lmatch, right_matches_local)

		local match_pair = find_match_pair(_lmatch, right_matches_local)

		-- No right match for this placeholder. SKIP
		if match_pair and match_pair.filter then
			table.insert(matching_locations, match_pair)
		end
	end

	-- Getting the first position of the match
	local start_idx = matching_locations[1].left
	-- The total number of inlines being processed
	local total_inlines = #inlines
	-- The new inlines start with the inlines up to the first match location
	local inlines_modified = slice(inlines, 1, start_idx - 1)
	local last_inline_pos = 1

	-- ┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┤ Iterating the valid match locations ├┅┅┅┅┅┅┅┅┅┅┅┅┅┅
	local span_counter = 1
	for i, match in ipairs(matching_locations) do
		left_pos = match.left
		right_pos = match.right
		filter = match.filter
		opts = match.opts

		-- Copying the inline elements between the last position of the previous
		-- matching_locations and the begining of the current match
		if last_inline_pos < left_pos then
			for i = last_inline_pos, left_pos - 1 do
				table.insert(inlines_modified, inlines[i])
			end
		end

		-- ┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┤ Skip if positions not found ├┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅
		if not (left_pos and right_pos) then
			goto continue
		end

		-- local end_pattern = "$" -- Regex to mark end of the line
		-- local attr_table
		local punctuation = nil
		-- if opts then
		-- 	-- Checking if opts is a punctuation symbol
		-- 	-- local p_start, _, p = opts:find("^([.;:?!-]?)$")
		-- 	local p_start, _, p = opts:find("^(%p?)$")
		-- 	if p_start then
		-- 		-- Creating a Str for the punctuation after the placeholder
		-- 		punctuation = pandoc.Str(p)
		-- 		end_pattern = p .. "$"
		-- 		opts = nil
		-- 	else
		-- 		end_pattern = "%s*(%b())"
		-- 	end
		-- else
		-- 	-- Use the options defined in the metadata, in case no options provided
		-- 	-- it stil can be nil
		-- 	opts = filter.options
		-- end
		-- Getting the span attributes table
		-- _, attr_table = split_key_value_pairs(opts, ",")
		-- Handle special case of a single Str element containing the left and right placeholders
		local new_span
		-- local new_inlines = {}
		-- This is a special case, where the user discards the
		-- text inside the span and forces to use the provided content
		-- local filter_content = filter.content
		-- The left and right placeholders are in a single string

		-- ░░░░░░░░░░░░░░░┤ Wraping the inlines range inside a Span ├░░░░░░░░░░░░
		-- Getting the new Span
		new_span, punctuation = wrap_inlines_span(inlines, left_pos, right_pos, filter, attr_table)
		-- Adding the Span to the modified inlines
		table.insert(inlines_modified, new_span)
		-- If a punctuation mark occurs right after the right placeholder (without a space),
		-- add it to the modifed inlines
		if punctuation then
			table.insert(inlines_modified, punctuation)
		end

		span_counter = span_counter + 1

		last_inline_pos = right_pos + 1

		--[[
		local txt = inlines[left_pos].text


		if left_pos == right_pos then
			-- First remove the placeholders
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
			-- If a punctuation character is found after the right placeholder, then add it back as a pandoc.Str
			if punctuation then
				table.insert(new_inlines, left_pos + 1, punctuation)
			end
		else
			-- Creating the span
			local txt = inlines[left_pos].text
			txt = txt:gsub("^" .. filter.left, "", 1)
			inlines[left_pos].text = txt
			txt = inlines[right_pos].text
			txt = txt:gsub(filter.right .. end_pattern, "", 1)
			inlines[right_pos].text = txt

			-- Now modifying the inlines to add the span between left and right pos
			new_inlines, span_pos = wrap_inlines_span(inlines, left_pos, right_pos, filter, opts)
			-- Adding the punctuation
			if punctuation then
				table.insert(new_inlines, span_pos + 1, punctuation)
			end
		end
		-- return new_inlines, true
		inlines = new_inlines
	]]
		::continue::
	end
	-- ┅┅┅┤ Filling the inlines with elements after the last modified location ├┅┅
	if last_inline_pos < total_inlines then
		for i = last_inline_pos, total_inlines do
			table.insert(inlines_modified, inlines[i])
		end
	end

	return inlines_modified, true
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

			table.insert(FILTERS, {
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
	table.sort(FILTERS, function(a, b)
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
	-- Creating exact filters map. These will be processed first
	EXACT_FILTERS = create_exact_filters_map(FILTERS)
	-- Sorting the xact filters by the longest matches
	table.sort(EXACT_FILTERS, function(a, b)
		local size_a = #a.left + #a.right
		local size_b = #b.left + #b.right
		return size_a > size_b
	end)
	-- Generating the table with the left placeholders
	PLACEHOLDERS_LEFT = create_command_map(FILTERS, true)
	PLACEHOLDERS_RIGHT = create_command_map(FILTERS, false)
end

-- ░░………………………………………………………………………………………………………………………………………░ process_inlines ░{{{2
-- AST transformation function that processes inlines, scanning for the
-- presence of the placeholders and substituting the matches by Span elements
-- The AST is transformed by adding the Span enclosing the match
local function process_inlines(inline)
	if #FILTERS == 0 then
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
	-- for _, filter in ipairs(filters) do
	for _, pos in ipairs(included_positions) do
		-- -- ┅┤ Trying to find the left pattern ├┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅
		-- returns new inlines with the span added, if the left and right
		-- patterns were found
		inlines, modified = NEWreplace_span(inlines, filter)
		-- inlines, modified = replace_span(inlines, filter)
	end
	-- Recalculating positions of skipped elements, since inlines were modified
	if found_skipped and modified then
		included_positions = find_non_matching_ranges(inlines, 1, skipped_types)
	end
	-- end
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
	{ Meta = Meta },              -- Process first the metadata
	{ Para = process_inlines },   -- Scans the paragraphs
	{ Plain = process_inlines },  -- Scans the paragraphs
	{ Span = write_latex_commands }, -- Processes LaTeX spans
}
