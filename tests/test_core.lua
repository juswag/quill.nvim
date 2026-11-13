local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/helpers.lua")
H.bootstrap()
local ai = require("quill")

local ORIGINAL = {
  "local function add(a, b)",
  "  return a + b",
  "end",
  "",
  "local function sub(a, b)",
  "  return a - b",
  "end",
}
local REWRITE = table.concat({
  "local function add(a, b)",
  "  assert(type(a) == 'number')",
  "  return a + b",
  "end",
  "",
  "local function subtract(a, b)",
  "  return a - b",
  "end",
}, "\n") .. "\n"

local seen = {}
local function use_mock(extra)
  ai.setup({
    provider = "mock",
    providers = {
      mock = vim.tbl_extend("force", {
        interval_ms = 2,
        chunk_size = 6,
        response = function(req)
          seen[#seen + 1] = req
          return REWRITE
        end,
      }, extra or {}),
    },
  })
end

H.test("hunks.merge applies only accepted hunks", function()
  local hunks = require("quill.hunks")
  local proposed = vim.split(REWRITE, "\n", { trimempty = true })
  local hs = hunks.compute(ORIGINAL, proposed)
  H.eq(2, #hs, "two hunks")
  hs[1].status, hs[2].status = "rejected", "accepted"
  local expected = vim.deepcopy(ORIGINAL)
  expected[5] = "local function subtract(a, b)"
  H.eq(expected, hunks.merge(ORIGINAL, proposed, hs), "only second hunk merged")
  hs[1].status = "accepted"
  H.eq(proposed, hunks.merge(ORIGINAL, proposed, hs), "all accepted equals proposal")
end)

H.test("hunks.inline finds changed words and skips rewritten lines", function()
  local hunks = require("quill.hunks")
  H.eq({ old = { { 15, 18 } }, new = { { 15, 23 } } },
    hunks.inline("local function sub(a, b)", "local function subtract(a, b)"), "renamed identifier")
  H.eq({ old = {}, new = { { 10, 21 } } }, hunks.inline("  return x", "  return x, \"invalid\""), "appended words")
  H.eq({ old = { { 11, 12 } }, new = { { 11, 12 } } }, hunks.inline('x = "é" + 1', 'x = "é" + 2'), "multibyte-safe offsets")
  H.eq(nil, hunks.inline("return a + b", "error('unsupported operation')"), "full rewrite gets no word highlight")
end)

H.test("current hunk gets word highlights and strong colors, others are dimmed", function()
  use_mock()
  local buf = H.buffer(ORIGINAL)
  ai.start(1, 7, { instruction = "validate and rename" })
  H.wait_phase("reviewing")
  H.keys("]h")
  local by_row = {}
  for _, m in ipairs(H.preview_marks(buf)) do
    local d = m[4]
    by_row[m[2]] = by_row[m[2]] or {}
    table.insert(by_row[m[2]], { hl = d.hl_group, line = d.line_hl_group, col = m[3], end_col = d.end_col, hint = d.virt_text })
  end
  local function find(row, pred)
    for _, x in ipairs(by_row[row] or {}) do
      if pred(x) then return x end
    end
  end
  H.ok(find(4, function(x) return x.hl == "QuillDelete" end), "current hunk row uses strong delete bg")
  H.ok(find(4, function(x) return x.hl == "QuillDeleteText" and x.col == 15 and x.end_col == 18 end), "word 'sub' highlighted")
  H.ok(find(4, function(x) return x.hint end), "key hint on current hunk")
  local virt
  for _, m in ipairs(H.preview_marks(buf)) do
    if m[4].virt_lines and m[2] == 0 then virt = m[4].virt_lines end
  end
  H.ok(virt and virt[1][1][2] == "QuillSignDim", "other hunk added line has dim gutter")
  H.ok(vim.iter(virt[1]):any(function(c) return c[2] == "QuillAddDim" end), "other hunk added line dimmed")
end)

H.test("status float shows streaming progress, then a done state", function()
  use_mock({ interval_ms = 10, chunk_size = 3 })
  H.buffer(ORIGINAL)
  local s = ai.start(1, 7, { instruction = "x" })
  local function status_text()
    return s.hint_buf and vim.api.nvim_buf_is_valid(s.hint_buf) and vim.api.nvim_buf_get_lines(s.hint_buf, 0, 1, false)[1] or ""
  end
  H.ok(vim.wait(1000, function() return status_text():find("Generating", 1, true) and status_text():find("mock", 1, true) end, 5),
    "streaming status with model: " .. status_text())
  H.wait_phase("reviewing")
  H.ok(status_text():find("Ready", 1, true) and status_text():find("+2", 1, true) and status_text():find("−1", 1, true),
    "done status with line counts: " .. status_text())
end)

H.test("accepting a hunk flashes it briefly, then it settles into the accepted style", function()
  use_mock()
  local buf = H.buffer(ORIGINAL)
  ai.start(1, 7, { instruction = "validate and rename" })
  H.wait_phase("reviewing")
  H.keys("a")
  local function added_hl()
    for _, m in ipairs(H.preview_marks(buf)) do
      if m[4].virt_lines and m[2] == 0 then
        return m[4].virt_lines[1][3][2]
      end
    end
  end
  H.eq("QuillFlash", added_hl(), "flash right after accept")
  H.ok(vim.wait(1000, function() return added_hl() == "QuillAdd" end, 10), "settled: " .. tostring(added_hl()))
end)

H.test("preview never modifies the buffer while streaming or reviewing", function()
  use_mock({ interval_ms = 5, chunk_size = 3 })
  local buf = H.buffer(ORIGINAL)
  local tick = vim.b[buf].changedtick
  ai.start(1, 7, { instruction = "validate and rename" })
  local saw_partial = vim.wait(2000, function()
    local s = ai.get_session()
    return s.phase == "streaming" and #s.proposed >= 3 and #H.preview_marks(buf) > 0
  end, 1)
  H.ok(saw_partial, "preview extmarks drawn mid-stream")
  H.eq(ORIGINAL, H.lines(buf), "buffer unchanged mid-stream")
  H.wait_phase("reviewing")
  H.eq(ORIGINAL, H.lines(buf), "buffer unchanged in review")
  H.eq(tick, vim.b[buf].changedtick, "changedtick unchanged")
  H.eq(false, vim.bo[buf].modified, "buffer not modified")
  local virt = 0
  for _, m in ipairs(H.preview_marks(buf)) do
    virt = virt + (m[4].virt_lines and #m[4].virt_lines or 0)
  end
  H.eq(2, virt, "two proposed lines rendered as virt_lines")
  H.eq(2, #ai.get_session().hunks, "two hunks")
end)

H.test("accepting one hunk and rejecting the other yields the expected text", function()
  use_mock()
  local buf = H.buffer(ORIGINAL)
  ai.start(1, 7, { instruction = "validate and rename" })
  H.wait_phase("reviewing")
  H.keys("a")
  H.eq(ORIGINAL, H.lines(buf), "accepting is staged, buffer untouched until all hunks resolved")
  H.keys("r")
  H.wait_phase("closed")
  local flash = vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_get_namespaces().quill_flash, 0, -1, {})
  H.eq({ 1 }, vim.tbl_map(function(m) return m[2] end, flash), "only the inserted row flashes as applied")
  H.eq({
    "local function add(a, b)",
    "  assert(type(a) == 'number')",
    "  return a + b",
    "end",
    "",
    "local function sub(a, b)",
    "  return a - b",
    "end",
  }, H.lines(buf), "only first hunk applied")
  H.eq({}, H.preview_marks(buf), "preview cleared")
  H.eq("", vim.fn.maparg("a", "n"), "session mappings removed")
end)

H.test("a single u restores the original after accepting several hunks", function()
  use_mock()
  local buf = H.buffer(ORIGINAL)
  local before = vim.fn.undotree().seq_cur
  ai.start(1, 7, { instruction = "validate and rename" })
  H.wait_phase("reviewing")
  H.keys("a")
  H.keys("a")
  H.wait_phase("closed")
  H.eq(vim.split(REWRITE, "\n", { trimempty = true }), H.lines(buf), "both hunks applied")
  H.eq(before + 1, vim.fn.undotree().seq_cur, "exactly one undo step added")
  vim.cmd("silent normal! u")
  H.eq(ORIGINAL, H.lines(buf), "one u restores the original")
end)

H.test("reject all leaves the buffer identical with no undo entry", function()
  use_mock()
  local buf = H.buffer(ORIGINAL)
  local tick, seq = vim.b[buf].changedtick, vim.fn.undotree().seq_cur
  ai.start(1, 7, { instruction = "validate and rename" })
  H.wait_phase("reviewing")
  H.keys("R")
  H.wait_phase("closed")
  H.eq(ORIGINAL, H.lines(buf), "identical")
  H.eq(tick, vim.b[buf].changedtick, "changedtick unchanged")
  H.eq(seq, vim.fn.undotree().seq_cur, "no undo entry")
end)

H.test("navigation: ]h then a accepts the second hunk only", function()
  use_mock()
  local buf = H.buffer(ORIGINAL)
  ai.start(1, 7, { instruction = "validate and rename" })
  H.wait_phase("reviewing")
  H.keys("]h")
  H.eq(5, vim.api.nvim_win_get_cursor(0)[1], "cursor on second hunk")
  H.keys("a")
  H.keys("r")
  H.wait_phase("closed")
  H.eq({ ORIGINAL[1], ORIGINAL[2], ORIGINAL[3], "", "local function subtract(a, b)", ORIGINAL[6], ORIGINAL[7] },
    H.lines(buf), "only rename applied")
end)

H.test("follow-up re-runs with prior instruction and output, anchored to the same range", function()
  seen = {}
  use_mock()
  local buf = H.buffer({ "-- header", unpack(ORIGINAL) })
  ai.start(2, 8, { instruction = "validate and rename" })
  H.wait_phase("reviewing")
  ai.followup("also keep the name sub")
  H.eq("streaming", ai.get_session().phase, "follow-up streaming")
  H.wait_phase("reviewing")
  H.eq(2, #seen, "two requests")
  local msgs = seen[2].messages
  H.eq({ "user", "assistant", "user" }, vim.tbl_map(function(m) return m.role end, msgs), "history roles")
  H.ok(msgs[1].content:find("Instruction: validate and rename", 1, true), "first instruction kept")
  H.eq(REWRITE, msgs[2].content, "prior proposed output included")
  H.ok(msgs[3].content:find("also keep the name sub", 1, true), "follow-up instruction")
  H.eq(ORIGINAL, seen[2].selection, "same anchored selection")
  H.eq({ 1, 7 }, ai.get_session().range, "range unchanged (0-based rows)")
  H.keys("A")
  H.wait_phase("closed")
  H.eq("-- header", H.lines(buf)[1], "text outside range untouched")
  H.eq("  assert(type(a) == 'number')", H.lines(buf)[3], "applied inside range")
end)

H.test("follow-up through the f mapping and the prompt window", function()
  seen = {}
  use_mock()
  local buf = H.buffer(ORIGINAL)
  ai.start(1, 7, { instruction = "first" })
  H.wait_phase("reviewing")
  H.keys("f")
  H.eq("prompting", ai.get_session(buf).phase, "prompt opened")
  H.ok(vim.api.nvim_win_get_config(0).title, "follow-up prompt focused")
  vim.api.nvim_win_close(0, true)
  H.eq("reviewing", ai.get_session(buf).phase, "closing the follow-up prompt returns to review")
  -- One feedkeys call so startinsert takes effect before the text is typed, as in real typing.
  H.keys("fsecond pass<CR>")
  H.wait_phase("reviewing")
  H.eq("second pass", seen[2].instruction, "typed follow-up sent")
  H.eq(2, #ai.get_session().history, "two turns")
end)

H.test("visual select + <leader>k + typed instruction starts a session", function()
  seen = {}
  use_mock()
  local buf = H.buffer(ORIGINAL)
  H.keys("ggVG")
  H.keys(" k")
  H.eq("prompting", ai.get_session(buf).phase, "prompt open")
  H.ok(vim.api.nvim_win_get_config(0).relative ~= "", "focus in floating prompt")
  vim.api.nvim_win_close(0, true)
  H.eq(nil, ai.get_session(buf), "closing the first prompt ends the session")
  H.keys("ggVG k" .. "validate<CR>")
  H.wait_phase("reviewing")
  H.eq("validate", seen[1].instruction, "instruction")
  H.eq(ORIGINAL, seen[1].selection, "selection")
  H.eq(buf, vim.api.nvim_get_current_buf(), "focus back in source buffer")
end)

H.test("Esc in the first prompt cancels the session", function()
  use_mock()
  local buf = H.buffer(ORIGINAL)
  H.keys("ggVj")
  H.keys(" k")
  H.keys("<Esc>")
  H.eq(nil, ai.get_session(), "session closed")
  H.eq(ORIGINAL, H.lines(buf), "unchanged")
end)

H.test("q mid-stream cancels the request and clears the preview", function()
  local chunks_after = 0
  use_mock({ interval_ms = 20, chunk_size = 2 })
  local buf = H.buffer(ORIGINAL)
  local s = ai.start(1, 7, { instruction = "slow" })
  vim.wait(200, function() return #H.preview_marks(buf) > 0 end, 5)
  H.keys("q")
  H.eq(nil, ai.get_session(), "session closed")
  local snapshot = #s.proposed
  vim.wait(200, function() chunks_after = #s.proposed - snapshot return false end, 10)
  H.eq(0, chunks_after, "no chunks after cancel")
  H.eq("closed", s.phase, "phase closed")
  H.eq({}, H.preview_marks(buf), "preview cleared")
  H.eq(ORIGINAL, H.lines(buf), "unchanged")
end)

H.test("request carries filetype, surrounding lines, diagnostics and treesitter node", function()
  seen = {}
  use_mock()
  local buf = H.buffer({ "local x = 1", unpack(ORIGINAL) })
  local dns = vim.api.nvim_create_namespace("test_diag")
  vim.diagnostic.set(dns, buf, { { lnum = 2, col = 0, message = "undefined global b", severity = vim.diagnostic.severity.WARN } })
  ai.start(3, 3, { instruction = "fix" })
  H.wait_phase("reviewing")
  local first = seen[1].messages[1].content
  H.ok(first:find("filetype: lua", 1, true), "filetype")
  H.ok(first:find("local x = 1", 1, true), "surrounding lines")
  H.ok(first:find("line 1 [WARN]: undefined global b", 1, true), "diagnostic in range")
  H.ok(first:find("Enclosing syntax node: ", 1, true), "treesitter node: " .. first)
end)

H.finish()
