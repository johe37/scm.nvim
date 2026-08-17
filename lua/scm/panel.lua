-- The sidebar. It hosts three views in one window, VS Code style:
--   status  the working tree, grouped into Conflicts/Staged/Changes/Untracked
--   log     a commit list, either repo-wide or for one file
--   commit  one commit: metadata, message, and the files it touched
-- `<BS>` walks back through the views you came from.
local git = require("scm.git")
local state = require("scm.state")
local config = require("scm.config")
local diff = require("scm.diff")

local M = {}

local ns = vim.api.nvim_create_namespace("scm.panel")

local SECTIONS = {
  { key = "conflicted", title = "Merge Conflicts" },
  { key = "staged", title = "Staged Changes" },
  { key = "unstaged", title = "Changes" },
  { key = "untracked", title = "Untracked" },
}

local CODE_HL = {
  M = "ScmModified",
  A = "ScmAdded",
  D = "ScmDeleted",
  R = "ScmRenamed",
  C = "ScmRenamed",
  T = "ScmModified",
  U = "ScmConflict",
  ["?"] = "ScmUntracked",
}

local function win_valid(win)
  return win and vim.api.nvim_win_is_valid(win)
end

function M.is_open()
  return state.panel.win ~= nil and vim.api.nvim_win_is_valid(state.panel.win)
end

function M.view()
  return state.panel.view or { kind = "status" }
end

--- Item under the cursor: a working tree file, a commit, a commit's file, or one
--- of the inline actions. Nil on a header or blank line.
function M.current_item()
  if not M.is_open() then
    return nil
  end
  local lnum = vim.api.nvim_win_get_cursor(state.panel.win)[1]
  return state.panel.entries[lnum]
end

--- Kept for callers that only care about working tree files.
function M.current_entry()
  local item = M.current_item()
  return item and item.type == "file" and item.entry or nil
end

local function current_section()
  if not M.is_open() then
    return nil
  end
  local lnum = vim.api.nvim_win_get_cursor(state.panel.win)[1]
  local item = state.panel.entries[lnum]
  return state.panel.sections[lnum] or (item and item.entry and item.entry.kind) or nil
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

local function render_status(add, _, width)
  local status = git.status(state.root)
  state.panel.status = status

  add(" Source Control", { { 0, -1, "ScmTitle" } })

  local branch_line = " " .. git.branch(state.root)
  local upstream = git.upstream(state.root)
  if upstream and (upstream.ahead > 0 or upstream.behind > 0) then
    branch_line = branch_line .. string.format("  ^%d v%d", upstream.ahead, upstream.behind)
  end
  add(branch_line, { { 0, -1, "ScmBranch" } })
  add(" " .. vim.fs.basename(state.root or ""), { { 0, -1, "ScmDim" } })

  local total = 0
  for _, section in ipairs(SECTIONS) do
    local list = status[section.key] or {}
    total = total + #list
    if #list > 0 then
      add("")
      local collapsed = state.panel.collapsed[section.key]
      add(
        string.format(" %s %s (%d)", collapsed and ">" or "v", section.title, #list),
        { { 0, -1, "ScmSection" } },
        { section = section.key }
      )
      if not collapsed then
        for _, entry in ipairs(list) do
          local base = vim.fs.basename(entry.path)
          local dir = vim.fs.dirname(entry.path)
          dir = (dir == "." or dir == "") and "" or dir
          local prefix = string.format("   %s  ", entry.code)
          local text = prefix .. base
          local hls = {
            { 3, 4, CODE_HL[entry.code] or "ScmModified" },
            { #prefix, #prefix + #base, entry.code == "D" and "ScmDeleted" or "ScmPath" },
          }
          if dir ~= "" then
            text = text .. "  " .. dir
            hls[#hls + 1] = { #prefix + #base, -1, "ScmDim" }
          end
          add(text, hls, {
            item = { type = "file", entry = entry, key = entry.kind .. ":" .. entry.path },
            section = section.key,
          })
        end
      end
    end
  end
  _ = width

  if total == 0 then
    add("")
    add("  No changes", { { 0, -1, "ScmDim" } })
  end
end

local function render(buf)
  local view = M.view()
  local width = M.is_open() and vim.api.nvim_win_get_width(state.panel.win) or config.width
  local lines, marks, entries, sections = {}, {}, {}, {}

  local function add(text, hls, meta)
    -- A buffer line can never hold a newline; git output should not be able to
    -- break the panel even if something upstream changes shape.
    lines[#lines + 1] = text:gsub("[\r\n]", " ")
    local lnum = #lines
    for _, hl in ipairs(hls or {}) do
      marks[#marks + 1] = { lnum - 1, hl[1], hl[2], hl[3] }
    end
    if meta then
      if meta.item then
        entries[lnum] = meta.item
      end
      if meta.section then
        sections[lnum] = meta.section
      end
    end
  end

  if view.kind == "log" then
    require("scm.log").render_log(add, view, width)
  elseif view.kind == "commit" then
    require("scm.log").render_commit(add, view, width)
  else
    render_status(add, view, width)
  end

  add("")
  local hint = view.kind == "status" and "  g? for help" or "  <BS> back · g? for help"
  add(hint, { { 0, -1, "ScmDim" } })

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false

  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, mark in ipairs(marks) do
    local lnum, col_start, col_end, hl = mark[1], mark[2], mark[3], mark[4]
    local len = #(lines[lnum + 1] or "")
    if col_end == -1 or col_end > len then
      col_end = len
    end
    if col_start < col_end then
      vim.api.nvim_buf_set_extmark(buf, ns, lnum, col_start, { end_col = col_end, hl_group = hl })
    end
  end

  state.panel.entries = entries
  state.panel.sections = sections
end

--- Redraw the current view, keeping the cursor on the same item when possible.
---@param opts? { cursor?: "keep"|"top" }
function M.refresh(opts)
  opts = opts or {}
  if not (state.panel.buf and vim.api.nvim_buf_is_valid(state.panel.buf) and state.root) then
    return
  end
  local keep = opts.cursor ~= "top" and M.current_item() or nil
  render(state.panel.buf)
  if not M.is_open() then
    return
  end
  if opts.cursor == "top" then
    -- Land on the first selectable line of the new view.
    for lnum = 1, vim.api.nvim_buf_line_count(state.panel.buf) do
      if state.panel.entries[lnum] then
        pcall(vim.api.nvim_win_set_cursor, state.panel.win, { lnum, 0 })
        return
      end
    end
    pcall(vim.api.nvim_win_set_cursor, state.panel.win, { 1, 0 })
    return
  end
  if keep then
    local fallback
    for lnum, item in pairs(state.panel.entries) do
      if item.key == keep.key then
        pcall(vim.api.nvim_win_set_cursor, state.panel.win, { lnum, 0 })
        return
      end
      -- The file may have moved between sections (e.g. it was just staged).
      if keep.entry and item.entry and item.entry.path == keep.entry.path then
        fallback = math.min(fallback or math.huge, lnum)
      end
    end
    if fallback then
      pcall(vim.api.nvim_win_set_cursor, state.panel.win, { fallback, 0 })
    end
  end
end

---------------------------------------------------------------------------
-- Views
---------------------------------------------------------------------------

--- Switch the sidebar to another view, remembering where we came from.
---@param view table
---@param opts? { replace?: boolean }
function M.set_view(view, opts)
  opts = opts or {}
  if not opts.replace and state.panel.view then
    state.panel.stack[#state.panel.stack + 1] = state.panel.view
  end
  state.panel.view = view
  M.refresh({ cursor = "top" })
end

--- Back to the view we came from; from the top level that means the status view.
function M.back()
  local previous = table.remove(state.panel.stack)
  state.panel.view = previous or { kind = "status" }
  M.refresh({ cursor = "top" })
end

---------------------------------------------------------------------------
-- Keymaps
---------------------------------------------------------------------------

local function act(fn)
  return function()
    local entry = M.current_entry()
    if not entry then
      return
    end
    fn(entry)
  end
end

local function each_in_section(kind, fn)
  local list = (state.panel.status or {})[kind] or {}
  for _, entry in ipairs(list) do
    fn(entry)
  end
end

local function after_index_change()
  M.refresh()
  diff.refresh()
end

local HELP = {
  "SCM panel",
  "",
  "Working tree (status view)",
  "  <CR> / o   open the side-by-side diff and jump into it",
  "  p          open the diff, keep the cursor in the panel",
  "  s / u / -  stage / unstage / toggle the file",
  "  S / U      stage everything in the section / unstage everything",
  "  X          discard changes (untracked files are deleted)",
  "  cc / ca    commit / amend the last commit",
  "  <Tab>      collapse or expand a section",
  "",
  "History",
  "  L          commit history for the repository",
  "  l          history of the file under the cursor",
  "  <CR>       on a commit: inspect it (in a file's history: diff that file)",
  "             on a commit's file: diff it against the parent commit",
  "  i          inspect the commit under the cursor",
  "  D          the commit as one unified patch",
  "  m          load more commits",
  "  y          yank the commit sha",
  "  <BS>       back to the previous view",
  "",
  "Anywhere",
  "  J / K      next / previous item     r  refresh     q  close",
  "",
  "In a diff: ]c / [c jump between changes, q closes it,",
  "<leader>gS stages the file you are looking at.",
}

local function attach_keymaps(buf)
  local function map(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, silent = true, nowait = true, desc = "SCM: " .. desc })
  end

  --- `<CR>` means "open whatever is under the cursor".
  local function open(focus)
    return function()
      local log = require("scm.log")
      local item = M.current_item()
      local lnum = M.is_open() and vim.api.nvim_win_get_cursor(state.panel.win)[1] or 0
      if not item then
        local section = state.panel.sections[lnum]
        if section then
          state.panel.collapsed[section] = not state.panel.collapsed[section]
          M.refresh()
        end
        return
      end
      if item.type == "file" then
        diff.open(item.entry, { focus = focus })
      elseif item.type == "commit" then
        -- In a file's history, the interesting thing is that file at that commit.
        if M.view().path and item.commit.file then
          log.open_file_diff(item.commit.file)
          if not focus and M.is_open() then
            vim.api.nvim_set_current_win(state.panel.win)
          end
        else
          log.open_commit(item.commit.sha)
        end
      elseif item.type == "commit_file" then
        log.open_file_diff(item.file)
        if not focus and M.is_open() then
          vim.api.nvim_set_current_win(state.panel.win)
        end
      elseif item.type == "patch" then
        log.open_patch(M.view().sha)
      elseif item.type == "more" then
        M.view().limit = M.view().limit + require("scm.log").PAGE
        M.refresh()
      end
    end
  end

  map("<CR>", open(true), "Open")
  map("o", open(true), "Open")
  map("<2-LeftMouse>", open(true), "Open")
  map("p", open(false), "Open, keep focus in the panel")

  map("s", act(function(entry)
    if git.stage(state.root, entry) then
      after_index_change()
    end
  end), "Stage file")
  map("u", act(function(entry)
    if git.unstage(state.root, entry) then
      after_index_change()
    end
  end), "Unstage file")
  map("-", act(function(entry)
    local ok = entry.kind == "staged" and git.unstage(state.root, entry) or git.stage(state.root, entry)
    if ok then
      after_index_change()
    end
  end), "Toggle staged")

  map("S", function()
    local kind = current_section() or "unstaged"
    if kind == "staged" then
      return
    end
    each_in_section(kind, function(entry)
      git.stage(state.root, entry)
    end)
    after_index_change()
  end, "Stage all in section")
  map("U", function()
    each_in_section("staged", function(entry)
      git.unstage(state.root, entry)
    end)
    after_index_change()
  end, "Unstage all")

  map("X", act(function(entry)
    if config.confirm_discard then
      local what = entry.kind == "untracked" and ("Delete untracked " .. entry.path .. "?")
        or ("Discard changes in " .. entry.path .. "?")
      if vim.fn.confirm(what, "&Yes\n&No", 2) ~= 1 then
        return
      end
    end
    if git.discard(state.root, entry) then
      -- Reload the buffer so the window shows the reverted file.
      local bufnr = vim.fn.bufnr(state.root .. "/" .. entry.path)
      if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_call(bufnr, function()
          pcall(vim.cmd, "silent! edit!")
        end)
      end
      after_index_change()
    end
  end), "Discard changes")

  map("cc", function()
    require("scm.commit").open()
  end, "Commit")
  map("ca", function()
    require("scm.commit").open({ amend = true })
  end, "Commit --amend")

  map("L", function()
    require("scm.log").open_log()
  end, "Repository history")
  map("i", function()
    local item = M.current_item()
    local sha = item and item.commit and item.commit.sha
    if sha then
      require("scm.log").open_commit(sha)
    end
  end, "Inspect this commit")
  map("l", function()
    local item = M.current_item()
    local path = item and ((item.entry and item.entry.path) or (item.file and item.file.path))
    if not path then
      vim.notify("scm: put the cursor on a file first", vim.log.levels.WARN)
      return
    end
    require("scm.log").open_log({ path = path })
  end, "History of this file")
  map("D", function()
    local view = M.view()
    local item = M.current_item()
    local sha = view.sha or (item and item.commit and item.commit.sha)
    if sha then
      require("scm.log").open_patch(sha)
    end
  end, "Full patch")
  map("m", function()
    local view = M.view()
    if view.kind == "log" then
      view.limit = view.limit + require("scm.log").PAGE
      M.refresh()
    end
  end, "Load more commits")
  map("y", function()
    local view = M.view()
    local item = M.current_item()
    local sha = (item and item.commit and item.commit.sha) or view.sha
    if not sha then
      return
    end
    vim.fn.setreg("+", sha)
    vim.fn.setreg('"', sha)
    vim.notify("scm: yanked " .. sha:sub(1, 7))
  end, "Yank commit sha")
  map("<BS>", M.back, "Back")

  map("<Tab>", function()
    local section = current_section()
    if section then
      state.panel.collapsed[section] = not state.panel.collapsed[section]
      M.refresh()
    end
  end, "Toggle section")

  local function jump(step)
    return function()
      local lnum = vim.api.nvim_win_get_cursor(0)[1]
      local last = vim.api.nvim_buf_line_count(buf)
      local current = state.panel.entries[lnum]
      for i = lnum + step, step > 0 and last or 1, step do
        local item = state.panel.entries[i]
        -- Commits span two lines; skip to the next distinct item.
        if item and (not current or item.key ~= current.key) then
          local target = i
          -- Going up, stop on the item's first line rather than its last.
          while step < 0 and state.panel.entries[target - 1] and state.panel.entries[target - 1].key == item.key do
            target = target - 1
          end
          vim.api.nvim_win_set_cursor(0, { target, 0 })
          return
        end
      end
    end
  end
  map("J", jump(1), "Next item")
  map("K", jump(-1), "Previous item")

  map("r", function()
    M.refresh()
  end, "Refresh")
  map("R", function()
    M.refresh()
  end, "Refresh")
  map("q", M.close, "Close panel")
  map("g?", function()
    vim.notify(table.concat(HELP, "\n"), vim.log.levels.INFO, { title = "scm.nvim" })
  end, "Help")
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

local function create_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "scm"
  pcall(vim.api.nvim_buf_set_name, buf, "scm://panel")
  attach_keymaps(buf)
  return buf
end

local function setup_win(win)
  local wo = vim.wo[win]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.cursorline = true
  wo.wrap = false
  wo.list = false
  wo.winfixwidth = true
  wo.spell = false
  wo.statuscolumn = ""
end

---@param opts? { keep_focus?: boolean }
function M.open(opts)
  opts = opts or {}
  local root = git.root(vim.api.nvim_buf_get_name(0)) or git.root(vim.uv.cwd())
  if not root then
    vim.notify("scm: not inside a git repository", vim.log.levels.WARN)
    return
  end
  if state.root and state.root ~= root then
    state.panel.collapsed = {}
    state.panel.stack = {}
    state.panel.view = { kind = "status" }
  end
  state.root = root
  state.panel.view = state.panel.view or { kind = "status" }

  if not (state.panel.buf and vim.api.nvim_buf_is_valid(state.panel.buf)) then
    state.panel.buf = create_buf()
  end

  if not M.is_open() then
    local previous = vim.api.nvim_get_current_win()
    vim.cmd(config.position == "left" and "topleft vsplit" or "botright vsplit")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, state.panel.buf)
    vim.api.nvim_win_set_width(win, config.width)
    setup_win(win)
    state.panel.win = win
    M.refresh()
    if opts.keep_focus and win_valid(previous) then
      vim.api.nvim_set_current_win(previous)
    end
  else
    M.refresh()
    if not opts.keep_focus then
      vim.api.nvim_set_current_win(state.panel.win)
    end
  end
end

function M.close()
  diff.close()
  if M.is_open() and #vim.api.nvim_tabpage_list_wins(0) > 1 then
    pcall(vim.api.nvim_win_close, state.panel.win, true)
  end
  state.panel.win = nil
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

--- Diff the file in the current buffer against the index (or a revision).
---@param opts? { rev?: string }
function M.diff_current(opts)
  opts = opts or {}
  local path = vim.api.nvim_buf_get_name(0)
  if path == "" then
    vim.notify("scm: no file in this buffer", vim.log.levels.WARN)
    return
  end
  local root = git.root(path)
  if not root then
    vim.notify("scm: not inside a git repository", vim.log.levels.WARN)
    return
  end
  state.root = root
  local rel = vim.fs.relpath(root, path) or path
  diff.open({
    path = rel,
    code = "M",
    kind = "unstaged",
    label = "modified",
    force_left = opts.rev and git.spec(opts.rev, rel) or nil,
  })
end

return M
