-- Streaming chat over curl + SSE. Each wire format is one entry in `formats`.
local M = {}

local formats = {
  openai = {
    defaults = { base_url = "https://api.openai.com/v1", model = "gpt-4o-mini", api_key_env = "OPENAI_API_KEY" },
    request = function(req, opts, key)
      local messages = { { role = "system", content = req.system } }
      vim.list_extend(messages, req.messages)
      return opts.base_url .. "/chat/completions",
        { "Authorization: Bearer " .. key },
        { model = opts.model, stream = true, temperature = opts.temperature or 0, messages = messages }
    end,
    extract = function(event)
      local choice = event.choices and event.choices[1]
      return choice and choice.delta and choice.delta.content or nil
    end,
  },
  anthropic = {
    defaults = {
      base_url = "https://api.anthropic.com/v1",
      model = "claude-sonnet-4-5",
      api_key_env = "ANTHROPIC_API_KEY",
      max_tokens = 4096,
    },
    request = function(req, opts, key)
      return opts.base_url .. "/messages",
        { "x-api-key: " .. key, "anthropic-version: 2023-06-01" },
        { model = opts.model, stream = true, max_tokens = opts.max_tokens, system = req.system, messages = req.messages }
    end,
    extract = function(event)
      if event.type == "content_block_delta" and event.delta then
        return event.delta.text
      end
      if event.type == "error" then
        error(event.error and event.error.message or "anthropic error")
      end
    end,
  },
}

--- Splits a byte stream into lines, carrying a partial line across chunks.
function M.line_decoder(on_line)
  local pending = ""
  return function(chunk)
    pending = pending .. chunk
    while true do
      local nl = pending:find("\n", 1, true)
      if not nl then
        return
      end
      local line = pending:sub(1, nl - 1):gsub("\r$", "")
      pending = pending:sub(nl + 1)
      on_line(line)
    end
  end
end

--- Splits an SSE byte stream into `data:` payloads.
function M.sse_decoder(on_data)
  return M.line_decoder(function(line)
    local data = line:match("^data:%s?(.*)$")
    if data and data ~= "" then
      on_data(data)
    end
  end)
end

--- POSTs `body` as JSON and feeds each SSE event through `extract` (event -> text, or error()).
function M.stream(url, headers, body, extract, cb)
  local cmd = { "curl", "-sS", "-N", "--fail-with-body", "-X", "POST", url, "-H", "Content-Type: application/json" }
  for _, h in ipairs(headers) do
    vim.list_extend(cmd, { "-H", h })
  end
  vim.list_extend(cmd, { "--data-binary", "@-" })

  local finished, raw = false, {}
  local function finish(err)
    if finished then
      return
    end
    finished = true
    if err then
      cb.on_error(err)
    else
      cb.on_done()
    end
  end

  local decode = M.sse_decoder(function(data)
    if data == "[DONE]" then
      return
    end
    local ok, event = pcall(vim.json.decode, data)
    if not ok then
      return
    end
    local ok2, text = pcall(extract, event)
    if not ok2 then
      finish(tostring(text))
    elseif type(text) == "string" and text ~= "" then
      cb.on_chunk(text)
    end
  end)

  local job = vim.system(cmd, {
    stdin = vim.json.encode(body),
    stdout = function(_, chunk)
      if chunk then
        vim.schedule(function()
          raw[#raw + 1] = chunk
          if not finished then
            decode(chunk)
          end
        end)
      end
    end,
  }, function(res)
    vim.schedule(function()
      if res.code == 0 then
        finish()
      else
        finish(("request failed (curl %d): %s%s"):format(res.code, res.stderr or "", table.concat(raw):sub(1, 300)))
      end
    end)
  end)

  return {
    cancel = function()
      finished = true
      pcall(function()
        job:kill("sigterm")
      end)
    end,
  }
end

function M.new(format_name)
  local format = assert(formats[format_name], "unknown format " .. format_name)
  return function(req, opts, cb)
    opts = vim.tbl_extend("force", format.defaults, opts or {})
    local key = opts.api_key or os.getenv(opts.api_key_env)
    if not key or key == "" then
      cb.on_error(("missing API key: set $%s"):format(opts.api_key_env))
      return { cancel = function() end }
    end
    local url, headers, body = format.request(req, opts, key)
    return M.stream(url, headers, body, format.extract, cb)
  end
end

M.formats = formats

return M
