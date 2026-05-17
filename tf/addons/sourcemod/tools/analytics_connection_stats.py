#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import os
import re
import subprocess
import sys
from collections import Counter, defaultdict
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


def infer_map_sessions(rows: list[dict[str, str | int]], max_session_minutes: int) -> list[dict[str, str | int | float]]:
    sessions: list[dict[str, str | int | float]] = []
    rows_by_port: dict[int, list[dict[str, str | int]]] = defaultdict(list)

    for row in rows:
        rows_by_port[int(row["host_port"])].append(row)

    for port, port_rows in rows_by_port.items():
        map_change_indexes = [
            index for index, row in enumerate(port_rows)
            if row["event_type"] == "map_change"
        ]

        for index, start_index in enumerate(map_change_indexes[:-1]):
            end_index = map_change_indexes[index + 1]
            start_row = port_rows[start_index]
            end_row = port_rows[end_index]
            start_ts = int(start_row["occurred_at"])
            end_ts = int(end_row["occurred_at"])
            duration = end_ts - start_ts
            if duration <= 0 or duration > max_session_minutes * 60:
                continue

            connects = 0
            disconnects = 0
            first5 = 0
            first10 = 0
            first15 = 0
            early_disconnects = 0
            player_minutes = 0

            for event in port_rows[start_index + 1:end_index]:
                event_type = event["event_type"]
                event_ts = int(event["occurred_at"])
                if event_type == "connect":
                    connects += 1
                    elapsed = event_ts - start_ts
                    if elapsed <= 5 * 60:
                        first5 += 1
                    if elapsed <= 10 * 60:
                        first10 += 1
                    if elapsed <= 15 * 60:
                        first15 += 1
                elif event_type == "disconnect":
                    disconnects += 1
                    minutes = int(event["connection_minutes"])
                    if 0 < minutes <= 5:
                        early_disconnects += 1
                    if minutes > 0:
                        player_minutes += minutes

            sessions.append({
                "host_port": port,
                "map": str(start_row["map"]),
                "gamemode": str(start_row["gamemode"]),
                "start": start_ts,
                "end": end_ts,
                "duration_minutes": duration / 60.0,
                "connects": connects,
                "disconnects": disconnects,
                "first5": first5,
                "first10": first10,
                "first15": first15,
                "early_disconnects": early_disconnects,
                "player_minutes": player_minutes,
                "net_delta": connects - disconnects,
            })

    sessions.sort(key=lambda session: (int(session["host_port"]), int(session["start"])))
    return sessions


def print_map_session_metrics(sessions: list[dict[str, str | int | float]], limit: int, min_sessions: int) -> None:
    if not sessions:
        return

    by_map: dict[str, list[dict[str, str | int | float]]] = defaultdict(list)
    for session in sessions:
        by_map[str(session["map"])].append(session)

    print("\nInferred map sessions")
    print(f"  sessions: {len(sessions):,}")
    print(f"  average_minutes: {mean(float(session['duration_minutes']) for session in sessions):.1f}")
    print(f"  median_minutes: {median(float(session['duration_minutes']) for session in sessions):.1f}")

    qualified = {
        map_name: map_sessions
        for map_name, map_sessions in by_map.items()
        if len(map_sessions) >= min_sessions
    }

    velocity = []
    net_delta = []
    early_leave = []
    player_density = []
    connects_per_rotation = []

    for map_name, map_sessions in qualified.items():
        count = len(map_sessions)
        connects = sum(int(session["connects"]) for session in map_sessions)
        disconnects = sum(int(session["disconnects"]) for session in map_sessions)
        early = sum(int(session["early_disconnects"]) for session in map_sessions)
        player_minutes = sum(int(session["player_minutes"]) for session in map_sessions)
        duration = sum(float(session["duration_minutes"]) for session in map_sessions)

        velocity.append((sum(int(session["first15"]) for session in map_sessions) / count, map_name))
        net_delta.append((sum(int(session["net_delta"]) for session in map_sessions) / count, map_name))
        connects_per_rotation.append((connects / count, map_name))
        if disconnects > 0:
            early_leave.append((early / disconnects, map_name))
        if duration > 0:
            player_density.append((player_minutes / duration, map_name))

    print("\nBest join velocity by map")
    for value, map_name in sorted(velocity, reverse=True)[:limit]:
        print(f"  {map_name}: {value:.2f} connects in first 15m/session")

    print("\nHighest connects per rotation")
    for value, map_name in sorted(connects_per_rotation, reverse=True)[:limit]:
        print(f"  {map_name}: {value:.2f} connects/session")

    print("\nBest average net population delta")
    for value, map_name in sorted(net_delta, reverse=True)[:limit]:
        print(f"  {map_name}: {value:+.2f} connects-minus-disconnects/session")

    print("\nWorst average net population delta")
    for value, map_name in sorted(net_delta)[:limit]:
        print(f"  {map_name}: {value:+.2f} connects-minus-disconnects/session")

    print("\nHighest early leave rate")
    for value, map_name in sorted(early_leave, reverse=True)[:limit]:
        print(f"  {map_name}: {value * 100.0:.1f}% of disconnects at <=5m")

    print("\nHighest recorded player-minutes per map-minute")
    for value, map_name in sorted(player_density, reverse=True)[:limit]:
        print(f"  {map_name}: {value:.2f}")


def print_transition_metrics(sessions: list[dict[str, str | int | float]], limit: int) -> None:
    if len(sessions) < 2:
        return

    by_port: dict[int, list[dict[str, str | int | float]]] = defaultdict(list)
    for session in sessions:
        by_port[int(session["host_port"])].append(session)

    map_transitions: Counter[str] = Counter()
    gamemode_transitions: Counter[str] = Counter()
    next_delta: dict[str, list[int]] = defaultdict(list)

    for port_sessions in by_port.values():
        port_sessions.sort(key=lambda session: int(session["start"]))
        for index, session in enumerate(port_sessions[:-1]):
            next_session = port_sessions[index + 1]
            map_key = f"{session['map']} -> {next_session['map']}"
            gamemode_key = f"{session['gamemode']} -> {next_session['gamemode']}"
            map_transitions[map_key] += 1
            gamemode_transitions[gamemode_key] += 1
            next_delta[map_key].append(int(next_session["net_delta"]))

    print_top("Top map transitions", map_transitions.most_common(), limit)
    print_top("Top gamemode transitions", gamemode_transitions.most_common(), limit)

    scored = []
    for key, values in next_delta.items():
        if len(values) < 3:
            continue
        scored.append((mean(values), key, len(values)))

    print("\nBest repeated transitions by next-map net delta")
    for value, key, count in sorted(scored, reverse=True)[:limit]:
        print(f"  {key}: next avg {value:+.2f}, samples {count}")

    print("\nWorst repeated transitions by next-map net delta")
    for value, key, count in sorted(scored)[:limit]:
        print(f"  {key}: next avg {value:+.2f}, samples {count}")


def print_disconnect_bursts(rows: list[dict[str, str | int]], limit: int, window_seconds: int, minimum: int) -> None:
    disconnects = [row for row in rows if row["event_type"] == "disconnect"]
    disconnects.sort(key=lambda row: int(row["occurred_at"]))
    bursts = []
    index = 0

    while index < len(disconnects):
        end = index
        start_ts = int(disconnects[index]["occurred_at"])
        while end < len(disconnects) and int(disconnects[end]["occurred_at"]) - start_ts <= window_seconds:
            end += 1

        count = end - index
        if count >= minimum:
            window = disconnects[index:end]
            reasons = Counter(str(row["reason"]) for row in window)
            maps = Counter(str(row["map"]) for row in window)
            bursts.append((count, start_ts, reasons.most_common(1)[0][0], maps.most_common(1)[0][0]))
            index = end
        else:
            index += 1

    print(f"\nDisconnect bursts ({minimum}+ disconnects within {window_seconds}s)")
    if not bursts:
        print("  none found")
        return

    for count, start_ts, reason, map_name in sorted(bursts, reverse=True)[:limit]:
        started = datetime.fromtimestamp(start_ts)
        print(f"  {started:%Y-%m-%d %H:%M:%S}: {count} disconnects, map {map_name}, top reason {reason}")


def print_player_cohort_metrics(rows: list[dict[str, str | int]]) -> None:
    connects = [row for row in rows if row["event_type"] == "connect" and row["steamid"]]
    seen: set[str] = set()
    first_time = 0
    returning = 0

    for row in connects:
        steamid = str(row["steamid"])
        if steamid in seen:
            returning += 1
        else:
            first_time += 1
            seen.add(steamid)

    total = first_time + returning
    if total == 0:
        return

    print("\nPlayer cohort connects")
    print(f"  first_seen_in_range: {first_time} ({first_time / total * 100.0:.1f}%)")
    print(f"  returning_in_range: {returning} ({returning / total * 100.0:.1f}%)")


def summarize(rows: list[dict[str, str | int]], limit: int, days: int, min_sessions: int, max_session_minutes: int, burst_window: int, burst_minimum: int) -> None:
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

    print_player_cohort_metrics(rows)
    sessions = infer_map_sessions(rows, max_session_minutes)
    print_map_session_metrics(sessions, limit, min_sessions)
    print_transition_metrics(sessions, limit)
    print_disconnect_bursts(rows, limit, burst_window, burst_minimum)


def main() -> int:
    parser = argparse.ArgumentParser(description="Summarize the SourceMod server_connection_events analytics table.")
    parser.add_argument("--config", default=DEFAULT_DB_CONFIG, help="SourceMod databases.cfg path")
    parser.add_argument("--connection", default="default", help="databases.cfg connection name")
    parser.add_argument("--table", default=DEFAULT_TABLE, help="analytics table name")
    parser.add_argument("--mysql", default="mysql", help="mysql client binary")
    parser.add_argument("--days", type=int, default=0, help="only include the last N days; 0 means all rows")
    parser.add_argument("--top", type=int, default=10, help="number of rows to show in top lists")
    parser.add_argument("--min-sessions", type=int, default=5, help="minimum inferred sessions required for per-map session rankings")
    parser.add_argument("--max-session-minutes", type=int, default=360, help="ignore inferred map sessions longer than this")
    parser.add_argument("--burst-window", type=int, default=60, help="disconnect burst window in seconds")
    parser.add_argument("--burst-minimum", type=int, default=8, help="minimum disconnects inside the burst window")
    args = parser.parse_args()

    try:
        config = parse_databases_cfg(args.config, args.connection)
        db_args = mysql_args(args.mysql, config)
        password = config.get("pass", "")
        if not table_exists(db_args, password, args.table):
            print(f'ERROR: table "{args.table}" does not exist in database "{config.get("database", "")}".', file=sys.stderr)
            return 2

        rows = fetch_rows(db_args, password, args.table, args.days)
        summarize(
            rows,
            max(args.top, 1),
            args.days,
            max(args.min_sessions, 1),
            max(args.max_session_minutes, 1),
            max(args.burst_window, 1),
            max(args.burst_minimum, 2),
        )
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
