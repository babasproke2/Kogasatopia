#!/bin/bash -e
# This change just copies the compiled file to the plugins folder for faster work, I love this
cd "$(dirname "$0")"

test -e compiled || mkdir compiled
SM_PATH="${SM_PATH:-$(cd .. && pwd)}"
PLUGIN_DIR="${SM_PLUGIN_DIR:-$SM_PATH/plugins}"
SPCOMP="${SPCOMP:-./spcomp}"

if [[ $# -ne 0 ]]; then
    for sourcefile in "$@"
    do
        smxfile="$(echo "$sourcefile" | sed -e 's/\.sp$/\.smx/')"
        echo -e "\nCompiling $sourcefile..."
        "$SPCOMP" "$sourcefile" -iinclude -ocompiled/"$smxfile"
        cp compiled/"$smxfile" "$PLUGIN_DIR"/
    done
else
    for sourcefile in *.sp
    do
        smxfile="$(echo "$sourcefile" | sed -e 's/\.sp$/\.smx/')"
        echo -e "\nCompiling $sourcefile ..."
        "$SPCOMP" "$sourcefile" -iinclude -ocompiled/"$smxfile"
        cp compiled/"$smxfile" "$PLUGIN_DIR"/
    done
fi
