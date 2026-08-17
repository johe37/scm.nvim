-- A scratch commit message buffer. Write it (`:w` or <C-c><C-c>) to commit,
-- quit it to abort — the same muscle memory as `git commit`.
local git = require("scm.git")
local state = require("scm.state")

local M = {}

local function message_of(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local kept = {}
  for _, line in ipairs(lines) do
    if line:sub(1, 1) ~= "#" then
      kept[#kept + 1] = line
    end
  end
  return vim.trim(table.concat(kept, "\n"))
end

---@param opts? { amend?: boolean }
function M.open(opts)
  opts = opts or {}
  if not state.root then
    state.root = git.root(vim.api.nvim_buf_get_name(0))
  end
  if not state.root then
    vim.notify("scm: not inside a git repository", vim.log.levels.WARN)
    return
  end

  local status = git.status(state.root)
  if #status.conflicted > 0 then
    vim.notify("scm: resolve the merge conflicts first", vim.log.levels.WARN)
    return
  end
  if #status.staged == 0 and not opts.amend then
    vim.notify("scm: nothing staged — stage files with `s` in the panel first", vim.log.levels.WARN)
    return
  end

  local lines = {}
  if opts.amend then
    for _, line in ipairs(vim.split(git.last_message(state.root), "\n", { plain = true })) do
      lines[#lines + 1] = line
    end
  else
    lines[#lines + 1] = ""
  end
  lines[#lines + 1] = "# Write the message, then :w to commit or :q to abort."
  if opts.amend then
    lines[#lines + 1] = "# Amending " .. git.branch(state.root) .. "'s last commit."
  end
  lines[#lines + 1] = "#"
  for _, entry in ipairs(status.staged) do
    lines[#lines + 1] = string.format("#   %s  %s", entry.label, entry.path)
  end

  local existing = vim.fn.bufnr("scm://COMMIT_MSG")
  if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
    pcall(vim.api.nvim_buf_delete, existing, { force = true })
  end

  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, "scm://COMMIT_MSG")
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false

  vim.cmd("botright split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_height(win, math.min(#lines + 2, 14))
  vim.wo[win].winbar = "%#ScmTitle# Commit message %*"
  vim.wo[win].number = false
  vim.bo[buf].filetype = "gitcommit"

  local function commit()
    local message = message_of(buf)
    if message == "" then
      vim.notify("scm: empty commit message, aborting", vim.log.levels.WARN)
      return
    end
    if git.commit(state.root, message, opts.amend) then
      vim.bo[buf].modified = false
      if vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, true)
      end
      require("scm.panel").refresh()
      require("scm.diff").refresh()
    end
  end

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = commit,
  })
  vim.keymap.set({ "n", "i" }, "<C-c><C-c>", function()
    vim.cmd("stopinsert")
    commit()
  end, { buffer = buf, desc = "SCM: commit" })
  vim.keymap.set("n", "q", function()
    vim.bo[buf].modified = false
    pcall(vim.api.nvim_win_close, win, true)
  end, { buffer = buf, desc = "SCM: abort commit" })

  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  vim.cmd("startinsert")
end

return M
