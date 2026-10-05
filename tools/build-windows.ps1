<#
.SYNOPSIS
  Build the MSU-1 test core on Windows and package release\defgenx.SNESMSU.zip.

.DESCRIPTION
  Compiles the NTSC, PAL and SPC7110/S-DD1/BSX bitstreams with a native Quartus Prime Lite
  (21.1 is what the repo targets), then packages them the same way tools/package-msu.sh does:
  Cores\defgenx.SNESMSU renamed from pkg\pocket, Platforms\, and the double-click installers.

  Easiest: double-click tools\build-windows.bat. Or in PowerShell, from the repo:
    .\tools\build-windows.ps1                     # all three bitstreams, then the zip
    .\tools\build-windows.ps1 -Variants ntsc      # only NTSC; the others are left out of the zip
    .\tools\build-windows.ps1 -PackageOnly        # re-package the last build\msu-test\*.rbf
    .\tools\build-windows.ps1 -Install            # also run the installer afterwards
    .\tools\build-windows.ps1 -Release            # build without the MSU-1 debug overlay
    .\tools\build-windows.ps1 -Quartus C:\intelFPGA_lite\21.1\quartus\bin64
#>
[CmdletBinding()]
param(
    [ValidateSet("ntsc", "pal", "ntsc_spc")]
    [string[]]$Variants = @("ntsc", "pal", "ntsc_spc"),
    [string]$Quartus = "",
    [switch]$PackageOnly,
    [switch]$Release,
    [switch]$Install
)

$ErrorActionPreference = "Stop"
$Author = "defgenx"
$ShortName = "SNESMSU"
$CoreDir = "$Author.$ShortName"
$Repo = Split-Path -Parent $PSScriptRoot
$Work = Join-Path $Repo "build/msu-test"
$Pkg = Join-Path $Repo "build/msu-package"
$Zip = Join-Path $Repo "release/$CoreDir.zip"
$RevName = @{ "ntsc" = "snes_main.rev"; "pal" = "snes_pal.rev"; "ntsc_spc" = "snes_spc.rev" }

function Fail([string]$msg) { Write-Host "error: $msg" -ForegroundColor Red; exit 1 }

New-Item -ItemType Directory -Force -Path $Work | Out-Null

# ---------------------------------------------------------------------------
# 1. Compile
# ---------------------------------------------------------------------------

if (-not $PackageOnly) {
    if (-not $Quartus) {
        $cmd = Get-Command quartus_sh -ErrorAction SilentlyContinue
        if ($cmd) { $Quartus = Split-Path -Parent $cmd.Source }
        else {
            # newest install under the default folders
            $found = Get-ChildItem -Path "C:\intelFPGA_lite", "C:\intelFPGA", "C:\altera_lite" -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { Join-Path $_.FullName "quartus\bin64" } | Where-Object { Test-Path (Join-Path $_ "quartus_sh.exe") } |
                Sort-Object -Descending | Select-Object -First 1
            if ($found) { $Quartus = $found }
        }
    }
    $sh = Join-Path $Quartus "quartus_sh.exe"
    if (-not (Test-Path -LiteralPath $sh)) { Fail "quartus_sh.exe not found; install Quartus Prime Lite 21.1 or pass -Quartus <...\quartus\bin64>" }
    Write-Host "Using $sh"

    Push-Location $Repo
    try {
        foreach ($v in $Variants) {
            $log = Join-Path $Work "build_$v.log"
            Write-Host "Building $v (log: $log)..."
            $t = Get-Date
            if ($Release) { & $sh -t generate.tcl $v release *> $log } else { & $sh -t generate.tcl $v *> $log }
            if ($LASTEXITCODE -ne 0) { Get-Content $log -Tail 30; Fail "$v build failed, see $log" }
            $summary = Join-Path $Repo "projects/output_files/snes_pocket.fit.summary"
            Select-String -Path $summary -Pattern "Logic utilization" | ForEach-Object { Write-Host "  $($_.Line.Trim())" }
            Copy-Item -LiteralPath (Join-Path $Repo "projects/output_files/snes_pocket.rbf") -Destination (Join-Path $Work "$v.rbf") -Force
            Write-Host ("  done in {0:N0} min" -f ((Get-Date) - $t).TotalMinutes)
        }
    } finally { Pop-Location }
}

# ---------------------------------------------------------------------------
# 2. Package
# ---------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath (Join-Path $Work "ntsc.rbf"))) { Fail "no build/msu-test/ntsc.rbf; build the ntsc variant first" }

if (Test-Path -LiteralPath $Pkg) { Remove-Item -LiteralPath $Pkg -Recurse -Force }
$stage = Join-Path $Pkg "Cores/$CoreDir"
New-Item -ItemType Directory -Force -Path $stage, (Join-Path $Pkg "Platforms/_images") | Out-Null
Copy-Item -Path (Join-Path $Repo "pkg/pocket/Cores/agg23.SNES/*") -Destination $stage
Copy-Item -LiteralPath (Join-Path $Repo "pkg/pocket/Platforms/snes.json") -Destination (Join-Path $Pkg "Platforms")
Copy-Item -LiteralPath (Join-Path $Repo "pkg/pocket/Platforms/_images/snes.bin") -Destination (Join-Path $Pkg "Platforms/_images")

$utf8 = New-Object System.Text.UTF8Encoding $false
$rev = "local"
try { $rev = (& git -C $Repo rev-parse --short HEAD).Trim() } catch {}

# The folder name must match author.shortname, or the Pocket ignores the core
$coreJson = Join-Path $stage "core.json"
$core = Get-Content -Raw -LiteralPath $coreJson | ConvertFrom-Json
$meta = $core.core.metadata
$meta.author = $Author
$meta.shortname = $ShortName
$meta.description = "SNES with MSU-1 (test build $rev)"
$meta.url = "https://github.com/defgenx/openfpga-SNES/tree/feature/msu1"
$meta.version = "$($meta.version)-msu1"
$meta.date_release = (Get-Date).ToString("yyyy-MM-dd")
[IO.File]::WriteAllText($coreJson, ($core | ConvertTo-Json -Depth 20), $utf8)

$infoTxt = Join-Path $stage "info.txt"
$info = [IO.File]::ReadAllText($infoTxt) -replace "^Port by agg23\.", "MSU-1 test build of the agg23 port."
[IO.File]::WriteAllText($infoTxt, $info, $utf8)

# APF wants the rbf with the bit order of every byte reversed
$table = New-Object byte[] 256
for ($b = 0; $b -lt 256; $b++) {
    $r = 0
    for ($i = 0; $i -lt 8; $i++) { if ($b -band (1 -shl $i)) { $r = $r -bor (1 -shl (7 - $i)) } }
    $table[$b] = [byte]$r
}
foreach ($v in "ntsc", "pal", "ntsc_spc") {
    $rbf = Join-Path $Work "$v.rbf"
    if (Test-Path -LiteralPath $rbf) {
        $data = [IO.File]::ReadAllBytes($rbf)
        for ($i = 0; $i -lt $data.Length; $i++) { $data[$i] = $table[$data[$i]] }
        [IO.File]::WriteAllBytes((Join-Path $stage $RevName[$v]), $data)
        Write-Host "$($RevName[$v]): $rbf"
    } else {
        Write-Host "$($RevName[$v]): not packaged, the installer copies it from Cores\agg23.SNES on the card"
    }
}

$installer = Join-Path $Repo "tools/installer"
foreach ($f in "install.sh", "install.ps1", "install-linux.desktop", "MSU1-INSTALL.md") {
    Copy-Item -LiteralPath (Join-Path $installer $f) -Destination $Pkg
}
# Windows batch files need CRLF line endings
$bat = [IO.File]::ReadAllText((Join-Path $installer "install.bat")) -replace "`r?`n", "`r`n"
[IO.File]::WriteAllText((Join-Path $Pkg "install.bat"), $bat, $utf8)

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Zip) | Out-Null
if (Test-Path -LiteralPath $Zip) { Remove-Item -LiteralPath $Zip -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($Pkg, $Zip)
Write-Host "Packaged $Zip"

if ($Install) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Pkg "install.ps1")
}
