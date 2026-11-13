-- Proof recordings: the demo look, plus :Proof <scene> to switch provider setups on camera.
local root = vim.env.QUILL_ROOT
vim.opt.rtp:prepend(root)
vim.opt.rtp:prepend("/workspace/quill.nvim/demo/.deps/tokyonight.nvim")
vim.g.mapleader = " "
vim.o.termguicolors = true
vim.o.number = true
vim.o.signcolumn = "yes:1"
vim.o.laststatus = 3
vim.o.showmode = false
vim.o.ruler = false
vim.o.shortmess = vim.o.shortmess .. "IFc"
vim.o.swapfile = false
vim.o.fillchars = "eob: "
require("tokyonight").setup({ style = "night" })
vim.cmd.colorscheme("tokyonight")
local c = require("tokyonight.colors").setup({ style = "night" })
vim.api.nvim_set_hl(0, "ProofMode", { fg = c.bg_dark, bg = c.blue, bold = true })
vim.api.nvim_set_hl(0, "ProofBar", { fg = c.comment, bg = c.bg_dark })
vim.api.nvim_set_hl(0, "ProofSession", { fg = c.blue, bg = c.bg_dark, bold = true })
vim.api.nvim_set_hl(0, "ProofLabel", { fg = c.bg_dark, bg = c.yellow, bold = true })
vim.api.nvim_set_hl(0, "ProofBranch", { fg = c.fg, bg = c.bg_highlight })

local ai = require("quill")
local branch = vim.env.PROOF_BRANCH or "?"
local label = ""
local orig_path, orig_home = vim.env.PATH, vim.env.HOME

function _G.proof_statusline()
  local s = ai.get_session(vim.fn.bufnr("sample.lua"))
  local phase = s and ("%#ProofSession# quill · " .. s.phase .. " ") or ""
  return ("%%#ProofMode# %s %%#ProofBranch# provider: %s %%#ProofBar#%%=%s%%#ProofBar# %%l:%%c "):format(
    branch, ai.config.provider, phase)
end
vim.o.statusline = "%!v:lua.proof_statusline()"
function _G.proof_winbar()
  return label == "" and "" or ("%#ProofLabel# " .. label .. " %#ProofBar#")
end

local fake_bin = root .. "/tests/bin"
local port = tonumber(vim.env.PROOF_PORT or "18799")
local scenes = {
  sse = function()
    label = "openai format → tests/sse_server.py (local mock, fake key)"
    vim.env.FAKE_KEY = "sk-fake"
    ai.setup({ provider = "fake", providers = { fake = { format = "openai", base_url = ("http://127.0.0.1:%d/v1"):format(port), model = "mock", api_key_env = "FAKE_KEY" } } })
  end,
  ["codex-fake"] = function()
    label = "codex → FAKE tests/bin/codex replaying recorded JSONL"
    vim.env.PATH, vim.env.HOME = fake_bin .. ":" .. orig_path, orig_home
    ai.setup({ provider = "codex" })
  end,
  ["claude-fake"] = function()
    label = "claude_code → FAKE tests/bin/claude replaying recorded JSONL"
    vim.env.PATH, vim.env.HOME = fake_bin .. ":" .. orig_path, orig_home
    ai.setup({ provider = "claude_code" })
  end,
  ["codex-real"] = function()
    label = "codex → REAL codex-cli 0.169.0 (/tmp/clis), logged out"
    vim.env.PATH, vim.env.HOME = "/tmp/clis/bin:" .. orig_path, vim.env.PROOF_EMPTY_HOME
    ai.setup({ provider = "codex" })
  end,
  ["claude-real"] = function()
    label = "claude_code → REAL Claude Code 2.1.323 (/tmp/clis), logged out"
    vim.env.PATH, vim.env.HOME = "/tmp/clis/bin:" .. orig_path, vim.env.PROOF_EMPTY_HOME
    ai.setup({ provider = "claude_code" })
  end,
  copilot = function()
    label = "copilot → apps.json (fake gho_demo) + MOCK token/chat server"
    ai.setup({ provider = "copilot", providers = { copilot = { config_dir = vim.env.PROOF_COPILOT_DIR, token_url = ("http://127.0.0.1:%d/copilot_internal/v2/token"):format(port) } } })
  end,
  ["copilot-signed-out"] = function()
    label = "copilot → no apps.json/hosts.json in config_dir"
    ai.setup({ provider = "copilot", providers = { copilot = { config_dir = vim.env.PROOF_EMPTY_HOME .. "/github-copilot" } } })
  end,
}
-- On PR #2 the CLI base exists but no provider is registered; wire one in the way its tests do.
if vim.env.PROOF_REGISTER_CLI == "1" then
  require("quill.providers").codex = require("quill.providers.cli").new("codex")
end

vim.api.nvim_create_user_command("Proof", function(o)
  ai.config.providers = {}
  scenes[o.args]()
  vim.cmd.redrawstatus({ bang = true })
  vim.cmd("redraw!")
end, { nargs = 1, complete = function() return vim.tbl_keys(scenes) end })

vim.api.nvim_create_user_command("ProofMonitor", function()
  local cur = vim.api.nvim_get_current_win()
  vim.cmd("botright 7new")
  vim.fn.termopen({ "/tmp/proof/monitor.sh", vim.env.PROOF_LOG or "" })
  vim.wo.number, vim.wo.signcolumn, vim.wo.winbar = false, "no", ""
  vim.api.nvim_set_current_win(cur)
end, {})

vim.api.nvim_create_autocmd("BufWinEnter", { pattern = "sample.lua", callback = function()
  vim.wo.winbar = "%!v:lua.proof_winbar()"
end })
