local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/helpers.lua")
H.bootstrap()
local ai = require("quill")

local port = 18765
local log = vim.fn.tempname()
local server = vim.system({ "python3", vim.fn.fnamemodify("tests/sse_server.py", ":p"), tostring(port), log })
vim.wait(3000, function()
  return vim.system({ "curl", "-s", "-o", "/dev/null", "-X", "POST", "-d", "{\"messages\":[{\"content\":\"\"}]}",
    ("http://127.0.0.1:%d/ping"):format(port) }):wait().code == 0
end, 100)
vim.env.FAKE_KEY = "sk-test"

local function requests()
  local out = {}
  for _, line in ipairs(vim.fn.readfile(log)) do
    out[#out + 1] = vim.json.decode(line)
  end
  return out
end

for _, fmt in ipairs({ "openai", "anthropic" }) do
  H.test(fmt .. " provider streams SSE through curl into the preview", function()
    ai.setup({
      provider = "fake",
      providers = { fake = { format = fmt, base_url = ("http://127.0.0.1:%d/v1"):format(port), model = "m", api_key_env = "FAKE_KEY" } },
    })
    local buf = H.buffer({ "local x = 1", "return x" })
    ai.start(1, 2, { instruction = "bump" })
    H.wait_phase("reviewing", 5000)
    local s = ai.get_session()
    H.eq({ "local x = 2", "return x" }, s.proposed, "fences stripped and chunks reassembled")
    H.eq(1, #s.hunks, "one hunk")
    H.eq({ "local x = 1", "return x" }, H.lines(buf), "buffer unchanged")
    local req = requests()[#requests()]
    if fmt == "openai" then
      H.eq("/v1/chat/completions", req.path, "path")
      H.eq("Bearer sk-test", req.headers.Authorization, "auth header")
      H.eq("system", req.body.messages[1].role, "system message first")
    else
      H.eq("/v1/messages", req.path, "path")
      H.eq("sk-test", req.headers["x-api-key"], "api key header")
      H.ok(req.body.system:find("rewrite", 1, true), "system prompt")
    end
    H.eq(true, req.body.stream, "stream flag")
    H.keys("A")
    H.eq({ "local x = 2", "return x" }, H.lines(buf), "applied")
  end)
end

H.test("cancel kills the curl process", function()
  ai.setup({
    provider = "fake",
    providers = { fake = { format = "openai", base_url = ("http://127.0.0.1:%d/v1"):format(port), api_key_env = "FAKE_KEY" } },
  })
  H.buffer({ "local x = 1" })
  ai.start(1, 1, { instruction = "SLOW" })
  local function curl_running()
    return vim.system({ "pgrep", "-f", "curl.*127.0.0.1:" .. port }):wait().code == 0
  end
  H.ok(vim.wait(3000, function() return #ai.get_session().proposed > 0 end, 20), "streaming started")
  H.ok(curl_running(), "curl running mid-stream")
  H.keys("q")
  H.ok(vim.wait(2000, function() return not curl_running() end, 50), "curl killed")
  H.eq(nil, ai.get_session(), "session closed")
end)

H.test("missing API key reports an error and closes the session", function()
  ai.setup({ provider = "openai", providers = { openai = { api_key_env = "DEFINITELY_UNSET_KEY" } } })
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(m) msgs[#msgs + 1] = m end
  H.buffer({ "x" })
  ai.start(1, 1, { instruction = "y" })
  vim.notify = orig
  H.eq(nil, ai.get_session(), "closed")
  H.ok(msgs[1] and msgs[1]:find("DEFINITELY_UNSET_KEY", 1, true), "error names the env var")
end)

server:kill("sigterm")
H.finish()
