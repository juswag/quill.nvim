-- Cmd-K style inline edit sessions. One session per buffer, driven by a phase table:
--   prompting -> streaming -> reviewing -> (prompting via follow-up) ... -> closed
local hunks_mod = require("quill.hunks")
local render = require("quill.render")
local context = require("quill.context")
local prompt = require("quill.prompt")
local registry = require("quill.providers")

local M = {}

M.config = {
  provider = "openai",
  providers = {
    mock = {},
    openai = {},
    anthropic = {},
  },
  context_lines = 20,
  mapping = "<leader>k",
  keys = {
    accept = "a",
    reject = "r",
    accept_all = "A",
    reject_all = "R",
    next = "]h",
    prev = "[h",
    followup = "f",
    cancel = { "q", "<Esc>" },
  },
}

local sessions = {}
local anchor_ns = vim.api.nvim_create_namespace("quill_anchor")

local transitions = {
  prompting = { submit = "streaming", dismiss = "reviewing", cancel = "closed" },
  streaming = { done = "reviewing", failed = "reviewing", cancel = "closed" },
  reviewing = { followup = "prompting", resolve = "closed", cancel = "closed" },
}

local function transition(s, event)
  local next_phase = transitions[s.phase] and transitions[s.phase][event]
  assert(next_phase, ("quill: no transition %s --%s-->"):format(s.phase, event))
  s.phase = next_phase
end

--- Returns 0-based inclusive start/end rows tracked by the anchor extmark.
local function range(s)
  local m = vim.api.nvim_buf_get_extmark_by_id(s.bufnr, anchor_ns, s.mark, { details = true })
  return m[1], m[3].end_row
end

--- Model output -> lines. Drops markdown fences; while streaming, drops the partial last line.
local function output_lines(text, complete)
  local lines = vim.split(text, "\n", { plain = true })
  if not complete or lines[#lines] == "" then
    table.remove(lines)
  end
  if lines[1] and lines[1]:match("^```") then
    table.remove(lines, 1)
  end
  if complete and lines[#lines] and lines[#lines]:match("^```%s*$") then
    table.remove(lines)
  end
  return lines
end

local function cancel_key()
  local c = M.config.keys.cancel
  return type(c) == "table" and c[1] or c
end

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local function key_chips(pairs_list)
  local chunks = {}
  for _, p in ipairs(pairs_list) do
    chunks[#chunks + 1] = { " " .. p[1] .. " ", "QuillKey" }
    chunks[#chunks + 1] = { " " .. p[2] .. " ", "QuillKeyLabel" }
  end
  return chunks
end

local function status_chunks(s)
  local k = M.config.keys
  if s.phase == "streaming" then
    local st = s.stats
    local out = {
      { " " .. SPINNER[st.frame % #SPINNER + 1] .. " ", "QuillSpinner" },
      { "Generating", "QuillStatus" },
      { ("  %s · %d %s · %d tokens  "):format(st.model, #s.proposed, #s.proposed == 1 and "line" or "lines", st.tokens),
        "QuillMuted" },
    }
    return vim.list_extend(out, key_chips({ { cancel_key(), "cancel" } }))
  end
  if #s.hunks == 0 then
    return vim.list_extend({ { " ○ ", "QuillMuted" }, { "No changes proposed  ", "QuillStatus" } },
      key_chips({ { k.followup, "follow-up" }, { cancel_key(), "close" } }))
  end
  local plus, minus = 0, 0
  for _, h in ipairs(s.hunks) do
    if h.status ~= "rejected" then
      plus, minus = plus + h.b_count, minus + h.a_count
    end
  end
  local out = {
    { " ✓ ", "QuillDone" },
    { "Ready ", "QuillStatus" },
    { "+" .. plus, "QuillPlus" },
    { " ", "QuillMuted" },
    { "−" .. minus, "QuillMinus" },
    { "  ", "QuillMuted" },
  }
  return vim.list_extend(out, key_chips({
    { k.accept_all, "accept all" },
    { k.reject_all, "reject all" },
    { k.next .. "/" .. k.prev, "move" },
    { k.followup, "follow-up" },
    { cancel_key(), "cancel" },
  }))
end

local function inline_hint(s)
  local k = M.config.keys
  return {
    { " " .. k.accept .. " ", "QuillInlineKey" },
    { " accept ", "QuillInlineLabel" },
    { " " .. k.reject .. " ", "QuillInlineKey" },
    { " reject ", "QuillInlineLabel" },
    { (" %d/%d "):format(s.current, #s.hunks), "QuillCounter" },
  }
end

local function redraw(s)
  local start = range(s)
  local win_ok = vim.api.nvim_win_is_valid(s.win)
  local info = win_ok and vim.fn.getwininfo(s.win)[1]
  render.draw({
    bufnr = s.bufnr,
    start_row = start,
    original = s.original,
    proposed = s.proposed,
    hunks = s.hunks,
    current = s.current,
    phase = s.phase,
    flash = s.flash,
    inline_hint = inline_hint(s),
    width = info and info.width or 80,
    textoff = info and info.textoff or 0,
  })
  if s.phase == "streaming" or s.phase == "reviewing" then
    render.status(s, status_chunks(s))
  end
end

local function stop_spinner(s)
  if s.spinner and not s.spinner:is_closing() then
    s.spinner:stop()
    s.spinner:close()
  end
  s.spinner = nil
end

local function start_spinner(s)
  stop_spinner(s)
  s.spinner = vim.uv.new_timer()
  s.spinner:start(80, 80, vim.schedule_wrap(function()
    if s.phase ~= "streaming" then
      return stop_spinner(s)
    end
    s.stats.frame = s.stats.frame + 1
    render.status(s, status_chunks(s))
  end))
end

local function focus_current(s)
  local h = s.hunks[s.current]
  if not h or not vim.api.nvim_win_is_valid(s.win) then
    return
  end
  local start = range(s)
  local row = start + math.max(hunks_mod.first_line(h), 1) - 1
  pcall(vim.api.nvim_win_set_cursor, s.win, { row + 1, 0 })
end

local function unmap(s)
  for _, lhs in ipairs(s.mapped or {}) do
    pcall(vim.keymap.del, "n", lhs, { buffer = s.bufnr })
  end
  s.mapped = {}
end

local function close(s, event)
  if s.job then
    s.job.cancel()
    s.job = nil
  end
  if s.phase ~= "closed" then
    transition(s, event)
  end
  stop_spinner(s)
  unmap(s)
  render.clear(s.bufnr)
  render.close_status(s)
  pcall(vim.api.nvim_buf_del_extmark, s.bufnr, anchor_ns, s.mark)
  sessions[s.bufnr] = nil
end

--- Applies every accepted hunk in a single nvim_buf_set_lines call, so one `u` undoes it.
local function finalize(s)
  local accepted = vim.tbl_filter(function(h)
    return h.status == "accepted"
  end, s.hunks)
  if #accepted > 0 then
    local start, stop = range(s)
    local merged, changed = hunks_mod.merge(s.original, s.proposed, s.hunks)
    vim.api.nvim_buf_set_lines(s.bufnr, start, stop + 1, false, merged)
    render.flash_applied(s.bufnr, vim.tbl_map(function(c)
      return { start + c[1] - 1, start + c[2] - 1 }
    end, changed))
  end
  close(s, "resolve")
end

local function next_pending(s, from, step)
  local n = #s.hunks
  for k = 1, n do
    local i = ((from - 1 + step * k) % n) + 1
    if s.hunks[i].status == "pending" then
      return i
    end
  end
end

local function resolve(s, status, all)
  if s.phase ~= "reviewing" or #s.hunks == 0 then
    return
  end
  local resolved = s.current
  for i, h in ipairs(s.hunks) do
    if h.status == "pending" and (all or i == s.current) then
      h.status = status
    end
  end
  local nxt = next_pending(s, s.current, 1)
  if not nxt then
    return finalize(s)
  end
  s.current = nxt
  if status == "accepted" and not all then
    s.flash = resolved
    vim.defer_fn(function()
      if s.flash == resolved and s.phase == "reviewing" then
        s.flash = nil
        redraw(s)
      end
    end, 260)
  end
  redraw(s)
  focus_current(s)
end

local function move(s, step)
  if s.phase ~= "reviewing" then
    return
  end
  local nxt = next_pending(s, s.current, step)
  if nxt then
    s.current = nxt
    redraw(s)
    focus_current(s)
  end
end

local run_request

local function open_prompt(s)
  local start, stop = range(s)
  local turns = #s.history
  prompt.open({
    win = s.win,
    row = start,
    end_row = stop,
    title = turns == 0 and { { " ✎ Edit ", "QuillTitle" }, { ("lines %d–%d "):format(start + 1, stop + 1), "QuillMuted" } }
      or { { " ↻ Follow-up ", "QuillTitle" }, { ("turn %d "):format(turns + 1), "QuillMuted" } },
    placeholder = turns == 0 and "Describe the change…" or "Refine the proposal…",
    on_submit = function(instruction)
      if s.phase ~= "prompting" then
        return
      end
      s.history[#s.history + 1] = { instruction = instruction }
      transition(s, "submit")
      run_request(s)
    end,
    on_cancel = function()
      if s.phase ~= "prompting" then
        return
      end
      if #s.history == 0 then
        close(s, "cancel")
      else
        transition(s, "dismiss")
        redraw(s)
      end
    end,
  })
end

local function map_session_keys(s)
  local k = M.config.keys
  local actions = {
    [k.accept] = function() resolve(s, "accepted", false) end,
    [k.reject] = function() resolve(s, "rejected", false) end,
    [k.accept_all] = function() resolve(s, "accepted", true) end,
    [k.reject_all] = function() resolve(s, "rejected", true) end,
    [k.next] = function() move(s, 1) end,
    [k.prev] = function() move(s, -1) end,
    [k.followup] = function() M.followup() end,
  }
  for _, lhs in ipairs(type(k.cancel) == "table" and k.cancel or { k.cancel }) do
    actions[lhs] = function() M.cancel() end
  end
  for lhs, fn in pairs(actions) do
    vim.keymap.set("n", lhs, fn, { buffer = s.bufnr, nowait = true, desc = "quill session" })
    s.mapped[#s.mapped + 1] = lhs
  end
end

function run_request(s)
  local name = M.config.provider
  local opts = M.config.providers[name] or {}
  local stream = registry[opts.format or name]
  assert(stream, "quill: unknown provider " .. name)
  s.range = { range(s) }
  local req = context.request(s, M.config)
  s.stats = { model = opts.model or name, tokens = 0, frame = 0, started = vim.uv.hrtime() }
  local prior = { proposed = s.proposed, hunks = s.hunks }
  local buffer = {}
  s.proposed, s.hunks, s.current, s.flash = {}, {}, 1, nil
  redraw(s)
  start_spinner(s)

  local function update(complete)
    s.proposed = output_lines(table.concat(buffer), complete)
    s.hunks = hunks_mod.compute(s.original, s.proposed)
    s.current = math.min(math.max(s.current, 1), math.max(#s.hunks, 1))
    redraw(s)
  end

  s.job = stream(req, opts, {
    on_chunk = function(text)
      if s.phase ~= "streaming" then
        return
      end
      buffer[#buffer + 1] = text
      s.stats.tokens = s.stats.tokens + 1
      if text:find("\n", 1, true) then
        update(false)
      end
    end,
    on_done = function()
      if s.phase ~= "streaming" then
        return
      end
      s.job = nil
      stop_spinner(s)
      s.history[#s.history].output = table.concat(buffer)
      transition(s, "done")
      update(true)
      focus_current(s)
    end,
    on_error = function(err)
      if s.phase ~= "streaming" then
        return
      end
      s.job = nil
      stop_spinner(s)
      vim.notify("quill: " .. err, vim.log.levels.ERROR)
      table.remove(s.history)
      if #s.history == 0 then
        return close(s, "cancel")
      end
      s.proposed, s.hunks, s.current = prior.proposed, prior.hunks, 1
      transition(s, "failed")
      redraw(s)
    end,
  })
end

--- Starts a session on 1-based inclusive lines [line1, line2].
--- With opts.instruction it skips the prompt window (used by tests and scripts).
function M.start(line1, line2, opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  if sessions[bufnr] then
    close(sessions[bufnr], "cancel")
  end
  local last = vim.api.nvim_buf_get_lines(bufnr, line2 - 1, line2, false)[1] or ""
  local s = {
    bufnr = bufnr,
    win = vim.api.nvim_get_current_win(),
    phase = "prompting",
    original = vim.api.nvim_buf_get_lines(bufnr, line1 - 1, line2, false),
    proposed = {},
    hunks = {},
    current = 1,
    history = {},
    mapped = {},
    mark = vim.api.nvim_buf_set_extmark(bufnr, anchor_ns, line1 - 1, 0, {
      end_row = line2 - 1,
      end_col = #last,
      right_gravity = false,
      end_right_gravity = true,
    }),
  }
  sessions[bufnr] = s
  map_session_keys(s)
  if opts.instruction then
    s.history[1] = { instruction = opts.instruction }
    transition(s, "submit")
    run_request(s)
  else
    open_prompt(s)
  end
  return s
end

local function current_session()
  return sessions[vim.api.nvim_get_current_buf()]
end

--- Reopens the prompt (or takes `instruction` directly) to refine the open proposal.
function M.followup(instruction)
  local s = current_session()
  if not s or s.phase ~= "reviewing" then
    return
  end
  transition(s, "followup")
  if instruction then
    s.history[#s.history + 1] = { instruction = instruction }
    transition(s, "submit")
    run_request(s)
  else
    open_prompt(s)
  end
end

function M.cancel()
  local s = current_session()
  if s then
    close(s, "cancel")
  end
end

function M.accept(all) local s = current_session() if s then resolve(s, "accepted", all) end end
function M.reject(all) local s = current_session() if s then resolve(s, "rejected", all) end end
function M.next_hunk() local s = current_session() if s then move(s, 1) end end
function M.prev_hunk() local s = current_session() if s then move(s, -1) end end

--- Read-only snapshot for statuslines and tests.
function M.get_session(bufnr)
  return sessions[bufnr or vim.api.nvim_get_current_buf()]
end

function M.setup(user)
  M.config = vim.tbl_deep_extend("force", M.config, user or {})
  render.define_highlights()
  if M.config.mapping then
    vim.keymap.set("x", M.config.mapping, ":Quill<CR>", { silent = true, desc = "Quill: inline edit" })
  end
end

return M
