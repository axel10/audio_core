$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
$repoRoot = Resolve-Path $scriptDir
$targetDir = Join-Path -Path $repoRoot -ChildPath "windows\third_party\ffmpeg"

$ffmpegVersion = "0.7"
$versionFile = Join-Path -Path $targetDir -ChildPath "version.txt"
$checkFile = Join-Path -Path $targetDir -ChildPath "bin\avcodec-62.dll"

# Check if libraries already exist and match version
if ((Test-Path -LiteralPath $checkFile) -and (Test-Path -LiteralPath $versionFile)) {
    $existingVersion = (Get-Content -LiteralPath $versionFile -Raw).Trim()
    if ($existingVersion -eq $ffmpegVersion) {
        Write-Host "FFmpeg Windows binaries ($ffmpegVersion) already exist at $targetDir, skipping download."
        Exit 0
    }
}

$downloadUrl = "https://github.com/axel10/audio_core/releases/download/$ffmpegVersion/ffmpeg_lib_windows.zip"
$tempFile = Join-Path -Path $repoRoot -ChildPath "ffmpeg_lib_windows_temp.zip"

Write-Host "Downloading precompiled FFmpeg Windows libraries from $downloadUrl..."
Invoke-WebRequest -Uri $downloadUrl -OutFile $tempFile -UseBasicParsing

Write-Host "Extracting FFmpeg binaries..."
if (Test-Path -LiteralPath $targetDir) {
    Remove-Item -LiteralPath $targetDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
Expand-Archive -Path $tempFile -DestinationPath $targetDir -Force
Set-Content -LiteralPath $versionFile -Value $ffmpegVersion -Force
Remove-Item -LiteralPath $tempFile -Force

Write-Host "FFmpeg Windows binaries ($ffmpegVersion) downloaded and configured successfully!"
