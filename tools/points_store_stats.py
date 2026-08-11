#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
from collections import Counter, defaultdict
from datetime import datetime

from kogasa_db import DEFAULT_DB_CONFIG, mysql_args, mysql_query, parse_databases_cfg, sql_literal, table_exists


DEFAULT_TABLE = "plugin_statistics_events"


def parse_message(message: str) -> dict[str, str]:
    parsed: dict[str, str] = {}
    for part in message.split("|"):
        if "=" not in part:
            continue
        key, value = part.split("=", 1)
        if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
            value = value[1:-1]
        parsed[key] = value
    return parsed


def fetch_rows(args: list[str], password: str, table: str, days: int) -> list[dict[str, object]]:
    where = "WHERE events.source_plugin = 'points_store'"
    if days > 0:
        where += f" AND events.occurred_at >= UNIX_TIMESTAMP() - {days * 86400}"

    query = f"""
        SELECT events.id, events.occurred_at, events.event_name, sessions.map_name,
               events.message, 0, ''
        FROM {table} AS events
        JOIN plugin_statistics_map_sessions AS sessions ON sessions.id = events.session_id
        {where}
        ORDER BY events.id;
    """
    output = mysql_query(args, password, query)

    rows: list[dict[str, object]] = []
    for row in csv.reader(output.splitlines(), delimiter="\t"):
        if len(row) < 7:
            continue
        rows.append({
            "id": int(row[0]),
            "occurred_at": int(row[1]),
            "event_name": row[2],
            "map_name": row[3] or "unknown",
            "message": row[4],
            "imported": int(row[5]),
            "source_file": row[6],
            "fields": parse_message(row[4]),
        })
    return rows


def fmt_time(timestamp: int) -> str:
    return datetime.fromtimestamp(timestamp).strftime("%Y-%m-%d %H:%M:%S")


def print_counter(title: str, counter: Counter[str], limit: int) -> None:
    print(f"\n{title}")
    for key, value in counter.most_common(limit):
        print(f"  {key}: {value:,}")


def print_pairs(title: str, rows: list[tuple[int, str]], limit: int) -> None:
    print(f"\n{title}")
    for value, key in rows[:limit]:
        print(f"  {key}: {value:,}")


def analyze(rows: list[dict[str, object]], limit: int) -> None:
    if not rows:
        print("No points store statistics rows found.")
        return

    event_counts: Counter[str] = Counter(str(row["event_name"]) for row in rows)
    imported_counts: Counter[str] = Counter("imported" if int(row["imported"]) else "live_sql" for row in rows)
    map_events: Counter[str] = Counter(str(row["map_name"]) for row in rows)
    per_minute: Counter[int] = Counter(int(row["occurred_at"]) // 60 for row in rows)

    net_by_type: defaultdict[str, int] = defaultdict(int)
    positive_by_type: Counter[str] = Counter()
    negative_by_type: Counter[str] = Counter()
    player_stats: defaultdict[str, dict[str, object]] = defaultdict(lambda: {"name": "", "net": 0, "earned": 0, "spent": 0, "events": 0})
    map_net: defaultdict[str, int] = defaultdict(int)
    rejection_reasons: Counter[str] = Counter()
    purchase_rejections: Counter[str] = Counter()
    transfers: list[tuple[int, str, str]] = []
    level_counts: defaultdict[str, Counter[str]] = defaultdict(Counter)

    total_positive = 0
    total_negative = 0

    for row in rows:
        event_name = str(row["event_name"])
        fields = row["fields"]
        assert isinstance(fields, dict)

        if event_name == "bp_delta":
            delta = int(fields.get("delta", "0") or 0)
            source_type = fields.get("type", "unknown") or "unknown"
            steamid64 = fields.get("steamid64", "")
            player = player_stats[steamid64]
            player["name"] = fields.get("name", "") or player["name"]
            player["net"] = int(player["net"]) + delta
            player["events"] = int(player["events"]) + 1
            net_by_type[source_type] += delta
            map_net[str(row["map_name"])] += delta

            if source_type in {"killstreak", "killstreak_end", "multikill"}:
                level_counts[source_type][fields.get("target_value", "unknown") or "unknown"] += 1

            if delta > 0:
                total_positive += delta
                positive_by_type[source_type] += delta
                player["earned"] = int(player["earned"]) + delta
            elif delta < 0:
                total_negative += -delta
                negative_by_type[source_type] += -delta
                player["spent"] = int(player["spent"]) + -delta
        elif event_name == "bp_rejected":
            key = f"{fields.get('reason', 'unknown')} / {fields.get('type', 'unknown')}"
            rejection_reasons[key] += 1
        elif event_name == "purchase_rejected":
            key = f"{fields.get('item_key', 'unknown')} / {fields.get('reason', 'unknown')}"
            purchase_rejections[key] += 1
        elif event_name == "transfer_success":
            amount = int(fields.get("amount", "0") or 0)
            transfers.append((amount, fields.get("sender_name", ""), fields.get("target_name", "")))

    first = min(int(row["occurred_at"]) for row in rows)
    last = max(int(row["occurred_at"]) for row in rows)
    gameplay_minted = total_positive - positive_by_type.get("transfer_in", 0)
    true_sinks = total_negative - negative_by_type.get("transfer_out", 0)

    print("Points Store Economy Statistics")
    print(f"  rows: {len(rows):,}")
    print(f"  range: {fmt_time(first)} to {fmt_time(last)}")
    print(f"  balance-positive deltas: {total_positive:,}")
    print(f"  balance-negative deltas: {total_negative:,}")
    print(f"  net balance delta: {total_positive - total_negative:+,}")
    print(f"  gameplay minted, excluding transfer_in: {gameplay_minted:,}")
    print(f"  true sinks, excluding transfer_out: {true_sinks:,}")
    print(f"  max rows/minute: {max(per_minute.values()) if per_minute else 0:,}")

    print_counter("Rows by source", imported_counts, limit)
    print_counter("Rows by event", event_counts, limit)

    print("\nTop gameplay sources")
    for source_type, value in positive_by_type.most_common(limit):
        share = (value * 100.0 / total_positive) if total_positive else 0.0
        print(f"  {source_type}: {value:,} ({share:.1f}%)")

    print_pairs("Top net maps", sorted(((value, key) for key, value in map_net.items()), reverse=True), limit)
    print_counter("Top maps by logged rows", map_events, limit)

    top_earned = sorted(
        ((int(stats["earned"]), int(stats["net"]), int(stats["events"]), str(stats["name"]), steamid64) for steamid64, stats in player_stats.items()),
        reverse=True,
    )
    print("\nTop players by earned currency")
    for earned, net, events, name, steamid64 in top_earned[:limit]:
        print(f"  {name} ({steamid64}): earned {earned:,}, net {net:+,}, events {events:,}")

    if level_counts:
        print("\nKillstreak and multikill levels")
        for source_type in sorted(level_counts):
            def sort_key(item: tuple[str, int]) -> tuple[int, str]:
                key, _ = item
                return (int(key), key) if key.isdigit() else (999999, key)
            rendered = ", ".join(f"{key}: {value}" for key, value in sorted(level_counts[source_type].items(), key=sort_key))
            print(f"  {source_type}: {rendered}")

    if rejection_reasons:
        print_counter("Rejections", rejection_reasons, limit)
    if purchase_rejections:
        print_counter("Rejected purchases", purchase_rejections, limit)
    if transfers:
        print("\nTransfers")
        for amount, sender, target in transfers[:limit]:
            print(f"  {sender} -> {target}: {amount:,}")

    print("\nBusiest minutes")
    for minute, count in per_minute.most_common(limit):
        print(f"  {fmt_time(minute * 60)}: {count:,} rows")


def main() -> int:
    parser = argparse.ArgumentParser(description="Summarize points_store statistics events.")
    parser.add_argument("--db-config", default=DEFAULT_DB_CONFIG, help="Path to SourceMod databases.cfg")
    parser.add_argument("--db-section", default="default", help="databases.cfg section to use")
    parser.add_argument("--mysql-bin", default="mysql", help="mysql client binary")
    parser.add_argument("--table", default=DEFAULT_TABLE, help="canonical plugin statistics events table")
    parser.add_argument("--days", type=int, default=0, help="Only include rows from the last N days; 0 means all rows")
    parser.add_argument("--limit", type=int, default=10, help="Rows to show per top-list")
    args = parser.parse_args()

    config = parse_databases_cfg(args.db_config, args.db_section)
    mysql = mysql_args(args.mysql_bin, config)
    password = config.get("pass", "")

    if not table_exists(mysql, password, args.table):
        raise SystemExit(f"error: table {args.table!r} does not exist")

    rows = fetch_rows(mysql, password, args.table, args.days)
    analyze(rows, args.limit)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
