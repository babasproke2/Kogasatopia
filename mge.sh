#!/bin/sh
cd /home/kogasa/hlserver/tf2 || exit 1

./srcds_run -console -game tf \
    +sv_pure 0 \
    -secure \
    -port 27016 \
    +map mge_eientei_v4a \
    -autoupdate \
    +servercfgfile server_testing.cfg \
    -steam_dir /home/kogasa/hlserver \
    -steamcmd_script /home/kogasa/hlserver/update_script.txt \
    +maxplayers 18 \
    +sv_setsteamaccount b \
    2>&1 | egrep -v "Staging library folder not found|Install library folder not found"
