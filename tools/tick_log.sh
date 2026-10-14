#!/bin/bash
# passive crash forensics: append "<time> <tick> <pause> <pop>" every 5 s so the tick of a DF crash is known
E="E:/Program Files (x86)/Steam/steamapps/common/Dwarf Fortress/hack/dfhack-run.exe"
OUT="${1:-tick_log.txt}"
while true; do
  r=$(timeout 10 "$E" lua "print(df.global.cur_year, df.global.cur_year_tick, tostring(df.global.pause_state), #dfhack.units.getCitizens(true))" 2>&1 | tail -1)
  echo "$(date +%T) $r" >> "$OUT"
  sleep 5
done
