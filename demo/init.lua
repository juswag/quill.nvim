-- Config for the recorded demo only: tokyonight, a small statusline, the mock provider.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
vim.opt.rtp:prepend(root .. "/demo/.deps/tokyonight.nvim")
vim.g.mapleader = " "
vim.o.termguicolors = true
vim.o.number = true
vim.o.signcolumn = "yes:1"
vim.o.cursorline = true
vim.o.cursorlineopt = "number"
vim.o.laststatus = 3
vim.o.showmode = false
vim.o.ruler = false
vim.o.shortmess = vim.o.shortmess .. "IFc"
vim.o.swapfile = false
vim.o.fillchars = "eob: "
vim.o.numberwidth = 4

require("tokyonight").setup({ style = "night" })
vim.cmd.colorscheme("tokyonight")
vim.api.nvim_create_autocmd("FileType", { pattern = "lua", callback = function() pcall(vim.treesitter.start) end })

local c = require("tokyonight.colors").setup({ style = "night" })
vim.api.nvim_set_hl(0, "DemoMode", { fg = c.bg_dark, bg = c.blue, bold = true })
vim.api.nvim_set_hl(0, "DemoModeVisual", { fg = c.bg_dark, bg = c.magenta, bold = true })
vim.api.nvim_set_hl(0, "DemoModeInsert", { fg = c.bg_dark, bg = c.green, bold = true })
vim.api.nvim_set_hl(0, "DemoFile", { fg = c.fg, bg = c.bg_highlight })
vim.api.nvim_set_hl(0, "DemoBar", { fg = c.comment, bg = c.bg_dark })
vim.api.nvim_set_hl(0, "DemoSession", { fg = c.blue, bg = c.bg_dark, bold = true })

function _G.demo_statusline()
  local mode = vim.api.nvim_get_mode().mode
  local name, hl = "NORMAL", "DemoMode"
  if mode:match("^[vV\22]") then
    name, hl = "VISUAL", "DemoModeVisual"
  elseif mode:match("^i") then
    name, hl = "INSERT", "DemoModeInsert"
  end
  local session = ""
  local s = require("quill").get_session(vim.fn.bufnr("sample.lua"))
  if s then
    session = ("%%#DemoSession# ✎ quill · %s "):format(s.phase)
  end
  return ("%%#%s# %s %%#DemoFile# sample.lua %%#DemoBar#%%=%s%%#DemoBar# lua  %%l:%%c "):format(hl, name, session)
end
vim.o.statusline = "%!v:lua.demo_statusline()"

local rewrite = [[
function M.parse_port(value)
  local n = tonumber(value)
  if not n or n < 1 or n > 65535 then
    return nil, "invalid port: " .. tostring(value)
  end
  return n
end

---@param user { first: string, last: string, email: string }
function M.format_user(user)
  local name = table.concat({ user.first, user.last }, " ")
  return ("%s <%s>"):format(name, user.email)
end
]]

require("quill").setup({
  provider = "mock",
  providers = { mock = { response = rewrite, chunk_size = 3, interval_ms = 30 } },
})

-- Key overlay so viewers can see what was pressed; typed text is grouped into one chip.
vim.api.nvim_set_hl(0, "DemoKey", { fg = c.fg, bg = c.bg_highlight, bold = true })
local kbuf = vim.api.nvim_create_buf(false, true)
local kns = vim.api.nvim_create_namespace("demo_keys")
local kwin, recent, typing = nil, {}, false
vim.on_key(function(_, typed)
  if not typed or typed == "" then
    return
  end
  local key = vim.fn.keytrans(typed)
  vim.schedule(function()
    local printable = #key == 1 or key == "<Space>"
    local ch = key == "<Space>" and " " or key
    if printable and typing and vim.api.nvim_get_mode().mode == "i" then
      recent[#recent] = recent[#recent] .. ch
    else
      recent[#recent + 1] = key == "<Space>" and "␣" or key
    end
    typing = printable and vim.api.nvim_get_mode().mode == "i"
    while #recent > 4 or #table.concat(recent, "   ") > 46 do
      table.remove(recent, 1)
    end
    local text, marks = " ", {}
    for _, k in ipairs(recent) do
      local label = " " .. k .. " "
      marks[#marks + 1] = { #text, #text + #label }
      text = text .. label .. " "
    end
    vim.api.nvim_buf_set_lines(kbuf, 0, -1, false, { text })
    for _, m in ipairs(marks) do
      vim.api.nvim_buf_set_extmark(kbuf, kns, 0, m[1], { end_col = m[2], hl_group = "DemoKey" })
    end
    local cfg = { relative = "editor", anchor = "NE", row = 0, col = vim.o.columns, width = vim.fn.strdisplaywidth(text),
      height = 1, style = "minimal", border = "rounded", focusable = false, zindex = 80, title = " keys ", title_pos = "right" }
    if kwin and vim.api.nvim_win_is_valid(kwin) then
      vim.api.nvim_win_set_config(kwin, cfg)
    else
      kwin = vim.api.nvim_open_win(kbuf, false, cfg)
      vim.wo[kwin].winhighlight = "NormalFloat:NormalFloat,FloatBorder:FloatBorder"
    end
  end)
end)
