-- Executed by tests/run.py with the production block injected below.
local definition, pending, lastArgv, copied
local decoded, lastOptions
local configuredPython = nil
local installedPython = false
local function node(kind, p, c) return { k = kind, p = p or {}, c = c } end
local ui = { node = node, el = function(tag, props, children) return node(tag, props, children) end, span = function(text, style) return {t = text, s = style} end, card = function(head, children) return node("card", {head = head}, children) end }
for _, kind in { "text", "code", "progress", "kv", "table", "badge", "col", "row" } do
	ui[kind] = function(a, b)
		if kind == "col" or kind == "row" then return node(kind, {}, a) end
		return node(kind, { a = a, b = b })
	end
end
ui.list = function(items)
	local children = {}
	for _, item in items do table.insert(children, node("item", item)) end
	return node("list", {}, children)
end
local tern = {
	ui = ui, getenv = function(name) return if name == "CLOUDSDK_PYTHON" then configuredPython else nil end,
	fs = { exists = function(path) return installedPython and path == "/opt/homebrew/bin/python3.13" end },
	pane = { list = function() return { { pane = 1 } } end },
	json = { null = {}, decode = function(text)
		if text == "bad" then error("Invalid JSON") end
		return decoded
	end, encode = function() return "{}" end },
	process = { run = function(argv, opts, cb) lastArgv = argv; lastOptions = opts; pending = cb end },
	block = { define = function(_, def) definition = def end },
}
-- BLOCK_SOURCE
local cx = { pane = 1, rows = 30, render = function() end, frame = function() end, toast = function() end, copy = function(_, text) copied = text end }
local function finish(data)
	decoded = data
	pending({ status = 0, stdout = "json", stderr = "" })
end
local function hasArg(arg)
	for _, a in lastArgv do if a == arg then return true end end
	return false
end
local function key(s, name) definition.key(s, { name = name }) end
-- Text of a text node, whether it holds a plain string or styled spans.
local function flat(n)
	local a = n.p.a
	if type(a) == "string" then return a end
	if a.t then return a.t end
	local out = ""
	for _, span in a do out ..= if type(span) == "string" then span else span.t end
	return out
end
local function find(n, wanted)
	if type(n) ~= "table" then return nil end
	if n.p and n.p.key == wanted then return n end
	for _, child in n.c or {} do
		local hit = find(child, wanted)
		if hit then return hit end
	end
	return nil
end
local s = definition.init(cx, {}, nil)
assert(hasArg("--projects=true"))
finish({ { id = "test-project" } })
key(s, "enter")
assert(hasArg("test-project:") and hasArg("--datasets=true"))
finish({ { datasetReference = { datasetId = "analytics" } } })
key(s, "enter")
assert(hasArg("test-project:analytics"))
finish({ { tableReference = { tableId = "events" }, type = "TABLE" } })
key(s, "enter")
assert(hasArg("show") and hasArg("test-project:analytics.events"))
finish({ type = "TABLE", numRows = "164656", numBytes = "6432064", creationTime = "1457975805856",
	schema = { fields = { { name = "user", type = "RECORD", fields = { { name = "id", type = "STRING" } } } } } })
local view = definition.view(s)
local schemaGrid = find(view.main, "schema-grid")
assert(flat(schemaGrid.c[3].c[1]) == "user.id", "Nested schema paths must render")
local stats = {}
for _, tile in find(view.main, "properties").c do stats[flat(tile.c[1])] = flat(tile.c[2]) end
assert(stats.Rows == "164,656" and stats["Logical size"] == "6.1 MB" and stats.Created == "2016-03-14 17:16 UTC",
	"Table properties are human-readable")
key(s, "y")
assert(copied == "test-project.analytics.events")
key(s, "v")
assert(hasArg("head") and hasArg("--max_rows=50") and hasArg("--start_row=0"))
local page = {}
for i = 1, 50 do page[i] = { id = i } end
finish(page)
definition.event(s, { ev = "action", act = "next" })
assert(hasArg("--start_row=50"))
finish({})
definition.event(s, { ev = "action", act = "next" })
assert(s.offset == 50, "Do not advance past the final page")
definition.event(s, { ev = "action", act = "previous" })
assert(hasArg("--start_row=0"))
pending({ status = 1, stdout = "", stderr = "Permission denied" })
assert(string.find(s.error, "Permission denied", 1, true))
key(s, "r")
pending({ status = 0, stdout = "bad", stderr = "" })
assert(string.find(s.error, "invalid JSON", 1, true))
-- A restarted pane must ignore callbacks from its old state.
key(s, "r")
local oldCallback = pending
local replacement = definition.init(cx, { "other-project" }, nil)
decoded = { { id = "stale" } }
oldCallback({ status = 0, stdout = "json", stderr = "" })
assert(replacement.loading and #replacement.data == 0)
assert(definition.save(replacement).project == "other-project")
assert(not hasArg("query"), "Browsing must not execute SQL")
print("PASS: navigation, nested schema, preview paging, errors, persistence, stale callbacks")

installedPython = true
definition.init(cx, {}, nil)
assert(lastOptions.env.CLOUDSDK_PYTHON == "/opt/homebrew/bin/python3.13")
configuredPython = "/custom/python"
definition.init(cx, {}, nil)
assert(lastOptions.env.CLOUDSDK_PYTHON == nil, "Preserve explicitly configured Python via inherited environment")
print("PASS: desktop Python fallback and explicit configuration")

tern.getenv = function(name)
	if name == "TERN_BIGQUERY_BQ" then return "/custom/google-cloud-sdk/bin/bq" end
	if name == "PATH" then return "/usr/bin:/bin" end
	return nil
end
definition.init(cx, {}, nil)
assert(lastArgv[1] == "/custom/google-cloud-sdk/bin/bq")
assert(lastOptions.env.PATH == "/custom/google-cloud-sdk/bin:/usr/bin:/bin", "bq's sibling gcloud must be discoverable without losing inherited PATH")
print("PASS: gcloud discovery with a minimal desktop PATH and custom bq path")
local searchState = definition.init(cx, {}, nil)
finish({ { id = "alpha-dev", name = "Sandbox" }, { id = "beta-prod", name = "Warehouse" }, { id = "gamma-prod" } })
key(searchState, "/")
definition.key(searchState, { name = "paste", text = "PROD beta" })
assert(searchState.filter == "PROD beta")
local searchView = definition.view(searchState)
local listing = searchView.main.c[#searchView.main.c]
assert(#listing.c == 1 and listing.c[1].p.key == "beta-prod")
key(searchState, "enter") -- Finish editing without opening.
assert(searchState.level == "projects")
key(searchState, "enter")
assert(searchState.project == "beta-prod", "Filtered Enter must open the matching source row")
finish({ { datasetReference = { datasetId = "one" } }, { datasetReference = { datasetId = "two" } } })
assert(searchState.filter == "", "Filters reset when navigating")
key(searchState, "/")
definition.key(searchState, { name = "paste", text = "[no match]" })
assert(#definition.view(searchState).main.c[#definition.view(searchState).main.c].c == 0, "Search terms are literal, not patterns")
key(searchState, "enter")
key(searchState, "enter")
assert(searchState.level == "datasets", "No matches must not open a resource")
key(searchState, "escape")
assert(searchState.filter == "" and searchState.level == "datasets")
key(searchState, "/")
definition.key(searchState, { name = "paste", text = "two" })
key(searchState, "enter")
definition.event(searchState, { ev = "action", act = "open", value = "2" })
assert(searchState.dataset == "two", "Filtered click must use source index")
print("PASS: literal case-insensitive search, multiple terms, keyboard/click mapping, empty matches and clearing")

local native = definition.init(cx, {}, nil)
finish({ {id = "one"}, {id = "two"} })
definition.event(native, {ev = "focus", id = "main.searchbar.search"})
definition.event(native, {ev = "edit", id = "main.searchbar.search", from = 0, to = 0, text = "two", cursor = 3, len = 0})
assert(native.filter == "two")
definition.key(native, { name = "a", meta = true })
definition.key(native, { name = "paste", text = "one" })
assert(native.filter == "one", "Select-all and replacement must work")
definition.event(native, {ev = "activate", id = "main.objects", item = "main.objects.one"})
assert(native.project == "one", "Virtual row activation opens the selected resource")
finish({})
assert(find(definition.view(native).main, "empty"), "An empty project explains itself instead of showing a blank list")
key(native, "/")
definition.key(native, {name = "paste", text = "😀é"})
key(native, "backspace")
assert(native.filter == "😀", "Backspace preserves UTF-8 and UTF-16 boundaries")
key(native, "backspace")
assert(native.filter == "")
print("PASS: native edits, select-all, virtual-list activation and Unicode editing")
local wide = definition.init(cx, { "test-project" }, nil)
finish({ {datasetReference = {datasetId = "dataset"}} })
key(wide, "enter")
finish({ {tableReference = {tableId = "wide"}} })
key(wide, "enter")
local fields = {}
for i = 1, 35 do table.insert(fields, {name = "field_" .. i, type = "STRING"}) end
finish({schema = {fields = fields}})
key(wide, "v")
finish({ {field_1 = "first", field_35 = "last", extra = "discovered"}, {field_2 = "second"} })
local preview = definition.view(wide).main.c
local body = preview[#preview]
local grid = body.c[2]
assert(grid.k == "div" and grid.p.class == "bq-grid-scroll")
assert(#grid.c[1].c == 37, "All 35 schema fields, extra field and row number must render")
assert(grid.c[1].c[2].p.a == "field_1" and grid.c[1].c[36].p.a == "field_35", "Preserve schema column order")
assert(flat(grid.c[2].c[36]) == "last", "Far-right values must render")
assert(flat(grid.c[2].c[3]) == "NULL", "Render schema fields absent from the row")
assert(flat(grid.c[2].c[37]) == "discovered", "Keep unexpected returned fields")
definition.event(wide, {ev = "action", act = "inspect", value = "1"})
local inspectedBody = definition.view(wide).main.c
inspectedBody = inspectedBody[#inspectedBody]
assert(#inspectedBody.c[3].c[1].p.a == 36, "Inspector includes every field")
definition.event(wide, {ev = "action", act = "close-inspector"})
assert(wide.inspected == nil)
finish({})
local emptyBody = definition.view(wide).main.c
emptyBody = emptyBody[#emptyBody]
assert(#emptyBody.c[2].c[1].c == 36, "Empty pages retain schema headers")
print("PASS: wide preview, schema order, sparse/null fields, extra fields, full row inspector and empty-page headers")

local schemaState = definition.init(cx, { "test-project" }, nil)
finish({{datasetReference = {datasetId = "ds"}}})
key(schemaState, "enter")
finish({{tableReference = {tableId = "table"}}})
key(schemaState, "enter")
local manyFields = {}
for i = 1, 80 do
	table.insert(manyFields, {name = "field_" .. i, type = "STRING", mode = "REQUIRED", description = "Full description for field " .. i .. string.rep(" details", 100)})
end
finish({schema = {fields = manyFields}})
schemaState.cx.cols = 20
local allFields = find(definition.view(schemaState).main, "schema-grid")
assert(allFields.k == "div" and string.find(allFields.p.class, "bq-grid-scroll", 1, true))
assert(#allFields.c == 81, "Every schema field remains rendered in a narrow pane")
for _, row in allFields.c do assert(#row.c == 4, "All four schema columns must remain present") end
assert(allFields.c[1].c[4].p.a == "Description")
assert(flat(allFields.c[81].c[1]) == "field_80")
assert(flat(allFields.c[81].c[4]) == manyFields[80].description, "Descriptions must remain complete")
print("PASS: narrow schema grid renders all fields and four columns with complete descriptions")
