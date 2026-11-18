<#
.SYNOPSIS
  Benchmark cuBitCrack / clBitCrack launch configurations with GPU telemetry.

.DESCRIPTION
  Each configuration searches a large range for an address derived from a
  random synthetic key (never found in practice) for -Seconds seconds while
  nvidia-smi samples the selected GPU when it can be identified uniquely.
  Reports the median of the last progress readings and the process outcome
  for each configuration. Exits 1 if any configuration fails.
#>
param(
    [string]$Bin,
    [ValidateRange(1, 2147483)] [int]$Seconds = 40,
    [string[]]$Configs = @('', '-b 60 -t 256 -p 256', '-b 120 -t 256 -p 512', '-b 60 -t 256 -p 1024', '-b 120 -t 256 -p 1024'),
    [switch]$IncludeOpenCL
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$repo = Resolve-Path (Join-Path $PSScriptRoot '..')
if (-not $Bin) { $Bin = Join-Path $repo 'x64\Release' }
$py = (Get-Command python).Source
$work = Join-Path $env:TEMP 'bitcrack-bench'
$logs = Join-Path $work ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $logs | Out-Null

function Get-BenchmarkGpu([string]$Config, [object[]]$Devices, [object[]]$NvidiaGpus) {
    $deviceOptions = [regex]::Matches($Config, '(?:^|\s)(?:-d|--device)\s+(\S+)')
    $deviceId = 0
    if ($deviceOptions.Count) {
        $value = $deviceOptions[$deviceOptions.Count - 1].Groups[1].Value
        if ($value -cmatch '^(?:0x([0-9a-fA-F]+)|([0-9a-fA-F]+)h)$') {
            if (-not [int]::TryParse(($Matches[1] + $Matches[2]), 'HexNumber', $null, [ref]$deviceId)) { return }
        } elseif ($value -notmatch '^\d+$' -or -not [int]::TryParse($value, [ref]$deviceId)) {
            return
        }
    }
    $device = $Devices | Where-Object Id -eq $deviceId
    if (-not $device) { return }
    # CUDA/OpenCL device ordinals do not identify the same GPU in nvidia-smi.
    $candidates = @($NvidiaGpus | Where-Object Name -eq $device.Name)
    if ($candidates.Count -eq 1) { $candidates[0] }
}

function Get-TelemetryStat($Samples, [int]$Column, [switch]$Maximum, [int]$Digits = 0) {
    $values = foreach ($sample in $Samples) {
        $number = 0.0
        if ([double]::TryParse($sample[$Column], 'Float', [cultureinfo]::InvariantCulture, [ref]$number)) { $number }
    }
    if ($null -eq $values) { return '-' }
    if ($Maximum) { return ($values | Measure-Object -Maximum).Maximum }
    [math]::Round(($values | Measure-Object -Average).Average, $Digits)
}

$key = & $py -I -c "import secrets;print(hex(secrets.randbits(200) | 1 << 200)[2:])"
if ($LASTEXITCODE -ne 0) { throw 'Synthetic benchmark key generation failed.' }
$addr = ((& $py -I (Join-Path $repo 'tests\synthetic\btcaddr.py') $key) -split ' ')[1]
if ($LASTEXITCODE -ne 0 -or -not $addr) { throw 'Synthetic benchmark address generation failed.' }
Write-Host "Synthetic dummy target: $addr"
$nvidiaGpus = @()
$smiExe = (Get-Command nvidia-smi -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if ($smiExe) {
    try {
        $inventory = & $smiExe --query-gpu=uuid,name,driver_version --format=csv,noheader,nounits 2>$null
        if ($LASTEXITCODE -eq 0) {
            $nvidiaGpus = @($inventory | ConvertFrom-Csv -Header Uuid, Name, Driver)
        }
    } catch {
        Write-Warning "NVIDIA device listing failed. $($_.Exception.Message)"
    }
}

$runs = @()
foreach ($c in $Configs) { $runs += , @('cuBitCrack.exe', $c) }
if ($IncludeOpenCL) { $runs += , @('clBitCrack.exe', '') }
if (-not $runs.Count) { throw 'No benchmark configurations requested.' }

$deviceLists = @{}
$runNumber = 0
$rows = foreach ($r in $runs) {
    $exe = Join-Path $Bin $r[0]; $cfg = $r[1]
    $runNumber++
    $log = Join-Path $logs "$runNumber.log"
    $smiCsv = Join-Path $logs "$runNumber.smi.csv"
    $arguments = @($cfg -split '\s+' | Where-Object { $_ }) + @('--keyspace', '8000000000:+FFFFFFFFFFFF', $addr)
    if (-not $deviceLists.ContainsKey($exe)) {
        $deviceLists[$exe] = @()
        if ($nvidiaGpus.Count -and (Test-Path -LiteralPath $exe -PathType Leaf)) {
            try {
                $devices = & $exe --list-devices 2>$null
                if ($LASTEXITCODE -eq 0) {
                    $deviceLists[$exe] = @([regex]::Matches(($devices -join "`n"), '(?m)^ID:[ \t]*(\d+)\nName:[ \t]*(.+)$') |
                        ForEach-Object { [pscustomobject]@{ Id = [int]$_.Groups[1].Value; Name = $_.Groups[2].Value.Trim() } })
                }
            } catch {
                Write-Warning "Device listing failed for $exe. $($_.Exception.Message)"
            }
        }
    }
    $gpu = Get-BenchmarkGpu $cfg $deviceLists[$exe] $nvidiaGpus
    $smi = $null
    $telemetryNote = ''
    if ($gpu) {
        Write-Host "Run ${runNumber}: $($gpu.Name) ($($gpu.Uuid)), NVIDIA driver $($gpu.Driver)"
        try {
            $smiArgs = @('-i', $gpu.Uuid, '--query-gpu=utilization.gpu,memory.used,temperature.gpu,power.draw,clocks.sm',
                '--format=csv,noheader,nounits', '-l', '2')
            $smi = Start-Process $smiExe -ArgumentList $smiArgs -NoNewWindow -PassThru `
                -RedirectStandardOutput $smiCsv -RedirectStandardError "$smiCsv.err"
        } catch {
            $telemetryNote = "Telemetry launch failed. $($_.Exception.Message)"
        }
    } else {
        $telemetryNote = 'Telemetry unavailable. No unique NVIDIA match for the selected device.'
    }

    $p = $null
    $exitCode = $null
    $timedOut = $false
    $runError = ''
    try {
        $p = Start-Process $exe -ArgumentList $arguments -NoNewWindow -PassThru `
            -RedirectStandardOutput $log -RedirectStandardError "$log.err"
        $null = $p.Handle # Retain the process handle to read its exit code.
        if (-not $p.WaitForExit($Seconds * 1000) -and -not $p.HasExited) {
            try {
                $p.Kill()
                $timedOut = $true
            } catch {
                if (-not $p.HasExited) { throw }
            }
        }
        $p.WaitForExit()
        $exitCode = $p.ExitCode
        # Process.Kill uses -1 on Windows. A natural exit can race the kill request.
        $timedOut = $timedOut -and $exitCode -eq -1
    } catch {
        $runError = $_.Exception.Message
    } finally {
        if ($p) { $p.Dispose() }
        if ($smi) {
            try {
                if (-not $smi.HasExited) { $smi.Kill() }
            } catch {
                if (-not $smi.HasExited) { $telemetryNote = "Telemetry stop failed. $($_.Exception.Message)" }
            } finally {
                if (-not $telemetryNote) { $smi.WaitForExit() }
                $smi.Dispose()
            }
        }
    }

    $stdout = if (Test-Path -LiteralPath $log) { [string](Get-Content -LiteralPath $log -Raw) } else { '' }
    $stderr = if (Test-Path -LiteralPath "$log.err") { @(Get-Content -LiteralPath "$log.err") }
    $rates = [regex]::Matches($stdout, '([0-9.]+) MKey/s') | ForEach-Object { [double]$_.Groups[1].Value }
    $tail = @($rates | Select-Object -Last 5 | Sort-Object)
    $rate = if ($tail.Count) { $tail[[int][math]::Floor($tail.Count / 2)] } else { 0 }
    if (-not $runError -and -not $timedOut -and $exitCode -ne 0) { $runError = 'Process exited unsuccessfully.' }
    if (-not $runError -and $rate -le 0) { $runError = 'No positive throughput samples.' }
    if ($runError -and $stderr) {
        $errorLines = @($stderr | Where-Object { $_ -match '\berror\b' })
        if (-not $errorLines.Count) { $errorLines = @($stderr | Select-Object -Last 3) }
        $runError = "$runError " + ($errorLines -join ' ')
    }

    $samples = @(if (Test-Path -LiteralPath $smiCsv) {
        Get-Content -LiteralPath $smiCsv | ForEach-Object {
            $fields = $_ -split ',\s*'
            if ($fields.Count -eq 5) { ,$fields }
        }
    })
    $busy = @($samples | Where-Object { $_[0] -match '^\d+$' -and [int]$_[0] -ge 50 })
    if ($gpu -and -not $samples.Count -and -not $telemetryNote) { $telemetryNote = 'No telemetry samples.' }
    $note = @($runError, $telemetryNote) | Where-Object { $_ }
    [pscustomobject]@{
        Run = $runNumber
        Binary   = $r[0]
        Config   = if ($cfg) { $cfg } else { '(auto)' }
        Status   = if ($runError) { 'FAIL' } else { 'PASS' }
        ExitCode = if ($null -ne $exitCode) { $exitCode } else { '-' }
        End      = if ($timedOut) { 'Time limit' } elseif ($null -ne $exitCode) { 'Exited' } else { '-' }
        Gpu      = if ($gpu) { $gpu.Uuid } else { '-' }
        'MKey/s' = if ($runError) { '-' } else { $rate }
        'GPU %'  = Get-TelemetryStat $busy 0
        'VRAM MiB (nvidia-smi max)' = Get-TelemetryStat $samples 1 -Maximum
        'Temp C max' = Get-TelemetryStat $samples 2 -Maximum
        'Power W avg' = Get-TelemetryStat $busy 3 -Digits 1
        'SM MHz avg' = Get-TelemetryStat $busy 4
        Note     = ($note -join ' ') -replace '\|', '\|' -replace '[\r\n]+', ' '
    }
}

$md = @('| Run | Binary | Config | Status | Exit code | End | GPU UUID | MKey/s | GPU % | VRAM MiB | Temp C max | Power W avg | SM MHz avg | Note |',
    '|---:|---|---|---|---:|---|---|---:|---:|---:|---:|---:|---:|---|')
foreach ($x in $rows) {
    $md += "| $($x.Run) | $($x.Binary) | ``$($x.Config)`` | $($x.Status) | $($x.ExitCode) | $($x.End) | $($x.Gpu) | $($x.'MKey/s') | $($x.'GPU %') | $($x.'VRAM MiB (nvidia-smi max)') | $($x.'Temp C max') | $($x.'Power W avg') | $($x.'SM MHz avg') | $($x.Note) |"
}
$md -join "`n" | Tee-Object -FilePath (Join-Path $work 'benchmark.md')
Write-Host "`nRaw logs: $logs"
exit $(if ($rows | Where-Object Status -eq 'FAIL') { 1 } else { 0 })
