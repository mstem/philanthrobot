#!/usr/bin/env python3
"""Polls remote-session activity on philanthrobot (the Evens Mac Studio) and posts
Slack updates when someone starts, idles, resumes, or ends a remote session.

Two detection sources are combined, because neither alone sees everything:
  - netstat: established inbound TCP connections to the SSH port. Catches
    non-interactive SSH (scp, sftp, ssh -T, port forwarding) that never
    appears in utmpx.
  - w: interactive login sessions, the only source of idle time.
State is tracked per person, not per session, so one login seen by both
sources produces a single notification.
"""

import ipaddress
import json
import os
import re
import subprocess
import sys
import urllib.request
from datetime import datetime, timezone

CONFIG_PATH = os.environ.get("MONITOR_CONFIG", "/usr/local/etc/philanthrobot/config.json")
STATE_PATH = os.environ.get("MONITOR_STATE", "/usr/local/etc/philanthrobot/state.json")
AUDIT_LOG_PATH = os.environ.get("MONITOR_AUDIT_LOG", "/usr/local/var/log/philanthrobot.jsonl")

TAILNET_V4 = ipaddress.ip_network("100.64.0.0/10")
TAILNET_V6 = ipaddress.ip_network("fd7a:115c:a1e0::/48")
SSH_PORT = "22"
TAILSCALE_CLI_PATHS = [
    "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    "/usr/local/bin/tailscale",
    "/opt/homebrew/bin/tailscale",
]


def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return default


def save_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)


def run(cmd, timeout=15):
    return subprocess.run(cmd, capture_output=True, text=True, check=True, timeout=timeout).stdout


def in_tailnet(ip):
    return ip in TAILNET_V4 or ip in TAILNET_V6


def parse_idle_seconds(idle_str):
    if idle_str == "-":
        return 0
    m = re.match(r"^(\d+)days?$", idle_str)
    if m:
        return int(m.group(1)) * 86400
    m = re.match(r"^(\d+):(\d+)$", idle_str)
    if m:
        return int(m.group(1)) * 3600 + int(m.group(2)) * 60
    m = re.match(r"^(\d+)$", idle_str)
    if m:
        return int(m.group(1)) * 60
    return 0


def parse_w():
    """Return a list of dicts for each logged-in session via `w`."""
    lines = run(["w"]).splitlines()
    sessions = []
    for line in lines[2:]:  # skip load-average line and column header
        parts = line.split(None, 5)
        if len(parts) < 5:
            continue
        user, tty, from_field, login_at, idle = parts[:5]
        sessions.append({
            "user": user,
            "tty": tty,
            "from": from_field,
            "login_at": login_at,
            "idle_seconds": parse_idle_seconds(idle),
        })
    return sessions


def parse_netstat_addr(addr):
    """Split netstat's `host.port` form; the last dot separates the port."""
    host, _, port = addr.rpartition(".")
    return host.split("%")[0], port


def ssh_remote_ips():
    """Return remote IPs of established inbound connections to the SSH port."""
    ips = set()
    for line in run(["netstat", "-an", "-p", "tcp"]).splitlines():
        parts = line.split()
        if len(parts) < 6 or parts[-1] != "ESTABLISHED":
            continue
        _, local_port = parse_netstat_addr(parts[3])
        if local_port != SSH_PORT:
            continue
        remote_host, _ = parse_netstat_addr(parts[4])
        try:
            ip = ipaddress.ip_address(remote_host)
        except ValueError:
            continue
        if ip.is_loopback:
            continue
        ips.add(str(ip))
    return ips


def tailscale_peers():
    """Best-effort map of tailnet IP -> device hostname via the tailscale CLI."""
    for path in TAILSCALE_CLI_PATHS:
        try:
            status = json.loads(run([path, "status", "--json"]))
        except (OSError, subprocess.SubprocessError, ValueError):
            continue
        peers = {}
        nodes = list((status.get("Peer") or {}).values())
        if status.get("Self"):
            nodes.append(status["Self"])
        for node in nodes:
            name = (node.get("HostName") or "").lower()
            if not name:
                continue
            for ip in node.get("TailscaleIPs") or []:
                peers[ip] = name
        return peers
    return {}


def person_for_ip(ip, peers, config):
    names = config.get("device_names", {})
    hostname = peers.get(ip, "")
    if hostname in names:
        return names[hostname]
    if ip in names:
        return names[ip]
    if hostname:
        return hostname
    if in_tailnet(ipaddress.ip_address(ip)):
        return ip
    return f"{ip} (not via Tailscale)"


def person_for_w_from(from_field, peers, config):
    """Resolve `w`'s FROM column to a person, or None for console sessions.

    macOS `w` truncates the FROM column, so hostnames are matched by prefix
    against known device names rather than requiring a full `.ts.net` name.
    """
    if from_field in ("-", ""):
        return None
    try:
        ip = ipaddress.ip_address(from_field)
        return person_for_ip(str(ip), peers, config)
    except ValueError:
        pass
    label = from_field.split(".")[0].lower()
    names = {k.lower(): v for k, v in config.get("device_names", {}).items()}
    if label in names:
        return names[label]
    for cand in sorted(set(names) | set(peers.values())):
        if len(label) >= 4 and cand.startswith(label):
            return names.get(cand, cand)
    return label


def log_event(event, person):
    entry = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "event": event,
        "person": person,
    }
    with open(AUDIT_LOG_PATH, "a") as f:
        f.write(json.dumps(entry) + "\n")


def notify(config, text):
    webhook = config.get("slack_webhook_url")
    if not webhook:
        return
    body = json.dumps({"text": text}).encode("utf-8")
    req = urllib.request.Request(webhook, data=body, headers={"Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=10)
    except Exception as e:
        print(f"Slack post failed: {e}", file=sys.stderr)


def migrate_v1_state(state):
    """Old state was keyed per TTY session; fold it into per-person entries so
    an upgrade doesn't re-announce everyone already connected."""
    people = {}
    for sess in (state.pop("sessions", None) or {}).values():
        prev = people.get(sess["person"])
        if prev is None or sess["status"] == "active":
            people[sess["person"]] = {"status": sess["status"]}
    state["people"] = people


def main():
    os.umask(0o077)  # state and audit log hold presence data; keep them private
    config = load_json(CONFIG_PATH, {})
    state = load_json(STATE_PATH, {})
    if "people" not in state:
        migrate_v1_state(state)
    people = state["people"]
    first_run = not state.get("initialized", False)

    idle_threshold = config.get("idle_threshold_seconds", 600)
    peers = tailscale_peers()

    # idle_seconds None means no interactive TTY to measure; treated as active
    current = {}
    for ip in ssh_remote_ips():
        current.setdefault(person_for_ip(ip, peers, config), {"idle_seconds": None})
    for s in parse_w():
        person = person_for_w_from(s["from"], peers, config)
        if person is None:
            continue
        entry = current.setdefault(person, {"idle_seconds": None})
        if entry["idle_seconds"] is None or s["idle_seconds"] < entry["idle_seconds"]:
            entry["idle_seconds"] = s["idle_seconds"]

    for person, info in current.items():
        is_idle = info["idle_seconds"] is not None and info["idle_seconds"] >= idle_threshold
        st = people.get(person)
        if st is None:
            if not first_run:
                notify(config, f":red_circle: *{person}* started a session on philanthrobot")
                log_event("start", person)
            people[person] = {"status": "idle" if is_idle else "active"}
        elif is_idle and st["status"] == "active":
            notify(config, f":crescent_moon: *{person}* has gone idle on philanthrobot")
            log_event("idle", person)
            st["status"] = "idle"
        elif not is_idle and st["status"] == "idle":
            notify(config, f":red_circle: *{person}* is active again on philanthrobot")
            log_event("active", person)
            st["status"] = "active"

    for person in list(people):
        if person not in current:
            people.pop(person)
            if not first_run:
                notify(config, f":large_green_circle: *{person}* disconnected from philanthrobot")
                log_event("end", person)

    state["initialized"] = True
    save_json(STATE_PATH, state)


if __name__ == "__main__":
    main()
