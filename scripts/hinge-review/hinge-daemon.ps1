# hinge-daemon.ps1 — the host-side Hinge daemon (substrate-driven + obeys the emergency stop).
#
# `claude` lives on the host, so the reviewer must run host-side. But the SUBSTRATE drives
# it: each tick the daemon asks `stewards.hinge_gate_status()` whether to run, how often, and
# whether the system is paused. It runs the reviewer only when there's pending work AND the
# substrate is not paused — so the global emergency stop (autonomy_paused, which the watchman
# trips) halts the gate along with the source and the digesters. The cadence comes from config
# (hinge_daemon_interval_seconds), so pg-ai-stewards owns the Hinge schedule, not the host.
#
# Run it in a terminal:   pwsh scripts/hinge-review/hinge-daemon.ps1
# Or register it as a Windows scheduled task / startup item for hands-free operation.
# Stop it with Ctrl-C (or pause the whole substrate: it will hold until you resume).
param(
    [string]$Container   = "stewards-oss-pg",
    [int]   $MinInterval = 30,          # floor on the poll cadence, regardless of config
    [string]$Model       = "",          # optional: pass through to the reviewer (e.g. claude-sonnet-4-6)
    [switch]$Once                       # run a single poll + act, then exit (for testing / cron-style ticks)
)
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$log  = Join-Path $here "hinge-review.log"
function Note($m) { $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') hinge-daemon: $m"; Write-Host $line; Add-Content -Path $log -Value $line }

Note "starting — substrate-driven cadence; obeys autonomy_paused (emergency stop)"
while ($true) {
    $json = docker exec -i $Container psql -U stewards -d stewards -tAc "SELECT stewards.hinge_gate_status()" 2>$null
    $st = $null; try { $st = $json | ConvertFrom-Json } catch { }
    if ($null -eq $st) { Note "substrate unreachable — retrying in 30s"; Start-Sleep -Seconds 30; continue }

    $interval = [Math]::Max($MinInterval, [int]$st.interval_seconds)
    if ($st.paused) {
        Note "PAUSED ($($st.paused_reason)) — holding"
    } elseif ($st.should_run) {
        Note "$($st.pending) pending — running the reviewer"
        $args = @("$here\hinge-review.py", "--container", $Container)
        if ($Model) { $args += @("--model", $Model) }
        & python @args
    } else {
        Note "idle ($($st.pending) pending)"
    }
    if ($Once) { break }
    Start-Sleep -Seconds $interval
}
