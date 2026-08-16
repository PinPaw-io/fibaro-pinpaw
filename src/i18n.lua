--[[
UI strings.

The Home Assistant integration ships translations/en.json and pl.json; this is
the QuickApp equivalent. Selected with the `language` QuickApp variable, and
falls back to English for any key a translation is missing.
]]

PinPawI18n = {}

local STRINGS = {
  en = {
    atHome = "At home",
    inZone = "In zone: %s",
    away = "Away (%d m from home)",
    awayNoHome = "Position known (no home zone set)",
    noPosition = "No position data yet",
    battery = "Battery: %d%%",
    batteryCharging = "Battery: %d%% (charging)",
    batteryUnknown = "Battery: unknown",
    updated = "Updated %s",
    never = "never",
    noToken = "Set the apiToken variable to a PinPaw token",
    badTokenFormat = "apiToken does not look like a PinPaw token (ppw_pat_...)",
    authFailed = "Token rejected - check apiToken",
    connectionError = "Cannot reach PinPaw (%s)",
    noPets = "No pets on this account",
    starting = "Connecting to PinPaw...",
  },
  pl = {
    atHome = "W domu",
    inZone = "W strefie: %s",
    away = "Poza domem (%d m od domu)",
    awayNoHome = "Pozycja znana (brak strefy domowej)",
    noPosition = "Brak danych o lokalizacji",
    battery = "Bateria: %d%%",
    batteryCharging = "Bateria: %d%% (ładowanie)",
    batteryUnknown = "Bateria: brak danych",
    updated = "Aktualizacja %s",
    never = "nigdy",
    noToken = "Ustaw zmienną apiToken na token PinPaw",
    badTokenFormat = "apiToken nie wygląda na token PinPaw (ppw_pat_...)",
    authFailed = "Token odrzucony — sprawdź apiToken",
    connectionError = "Brak połączenia z PinPaw (%s)",
    noPets = "Brak zwierząt na tym koncie",
    starting = "Łączenie z PinPaw...",
  },
}

--- Look up `key` in `language`, falling back to English.
function PinPawI18n.get(language, key)
  local table_ = STRINGS[language] or STRINGS.en
  return table_[key] or STRINGS.en[key] or key
end

--- Look up and string.format in one step.
function PinPawI18n.format(language, key, ...)
  return string.format(PinPawI18n.get(language, key), ...)
end
