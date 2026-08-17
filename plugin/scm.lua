if vim.g.loaded_scm then
  return
end
vim.g.loaded_scm = true

local function cmd(name, fn, opts)
  vim.api.nvim_create_user_command(name, fn, opts or {})
end

cmd("Scm", function()
  require("scm").toggle()
end, { desc = "Toggle the source control panel" })

cmd("ScmOpen", function()
  require("scm").open()
end, { desc = "Open the source control panel" })

cmd("ScmClose", function()
  require("scm").close()
end, { desc = "Close the source control panel and any diff" })

cmd("ScmRefresh", function()
  require("scm").refresh()
end, { desc = "Refresh the source control panel" })

cmd("ScmDiff", function(args)
  require("scm").diff_current({ rev = args.args ~= "" and args.args or nil })
end, { nargs = "?", desc = "Diff the current file side by side (optionally against a revision)" })

cmd("ScmDiffClose", function()
  require("scm").close_diff()
end, { desc = "Close the side-by-side diff" })

cmd("ScmLog", function(args)
  require("scm").log({ rev = args.args ~= "" and args.args or nil })
end, { nargs = "?", desc = "Browse the commit history in the panel" })

cmd("ScmFileLog", function()
  require("scm").file_history()
end, { desc = "Browse the history of the current file" })

cmd("ScmShow", function(args)
  require("scm").show(args.args ~= "" and args.args or "HEAD")
end, { nargs = "?", desc = "Inspect a commit and the files it touched" })

cmd("ScmBlame", function()
  require("scm").blame_line()
end, { desc = "Inspect the commit that last touched the current line" })

cmd("ScmCommit", function(args)
  require("scm").commit({ amend = args.args == "amend" })
end, { nargs = "?", complete = function()
  return { "amend" }
end, desc = "Write a commit message for the staged changes" })
