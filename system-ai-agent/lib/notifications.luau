-- Completion counters are bridge-local. Remember every observed result, even
-- when its toast is suppressed, so opening/closing the panel cannot replay it.
local Notifications = {}
Notifications.__index = Notifications

function Notifications.new()
  return setmetatable({}, Notifications)
end

function Notifications:reset()
  self.last = nil
end

function Notifications:observe(completion, panelOpen, enabled)
  local id = type(completion) == "table" and tonumber(completion.id) or 0
  if id == nil then return nil end
  local previous = self.last
  self.last = id
  if previous == nil or id <= previous or panelOpen or not enabled then return nil end
  if completion.kind == "success" or completion.kind == "error" then
    return completion.kind
  end
  return nil
end

return Notifications
