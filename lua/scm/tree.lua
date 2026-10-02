-- Renders a list of paths as a directory tree for the panel's file lists (the
-- working tree sections and a commit's files).
--
-- Changed files are sparse, so a literal one-level-per-component tree spends
-- most of its indentation on directories holding a single subdirectory. Those
-- chains are joined into one line — `lua/scm/` rather than `lua/` above `scm/`
-- — which is what VS Code and neo-tree do.
local state = require("scm.state")
local config = require("scm.config")

local M = {}

local function new_dir(name, path)
  return { name = name, path = path, names = {}, dirs = {}, files = {} }
end

local function child(parent, name)
  local dir = parent.dirs[name]
  if not dir then
    dir = new_dir(name, parent.path == "" and name or (parent.path .. "/" .. name))
    parent.dirs[name] = dir
    parent.names[#parent.names + 1] = name
  end
  return dir
end

--- Join a chain of directories that each hold one subdirectory and no files.
local function compress(dir)
  while #dir.names == 1 and #dir.files == 0 do
    local only = dir.dirs[dir.names[1]]
    dir.name = dir.name .. "/" .. only.name
    dir.path = only.path
    dir.names, dir.dirs, dir.files = only.names, only.dirs, only.files
  end
  for _, name in ipairs(dir.names) do
    compress(dir.dirs[name])
  end
end

local function count(dir)
  local total = #dir.files
  for _, name in ipairs(dir.names) do
    total = total + count(dir.dirs[name])
  end
  return total
end

--- Fold state is shared with the section headers, so directory keys carry the
--- scope they live in: two sections can show the same path independently.
---@param scope string
---@param path string
function M.fold_key(scope, path)
  return scope .. "//" .. path
end

--- Group `entries` (anything with a `path`) into rows to render.
---@param entries table[]
---@param scope string
---@return table[] rows `{ kind = "dir"|"file", depth, entry?, name?, path?, count?, collapsed? }`
function M.rows(entries, scope)
  if not config.tree then
    local rows = {}
    for _, entry in ipairs(entries) do
      rows[#rows + 1] = { kind = "file", entry = entry, depth = 0, flat = true }
    end
    return rows
  end

  local root = new_dir("", "")
  for _, entry in ipairs(entries) do
    local dir = root
    local parts = vim.split(entry.path, "/", { plain = true })
    for i = 1, #parts - 1 do
      dir = child(dir, parts[i])
    end
    dir.files[#dir.files + 1] = entry
  end
  -- The root itself is never a line, so compress its children instead of it:
  -- collapsing the root away would drop the only place a path is shown.
  for _, name in ipairs(root.names) do
    compress(root.dirs[name])
  end

  local rows = {}
  local function walk(dir, depth)
    -- Directories first, both halves alphabetical. `names` holds the first
    -- component of each child, which is unique among siblings, so this orders
    -- compressed nodes the same way their full paths would.
    table.sort(dir.names)
    table.sort(dir.files, function(a, b)
      return a.path < b.path
    end)
    for _, name in ipairs(dir.names) do
      local sub = dir.dirs[name]
      local collapsed = state.panel.collapsed[M.fold_key(scope, sub.path)] == true
      rows[#rows + 1] = {
        kind = "dir",
        depth = depth,
        name = sub.name,
        path = sub.path,
        count = count(sub),
        collapsed = collapsed,
      }
      if not collapsed then
        walk(sub, depth + 1)
      end
    end
    for _, entry in ipairs(dir.files) do
      rows[#rows + 1] = { kind = "file", entry = entry, depth = depth }
    end
  end
  walk(root, 0)
  return rows
end

--- Render a file list. Directory lines become items too, so `<Tab>` can fold
--- them and `J`/`K` walk over them.
---@param add fun(text: string, hls?: table[], meta?: table)
---@param entries table[]
---@param opts { scope: string, width?: integer, item: fun(entry: table): table, meta?: table }
function M.render(add, entries, opts)
  for _, row in ipairs(M.rows(entries, opts.scope)) do
    local indent = "   " .. string.rep("  ", row.depth)
    local meta = vim.tbl_extend("force", {}, opts.meta or {})
    if row.kind == "dir" then
      local name = row.name .. "/"
      local text = indent .. name .. string.format(" (%d)", row.count)
      if row.collapsed then
        text = text .. " …"
      end
      meta.item = {
        type = "dir",
        key = "dir:" .. M.fold_key(opts.scope, row.path),
        fold = M.fold_key(opts.scope, row.path),
      }
      add(text, {
        { #indent, #indent + #name, "ScmDir" },
        { #indent + #name, -1, "ScmDim" },
      }, meta)
    else
      -- The file row (status color, rename arrow, right-aligned directory)
      -- lives in the panel. A tree already shows the directory above the file,
      -- so only the flat fallback repeats it.
      meta.item = opts.item(row.entry)
      require("scm.panel").add_file_row(add, row.entry, meta, opts.width, {
        indent = indent,
        show_dir = row.flat == true,
      })
    end
  end
end

return M
