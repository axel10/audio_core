$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
$repoRoot = Resolve-Path $scriptDir
$targetDir = Join-Path -Path $repoRoot -ChildPath "windows\third_party\ffmpeg"

# Check if libraries already exist
$checkFile = Join-Path -Path $targetDir -ChildPath "bin\avcodec-62.dll"
if (Test-Path -LiteralPath $checkFile) {
    Write-Host "FFmpeg Windows binaries already exist at $targetDir, skipping download."
    Exit 0
}

$downloadUrl = "https://github.com/axel10/audio_core/releases/download/0.4/ffmpeg_lib_windows.zip"
$tempFile = Join-Path -Path $repoRoot -ChildPath "ffmpeg_lib_windows_temp.zip"

Write-Host "Downloading precompiled FFmpeg Windows libraries from $downloadUrl..."
Invoke-WebRequest -Uri $downloadUrl -OutFile $tempFile -UseBasicParsing

Write-Host "Extracting FFmpeg binaries..."
if (Test-Path -LiteralPath $targetDir) {
    Remove-Item -LiteralPath $targetDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
Expand-Archive -Path $tempFile -DestinationPath $targetDir -Force
Remove-Item -LiteralPath $tempFile -Force

Write-Host "FFmpeg Windows binaries downloaded and configured successfully!"
