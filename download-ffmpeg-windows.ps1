$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
$repoRoot = Resolve-Path $scriptDir
$targetDir = Join-Path -Path $repoRoot -ChildPath "windows\third_party\ffmpeg"

$configFile = Join-Path -Path $repoRoot -ChildPath "ffmpeg_version.env"
$ffmpegVersion = "0.7"
$ffmpegBaseUrl = "https://github.com/axel10/audio_core/releases/download"
$ffmpegUrlWindows = ""

if (Test-Path -LiteralPath $configFile) {
    Get-Content -LiteralPath $configFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#") -and $line -match '^([^=]+)=(.*)$') {
            $k = $matches[1].Trim()
            $v = $matches[2].Trim().Trim('"').Trim("'")
            if ($k -eq "FFMPEG_VERSION") { $ffmpegVersion = $v }
            elseif ($k -eq "FFMPEG_BASE_URL") { $ffmpegBaseUrl = $v }
            elseif ($k -eq "FFMPEG_URL_WINDOWS") { $ffmpegUrlWindows = $v }
        }
    }
}

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

$downloadUrl = if ($ffmpegUrlWindows) { $ffmpegUrlWindows } else { "$ffmpegBaseUrl/$ffmpegVersion/ffmpeg_lib_windows.zip" }
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
