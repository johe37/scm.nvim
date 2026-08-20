-- scm.nvim — a full-screen source control view for Neovim.
--
--   :Scm            toggle the change list; from history, come back to it
--   :ScmDiff        diff the current file side by side
--   :ScmCommit      write a commit message for what is staged
--   :ScmLog         browse commits; <CR> inspects one, its files diff on <CR>
--   :ScmFileLog     history of the current file
--   :ScmShow <rev>  inspect one commit
--   :ScmBlame       inspect the commit behind the current line
local config = require("scm.config")

local M = {}

local HIGHLIGHTS = {
  ScmTitle = { link = "Title" },
  ScmSection = { link = "Statement" },
  ScmBranch = { link = "Special" },
  ScmDim = { link = "Comment" },
  ScmDir = { link = "Directory" },
  ScmSha = { link = "Identifier" },
  ScmPath = { link = "Normal" },
  ScmAdded = { link = "Added" },
  ScmModified = { link = "Changed" },
  ScmDeleted = { link = "Removed" },
  ScmRenamed = { link = "Changed" },
  ScmConflict = { link = "DiagnosticError" },
  ScmUntracked = { link = "Comment" },
  ScmDiffOld = { link = "DiffDelete" },
  ScmDiffNew = { link = "DiffAdd" },
}

local function set_highlights()
  for name, spec in pairs(HIGHLIGHTS) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("keep", { default = true }, spec))
  end
end

local function set_diffopt()
  -- `linematch` is what makes the side-by-side view line up the way VS Code's does.
  local wanted = { "internal", "filler", "closeoff", "vertical", "algorithm:histogram", "linematch:60" }
  local current = vim.opt.diffopt:get()
  local has = {}
  for _, item in ipairs(current) do
    has[item:gsub(":.*", "")] = true
  end
  for _, item in ipairs(wanted) do
    if not has[item:gsub(":.*", "")] then
      vim.opt.diffopt:append(item)
    end
  end
end

local function set_autocmds()
  local group = vim.api.nvim_create_augroup("scm", { clear = true })
  local state = require("scm.state")

  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_highlights })

  if config.auto_refresh then
    vim.api.nvim_create_autocmd({ "BufWritePost", "FocusGained" }, {
      group = group,
      desc = "Refresh the SCM panel after changes on disk",
      callback = function()
        if require("scm.panel").is_active() then
          vim.schedule(function()
            require("scm.panel").refresh()
          end)
        end
      end,
    })
  end

  if config.live_diff then
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      group = group,
      desc = "Keep the side-by-side diff in step with live edits",
      callback = function(event)
        if require("scm.diff").owns_buf(event.buf) then
          require("scm.diff").schedule_update()
        end
      end,
    })
  end

  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    desc = "Keep the panel window for the panel — hand other buffers to another window",
    callback = function(event)
      local panel = require("scm.panel")
      if not panel.is_open() or event.buf == state.panel.buf or state.diff.closing then
        return
      end
      -- Only when the panel window itself received this buffer. Checking the
      -- current window is wrong: `<CR>` after `q` sets a file in a new split
      -- while the cursor may still be on the panel, and that used to steal
      -- the buffer and collapse the just-opened diff.
      if vim.api.nvim_win_get_buf(state.panel.win) ~= event.buf then
        return
      end
      local other
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if win ~= state.panel.win and vim.api.nvim_win_get_config(win).relative == "" then
          other = win
          break
        end
      end
      vim.api.nvim_win_set_buf(state.panel.win, state.panel.buf)
      if other then
        vim.api.nvim_win_set_buf(other, event.buf)
        vim.api.nvim_set_current_win(other)
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    desc = "Forget windows the user closed by hand",
    callback = function(event)
      local win = tonumber(event.match)
      if win == state.panel.win then
        state.panel.win = nil
        state.panel.active = false
        state.panel.hidden = false
        state.panel.prev_buf = nil
        state.panel.saved = nil
      else
        require("scm.diff").on_win_closed(win)
      end
    end,
  })
end

function M.setup(opts)
  config.setup(opts)
  set_highlights()
  if config.set_diffopt then
    set_diffopt()
  end
  set_autocmds()
end

-- Public API, all lazily resolved so `require("scm")` stays cheap.
function M.open()
  require("scm.panel").show_status()
end

function M.close()
  require("scm.panel").close()
end

function M.toggle()
  require("scm.panel").toggle()
end

function M.refresh()
  require("scm.panel").refresh()
  require("scm.diff").refresh()
end

---@param opts? { rev?: string }
function M.diff_current(opts)
  require("scm.panel").diff_current(opts)
end

function M.close_diff()
  require("scm.diff").close()
end

---@param opts? { amend?: boolean }
function M.commit(opts)
  require("scm.commit").open(opts)
end

--- Commit history in the panel.
---@param opts? { path?: string, rev?: string }
function M.log(opts)
  require("scm.panel").open()
  require("scm.log").open_log(opts)
end

--- History of the file in the current buffer.
function M.file_history()
  require("scm.log").file_history()
end

--- Inspect one commit: metadata, message, and the files it touched.
function M.show(rev)
  require("scm.panel").open()
  require("scm.log").open_commit(rev or "HEAD")
end

--- Inspect the commit that last touched the current line.
function M.blame_line()
  require("scm.log").blame_current_line()
end

return M
