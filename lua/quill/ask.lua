-- Cursor-anchored ask box: question, spinner, then the answer in the same window.
-- The box never writes the source buffer. Providers stream into a hidden buffer;
-- the UI waits, then morphs to the full answer (no token-by-token text).
local context = require("quill.context")
local render = require("quill.render")
local registry = require("quill.providers")

local M = {}
M.ns = vim.api.nvim_create_namespace("quill_ask")
local box_ns = vim.api.nvim_create_namespace("quill_ask_box")

local WIDTH = 46
local MAX_LINES = 8

local current

local function config()
  return require("quill").config
end

local function keys_of(value)
  if value == nil then
    return {}
  end
  return type(value) == "table" and value or { value }
end

local function first_key(value)
  return keys_of(value)[1]
end

local function key_label(value)
  local fallback = ""
  for _, lhs in ipairs(keys_of(value)) do
    local label = lhs:gsub("[<>]", ""):lower()
    if #label == 1 then
      return label
    end
    if fallback == "" then
      fallback = label
    end
  end
  return fallback
end

-- Same opt-out as the edit prompt; the filetype is documented in :h quill-commands.
local function disable_completion(buf)
  vim.bo[buf].filetype = "quill_prompt"
  vim.bo[buf].complete = ""
  if vim.fn.exists("+autocomplete") == 1 then
    vim.bo[buf].autocomplete = false
  end
  vim.b[buf].completion = false
  vim.b[buf].minicompletion_disable = true
  local cmp = package.loaded.cmp
  if cmp and cmp.setup and cmp.setup.buffer then
    vim.api.nvim_buf_call(buf, function()
      cmp.setup.buffer({ enabled = false })
    end)
  end
end

local function wrap_line(line, width)
  local out, cur = {}, ""
  local function flush()
    if cur ~= "" then
      out[#out + 1] = cur
      cur = ""
    end
  end
  local function push(word)
    if word == "" then
      return
    end
    if cur == "" then
      if vim.fn.strdisplaywidth(word) <= width then
        cur = word
        return
      end
      -- A single token wider than the box is split so the cap stays honest.
      local i = 1
      while i <= #word do
        local chunk = ""
        while i <= #word do
          local next_chunk = chunk .. word:sub(i, i)
          if chunk ~= "" and vim.fn.strdisplaywidth(next_chunk) > width then
            break
          end
          chunk = next_chunk
          i = i + 1
        end
        out[#out + 1] = chunk
      end
      return
    end
    if vim.fn.strdisplaywidth(cur .. " " .. word) <= width then
      cur = cur .. " " .. word
    else
      flush()
      push(word)
    end
  end
  -- Keep `backtick spans` whole so wrapping cannot split them and leak ticks.
  local i = 1
  while i <= #line do
    local a, b = line:find("`[^`]+`", i)
    if not a then
      for word in line:sub(i):gmatch("%S+") do
        push(word)
      end
      break
    end
    for word in line:sub(i, a - 1):gmatch("%S+") do
      push(word)
    end
    push(line:sub(a, b))
    i = b + 1
  end
  flush()
  return #out > 0 and out or { "" }
end

--- Drop fences and emphasis so the box shows prose; backticks stay for highlighting.
local function prepare(text)
  text = text:gsub("```%w*%s*\n", ""):gsub("```%w*", ""):gsub("```", "")
  text = text:gsub("%*%*(.-)%*%*", "%1"):gsub("__(.-)__", "%1")
  return text
end

local function wrap_text(text, width)
  local lines = {}
  for para in (text .. "\n"):gmatch("(.-)\n") do
    if para == "" then
      if #lines > 0 then
        lines[#lines + 1] = ""
      end
    else
      vim.list_extend(lines, wrap_line(para, width))
    end
  end
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  return lines
end

-- Remove backticks from a line and return byte ranges of the inner spans.
local function strip_ticks(line)
  local marks, out, i = {}, "", 1
  while i <= #line do
    local a, b, inner = line:find("`([^`]+)`", i)
    if not a then
      out = out .. line:sub(i)
      break
    end
    out = out .. line:sub(i, a - 1)
    local start = #out
    out = out .. inner
    marks[#marks + 1] = { start, #out, inner }
    i = b + 1
  end
  return out, marks
end

local function layout(text, width, expanded)
  local wrapped = wrap_text(prepare(text), width)
  local truncated = not expanded and #wrapped > MAX_LINES
  local src = wrapped
  if truncated then
    src = vim.list_slice(wrapped, 1, MAX_LINES - 1)
  end
  local lines, refs = {}, {}
  for i, line in ipairs(src) do
    local shown, marks = strip_ticks(line)
    lines[i] = shown
    for _, m in ipairs(marks) do
      refs[#refs + 1] = { row = i - 1, col = m[1], end_col = m[2] }
    end
  end
  if truncated then
    lines[#lines + 1] = "… " .. (#wrapped - (MAX_LINES - 1)) .. " more"
  end
  if #lines == 0 then
    lines[1] = ""
  end
  return lines, refs, truncated
end

local function mentions(text)
  local codes = {}
  for code in prepare(text):gmatch("`([^`]+)`") do
    if code:match("%S") then
      codes[#codes + 1] = code
    end
  end
  local lines = {}
  for a, b in prepare(text):gmatch("[Ll]ines?%s+(%d+)%s*%-?%s*(%d*)") do
    local s, e = tonumber(a), tonumber(b)
    lines[#lines + 1] = { s, e or s }
  end
  return codes, lines
end

local function highlight_buffer(a)
  if not vim.api.nvim_buf_is_valid(a.bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(a.bufnr, M.ns, 0, -1)
  if not a.answer then
    return
  end
  local s, e = a.scope[1], a.scope[2]
  local codes, line_refs = mentions(a.answer)
  local rows = vim.api.nvim_buf_get_lines(a.bufnr, s, e + 1, false)
  for _, code in ipairs(codes) do
    for i, line in ipairs(rows) do
      local col = 1
      while true do
        local from, to = line:find(code, col, true)
        if not from then
          break
        end
        vim.api.nvim_buf_set_extmark(a.bufnr, M.ns, s + i - 1, from - 1, {
          end_col = to,
          hl_group = "QuillAskBuf",
        })
        col = to + 1
      end
    end
  end
  local last = vim.api.nvim_buf_line_count(a.bufnr)
  for _, r in ipairs(line_refs) do
    for lnum = r[1], r[2] do
      local row = lnum - 1
      if row >= s and row <= e and row < last then
        local line = vim.api.nvim_buf_get_lines(a.bufnr, row, row + 1, false)[1] or ""
        vim.api.nvim_buf_set_extmark(a.bufnr, M.ns, row, 0, {
          end_col = #line,
          hl_group = "QuillAskBuf",
        })
      end
    end
  end
end

local function footer_chunks(pairs_list)
  local chunks = {}
  for i, p in ipairs(pairs_list) do
    if i > 1 then
      chunks[#chunks + 1] = { " ", "QuillBorder" }
    end
    chunks[#chunks + 1] = { " " .. p[1] .. " ", "QuillAskKey" }
    chunks[#chunks + 1] = { " " .. p[2] .. " ", "QuillAskLabel" }
  end
  return chunks
end

local function stop_spinner(a)
  if a.spinner and not a.spinner:is_closing() then
    a.spinner:stop()
    a.spinner:close()
  end
  a.spinner = nil
end

local function unmap(a)
  if not a.mapped or not vim.api.nvim_buf_is_valid(a.bufnr) then
    a.mapped = {}
    return
  end
  for _, lhs in ipairs(a.mapped) do
    pcall(vim.keymap.del, "n", lhs, { buffer = a.bufnr })
  end
  a.mapped = {}
end

local function close(a)
  if a.phase == "closed" then
    return
  end
  a.phase = "closed"
  stop_spinner(a)
  if a.job and a.job.cancel then
    a.job.cancel()
  end
  a.job = nil
  unmap(a)
  if a.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, a.augroup)
    a.augroup = nil
  end
  if vim.api.nvim_buf_is_valid(a.bufnr) then
    vim.api.nvim_buf_clear_namespace(a.bufnr, M.ns, 0, -1)
  end
  if a.box_win and vim.api.nvim_win_is_valid(a.box_win) then
    pcall(vim.api.nvim_win_close, a.box_win, true)
  end
  a.box_win, a.box_buf = nil, nil
  if current == a then
    current = nil
  end
end

local function box_opts(a, height, footer)
  local w0 = vim.fn.line("w0", a.win)
  local wlast = vim.fn.line("w$", a.win)
  local below = wlast - (a.row + 1)
  local above = (a.row + 1) - w0
  local put_below = below >= height + 1 or below >= above
  return {
    relative = "win",
    win = a.win,
    bufpos = { a.row, 0 },
    anchor = put_below and "NW" or "SW",
    row = put_below and 1 or 0,
    col = 0,
    width = a.width,
    height = height,
    style = "minimal",
    border = "rounded",
    footer = footer or "",
    footer_pos = "right",
    zindex = 70,
    focusable = a.phase == "prompting",
  }
end

local function set_box(a, lines, marks, footer)
  if not (a.box_buf and vim.api.nvim_buf_is_valid(a.box_buf) and a.box_win and vim.api.nvim_win_is_valid(a.box_win)) then
    return
  end
  vim.bo[a.box_buf].modifiable = true
  vim.api.nvim_buf_set_lines(a.box_buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(a.box_buf, box_ns, 0, -1)
  for _, m in ipairs(marks or {}) do
    vim.api.nvim_buf_set_extmark(a.box_buf, box_ns, m.row, m.col, {
      end_col = m.end_col,
      hl_group = m.hl or "QuillAskRef",
    })
  end
  if a.phase ~= "prompting" then
    vim.bo[a.box_buf].modifiable = false
  end
  pcall(vim.api.nvim_win_set_config, a.box_win, box_opts(a, math.max(#lines, 1), footer))
end

local function decorate_prompt(a)
  if not (a.box_buf and vim.api.nvim_buf_is_valid(a.box_buf)) then
    return
  end
  vim.api.nvim_buf_clear_namespace(a.box_buf, box_ns, 0, -1)
  local empty = (vim.api.nvim_buf_get_lines(a.box_buf, 0, 1, false)[1] or "") == ""
  if empty then
    vim.api.nvim_buf_set_extmark(a.box_buf, box_ns, 0, 0, {
      virt_text = { { "Ask about this code", "QuillPlaceholder" } },
      virt_text_pos = "overlay",
    })
  end
end

local function paint(a)
  if a.phase == "prompting" then
    decorate_prompt(a)
    pcall(vim.api.nvim_win_set_config, a.box_win, box_opts(a, 1, footer_chunks({
      { "⏎", "submit" },
      { "esc", "cancel" },
    })))
    return
  end
  if a.phase == "waiting" then
    local spin = render.spinner(a.frame)
    set_box(a, { " " .. spin }, { { row = 0, col = 1, end_col = 1 + #spin, hl = "QuillAskKey" } }, "")
    return
  end
  if a.phase == "answered" then
    local k = config().keys
    local lines, refs, truncated = layout(a.answer or "", a.width - 1, a.expanded)
    a.truncated = truncated
    local pairs_list = {}
    if truncated then
      pairs_list[#pairs_list + 1] = { key_label(k.expand), "expand" }
    end
    pairs_list[#pairs_list + 1] = { key_label(k.edit), "edit" }
    pairs_list[#pairs_list + 1] = { key_label(k.cancel), "close" }
    set_box(a, lines, refs, footer_chunks(pairs_list))
    highlight_buffer(a)
  end
  pcall(vim.cmd.redrawstatus)
end

local function focus_source(a)
  if a.win and vim.api.nvim_win_is_valid(a.win) then
    vim.api.nvim_set_current_win(a.win)
  end
end

local function to_edit(a)
  local s, e, bufnr, win = a.scope[1], a.scope[2], a.bufnr, a.win
  local instruction = ("Question: %s\n\nAnswer:\n%s"):format(a.question, a.answer or "")
  close(a)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
  end
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_get_current_buf() ~= bufnr then
    vim.api.nvim_win_set_buf(0, bufnr)
  end
  require("quill").start(s + 1, e + 1, { instruction = instruction })
end

local function map_keys(a)
  unmap(a)
  if not vim.api.nvim_buf_is_valid(a.bufnr) then
    return
  end
  local k = config().keys
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = a.bufnr, nowait = true, desc = "quill ask" })
    a.mapped[#a.mapped + 1] = lhs
  end
  for _, lhs in ipairs(keys_of(k.cancel)) do
    map(lhs, function()
      close(a)
    end)
  end
  if a.phase == "answered" then
    for _, lhs in ipairs(keys_of(k.edit)) do
      map(lhs, function()
        to_edit(a)
      end)
    end
    if a.truncated then
      for _, lhs in ipairs(keys_of(k.expand)) do
        map(lhs, function()
          a.expanded = true
          paint(a)
          map_keys(a)
        end)
      end
    end
  end
end

local function start_spinner(a)
  stop_spinner(a)
  a.spinner = vim.uv.new_timer()
  a.spinner:start(80, 80, vim.schedule_wrap(function()
    if a.phase ~= "waiting" then
      return stop_spinner(a)
    end
    a.frame = a.frame + 1
    paint(a)
  end))
end

local function run(a, question)
  a.question = question
  a.answer, a.expanded, a.truncated = nil, false, false
  a.phase = "waiting"
  a.frame = 0
  vim.cmd.stopinsert()
  focus_source(a)
  paint(a)
  map_keys(a)
  start_spinner(a)

  local cfg = config()
  local name = cfg.provider
  local opts = cfg.providers[name] or {}
  local stream = registry[opts.format or name]
  if not stream then
    vim.notify("quill: unknown provider " .. name, vim.log.levels.ERROR)
    return close(a)
  end
  local req = context.ask_request({
    bufnr = a.bufnr,
    row = a.row,
    scope = a.scope,
    question = question,
  })
  local buffer = {}
  a.job = stream(req, opts, {
    on_chunk = function(text)
      if a.phase ~= "waiting" then
        return
      end
      buffer[#buffer + 1] = text
    end,
    on_done = function()
      if a.phase ~= "waiting" then
        return
      end
      a.job = nil
      stop_spinner(a)
      a.answer = table.concat(buffer)
      a.phase = "answered"
      paint(a)
      map_keys(a)
    end,
    on_error = function(err)
      if a.phase ~= "waiting" then
        return
      end
      a.job = nil
      stop_spinner(a)
      vim.notify("quill: " .. err, vim.log.levels.ERROR)
      close(a)
    end,
  })
end

local function bind_prompt(a)
  local function submit()
    if a.phase ~= "prompting" then
      return
    end
    local text = vim.trim(vim.api.nvim_buf_get_lines(a.box_buf, 0, 1, false)[1] or "")
    if text == "" then
      return
    end
    run(a, text)
  end
  local function cancel()
    close(a)
  end
  local map = function(modes, lhs, fn)
    vim.keymap.set(modes, lhs, fn, { buffer = a.box_buf, nowait = true })
  end
  map({ "i", "n" }, "<CR>", submit)
  map({ "i", "n" }, "<Esc>", cancel)
  map("n", "q", cancel)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = a.augroup,
    buffer = a.box_buf,
    callback = function()
      if a.phase == "prompting" then
        decorate_prompt(a)
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = a.augroup,
    pattern = tostring(a.box_win),
    callback = function()
      close(a)
    end,
  })
end

local function watch_source(a)
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = a.augroup,
    buffer = a.bufnr,
    callback = function()
      if current ~= a or a.phase == "prompting" or a.phase == "closed" then
        return
      end
      local win = vim.api.nvim_get_current_win()
      if a.box_win and win == a.box_win then
        return
      end
      if win ~= a.win then
        close(a)
        return
      end
      local row = vim.api.nvim_win_get_cursor(a.win)[1] - 1
      if row < a.scope[1] or row > a.scope[2] then
        close(a)
      end
    end,
  })
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = a.augroup,
    buffer = a.bufnr,
    callback = function()
      if current == a and a.phase ~= "prompting" and a.phase ~= "closed" then
        close(a)
      end
    end,
  })
end

function M.get()
  return current
end

function M.cancel()
  if current then
    close(current)
  end
end

--- Open the ask box on the cursor line. A non-empty `question` skips the prompt.
function M.open(question)
  M.cancel()
  local bufnr = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  local row = vim.api.nvim_win_get_cursor(win)[1] - 1
  local cfg = config()
  local s, e, is_fn = context.scope(bufnr, row, cfg.context_lines)
  local width = math.max(20, math.min(WIDTH, vim.api.nvim_win_get_width(win) - 4))
  local a = {
    bufnr = bufnr,
    win = win,
    row = row,
    scope = { s, e, is_fn },
    phase = "prompting",
    width = width,
    mapped = {},
    frame = 0,
  }
  current = a
  a.box_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[a.box_buf].bufhidden = "wipe"
  disable_completion(a.box_buf)
  a.box_win = vim.api.nvim_open_win(a.box_buf, question and question:match("%S") and false or true, box_opts(a, 1, ""))
  vim.wo[a.box_win].winhighlight = "NormalFloat:QuillFloat,FloatBorder:QuillBorder,FloatFooter:QuillMuted"
  vim.wo[a.box_win].wrap = false
  a.augroup = vim.api.nvim_create_augroup("quill_ask_" .. a.box_buf, { clear = true })
  bind_prompt(a)
  watch_source(a)
  if question and question:match("%S") then
    run(a, vim.trim(question))
  else
    paint(a)
    vim.cmd.startinsert()
  end
  return a
end

return M
