-- History views for the sidebar: a commit list (repo-wide or for one file) and a
-- single commit's details, with its files openable as side-by-side diffs. The
-- GitLens half of the plugin.
local git = require("scm.git")
local state = require("scm.state")

local M = {}

M.PAGE = 50

local function panel()
  return require("scm.panel")
end

--- Truncate to the panel width so long subjects do not need horizontal scrolling.
local function fit(text, width)
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  return vim.fn.strcharpart(text, 0, math.max(width - 1, 1)) .. "…"
end

---------------------------------------------------------------------------
-- Commit list
---------------------------------------------------------------------------

--- @param view { path?: string, rev?: string, limit: integer }
function M.render_log(add, view, width)
  local commits = git.log(state.root, { limit = view.limit + 1, path = view.path, rev = view.rev })
  local more = #commits > view.limit
  if more then
    table.remove(commits)
  end

  add(" History", { { 0, -1, "ScmTitle" } })
  if view.path then
    add(" " .. fit(view.path, width - 2), { { 0, -1, "ScmBranch" } })
  else
    add(" " .. git.branch(state.root), { { 0, -1, "ScmBranch" } })
  end
  add(" " .. vim.fs.basename(state.root or ""), { { 0, -1, "ScmDim" } })
  add("")

  if #commits == 0 then
    add("  No commits", { { 0, -1, "ScmDim" } })
    return
  end

  for _, commit in ipairs(commits) do
    local item = { type = "commit", commit = commit, key = "commit:" .. commit.sha }
    local subject = fit(commit.subject, width - #commit.short - 5)
    add(
      string.format(" %s  %s", commit.short, subject),
      { { 1, 1 + #commit.short, "ScmSha" }, { 3 + #commit.short, -1, "ScmPath" } },
      { item = item }
    )
    local meta = string.format("   %s · %s", commit.author, commit.rel_date)
    if #commit.parents > 1 then
      meta = meta .. " · merge"
    end
    if commit.file and (commit.file.code == "R" or commit.file.code == "C") then
      meta = meta .. " · was " .. vim.fs.basename(commit.file.orig or "")
    end
    add(fit(meta, width - 1), { { 0, -1, "ScmDim" } }, { item = item })
  end

  if more then
    add("")
    add("  m  load more", { { 0, -1, "ScmDim" } }, { item = { type = "more", key = "more" } })
  end
end

---------------------------------------------------------------------------
-- Single commit
---------------------------------------------------------------------------

local CODE_HL = {
  M = "ScmModified",
  A = "ScmAdded",
  D = "ScmDeleted",
  R = "ScmRenamed",
  C = "ScmRenamed",
  T = "ScmModified",
}

--- @param view { sha: string }
function M.render_commit(add, view, width)
  local commit, err = git.commit_info(state.root, view.sha)
  if not commit then
    add(" " .. (err or "unknown revision"), { { 0, -1, "ScmConflict" } })
    return
  end
  view.commit = commit

  add(" " .. commit.short, { { 0, -1, "ScmTitle" } })
  for _, line in ipairs(vim.split(commit.subject, "\n", { plain = true })) do
    add(" " .. fit(line, width - 2), { { 0, -1, "ScmPath" } })
  end
  add(" " .. fit(commit.author .. " · " .. commit.rel_date, width - 2), { { 0, -1, "ScmBranch" } })
  add(" " .. fit(commit.date, width - 2), { { 0, -1, "ScmDim" } })
  if #commit.parents > 1 then
    add(" merge of " .. #commit.parents .. " parents (vs first)", { { 0, -1, "ScmDim" } })
  end

  if commit.body ~= "" then
    add("")
    for _, line in ipairs(vim.split(commit.body, "\n", { plain = true })) do
      add(" " .. fit(line, width - 2), { { 0, -1, "ScmDim" } })
    end
  end

  local files = git.commit_files(state.root, commit)
  view.files = files
  add("")
  add(string.format(" v Files (%d)", #files), { { 0, -1, "ScmSection" } })
  for _, file in ipairs(files) do
    local base = vim.fs.basename(file.path)
    local dir = vim.fs.dirname(file.path)
    dir = (dir == "." or dir == "") and "" or dir
    local prefix = string.format("   %s  ", file.code)
    local text = prefix .. base
    local hls = {
      { 3, 4, CODE_HL[file.code] or "ScmModified" },
      { #prefix, #prefix + #base, file.code == "D" and "ScmDeleted" or "ScmPath" },
    }
    if dir ~= "" then
      text = text .. "  " .. dir
      hls[#hls + 1] = { #prefix + #base, -1, "ScmDim" }
    end
    add(fit(text, width - 1), hls, { item = { type = "commit_file", file = file, key = "cf:" .. file.path } })
  end

  add("")
  add("  D  full patch", { { 0, -1, "ScmDim" } }, { item = { type = "patch", key = "patch" } })
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

--- Show the repo history (or one file's history) in the sidebar.
---@param opts? { path?: string, rev?: string }
function M.open_log(opts)
  opts = opts or {}
  panel().set_view({ kind = "log", limit = M.PAGE, path = opts.path, rev = opts.rev })
end

--- Show one commit's details in the sidebar.
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
  require("scm.diff").open({
    path = file.path,
    code = file.code,
    kind = "commit_file",
    label = file.label,
    left_spec = left,
    right_spec = right,
    left_label = left and (file.parent and file.parent:sub(1, 7) or "parent") .. ":" .. (file.orig or file.path)
      or "(added in this commit)",
    right_label = right and (file.sha:sub(1, 7) .. ":" .. file.path) or "(deleted in this commit)",
  })
end

--- Open the whole commit as a unified patch in the editor area.
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
  local win = diff.main_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_set_current_win(win)
  vim.bo[buf].filetype = "diff"
  vim.wo[win].winbar = "%#ScmDiffNew# " .. info.short .. " " .. info.subject:gsub("%%", "%%%%") .. " %*"
  vim.keymap.set("n", "q", function()
    if #vim.api.nvim_tabpage_list_wins(0) > 1 then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end, { buffer = buf, desc = "SCM: close patch" })
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
