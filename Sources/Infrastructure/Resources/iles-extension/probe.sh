#!/bin/sh
set -euo pipefail
# Harnais Iles probe: quotas (island rings) + harness sync state in one fetch.
# Reads only Harnais-owned JSON under ~/.harnais; every file is optional.
# Output: {"quotas": [...], "capturedAt": ..., "stale": ..., "refreshTriggered": ...,
#          "harnesses": {...}}. Missing feed => empty quotas, never an error,
# so Iles renders an empty grid instead of failing the probe.
#
# Iles owns refresh scheduling: when the feed is stale (or missing) this probe
# triggers `harnais quotas` in the background —detached, lock-guarded so polls
# never stampede— and returns the current snapshot immediately. The next poll
# (Iles default: every 120s) picks up the fresh feed. Probe itself stays fast
# under Iles's 10s timeout.
python3 - <<'PY'
import json, os, subprocess, time
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
HARNAIS_DIR = os.path.join(HOME, ".harnais")
HARNAIS_BIN = os.path.join(HARNAIS_DIR, "bin", "harnais")
LOCK_DIR = os.path.join(HARNAIS_DIR, "quotas-refresh.lock")
# Matches IslandFeed.staleAfter (2x the 120s Iles poll interval).
STALE_AFTER = 240
LOCK_TTL = 900


def load(name, default):
    try:
        with open(os.path.join(HARNAIS_DIR, name)) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return default


def feed_age(feed):
    try:
        ts = feed.get("capturedAt")
        if not ts:
            return None
        moment = datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
        if moment.tzinfo is None:
            moment = moment.replace(tzinfo=timezone.utc)
        return (datetime.now(timezone.utc) - moment).total_seconds()
    except (ValueError, TypeError):
        return None


def lock_is_live():
    try:
        age = time.time() - os.stat(LOCK_DIR).st_mtime
    except OSError:
        return False
    if age > LOCK_TTL:
        try:
            os.rmdir(LOCK_DIR)
        except OSError:
            pass
        return False
    return True


def spawn_refresh():
    """Double-fork `harnais quotas`; the grandchild releases the lock."""
    try:
        pid = os.fork()
    except OSError:
        return False
    if pid != 0:
        _, _ = os.waitpid(pid, 0)
        return True
    try:
        os.setsid()
        if os.fork() != 0:
            os._exit(0)
        try:
            with open(os.devnull, "rb") as devnull, \
                 open(os.devnull, "ab") as sink:
                subprocess.run(
                    [HARNAIS_BIN, "quotas"],
                    stdin=devnull, stdout=sink, stderr=sink, timeout=300,
                )
        finally:
            try:
                os.rmdir(LOCK_DIR)
            except OSError:
                pass
            os._exit(0)
    except Exception:
        os._exit(1)


feed = load("quotas.json", {})
hidden = set(load("islands.json", {}).get("hiddenTypes", []))

age = feed_age(feed)
stale = age is None or age > STALE_AFTER
refresh_triggered = False
if stale and os.access(HARNAIS_BIN, os.X_OK) and not lock_is_live():
    try:
        os.mkdir(LOCK_DIR)
    except FileExistsError:
        pass
    else:
        refresh_triggered = spawn_refresh()
        if not refresh_triggered:
            try:
                os.rmdir(LOCK_DIR)
            except OSError:
                pass

quotas = []
for account in feed.get("accounts", []):
    for quota in account.get("quotas", []):
        if quota.get("type", "session") in hidden:
            continue
        quotas.append({
            "type": quota.get("type", "session"),
            "percentRemaining": quota.get("percentRemaining", 0),
            "resetsAt": quota.get("resetsAt"),
            "resetText": quota.get("resetText"),
            "group": quota.get("group"),
            "compactTitle": quota.get("compactTitle"),
            "menuBarTitle": quota.get("menuBarTitle"),
        })

registry = load("integrations.json", {})
connections = []
for connection in registry.get("connections", []):
    connections.append({
        "mcpName": connection.get("mcpName"),
        "kind": connection.get("kind"),
        "label": connection.get("label"),
        "slug": connection.get("slug"),
        "signedIn": connection.get("lastLoginAt") is not None,
        "excluded": bool(connection.get("isExcludedFromApply", False)),
    })

apply = load("mcp-apply.json", {})
applied_names = set(apply.get("mcpNames", []))
for connection in connections:
    # Synced = active in the last apply. Excluded connections are cleaned
    # from harness files, so they report synced=false even if a stale
    # entry lingers somewhere.
    connection["synced"] = (
        connection["mcpName"] in applied_names and not connection["excluded"]
    )

harnesses = {
    "connections": connections,
    "lastApply": {
        "at": apply.get("appliedAt"),
        "names": apply.get("mcpNames", []),
        "files": apply.get("files"),
        "hiddenRings": sorted(hidden),
    },
}

print(json.dumps({
    "quotas": quotas,
    "capturedAt": feed.get("capturedAt"),
    "stale": stale,
    "refreshTriggered": refresh_triggered,
    "harnesses": harnesses,
}))
PY
