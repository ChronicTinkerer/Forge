# release.ps1 -- one-command release helper for the Forge addon family.
#
# Usage (from the Forge folder, in a PowerShell terminal):
#   .\release.ps1 "feat: Forge_AddonManager toolbar overflow fix"
#   .\release.ps1 "fix: ..." -DryRun     # preview, no files touched, no git
#   .\release.ps1 "fix: ..." -NoPush     # bump + commit + tag locally only
#
# What it does:
#   1. Compute a YYMMDDHHMM stamp from the current local clock.
#   2. Rewrite "## Version:" in ALL 10 .toc files (parent + 9 sub-addons).
#      Every addon ships from the same zip, so they get the same stamp.
#   3. git add -A
#   4. git commit -m <message>
#   5. git tag -a <stamp> -m <stamp>     (annotated -- never lightweight)
#   6. git push origin HEAD
#   7. git push origin <stamp>
#   8. Print the GitHub Actions URL.
#
# How the published zip is shaped (see .pkgmeta):
#   The packager moves each Forge/Forge_*/ folder out of Forge/ so the zip
#   contains 10 sibling addon folders. Users extract once into AddOns/ and
#   get the parent + all 9 sub-tools as independent installable addons.
#
# If PowerShell blocks the script with an execution policy error:
#     Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Message,

    [switch]$DryRun,

    [switch]$NoPush
)

$ErrorActionPreference = 'Stop'

# ---------- Configuration ------------------------------------------------

$AddonName       = 'Forge'
$RepoOwner       = 'ChronicTinkerer'

# Versioning convention (changed 2026-05-05): sequential integer build
# numbers, +1 per release. Reads the current value from $PrimaryVersionFile
# and writes (N+1) to every TOC in $FilesToBump. If the primary's value is 0
# or missing, the counter starts at 1.
# Rationale: time-stamped versions go non-monotonic when builds happen
# from machines on different timezones (or when a sandbox runs UTC vs
# Eastern). Sequential is always strictly increasing.
# All 10 Forge TOCs share one stamp because they all ship from the same
# zip; users see one coordinated release across the whole family.
$PrimaryVersionFile = 'Forge.toc'

# All 10 toc files get the same stamp on every release. Order is parent
# first, sub-addons alphabetical -- doesn't matter functionally; just for
# readable dry-run output.
$FilesToBump = @(
    @{ Path = 'Forge.toc';                                 Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge (parent) Version' },
    @{ Path = 'Forge_AddonManager\Forge_AddonManager.toc'; Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_AddonManager Version' },
    @{ Path = 'Forge_BugCatcher\Forge_BugCatcher.toc';     Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_BugCatcher Version' },
    @{ Path = 'Forge_Codex\Forge_Codex.toc';               Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_Codex Version' },
    @{ Path = 'Forge_Console\Forge_Console.toc';           Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_Console Version' },
    @{ Path = 'Forge_Inspector\Forge_Inspector.toc';       Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_Inspector Version' },
    @{ Path = 'Forge_Logs\Forge_Logs.toc';                 Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_Logs Version' },
    @{ Path = 'Forge_Macros\Forge_Macros.toc';             Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_Macros Version' },
    @{ Path = 'Forge_Profiles\Forge_Profiles.toc';         Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_Profiles Version' },
    @{ Path = 'Forge_Registry\Forge_Registry.toc';         Pattern = '(?m)^(## Version:\s*)\d+'; Description = 'Forge_Registry Version' }
)

# --------------------------------------------------------------------------

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]]$Args)
    & git @Args
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Args -join ' ') failed (exit $LASTEXITCODE)"
    }
}

# This script lives at .dev/release.ps1; the repo root is one level up.
# Anchor there so $FilesToBump's relative paths (Forge.toc, Forge_*/*.toc)
# resolve correctly no matter where the user invoked this from.
$RepoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $RepoRoot
try {
    # Read the current version from the primary TOC and increment by 1.
    if (-not (Test-Path $PrimaryVersionFile)) {
        throw "Primary version file not found: $PrimaryVersionFile"
    }
    $primaryContent = Get-Content $PrimaryVersionFile -Raw
    if ($primaryContent -match '(?m)^## Version:\s*(\d+)') {
        $currentVersion = [long]$matches[1]
    } else {
        $currentVersion = 0
    }
    $stamp = ($currentVersion + 1).ToString()

    Write-Host ''
    Write-Host "Release $AddonName -> $stamp" -ForegroundColor Cyan
    Write-Host "Commit message: $Message"     -ForegroundColor Cyan
    Write-Host ''

    foreach ($entry in $FilesToBump) {
        if (-not (Test-Path $entry.Path)) {
            throw "Missing file: $($entry.Path)"
        }
        $content = Get-Content $entry.Path -Raw
        $matches = [regex]::Matches($content, $entry.Pattern)
        if ($matches.Count -eq 0) {
            throw "Pattern not found in $($entry.Path): $($entry.Pattern)"
        }
        if ($matches.Count -gt 1) {
            throw "Pattern matched $($matches.Count) places in $($entry.Path); expected exactly 1."
        }
        $oldLine = $matches[0].Value
        $newLine = $matches[0].Groups[1].Value + $stamp
        Write-Host "  $($entry.Description) [$($entry.Path)]"
        Write-Host "    before: $oldLine"
        Write-Host "    after:  $newLine"
    }
    Write-Host ''

    if ($DryRun) {
        Write-Host 'DRY RUN. No files modified, no git actions.' -ForegroundColor Yellow
        return
    }

    foreach ($entry in $FilesToBump) {
        $content = Get-Content $entry.Path -Raw
        $updated = [regex]::Replace($content, $entry.Pattern, '${1}' + $stamp)
        Set-Content -Path $entry.Path -Value $updated -NoNewline
    }
    Write-Host 'Files updated.' -ForegroundColor Green
    Write-Host ''

    Invoke-Git @('add', '-A')
    Invoke-Git @('commit', '-m', $Message)
    Invoke-Git @('tag', '-a', $stamp, '-m', $stamp)

    if ($NoPush) {
        Write-Host ''
        Write-Host "Tag $stamp created locally. -NoPush set; not pushing." -ForegroundColor Yellow
        Write-Host "When ready:" -ForegroundColor Yellow
        Write-Host "  git push origin HEAD"        -ForegroundColor Yellow
        Write-Host "  git push origin $stamp"      -ForegroundColor Yellow
        return
    }

    Invoke-Git @('push', 'origin', 'HEAD')
    Invoke-Git @('push', 'origin', $stamp)

    Write-Host ''
    Write-Host "Released $stamp" -ForegroundColor Green
    Write-Host "Watch the run: https://github.com/$RepoOwner/$AddonName/actions" -ForegroundColor Green
}
finally {
    Pop-Location
}
