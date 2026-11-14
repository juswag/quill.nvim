local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/helpers.lua")
H.bootstrap()
local ai = require("quill")
local ask = require("quill.ask")
ai.setup({ provider = "mock" })

local CODE = {
  "local M = {}",
  "",
  "function M.parse_port(value)",
  "  local n = tonumber(value)",
  "  if n < 1 then",
  "    return nil",
  "  end",
  "  return n",
  "end",
  "",
  "return M",
}
local ANSWER = "`tonumber` returns **nil** for input like `\"abc\"`, so `n < 1` errors.\n"
local FIXED = {
  "function M.parse_port(value)",
  "  local n = tonumber(value)",
  "  if not n or n < 1 then",
  "    return nil",
  "  end",
  "  return n",
  "end",
}

local seen = {}
local function use_mock(extra)
  seen = {}
  ai.config.provider = "mock"
  ai.config.providers.mock = vim.tbl_extend("force", {
    interval_ms = 2,
    chunk_size = 5,
    answer = function(req)
      seen[#seen + 1] = req
      return ANSWER
    end,
    response = function(req)
      seen[#seen + 1] = req
      return table.concat(FIXED, "\n") .. "\n"
    end,
  }, extra or {})
end

local function phase()
  local a = ask.get()
  return a and a.phase or "closed"
end

local function wait_ask(want)
  H.ok(vim.wait(3000, function() return phase() == want end, 5), "timed out waiting for ask phase " .. want)
end

--- The answer's virtual lines as text, one string per line, plus the row they hang from.
local function answer_lines(buf)
  local marks = vim.api.nvim_buf_get_extmarks(buf, ask.ns, 0, -1, { details = true })
  if #marks == 0 then
    return nil
  end
  local out = {}
  for i, vl in ipairs(marks[1][4].virt_lines) do
    out[i] = vim.trim(table.concat(vim.tbl_map(function(c) return c[1] end, vim.list_slice(vl, 4)), ""))
  end
  return out, marks[1][2], marks[1][4].virt_lines
end

local function has_mapping(buf, lhs)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if m.lhs == lhs then
      return true
    end
  end
  return false
end

H.test("normal <leader>k answers inline under the cursor line without touching the buffer", function()
  use_mock()
  local buf = H.buffer(CODE)
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_cursor(0, { 6, 4 })
  H.keys(" k")
  H.eq("prompting", phase(), "prompt open")
  local title = table.concat(vim.tbl_map(function(c) return c[1] end, vim.api.nvim_win_get_config(0).title), "")
  H.ok(title:find("Ask", 1, true), "prompt titled Ask: " .. title)
  vim.api.nvim_win_close(0, true)
  H.eq("closed", phase(), "closing the prompt ends the ask")
  H.keys(" kwhy could this return nil?<CR>")
  wait_ask("answered")
  H.eq(win, vim.api.nvim_get_current_win(), "focus stays in the code window")
  H.eq(buf, vim.api.nvim_get_current_buf(), "focus stays in the code buffer")
  local floats = vim.tbl_filter(function(w) return vim.api.nvim_win_get_config(w).relative ~= "" end,
    vim.api.nvim_list_wins())
  H.eq(0, #floats, "no floating window")
  local lines, row, virt = answer_lines(buf)
  H.eq(5, row, "hangs from the cursor line")
  H.eq('tonumber returns nil for input like "abc", so n < 1 errors.', lines[1], "markdown markers stripped")
  H.ok(lines[#lines]:find("edit", 1, true) and lines[#lines]:find("dismiss", 1, true), "key hint: " .. lines[#lines])
  H.eq("QuillAnswerBar", virt[1][1][2], "gutter bar")
  local code_chunks = vim.tbl_filter(function(c) return c[2] == "QuillAnswerCode" end, virt[1])
  H.eq("tonumber", code_chunks[1][1], "inline code highlighted")
  H.eq(CODE, H.lines(buf), "buffer text unchanged")
  H.eq(false, vim.bo[buf].modified, "buffer not modified")
  H.ok(has_mapping(buf, "<CR>") and has_mapping(buf, "q"), "answer keys mapped")
  H.keys("<Esc>")
  H.eq("closed", phase(), "<Esc> dismisses")
  H.eq(nil, answer_lines(buf), "answer cleared")
  H.ok(not has_mapping(buf, "<CR>") and not has_mapping(buf, "q"), "answer keys removed")
end)

H.test("the request carries the enclosing function, cursor line, diagnostics and question", function()
  use_mock()
  local buf = H.buffer(CODE)
  vim.diagnostic.set(vim.api.nvim_create_namespace("ask_test"), buf,
    { { lnum = 4, col = 5, message = "attempt to compare nil with number", severity = vim.diagnostic.severity.WARN } })
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  ai.ask("why could this return nil?")
  wait_ask("answered")
  local req = seen[1]
  H.eq("ask", req.mode, "ask mode")
  H.eq(require("quill.context").ask_system, req.system, "ask system prompt")
  H.eq(1, #req.messages, "a single turn")
  H.eq({ 2, 8, true }, ask.get().scope, "scope is the enclosing function")
  local first = req.messages[1].content
  H.ok(first:find("Enclosing function (lines 3-9)", 1, true), first)
  H.ok(first:find("function M.parse_port(value)", 1, true), "function code")
  H.ok(not first:find("return M", 1, true), "code outside the function left out")
  H.ok(first:find("Cursor on line 5: if n < 1 then", 1, true), "cursor line")
  H.ok(first:find("line 5 [WARN]: attempt to compare nil with number", 1, true), "diagnostic with file line number")
  local q = "Question: why could this return nil?"
  H.eq(q, first:sub(-#q), "question last")
end)

H.test("without a function the scope falls back to lines around the cursor", function()
  use_mock()
  ai.config.context_lines = 2
  local lines = {}
  for i = 1, 20 do
    lines[i] = "line " .. i
  end
  H.buffer(lines, "text")
  vim.api.nvim_win_set_cursor(0, { 10, 0 })
  ai.ask("what is this?")
  wait_ask("answered")
  H.eq({ 7, 11, false }, ask.get().scope, "cursor +-2")
  H.ok(seen[1].messages[1].content:find("Code around the cursor (lines 8-12)", 1, true), "fallback label")
  ai.config.context_lines = 20
end)

H.test("moving off the line, typing, or asking again dismisses the answer", function()
  use_mock()
  local buf = H.buffer(CODE)
  vim.api.nvim_win_set_cursor(0, { 6, 0 })
  ai.ask("why?")
  wait_ask("answered")
  H.keys("l")
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
  H.eq("answered", phase(), "moving along the line keeps it")
  H.keys("j")
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
  H.eq("closed", phase(), "moving to another line dismisses")
  H.eq(nil, answer_lines(buf), "cleared")

  ai.ask("why?")
  wait_ask("answered")
  vim.api.nvim_exec_autocmds("InsertEnter", { buffer = buf })
  H.eq("closed", phase(), "insert mode dismisses")

  local first = ai.ask("first?")
  wait_ask("answered")
  ai.ask("second?")
  H.eq("closed", first.phase, "asking again replaces the answer")
  wait_ask("answered")
  H.eq(1, #vim.api.nvim_buf_get_extmarks(buf, ask.ns, 0, -1, {}), "one answer shown")
end)

H.test("<CR> turns the answer into a reviewed edit of the enclosing function", function()
  use_mock()
  local buf = H.buffer(CODE)
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  ai.ask("why could this return nil?")
  wait_ask("answered")
  H.keys("<CR>")
  H.eq("closed", phase(), "answer closed")
  H.eq(nil, answer_lines(buf), "answer cleared")
  H.wait_phase("reviewing")
  local s = ai.get_session(buf)
  H.eq(vim.list_slice(CODE, 3, 9), s.original, "edit range is the function")
  local instruction = seen[2].instruction
  H.ok(instruction:find("Question: why could this return nil?", 1, true), "question in instruction")
  H.ok(instruction:find("returns **nil**", 1, true), "answer in instruction")
  H.eq(1, #s.hunks, "one hunk")
  H.eq(CODE, H.lines(buf), "nothing written before review")
  H.keys("A")
  H.wait_phase("closed")
  H.eq("  if not n or n < 1 then", H.lines(buf)[5], "edit applied")
  H.eq("return M", H.lines(buf)[11], "outside the function untouched")
end)

H.test("long answers are capped with a key to expand; code blocks are indented", function()
  local long = { "First line with `code`." }
  for i = 2, 12 do
    long[i] = "Sentence " .. i .. "."
  end
  use_mock({ answer = table.concat(long, "\n\n") .. "\n\n```lua\nreturn nil, \"bad\"\n```" })
  local buf = H.buffer(CODE)
  ai.ask("explain")
  wait_ask("answered")
  local lines = answer_lines(buf)
  H.eq(9, #lines, "8 lines plus the key hint")
  H.ok(lines[8]:find("…$"), "truncation mark: " .. lines[8])
  H.ok(lines[9]:find("more", 1, true), "expand key in hint: " .. lines[9])
  H.keys("<Tab>")
  local _, _, virt = answer_lines(buf)
  local code = table.concat(vim.tbl_map(function(c) return c[2] == "QuillAnswerCode" and c[1] or "" end, virt[#virt - 1]))
  H.eq('  return nil, "bad"', code, "fence dropped, code indented")
  H.ok(#virt > 20, "expanded shows everything")
end)

H.test("Esc while streaming cancels the request", function()
  use_mock({ interval_ms = 50, chunk_size = 1 })
  local buf = H.buffer(CODE)
  ai.ask("why?")
  H.eq("streaming", phase(), "streaming")
  H.ok(answer_lines(buf), "spinner line shown while waiting")
  H.keys("<Esc>")
  H.eq("closed", phase(), "closed")
  H.eq(nil, answer_lines(buf), "cleared")
end)

H.test(":QuillAsk with a question skips the prompt; visual <leader>k still edits", function()
  use_mock()
  local buf = H.buffer(CODE)
  vim.cmd("QuillAsk why nil?")
  H.eq("streaming", phase(), "went straight to streaming")
  wait_ask("answered")
  H.eq("why nil?", seen[1].instruction, "question from the command")
  H.keys("q")
  H.keys("3GV9G k" .. "fix<CR>")
  H.wait_phase("reviewing")
  H.eq("closed", phase(), "no ask from visual mode")
  H.eq("fix", seen[2].instruction, "edit instruction")
  H.eq(nil, seen[2].mode, "edit request")
  H.eq(buf, vim.api.nvim_get_current_buf(), "source buffer")
end)

H.test("mock keeps its edit reply and has a default answer", function()
  ai.config.provider, ai.config.providers.mock = "mock", { interval_ms = 2, chunk_size = 50 }
  local buf = H.buffer(CODE)
  ai.ask("why?")
  wait_ask("answered")
  H.ok(answer_lines(buf)[1]:find("Mock answer to: why?", 1, true), answer_lines(buf)[1])
end)

H.finish()
