<#
.SYNOPSIS
  Benchmark cuBitCrack / clBitCrack launch configurations with GPU telemetry.

.DESCRIPTION
  Each configuration searches a large range for an address derived from a
  random synthetic key (never found in practice) for -Seconds seconds while
  nvidia-smi samples utilization, VRAM, temperature, power and SM clock.
  Reports the median of the last progress readings (warm-up excluded) as a
  Markdown table.
#>
param(
    [string]$Bin,
    [int]$Seconds = 40,
    [string[]]$Configs = @('', '-b 60 -t 256 -p 256', '-b 120 -t 256 -p 512', '-b 60 -t 256 -p 1024', '-b 120 -t 256 -p 1024'),
    [switch]$IncludeOpenCL
)
$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..')
if (-not $Bin) { $Bin = Join-Path $repo 'x64\Release' }
$py = (Get-Command python).Source
$work = Join-Path $env:TEMP 'bitcrack-bench'; New-Item -ItemType Directory -Force $work | Out-Null

$key = & $py -I -c "import secrets;print(hex(secrets.randbits(200) | 1 << 200)[2:])"
$addr = ((& $py -I (Join-Path $repo 'tests\synthetic\btcaddr.py') $key) -split ' ')[1]
Write-Host "Synthetic dummy target: $addr"
Write-Host (& nvidia-smi --query-gpu=name,driver_version,power.limit --format=csv,noheader)

$runs = @()
foreach ($c in $Configs) { $runs += , @('cuBitCrack.exe', $c) }
if ($IncludeOpenCL) { $runs += , @('clBitCrack.exe', '') }

$rows = foreach ($r in $runs) {
    $exe = Join-Path $Bin $r[0]; $cfg = $r[1]
    $tag = ($r[0] + $cfg) -replace '[^A-Za-z0-9]', '_'
    $log = Join-Path $work "$tag.log"; $smiCsv = Join-Path $work "$tag.smi.csv"
    $args = @(); if ($cfg) { $args += $cfg -split ' ' }
    $args += @('--keyspace', '8000000000:+FFFFFFFFFFFF', $addr)
    $smi = Start-Process nvidia-smi -ArgumentList '--query-gpu=utilization.gpu,memory.used,temperature.gpu,power.draw,clocks.sm', '--format=csv,noheader,nounits', '-l', '2' `
        -NoNewWindow -PassThru -RedirectStandardOutput $smiCsv
    $p = Start-Process $exe -ArgumentList $args -NoNewWindow -PassThru -RedirectStandardOutput $log -RedirectStandardError "$log.err"
    $null = $p.WaitForExit($Seconds * 1000)
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    Stop-Process -Id $smi.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    $text = (Get-Content $log -Raw) -replace "`r", "`n"
    $rates = [regex]::Matches($text, '([0-9.]+) MKey/s') | ForEach-Object { [double]$_.Groups[1].Value }
    $mem = [regex]::Matches($text, '\| ?\s*([0-9]+) ?/ ?([0-9]+)MB') | Select-Object -Last 1
    $tail = @($rates | Select-Object -Last 5 | Sort-Object)
    $rate = if ($tail.Count) { $tail[[int][math]::Floor($tail.Count / 2)] } else { 0 }
    $s = Get-Content $smiCsv | Where-Object { $_ } | ForEach-Object { , ($_ -split ',\s*' | ForEach-Object { [double]$_ }) }
    $busy = @($s | Where-Object { $_[0] -ge 50 })
    $err = if ($rate -eq 0) { ([regex]::Match($text, 'Error: (.*)').Groups[1].Value) } else { '' }
    [pscustomobject]@{
        Binary   = $r[0]
        Config   = if ($cfg) { $cfg } else { '(auto)' }
        'MKey/s' = $rate
        'GPU %'  = if ($busy) { [math]::Round(($busy | ForEach-Object { $_[0] } | Measure-Object -Average).Average) } else { '-' }
        'VRAM MiB (nvidia-smi max)' = if ($s) { ($s | ForEach-Object { $_[1] } | Measure-Object -Maximum).Maximum } else { '-' }
        'Temp C max' = if ($s) { ($s | ForEach-Object { $_[2] } | Measure-Object -Maximum).Maximum } else { '-' }
        'Power W avg' = if ($busy) { [math]::Round(($busy | ForEach-Object { $_[3] } | Measure-Object -Average).Average, 1) } else { '-' }
        'SM MHz avg' = if ($busy) { [math]::Round(($busy | ForEach-Object { $_[4] } | Measure-Object -Average).Average) } else { '-' }
        Note     = $err
    }
}

$md = @('| Binary | Config | MKey/s | GPU % | VRAM MiB | Temp °C max | Power W avg | SM MHz avg | Note |', '|---|---|---:|---:|---:|---:|---:|---:|---|')
foreach ($x in $rows) {
    $md += "| $($x.Binary) | ``$($x.Config)`` | $($x.'MKey/s') | $($x.'GPU %') | $($x.'VRAM MiB (nvidia-smi max)') | $($x.'Temp C max') | $($x.'Power W avg') | $($x.'SM MHz avg') | $($x.Note) |"
}
$md -join "`n" | Tee-Object -FilePath (Join-Path $work 'benchmark.md')
Write-Host "`nRaw logs: $work"
