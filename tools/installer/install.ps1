<#
.SYNOPSIS
  Install the SNES MSU-1 test core (defgenx.SNESMSU) onto an Analogue Pocket microSD card.

.DESCRIPTION
  Installs next to agg23.SNES, which is never modified. Finds the Pocket SD card, then
  copies Cores\defgenx.SNESMSU and Platforms\. Files already on the card are never replaced
  silently: identical ones are skipped, and for each one that differs you are asked
  (default: keep the card's file). Without an interactive console (or with -DryRun)
  nothing on the card is ever replaced. Without a package next to the script, the newest
  release is downloaded from GitHub.

  Easiest: double-click install.bat. Or in PowerShell:
    .\install.ps1
    .\install.ps1 -SD E:\
    .\install.ps1 -DryRun
    .\install.ps1 -Tag msu1-test-10   # download that release (outside a release zip only)
#>
[CmdletBinding()]
param(
    [string]$SD = "",
    [string]$Tag = "",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$Repo = "defgenx/openfpga-SNES"
$Core = "defgenx.SNESMSU"
$UpstreamCore = "agg23.SNES"
$Here = $PSScriptRoot

function Fail([string]$msg) { Write-Host "error: $msg" -ForegroundColor Red; exit 1 }

# Ask PROMPT DEFAULT: without an interactive console the default is used
$Interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
function Ask([string]$prompt, [string]$default) {
    if (-not $Interactive) { return $default }
    $a = Read-Host $prompt
    if ([string]::IsNullOrWhiteSpace($a)) { return $default }
    return $a
}

$Tmp = $null
try {
    # -----------------------------------------------------------------------
    # 1. Files to install: Cores\ next to this script (release zip), else the latest release
    # -----------------------------------------------------------------------

    if (Test-Path -LiteralPath (Join-Path $Here "Cores/$Core/snes_main.rev")) {
        $Src = $Here
        Write-Host "Using the core from $Src"
    } else {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $Tmp = Join-Path ([IO.Path]::GetTempPath()) ("snesmsu-" + [Guid]::NewGuid())
        New-Item -ItemType Directory -Path $Tmp | Out-Null
        $url = $null
        if ($Tag) {
            $url = "https://github.com/$Repo/releases/download/$Tag/$Core.zip"
        } else {
            # The API lists releases by tag name (msu1-test-9 before msu1-test-10): take the most
            # recently published one that carries the zip, pre-releases included
            $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases?per_page=100" -Headers @{ "User-Agent" = "snesmsu-installer" }
            foreach ($r in ($releases | Sort-Object { [DateTime]$_.published_at } -Descending)) {
                $asset = $r.assets | Where-Object { $_.name -eq "$Core.zip" } | Select-Object -First 1
                if ($asset) { $url = $asset.browser_download_url; break }
            }
        }
        if (-not $url) { Fail "could not find a release of $Repo with $Core.zip" }
        Write-Host "Downloading $url"
        $zip = Join-Path $Tmp "core.zip"
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
        Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $Tmp "core")
        $Src = Join-Path $Tmp "core"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Src "Cores/$Core/snes_main.rev"))) { Fail "no core bitstream found in $Src" }

    # -----------------------------------------------------------------------
    # 2. Find the SD card
    # -----------------------------------------------------------------------

    function Test-PocketCard([string]$root) {
        foreach ($d in "Cores", "Platforms", "Assets", "System") {
            if (Test-Path -LiteralPath (Join-Path $root $d) -PathType Container) { return $true }
        }
        return $false
    }

    if (-not $SD) {
        $candidates = @()
        if ($IsLinux -or $IsMacOS) {
            foreach ($base in "/media/$env:USER", "/run/media/$env:USER", "/media", "/mnt", "/Volumes") {
                if (Test-Path $base) { $candidates += Get-ChildItem -LiteralPath $base -Directory | ForEach-Object FullName }
            }
        } else {
            # removable drives first, then any other drive that already looks like a Pocket card
            $drives = Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DriveType -in 2, 3 } |
                Sort-Object @{ Expression = { $_.DriveType -ne 2 } }, DeviceID
            foreach ($d in $drives) {
                $root = "$($d.DeviceID)\"
                if ($d.DeviceID -eq $env:SystemDrive) { continue }
                if ($d.DriveType -eq 2 -or (Test-PocketCard $root)) { $candidates += $root }
            }
        }
        $pocket = @($candidates | Where-Object { Test-PocketCard $_ })

        if ($pocket.Count -eq 1) {
            $SD = $pocket[0]
            Write-Host "Found Pocket SD card: $SD"
            if ((Ask "Install there? [Y/n]" "y") -match "^[nN]") { Fail "aborted" }
        } else {
            $list = if ($pocket.Count -gt 0) { $pocket } else { @($candidates) }
            if ($list.Count -eq 0) { Fail "no SD card found - insert it, or run with -SD E:\" }
            if ($pocket.Count -eq 0) { Write-Host "No card with Pocket folders found; drives:" }
            else { Write-Host "Several Pocket cards found:" }
            for ($i = 0; $i -lt $list.Count; $i++) { Write-Host ("  {0}) {1}" -f ($i + 1), $list[$i]) }
            if (-not $Interactive) { Fail "several drives found - run with -SD E:\" }
            $n = Ask "Number of the SD card to install to" ""
            if (-not ($n -match "^\d+$") -or [int]$n -lt 1 -or [int]$n -gt $list.Count) { Fail "invalid choice" }
            $SD = $list[[int]$n - 1]
        }
    }

    if (-not (Test-Path -LiteralPath $SD -PathType Container)) { Fail "$SD is not a drive or folder" }
    if (-not (Test-PocketCard $SD)) { Write-Host "Note: $SD has no Cores/Platforms/Assets folders yet; they will be created." }

    # -----------------------------------------------------------------------
    # 3. Copy, never replacing anything silently. Only Cores\$Core and Platforms\ are written.
    # -----------------------------------------------------------------------

    $script:copied = 0; $script:replaced = 0; $script:same = 0
    $script:kept = New-Object System.Collections.Generic.List[string]
    $script:policy = ""   # "all" = replace every differing file, "none" = keep every one

    function Install-File([string]$from, [string]$rel) {
        $rel = $rel -replace '\\', '/'
        if ($rel.StartsWith("Cores/$UpstreamCore/")) { Fail "refusing to write $rel" }
        $dst = Join-Path $SD $rel
        $verb = "copied  "
        if (Test-Path -LiteralPath $dst) {
            if ((Get-FileHash -LiteralPath $from).Hash -eq (Get-FileHash -LiteralPath $dst).Hash) { $script:same++; return }
            if ($DryRun -or -not $Interactive -or $script:policy -eq "none") { $script:kept.Add($rel); return }
            if ($script:policy -ne "all") {
                $a = Ask "$rel already exists and differs. Replace it? [y]es/[N]o/[a]ll/[s]kip all" "n"
                if ($a -match "^[aA]") { $script:policy = "all" }
                elseif ($a -match "^[sS]") { $script:policy = "none"; $script:kept.Add($rel); return }
                elseif ($a -notmatch "^[yY]") { $script:kept.Add($rel); return }
            }
            $verb = "replaced"
        }
        if ($DryRun) {
            Write-Host "would copy  $rel"
        } else {
            $dir = Split-Path -Parent $dst
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            Copy-Item -LiteralPath $from -Destination $dst -Force
            Write-Host "$verb    $rel"
        }
        if ($verb -eq "replaced") { $script:replaced++ } else { $script:copied++ }
    }

    $srcFull = (Resolve-Path -LiteralPath $Src).Path.TrimEnd('\', '/')
    $files = @(foreach ($top in "Cores", "Platforms") {
            $p = Join-Path $srcFull $top
            if (Test-Path -LiteralPath $p) { Get-ChildItem -LiteralPath $p -Recurse -File -Force }
        }) | Where-Object { $_.Name -notin ".DS_Store", ".keep" -and -not $_.Name.StartsWith("._") } |
        Sort-Object FullName
    foreach ($f in $files) { Install-File $f.FullName $f.FullName.Substring($srcFull.Length + 1) }

    # Bitstreams the zip does not carry (PAL, SPC7110/S-DD1/BSX) come from agg23.SNES on the card
    foreach ($rev in "snes_pal.rev", "snes_spc.rev") {
        if (-not (Test-Path -LiteralPath (Join-Path $Src "Cores/$Core/$rev"))) {
            $fromCard = Join-Path $SD "Cores/$UpstreamCore/$rev"
            if (Test-Path -LiteralPath $fromCard) { Install-File $fromCard "Cores/$Core/$rev" }
            else { Write-Host "warning: no $rev in this package or in Cores/$UpstreamCore; those games will not boot in $Core" }
        }
    }

    # ROMs and MSU-1 packs go here, shared with agg23.SNES
    if (-not $DryRun) { New-Item -ItemType Directory -Path (Join-Path $SD "Assets/snes/common") -Force | Out-Null }

    Write-Host ""
    if ($DryRun) { Write-Host "Dry run: $script:copied file(s) would be copied to $SD" }
    else { Write-Host "Copied $script:copied new file(s), replaced $script:replaced, $script:same already up to date on $SD" }
    if ($script:kept.Count -gt 0) {
        Write-Host "Kept the card's version (differs from this package): $($script:kept.Count)"
        foreach ($s in $script:kept) { Write-Host "  - $s" }
        if (-not $Interactive -and -not $DryRun) { Write-Host "Run the script in a console to be asked about replacing them." }
    }
    if ($DryRun) { exit 0 }

    # -----------------------------------------------------------------------
    # 4. Eject
    # -----------------------------------------------------------------------

    $doneMsg = "Put the card in the Pocket: Cores > SNES > pick the 'defgenx' core."
    $ej = Ask "Eject the SD card now? [Y/n]" $(if ($Interactive) { "y" } else { "n" })
    if ($ej -match "^[nN]") {
        Write-Host "Remember to eject the card before removing it. $doneMsg"
    } elseif ($IsLinux -or $IsMacOS) {
        Write-Host "Eject the card from your system before removing it. $doneMsg"
    } else {
        $letter = (Split-Path -Qualifier $SD)
        try {
            (New-Object -ComObject Shell.Application).Namespace(17).ParseName("$letter\").InvokeVerb("Eject")
            Write-Host "Ejected. $doneMsg"
        } catch {
            Write-Host "Could not eject automatically; use 'Safely Remove Hardware' before removing the card."
        }
    }
} finally {
    if ($Tmp -and (Test-Path -LiteralPath $Tmp)) { Remove-Item -LiteralPath $Tmp -Recurse -Force }
}
