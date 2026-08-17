-- Shared mutable state. Kept in its own module so panel/diff/commit can all see
-- the same windows without requiring each other in a cycle.
return {
  root = nil, ---@type string|nil

  panel = {
    buf = nil, ---@type integer|nil
    win = nil, ---@type integer|nil
    entries = {}, ---@type table<integer, table> line number -> item under that line
    sections = {}, ---@type table<integer, string> line number -> section key
    collapsed = {}, ---@type table<string, boolean>
    status = nil,
    view = nil, ---@type table|nil the view the panel currently shows
    stack = {}, ---@type table[] views to walk back through with <BS>
    -- True from :Scm / panel.open until the session is dismissed. Stays true
    -- while a diff or patch has taken over the window (the list is hidden).
    active = false,
    hidden = false,
    prev_buf = nil, ---@type integer|nil buffer the window showed before the panel
    saved = nil, ---@type table<string, any>|nil window options captured on open
  },

  diff = {
    left_win = nil, ---@type integer|nil
    right_win = nil, ---@type integer|nil
    left_buf = nil, ---@type integer|nil
    right_buf = nil, ---@type integer|nil
    entry = nil, ---@type table|nil
    prev_buf = nil, ---@type integer|nil buffer the editor showed before the diff
    gen = 0, ---@type integer bumped on each open/close so stale WinClosed callbacks no-op
    closing = false, ---@type boolean true while close() is tearing windows down
    saved = {}, ---@type table window id -> options captured before diff mode
  },
}
