#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-$HOME/Kogasatopia}"
SM_PATH="${SM_PATH:-$HOME/hlserver/tf2/tf/addons/sourcemod}"
LIVE_TF_DIR="${LIVE_TF_DIR:-$(cd "$SM_PATH/../.." && pwd)}"
FRONTEND_DIR="${FRONTEND_DIR:-$HOME/Kogasatopia-Frontend}"
BRANCH="${BRANCH:-main}"

cd "$REPO_DIR"

if ! git diff --cached --quiet; then
    echo "Refusing to sync: git index already has staged changes." >&2
    exit 2
fi

export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -i $HOME/.ssh/id_ed25519 -o IdentitiesOnly=yes}"

targets=(
    "addons/sourcemod/configs/announcers.cfg|tf/addons/sourcemod/configs/announcers.cfg|raw"
    "addons/sourcemod/configs/adverts.cfg|tf/addons/sourcemod/configs/adverts.cfg|raw"
    "addons/sourcemod/configs/changelog.cfg|tf/addons/sourcemod/configs/changelog.cfg|raw"
    "addons/sourcemod/configs/empty_server_maps.cfg|tf/addons/sourcemod/configs/empty_server_maps.cfg|raw"
    "addons/sourcemod/configs/empty_training_maps.cfg|tf/addons/sourcemod/configs/empty_training_maps.cfg|raw"
    "addons/sourcemod/configs/filters.cfg|tf/addons/sourcemod/configs/filters.cfg|raw"
    "addons/sourcemod/configs/mapeval.cfg|tf/addons/sourcemod/configs/mapeval.cfg|raw"
    "addons/sourcemod/configs/mgemod_spawns.cfg|tf/addons/sourcemod/configs/mgemod_spawns.cfg|raw"
    "addons/sourcemod/configs/points_store.cfg|tf/addons/sourcemod/configs/points_store.cfg|raw"
    "addons/sourcemod/configs/saysounds.cfg|tf/addons/sourcemod/configs/saysounds.cfg|raw"
    "addons/sourcemod/configs/precachefiles.cfg|tf/addons/sourcemod/configs/precachefiles.cfg|raw"
    "addons/sourcemod/configs/weapons.cfg|tf/addons/sourcemod/configs/weapons.cfg|raw"
    "cfg/bots.cfg|tf/cfg/bots.cfg|scrub_rcon"
    "cfg/cronjobs.txt|tf/cfg/cronjobs.txt|scrub_rcon"
    "cfg/mapcycle.txt|tf/cfg/mapcycle.txt|raw"
    "cfg/nobots.cfg|tf/cfg/nobots.cfg|scrub_rcon"
    "cfg/server.cfg|tf/cfg/server.cfg|scrub_rcon"
    "cfg/mapsdb/5cp.cfg|tf/cfg/mapsdb/5cp.cfg|scrub_rcon"
    "cfg/mapsdb/adcp.cfg|tf/cfg/mapsdb/adcp.cfg|scrub_rcon"
    "cfg/mapsdb/arena.cfg|tf/cfg/mapsdb/arena.cfg|scrub_rcon"
    "cfg/mapsdb/ctf.cfg|tf/cfg/mapsdb/ctf.cfg|scrub_rcon"
    "cfg/mapsdb/default.cfg|tf/cfg/mapsdb/default.cfg|scrub_rcon"
    "cfg/mapsdb/dm.cfg|tf/cfg/mapsdb/dm.cfg|scrub_rcon"
    "cfg/mapsdb/dom.cfg|tf/cfg/mapsdb/dom.cfg|scrub_rcon"
    "cfg/mapsdb/koth.cfg|tf/cfg/mapsdb/koth.cfg|scrub_rcon"
    "cfg/mapsdb/mge.cfg|tf/cfg/mapsdb/mge.cfg|scrub_rcon"
    "cfg/mapsdb/mge_eientei_v4a.cfg|tf/cfg/mapsdb/mge_eientei_v4a.cfg|scrub_rcon"
    "cfg/mapsdb/payload.cfg|tf/cfg/mapsdb/payload.cfg|scrub_rcon"
    "cfg/mapsdb/payloadrace.cfg|tf/cfg/mapsdb/payloadrace.cfg|scrub_rcon"
    "cfg/mapsdb/pd.cfg|tf/cfg/mapsdb/pd.cfg|scrub_rcon"
    "cfg/mapsdb/plr.cfg|tf/cfg/mapsdb/plr.cfg|scrub_rcon"
    "cfg/mapsdb/server_once.cfg|tf/cfg/mapsdb/server_once.cfg|scrub_rcon"
    "cfg/mapsdb/tc.cfg|tf/cfg/mapsdb/tc.cfg|scrub_rcon"
    "cfg/server_testing.cfg|tf/cfg/server_testing.cfg|scrub_rcon"
    "cfg/sourcemod/new_engi_buildings.cfg|tf/cfg/sourcemod/new_engi_buildings.cfg|scrub_rcon"
    "cfg/sourcemod/nerfhalloweengimmicks.cfg|tf/cfg/sourcemod/nerfhalloweengimmicks.cfg|scrub_rcon"
)

repo_targets=()
frontend_targets=(
    "addons/sourcemod/configs/weapons.cfg|weapons.cfg|raw"
)

copy_target() {
    local live_rel="$1"
    local repo_rel="$2"
    local mode="$3"
    local live_path="$LIVE_TF_DIR/$live_rel"
    local repo_path="$REPO_DIR/$repo_rel"

    if [[ ! -f "$live_path" ]]; then
        echo "Missing live config: $live_path" >&2
        return 1
    fi

    mkdir -p "$(dirname "$repo_path")"
    if [[ "$mode" == "scrub_rcon" ]]; then
        sed '/^[[:space:]]*rcon_password\b/d' "$live_path" > "$repo_path"
    else
        cp "$live_path" "$repo_path"
    fi

    repo_targets+=("$repo_rel")
    echo "synced $live_rel -> $repo_rel"
}

for entry in "${targets[@]}"; do
    IFS='|' read -r live_rel repo_rel mode <<< "$entry"
    copy_target "$live_rel" "$repo_rel" "$mode"
done

copy_frontend_target() {
    local live_rel="$1"
    local frontend_rel="$2"
    local mode="$3"
    local live_path="$LIVE_TF_DIR/$live_rel"
    local frontend_path="$FRONTEND_DIR/$frontend_rel"

    if [[ ! -f "$live_path" ]]; then
        echo "Missing live config: $live_path" >&2
        return 1
    fi

    mkdir -p "$(dirname "$frontend_path")"
    rm -f "$frontend_path"
    if [[ "$mode" == "scrub_rcon" ]]; then
        sed '/^[[:space:]]*rcon_password\b/d' "$live_path" > "$frontend_path"
    else
        cp "$live_path" "$frontend_path"
    fi

    echo "synced $live_rel -> $frontend_path"
}

for entry in "${frontend_targets[@]}"; do
    IFS='|' read -r live_rel frontend_rel mode <<< "$entry"
    copy_frontend_target "$live_rel" "$frontend_rel" "$mode"
done

git add -- "${repo_targets[@]}"

if git diff --cached --quiet -- "${repo_targets[@]}"; then
    echo "No live config changes to commit."
    exit 0
fi

git commit -m "Sync live server configs"
git push origin "$BRANCH"
