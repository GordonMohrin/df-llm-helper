param([int]$DesktopIndex = 1, [int]$TimeoutS = 180)
# Start Dwarf Fortress (Steam, DFHack via dfhooks) and move its window to virtual desktop N as soon as it appears.
# Never switches the user's current desktop. Requires vdesk_move.ps1 next to this file.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
[void](& (Join-Path $here "vdesk_move.ps1") -LoadOnly)   # compile the COM shim before DF shows a window
if (Get-Process -Name "Dwarf Fortress" -ErrorAction SilentlyContinue) { "DF already running"; }
else { Start-Process "steam://rungameid/975370" }
$deadline = (Get-Date).AddSeconds($TimeoutS)
$moved = @{}
while ((Get-Date) -lt $deadline) {
  $p = Get-Process -Name "Dwarf Fortress" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($p) {
    $p.Refresh()
    $h = $p.MainWindowHandle
    if ($h -ne [IntPtr]::Zero -and -not $moved.ContainsKey([string]$h)) {
      $r = & "$here\vdesk_move.ps1" -Hwnd $h -DesktopIndex $DesktopIndex
      "hwnd $h -> $r"
      if ($r -like "MOVED*" ) { $moved[[string]$h] = $true }
    }
    # DF may replace its window once while initialising; keep watching for 20 s after the first move
    if ($moved.Count -gt 0 -and ((Get-Date) - $p.StartTime).TotalSeconds -gt 40) { break }
  }
  Start-Sleep -Milliseconds 100
}
if ($moved.Count -eq 0) { "no DF window moved within $TimeoutS s"; exit 1 }
"done"
