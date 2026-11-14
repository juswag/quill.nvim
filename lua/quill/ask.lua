-- Ask mode: a question about the code under the cursor, answered inline as virtual lines
-- under the cursor line. Never writes the buffer. Moving off the line, typing, or <Esc>
-- dismisses it; the edit key turns it into an edit session on the enclosing function.
--   prompting -> streaming -> answered -> closed
local context = require("quill.context")
local prompt = require("quill.prompt")
local render = require("quill.render")
local registry = require("quill.providers")

local M = {}

M.ns = vim.api.nvim_create_namespace("quill_ask")
local MAX_LINES = 8
local current

local transitions = {
  prompting = { submit = "streaming", cancel = "closed" },
  streaming = { done = "answered", cancel = "closed" },
  answered = { edit = "closed", cancel = "closed" },
}

local function transition(a, event)
  local next_phase = transitions[a.phase] and transitions[a.phase][event]
  assert(next_phase, ("quill: no ask transition %s --%s-->"):format(a.phase, event))
  a.phase = next_phase
end

local function config()
  return require("quill").config
end

local function list(v)
  return type(v) == "table" and v or { v }
end

--- Markdown -> lines of {text, hl} chunks: fences dropped and code indented, `code` spans
--- kept as subtle chips, emphasis markers and heading hashes stripped.
local function parse(text)
  local out, in_code = {}, false
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    if line:match("^%s*```") then
      in_code = not in_code
    elseif in_code then
      out[#out + 1] = { { "  " .. line, "QuillAnswerCode" } }
    else
      line = line:gsub("^#+%s*", ""):gsub("%*%*", "")
      local chunks, code = {}, false
      for part in (line .. "`"):gmatch("(.-)`") do
        if part ~= "" then
          chunks[#chunks + 1] = { part, code and "QuillAnswerCode" or "QuillAnswer" }
        end
        code = not code
      end
      out[#out + 1] = chunks
    end
  end
  while #out > 0 and #out[#out] == 0 do
    table.remove(out)
  end
  return out
end

--- Word-wraps one line of chunks to `width` display cells.
local function wrap(chunks, width)
  local rows, row, used = {}, {}, 0
  for _, c in ipairs(chunks) do
    for word in c[1]:gmatch("%s*%S+") do
      local w = vim.fn.strdisplaywidth(word)
      if used > 0 and used + w > width then
        rows[#rows + 1], row, used = row, {}, 0
        word = word:gsub("^%s+", "")
        w = vim.fn.strdisplaywidth(word)
      end
      row[#row + 1] = { word, c[2] }
      used = used + w
    end
    local tail = c[1]:match("%s+$")
    if tail then
      row[#row + 1] = { tail, c[2] }
      used = used + #tail
    end
  end
  rows[#rows + 1] = row
  return rows
end

local LABELS = { ["<CR>"] = "⏎", ["<Esc>"] = "esc", ["<Tab>"] = "tab" }

local function key_hint(pairs_list)
  local out = {}
  for _, p in ipairs(pairs_list) do
    vim.list_extend(out, { { " " .. (LABELS[p[1]] or p[1]) .. " ", "QuillInlineKey" }, { " " .. p[2] .. " ", "QuillAnswer" }, { " ", "QuillAnswer" } })
  end
  return out
end

local function draw(a)
  if not vim.api.nvim_buf_is_valid(a.bufnr) then
    return
  end
  local info = vim.fn.getwininfo(a.win)[1]
  local textoff = info and info.textoff or 0
  local indent = string.rep(" ", vim.fn.indent(a.row + 1))
  local prefix = { { "┃", "QuillAnswerBar" }, { string.rep(" ", math.max(0, textoff - 1)), "QuillGutter" }, { indent, "QuillAnswer" } }
  local width = math.max(20, (info and info.width or 80) - textoff - #indent - 1)

  local rows = {}
  for _, chunks in ipairs(parse(a.answer or table.concat(a.chunks))) do
    vim.list_extend(rows, wrap(chunks, width))
  end
  local k = config().keys
  local hidden = 0
  if not a.expanded and #rows > MAX_LINES then
    hidden = #rows - MAX_LINES
    rows = vim.list_slice(rows, 1, MAX_LINES)
    table.insert(rows[#rows], { " …", "QuillAnswer" })
  end
  if a.phase == "streaming" then
    if #rows == 0 then
      rows[1] = {}
    end
    table.insert(rows[#rows], { (#rows[#rows] > 0 and " " or "") .. render.spinner(a.frame), "QuillPromptIcon" })
  else
    local cancel = list(k.cancel)
    local keys = { { list(k.edit)[1], "edit" }, { vim.tbl_contains(cancel, "<Esc>") and "<Esc>" or cancel[1], "dismiss" } }
    if hidden > 0 then
      table.insert(keys, 2, { k.expand, ("%d more"):format(hidden) })
    end
    rows[#rows + 1] = key_hint(keys)
  end
  local virt = {}
  for i, r in ipairs(rows) do
    virt[i] = vim.list_extend(vim.deepcopy(prefix), r)
  end
  a.mark = vim.api.nvim_buf_set_extmark(a.bufnr, M.ns, a.row, 0, {
    id = a.mark,
    virt_lines = virt,
    virt_lines_leftcol = true,
  })
end

local function stop_spinner(a)
  if a.spinner and not a.spinner:is_closing() then
    a.spinner:stop()
    a.spinner:close()
  end
  a.spinner = nil
end

local function close(a, event)
  if a.phase == "closed" then
    return
  end
  if a.job then
    a.job.cancel()
    a.job = nil
  end
  transition(a, event)
  stop_spinner(a)
  for _, lhs in ipairs(a.mapped) do
    pcall(vim.keymap.del, "n", lhs, { buffer = a.bufnr })
  end
  pcall(vim.api.nvim_del_augroup_by_id, a.augroup)
  if vim.api.nvim_buf_is_valid(a.bufnr) then
    vim.api.nvim_buf_clear_namespace(a.bufnr, M.ns, 0, -1)
  end
  if current == a then
    current = nil
  end
end

--- Turns the answer into an edit session on the enclosing function.
local function to_edit(a)
  if a.phase ~= "answered" then
    return
  end
  local instruction = ("Question: %s\nAnswer: %s\n\nMake the change the answer suggests."):format(a.question, a.answer)
  local s, e = a.scope[1], a.scope[2]
  close(a, "edit")
  require("quill").start(s + 1, e + 1, { instruction = instruction })
end

--- Buffer-local keys and dismiss triggers, live only while the answer is shown.
local function attach(a)
  local k = config().keys
  local actions = {
    [k.expand] = function()
      if a.phase == "answered" then
        a.expanded = true
        draw(a)
      end
    end,
  }
  for _, lhs in ipairs(list(k.edit)) do
    actions[lhs] = function() to_edit(a) end
  end
  for _, lhs in ipairs(list(k.cancel)) do
    actions[lhs] = function() close(a, "cancel") end
  end
  for lhs, fn in pairs(actions) do
    vim.keymap.set("n", lhs, fn, { buffer = a.bufnr, nowait = true, desc = "quill ask" })
    a.mapped[#a.mapped + 1] = lhs
  end
  a.augroup = vim.api.nvim_create_augroup("quill_ask_" .. a.bufnr, { clear = true })
  local function dismiss()
    close(a, "cancel")
  end
  vim.api.nvim_create_autocmd("CursorMoved", { group = a.augroup, buffer = a.bufnr, callback = function()
    if vim.api.nvim_win_get_cursor(0)[1] - 1 ~= a.row then
      dismiss()
    end
  end })
  vim.api.nvim_create_autocmd({ "InsertEnter", "TextChanged", "BufLeave", "WinLeave" },
    { group = a.augroup, buffer = a.bufnr, callback = dismiss })
end

local function run(a)
  local name = config().provider
  local opts = config().providers[name] or {}
  local stream = registry[opts.format or name]
  assert(stream, "quill: unknown provider " .. name)
  local req = context.ask_request(a)
  a.chunks, a.frame = {}, 0
  attach(a)
  draw(a)
  a.spinner = vim.uv.new_timer()
  a.spinner:start(80, 80, vim.schedule_wrap(function()
    if a.phase ~= "streaming" then
      return stop_spinner(a)
    end
    a.frame = a.frame + 1
    draw(a)
  end))
  a.job = stream(req, opts, {
    on_chunk = function(text)
      if a.phase == "streaming" then
        a.chunks[#a.chunks + 1] = text
        draw(a)
      end
    end,
    on_done = function()
      if a.phase ~= "streaming" then
        return
      end
      a.job = nil
      a.answer = vim.trim(table.concat(a.chunks))
      transition(a, "done")
      stop_spinner(a)
      draw(a)
    end,
    on_error = function(err)
      if a.phase ~= "streaming" then
        return
      end
      a.job = nil
      vim.notify("quill: " .. err, vim.log.levels.ERROR)
      close(a, "cancel")
    end,
  })
end

local function submit(a, question)
  a.question = question
  transition(a, "submit")
  run(a)
end

--- Asks about the code under the cursor. With `question` it skips the prompt window.
function M.open(question)
  if current then
    close(current, "cancel")
  end
  local win = vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_win_get_buf(win)
  local row = vim.api.nvim_win_get_cursor(win)[1] - 1
  local a = {
    bufnr = bufnr,
    win = win,
    row = row,
    scope = { context.scope(bufnr, row, config().context_lines) },
    chunks = {},
    mapped = {},
    phase = "prompting",
  }
  current = a
  if question and question ~= "" then
    submit(a, question)
    return a
  end
  local s, e = a.scope[1], a.scope[2]
  prompt.open({
    win = win,
    row = row,
    end_row = row,
    title = { { " ? Ask ", "QuillTitle" }, { ("lines %d–%d "):format(s + 1, e + 1), "QuillMuted" } },
    placeholder = "Ask about this code…",
    on_submit = function(q)
      if a.phase == "prompting" then
        submit(a, q)
      end
    end,
    on_cancel = function()
      close(a, "cancel")
    end,
  })
  return a
end

function M.cancel()
  if current then
    close(current, "cancel")
  end
end

--- Read-only snapshot for statuslines and tests.
function M.get()
  return current
end

return M
