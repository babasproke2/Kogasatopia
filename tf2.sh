#!/bin/sh
cd /home/kogasa/hlserver/tf2 || exit 1

./srcds_run -console -game tf \
    -port 27015 \
    -secure \
    +map koth_product_pro \
    -autoupdate \
    -steam_dir /home/kogasa/hlserver \
    -steamcmd_script /home/kogasa/hlserver/update_script.txt \
    +sv_pure 0 \
    +maxplayers 32 \
    +sv_setsteamaccount a \
    2>&1 | egrep -v "Staging library folder not found|Install library folder not found"
