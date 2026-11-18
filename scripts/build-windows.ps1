<#
.SYNOPSIS
  Build BitCrack (cuBitCrack + clBitCrack) on Windows with MSBuild.

.DESCRIPTION
  Requires Visual Studio 2022 (or Build Tools 2022) with the MSVC v143 C++
  toolset and a Windows 10/11 SDK, plus the CUDA Toolkit whose version matches
  the "CUDA 13.4" build customization referenced in the .vcxproj files.

.PARAMETER Configuration  Release (default) or Debug.
.PARAMETER CudaArch       nvcc -gencode pair, default compute_86,sm_86 (RTX 30xx).
.PARAMETER Target         MSBuild target(s), default Build. Use Rebuild for clean.
#>
param(
    [ValidateSet('Release', 'Debug')] [string]$Configuration = 'Release',
    [string]$CudaArch = 'compute_86,sm_86',
    [string]$Target = 'Build'
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

if (-not $env:CUDA_PATH -or -not (Test-Path "$env:CUDA_PATH\bin\nvcc.exe")) {
    $default = 'C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.4'
    if (Test-Path "$default\bin\nvcc.exe") { $env:CUDA_PATH = $default }
    else { throw "CUDA Toolkit not found. Install it (winget install Nvidia.CUDA --version 13.4) or set CUDA_PATH." }
}
Write-Host "CUDA_PATH = $env:CUDA_PATH"
# The CUDA MSBuild customization locates the toolkit via CUDA_PATH_V<major>_<minor>.
# A shell opened before the CUDA install will not have it yet.
if (-not $env:CUDA_PATH_V13_4) { $env:CUDA_PATH_V13_4 = $env:CUDA_PATH }

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$msbuild = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
if (-not $msbuild) { throw 'MSBuild not found (install VS 2022 Build Tools with the C++ workload).' }
Write-Host "MSBuild   = $msbuild"

& $msbuild "$repo\BitCrack.sln" "/t:$Target" "/p:Configuration=$Configuration" '/p:Platform=x64' `
    "/p:BitCrackCudaArch=$($CudaArch -replace ',', '%2C')" '/m' '/nologo' '/v:minimal'
if ($LASTEXITCODE -ne 0) { throw "MSBuild failed with exit code $LASTEXITCODE" }

Get-ChildItem "$repo\x64\$Configuration\*.exe" | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize
