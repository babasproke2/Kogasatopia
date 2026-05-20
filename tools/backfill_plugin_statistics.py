#!/usr/bin/env python3
from __future__ import annotations

import argparse
import bisect
import calendar
import re
import shlex
import subprocess
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo


DEFAULT_LOG_ROOT = "/home/kogasa/hlserver/tf2/tf/addons/sourcemod/logs"
DEFAULT_HOST_PORT = 27015
LOG_SOURCES = {
    "whalescramble.log": "whalescramble_statistics_events",
    "autobalance.log": "autobalance_statistics_events",
    "points_store_events.log": "points_store_statistics_events",
}
LOG_RE = re.compile(r"^L (?P<date>\d{2})/(?P<day>\d{2})/(?P<year>\d{4}) - (?P<time>\d{2}:\d{2}:\d{2}): (?P<message>.*)$")


@dataclass
class MapContext:
    occurred_at: int
    host_port: int
    map_session_id: str
    map_name: str
    gamemode: str


@dataclass
class PluginEvent:
    occurred_at: int
    host_port: int
    map_session_id: str
    map_name: str
    gamemode: str
    event_name: str
    message: str
    weekday: int
    hour_of_day: int
    source_file: str
    source_line: int


def sql_string(value: str | None) -> str:
    if value is None:
        return "NULL"
    return "'" + value.replace("\\", "\\\\").replace("'", "''") + "'"


def mysql_query(mysql_args: list[str], query: str) -> str:
    return subprocess.run(mysql_args, input=query, text=True, stdout=subprocess.PIPE, check=True).stdout


def ensure_schema(mysql_args: list[str], table: str) -> None:
    query = (
        f"CREATE TABLE IF NOT EXISTS {table} ("
        "id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,"
        "occurred_at INT NOT NULL,"
        "host_port INT NOT NULL DEFAULT 0,"
        "map_session_id VARCHAR(64) NOT NULL DEFAULT '',"
        "map_name VARCHAR(128) NOT NULL DEFAULT '',"
        "gamemode VARCHAR(32) NOT NULL DEFAULT '',"
        "event_name VARCHAR(64) NOT NULL DEFAULT '',"
        "message VARCHAR(512) NOT NULL DEFAULT '',"
        "weekday TINYINT NOT NULL DEFAULT 0,"
        "hour_of_day TINYINT NOT NULL DEFAULT 0,"
        "imported TINYINT(1) NOT NULL DEFAULT 0,"
        "source_file VARCHAR(255) NULL,"
        "source_line INT NULL,"
        "created_at INT NOT NULL,"
        "KEY idx_occurred_at (occurred_at),"
        "KEY idx_host_occurred_at (host_port, occurred_at),"
        "KEY idx_map_session (map_session_id),"
        "KEY idx_map_occurred_at (map_name, occurred_at),"
        "KEY idx_event_name (event_name),"
        "KEY idx_weekday_hour (weekday, hour_of_day),"
        "UNIQUE KEY uniq_import_source (source_file, source_line)"
        ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;"
    )
    mysql_query(mysql_args, query)


def load_map_contexts(mysql_args: list[str]) -> dict[int, tuple[list[int], list[MapContext]]]:
    output = mysql_query(mysql_args, """
        SELECT occurred_at, host_port, map_name, gamemode
        FROM server_connection_statistics_events
        WHERE event_type = 'map_change'
        ORDER BY host_port, occurred_at, id;
    """)
    contexts: dict[int, list[MapContext]] = {}
    for line in output.splitlines():
        if not line:
            continue
        occurred_at, host_port, map_name, gamemode = line.split("\t", 3)
        port = int(host_port)
        ts = int(occurred_at)
        contexts.setdefault(port, []).append(MapContext(
            occurred_at=ts,
            host_port=port,
            map_session_id=f"{port}-{ts}",
            map_name=map_name or "unknown",
            gamemode=gamemode or "unknown",
        ))

    return {
        port: ([context.occurred_at for context in port_contexts], port_contexts)
        for port, port_contexts in contexts.items()
    }


def context_for(contexts: dict[int, tuple[list[int], list[MapContext]]], host_port: int, occurred_at: int) -> MapContext:
    if host_port not in contexts:
        return MapContext(occurred_at, host_port, "", "unknown", "unknown")

    timestamps, port_contexts = contexts[host_port]
    index = bisect.bisect_right(timestamps, occurred_at) - 1
    if index < 0:
        return MapContext(occurred_at, host_port, "", "unknown", "unknown")

    return port_contexts[index]


def derive_event_name(message: str) -> str:
    known = known_event_name(message)
    if known:
        return known

    start = 6 if message.startswith("event=") else 0
    chars: list[str] = []
    for char in message[start:]:
        if char in "|:.(":
            break
        if char.isalnum():
            chars.append(char.lower())
        elif char in " -_":
            if chars and chars[-1] != "_":
                chars.append("_")

    while chars and chars[-1] == "_":
        chars.pop()
    return "".join(chars) or "event"


def known_event_name(message: str) -> str:
    check = message
    if check.startswith("[autobalance_4teams] "):
        check = check[len("[autobalance_4teams] "):]

    if check.startswith("Autobalancing "):
        return "autobalance_move"
    if check.startswith("Imbalance:"):
        return "imbalance_detected"
    if check.startswith("Volunteer priority"):
        return "volunteer_priority"
    if check.startswith("Skip balance"):
        return "balance_skipped"
    if check.startswith("Persistent immunity"):
        return "immunity_changed"
    if "volunteer" in check.lower():
        return "volunteer_changed"

    return ""


def parse_log(path: Path, source_name: str, table: str, timezone: ZoneInfo, host_port: int, contexts: dict[int, tuple[list[int], list[MapContext]]]) -> list[PluginEvent]:
    events: list[PluginEvent] = []
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line_number, line in enumerate(handle, 1):
            match = LOG_RE.match(line.rstrip("\n"))
            if not match:
                continue

            month = int(match.group("date"))
            day = int(match.group("day"))
            year = int(match.group("year"))
            hour, minute, second = [int(part) for part in match.group("time").split(":")]
            timestamp = int(datetime(year, month, day, hour, minute, second, tzinfo=timezone).timestamp())
            weekday = int(datetime(year, month, day, hour, minute, second, tzinfo=timezone).strftime("%w"))
            message = match.group("message")[:512]
            context = context_for(contexts, host_port, timestamp)

            events.append(PluginEvent(
                occurred_at=timestamp,
                host_port=host_port,
                map_session_id=context.map_session_id,
                map_name=context.map_name,
                gamemode=context.gamemode,
                event_name=derive_event_name(message)[:64],
                message=message,
                weekday=weekday,
                hour_of_day=hour,
                source_file=source_name,
                source_line=line_number,
            ))
    return events


def insert_events(mysql_args: list[str], table: str, events: list[PluginEvent], chunk_size: int) -> None:
    if not events:
        return

    created_at = int(datetime.now().timestamp())
    columns = (
        "occurred_at, host_port, map_session_id, map_name, gamemode, event_name, message, "
        "weekday, hour_of_day, imported, source_file, source_line, created_at"
    )

    for start in range(0, len(events), chunk_size):
        values = []
        for event in events[start:start + chunk_size]:
            values.append(
                "("
                f"{event.occurred_at}, {event.host_port}, {sql_string(event.map_session_id)}, "
                f"{sql_string(event.map_name)}, {sql_string(event.gamemode)}, {sql_string(event.event_name)}, "
                f"{sql_string(event.message)}, {event.weekday}, {event.hour_of_day}, 1, "
                f"{sql_string(event.source_file)}, {event.source_line}, {created_at}"
                ")"
            )
        query = f"INSERT IGNORE INTO {table} ({columns}) VALUES\n" + ",\n".join(values) + ";"
        mysql_query(mysql_args, query)


def main() -> int:
    parser = argparse.ArgumentParser(description="Backfill plugin statistics event tables from legacy SourceMod log files.")
    parser.add_argument("--log-root", default=DEFAULT_LOG_ROOT)
    parser.add_argument("--timezone", default="America/New_York")
    parser.add_argument("--host-port", type=int, default=DEFAULT_HOST_PORT)
    parser.add_argument("--mysql", required=True, help="mysql command and arguments, quoted as one shell-like string")
    parser.add_argument("--chunk-size", type=int, default=500)
    args = parser.parse_args()

    mysql_args = shlex.split(args.mysql)
    if not mysql_args:
        parser.error("--mysql requires a mysql command")

    timezone = ZoneInfo(args.timezone)
    log_root = Path(args.log_root)
    contexts = load_map_contexts(mysql_args)

    for filename, table in LOG_SOURCES.items():
        ensure_schema(mysql_args, table)
        path = log_root / filename
        if not path.exists():
            print(f"{table}: missing {path}")
            continue

        events = parse_log(path, f"logs/{filename}", table, timezone, args.host_port, contexts)
        insert_events(mysql_args, table, events, args.chunk_size)
        print(f"{table}: parsed_events={len(events)}")

    print("backfill_complete=1")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
