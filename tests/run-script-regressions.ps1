param(
    [string]$Bin,
    [string]$WorkDir,
    [switch]$PortableOnly
)
$ErrorActionPreference = 'Stop'
$passed = 0
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $Bin) { $Bin = Join-Path $repo 'x64\Release' }
if (-not $WorkDir) { $WorkDir = Join-Path $repo ('artifacts\script-regressions-' + [guid]::NewGuid().ToString('N')) }
New-Item -ItemType Directory -Force $WorkDir | Out-Null
$synthetic = Join-Path $PSScriptRoot 'synthetic\run-synthetic.ps1'
$benchmark = Join-Path $repo 'scripts\benchmark.ps1'

function Assert-Case([bool]$Pass, [string]$Name, [string]$Detail) {
    if (-not $Pass) { throw "$Name failed. $Detail" }
    $script:passed++
    Write-Host "[PASS] $Name"
}

if (-not $PortableOnly) {
    $spaced = Join-Path $WorkDir 'vector outputs with spaces'
    $output = & $synthetic -Bin $Bin -WorkDir $spaced -Stages vectors, cl-vectors 6>&1 | Out-String
    $code = $LASTEXITCODE
    Assert-Case ($code -eq 0 -and $output -match '4/4 checks passed' -and
        (Test-Path -LiteralPath (Join-Path $spaced 'vectors.txt')) -and
        (Test-Path -LiteralPath (Join-Path $spaced 'clvectors.txt'))) 'CUDA and OpenCL output paths with spaces' $output

    & {
        # Pin only the random-key generator. Keep real address derivation and GPU execution.
        $python = (Get-Command python).Source
        $fixedKeyCalls = [System.Collections.Generic.List[string]]::new()
        function Invoke-FixturePython {
            if ($args[1] -ceq '-c' -and $args[2] -match 'secrets\.randbits\(35\)') {
                $fixedKeyCalls.Add('800000001')
                '800000001'
            } else {
                & $python @args
            }
        }
        function Get-Command {
            [CmdletBinding()]
            param([string]$Name)
            if ($Name -eq 'python') { [pscustomobject]@{ Source = 'Invoke-FixturePython' } }
            else { Microsoft.PowerShell.Core\Get-Command @PSBoundParameters }
        }

        $puzzle = Join-Path $WorkDir 'first batch puzzle'
        $output = & $synthetic -Bin $Bin -WorkDir $puzzle -Stages puzzle -GpuArgs @('-b', '1', '-t', '32', '-p', '1') 6>&1 | Out-String
        $code = $LASTEXITCODE
        $log = [string](Get-Content -LiteralPath (Join-Path $puzzle 'puzzle.log') -Raw)
        Assert-Case ($code -eq 0 -and $fixedKeyCalls.Count -eq 1 -and $output -match '3/3 checks passed' -and
            $output -match 'key=800000001' -and $log -notmatch 'MKey/s') 'Puzzle completes before its first progress update' $output
    }
}

$missing = Join-Path $WorkDir 'missing OpenCL'
New-Item -ItemType Directory -Force $missing | Out-Null
$output = & $synthetic -Bin $missing -WorkDir $missing -Stages cl-vectors 6>&1 | Out-String
$code = $LASTEXITCODE
Assert-Case ($code -eq 1 -and $output -match '\[FAIL\] cl-vectors key1: clBitCrack\.exe not found' -and
    $output -match '1/2 checks passed') 'Requested OpenCL binary is required' $output
$output = & $synthetic -Bin $missing -WorkDir $missing -Stages cl-vectors -NoOpenCL 6>&1 | Out-String
$code = $LASTEXITCODE
Assert-Case ($code -eq 0 -and $output -match '1/1 checks passed') 'Explicit OpenCL skip' $output

$fixtures = Join-Path $WorkDir 'benchmark fixtures'
New-Item -ItemType Directory -Force $fixtures | Out-Null
$fixtureExe = Join-Path $fixtures 'cuBitCrack.exe'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
& $compiler /nologo /target:exe "/out:$fixtureExe" (Join-Path $PSScriptRoot 'fixtures\benchmark-process.cs')
if ($LASTEXITCODE -ne 0) { throw "Benchmark fixture compilation failed (exit $LASTEXITCODE)." }
Copy-Item -LiteralPath $fixtureExe -Destination (Join-Path $fixtures 'nvidia-smi.exe')

$oldPath = $env:PATH
$oldTemp = $env:TEMP
$oldDuplicate = $env:BITCRACK_TEST_DUPLICATE_GPU
$oldReady = $env:BITCRACK_TEST_TELEMETRY_READY
$eventName = 'BitCrackTest-' + [guid]::NewGuid().ToString('N')
$ready = [Threading.EventWaitHandle]::new($false, 'AutoReset', $eventName)
try {
    $env:PATH = "$fixtures;$oldPath"
    $env:BITCRACK_TEST_DUPLICATE_GPU = '0'
    $env:BITCRACK_TEST_TELEMETRY_READY = $eventName
    $env:TEMP = Join-Path $WorkDir 'benchmark output'
    $output = & $benchmark -Bin $fixtures -Seconds 3 -Configs '-d 1', '--device 1 -t 13', '--help', '-d 1 -t 31' 6>&1 | Out-String -Width 4096
    $code = $LASTEXITCODE
    $selectedTelemetry = $output -match '\| PASS \| 0 \| Exited \| GPU-chosen \| 123\.4 \| 80 \| 1024 \| 60 \| 100\.5 \| 1800 \|'
    Assert-Case $selectedTelemetry 'Benchmark telemetry follows the selected GPU, independent of enumeration order' $output
    Assert-Case ($code -eq 1 -and $output -match 'FAIL \| 7 \| Exited \| GPU-chosen \| - .*deliberate fixture failure' -and
        $output -match 'FAIL \| 0 \| Exited .*No positive throughput samples') 'Benchmark reports child failures and missing measurements' $output
    $rawLogs = [regex]::Match($output, '(?m)^Raw logs: ([^\r\n]+)').Groups[1].Value
    $successStderr = Get-Content -LiteralPath (Join-Path $rawLogs '1.log.err') -Raw
    Assert-Case ($successStderr -match 'Fixture completed') 'Benchmark preserves stderr from successful configurations' $output
    Assert-Case ($output -match '\| PASS \| -1 \| Time limit \| GPU-chosen \| 123\.4 \|') 'Benchmark accepts a measured configuration stopped at the time limit' $output

    $env:BITCRACK_TEST_DUPLICATE_GPU = '1'
    $output = & $benchmark -Bin $fixtures -Seconds 3 -Configs '--device 1' 6>&1 | Out-String -Width 4096
    $code = $LASTEXITCODE
    $unattributed = $output -match '\| PASS \| 0 \| Exited \| - \| 123\.4 \| - \| - \| - \| - \| - \| Telemetry unavailable'
    Assert-Case ($code -eq 0 -and $unattributed) 'Benchmark omits telemetry when two GPUs share the selected name' $output

    $output = & $benchmark -Bin $missing -Seconds 3 -Configs '-d 1' 6>&1 | Out-String -Width 4096
    $code = $LASTEXITCODE
    Assert-Case ($code -eq 1 -and $output -match '\| FAIL \| - \| - \| - \| - \|' -and $output -match 'cuBitCrack\.exe') 'Benchmark reports launch failures without an exit code' $output
} finally {
    $ready.Dispose()
    $env:PATH = $oldPath
    $env:TEMP = $oldTemp
    $env:BITCRACK_TEST_DUPLICATE_GPU = $oldDuplicate
    $env:BITCRACK_TEST_TELEMETRY_READY = $oldReady
}

$expected = if ($PortableOnly) { 8 } else { 10 }
if ($passed -ne $expected) { throw "Expected $expected regression checks, but $passed passed." }
Write-Host "$passed/$expected script regression checks passed. Logs in $WorkDir"
exit 0
