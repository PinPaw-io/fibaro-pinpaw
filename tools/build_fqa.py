#!/usr/bin/env python3
"""Bundle src/*.lua into dist/pinpaw.fqa, the archive format HC3 imports.

A .fqa is a single JSON document describing the QuickApp: its device type, the
UI layout, the variables it exposes, and every Lua file it is made of. HC3's
"Import QuickApp" dialog takes exactly this, which is why the repo ships one --
otherwise installing means hand-creating a QuickApp and pasting five files in
the right order.

The output is deterministic (fixed key order, no timestamps) so rebuilding
without source changes produces a byte-identical file and leaves git alone.

Usage:
    python3 tools/build_fqa.py            # write dist/pinpaw.fqa
    python3 tools/build_fqa.py --check    # fail if dist is stale (for CI)
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
OUT = ROOT / "dist" / "pinpaw.fqa"

QUICKAPP_NAME = "PinPaw"
QUICKAPP_TYPE = "com.fibaro.deviceController"
API_VERSION = "1.3"

# Load order is significant: main.lua references globals the other files
# define (PinPawApi, PinPawGeo, PinPawI18n, PinPawSensor), and the child class
# must exist before onInit calls initChildDevices. main goes last.
FILE_ORDER = ["api", "geo", "i18n", "children", "main"]

# Variables the user fills in on the QuickApp's Variables tab. Empty values are
# intentional -- a token must never ship inside the package.
QUICKAPP_VARIABLES = [
    ("apiToken", ""),
    ("baseUrl", "https://api.pinpaw.io"),
    ("pollInterval", "60"),
    ("language", "en"),
    ("reverseGeocode", "false"),
    ("primaryPet", ""),
    ("homeLat", ""),
    ("homeLon", ""),
    ("homeRadius", ""),
]

# (element name, kind, initial text). Labels are filled in at runtime.
UI_ROWS = [
    ("lblStatus", "label", "PinPaw"),
    ("lblLocation", "label", "-"),
    ("lblBattery", "label", "-"),
    ("lblUpdated", "label", "-"),
    ("btnRefresh", "button", "Refresh"),
]

# Button name -> QuickApp method invoked when it is released.
UI_CALLBACKS = {"btnRefresh": "onRefreshClicked"}


def _label(name: str, text: str) -> dict:
    return {
        "eventBinding": {},
        "name": name,
        "style": {"weight": "1.2"},
        "text": text,
        "type": "label",
        "visible": True,
    }


def _button(name: str, text: str) -> dict:
    return {
        "eventBinding": {
            "onReleased": [
                {
                    "params": {"actionName": "UIAction", "args": ["onReleased", name]},
                    "type": "deviceAction",
                }
            ]
        },
        "name": name,
        "style": {"weight": "1.2"},
        "text": text,
        "type": "button",
        "visible": True,
    }


def build_view_layout() -> dict:
    """Assemble the nested $jason structure HC3 uses for QuickApp UIs."""
    items = []
    for name, kind, text in UI_ROWS:
        component = _button(name, text) if kind == "button" else _label(name, text)
        items.append(
            {
                "components": [component, {"style": {"weight": "0.5"}, "type": "space"}],
                "style": {"weight": "1.2"},
                "type": "vertical",
            }
        )

    title = f"quickApp_device_{QUICKAPP_NAME}"
    return {
        "$jason": {
            "body": {
                "header": {"style": {"height": "0"}, "title": title},
                "sections": {"items": items},
            },
            "head": {"title": title},
        }
    }


def build_ui_callbacks() -> list[dict]:
    return [
        {"callback": callback, "eventType": "onReleased", "name": name}
        for name, callback in UI_CALLBACKS.items()
    ]


def read_sources() -> list[dict]:
    files = []
    for stem in FILE_ORDER:
        path = SRC / f"{stem}.lua"
        if not path.is_file():
            sys.exit(f"error: missing source file {path.relative_to(ROOT)}")
        is_main = stem == "main"
        files.append(
            {
                "name": stem,
                "isMain": is_main,
                "isOpen": is_main,
                "type": "lua",
                "content": path.read_text(encoding="utf-8"),
            }
        )
    return files


def build_package() -> dict:
    return {
        "apiVersion": API_VERSION,
        "name": QUICKAPP_NAME,
        "type": QUICKAPP_TYPE,
        "initialInterfaces": ["quickApp"],
        "initialProperties": {
            "quickAppVariables": [
                {"name": name, "value": value} for name, value in QUICKAPP_VARIABLES
            ],
            "typeTemplateInitialized": True,
            "uiCallbacks": build_ui_callbacks(),
            "viewLayout": build_view_layout(),
        },
        "files": read_sources(),
    }


def render(package: dict) -> str:
    return json.dumps(package, indent=2, ensure_ascii=False, sort_keys=True) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="exit non-zero if dist/pinpaw.fqa does not match the sources",
    )
    args = parser.parse_args()

    rendered = render(build_package())

    if args.check:
        if not OUT.is_file():
            print(f"error: {OUT.relative_to(ROOT)} is missing; run build_fqa.py")
            return 1
        if OUT.read_text(encoding="utf-8") != rendered:
            print(f"error: {OUT.relative_to(ROOT)} is stale; run build_fqa.py")
            return 1
        print(f"ok: {OUT.relative_to(ROOT)} is up to date")
        return 0

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(rendered, encoding="utf-8")
    size_kb = len(rendered.encode("utf-8")) / 1024
    print(f"wrote {OUT.relative_to(ROOT)} ({size_kb:.1f} KB, {len(FILE_ORDER)} Lua files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
