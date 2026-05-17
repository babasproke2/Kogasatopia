#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import os
import re
import subprocess
import sys
from collections import Counter
from datetime import datetime
from statistics import mean, median


DEFAULT_DB_CONFIG = "/home/kogasa/hlserver/tf2/tf/addons/sourcemod/configs/databases.cfg"
DEFAULT_TABLE = "server_connection_events"


def parse_databases_cfg(path: str, section: str) -> dict[str, str]:
    current = None
    pending_section = None
    config: dict[str, str] = {}

    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for raw_line in handle:
            line = raw_line.split("//", 1)[0].strip()
            if not line:
                continue

            key_match = re.match(r'^"([^"]+)"(?:\s+"([^"]*)")?$', line)
            if key_match:
                key, value = key_match.groups()
                if value is None:
                    pending_section = key
                elif current == section:
                    config[key] = value
                continue

            if line == "{":
                if pending_section is not None:
                    current = pending_section
                    pending_section = None
                continue

            if line == "}":
                if current == section:
                    break
                current = None
                pending_section = None

    if not config:
        raise RuntimeError(f'database section "{section}" was not found in {path}')

    return config


def mysql_args(mysql_bin: str, config: dict[str, str]) -> list[str]:
    args = [mysql_bin, "-N", "-B", "--raw"]

    host = config.get("host")
    if host:
        args.extend(["-h", host])

    user = config.get("user")
    if user:
        args.extend(["-u", user])

    port = config.get("port")
    if port:
        args.extend(["-P", port])

    database = config.get("database")
    if database:
        args.append(database)

    return args


def mysql_query(args: list[str], password: str, query: str) -> str:
    env = os.environ.copy()
    if password:
        env["MYSQL_PWD"] = password

    proc = subprocess.run(
        args,
        input=query,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or f"mysql exited with {proc.returncode}")
    return proc.stdout


def table_exists(args: list[str], password: str, table: str) -> bool:
    query = (
        "SELECT COUNT(*) FROM information_schema.tables "
        f"WHERE table_schema = DATABASE() AND table_name = '{sql_literal(table)}';"
    )
    output = mysql_query(args, password, query).strip()
    return output == "1"


def sql_literal(value: str) -> str:
    return value.replace("\\", "\\\\").replace("'", "''")


def pct(values: list[int], percentile: float) -> int:
    if not values:
        return 0
    values = sorted(values)
    index = round((len(values) - 1) * percentile)
    return values[index]


def fetch_rows(args: list[str], password: str, table: str, days: int) -> list[dict[str, str | int]]:
    where = ""
    if days > 0:
        where = f"WHERE occurred_at >= UNIX_TIMESTAMP() - {days * 86400}"

    query = f"""
        SELECT occurred_at, host_port, map_name, gamemode, event_type,
               player_name, steamid, ip_subnet, country, connection_minutes,
               reason, weekday, hour_of_day, imported
        FROM {table}
        {where}
        ORDER BY occurred_at, id;
    """
    output = mysql_query(args, password, query)

    rows: list[dict[str, str | int]] = []
    for row in csv.reader(output.splitlines(), delimiter="\t"):
        if len(row) < 14:
            continue
        rows.append({
            "occurred_at": int(row[0]),
            "host_port": int(row[1]),
            "map": row[2] or "unknown",
            "gamemode": row[3] or "unknown",
            "event_type": row[4],
            "player_name": row[5],
            "steamid": row[6],
            "ip_subnet": row[7],
            "country": row[8] or "Unknown",
            "connection_minutes": int(row[9]),
            "reason": row[10] or "(blank)",
            "weekday": int(row[11]),
            "hour_of_day": int(row[12]),
            "imported": int(row[13]),
        })
    return rows


def print_top(title: str, items: list[tuple[str, int]], limit: int) -> None:
    print(f"\n{title}")
    for key, value in items[:limit]:
        print(f"  {key}: {value}")


def summarize(rows: list[dict[str, str | int]], limit: int, days: int) -> None:
    if not rows:
        print("No rows found for the selected range.")
        return

    connects = [row for row in rows if row["event_type"] == "connect"]
    disconnects = [row for row in rows if row["event_type"] == "disconnect"]
    map_changes = [row for row in rows if row["event_type"] == "map_change"]
    minutes = [int(row["connection_minutes"]) for row in disconnects if int(row["connection_minutes"]) > 0]

    start = datetime.fromtimestamp(min(int(row["occurred_at"]) for row in rows))
    end = datetime.fromtimestamp(max(int(row["occurred_at"]) for row in rows))
    title_range = f"last {days} days" if days > 0 else "all rows"

    print(f"Analytics connection stats ({title_range})")
    print(f"Range: {start:%Y-%m-%d %H:%M:%S} to {end:%Y-%m-%d %H:%M:%S}")
    print(f"Rows: {len(rows):,}")
    print(f"Unique SteamIDs on connect: {len({row['steamid'] for row in connects if row['steamid']})}")

    print_top("Event counts", Counter(str(row["event_type"]) for row in rows).most_common(), limit)
    print_top("Host/import counts", Counter(f"{row['host_port']} imported={row['imported']}" for row in rows).most_common(), limit)

    if minutes:
        print("\nDisconnect session minutes")
        print(f"  total_hours: {sum(minutes) / 60.0:.1f}")
        print(f"  average: {mean(minutes):.1f}")
        print(f"  median: {median(minutes):.1f}")
        print(f"  p75: {pct(minutes, 0.75)}")
        print(f"  p90: {pct(minutes, 0.90)}")
        print(f"  p95: {pct(minutes, 0.95)}")

    print_top("Top connect hours", [(str(hour), count) for hour, count in Counter(int(row["hour_of_day"]) for row in connects).most_common()], limit)
    print_top("Top maps by connects", Counter(str(row["map"]) for row in connects).most_common(), limit)
    print_top("Top maps by map changes", Counter(str(row["map"]) for row in map_changes).most_common(), limit)
    print_top("Top gamemodes by connects", Counter(str(row["gamemode"]) for row in connects).most_common(), limit)
    print_top("Top countries by connects", Counter(str(row["country"]) for row in connects).most_common(), limit)
    print_top("Top disconnect reasons", Counter(str(row["reason"]) for row in disconnects).most_common(), limit)

    map_minutes: Counter[str] = Counter()
    map_disconnects: Counter[str] = Counter()
    for row in disconnects:
        value = int(row["connection_minutes"])
        if value <= 0:
            continue
        key = str(row["map"])
        map_minutes[key] += value
        map_disconnects[key] += 1

    print("\nTop maps by disconnect playtime")
    for map_name, total in map_minutes.most_common(limit):
        avg = total / max(map_disconnects[map_name], 1)
        print(f"  {map_name}: {total / 60.0:.1f} hours, avg disconnect {avg:.1f} min")


def main() -> int:
    parser = argparse.ArgumentParser(description="Summarize the SourceMod server_connection_events analytics table.")
    parser.add_argument("--config", default=DEFAULT_DB_CONFIG, help="SourceMod databases.cfg path")
    parser.add_argument("--connection", default="default", help="databases.cfg connection name")
    parser.add_argument("--table", default=DEFAULT_TABLE, help="analytics table name")
    parser.add_argument("--mysql", default="mysql", help="mysql client binary")
    parser.add_argument("--days", type=int, default=0, help="only include the last N days; 0 means all rows")
    parser.add_argument("--top", type=int, default=10, help="number of rows to show in top lists")
    args = parser.parse_args()

    try:
        config = parse_databases_cfg(args.config, args.connection)
        db_args = mysql_args(args.mysql, config)
        password = config.get("pass", "")
        if not table_exists(db_args, password, args.table):
            print(f'ERROR: table "{args.table}" does not exist in database "{config.get("database", "")}".', file=sys.stderr)
            return 2

        rows = fetch_rows(db_args, password, args.table, args.days)
        summarize(rows, max(args.top, 1), args.days)
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
