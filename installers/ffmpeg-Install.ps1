# ffmpeg-Install.ps1
# Принудительно .zip (если .7z глючит)
#.\ffmpeg-Install.ps1 -ForceZip

# По умолчанию: ffmpeg.exe + ffprobe.exe
#.\ffmpeg-Install.ps1

# С ffplay.exe
#.\ffmpeg-Install.ps1 -InstallDecoder

# В свою папку, с ffplay.exe, с паузой при ошибке
#.\ffmpeg-Install.ps1 -InstallDir "C:\Tools\ffmpeg" -InstallDecoder -PauseOnError

# Без добавления в PATH
#.\ffmpeg-Install.ps1 -AddToUserPath:$false

[CmdletBinding()]
param(
	[string]$InstallDir,
	[switch]$AddToUserPath = $true,
	[switch]$InstallFFplay,
	[switch]$ForceZip,
	[switch]$PauseOnError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($InstallDir)) {
	$projectRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
		Split-Path -Parent $PSScriptRoot
	}
	elseif (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
		Split-Path -Parent (Split-Path -Parent $PSCommandPath)
	}
	else {
		(Get-Location).Path
	}

	$InstallDir = Join-Path $projectRoot "tools\ffmpeg"
}

# ----------------------------
# Helper functions
# ----------------------------

function Write-Section {
	param([string]$Text)

	Write-Host "    =========================================" -ForegroundColor Cyan
	Write-Host "    $Text" -ForegroundColor Cyan
	Write-Host "    =========================================" -ForegroundColor Cyan
}

function Write-Step {
	param(
		[string]$Step,
		[string]$Message
	)

	Write-Host "    [$Step] $Message" -ForegroundColor Yellow
}

function Write-Detail {
	param([string]$Message)

	Write-Host "    $Message" -ForegroundColor Yellow
}

function Write-Success {
	param([string]$Message)

	Write-Host "    $Message" -ForegroundColor Green
}

function Stop-Install {
	param([string]$Message)

	Write-Host "    ERROR: $Message" -ForegroundColor Red

	if ($PauseOnError) {
		Read-Host "    Press Enter to exit" | Out-Null
	}

	throw $Message
}

function Find-7ZipExecutable {
	# Check PATH
	$inPath = Get-Command "7z.exe" -ErrorAction SilentlyContinue
	if ($inPath) {
		return $inPath.Source
	}

	# Check common install locations
	$commonPaths = @(
		"${env:ProgramFiles}\7-Zip\7z.exe"
		"${env:ProgramFiles(x86)}\7-Zip\7z.exe"
	)

	foreach ($p in $commonPaths) {
		if (Test-Path $p) {
			return $p
		}
	}

	return $null
}

function Download-File {
	param(
		[string]$Url,
		[string]$Destination
	)

	try {
		if (Test-Path $Destination) {
			Remove-Item $Destination -Force -ErrorAction SilentlyContinue
		}

		# Try BITS first (cleaner progress bar)
		try {
			Start-BitsTransfer -Source $Url -Destination $Destination -DisplayName "Downloading" -Description $Url
			return
		}
		catch {
			Write-Detail "BITS transfer failed, using fallback method..."
		}

		# Fallback: HttpWebRequest with progress
		$request = [System.Net.HttpWebRequest]::Create($Url)
		$request.Timeout = 60000
		$request.UserAgent = "PowerShell-ffmpeg-installer"

		$response = $request.GetResponse()
		$totalBytes = $response.ContentLength
		$responseStream = $response.GetResponseStream()

		$fileStream = [System.IO.File]::Create($Destination)
		$buffer = New-Object byte[] 65536
		$downloadedBytes = 0
		$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

		try {
			while (($bytesRead = $responseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
				$fileStream.Write($buffer, 0, $bytesRead)
				$downloadedBytes += $bytesRead

				if ($totalBytes -gt 0) {
					$percent = [int](($downloadedBytes / $totalBytes) * 100)
					$downloadedMB = [math]::Round($downloadedBytes / 1MB, 2)
					$totalMB = [math]::Round($totalBytes / 1MB, 2)

					$elapsedSeconds = $stopwatch.Elapsed.TotalSeconds
					if ($elapsedSeconds -gt 0) {
						$speedMBps = [math]::Round(($downloadedBytes / 1MB) / $elapsedSeconds, 2)
						$status = "$downloadedMB MB / $totalMB MB ($speedMBps MB/s)"
					}
					else {
						$status = "$downloadedMB MB / $totalMB MB"
					}

					Write-Progress -Activity "Downloading" -Status $status -PercentComplete $percent
				}
			}
		}
		finally {
			Write-Progress -Activity "Downloading" -Completed

			if ($fileStream) {
				try { $fileStream.Close() } catch { }
			}
			if ($responseStream) {
				try { $responseStream.Close() } catch { }
			}
			if ($response) {
				try { $response.Close() } catch { }
			}
			if ($stopwatch) {
				try { $stopwatch.Stop() } catch { }
			}
		}

	}
	catch {
		Stop-Install "Failed to download file. $($_.Exception.Message)"
	}
}

function Expand-ArchiveSafe {
	param(
		[string]$ArchivePath,
		[string]$DestinationPath
	)

	try {
		Expand-Archive -Path $ArchivePath -DestinationPath $DestinationPath -Force
	}
	catch {
		Stop-Install "Failed to extract archive. $($_.Exception.Message)"
	}
}

function Expand-7ZipArchive {
	param(
		[string]$ArchivePath,
		[string]$DestinationPath,
		[string]$SevenZipPath
	)

	try {
		New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null

		$arguments = @(
			"x"
			"`"$ArchivePath`""
			"-o`"$DestinationPath`""
			"-y"
			"-bso0"
			"-bsp0"
		)

		$proc = Start-Process -FilePath $SevenZipPath -ArgumentList $arguments -Wait -PassThru -NoNewWindow

		if ($proc.ExitCode -ne 0) {
			Stop-Install "7-Zip extraction failed with exit code $($proc.ExitCode)."
		}
	}
	catch {
		Stop-Install "Failed to extract 7z archive. $($_.Exception.Message)"
	}
}

function Install-FFmpegTools {
	param(
		[string]$SourceRoot,
		[string]$TargetDir,
		[switch]$InstallFFplay
	)

	$ffmpegFile = Get-ChildItem -Path $SourceRoot -Recurse -Filter "ffmpeg.exe" -File |
		Select-Object -First 1

	if (-not $ffmpegFile) {
		Stop-Install "ffmpeg.exe not found in the archive."
	}

	$binDir = $ffmpegFile.Directory.FullName

	New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null

	# ffmpeg.exe (always)
	Copy-Item -Path $ffmpegFile.FullName -Destination (Join-Path $TargetDir "ffmpeg.exe") -Force

	# ffprobe.exe (always)
	$ffprobeFile = Get-ChildItem -Path $binDir -Filter "ffprobe.exe" -File -ErrorAction SilentlyContinue |
		Select-Object -First 1

	if (-not $ffprobeFile) {
		Stop-Install "ffprobe.exe not found in the archive."
	}

	Copy-Item -Path $ffprobeFile.FullName -Destination (Join-Path $TargetDir "ffprobe.exe") -Force

	# ffplay.exe (optional)
	if ($InstallFFplay) {
		$ffplayFile = Get-ChildItem -Path $binDir -Filter "ffplay.exe" -File -ErrorAction SilentlyContinue |
			Select-Object -First 1

		if (-not $ffplayFile) {
			Stop-Install "ffplay.exe not found in the archive."
		}

		Copy-Item -Path $ffplayFile.FullName -Destination (Join-Path $TargetDir "ffplay.exe") -Force
	}
}

function Normalize-Path {
	param([string]$PathValue)

	if ([string]::IsNullOrWhiteSpace($PathValue)) {
		return ""
	}

	try {
		return [System.IO.Path]::GetFullPath($PathValue).TrimEnd('\')
	}
	catch {
		return $PathValue.Trim().TrimEnd('\')
	}
}

function Get-PathLeafName {
	param([string]$PathValue)

	$normalized = Normalize-Path $PathValue

	if ([string]::IsNullOrWhiteSpace($normalized)) {
		return ""
	}

	try {
		return (Split-Path -Path $normalized -Leaf).Trim().ToLowerInvariant()
	}
	catch {
		return ""
	}
}

function Add-DirectoryToUserPath {
	param([string]$Directory)

	$userPath = [Environment]::GetEnvironmentVariable("Path", "User")

	if ([string]::IsNullOrWhiteSpace($userPath)) {
		$userPath = ""
	}

	$normalizedTarget = Normalize-Path $Directory
	$targetLeaf = Get-PathLeafName $Directory

	$entries = $userPath -split ";" |
		Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

	$filteredEntries = New-Object System.Collections.Generic.List[string]

	foreach ($entry in $entries) {
		$normalizedEntry = Normalize-Path $entry
		$entryLeaf = Get-PathLeafName $entry

		if ($normalizedEntry -ieq $normalizedTarget -or $entryLeaf -ieq $targetLeaf) {
			continue
		}

		$filteredEntries.Add($entry.Trim())
	}

	$filteredEntries.Add($Directory)

	$uniqueEntries = New-Object System.Collections.Generic.List[string]

	foreach ($entry in $filteredEntries) {
		$normalizedEntry = Normalize-Path $entry
		$exists = $false

		foreach ($existing in $uniqueEntries) {
			if ((Normalize-Path $existing) -ieq $normalizedEntry) {
				$exists = $true
				break
			}
		}

		if (-not $exists) {
			$uniqueEntries.Add($entry)
		}
	}

	$newUserPath = $uniqueEntries -join ";"

	[Environment]::SetEnvironmentVariable("Path", $newUserPath, "User")

	$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")

	if ([string]::IsNullOrWhiteSpace($machinePath)) {
		$env:Path = $newUserPath
	}
	else {
		$env:Path = if ([string]::IsNullOrWhiteSpace($machinePath)) {
			$newUserPath
		}
		else {
			"$machinePath;$newUserPath"
		}
	}
}

# ----------------------------
# Main
# ----------------------------

$workRoot	= Join-Path $env:TEMP ("ffmpeg_install_" + [guid]::NewGuid().ToString())
$tempDir	 = Join-Path $workRoot "unpack"
$sevenZipExe = Find-7ZipExecutable

# Determine archive format
if ($ForceZip -or (-not $sevenZipExe)) {
	$archiveExt  = "zip"
	$downloadUrl = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"
}
else {
	$archiveExt  = "7z"
	$downloadUrl = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.7z"
}

$archiveName = "ffmpeg-release-essentials.$archiveExt"
$archivePath = Join-Path $workRoot $archiveName

Write-Section "FFmpeg installer for Windows"

try {
	New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

	Write-Step "1/5" "Install directory:"
	Write-Detail "$InstallDir"
	# Write-Detail "Temp: $workRoot"

	if ($sevenZipExe) {
		Write-Detail "7-Zip found: $sevenZipExe"
		Write-Detail "Archive format: $archiveExt (smaller)"
	}
	else {
		Write-Detail "7-Zip not found"
		Write-Detail "Archive format: $archiveExt (fallback)"
	}

	if ($InstallFFplay) {
		Write-Detail "Components: ffmpeg.exe, ffprobe.exe, ffplay.exe"
	}
	else {
		Write-Detail "Components: ffmpeg.exe, ffprobe.exe"
	}

	Write-Step "2/5" "Downloading $archiveName..."
	Write-Detail "Source: $downloadUrl"
	Download-File -Url $downloadUrl -Destination $archivePath
	Write-Success "Download complete."

	Write-Step "3/5" "Extracting..."
	if ($archiveExt -eq "7z") {
		Expand-7ZipArchive -ArchivePath $archivePath -DestinationPath $tempDir -SevenZipPath $sevenZipExe
	}
	else {
		Expand-ArchiveSafe -ArchivePath $archivePath -DestinationPath $tempDir
	}
	Write-Success "Extracted."

	Write-Step "4/5" "Installing..."
	Install-FFmpegTools -SourceRoot $tempDir -TargetDir $InstallDir -InstallFFplay:$InstallFFplay
	Write-Success "Installed."

	if ($AddToUserPath) {
		Write-Step "5/5" "Updating user PATH..."
		Add-DirectoryToUserPath -Directory $InstallDir
		Write-Success "PATH updated."
	}
	else {
		Write-Step "5/5" "PATH update skipped."
	}

	Write-Host "    Done." -ForegroundColor Cyan
}
catch {
	Write-Host "    $($_.Exception.Message)" -ForegroundColor Red

	if ($PauseOnError) {
		Read-Host "    Press Enter to exit" | Out-Null
	}

	exit 1
}
finally {
	Write-Host "    [*] Cleaning up temp files..." -ForegroundColor Yellow

	$cleanupOk = $true
	if (Test-Path -LiteralPath $workRoot) {
		try {
			Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction Stop
		}
		catch {
			$cleanupOk = $false
			Write-Host "    [!] Failed to remove temp files: $($_.Exception.Message)" -ForegroundColor Yellow
		}
	}

	if ($cleanupOk) {
		Write-Success "Temp files removed."
	}
}