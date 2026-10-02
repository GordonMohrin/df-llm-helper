# Embark without a desktop (DFHack Lua, as of 01.10.2026)
Scripts from the scratchpad session; adjust the `SP=` paths in `probe.sh`/`scan2.sh`.
- `screen.lua`: print the screen's text buffer (menus, popups, info panel on the right).
- `findclick.lua <text>` / `findclick_bottom.lua <text>`: search the buffer for text and click it (from the top or bottom respectively; pixel = tile_pixel_x/y, which change with the window size!).
- `clickpx2.lua px py`: click at a pixel (WORLD MAP: set `scr.region_cent_x/y`, then click at the screen center -> zooms to that world tile; screen center = (screen_pixel_x/2, screen_pixel_y/2)).
- Local placement (zoomed_in, click the "Embark" button at the bottom): set `scr.zoom_cent_x/y = (embx-32, emby+10)`, wait 4 s, `hold.lua 600 400` (hold the mouse every frame), `clickonly.lua`, `hold.lua stop` -> rectangle minimum = (embx,emby) (embx=16*worldx+locx). The info panel (soil, metals, aquifer line, trees) is then in the text buffer; popup 'light aquifer' = pick another site.
- Then popups 'Confirm', 'Play now'. `probe.sh embx emby` reads popup+panel, `scan2.sh` scans a grid.
Warning: fast double clicks/probes without a pause can crash DF (happened once).
