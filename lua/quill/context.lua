-- Builds the provider request for a session: system prompt plus a chat history
-- whose first turn carries the selection and its surroundings.
local M = {}

M.system = table.concat({
  "You rewrite a selected region of a source file according to an instruction.",
  "Reply with ONLY the full replacement text for the selected region.",
  "No explanations and no markdown fences. Preserve indentation style.",
}, " ")

local function enclosing_node(bufnr, s, e)
  local has_parser, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not has_parser or not parser then
    return nil
  end
  parser:parse()
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { s, 0 }, ignore_injections = false })
  if not ok or not node then
    return nil
  end
  while node do
    local ns, _, ne = node:range()
    if ns <= s and ne >= e and node:parent() then
      return ("%s (lines %d-%d)"):format(node:type(), ns + 1, ne + 1)
    end
    node = node:parent()
  end
end

--- Diagnostics on rows s..e, numbered from `base` (a 0-based row that becomes line 1).
local function diagnostics(bufnr, s, e, base)
  local out = {}
  for _, d in ipairs(vim.diagnostic.get(bufnr)) do
    if d.lnum >= s and d.lnum <= e then
      local sev = vim.diagnostic.severity[d.severity] or "?"
      out[#out + 1] = ("line %d [%s]: %s"):format(d.lnum - base + 1, sev, d.message)
    end
  end
  return out
end

local function file_line(bufnr)
  return ("File: %s (filetype: %s)"):format(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t"), vim.bo[bufnr].filetype)
end

--- s, e are 0-based inclusive rows of the selection.
function M.first_turn(bufnr, s, e, selection, instruction, opts)
  local n = opts.context_lines
  local before = vim.api.nvim_buf_get_lines(bufnr, math.max(0, s - n), s, false)
  local after = vim.api.nvim_buf_get_lines(bufnr, e + 1, e + 1 + n, false)
  local parts = { file_line(bufnr) }
  local node = enclosing_node(bufnr, s, e)
  if node then
    parts[#parts + 1] = "Enclosing syntax node: " .. node
  end
  local diags = diagnostics(bufnr, s, e, s)
  if #diags > 0 then
    parts[#parts + 1] = "Diagnostics in selection:\n" .. table.concat(diags, "\n")
  end
  parts[#parts + 1] = "Code before selection:\n" .. table.concat(before, "\n")
  parts[#parts + 1] = "<selection>\n" .. table.concat(selection, "\n") .. "\n</selection>"
  parts[#parts + 1] = "Code after selection:\n" .. table.concat(after, "\n")
  parts[#parts + 1] = "Instruction: " .. instruction
  return table.concat(parts, "\n\n")
end

M.ask_system = table.concat({
  "You answer questions about code open in the user's editor.",
  "Answer in 1-3 short sentences specific to the code shown. No headings, no lists, no preamble.",
  "Use backticks for identifiers and quoted expressions.",
  "When you refer to a specific line, write 'line N' using the file's line numbers.",
}, " ")

-- Node types that are functions in common grammars (function_declaration, method_definition,
-- arrow_function, function_item, func_literal...), minus the call and name nodes that share words.
local function is_function(t)
  return (t:find("function") or t:find("method") or t:find("func_literal") or t == "lambda")
    and not (t:find("call") or t:find("name") or t:find("index") or t:find("parameter") or t:find("signature"))
end

--- 0-based inclusive rows of the function around `row`, or `row` +-n when there is none.
--- Returns s, e, is_function.
function M.scope(bufnr, row, n)
  local has_parser, parser = pcall(vim.treesitter.get_parser, bufnr)
  if has_parser and parser then
    parser:parse()
    local col = #(vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""):match("^%s*")
    local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row, col } })
    while ok and node do
      if is_function(node:type()) then
        local s, _, e, ecol = node:range()
        return s, ecol == 0 and e > s and e - 1 or e, true
      end
      node = node:parent()
    end
  end
  return math.max(0, row - n), math.min(vim.api.nvim_buf_line_count(bufnr) - 1, row + n), false
end

--- ask = { bufnr, row, scope = {s, e, is_function}, question }
function M.ask_request(ask)
  local bufnr, row = ask.bufnr, ask.row
  local s, e, is_fn = unpack(ask.scope)
  local code = vim.api.nvim_buf_get_lines(bufnr, s, e + 1, false)
  local parts = {
    file_line(bufnr),
    ("Cursor on line %d: %s"):format(row + 1, vim.trim(vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or "")),
  }
  local diags = diagnostics(bufnr, s, e, 0)
  if #diags > 0 then
    parts[#parts + 1] = "Diagnostics:\n" .. table.concat(diags, "\n")
  end
  parts[#parts + 1] = ("%s (lines %d-%d):\n```%s\n%s\n```"):format(
    is_fn and "Enclosing function" or "Code around the cursor",
    s + 1, e + 1, vim.bo[bufnr].filetype, table.concat(code, "\n"))
  parts[#parts + 1] = "Question: " .. ask.question
  return {
    mode = "ask",
    system = M.ask_system,
    messages = { { role = "user", content = table.concat(parts, "\n\n") } },
    instruction = ask.question,
    selection = code,
  }
end

--- history: { {instruction, output}... }; the last entry has no output yet.
function M.request(session, opts)
  local messages = {}
  for i, turn in ipairs(session.history) do
    local content = i == 1
        and M.first_turn(session.bufnr, session.range[1], session.range[2], session.original, turn.instruction, opts)
      or ("Refine your previous rewrite. Instruction: %s"):format(turn.instruction)
    messages[#messages + 1] = { role = "user", content = content }
    if turn.output then
      messages[#messages + 1] = { role = "assistant", content = turn.output }
    end
  end
  return {
    system = M.system,
    messages = messages,
    instruction = session.history[#session.history].instruction,
    selection = session.original,
    history = session.history,
  }
end

return M
