param([string]$Destination = "$env:LOCALAPPDATA\NeLispIME")
$ErrorActionPreference = "Stop"
$Dll = Join-Path $Destination "bin\nelisp-ime-tsf.dll"
if (Test-Path $Dll) { & "$env:SystemRoot\System32\regsvr32.exe" /s /u $Dll }
if (Test-Path $Destination) { Remove-Item -Recurse -Force $Destination }
Write-Host "Uninstalled NeLisp IME"
