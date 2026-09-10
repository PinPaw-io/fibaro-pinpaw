--[[
Thin PinPaw REST client for Fibaro HC3 QuickApps.

Mirrors custom_components/pinpaw/api.py from the Home Assistant integration:
only the endpoints the integration needs are wrapped, and authentication uses
a long-lived personal access token ("ppw_pat_...") sent as a Bearer credential.

HC3's net.HTTPClient is callback-based, so every call takes an onSuccess and an
onError callback instead of returning a value. onError receives a machine
readable kind ("auth" | "http" | "network" | "parse") so the caller can react
differently to a rejected token than to a flaky network -- the QuickApp stops
polling on "auth" rather than hammering the API with a credential it knows is
bad.
]]

PinPawApi = {}
PinPawApi.__index = PinPawApi

-- A PinPaw personal access token always carries this prefix.
PINPAW_TOKEN_PREFIX = "ppw_pat_"

PINPAW_DEFAULT_BASE_URL = "https://api.pinpaw.io"

--- Device command types the QuickApp sends.
PINPAW_CMD = {
  liveTracking = "LIVE_TRACKING",
  defaultTracking = "DEFAULT_TRACKING",
  savingTracking = "SAVING_TRACKING",
  ledOn = "LED_SWITCH_ON",
  ledOff = "LED_SWITCH_OFF",
  soundOn = "SOUND_SWITCH_ON",
  soundOff = "SOUND_SWITCH_OFF",
}

local HTTP_TIMEOUT_MS = 15000

--- Create a client. `logger` is optional and only needs a :debug(...) method.
function PinPawApi.new(baseUrl, token, logger)
  local self = setmetatable({}, PinPawApi)
  self.baseUrl = (baseUrl or PINPAW_DEFAULT_BASE_URL):gsub("/+$", "")
  self.token = token or ""
  self.logger = logger
  self.http = net.HTTPClient({ timeout = HTTP_TIMEOUT_MS })
  return self
end

--- True when the token at least looks like a PinPaw PAT.
--- Cheap local check so an obvious typo is reported before any network call,
--- matching the Home Assistant config flow.
function PinPawApi.looksLikeToken(token)
  return type(token) == "string" and token:sub(1, #PINPAW_TOKEN_PREFIX) == PINPAW_TOKEN_PREFIX
end

function PinPawApi:_debug(message)
  if self.logger and self.logger.debug then
    self.logger:debug(message)
  end
end

function PinPawApi:_request(method, path, body, onSuccess, onError)
  local headers = {
    ["Authorization"] = "Bearer " .. self.token,
    ["Accept"] = "application/json",
  }

  local options = { method = method, headers = headers, timeout = HTTP_TIMEOUT_MS }
  if body ~= nil then
    headers["Content-Type"] = "application/json"
    options.data = json.encode(body)
  end

  self:_debug(string.format("%s %s", method, path))

  self.http:request(self.baseUrl .. path, {
    options = options,
    success = function(response)
      local status = tonumber(response and response.status) or 0

      if status == 401 or status == 403 then
        onError("auth", string.format("token rejected (HTTP %d)", status))
        return
      end
      if status < 200 or status >= 300 then
        onError("http", string.format("%s %s -> HTTP %d", method, path, status))
        return
      end

      -- 204 No Content, or an empty body on a 200: nothing to decode.
      if status == 204 or response.data == nil or response.data == "" then
        onSuccess(nil)
        return
      end

      local ok, decoded = pcall(json.decode, response.data)
      if not ok then
        onError("parse", string.format("malformed JSON from %s", path))
        return
      end
      onSuccess(decoded)
    end,
    error = function(err)
      onError("network", string.format("network error calling %s: %s", path, tostring(err)))
    end,
  })
end

--- GET /api/auth/me -- verifies the token belongs to a real account.
function PinPawApi:getAccount(onSuccess, onError)
  self:_request("GET", "/api/auth/me", nil, onSuccess, onError)
end

--- GET /api/pets -- every pet with deviceStatus, latestPosition and
--- trackingInterval already embedded, so one call covers the whole integration.
function PinPawApi:getPets(onSuccess, onError)
  self:_request("GET", "/api/pets", nil, function(data)
    if type(data) ~= "table" then
      onError("parse", "/api/pets did not return a list")
      return
    end
    onSuccess(data)
  end, onError)
end

--- GET /api/device-states/my-pets -- the last heartbeat for every visible pet.
--- The only place the light and sound state lives; /api/pets omits it.
function PinPawApi:getDeviceStates(onSuccess, onError)
  self:_request("GET", "/api/device-states/my-pets", nil, function(data)
    if type(data) ~= "table" then
      onError("parse", "/api/device-states/my-pets did not return a list")
      return
    end
    onSuccess(data)
  end, onError)
end

--- PUT /api/pets/{id}/car-mode -- the pet is riding along, so no walk is recorded.
function PinPawApi:setCarMode(petId, enabled, onSuccess, onError)
  self:_request(
    "PUT",
    string.format("/api/pets/%s/car-mode", tostring(petId)),
    { enabled = enabled },
    onSuccess,
    onError
  )
end

--- PUT /api/pets/{id}/walk-recording-mode -- "AUTO" or "MANUAL".
function PinPawApi:setWalkRecordingMode(petId, mode, onSuccess, onError)
  self:_request(
    "PUT",
    string.format("/api/pets/%s/walk-recording-mode", tostring(petId)),
    { mode = mode },
    onSuccess,
    onError
  )
end

--- PUT /api/pets/{id}/walk-active -- start or stop a walk. Manual mode only.
function PinPawApi:setWalkActive(petId, enabled, onSuccess, onError)
  self:_request(
    "PUT",
    string.format("/api/pets/%s/walk-active", tostring(petId)),
    { enabled = enabled },
    onSuccess,
    onError
  )
end

--- POST /api/pets/{id}/commands/{command} -- fire and forget.
--- The backend also offers a /sync variant that blocks up to 30s waiting for the
--- tracker to acknowledge, which is twice this client's own timeout. The result
--- of the command shows up in the next poll instead.
function PinPawApi:sendCommand(petId, command, onSuccess, onError)
  self:_request(
    "POST",
    string.format("/api/pets/%s/commands/%s", tostring(petId), command),
    nil,
    onSuccess,
    onError
  )
end

--- PUT /api/pets/{id}/tracking-interval -- push a new reporting interval.
function PinPawApi:setTrackingInterval(petId, seconds, onSuccess, onError)
  self:_request(
    "PUT",
    string.format("/api/pets/%s/tracking-interval", tostring(petId)),
    { trackingInterval = seconds },
    onSuccess,
    onError
  )
end
