--[[
Child devices -- one per pet, per measurement.

The Home Assistant integration exposes each pet as a device with several
entities hanging off it. HC3's equivalent is a device controller QuickApp with
child devices, so the entity list is mirrored here one-for-one, plus the two
values the HA integration gets for free from Zones (at-home / distance) which
on HC3 we have to compute ourselves.

    HA entity                       role         HC3 child type
    ---------------------------------------------------------------------
    sensor.battery                  battery      com.fibaro.multilevelSensor
    binary_sensor.online            online       com.fibaro.binarySensor
    binary_sensor.charging          charging     com.fibaro.binarySensor
    binary_sensor.battery_low       batteryLow   com.fibaro.binarySensor
    binary_sensor.lost              lost         com.fibaro.binarySensor
    (zone membership)               home         com.fibaro.binarySensor
    (distance to zone)              distance     com.fibaro.multilevelSensor
    -- latestPosition.motion        motion       com.fibaro.motionSensor
    switch.car_mode                 carMode      com.fibaro.binarySwitch
    select.walk_recording_mode      manualWalk   com.fibaro.binarySwitch
    switch.walk_active              walkActive   com.fibaro.binarySwitch
    switch.live_tracking            liveTracking com.fibaro.binarySwitch
    button.sleep_mode               sleep        com.fibaro.binarySwitch
    switch.led                      led          com.fibaro.binarySwitch
    switch.sound                    sound        com.fibaro.binarySwitch

All roles share ONE Lua class. QuickApp:initChildDevices maps children back to
classes by device *type* after a restart, and several roles here share a type
(four of them are com.fibaro.binarySensor, seven com.fibaro.binarySwitch), so a
class-per-role scheme would not survive a reboot -- HC3 could not tell which
class to rebuild. Instead each child stores its role in a QuickApp variable and
dispatches on it.

Switch roles carry a `writer`, called when HC3 turns the child on or off. It
hands the action back to the parent QuickApp, which owns the API client. Roles
with a `requires` list are only created for trackers whose protocol advertises
those commands, so a tracker with no LED gets no light child rather than one
that fails on every tap.
]]

-- Battery level (%) below which the "battery low" child turns on. Matches
-- LOW_BATTERY_THRESHOLD in the Home Assistant integration.
PINPAW_LOW_BATTERY_THRESHOLD = 20

--- The child roles to create for every pet, in display order.
PINPAW_CHILD_ROLES = {
  {
    role = "home",
    label = "At home",
    type = "com.fibaro.binarySensor",
  },
  {
    role = "distance",
    label = "Distance from home",
    type = "com.fibaro.multilevelSensor",
    properties = { unit = "m" },
  },
  {
    role = "battery",
    label = "Battery",
    type = "com.fibaro.multilevelSensor",
    properties = { unit = "%" },
    interfaces = { "battery" },
  },
  {
    role = "batteryLow",
    label = "Battery low",
    type = "com.fibaro.binarySensor",
  },
  {
    role = "online",
    label = "Online",
    type = "com.fibaro.binarySensor",
  },
  {
    role = "charging",
    label = "Charging",
    type = "com.fibaro.binarySensor",
  },
  {
    role = "motion",
    label = "Motion",
    type = "com.fibaro.motionSensor",
  },
  {
    role = "lost",
    label = "Reported lost",
    type = "com.fibaro.binarySensor",
  },
  {
    role = "carMode",
    label = "Car mode",
    type = "com.fibaro.binarySwitch",
    writer = "carMode",
  },
  {
    role = "manualWalk",
    label = "Manual walk mode",
    type = "com.fibaro.binarySwitch",
    writer = "manualWalk",
  },
  {
    role = "walkActive",
    label = "Walk recording",
    type = "com.fibaro.binarySwitch",
    writer = "walkActive",
  },
  {
    role = "liveTracking",
    label = "Live tracking",
    type = "com.fibaro.binarySwitch",
    writer = "liveTracking",
    requires = { PINPAW_CMD.liveTracking, PINPAW_CMD.defaultTracking },
  },
  {
    role = "sleep",
    label = "Sleeping mode",
    type = "com.fibaro.binarySwitch",
    writer = "sleep",
    requires = { PINPAW_CMD.savingTracking },
  },
  {
    role = "led",
    label = "Light",
    type = "com.fibaro.binarySwitch",
    writer = "led",
    requires = { PINPAW_CMD.ledOn, PINPAW_CMD.ledOff },
  },
  {
    role = "sound",
    label = "Sound",
    type = "com.fibaro.binarySwitch",
    writer = "sound",
    requires = { PINPAW_CMD.soundOn, PINPAW_CMD.soundOff },
  },
}

--- Role -> spec, for the dispatch below and the parent's gating checks.
PINPAW_ROLE_SPECS = {}
for _, spec in ipairs(PINPAW_CHILD_ROLES) do
  PINPAW_ROLE_SPECS[spec.role] = spec
end

class 'PinPawSensor' (QuickAppChild)

function PinPawSensor:__init(device)
  QuickAppChild.__init(self, device)
  -- Set from the stored variables on restart. Freshly created children get
  -- these assigned directly by the parent, because createChildDevice returns
  -- before setVariable has had a chance to run.
  self.petId = tonumber(self:getVariable("petId"))
  self.role = self:getVariable("role")
end

-- state fields are pre-computed by the parent so every child sees exactly the
-- same snapshot; a role whose value is missing this round is left untouched
-- rather than being reset to a wrong default.
local UPDATERS = {}

UPDATERS.battery = function(child, state)
  if state.batteryLevel == nil then
    return
  end
  child:updateProperty("value", state.batteryLevel)
  -- Also as batteryLevel so the HC3 UI shows its native battery indicator.
  child:updateProperty("batteryLevel", state.batteryLevel)
end

UPDATERS.batteryLow = function(child, state)
  if state.batteryLevel == nil then
    return
  end
  child:updateProperty("value", state.batteryLevel < PINPAW_LOW_BATTERY_THRESHOLD)
end

UPDATERS.online = function(child, state)
  if state.online == nil then
    return
  end
  child:updateProperty("value", state.online)
end

UPDATERS.charging = function(child, state)
  if state.charging == nil then
    return
  end
  child:updateProperty("value", state.charging)
end

UPDATERS.motion = function(child, state)
  if state.motion == nil then
    return
  end
  child:updateProperty("value", state.motion)
end

UPDATERS.home = function(child, state)
  if state.atHome == nil then
    return
  end
  child:updateProperty("value", state.atHome)
end

UPDATERS.distance = function(child, state)
  if state.distance == nil then
    return
  end
  child:updateProperty("value", math.floor(state.distance + 0.5))
end

UPDATERS.lost = function(child, state)
  if state.lost == nil then
    return
  end
  child:updateProperty("value", state.lost)
end

UPDATERS.carMode = function(child, state)
  if state.carMode == nil then
    return
  end
  child:updateProperty("value", state.carMode)
end

UPDATERS.manualWalk = function(child, state)
  if state.walkRecordingMode == nil then
    return
  end
  child:updateProperty("value", state.walkRecordingMode == "MANUAL")
end

UPDATERS.walkActive = function(child, state)
  if state.walkActive == nil then
    return
  end
  child:updateProperty("value", state.walkActive)
end

UPDATERS.liveTracking = function(child, state)
  if state.trackingMode == nil then
    return
  end
  child:updateProperty("value", state.trackingMode == "TRACKING")
end

UPDATERS.led = function(child, state)
  if state.led == nil then
    return
  end
  child:updateProperty("value", state.led)
end

UPDATERS.sound = function(child, state)
  if state.sound == nil then
    return
  end
  child:updateProperty("value", state.sound)
end

-- No updater for "sleep": it is a momentary button, not a state. The parent
-- pushes it back to false after the command goes out.

--- Apply one poll's snapshot to this child.
function PinPawSensor:refresh(state)
  local updater = UPDATERS[self.role]
  if updater then
    updater(self, state)
  end
end

--- HC3 calls these on a com.fibaro.binarySwitch child. Sensor roles have no
--- writer, so a stray call is ignored rather than reaching the API.
function PinPawSensor:turnOn()
  self:_write(true)
end

function PinPawSensor:turnOff()
  self:_write(false)
end

function PinPawSensor:_write(enabled)
  local spec = PINPAW_ROLE_SPECS[self.role]
  if not spec or not spec.writer then
    return
  end
  -- parentApp is assigned by the parent when it creates or re-indexes children;
  -- the child itself has no route back to the API client.
  if not self.parentApp then
    return
  end
  self.parentApp:applyControl(self.petId, spec.writer, enabled)
end
