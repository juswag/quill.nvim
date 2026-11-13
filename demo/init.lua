-- Config for the recorded demo only: a flat light palette matching assets/banner.svg,
-- a small statusline, and the mock provider with a two-turn rewrite.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
vim.g.mapleader = " "
vim.o.termguicolors = true
vim.o.background = "light"
vim.o.number = true
vim.o.signcolumn = "yes:1"
vim.o.laststatus = 3
vim.o.cmdheight = 0
vim.o.showmode = false
vim.o.ruler = false
vim.o.shortmess = vim.o.shortmess .. "IFc"
vim.o.swapfile = false
vim.o.fillchars = "eob: "
vim.o.numberwidth = 4

local ink, grey, faint, line, paper, wash = "#0d1117", "#6e7781", "#afb8c1", "#d0d7de", "#ffffff", "#f6f8fa"
local hl = function(name, spec) vim.api.nvim_set_hl(0, name, spec) end
vim.cmd("hi clear")
for name, spec in pairs({
  Normal = { fg = ink, bg = paper }, NormalFloat = { fg = ink, bg = paper }, FloatBorder = { fg = line, bg = paper },
  LineNr = { fg = faint }, CursorLineNr = { fg = ink }, SignColumn = { bg = paper }, Visual = { bg = "#e7ebef" },
  Comment = { fg = grey }, String = { fg = "#0a3069" }, Number = { fg = "#0550ae" }, Boolean = { fg = "#0550ae" },
  Keyword = { fg = grey }, Statement = { fg = grey }, Conditional = { fg = grey }, Function = { fg = ink, bold = true },
  Identifier = { fg = ink }, Operator = { fg = ink }, Delimiter = { fg = grey }, Special = { fg = ink }, Type = { fg = "#0550ae" },
  StatusLine = { fg = grey, bg = wash }, StatusLineNC = { fg = grey, bg = wash }, MsgArea = { fg = grey },
  DiagnosticError = { fg = "#cf222e" }, DiagnosticOk = { fg = "#1a7f37" }, DiagnosticInfo = { fg = ink },
  ["@variable"] = { fg = ink }, ["@variable.builtin"] = { fg = "#0550ae" }, ["@constant.builtin"] = { fg = "#0550ae" },
  ["@keyword"] = { fg = grey }, ["@keyword.function"] = { fg = grey }, ["@keyword.return"] = { fg = grey },
  ["@keyword.conditional"] = { fg = grey }, ["@keyword.operator"] = { fg = grey }, ["@function"] = { fg = ink, bold = true },
  ["@function.call"] = { fg = ink }, ["@function.method.call"] = { fg = ink }, ["@function.builtin"] = { fg = ink },
  ["@property"] = { fg = ink }, ["@field"] = { fg = ink }, ["@punctuation"] = { fg = grey }, ["@punctuation.bracket"] = { fg = grey },
  ["@punctuation.delimiter"] = { fg = grey }, ["@comment"] = { fg = grey }, ["@string"] = { fg = "#0a3069" },
  ["@number"] = { fg = "#0550ae" }, ["@module"] = { fg = ink }, ["@type"] = { fg = "#0550ae" },
  DemoMode = { fg = paper, bg = ink, bold = true }, DemoFile = { fg = ink, bg = wash }, DemoBar = { fg = grey, bg = wash },
}) do
  hl(name, spec)
end
vim.api.nvim_create_autocmd("FileType", { pattern = "lua", callback = function() pcall(vim.treesitter.start) end })

function _G.demo_statusline()
  local mode = vim.api.nvim_get_mode().mode
  local name = mode:match("^[vV\22]") and "VISUAL" or mode:match("^i") and "INSERT" or "NORMAL"
  local s = require("quill").get_session(vim.fn.bufnr("sample.lua"))
  local session = s and ("quill · %s  "):format(s.phase) or ""
  return ("%%#DemoMode# %s %%#DemoFile# sample.lua %%#DemoBar#%%=%s lua  %%l:%%c "):format(name, session)
end
vim.o.statusline = "%!v:lua.demo_statusline()"

local handled = [[
function M.read_config(path)
  local file, err = io.open(path)
  if not file then
    return nil, err
  end
  local text = file:read("*a")
  file:close()
  local ok, config = pcall(vim.json.decode, text)
  return ok and config or nil
end
]]
local typed = [[
---@param path string
---@return table|nil config, string|nil err
]] .. handled

require("quill").setup({
  provider = "mock",
  providers = { mock = {
    chunk_size = 2,
    interval_ms = 16,
    response = function(req)
      return #req.history > 1 and typed or handled
    end,
  } },
})
