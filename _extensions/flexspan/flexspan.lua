--- flexspan-AST.lua
--
-- This Lua filter finds text enclosed in custom placeholders (e.g., [[text]])
--          and converts it to a Span. It also supports parsing optional
--          arguments (e.g., [[text]](args)) associated with these placeholders.
--
--          In the case of latex/beamer output, the span is transformed into a LaTeX command.
--          The definitions for placeholders and their corresponding span classes (LaTeX commands) are configured via the document's metadata.
--
-- Author: Georgios Pappas Jr
--         Universidade de Brasília (UnB) - Brasil
-- Last modified: November, 2025
-- Version: 1.0.0

-- For debugging purposes
-- require("mobdebug").start()

-- The prefix to skip inline code
local SKIP_PREFIX = "__SKIPCODE__"
local SKIP_CLASS = "skipspan"

-- ┤ The filters that are defined in the Metadata ├░░░░░░░░░░░░░░░░░░░░░░░
local filters = {}

-- ┅┅┅┅┅┅┅┅┤ The name of the metadata key to define the span mappings ├┅┅┅┅┅┅┅
local META_NAME = "flexspan"
-- ┅┅┅┅┅┅┅┤ The name of the span attribute to hold additional options ├┅┅┅
local OPTS_KEY_NAME = "opts"

-- ░░………………………………………………………………………………………………General lua functions {{{1

local tostring = pandoc.utils.stringify

-- ░░…………………………………………………………………………………………………………………………………………░ escape_pattern {{{2
-- Helper function to escape characters that are special in Lua patterns.
-- This is necessary because the user-defined delimiters might contain
-- characters like '[', '(', '*', etc.
local function escape_pattern(s)
	return s:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
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
	local result_components = {}
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
	for i = 1, #final_result do
		for key, val in final_result[i]:gmatch("(.-)=(.*)$") do
			kv_table[string.format("%s", key)] = val
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
-- @return If a match is found:
--   - `start_pos` (number): The starting index of the match in `s`.
--   - `end_pos` (number): The ending index of the match in `s`.
--   - `args` (string or nil): If the pattern was followed by `()`, this contains the content inside the parentheses. Otherwise, it's `nil`.
-- @return If no match is found, returns `nil`.
local function find_pattern_in_str(s, pattern, is_right)
	-- local pattern = escape_pattern(pattern)
	if is_right then
		-- Find pattern followed by ()
		local start_pos, end_pos, args = s:find(pattern .. "%s*(%b())")
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
		if value then
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
		local str, attr_table = split_key_value_pairs(attributes, ",")
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

	--[[
	-- 2. Build the final result list by combining the three parts
	local result = pandoc.List:new()

	-- Insert all elements from the before_slice list
	for _, el in ipairs(before_slice) do
		result:insert(el)
	end

	-- Insert the single new Span element
	result:insert(span)

	-- Insert all elements from the after_slice list
	for _, el in ipairs(after_slice) do
		result:insert(el)
	end
	]]

	return result
end

--- Finds a pattern within the Str elements of an inlines list.
-- @param inlines A pandoc.List of inline elements.
-- @param pattern The string pattern to search for.
-- @param is_relaxed Boolean, if true, allows for more flexible matching rules.
-- @return If a match is found, returns:
--   - index of the Str element.
--   - captured arguments from inside () if any.
--   - the Str element itself.
--   - start position of the match within the string.
--   - end position of the match within the string.
-- @return If no match is found, returns nil.
local function find_pattern_in_inlines(inlines, pattern, start_idx, is_relaxed)
	start_idx = start_idx or 1
	for i = start_idx, #inlines do
		-- for i, el in ipairs(merged_inlines) do
		local el = inlines[i]
		if el.t == "Str" then
			local start_pos, end_pos, opts = find_pattern_in_str(el.text, pattern, is_relaxed)
			if start_pos then
				return i, opts, el, start_pos, end_pos
			end
		end
	end
	return nil
end

local function replace_span(inlines, filter, skip_pos)
	-- ┅┤ Trying to find the left pattern ├┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅
	local left_pos = find_pattern_in_inlines(inlines, filter.left, skip_pos.start)
	if not left_pos then
		-- Return unmodified
		return inlines, false
	end
	-- ┅┤ Trying to find the right pattern ├┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅
	local right_pos, opts = find_pattern_in_inlines(inlines, filter.right, left_pos, true)

	local end_pattern = "$" -- Regex to mark end of the line
	local attr_str, attr_table
	if opts then
		attr_str, attr_table = split_key_value_pairs(opts, ",")
		end_pattern = "%s*(%b())"
	end

	-- ┅┤ If both found, wrap in a span an insert to inlines ├┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅
	if left_pos and right_pos then
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
			table.insert(new_inlines, left_pos, new_span)
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
		return new_inlines, true
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

		-- If the placeholders and command are set, then
		-- fill the filters table
		if left and right and command then
			left = escape_pattern(left)
			right = escape_pattern(right)

			table.insert(filters, {
				left = left,
				right = right,
				command = command,
				options = opts,
				content = content,
			})
		end
	end
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
		local left = filter.left
		local right = filter.right
		local filter_opts = filter.options
		local filter_content = filter.content

		for _, pos in ipairs(included_positions) do
			-- -- ┅┤ Trying to find the left pattern ├┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅
			-- returns new inlines with the span added, if the left and right
			-- patterns were found
			inlines, modified = replace_span(inlines, filter, pos)
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
