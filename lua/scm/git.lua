-- Thin wrapper around the `git` CLI. Everything is synchronous: the commands we
-- run (status, show, add, reset) are cheap enough that a blocking call keeps the
-- rest of the plugin free of callback plumbing.
local M = {}

---@param args string[]
---@param opts? { cwd?: string, stdin?: string }
function M.run(args, opts)
  opts = opts or {}
  local cmd = { "git", "--no-pager", "--literal-pathspecs" }
  for _, a in ipairs(args) do
    cmd[#cmd + 1] = a
  end
  local ok, res = pcall(function()
    return vim.system(cmd, { text = true, cwd = opts.cwd, stdin = opts.stdin }):wait()
  end)
  if not ok then
    return { code = 1, stdout = "", stderr = tostring(res) }
  end
  res.stdout = res.stdout or ""
  res.stderr = res.stderr or ""
  return res
end

--- Run git and report failures to the user.
---@return boolean ok
function M.exec(args, opts)
  local res = M.run(args, opts)
  if res.code ~= 0 then
    local msg = vim.trim(res.stderr ~= "" and res.stderr or res.stdout)
    vim.notify("scm: git " .. table.concat(args, " ") .. "\n" .. msg, vim.log.levels.ERROR)
    return false
  end
  return true
end

--- Repository root containing `path` (a file or directory), or nil.
---@param path? string
---@return string|nil
function M.root(path)
  path = path or vim.uv.cwd()
  if path == "" or vim.fn.isdirectory(path) == 0 then
    path = vim.fs.dirname(path)
  end
  if not path or path == "" or vim.fn.isdirectory(path) == 0 then
    return nil
  end
  local res = M.run({ "rev-parse", "--show-toplevel" }, { cwd = path })
  if res.code ~= 0 then
    return nil
  end
  local root = vim.trim(res.stdout)
  return root ~= "" and root or nil
end

--- True when HEAD points at a commit (false in a repo with no commits yet).
function M.has_head(root)
  return M.run({ "rev-parse", "--verify", "--quiet", "HEAD" }, { cwd = root }).code == 0
end

function M.branch(root)
  local res = M.run({ "symbolic-ref", "--short", "HEAD" }, { cwd = root })
  if res.code == 0 then
    return vim.trim(res.stdout)
  end
  local sha = M.run({ "rev-parse", "--short", "HEAD" }, { cwd = root })
  if sha.code == 0 then
    return "detached " .. vim.trim(sha.stdout)
  end
  return "no commits yet"
end

--- How far the current branch is ahead/behind its upstream.
---@return { ahead: integer, behind: integer }|nil
function M.upstream(root)
  local res = M.run({ "rev-list", "--left-right", "--count", "HEAD...@{upstream}" }, { cwd = root })
  if res.code ~= 0 then
    return nil
  end
  local ahead, behind = vim.trim(res.stdout):match("^(%d+)%s+(%d+)$")
  if not ahead then
    return nil
  end
  return { ahead = tonumber(ahead), behind = tonumber(behind) }
end

--- What the history view compares HEAD against.
--- On master (or main) that is the upstream, then `origin/master`, so commits
--- that are not published yet still stand out from the ones already there.
--- On any other branch it is local `master`, then `main`. Nil when none exist.
---@return string|nil
function M.base_ref(root)
  local branch = M.branch(root)
  local candidates = {}
  local function add(ref)
    candidates[#candidates + 1] = ref
  end
  if branch == "master" or branch == "main" then
    add("@{upstream}")
  end
  if branch ~= "master" then
    add("master")
  end
  add("origin/master")
  if branch ~= "main" then
    add("main")
  end
  add("origin/main")
  for _, ref in ipairs(candidates) do
    local res = M.run({ "rev-parse", "--verify", "--quiet", ref .. "^{commit}" }, { cwd = root })
    if res.code == 0 then
      -- @{upstream} verifies, but the view should name the branch it points at.
      local shown = M.run({ "rev-parse", "--abbrev-ref", ref }, { cwd = root })
      local name = vim.trim(shown.stdout or "")
      if shown.code == 0 and name ~= "" and name ~= "HEAD" then
        return name
      end
      return ref
    end
  end
  return nil
end

--- How many commits HEAD has that `ref` does not.
function M.ahead_of(root, ref)
  local res = M.run({ "rev-list", "--count", "HEAD", "--not", ref }, { cwd = root })
  if res.code ~= 0 then
    return 0
  end
  return tonumber(vim.trim(res.stdout)) or 0
end

--- Full shas from `shas` that are not contained in `ref`.
--- `--no-walk` keeps the listed commits, and the negative ref still excludes
--- everything reachable from it.
---@param shas string[]
---@return table<string, boolean>
function M.not_on(root, ref, shas)
  local set = {}
  if not ref or #shas == 0 then
    return set
  end
  local args = { "rev-list", "--no-walk" }
  for _, sha in ipairs(shas) do
    args[#args + 1] = sha
  end
  args[#args + 1] = "--not"
  args[#args + 1] = ref
  local res = M.run(args, { cwd = root })
  if res.code ~= 0 then
    return set
  end
  for line in vim.gsplit(res.stdout, "\n", { plain = true, trimempty = true }) do
    set[line] = true
  end
  return set
end

local STATUS_LABEL = {
  M = "modified",
  A = "added",
  D = "deleted",
  R = "renamed",
  C = "copied",
  T = "typechange",
  U = "conflict",
  ["?"] = "untracked",
}

--- Working tree status, split into the three sections the panel renders.
---@return { staged: table[], unstaged: table[], untracked: table[], conflicted: table[] }
function M.status(root)
  local out = { staged = {}, unstaged = {}, untracked = {}, conflicted = {} }
  local res = M.run({ "status", "--porcelain=v1", "-z", "--untracked-files=all" }, { cwd = root })
  if res.code ~= 0 then
    return out
  end

  -- With -z each record is NUL terminated; rename/copy records are followed by a
  -- second NUL terminated field holding the original path.
  local fields = vim.split(res.stdout, "\0", { plain = true })
  local i = 1
  while fields[i] and fields[i] ~= "" do
    local record = fields[i]
    local x, y, path = record:sub(1, 1), record:sub(2, 2), record:sub(4)
    local orig = nil
    if x == "R" or x == "C" or y == "R" or y == "C" then
      orig = fields[i + 1]
      i = i + 1
    end
    i = i + 1

    local function entry(code, kind)
      return {
        path = path,
        orig = orig,
        code = code,
        kind = kind,
        label = STATUS_LABEL[code] or code,
        x = x,
        y = y,
      }
    end

    if x == "U" or y == "U" or (x == "A" and y == "A") or (x == "D" and y == "D") then
      out.conflicted[#out.conflicted + 1] = entry("U", "conflicted")
    elseif x == "?" then
      out.untracked[#out.untracked + 1] = entry("?", "untracked")
    else
      if x ~= " " then
        out.staged[#out.staged + 1] = entry(x, "staged")
      end
      if y ~= " " then
        out.unstaged[#out.unstaged + 1] = entry(y, "unstaged")
      end
    end
  end

  local function by_path(a, b)
    return a.path < b.path
  end
  for _, list in pairs(out) do
    table.sort(list, by_path)
  end
  return out
end

--- Contents of a blob, e.g. spec = "HEAD:lua/init.lua" or ":0:lua/init.lua".
---@return string[]|nil lines, string|nil err
function M.blob(root, spec)
  local res = M.run({ "show", spec }, { cwd = root })
  if res.code ~= 0 then
    return nil, vim.trim(res.stderr)
  end
  if res.stdout:find("\0", 1, true) then
    return nil, "binary file"
  end
  local lines = vim.split(res.stdout, "\n", { plain = true })
  -- git emits a trailing newline; don't turn it into a phantom last line.
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

--- Escape a path so `git show` treats it literally even if it starts with `-`.
function M.spec(rev, path)
  return string.format("%s:%s", rev, path)
end

function M.stage(root, entry)
  return M.exec({ "add", "--", entry.orig or entry.path, entry.path }, { cwd = root })
end

function M.unstage(root, entry)
  local paths = { "reset", "--quiet", "HEAD", "--", entry.path }
  if entry.orig then
    paths[#paths + 1] = entry.orig
  end
  if not M.has_head(root) then
    paths = { "rm", "--cached", "--quiet", "--", entry.path }
  end
  return M.exec(paths, { cwd = root })
end

function M.discard(root, entry)
  if entry.kind == "untracked" then
    return vim.fn.delete(root .. "/" .. entry.path) == 0
  end
  return M.exec({ "checkout", "--", entry.path }, { cwd = root })
end

function M.commit(root, message, amend)
  local args = { "commit", "--file=-", "--cleanup=strip" }
  if amend then
    args[#args + 1] = "--amend"
  end
  local res = M.run(args, { cwd = root, stdin = message })
  if res.code ~= 0 then
    vim.notify("scm: commit failed\n" .. vim.trim(res.stderr .. res.stdout), vim.log.levels.ERROR)
    return false
  end
  vim.notify("scm: " .. vim.trim(vim.split(res.stdout, "\n")[1] or "committed"))
  return true
end

-- Field/record separators for the custom `--format` strings below. Using bytes
-- that cannot appear in a path or a subject line keeps parsing unambiguous.
local FS, RS = "\31", "\30"
-- The record separator leads the format so that the `--name-status` output git
-- appends for a path-filtered log lands inside the record it belongs to.
local LOG_FORMAT = "%x1e" .. table.concat({ "%H", "%h", "%an", "%ar", "%as", "%P", "%s", "%D" }, "%x1f")

--- One record: the formatted fields, optionally followed by NUL separated
--- `--name-status` output for the path we are following.
local function parse_commit_record(record)
  local nul = record:find("\0", 1, true)
  -- git ends each commit's output with a newline; it belongs to no field.
  local head = (nul and record:sub(1, nul - 1) or record):gsub("[\r\n]+$", "")
  local f = vim.split(head, FS, { plain = true })
  if not f[1] or f[1] == "" then
    return nil
  end
  local commit = {
    sha = f[1],
    short = f[2],
    author = f[3],
    rel_date = f[4],
    date = f[5],
    parents = vim.split(f[6] or "", " ", { plain = true, trimempty = true }),
    subject = f[7] or "",
    -- %D is "HEAD -> main, origin/main, tag: v1", or empty.
    refs = vim.trim(f[8] or ""),
  }

  if nul then
    local fields = {}
    for _, field in ipairs(vim.split(record:sub(nul + 1), "\0", { plain = true })) do
      field = field:gsub("^\n", "")
      if field ~= "" then
        fields[#fields + 1] = field
      end
    end
    local code = (fields[1] or ""):sub(1, 1)
    -- The file's name *as of this commit*, which is what a rename changes.
    local file
    if code == "R" or code == "C" then
      file = { code = code, orig = fields[2], path = fields[3] }
    elseif code ~= "" then
      file = { code = code, path = fields[2] }
    end
    if file and file.path then
      file.kind = "commit_file"
      file.label = STATUS_LABEL[file.code] or file.code
      file.sha = commit.sha
      file.parent = commit.parents[1]
      commit.file = file
    end
  end
  return commit
end

--- Commit history, newest first. With `path`, only commits touching that file,
--- each carrying the name the file had at that point (`commit.file`).
---@param opts? { limit?: integer, rev?: string, path?: string }
---@return table[]
function M.log(root, opts)
  opts = opts or {}
  local args = { "log", "--no-color", "--format=" .. LOG_FORMAT }
  if opts.limit then
    args[#args + 1] = "-n" .. opts.limit
  end
  if opts.rev then
    args[#args + 1] = opts.rev
  end
  if opts.path then
    -- --follow keeps the history going across renames, like GitLens does.
    args[#args + 1] = "--follow"
    args[#args + 1] = "--name-status"
    args[#args + 1] = "-z"
    args[#args + 1] = "--find-renames"
    args[#args + 1] = "--"
    args[#args + 1] = opts.path
  end
  local res = M.run(args, { cwd = root })
  if res.code ~= 0 then
    return {}
  end
  local commits = {}
  for _, record in ipairs(vim.split(res.stdout, RS, { plain = true })) do
    local commit = parse_commit_record(record)
    if commit then
      commits[#commits + 1] = commit
    end
  end
  return commits
end

--- Everything needed to describe one commit, including its message body.
---@return table|nil
function M.commit_info(root, rev)
  local format = table.concat({ "%H", "%h", "%an", "%ae", "%ar", "%ad", "%P", "%s", "%b" }, "%x1f")
  local res = M.run({ "show", "--no-patch", "--format=" .. format, "--date=iso", rev }, { cwd = root })
  if res.code ~= 0 then
    return nil, vim.trim(res.stderr)
  end
  local f = vim.split(res.stdout, FS, { plain = true })
  if not f[1] or f[1] == "" then
    return nil, "no such revision: " .. rev
  end
  return {
    sha = f[1],
    short = f[2],
    author = f[3],
    email = f[4],
    rel_date = f[5],
    date = vim.trim(f[6] or ""),
    parents = vim.split(f[7] or "", " ", { plain = true, trimempty = true }),
    subject = f[8] or "",
    body = vim.trim((f[9] or ""):gsub("\n+$", "")),
  }
end

--- `git diff -z --name-status` and `diff-tree` share this shape: a status, then
--- the path, and for a rename the old path before the new one.
local function parse_name_status(stdout)
  local files = {}
  local fields = vim.split(stdout, "\0", { plain = true })
  local i = 1
  while fields[i] and fields[i] ~= "" do
    local code = fields[i]:sub(1, 1)
    -- The path sits in the next field. A rename has the old path there and the
    -- new path after that.
    local path, orig = fields[i + 1], nil
    if code == "R" or code == "C" then
      orig, path = fields[i + 1], fields[i + 2]
      i = i + 3
    else
      i = i + 2
    end
    if path and path ~= "" then
      files[#files + 1] = {
        path = path,
        orig = orig,
        code = code,
        label = STATUS_LABEL[code] or code,
      }
    end
  end
  table.sort(files, function(a, b)
    return a.path < b.path
  end)
  return files
end

--- Files touched by a commit, as status entries the panel can render.
--- Merge commits are compared against their first parent, which is what you
--- almost always want to look at.
---@return table[]
function M.commit_files(root, commit)
  local parent = commit.parents[1]
  local args = { "diff-tree", "-r", "-z", "--name-status", "--no-commit-id", "--find-renames" }
  if parent then
    args[#args + 1] = parent
    args[#args + 1] = commit.sha
  else
    args[#args + 1] = "--root"
    args[#args + 1] = commit.sha
  end
  local res = M.run(args, { cwd = root })
  if res.code ~= 0 then
    return {}
  end
  local files = parse_name_status(res.stdout)
  for _, file in ipairs(files) do
    file.kind = "commit_file"
    file.sha = commit.sha
    file.parent = parent
  end
  return files
end

--- What `sha` introduced after it left `base`. Three-dot: commits and files on
--- this side, not changes that exist only on `base`.
--- `on_base` means `sha` is already contained in `base`. Nil when git can't tell.
---@return { on_base: boolean, commits?: integer, added?: integer, deleted?: integer, files?: table[] }|nil
function M.since(root, base, sha)
  local contained = M.run({ "merge-base", "--is-ancestor", sha, base }, { cwd = root })
  if contained.code == 0 then
    return { on_base = true }
  end
  -- A missing base is an error (not 1). Don't pretend the commit is new work.
  if contained.code ~= 1 then
    return nil
  end
  local range = base .. "..." .. sha
  local count = M.run({ "rev-list", "--count", base .. ".." .. sha }, { cwd = root })
  local stat = M.run({ "diff", "--shortstat", "--find-renames", range }, { cwd = root })
  local names = M.run({ "diff", "-z", "--name-status", "--find-renames", range }, { cwd = root })
  if count.code ~= 0 or stat.code ~= 0 or names.code ~= 0 then
    return nil
  end
  local mb = M.run({ "merge-base", base, sha }, { cwd = root })
  local parent = mb.code == 0 and vim.trim(mb.stdout) or nil
  local summary = vim.trim(stat.stdout)
  local files = parse_name_status(names.stdout)
  for _, file in ipairs(files) do
    -- Left side of a file diff is the fork point, which is what the three-dot
    -- range actually compares.
    file.kind = "commit_file"
    file.sha = sha
    file.parent = parent
  end
  return {
    on_base = false,
    commits = tonumber(vim.trim(count.stdout)) or 0,
    added = tonumber(summary:match("(%d+) insertion")) or 0,
    deleted = tonumber(summary:match("(%d+) deletion")) or 0,
    files = files,
  }
end

--- The whole commit as a unified patch.
---@return string[]
function M.commit_patch(root, rev)
  local res = M.run({ "show", "--no-color", "--stat", "--patch", "--find-renames", rev }, { cwd = root })
  if res.code ~= 0 then
    return { "scm: " .. vim.trim(res.stderr) }
  end
  local lines = vim.split(res.stdout, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

--- Commit that last touched `lnum` in `path`, or nil if the line is not committed.
---@return string|nil sha, string|nil err
function M.blame_line(root, path, lnum)
  local res = M.run({ "blame", "--porcelain", "-L", lnum .. "," .. lnum, "--", path }, { cwd = root })
  if res.code ~= 0 then
    return nil, vim.trim(res.stderr)
  end
  local sha = res.stdout:match("^(%x+)")
  if not sha then
    return nil, "no blame information"
  end
  if sha:match("^0+$") then
    return nil, "line is not committed yet"
  end
  return sha
end

function M.last_message(root)
  local res = M.run({ "log", "-1", "--pretty=%B" }, { cwd = root })
  if res.code ~= 0 then
    return ""
  end
  return vim.trim(res.stdout)
end

return M
