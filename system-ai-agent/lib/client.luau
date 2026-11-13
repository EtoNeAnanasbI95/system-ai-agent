--!nonstrict
-- HTTP/NDJSON client for the local bridge (bridge/http_api.py).
--
--   local c = Client.new({ port = 41234, token = "..." })
--   c:get("/v1/health", function(ok, status, body, raw) end)
--   c:post("/v1/messages", { text = "hi" }, function(ok, status, body, raw) end)
--   local h = c:stream("/v1/events?since=0", function(event) end, function(ok, status) end)
--   h.stop()
--
-- cb(ok, status, body, raw): ok is true only for a transport success with a
-- 2xx status; body is the decoded JSON value (nil when the reply is not JSON);
-- raw is the response text. The URL host is the literal 127.0.0.1 because the
-- bridge checks the Host header exactly. No Origin header is ever sent.

local Client = {}
Client.__index = Client

local function decode(text)
  if type(text) ~= "string" or text == "" then
    return nil
  end
  local okCall, value = pcall(noctalia.json.decode, text)
  if not okCall then
    return nil
  end
  return value
end

local function encode(value)
  if value == nil then
    return "{}"
  end
  local okCall, text = pcall(noctalia.json.encode, value)
  if not okCall or type(text) ~= "string" then
    return nil
  end
  return text
end

function Client.new(opts)
  assert(type(opts) == "table", "Client.new expects { port, token }")
  local port = tonumber(opts.port)
  assert(port ~= nil and port > 0, "Client.new: bad port")
  assert(type(opts.token) == "string" and opts.token ~= "", "Client.new: bad token")
  local self = setmetatable({}, Client)
  self.port = math.floor(port)
  self.token = opts.token
  self.base = "http://127.0.0.1:" .. tostring(self.port)
  return self
end

function Client:_headers(withBody)
  local headers = {
    "Authorization: Bearer " .. self.token,
    "Accept: application/json",
  }
  if withBody then
    headers[#headers + 1] = "Content-Type: application/json"
    -- The bridge does not answer "100 Continue"; an empty Expect stops curl
    -- from waiting a second before sending a large body.
    headers[#headers + 1] = "Expect:"
  end
  return headers
end

function Client:_request(method, path, body, cb)
  local request = {
    url = self.base .. path,
    method = method,
    headers = self:_headers(method == "POST"),
  }
  if method == "POST" then
    -- Always send a body: a POST without one would make curl read stdin.
    local text = encode(body)
    if text == nil then
      if cb ~= nil then
        cb(false, 0, nil, "")
      end
      return false
    end
    request.body = text
  end
  local accepted = noctalia.http(request, function(res)
    if cb == nil then
      return
    end
    local status = tonumber(res.status) or 0
    local raw = res.body or ""
    cb(res.ok == true and status >= 200 and status < 300, status, decode(raw), raw)
  end)
  if not accepted and cb ~= nil then
    cb(false, 0, nil, "")
  end
  return accepted
end

function Client:get(path, cb)
  return self:_request("GET", path, nil, cb)
end

function Client:post(path, body, cb)
  return self:_request("POST", path, body, cb)
end

-- Opens a long-lived NDJSON stream. onEvent(obj) gets each decoded line that
-- is a JSON object; empty and malformed lines are skipped. onClose(ok, status)
-- fires once when the transfer ends, unless handle.stop() was called first.
-- Returns a handle { stop = function } or nil when the stream did not start.
function Client:stream(path, onEvent, onClose)
  local stopped = false
  local native = noctalia.httpStream({
    url = self.base .. path,
    method = "GET",
    headers = self:_headers(false),
  }, function(line)
    if stopped or line == nil or line == "" then
      return
    end
    local value = decode(line)
    if type(value) == "table" then
      onEvent(value)
    end
  end, function(result)
    if stopped then
      return
    end
    stopped = true
    if onClose ~= nil then
      onClose(result ~= nil and result.ok == true, result ~= nil and (tonumber(result.status) or 0) or 0)
    end
  end)
  if native == nil then
    return nil
  end
  return {
    stop = function()
      if stopped then
        return
      end
      stopped = true
      native.stop()
    end,
  }
end

return Client
