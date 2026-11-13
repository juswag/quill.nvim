local M = {}

function M.read_config(path)
  local file = io.open(path)
  local text = file:read("*a")
  file:close()
  return vim.json.decode(text)
end

return M
