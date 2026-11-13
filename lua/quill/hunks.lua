-- Pure line-diff model. A hunk is relative to the edited range (1-based).
-- For a pure insertion (a_count == 0) vim.diff reports a_start as the line
-- the new text goes after, so `first_line` normalizes it.
local M = {}

local diff = (vim.text and vim.text.diff) or vim.diff

local function join(lines)
  if #lines == 0 then
    return ""
  end
  return table.concat(lines, "\n") .. "\n"
end

---@class QuillHunk
---@field a_start integer
---@field a_count integer
---@field b_start integer
---@field b_count integer
---@field status "pending"|"accepted"|"rejected"

---@return QuillHunk[]
function M.compute(original, proposed)
  local indices = diff(join(original), join(proposed), { result_type = "indices", algorithm = "histogram" })
  local hunks = {}
  for _, h in ipairs(indices) do
    hunks[#hunks + 1] = { a_start = h[1], a_count = h[2], b_start = h[3], b_count = h[4], status = "pending" }
  end
  return hunks
end

function M.first_line(h)
  return h.a_count == 0 and h.a_start + 1 or h.a_start
end

function M.added_lines(h, proposed)
  return vim.list_slice(proposed, h.b_start, h.b_start + h.b_count - 1)
end

local function tokens(line)
  local out, pos = {}, 1
  while pos <= #line do
    local s, e = line:find("^[%w_]+", pos)
    if not s then
      s, e = line:find("^%s+", pos)
    end
    if not s then
      s, e = pos, pos + #(line:sub(pos):match("^[%z\1-\127\194-\244][\128-\191]*")) - 1
    end
    out[#out + 1] = { text = line:sub(s, e), s = s - 1, e = e }
    pos = e + 1
  end
  return out
end

local function spans(toks, start, count)
  if count == 0 then
    return nil
  end
  return { toks[start].s, toks[start + count - 1].e }
end

--- Word-level diff of one changed line pair. Returns 0-based [start, end) byte
--- ranges for each side, or nil when most of the line changed and a whole-line
--- highlight already says everything.
---@return { old: integer[][], new: integer[][] }|nil
function M.inline(old, new)
  local a, b = tokens(old), tokens(new)
  local ta = vim.tbl_map(function(t) return t.text end, a)
  local tb = vim.tbl_map(function(t) return t.text end, b)
  local result = { old = {}, new = {} }
  local changed = 0
  -- Ranges separated only by whitespace read as one change, so join them.
  local function add(list, line, r)
    local last = list[#list]
    if last and line:sub(last[2] + 1, r[1]):match("^%s*$") then
      last[2] = r[2]
    else
      list[#list + 1] = r
    end
  end
  for _, h in ipairs(diff(join(ta), join(tb), { result_type = "indices" })) do
    local ra, rb = spans(a, h[1], h[2]), spans(b, h[3], h[4])
    if ra then
      add(result.old, old, ra)
      changed = changed + ra[2] - ra[1]
    end
    if rb then
      add(result.new, new, rb)
    end
  end
  local significant = #old:gsub("^%s+", "")
  if significant == 0 or changed / significant > 0.6 then
    return nil
  end
  return result
end

--- Original lines with every accepted hunk swapped for its proposed lines.
--- Second result: 1-based {first, last} output rows written by accepted hunks.
function M.merge(original, proposed, hunks)
  local out, i, changed = {}, 1, {}
  for _, h in ipairs(hunks) do
    local first = M.first_line(h)
    for k = i, first - 1 do
      out[#out + 1] = original[k]
    end
    local replacement = h.status == "accepted" and M.added_lines(h, proposed)
      or vim.list_slice(original, first, first + h.a_count - 1)
    if h.status == "accepted" and #replacement > 0 then
      changed[#changed + 1] = { #out + 1, #out + #replacement }
    end
    vim.list_extend(out, replacement)
    i = first + h.a_count
  end
  for k = i, #original do
    out[#out + 1] = original[k]
  end
  return out, changed
end

return M
