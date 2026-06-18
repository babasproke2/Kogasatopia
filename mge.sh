#!/bin/sh
SM_PATH="${SM_PATH:-$HOME/hlserver/tf2/tf/addons/sourcemod}"
TF2_DIR="${TF2_DIR:-$(cd "$SM_PATH/../../../.." && pwd)}"
STEAM_DIR="${STEAM_DIR:-$(dirname "$TF2_DIR")}"
STEAMCMD_SCRIPT="${STEAMCMD_SCRIPT:-$STEAM_DIR/update_script.txt}"

cd "$TF2_DIR" || exit 1

./srcds_run -console -game tf \
    +sv_pure 0 \
    -secure \
    -port 27016 \
    +map mge_eientei_v4a \
    -autoupdate \
    +servercfgfile server_testing.cfg \
    -steam_dir "$STEAM_DIR" \
    -steamcmd_script "$STEAMCMD_SCRIPT" \
    +maxplayers 18 \
    +sv_setsteamaccount b \
    2>&1 | egrep -v "Staging library folder not found|Install library folder not found"
