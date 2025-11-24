#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Kill existing screens if they exist
for sess in tf2 mge; do
    if screen -list | grep -q "\.${sess}\b"; then
        screen -S "$sess" -X quit || true
    fi
done

# Start fresh sessions
screen -dmS tf2 ./tf2.sh
screen -dmS mge ./mge.sh
