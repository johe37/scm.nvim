local M = {}

M.defaults = {
  -- Kept so existing setups that pass these do not error. The panel is no
  -- longer a sidebar: it takes over the current window.
  width = 42,
  position = "left", ---@type "left"|"right"
  -- Group changed files under their directories instead of listing every path
  -- flat. Directory chains with a single child are joined into one line.
  tree = true,
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
