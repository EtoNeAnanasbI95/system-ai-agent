--!nonstrict
-- Bar widget: shows the agent state from the service's "status" channel.
-- Left click toggles the chat panel, middle click interrupts the current turn.
local Client = require("./lib/client.luau")

local PANEL_ID = "notkirilov/system-ai-agent:panel"

local GLYPHS = {
  idle = "sparkles",
  running = "loader-2",
  waiting_permission = "alert-circle",
  error = "alert-triangle",
}

local status = noctalia.state.get("status")
local bridge = noctalia.state.get("bridge")
local bridgeError = noctalia.state.get("bridge_error")

local function currentState()
  if bridgeError ~= nil then
    return "error"
  end
  if type(status) == "table" and GLYPHS[status.state] ~= nil then
    return status.state
  end
  return "idle"
end

local function render()
  local state = currentState()
  barWidget.setGlyph(GLYPHS[state])
  if state == "waiting_permission" then
    barWidget.setGlyphColor("error")
  else
    barWidget.setGlyphColor("on_surface")
  end

  local pending = type(status) == "table" and tonumber(status.pending) or 0
  barWidget.setText(pending > 0 and tostring(pending) or "")

  local stateText
  if bridgeError ~= nil then
    stateText = tostring(bridgeError)
  elseif bridge == nil then
    stateText = noctalia.tr("widget.state.starting")
  else
    stateText = noctalia.tr("widget.state." .. state)
  end
  local title = type(status) == "table" and status.title or nil
  if type(title) ~= "string" or title == "" then
    title = noctalia.tr("widget.no_chat")
  end
  barWidget.setTooltip({
    { noctalia.tr("widget.chat"), title },
    { noctalia.tr("widget.state_label"), stateText },
  })
end

noctalia.state.watch("status", function(value)
  status = value
  render()
end)
noctalia.state.watch("bridge", function(value)
  bridge = value
  render()
end)
noctalia.state.watch("bridge_error", function(value)
  bridgeError = value
  render()
end)

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onMiddleClick()
  if type(bridge) ~= "table" then
    return
  end
  local okNew, client = pcall(Client.new, bridge)
  if not okNew then
    return
  end
  client:post("/v1/interrupt", nil, function(ok, code)
    if not ok then
      noctalia.log("system-ai-agent: POST /v1/interrupt failed, status " .. tostring(code))
    end
  end)
end

render()
