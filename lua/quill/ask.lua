-- Ask mode: a question about the code under the cursor, answered in a float next to it.
-- Never writes the buffer; the edit key hands the thread to an edit session instead.
--   prompting -> streaming -> answered -> (prompting via follow-up) ... -> closed
local context = require("quill.context")
local prompt = require("quill.prompt")
local render = require("quill.render")
local registry = require("quill.providers")

local M = {}

local WIDTH, MAX_HEIGHT = 72, 20
local current

local transitions = {
  prompting = { submit = "streaming", dismiss = "answered", cancel = "closed" },
  streaming = { done = "answered", failed = "answered", cancel = "closed" },
  answered = { followup = "prompting", edit = "closed", cancel = "closed" },
}

local function transition(a, event)
  local next_phase = transitions[a.phase] and transitions[a.phase][event]
  assert(next_phase, ("quill: no ask transition %s --%s-->"):format(a.phase, event))
  a.phase = next_phase
end

local function config()
  return require("quill").config
end

local function cancel_keys()
  local c = config().keys.cancel
  return type(c) == "table" and c or { c }
end

local function title(a)
  local s, e = a.scope[1], a.scope[2]
  return { { " ? Ask ", "QuillTitle" }, { ("lines %d–%d "):format(s + 1, e + 1), "QuillMuted" } }
end

local function footer(a)
  local k = config().keys
  if a.phase == "streaming" then
    return vim.list_extend({
      { " " .. render.spinner(a.frame) .. " ", "QuillSpinner" },
      { "Answering ", "QuillStatus" },
      { a.model .. "  ", "QuillMuted" },
    }, render.key_chips({ { cancel_keys()[1], "cancel" } }))
  end
  return render.key_chips({ { k.followup, "follow-up" }, { k.edit, "edit" }, { cancel_keys()[1], "close" } })
end

local thread_ns = vim.api.nvim_create_namespace("quill_ask")

--- The thread: each question on its own line, then its answer (partial while streaming).
--- Returns the lines, the 0-based rows of the questions, and the row where the latest turn starts.
local function thread(a)
  local lines, questions = {}, {}
  for i, turn in ipairs(a.turns) do
    if i > 1 then
      vim.list_extend(lines, { "", "" })
    end
    questions[#questions + 1] = #lines
    lines[#lines + 1] = "› " .. turn.question
    lines[#lines + 1] = ""
    vim.list_extend(lines, vim.split(turn.answer or table.concat(a.chunks), "\n", { plain = true }))
  end
  return lines, questions, questions[#questions] or 0
end

--- Below the cursor line when the answer fits there or there is more room below, else above.
local function placement(a, height)
  local screen_row = vim.api.nvim_win_call(a.win, function()
    return vim.fn.winline()
  end)
  local below = vim.api.nvim_win_get_height(a.win) - screen_row - 2
  local above = screen_row - 3
  local down = below >= height or below >= above
  local info = vim.fn.getwininfo(a.win)[1]
  return {
    relative = "win",
    win = a.win,
    bufpos = { a.row, 0 },
    anchor = down and "NW" or "SW",
    row = down and 1 or 0,
    col = 0,
    width = math.max(20, math.min(WIDTH, info.width - info.textoff - 4)),
    height = math.max(1, math.min(height, MAX_HEIGHT, down and below or above)),
    border = "rounded",
    title = title(a),
    title_pos = "left",
    footer = footer(a),
    footer_pos = "right",
    zindex = 60,
  }
end

local function redraw(a)
  if not (a.answer_win and vim.api.nvim_win_is_valid(a.answer_win)) then
    return
  end
  local buf, win = a.answer_buf, a.answer_win
  local lines, questions, latest = thread(a)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, thread_ns, 0, -1)
  for _, row in ipairs(questions) do
    vim.api.nvim_buf_set_extmark(buf, thread_ns, row, 0, { end_col = #"›", hl_group = "QuillPromptIcon", priority = 300 })
    vim.api.nvim_buf_set_extmark(buf, thread_ns, row, #"›", { end_col = #lines[row + 1], hl_group = "QuillStatus", priority = 300 })
  end
  vim.api.nvim_win_set_config(win, placement(a, vim.api.nvim_win_text_height(win, {}).all))
  -- Follow the tail, but never scroll the latest question out of view; rest on that question.
  vim.api.nvim_win_call(win, function()
    if a.phase == "streaming" then
      vim.cmd("normal! Gzb")
      if vim.fn.line("w0") > latest + 1 then
        vim.fn.winrestview({ topline = latest + 1 })
      end
    end
    vim.api.nvim_win_set_cursor(win, { latest + 1, 0 })
  end)
end

local close

local function open_window(a)
  if a.answer_win and vim.api.nvim_win_is_valid(a.answer_win) then
    return vim.api.nvim_set_current_win(a.answer_win)
  end
  a.answer_buf = vim.api.nvim_create_buf(false, true)
  local buf = a.answer_buf
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  pcall(vim.treesitter.start, buf, "markdown")
  local cfg = placement(a, 1)
  cfg.style = "minimal"
  a.answer_win = vim.api.nvim_open_win(buf, true, cfg)
  local wo = vim.wo[a.answer_win]
  wo.winhighlight = "NormalFloat:QuillFloat,FloatBorder:QuillBorder,FloatTitle:QuillTitle"
  wo.wrap, wo.linebreak, wo.conceallevel, wo.concealcursor = true, true, 2, "nc"

  local k = config().keys
  local actions = {
    [k.followup] = function() M.followup() end,
    [k.edit] = function() M.edit() end,
  }
  for _, lhs in ipairs(cancel_keys()) do
    actions[lhs] = function() close(a, "cancel") end
  end
  for lhs, fn in pairs(actions) do
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = "quill ask" })
  end
  vim.api.nvim_create_autocmd("WinClosed", { pattern = tostring(a.answer_win), once = true, callback = function()
    vim.schedule(function()
      close(a, "cancel")
    end)
  end })
end

local function stop_spinner(a)
  if a.spinner and not a.spinner:is_closing() then
    a.spinner:stop()
    a.spinner:close()
  end
  a.spinner = nil
end

function close(a, event)
  if a.phase == "closed" then
    return
  end
  if a.job then
    a.job.cancel()
    a.job = nil
  end
  transition(a, event)
  stop_spinner(a)
  if a.answer_win and vim.api.nvim_win_is_valid(a.answer_win) then
    vim.api.nvim_win_close(a.answer_win, true)
  end
  if vim.api.nvim_win_is_valid(a.win) then
    vim.api.nvim_set_current_win(a.win)
  end
  if current == a then
    current = nil
  end
end

local function run(a)
  local name = config().provider
  local opts = config().providers[name] or {}
  local stream = registry[opts.format or name]
  assert(stream, "quill: unknown provider " .. name)
  local req = context.ask_request(a)
  a.chunks, a.frame, a.model = {}, 0, opts.model or name
  open_window(a)
  redraw(a)
  stop_spinner(a)
  a.spinner = vim.uv.new_timer()
  a.spinner:start(80, 80, vim.schedule_wrap(function()
    if a.phase ~= "streaming" then
      return stop_spinner(a)
    end
    a.frame = a.frame + 1
    redraw(a)
  end))
  local turn = a.turns[#a.turns]
  a.job = stream(req, opts, {
    on_chunk = function(text)
      if a.phase == "streaming" then
        a.chunks[#a.chunks + 1] = text
        redraw(a)
      end
    end,
    on_done = function()
      if a.phase ~= "streaming" then
        return
      end
      a.job = nil
      turn.answer = vim.trim(table.concat(a.chunks))
      transition(a, "done")
      stop_spinner(a)
      redraw(a)
    end,
    on_error = function(err)
      if a.phase ~= "streaming" then
        return
      end
      a.job = nil
      vim.notify("quill: " .. err, vim.log.levels.ERROR)
      table.remove(a.turns)
      if #a.turns == 0 then
        return close(a, "cancel")
      end
      transition(a, "failed")
      stop_spinner(a)
      redraw(a)
    end,
  })
end

local function submit(a, question)
  a.turns[#a.turns + 1] = { question = question }
  transition(a, "submit")
  run(a)
end

local function open_prompt(a)
  local first = #a.turns == 0
  prompt.open({
    win = a.win,
    row = a.row,
    end_row = a.row,
    title = first and title(a) or { { " ↻ Follow-up ", "QuillTitle" }, { ("turn %d "):format(#a.turns + 1), "QuillMuted" } },
    placeholder = first and "Ask about this code…" or "Ask a follow-up…",
    on_submit = function(question)
      if a.phase == "prompting" then
        submit(a, question)
      end
    end,
    on_cancel = function()
      if a.phase ~= "prompting" then
        return
      end
      if #a.turns == 0 then
        return close(a, "cancel")
      end
      transition(a, "dismiss")
      open_window(a)
    end,
  })
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
    turns = {},
    chunks = {},
    phase = "prompting",
  }
  current = a
  if question and question ~= "" then
    submit(a, question)
  else
    open_prompt(a)
  end
  return a
end

--- Asks a follow-up in the same thread (prompts unless `question` is given).
function M.followup(question)
  local a = current
  if not a or a.phase ~= "answered" then
    return
  end
  transition(a, "followup")
  if question then
    submit(a, question)
  else
    open_prompt(a)
  end
end

--- Closes the thread and starts an edit session on the enclosing function that applies it.
function M.edit()
  local a = current
  if not a or a.phase ~= "answered" then
    return
  end
  local parts = { "Make the change this discussion about the code arrived at." }
  for _, turn in ipairs(a.turns) do
    parts[#parts + 1] = ("Question: %s\nAnswer: %s"):format(turn.question, turn.answer)
  end
  local s, e = a.scope[1], a.scope[2]
  close(a, "edit")
  require("quill").start(s + 1, e + 1, { instruction = table.concat(parts, "\n\n") })
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
