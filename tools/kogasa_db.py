from __future__ import annotations

import os
import re
import subprocess


DEFAULT_DB_CONFIG = "/home/kogasa/hlserver/tf2/tf/addons/sourcemod/configs/databases.cfg"


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
