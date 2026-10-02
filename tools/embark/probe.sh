#!/bin/bash
# probe.sh embx emby : set the embark rectangle minimum to (embx,emby) on the local embark map and print the popup and
# the info panel (soil, metals, aquifer line, trees). EXPERIMENTAL (desktop-free embark, see README.md).
# Environment: DF_DIR = Dwarf Fortress folder (default below), EMBARK_DIR = folder with the embark Lua helpers (this folder).
DF_DIR="${DF_DIR:-C:/Program Files (x86)/Steam/steamapps/common/Dwarf Fortress}"
EMBARK_DIR="${EMBARK_DIR:-$(cd "$(dirname "$0")" && pwd)}"
cd "$DF_DIR/hack" || exit 1
for k in 1 2 3; do if ./dfhack-run.exe lua -f "$EMBARK_DIR/screen.lua" | grep -q 'Confirm'; then ./dfhack-run.exe lua -f "$EMBARK_DIR/findclick.lua" Abort >/dev/null; sleep 2; fi; done
if ! ./dfhack-run.exe lua -f "$EMBARK_DIR/screen.lua" | grep -q 'Click on the map to embark'; then ./dfhack-run.exe lua -f "$EMBARK_DIR/findclick_bottom.lua" Embark >/dev/null; sleep 2; fi
./dfhack-run.exe lua "local scr=dfhack.gui.getCurViewscreen() scr.zoom_cent_x=$1-32 scr.zoom_cent_y=$2+10"; sleep 4
./dfhack-run.exe lua -f "$EMBARK_DIR/hold.lua" 600 400 >/dev/null; sleep 2; ./dfhack-run.exe lua -f "$EMBARK_DIR/clickonly.lua"; sleep 3
./dfhack-run.exe lua "local scr=dfhack.gui.getCurViewscreen() local l=scr.location print('emb',l.embark_pos_min.x,l.embark_pos_min.y,'rp',l.region_pos.x,l.region_pos.y)"
./dfhack-run.exe lua -f "$EMBARK_DIR/screen.lua" | cut -c1-200 | sed 's/  */ /g' | grep -v '^ *[0-9]* *$' | grep -viE "Neighbors|Nearest|War,|Hundreds|Click the|Abort Show|FPS|focus"
./dfhack-run.exe lua -f "$EMBARK_DIR/hold.lua" stop >/dev/null
