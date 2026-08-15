param([string]$Destination = "$env:LOCALAPPDATA\NeLispIME")
$ErrorActionPreference = "Stop"
$Dll = Join-Path $Destination "bin\nelisp-ime-tsf.dll"
if (Test-Path $Dll) {
    # Match install.ps1: regsvr32 is GUI-subsystem (must be waited on
    # explicitly) and TSF profile unregistration writes under HKLM, so
    # elevate when this shell is not already an administrator.
    $regsvr = "$env:SystemRoot\System32\regsvr32.exe"
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $elevated = (New-Object Security.Principal.WindowsPrincipal($identity)).
        IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $spawn = @{ FilePath = $regsvr
                ArgumentList = @('/s', '/u', $Dll)
                Wait = $true; PassThru = $true }
    if (-not $elevated) { $spawn.Verb = 'RunAs' }
    $process = Start-Process @spawn
    if ($process.ExitCode -ne 0) { throw "regsvr32 /u failed: $($process.ExitCode)" }
}
if (Test-Path $Destination) { Remove-Item -Recurse -Force $Destination }
Write-Host "Uninstalled NeLisp IME"
