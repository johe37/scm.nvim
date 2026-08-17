local M = {}

M.defaults = {
  -- Width of the source control panel.
  width = 42,
  -- Open the panel on the left (like VS Code) or the right.
  position = "left", ---@type "left"|"right"
  -- Fold away unchanged regions in the diff. VS Code shows the whole file, so off.
  fold_unchanged = false,
  -- Ask before discarding working tree changes / deleting untracked files.
  confirm_discard = true,
  -- Re-run the diff a moment after you stop typing, so the highlights track edits.
  live_diff = true,
  live_diff_debounce = 150,
  -- Apply the diff options that make side-by-side diffs readable.
  set_diffopt = true,
  -- Refresh the panel after writes and when Neovim regains focus.
  auto_refresh = true,
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.options
end

return setmetatable(M, {
  __index = function(_, key)
    return M.options[key]
  end,
})
