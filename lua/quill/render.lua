-- Draws a session's preview with extmarks only; never touches buffer text.
local hunks = require("quill.hunks")

local M = {}
M.ns = vim.api.nvim_create_namespace("quill_preview")
local flash_ns = vim.api.nvim_create_namespace("quill_flash")
local float_ns = vim.api.nvim_create_namespace("quill_float")

local function pad(text, width)
  local w = vim.fn.strdisplaywidth(text)
  return w < width and text .. string.rep(" ", width - w) or text
end

--- Chunks for one added line: soft line background, stronger on changed words.
local function added_chunks(line, ranges, base, strong, width, tabstop)
  local chunks, pos = {}, 0
  local function push(text, hl)
    if text ~= "" then
      chunks[#chunks + 1] = { (text:gsub("\t", string.rep(" ", tabstop))), hl }
    end
  end
  for _, r in ipairs(ranges or {}) do
    push(line:sub(pos + 1, r[1]), base)
    push(line:sub(r[1] + 1, r[2]), strong)
    pos = r[2]
  end
  push(line:sub(pos + 1), base)
  local used = 0
  for _, c in ipairs(chunks) do
    used = used + vim.fn.strdisplaywidth(c[1])
  end
  chunks[#chunks + 1] = { string.rep(" ", math.max(0, width - used)), base }
  return chunks
end

--- The visual role of a hunk decides every highlight it uses.
local styles = {
  current = { del = "QuillDelete", del_text = "QuillDeleteText", add = "QuillAdd", add_text = "QuillAddText",
    sign_del = "QuillSignDelete", sign_add = "QuillSignAdd", glyph = "┃" },
  other = { del = "QuillDeleteDim", del_text = "QuillDeleteDim", add = "QuillAddDim", add_text = "QuillAddDim",
    sign_del = "QuillSignDim", sign_add = "QuillSignDim", glyph = "│" },
  accepted = { del = "QuillDeleteAccepted", del_text = "QuillDeleteAccepted", add = "QuillAdd", add_text = "QuillAdd",
    sign_del = "QuillSignAccepted", sign_add = "QuillSignAccepted", glyph = "✓" },
  flash = { del = "QuillDeleteAccepted", del_text = "QuillDeleteAccepted", add = "QuillFlash", add_text = "QuillFlash",
    sign_del = "QuillSignAccepted", sign_add = "QuillSignAccepted", glyph = "✓" },
  streaming = { del = "QuillDelete", del_text = "QuillDeleteText", add = "QuillAdd", add_text = "QuillAddText",
    sign_del = "QuillSignDelete", sign_add = "QuillSignAdd", glyph = "┃" },
}

local function role(i, h, view)
  if h.status == "accepted" then
    return view.flash == i and "flash" or "accepted"
  end
  if view.phase == "streaming" then
    return "streaming"
  end
  return i == view.current and "current" or "other"
end

local function draw_hunk(s, i, h, view)
  if h.status == "rejected" then
    return
  end
  local buf, first = view.bufnr, hunks.first_line(h)
  local style = styles[role(i, h, view)]
  local tail = view.phase == "streaming" and first + h.a_count - 1 == #view.original
  local added = hunks.added_lines(h, view.proposed)
  local hint = view.phase == "reviewing" and i == view.current and h.status == "pending" and view.inline_hint or nil

  for k = 0, h.a_count - 1 do
    local row = s + first - 1 + k
    -- A full-row hl_group (not line_hl_group) so the word highlights below can paint over it.
    local text = view.original[first + k] or ""
    vim.api.nvim_buf_set_extmark(buf, M.ns, row, 0, {
      end_row = row,
      end_col = #text,
      hl_eol = true,
      hl_group = tail and "QuillPending" or style.del,
      sign_text = not tail and style.glyph or nil,
      sign_hl_group = style.sign_del,
      virt_text = k == 0 and hint or nil,
      virt_text_pos = "right_align",
      priority = 200,
    })
    local pair = not tail and added[k + 1] and hunks.inline(view.original[first + k], added[k + 1])
    for _, r in ipairs(pair and pair.old or {}) do
      vim.api.nvim_buf_set_extmark(buf, M.ns, row, r[1], { end_col = r[2], hl_group = style.del_text, priority = 210 })
    end
  end
  if #added == 0 then
    return
  end

  local gutter = { { style.glyph, style.sign_add }, { string.rep(" ", math.max(0, view.textoff - 1)), "QuillGutter" } }
  local virt = {}
  for k, line in ipairs(added) do
    local pair = k <= h.a_count and hunks.inline(view.original[first + k - 1], line)
    local chunks = vim.list_extend(vim.deepcopy(gutter),
      added_chunks(line, pair and pair.new, style.add, style.add_text, view.width - view.textoff, vim.bo[buf].tabstop))
    virt[#virt + 1] = chunks
  end
  local row, above
  if h.a_count > 0 then
    row = s + first - 1 + h.a_count - 1
  elseif h.a_start > 0 then
    row = s + h.a_start - 1
  else
    row, above = s, true
  end
  vim.api.nvim_buf_set_extmark(buf, M.ns, row, 0, {
    virt_lines = virt,
    virt_lines_above = above,
    virt_lines_leftcol = true,
    virt_text = h.a_count == 0 and hint or nil,
    virt_text_pos = "right_align",
  })
end

--- view = { bufnr, start_row, original, proposed, hunks, current, phase, width, textoff, inline_hint, flash }
function M.draw(view)
  vim.api.nvim_buf_clear_namespace(view.bufnr, M.ns, 0, -1)
  for i, h in ipairs(view.hunks) do
    draw_hunk(view.start_row, i, h, view)
  end
end

function M.clear(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  end
end

--- Briefly highlights rows that were just written, so the applied change is visible.
--- spans: 0-based inclusive {first, last} rows.
function M.flash_applied(bufnr, spans)
  for _, span in ipairs(spans) do
    for row = span[1], span[2] do
      vim.api.nvim_buf_set_extmark(bufnr, flash_ns, row, 0, { line_hl_group = "QuillFlash", priority = 220 })
    end
  end
  vim.defer_fn(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, flash_ns, 0, -1)
    end
  end, 450)
end

local function color(name, attr)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  return ok and hl[attr] or nil
end

local function blend(fg, bg, alpha)
  local function ch(c, shift)
    return bit.band(bit.rshift(c, shift), 0xff)
  end
  local out = 0
  for _, shift in ipairs({ 16, 8, 0 }) do
    local v = math.floor(ch(fg, shift) * alpha + ch(bg, shift) * (1 - alpha) + 0.5)
    out = out + bit.lshift(v, shift)
  end
  return out
end

--- Diff backgrounds are mixed from the colorscheme's own error/ok colors over its
--- Normal background, so they match any theme. Everything else links to standard groups.
function M.define_highlights()
  local dark = vim.o.background == "dark"
  local bg = color("Normal", "bg") or (dark and 0x1a1b26 or 0xffffff)
  local fg = color("Normal", "fg") or (dark and 0xc0caf5 or 0x1a1b26)
  local red = color("DiagnosticError", "fg") or color("DiffDelete", "fg") or 0xf7768e
  local green = color("DiagnosticOk", "fg") or color("String", "fg") or 0x9ece6a
  local accent = color("DiagnosticInfo", "fg") or color("Function", "fg") or 0x7aa2f7
  local muted = color("Comment", "fg") or blend(fg, bg, 0.5)
  local float_bg = color("NormalFloat", "bg") or bg
  local groups = {
    QuillDelete = { bg = blend(red, bg, 0.16) },
    QuillDeleteText = { bg = blend(red, bg, 0.38) },
    QuillDeleteDim = { bg = blend(red, bg, 0.07) },
    QuillDeleteAccepted = { fg = muted, bg = blend(red, bg, 0.05), strikethrough = true },
    QuillAdd = { bg = blend(green, bg, 0.14) },
    QuillAddText = { bg = blend(green, bg, 0.34) },
    QuillAddDim = { bg = blend(green, bg, 0.06) },
    QuillFlash = { bg = blend(green, bg, 0.42) },
    QuillPending = { fg = muted, italic = true },
    QuillGutter = { link = "LineNr" },
    QuillSignDelete = { fg = red },
    QuillSignAdd = { fg = green },
    QuillSignDim = { fg = blend(muted, bg, 0.7) },
    QuillSignAccepted = { fg = green, bold = true },
    QuillKey = { fg = float_bg, bg = accent, bold = true },
    QuillKeyLabel = { fg = muted, bg = float_bg },
    QuillInlineKey = { fg = bg, bg = accent, bold = true },
    QuillInlineLabel = { fg = fg, bg = blend(accent, bg, 0.16) },
    QuillCounter = { fg = accent, bg = blend(accent, bg, 0.16), bold = true },
    QuillStatus = { fg = fg, bg = float_bg, bold = true },
    QuillMuted = { fg = muted, bg = float_bg },
    QuillSpinner = { fg = accent, bg = float_bg, bold = true },
    QuillDone = { fg = green, bg = float_bg, bold = true },
    QuillPlus = { fg = green, bg = float_bg },
    QuillMinus = { fg = red, bg = float_bg },
    QuillPlaceholder = { link = "Comment" },
    QuillPromptIcon = { fg = accent, bold = true },
    QuillFloat = { link = "NormalFloat" },
    QuillBorder = { link = "FloatBorder" },
    QuillTitle = { fg = accent, bg = color("FloatBorder", "bg") or float_bg, bold = true },
  }
  if not vim.o.termguicolors then
    for name, target in pairs({ QuillDelete = "DiffDelete", QuillDeleteText = "DiffText", QuillDeleteDim = "DiffDelete",
      QuillAdd = "DiffAdd", QuillAddText = "DiffText", QuillAddDim = "DiffAdd", QuillFlash = "DiffText" }) do
      groups[name] = { link = target }
    end
  end
  for name, spec in pairs(groups) do
    spec.default = true
    vim.api.nvim_set_hl(0, name, spec)
  end
end

vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("quill_highlights", { clear = true }),
  callback = function()
    M.define_highlights()
  end,
})

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

function M.spinner(frame)
  return SPINNER[frame % #SPINNER + 1]
end

--- { {key, label}... } -> chunks drawn as key chips.
function M.key_chips(pairs_list)
  local chunks = {}
  for _, p in ipairs(pairs_list) do
    chunks[#chunks + 1] = { " " .. p[1] .. " ", "QuillKey" }
    chunks[#chunks + 1] = { " " .. p[2] .. " ", "QuillKeyLabel" }
  end
  return chunks
end

--- Writes `chunks` ({text, hl} pairs) as one line of `buf` and returns its display width.
function M.set_chunks(buf, chunks)
  local text, marks = "", {}
  for _, c in ipairs(chunks) do
    marks[#marks + 1] = { #text, #text + #c[1], c[2] }
    text = text .. c[1]
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
  vim.api.nvim_buf_clear_namespace(buf, float_ns, 0, -1)
  for _, m in ipairs(marks) do
    if m[3] then
      vim.api.nvim_buf_set_extmark(buf, float_ns, 0, m[1], { end_col = m[2], hl_group = m[3] })
    end
  end
  return vim.fn.strdisplaywidth(text)
end

--- Non-focusable status float in the window's bottom-right corner.
function M.status(state, chunks)
  if not vim.api.nvim_win_is_valid(state.win) then
    return
  end
  if not (state.hint_win and vim.api.nvim_win_is_valid(state.hint_win)) then
    state.hint_buf = vim.api.nvim_create_buf(false, true)
    state.hint_win = vim.api.nvim_open_win(state.hint_buf, false, {
      relative = "win",
      win = state.win,
      anchor = "SE",
      row = vim.api.nvim_win_get_height(state.win) - 1,
      col = vim.api.nvim_win_get_width(state.win) - 1,
      width = 1,
      height = 1,
      style = "minimal",
      border = "rounded",
      focusable = false,
      zindex = 60,
    })
    vim.wo[state.hint_win].winhighlight = "NormalFloat:QuillFloat,FloatBorder:QuillBorder"
  end
  vim.api.nvim_win_set_width(state.hint_win, M.set_chunks(state.hint_buf, chunks))
end

function M.close_status(state)
  if state.hint_win and vim.api.nvim_win_is_valid(state.hint_win) then
    vim.api.nvim_win_close(state.hint_win, true)
  end
  state.hint_win = nil
end

return M
