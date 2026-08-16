--[[
PinPaw Pet Tracker -- Fibaro Home Center 3 QuickApp.

Polls GET /api/pets on an interval and fans the result out to one set of child
devices per pet, so pets and their measurements show up as first class HC3
devices usable in blocks, scenes and the mobile app.

Load order matters: this file uses PinPawApi, PinPawGeo, PinPawI18n and
PinPawSensor, so main must be the LAST file in the QuickApp.
]]

local DEFAULTS = {
  baseUrl = PINPAW_DEFAULT_BASE_URL,
  pollInterval = "60",
  language = "en",
  reverseGeocode = "false",
  primaryPet = "",
  homeLat = "",
  homeLon = "",
  homeRadius = "",
}

-- Polling floor. The tracker itself reports on its own schedule
-- (trackingInterval), so hammering the API faster than this buys nothing.
local MIN_POLL_INTERVAL = 15

-- Re-read the HC3 location panel every N polls rather than every poll: zones
-- change about once a year, and this keeps the local API call off the hot path.
local ZONE_REFRESH_EVERY = 10

-- Nominatim's usage policy caps automated use at 1 request/second and expects
-- a descriptive User-Agent. We stay far below that: opt-in only, and never
-- more than one lookup per this many seconds regardless of how often we poll.
local GEOCODE_MIN_INTERVAL = 120
local GEOCODE_USER_AGENT = "fibaro-pinpaw/1.0 (+https://github.com/PinPaw-io/fibaro-pinpaw)"

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function QuickApp:onInit()
  self.config = self:readConfig()
  self.halted = false
  self.pollTimer = nil
  self.zones, self.homeZone = {}, nil
  self.pollCount = 0
  self.lastGeocodeAt = 0
  self.geocodeCache = {}
  self.failureCount = 0

  self:updateView("lblStatus", "text", self:t("starting"))

  self:initChildDevices({
    ["com.fibaro.binarySensor"] = PinPawSensor,
    ["com.fibaro.multilevelSensor"] = PinPawSensor,
    ["com.fibaro.motionSensor"] = PinPawSensor,
  })
  self.childIndex = self:indexChildren()

  if self.config.token == "" then
    self:halt("noToken")
    return
  end
  if not PinPawApi.looksLikeToken(self.config.token) then
    self:halt("badTokenFormat")
    return
  end

  self.api = PinPawApi.new(self.config.baseUrl, self.config.token, self)
  self:refreshZones()
  self:loop()
end

--- Read QuickApp variables, writing defaults back so they appear in the UI
--- ready to be edited instead of the user having to know the names.
function QuickApp:readConfig()
  local function read(name, default)
    local value = self:getVariable(name)
    if value == nil or value == "" then
      if default ~= nil and default ~= "" then
        self:setVariable(name, default)
      end
      return default or ""
    end
    return value
  end

  local pollInterval = tonumber(read("pollInterval", DEFAULTS.pollInterval)) or 60

  return {
    token = self:getVariable("apiToken") or "",
    baseUrl = read("baseUrl", DEFAULTS.baseUrl),
    pollInterval = math.max(MIN_POLL_INTERVAL, math.floor(pollInterval)),
    language = read("language", DEFAULTS.language),
    reverseGeocode = read("reverseGeocode", DEFAULTS.reverseGeocode) == "true",
    primaryPet = read("primaryPet", DEFAULTS.primaryPet),
    homeLat = read("homeLat", DEFAULTS.homeLat),
    homeLon = read("homeLon", DEFAULTS.homeLon),
    homeRadius = read("homeRadius", DEFAULTS.homeRadius),
  }
end

function QuickApp:t(key, ...)
  if select("#", ...) > 0 then
    return PinPawI18n.format(self.config.language, key, ...)
  end
  return PinPawI18n.get(self.config.language, key)
end

--- Stop polling and park a message on the UI. Used for conditions that
--- retrying cannot fix -- a missing or rejected token.
function QuickApp:halt(messageKey)
  self.halted = true
  if self.pollTimer then
    fibaro.clearTimeout(self.pollTimer)
    self.pollTimer = nil
  end
  local message = self:t(messageKey)
  self:error(message)
  self:updateView("lblStatus", "text", message)
  self:updateProperty("log", message)
end

--------------------------------------------------------------------------------
-- Polling
--------------------------------------------------------------------------------

function QuickApp:loop()
  if self.halted then
    return
  end
  self:poll()
  self.pollTimer = fibaro.setTimeout(self.config.pollInterval * 1000, function()
    self:loop()
  end)
end

function QuickApp:poll()
  self.pollCount = self.pollCount + 1
  if self.pollCount % ZONE_REFRESH_EVERY == 1 then
    self:refreshZones()
  end

  self.api:getPets(function(pets)
    self.failureCount = 0
    self:onPets(pets)
  end, function(kind, message)
    self:onApiError(kind, message)
  end)
end

function QuickApp:onApiError(kind, message)
  if kind == "auth" then
    self:halt("authFailed")
    return
  end

  self.failureCount = self.failureCount + 1
  self:warning(string.format("PinPaw: %s", message))
  -- Only surface transient trouble on the UI once it stops looking transient,
  -- so a single dropped request does not wipe a good last-known position.
  if self.failureCount >= 3 then
    self:updateView("lblStatus", "text", self:t("connectionError", kind))
  end
end

function QuickApp:refreshZones()
  local zones, home = PinPawGeo.loadZones()

  -- Explicit coordinates win over the gateway's location panel.
  local manual = PinPawGeo.manualHome(
    self.config.homeLat,
    self.config.homeLon,
    self.config.homeRadius
  )
  if manual then
    -- Demote the gateway's own home zone, otherwise "at home" could resolve
    -- against the panel while "distance" is measured from the override.
    for _, zone in ipairs(zones) do
      zone.home = false
    end
    home = manual
    zones[#zones + 1] = manual
  elseif home and self.config.homeRadius ~= "" then
    -- Radius override without moving the home coordinate.
    home.radius = tonumber(self.config.homeRadius) or home.radius
  end

  self.zones, self.homeZone = zones, home
end

--------------------------------------------------------------------------------
-- Applying data
--------------------------------------------------------------------------------

function QuickApp:onPets(pets)
  if #pets == 0 then
    self:updateView("lblStatus", "text", self:t("noPets"))
    return
  end

  local primary = nil
  for _, pet in ipairs(pets) do
    if pet.id ~= nil then
      local state = self:buildState(pet)
      self:ensureChildren(pet)
      self:refreshChildren(state)
      if primary == nil or self:isPrimary(pet) then
        primary = state
      end
    end
  end

  if primary then
    self:updateMainView(primary)
  end
end

--- Which pet drives the QuickApp's own labels. Defaults to the first one.
function QuickApp:isPrimary(pet)
  local wanted = self.config.primaryPet
  if wanted == "" then
    return false
  end
  return tostring(pet.id) == wanted or pet.name == wanted
end

--- Flatten one pet into the snapshot the children and the UI both consume.
function QuickApp:buildState(pet)
  local position = pet.latestPosition or {}
  local lat = tonumber(position.latitude)
  local lon = tonumber(position.longitude)

  local state = {
    petId = pet.id,
    name = pet.name or ("Pet " .. tostring(pet.id)),
    latitude = lat,
    longitude = lon,
    batteryLevel = tonumber(position.batteryLevel),
    charging = position.charging,
    motion = position.motion,
    address = position.address,
    speed = tonumber(position.speed),
    trackingInterval = tonumber(pet.trackingInterval),
    lastUpdate = pet.deviceLastUpdate,
  }

  -- deviceStatus is the authoritative online flag when present, exactly as in
  -- the Home Assistant integration; latestPosition.online is the fallback.
  if pet.deviceStatus ~= nil then
    state.online = pet.deviceStatus == "online"
  else
    state.online = position.online
  end

  if lat and lon then
    local zone, zoneDistance = PinPawGeo.resolveZone(self.zones, lat, lon)
    state.zone = zone
    state.zoneDistance = zoneDistance
    state.atHome = zone ~= nil and zone.home == true

    if self.homeZone then
      state.distance = PinPawGeo.distance(
        self.homeZone.latitude,
        self.homeZone.longitude,
        lat,
        lon
      )
    end
  end

  return state
end

function QuickApp:refreshChildren(state)
  for _, spec in ipairs(PINPAW_CHILD_ROLES) do
    local child = self.childIndex[self:childKey(state.petId, spec.role)]
    if child then
      child:refresh(state)
    end
  end
end

--------------------------------------------------------------------------------
-- Child bookkeeping
--------------------------------------------------------------------------------

function QuickApp:childKey(petId, role)
  return tostring(petId) .. ":" .. role
end

--- Rebuild the pet/role -> child map from the children HC3 restored for us.
function QuickApp:indexChildren()
  local index = {}
  for _, child in pairs(self.childDevices) do
    if child.petId and child.role then
      index[self:childKey(child.petId, child.role)] = child
    end
  end
  return index
end

function QuickApp:ensureChildren(pet)
  for _, spec in ipairs(PINPAW_CHILD_ROLES) do
    local key = self:childKey(pet.id, spec.role)
    if not self.childIndex[key] then
      local petName = pet.name or ("Pet " .. tostring(pet.id))
      local child = self:createChildDevice({
        name = string.format("%s - %s", petName, spec.label),
        type = spec.type,
        initialProperties = spec.properties or {},
        initialInterfaces = spec.interfaces or {},
      }, PinPawSensor)

      child:setVariable("petId", tostring(pet.id))
      child:setVariable("role", spec.role)
      -- The constructor ran before those variables existed, so seed the
      -- in-memory copies too; the stored ones take over after a restart.
      child.petId = pet.id
      child.role = spec.role

      self.childIndex[key] = child
      self:debug(string.format("PinPaw: created child '%s'", spec.role))
    end
  end
end

--------------------------------------------------------------------------------
-- QuickApp view
--------------------------------------------------------------------------------

function QuickApp:updateMainView(state)
  self:updateView("lblStatus", "text", self:statusText(state))
  self:updateView("lblBattery", "text", self:batteryText(state))
  self:updateView("lblUpdated", "text", self:t("updated", self:formatTimestamp(state.lastUpdate)))
  self:updateProperty("log", self:statusText(state))
  self:resolveAddress(state)
end

function QuickApp:statusText(state)
  if not state.latitude or not state.longitude then
    return self:t("noPosition")
  end
  if state.atHome then
    return self:t("atHome")
  end
  if state.zone then
    return self:t("inZone", state.zone.name or "?")
  end
  if state.distance then
    return self:t("away", math.floor(state.distance + 0.5))
  end
  return self:t("awayNoHome")
end

function QuickApp:batteryText(state)
  if state.batteryLevel == nil then
    return self:t("batteryUnknown")
  end
  local key = state.charging and "batteryCharging" or "battery"
  return self:t(key, math.floor(state.batteryLevel + 0.5))
end

function QuickApp:formatTimestamp(value)
  if value == nil then
    return self:t("never")
  end
  if type(value) == "number" then
    -- Backends vary between seconds and milliseconds since the epoch.
    local seconds = value > 1e12 and math.floor(value / 1000) or math.floor(value)
    return os.date("%Y-%m-%d %H:%M:%S", seconds)
  end
  -- ISO 8601 -- trim to "YYYY-MM-DD HH:MM:SS" for the narrow label.
  return (tostring(value):gsub("T", " "):sub(1, 19))
end

--------------------------------------------------------------------------------
-- Address
--------------------------------------------------------------------------------

--- Prefer the address the backend already resolved; fall back to OpenStreetMap
--- only when the user opted in, and never faster than GEOCODE_MIN_INTERVAL.
function QuickApp:resolveAddress(state)
  if type(state.address) == "string" and state.address ~= "" then
    self:updateView("lblLocation", "text", state.address)
    return
  end

  if not state.latitude or not state.longitude then
    self:updateView("lblLocation", "text", "-")
    return
  end

  local coordinateText = string.format("%.5f, %.5f", state.latitude, state.longitude)

  if not self.config.reverseGeocode then
    self:updateView("lblLocation", "text", coordinateText)
    return
  end

  local cacheKey = string.format("%.4f/%.4f", state.latitude, state.longitude)
  if self.geocodeCache[cacheKey] then
    self:updateView("lblLocation", "text", self.geocodeCache[cacheKey])
    return
  end

  local now = os.time()
  if now - self.lastGeocodeAt < GEOCODE_MIN_INTERVAL then
    self:updateView("lblLocation", "text", coordinateText)
    return
  end
  self.lastGeocodeAt = now

  self:updateView("lblLocation", "text", coordinateText)
  self:geocode(state.latitude, state.longitude, cacheKey, coordinateText)
end

function QuickApp:geocode(lat, lon, cacheKey, fallback)
  self.geocodeHttp = self.geocodeHttp or net.HTTPClient({ timeout = 10000 })

  local url = string.format(
    "https://nominatim.openstreetmap.org/reverse?format=json&lat=%f&lon=%f&zoom=18&addressdetails=1",
    lat,
    lon
  )

  self.geocodeHttp:request(url, {
    options = {
      method = "GET",
      headers = {
        ["User-Agent"] = GEOCODE_USER_AGENT,
        ["Accept"] = "application/json",
      },
    },
    success = function(response)
      if tonumber(response.status) ~= 200 then
        return
      end
      local ok, data = pcall(json.decode, response.data)
      if not ok or type(data) ~= "table" or type(data.address) ~= "table" then
        return
      end

      local a = data.address
      local street = a.road or a.pedestrian or a.path
      local city = a.city or a.town or a.village
      local text

      if street then
        text = street
        if a.house_number then
          text = text .. " " .. a.house_number
        end
        if city then
          text = text .. ", " .. city
        end
      else
        text = data.display_name or fallback
      end

      self.geocodeCache[cacheKey] = text
      self:updateView("lblLocation", "text", text)
    end,
    error = function(err)
      self:debug(string.format("PinPaw: reverse geocoding failed: %s", tostring(err)))
    end,
  })
end

--------------------------------------------------------------------------------
-- Actions (UI button and scene-callable)
--------------------------------------------------------------------------------

function QuickApp:onRefreshClicked()
  if self.halted then
    return
  end
  self:poll()
end

--- Change a tracker's reporting interval, the QuickApp counterpart of the
--- number entity in the Home Assistant integration. Call from a scene with:
---   fibaro.call(<quickAppId>, "setPetTrackingInterval", <petId>, <seconds>)
function QuickApp:setPetTrackingInterval(petId, seconds)
  if not self.api then
    return
  end

  local value = tonumber(seconds)
  if not value then
    self:error("PinPaw: setPetTrackingInterval needs a numeric interval")
    return
  end

  self.api:setTrackingInterval(petId, math.floor(value), function()
    self:debug(string.format("PinPaw: interval for pet %s set to %ds", tostring(petId), value))
    self:poll()
  end, function(kind, message)
    self:onApiError(kind, message)
  end)
end
