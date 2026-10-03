# Build the sibling NeLisp runtime for the IME reader path without touching its source tree.
[CmdletBinding()]
param(
    [string]$Emacs = $env:EMACS,
    [string]$RuntimeRoot = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'nelisp'),
    [string]$OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'target/ime-runtime-build')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Emacs)) {
    $Emacs = 'emacs'
}
$emacsCommand = Get-Command $Emacs -ErrorAction Stop
$Emacs = $emacsCommand.Source
$RuntimeRoot = [IO.Path]::GetFullPath($RuntimeRoot)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
foreach ($required in @('scripts/nelisp-standalone-build.el', 'lisp', 'src')) {
    if (-not (Test-Path -LiteralPath (Join-Path $RuntimeRoot $required))) {
        throw "Runtime root is missing ${required}: $RuntimeRoot"
    }
}
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

$exe = Join-Path $OutputDirectory 'nelisp.exe'
$cacheRoot = Join-Path $OutputDirectory 'unit-cache'
$artifactRuntimeSource = Join-Path $OutputDirectory 'nelisp-artifact-runtime.el'
$artifactRuntimeCache = "$artifactRuntimeSource.nelc"
$artifactRuntimeCacheEnable = "$artifactRuntimeCache.enable"
$buildLog = Join-Path $OutputDirectory 'build.log'
$embeddedLog = Join-Path $OutputDirectory 'embedded.log'
$dynamicLog = Join-Path $OutputDirectory 'dynamic-eval.log'
$reportPath = Join-Path $OutputDirectory 'report.json'
$hostHashBefore = (Get-FileHash -LiteralPath $Emacs -Algorithm SHA256).Hash
$runtimeRevisionOutput = & git -c 'safe.directory=*' -C $RuntimeRoot rev-parse HEAD 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Could not read runtime Git revision: $runtimeRevisionOutput"
}
$runtimeRevision = ([string]$runtimeRevisionOutput).Trim()

function Get-RuntimeElcSnapshot {
    param([string]$Root)
    $snapshot = @{}
    foreach ($directory in @('lisp', 'src', 'scripts')) {
        $base = Join-Path $Root $directory
        if (Test-Path -LiteralPath $base) {
            foreach ($file in (Get-ChildItem -LiteralPath $base -File -Filter '*.elc' -Recurse)) {
                $relative = $file.FullName.Substring($Root.Length).TrimStart([char]92, [char]47)
                $snapshot[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
            }
        }
    }
    return ,$snapshot
}

$elcBefore = Get-RuntimeElcSnapshot $RuntimeRoot
$savedEnvironment = @{}
foreach ($name in @('NELISP_STANDALONE_TARGET', 'NELISP_STANDALONE_READER_OUTPUT', 'NELISP_SRC')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$report = [ordered]@{
    success = $false
    runtimeRoot = $RuntimeRoot
    runtimeRevision = $runtimeRevision
    emacs = $Emacs
    outputDirectory = $OutputDirectory
    executable = $exe
    buildExit = $null
    buildElapsedMs = $null
    embeddedExit = $null
    embeddedElapsedMs = $null
    dynamicEvalExit = $null
    dynamicEvalElapsedMs = $null
    dynamicEvalOutput = $null
    emacsSha256Before = $hostHashBefore
    emacsSha256After = $null
    readerSha256 = $null
    artifactRuntimeSourceSha256 = $null
    artifactRuntimeCacheSha256 = $null
    elcCountBefore = $elcBefore.Count
    elcCountAfter = $null
    elcHashesUnchanged = $null
    error = $null
}
$failure = $null

try {
    $env:NELISP_STANDALONE_TARGET = 'windows-x86_64'
    $env:NELISP_STANDALONE_READER_OUTPUT = $exe
    $env:NELISP_SRC = '(+ 40 2)'
    $sourceOnlyEval = '(setq load-prefer-newer t load-suffixes (list ".el"))'
    $cachePath = $cacheRoot.Replace([char]92, [char]47)
    $artifactSourcePath = $artifactRuntimeSource.Replace([char]92, [char]47)
    $artifactCachePath = $artifactRuntimeCache.Replace([char]92, [char]47)
    $artifactEnablePath = $artifactRuntimeCacheEnable.Replace([char]92, [char]47)
    $cacheEval = "(let* ((nelisp-standalone--cache-dir `"$cachePath`") (nelisp-standalone--artifact-runtime-source-path `"$artifactSourcePath`") (nelisp-standalone--artifact-runtime-cache-path `"$artifactCachePath`") (nelisp-standalone--artifact-runtime-cache-enable-path `"$artifactEnablePath`")) (nelisp-standalone-build-reader))"

    $watch = [Diagnostics.Stopwatch]::StartNew()
    Push-Location $RuntimeRoot
    try {
        & $Emacs --batch -Q -L lisp -L src -L scripts `
            --eval $sourceOnlyEval -l nelisp-standalone-build `
            --eval $cacheEval *> $buildLog
        $report.buildExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    $watch.Stop()
    $report.buildElapsedMs = $watch.ElapsedMilliseconds
    if ($report.buildExit -ne 0) {
        throw "Reader build failed with exit code $($report.buildExit); see $buildLog"
    }
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw "Reader build returned success but did not create $exe"
    }

    $watch = [Diagnostics.Stopwatch]::StartNew()
    & $exe --embedded *> $embeddedLog
    $report.embeddedExit = $LASTEXITCODE
    $watch.Stop()
    $report.embeddedElapsedMs = $watch.ElapsedMilliseconds
    if ($report.embeddedExit -ne 42) {
        throw "Embedded reader returned $($report.embeddedExit), expected 42; see $embeddedLog"
    }

    $watch = [Diagnostics.Stopwatch]::StartNew()
    & $exe --eval '(+ 20 23)' *> $dynamicLog
    $report.dynamicEvalExit = $LASTEXITCODE
    $watch.Stop()
    $report.dynamicEvalElapsedMs = $watch.ElapsedMilliseconds
    $report.dynamicEvalOutput = (Get-Content -LiteralPath $dynamicLog -Raw).Trim()
    if ($report.dynamicEvalExit -ne 0 -or $report.dynamicEvalOutput -cne '43') {
        throw "Dynamic evaluation did not produce 43; see $dynamicLog"
    }
    $report.readerSha256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
    if (Test-Path -LiteralPath $artifactRuntimeSource -PathType Leaf) {
        $report.artifactRuntimeSourceSha256 = (Get-FileHash -LiteralPath $artifactRuntimeSource -Algorithm SHA256).Hash
    }
    if (Test-Path -LiteralPath $artifactRuntimeCache -PathType Leaf) {
        $report.artifactRuntimeCacheSha256 = (Get-FileHash -LiteralPath $artifactRuntimeCache -Algorithm SHA256).Hash
    }
    $report.success = $true
} catch {
    $failure = $_.Exception.Message
    $report.error = $failure
} finally {
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
    }
    $report.emacsSha256After = (Get-FileHash -LiteralPath $Emacs -Algorithm SHA256).Hash
    $elcAfter = Get-RuntimeElcSnapshot $RuntimeRoot
    $report.elcCountAfter = $elcAfter.Count
    $report.elcHashesUnchanged = $elcBefore.Count -eq $elcAfter.Count
    if ($report.elcHashesUnchanged) {
        foreach ($path in $elcBefore.Keys) {
            if (-not $elcAfter.ContainsKey($path) -or $elcBefore[$path] -ne $elcAfter[$path]) {
                $report.elcHashesUnchanged = $false
                break
            }
        }
    }
    if ($report.emacsSha256Before -ne $report.emacsSha256After) {
        $report.success = $false
        $report.error = 'The installed Emacs executable changed during the build.'
    }
    if (-not $report.elcHashesUnchanged) {
        $report.success = $false
        $report.error = '.elc files under the runtime source directories changed during the build.'
    }
    $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $reportPath -Encoding utf8
}

Get-Content -LiteralPath $reportPath -Raw
if (-not $report.success) {
    if ($failure) {
        Write-Error $failure
    }
    exit 1
}
