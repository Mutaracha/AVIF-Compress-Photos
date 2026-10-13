# Main.ps1
#Requires -Version 5.1
param(
    [string]$InputPath
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::CursorVisible = $false

# ═══════════════════════════════════════════════════════════════════════
# SINGLE INSTANCE CHECK
# ═══════════════════════════════════════════════════════════════════════

$script:mutex = $null
try {
    $script:mutex = [System.Threading.Mutex]::new($false, 'Global\AVIFCompressorInstance')
    if (-not $script:mutex.WaitOne(0)) {
        Write-Host ''
        Write-Host '    [!] Another instance of AVIF Compressor is already running.' -ForegroundColor Yellow
        Write-Host '    Close it first, then try again.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '    Press any key to exit.'
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        exit 0
    }
}
catch [System.Threading.AbandonedMutexException] {
    # Previous instance crashed — mutex is ours now
}

# ═══════════════════════════════════════════════════════════════════════
# LOAD MODULES
# ═══════════════════════════════════════════════════════════════════════

. "$PSScriptRoot\UI.ps1"
. "$PSScriptRoot\Config.ps1"
. "$PSScriptRoot\Logging.ps1"

# ═══════════════════════════════════════════════════════════════════════
# ERROR HANDLER
# ═══════════════════════════════════════════════════════════════════════

trap {
    $debugMode = $false
    try {
        $s = Import-PowerShellDataFile (Get-SettingsPath)
        $debugMode = [bool][int]$s.General.DebugMode
    } catch { }

    Show-FatalError -ErrorRecord $_ -DebugMode $debugMode
    [Console]::CursorVisible = $true
    exit 99
}

# ═══════════════════════════════════════════════════════════════════════
# SETTINGS & VALIDATION
# ═══════════════════════════════════════════════════════════════════════

$ScriptRoot   = $PSScriptRoot
$SettingsPath = Get-SettingsPath
$settings     = Get-ProjectSettings

# Validate config
$configErrors = Test-ProjectSettings -Settings $settings
if ($configErrors.Count -gt 0) {
    Reset-Screen
    Write-BoxHeader -Title 'CONFIGURATION ERRORS' -Color Red
    Write-BoxEmpty -Color Red
    foreach ($err in $configErrors) {
        Write-BoxLine -Text "  $err" -Color Red
    }
    Write-BoxEmpty -Color Red
    Write-BoxFooter -Color Red
    Write-Host
    Write-Host '    Fix Settings.psd1 and restart.'
    exit 1
}

Merge-GlobalAvifQuality -Settings $settings

# ═══════════════════════════════════════════════════════════════════════
# DEPENDENCY CHECKS (unified model)
# ═══════════════════════════════════════════════════════════════════════

$installersDir = Join-Path (Get-ProjectRoot) 'installers'

# FFmpeg
$ok = Test-ToolInstalled `
    -Command 'ffmpeg' `
    -DisplayName 'FFmpeg' `
    -StateKey 'FFmpegChecked' `
    -InstallerScript (Join-Path $installersDir 'ffmpeg-Install.ps1')
if (-not $ok) { exit 1 }

# avifenc
$ok = Test-ToolInstalled `
    -Command 'avifenc' `
    -DisplayName 'avifenc' `
    -StateKey 'AvifencChecked' `
    -InstallerScript (Join-Path $installersDir 'avifenc-Install.ps1')
if (-not $ok) { exit 1 }

# gif2webp
$ok = Test-ToolInstalled `
    -Command 'gif2webp' `
    -DisplayName 'gif2webp' `
    -StateKey 'Gif2WebpChecked' `
    -InstallerScript (Join-Path $installersDir 'gif2webp-Install.ps1')
if (-not $ok) { exit 1 }

function Test-CommandExists {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-OsArch {
    if ($env:PROCESSOR_ARCHITEW6432 -eq 'ARM64' -or $env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {
        return 'arm64'
    }

    if ([Environment]::Is64BitOperatingSystem) {
        return 'x64'
    }

    return 'x86'
}

function Refresh-ProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path    = @($machinePath, $userPath) -join ';'
}

function Download-File {
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [string]$OutFile
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
}

function Get-WinGetPath {
    $cmd = Get-Command 'winget.exe' -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    return $null
}

function Get-LatestPowerShellMsiUrl {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('x64', 'x86', 'arm64')]
        [string]$Arch
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $headers = @{
        'User-Agent' = 'PowerShell-Installer'
    }

    $release = Invoke-RestMethod `
        -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' `
        -Headers $headers `
        -ErrorAction Stop

    $pattern = '^PowerShell-.*-win-{0}\.msi$' -f [Regex]::Escape($Arch)

    $asset = $release.assets |
        Where-Object { $_.name -match $pattern } |
        Select-Object -First 1

    if (-not $asset) {
        throw "Could not find a PowerShell MSI for architecture [$Arch]."
    }

    return $asset.browser_download_url
}

function Install-PowerShell7Direct {
    $arch   = Get-OsArch
    $tmpDir = Join-Path $env:TEMP ("pwsh-install-" + [Guid]::NewGuid().ToString('N'))
    $null   = New-Item -Path $tmpDir -ItemType Directory -Force

    try {
        $msiUrl  = Get-LatestPowerShellMsiUrl -Arch $arch
        $msiPath = Join-Path $tmpDir ("PowerShell-win-{0}.msi" -f $arch)

        Write-Host '    Downloading PowerShell 7 MSI...'
        Download-File -Uri $msiUrl -OutFile $msiPath

        Write-Host '    Installing PowerShell 7...'
        Write-Host

        $proc = Start-Process -FilePath 'msiexec.exe' `
            -ArgumentList "/i `"$msiPath`" /quiet /norestart ADD_PATH=1" `
            -Wait -PassThru

        return $proc.ExitCode
    }
    finally {
        Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Install-WinGet {
    if (Test-CommandExists 'winget.exe') {
        return $true
    }

    if (-not (Get-Command 'Add-AppxPackage' -ErrorAction SilentlyContinue)) {
        return $false
    }

    $arch = Get-OsArch
    $tmpDir = Join-Path $env:TEMP ("winget-install-" + [Guid]::NewGuid().ToString('N'))
    $null = New-Item -Path $tmpDir -ItemType Directory -Force

    $wingetBundle = Join-Path $tmpDir 'Microsoft.DesktopAppInstaller.msixbundle'
    $vclibsPkg    = Join-Path $tmpDir ("Microsoft.VCLibs.{0}.14.00.Desktop.appx" -f $arch)
    $uiXamlPkg    = Join-Path $tmpDir ("Microsoft.UI.Xaml.2.8.{0}.appx" -f $arch)

    $wingetUrl = 'https://aka.ms/getwinget'
    $vclibsUrl = switch ($arch) {
        'x64'   { 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx' }
        'x86'   { 'https://aka.ms/Microsoft.VCLibs.x86.14.00.Desktop.appx' }
        'arm64' { 'https://aka.ms/Microsoft.VCLibs.arm64.14.00.Desktop.appx' }
    }
    $uiXamlUrl = switch ($arch) {
        'x64'   { 'https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.x64.appx' }
        'x86'   { 'https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.x86.appx' }
        'arm64' { 'https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.arm64.appx' }
    }

    try {
        Write-Host '    Downloading WinGet dependencies...'
        Download-File -Uri $vclibsUrl -OutFile $vclibsPkg
        Download-File -Uri $uiXamlUrl -OutFile $uiXamlPkg

        Write-Host '    Downloading WinGet...'
        Download-File -Uri $wingetUrl -OutFile $wingetBundle

        Write-Host '    Installing WinGet...'
        Add-AppxPackage -Path $wingetBundle -DependencyPath @($vclibsPkg, $uiXamlPkg) -ErrorAction Stop

        Refresh-ProcessPath
    }
    catch {
        return $false
    }
    finally {
        Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (Test-CommandExists 'winget.exe') {
        return $true
    }

    Reset-Screen
    Write-BoxMenu -Title '[i] WinGet INSTALLED - RESTART REQUIRED' -Lines @(
        'WinGet was installed successfully.'
        ''
        'Close this console window, open a new one,'
        'and run this script again.'
    )
    Wait-Exit
    exit 0
}

function Ensure-WinGet {
    if (Test-CommandExists 'winget.exe') {
        return $true
    }

    $desktopAppInstaller = $null
    if (Get-Command 'Get-AppxPackage' -ErrorAction SilentlyContinue) {
        $desktopAppInstaller = Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction SilentlyContinue
    }

    if ($desktopAppInstaller) {
        Reset-Screen
        Write-BoxMenu -Title '[i] CONSOLE RESTART REQUIRED' -Lines @(
            'WinGet is already installed, but this console session cannot see it yet.'
            ''
            'Close this console window, open a new one,'
            'and run this script again.'
        )
        Wait-Exit
        exit 0
    }

    Reset-Screen
    Write-BoxMenu -Title '[!] WinGet NOT FOUND' -Lines @(
        'WinGet is required for automatic PowerShell 7 installation.'
        ''
        '[Enter]  Install WinGet automatically'
        '[1]      Install PowerShell 7 directly (without WinGet)'
        '[2]      Exit and install manually'
    )

    $choice = Read-Choice -Prompt 'Your choice [Enter]: ' -Default ''

    if ($choice -eq '1') {
        return $false
    }

    if ($choice -eq '2') {
        Write-Host '    Manual WinGet install: https://aka.ms/getwinget'
        Write-Host '    Manual PowerShell install: https://github.com/PowerShell/PowerShell/releases/latest'
        Wait-Exit
        exit 0
    }

    $ok = Install-WinGet
    if ($ok) {
        return $true
    }

    Reset-Screen
    Write-BoxMenu -Title '[!] WinGet INSTALLATION FAILED' -Lines @(
        'WinGet could not be installed on this system.'
        ''
        'The script can still install PowerShell 7 directly via MSI.'
        ''
        '[Enter]  Continue with direct PowerShell 7 installation'
        '[1]      Exit'
    )

    $fallbackChoice = Read-Choice -Prompt 'Your choice [Enter]: ' -Default ''
    if ($fallbackChoice -eq '1') {
        Wait-Exit
        exit 1
    }

    return $false
}

# ═══════════════════════════════════════════════════════════════════════
# PowerShell 7 bootstrap
# ═══════════════════════════════════════════════════════════════════════

$canUseWinget = Ensure-WinGet

if (-not (Get-Command 'pwsh' -ErrorAction SilentlyContinue)) {
    $installMode = $null

    if ($canUseWinget) {
        Reset-Screen
        Write-BoxMenu -Title '[!] PowerShell 7 NOT FOUND' -Lines @(
            'PowerShell 7 is required for fast file analysis.'
            ''
            '[Enter]  Install via WinGet (recommended)'
            '[1]      Install directly via MSI'
            '[2]      Exit and install manually'
        )

        $choice = Read-Choice -Prompt 'Your choice [Enter]: ' -Default ''

        if ($choice -eq '1') {
            $installMode = 'Direct'
        }
        elseif ($choice -eq '2') {
            Write-Host '    Manual install (WinGet): winget install Microsoft.PowerShell'
            Write-Host '    Manual install (MSI):   https://github.com/PowerShell/PowerShell/releases/latest'
            Wait-Exit
            exit 0
        }
        else {
            $installMode = 'Winget'
        }
    }
    else {
        Reset-Screen
        Write-BoxMenu -Title '[!] PowerShell 7 NOT FOUND' -Lines @(
            'PowerShell 7 is required for fast file analysis.'
            ''
            'WinGet is unavailable on this system.'
            ''
            '[Enter]  Install directly via MSI'
            '[1]      Exit and install manually'
        )

        $choice = Read-Choice -Prompt 'Your choice [Enter]: ' -Default ''

        if ($choice -eq '1') {
            Write-Host '    Manual install: https://github.com/PowerShell/PowerShell/releases/latest'
            Wait-Exit
            exit 0
        }

        $installMode = 'Direct'
    }

    if ($installMode -eq 'Winget') {
        $wingetExe = Get-WinGetPath

        if (-not $wingetExe) {
            Show-InputError 'WinGet is not available in this console session. Restart the console or use direct MSI installation.'
            Wait-Exit
            exit 1
        }

        Write-Host '    Installing PowerShell 7 via WinGet...'
        Write-Host

        $proc = Start-Process -FilePath $wingetExe `
            -ArgumentList 'install Microsoft.PowerShell --accept-source-agreements --accept-package-agreements' `
            -Wait -PassThru -NoNewWindow

        if ($proc.ExitCode -eq 0) {
            Write-Host '    PowerShell 7 installed! Please restart this script.'
            Wait-Exit
            exit 0
        }

        Reset-Screen
        Write-BoxMenu -Title '[!] WinGet INSTALL FAILED' -Lines @(
            'PowerShell 7 installation via WinGet failed.'
            ''
            '[Enter]  Try direct MSI installation instead'
            '[1]      Exit'
        )

        $fallbackChoice = Read-Choice -Prompt 'Your choice [Enter]: ' -Default ''
        if ($fallbackChoice -eq '1') {
            Wait-Exit
            exit 1
        }

        $installMode = 'Direct'
    }

    if ($installMode -eq 'Direct') {
        try {
            $exitCode = Install-PowerShell7Direct
        }
        catch {
            Show-InputError ("Direct installation failed: " + $_.Exception.Message)
            Wait-Exit
            exit 1
        }

        if ($exitCode -ne 0) {
            Show-InputError ('Direct installation failed. Try running as Administrator.')
            Wait-Exit
            exit 1
        }

        Write-Host '    PowerShell 7 installed! Please restart this script.'
        Wait-Exit
        exit 0
    }
}

# ═══════════════════════════════════════════════════════════════════════
# INPUT: INITIAL PATH RESOLUTION (from argument)
# ═══════════════════════════════════════════════════════════════════════

$Folder     = $null
$SingleFile = $null
$folderNote = $null

function Write-InfoBox {
    $innerWidth = 68
    $label      = '  Supported:   '
    $formats    = Get-SupportedFormatsDisplayText
    $maxContent = $innerWidth - $label.Length

    Write-BorderTop -ColWidths $script:BoxCols -Indent $script:BoxIndent

    if ($formats.Length -le $maxContent) {
        Write-BoxLine ($label + $formats)
    }
    else {
        # Split into chunks that fit
        $words = $formats -split ', '
        $currentLine = $label
        $isFirstLine = $true

        foreach ($word in $words) {
            $addition = if ($isFirstLine -and $currentLine -eq $label) { $word } else { ", $word" }

            if (($currentLine + $addition).Length -gt $innerWidth) {
                Write-BoxLine $currentLine
                # Continuation line aligned with first format name
                $currentLine = (' ' * $label.Length) + $word
                $isFirstLine = $false
            }
            else {
                $currentLine += $addition
            }
        }

        if ($currentLine.Trim()) {
            Write-BoxLine $currentLine
        }
    }

    Write-BoxLine '  Output:      AVIF (images) / WebP (animated GIF)'
    Write-BoxFooter
    Write-Host
}

if ($InputPath) {
    if (Test-Path -LiteralPath $InputPath -PathType Container) {
        $Folder = $InputPath
        $folderNote = 'Folder received via argument'
    }
    elseif (Test-Path -LiteralPath $InputPath -PathType Leaf) {
        $ext = [System.IO.Path]::GetExtension($InputPath).ToLowerInvariant()
        if ((Get-SupportedExtensions) -contains $ext) {
            $SingleFile = $InputPath
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# SINGLE FILE: FAST PATH (no retry loop)
# ═══════════════════════════════════════════════════════════════════════

if ($SingleFile) {
    Clear-Host
    Show-Logo

    $analyzeScript = Join-Path $ScriptRoot 'AnalyzeFiles.ps1'
    & pwsh -ExecutionPolicy Bypass -File $analyzeScript -SingleFile $SingleFile

    if ($LASTEXITCODE -ne 0) {
        [Console]::CursorVisible = $true
        exit $LASTEXITCODE
    }

    $analysisTempPath = Join-Path ([System.IO.Path]::GetTempPath()) 'compress_analysis.clixml'
    if (-not (Test-Path -LiteralPath $analysisTempPath)) {
        [Console]::CursorVisible = $true
        exit 0
    }

    $buildScript = Join-Path $ScriptRoot 'BuildEncodingPlan.ps1'
    & pwsh -ExecutionPolicy Bypass -File $buildScript

    if ($LASTEXITCODE -ne 0) {
        [Console]::CursorVisible = $true
        exit $LASTEXITCODE
    }

    $planCheck = Join-Path ([System.IO.Path]::GetTempPath()) 'compress_plan.clixml'
    if (-not (Test-Path -LiteralPath $planCheck)) {
        [Console]::CursorVisible = $true
        exit 0
    }

    $compress = Join-Path $ScriptRoot 'CompressPhotos.ps1'
    & powershell -ExecutionPolicy Bypass -File $compress
    $compressExit = $LASTEXITCODE

    [Console]::CursorVisible = $true
    exit $compressExit
}

# ═══════════════════════════════════════════════════════════════════════
# FOLDER MODE: MAIN LOOP (with retry on empty folder)
# ═══════════════════════════════════════════════════════════════════════

$planTempFile = Join-Path ([System.IO.Path]::GetTempPath()) 'compress_plan.clixml'

while ($true) {

    # ── Folder selection (interactive, if not set via argument) ──
    if (-not $Folder) {
        while ($true) {
            Reset-Screen
            Write-InfoBox
            Write-BoxHeader '[1/2] TARGET FOLDER'
            Write-BoxLine '  Full path to folder with photos. Subfolders included.'
            Write-BoxFooter
            Write-Host

            $raw = Read-Choice -Prompt 'Path: ' -Default ''
            if ([string]::IsNullOrWhiteSpace($raw)) {
                Show-InputError 'Path cannot be empty.'
                continue
            }

            $raw = $raw.Trim('"', "'", ' ')

            if (Test-Path -LiteralPath $raw -PathType Container) {
                $Folder = $raw
                break
            }
            Show-InputError 'Folder not found or is a file.'
        }
    }

    # ── Show folder confirmation (argument mode) ──
    if ($folderNote) {
        Reset-Screen
        Write-InfoBox
        Write-BoxHeader '[1/2] TARGET FOLDER'
        Write-BoxLine "  $folderNote"
        Write-BoxFooter
        Write-Host
        Write-Host "    Path: $Folder"
        Write-Host
    }

    # ── Resume plan check ──
    $resumeChosen = $false

    $resumePlanPath = Join-Path $Folder 'EncodingPlan_Resume.clixml'
    if (Test-Path -LiteralPath $resumePlanPath) {
        Reset-Screen
        Write-BoxMenu -Title 'RESUME PLAN FOUND' -Lines @(
            'A previous encoding session was interrupted.'
            'Resume plan is saved in the target folder.'
            ''
            '[Enter]  Resume previous session'
            '[1]      Start over (new plan)'
        )

        $resumeKey = Read-MenuKey -AllowedKeys @('Enter', '1')

        if ($resumeKey -eq 'Enter') {
            $resumeChosen = $true
        }
        else {
            Remove-Item -LiteralPath $resumePlanPath -Force -ErrorAction SilentlyContinue
        }
    }

# ═══════════════════════════════════════════════════════════════════════
# RESUME: FAST PATH
# ═══════════════════════════════════════════════════════════════════════

    if ($resumeChosen) {
        Clear-Host
        [Console]::CursorVisible = $false
        Show-Logo

        $plan = Import-Clixml -LiteralPath $resumePlanPath
        $plan.PlanFile = $planTempFile
        $plan | Export-Clixml -LiteralPath $planTempFile -Force

        Write-BoxTitleOnly "Resuming $($plan.Tasks.Count) tasks..."
        Write-Host
        Start-Sleep -Seconds 2

        $compress = Join-Path $ScriptRoot 'CompressPhotos.ps1'
        & powershell -ExecutionPolicy Bypass -File $compress
        $compressExit = $LASTEXITCODE

        [Console]::CursorVisible = $true
        exit $compressExit
    }

# ═══════════════════════════════════════════════════════════════════════
# PROCESSING MODE
# ═══════════════════════════════════════════════════════════════════════
	
	Reset-Screen
	Write-BoxMenu -Title '[2/2] PROCESSING MODE' -Lines @(
		'[Enter]  Quick start (default settings from Settings.psd1)'
		''
		'[1]      Custom settings'
		'         Override delete policy'
	)

	Write-Host -NoNewline '        Mode [Quick]: '
	$promptY = $Host.UI.RawUI.CursorPosition.Y

	$modeKey = Read-TimedMenuKey `
		-AllowedKeys @('Enter', '1') `
		-Default 'Enter' `
		-TimeoutSec 3 `
		-CountdownX 3 `
		-CountdownY $promptY

	Write-Host

	$ExtraArgs = @()

# ═══════════════════════════════════════════════════════════════════════
# CUSTOM SETTINGS
# ═══════════════════════════════════════════════════════════════════════

    if ($modeKey -eq '1') {
    # ── 1. Pixel format ──
        $pf = Read-ValidatedChoice `
            -MenuTitle 'PIXEL FORMAT (FFmpeg)' `
            -MenuLines @(
                '[1]  yuv444p (default) - preserves color, safer for graphics'
                '[2]  yuv420p - standard, slightly smaller files'
            ) `
            -Prompt 'PixFmt [1]: ' `
            -Default '1' `
            -ValidValues @('1', '2') `
            -ErrorMessage 'Enter 1, 2 or press Enter.'
        $CustomPixFmt = if ($pf -eq '2') { 'yuv420p' } else { 'yuv444p' }

    # ── 2. AVIF Quality ──
        $CustomAvifQ = Read-ValidatedNumber `
            -MenuTitle 'AVIF QUALITY (avifenc -q)' `
            -MenuLines @(
                'Range: 0-100 (lower = smaller file, more artifacts)'
                ''
                '55 - good for photos'
                '65 - better for detailed graphics (default)'
            ) `
            -Prompt 'Quality [65]: ' `
            -Default 65 -Min 0 -Max 100

    # ── 3. AVIF Speed ──
        $CustomAvifS = Read-ValidatedNumber `
            -MenuTitle 'AVIF SPEED (avifenc -s)' `
            -MenuLines @(
                'Range: 0-10 (higher = faster, larger file)'
                ''
                '6 - default'
                '5 - optimal for detail preservation'
            ) `
            -Prompt 'Speed [6]: ' `
            -Default 6 -Min 0 -Max 10

    # ── 4. Sharpness ──
        $CustomSharpness = Read-ValidatedNumber `
            -MenuTitle 'AVIF SHARPNESS (avifenc -a color:sharpness)' `
            -MenuLines @(
                'Range: 0-7 (higher = sharper edges)'
                'Values above 2 may introduce ringing artifacts'
                ''
                'Default: 2'
            ) `
            -Prompt 'Sharpness [2]: ' `
            -Default 2 -Min 0 -Max 7

    # ── 5. Alpha Quality ──
        $CustomQAlpha = Read-ValidatedNumber `
            -MenuTitle 'ALPHA QUALITY (avifenc --qalpha)' `
            -MenuLines @(
                'Range: 0-100 (higher = better alpha preservation)'
                'Recommended: 60-100'
                ''
                'Default: 80'
            ) `
            -Prompt 'QAlpha [80]: ' `
            -Default 80 -Min 0 -Max 100

    # ── 6. WebP Quality ──
        $CustomWebpQ = Read-ValidatedNumber `
            -MenuTitle 'WEBP QUALITY (animated GIF conversion)' `
            -MenuLines @(
                'Range: 0-100'
                '80 - optimal balance (default)'
            ) `
            -Prompt 'WebP Quality [80]: ' `
            -Default 80 -Min 0 -Max 100

    # ── 7. WebP Compression ──
        $CustomWebpCL = Read-ValidatedNumber `
            -MenuTitle 'WEBP COMPRESSION LEVEL' `
            -MenuLines @(
                'Range: 1-6 (higher = better compression, slower)'
                'Default: 6'
            ) `
            -Prompt 'Compression [6]: ' `
            -Default 6 -Min 1 -Max 6

    # ── 8. Delete originals ──
        $dc = Read-ValidatedChoice `
            -MenuTitle 'DELETE ORIGINALS' `
            -MenuLines @(
                'After successful conversion, original file can be'
                'moved to RECYCLE BIN (recoverable).'
                ''
                '[Enter]  Yes, move to recycle bin (default)'
                '[1]      No, keep originals'
            ) `
            -Prompt 'Delete originals? [Yes]: ' `
            -Default '0' `
            -ValidValues @('0', '1') `
            -ErrorMessage 'Enter 1 or press Enter.'

        $DelFlag = if ($dc -eq '0') { '-DeleteOriginal' } else { '' }

    # ── Write custom config ──
        $CustomCfg = Join-Path $env:TEMP 'avif_custom_config.txt'
        @(
            "PIXFMT=$CustomPixFmt"
            "AVIF_Q=$CustomAvifQ"
            "AVIF_S=$CustomAvifS"
            "SHARPNESS=$CustomSharpness"
            "QALPHA=$CustomQAlpha"
            "WEBP_Q=$CustomWebpQ"
            "WEBP_CL=$CustomWebpCL"
        ) | Set-Content -LiteralPath $CustomCfg -Encoding UTF8

        if ($DelFlag) { $ExtraArgs += $DelFlag }
        $ExtraArgs += '-CustomConfig'
        $ExtraArgs += $CustomCfg
    }
# ═══════════════════════════════════════════════════════════════════════
# START PROCESSING
# ═══════════════════════════════════════════════════════════════════════

    # ── Stage 1: Analyze ──
    Clear-Host
    [Console]::CursorVisible = $false
    Show-Logo

    Write-BoxTitleOnly 'FOLDER CONTENTS'
    Write-Host

    $analyzeScript = Join-Path $ScriptRoot 'AnalyzeFiles.ps1'
    $analyzeArgs = @('-ExecutionPolicy', 'Bypass', '-File', $analyzeScript, '-TargetFolder', $Folder) + $ExtraArgs

    & pwsh @analyzeArgs

    $analysisTempPath = Join-Path ([System.IO.Path]::GetTempPath()) 'compress_analysis.clixml'

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $analysisTempPath)) {
        $Folder = $null
        $folderNote = $null
        Write-Host
        Write-Host '    Press any key to select another folder...'
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        continue
    }

    # ── Stage 2: Build plan ──
    $buildScript = Join-Path $ScriptRoot 'BuildEncodingPlan.ps1'
    & pwsh -ExecutionPolicy Bypass -File $buildScript

    $planCheck = Join-Path ([System.IO.Path]::GetTempPath()) 'compress_plan.clixml'

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $planCheck)) {
        $Folder = $null
        $folderNote = $null
        Write-Host
        Write-Host '    Press any key to select another folder...'
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        continue
    }

    # ── Stage 3: Compress ──
    Write-Host
    Write-BoxTitleOnly 'Starting in 3 seconds...'
    Start-Sleep -Seconds 3

    $compress = Join-Path $ScriptRoot 'CompressPhotos.ps1'
    & powershell -ExecutionPolicy Bypass -File $compress
    $compressExit = $LASTEXITCODE

    [Console]::CursorVisible = $true
    exit $compressExit
}