#!/bin/bash -e
# This change just copies the compiled file to the plugins folder for faster work, I love this
cd "$(dirname "$0")"

test -e compiled || mkdir compiled

if [[ $# -ne 0 ]]; then
    for sourcefile in "$@"
    do
        smxfile="$(echo "$sourcefile" | sed -e 's/\.sp$/\.smx/')"
        echo -e "\nCompiling $sourcefile..."
        ./spcomp "$sourcefile" -ocompiled/"$smxfile"
        cp compiled/"$smxfile" ../plugins/
    done
else
    for sourcefile in *.sp
    do
        smxfile="$(echo "$sourcefile" | sed -e 's/\.sp$/\.smx/')"
        echo -e "\nCompiling $sourcefile ..."
        ./spcomp "$sourcefile" -ocompiled/"$smxfile"
        cp compiled/"$smxfile" /home/kogasa/hlserver/tf2/tf/addons/sourcemod/plugins/
    done
fi
