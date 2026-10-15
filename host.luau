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

-- Variants: "primary", "secondary" (default), "ghost", "tool" (compact header action), "crumb" and "rownum".
local function button(label, action, disabled, variant)
	local class = "bq-button bq-" .. (variant or "secondary")
	if disabled then class ..= " bq-disabled" end
	return ui.el("button", { text = label, class = class, disabled = disabled == true,
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
					if s.level == "schema" then s.schema = (data.schema or {}).fields or {}; s.info = data; s.schemaTarget = target(s) end
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
	elseif s.level == "tables" then s.table = name; s.tableType = item.type; navigate(s, "schema") end
end

local function back(s)
	local parent = { datasets = "projects", tables = "datasets", schema = "tables", preview = "schema" }
	if parent[s.level] then navigate(s, parent[s.level]) end
end

local function with(n, props)
	n.p = n.p or {}
	for k, v in props do n.p[k] = v end
	return n
end

-- Every span carries a style token so it renders as its own element.
local function text(spans, role)
	return with(ui.text(spans), { role = role })
end

local function plural(n, one, many)
	return if n == 1 then one else many
end

local function grouped(value)
	local sign, digits = string.match(tostring(value or ""), "^(-?)(%d+)$")
	if not digits then return nil end
	local out = string.reverse((string.gsub(string.reverse(digits), "(%d%d%d)", "%1,")))
	if string.sub(out, 1, 1) == "," then out = string.sub(out, 2) end
	return sign .. out
end

local function bytes(value)
	local n = tonumber(value)
	if not n then return nil end
	local suffixes = { "B", "KB", "MB", "GB", "TB", "PB" }
	local i = 1
	while n >= 1024 and i < #suffixes do n /= 1024; i += 1 end
	return if i == 1 then string.format("%d B", n) else string.format("%.1f %s", n, suffixes[i])
end

-- Milliseconds since the epoch as a UTC date (days-from-civil inverse).
local function date(ms)
	local t = tonumber(ms)
	if not t then return nil end
	local secs = t // 1000
	local days = secs // 86400
	local rem = secs - days * 86400
	local z = days + 719468
	local era = z // 146097
	local doe = z - era * 146097
	local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
	local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
	local mp = (5 * doy + 2) // 153
	local day = doy - (153 * mp + 2) // 5 + 1
	local month = if mp < 10 then mp + 3 else mp - 9
	local year = yoe + era * 400 + (if month <= 2 then 1 else 0)
	return string.format("%04d-%02d-%02d %02d:%02d UTC", year, month, day, rem // 3600, rem % 3600 // 60)
end

local KINDS = { TABLE = "Table", VIEW = "View", MATERIALIZED_VIEW = "Materialized view", EXTERNAL = "External table",
	SNAPSHOT = "Snapshot", CLONE = "Clone", MODEL = "Model", LINKED = "Linked", DEFAULT = "Dataset" }
local KIND_ICONS = { VIEW = "eye", MATERIALIZED_VIEW = "eye", EXTERNAL = "link" }
local KIND_TONES = { VIEW = "info", MATERIALIZED_VIEW = "accent", EXTERNAL = "warning", SNAPSHOT = "muted", CLONE = "muted", LINKED = "info" }

local function kind(t)
	if type(t) ~= "string" or t == "" then return nil end
	return KINDS[t] or (string.sub(t, 1, 1) .. string.lower(string.gsub(string.sub(t, 2), "_", " ")))
end

local TYPE_GROUPS = { INTEGER = "number", INT64 = "number", FLOAT = "number", FLOAT64 = "number", NUMERIC = "number",
	BIGNUMERIC = "number", DECIMAL = "number", BIGDECIMAL = "number", STRING = "text", BYTES = "text", BOOLEAN = "bool",
	BOOL = "bool", DATE = "time", DATETIME = "time", TIME = "time", TIMESTAMP = "time", INTERVAL = "time",
	RECORD = "record", STRUCT = "record", RANGE = "record", GEOGRAPHY = "geo", JSON = "json" }

local function schema_rows(fields, prefix, depth, rows)
	for _, f in fields do
		local name = prefix .. f.name
		table.insert(rows, { name, f.type or "", f.mode or "NULLABLE", f.description or "", depth = depth, prefix = prefix, leaf = f.name })
		if f.fields then schema_rows(f.fields, name .. ".", depth + 1, rows) end
	end
end

local function cell(value)
	if value == nil or value == tern.json.null then return "NULL" end
	if type(value) == "table" then return tern.json.encode(value) end
	return tostring(value)
end

local function cell_spans(value)
	if value == nil or value == tern.json.null then return { ui.span("NULL", "dim") } end
	return { ui.span(cell(value), "mono") }
end

local function sized(n, width)
	n.p.min, n.p.max, n.p.shrink = { w = width .. "ch" }, { w = width .. "ch" }, 0
	return n
end

local function grid_row(cells, key, total, index)
	-- Alternate roles give zebra striping without relying on :nth-child.
	local role = if index and index % 2 == 0 then "bq-grid-row-alt" else "bq-grid-row"
	if not index then role = "bq-grid-head" end
	return with(ui.row(cells), { key = key, role = role, min = { w = total .. "ch" }, shrink = 0, gap = "none" })
end

local function header_cell(label, width, align)
	return sized(with(text(label, if align == "end" then "bq-grid-header-end" else "bq-grid-header"), { title = label }), width)
end

-- The last schema column takes the pane's spare width; every row gets the same constraints, so columns stay aligned.
local function fluid(n, width)
	n.p.min, n.p.max, n.p.grow, n.p.shrink = { w = width .. "ch" }, nil, 1, 1
	return n
end

local function stat(label, value)
	return with(ui.col({ text({ ui.span(label, "muted") }, "bq-stat-label"), text({ ui.span(value, "strong") }, "bq-stat-value") }),
		{ role = "bq-stat" })
end

local function properties(info)
	local tiles = {}
	local function add(label, value) if value and value ~= "" then table.insert(tiles, stat(label, value)) end end
	add("Rows", grouped(info.numRows))
	add("Logical size", bytes(info.numBytes))
	add("Physical size", bytes(info.numTotalPhysicalBytes))
	add("Location", info.location)
	add("Created", date(info.creationTime))
	add("Modified", date(info.lastModifiedTime))
	add("Expires", date(info.expirationTime))
	local tp = info.timePartitioning
	if type(tp) == "table" then add("Partitioning", string.lower(tp.type or "DAY") .. " on " .. (tp.field or "_PARTITIONTIME")) end
	local rp = info.rangePartitioning
	if type(rp) == "table" and rp.field then add("Partitioning", "range on " .. rp.field) end
	if type(info.clustering) == "table" and type(info.clustering.fields) == "table" then
		add("Clustering", table.concat(info.clustering.fields, ", "))
	end
	return with(ui.row(tiles), { key = "properties", role = "bq-stats" })
end

local function schema_content(s)
	local info = s.data
	local rows = {}
	schema_rows((info.schema or {}).fields or {}, "", 0, rows)
	local widths = { 28, 16, 12, 32 }
	local nested = 0
	for _, row in rows do
		widths[1] = math.max(widths[1], math.min(48, units(row[1]) + 4))
		if row.depth > 0 then nested += 1 end
	end
	local total = widths[1] + widths[2] + widths[3] + widths[4]
	local grid = { grid_row({ header_cell("Field", widths[1]), header_cell("Type", widths[2]),
		header_cell("Mode", widths[3]), fluid(header_cell("Description", widths[4]), widths[4]) }, "header", total) }
	for i, row in rows do
		local name = { ui.span(row.leaf, "mono") }
		if row.prefix ~= "" then name = { ui.span(row.prefix, "dim"), ui.span(row.leaf, "mono") } end
		local group = TYPE_GROUPS[row[2]] or "other"
		local chip = ui.el("span", { class = "bq-type bq-type-" .. group, text = if row[2] ~= "" then row[2] else "?", title = row[2] })
		local mode = { ui.span(row[3], if row[3] == "NULLABLE" then "dim" elseif row[3] == "REPEATED" then "accent" else "muted") }
		local description = if row[4] ~= "" then { ui.span(row[4], "muted") } else { ui.span("—", "dim") }
		local cells = {
			sized(with(text(name, "bq-field-" .. math.min(row.depth, 3)), { title = row[1] }), widths[1]),
			sized(with(ui.row({ chip }), { role = "bq-schema-cell" }), widths[2]),
			sized(with(text(mode, "bq-schema-mode"), { title = row[3] }), widths[3]),
			fluid(with(text(description, "bq-schema-cell"), { title = row[4] }), widths[4]),
		}
		table.insert(grid, grid_row(cells, "field-" .. i, total, i))
	end
	local parts = { properties(info) }
	if type(info.description) == "string" and info.description ~= "" then
		table.insert(parts, text({ ui.span(info.description, "muted") }, "bq-description"))
	end
	local query = (info.view or {}).query or (info.materializedView or {}).query
	if type(query) == "string" and query ~= "" then
		table.insert(parts, with(ui.card({ ui.span("Definition", "strong") }, { ui.code(query, "sql") }), { key = "definition" }))
	end
	local heading = { text({ ui.span("Schema", "strong") }, "bq-section-title"),
		ui.badge(#rows .. plural(#rows, " field", " fields"), "muted") }
	if nested > 0 then table.insert(heading, ui.badge(nested .. " nested", "info")) end
	table.insert(parts, with(ui.row(heading), { role = "bq-section" }))
	table.insert(parts, ui.el("div", { key = "schema-grid", class = "bq-grid-scroll bq-schema-grid", attrs = {
		role = "region", ["aria-label"] = "Schema fields. Scroll horizontally to see all four columns." } }, grid))
	if #rows == 0 then table.insert(parts, text({ ui.span("This table has no schema fields.", "muted") }, "bq-note")) end
	return ui.col(parts)
end

local NUMERIC = { INTEGER = true, INT64 = true, FLOAT = true, FLOAT64 = true, NUMERIC = true, BIGNUMERIC = true, DECIMAL = true, BIGDECIMAL = true }

local function preview_content(s)
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
	local widths, total = {}, 8
	for _, name in names do
		local width = math.max(14, units(name) + 3)
		for _, row in s.data do width = math.max(width, math.min(36, units(cell(row[name])) + 2)) end
		widths[name] = math.min(40, width)
		total += widths[name]
	end
	local head = { header_cell("#", 8, "end") }
	for _, name in names do table.insert(head, header_cell(name, widths[name], if NUMERIC[types[name]] then "end" else nil)) end
	local grid = { grid_row(head, "header", total) }
	for i, row in s.data do
		local inspect = sized(button(tostring(s.offset + i), "inspect=" .. i, false, "rownum"), 8)
		if s.inspected == i then inspect.p.class ..= " bq-on" end
		local cells = { inspect }
		for _, name in names do
			local value = row[name]
			local numeric = NUMERIC[types[name]]
			local role = if value == nil or value == tern.json.null then (if numeric then "bq-grid-null-end" else "bq-grid-null")
				elseif numeric then "bq-grid-number" else "bq-grid-cell"
			table.insert(cells, sized(with(text(cell_spans(value), role), { title = cell(value) }), widths[name]))
		end
		table.insert(grid, grid_row(cells, "row-" .. (s.offset + i), total, i))
	end
	local range = if #s.data > 0 then "Rows " .. grouped(s.offset + 1) .. "–" .. grouped(s.offset + #s.data)
		else "No rows from " .. grouped(s.offset + 1)
	local toolbar = with(ui.row({
		button("‹ Previous", "previous", s.offset == 0),
		button("Next ›", "next", #s.data < PAGE),
		text({ ui.span(range, "strong"), ui.span("  ·  " .. #names .. plural(#names, " column", " columns"), "muted") }, "bq-range"),
		button("Copy page JSON", "copy-page", #s.data == 0, "ghost"),
	}), { role = "bq-toolbar" })
	local parts = { toolbar, ui.el("div", { class = "bq-grid-scroll", key = "grid", attrs = { role = "region",
		["aria-label"] = "Preview data. Scroll horizontally to see every column." } }, grid) }
	if #s.data == 0 then
		table.insert(parts, with(ui.card({ ui.span("No rows on this page", "strong") }, {
			text({ ui.span(if s.offset > 0 then "The table ends before this page. Go back a page." else "This table has no rows, or bq head can't read it (views have no stored rows).", "muted") }, "bq-note") }),
			{ key = "empty-page" }))
	end
	if s.inspected and s.data[s.inspected] then
		local fields = {}
		for _, name in names do table.insert(fields, { { ui.span(name, "mono") }, cell_spans(s.data[s.inspected][name]) }) end
		table.insert(parts, with(ui.card({ ui.span("Row " .. grouped(s.offset + s.inspected), "strong"), ui.span("  ·  " .. #names .. plural(#names, " field", " fields"), "muted") },
			{ with(ui.kv(fields), { role = "bq-inspector" }), ui.row({ button("Close inspector", "close-inspector") }) }), { key = "inspector" }))
	end
	table.insert(parts, text({ ui.span("Click a row number to inspect it. BigQuery doesn't guarantee row order in a preview.", "dim") }, "bq-note"))
	return ui.col(parts)
end

local NOUNS = { projects = { "project", "projects" }, datasets = { "dataset", "datasets" }, tables = { "table", "tables" } }

local function listing_item(s, item)
	local name = id(s, item) or "Unknown"
	local friendly = item.friendlyName or item.name
	if friendly == name or friendly == "" then friendly = nil end
	if s.level == "projects" then return { label = name, detail = friendly, icon = "folder" } end
	if s.level == "datasets" then
		local value = item.location
		if item.type and item.type ~= "DEFAULT" then value = kind(item.type) .. (if value then " · " .. value else "") end
		return { label = name, detail = friendly, value = value, icon = "database", tone = KIND_TONES[item.type] }
	end
	local detail = friendly
	if not detail and type(item.timePartitioning) == "table" then
		detail = "partitioned by " .. string.lower(item.timePartitioning.type or "day")
	end
	return { label = name, detail = detail, value = kind(item.type), icon = KIND_ICONS[item.type] or "table", tone = KIND_TONES[item.type] }
end

local function listing(s)
	local items = {}
	local indices = filtered(s)
	for _, source in indices do table.insert(items, listing_item(s, s.data[source])) end
	local noun = NOUNS[s.level][2]
	local list = ui.list(items)
	list.p = { key = "objects", filter = s.filter, max = { lines = math.max(4, math.floor((s.cx.rows - 10) * 0.72)) },
		empty = if s.filter ~= "" then "No " .. noun .. " match “" .. s.filter .. "”. Press Esc to clear the search." else "No " .. noun .. " found.",
		selected = if indices[s.cursor] then "main.objects." .. (id(s, s.data[indices[s.cursor]]) or tostring(indices[s.cursor])) else nil }
	for i, child in list.c or {} do
		child.p = child.p or {}
		child.p.key = id(s, s.data[indices[i]]) or tostring(indices[i])
		-- Native select/activate works for both regular and virtual lists.
	end
	return list
end

local function empty_state(s)
	local head, body, actions
	if s.level == "projects" then
		head, body = "No projects", "Your account can't list any projects. Open a project by its ID instead."
		actions = { button("Open project…", "project", false, "primary") }
	elseif s.level == "datasets" then
		head, body = "No datasets", s.project .. " has no datasets that your account can read."
		actions = { button("Back to projects", "projects"), button("Open project…", "project", false, "ghost") }
	else
		head, body = "No tables", s.dataset .. " has no tables or views yet."
		actions = { button("Back to datasets", "datasets") }
	end
	return with(ui.card({ ui.span(head, "strong") }, { text({ ui.span(body, "muted") }, "bq-note"), ui.row(actions) }), { key = "empty" })
end

local function content(s)
	if s.level == "schema" then return schema_content(s) end
	if s.level == "preview" then return preview_content(s) end
	if #s.data == 0 and s.filter == "" then return empty_state(s) end
	return listing(s)
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

local function header(s)
	local trail = { text({ ui.span("BigQuery", "strong") }, "bq-brand") }
	local function crumb(label, act)
		table.insert(trail, text({ ui.span("›", "dim") }, "bq-crumb-sep"))
		table.insert(trail, button(label, act, s.loading, "crumb"))
	end
	local detail = s.level == "schema" or s.level == "preview"
	if s.level ~= "projects" then crumb("Projects", "projects") end
	if s.level == "tables" or detail then crumb(s.project, "datasets") end
	if detail then crumb(s.dataset, "tables") end
	local title, tableType = "Projects", nil
	local badge = nil
	if s.level == "datasets" then title, badge = s.project, "Project"
	elseif s.level == "tables" then title, badge = s.dataset, "Dataset"
	elseif detail then
		tableType = if s.schemaTarget == target(s) and s.info then s.info.type else s.tableType
		title, badge = s.table, kind(tableType) or "Table"
	end
	local heading = { text({ ui.span(title, "strong") }, "bq-title") }
	if badge then table.insert(heading, ui.badge(badge, KIND_TONES[tableType] or "neutral")) end
	local bar = { with(ui.row(heading), { role = "bq-heading" }) }
	local tools = {}
	if detail then
		table.insert(tools, button("Copy name", "copy", s.loading, "tool"))
		table.insert(tools, button("Copy SQL", "sql", s.loading, "tool"))
	else
		table.insert(tools, button("Open project…", "project", s.loading, "tool"))
	end
	table.insert(tools, button("Refresh", "refresh", s.loading, "tool"))
	table.insert(bar, with(ui.row(tools), { role = "bq-actions" }))
	return with(ui.col({ with(ui.row(trail), { role = "bq-breadcrumbs" }), with(ui.row(bar), { role = "bq-titlebar" }) }),
		{ role = "bq-header" })
end

local function command_line(s)
	if s.level == "projects" then return "bq ls --projects" end
	if s.level == "datasets" then return "bq ls " .. s.project .. ":" end
	if s.level == "tables" then return "bq ls " .. s.project .. ":" .. s.dataset end
	if s.level == "schema" then return "bq show " .. target(s) end
	return "bq head --start_row=" .. s.offset .. " --max_rows=" .. PAGE .. " " .. target(s)
end

local SUBJECTS = { projects = "projects", datasets = "datasets", tables = "tables", schema = "table details", preview = "rows" }

local function loading_card(s)
	local subject = SUBJECTS[s.level]
	if s.level == "preview" then subject ..= " " .. grouped(s.offset + 1) .. "–" .. grouped(s.offset + PAGE) end
	return with(ui.card({ ui.span("Loading " .. subject .. "…", "strong") }, { ui.progress(nil, { ui.span(command_line(s), "muted") }) }),
		{ key = "loading", tone = "info" })
end

local function error_hint(message)
	local e = string.lower(message)
	local function has(term) return string.find(e, term, 1, true) ~= nil end
	if has("timed out") then return "BigQuery didn't answer within 30 seconds. Try again in a moment." end
	if has("could not start bq") then return "Tern couldn't run bq on this host." end
	if has("invalid json") then return "bq printed something other than JSON. Check its configuration in a shell." end
	if has("reauth") or has("credential") or has("gcloud auth") or has("unauthenticated") or has("invalid_grant") then
		return "Your Google Cloud sign-in may have expired. Run gcloud auth login in a shell, then try again."
	end
	if has("access denied") or has("permission") then return "Your account can't read this resource. Check its IAM roles or open another project." end
	if has("not found") then return "The resource doesn't exist, or it was deleted or renamed." end
	return nil
end

local function error_card(s)
	local message = (string.gsub((string.gsub(s.error, "^bq failed: ", "")), "%s+$", ""))
	local body = {}
	local hint = error_hint(s.error)
	if hint then table.insert(body, text({ ui.span(hint, "mono") }, "bq-error-hint")) end
	table.insert(body, text({ ui.span(message, "mono") }, "bq-error-detail"))
	local actions = { button("Try again", "refresh", false, "primary") }
	if s.level ~= "projects" then table.insert(actions, button("Back", "back", false, "ghost")) end
	table.insert(body, ui.row(actions))
	return with(ui.card({ ui.span("Couldn't load " .. SUBJECTS[s.level], "strong error") }, body), { tone = "error", key = "problem" })
end

local function hints(keys)
	local spans = {}
	for i, pair in keys do
		if i > 1 then table.insert(spans, ui.span("    ", "dim")) end
		table.insert(spans, ui.span(pair[1], "key"))
		table.insert(spans, ui.span(" " .. pair[2], "muted"))
	end
	return text(spans, "bq-hints")
end

local function footer(s)
	local keys
	if s.searching then keys = { { "↵", "done" }, { "↓", "results" }, { "esc", "clear" } }
	elseif s.editing then keys = { { "↵", "open" }, { "esc", "cancel" }, { "⌃U", "clear" } }
	elseif is_listing(s) then
		keys = { { "↑↓", "select" }, { "↵", "open" }, { "/", "search" } }
		table.insert(keys, if s.level == "projects" then { "p", "project ID" } else { "esc", "back" })
	elseif s.level == "schema" then keys = { { "v", "preview" }, { "y", "copy name" }, { "esc", "back" } }
	else keys = { { "y", "copy name" }, { "esc", "schema" } } end
	if not (s.searching or s.editing) then table.insert(keys, { "r", "refresh" }) end
	local actions = { button("Back", "back", s.loading or s.level == "projects", "ghost") }
	if is_listing(s) then
		table.insert(actions, button("Open selected", "open", s.loading or not open_selected(s), if s.editing then nil else "primary"))
	end
	return with(ui.col({ with(ui.row({ hints(keys), with(ui.row(actions), { role = "bq-footer-actions" }) }), { role = "bq-footer-bar" }) }),
		{ role = "bq-footer" })
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
		local detail = s.level == "schema" or s.level == "preview"
		local parts = { header(s) }
		if s.editing then
			local form = ui.row({ ui.node("input", { key = "project", text = s.input, cursor = s.caret or units(s.input),
				anchor = s.anchor, placeholder = "Project ID, for example bigquery-public-data", aria = "Project ID", grow = 1 }),
				button("Open", "open-project", s.loading, "primary"), button("Cancel", "cancel-project", false, "ghost") })
			table.insert(parts, with(form, { key = "projectform", role = "bq-projectform" }))
		end
		if is_listing(s) then
			local noun = NOUNS[s.level]
			local total = #s.data
			local count = if s.loading then "…" elseif s.error then "—"
				elseif s.filter == "" then grouped(total) .. " " .. plural(total, noun[1], noun[2])
				else grouped(#filtered(s)) .. " of " .. grouped(total)
			local bar = ui.row({ ui.node("input", { key = "search", text = s.filter, cursor = s.caret or units(s.filter),
				anchor = s.anchor, placeholder = "Search " .. noun[2] .. " by name or type…", aria = "Search " .. noun[2], grow = 1 }),
				text({ ui.span(count, "muted") }, "bq-count"), button("Clear", "clear", s.filter == "", "ghost") })
			table.insert(parts, with(bar, { key = "searchbar", role = "bq-searchbar" }))
		end
		if detail then
			table.insert(parts, ui.node("tabs", { key = "tabs", active = s.level,
				items = { { id = "schema", label = "Schema" }, { id = "preview", label = "Preview" } } }))
		end
		if s.loading then table.insert(parts, loading_card(s))
		elseif s.error then table.insert(parts, error_card(s))
		else table.insert(parts, content(s)) end
		return { main = with(ui.col(parts), { role = "bq-browser" }), dock = footer(s) }
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
