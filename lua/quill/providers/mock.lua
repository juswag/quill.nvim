-- Deterministic provider: streams a canned rewrite in fixed-size chunks on a timer.
-- `opts.response` is a string or `function(req) -> string`. The default echoes the
-- selection with a comment naming the latest instruction, so it works on any code.
local function default_response(req)
  return ("-- edit: %s\n%s"):format(req.instruction, table.concat(req.selection, "\n"))
end

return function(req, opts, cb)
  opts = opts or {}
  local response = opts.response or default_response
  local text = type(response) == "function" and response(req) or response
  local size, interval = opts.chunk_size or 4, opts.interval_ms or 15
  local pos, timer = 1, vim.uv.new_timer()
  local function stop()
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end
  timer:start(interval, interval, vim.schedule_wrap(function()
    if timer:is_closing() then
      return
    end
    if pos > #text then
      stop()
      cb.on_done()
      return
    end
    cb.on_chunk(text:sub(pos, pos + size - 1))
    pos = pos + size
  end))
  return { cancel = stop }
end
