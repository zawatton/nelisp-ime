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
if (-not $NoRegister) {
    & "$env:SystemRoot\System32\regsvr32.exe" /s "$Bin\nelisp-ime-tsf.dll"
    if ($LASTEXITCODE -ne 0) { throw "regsvr32 failed: $LASTEXITCODE" }
}
Write-Host "Installed NeLisp IME to $Destination"
