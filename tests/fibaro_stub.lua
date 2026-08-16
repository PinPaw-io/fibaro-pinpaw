--[[
Minimal stand-in for the HC3 QuickApp runtime, so the integration's logic can
be exercised with a plain `lua` binary.

This is NOT an emulator. It implements just enough of the globals HC3 injects
(class, QuickApp, QuickAppChild, net, json, api, fibaro) for the polling and
state-mapping code to run, and records everything the QuickApp does so tests
can assert on it.

json.decode is deliberately a sentinel lookup rather than a real parser: the
fake HTTP client hands back a marker string and this maps it to a prepared Lua
table. Parsing real JSON would be testing Lua, not testing PinPaw.
]]

local Stub = {}

--------------------------------------------------------------------------------
-- Fibaro's class system
--------------------------------------------------------------------------------

-- HC3 exposes `class 'Name' (Parent)`, which is plain Lua: a call with a string
-- literal returning a function that is then called with the parent.
function class(name)
  return function(parent)
    local cls = {}
    cls.__index = cls
    cls.__name = name
    if parent then
      setmetatable(cls, { __index = parent })
    end
    _G[name] = setmetatable(cls, {
      __index = parent,
      __call = function(c, ...)
        local instance = setmetatable({}, c)
        if instance.__init then
          instance:__init(...)
        end
        return instance
      end,
    })
    return cls
  end
end

--------------------------------------------------------------------------------
-- Recording sinks the tests assert against
--------------------------------------------------------------------------------

Stub.log = { debug = {}, error = {}, warning = {} }
Stub.views = {}
Stub.properties = {}
Stub.timers = {}
Stub.requests = {}

--- Responses the fake HTTP client serves, keyed by "METHOD path".
--- Each entry: { status = 200, body = <lua table or nil> }
Stub.responses = {}

--- What api.get("/panels/location") returns.
Stub.locations = {}

function Stub.reset()
  Stub.log = { debug = {}, error = {}, warning = {} }
  Stub.views = {}
  Stub.properties = {}
  Stub.timers = {}
  Stub.requests = {}
  Stub.responses = {}
  Stub.locations = {}
  Stub.nextDeviceId = 100
end

Stub.nextDeviceId = 100

--------------------------------------------------------------------------------
-- json
--------------------------------------------------------------------------------

local sentinels = {}
local sentinelCount = 0

--- Register a Lua table as an HTTP body and return the marker string that the
--- fake transport will carry and json.decode will map back.
function Stub.body(value)
  sentinelCount = sentinelCount + 1
  local marker = "<<json:" .. sentinelCount .. ">>"
  sentinels[marker] = value
  return marker
end

json = {
  decode = function(text)
    if sentinels[text] ~= nil then
      return sentinels[text]
    end
    error("stub json.decode got unregistered payload: " .. tostring(text))
  end,
  encode = function(value)
    return Stub.body(value)
  end,
}

--------------------------------------------------------------------------------
-- net.HTTPClient
--------------------------------------------------------------------------------

local HTTPClient = {}
HTTPClient.__index = HTTPClient

function HTTPClient:request(url, config)
  local method = config.options and config.options.method or "GET"
  local path = url:gsub("^https?://[^/]+", "")
  local key = method .. " " .. path

  table.insert(Stub.requests, { key = key, url = url, options = config.options })

  local canned = Stub.responses[key]
  if canned == nil then
    if config.error then
      config.error("no stubbed response for " .. key)
    end
    return
  end

  if canned.networkError then
    config.error(canned.networkError)
    return
  end

  config.success({
    status = canned.status or 200,
    data = canned.body ~= nil and Stub.body(canned.body) or "",
  })
end

net = {
  HTTPClient = function()
    return setmetatable({}, HTTPClient)
  end,
}

--------------------------------------------------------------------------------
-- Local HC3 REST API
--------------------------------------------------------------------------------

api = {
  get = function(path)
    if path == "/panels/location" then
      return Stub.locations, 200
    end
    error("stub api.get: unhandled path " .. tostring(path))
  end,
}

--------------------------------------------------------------------------------
-- fibaro
--------------------------------------------------------------------------------

fibaro = {
  setTimeout = function(ms, fn)
    local handle = { ms = ms, fn = fn, cancelled = false }
    table.insert(Stub.timers, handle)
    return handle
  end,
  clearTimeout = function(handle)
    if type(handle) == "table" then
      handle.cancelled = true
    end
  end,
}

--------------------------------------------------------------------------------
-- QuickApp / QuickAppChild
--------------------------------------------------------------------------------

local Device = {}
Device.__index = Device

function Device:debug(...)
  table.insert(Stub.log.debug, table.concat({ ... }, " "))
end

function Device:error(...)
  table.insert(Stub.log.error, table.concat({ ... }, " "))
end

function Device:warning(...)
  table.insert(Stub.log.warning, table.concat({ ... }, " "))
end

function Device:trace(...) end

function Device:getVariable(name)
  return (self._variables or {})[name] or ""
end

function Device:setVariable(name, value)
  self._variables = self._variables or {}
  self._variables[name] = value
end

function Device:updateView(element, property, value)
  Stub.views[element] = value
end

function Device:updateProperty(name, value)
  Stub.properties[self.id or "parent"] = Stub.properties[self.id or "parent"] or {}
  Stub.properties[self.id or "parent"][name] = value
end

QuickAppChild = setmetatable({}, { __index = Device })
QuickAppChild.__index = QuickAppChild

function QuickAppChild:__init(device)
  self.id = device.id
  self.name = device.name
  self.type = device.type
  self._variables = device._variables or {}
end

QuickApp = setmetatable({}, { __index = Device })
QuickApp.__index = QuickApp

--- Build a QuickApp instance with the given variables already set.
function Stub.newQuickApp(variables)
  local instance = setmetatable({}, QuickApp)
  instance.id = 1
  instance._variables = {}
  for name, value in pairs(variables or {}) do
    instance._variables[name] = value
  end
  instance.childDevices = {}
  return instance
end

function QuickApp:initChildDevices(_map)
  -- Fresh install: HC3 has nothing to restore. Tests that need restored
  -- children populate self.childDevices before calling onInit.
  self.childDevices = self.childDevices or {}
end

function QuickApp:createChildDevice(properties, cls)
  Stub.nextDeviceId = Stub.nextDeviceId + 1
  local device = {
    id = Stub.nextDeviceId,
    name = properties.name,
    type = properties.type,
    _variables = {},
  }
  local child = setmetatable({}, cls)
  child:__init(device)
  child.initialProperties = properties.initialProperties
  child.initialInterfaces = properties.initialInterfaces
  self.childDevices[device.id] = child
  return child
end

return Stub
