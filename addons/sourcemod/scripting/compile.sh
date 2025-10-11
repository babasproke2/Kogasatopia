#!/bin/bash -e
#This slight edit of compile.sh copies to the plugins directory for me, very convenient
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
        cp compiled/"$smxfile" ../plugins/
    done
fi
