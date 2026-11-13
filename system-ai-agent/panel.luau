--!nonstrict
-- Chat panel: streams /v1/events from the bridge into lib/model.luau and
-- renders it with lib/render.luau.
--
-- State channels read: "bridge" ({port, token} or nil), "status", "bridge_error".
-- Written: "panel_open" (true while the panel is open; the service uses it to
-- decide whether a permission request needs a notification).
local Client = require("./lib/client.luau")
local Model = require("./lib/model.luau")
local Render = require("./lib/render.luau")

local RENDER_INTERVAL_MS = 100
local RETRY_MS = 1000
local MAX_MESSAGE_CHARS = 100000
local MAX_IMAGES = 5 -- bridge/images.py MAX_IMAGES
local COPIED_MS = 1500 -- how long a Copy button shows "Copied"

local model = Model.new()
local uiState = {
  expanded = {},
  busy = {},
  draft = "",
  attachments = {}, paths = {}, pathsTotal = 0, pathsOffset = 0,
  images = {}, -- pasted images { id, path, name } waiting to be sent
  pickerGen = 0, -- bumped when the panel itself changes the chat search text
  copied = nil, -- key of the Copy button that just copied (shows "Copied" briefly)
  copiedAt = 0,
  imagePasting = false,
  pathsLoading = false, fileBrowser = false, pathsDirectory = "",
  composerGen = 0,
  scrollRev = 0,
  hasBridge = false,
  connected = false,
  bridgeError = nil,
  status = nil,
  notice = nil,
  picker = false,
  query = "",
  sessions = {},
  sessionsOffset = 0,
  sessionsTotal = 0,
  sessionsLoading = false,
  switching = false,
  sending = false,
  activeWarning = nil,
  suggestions = {},
  suggestionsPage = 0,
  preferences = { model = "default", effort = "default", permission_mode = "bypassPermissions" },
  preferencesLoading = false,
  preferencesSaving = false,
  controlsMenu = nil,
  commands = {},
  commandsReady = false,
  commandsAt = 0,
  suggestionsDismissed = false,
  historyPage = nil,
  historyOffset = 0,
  historyStart = nil,
  historyTotal = 0,
  historyLoading = false,
}

local bridge = nil
local client = nil
local modelToken = nil -- token of the bridge run the feed came from
local stream = nil
local streamGen = 0
local retryAt = nil
local isOpen = false
local lastRenderMs = 0
local frameTick = false

local function now()
  return noctalia.nowMs()
end

-- Suggestion hotkeys. The host captures only the chords listed in the manifest's capture_keys,
-- and always, so every key a setting may pick is listed there (a listed key never reaches the
-- composer). Enter is the exception: capturing it would break sending and new lines, so an Enter
-- binding is recognised from the composer's submit or the newline it types.
local SUGGESTION_CHORDS = { tab = "Tab", shift_tab = "shift+ISO_Left_Tab", up = "Up", down = "Down", enter = true }
local SUGGESTION_DEFAULTS = { next = "down", previous = "up", accept = "tab" }
local SUGGESTION_ORDER = { "accept", "next", "previous" } -- a key bound twice does the first

local function suggestionKeys()
  local keys = {}
  for action, default in pairs(SUGGESTION_DEFAULTS) do
    local value = noctalia.getConfig("suggestion_" .. action)
    keys[action] = (type(value) == "string" and SUGGESTION_CHORDS[value] ~= nil) and value or default
  end
  return keys
end

local function settings()
  return {
    send_on_enter = noctalia.getConfig("send_on_enter") == true,
    default_cwd = noctalia.getConfig("default_cwd"),
    suggestion_keys = suggestionKeys(),
  }
end

local function setFrameTick(on)
  if frameTick ~= on then
    frameTick = on
    panel.setNeedsFrameTick(on)
  end
end

local actions = {}
local catalogGen = 0
local commandGen = 0
local historyGen = 0
local sessionRev = 0
local operationGen = 0
local preferencesGen = 0 -- write generation
local preferencesReadGen = 0
local pathGen, attachmentId = 0, 0
local sendGen = 0
local pathAt = nil
local function fragment(text)
  -- Scan forward so an @ inside a quoted path belongs to that path.
  local at = 1
  while at <= #text do
    if string.sub(text, at, at) == "@" and (at == 1 or string.match(string.sub(text, at - 1, at - 1), "%s")) then
      if string.sub(text, at + 1, at + 1) == '"' then
        local position, pieces, closing = at + 2, {}, nil
        while position <= #text do
          local ch = string.sub(text, position, position)
          local following = string.sub(text, position + 1, position + 1)
          if ch == "\\" and (following == '"' or following == "\\") then
            pieces[#pieces + 1] = following
            position += 2
          elseif ch == '"' then
            closing = position
            break
          else
            pieces[#pieces + 1] = ch
            position += 1
          end
        end
        if closing == nil then return { start = at, query = table.concat(pieces) } end
        at = closing + 1
      else
        local ending = string.find(text, '[%s"]', at + 1)
        if ending == nil then return { start = at, query = string.sub(text, at + 1) } end
        at = ending + 1
      end
    else at = at + 1 end
  end
end
local function invalidatePaths(keepBrowserRows)
  local reload = keepBrowserRows and uiState.pathsLoading
  pathGen += 1
  pathAt = nil
  if not keepBrowserRows then uiState.paths = {} end
  uiState.pathsLoading = false
  if reload then pathAt = now() + 250 end
end
local queryAt = nil

local function busy()
  return uiState.preferencesSaving or uiState.switching or uiState.sending or model.state == "running" or uiState.status == "running"
    or uiState.status == "waiting_permission" or Model.pendingPermission(model) ~= nil
end

local function refreshSuggestions()
  local prefix = string.match(uiState.draft, "^/([^%s]*)$")
  local out = {}
  if prefix ~= nil and not uiState.suggestionsDismissed then
    local all = {
      { name = "new", description = noctalia.tr("panel.new_chat") },
      { name = "clear", description = noctalia.tr("panel.clear_chat") },
      { name = "resume", description = noctalia.tr("panel.chats") },
    }
    local seen = { new = true, clear = true, resume = true }
    for _, command in ipairs(uiState.commands) do
      if type(command) == "table" and type(command.name) == "string" then
        local name = string.gsub(command.name, "^/", "")
        if not seen[name] and string.sub(name, 1, 1) ~= "_"
          and not (type(command.description) == "string" and string.find(string.lower(command.description), "(removed)", 1, true)) then
          seen[name] = true
          all[#all + 1] = { name = name, description = command.description }
        end
      end
    end
    for _, command in ipairs(all) do
      if string.sub(string.lower(command.name), 1, #prefix) == string.lower(prefix) then
        out[#out + 1] = command
      end
    end
  end
  uiState.suggestions = out
  uiState.suggestionsPage = 0
  uiState.suggestionIndex = 1
end

local function render()
  if not isOpen then
    return
  end
  model.dirty = false
  lastRenderMs = now()
  uiState.clock = lastRenderMs
  uiState.spinning = false -- set again by every spinner the render draws
  panel.render(Render.panel(model, uiState, settings(), actions))
  if uiState.spinning then setFrameTick(true) end
end

-- Streaming updates are coalesced: the frame tick renders at most every 100 ms.
local function markDirty()
  model.dirty = true
  if isOpen then
    setFrameTick(true)
  end
end

local function stopStream()
  invalidatePaths()
  streamGen += 1
  if stream ~= nil then
    stream.stop()
    stream = nil
  end
  uiState.connected = false
  retryAt = nil
end

local function onEvent(ev)
  if Model.apply(model, ev) then
    local t = ev.type
    if t == "reset" then
      invalidatePaths()
      uiState.fileBrowser = false
      sessionRev += 1
      historyGen += 1
      commandGen += 1
      uiState.historyPage = nil
      uiState.historyStart = tonumber(ev.history_offset)
      uiState.historyTotal = tonumber(ev.history_total) or 0
      uiState.historyLoading = false
      uiState.commands = {}
      uiState.commandsReady = false
      uiState.commandsAt = 0
      refreshSuggestions()
      uiState.expanded = {}
      uiState.busy = {}
    elseif t == "commands" and type(ev.commands) == "table" then
      uiState.commands = ev.commands
      uiState.commandsReady = true
      uiState.commandsAt = now()
      refreshSuggestions()
    elseif t == "session_started" and ev.historical ~= true then
      if type(ev.slash_commands) == "table" then
        uiState.commands = ev.slash_commands
        uiState.commandsReady = true
        uiState.commandsAt = now()
        refreshSuggestions()
      end
    elseif ev.historical ~= true and (t == "user_message" or t == "permission_request") then
      uiState.scrollRev += 1 -- bring the new message or card into view
    end
    markDirty()
  end
end

local function connect()
  stopStream()
  if type(bridge) ~= "table" then
    client = nil
    return
  end
  if client == nil or client.token ~= bridge.token or client.port ~= tonumber(bridge.port) then
    local okNew, made = pcall(Client.new, bridge)
    if not okNew then
      client = nil
      noctalia.log("system-ai-agent: " .. tostring(made))
      retryAt = now() + RETRY_MS
      return
    end
    client = made
  end
  actions.refreshPreferences()
  local myGen = streamGen
  stream = client:stream("/v1/events?since=" .. tostring(model.lastSeq), function(ev)
    if myGen == streamGen then
      onEvent(ev)
    end
  end, function(_ok, status)
    if myGen ~= streamGen then
      return
    end
    stream = nil
    uiState.connected = false
    if status == 401 or status == 403 then
      -- A stale token: retrying cannot help. onBridge() reconnects when the
      -- service publishes the new bridge (and onOpen tries once more).
      noctalia.log("system-ai-agent: events stream rejected with " .. tostring(status))
      retryAt = nil
    else
      retryAt = now() + RETRY_MS
    end
    markDirty()
  end)
  if stream == nil then
    retryAt = now() + RETRY_MS
  else
    uiState.connected = true
  end
end

local function onBridge(value)
  if type(value) ~= "table" or bridge == nil or value.token ~= bridge.token or value.port ~= bridge.port then
    invalidatePaths()
    uiState.fileBrowser = false
    preferencesGen += 1
    preferencesReadGen += 1
    uiState.preferencesLoading = false
    uiState.preferencesSaving = false
    uiState.controlsMenu = nil
    catalogGen += 1
    commandGen += 1
    historyGen += 1
    operationGen += 1
    sessionRev += 1
    uiState.switching = false
    uiState.sending = false
    uiState.historyStart = nil
    uiState.sessionsLoading = false
    uiState.historyLoading = false
    uiState.commands = {}
    uiState.commandsReady = false
    uiState.commandsAt = 0
    uiState.historyPage = nil
    refreshSuggestions()
  end
  bridge = type(value) == "table" and value or nil
  uiState.hasBridge = bridge ~= nil
  if bridge == nil then
    -- Keep the feed on screen while the service brings a bridge back.
    stopStream()
    client = nil
    markDirty()
    return
  end
  if bridge.token ~= modelToken then
    -- A new bridge run has a new event log: start over from seq 0.
    stopStream()
    client = nil
    modelToken = bridge.token
    Model.clear(model)
    model.lastSeq = 0
    uiState.expanded = {}
    uiState.busy = {}
  end
  if isOpen and stream == nil then
    connect()
  end
  markDirty()
end

local function onStatus(value)
  uiState.status = type(value) == "table" and value.state or nil
  markDirty()
end

-- --------------------------------------------------------------- actions

local function post(path, body, onDone)
  if client == nil then
    return false
  end
  return client:post(path, body, function(ok, status, resBody)
    if not ok then
      noctalia.log("system-ai-agent: POST " .. path .. " failed, status " .. tostring(status))
    end
    if onDone ~= nil then
      onDone(ok, status, resBody)
    end
  end)
end

local function requestError(body)
  local code = type(body) == "table" and body.error or "request_failed"
  local known = { session_busy = true, session_active_elsewhere = true, missing_cwd = true,
    invalid_attachments = true, invalid_path = true, path_not_found = true, too_many_attachments = true,
    no_image = true, image_too_large = true, clipboard_unavailable = true, invalid_image = true,
    image_not_found = true, invalid_images = true, nothing_to_fork = true, message_not_found = true,
    clipboard_empty = true, paste_too_long = true,
    session_not_found = true, invalid_session = true, unknown_command = true }
  return noctalia.tr("panel." .. (known[code] and code or "request_failed"))
end

-- Paths are request scoped: edits, navigation and lifecycle changes invalidate callbacks.
-- index: the row to highlight once the page arrives (keyboard paging), 1 by default.
function actions.loadPaths(offset, index)
  if not isOpen or client == nil or not uiState.connected or uiState.switching then return end
  invalidatePaths()
  local token = fragment(uiState.draft)
  local browsing = uiState.fileBrowser
  if not browsing and token == nil then return end
  local query = browsing and (uiState.browseQuery or "") or token.query
  local gen, c, rev = pathGen, client, sessionRev
  uiState.pathsOffset = offset or 0
  uiState.pathsLoading = true
  c:get("/v1/paths?query=" .. noctalia.string.urlEncode(query) .. "&offset=" .. tostring(offset or 0) .. "&limit=4" .. (browsing and "&browse=1" or ""), function(ok, _status, body)
    if gen ~= pathGen or c ~= client or rev ~= sessionRev or not isOpen or uiState.switching then return end
    uiState.pathsLoading = false
    if type(body) == "table" and body.session_id ~= nil and model.sessionId ~= nil and body.session_id ~= model.sessionId then render() return end
    if ok and type(body) == "table" and type(body.items) == "table" then
      uiState.paths = {}
      for i = 1, math.min(4, #body.items) do uiState.paths[i] = body.items[i] end
      uiState.pathIndex = math.max(1, math.min(index or 1, #uiState.paths))
      uiState.pathsTotal = tonumber(body.total) or #body.items
      uiState.pathsDirectory = body.directory or ""
      uiState.pathsTruncated = body.truncated == true
    else uiState.notice = requestError(body) end
    render()
  end)
  render()
end

function actions.openFiles()
  if uiState.switching or not uiState.connected then return end
  uiState.fileBrowser = true
  uiState.controlsMenu = nil
  uiState.browseQuery = ""
  actions.loadPaths(0)
end
function actions.closeFiles()
  invalidatePaths()
  uiState.fileBrowser = false
  render()
end
function actions.filePath(value)
  if uiState.switching then return end
  invalidatePaths()
  uiState.filePath = type(value) == "string" and value or ""
  render()
end
function actions.parentFiles()
  if not uiState.fileBrowser then return end
  local directory = string.gsub(uiState.pathsDirectory, "/+$", "")
  uiState.browseQuery = (string.match(directory, "^(.*)/") or "") .. "/"
  actions.loadPaths(0)
end
function actions.removeAttachment(id)
  if uiState.switching then return end
  for i, item in ipairs(uiState.attachments) do
    if item.id == id then table.remove(uiState.attachments, i) break end
  end
  render()
end
function actions.attachFile(path, token)
  if uiState.switching or client == nil or not uiState.connected then return end
  if #uiState.attachments >= 10 then uiState.notice = noctalia.tr("panel.too_many_attachments") render() return end
  local c, rev, gen, draft = client, sessionRev, pathGen, uiState.draft
  post("/v1/attachments/resolve", { path = path }, function(ok, _status, body)
    if c ~= client or rev ~= sessionRev or gen ~= pathGen or not isOpen or uiState.switching then return end
    if token and draft ~= uiState.draft then return end
    if ok and type(body) == "table" and type(body.path) == "string" then
      local exists = false
      for _, item in ipairs(uiState.attachments) do if item.path == body.path then exists = true end end
      if not exists and #uiState.attachments < 10 then
        attachmentId += 1
        uiState.attachments[#uiState.attachments + 1] = { id = attachmentId, path = body.path, name = body.name or body.path }
      end
      if token then
        uiState.draft = string.sub(draft, 1, token.start - 1)
        uiState.composerGen += 1
        invalidatePaths()
      end
    else uiState.notice = requestError(body) end
    render()
  end)
end
function actions.choosePath(entry)
  if uiState.switching or type(entry) ~= "table" then return end
  local current = false
  for _, item in ipairs(uiState.paths) do if item == entry then current = true end end
  if not current then return end
  local token = fragment(uiState.draft)
  if entry.is_dir then
    if uiState.fileBrowser then
      uiState.browseQuery = entry.path .. "/"
      actions.loadPaths(0)
    elseif token then
      local escaped = string.gsub(string.gsub(entry.path, "\\", "\\\\"), '"', '\\"')
      actions.draft(string.sub(uiState.draft, 1, token.start - 1) .. '@"' .. escaped .. "/")
      uiState.composerGen += 1
      render()
    end
  else actions.attachFile(entry.path, not uiState.fileBrowser and token or nil) end
end

local preferenceChoices = {
  model = { "default", "fable", "opus", "sonnet", "haiku" },
  effort = { "default", "low", "medium", "high", "xhigh", "max" },
  permission_mode = { "bypassPermissions", "default", "acceptEdits", "plan" },
}

local function applyPreferences(body)
  if type(body) ~= "table" then return end
  for field, choices in pairs(preferenceChoices) do
    for _, value in ipairs(choices) do
      if body[field] == value then uiState.preferences[field] = value end
    end
  end
end

function actions.refreshPreferences()
  if client == nil then return end
  preferencesReadGen += 1
  local gen, c = preferencesReadGen, client
  uiState.preferencesLoading = true
  c:get("/v1/preferences", function(ok, _status, body)
    if gen ~= preferencesReadGen or c ~= client or not isOpen then return end
    uiState.preferencesLoading = false
    if ok then applyPreferences(body) else uiState.notice = requestError(body) end
    render()
  end)
end

function actions.controls(field)
  if busy() or uiState.preferencesLoading or not uiState.connected then return end
  uiState.controlsMenu = uiState.controlsMenu ~= field and field or nil
  render()
end

function actions.setPreference(field, value)
  if busy() or uiState.preferencesLoading or not uiState.connected or client == nil then return end
  local valid = false
  for _, choice in ipairs(preferenceChoices[field] or {}) do if value == choice then valid = true end end
  if not valid then return end
  preferencesGen += 1
  preferencesReadGen += 1
  local gen, c = preferencesGen, client
  uiState.preferencesSaving = true
  render()
  local sent = post("/v1/preferences", { [field] = value }, function(ok, _status, body)
    if gen ~= preferencesGen or c ~= client or not isOpen then return end
    uiState.preferencesSaving = false
    preferencesReadGen += 1
    uiState.preferencesLoading = false
    if ok then
      applyPreferences(body)
      uiState.controlsMenu = nil
      commandGen += 1
      uiState.commands = {}
      uiState.commandsReady = false
      uiState.commandsAt = 0
      uiState.discoverAt = nil
      refreshSuggestions()
    else uiState.notice = requestError(body) end
    render()
  end)
  if not sent then uiState.preferencesSaving = false render() end
end

function actions.suggestionPage(page)
  uiState.suggestionsPage = math.max(0, math.min(page, math.floor(math.max(0, #uiState.suggestions - 1) / 4)))
  uiState.suggestionIndex = uiState.suggestionsPage * 4 + 1
  render()
end

function actions.refreshCommands(onDone)
  uiState.discoverAt = nil
  if client == nil then
    if onDone then onDone(false) end
    return
  end
  commandGen += 1
  local gen, c, rev = commandGen, client, sessionRev
  c:get("/v1/commands", function(ok, _status, body)
    if gen ~= commandGen or c ~= client or rev ~= sessionRev then return end
    local ready = ok and type(body) == "table" and body.ready == true and type(body.commands) == "table"
    uiState.commandsReady = ready
    local failure = not ok and requestError(body) or noctalia.tr("panel.commands_unavailable")
    if not ok then uiState.notice = failure end
    if ready then
      uiState.commands = body.commands
      uiState.commandsAt = now()
    end
    refreshSuggestions()
    render()
    if onDone then onDone(ready, failure) end
  end)
end

-- index: the chat to highlight once the page arrives (keyboard paging), 1 by default.
function actions.loadChats(offset, index)
  if client == nil then return end
  catalogGen += 1
  local gen, c, query = catalogGen, client, uiState.query
  uiState.sessionsLoading = true
  uiState.activeWarning = nil
  render()
  c:get("/v1/sessions?q=" .. noctalia.string.urlEncode(query) .. "&offset=" .. tostring(offset or 0) .. "&limit=30", function(ok, _status, body)
    if gen ~= catalogGen or c ~= client or query ~= uiState.query then return end
    uiState.sessionsLoading = false
    if ok and type(body) == "table" and type(body.sessions) == "table" then
      uiState.sessions = body.sessions
      uiState.sessionsOffset = tonumber(body.offset) or 0
      uiState.sessionsTotal = tonumber(body.total) or #body.sessions
      uiState.chatIndex = math.max(1, math.min(index or 1, #uiState.sessions))
    else
      uiState.sessions = {}
      uiState.sessionsTotal = 0
      uiState.notice = requestError(body)
    end
    render()
  end)
end

function actions.chats()
  actions.closeFiles()
  uiState.picker = true
  uiState.notice = nil
  queryAt = nil
  actions.loadChats(0)
  render()
end

function actions.closeChats()
  uiState.picker = false
  uiState.activeWarning = nil
  render()
end

function actions.searchChats(value)
  uiState.query = type(value) == "string" and value or ""
  catalogGen += 1 -- invalidate even before the debounced request starts
  uiState.sessionsLoading = true
  uiState.activeWarning = nil
  queryAt = now() + 250
  markDirty()
end

local function changeChat(path, body, selected)
  if busy() or client == nil or not uiState.connected then return end
  invalidatePaths()
  uiState.fileBrowser = false
  uiState.switching = true
  -- Invalidate reads immediately: the reset event can arrive after the POST reply.
  sessionRev += 1
  historyGen += 1
  commandGen += 1
  uiState.historyLoading = false
  uiState.discoverAt = nil
  uiState.notice = nil
  operationGen += 1
  local gen, c = operationGen, client
  render()
  post(path, body, function(ok, _status, result)
    if gen ~= operationGen or c ~= client then return end
    uiState.switching = false
    if ok then
      model.sessionId = type(result) == "table" and result.session_id or (selected and selected.id or nil)
      uiState.attachments = {}
      uiState.images = {}
      uiState.draft = ""
      uiState.composerGen += 1
      uiState.picker = false
      uiState.activeWarning = nil
      uiState.historyPage = nil
      uiState.suggestionsDismissed = true
      refreshSuggestions()
      uiState.scrollRev += 1
    elseif type(result) == "table" and result.error == "session_active_elsewhere" then
      uiState.activeWarning = selected
    else
      uiState.notice = requestError(result)
    end
    render()
  end)
end

function actions.selectChat(session, confirmed)
  if busy() then return end
  if session.active and not confirmed then
    uiState.activeWarning = session
    render()
    return
  end
  changeChat("/v1/sessions/select", { session_id = session.id, confirm_active = confirmed == true }, session)
end

function actions.newChat()
  changeChat("/v1/new", nil, nil)
end

function actions.history(offset)
  if client == nil or uiState.historyLoading or uiState.switching then return end
  historyGen += 1
  local gen, c, rev = historyGen, client, sessionRev
  uiState.historyLoading = true
  render()
  local function load(at)
    c:get("/v1/history?offset=" .. tostring(at) .. "&limit=100", function(ok, _status, body)
      if gen ~= historyGen or c ~= client or rev ~= sessionRev then return end
      if ok and type(body) == "table" and type(body.events) == "table" then
        if type(body.session_id) == "string" and model.sessionId ~= nil and body.session_id ~= model.sessionId then
          uiState.historyLoading = false
          render()
          return
        end
        local total = tonumber(body.total) or #body.events
        if offset == nil and total > 100 and at == 0 then
          offset = math.max(0, total - 100)
          load(offset)
          return
        end
        local page = Model.new()
        for _, event in ipairs(body.events) do
          local historical = table.clone(event)
          historical.historical = true
          historical.seq = nil -- paging must never advance the live stream cursor
          Model.apply(page, historical)
        end
        uiState.historyPage = page
        uiState.historyOffset = tonumber(body.offset) or at
        uiState.historyTotal = total
      else
        uiState.notice = requestError(body)
      end
      uiState.historyLoading = false
      render()
    end)
  end
  load(offset or 0)
end

function actions.latest()
  historyGen += 1
  uiState.historyLoading = false
  uiState.historyPage = nil
  uiState.scrollRev += 1
  render()
end

function actions.chooseCommand(command)
  if uiState.switching then return end
  invalidatePaths()
  uiState.draft = "/" .. command.name .. " "
  uiState.composerGen += 1
  uiState.suggestionsDismissed = true
  refreshSuggestions()
  render()
end

function actions.dismissSuggestions()
  uiState.suggestionsDismissed = true
  refreshSuggestions()
  render()
end

-- The list the suggestion keys act on: what the panel shows above the composer.
local function suggestionList()
  if uiState.picker or uiState.switching then return nil end
  if #uiState.paths > 0 and not uiState.pathsLoading then return "paths" end
  if not uiState.fileBrowser and #uiState.paths == 0 and uiState.controlsMenu == nil and #uiState.suggestions > 0 then
    return "commands"
  end
end

-- Wraps around both ends; path suggestions arrive four per page, so leaving a page loads the next.
local function moveSuggestion(step)
  local list = suggestionList()
  if list == "commands" then
    local index = ((uiState.suggestionIndex or 1) - 1 + step) % #uiState.suggestions + 1
    uiState.suggestionIndex = index
    uiState.suggestionsPage = math.floor((index - 1) / 4)
    render()
  elseif list == "paths" then
    local total = math.max(tonumber(uiState.pathsTotal) or 0, uiState.pathsOffset + #uiState.paths)
    local target = (uiState.pathsOffset + (uiState.pathIndex or 1) - 1 + step) % total
    local offset = target - target % 4
    if offset == uiState.pathsOffset then
      uiState.pathIndex = target - offset + 1
      render()
    else
      actions.loadPaths(offset, target - offset + 1)
    end
  end
end

local function acceptSuggestion()
  local list = suggestionList()
  if list == "commands" then
    local entry = uiState.suggestions[uiState.suggestionIndex or 1]
    if entry ~= nil then actions.chooseCommand(entry) return true end
  elseif list == "paths" then
    local entry = uiState.paths[uiState.pathIndex or 1]
    if entry ~= nil then actions.choosePath(entry) return true end
  end
  return false
end

-- Chat picker: the suggestion keys walk the chats, 30 per page; leaving a page loads the next.
local CHATS_PAGE = 30

local function moveChat(step)
  if uiState.sessionsLoading or #uiState.sessions == 0 then return end
  local total = math.max(tonumber(uiState.sessionsTotal) or 0, uiState.sessionsOffset + #uiState.sessions)
  local target = (uiState.sessionsOffset + (uiState.chatIndex or 1) - 1 + step) % total
  local offset = target - target % CHATS_PAGE
  if offset == uiState.sessionsOffset then
    uiState.chatIndex = target - offset + 1
    render()
  else
    actions.loadChats(offset, target - offset + 1)
  end
end

function actions.openHighlightedChat()
  local entry = not uiState.sessionsLoading and uiState.sessions[uiState.chatIndex or 1] or nil
  if entry ~= nil then actions.selectChat(entry, false) end
end

function actions.toggleChats()
  if uiState.picker then actions.closeChats() else actions.chats() end
end

local function enterAccepts()
  return suggestionKeys().accept == "enter" and suggestionList() ~= nil
end

-- The composer's submit (Enter in send-on-Enter mode, Ctrl+Enter otherwise).
function actions.submit(value)
  if settings().send_on_enter and enterAccepts() and acceptSuggestion() then return end
  actions.send(value)
end

-- Enter in the file browser's path field: an empty field picks the highlighted row.
function actions.submitFilePath(value)
  if noctalia.string.trim(value or "") == "" then
    acceptSuggestion()
  else
    actions.attachFile(value)
  end
end

function actions.send(value)
  if uiState.switching or uiState.sending or uiState.preferencesSaving then return end
  local text = type(value) == "string" and noctalia.string.trim(value) or ""
  if text == "" and #uiState.attachments == 0 and #uiState.images == 0 then return end
  local command = #uiState.images == 0 and string.match(text, "^/([^%s]*)") or nil
  if command == "new" or command == "clear" then actions.newChat() return end
  if command == "fork" or command == "branch" then
    actions.fork(function(ok)
      if ok then
        uiState.draft = ""
        uiState.composerGen += 1
        refreshSuggestions()
        render()
      end
    end)
    return
  end
  if command == "resume" then actions.chats() return end
  if (utf8.len(text) or #text) > MAX_MESSAGE_CHARS then
    uiState.notice = noctalia.tr("panel.too_long")
    render()
    return
  end
  if client == nil or not uiState.connected then
    uiState.notice = noctalia.tr("panel.not_connected")
    render()
    return
  end
  if command ~= nil and (not uiState.commandsReady or now() - uiState.commandsAt > 30000) then
    local draft, rev = uiState.draft, sessionRev
    actions.refreshCommands(function(ready, failure)
      if draft ~= uiState.draft or rev ~= sessionRev then return end
      if ready then actions.send(value) else
        uiState.notice = failure or noctalia.tr("panel.commands_unavailable")
        render()
      end
    end)
    return
  end
  if command ~= nil then
    local found = false
    for _, entry in ipairs(uiState.commands) do
      if type(entry) == "table" and type(entry.name) == "string" and string.gsub(entry.name, "^/", "") == command then found = true break end
    end
    if not found then
      uiState.notice = noctalia.tr("panel.unknown_command")
      render()
      return
    end
  end
  uiState.notice = nil
  uiState.sending = true
  render()
  local c, sendScope, draft = client, operationGen, uiState.draft
  sendGen += 1
  local sendingGen = sendGen
  local paths, sentIds = {}, {}
  for _, item in ipairs(uiState.attachments) do paths[#paths + 1] = item.path sentIds[item.id] = true end
  local imageIds, sentImages = {}, {}
  for _, image in ipairs(uiState.images) do imageIds[#imageIds + 1] = image.id sentImages[image.id] = true end
  -- Empty lists are omitted: Noctalia encodes an empty table as a JSON object, not [].
  local message = { text = text }
  if #paths > 0 then message.attachments = paths end
  if #imageIds > 0 then message.images = imageIds end
  local dispatched = post("/v1/messages", message, function(ok, _status, body)
    if c ~= client or sendScope ~= operationGen or sendingGen ~= sendGen or not isOpen then return end
    sendGen += 1
    uiState.sending = false
    if ok then
      local remaining = {}
      for _, item in ipairs(uiState.attachments) do if not sentIds[item.id] then remaining[#remaining + 1] = item end end
      uiState.attachments = remaining
      local images = {}
      for _, image in ipairs(uiState.images) do if not sentImages[image.id] then images[#images + 1] = image end end
      uiState.images = images
      invalidatePaths()
      if uiState.draft == draft then
        uiState.draft = ""
        uiState.composerGen += 1
        refreshSuggestions()
      end
      actions.latest()
    else
      uiState.notice = requestError(body)
    end
    render()
  end)
  if not dispatched then
    uiState.sending = false
    uiState.notice = noctalia.tr("panel.request_failed")
    render()
  end
end

function actions.draft(value)
  if uiState.switching then return end
  -- Enter typed a newline at the end of the draft while suggestions were open: pick instead.
  if value == (uiState.draft or "") .. "\n" and not settings().send_on_enter and enterAccepts() then
    uiState.composerGen += 1 -- the recreated input drops the typed newline
    acceptSuggestion()
    render()
    return
  end
  invalidatePaths(uiState.fileBrowser)
  uiState.draft = type(value) == "string" and value or ""
  if not uiState.fileBrowser and fragment(uiState.draft) then pathAt = now() + 250 end
  uiState.suggestionsDismissed = false
  refreshSuggestions()
  if string.sub(uiState.draft, 1, 1) == "/" and (not uiState.commandsReady or now() - uiState.commandsAt > 30000) then
    -- Discovery is debounced in update(), avoiding a request per keystroke.
    uiState.discoverAt = now() + 250
  end
  markDirty()
end

function actions.stop()
  post("/v1/interrupt", nil, nil)
end

function actions.toggle(id)
  uiState.expanded[id] = not uiState.expanded[id] or nil
  render()
end

function actions.decide(requestId, decision)
  local permission = model.byRequest[requestId]
  if permission == nil or permission.historical or permission.decision ~= nil or uiState.busy[requestId] then
    return
  end
  uiState.busy[requestId] = true
  render()
  local path = "/v1/permissions/" .. noctalia.string.urlEncode(requestId)
  local c, rev = client, sessionRev
  local sent = post(path, { decision = decision }, function(ok, status)
    if c ~= client or rev ~= sessionRev then return end
    uiState.busy[requestId] = nil
    if not ok and status ~= 404 then
      uiState.notice = noctalia.tr("panel.decide_failed")
    end
    render()
  end)
  if not sent then
    uiState.busy[requestId] = nil
    render()
  end
end

function actions.openSettings()
  noctalia.openSettings()
end

function actions.copy(text, key)
  if type(text) ~= "string" or text == "" then return end
  if noctalia.copyToClipboard(text, "text/plain") ~= false and key ~= nil then
    uiState.copied = key
    uiState.copiedAt = now()
    render()
  end
end

-- Alt+V or the photo button: the bridge reads the clipboard image itself (no upload through Luau).
function actions.pasteImage()
  if uiState.switching or uiState.imagePasting or client == nil or not uiState.connected then return end
  if #uiState.images >= MAX_IMAGES then
    uiState.notice = noctalia.tr("panel.too_many_images")
    render()
    return
  end
  local c, rev = client, sessionRev
  uiState.imagePasting = true
  uiState.notice = nil
  render()
  local dispatched = post("/v1/images/clipboard", {}, function(ok, _status, body)
    if c ~= client then return end
    uiState.imagePasting = false
    if rev == sessionRev and ok and type(body) == "table" and type(body.id) == "string" and #uiState.images < MAX_IMAGES then
      uiState.images[#uiState.images + 1] = { id = body.id, path = body.path, name = body.name or "image" }
    elseif not ok then
      uiState.notice = requestError(body)
    end
    render()
  end)
  if not dispatched then uiState.imagePasting = false render() end
end

function actions.removeImage(id)
  for i, image in ipairs(uiState.images) do
    if image.id == id then table.remove(uiState.images, i) break end
  end
  render()
end

-- Branch the current chat: the bridge appends a `forked` marker; the next message continues a copy.
-- at: transcript uuid of an assistant message to branch from (nil = the whole chat).
function actions.fork(onDone, at)
  if busy() or client == nil or not uiState.connected then return end
  uiState.notice = nil
  uiState.historyPage = nil -- the branch's feed replaces whatever page was being read
  local c = client
  local dispatched = post("/v1/fork", { at = at }, function(ok, _status, body)
    if c ~= client then return end
    if not ok then uiState.notice = requestError(body) end
    if onDone ~= nil then onDone(ok) end
    render()
  end)
  if not dispatched then
    uiState.notice = noctalia.tr("panel.request_failed")
    render()
  end
end

-- Ctrl+V text goes where the user was typing. The host's input would paste the newest *text*
-- from its clipboard history even when the clipboard holds a screenshot, so the panel takes
-- Ctrl+V over. A recreated input puts the cursor at the end, so text is appended; Ctrl+Shift+V
-- stays the host's own paste at the cursor.
local function insertText(text)
  if text == "" then return end
  if uiState.picker then
    uiState.pickerGen += 1
    actions.searchChats((uiState.query or "") .. text)
    return
  end
  local trimmed = noctalia.string.trim(text)
  if uiState.fileBrowser and string.find(trimmed, "\n", 1, true) == nil and string.match(trimmed, "^[~/]") then
    actions.attachFile(trimmed)
    return
  end
  if uiState.switching then return end
  actions.draft((uiState.draft or "") .. text)
  uiState.composerGen += 1
  render()
end

function actions.paste()
  if not isOpen then return end
  if client == nil or not uiState.connected then
    insertText(noctalia.clipboardText() or "") -- no bridge: the host's text is all there is
    return
  end
  local c, rev = client, sessionRev
  local dispatched = post("/v1/clipboard", {}, function(ok, _status, body)
    if c ~= client or not isOpen then return end
    if not ok then
      uiState.notice = requestError(body)
      render()
    elseif type(body) == "table" and body.kind == "image" and type(body.id) == "string" then
      if rev ~= sessionRev or uiState.picker then return end
      if #uiState.images >= MAX_IMAGES then
        uiState.notice = noctalia.tr("panel.too_many_images")
      else
        uiState.notice = nil
        uiState.images[#uiState.images + 1] = { id = body.id, path = body.path, name = body.name or "image" }
      end
      render()
    elseif type(body) == "table" and type(body.text) == "string" then
      insertText(body.text)
    end
  end)
  if not dispatched then insertText(noctalia.clipboardText() or "") end
end

local PASTE_CHORDS = { ["ctrl+v"] = true, ["ctrl+Cyrillic_em"] = true }
local CHATS_CHORDS = { ["ctrl+r"] = true, ["ctrl+Cyrillic_ka"] = true } -- Ctrl+R on a Russian layout too

function onKey(chord, pressed)
  if not pressed or not isOpen then return end
  if PASTE_CHORDS[chord] then
    actions.paste()
  elseif CHATS_CHORDS[chord] then
    actions.toggleChats()
  elseif chord == "alt+v" and not uiState.picker then
    actions.pasteImage()
  else
    local keys = suggestionKeys()
    for _, action in ipairs(SUGGESTION_ORDER) do
      if SUGGESTION_CHORDS[keys[action]] == chord then
        local step = action == "next" and 1 or -1
        if uiState.picker then
          if action == "accept" then actions.openHighlightedChat() else moveChat(step) end
        elseif action == "accept" then
          acceptSuggestion()
        else
          moveSuggestion(step)
        end
        return
      end
    end
  end
end

-- --------------------------------------------------------------- lifecycle

function onOpen(_context)
  isOpen = true
  noctalia.state.set("panel_open", true)
  uiState.scrollRev += 1
  if bridge ~= nil and stream == nil then
    connect() -- catch up from model.lastSeq
  end
  if client ~= nil then actions.refreshPreferences() end
  render() -- the feed in memory shows at once; the stream fills in the rest
  panel.setWantsSecondTicks(true) -- update(): stream reconnects
end

function onFrameTick(_deltaMs)
  if isOpen and pathAt ~= nil and now() >= pathAt then actions.loadPaths(0) end
  if queryAt ~= nil and now() >= queryAt then
    queryAt = nil
    if uiState.picker then actions.loadChats(0) end
  end
  if uiState.discoverAt ~= nil and now() >= uiState.discoverAt then
    uiState.discoverAt = nil
    actions.refreshCommands(nil)
  end
  if not model.dirty then
    -- A spinner on screen advances one frame per render interval.
    if uiState.spinning and now() - lastRenderMs >= RENDER_INTERVAL_MS then render() end
    setFrameTick(uiState.spinning or pathAt ~= nil or queryAt ~= nil or uiState.discoverAt ~= nil)
    return
  end
  if now() - lastRenderMs >= RENDER_INTERVAL_MS then
    render()
  end
end

function update()
  if isOpen and uiState.copied ~= nil and now() - uiState.copiedAt >= COPIED_MS then
    uiState.copied = nil
    render()
  end
  if isOpen and pathAt ~= nil and now() >= pathAt then actions.loadPaths(0) end
  if isOpen and queryAt ~= nil and now() >= queryAt then
    queryAt = nil
    if uiState.picker then actions.loadChats(0) end
  end
  if isOpen and uiState.discoverAt ~= nil and now() >= uiState.discoverAt then
    uiState.discoverAt = nil
    actions.refreshCommands(nil)
  end
  if isOpen and bridge ~= nil and stream == nil and retryAt ~= nil and now() >= retryAt then
    connect()
    markDirty()
  end
end

local function shutdown()
  sendGen += 1
  uiState.sending = false
  isOpen = false
  preferencesGen += 1
  preferencesReadGen += 1
  uiState.preferencesLoading = false
  uiState.preferencesSaving = false
  stopStream()
  setFrameTick(false)
  noctalia.state.set("panel_open", false)
end

function onClose()
  shutdown()
end

function onExit(_signal, _reason)
  shutdown()
end

noctalia.state.watch("bridge", onBridge)
noctalia.state.watch("status", onStatus)
noctalia.state.watch("bridge_error", function(value)
  uiState.bridgeError = type(value) == "string" and value or nil
  markDirty()
end)

uiState.bridgeError = noctalia.state.get("bridge_error")
onStatus(noctalia.state.get("status"))
onBridge(noctalia.state.get("bridge"))
