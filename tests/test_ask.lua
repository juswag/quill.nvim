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
local ANSWER = "`tonumber` returns **nil** for input like `\"abc\"`, so `n < 1` errors on line 6.\n"
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

local function box_lines()
  local a = ask.get()
  if not (a and a.box_buf and vim.api.nvim_buf_is_valid(a.box_buf)) then
    return nil
  end
  return vim.api.nvim_buf_get_lines(a.box_buf, 0, -1, false)
end

local function floats()
  return vim.tbl_filter(function(w)
    return vim.api.nvim_win_get_config(w).relative ~= ""
  end, vim.api.nvim_list_wins())
end

local function has_mapping(buf, lhs)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if m.lhs == lhs then
      return true
    end
  end
  return false
end

local function buf_hl(buf)
  return vim.api.nvim_buf_get_extmarks(buf, ask.ns, 0, -1, { details = true })
end

H.test("normal <leader>k opens a box at the cursor, then morphs the answer in place", function()
  use_mock()
  local buf = H.buffer(CODE)
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_cursor(0, { 6, 4 })
  H.keys(" k")
  H.eq("prompting", phase(), "prompt open")
  H.eq(1, #floats(), "one floating box")
  vim.api.nvim_win_close(0, true)
  H.eq("closed", phase(), "closing the box ends the ask")
  H.keys(" kwhy could this return nil?<CR>")
  wait_ask("answered")
  H.eq(win, vim.api.nvim_get_current_win(), "focus returns to the code window")
  H.eq(buf, vim.api.nvim_get_current_buf(), "focus returns to the code buffer")
  H.eq(1, #floats(), "the same kind of box stays open")
  local lines = box_lines()
  H.ok(lines and #lines >= 1, "answer is in the box")
  local body = table.concat(lines, " ")
  H.ok(body:find("tonumber returns nil", 1, true), "markdown markers stripped, backticks unwrapped: " .. body)
  H.ok(not body:find("**", 1, true), "bold markers stripped")
  H.eq(CODE, H.lines(buf), "buffer text unchanged")
  H.eq(false, vim.bo[buf].modified, "buffer not modified")
  H.ok(has_mapping(buf, "e") and has_mapping(buf, "q"), "answer keys mapped")
  local a = ask.get()
  H.ok(a.box_win and not vim.api.nvim_win_get_config(a.box_win).focusable, "answered box is not focusable")
  H.keys("<Esc>")
  H.eq("closed", phase(), "<Esc> dismisses")
  H.eq(nil, box_lines(), "box closed")
  H.eq(0, #buf_hl(buf), "buffer highlights cleared")
  H.ok(not has_mapping(buf, "e") and not has_mapping(buf, "q"), "answer keys removed")
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
  H.ok(first:find("File: ", 1, true) and first:find("filetype: lua", 1, true), "filename and filetype")
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

H.test("referenced code is highlighted in the box and in the matching buffer ranges", function()
  use_mock()
  local buf = H.buffer(CODE)
  vim.api.nvim_win_set_cursor(0, { 6, 0 })
  ai.ask("why could this return nil?")
  wait_ask("answered")
  local body = table.concat(box_lines(), "\n")
  H.ok(body:find("tonumber", 1, true), body)
  local box = ask.get().box_buf
  local box_marks = vim.api.nvim_buf_get_extmarks(box, vim.api.nvim_create_namespace("quill_ask_box"), 0, -1, { details = true })
  -- The namespace id is recreated above and would be empty. Use get_namespaces.
  local ns = vim.api.nvim_get_namespaces()["quill_ask_box"]
  box_marks = vim.api.nvim_buf_get_extmarks(box, ns, 0, -1, { details = true })
  local found_tonumber = false
  for _, m in ipairs(box_marks) do
    if m[4].hl_group == "QuillAskRef" then
      local line = vim.api.nvim_buf_get_lines(box, m[2], m[2] + 1, false)[1]
      if line:sub(m[3] + 1, m[4].end_col):find("tonumber", 1, true) then
        found_tonumber = true
      end
    end
  end
  H.ok(found_tonumber, "tonumber highlighted in the box")
  local marks = buf_hl(buf)
  H.ok(#marks > 0, "buffer ranges highlighted")
  local hit_tonumber, hit_line6 = false, false
  for _, m in ipairs(marks) do
    H.eq("QuillAskBuf", m[4].hl_group, "buffer highlight group")
    local line = vim.api.nvim_buf_get_lines(buf, m[2], m[2] + 1, false)[1]
    local span = line:sub(m[3] + 1, m[4].end_col)
    if m[2] == 3 and span:find("tonumber", 1, true) then
      hit_tonumber = true
    end
    if m[2] == 5 then
      hit_line6 = true
    end
  end
  H.ok(hit_tonumber, "tonumber highlighted in the buffer")
  H.ok(hit_line6, "line 6 highlighted from the 'line 6' mention")
end)

H.test("leaving the scope, entering insert, or asking again closes the box", function()
  use_mock()
  local buf = H.buffer(CODE)
  vim.api.nvim_win_set_cursor(0, { 6, 0 })
  ai.ask("why?")
  wait_ask("answered")
  H.keys("l")
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
  H.eq("answered", phase(), "moving along the line keeps it")
  H.keys("k")
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
  H.eq("answered", phase(), "moving inside the function keeps it")
  vim.api.nvim_win_set_cursor(0, { 11, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
  H.eq("closed", phase(), "leaving the function closes the box")
  H.eq(0, #floats(), "box gone")

  vim.api.nvim_win_set_cursor(0, { 6, 0 })
  ai.ask("why?")
  wait_ask("answered")
  vim.api.nvim_exec_autocmds("InsertEnter", { buffer = buf })
  H.eq("closed", phase(), "insert mode closes the box")

  vim.api.nvim_win_set_cursor(0, { 6, 0 })
  local first = ai.ask("first?")
  wait_ask("answered")
  ai.ask("second?")
  H.eq("closed", first.phase, "asking again replaces the box")
  wait_ask("answered")
  H.eq(1, #floats(), "one box shown")
end)

H.test("e hands the question and answer to a reviewed edit of the enclosing function", function()
  use_mock()
  local buf = H.buffer(CODE)
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  ai.ask("why could this return nil?")
  wait_ask("answered")
  H.keys("e")
  H.eq("closed", phase(), "box closed")
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

H.test("long answers are capped at 8 lines with a key to expand", function()
  local long = { "First line with `code`." }
  for i = 2, 12 do
    long[i] = "Sentence number " .. i .. " is here."
  end
  use_mock({ answer = table.concat(long, "\n") })
  H.buffer(CODE)
  vim.api.nvim_win_set_cursor(0, { 6, 0 })
  ai.ask("explain")
  wait_ask("answered")
  local lines = box_lines()
  H.eq(8, #lines, "capped at 8")
  H.ok(lines[8]:find("more", 1, true), "more hint: " .. lines[8])
  H.ok(has_mapping(0, "<Tab>"), "expand mapped")
  local footer = vim.api.nvim_win_get_config(ask.get().box_win).footer
  local footer_text = ""
  if type(footer) == "table" then
    for _, c in ipairs(footer) do
      footer_text = footer_text .. (type(c) == "table" and c[1] or tostring(c))
    end
  end
  H.ok(footer_text:find("expand", 1, true), "expand in footer: " .. footer_text)
  H.keys("<Tab>")
  H.ok(#box_lines() > 8, "expanded shows the rest")
  H.ok(not has_mapping(0, "<Tab>"), "expand key removed once open")
end)

H.test("Esc while waiting cancels the request and closes the box", function()
  use_mock({ interval_ms = 50, chunk_size = 1 })
  H.buffer(CODE)
  vim.api.nvim_win_set_cursor(0, { 6, 0 })
  ai.ask("why?")
  H.eq("waiting", phase(), "waiting")
  local body = table.concat(box_lines() or {}, "")
  H.ok(body:find("[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]"), "spinner shown: " .. body)
  H.keys("<Esc>")
  H.eq("closed", phase(), "closed")
  H.eq(0, #floats(), "box closed")
end)

H.test(":QuillAsk with a question skips the prompt; visual <leader>k still edits", function()
  use_mock()
  local buf = H.buffer(CODE)
  vim.api.nvim_win_set_cursor(0, { 6, 0 })
  vim.cmd("QuillAsk why nil?")
  H.eq("waiting", phase(), "went straight to waiting")
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

H.test("empty Enter keeps the prompt open; mock has a default answer", function()
  ai.config.provider, ai.config.providers.mock = "mock", { interval_ms = 2, chunk_size = 50 }
  H.buffer(CODE)
  vim.api.nvim_win_set_cursor(0, { 6, 0 })
  H.keys(" k")
  H.eq("prompting", phase(), "prompt open")
  H.keys("<CR>")
  H.eq("prompting", phase(), "empty submit stays in the prompt")
  H.keys("<Esc>")
  H.eq("closed", phase(), "esc closes")
  ai.ask("why?")
  wait_ask("answered")
  local body = table.concat(box_lines(), " ")
  H.ok(body:find("Mock answer to: why?", 1, true), body)
end)

H.test("the prompt buffer opts out of completion", function()
  local configured
  package.loaded.cmp = { setup = { buffer = function(cfg)
    configured = cfg
  end } }
  H.buffer(CODE)
  vim.api.nvim_win_set_cursor(0, { 6, 0 })
  H.keys(" k")
  H.eq("prompting", phase(), "prompt open")
  local buf = ask.get().box_buf
  H.eq("quill_prompt", vim.bo[buf].filetype, "filetype")
  H.eq("", vim.bo[buf].complete, "complete opt")
  H.eq(false, vim.b[buf].completion, "blink.cmp")
  H.eq(true, vim.b[buf].minicompletion_disable, "mini.completion")
  H.eq({ enabled = false }, configured, "nvim-cmp")
  package.loaded.cmp = nil
end)


H.test("wrapping does not split backtick spans or leak ticks", function()
  use_mock({
    answer = "The comparison `n < 1` is unsafe when tonumber fails and n is nil, which is a problem.\n",
  })
  vim.o.columns = 40
  H.buffer(CODE)
  vim.api.nvim_win_set_cursor(0, { 6, 0 })
  ai.ask("why?")
  wait_ask("answered")
  local body = table.concat(box_lines(), "\n")
  H.ok(not body:find("`", 1, true), "no leaked backticks: " .. body)
  H.ok(body:find("n < 1", 1, true), "span stays together: " .. body)
  vim.o.columns = 80
end)

H.finish()
