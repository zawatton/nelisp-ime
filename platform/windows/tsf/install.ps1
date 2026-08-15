param(
    [string]$BuildDirectory = "$PSScriptRoot\build",
    [string]$Destination = "$env:LOCALAPPDATA\NeLispIME",
    [switch]$NoRegister
)
$ErrorActionPreference = "Stop"
$Repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
$Runtime = Join-Path $Repo "target\nelisp.exe"
$Dll = @((Join-Path $BuildDirectory "Release\nelisp-ime-tsf.dll"),
         (Join-Path $BuildDirectory "nelisp-ime-tsf.dll")) |
       Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not (Test-Path $Runtime)) { throw "Build target\nelisp.exe first" }
if (-not $Dll) { throw "Build nelisp-ime-tsf.dll first" }
$Bin = Join-Path $Destination "bin"
$Root = Join-Path $Destination "nelisp-root"
New-Item -ItemType Directory -Force -Path $Bin | Out-Null
New-Item -ItemType Directory -Force -Path "$Root\packages\nelisp-json\src" | Out-Null
New-Item -ItemType Directory -Force -Path "$Root\packages\nelisp-ime\src" | Out-Null
New-Item -ItemType Directory -Force -Path "$Root\packages\nelisp-ime\data" | Out-Null
Copy-Item $Runtime "$Bin\nelisp.exe" -Force
Copy-Item $Dll "$Bin\nelisp-ime-tsf.dll" -Force
Copy-Item "$Repo\packages\nelisp-json\src\nelisp-json.el" "$Root\packages\nelisp-json\src" -Force
Copy-Item "$Repo\packages\nelisp-ime\src\*.el" "$Root\packages\nelisp-ime\src" -Force
Copy-Item "$Repo\packages\nelisp-ime\data\nelisp-ime-dictionary-data.el" "$Root\packages\nelisp-ime\data" -Force
# Precompile every staged .el to an adjacent .nelc so the resident engine's
# bootstrap loads the compiled artifact instead of re-reading source.  Without
# this the first TSF Activate blocks for minutes on the bare source reader.
Get-ChildItem $Root -Recurse -Filter *.el | ForEach-Object {
    & "$Bin\nelisp.exe" compile-elisp-artifact --kind nelc `
        --input $_.FullName --output "$($_.FullName).nelc"
    if ($LASTEXITCODE -ne 0) { throw "nelc precompile failed: $($_.FullName)" }
}
if (-not $NoRegister) {
    # regsvr32 is a GUI-subsystem binary: `&` does not wait for it and leaves
    # $LASTEXITCODE stale, so run it synchronously and read the real exit code.
    # TSF profile/category registration writes under HKLM\SOFTWARE\Microsoft\CTF,
    # which needs elevation even though the COM class itself is per-user (HKCU),
    # so re-launch elevated when this shell is not already an administrator.
    $regsvr = "$env:SystemRoot\System32\regsvr32.exe"
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $elevated = (New-Object Security.Principal.WindowsPrincipal($identity)).
        IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $spawn = @{ FilePath = $regsvr
                ArgumentList = @('/s', "$Bin\nelisp-ime-tsf.dll")
                Wait = $true; PassThru = $true }
    if (-not $elevated) { $spawn.Verb = 'RunAs' }
    $process = Start-Process @spawn
    if ($process.ExitCode -ne 0) { throw "regsvr32 failed: $($process.ExitCode)" }
}
Write-Host "Installed NeLisp IME to $Destination"
