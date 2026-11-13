if vim.g.loaded_quill then
  return
end
vim.g.loaded_quill = true

vim.api.nvim_create_user_command("Quill", function(cmd)
  require("quill").start(cmd.line1, cmd.line2, { instruction = cmd.args ~= "" and cmd.args or nil })
end, { range = true, nargs = "*", desc = "Quill: AI edit of the selected lines" })
vim.api.nvim_create_user_command("QuillAsk", function(cmd)
  require("quill").ask(cmd.args)
end, { nargs = "*", desc = "Quill: ask about the code under the cursor" })
vim.api.nvim_create_user_command("QuillCancel", function()
  require("quill").cancel()
end, {})
require("quill.render").define_highlights()
