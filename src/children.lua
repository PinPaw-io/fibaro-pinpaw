--[[
Child devices -- one per pet, per measurement.

The Home Assistant integration exposes each pet as a device with several
entities hanging off it. HC3's equivalent is a device controller QuickApp with
child devices, so the entity list is mirrored here one-for-one, plus the two
values the HA integration gets for free from Zones (at-home / distance) which
on HC3 we have to compute ourselves.

    HA entity                       role        HC3 child type
    ---------------------------------------------------------------------
    sensor.battery                  battery     com.fibaro.multilevelSensor
    binary_sensor.online            online      com.fibaro.binarySensor
    binary_sensor.charging          charging    com.fibaro.binarySensor
    binary_sensor.battery_low       batteryLow  com.fibaro.binarySensor
    (zone membership)               home        com.fibaro.binarySensor
    (distance to zone)              distance    com.fibaro.multilevelSensor
    -- latestPosition.motion        motion      com.fibaro.motionSensor

All roles share ONE Lua class. QuickApp:initChildDevices maps children back to
classes by device *type* after a restart, and several roles here share a type
(three of them are com.fibaro.binarySensor), so a class-per-role scheme would
not survive a reboot -- HC3 could not tell which class to rebuild. Instead each
child stores its role in a QuickApp variable and dispatches on it.
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
}

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

--- Apply one poll's snapshot to this child.
function PinPawSensor:refresh(state)
  local updater = UPDATERS[self.role]
  if updater then
    updater(self, state)
  end
end
