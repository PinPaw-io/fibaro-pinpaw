--[[
Geofencing helpers.

The Home Assistant integration deliberately implements no geofencing of its
own: it publishes the pet as a device_tracker and lets Home Assistant Zones
drive the automations. This module is the Fibaro equivalent of that decision --
HC3 already models zones in Settings > Location (GET /panels/location), each
with a name, coordinates and a radius, and exactly one of them flagged as home.

So rather than hardcoding a home coordinate in the QuickApp source, we read the
zones the user already configured on their gateway. A pet is "at home" when it
is inside the radius of the zone flagged home, and any other configured zone
("Vet", "Park", ...) is reported by name.

Manual homeLat/homeLon/homeRadius QuickApp variables act as an override for
gateways where the location panel was never filled in.
]]

PinPawGeo = {}

local EARTH_RADIUS_M = 6371000

--- Great-circle distance in metres between two WGS84 points.
---
--- Uses the 2*asin(sqrt(a)) form of the haversine formula rather than the more
--- commonly seen atan2 form: Lua 5.3 (which HC3 runs) dropped math.atan2 in
--- favour of math.atan(y, x), so the atan2 spelling is not portable. The clamp
--- guards against sqrt(a) drifting a hair above 1 through rounding on
--- antipodal points, which would make asin return nan.
function PinPawGeo.distance(lat1, lon1, lat2, lon2)
  local dLat = math.rad(lat2 - lat1)
  local dLon = math.rad(lon2 - lon1)
  local a = math.sin(dLat / 2) ^ 2
    + math.cos(math.rad(lat1)) * math.cos(math.rad(lat2)) * math.sin(dLon / 2) ^ 2
  return 2 * EARTH_RADIUS_M * math.asin(math.min(1, math.sqrt(a)))
end

--- Read the zones configured on this gateway.
--- Returns (zones, homeZone). homeZone is nil when the user never flagged one.
---
--- api.get is the QuickApp's in-process handle to the local HC3 REST API, so
--- this needs no credentials. It is wrapped in pcall because a gateway with an
--- empty location panel is a normal state, not an error worth crashing over.
function PinPawGeo.loadZones()
  local ok, locations = pcall(function()
    return api.get("/panels/location")
  end)

  if not ok or type(locations) ~= "table" then
    return {}, nil
  end

  local zones, home = {}, nil
  for _, loc in ipairs(locations) do
    local lat, lon = tonumber(loc.latitude), tonumber(loc.longitude)
    if lat and lon then
      local zone = {
        id = loc.id,
        name = loc.name,
        latitude = lat,
        longitude = lon,
        radius = tonumber(loc.radius) or 100,
        home = loc.home == true,
      }
      zones[#zones + 1] = zone
      if zone.home then
        home = zone
      end
    end
  end

  return zones, home
end

--- Build the home zone from explicit QuickApp variables, when set.
function PinPawGeo.manualHome(lat, lon, radius, name)
  lat, lon = tonumber(lat), tonumber(lon)
  if not lat or not lon then
    return nil
  end
  return {
    name = name or "Home",
    latitude = lat,
    longitude = lon,
    radius = tonumber(radius) or 100,
    home = true,
    manual = true,
  }
end

--- Innermost zone containing the point, or nil when the pet is outside them all.
--- "Innermost" (smallest distance-to-centre) so a small zone nested inside a
--- larger one wins, which is what a user who drew both would expect.
function PinPawGeo.resolveZone(zones, lat, lon)
  local best, bestDistance = nil, nil
  for _, zone in ipairs(zones) do
    local d = PinPawGeo.distance(zone.latitude, zone.longitude, lat, lon)
    if d <= zone.radius and (bestDistance == nil or d < bestDistance) then
      best, bestDistance = zone, d
    end
  end
  return best, bestDistance
end
