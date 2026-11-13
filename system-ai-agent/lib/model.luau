--!nonstrict
-- Chat model: folds bridge events (/v1/events) into a feed of items.
--
--   local m = Model.new()
--   Model.apply(m, event)   -- returns true when the feed changed
--
-- m = { items, byBlock, byTool, byRequest, state, lastSeq, error, session, dirty }
-- Item kinds: user | assistant | thinking | tool | permission | result | error | forked.
-- Every item has a stable `id` ("i<n>") used as the render key.

local Model = {}

Model.MAX_ITEMS = 300

local function str(value)
  if type(value) == "string" then
    return value
  end
  return nil
end

function Model.new()
  local m = {
    items = {},
    byBlock = {}, -- block_id -> assistant/thinking item
    byTool = {}, -- tool_use_id -> tool item
    byRequest = {}, -- request_id -> permission item
    state = "idle", -- feed-local view of the turn: idle | running
    lastSeq = 0,
    error = nil, -- last error event { kind, message } until the next good turn
    sessionId = nil,
    session = nil, -- { model, cwd } from session_started
    dirty = true,
    nextId = 0,
    evicted = false,
  }
  return m
end

-- Empties the feed but keeps the id counter, so keys never repeat.
function Model.clear(m)
  m.items = {}
  m.byBlock = {}
  m.byTool = {}
  m.byRequest = {}
  m.state = "idle"
  m.error = nil
  m.session = nil
  m.sessionId = nil
  m.commands = nil
  m.evicted = false
  m.dirty = true
end

local function forget(m, item)
  if item.block_id ~= nil and m.byBlock[item.block_id] == item then
    m.byBlock[item.block_id] = nil
  end
  if item.tool_use_id ~= nil and m.byTool[item.tool_use_id] == item then
    m.byTool[item.tool_use_id] = nil
  end
  if item.request_id ~= nil and m.byRequest[item.request_id] == item then
    m.byRequest[item.request_id] = nil
  end
  for _, child in ipairs(item.children or {}) do
    forget(m, child)
  end
end

local function newItem(m, kind)
  m.nextId += 1
  return { id = "i" .. tostring(m.nextId), kind = kind }
end

local function push(m, item)
  local items = m.items
  items[#items + 1] = item
  while #items > Model.MAX_ITEMS do
    m.evicted = true
    forget(m, table.remove(items, 1))
  end
  return item
end

local function textItem(m, kind, blockId)
  local item = blockId ~= nil and m.byBlock[blockId] or nil
  if item == nil then
    item = newItem(m, kind)
    item.block_id = blockId
    item.text = ""
    push(m, item)
    if blockId ~= nil then
      m.byBlock[blockId] = item
    end
  end
  return item
end

-- Tools still marked running when a turn ends will never get a result.
local function settleTools(m, status)
  for _, item in pairs(m.byTool) do
    if item.status == "running" then
      item.status = status
    end
  end
end

local handlers = {}

function handlers.user_message(m, ev)
  local item = newItem(m, "user")
  item.text = str(ev.text) or ""
  if type(ev.images) == "table" then
    item.images = {}
    for _, path in ipairs(ev.images) do
      if type(path) == "string" then
        item.images[#item.images + 1] = path
      end
    end
  end
  item.image_count = tonumber(ev.image_count)
  push(m, item)
  if ev.historical ~= true then
    m.state = "running"
  end
  m.error = nil
end

function handlers.commands(m, ev)
  m.commands = type(ev.commands) == "table" and ev.commands or {}
end

function handlers.session_started(m, ev)
  m.session = { model = str(ev.model), cwd = str(ev.cwd), id = str(ev.session_id) }
  m.commands = type(ev.slash_commands) == "table" and ev.slash_commands or m.commands
end

function handlers.assistant_text_delta(m, ev)
  local item = textItem(m, "assistant", str(ev.block_id))
  item.text ..= str(ev.text) or ""
  item.streaming = ev.historical ~= true
end

function handlers.assistant_text_done(m, ev)
  local item = textItem(m, "assistant", str(ev.block_id))
  item.text = str(ev.text) or item.text
  item.streaming = false
  item.uuid = str(ev.uuid) or item.uuid -- transcript entry: where a branch can start
end

-- Live stream: the transcript uuid of an already shown text block arrives right after it.
function handlers.assistant_anchor(m, ev)
  local item = m.byBlock[str(ev.block_id) or ""]
  if item == nil or item.kind ~= "assistant" then
    return false
  end
  item.uuid = str(ev.uuid)
end

function handlers.thinking(m, ev)
  local item = textItem(m, "thinking", str(ev.block_id))
  item.text = str(ev.text) or ""
end

function handlers.tool_call(m, ev)
  local id = str(ev.tool_use_id)
  if id ~= nil and m.byTool[id] ~= nil then
    return false
  end
  local item = newItem(m, "tool")
  item.tool_use_id = id
  item.name = str(ev.name) or "?"
  item.summary = str(ev.summary) or ""
  item.input = ev.input
  item.input_truncated = ev.input_truncated == true
  item.status = ev.historical == true and "stopped" or "running"
  item.children = {}
  local parent = str(ev.parent)
  local parentItem = parent ~= nil and m.byTool[parent] or nil
  if parentItem ~= nil then
    -- Subagent steps live under their Task row instead of the main feed.
    parentItem.children[#parentItem.children + 1] = item
  else
    push(m, item)
  end
  if id ~= nil then
    m.byTool[id] = item
  end
end

function handlers.tool_result(m, ev)
  local item = m.byTool[str(ev.tool_use_id) or ""]
  if item == nil and ev.historical == true then
    -- A page can begin with a result whose call was on the preceding page.
    handlers.tool_call(m, { historical = true, tool_use_id = ev.tool_use_id, name = ev.name })
    item = m.byTool[str(ev.tool_use_id) or ""]
  end
  if item == nil then
    return false
  end
  item.output = str(ev.text) or ""
  item.output_truncated = ev.truncated == true
  if item.status ~= "denied" then
    item.status = ev.ok == false and "error" or "done"
  end
end

function handlers.permission_request(m, ev)
  local rid = str(ev.request_id)
  if rid ~= nil and m.byRequest[rid] ~= nil then
    return false
  end
  local item = newItem(m, "permission")
  item.request_id = rid
  item.tool_use_id_ref = str(ev.tool_use_id)
  item.tool_name = str(ev.tool_name) or ""
  item.display_name = str(ev.display_name) or item.tool_name
  item.summary = str(ev.summary) or ""
  item.input = ev.input
  item.input_truncated = ev.input_truncated == true
  item.description = str(ev.description)
  item.blocked_path = str(ev.blocked_path)
  item.allow_session_available = ev.historical ~= true and ev.allow_session_available == true
  item.session_rule_preview = str(ev.session_rule_preview)
  item.historical = ev.historical == true
  item.decision = item.historical and "cancelled" or nil -- history is never actionable
  push(m, item)
  if rid ~= nil then
    m.byRequest[rid] = item
  end
end

function handlers.permission_resolved(m, ev)
  local item = m.byRequest[str(ev.request_id) or ""]
  if item == nil then
    return false
  end
  local decision = str(ev.decision) or "cancelled"
  item.decision = decision
  if decision == "deny" or decision == "cancelled" then
    local tool = item.tool_use_id_ref ~= nil and m.byTool[item.tool_use_id_ref] or nil
    if tool ~= nil and tool.status == "running" then
      tool.status = "denied"
    end
  end
end

function handlers.turn_result(m, ev)
  local item = newItem(m, "result")
  item.ok = ev.ok == true
  item.subtype = str(ev.subtype)
  item.duration_ms = tonumber(ev.duration_ms)
  item.cost_usd = tonumber(ev.cost_usd)
  item.error = str(ev.error)
  -- The turn's answer text (everything Claude said since the last user message),
  -- for the copy button on the summary row.
  local parts = {}
  for i = #m.items, 1, -1 do
    local prev = m.items[i]
    if prev.kind == "user" then
      break
    end
    if prev.kind == "assistant" and prev.text ~= "" then
      table.insert(parts, 1, prev.text)
    end
  end
  item.copyText = table.concat(parts, "\n\n")
  push(m, item)
  if ev.historical ~= true then
    for _, block in pairs(m.byBlock) do
      block.streaming = false
    end
    settleTools(m, "stopped")
    m.state = "idle"
  end
  if item.ok then
    m.error = nil
  end
end

function handlers.error(m, ev)
  local item = newItem(m, "error")
  item.errorKind = str(ev.kind) or "protocol"
  item.message = str(ev.message) or ""
  push(m, item)
  m.error = { kind = item.errorKind, message = item.message }
  if ev.historical ~= true and item.errorKind ~= "protocol" then
    settleTools(m, "stopped")
    m.state = "idle"
  end
end

-- The bridge branched the conversation: the next message continues a copy under a new id.
function handlers.forked(m, ev)
  local item = newItem(m, "forked")
  item.from = str(ev.from)
  item.title = str(ev.title)
  item.at = str(ev.at)
  push(m, item)
end

function handlers.rate_limit(_m, _ev)
  return false
end

-- Applies one event. Returns true when the feed changed (and sets m.dirty).
function Model.apply(m, ev)
  if type(ev) ~= "table" then
    return false
  end
  local t = ev.type
  local seq = tonumber(ev.seq)
  if t == "reset" then
    -- A reset may carry a seq lower than ours (new bridge run) or none at all.
    Model.clear(m)
    m.sessionId = str(ev.session_id)
    m.lastSeq = seq or 0
    return true
  end
  if t == "heartbeat" then
    return false
  end
  if seq ~= nil then
    if seq <= m.lastSeq then
      return false
    end
    m.lastSeq = seq
  end
  m.sessionId = str(ev.session_id) or m.sessionId
  local handler = handlers[t]
  if handler == nil then
    return false
  end
  local previousState, previousError = m.state, m.error
  local changed = handler(m, ev)
  if ev.historical == true then
    m.state, m.error = previousState, previousError
  end
  if changed == false then
    return false
  end
  m.dirty = true
  return true
end

-- First pending permission request, or nil.
function Model.pendingPermission(m)
  for _, item in ipairs(m.items) do
    if item.kind == "permission" and not item.historical and item.decision == nil then
      return item
    end
  end
  return nil
end

return Model
