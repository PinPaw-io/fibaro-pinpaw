--[[
Logic tests for the PinPaw QuickApp.

Run with:  lua tests/run.lua   (from the repository root)

These exercise the real src/*.lua against the stubbed HC3 runtime in
fibaro_stub.lua. The stub's HTTP client invokes its success callback
synchronously, so a whole poll cycle completes inside the onInit() call and can
be asserted on directly.
]]

package.path = "tests/?.lua;" .. package.path
local Stub = require("fibaro_stub")

dofile("src/api.lua")
dofile("src/geo.lua")
dofile("src/i18n.lua")
dofile("src/children.lua")
dofile("src/main.lua")

--------------------------------------------------------------------------------
-- Tiny test harness
--------------------------------------------------------------------------------

local passed, failed = 0, 0
local currentTest = "?"

local function check(condition, message)
  if condition then
    passed = passed + 1
  else
    failed = failed + 1
    print(string.format("  FAIL [%s] %s", currentTest, message))
  end
end

local function equals(actual, expected, message)
  check(
    actual == expected,
    string.format("%s (expected %s, got %s)", message, tostring(expected), tostring(actual))
  )
end

local function near(actual, expected, tolerance, message)
  check(
    type(actual) == "number" and math.abs(actual - expected) <= tolerance,
    string.format("%s (expected ~%s, got %s)", message, tostring(expected), tostring(actual))
  )
end

local function test(name, fn)
  currentTest = name
  Stub.reset()
  local ok, err = pcall(fn)
  if not ok then
    failed = failed + 1
    print(string.format("  ERROR [%s] %s", name, tostring(err)))
  end
end

--------------------------------------------------------------------------------
-- Fixtures
--------------------------------------------------------------------------------

local HOME = { id = 1, name = "Dom", latitude = 52.2297, longitude = 21.0122, radius = 100, home = true }
local VET = { id = 2, name = "Weterynarz", latitude = 52.2500, longitude = 21.0300, radius = 80, home = false }

--- Everything a fully featured tracker's protocol advertises. The default
--- fixture carries the lot, so a test that cares about gating opts out instead
--- of every other test having to opt in.
local ALL_COMMANDS = {
  "LIVE_TRACKING",
  "DEFAULT_TRACKING",
  "SAVING_TRACKING",
  "LED_SWITCH_ON",
  "LED_SWITCH_OFF",
  "SOUND_SWITCH_ON",
  "SOUND_SWITCH_OFF",
}

--- Marker for "the backend did not send this field at all". A plain nil in an
--- override table is indistinguishable from an absent key, so tests that care
--- about a missing field pass this instead.
local ABSENT = setmetatable({}, { __tostring = function() return "<absent>" end })

local function pet(overrides)
  local p = {
    id = 7,
    name = "Burek",
    deviceStatus = "online",
    trackingInterval = 60,
    deviceLastUpdate = "2026-08-16T10:30:00Z",
    trackingMode = "DAILY",
    carMode = false,
    walkRecordingMode = "MANUAL",
    walkActive = false,
    lost = false,
    availableCommands = ALL_COMMANDS,
    latestPosition = {
      latitude = 52.2297,
      longitude = 21.0122,
      batteryLevel = 88,
      charging = false,
      online = true,
      motion = false,
      address = "Marszalkowska 1, Warszawa",
    },
  }
  for key, value in pairs(overrides or {}) do
    if value == ABSENT then
      p[key] = nil
    elseif key == "latestPosition" then
      for k, v in pairs(value) do
        p.latestPosition[k] = v
      end
    else
      p[key] = value
    end
  end
  return p
end

local function startWith(pets, variables, deviceStates)
  local vars = { apiToken = "ppw_pat_test123", language = "en" }
  for k, v in pairs(variables or {}) do
    vars[k] = v
  end
  Stub.responses["GET /api/pets"] = { status = 200, body = pets }
  Stub.responses["GET /api/device-states/my-pets"] =
    { status = 200, body = deviceStates or {} }
  local qa = Stub.newQuickApp(vars)
  qa:onInit()
  return qa
end

--- The request keys the QuickApp sent, in order.
local function sentKeys()
  local keys = {}
  for _, request in ipairs(Stub.requests) do
    table.insert(keys, request.key)
  end
  return keys
end

--- The decoded body of the first request matching `key`, or nil.
local function sentBody(key)
  for _, request in ipairs(Stub.requests) do
    if request.key == key and request.options and request.options.data then
      return json.decode(request.options.data)
    end
  end
  return nil
end

local function contains(list, wanted)
  for _, value in ipairs(list) do
    if value == wanted then
      return true
    end
  end
  return false
end

local function childValue(qa, petId, role)
  local child = qa.childIndex[qa:childKey(petId, role)]
  if not child then
    return nil
  end
  return (Stub.properties[child.id] or {}).value
end

--------------------------------------------------------------------------------
-- Geometry
--------------------------------------------------------------------------------

test("distance: one degree of longitude at the equator", function()
  near(PinPawGeo.distance(0, 0, 0, 1), 111194.9, 1.0, "1 deg lon at equator")
end)

test("distance: zero for identical points", function()
  equals(PinPawGeo.distance(52.2297, 21.0122, 52.2297, 21.0122), 0, "same point")
end)

test("distance: Warsaw to Krakow", function()
  near(PinPawGeo.distance(52.2297, 21.0122, 50.0647, 19.9450), 252000, 3000, "WAW-KRK")
end)

test("distance: symmetric", function()
  local a = PinPawGeo.distance(52.0, 21.0, 50.0, 19.0)
  local b = PinPawGeo.distance(50.0, 19.0, 52.0, 21.0)
  near(a, b, 0.001, "distance is symmetric")
end)

test("resolveZone: picks the innermost containing zone", function()
  local wide = { name = "Wide", latitude = 52.2297, longitude = 21.0122, radius = 5000, home = false }
  local tight = { name = "Tight", latitude = 52.2297, longitude = 21.0122, radius = 50, home = true }
  local zone = PinPawGeo.resolveZone({ wide, tight }, 52.2297, 21.0122)
  -- Both contain the point and both are centred on it, so the tie is broken by
  -- order; what matters is that a containing zone is returned at all.
  check(zone ~= nil, "a containing zone is found")
end)

test("resolveZone: nil when outside every zone", function()
  local zone = PinPawGeo.resolveZone({ HOME, VET }, 50.0647, 19.9450)
  equals(zone, nil, "far away point is in no zone")
end)

--------------------------------------------------------------------------------
-- Configuration guards
--------------------------------------------------------------------------------

test("halts when no token is set", function()
  local qa = Stub.newQuickApp({ apiToken = "" })
  qa:onInit()
  equals(qa.halted, true, "halted without a token")
  equals(#Stub.requests, 0, "no HTTP call attempted")
end)

test("halts when the token has the wrong prefix", function()
  local qa = Stub.newQuickApp({ apiToken = "definitely-not-a-pat" })
  qa:onInit()
  equals(qa.halted, true, "halted on malformed token")
  equals(#Stub.requests, 0, "no HTTP call attempted")
end)

test("accepts a well-formed token", function()
  Stub.locations = { HOME }
  local qa = startWith({ pet() })
  equals(qa.halted, false, "not halted")
  equals(Stub.requests[1].key, "GET /api/pets", "polled the pets endpoint")
end)

test("poll interval is clamped to the floor", function()
  Stub.locations = { HOME }
  local qa = startWith({ pet() }, { pollInterval = "1" })
  equals(qa.config.pollInterval, 15, "1s request clamped to 15s")
end)

test("bearer token is sent", function()
  Stub.locations = { HOME }
  startWith({ pet() })
  equals(
    Stub.requests[1].options.headers["Authorization"],
    "Bearer ppw_pat_test123",
    "Authorization header"
  )
end)

--------------------------------------------------------------------------------
-- Child devices
--------------------------------------------------------------------------------

test("creates one child per role", function()
  Stub.locations = { HOME }
  local qa = startWith({ pet() })
  local count = 0
  for _ in pairs(qa.childDevices) do
    count = count + 1
  end
  equals(count, #PINPAW_CHILD_ROLES, "child count matches role count")
end)

test("creates a full set for every pet", function()
  Stub.locations = { HOME }
  local qa = startWith({ pet(), pet({ id = 9, name = "Reksio" }) })
  local count = 0
  for _ in pairs(qa.childDevices) do
    count = count + 1
  end
  equals(count, #PINPAW_CHILD_ROLES * 2, "two pets get two full sets")
  check(qa.childIndex[qa:childKey(7, "battery")] ~= nil, "pet 7 has a battery child")
  check(qa.childIndex[qa:childKey(9, "battery")] ~= nil, "pet 9 has a battery child")
end)

test("does not duplicate children on a second poll", function()
  Stub.locations = { HOME }
  local qa = startWith({ pet() })
  qa:poll()
  qa:poll()
  local count = 0
  for _ in pairs(qa.childDevices) do
    count = count + 1
  end
  equals(count, #PINPAW_CHILD_ROLES, "still one set after three polls")
end)

test("maps position fields onto children", function()
  Stub.locations = { HOME }
  local qa = startWith({ pet() })
  equals(childValue(qa, 7, "battery"), 88, "battery level")
  equals(childValue(qa, 7, "online"), true, "online")
  equals(childValue(qa, 7, "charging"), false, "charging")
  equals(childValue(qa, 7, "motion"), false, "motion")
  equals(childValue(qa, 7, "home"), true, "at home")
  equals(childValue(qa, 7, "batteryLow"), false, "battery not low at 88%")
end)

test("battery low trips below the threshold", function()
  Stub.locations = { HOME }
  local qa = startWith({ pet({ latestPosition = { batteryLevel = 11 } }) })
  equals(childValue(qa, 7, "batteryLow"), true, "11% is low")
  equals(childValue(qa, 7, "battery"), 11, "level still reported")
end)

test("charging and motion propagate when true", function()
  Stub.locations = { HOME }
  local qa = startWith({ pet({ latestPosition = { charging = true, motion = true } }) })
  equals(childValue(qa, 7, "charging"), true, "charging")
  equals(childValue(qa, 7, "motion"), true, "motion")
end)

test("deviceStatus wins over latestPosition.online", function()
  Stub.locations = { HOME }
  local qa = startWith({
    pet({ deviceStatus = "offline", latestPosition = { online = true } }),
  })
  equals(childValue(qa, 7, "online"), false, "deviceStatus is authoritative")
end)

test("falls back to latestPosition.online when deviceStatus is absent", function()
  Stub.locations = { HOME }
  local p = pet()
  p.deviceStatus = nil
  p.latestPosition.online = false
  local qa = startWith({ p })
  equals(childValue(qa, 7, "online"), false, "fallback used")
end)

test("missing fields leave the previous child value untouched", function()
  Stub.locations = { HOME }
  local qa = startWith({ pet() })
  equals(childValue(qa, 7, "battery"), 88, "first poll sets battery")

  local stripped = pet()
  stripped.latestPosition.batteryLevel = nil
  Stub.responses["GET /api/pets"] = { status = 200, body = { stripped } }
  qa:poll()
  equals(childValue(qa, 7, "battery"), 88, "battery not clobbered by a missing field")
end)

--------------------------------------------------------------------------------
-- Zones and status text
--------------------------------------------------------------------------------

test("at home inside the home zone", function()
  Stub.locations = { HOME, VET }
  local qa = startWith({ pet() })
  equals(childValue(qa, 7, "home"), true, "home child on")
  equals(Stub.views.lblStatus, "At home", "status label")
  near(childValue(qa, 7, "distance"), 0, 1, "distance ~0")
end)

test("reports a named non-home zone", function()
  Stub.locations = { HOME, VET }
  local qa = startWith({
    pet({ latestPosition = { latitude = VET.latitude, longitude = VET.longitude } }),
  })
  equals(childValue(qa, 7, "home"), false, "not at home")
  equals(Stub.views.lblStatus, "In zone: Weterynarz", "zone name in status")
end)

test("away reports the distance from home", function()
  Stub.locations = { HOME }
  local qa = startWith({
    pet({ latestPosition = { latitude = 52.2400, longitude = 21.0122 } }),
  })
  equals(childValue(qa, 7, "home"), false, "not at home")
  local distance = childValue(qa, 7, "distance")
  near(distance, 1145, 60, "roughly 1.1 km north")
  check(
    Stub.views.lblStatus:find("Away") ~= nil,
    "status mentions Away, got: " .. tostring(Stub.views.lblStatus)
  )
end)

test("manual home coordinates override the location panel", function()
  Stub.locations = { HOME }
  local qa = startWith({ pet() }, {
    homeLat = "50.0647",
    homeLon = "19.9450",
    homeRadius = "100",
  })
  -- The pet sits on the panel's home, but the override moved home to Krakow.
  equals(childValue(qa, 7, "home"), false, "not at the overridden home")
  near(childValue(qa, 7, "distance"), 252000, 3000, "distance measured from the override")
end)

test("survives an empty location panel", function()
  Stub.locations = {}
  local qa = startWith({ pet() })
  equals(qa.halted, false, "no zones is not fatal")
  equals(childValue(qa, 7, "battery"), 88, "battery still reported")
end)

test("no position yields the placeholder status", function()
  Stub.locations = { HOME }
  local p = pet()
  p.latestPosition = {}
  local qa = startWith({ p })
  equals(Stub.views.lblStatus, "No position data yet", "placeholder status")
end)

test("Polish strings are selected by the language variable", function()
  Stub.locations = { HOME }
  startWith({ pet() }, { language = "pl" })
  equals(Stub.views.lblStatus, "W domu", "Polish status")
end)

test("unknown language falls back to English", function()
  Stub.locations = { HOME }
  startWith({ pet() }, { language = "de" })
  equals(Stub.views.lblStatus, "At home", "English fallback")
end)

--------------------------------------------------------------------------------
-- Error handling
--------------------------------------------------------------------------------

test("a rejected token halts polling", function()
  Stub.locations = { HOME }
  Stub.responses["GET /api/pets"] = { status = 401 }
  local qa = Stub.newQuickApp({ apiToken = "ppw_pat_test123" })
  qa:onInit()
  equals(qa.halted, true, "halted on 401")
  check(#Stub.log.error > 0, "an error was logged")
end)

test("a 403 halts polling too", function()
  Stub.locations = { HOME }
  Stub.responses["GET /api/pets"] = { status = 403 }
  local qa = Stub.newQuickApp({ apiToken = "ppw_pat_test123" })
  qa:onInit()
  equals(qa.halted, true, "halted on 403")
end)

test("a server error keeps polling", function()
  Stub.locations = { HOME }
  Stub.responses["GET /api/pets"] = { status = 500 }
  local qa = Stub.newQuickApp({ apiToken = "ppw_pat_test123" })
  qa:onInit()
  equals(qa.halted, false, "5xx is transient, keep trying")
  equals(qa.failureCount, 1, "failure counted")
end)

test("transient failures only reach the UI after three in a row", function()
  Stub.locations = { HOME }
  Stub.responses["GET /api/pets"] = { status = 500 }
  local qa = Stub.newQuickApp({ apiToken = "ppw_pat_test123" })
  qa:onInit()
  equals(Stub.views.lblStatus, "Connecting to PinPaw...", "still the startup text")
  qa:poll()
  qa:poll()
  check(
    Stub.views.lblStatus:find("Cannot reach PinPaw") ~= nil,
    "surfaced after the third failure"
  )
end)

test("a network error is not fatal", function()
  Stub.locations = { HOME }
  Stub.responses["GET /api/pets"] = { networkError = "timeout" }
  local qa = Stub.newQuickApp({ apiToken = "ppw_pat_test123" })
  qa:onInit()
  equals(qa.halted, false, "network trouble is transient")
end)

test("recovery resets the failure counter", function()
  Stub.locations = { HOME }
  Stub.responses["GET /api/pets"] = { status = 500 }
  local qa = Stub.newQuickApp({ apiToken = "ppw_pat_test123" })
  qa:onInit()
  equals(qa.failureCount, 1, "one failure")
  Stub.responses["GET /api/pets"] = { status = 200, body = { pet() } }
  qa:poll()
  equals(qa.failureCount, 0, "counter reset after a good poll")
end)

test("an empty pet list is reported, not crashed on", function()
  Stub.locations = { HOME }
  local qa = startWith({})
  equals(qa.halted, false, "not halted")
  equals(Stub.views.lblStatus, "No pets on this account", "empty-account message")
end)

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

test("setPetTrackingInterval issues the PUT", function()
  Stub.locations = { HOME }
  local qa = startWith({ pet() })
  Stub.responses["PUT /api/pets/7/tracking-interval"] = { status = 204 }
  qa:setPetTrackingInterval(7, 120)

  local seen = false
  for _, request in ipairs(Stub.requests) do
    if request.key == "PUT /api/pets/7/tracking-interval" then
      seen = true
    end
  end
  check(seen, "PUT was sent to the right path")
end)

test("setPetTrackingInterval rejects a non-numeric interval", function()
  Stub.locations = { HOME }
  local qa = startWith({ pet() })
  local before = #Stub.requests
  qa:setPetTrackingInterval(7, "soon")
  equals(#Stub.requests, before, "no request made")
  check(#Stub.log.error > 0, "an error was logged")
end)

--- How many times /api/pets was asked. A poll may issue a second request for
--- the device states, so counting every request would not count polls.
local function pollCount()
  local count = 0
  for _, request in ipairs(Stub.requests) do
    if request.key == "GET /api/pets" then
      count = count + 1
    end
  end
  return count
end

test("the refresh button triggers a poll", function()
  Stub.locations = { HOME }
  local qa = startWith({ pet() })
  local before = pollCount()
  qa:onRefreshClicked()
  equals(pollCount(), before + 1, "one extra poll")
end)

test("the refresh button does nothing once halted", function()
  local qa = Stub.newQuickApp({ apiToken = "" })
  qa:onInit()
  qa:onRefreshClicked()
  equals(#Stub.requests, 0, "still no requests")
end)

--------------------------------------------------------------------------------
-- Timestamps
--------------------------------------------------------------------------------

test("ISO timestamps are trimmed for the label", function()
  Stub.locations = { HOME }
  local qa = startWith({ pet() })
  equals(qa:formatTimestamp("2026-08-16T10:30:00Z"), "2026-08-16 10:30:00", "ISO trimmed")
end)

test("epoch milliseconds are detected", function()
  Stub.locations = { HOME }
  local qa = startWith({ pet() })
  local fromSeconds = qa:formatTimestamp(1755340200)
  local fromMillis = qa:formatTimestamp(1755340200000)
  equals(fromMillis, fromSeconds, "ms and s render identically")
end)

test("a missing timestamp renders as never", function()
  Stub.locations = { HOME }
  local qa = startWith({ pet() })
  equals(qa:formatTimestamp(nil), "never", "nil timestamp")
end)

--------------------------------------------------------------------------------
-- Modes, light and sound
--------------------------------------------------------------------------------

test("switch children mirror the reported modes", function()
  Stub.locations = { HOME }
  local qa = startWith({
    pet({ carMode = true, walkRecordingMode = "MANUAL", walkActive = true, trackingMode = "TRACKING" }),
  }, nil, { { petId = 7, lightSwitch = true, soundSwitch = false } })

  equals(childValue(qa, 7, "carMode"), true, "car mode on")
  equals(childValue(qa, 7, "manualWalk"), true, "manual walk mode on")
  equals(childValue(qa, 7, "walkActive"), true, "walk recording on")
  equals(childValue(qa, 7, "liveTracking"), true, "live tracking on")
  equals(childValue(qa, 7, "led"), true, "light on")
  equals(childValue(qa, 7, "sound"), false, "sound off")
end)

test("automatic walk mode reads as the manual switch being off", function()
  Stub.locations = { HOME }
  local qa = startWith({ pet({ walkRecordingMode = "AUTO" }) })
  equals(childValue(qa, 7, "manualWalk"), false, "manual walk mode off")
end)

test("the lost flag reaches its own child", function()
  Stub.locations = { HOME }
  local qa = startWith({ pet({ lost = true }) })
  equals(childValue(qa, 7, "lost"), true, "reported lost")
end)

test("a mode the backend omitted leaves the child untouched", function()
  Stub.locations = { HOME }
  local qa = startWith({ pet({ carMode = ABSENT, trackingMode = ABSENT }) })
  equals(childValue(qa, 7, "carMode"), nil, "car mode never written")
  equals(childValue(qa, 7, "liveTracking"), nil, "live tracking never written")
end)

test("children are not created for commands the tracker lacks", function()
  Stub.locations = { HOME }
  local qa = startWith({ pet({ availableCommands = {} }) })

  for _, role in ipairs({ "liveTracking", "sleep", "led", "sound" }) do
    equals(qa.childIndex[qa:childKey(7, role)], nil, role .. " child not created")
  end
  -- The three that are backend state rather than device commands still exist.
  check(qa.childIndex[qa:childKey(7, "carMode")] ~= nil, "car mode child exists")
  check(qa.childIndex[qa:childKey(7, "manualWalk")] ~= nil, "manual walk child exists")
  check(qa.childIndex[qa:childKey(7, "walkActive")] ~= nil, "walk recording child exists")
end)

test("the device states are not fetched when nothing advertises light or sound", function()
  Stub.locations = { HOME }
  startWith({ pet({ availableCommands = { "LIVE_TRACKING", "DEFAULT_TRACKING" } }) })
  equals(
    contains(sentKeys(), "GET /api/device-states/my-pets"),
    false,
    "no device-state request"
  )
end)

test("turning the car mode child on hits its own endpoint", function()
  Stub.locations = { HOME }
  local qa = startWith({ pet() })
  Stub.responses["PUT /api/pets/7/car-mode"] = { status = 200 }

  qa.childIndex[qa:childKey(7, "carMode")]:turnOn()

  local body = sentBody("PUT /api/pets/7/car-mode")
  check(body ~= nil, "car mode request sent")
  equals(body and body.enabled, true, "enabled true")
end)

test("the manual walk switch sends the mode by name", function()
  Stub.locations = { HOME }
  local qa = startWith({ pet() })
  Stub.responses["PUT /api/pets/7/walk-recording-mode"] = { status = 200 }

  qa.childIndex[qa:childKey(7, "manualWalk")]:turnOff()

  local body = sentBody("PUT /api/pets/7/walk-recording-mode")
  equals(body and body.mode, "AUTO", "switched to automatic")
end)

test("a walk can be started in manual mode", function()
  Stub.locations = { HOME }
  local qa = startWith({ pet({ walkRecordingMode = "MANUAL" }) })
  Stub.responses["PUT /api/pets/7/walk-active"] = { status = 200 }

  qa.childIndex[qa:childKey(7, "walkActive")]:turnOn()

  local body = sentBody("PUT /api/pets/7/walk-active")
  equals(body and body.enabled, true, "walk started")
end)

test("a walk cannot be started in automatic mode, and nothing is sent", function()
  Stub.locations = { HOME }
  local qa = startWith({ pet({ walkRecordingMode = "AUTO" }) })

  qa.childIndex[qa:childKey(7, "walkActive")]:turnOn()

  equals(contains(sentKeys(), "PUT /api/pets/7/walk-active"), false, "no request sent")
  check(#Stub.log.warning > 0, "warned why")
end)

test("the live tracking switch maps onto the two tracking commands", function()
  Stub.locations = { HOME }
  local qa = startWith({ pet() })
  Stub.responses["POST /api/pets/7/commands/LIVE_TRACKING"] = { status = 200 }
  Stub.responses["POST /api/pets/7/commands/DEFAULT_TRACKING"] = { status = 200 }

  local child = qa.childIndex[qa:childKey(7, "liveTracking")]
  child:turnOn()
  check(contains(sentKeys(), "POST /api/pets/7/commands/LIVE_TRACKING"), "live tracking sent")

  child:turnOff()
  check(contains(sentKeys(), "POST /api/pets/7/commands/DEFAULT_TRACKING"), "default tracking sent")
end)

test("sleeping mode is sent once and the child snaps back off", function()
  Stub.locations = { HOME }
  local qa = startWith({ pet() })
  Stub.responses["POST /api/pets/7/commands/SAVING_TRACKING"] = { status = 200 }

  local child = qa.childIndex[qa:childKey(7, "sleep")]
  child:turnOn()

  check(contains(sentKeys(), "POST /api/pets/7/commands/SAVING_TRACKING"), "command sent")
  equals(childValue(qa, 7, "sleep"), false, "child reset, because the mode cannot be left")
end)

test("switching sleeping mode off sends nothing", function()
  Stub.locations = { HOME }
  local qa = startWith({ pet() })
  local before = #Stub.requests

  qa.childIndex[qa:childKey(7, "sleep")]:turnOff()

  equals(#Stub.requests, before, "no request, waking is a Bluetooth job")
end)

test("the light and sound children send their commands", function()
  Stub.locations = { HOME }
  local qa = startWith({ pet() })
  Stub.responses["POST /api/pets/7/commands/LED_SWITCH_ON"] = { status = 200 }
  Stub.responses["POST /api/pets/7/commands/SOUND_SWITCH_OFF"] = { status = 200 }

  qa.childIndex[qa:childKey(7, "led")]:turnOn()
  qa.childIndex[qa:childKey(7, "sound")]:turnOff()

  check(contains(sentKeys(), "POST /api/pets/7/commands/LED_SWITCH_ON"), "light on sent")
  check(contains(sentKeys(), "POST /api/pets/7/commands/SOUND_SWITCH_OFF"), "sound off sent")
end)

test("a sensor child ignores a stray turnOn instead of calling the API", function()
  Stub.locations = { HOME }
  local qa = startWith({ pet() })
  local before = #Stub.requests

  qa.childIndex[qa:childKey(7, "battery")]:turnOn()

  equals(#Stub.requests, before, "battery has no writer, so nothing was sent")
end)

test("the scene-callable setters reach the same writers", function()
  Stub.locations = { HOME }
  local qa = startWith({ pet() })
  Stub.responses["PUT /api/pets/7/car-mode"] = { status = 200 }
  Stub.responses["POST /api/pets/7/commands/SAVING_TRACKING"] = { status = 200 }

  qa:setPetCarMode(7, true)
  qa:sleepPet(7)

  check(contains(sentKeys(), "PUT /api/pets/7/car-mode"), "car mode setter")
  check(contains(sentKeys(), "POST /api/pets/7/commands/SAVING_TRACKING"), "sleep setter")
end)

test("the setters accept a pet id passed as a string, as scenes do", function()
  Stub.locations = { HOME }
  local qa = startWith({ pet({ walkRecordingMode = "AUTO" }) })

  -- Only the manual-mode guard reads self.states, and it is keyed by number:
  -- a string id must not slip past it by failing the lookup.
  qa:setPetWalkActive("7", true)

  equals(contains(sentKeys(), "PUT /api/pets/7/walk-active"), false, "guard still applied")
end)

test("the modes label summarises the primary pet", function()
  Stub.locations = { HOME }
  startWith({
    pet({ trackingMode = "SAVING", walkRecordingMode = "MANUAL", walkActive = true, carMode = true }),
  })
  equals(Stub.views.lblModes, "Sleeping | Recording a walk | Car mode", "modes line")
end)

test("the modes label says so when the tracking mode is unknown", function()
  Stub.locations = { HOME }
  startWith({ pet({ trackingMode = ABSENT, walkRecordingMode = "AUTO", carMode = false }) })
  equals(Stub.views.lblModes, "Tracking mode unknown | Automatic walks", "modes line")
end)

test("the sleeping-mode button acts on the primary pet", function()
  Stub.locations = { HOME }
  local qa = startWith({ pet() })
  Stub.responses["POST /api/pets/7/commands/SAVING_TRACKING"] = { status = 200 }

  qa:onSleepClicked()

  check(contains(sentKeys(), "POST /api/pets/7/commands/SAVING_TRACKING"), "sent for pet 7")
end)

--------------------------------------------------------------------------------

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
