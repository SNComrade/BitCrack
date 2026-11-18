<#
.SYNOPSIS
  Synthetic end-to-end tests for cuBitCrack / clBitCrack on Windows.

.DESCRIPTION
  Every target address is either a published test vector (generator point,
  solved puzzle #20) or derived from a private key this script generates at
  random. No third-party funded address is searched.

  Stages (each prints PASS/FAIL; the script exits 1 if any stage fails):
    vectors     GPU recovers key 1 (compressed + uncompressed) and solved
                puzzle #20; every result is re-derived by btcaddr.py.
    cl-vectors  Same key-1 check through the OpenCL binary (skip with -NoOpenCL).
    puzzle      Random key in a 2^35-wide range is recovered, the run stops
                as soon as the target is found (before the range end).
    bounds      Keys exactly at START and END are found; START-1 is not.
    exhaust     A target outside the range is not found; the run ends with
                "Reached end of keyspace" and writes no result file.
    checkpoint  Run 1 is killed after the first checkpoint (~60 s, fixed in
                BitCrack). Run 2 resumes with --continue, logs the saved
                "next" key as its start, and finds a key placed after it.

.PARAMETER Bin        Directory holding cuBitCrack.exe (default x64\Release).
.PARAMETER WorkDir    Scratch directory for outputs (default %TEMP%\bitcrack-synthetic).
.PARAMETER GpuArgs    Launch parameters (default tuned for RTX 3060 Laptop).
.PARAMETER Stages     Subset of stages to run.
#>
param(
    [string]$Bin,
    [string]$WorkDir = (Join-Path $env:TEMP 'bitcrack-synthetic'),
    [string[]]$GpuArgs = @('-b', '60', '-t', '256', '-p', '1024'),
    [string[]]$Stages = @('vectors', 'cl-vectors', 'puzzle', 'bounds', 'exhaust', 'checkpoint'),
    [switch]$NoOpenCL
)
$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
if (-not $Bin) { $Bin = Join-Path $repo 'x64\Release' }
$cu = Join-Path $Bin 'cuBitCrack.exe'
$cl = Join-Path $Bin 'clBitCrack.exe'
$py = (Get-Command python -ErrorAction Stop).Source
$addrPy = Join-Path $PSScriptRoot 'btcaddr.py'
if (-not (Test-Path $cu)) { throw "cuBitCrack.exe not found in $Bin - run scripts\build-windows.ps1 first." }
New-Item -ItemType Directory -Force $WorkDir | Out-Null
$results = [System.Collections.Generic.List[object]]::new()

function Get-Address([System.Numerics.BigInteger]$Key, [switch]$Uncompressed) {
    $line = & $py -I $addrPy ($Key.ToString('x').TrimStart('0'))
    if ($LASTEXITCODE -ne 0) { throw "btcaddr.py failed" }
    $parts = $line -split ' '
    if ($Uncompressed) { $parts[2] } else { $parts[1] }
}
function New-RandomKey([int]$Bits) {
    # Uniform key in [2^(Bits-1), 2^Bits).
    $hex = & $py -I -c "import secrets;print(hex(secrets.randbits($($Bits-1)) | (1 << $($Bits-1)))[2:])"
    [System.Numerics.BigInteger]::Parse('0' + $hex, 'AllowHexSpecifier')
}
function Hex([System.Numerics.BigInteger]$v) { $v.ToString('x').TrimStart('0') }
function Invoke-BitCrack([string]$Exe, [string[]]$Arguments, [string]$Name, [int]$TimeoutSec = 600) {
    $out = Join-Path $WorkDir "$Name.log"
    $err = Join-Path $WorkDir "$Name.err"
    $p = Start-Process -FilePath $Exe -ArgumentList $Arguments -NoNewWindow -PassThru `
        -RedirectStandardOutput $out -RedirectStandardError $err
    $handle = $p.Handle  # keep the handle so ExitCode is available
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $killed = -not $p.WaitForExit($TimeoutSec * 1000)
    if ($killed) { Stop-Process -Id $p.Id -Force; $p.WaitForExit() }
    $text = ((Get-Content $out -Raw) + (Get-Content $err -Raw)) -replace "`r", "`n"
    [pscustomobject]@{ Exit = $p.ExitCode; Killed = $killed; Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); Log = $text }
}
function Read-Found([string]$File) {
    if (-not (Test-Path $File)) { return @() }
    Get-Content $File | Where-Object { $_ } | ForEach-Object {
        $f = $_ -split ' '
        [pscustomobject]@{ Address = $f[0]; Key = [System.Numerics.BigInteger]::Parse('0' + $f[1], 'AllowHexSpecifier'); PubKey = $f[2] }
    }
}
function Add-Result([string]$Stage, [bool]$Pass, [string]$Detail) {
    $results.Add([pscustomobject]@{ Stage = $Stage; Result = $(if ($Pass) { 'PASS' } else { 'FAIL' }); Detail = $Detail })
    Write-Host ("[{0}] {1}: {2}" -f $(if ($Pass) { 'PASS' } else { 'FAIL' }), $Stage, $Detail)
}
function Test-Found($found, [System.Numerics.BigInteger]$Key, [string]$Address) {
    $hit = $found | Where-Object { $_.Address -eq $Address }
    if (-not $hit) { return $false }
    # Independent re-derivation of the address from the reported key.
    $c = Get-Address $hit[0].Key; $u = Get-Address $hit[0].Key -Uncompressed
    return ($hit[0].Key -eq $Key) -and ($Address -eq $c -or $Address -eq $u)
}

Write-Host "btcaddr.py self-test:"
& $py -I $addrPy --selftest
Add-Result 'btcaddr-selftest' ($LASTEXITCODE -eq 0) 'pure-Python derivation matches published vectors'

if ('vectors' -in $Stages) {
    $f = Join-Path $WorkDir 'vectors.txt'; Remove-Item $f -ErrorAction SilentlyContinue
    $a1c = '1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH'; $a1u = '1EHNa6Q4Jz2uvNExL497mE43ikXhwF6kZm'
    $r = Invoke-BitCrack $cu ($GpuArgs + @('--compression', 'both', '--keyspace', '1:+FFFFFF', '-o', $f, $a1c, $a1u)) 'vectors-key1'
    $found = Read-Found $f
    Add-Result 'vectors key1' ((Test-Found $found 1 $a1c) -and (Test-Found $found 1 $a1u) -and $r.Exit -eq 0) "exit=$($r.Exit) found=$($found.Count)/2"

    $f = Join-Path $WorkDir 'vectors20.txt'; Remove-Item $f -ErrorAction SilentlyContinue
    $a20 = '1HsMJxNiV7TLxmoF6uJNkydxPFDog4NQum'   # solved puzzle #20, key 0xd2c55
    $r = Invoke-BitCrack $cu ($GpuArgs + @('--keyspace', '80000:FFFFF', '-o', $f, $a20)) 'vectors-p20'
    $found = Read-Found $f
    Add-Result 'vectors puzzle20' ((Test-Found $found 0xD2C55 $a20) -and $r.Exit -eq 0) "exit=$($r.Exit) key=$(if ($found) { Hex $found[0].Key })"
}

if ('cl-vectors' -in $Stages -and -not $NoOpenCL -and (Test-Path $cl)) {
    $f = Join-Path $WorkDir 'clvectors.txt'; Remove-Item $f -ErrorAction SilentlyContinue
    $a1c = '1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH'; $a1u = '1EHNa6Q4Jz2uvNExL497mE43ikXhwF6kZm'
    $r = Invoke-BitCrack $cl @('--compression', 'both', '--keyspace', '1:+FFFFFF', '-o', $f, $a1c, $a1u) 'cl-vectors'
    $found = Read-Found $f
    Add-Result 'cl-vectors key1' ((Test-Found $found 1 $a1c) -and (Test-Found $found 1 $a1u) -and $r.Exit -eq 0) "exit=$($r.Exit) found=$($found.Count)/2"
}

if ('puzzle' -in $Stages) {
    $bits = 36
    $lo = [System.Numerics.BigInteger]::Pow(2, $bits - 1); $hi = [System.Numerics.BigInteger]::Pow(2, $bits) - 1
    $key = New-RandomKey $bits; $addr = Get-Address $key
    $f = Join-Path $WorkDir 'puzzle.txt'; Remove-Item $f -ErrorAction SilentlyContinue
    Write-Host "Synthetic puzzle: $bits-bit range $(Hex $lo):$(Hex $hi), target $addr (key withheld until the end)"
    $r = Invoke-BitCrack $cu ($GpuArgs + @('--keyspace', "$(Hex $lo):$(Hex $hi)", '-o', $f, $addr)) 'puzzle'
    $found = Read-Found $f
    $stoppedEarly = $r.Log -match 'No targets remaining'
    $progress = ([regex]::Matches($r.Log, 'MKey/s')).Count -gt 0
    Add-Result 'puzzle recovery' ((Test-Found $found $key $addr) -and $r.Exit -eq 0) "key=$(Hex $key) found=$(if ($found) { Hex $found[0].Key }) in $($r.Seconds)s"
    Add-Result 'puzzle stop-on-found' $stoppedEarly "log contains 'No targets remaining'"
    Add-Result 'puzzle progress' $progress 'progress lines with MKey/s were printed'
}

if ('bounds' -in $Stages) {
    $s = [System.Numerics.BigInteger]0x40000000; $e = [System.Numerics.BigInteger]0x40100000
    foreach ($case in @(@{ K = $s; Want = $true; N = 'START' }, @{ K = $e; Want = $true; N = 'END' }, @{ K = $s - 1; Want = $false; N = 'START-1' })) {
        $addr = Get-Address $case.K
        $f = Join-Path $WorkDir "bounds-$($case.N).txt"; Remove-Item $f -ErrorAction SilentlyContinue
        $r = Invoke-BitCrack $cu ($GpuArgs + @('--keyspace', "$(Hex $s):$(Hex $e)", '-o', $f, $addr)) "bounds-$($case.N)"
        $got = [bool](Read-Found $f | Where-Object { $_.Key -eq $case.K })
        Add-Result "bounds $($case.N)" ($got -eq $case.Want -and $r.Exit -eq 0) "expected found=$($case.Want) observed=$got"
    }
}

if ('exhaust' -in $Stages) {
    $s = [System.Numerics.BigInteger]0x100000000; $e = $s + 0x7FFFFFFF
    $key = $e + 0x40000000   # well past the end, beyond any batch overshoot
    $addr = Get-Address $key
    $f = Join-Path $WorkDir 'exhaust.txt'; Remove-Item $f -ErrorAction SilentlyContinue
    $r = Invoke-BitCrack $cu ($GpuArgs + @('--keyspace', "$(Hex $s):$(Hex $e)", '-o', $f, $addr)) 'exhaust'
    Add-Result 'exhaust no-false-hit' ((-not (Test-Path $f)) -and $r.Exit -eq 0 -and $r.Log -match 'Reached end of keyspace') "exit=$($r.Exit) resultFile=$(Test-Path $f) in $($r.Seconds)s"
}

if ('checkpoint' -in $Stages) {
    $cp = Join-Path $WorkDir 'checkpoint.txt'; Remove-Item $cp -ErrorAction SilentlyContinue
    $s = [System.Numerics.BigInteger]::Pow(2, 44); $e = $s + [System.Numerics.BigInteger]::Pow(2, 46)
    $decoy = Get-Address ($e + 12345)   # unreachable: forces run 1 to keep going
    Write-Host 'Checkpoint run 1: will be killed after ~75 s (BitCrack checkpoints every 60 s)...'
    $r1 = Invoke-BitCrack $cu ($GpuArgs + @('--keyspace', "$(Hex $s):$(Hex $e)", '--continue', $cp, $decoy)) 'checkpoint-run1' -TimeoutSec 75
    $entries = @{}
    if (Test-Path $cp) { Get-Content $cp | ForEach-Object { $k, $v = $_ -split '=', 2; $entries[$k] = $v } }
    $next = if ($entries.next) { [System.Numerics.BigInteger]::Parse('0' + $entries.next, 'AllowHexSpecifier') } else { [System.Numerics.BigInteger]::Zero }
    $ok1 = $r1.Killed -and (Test-Path $cp) -and $next -gt $s -and $r1.Log -match 'Checkpoint'
    Add-Result 'checkpoint written' $ok1 "killed=$($r1.Killed) next=$(Hex $next) searched=$($next - $s) elapsed=$($entries.elapsed)ms"

    if ($ok1) {
        $key = $next + [System.Numerics.BigInteger]::Pow(2, 33)   # ~12 s past the resume point
        $addr = Get-Address $key
        $f = Join-Path $WorkDir 'checkpoint-found.txt'; Remove-Item $f -ErrorAction SilentlyContinue
        $r2 = Invoke-BitCrack $cu ($GpuArgs + @('--continue', $cp, '-o', $f, $addr)) 'checkpoint-run2' -TimeoutSec 300
        $resumedAt = [regex]::Match($r2.Log, 'Starting at: ([0-9A-Fa-f]+)').Groups[1].Value
        $resumedOk = $resumedAt -and ([System.Numerics.BigInteger]::Parse('0' + $resumedAt, 'AllowHexSpecifier') -eq $next)
        Add-Result 'checkpoint resume point' $resumedOk "run2 'Starting at' = $($resumedAt.TrimStart('0')) (checkpoint next = $(Hex $next))"
        Add-Result 'checkpoint resume find' ((Test-Found (Read-Found $f) $key $addr) -and $r2.Exit -eq 0) "key=$(Hex $key) found in $($r2.Seconds)s"
    }
}

Write-Host ''
$results | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
$failed = @($results | Where-Object Result -eq 'FAIL').Count
Write-Host "$($results.Count - $failed)/$($results.Count) checks passed. Logs: $WorkDir"
exit $(if ($failed) { 1 } else { 0 })
