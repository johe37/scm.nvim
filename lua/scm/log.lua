-- History views for the panel: a commit list (repo-wide or for one file) and a
-- single commit's details, with its files openable as side-by-side diffs. The
-- GitLens half of the plugin.
local git = require("scm.git")
local state = require("scm.state")

local M = {}

M.PAGE = 50

local function panel()
  return require("scm.panel")
end

local function clip(text, width)
  return panel().truncate(text, width)
end

---------------------------------------------------------------------------
-- Commit list
---------------------------------------------------------------------------

--- One commit: sha, subject, ref decorations, and the author and date on the right.
--- `ahead` paints the sha as an addition: this commit is not on the base ref.
local function commit_line(commit, width, ahead)
  local ui = panel()
  local sha = commit.short or ""
  local subject = commit.subject or ""
  local meta = (commit.author or "") .. " · " .. (commit.rel_date or "")
  local notes = {}
  if commit.refs and commit.refs ~= "" then
    notes[#notes + 1] = commit.refs
  end
  if #(commit.parents or {}) > 1 then
    notes[#notes + 1] = "merge"
  end
  if commit.file and (commit.file.code == "R" or commit.file.code == "C") then
    notes[#notes + 1] = "was " .. vim.fs.basename(commit.file.orig or "")
  end
  local refs = table.concat(notes, " · ")

  local prefix_w = vim.fn.strdisplaywidth(sha) + 3
  local meta_w = vim.fn.strdisplaywidth(meta)
  local show_meta = width - prefix_w - 2 - meta_w >= 8
  local right_w = show_meta and (2 + meta_w) or 0

  local refs_text = ""
  if refs ~= "" then
    local room = width - prefix_w - right_w - 8
    if room >= 8 then
      local cap = math.min(vim.fn.strdisplaywidth(refs), math.floor(width * 0.4), room)
      refs_text = ui.truncate(refs, cap)
    end
  end
  local refs_w = refs_text ~= "" and (2 + vim.fn.strdisplaywidth(refs_text)) or 0
  subject = ui.truncate(subject, math.max(width - prefix_w - refs_w - right_w, 0))

  local text = " " .. sha .. "  " .. subject
  local hls = {
    { 1, 1 + #sha, ahead and "ScmAdded" or "ScmSha" },
    { #sha + 3, #text, "ScmPath" },
  }
  if refs_text ~= "" then
    local at = #text + 2
    text = text .. "  " .. refs_text
    hls[#hls + 1] = { at, #text, "ScmRef" }
  end
  if show_meta then
    local pad = width - vim.fn.strdisplaywidth(text) - meta_w
    if pad < 2 then
      pad = 2
    end
    text = text .. string.rep(" ", pad) .. meta
    hls[#hls + 1] = { #text - #meta, #text, "ScmDim" }
  end
  return text, hls
end

--- The row that splits commits HEAD has from the ones already on `base`.
--- Not an item: moving through the list skips it, and it is not remembered.
local function base_line(add, base, reached, width)
  local text = reached and (" ── " .. base) or (" ── ahead of " .. base)
  text = clip(text, math.max(width - 1, 1))
  local at = text:find(base, 1, true)
  if not at then
    add(text, { { 0, -1, "ScmDim" } })
    return
  end
  local byte = at - 1
  add(text, {
    { 0, byte, "ScmDim" },
    { byte, byte + #base, "ScmBranch" },
    { byte + #base, #text, "ScmDim" },
  })
end

-- Declared above the log renderer, which calls it while drawing the first row.
local render_vs_row

--- @param view { path?: string, rev?: string, limit: integer }
function M.render_log(add, view, width)
  view.base_ref = nil
  view.ahead_count = nil
  local commits = git.log(state.root, { limit = view.limit + 1, path = view.path, rev = view.rev })
  local more = #commits > view.limit
  if more then
    table.remove(commits)
  end

  if #commits == 0 then
    add("  No commits", { { 0, -1, "ScmDim" } })
    return
  end

  -- Commits above the line are the difference against master (or main).
  -- On master itself the other side of that line is the published branch.
  local base = git.base_ref(state.root)
  local ahead = base and git.not_on(state.root, base, vim.tbl_map(function(commit)
    return commit.sha
  end, commits)) or {}
  local any_ahead = false
  local cut
  for i, commit in ipairs(commits) do
    if ahead[commit.sha] then
      any_ahead = true
    elseif any_ahead and not cut then
      cut = i
    end
  end
  if base and not view.path then
    view.base_ref = base
    view.ahead_count = git.ahead_of(state.root, base)
    -- The whole branch against its base, one row above the commits. A file's
    -- log stays a list of that file: this comparison is the repo, not the file.
    local tip = view.rev or "HEAD"
    if view.rev or view.ahead_count > 0 then
      local since = git.since(state.root, base, tip, { files = false })
      if since and not since.on_base and (since.commits or 0) > 0 then
        render_vs_row(add, base, since, tip, width)
        add("")
      end
    end
  end

  for i, commit in ipairs(commits) do
    if cut == i then
      add("")
      base_line(add, base, true, width)
    end
    local text, hls = commit_line(commit, width, ahead[commit.sha])
    add(text, hls, { item = { type = "commit", commit = commit, key = "commit:" .. commit.sha } })
  end
  if base and any_ahead and not cut then
    add("")
    base_line(add, base, false, width)
  end

  if more then
    add("")
    local more = "  m  load more"
    add(more, panel().highlight_keys(more, { "m" }), { item = { type = "more", key = "more" } })
  end
end

---------------------------------------------------------------------------
-- Single commit
---------------------------------------------------------------------------

--- `prefix` is the dim or section lead-in; `base` is drawn as a branch name.
local function ref_heading(add, prefix, base, prefix_hl, width)
  local text = clip(prefix .. base, math.max(width - 1, 1))
  local hls = { { 0, math.min(#prefix, #text), prefix_hl } }
  if #prefix < #text then
    hls[#hls + 1] = { #prefix, #text, "ScmBranch" }
  end
  add(text, hls)
end

--- "16 commits · 4 files", plus the insertion and deletion counts when present.
local function since_parts(since)
  local nfiles = since.file_count
  if nfiles == nil then
    nfiles = #(since.files or {})
  end
  local commits = since.commits or 0
  local counts = string.format(
    "%d %s · %d %s",
    commits,
    commits == 1 and "commit" or "commits",
    nfiles,
    nfiles == 1 and "file" or "files"
  )
  local plus = (since.added or 0) > 0 and ("+" .. since.added) or ""
  local minus = (since.deleted or 0) > 0 and ("-" .. since.deleted) or ""
  return counts, plus, minus
end

local function hl_line(parts, width)
  local text = ""
  local hls = {}
  for _, part in ipairs(parts) do
    local at = #text
    text = text .. part[1]
    hls[#hls + 1] = { at, #text, part[2] }
  end
  text = clip(text, math.max(width, 1))
  for _, hl in ipairs(hls) do
    if hl[2] > #text then
      hl[2] = #text
    end
  end
  return text, hls
end

--- One selectable row: the branch tip against `base`. Not where the cursor
--- lands when the list opens — Enter on a commit is still the next step.
function render_vs_row(add, base, since, rev, width)
  local counts, plus, minus = since_parts(since)
  local function pieces(with_diff)
    local parts = {
      { " vs ", "ScmSection" },
      { base, "ScmBranch" },
      { "   " .. counts, "ScmPath" },
    }
    if with_diff and plus ~= "" then
      parts[#parts + 1] = { "  " .. plus, "ScmAdded" }
    end
    if with_diff and minus ~= "" then
      parts[#parts + 1] = { "  " .. minus, "ScmDeleted" }
    end
    return parts
  end
  local function columns(parts)
    local n = 0
    for _, part in ipairs(parts) do
      n = n + vim.fn.strdisplaywidth(part[1])
    end
    return n
  end
  local parts = pieces(true)
  if columns(parts) > width then
    parts = pieces(false)
  end
  if columns(parts) > width then
    local room = width - (columns(parts) - vim.fn.strdisplaywidth(parts[2][1]))
    parts[2][1] = panel().truncate(base, math.max(room, 1))
  end
  local text, hls = hl_line(parts, width)
  add(text, hls, {
    item = { type = "vs", key = "vs", base = base, rev = rev, land = false },
  })
end

local function add_since_stats(add, since, width)
  local counts, plus, minus = since_parts(since)
  local parts = { { "  " .. counts, "ScmPath" } }
  if plus ~= "" then
    parts[#parts + 1] = { "  " .. plus, "ScmAdded" }
  end
  if minus ~= "" then
    parts[#parts + 1] = { "  " .. minus, "ScmDeleted" }
  end
  local text, hls = hl_line(parts, math.max(width - 1, 1))
  add(text, hls)
end

--- @param view { sha: string }
function M.render_commit(add, view, width)
  local commit, err = git.commit_info(state.root, view.sha)
  if not commit then
    add(" " .. (err or "unknown revision"), { { 0, -1, "ScmConflict" } })
    return
  end
  view.commit = commit

  add(" " .. commit.short, { { 1, 1 + #commit.short, "ScmSha" } })
  for _, line in ipairs(vim.split(commit.subject, "\n", { plain = true })) do
    add(" " .. clip(line, width - 2), { { 0, -1, "ScmTitle" } })
  end
  add(" " .. clip(commit.author, width - 2), { { 0, -1, "ScmBranch" } })
  local when = commit.rel_date or ""
  if commit.date and commit.date ~= "" then
    when = when .. "  ·  " .. commit.date
  end
  add(" " .. clip(when, width - 2), { { 0, -1, "ScmDim" } })
  if #commit.parents > 1 then
    add(" merge of " .. #commit.parents .. " parents (vs first)", { { 0, -1, "ScmDim" } })
  end

  if commit.body ~= "" then
    add("")
    for _, line in ipairs(vim.split(commit.body, "\n", { plain = true })) do
      add(" " .. clip(line, width - 2), { { 0, -1, "ScmDim" } })
    end
  end

  local files = git.commit_files(state.root, commit)
  view.files = files
  add("")
  add(string.format(" Files (%d)", #files), { { 0, -1, "ScmSection" } })
  require("scm.tree").render(add, files, {
    -- Scoped to the commit so folding one does not fold every other commit's
    -- view of the same directory.
    scope = "commit:" .. commit.short,
    width = width,
    item = function(file)
      return { type = "commit_file", file = file, key = "cf:" .. file.path }
    end,
  })

  add("")
  local patch_line = "  D  full patch"
  add(patch_line, panel().highlight_keys(patch_line, { "D" }), { item = { type = "patch", key = "patch" } })
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

--- Show the repo history (or one file's history) in the panel.
---@param opts? { path?: string, rev?: string }
function M.open_log(opts)
  opts = opts or {}
  panel().set_view({ kind = "log", limit = M.PAGE, path = opts.path, rev = opts.rev })
end

--- Files changed on `rev` (default HEAD) that `base` does not have.
---@param opts? { base?: string, rev?: string }
function M.open_vs(opts)
  opts = opts or {}
  local base = opts.base or git.base_ref(state.root)
  if not base then
    return
  end
  panel().set_view({ kind = "vs", base = base, rev = opts.rev or "HEAD" })
end

--- The branch tip against its base: the summary, then every file in that range.
---@param view { base: string, rev?: string }
function M.render_vs(add, view, width)
  local since = git.since(state.root, view.base, view.rev or "HEAD")
  view.since = since
  if not since then
    add(" could not compare with " .. view.base, { { 0, -1, "ScmConflict" } })
    return
  end
  if since.on_base then
    ref_heading(add, " on ", view.base, "ScmDim", width)
    return
  end
  ref_heading(add, " vs ", view.base, "ScmSection", width)
  add_since_stats(add, since, width)
  if #(since.files or {}) == 0 then
    add("")
    add("  No file changes", { { 0, -1, "ScmDim" } })
    return
  end
  add("")
  require("scm.tree").render(add, since.files, {
    scope = "vs:" .. view.base,
    width = width,
    item = function(file)
      return { type = "commit_file", file = file, key = "vf:" .. file.path }
    end,
  })
end

--- Show one commit's details in the panel.
function M.open_commit(rev)
  local info, err = git.commit_info(state.root, rev)
  if not info then
    vim.notify("scm: " .. (err or ("unknown revision: " .. rev)), vim.log.levels.WARN)
    return
  end
  panel().set_view({ kind = "commit", sha = info.sha })
end

--- Diff one file of a commit against the same file in its first parent.
function M.open_file_diff(file)
  local left, right
  -- No parent means the root commit: everything in it is new.
  if file.code ~= "A" and file.parent then
    left = git.spec(file.parent, file.orig or file.path)
  end
  if file.code ~= "D" then
    right = git.spec(file.sha, file.path)
  end
  -- A comparison against a base ref names that ref. A commit's own file names
  -- the parent sha, and says the change belongs to this commit.
  local left_name = file.parent_label or (file.parent and file.parent:sub(1, 7)) or "parent"
  local right_name = file.sha and file.sha:sub(1, 7) or ""
  require("scm.diff").open({
    path = file.path,
    code = file.code,
    kind = "commit_file",
    label = file.label,
    left_spec = left,
    right_spec = right,
    left_label = left and (left_name .. ":" .. (file.orig or file.path))
      or (file.parent_label and "(added)" or "(added in this commit)"),
    right_label = right and (right_name .. ":" .. file.path)
      or (file.parent_label and "(deleted)" or "(deleted in this commit)"),
  })
end

--- Open the whole commit as a unified patch, taking over the panel window.
function M.open_patch(rev)
  local info = git.commit_info(state.root, rev)
  if not info then
    return
  end
  local name = "scm://patch/" .. info.short
  local buf = vim.fn.bufnr(name)
  if buf == -1 or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    pcall(vim.api.nvim_buf_set_name, buf, name)
  end
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, git.commit_patch(state.root, info.sha))
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false

  local diff = require("scm.diff")
  diff.close()
  local win
  if panel().is_open() then
    win = panel().hide()
  else
    win = diff.main_win()
  end
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_set_current_win(win)
  vim.bo[buf].filetype = "diff"
  local width = vim.api.nvim_win_get_width(win)
  local subject = (info.subject or ""):gsub("[\r\n]", " ")
  -- Two extra columns: the winbar starts clipping with "<" when the text fills it.
  subject = panel().truncate(subject, math.max(width - vim.fn.strdisplaywidth(info.short) - 4, 1))
  local function esc(text)
    return (text or ""):gsub("%%", "%%%%")
  end
  vim.wo[win].winbar = "%#ScmSha# " .. esc(info.short) .. " %#ScmTitle# " .. esc(subject) .. "%*"
  -- The patch takes the panel window, so it would otherwise keep the change-list statusline.
  if panel().is_active() then
    panel().release_chrome(win)
  end
  local function back()
    if panel().is_active() and panel().show(win) then
      return
    end
    if #vim.api.nvim_tabpage_list_wins(0) > 1 then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  vim.keymap.set("n", "q", back, { buffer = buf, desc = "SCM: back to the commit" })
  vim.keymap.set("n", "<BS>", back, { buffer = buf, desc = "SCM: back to the commit" })
end

--- Inspect the commit that last touched the current line (GitLens' blame jump).
function M.blame_current_line()
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
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local sha, err = git.blame_line(root, vim.fs.relpath(root, path) or path, lnum)
  if not sha then
    vim.notify("scm: " .. (err or "no blame information"), vim.log.levels.WARN)
    return
  end
  panel().open()
  M.open_commit(sha)
end

--- History of the file in the current buffer.
function M.file_history()
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
  panel().open()
  M.open_log({ path = vim.fs.relpath(root, path) or path })
end

return M
