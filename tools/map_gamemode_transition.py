#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import os
import re
import subprocess
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime
from statistics import mean


DEFAULT_DB_CONFIG = "/home/kogasa/hlserver/tf2/tf/addons/sourcemod/configs/databases.cfg"
SESSION_TABLE = "map_statistics_sessions"
POPULATION_TABLE = "server_population_statistics_samples"
VOTE_TABLE = "nativevotes_statistics_events"


@dataclass(frozen=True)
class Session:
    id: int
    session_id: str
    host_port: int
    map_name: str
    gamemode: str
    started_at: int
    ended_at: int
    duration: int
    start_players: int
    end_players: int
    peak_players: int
    avg_players: float
    player_seconds: int
    joins: int
    leaves: int
    sample_count: int
    end_reason: str
    weekday: int
    hour_of_day: int


@dataclass(frozen=True)
class SampleSummary:
    first_players: int
    first_15_players: int
    first_15_delta: int
    max_first_15_players: int


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
    if config.get("host"):
        args.extend(["-h", config["host"]])
    if config.get("user"):
        args.extend(["-u", config["user"]])
    if config.get("port"):
        args.extend(["-P", config["port"]])
    if config.get("database"):
        args.append(config["database"])
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


def sql_literal(value: str) -> str:
    return value.replace("\\", "\\\\").replace("'", "''")


def table_exists(args: list[str], password: str, table: str) -> bool:
    query = (
        "SELECT COUNT(*) FROM information_schema.tables "
        f"WHERE table_schema = DATABASE() AND table_name = '{sql_literal(table)}';"
    )
    return mysql_query(args, password, query).strip() == "1"


def fetch_sessions(args: list[str], password: str, days: int, min_peak: int) -> list[Session]:
    where = [f"peak_players >= {min_peak}"]
    if days > 0:
        where.append(f"started_at >= UNIX_TIMESTAMP() - {days * 86400}")

    query = f"""
        SELECT id, map_session_id, host_port, map_name, gamemode, started_at,
               ended_at, duration, start_players, end_players, peak_players,
               avg_players, player_seconds, joins, leaves, sample_count,
               end_reason, weekday, hour_of_day
        FROM {SESSION_TABLE}
        WHERE {" AND ".join(where)}
        ORDER BY host_port, started_at, id;
    """
    output = mysql_query(args, password, query)

    sessions: list[Session] = []
    for row in csv.reader(output.splitlines(), delimiter="\t"):
        if len(row) < 19:
            continue
        sessions.append(Session(
            id=int(row[0]),
            session_id=row[1],
            host_port=int(row[2]),
            map_name=row[3] or "unknown",
            gamemode=row[4] or "unknown",
            started_at=int(row[5]),
            ended_at=int(row[6]),
            duration=int(row[7]),
            start_players=int(row[8]),
            end_players=int(row[9]),
            peak_players=int(row[10]),
            avg_players=float(row[11]),
            player_seconds=int(row[12]),
            joins=int(row[13]),
            leaves=int(row[14]),
            sample_count=int(row[15]),
            end_reason=row[16] or "unknown",
            weekday=int(row[17]),
            hour_of_day=int(row[18]),
        ))
    return sessions


def fetch_sample_summaries(args: list[str], password: str, sessions: list[Session]) -> dict[str, SampleSummary]:
    if not sessions:
        return {}

    session_ids = ",".join(f"'{sql_literal(session.session_id)}'" for session in sessions)
    query = f"""
        SELECT map_session_id, sample_sequence, map_elapsed_seconds, player_count
        FROM {POPULATION_TABLE}
        WHERE map_session_id IN ({session_ids})
        ORDER BY map_session_id, sample_sequence, sampled_at, id;
    """
    output = mysql_query(args, password, query)

    samples: defaultdict[str, list[tuple[int, int, int]]] = defaultdict(list)
    for row in csv.reader(output.splitlines(), delimiter="\t"):
        if len(row) < 4:
            continue
        samples[row[0]].append((int(row[1]), int(row[2]), int(row[3])))

    summaries: dict[str, SampleSummary] = {}
    for session_id, rows in samples.items():
        rows.sort()
        first_players = rows[0][2]
        first_15_rows = [row for row in rows if row[1] <= 900]
        if not first_15_rows:
            first_15_rows = [rows[0]]
        first_15_players = first_15_rows[-1][2]
        max_first_15_players = max(row[2] for row in first_15_rows)
        summaries[session_id] = SampleSummary(
            first_players=first_players,
            first_15_players=first_15_players,
            first_15_delta=first_15_players - first_players,
            max_first_15_players=max_first_15_players,
        )
    return summaries


def fetch_vote_counts(args: list[str], password: str, sessions: list[Session]) -> dict[str, Counter[str]]:
    if not sessions or not table_exists(args, password, VOTE_TABLE):
        return {}

    session_ids = ",".join(f"'{sql_literal(session.session_id)}'" for session in sessions)
    query = f"""
        SELECT map_session_id, event_type, COUNT(*)
        FROM {VOTE_TABLE}
        WHERE map_session_id IN ({session_ids})
        GROUP BY map_session_id, event_type;
    """
    output = mysql_query(args, password, query)

    counts: defaultdict[str, Counter[str]] = defaultdict(Counter)
    for row in csv.reader(output.splitlines(), delimiter="\t"):
        if len(row) < 3:
            continue
        counts[row[0]][row[1]] = int(row[2])
    return counts


def adjacent_transitions(sessions: list[Session]) -> list[tuple[Session, Session]]:
    by_port: defaultdict[int, list[Session]] = defaultdict(list)
    for session in sessions:
        by_port[session.host_port].append(session)

    transitions: list[tuple[Session, Session]] = []
    for port_sessions in by_port.values():
        port_sessions.sort(key=lambda session: (session.started_at, session.id))
        for index in range(len(port_sessions) - 1):
            transitions.append((port_sessions[index], port_sessions[index + 1]))
    return transitions


def transition_score(to_session: Session, sample: SampleSummary | None) -> float:
    session_delta = to_session.end_players - to_session.start_players
    peak_gain = to_session.peak_players - to_session.start_players
    join_pressure = to_session.joins - to_session.leaves
    first_15_delta = sample.first_15_delta if sample else session_delta
    return (first_15_delta * 1.4) + (session_delta * 1.0) + (peak_gain * 0.6) + (join_pressure * 0.35)


def aggregate_transitions(
    transitions: list[tuple[Session, Session]],
    samples: dict[str, SampleSummary],
    key_fn,
) -> list[dict[str, object]]:
    buckets: defaultdict[str, list[tuple[Session, Session, float]]] = defaultdict(list)
    for from_session, to_session in transitions:
        key = key_fn(from_session, to_session)
        buckets[key].append((from_session, to_session, transition_score(to_session, samples.get(to_session.session_id))))

    rows: list[dict[str, object]] = []
    for key, values in buckets.items():
        to_sessions = [value[1] for value in values]
        scores = [value[2] for value in values]
        first_15 = [
            samples[to_session.session_id].first_15_delta
            for to_session in to_sessions
            if to_session.session_id in samples
        ]
        rows.append({
            "key": key,
            "count": len(values),
            "score": mean(scores),
            "avg_session_delta": mean(session.end_players - session.start_players for session in to_sessions),
            "avg_peak_gain": mean(session.peak_players - session.start_players for session in to_sessions),
            "avg_first_15_delta": mean(first_15) if first_15 else 0.0,
            "avg_joins": mean(session.joins for session in to_sessions),
            "avg_leaves": mean(session.leaves for session in to_sessions),
            "avg_players": mean(session.avg_players for session in to_sessions),
        })
    return rows


def print_transition_rows(title: str, rows: list[dict[str, object]], limit: int, min_observations: int, reverse: bool) -> None:
    filtered = [row for row in rows if int(row["count"]) >= min_observations]
    filtered.sort(key=lambda row: (float(row["score"]), int(row["count"])), reverse=reverse)

    print(f"\n{title}")
    if not filtered:
        print("  No rows matched the current filters.")
        return

    for row in filtered[:limit]:
        print(
            "  {key}: score {score:+.2f}, n={count}, "
            "session {avg_session_delta:+.1f}, first15 {avg_first_15_delta:+.1f}, "
            "peak {avg_peak_gain:+.1f}, joins/leaves {avg_joins:.1f}/{avg_leaves:.1f}, avg pop {avg_players:.1f}"
            .format(**row)
        )


def print_vote_pressure(votes: dict[str, Counter[str]], sessions: list[Session], limit: int) -> None:
    if not votes:
        print("\nVote Pressure")
        print("  No native vote statistics rows matched these sessions.")
        return

    by_map: defaultdict[str, Counter[str]] = defaultdict(Counter)
    sessions_by_id = {session.session_id: session for session in sessions}
    for session_id, counter in votes.items():
        session = sessions_by_id.get(session_id)
        if session is None:
            continue
        by_map[session.map_name].update(counter)

    rows = sorted(
        by_map.items(),
        key=lambda item: (
            item[1].get("rtv", 0) + item[1].get("nomination", 0) + item[1].get("eligibility_failure", 0),
            item[0],
        ),
        reverse=True,
    )

    print("\nVote Pressure")
    for map_name, counter in rows[:limit]:
        print(
            f"  {map_name}: rtv={counter.get('rtv', 0)}, nominations={counter.get('nomination', 0)}, "
            f"options={counter.get('vote_option', 0)}, winners={counter.get('vote_winner', 0)}, "
            f"eligibility failures={counter.get('eligibility_failure', 0)}"
        )


def print_candidate_rows(
    sessions: list[Session],
    transitions: list[tuple[Session, Session]],
    samples: dict[str, SampleSummary],
    votes: dict[str, Counter[str]],
    limit: int,
) -> None:
    if not sessions:
        return

    latest = max(sessions, key=lambda session: (session.started_at, session.id))
    recent_maps = {session.map_name for session in sorted(sessions, key=lambda session: session.started_at)[-4:]}

    candidate_scores: defaultdict[str, list[float]] = defaultdict(list)
    candidate_modes: dict[str, str] = {}
    candidate_counts: Counter[str] = Counter()

    for from_session, to_session in transitions:
        if from_session.map_name != latest.map_name:
            continue
        if to_session.map_name in recent_maps:
            continue
        candidate_scores[to_session.map_name].append(transition_score(to_session, samples.get(to_session.session_id)))
        candidate_modes[to_session.map_name] = to_session.gamemode
        candidate_counts[to_session.map_name] += 1

    if not candidate_scores:
        for session in sessions:
            if session.map_name in recent_maps:
                continue
            score = (session.avg_players * 0.4) + ((session.end_players - session.start_players) * 1.0) + ((session.joins - session.leaves) * 0.25)
            if session.session_id in votes:
                score -= votes[session.session_id].get("rtv", 0) * 0.5
            candidate_scores[session.map_name].append(score)
            candidate_modes[session.map_name] = session.gamemode
            candidate_counts[session.map_name] += 1

    rows = [
        (mean(scores), candidate_counts[map_name], map_name, candidate_modes.get(map_name, "unknown"))
        for map_name, scores in candidate_scores.items()
    ]
    rows.sort(reverse=True)

    print(f"\nSuggested Next-Map Candidates after {latest.map_name} ({latest.gamemode})")
    if not rows:
        print("  No candidates matched the current filters.")
        return

    for score, count, map_name, gamemode in rows[:limit]:
        print(f"  {map_name} ({gamemode}): score {score:+.2f}, evidence sessions={count}")


def fmt_time(timestamp: int) -> str:
    return datetime.fromtimestamp(timestamp).strftime("%Y-%m-%d %H:%M:%S")


def main() -> int:
    parser = argparse.ArgumentParser(description="Analyze map and gamemode transition health from SourceMod statistics tables.")
    parser.add_argument("--db-config", default=DEFAULT_DB_CONFIG)
    parser.add_argument("--db-section", default="default")
    parser.add_argument("--mysql-bin", default="mysql")
    parser.add_argument("--days", type=int, default=30, help="Only include sessions started within this many days. Use 0 for all time.")
    parser.add_argument("--min-peak", type=int, default=4, help="Ignore map sessions whose peak playercount is below this value.")
    parser.add_argument("--min-observations", type=int, default=1)
    parser.add_argument("--limit", type=int, default=10)
    args = parser.parse_args()

    config = parse_databases_cfg(args.db_config, args.db_section)
    mysql = mysql_args(args.mysql_bin, config)
    password = config.get("pass", "")

    for table in (SESSION_TABLE, POPULATION_TABLE):
        if not table_exists(mysql, password, table):
            raise SystemExit(f"Required table does not exist: {table}")

    sessions = fetch_sessions(mysql, password, args.days, args.min_peak)
    samples = fetch_sample_summaries(mysql, password, sessions)
    votes = fetch_vote_counts(mysql, password, sessions)
    transitions = adjacent_transitions(sessions)

    print("Map/Gamemode Transition Analysis")
    print(f"  sessions: {len(sessions):,}")
    print(f"  transitions: {len(transitions):,}")
    print(f"  days: {'all' if args.days <= 0 else args.days}")
    print(f"  min_peak: {args.min_peak}")
    if sessions:
        print(f"  range: {fmt_time(min(session.started_at for session in sessions))} to {fmt_time(max(session.started_at for session in sessions))}")

    map_rows = aggregate_transitions(transitions, samples, lambda previous, current: f"{previous.map_name} -> {current.map_name}")
    mode_rows = aggregate_transitions(transitions, samples, lambda previous, current: f"{previous.gamemode} -> {current.gamemode}")

    print_transition_rows("Best Map Transitions", map_rows, args.limit, args.min_observations, True)
    print_transition_rows("Worst Map Transitions", map_rows, args.limit, args.min_observations, False)
    print_transition_rows("Gamemode Transition Health", mode_rows, args.limit, args.min_observations, True)
    print_vote_pressure(votes, sessions, args.limit)
    print_candidate_rows(sessions, transitions, samples, votes, args.limit)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
