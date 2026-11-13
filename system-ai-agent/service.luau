--!nonstrict
-- Bridge supervisor: starts bridge/agentd.py, watches its pings, restarts it
-- with backoff, mirrors /v1/status into noctalia.state and forwards settings.
--
-- State channels written here:
--   "bridge"       -> { port, token } while a bridge is ready, else nil
--   "status"       -> { state, pending, title } from /v1/status, nil without a bridge
--   "bridge_error" -> string while the bridge cannot be started, else nil
-- Read here: "panel_open" (bool, written by the panel).
local Client = require("./lib/client.luau")
local Notifications = require("./lib/notifications.luau")
local completions = Notifications.new()

local PING_TIMEOUT_MS = 15000
local BACKOFF_SECONDS = { 1, 2, 5, 10, 30 }
local STATUS_RETRY_MS = 1000
local ALLOWED_MODES = { default = true, acceptEdits = true, plan = true, bypassPermissions = true }

local gen = 0 -- bumps on every launch; lines from older launches are ignored
local running = false -- a runStream child is (believed to be) alive
local lastSeenMs = 0 -- last ready/ping line from the current child
local bridgePid = nil
local client = nil
local statusStream = nil
local statusRetryAt = nil
local restartAt = nil
local backoffIndex = 0
local healthy = false -- got a ping after ready: the launch counts as good
local lastPending = 0
local lastPython = nil
local killQueue = {} -- { pid, at }: SIGKILL for children that ignored SIGTERM
local KILL_GRACE_MS = 3000

local function now()
  return noctalia.nowMs()
end

local function shellQuote(value)
  return "'" .. string.gsub(tostring(value), "'", "'\\''") .. "'"
end

local function configString(key, fallback)
  local value = noctalia.getConfig(key)
  if type(value) ~= "string" then
    return fallback
  end
  value = noctalia.string.trim(value)
  if value == "" then
    return fallback
  end
  return value
end

local function permissionMode()
  local mode = configString("permission_mode", "bypassPermissions")
  if not ALLOWED_MODES[mode] then
    return "bypassPermissions"
  end
  return mode
end

local function safeMode()
  return noctalia.getConfig("load_user_config") == false
end

local function pythonPath()
  return configString("python_path", "python3")
end

local function bridgeConfig()
  return {
    claude_path = configString("claude_path", ""),
    cwd = configString("default_cwd", "~"),
    model = configString("model", "default"),
    permission_mode = permissionMode(),
    effort = configString("effort", "default"),
    safe_mode = safeMode(),
    extra_prompt = noctalia.getConfig("extra_prompt") or "",
  }
end

local function buildCommand()
  local pluginDir = noctalia.pluginDir()
  local dataDir, err = noctalia.pluginDataDir()
  if pluginDir == nil or dataDir == nil then
    return nil, "plugin directories unavailable: " .. tostring(err)
  end
  local cfg = bridgeConfig()
  local parts = {
    "exec",
    shellQuote(pythonPath()),
    "-I",
    shellQuote(pluginDir .. "/bridge/agentd.py"),
    "--data-dir",
    shellQuote(dataDir),
    "--cwd",
    shellQuote(cfg.cwd),
    "--model",
    shellQuote(cfg.model),
    "--permission-mode",
    shellQuote(cfg.permission_mode),
    "--effort",
    shellQuote(cfg.effort),
  }
  if cfg.safe_mode then
    parts[#parts + 1] = "--safe-mode"
  end
  if cfg.claude_path ~= "" then
    parts[#parts + 1] = "--claude-path"
    parts[#parts + 1] = shellQuote(cfg.claude_path)
  end
  return table.concat(parts, " ")
end

local function setError(message)
  noctalia.state.set("bridge_error", message)
end

local function stopStatusStream()
  if statusStream ~= nil then
    statusStream.stop()
    statusStream = nil
  end
  statusRetryAt = nil
end

local function onStatus(event)
  if event.type ~= "status" then
    return -- heartbeat
  end
  local pending = tonumber(event.pending) or 0
  noctalia.state.set("status", {
    state = event.state,
    pending = pending,
    title = event.title,
  })
  if
    pending > lastPending
    and noctalia.state.get("panel_open") ~= true
    and noctalia.getConfig("notify_on_permission") ~= false
  then
    noctalia.notify(noctalia.tr("notify.permission.title"), noctalia.tr("notify.permission.body"))
  end
  lastPending = pending
  local finished = completions:observe(event.completion, noctalia.state.get("panel_open") == true,
    noctalia.getConfig("notify_on_completion") ~= false)
  if finished ~= nil then
    noctalia.notify(noctalia.tr("notify." .. finished .. ".title"), noctalia.tr("notify." .. finished .. ".body"))
  end
end

local function openStatusStream()
  stopStatusStream()
  if client == nil then
    return
  end
  local myGen = gen
  statusStream = client:stream("/v1/status", function(event)
    if myGen == gen then
      onStatus(event)
    end
  end, function(_ok, status)
    if myGen ~= gen then
      return
    end
    statusStream = nil
    if status == 401 or status == 403 then
      noctalia.log("system-ai-agent: status stream rejected with " .. tostring(status))
    end
    statusRetryAt = now() + STATUS_RETRY_MS -- update() reconnects while the bridge lives
  end)
  if statusStream == nil then
    statusRetryAt = now() + STATUS_RETRY_MS
  end
end

local function clearBridge()
  stopStatusStream()
  client = nil
  bridgePid = nil
  lastPending = 0
  completions:reset()
  noctalia.state.set("bridge", nil)
  noctalia.state.set("status", nil)
end

local function onReady(msg)
  local port = tonumber(msg.port)
  if port == nil or type(msg.token) ~= "string" or msg.token == "" then
    noctalia.log("system-ai-agent: malformed ready line from bridge")
    return
  end
  bridgePid = tonumber(msg.pid)
  local okNew, made = pcall(Client.new, { port = port, token = msg.token })
  if not okNew then
    noctalia.log("system-ai-agent: " .. tostring(made))
    return
  end
  client = made
  -- extra_prompt never goes into argv: it travels in the HTTP body.
  client:post("/v1/config", bridgeConfig(), function(ok, status)
    if not ok then
      noctalia.log("system-ai-agent: POST /v1/config failed, status " .. tostring(status))
    end
  end)
  setError(nil)
  noctalia.state.set("bridge", { port = client.port, token = client.token })
  openStatusStream()
end

local function onLine(myGen, line)
  if myGen ~= gen or line == nil or line == "" then
    return
  end
  local okCall, msg = pcall(noctalia.json.decode, line)
  if not okCall or type(msg) ~= "table" then
    return
  end
  if msg.type == "ready" then
    lastSeenMs = now()
    onReady(msg)
  elseif msg.type == "ping" then
    lastSeenMs = now()
    if client ~= nil and not healthy then
      healthy = true
      backoffIndex = 0
    end
  end
end

local function launch()
  restartAt = nil
  clearBridge()
  gen = gen + 1
  healthy = false
  lastPython = pythonPath()
  if string.find(lastPython, "/", 1, true) == nil and not noctalia.commandExists(lastPython) then
    setError(noctalia.tr("error.python_missing", { python = lastPython }))
  end
  local cmd, err = buildCommand()
  if cmd == nil then
    setError(err)
    running = false
    return false
  end
  local myGen = gen
  lastSeenMs = now()
  running = noctalia.runStream(cmd, function(line)
    onLine(myGen, line)
  end)
  if not running then
    setError(noctalia.tr("error.start_failed"))
  end
  return running
end

local function scheduleRestart(reason)
  backoffIndex = math.min(backoffIndex + 1, #BACKOFF_SECONDS)
  local delay = BACKOFF_SECONDS[backoffIndex]
  noctalia.log("system-ai-agent: bridge " .. reason .. "; restarting in " .. tostring(delay) .. " s")
  restartAt = now() + delay * 1000
end

-- Stops the current child: polite shutdown over HTTP, then SIGTERM by pid.
-- runStream has no handle, so the pid from the ready line is the only way to
-- reach a hung child before the runtime itself goes away.
local function stopBridge()
  local pid = bridgePid
  if client ~= nil then
    client:post("/v1/shutdown", nil, nil)
  end
  if pid ~= nil and pid > 1 then
    pid = math.floor(pid)
    noctalia.runAsync({ "kill", "-TERM", tostring(pid) })
    killQueue[#killQueue + 1] = { pid = pid, at = now() + KILL_GRACE_MS }
  end
  gen = gen + 1 -- ignore whatever the old child still prints
  running = false
  clearBridge()
end

local function lostBridge(reason)
  stopBridge()
  if not healthy and noctalia.state.get("bridge_error") == nil then
    setError(noctalia.tr("error.not_responding"))
  end
  scheduleRestart(reason)
end

local function reapStuck(t)
  local keep = {}
  for _, item in ipairs(killQueue) do
    if t >= item.at then
      -- Only signal it if it is still our bridge, not a recycled pid.
      local pid = tostring(item.pid)
      noctalia.runAsync({
        "/bin/sh",
        "-c",
        'grep -qa agentd.py "/proc/$1/cmdline" 2>/dev/null && kill -KILL "$1"',
        "sh",
        pid,
      })
    else
      keep[#keep + 1] = item
    end
  end
  killQueue = keep
end

function update()
  local t = now()
  if #killQueue > 0 then
    reapStuck(t)
  end
  if restartAt ~= nil then
    if t >= restartAt then
      launch()
    end
    return
  end
  if not running then
    scheduleRestart("did not start")
    return
  end
  if t - lastSeenMs > PING_TIMEOUT_MS then
    lostBridge(client == nil and "sent no ready line" or "stopped pinging")
    return
  end
  if client ~= nil and statusStream == nil and statusRetryAt ~= nil and t >= statusRetryAt then
    openStatusStream()
  end
end

function onConfigChanged()
  if pythonPath() ~= lastPython then
    -- A different interpreter needs a new process.
    stopBridge()
    backoffIndex = 0
    launch()
    return
  end
  if client == nil then
    return -- the next launch reads the new settings from getConfig()
  end
  client:post("/v1/config", bridgeConfig(), function(ok, status)
    if not ok then
      noctalia.log("system-ai-agent: POST /v1/config failed, status " .. tostring(status))
    end
  end)
end

-- `noctalia msg plugin notkirilov/system-ai-agent:service all status` logs a
-- one-line summary. Never logs the token or the chat title (user text).
function onIpc(event, _payload)
  if event ~= "status" then
    return
  end
  local s = noctalia.state.get("status")
  noctalia.log(string.format(
    "system-ai-agent: bridge=%s pid=%s state=%s pending=%s error=%s",
    client ~= nil and ("127.0.0.1:" .. tostring(client.port)) or "none",
    tostring(bridgePid),
    type(s) == "table" and tostring(s.state) or "nil",
    type(s) == "table" and tostring(s.pending) or "nil",
    tostring(noctalia.state.get("bridge_error"))
  ))
end

function onExit(_signal, _reason)
  if client ~= nil then
    client:post("/v1/shutdown", nil, nil)
  end
  noctalia.state.set("bridge", nil)
  noctalia.state.set("status", nil)
end

-- A previous runtime may have left values behind (state outlives a reload).
noctalia.state.set("bridge", nil)
noctalia.state.set("status", nil)
noctalia.state.set("bridge_error", nil)
noctalia.setUpdateInterval(1000)
launch()
