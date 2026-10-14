--!nonstrict
-- All subprocesses use argv, never a shell. Browsing never executes SQL.
local ui = tern.ui
local PAGE = 50
local runs = {}

local function alive(s)
	if runs[s.cx.pane] ~= s then return false end
	for _, p in tern.pane.list() do
		if p.pane == s.cx.pane then return true end
	end
	runs[s.cx.pane] = nil
	return false
end

local function button(label, action, disabled)
	return ui.el("button", { text = label, class = if disabled then "bq-button bq-disabled" else "bq-button", disabled = disabled == true,
		actions = if disabled then nil else { click = action }, title = label })
end

local function focus(s, field)
	s.searching, s.editing = field == "search", field == "project"
	s.field = field
	s.cx:frame({ { "focus", if field == "search" then "main.searchbar.search" elseif field == "project" then "main.projectform.project" else nil } })
end

-- Native edit offsets are UTF-16 units. Translate at codepoint boundaries.
local function byte_offset(text, offset)
	local units = 0
	for pos, cp in utf8.codes(text) do
		local width = if cp > 0xffff then 2 else 1
		if units + width > offset then return pos - 1 end
		units += width
	end
	return #text
end

local function units(text)
	local n = 0
	for _, cp in utf8.codes(text) do n += if cp > 0xffff then 2 else 1 end
	return n
end

local function edit_field(s, key)
	local property = if s.editing then "input" else "filter"
	local text = s[property]
	local caret = math.clamp(s.caret or units(text), 0, units(text))
	local anchor = s.anchor
	local from, to = caret, caret
	if anchor then from, to = math.min(anchor, caret), math.max(anchor, caret) end
	if (key.meta or key.ctrl) and key.name == "a" then s.anchor, s.caret = 0, units(text); return true end
	if key.name == "left" or key.name == "right" or key.name == "home" or key.name == "end" then
		local position = caret
		if key.name == "home" then position = 0
		elseif key.name == "end" then position = units(text)
		elseif key.name == "left" then position = units(string.sub(text, 1, byte_offset(text, math.max(0, caret - 1))))
		else
			local pos = byte_offset(text, caret)
			local nextByte = utf8.offset(text, 2, pos + 1) or (#text + 1)
			position = units(string.sub(text, 1, nextByte - 1))
		end
		s.anchor = if key.shift then (anchor or caret) else nil
		s.caret = position
		return true
	end
	local replacement = ""
	if key.name == "backspace" then
		if from == to then from = units(string.sub(text, 1, byte_offset(text, math.max(0, caret - 1)))) end
	elseif key.name == "delete" then
		if from == to then
			local nextByte = utf8.offset(text, 2, byte_offset(text, caret) + 1) or (#text + 1)
			to = units(string.sub(text, 1, nextByte - 1))
		end
	elseif key.ctrl and key.name == "u" then from, to = 0, units(text)
	elseif key.text and not key.ctrl and not key.meta then replacement = string.gsub(key.text, "[\r\n]", " ")
	else return false end
	s[property] = string.sub(text, 1, byte_offset(text, from)) .. replacement .. string.sub(text, byte_offset(text, to) + 1)
	s.caret, s.anchor, s.cursor = from + units(replacement), nil, 1
	return true
end

local function target(s)
	return s.project .. ":" .. s.dataset .. "." .. s.table
end

local function fetch(s)
	if s.loading then return end
	local args = { "--format=json", "--quiet=true" }
	if s.project ~= "" then table.insert(args, "--project_id=" .. s.project) end
	if s.level == "projects" then
		table.insert(args, "ls")
		table.insert(args, "--projects=true")
		table.insert(args, "--max_results=1000")
	elseif s.level == "datasets" then
		table.insert(args, "ls")
		table.insert(args, "--datasets=true")
		table.insert(args, "--max_results=1000")
		table.insert(args, s.project .. ":")
	elseif s.level == "tables" then
		table.insert(args, "ls")
		table.insert(args, "--max_results=1000")
		table.insert(args, s.project .. ":" .. s.dataset)
	elseif s.level == "schema" then
		table.insert(args, "show")
		table.insert(args, target(s))
	else
		table.insert(args, "head")
		table.insert(args, "--max_rows=" .. PAGE)
		table.insert(args, "--start_row=" .. s.offset)
		table.insert(args, target(s))
	end
	s.loading, s.error, s.inspected = true, nil, nil
	s.request += 1
	local request = s.request
	local argv = { tern.getenv("TERN_BIGQUERY_BQ") or "bq" }
	-- Desktop launchers may have a minimal PATH.
	if argv[1] == "bq" then
		for _, path in { "/opt/homebrew/bin/bq", "/usr/local/bin/bq" } do
			if tern.fs.exists(path) then argv[1] = path; break end
		end
	end
	for _, a in args do table.insert(argv, a) end
	-- bq invokes gcloud for authentication; an absolute bq path alone is
	-- insufficient when the daemon inherited a minimal desktop PATH.
	local bin = string.match(argv[1], "^(.*)/[^/]+$")
	local path = tern.getenv("PATH") or "/usr/bin:/bin"
	local dirs = {}
	if bin then table.insert(dirs, bin) end
	for _, dir in { "/opt/homebrew/bin", "/usr/local/bin" } do
		if tern.fs.exists(dir .. "/gcloud") then table.insert(dirs, dir) end
	end
	table.insert(dirs, path)
	local env = { PATH = table.concat(dirs, ":") }
	if not tern.getenv("CLOUDSDK_PYTHON") then
		-- A GUI daemon can otherwise pick Apple's Python 3.9 even when the
		-- shell uses a newer interpreter through pyenv.
		for _, path in { "/opt/homebrew/bin/python3.13", "/opt/homebrew/bin/python3.12",
			"/opt/homebrew/bin/python3.11", "/opt/homebrew/bin/python3.14", "/usr/local/bin/python3.13",
			"/usr/local/bin/python3.12", "/usr/local/bin/python3.11", "/usr/local/bin/python3.14" } do
			if tern.fs.exists(path) then env.CLOUDSDK_PYTHON = path; break end
		end
	end
	local ok, err = pcall(function()
		tern.process.run(argv, { timeout_ms = 30000, env = env }, function(result)
			if not alive(s) or request ~= s.request then return end
			s.loading = false
			if result.status ~= 0 then
				s.error = if result.timed_out then "BigQuery request timed out. Press r to retry."
					else "bq failed: " .. result.stderr .. result.stdout
			else
				local decoded, data = pcall(tern.json.decode, result.stdout)
				if decoded and type(data) == "table" then
					s.data, s.cursor = data, 1
					if s.level == "schema" then s.schema = (data.schema or {}).fields or {}; s.schemaTarget = target(s) end
				else
					s.error = "bq returned invalid JSON. " .. string.sub(result.stdout, 1, 1000)
				end
			end
			s.cx:render()
		end)
	end)
	if not ok then
		s.loading = false
		s.error = "Could not start bq. Install Google Cloud CLI on the pane host or set TERN_BIGQUERY_BQ to its absolute path. " .. tostring(err)
	end
end

local function navigate(s, level)
	if s.loading then return end
	s.level, s.data, s.cursor, s.offset = level, {}, 1, 0
	s.inspected = nil
	s.filter, s.searching, s.editing, s.field = "", false, false, nil
	s.cx:frame({ { "focus", nil } })
	fetch(s)
end

local function id(s, item)
	if s.level == "projects" then return item.id or item.projectId end
	if s.level == "datasets" then return item.datasetReference and item.datasetReference.datasetId end
	return item.tableReference and item.tableReference.tableId
end

local function is_listing(s)
	return s.level == "projects" or s.level == "datasets" or s.level == "tables"
end

-- Keep source indices so filtered keyboard and pointer actions open the
-- correct resource. Match literal, case-insensitive terms (all must match).
local function filtered(s)
	local indices = {}
	if not is_listing(s) then return indices end
	for i, item in s.data do
		local text = string.lower((id(s, item) or "") .. " " .. (item.friendlyName or item.name or "") .. " " .. (item.type or ""))
		local matches = true
		for term in string.gmatch(string.lower(s.filter), "%S+") do
			if not string.find(text, term, 1, true) then matches = false; break end
		end
		if matches then table.insert(indices, i) end
	end
	return indices
end

local function open_selected(s)
	local index = filtered(s)[s.cursor]
	if index then return index end
	return nil
end

local function open(s, index)
	if s.loading then return end
	local item = if index then s.data[index] else nil
	if not item then return end
	local name = id(s, item)
	if not name then return end
	if s.level == "projects" then s.project = name; navigate(s, "datasets")
	elseif s.level == "datasets" then s.dataset = name; navigate(s, "tables")
	elseif s.level == "tables" then s.table = name; navigate(s, "schema") end
end

local function back(s)
	local parent = { datasets = "projects", tables = "datasets", schema = "tables", preview = "schema" }
	if parent[s.level] then navigate(s, parent[s.level]) end
end

local function schema_rows(fields, prefix, rows)
	for _, f in fields do
		local name = prefix .. f.name
		table.insert(rows, { name, f.type or "", f.mode or "NULLABLE", f.description or "" })
		if f.fields then schema_rows(f.fields, name .. ".", rows) end
	end
end

local function cell(value)
	if value == nil or value == tern.json.null then return "NULL" end
	if type(value) == "table" then return tern.json.encode(value) end
	return tostring(value)
end

local function content(s)
	if s.level == "schema" then
		local rows = {}
		schema_rows((s.data.schema or {}).fields or {}, "", rows)
		local widths = { 32, 18, 14, 60 }
		for _, row in rows do widths[1] = math.max(widths[1], math.min(60, units(row[1]) + 2)) end
		local total = widths[1] + widths[2] + widths[3] + widths[4]
		local function schema_row(values, key, header)
			local cells = {}
			for i, value in values do
				local n = ui.text(value)
				n.p = n.p or {}
				n.p.role = if header then "bq-grid-header" else "bq-schema-cell"
				n.p.min, n.p.max, n.p.shrink = { w = widths[i] .. "ch" }, { w = widths[i] .. "ch" }, 0
				n.p.title = value
				table.insert(cells, n)
			end
			local n = ui.row(cells)
			n.p = { key = key, role = "bq-grid-row", min = { w = total .. "ch" }, shrink = 0 }
			return n
		end
		local grid = { schema_row({ "Field", "Type", "Mode", "Description" }, "header", true) }
		for i, row in rows do table.insert(grid, schema_row(row, "field-" .. i, false)) end
		local scroll = ui.el("div", { key = "schema-grid", class = "bq-grid-scroll", attrs = {
			role = "region", ["aria-label"] = "Schema fields. Scroll horizontally to see all four columns." } }, grid)
		local parts = {
			ui.kv({ { "Type", s.data.type or "" }, { "Rows", tostring(s.data.numRows or "—") },
				{ "Bytes", tostring(s.data.numBytes or "—") }, { "Location", s.data.location or "" } }),
			ui.row({ ui.badge(#rows .. " fields", "muted"), ui.text("Scroll sideways to see all schema columns") }),
			scroll,
		}
		if #rows == 0 then table.insert(parts, ui.text("No schema fields returned.")) end
		return ui.col(parts)
	elseif s.level == "preview" then
		local names, seen, types = {}, {}, {}
		-- Schema order is authoritative, including fields omitted from all rows.
		if s.schemaTarget == target(s) then
			for _, field in s.schema or {} do
				table.insert(names, field.name); seen[field.name] = true; types[field.name] = field.type
			end
		end
		local extras = {}
		for _, row in s.data do
			for name in row do if not seen[name] then seen[name] = true; table.insert(extras, name) end end
		end
		table.sort(extras)
		for _, name in extras do table.insert(names, name) end
		local widths, total = {}, 10
		for _, name in names do
			local width = math.max(16, units(name) + 2)
			for _, row in s.data do width = math.max(width, math.min(36, units(cell(row[name])) + 2)) end
			widths[name] = math.min(40, width)
			total += widths[name]
		end
		local function gridcell(text, width, header, numeric)
			local n = ui.text(text)
			n.p = n.p or {}
			n.p.role = if header then "bq-grid-header" else "bq-grid-cell"
			n.p.min, n.p.max, n.p.shrink = { w = width .. "ch" }, { w = width .. "ch" }, 0
			n.p.title = text
			if numeric then n.p.role = "bq-grid-number" end
			return n
		end
		local function gridrow(children, key)
			local n = ui.row(children)
			n.p = { key = key, role = "bq-grid-row", min = { w = total .. "ch" }, shrink = 0 }
			return n
		end
		local head = { gridcell("Row", 10, true) }
		for _, name in names do table.insert(head, gridcell(name, widths[name], true)) end
		local grid = { gridrow(head, "header") }
		for i, row in s.data do
			local inspect = button(tostring(s.offset + i), "inspect=" .. i)
			inspect.p.min, inspect.p.max, inspect.p.shrink = {w = "10ch"}, {w = "10ch"}, 0
			local cells = { inspect }
			for _, name in names do
				local numeric = types[name] == "INTEGER" or types[name] == "FLOAT" or types[name] == "NUMERIC" or types[name] == "BIGNUMERIC"
				table.insert(cells, gridcell(cell(row[name]), widths[name], false, numeric))
			end
			table.insert(grid, gridrow(cells, "row-" .. (s.offset + i)))
		end
		local scroll = ui.el("div", { class = "bq-grid-scroll", key = "grid", attrs = { role = "region", ["aria-label"] = "Preview data. Scroll horizontally to see every column." } }, grid)
		local parts = { ui.row({ ui.badge(#s.data .. " rows", "muted"), ui.badge(#names .. " columns", "muted"),
			ui.text("Scroll sideways for more columns · click a row number to inspect") }), scroll }
		if #s.data == 0 then table.insert(parts, ui.card("No rows on this page", { ui.text("Return to the previous page or inspect the schema.") })) end
		if s.inspected and s.data[s.inspected] then
			local fields = {}
			for _, name in names do table.insert(fields, { name, cell(s.data[s.inspected][name]) }) end
			table.insert(parts, ui.card("Row " .. (s.offset + s.inspected), { ui.kv(fields), ui.row({ button("Close inspector", "close-inspector") }) }))
		end
		table.insert(parts, ui.row({ button("Previous", "previous", s.offset == 0), button("Next", "next", #s.data < PAGE), button("Copy page JSON", "copy-page", #s.data == 0) }))
		table.insert(parts, ui.text(if #s.data > 0 then "Rows " .. (s.offset + 1) .. "–" .. (s.offset + #s.data) .. " · preview order is not guaranteed" else "No rows · offset " .. s.offset))
		return ui.col(parts)
	end
	local items = {}
	local indices = filtered(s)
	for i, source in indices do
		local item = s.data[source]
		local name = id(s, item) or "Unknown"
		table.insert(items, { label = name, detail = item.friendlyName or item.name, value = item.type or "", icon = if s.level == "projects" then "folder" elseif s.level == "datasets" then "database" else "table" })
	end
	local list = ui.list(items)
	list.p = { key = "objects", filter = s.filter, max = { lines = math.max(4, math.floor((s.cx.rows - 10) * 0.72)) }, empty = if s.filter ~= "" then "No matches. Clear the filter to show all objects." else "No objects found.",
		selected = if indices[s.cursor] then "main.objects." .. (id(s, s.data[indices[s.cursor]]) or tostring(indices[s.cursor])) else nil }
	for i, child in list.c or {} do
		child.p = child.p or {}
		child.p.key = id(s, s.data[indices[i]]) or tostring(indices[i])
		-- Native select/activate works for both regular and virtual lists.
	end
	return list
end

local function action(s, act, value)
	if s.loading then return end
	if act == "refresh" then fetch(s)
	elseif act == "back" then back(s)
	elseif act == "search" and is_listing(s) then s.caret = units(s.filter); s.anchor = nil; focus(s, "search")
	elseif act == "project" then s.input = s.project; s.caret = units(s.input); s.anchor = nil; focus(s, "project")
	elseif act == "cancel-project" then focus(s, nil)
	elseif act == "open-project" then
		local project = string.match(s.input, "^%s*(.-)%s*$")
		if string.match(project, "^[%w][%w%-%.:]*$") then
			s.project, s.dataset, s.table = project, "", ""; navigate(s, "datasets")
		else s.cx:toast("error", "Enter a valid project ID") end
	elseif act == "projects" then s.project, s.dataset, s.table = "", "", ""; navigate(s, "projects")
	elseif act == "datasets" and s.project ~= "" then navigate(s, "datasets")
	elseif act == "tables" and s.dataset ~= "" then navigate(s, "tables")
	elseif act == "schema" and s.table ~= "" then navigate(s, "schema")
	elseif act == "clear" then s.filter, s.cursor, s.caret, s.anchor = "", 1, 0, nil; focus(s, nil)
	elseif act == "open" then focus(s, nil); open(s, tonumber(value) or open_selected(s))
	elseif act == "preview" and s.level == "schema" then navigate(s, "preview")
	elseif act == "inspect" and s.level == "preview" then
		local index = tonumber(value)
		if index and s.data[index] then s.inspected = index end
	elseif act == "close-inspector" then s.inspected = nil
	elseif act == "copy-page" and s.level == "preview" then s.cx:copy(tern.json.encode(tern.json.array(s.data)))
	elseif act == "previous" and s.level == "preview" and s.offset > 0 then s.offset = math.max(0, s.offset - PAGE); s.data = {}; s.inspected = nil; fetch(s)
	elseif act == "next" and s.level == "preview" and #s.data == PAGE then s.offset += PAGE; s.data = {}; s.inspected = nil; fetch(s)
	elseif act == "copy" then s.cx:copy(s.project .. "." .. s.dataset .. "." .. s.table)
	elseif act == "sql" then s.cx:copy("SELECT *\nFROM `" .. s.project .. "." .. s.dataset .. "." .. s.table .. "`\nLIMIT 50;") end
end

tern.block.define("browser", {
	features = { "edit" },
	init = function(cx, args, saved)
		local project = if type(saved) == "table" then saved.project else args[1]
		local s = { cx = cx, project = project or "", dataset = "", table = "", level = "projects",
			data = {}, cursor = 1, loading = false, error = nil, request = 0, offset = 0, editing = false, input = "", filter = "", searching = false }
		if s.project ~= "" then s.level = "datasets" end
		runs[cx.pane] = s
		fetch(s)
		return s
	end,
	title = function(s) return "BigQuery" .. (if s.project ~= "" then " · " .. s.project else "") end,
	view = function(s)
		local crumbs = { button("Projects", "projects", s.loading) }
		if s.project ~= "" then table.insert(crumbs, button(s.project, "datasets", s.loading)) end
		if s.dataset ~= "" and s.level ~= "projects" and s.level ~= "datasets" then table.insert(crumbs, button(s.dataset, "tables", s.loading)) end
		if s.level == "schema" or s.level == "preview" then table.insert(crumbs, ui.text({ ui.span(s.table, "strong") })) end
		local trail = {}
		for i, crumb in crumbs do
			if i > 1 then table.insert(trail, ui.text({ ui.span("/", "muted") })) end
			table.insert(trail, crumb)
		end
		local parts = {
			ui.row({ ui.text({ ui.span("BigQuery", "strong") }), ui.badge("Explorer", "muted") }),
			ui.node("row", { role = "bq-breadcrumbs" }, trail),
		}
		if is_listing(s) then
			local bar = ui.row({ ui.node("input", { key = "search", text = s.filter, cursor = s.caret or units(s.filter),
				anchor = s.anchor, placeholder = "Search " .. s.level .. "…", aria = "Search " .. s.level, grow = 1 }),
				button("Clear", "clear", s.filter == ""), ui.badge(#filtered(s) .. " of " .. #s.data, "muted") })
			bar.p = { key = "searchbar", role = "bq-searchbar" }
			table.insert(parts, bar)
		end
		if s.editing then
			local form = ui.row({ ui.node("input", { key = "project", text = s.input, cursor = s.caret or units(s.input),
				anchor = s.anchor, placeholder = "Project ID", aria = "Project ID", grow = 1 }),
				button("Open", "open-project", s.loading), button("Cancel", "cancel-project") })
			form.p = { key = "projectform", role = "bq-projectform" }
			table.insert(parts, form)
		end
		if s.loading then
			local loading = ui.card("Loading " .. s.level, { ui.progress(nil, "Connecting to BigQuery") })
			loading.p = { key = "loading", tone = "info" }; table.insert(parts, loading)
		elseif s.error then
			local problem = ui.card("Unable to load " .. s.level, { ui.text(s.error), ui.row({ button("Try again", "refresh") }) })
			problem.p = { tone = "error", key = "problem" }; table.insert(parts, problem)
		else
			if s.level == "schema" or s.level == "preview" then
				table.insert(parts, ui.node("tabs", { key = "tabs", active = s.level,
					items = { { id = "schema", label = "Schema" }, { id = "preview", label = "Preview" } } }))
				table.insert(parts, ui.row({ button("Copy name", "copy"), button("Copy SQL", "sql") }))
			end
			table.insert(parts, content(s))
		end
		local main = ui.col(parts); main.p = { role = "bq-browser" }
		local controls = { button("Back", "back", s.loading or s.level == "projects"),
			button("Refresh", "refresh", s.loading), button("Open project…", "project", s.loading) }
		if is_listing(s) then table.insert(controls, button("Open selected", "open", s.loading or not open_selected(s))) end
		local dock = ui.col({ ui.row(controls) }); dock.p = { role = "bq-footer" }
		return { main = main, dock = dock }
	end,

	key = function(s, key)
		if s.loading then return false end
		if s.searching or s.editing then
			if key.name == "escape" then
				if s.searching then s.filter, s.cursor = "", 1 end
				focus(s, nil)
			elseif key.name == "enter" then
				if s.editing then action(s, "open-project") else focus(s, nil) end
			elseif key.name == "down" and s.searching then focus(s, nil)
			else return edit_field(s, key) end
			return true
		end
		local k = key.name
		if k == "/" and is_listing(s) then action(s, "search")
		elseif k == "p" then action(s, "project")
		elseif k == "up" or k == "k" then s.cursor = math.max(1, s.cursor - 1)
		elseif k == "down" or k == "j" then s.cursor = math.max(1, math.min(#filtered(s), s.cursor + 1))
		elseif k == "enter" then open(s, open_selected(s))
		elseif k == "escape" then
			if s.filter ~= "" then s.filter, s.cursor = "", 1 else back(s) end
		elseif k == "r" then fetch(s)
		elseif k == "v" then action(s, "preview")
		elseif k == "y" and (s.level == "schema" or s.level == "preview") then action(s, "copy")
		else return false end
		return true
	end,
	event = function(s, ev)
		if ev.ev == "focus" then
			if ev.id == "main.searchbar.search" then s.caret = units(s.filter); s.anchor = nil; focus(s, "search")
			elseif ev.id == "main.projectform.project" then focus(s, "project") end
		elseif ev.ev == "edit" and (ev.id == "main.searchbar.search" or ev.id == "main.projectform.project") then
			local property = if ev.id == "main.searchbar.search" then "filter" else "input"
			local text = s[property]
			if ev.len and ev.len ~= units(text) then return end
			s[property] = string.sub(text, 1, byte_offset(text, ev.from)) .. string.gsub(ev.text or "", "[\r\n]", " ") .. string.sub(text, byte_offset(text, ev.to) + 1)
			s.caret, s.anchor, s.cursor = ev.cursor, nil, 1
		elseif ev.ev == "select" and ev.id == "main.tabs" then
			if not s.loading and (ev.item == "schema" or ev.item == "preview") and ev.item ~= s.level then navigate(s, ev.item) end
		elseif (ev.ev == "select" or ev.ev == "activate") and ev.item then
			for i, source in filtered(s) do
				if ev.item == "main.objects." .. (id(s, s.data[source]) or tostring(source)) then
					s.cursor = i; focus(s, nil)
					if ev.ev == "activate" then open(s, source) end
					break
				end
			end
		elseif ev.ev == "action" then action(s, ev.act, ev.value) end
	end,

	save = function(s) return { project = s.project } end,
})
