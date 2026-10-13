# gif2webp-Install.ps1
# Только gif2webp.exe (по умолчанию)
#.\gif2webp-Install.ps1

# gif2webp.exe + все дополнительные утилиты
#.\gif2webp-Install.ps1 -InstallExtraTools

# В свою папку, с доп. утилитами, с паузой при ошибке
#.\gif2webp-Install.ps1 -InstallDir "C:\Tools\gif2webp" -InstallExtraTools -PauseOnError

# Без добавления в PATH
#.\gif2webp-Install.ps1 -AddToUserPath:$false

[CmdletBinding()]
param(
	[string]$InstallDir,
	[switch]$AddToUserPath = $true,
	[switch]$InstallExtraTools,
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

	$InstallDir = Join-Path $projectRoot "tools\gif2webp"
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

function Normalize-VersionString {
	param([string]$Version)

	$parts = $Version.Split('.')
	while ($parts.Count -lt 4) {
		$parts += '0'
	}

	return ($parts[0..3] -join '.')
}

function Get-LatestLibwebpAsset {
	$indexUrl = "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/index.html"
	$baseUrl  = "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/"

	try {
		$response = Invoke-WebRequest -Uri $indexUrl -UseBasicParsing
	}
	catch {
		Stop-Install "Failed to fetch libwebp release index. $($_.Exception.Message)"
	}

	if (-not $response.Content) {
		Stop-Install "Release index page is empty."
	}

	$content = $response.Content

	$regex = 'libwebp-(\d+(?:\.\d+)+)-windows-x64\.zip'
	$allMatches = [regex]::Matches($content, $regex)

	if (-not $allMatches -or $allMatches.Count -eq 0) {
		Stop-Install "No Windows x64 archive found on the official libwebp release page."
	}

	$items = foreach ($m in $allMatches) {
		[PSCustomObject]@{
			Version = $m.Groups[1].Value
			Name	= $m.Value
		}
	}

	$latest = $items |
		Sort-Object @{ Expression = { [version](Normalize-VersionString $_.Version) }; Descending = $true } |
		Select-Object -First 1

	if (-not $latest) {
		Stop-Install "Failed to determine the latest libwebp Windows x64 package."
	}

	return [PSCustomObject]@{
		Version = $latest.Version
		Name	= $latest.Name
		Url	 = $baseUrl + $latest.Name
	}
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

function Install-WebpTools {
	param(
		[string]$SourceRoot,
		[string]$TargetDir,
		[switch]$InstallExtraTools
	)

	$gif2webpFile = Get-ChildItem -Path $SourceRoot -Recurse -Filter "gif2webp.exe" -File |
		Select-Object -First 1

	if (-not $gif2webpFile) {
		Stop-Install "gif2webp.exe not found in the archive."
	}

	New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null

	Copy-Item -Path $gif2webpFile.FullName -Destination (Join-Path $TargetDir "gif2webp.exe") -Force

	if ($InstallExtraTools) {
		$extraTools = @(
			"cwebp.exe",
			"dwebp.exe",
			"webpmux.exe",
			"webpinfo.exe",
			"img2webp.exe",
			"anim_diff.exe",
			"anim_dump.exe",
			"get_disto.exe",
			"vwebp.exe"
		)

		foreach ($toolName in $extraTools) {
			$toolFile = Get-ChildItem -Path $gif2webpFile.Directory.FullName -Filter $toolName -File -ErrorAction SilentlyContinue |
				Select-Object -First 1

			if ($toolFile) {
				Copy-Item -Path $toolFile.FullName -Destination (Join-Path $TargetDir $toolFile.Name) -Force
			}
		}
	}

	$dllFiles = Get-ChildItem -Path $gif2webpFile.Directory.FullName -Filter "*.dll" -File -ErrorAction SilentlyContinue
	foreach ($dll in $dllFiles) {
		Copy-Item -Path $dll.FullName -Destination (Join-Path $TargetDir $dll.Name) -Force
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

$workRoot = Join-Path $env:TEMP ("gif2webp_install_" + [guid]::NewGuid().ToString())
$tempDir  = Join-Path $workRoot "unpack"

Write-Section "gif2webp (libwebp) installer for Windows"

try {
	New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

	Write-Step "1/6" "Install directory:"
	Write-Detail "$InstallDir"
	# Write-Detail "Temp: $workRoot"

	if ($InstallExtraTools) {
		Write-Detail "Extra tools: yes"
	}
	else {
		Write-Detail "Extra tools: no"
	}

	Write-Step "2/6" "Fetching latest release from official libwebp page..."
	$asset = Get-LatestLibwebpAsset
	Write-Success "Latest version: $($asset.Version)"

	Write-Step "3/6" "Looking for Windows x64 archive..."
	$archiveName = $asset.Name
	$archivePath = Join-Path $workRoot $archiveName
	Write-Success "File: $archiveName"

	Write-Step "4/6" "Downloading..."
	Download-File -Url $asset.Url -Destination $archivePath
	Write-Success "Download complete."

	Write-Step "5/6" "Extracting and installing..."
	Expand-ArchiveSafe -ArchivePath $archivePath -DestinationPath $tempDir
	Install-WebpTools -SourceRoot $tempDir -TargetDir $InstallDir -InstallExtraTools:$InstallExtraTools
	Write-Success "Installed."

	if ($AddToUserPath) {
		Write-Step "6/6" "Updating user PATH..."
		Add-DirectoryToUserPath -Directory $InstallDir
		Write-Success "PATH updated."
	}
	else {
		Write-Step "6/6" "PATH update skipped."
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