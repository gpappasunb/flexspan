-- placeholder-filter-v2.lua
--
-- Finds text in placeholders, e.g., [[text]], and converts it to a
-- LaTeX command. Also parses optional arguments, e.g., [[text]](args).
-- The placeholders and command are defined in the metadata.

-- For debugging purposes
-- require("mobdebug").start()

local tostring = pandoc.utils.stringify

local filters = {}

-- ┅┅┅┅┅┅┅┅┤ The name of the metadata key to define the span mappings ├┅┅┅┅┅┅┅
local META_NAME = "flexspan"
-- ┅┅┅┅┅┅┅┤ The name of the span attribute to hold additional options ├┅┅┅
local OPTS_KEY_NAME = "opts"

-- Helper function to escape characters that are special in Lua patterns.
-- This is necessary because the user-defined delimiters might contain
-- characters like '[', '(', '*', etc.
function escape_pattern(s)
	return s:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
end

function extract_keys(tbl)
	local keys = {}
	for key, _ in pairs(tbl) do
		table.insert(keys, key)
	end
	return keys
end

function table_intersect(table1, table2)
	-- Check for the first key in the second list that exists in the lookup table
	for _, key in ipairs(table2) do
		if table1[key] then
			return key -- Return the first intersection key found
		end
	end

	return nil -- Return nil if no intersection is found
end

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
			})
		end
	end
end

--[[
 -   ▄┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈▄
 -   ░ Processes paragraphs, scanning for the placeholders          ░
 -   ▀┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈▀
]]
local function process_para(inlines)
	if #filters == 0 then
		print("*** NO PLACEHOLDERS DEFINED. Skipping")
		return nil
	end

	local flat_inlines = inlines.content

	--log.info('para',elements)
	local modified = false
	local para_str = tostring(flat_inlines)
	-- Iterating over the filters
	for _, filter in ipairs(filters) do
		local filter_name = filter.command
		if not filter_name then
			break
		end
		local left = filter.left
		local right = filter.right
		local filter_opts = filter.options

		-- First match of the placeholders
		local all_contents = para_str:gmatch(left .. "(.-)" .. right)
		-- Skip if no matches
		if not all_contents then
			goto continue
		end

		-- ┅┤ Iterating over all matches inside the paragraph ├┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅┅
		for contents in all_contents do
			-- Trying again to check if options were passed
			-- if placeholders are ## the options syntax is ## inside ##(fg=blue,bg=black)
			-- Options always follow the right placeholder and are provided inside parenthesis
			local opts = para_str:match(left .. escape_pattern(contents) .. right .. "%s*(%b())")

			-- Construct a span in markdown using only the class name, without options
			if not opts then
				-- However, if opts field is provided in the filter metadata (filter_opts), use it, in this case
				if filter_opts then
					para_str = para_str:gsub(
						left .. escape_pattern(contents) .. right,
						string.format("[%s]{.%s %s='%s'}", contents, filter_name, OPTS_KEY_NAME, filter_opts),
						1
					)
				else
					-- No options
					para_str = para_str:gsub(
						left .. escape_pattern(contents) .. right,
						string.format("[%s]{.%s}", contents, filter_name),
						1
					)
				end
			else
				-- Construct the span passing the options
				-- remove the parenthesis from opts
				opts = opts:gsub("^%(", "")
				opts = opts:gsub("%)$", "")

				para_str = para_str:gsub(
					left .. escape_pattern(contents) .. right .. "%s*(%b())",
					string.format("[%s]{.%s %s='%s'}", contents, filter_name, OPTS_KEY_NAME, opts),
					1
				)
			end
			modified = true
		end

		::continue::
	end
	if modified then
		-- Transform this text to a list of inlines
		local new_inlines = pandoc.read(para_str, "markdown").blocks[1].content
		if new_inlines then
			-- Rebuild the paragraph AST
			return pandoc.Para(new_inlines)
		else
			return nil
		end
	else
		return nil
	end
end

-- emit a custom environment for latex
-- if attributes are named
---  opts="a,b,c" then it transforms to \command[a,b,c]{...}"
---  opts are inside [] or optional arguments for \command
local function writeCommands(spanEl)
	if FORMAT == "beamer" or FORMAT == "latex" then
		if not spanEl.attr.classes then
			return nil
		end
		local class_name = spanEl.attr.classes[1]

		-- resolve the begin command
		local beginCommand = "\\" .. pandoc.utils.stringify(class_name)
		-- check if custom options or arguments are present
		-- and add them to the environment accordingly
		local opts = spanEl.attr.attributes and spanEl.attr.attributes[OPTS_KEY_NAME]
		if opts then
			opts = tostring(opts)
			beginCommand = beginCommand .. string.format("[%s]", opts)
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

return {
	{ Meta = Meta }, -- Process first the metadata
	{ Para = process_para }, -- Scans the paragraphs
	{ Span = writeCommands }, -- Processes LaTeX spans
}
