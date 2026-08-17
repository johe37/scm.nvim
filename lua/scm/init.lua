-- scm.nvim — a VS Code style source control view for Neovim.
--
--   :Scm            toggle the panel
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
        if require("scm.panel").is_open() then
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
    desc = "Keep the panel window for the panel — hand other buffers to the editor area",
    callback = function(event)
      local panel = require("scm.panel")
      if not panel.is_open() or event.buf == state.panel.buf then
        return
      end
      if vim.api.nvim_get_current_win() ~= state.panel.win then
        return
      end
      vim.api.nvim_win_set_buf(state.panel.win, state.panel.buf)
      local win = require("scm.diff").main_win()
      vim.api.nvim_win_set_buf(win, event.buf)
      vim.api.nvim_set_current_win(win)
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    desc = "Forget windows the user closed by hand",
    callback = function(event)
      local win = tonumber(event.match)
      if win == state.panel.win then
        state.panel.win = nil
      elseif win == state.diff.left_win or win == state.diff.right_win then
        vim.schedule(function()
          require("scm.diff").close()
        end)
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
  require("scm.panel").open()
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

--- Commit history in the sidebar.
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
