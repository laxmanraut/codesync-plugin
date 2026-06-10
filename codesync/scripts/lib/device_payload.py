"""device_payload.py — build the Syncthing device-config JSON for a peer.

Single source of truth for the introducer-preserving logic that used to be
duplicated verbatim in pair-peer.sh and invite-peer-to-project.sh (extracted
per eng-review 3A, 2026-06-10).

Usage:
    $PY_BIN lib/device_payload.py PEER_ID SHORT_NAME AS_INTRODUCER EXISTING_JSON

Args:
    PEER_ID        the peer's Syncthing device ID
    SHORT_NAME     local label for the peer
    AS_INTRODUCER  "yes" to set introducer=true; anything else preserves
    EXISTING_JSON  the peer's current device config from the REST API, or ""

Behavior: --as-introducer always upgrades to true. WITHOUT it, an existing
introducer=true is PRESERVED (never silently demoted — the v0.12.x guarantee).
Prints the device-config JSON on stdout.
"""
import json
import sys


def build_payload(peer: str, name: str, asintro: str, existing: str) -> dict:
    introducer = asintro == "yes"
    if not introducer and existing:
        try:
            introducer = bool(json.loads(existing).get("introducer", False))
        except Exception:
            introducer = False
    return {
        "deviceID":          peer,
        "name":              name,
        "addresses":         ["dynamic"],
        "compression":       "metadata",
        "introducer":        introducer,
        "autoAcceptFolders": False,
    }


if __name__ == "__main__":
    peer, name, asintro = sys.argv[1], sys.argv[2], sys.argv[3]
    existing = sys.argv[4] if len(sys.argv) > 4 else ""
    print(json.dumps(build_payload(peer, name, asintro, existing)))
