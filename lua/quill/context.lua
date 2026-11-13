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

local function diagnostics(bufnr, s, e)
  local out = {}
  for _, d in ipairs(vim.diagnostic.get(bufnr)) do
    if d.lnum >= s and d.lnum <= e then
      local sev = vim.diagnostic.severity[d.severity] or "?"
      out[#out + 1] = ("line %d [%s]: %s"):format(d.lnum - s + 1, sev, d.message)
    end
  end
  return out
end

--- s, e are 0-based inclusive rows of the selection.
function M.first_turn(bufnr, s, e, selection, instruction, opts)
  local n = opts.context_lines
  local before = vim.api.nvim_buf_get_lines(bufnr, math.max(0, s - n), s, false)
  local after = vim.api.nvim_buf_get_lines(bufnr, e + 1, e + 1 + n, false)
  local parts = {
    ("File: %s (filetype: %s)"):format(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t"), vim.bo[bufnr].filetype),
  }
  local node = enclosing_node(bufnr, s, e)
  if node then
    parts[#parts + 1] = "Enclosing syntax node: " .. node
  end
  local diags = diagnostics(bufnr, s, e)
  if #diags > 0 then
    parts[#parts + 1] = "Diagnostics in selection:\n" .. table.concat(diags, "\n")
  end
  parts[#parts + 1] = "Code before selection:\n" .. table.concat(before, "\n")
  parts[#parts + 1] = "<selection>\n" .. table.concat(selection, "\n") .. "\n</selection>"
  parts[#parts + 1] = "Code after selection:\n" .. table.concat(after, "\n")
  parts[#parts + 1] = "Instruction: " .. instruction
  return table.concat(parts, "\n\n")
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
