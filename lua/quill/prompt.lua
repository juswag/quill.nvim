-- One-line floating input anchored above the selection (below it when there is no room).
local M = {}

local ns = vim.api.nvim_create_namespace("quill_prompt")
local WIDTH = 64

local function decorate(buf, placeholder)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local empty = (vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "") == ""
  local chunks = { { " › ", "QuillPromptIcon" } }
  if empty then
    chunks[#chunks + 1] = { placeholder, "QuillPlaceholder" }
  end
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { virt_text = chunks, virt_text_pos = "inline", right_gravity = false })
end

--- opts = { win, row, end_row, title, placeholder, on_submit, on_cancel }
function M.open(opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local above = opts.row - vim.fn.line("w0", opts.win) + 1 >= 3
  local width = math.min(WIDTH, vim.api.nvim_win_get_width(opts.win) - 8)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "win",
    win = opts.win,
    bufpos = above and { opts.row, 0 } or { opts.end_row, 0 },
    anchor = above and "SW" or "NW",
    row = above and 0 or 1,
    col = 0,
    width = width,
    height = 1,
    style = "minimal",
    border = "rounded",
    title = opts.title,
    title_pos = "left",
    footer = {
      { " ⏎ ", "QuillKey" }, { " submit ", "QuillKeyLabel" },
      { " ", "QuillBorder" },
      { " esc ", "QuillKey" }, { " cancel ", "QuillKeyLabel" },
      { " ", "QuillBorder" },
    },
    footer_pos = "right",
    zindex = 70,
  })
  vim.wo[win].winhighlight = "NormalFloat:QuillFloat,FloatBorder:QuillBorder,FloatTitle:QuillTitle"
  vim.wo[win].wrap = false
  decorate(buf, opts.placeholder or "")
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, { buffer = buf, callback = function()
    decorate(buf, opts.placeholder or "")
  end })

  local done = false
  local function close(text)
    if done then
      return
    end
    done = true
    vim.cmd.stopinsert()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if text and text:match("%S") then
      opts.on_submit(vim.trim(text))
    else
      opts.on_cancel()
    end
  end
  local function submit()
    close(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "")
  end
  local map = function(modes, lhs, fn)
    vim.keymap.set(modes, lhs, fn, { buffer = buf, nowait = true })
  end
  map({ "i", "n" }, "<CR>", submit)
  map({ "i", "n" }, "<Esc>", function()
    close(nil)
  end)
  map("n", "q", function()
    close(nil)
  end)
  vim.api.nvim_create_autocmd("WinClosed", { pattern = tostring(win), once = true, callback = function()
    close(nil)
  end })
  vim.api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = function()
    vim.schedule(function()
      close(nil)
    end)
  end })
  vim.cmd.startinsert()
end

return M
