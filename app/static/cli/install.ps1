# Install the InFocus Drive CLI (infocus.exe) for the current Windows user.
#   irm <drive>/cli/install.ps1 | iex
# No admin rights needed: it goes to %LOCALAPPDATA%\Programs\infocus and onto
# your user PATH. Run it again to update. Optional: $env:INFOCUS_VERSION to pin.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue' # much faster downloads in Windows PowerShell

$Server = '__INFOCUS_SERVER__'
$Repo = 'neelsatyavolu/infocus-drive'
$Arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
$Asset = "infocus-windows-$Arch.zip"
if ($env:INFOCUS_DOWNLOAD_BASE) {
  $Base = $env:INFOCUS_DOWNLOAD_BASE # local testing only: checksums come from the same place
} elseif ($env:INFOCUS_VERSION) {
  $Base = "https://github.com/$Repo/releases/download/cli-v$($env:INFOCUS_VERSION)"
} else {
  $Base = "https://github.com/$Repo/releases/latest/download"
}
$Dir = Join-Path $env:LOCALAPPDATA 'Programs\infocus'
$Tmp = Join-Path ([IO.Path]::GetTempPath()) ("infocus-" + [Guid]::NewGuid())
New-Item -ItemType Directory -Path $Tmp | Out-Null

try {
  Write-Host 'Downloading infocus...'
  Invoke-WebRequest -UseBasicParsing "$Base/$Asset" -OutFile (Join-Path $Tmp $Asset)
  Invoke-WebRequest -UseBasicParsing "$Base/SHA256SUMS" -OutFile (Join-Path $Tmp 'SHA256SUMS')
  $line = Get-Content (Join-Path $Tmp 'SHA256SUMS') |
    Where-Object { ($_ -split '\s+')[-1].TrimStart('*') -eq $Asset } | Select-Object -First 1
  if (-not $line) { throw "SHA256SUMS has no entry for $Asset" }
  $want = ($line -split '\s+')[0].ToLower()
  $got = (Get-FileHash (Join-Path $Tmp $Asset) -Algorithm SHA256).Hash.ToLower()
  if ($got -ne $want) { throw 'checksum mismatch - refusing to install' }

  Expand-Archive (Join-Path $Tmp $Asset) -DestinationPath (Join-Path $Tmp 'x') -Force
  $new = Join-Path $Tmp 'x\infocus.exe'
  if (-not (Test-Path $new)) { throw 'the download has no infocus.exe' }

  New-Item -ItemType Directory -Force -Path $Dir | Out-Null
  $exe = Join-Path $Dir 'infocus.exe'
  # A running infocus.exe can be renamed but not overwritten.
  if (Test-Path $exe) {
    Remove-Item "$exe.old" -Force -ErrorAction SilentlyContinue
    Move-Item $exe "$exe.old" -Force
  }
  Copy-Item $new $exe -Force
  Remove-Item "$exe.old" -Force -ErrorAction SilentlyContinue

  # Point the CLI at this Drive unless it's already configured.
  $cfgDir = Join-Path $env:APPDATA 'infocus'
  $cfg = Join-Path $cfgDir 'config.json'
  if (-not (Test-Path $cfg)) {
    New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
    # WriteAllText: UTF-8 without a BOM (Set-Content adds one in Windows PowerShell).
    [IO.File]::WriteAllText($cfg, "{`n  `"server`": `"$Server`"`n}`n")
  }

  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if (-not (($userPath -split ';') -contains $Dir)) {
    $newPath = if ($userPath) { $userPath.TrimEnd(';') + ";$Dir" } else { $Dir }
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Host "Added $Dir to your PATH (open a new terminal to pick it up)."
  }
  $env:Path = "$env:Path;$Dir"

  & $exe version
  Write-Host "`nInstalled. Next: run  infocus login"
}
finally {
  Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
}
