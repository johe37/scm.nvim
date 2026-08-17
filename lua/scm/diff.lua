-- Side-by-side diff view: old version on the left (read only), new version on the
-- right. When the right side is the working tree it is the real file buffer, so
-- you can edit and `:w` it and the diff follows along.
local git = require("scm.git")
local state = require("scm.state")
local config = require("scm.config")

local M = {}

local function win_valid(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function buf_valid(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

--- Wipe a buffer we created ourselves, never a real file buffer.
local function drop_scratch(buf)
  if not buf_valid(buf) then
    return
  end
  if vim.api.nvim_buf_get_name(buf):sub(1, 6) == "scm://" then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

--- Which pair of versions to compare, mirroring what VS Code shows when you
--- click an entry in each section of its source control view.
---@param entry table
---@return table left, table right
local function resolve(entry)
  local path = entry.path
  local orig = entry.orig or path

  local function head_side()
    return { spec = git.spec("HEAD", orig), label = "HEAD:" .. orig, name = "HEAD/" .. orig }
  end
  local function index_side()
    return { spec = git.spec(":0", path), label = "Index: " .. path, name = "index/" .. path }
  end
  local function new_side()
    return { empty = true, label = "(new file)", name = "new/" .. path }
  end

  if entry.force_left then
    return { spec = entry.force_left, label = entry.force_left, name = entry.force_left },
      { file = path, label = path }
  end

  -- Two explicit blobs: a file as it looked in a commit and in its parent.
  if entry.kind == "commit_file" then
    local left = entry.left_spec
        and { spec = entry.left_spec, label = entry.left_label, name = entry.left_spec }
      or { empty = true, label = entry.left_label, name = "empty/" .. path }
    local right = entry.right_spec
        and { spec = entry.right_spec, label = entry.right_label, name = entry.right_spec }
      or { empty = true, label = entry.right_label, name = "gone/" .. path }
    right.readonly = true
    return left, right
  end

  if entry.kind == "staged" then
    local left = entry.code == "A" and new_side() or head_side()
    local right = index_side()
    right.readonly = true
    return left, right
  end

  if entry.kind == "untracked" then
    return { empty = true, label = "(untracked)", name = "untracked/" .. path }, { file = path, label = path }
  end

  if entry.kind == "conflicted" then
    return { spec = git.spec(":2", path), label = "Ours: " .. path, name = "ours/" .. path },
      { file = path, label = path .. " (conflicted)" }
  end

  -- Unstaged: compare the index (falling back to HEAD) against the file on disk.
  local left = index_side()
  if not git.blob(state.root, left.spec) then
    left = git.has_head(state.root) and head_side() or new_side()
  end
  return left, { file = path, label = path }
end

--- Scratch buffer holding a git blob. Named `scm://…` so it is recognisable in
--- the buffer list and cannot be confused with the file on disk.
local function make_blob_buf(side)
  local full = "scm://" .. (side.name or side.label)
  -- Reuse a buffer of the same name rather than deleting it: it may be the one
  -- currently shown in the window we are about to reload, and wiping it would
  -- take the window down with it.
  local buf = vim.fn.bufnr(full)
  if buf == -1 or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    pcall(vim.api.nvim_buf_set_name, buf, full)
  end
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, side.lines or {})
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  return buf
end

local function fill_side(side)
  if side.empty then
    side.lines = {}
    return true
  end
  if side.file then
    return true
  end
  local lines, err = git.blob(state.root, side.spec)
  if not lines then
    side.lines = { "scm: cannot show " .. side.spec .. (err and (" (" .. err .. ")") or "") }
    side.error = true
    return true
  end
  side.lines = lines
  return true
end

--- The window a diff should take over: the first ordinary window that is not the
--- panel. Creates one at the far right if the panel is all there is.
function M.main_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= state.panel.win and vim.api.nvim_win_get_config(win).relative == "" then
      return win
    end
  end
  if win_valid(state.panel.win) then
    vim.api.nvim_set_current_win(state.panel.win)
    vim.cmd(config.position == "left" and "botright vsplit" or "topleft vsplit")
    return vim.api.nvim_get_current_win()
  end
  return vim.api.nvim_get_current_win()
end

local function save_win_opts(win)
  state.diff.saved[win] = {
    foldenable = vim.wo[win].foldenable,
    foldcolumn = vim.wo[win].foldcolumn,
    list = vim.wo[win].list,
    winbar = vim.wo[win].winbar,
  }
end

local function restore_win_opts(win)
  local saved = state.diff.saved[win]
  if not saved or not win_valid(win) then
    return
  end
  for opt, value in pairs(saved) do
    pcall(function()
      vim.wo[win][opt] = value
    end)
  end
  state.diff.saved[win] = nil
end

local function setup_diff_win(win, label, hl)
  vim.api.nvim_set_current_win(win)
  vim.w[win].scm_diff = true
  vim.cmd("diffthis")
  vim.wo[win].foldenable = config.fold_unchanged
  if not config.fold_unchanged then
    -- `diffthis` reserves a fold gutter; without folds it is just dead space.
    vim.wo[win].foldcolumn = "0"
  end
  vim.wo[win].list = false
  vim.wo[win].winbar = "%#" .. hl .. "# " .. label:gsub("%%", "%%%%") .. " %*"
end

--- Close the diff windows and take the file buffer out of diff mode.
function M.close()
  local d = state.diff
  for _, win in ipairs({ d.left_win, d.right_win }) do
    if win_valid(win) then
      vim.api.nvim_win_call(win, function()
        pcall(vim.cmd, "diffoff")
      end)
      restore_win_opts(win)
      vim.w[win].scm_diff = false
    end
  end
  if win_valid(d.left_win) and #vim.api.nvim_tabpage_list_wins(0) > 1 then
    pcall(vim.api.nvim_win_close, d.left_win, true)
  end
  drop_scratch(d.left_buf)
  drop_scratch(d.right_buf)
  d.left_win, d.right_win, d.left_buf, d.right_buf, d.entry = nil, nil, nil, nil, nil
end

--- True when both diff windows are still on screen and usable.
local function windows_alive()
  return win_valid(state.diff.left_win) and win_valid(state.diff.right_win)
end

--- Open (or re-target) the two side-by-side windows.
---@param entry table status entry from scm.git.status
---@param opts? { focus?: boolean }
function M.open(entry, opts)
  opts = opts or {}
  if not state.root then
    state.root = git.root(vim.api.nvim_buf_get_name(0))
  end
  if not state.root then
    vim.notify("scm: not inside a git repository", vim.log.levels.WARN)
    return
  end

  local left, right = resolve(entry)
  fill_side(left)
  fill_side(right)

  local previous = vim.api.nvim_get_current_win()
  local stale = { state.diff.left_buf, state.diff.right_buf }

  local left_win, right_win
  if windows_alive() then
    left_win, right_win = state.diff.left_win, state.diff.right_win
    for _, win in ipairs({ left_win, right_win }) do
      vim.api.nvim_win_call(win, function()
        pcall(vim.cmd, "diffoff")
      end)
    end
  else
    M.close()
    right_win = M.main_win()
    vim.api.nvim_set_current_win(right_win)
    vim.cmd("aboveleft vsplit")
    left_win = vim.api.nvim_get_current_win()
    save_win_opts(left_win)
    save_win_opts(right_win)
  end

  -- Right side first: it decides the filetype used for both buffers.
  local right_buf
  if right.file then
    local abs = state.root .. "/" .. right.file
    if vim.uv.fs_stat(abs) then
      right_buf = vim.fn.bufadd(abs)
      vim.fn.bufload(right_buf)
      vim.bo[right_buf].buflisted = true
    else
      right_buf = make_blob_buf({ lines = {}, name = "deleted/" .. right.file })
      right.label = right.file .. " (deleted)"
    end
  else
    right_buf = make_blob_buf(right)
  end
  vim.api.nvim_win_set_buf(right_win, right_buf)

  local left_buf = make_blob_buf(left)
  vim.api.nvim_win_set_buf(left_win, left_buf)

  for _, buf in ipairs(stale) do
    if buf ~= left_buf and buf ~= right_buf then
      drop_scratch(buf)
    end
  end

  -- Match syntax highlighting to the real file. Set it with the window current so
  -- FileType handlers that act on the current buffer see the right one.
  local ft = vim.filetype.match({ filename = entry.path, buf = right_buf })
  if ft then
    local function set_ft(win, buf, side)
      if side.error or vim.bo[buf].filetype == ft or vim.bo[buf].buftype ~= "nofile" then
        return
      end
      vim.api.nvim_win_call(win, function()
        vim.bo[buf].filetype = ft
      end)
    end
    set_ft(left_win, left_buf, left)
    set_ft(right_win, right_buf, right)
  end

  setup_diff_win(left_win, left.label, "ScmDiffOld")
  setup_diff_win(right_win, right.label .. (right.readonly and "  [read-only]" or "  [editable]"), "ScmDiffNew")

  state.diff.left_win, state.diff.right_win = left_win, right_win
  state.diff.left_buf, state.diff.right_buf = left_buf, right_buf
  state.diff.entry = entry

  M.attach_keymaps(left_buf)
  M.attach_keymaps(right_buf)

  -- Land on the first change instead of the top of an unchanged prologue.
  vim.api.nvim_win_call(right_win, function()
    vim.cmd("normal! gg")
    if pcall(vim.cmd, "normal! ]c") then
      vim.cmd("normal! zz")
    end
  end)

  if opts.focus == false then
    if win_valid(previous) then
      vim.api.nvim_set_current_win(previous)
    end
  else
    vim.api.nvim_set_current_win(right_win)
  end
end

--- Reload the left (old) side after the index changed, keeping the view in place.
function M.refresh()
  if not (windows_alive() and state.diff.entry) then
    return
  end
  local view = vim.api.nvim_win_call(state.diff.right_win, vim.fn.winsaveview)
  local entry = state.diff.entry
  local current = vim.api.nvim_get_current_win()
  M.open(entry, { focus = false })
  if win_valid(state.diff.right_win) then
    vim.api.nvim_win_call(state.diff.right_win, function()
      vim.fn.winrestview(view)
    end)
  end
  if win_valid(current) then
    vim.api.nvim_set_current_win(current)
  end
end

function M.attach_keymaps(buf)
  local function map(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, silent = true, desc = "SCM: " .. desc })
  end
  map("q", M.close, "Close diff")
  map("<leader>gq", M.close, "Close diff")
  map("]c", "]c", "Next change")
  map("[c", "[c", "Previous change")
  map("<leader>gS", function()
    local entry = state.diff.entry
    if not entry then
      return
    end
    if git.stage(state.root, entry) then
      require("scm.panel").refresh()
      M.refresh()
    end
  end, "Stage this file")
end

--- Whether `buf` is one of the two buffers currently on screen in the diff.
function M.owns_buf(buf)
  return buf == state.diff.left_buf or buf == state.diff.right_buf
end

local timer
--- Re-run the diff shortly after typing stops so highlights track live edits.
function M.schedule_update()
  if not config.live_diff or not windows_alive() then
    return
  end
  if timer then
    timer:stop()
    timer:close()
  end
  timer = vim.uv.new_timer()
  timer:start(config.live_diff_debounce, 0, function()
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end
    vim.schedule(function()
      if not windows_alive() then
        return
      end
      vim.api.nvim_win_call(state.diff.right_win, function()
        pcall(vim.cmd, "diffupdate")
      end)
    end)
  end)
end

return M
