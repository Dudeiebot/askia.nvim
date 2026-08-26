local M = {}

local function shout(s)
  return s:upper() .. "!"
end

function M.greet(name)
  local out = string.format("hello %s", name)
  print(shout(out))
  return out
end

return M
