-- Subscription CLIs (Codex, Claude Code) run as one-shot subprocesses that print JSONL
-- events. Each CLI is one entry in `clis`; `parse` maps an event to text, records a
-- soft error in `state.error`, or raises on a fatal one.
local line_decoder = require("quill.providers.http").line_decoder

local M = {}

--- Flattens the chat into one prompt, since both CLIs take a single user message.
local function transcript(messages)
  local parts = {}
  for _, m in ipairs(messages) do
    parts[#parts + 1] = m.role == "assistant" and ("Your previous reply:\n" .. m.content) or m.content
  end
  return table.concat(parts, "\n\n")
end

local clis = {
  codex = {
    install = "npm i -g @openai/codex",
    login = "`codex login`",
    args = { "exec", "--json", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral", "--color", "never" },
    model_flag = "-m",
    -- `-` makes codex read the whole prompt from stdin. It has no system prompt flag.
    argv = function(args)
      return vim.list_extend(args, { "-" })
    end,
    stdin = function(req)
      return req.system .. "\n\n" .. transcript(req.messages)
    end,
    -- Codex reports agent messages whole (no deltas) and may send several per turn,
    -- so only the last one is the answer. `error` events are retry notices.
    parse = function(event, state)
      local item = event.item
      if event.type == "item.completed" and item and item.type == "agent_message" then
        state.answer = item.text
      elseif event.type == "turn.completed" then
        return state.answer
      elseif event.type == "turn.failed" then
        error(event.error and event.error.message or "turn failed", 0)
      elseif event.type == "error" then
        state.error = event.message
      end
    end,
  },
  claude_code = {
    install = "npm i -g @anthropic-ai/claude-code",
    login = "`claude` then `/login`",
    cmd = "claude",
    args = {
      "-p",
      "--output-format", "stream-json",
      "--verbose",
      "--include-partial-messages",
      "--tools", "",
      "--strict-mcp-config",
      "--no-session-persistence",
    },
    model_flag = "--model",
    argv = function(args, req)
      return vim.list_extend(args, { "--system-prompt", req.system })
    end,
    stdin = function(req)
      return transcript(req.messages)
    end,
    parse = function(event, state)
      if event.type == "stream_event" then
        local e = event.event or {}
        if e.type == "content_block_delta" and e.delta and e.delta.type == "text_delta" then
          state.streamed = true
          return e.delta.text
        end
      elseif event.type == "assistant" and event.message then
        local text = {}
        for _, block in ipairs(event.message.content or {}) do
          if block.type == "text" then
            text[#text + 1] = block.text
          end
        end
        -- Auth and API failures arrive as a synthetic assistant message plus `error`.
        if event.error then
          state.error = table.concat(text)
        elseif not state.streamed then
          return table.concat(text)
        end
      elseif event.type == "result" and event.is_error then
        error(event.result or event.subtype or "claude failed", 0)
      end
    end,
  },
}

local auth_pattern = { "401", "[Uu]nauthori[sz]ed", "[Ll]ogin", "[Ll]ogged in", "[Aa]uthenticat" }

local function explain(cli, name, msg)
  for _, pat in ipairs(auth_pattern) do
    if msg:find(pat) then
      return ("%s: %s (sign in by running %s)"):format(name, msg, cli.login)
    end
  end
  return ("%s: %s"):format(name, msg)
end

function M.new(name)
  local cli = assert(clis[name], "unknown cli " .. name)
  return function(req, opts, cb)
    opts = opts or {}
    local exe = opts.cmd or cli.cmd or name
    if vim.fn.executable(exe) == 0 then
      cb.on_error(("`%s` not found on $PATH. Install it with `%s`, then sign in by running %s."):format(exe, cli.install, cli.login))
      return { cancel = function() end }
    end
    local args = vim.list_extend({ exe }, opts.args or cli.args)
    if opts.model then
      vim.list_extend(args, { cli.model_flag, opts.model })
    end
    args = cli.argv(args, req)

    local timeout = opts.timeout_ms or 120000
    local cwd = opts.cwd or vim.fn.stdpath("cache")
    vim.fn.mkdir(cwd, "p")

    local state, stderr, finished, job = {}, {}, false, nil
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

    local decode = line_decoder(function(line)
      local ok, event = pcall(vim.json.decode, line)
      if not ok or type(event) ~= "table" then
        return
      end
      local ok2, text = pcall(cli.parse, event, state)
      if not ok2 then
        finish(explain(cli, name, tostring(text)))
        pcall(function()
          job:kill("sigterm")
        end)
      elseif type(text) == "string" and text ~= "" then
        state.emitted = true
        cb.on_chunk(text)
      end
    end)

    local ok, spawned = pcall(vim.system, args, {
      cwd = cwd,
      stdin = cli.stdin(req),
      timeout = timeout,
      stdout = function(_, chunk)
        if chunk then
          vim.schedule(function()
            if not finished then
              decode(chunk)
            end
          end)
        end
      end,
      stderr = function(_, chunk)
        if chunk then
          stderr[#stderr + 1] = chunk
        end
      end,
    }, function(res)
      vim.schedule(function()
        if finished then
          return
        end
        decode("\n")
        if res.code == 124 then
          return finish(("%s: timed out after %ds"):format(name, timeout / 1000))
        end
        if res.code ~= 0 or not state.emitted then
          local msg = state.error or vim.trim(table.concat(stderr)):match("[^\n]*$")
          if not msg or msg == "" then
            msg = res.code ~= 0 and ("exited with code " .. res.code) or "returned no text"
          end
          return finish(explain(cli, name, msg))
        end
        finish()
      end)
    end)
    if not ok then
      cb.on_error(("%s: failed to start: %s"):format(name, spawned))
      return { cancel = function() end }
    end
    job = spawned

    return {
      cancel = function()
        finished = true
        pcall(function()
          job:kill("sigterm")
        end)
      end,
    }
  end
end

return M
