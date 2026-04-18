$ErrorActionPreference = 'Stop'

Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

function Require-Command {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found on PATH."
    }
}

Require-Command flutter
Require-Command dart

Write-Host "Installing project dependencies..." -ForegroundColor Cyan
flutter pub get

Write-Host "Building Windows release..." -ForegroundColor Cyan
flutter build windows --release

Write-Host "Creating MSIX installer..." -ForegroundColor Cyan
dart run msix:create

$releaseDir = Join-Path $repoRoot 'build/windows/x64/runner/Release'
$portableDir = Join-Path $repoRoot 'dist/windows/portable'
$portableZip = Join-Path $portableDir 'Flora-windows-release.zip'

if (Test-Path $releaseDir) {
    New-Item -ItemType Directory -Force -Path $portableDir | Out-Null
    if (Test-Path $portableZip) {
        Remove-Item $portableZip -Force
    }

    Write-Host "Creating portable zip bundle..." -ForegroundColor Cyan
    Compress-Archive -Path (Join-Path $releaseDir '*') -DestinationPath $portableZip -Force
    Write-Host "Portable bundle: $portableZip" -ForegroundColor Green
}

$msixDir = Join-Path $repoRoot 'dist/windows/msix'
if (Test-Path $msixDir) {
    Get-ChildItem $msixDir -File | ForEach-Object {
        Write-Host "Installer: $($_.FullName)" -ForegroundColor Green
    }
}

Write-Host "Windows packaging complete." -ForegroundColor Green
