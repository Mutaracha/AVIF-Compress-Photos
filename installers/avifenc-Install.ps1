# avifenc-Install.ps1
# По умолчанию: avifenc.exe
#.\avifenc-Install.ps1

# avifenc.exe + avifdec.exe
#.\avifenc-Install.ps1 -InstallDecoder

# В свою папку, с avifdec.exe, с паузой при ошибке
#.\avifenc-Install.ps1 -InstallDir "C:\Tools\avifenc" -InstallDecoder -PauseOnError

# Без добавления в PATH
#.\avifenc-Install.ps1 -AddToUserPath:$false
[CmdletBinding()]
param(
	[string]$InstallDir,
	[switch]$AddToUserPath = $true,
	[switch]$InstallDecoder,
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

	$InstallDir = Join-Path $projectRoot "tools\libavif"
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

function Get-LatestLibavifRelease {
	param([hashtable]$Headers)

	$apiUrl = "https://api.github.com/repos/AOMediaCodec/libavif/releases/latest"

	try {
		return Invoke-RestMethod -Uri $apiUrl -Headers $Headers
	}
	catch {
		Stop-Install "Failed to fetch release info. $($_.Exception.Message)"
	}
}

function Find-WindowsAsset {
	param([object]$Release)

	$preferred = $Release.assets | Where-Object {
		$_.name -match "windows" -and
		$_.name -match "(x86_64|amd64|x64)" -and
		$_.name -match "\.zip$"
	} | Select-Object -First 1

	if ($preferred) {
		return $preferred
	}

	$fallback = $Release.assets | Where-Object {
		$_.name -match "windows" -and
		$_.name -match "\.zip$"
	} | Select-Object -First 1

	if ($fallback) {
		return $fallback
	}

	$assetList = ($Release.assets | ForEach-Object { "		- $($_.name)" }) -join [Environment]::NewLine
	Stop-Install "No suitable Windows archive found.`n	Available files:`n$assetList"
}

function Download-File {
	param(
		[string]$Url,
		[string]$Destination,
		[hashtable]$Headers
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
		$request.UserAgent = "PowerShell-avifenc-installer"

		if ($Headers) {
			foreach ($key in $Headers.Keys) {
				if ($key -ieq 'User-Agent') {
					$request.UserAgent = [string]$Headers[$key]
				}
				else {
					$request.Headers[$key] = [string]$Headers[$key]
				}
			}
		}

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

function Install-AvifTools {
	param(
		[string]$SourceRoot,
		[string]$TargetDir,
		[switch]$InstallDecoder
	)

	$avifencFile = Get-ChildItem -Path $SourceRoot -Recurse -Filter "avifenc.exe" |
		Select-Object -First 1

	if (-not $avifencFile) {
		Stop-Install "avifenc.exe not found in the archive."
	}

	New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null

	Copy-Item -Path $avifencFile.FullName -Destination (Join-Path $TargetDir "avifenc.exe") -Force

	if ($InstallDecoder) {
		$avifdecFile = Get-ChildItem -Path $SourceRoot -Recurse -Filter "avifdec.exe" |
			Select-Object -First 1

		if (-not $avifdecFile) {
			Stop-Install "avifdec.exe not found in the archive."
		}

		Copy-Item -Path $avifdecFile.FullName -Destination (Join-Path $TargetDir "avifdec.exe") -Force
	}

	$dllFiles = Get-ChildItem -Path $avifencFile.Directory.FullName -Filter "*.dll" -File -ErrorAction SilentlyContinue
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

$headers  = @{ "User-Agent" = "PowerShell-avifenc-installer" }
$workRoot = Join-Path $env:TEMP ("libavif_install_" + [guid]::NewGuid().ToString())
$tempDir  = Join-Path $workRoot "unpack"

Write-Section "avifenc (libavif) installer for Windows"

try {
	New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

	Write-Step "1/6" "Install directory:"
	Write-Detail "$InstallDir"
	# Write-Detail "Temp: $workRoot"

	if ($InstallDecoder) {
		Write-Detail "Components: avifenc.exe + avifdec.exe"
	}
	else {
		Write-Detail "Components: avifenc.exe"
	}

	Write-Step "2/6" "Fetching latest release from GitHub..."
	$release = Get-LatestLibavifRelease -Headers $headers
	Write-Success "Latest version: $($release.tag_name)"

	Write-Step "3/6" "Looking for Windows x64 archive..."
	$asset	   = Find-WindowsAsset -Release $release
	$archiveName = $asset.name
	$archivePath = Join-Path $workRoot $archiveName
	Write-Success "File: $archiveName"

	Write-Step "4/6" "Downloading..."
	Download-File -Url $asset.browser_download_url -Destination $archivePath -Headers $headers
	Write-Success "Download complete."

	Write-Step "5/6" "Extracting and installing..."
	Expand-ArchiveSafe -ArchivePath $archivePath -DestinationPath $tempDir
	Install-AvifTools -SourceRoot $tempDir -TargetDir $InstallDir -InstallDecoder:$InstallDecoder
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