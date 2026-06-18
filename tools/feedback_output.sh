#!/usr/bin/env bash

set -euo pipefail

SM_PATH="${SM_PATH:-$HOME/hlserver/tf2/tf/addons/sourcemod}"
CFG="${DATABASES_CFG:-$SM_PATH/configs/databases.cfg}"
TABLE="whaletracker_feedback"

cfg_value() {
    local key="$1"
    awk -v target="$key" '
        /^\s*"default"\s*$/ { in_default_header=1; next }
        in_default_header && /^\s*\{/ { in_default_block=1; in_default_header=0; next }
        in_default_block && /^\s*\}/ { exit }
        in_default_block {
            pattern = "^[[:space:]]*\"" target "\"[[:space:]]*\"([^\"]*)\""
            if (match($0, pattern)) {
                value = substr($0, RSTART, RLENGTH)
                gsub("^[[:space:]]*\"" target "\"[[:space:]]*\"", "", value)
                gsub("\"$", "", value)
                print value
                exit
            }
        }
    ' "$CFG"
}

host="$(cfg_value host)"
database="$(cfg_value database)"
user="$(cfg_value user)"
pass="$(cfg_value pass)"

if [[ -z "${host}" || -z "${database}" || -z "${user}" ]]; then
    echo "Failed to parse MySQL credentials from ${CFG}" >&2
    exit 1
fi

mysql -h "${host}" -u "${user}" -p"${pass}" -D "${database}" \
    -e "SELECT id, player_name, message, created_at FROM ${TABLE} ORDER BY id DESC LIMIT 50;"
