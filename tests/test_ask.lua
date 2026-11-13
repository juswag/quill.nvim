local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/helpers.lua")
H.bootstrap()
local ai = require("quill")
local ask = require("quill.ask")

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
local ANSWER = "`tonumber` returns **nil** for input like `\"abc\"`.\n\nThen `n < 1` errors.\n"
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
  ai.setup({
    provider = "mock",
    providers = {
      mock = vim.tbl_extend("force", {
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
      }, extra or {}),
    },
  })
end

local function phase()
  local a = ask.get()
  return a and a.phase or "closed"
end

local function wait_ask(want)
  H.ok(vim.wait(3000, function() return phase() == want end, 5), "timed out waiting for ask phase " .. want)
end

local function answer_text()
  return table.concat(vim.api.nvim_buf_get_lines(ask.get().answer_buf, 0, -1, false), "\n")
end

local function title_text(win)
  return table.concat(vim.tbl_map(function(c) return c[1] end, vim.api.nvim_win_get_config(win).title), "")
end

H.test("normal <leader>k asks about the cursor's function without touching the buffer", function()
  use_mock()
  local buf = H.buffer(CODE)
  vim.api.nvim_win_set_cursor(0, { 5, 4 })
  H.keys(" k")
  H.eq("prompting", phase(), "prompt open")
  H.ok(title_text(0):find("Ask", 1, true), "prompt titled Ask: " .. title_text(0))
  vim.api.nvim_win_close(0, true)
  H.eq("closed", phase(), "closing the first prompt ends the ask")
  H.keys(" kwhy could this return nil?<CR>")
  H.ok(vim.wait(1000, function() return #seen == 1 end, 5), "request sent")
  wait_ask("answered")
  local a = ask.get()
  H.eq(a.answer_win, vim.api.nvim_get_current_win(), "focus in the answer window")
  H.eq("markdown", vim.bo[a.answer_buf].filetype, "answer is markdown")
  H.eq(false, vim.bo[a.answer_buf].modifiable, "answer is read-only")
  H.ok(answer_text():find("returns **nil**", 1, true), "answer shown: " .. answer_text())
  H.ok(answer_text():find("› why could this return nil?", 1, true), "question shown")
  local cfg = vim.api.nvim_win_get_config(a.answer_win)
  H.ok(cfg.relative == "win" and cfg.win == a.win, "anchored to the source window")
  H.eq(CODE, H.lines(buf), "buffer text unchanged")
  H.eq(false, vim.bo[buf].modified, "buffer not modified")
  H.keys("q")
  H.eq("closed", phase(), "q closes")
  H.eq(buf, vim.api.nvim_get_current_buf(), "focus back in source buffer")
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
  H.eq({ 2, 8, true }, ask.get().scope, "scope is the enclosing function")
  local first = req.messages[1].content
  H.ok(first:find("Enclosing function (lines 3-9)", 1, true), first)
  H.ok(first:find("function M.parse_port(value)", 1, true), "function code")
  H.ok(not first:find("return M", 1, true), "code outside the function left out")
  H.ok(first:find("Cursor on line 5: if n < 1 then", 1, true), "cursor line")
  H.ok(first:find("line 5 [WARN]: attempt to compare nil with number", 1, true), "diagnostic with file line number")
  H.eq("Question: why could this return nil?", first:sub(-#"Question: why could this return nil?"), "question last")
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
end)

H.test("f asks a follow-up in the same thread", function()
  use_mock()
  H.buffer(CODE)
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  ai.ask("why could this return nil?")
  wait_ask("answered")
  local win = ask.get().answer_win
  H.keys("f")
  H.eq("prompting", phase(), "follow-up prompt open")
  H.ok(title_text(0):find("Follow-up", 1, true), "follow-up title")
  vim.api.nvim_win_close(0, true)
  H.eq("answered", phase(), "closing the follow-up prompt keeps the answer")
  H.eq(win, vim.api.nvim_get_current_win(), "focus back in the answer")
  H.keys("fhow do I fix it?<CR>")
  H.ok(vim.wait(1000, function() return #seen == 2 end, 5), "follow-up sent")
  wait_ask("answered")
  H.eq(win, ask.get().answer_win, "same answer window")
  local roles = vim.tbl_map(function(m) return m.role end, seen[2].messages)
  H.eq({ "user", "assistant", "user" }, roles, "thread history sent")
  H.eq("how do I fix it?", seen[2].messages[3].content, "follow-up question")
  H.eq(vim.trim(ANSWER), seen[2].messages[2].content, "first answer replayed")
  local _, count = answer_text():gsub("returns %*%*nil%*%*", "")
  H.eq(2, count, "both answers in the window")
end)

H.test("e turns the thread into a reviewed edit of the enclosing function", function()
  use_mock()
  local buf = H.buffer(CODE)
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  ai.ask("why could this return nil?")
  wait_ask("answered")
  H.keys("e")
  H.eq("closed", phase(), "ask closed")
  H.wait_phase("reviewing")
  local s = ai.get_session(buf)
  H.eq(buf, vim.api.nvim_get_current_buf(), "focus in the source buffer")
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

H.test("Esc while streaming cancels the request", function()
  use_mock({ interval_ms = 50, chunk_size = 1 })
  H.buffer(CODE)
  ai.ask("why?")
  H.eq("streaming", phase(), "streaming")
  local win = ask.get().answer_win
  H.keys("<Esc>")
  H.eq("closed", phase(), "closed")
  H.ok(not vim.api.nvim_win_is_valid(win), "answer window gone")
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
  H.buffer(CODE)
  ai.ask("why?")
  wait_ask("answered")
  H.ok(answer_text():find("Mock answer to: why?", 1, true), answer_text())
end)

H.finish()
