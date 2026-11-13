local M = {}

function M.parse_port(value)
  local n = tonumber(value)
  if n == nil then
    return nil
  end
  return n
end

function M.format_user(user)
  local name = user.first .. " " .. user.last
  return name .. " <" .. user.email .. ">"
end

return M
