# PinPaw Pet Tracker for Fibaro HC3

QuickApp integration for the [PinPaw](https://pinpaw.io) GPS pet tracker on
Fibaro Home Center 3. It is the Fibaro counterpart of the
[Home Assistant integration](https://github.com/PinPaw-io/homeassistant-pinpaw)
and exposes the same measurements and mode controls, as native HC3 child
devices you can use in blocks, scenes and the mobile app.

> **Status: experimental. Not yet verified on real hardware.**
> The API client, geofencing, state mapping and error handling are covered by
> 106 automated tests that run against a stubbed HC3 runtime (`lua tests/run.lua`),
> but the package has not yet been installed on a physical Home Center 3.
> Expect rough edges around the HC3-specific parts, the `.fqa` import and the
> UI layout in particular. Please report what you hit.

## What you get

One QuickApp per account, and a set of child devices per pet:

| Child device | HC3 type | Value |
| --- | --- | --- |
| At home | `com.fibaro.binarySensor` | Inside the home zone |
| Distance from home | `com.fibaro.multilevelSensor` | Metres from the home zone centre |
| Battery | `com.fibaro.multilevelSensor` | Percent, also as a native battery level |
| Battery low | `com.fibaro.binarySensor` | Below 20% |
| Online | `com.fibaro.binarySensor` | Tracker reachable |
| Charging | `com.fibaro.binarySensor` | On the charger |
| Motion | `com.fibaro.motionSensor` | Device reports movement |
| Reported lost | `com.fibaro.binarySensor` | Pet is marked lost in the app |

And a switch per mode the tracker supports:

| Child device | HC3 type | What it does |
| --- | --- | --- |
| Car mode | `com.fibaro.binarySwitch` | Suspends walk recording while the pet is riding along |
| Manual walk mode | `com.fibaro.binarySwitch` | On for manual walks, off for automatic detection |
| Walk recording | `com.fibaro.binarySwitch` | Starts and stops a walk. Manual mode only |
| Live tracking | `com.fibaro.binarySwitch` | On for live tracking, off for the daily schedule |
| Sleeping mode | `com.fibaro.binarySwitch` | Puts the tracker to sleep. Momentary |
| Light | `com.fibaro.binarySwitch` | The tracker's locator light |
| Sound | `com.fibaro.binarySwitch` | The tracker's locator buzzer |

Car mode, manual walk mode and walk recording are backend state, so every
tracker gets them. The rest are device commands and are only created for
trackers whose protocol advertises them, so a tracker with no LED gets no light
child rather than one that fails on every tap.

**Sleeping mode is one-way.** Waking a sleeping tracker happens over Bluetooth
with the phone next to it and never through the API, so the child is momentary:
it goes back off once the command is out, and switching it off does nothing on
purpose.

**Walk recording only works in manual mode.** The backend refuses it in
automatic mode, where recording is always on and not yours to control. The
QuickApp logs why rather than sending a request it knows will fail.

**Light and sound lag a little.** Their state comes from the tracker's last
heartbeat (`GET /api/device-states/my-pets`), which is polled alongside the pet
list, but only when a tracker on the account advertises those commands.

The QuickApp's own panel shows status, address, battery, the primary pet's
modes and last update, with a refresh button and a sleeping-mode button. **All**
pets on the account get child devices; set `primaryPet` to choose which one the
panel follows.

## Geofencing uses your gateway's zones

The QuickApp does not hardcode a home coordinate. It reads the zones you have
already configured in **Settings → Location** on the HC3 (`GET /panels/location`):

- the zone flagged as **home** drives the *At home* and *Distance from home* children;
- any other zone is reported by name on the panel, for example `In zone: Vet`.

So configure your zones on the gateway and the integration follows them. If your
location panel is empty, set `homeLat` / `homeLon` / `homeRadius` instead and
those take priority.

## Installation

### Option A: import the package

1. Download [`dist/pinpaw.fqa`](dist/pinpaw.fqa).
2. HC3 web UI → **Settings → Devices → + → Other Device → Upload File**.
3. Select the `.fqa`, then open the new device's **Variables** tab and set
   `apiToken`.

### Option B: create it by hand

If the import misbehaves, the QuickApp is five plain Lua files:

1. **Settings → Devices → + → Other Device → QuickApp**, type
   `com.fibaro.deviceController`.
2. Add the files from `src/` **in this order**: `api`, `geo`, `i18n`,
   `children`, and `main` last. Order matters: `main` uses globals the others
   define, and the child class must exist before `onInit` runs.
3. Add the variables from the table below.
4. On the UI tab add labels named `lblStatus`, `lblLocation`, `lblBattery`,
   `lblUpdated`, and a button `btnRefresh` bound to `onRefreshClicked`.

### Getting a token

Requires PinPaw app **1.6.0+**: **Settings → API tokens → Create token**. It is
shown once and starts with `ppw_pat_`.

## Variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `apiToken` | *(empty)* | **Required.** PinPaw personal access token |
| `baseUrl` | `https://api.pinpaw.io` | API base URL |
| `pollInterval` | `60` | Seconds between polls; values below 15 are clamped |
| `language` | `en` | `en` or `pl` for the panel text |
| `primaryPet` | *(empty)* | Pet id or name the panel follows; defaults to the first |
| `reverseGeocode` | `false` | See the note below before enabling |
| `homeLat` | *(empty)* | Overrides the gateway's home zone |
| `homeLon` | *(empty)* | Overrides the gateway's home zone |
| `homeRadius` | *(empty)* | Home radius in metres |

A missing or malformed token stops the QuickApp with a message on the panel
rather than retrying against a credential that cannot work. The same applies if
the API rejects the token with `401`/`403`.

### About `reverseGeocode`

The backend usually supplies a street address in `latestPosition.address`, and
the panel shows it. When it does not, enabling `reverseGeocode` falls back to
OpenStreetMap's Nominatim.

It is **off by default on purpose**. Nominatim is a free service with a
[usage policy](https://operations.osmfoundation.org/policies/nominatim/) that
caps automated use. Enabling this points a request at someone else's donated
infrastructure every time your pet moves to an unlabelled spot. The QuickApp
rate-limits itself to one lookup per two minutes and caches by rounded
coordinates, but that decision should still be yours. For heavy use, run your
own Nominatim or a commercial geocoder.

## Driving it from a scene

Every switch is also a QuickApp action, callable from any scene. `7` below is
the PinPaw pet id.

```lua
-- Reporting interval, in seconds. Shorter means fresher positions and
-- shorter battery life.
fibaro.call(<quickAppDeviceId>, "setPetTrackingInterval", 7, 120)

fibaro.call(<quickAppDeviceId>, "setPetCarMode", 7, true)
fibaro.call(<quickAppDeviceId>, "setPetManualWalkMode", 7, true)
fibaro.call(<quickAppDeviceId>, "setPetWalkActive", 7, true)   -- manual mode only
fibaro.call(<quickAppDeviceId>, "setPetLiveTracking", 7, true)
fibaro.call(<quickAppDeviceId>, "setPetLed", 7, true)
fibaro.call(<quickAppDeviceId>, "setPetSound", 7, false)

-- One-way, see above
fibaro.call(<quickAppDeviceId>, "sleepPet", 7)
```

## Development

```bash
lua tests/run.lua              # 106 logic tests against a stubbed HC3 runtime
python3 tools/build_fqa.py     # rebuild dist/pinpaw.fqa from src/
python3 tools/build_fqa.py --check   # fail if dist/ is stale
```

`tests/fibaro_stub.lua` implements just enough of the HC3 globals (`class`,
`QuickApp`, `QuickAppChild`, `net`, `json`, `api`, `fibaro`) to run the real
sources under a plain `lua` binary. It is not an emulator: it covers the
integration's logic, not HC3's behaviour, which is exactly why the hardware
caveat at the top of this file still stands.

```
src/api.lua        REST client (Bearer PAT, 401/403 handled separately)
src/geo.lua        Haversine + HC3 location-panel zones
src/i18n.lua       Panel strings (en/pl)
src/children.lua   Child device roles, their updaters and the switch writers
src/main.lua       Lifecycle, polling, state mapping, UI  ← must load last
```

## Differences from the Home Assistant integration

- **No WebSocket push.** The HA integration supplements polling with
  `/api/socket` for near real-time updates. This QuickApp polls only. Adding it
  is tracked as future work. It was left out of the first release rather than
  shipping a second untested subsystem.
- **Geofencing is computed here.** Home Assistant gets zone membership for free
  from `device_tracker` + Zones; on HC3 the QuickApp does the distance maths
  against the location panel itself.
- **Walk recording mode is two states, not a dropdown.** Home Assistant has a
  `select` entity; HC3 has no equivalent child type, so it is a single "manual
  walk mode" switch instead.
- **Tracking mode has no child device.** HC3 has no enum sensor, so it is shown
  on the QuickApp panel rather than as a device of its own.

## Licence

MIT. See [LICENSE](LICENSE).
