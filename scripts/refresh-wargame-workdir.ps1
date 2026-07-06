# refresh-wargame-workdir.ps1 — (re)build the war-game seat's grounding context.
#
# The loom shim's role workdir (<serve-root>/wargame-workdir) is bind-mounted
# READ-ONLY as /work into every sonnet#wargame session. NTFS junctions do NOT
# traverse Docker Desktop's file share (names list, contents 404 — verified
# 2026-07-05), so this is a SNAPSHOT copy: run it before a war-game round if
# the plans have moved. Staleness is visible in the artifact's assumptions
# ledger, so a stale snapshot degrades honestly.
#
# CURATION IS THE WALL: only workspace planning surfaces + the two public
# repos. Never private/, journal/, becoming/, gospel-library — the war-game
# artifact pools into the shared substrate corpus, so nothing enters /work
# that could not appear in a pooled doc.
param(
    [string]$Workspace = "C:\path\to\workspace",
    [string]$Dest      = "$env:USERPROFILE\.stewards\wargame-workdir"
)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force $Dest | Out-Null

$sets = @(
    @{ src = "$Workspace\.spec";                        dst = "$Dest\spec" },
    @{ src = "$Workspace\.mind";                        dst = "$Dest\mind" },
    @{ src = "$Workspace\docs";                         dst = "$Dest\docs" },
    @{ src = "$Workspace\projects\pg-ai-stewards-oss";  dst = "$Dest\pg-ai-stewards-oss" },
    @{ src = "$Workspace\projects\loom";                dst = "$Dest\loom" }
)
# /MIR keeps the snapshot honest (deletions propagate); exclusions keep it small
# and keep secrets/build-junk out.
$xd = @("target", "node_modules", "dist", ".git", "external_context", "harness-scratch")
$xf = @("*.exe", "*.dll", "*.so", "*.gguf", ".env", "*.credentials.json", "*token*")

foreach ($s in $sets) {
    if (-not (Test-Path $s.src)) { Write-Warning "missing: $($s.src)"; continue }
    robocopy $s.src $s.dst /MIR /NFL /NDL /NJH /NJS /NP `
        /XD @($xd | ForEach-Object { Join-Path $s.src $_ }) $xd `
        /XF $xf | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE) for $($s.src)" }
}
"refreshed $Dest — " + ((Get-ChildItem $Dest | Measure-Object).Count) + " roots, " +
    ("{0:N0} files" -f (Get-ChildItem $Dest -Recurse -File | Measure-Object).Count)
exit 0  # robocopy success codes (1-7) otherwise leak as the script's exit code
