#!/usr/bin/env python3
from __future__ import annotations

import argparse
import calendar
import os
import re
import shlex
import subprocess
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo


DATE_RE = re.compile(r"(?P<day>\d{2})_(?P<mon>[A-Za-z]{3})_(?P<year>\d{4})_(?P<kind>admin|player)\.log$")
MAP_RE = re.compile(r"^(?P<time>\d{2}:\d{2}:\d{2}) - ===== Map change to (?P<map>.+) =====$")
CONNECT_RE = re.compile(r"^(?P<time>\d{2}:\d{2}:\d{2}) - <(?P<name>.*)> <(?P<steam>STEAM_[^>]*)> <(?P<ip>[^>]*)> CONNECTED from <(?P<country>[^>]*)>$")
DISCONNECT_RE = re.compile(r"^(?P<time>\d{2}:\d{2}:\d{2}) - <(?P<name>.*)> <(?P<steam>STEAM_[^>]*)> <(?P<ip>[^>]*)> DISCONNECTED after (?P<minutes>\d+) minutes\. <(?P<reason>.*)>?$")


@dataclass
class Event:
    occurred_at: int
    host_port: int
    map_name: str
    gamemode: str
    event_type: str
    is_admin: int
    player_name: str
    steamid: str
    ip_subnet: str
    country: str
    connection_minutes: int
    reason: str
    weekday: int
    hour_of_day: int
    source_file: str
    source_line: int


def sql_string(value: str | None) -> str:
    if value is None:
        return "NULL"
    return "'" + value.replace("\\", "\\\\").replace("'", "''") + "'"


def normalize_map(map_name: str) -> str:
    normalized = map_name.strip()
    if "/" in normalized:
        normalized = normalized.rsplit("/", 1)[-1]
    marker = ".ugc"
    if marker in normalized:
        normalized = normalized.split(marker, 1)[0]
    return normalized


def gamemode_for_map(map_name: str) -> str:
    if "_" not in map_name:
        return "unknown"
    return map_name.split("_", 1)[0] or "unknown"


def timestamp_for(file_date: datetime, line_time: str) -> tuple[int, int, int]:
    hour, minute, second = [int(part) for part in line_time.split(":")]
    dt = file_date.replace(hour=hour, minute=minute, second=second)
    return int(dt.timestamp()), int(dt.strftime("%w")), hour


def date_from_file(path: Path, timezone: ZoneInfo) -> tuple[datetime, str] | None:
    match = DATE_RE.search(path.name)
    if not match:
        return None

    month = list(calendar.month_abbr).index(match.group("mon"))
    dt = datetime(int(match.group("year")), month, int(match.group("day")), tzinfo=timezone)
    return dt, match.group("kind")


def parse_logs(log_root: Path, host_port: int, timezone: ZoneInfo) -> list[Event]:
    events: list[Event] = []
    seen_map_changes: set[tuple[int, str]] = set()

    for path in sorted(log_root.glob("*/*.log")):
        parsed = date_from_file(path, timezone)
        if parsed is None:
            continue

        file_date, kind = parsed
        is_admin = 1 if kind == "admin" else 0
        rel_path = str(path.relative_to(log_root))
        current_map = "unknown"
        current_gamemode = "unknown"

        with path.open("r", encoding="utf-8", errors="replace") as handle:
            for line_number, line in enumerate(handle, 1):
                line = line.rstrip("\n")
                if not line:
                    continue

                match = MAP_RE.match(line)
                if match:
                    occurred_at, weekday, hour = timestamp_for(file_date, match.group("time"))
                    current_map = normalize_map(match.group("map"))
                    current_gamemode = gamemode_for_map(current_map)
                    key = (occurred_at, current_map)
                    if key in seen_map_changes:
                        continue
                    seen_map_changes.add(key)
                    events.append(Event(
                        occurred_at, host_port, current_map, current_gamemode, "map_change", 0,
                        "", "", "", "", 0, "", weekday, hour, rel_path, line_number))
                    continue

                match = CONNECT_RE.match(line)
                if match:
                    occurred_at, weekday, hour = timestamp_for(file_date, match.group("time"))
                    events.append(Event(
                        occurred_at, host_port, current_map, current_gamemode, "connect", is_admin,
                        match.group("name"), match.group("steam"), match.group("ip"), match.group("country"),
                        0, "", weekday, hour, rel_path, line_number))
                    continue

                match = DISCONNECT_RE.match(line)
                if match:
                    occurred_at, weekday, hour = timestamp_for(file_date, match.group("time"))
                    reason = match.group("reason").rstrip(">")
                    events.append(Event(
                        occurred_at, host_port, current_map, current_gamemode, "disconnect", is_admin,
                        match.group("name"), match.group("steam"), match.group("ip"), "",
                        int(match.group("minutes")), reason, weekday, hour, rel_path, line_number))

    return events


def insert_events(events: list[Event], mysql_args: list[str], chunk_size: int) -> None:
    columns = (
        "occurred_at, host_port, map_name, gamemode, event_type, is_admin, player_name, "
        "steamid, ip_subnet, country, connection_minutes, reason, weekday, hour_of_day, "
        "imported, source_file, source_line, created_at"
    )
    created_at = int(datetime.now().timestamp())

    for start in range(0, len(events), chunk_size):
        chunk = events[start:start + chunk_size]
        values = []
        for event in chunk:
            values.append(
                "("
                f"{event.occurred_at}, {event.host_port}, "
                f"{sql_string(event.map_name)}, {sql_string(event.gamemode)}, {sql_string(event.event_type)}, "
                f"{event.is_admin}, {sql_string(event.player_name)}, {sql_string(event.steamid)}, "
                f"{sql_string(event.ip_subnet)}, {sql_string(event.country)}, {event.connection_minutes}, "
                f"{sql_string(event.reason)}, {event.weekday}, {event.hour_of_day}, 1, "
                f"{sql_string(event.source_file)}, {event.source_line}, {created_at}"
                ")"
            )
        query = f"INSERT IGNORE INTO server_connection_statistics_events ({columns}) VALUES\n" + ",\n".join(values) + ";"
        subprocess.run(mysql_args, input=query, text=True, check=True)


def main() -> None:
    default_sm_path = Path(os.environ.get("SM_PATH", os.path.expanduser("~/hlserver/tf2/tf/addons/sourcemod")))
    parser = argparse.ArgumentParser(description="Backfill server_connection_statistics_events from legacy SourceMod connection logs.")
    parser.add_argument("--log-root", default=str(default_sm_path / "logs" / "connections"))
    parser.add_argument("--host-port", type=int, default=27015)
    parser.add_argument("--timezone", default="America/New_York")
    parser.add_argument("--mysql", required=True, help="mysql command and arguments, quoted as one shell-like string")
    parser.add_argument("--chunk-size", type=int, default=500)
    args = parser.parse_args()

    mysql_args = shlex.split(args.mysql)
    if not mysql_args:
        parser.error("--mysql requires a mysql command")

    events = parse_logs(Path(args.log_root), args.host_port, ZoneInfo(args.timezone))
    print(f"parsed_events={len(events)}")
    insert_events(events, mysql_args, args.chunk_size)
    print("backfill_complete=1")


if __name__ == "__main__":
    main()
