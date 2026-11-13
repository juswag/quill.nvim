local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/helpers.lua")
H.bootstrap()
local ai = require("quill")
local context = require("quill.context")

local bin = vim.fn.fnamemodify("tests/bin", ":p"):gsub("/$", "")
vim.env.PATH = bin .. ":" .. vim.env.PATH
local log = vim.fn.tempname()
vim.env.QUILL_FAKE_LOG = log

-- setup() deep-merges into the live config, so start each test from clean provider opts.
local function setup(cfg)
  ai.config.providers = {}
  ai.setup(cfg)
end

local function records()
  local out = {}
  if vim.fn.filereadable(log) == 1 then
    for _, line in ipairs(vim.fn.readfile(log)) do
      out[#out + 1] = vim.json.decode(line)
    end
  end
  return out
end

local function last_record()
  local all = records()
  return all[#all]
end

local function index_of(list, value)
  for i, v in ipairs(list) do
    if v == value then
      return i
    end
  end
end

--- Runs one session to completion and returns the notified errors.
local function run_failing(cfg, instruction)
  setup(cfg)
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(m)
    msgs[#msgs + 1] = m
  end
  local buf = H.buffer({ "local x = 1", "return x" })
  ai.start(1, 2, { instruction = instruction })
  local closed = vim.wait(5000, function()
    return ai.get_session() == nil
  end, 10)
  vim.notify = orig
  H.ok(closed, "session closed after the error")
  H.eq({ "local x = 1", "return x" }, H.lines(buf), "buffer unchanged")
  return msgs
end

local function running(pattern)
  return vim.system({ "pgrep", "-f", pattern }):wait().code == 0
end

local cases = {
  {
    provider = "codex",
    chunks = 1,
    check_argv = function(argv)
      H.eq("exec", argv[1], "exec subcommand")
      H.ok(index_of(argv, "--json"), "JSONL events")
      H.eq("read-only", argv[index_of(argv, "--sandbox") + 1], "read-only sandbox")
      H.ok(index_of(argv, "--ephemeral"), "no session files")
      H.eq("gpt-test", argv[index_of(argv, "-m") + 1], "model flag")
      H.eq("-", argv[#argv], "prompt read from stdin")
    end,
  },
  {
    provider = "claude_code",
    chunks = 5,
    check_argv = function(argv)
      H.eq("-p", argv[1], "print mode")
      H.eq("stream-json", argv[index_of(argv, "--output-format") + 1], "stream-json")
      H.ok(index_of(argv, "--include-partial-messages"), "partial messages")
      H.eq("", argv[index_of(argv, "--tools") + 1], "all tools disabled")
      H.eq("gpt-test", argv[index_of(argv, "--model") + 1], "model flag")
      H.eq(context.system, argv[index_of(argv, "--system-prompt") + 1], "system prompt")
    end,
  },
}

for _, case in ipairs(cases) do
  local p = case.provider

  H.test(p .. " streams the CLI's JSONL events into the preview", function()
    setup({ provider = p, providers = { [p] = { model = "gpt-test" } } })
    local buf = H.buffer({ "local x = 1", "return x" })
    ai.start(1, 2, { instruction = "bump it" })
    H.wait_phase("reviewing", 5000)
    local s = ai.get_session()
    H.eq({ "local x = 2", "return x" }, s.proposed, "only the final answer, fences stripped")
    H.eq(case.chunks, s.stats.tokens, "chunks delivered")
    H.eq({ "local x = 1", "return x" }, H.lines(buf), "buffer unchanged until accepted")
    local rec = last_record()
    case.check_argv(rec.argv)
    H.ok(rec.stdin:find("<selection>\nlocal x = 1\nreturn x\n</selection>", 1, true), "selection on stdin")
    H.ok(rec.stdin:find("Instruction: bump it", 1, true), "instruction on stdin")
    for _, a in ipairs(rec.argv) do
      H.ok(not a:find("bump it", 1, true), "instruction kept out of argv")
    end
    H.keys("A")
    H.eq({ "local x = 2", "return x" }, H.lines(buf), "applied")
  end)

  H.test(p .. " follow-up sends the earlier answer back in the prompt", function()
    setup({ provider = p })
    H.buffer({ "local x = 1", "return x" })
    ai.start(1, 2, { instruction = "bump it" })
    H.wait_phase("reviewing", 5000)
    ai.followup("and more")
    H.wait_phase("reviewing", 5000)
    local stdin = last_record().stdin
    H.ok(stdin:find("Your previous reply:\n```lua\nlocal x = 2", 1, true), "previous answer included")
    H.ok(stdin:find("Instruction: and more", 1, true), "follow-up instruction included")
  end)

  H.test(p .. " cancel kills the CLI process", function()
    setup({ provider = p })
    H.buffer({ "local x = 1" })
    ai.start(1, 1, { instruction = "SLOW" })
    H.ok(vim.wait(3000, function() return running("fake_cli.py") end, 20), "CLI started")
    H.keys("q")
    H.ok(vim.wait(2000, function() return not running("fake_cli.py") end, 50), "CLI killed")
    H.eq(nil, ai.get_session(), "session closed")
  end)

  H.test(p .. " missing binary names the install command", function()
    local msgs = run_failing({ provider = p, providers = { [p] = { cmd = "definitely-not-on-path" } } }, "x")
    H.ok(msgs[1]:find("`definitely-not-on-path` not found", 1, true), msgs[1])
    H.ok(msgs[1]:find("npm i -g", 1, true), "install hint: " .. msgs[1])
  end)

  H.test(p .. " not signed in reports the CLI's error and the login command", function()
    local msgs = run_failing({ provider = p }, "UNAUTHORIZED")
    local want = p == "codex" and "401 Unauthorized" or "Not logged in"
    H.ok(msgs[1]:find(want, 1, true), msgs[1])
    H.ok(msgs[1]:find(p == "codex" and "`codex login`" or "/login", 1, true), "login hint: " .. msgs[1])
    H.eq(1, #msgs, "one error")
  end)

  H.test(p .. " non-zero exit surfaces stderr", function()
    local msgs = run_failing({ provider = p }, "CRASH")
    H.ok(msgs[1]:find("panic: something broke", 1, true), msgs[1])
  end)

  H.test(p .. " times out and kills a stuck CLI", function()
    local msgs = run_failing({ provider = p, providers = { [p] = { timeout_ms = 300 } } }, "HANG")
    H.ok(msgs[1]:find("timed out", 1, true), msgs[1])
    H.ok(vim.wait(2000, function() return not running("fake_cli.py") end, 50), "CLI killed")
  end)
end

H.test("args override replaces the default flags", function()
  setup({ provider = "codex", providers = { codex = { args = { "exec", "--json", "-c", "model_reasoning_effort=low" } } } })
  H.buffer({ "local x = 1", "return x" })
  ai.start(1, 2, { instruction = "bump it" })
  H.wait_phase("reviewing", 5000)
  H.eq({ "exec", "--json", "-c", "model_reasoning_effort=low", "-" }, last_record().argv, "argv")
end)

H.finish()
