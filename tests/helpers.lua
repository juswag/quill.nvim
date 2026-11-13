local H = {}
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

function H.bootstrap()
  vim.opt.rtp:prepend(root)
  vim.g.mapleader = " "
  dofile(root .. "/plugin/quill.lua")
end

local results = { pass = 0, fail = 0 }

function H.test(name, fn)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and b ~= vim.api.nvim_get_current_buf() then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  vim.cmd("enew!")
  local ok, err = xpcall(fn, debug.traceback)
  pcall(require("quill").cancel)
  if ok then
    results.pass = results.pass + 1
    io.stdout:write("PASS " .. name .. "\n")
  else
    results.fail = results.fail + 1
    io.stdout:write("FAIL " .. name .. "\n" .. err .. "\n")
  end
end

function H.eq(expected, actual, msg)
  if not vim.deep_equal(expected, actual) then
    error(("%s\nexpected: %s\nactual:   %s"):format(msg or "not equal", vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

function H.ok(cond, msg)
  if not cond then
    error(msg or "assertion failed", 2)
  end
end

function H.buffer(lines, ft)
  local buf = vim.api.nvim_get_current_buf()
  -- Load the fixture outside undo history so `u` cannot undo the fixture itself.
  local old = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].undolevels = old
  vim.bo[buf].filetype = ft or "lua"
  vim.bo[buf].modified = false
  return buf
end

function H.lines(buf)
  return vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false)
end

function H.keys(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

function H.wait_phase(phase, ms)
  local ai = require("quill")
  local ok = vim.wait(ms or 3000, function()
    local s = ai.get_session()
    return (s and s.phase or "closed") == phase
  end, 5)
  H.ok(ok, "timed out waiting for phase " .. phase)
end

function H.preview_marks(buf)
  return vim.api.nvim_buf_get_extmarks(buf, require("quill.render").ns, 0, -1, { details = true })
end

function H.finish()
  io.stdout:write(("\n%d passed, %d failed"):format(results.pass, results.fail) .. "\n")
  os.exit(results.fail == 0 and 0 or 1)
end

return H
