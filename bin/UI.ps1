# UI.ps1
# Unified UI module for AVIF Compressor
# All console output: logo, tables, menus, input, progress, summaries

# ═══════════════════════════════════════════════════════════════════════
# LOGO
# ═══════════════════════════════════════════════════════════════════════

function Show-Logo {
    Write-Host ""
    Write-Host "  ╔════════════════════════════════════════════════════════════════════╗" -ForegroundColor DarkCyan
    Write-Host "  ║                                                                    ║" -ForegroundColor DarkCyan
    Write-Host "  ║     " -NoNewline -ForegroundColor DarkCyan
    Write-Host "█████╗ ██╗   ██╗██╗███████╗" -NoNewline -ForegroundColor Cyan
    Write-Host "                                    ║" -ForegroundColor DarkCyan
    Write-Host "  ║    " -NoNewline -ForegroundColor DarkCyan
    Write-Host "██╔══██╗██║   ██║██║██╔════╝" -NoNewline -ForegroundColor Cyan
    Write-Host "                                    ║" -ForegroundColor DarkCyan
    Write-Host "  ║    " -NoNewline -ForegroundColor DarkCyan
    Write-Host "███████║██║   ██║██║█████╗" -NoNewline -ForegroundColor Cyan
    Write-Host "                                      ║" -ForegroundColor DarkCyan
    Write-Host "  ║    " -NoNewline -ForegroundColor DarkCyan
    Write-Host "██╔══██║╚██╗ ██╔╝██║██╔══╝" -NoNewline -ForegroundColor Cyan
    Write-Host "                                      ║" -ForegroundColor DarkCyan
    Write-Host "  ║    " -NoNewline -ForegroundColor DarkCyan
    Write-Host "██║  ██║ ╚████╔╝ ██║██║" -NoNewline -ForegroundColor Cyan
    Write-Host "                                         ║" -ForegroundColor DarkCyan
    Write-Host "  ║    " -NoNewline -ForegroundColor DarkCyan
    Write-Host "╚═╝  ╚═╝  ╚═══╝  ╚═╝╚═╝" -NoNewline -ForegroundColor Cyan
    Write-Host "  " -NoNewline
    Write-Host "COMPRESSOR" -NoNewline -ForegroundColor White
    Write-Host "                             ║" -ForegroundColor DarkCyan
    Write-Host "  ║                                                                    ║" -ForegroundColor DarkCyan
    Write-Host "  ╚════════════════════════════════════════════════════════════════════╝" -ForegroundColor DarkCyan
    Write-Host ""
}

function Reset-Screen {
    Clear-Host
    Show-Logo
}

# ═══════════════════════════════════════════════════════════════════════
# TABLE PRIMITIVES
# ═══════════════════════════════════════════════════════════════════════

$script:BoxCols   = @(68)
$script:BoxIndent = 2
$script:BoxColor  = 'Gray'

function Write-Border {
    <#  ┌─────────────┐  #>
    param(
        [int[]]$ColWidths,
        [int]$Indent = 2,
        [string]$Color = 'Gray',
        [string]$Left = '┌',
        [string]$Mid = '┬',
        [string]$Right = '┐'
    )
    $parts = $ColWidths | ForEach-Object { '─' * $_ }
    Write-Host ((' ' * $Indent) + $Left + ($parts -join $Mid) + $Right) -ForegroundColor $Color
}

function Write-BorderTop {
    <#  ┌──────┬──────┐  #>
    param(
        [int[]]$ColWidths,
        [int]$Indent = 2,
        [string]$Color = 'Gray'
    )
    Write-Border -ColWidths $ColWidths -Indent $Indent -Color $Color -Left '┌' -Mid '┬' -Right '┐'
}

function Write-BorderMid {
    param(
        [int[]]$ColWidths,
        [int]$Indent = 2,
        [string]$Color = 'Gray'
    )
    Write-Border -ColWidths $ColWidths -Indent $Indent -Color $Color -Left '├' -Mid '┼' -Right '┤'
}

function Write-BorderBot {
    <#  └──────┴──────┘  #>
    param(
        [int[]]$ColWidths,
        [int]$Indent = 2,
        [string]$Color = 'Gray'
    )
    Write-Border -ColWidths $ColWidths -Indent $Indent -Color $Color -Left '└' -Mid '┴' -Right '┘'
}

# ═══════════════════════════════════════════════════════════════════════
# SINGLE-COLUMN BOX
# ═══════════════════════════════════════════════════════════════════════

function Write-BoxLine {
    <#  │  text                        │  #>
    param(
        [string]$Text = '',
        [string]$Color = $script:BoxColor
    )
    $inner = 68
    $padded = $Text.PadRight($inner)
    if ($padded.Length -gt $inner) { $padded = $padded.Substring(0, $inner) }
    Write-Host "  │${padded}│" -ForegroundColor $Color
}

function Write-BoxEmpty {
    param([string]$Color = $script:BoxColor)
    Write-BoxLine -Text '' -Color $Color
}

function Write-BoxValueLine {
    <#  │  Label:       Value          │  #>
    param(
        [string]$Label,
        [string]$Value,
        [string]$ValueColor = 'White',
        [string]$BorderColor = $script:BoxColor
    )
    $labelWidth = 16
    $valueWidth = 52
    $maxVisible = $valueWidth - 3

    $labelPart = "  $Label".PadRight($labelWidth)
    if ($labelPart.Length -gt $labelWidth) { $labelPart = $labelPart.Substring(0, $labelWidth) }

    $valuePart = $Value
    if ($valuePart.Length -gt $maxVisible) {
        $valuePart = '...' + $valuePart.Substring($valuePart.Length - ($maxVisible - 3))
    }
    $valuePart = $valuePart.PadRight($valueWidth)

    Write-Host "  │" -NoNewline -ForegroundColor $BorderColor
    Write-Host $labelPart -NoNewline -ForegroundColor $BorderColor
    Write-Host $valuePart -NoNewline -ForegroundColor $ValueColor
    Write-Host "│" -ForegroundColor $BorderColor
}

# ═══════════════════════════════════════════════════════════════════════
# COMPOSITE BOX BUILDERS
# ═══════════════════════════════════════════════════════════════════════

function Write-BoxHeader {
    <#
        ┌──────────────────────────────┐
        │  Title                       │
        ├──────────────────────────────┤
    #>
    param(
        [string]$Title,
        [string]$Color = $script:BoxColor
    )
    Write-BorderTop -ColWidths $script:BoxCols -Indent $script:BoxIndent -Color $Color
    Write-BoxLine -Text "  $Title" -Color $Color
    Write-BorderMid -ColWidths $script:BoxCols -Indent $script:BoxIndent -Color $Color
}

function Write-BoxTitleOnly {
    <#
        ┌──────────────────────────────┐
        │  Title                       │
        └──────────────────────────────┘
    #>
    param(
        [string]$Title,
        [string]$Color = $script:BoxColor
    )
    Write-BorderTop -ColWidths $script:BoxCols -Indent $script:BoxIndent -Color $Color
    Write-BoxLine -Text "  $Title" -Color $Color
    Write-BorderBot -ColWidths $script:BoxCols -Indent $script:BoxIndent -Color $Color
}

function Write-BoxFooter {
    <#  └──────────────────────────────┘  #>
    param([string]$Color = $script:BoxColor)
    Write-BorderBot -ColWidths $script:BoxCols -Indent $script:BoxIndent -Color $Color
}

function Write-BoxMenu {
    <#
        ┌──────────────────────────────┐
        │  Title                       │
        ├──────────────────────────────┤
        │                              │
        │  Line 1                      │
        │  Line 2                      │
        │                              │
        └──────────────────────────────┘
    #>
    param(
        [string]$Title,
        [string[]]$Lines,
        [string]$Color = $script:BoxColor
    )
    Write-BoxHeader -Title $Title -Color $Color
    Write-BoxEmpty -Color $Color
    foreach ($line in $Lines) {
        Write-BoxLine -Text "  $line" -Color $Color
    }
    Write-BoxEmpty -Color $Color
    Write-BoxFooter -Color $Color
    Write-Host
}

# ═══════════════════════════════════════════════════════════════════════
# EXTENSION TABLE (3-column)
# ═══════════════════════════════════════════════════════════════════════

$script:ExtCols   = @(30, 12, 22)
$script:ExtIndent = 3
$script:ExtColor  = 'DarkGray'

function Write-ExtTableRow {
    param(
        [string]$Name,
        $Count,
        [string]$Status,
        [string]$NameColor = 'White',
        [string]$CountColor = 'White',
        [string]$StatusColor = 'White',
        [switch]$IsHeader
    )
    $extRaw = $Name
    if ($extRaw.Length -gt 28) { $extRaw = $extRaw.Substring(0, 25) + '...' }
    $ext = $extRaw.PadRight(28)

    $cnt = if ($IsHeader) {
        $Count.ToString().PadRight(10)
    }
    elseif ($null -ne $Count) {
        $Count.ToString().PadLeft(8) + '  '
    }
    else {
        ''.PadRight(10)
    }

    $st = $Status.PadRight(20)

    Write-Host '   │  ' -NoNewline -ForegroundColor $script:ExtColor
    Write-Host $ext -NoNewline -ForegroundColor $NameColor
    Write-Host '│  ' -NoNewline -ForegroundColor $script:ExtColor
    Write-Host $cnt -NoNewline -ForegroundColor $CountColor
    Write-Host '│  ' -NoNewline -ForegroundColor $script:ExtColor
    Write-Host $st -NoNewline -ForegroundColor $StatusColor
    Write-Host '│' -ForegroundColor $script:ExtColor
}

function Write-ExtensionTable {
    param(
        [array]$CompressGroups,
        [array]$AvifGroups,
        [array]$SkipGroups,
        [int]$MaxSkipShow = 10
    )

    #  ┌──────────────────────────────┬────────────┬──────────────────────┐
    Write-BorderTop -ColWidths $script:ExtCols -Indent $script:ExtIndent -Color $script:ExtColor
    Write-ExtTableRow -Name 'Extension' -Count 'Count' -Status 'Status' `
        -NameColor $script:ExtColor -CountColor $script:ExtColor -StatusColor $script:ExtColor -IsHeader
    #  ├──────────────────────────────┼────────────┼──────────────────────┤
    Write-BorderMid -ColWidths $script:ExtCols -Indent $script:ExtIndent -Color $script:ExtColor

    foreach ($g in $CompressGroups) {
        Write-ExtTableRow -Name $g.Name -Count $g.Count -Status 'Supported' `
            -NameColor White -CountColor White -StatusColor Green
    }
    foreach ($g in $AvifGroups) {
        Write-ExtTableRow -Name $g.Name -Count $g.Count -Status 'Already AVIF' `
            -NameColor White -CountColor White -StatusColor DarkYellow
    }

    $skipDisplayed = 0
    $hiddenExts = 0
    $hiddenFiles = 0
    foreach ($g in $SkipGroups) {
        if ($skipDisplayed -lt $MaxSkipShow) {
            Write-ExtTableRow -Name $g.Name -Count $g.Count -Status 'Not supported' `
                -NameColor DarkGray -CountColor DarkGray -StatusColor DarkGray
        }
        else {
            $hiddenExts++
            $hiddenFiles += $g.Count
        }
        $skipDisplayed++
    }

    if ($hiddenExts -gt 0) {
        $summaryText = "... +$hiddenExts ext ($hiddenFiles files)"
        if ($summaryText.Length -gt 28) { $summaryText = $summaryText.Substring(0, 28) }
        Write-ExtTableRow -Name $summaryText -Count $null -Status 'Not supported' `
            -NameColor DarkGray -CountColor DarkGray -StatusColor DarkGray
    }

    #  └──────────────────────────────┴────────────┴──────────────────────┘
    Write-BorderBot -ColWidths $script:ExtCols -Indent $script:ExtIndent -Color $script:ExtColor
    Write-Host
}

# ═══════════════════════════════════════════════════════════════════════
# INPUT HELPERS
# ═══════════════════════════════════════════════════════════════════════

function Show-InputError {
    param([string]$Message)
    Write-Host
    Write-Host "    [!] $Message" -ForegroundColor Yellow
    Start-Sleep -Milliseconds 1500
}

function Read-Choice {
    param(
        [string]$Prompt,
        [string]$Default = ''
    )
    Write-Host -NoNewline "    $Prompt"
    $result = Read-Host
    if ([string]::IsNullOrWhiteSpace($result)) { return $Default }
    return $result.Trim()
}

function Read-ValidatedChoice {
    param(
        [string]$MenuTitle,
        [string[]]$MenuLines,
        [string]$Prompt,
        [string]$Default,
        [string[]]$ValidValues,
        [string]$ErrorMessage
    )
    while ($true) {
        Reset-Screen
        Write-BoxMenu -Title $MenuTitle -Lines $MenuLines
        $choice = Read-Choice -Prompt $Prompt -Default $Default
        if ($choice -in $ValidValues) { return $choice }
        Show-InputError $ErrorMessage
    }
}

function Read-ValidatedNumber {
    param(
        [string]$MenuTitle,
        [string[]]$MenuLines,
        [string]$Prompt,
        [int]$Default,
        [int]$Min,
        [int]$Max
    )
    while ($true) {
        Reset-Screen
        Write-BoxMenu -Title $MenuTitle -Lines $MenuLines
        $raw = Read-Choice -Prompt $Prompt -Default "$Default"
        if ($raw -match '^\d+$') {
            $num = [int]$raw
            if ($num -ge $Min -and $num -le $Max) { return $num }
        }
        Show-InputError "Enter a number ${Min}-${Max}."
    }
}

function Wait-Exit {
    param([string]$Message = '    Press any key to exit.')
    Write-Host
    Write-Host $Message
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}

# ═══════════════════════════════════════════════════════════════════════
# KEY-BASED MENU INPUT
# ═══════════════════════════════════════════════════════════════════════

function Read-MenuKey {
    <#
    .SYNOPSIS
    Waits for one keypress from a fixed set of allowed keys.
    Supports Enter, digit keys (main keyboard + NumPad), letter keys.
    Returns normalized string: 'Enter', '1', '2', 'Q', etc.
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$AllowedKeys
    )

    while ($true) {
        $keyInfo = [Console]::ReadKey($true)
        $normalized = Convert-KeyName -KeyInfo $keyInfo

        if ($AllowedKeys -contains $normalized) {
            return $normalized
        }
    }
}

function Read-TimedMenuKey {
    <#
    .SYNOPSIS
    Waits for keypress with auto-timeout. Returns default if time expires.
    Shows countdown at specified screen position.
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$AllowedKeys,

        [Parameter(Mandatory)]
        [string]$Default,

        [int]$TimeoutSec = 3,
        [int]$CountdownX = 4,
        [int]$CountdownY = -1
    )

    if ($CountdownY -lt 0) {
        $CountdownY = $Host.UI.RawUI.CursorPosition.Y
    }

    $deadline = [DateTime]::Now.AddSeconds($TimeoutSec)

    while ([DateTime]::Now -lt $deadline) {
        $remaining = [Math]::Ceiling(($deadline - [DateTime]::Now).TotalSeconds)
        if ($remaining -lt 0) { $remaining = 0 }

        # Update countdown
        $Host.UI.RawUI.CursorPosition = @{ X = $CountdownX; Y = $CountdownY }
        Write-Host "[$remaining] " -NoNewline -ForegroundColor DarkGray

        if ([Console]::KeyAvailable) {
            $keyInfo = [Console]::ReadKey($true)
            $normalized = Convert-KeyName -KeyInfo $keyInfo

            if ($AllowedKeys -contains $normalized) {
                # Clear countdown
                $Host.UI.RawUI.CursorPosition = @{ X = $CountdownX; Y = $CountdownY }
                Write-Host '    ' -NoNewline
                return $normalized
            }

            # Invalid key — reset timer
            $deadline = [DateTime]::Now.AddSeconds($TimeoutSec)
        }

        Start-Sleep -Milliseconds 100
    }

    # Clear countdown
    $Host.UI.RawUI.CursorPosition = @{ X = $CountdownX; Y = $CountdownY }
    Write-Host '    ' -NoNewline

    return $Default
}

function Convert-KeyName {
    <#
    .SYNOPSIS
    Normalizes ConsoleKeyInfo to simple string.
    D0-D9 and NumPad0-NumPad9 → '0'-'9'
    Enter → 'Enter'
    Letters → uppercase letter
    #>
    param([System.ConsoleKeyInfo]$KeyInfo)

    $keyName = $KeyInfo.Key.ToString()

    # Enter
    if ($keyName -eq 'Enter') { return 'Enter' }

    # Digits: D0-D9
    if ($keyName -match '^D(\d)$') { return $Matches[1] }

    # Digits: NumPad0-NumPad9
    if ($keyName -match '^NumPad(\d)$') { return $Matches[1] }

    # Letters
    if ($keyName.Length -eq 1 -and $keyName -match '[A-Z]') { return $keyName }

    # Fallback
    return $keyName
}

# ═══════════════════════════════════════════════════════════════════════
# ANALYSIS STATUS
# ═══════════════════════════════════════════════════════════════════════

function Write-AnalysisBox {
    param(
        [int]$FileCount,
        [int]$Threads
    )

    $leftText  = "  Analyzing $FileCount files"
    $rightText = "Threads: $Threads  "
    $innerWidth = 68
    $padding = $innerWidth - $leftText.Length - $rightText.Length
    if ($padding -lt 1) { $padding = 1 }

    $line = $leftText + (' ' * $padding) + $rightText

    Write-BorderTop -ColWidths $script:BoxCols -Indent $script:BoxIndent
    Write-BoxLine -Text $line
    Write-BorderBot -ColWidths $script:BoxCols -Indent $script:BoxIndent
    Write-Host
}

function Write-AnalysisComplete {
    <#
    .SYNOPSIS
    Displays analysis completion status.
    #>
    param([int]$FileCount)

    Write-BorderTop -ColWidths $script:BoxCols -Indent $script:BoxIndent
    Write-BoxLine -Text "  Analysis complete: $FileCount files ready for encoding"
    Write-BorderBot -ColWidths $script:BoxCols -Indent $script:BoxIndent
    Write-Host
}

# ═══════════════════════════════════════════════════════════════════════
# PLAN SUMMARY
# ═══════════════════════════════════════════════════════════════════════

function Write-PlanSummary {
    param(
        [PSCustomObject]$Summary,
        [hashtable]$SkipReasons
    )

    Write-BoxHeader 'ENCODING PLAN'
    Write-BoxEmpty
    Write-BoxValueLine -Label 'Found:'     -Value "$($Summary.TotalFiles) files" -ValueColor White
    Write-BoxValueLine -Label 'Supported:' -Value "$($Summary.SupportedFiles)"   -ValueColor White
    Write-BoxValueLine -Label 'To encode:' -Value "$($Summary.TasksCount)"       -ValueColor Cyan

    if ($Summary.StaticCount -gt 0) {
        Write-BoxValueLine -Label '  Static:' -Value "$($Summary.StaticCount) → AVIF" -ValueColor Green
    }
    if ($Summary.AnimatedGifCount -gt 0) {
        Write-BoxValueLine -Label '  Animated:' -Value "$($Summary.AnimatedGifCount) → WebP" -ValueColor Green
    }
    if ($Summary.AlphaCount -gt 0) {
        Write-BoxValueLine -Label '  Alpha:' -Value "$($Summary.AlphaCount)" -ValueColor DarkYellow
    }
    if ($Summary.SkippedCount -gt 0) {
        Write-BoxValueLine -Label 'Skipped:' -Value "$($Summary.SkippedCount)" -ValueColor DarkYellow
    }
    if ($SkipReasons -and $SkipReasons['Corrupt'] -gt 0) {
        Write-BoxValueLine -Label '  Corrupt:' -Value "$($SkipReasons['Corrupt']) (→ _corrupt)" -ValueColor Red
    }
    if ($SkipReasons -and $SkipReasons['UnsupportedMetadata'] -gt 0) {
        Write-BoxValueLine -Label '  No metadata:' -Value "$($SkipReasons['UnsupportedMetadata']) (→ warnings.log)" -ValueColor DarkYellow
    }
    if ($SkipReasons -and $SkipReasons['Unreadable'] -gt 0) {
        Write-BoxValueLine -Label '  Unreadable:' -Value "$($SkipReasons['Unreadable']) (not moved, → warnings.log)" -ValueColor DarkYellow
    }
    Write-BoxEmpty
    Write-BoxFooter
}

# ═══════════════════════════════════════════════════════════════════════
# EXECUTION UI
# ═══════════════════════════════════════════════════════════════════════

function Write-ExecutionHeader {
    <#
    .SYNOPSIS
    Shows execution header with plan info.
    Stop hint shown only in folder mode.
    #>
    param(
        [PSCustomObject]$Plan,
        [bool]$ShowStopHint = $true
    )

    $delText = if ($Plan.PlanOptions.DeleteOriginals) { 'Yes (Recycle Bin)' } else { 'No' }

    Write-BoxHeader 'EXECUTING PLAN'
    Write-BoxEmpty
    Write-BoxValueLine -Label 'Mode:'       -Value $Plan.Mode                                    -ValueColor White
    Write-BoxValueLine -Label 'Source:'     -Value $Plan.SourceRoot                               -ValueColor White
    Write-BoxValueLine -Label 'Max time:'   -Value "$($Plan.PlanOptions.TimeoutSec) sec per file" -ValueColor White
    Write-BoxValueLine -Label 'Delete src:' -Value $delText                                       -ValueColor White
    if ($Plan.PlanOptions.DeleteOriginalsNote) {
        Write-BoxValueLine -Label '  Note:' -Value $Plan.PlanOptions.DeleteOriginalsNote -ValueColor DarkYellow
    }
    Write-BoxEmpty
    Write-BoxFooter
    Write-Host

    if ($ShowStopHint) {
        $leftText  = '  PROCESSING'
        $rightText = 'Press Q to stop  '
        $innerWidth = 68
        $padding = $innerWidth - $leftText.Length - $rightText.Length
        if ($padding -lt 1) { $padding = 1 }

        Write-BorderTop -ColWidths $script:BoxCols -Indent $script:BoxIndent

        Write-Host "  │" -NoNewline -ForegroundColor Gray
        Write-Host ($leftText + (' ' * ($padding))) -NoNewline -ForegroundColor Gray
        Write-Host $rightText -NoNewline -ForegroundColor Yellow
        Write-Host "│" -ForegroundColor Gray

        Write-BoxFooter
    }
    else {
        Write-BoxTitleOnly 'PROCESSING'
    }
}

# ═══════════════════════════════════════════════════════════════════════
# PROGRESS BAR
# ═══════════════════════════════════════════════════════════════════════
<# 
function Show-Progress {
    param(
        [int]$Current,
        [int]$Total,
        [int]$Success,
        [int]$Errors,
        [int]$Skipped,
        [int]$Running,
        [int]$BaseY,
        [bool]$StopRequested = $false
    )

    if ($null -eq $BaseY -or $BaseY -lt 0) { return }

    # Layout: must fit within box width
    # Box: indent(2) + border(1) + content(68) + border(1) = 72
    # Progress uses indent(6), so content width = 72 - 6 = 66
    $indent       = 3
    $contentWidth = 69
    $clearWidth   = 72 + 2  # clear a bit extra
    $clearStr     = ' ' * $clearWidth

    $safeTotal   = [math]::Max(1, $Total)
    $safeCurrent = [math]::Max(0, [math]::Min($Current, $safeTotal))
    $percent     = [math]::Floor(($safeCurrent * 100) / $safeTotal)

    $statsText = "$percent% ($Current / $Total)"
    $statsLen  = $statsText.Length
    $minGap    = 2

    # Bar takes whatever space remains after stats + gap
    $barWidth = $contentWidth - $statsLen - $minGap
    if ($barWidth -lt 10) { $barWidth = 10 }

    $filled = [math]::Floor(($barWidth * $safeCurrent) / $safeTotal)
    $empty  = $barWidth - $filled
    $filled = [math]::Max(0, [math]::Min($filled, $barWidth))
    $empty  = [math]::Max(0, [math]::Min($empty, $barWidth))

    $bar    = ([string][char]0x2588 * $filled) + ([string][char]0x2591 * $empty)
    $spacer = ' ' * ($contentWidth - $barWidth - $statsLen)

    # Row 0: empty
    $Host.UI.RawUI.CursorPosition = @{ X = 0; Y = $BaseY }
    Write-Host $clearStr -NoNewline

    # Row 1: bar + stats
    $Host.UI.RawUI.CursorPosition = @{ X = 0; Y = $BaseY + 1 }
    Write-Host $clearStr -NoNewline
    $Host.UI.RawUI.CursorPosition = @{ X = 0; Y = $BaseY + 1 }
    Write-Host (' ' * $indent) -NoNewline
    Write-Host $bar -NoNewline -ForegroundColor Cyan
    Write-Host $spacer -NoNewline
    Write-Host $statsText -ForegroundColor White

    # Row 2: empty
    $Host.UI.RawUI.CursorPosition = @{ X = 0; Y = $BaseY + 2 }
    Write-Host $clearStr -NoNewline

    # Row 3: counters
    $Host.UI.RawUI.CursorPosition = @{ X = 0; Y = $BaseY + 3 }
    Write-Host $clearStr -NoNewline
    $Host.UI.RawUI.CursorPosition = @{ X = 0; Y = $BaseY + 3 }
    Write-Host (' ' * $indent) -NoNewline
    Write-Host 'OK: ' -NoNewline -ForegroundColor DarkGray
    Write-Host "$Success".PadRight(8) -NoNewline -ForegroundColor Green
    Write-Host 'Skip: ' -NoNewline -ForegroundColor DarkGray
    Write-Host "$Skipped".PadRight(8) -NoNewline -ForegroundColor Yellow
    Write-Host 'Err: ' -NoNewline -ForegroundColor DarkGray
    Write-Host "$Errors".PadRight(8) -NoNewline -ForegroundColor Red
    Write-Host 'Active: ' -NoNewline -ForegroundColor DarkGray
    Write-Host "$Running" -ForegroundColor Cyan

    # Row 4: stop status
    $Host.UI.RawUI.CursorPosition = @{ X = 0; Y = $BaseY + 4 }
    Write-Host $clearStr -NoNewline
    if ($StopRequested) {
        $Host.UI.RawUI.CursorPosition = @{ X = 0; Y = $BaseY + 4 }
        Write-Host '     [Q] Stopping... waiting for active tasks' -ForegroundColor Yellow
    }

    # Park cursor
    $Host.UI.RawUI.CursorPosition = @{ X = 0; Y = $BaseY + 5 }
}
 #>

$script:LastProgressState = ''

function Show-Progress {
    param(
        [int]$Current,
        [int]$Total,
        [int]$Success,
        [int]$Errors,
        [int]$Skipped,
        [int]$Running,
        [int]$BaseY,
        [bool]$StopRequested = $false,
        [switch]$Force
    )

    if ($null -eq $BaseY -or $BaseY -lt 0) { return }

    # ── Cache check: skip if nothing changed ──
    $stateKey = '{0}|{1}|{2}|{3}|{4}|{5}' -f $Current, $Success, $Errors, $Skipped, $Running, $StopRequested

    if (-not $Force -and $stateKey -eq $script:LastProgressState) { return }
    $script:LastProgressState = $stateKey

    # ── Calculate bar ──
    $indent       = 5
    $contentWidth = 65

    $safeTotal   = [math]::Max(1, $Total)
    $safeCurrent = [math]::Max(0, [math]::Min($Current, $safeTotal))
    $percent     = [math]::Floor(($safeCurrent * 100) / $safeTotal)

    $statsText = "$percent% ($Current / $Total)"
    $statsLen  = $statsText.Length
    $minGap    = 2

    $barWidth = $contentWidth - $statsLen - $minGap
    if ($barWidth -lt 10) { $barWidth = 10 }

    $filled = [math]::Floor(($barWidth * $safeCurrent) / $safeTotal)
    $empty  = $barWidth - $filled
    $filled = [math]::Max(0, [math]::Min($filled, $barWidth))
    $empty  = [math]::Max(0, [math]::Min($empty, $barWidth))

    $bar    = ([string][char]0x2588 * $filled) + ([string][char]0x2591 * $empty)
    $spacer = ' ' * ($contentWidth - $barWidth - $statsLen)

    # ── Row 1: bar + stats (2 Write-Host calls instead of 5) ──
    $Host.UI.RawUI.CursorPosition = @{ X = 0; Y = $BaseY + 1 }
    $barLine = (' ' * $indent) + $bar
    Write-Host $barLine -NoNewline -ForegroundColor Cyan
    Write-Host ($spacer + $statsText).PadRight(74 - $barLine.Length) -ForegroundColor White

    # ── Row 3: counters (single formatted string, colored segments) ──
    $Host.UI.RawUI.CursorPosition = @{ X = 0; Y = $BaseY + 3 }
    Write-Host (' ' * $indent) -NoNewline
    Write-Host 'OK: ' -NoNewline -ForegroundColor DarkGray
    Write-Host "$Success".PadRight(8) -NoNewline -ForegroundColor Green
    Write-Host 'Skip: ' -NoNewline -ForegroundColor DarkGray
    Write-Host "$Skipped".PadRight(8) -NoNewline -ForegroundColor Yellow
    Write-Host 'Err: ' -NoNewline -ForegroundColor DarkGray
    Write-Host "$Errors".PadRight(8) -NoNewline -ForegroundColor Red
    Write-Host 'Active: ' -NoNewline -ForegroundColor DarkGray
    Write-Host "$Running".PadRight(10) -ForegroundColor Cyan

    # ── Row 4: stop status (only redraw if stop requested) ──
    if ($StopRequested) {
        $Host.UI.RawUI.CursorPosition = @{ X = 0; Y = $BaseY + 4 }
        Write-Host '     [Q] Stopping... waiting for active tasks    ' -ForegroundColor Yellow
    }

    # Park cursor
    $Host.UI.RawUI.CursorPosition = @{ X = 0; Y = $BaseY + 5 }
}

# ═══════════════════════════════════════════════════════════════════════
# FINAL SUMMARY
# ═══════════════════════════════════════════════════════════════════════

function Format-Duration {
    param([double]$Seconds)
    if ($Seconds -lt 0) { $Seconds = 0 }
    if ($Seconds -lt 60) { return '{0:F1}s' -f $Seconds }

    $totalSeconds = [int][math]::Floor($Seconds)
    $hours   = [math]::Floor($totalSeconds / 3600)
    $minutes = [math]::Floor(($totalSeconds % 3600) / 60)
    $secs    = $totalSeconds % 60

    if ($hours -gt 0) { return '{0}h {1}m {2}s' -f $hours, $minutes, $secs }
    return '{0}m {1}s' -f $minutes, $secs
}
<# 
function Write-FinalSummary {
    param(
        [int]$SuccessCount,
        [int]$SkipCount,
        [int]$ErrorCount,
        [long]$TotalOriginalSize,
        [long]$TotalNewSize,
        [bool]$StopRequested,
        [string]$ResumePlanPath,
        [double]$ElapsedSeconds = 0
    )

    $savedBytes = $TotalOriginalSize - $TotalNewSize
    $savedMB = [math]::Round($savedBytes / 1MB, 2)
    $origMB  = [math]::Round($TotalOriginalSize / 1MB, 2)
    $newMB   = [math]::Round($TotalNewSize / 1MB, 2)

    $totalPct = if ($TotalOriginalSize -gt 0) {
        100 - [math]::Round(($TotalNewSize / $TotalOriginalSize) * 100)
    } else { 0 }

    $savedColor = if ($totalPct -ge 0) { 'Green' } else { 'Yellow' }
    $errColor   = if ($ErrorCount -gt 0) { 'Red' } else { 'Green' }
    $timeStr    = Format-Duration -Seconds $ElapsedSeconds

    Write-BoxHeader 'SUMMARY'
    Write-BoxEmpty

    # Row 1: Encoded / Skipped / Errors — colored
    $bc = $script:BoxColor
    $col1 = "  Encoded: "
    $val1 = $SuccessCount.ToString().PadRight(6)
    $col2 = "Skipped: "
    $val2 = $SkipCount.ToString().PadRight(6)
    $col3 = "Errors: "
    $val3 = $ErrorCount.ToString()

    $innerUsed = $col1.Length + $val1.Length + $col2.Length + $val2.Length + $col3.Length + $val3.Length
    $pad1 = [Math]::Max(0, 68 - $innerUsed)

    Write-Host "  │" -NoNewline -ForegroundColor $bc
    Write-Host $col1 -NoNewline -ForegroundColor $bc
    Write-Host $val1 -NoNewline -ForegroundColor Green
    Write-Host $col2 -NoNewline -ForegroundColor $bc
    Write-Host $val2 -NoNewline -ForegroundColor Yellow
    Write-Host $col3 -NoNewline -ForegroundColor $bc
    Write-Host ($val3 + (' ' * $pad1)) -NoNewline -ForegroundColor $errColor
    Write-Host "│" -ForegroundColor $bc

    Write-BoxEmpty

    # Row 2: Size → Saved → Time — colored
    $sizeText  = "  $origMB MB → $newMB MB"
    $savedText = "Saved: $savedMB MB ($totalPct%)"
    $timeText  = "Time: $timeStr"

    $innerUsed2 = $sizeText.Length + 3 + $savedText.Length + 3 + $timeText.Length
    $pad2 = [Math]::Max(0, 68 - $innerUsed2)

    Write-Host "  │" -NoNewline -ForegroundColor $bc
    Write-Host $sizeText -NoNewline -ForegroundColor White
    Write-Host "   " -NoNewline
    Write-Host $savedText -NoNewline -ForegroundColor $savedColor
    Write-Host "   " -NoNewline
    Write-Host ($timeText + (' ' * $pad2)) -NoNewline -ForegroundColor White
    Write-Host "│" -ForegroundColor $bc

    Write-BoxEmpty
    Write-BoxFooter
}
 #>
function Write-FinalSummary {
    param(
        [int]$SuccessCount,
        [int]$SkipCount,
        [int]$ErrorCount,
        [long]$TotalOriginalSize,
        [long]$TotalNewSize,
        [bool]$StopRequested,
        [string]$ResumePlanPath,
        [double]$ElapsedSeconds = 0
    )

    $savedBytes = $TotalOriginalSize - $TotalNewSize
    $savedMB = [math]::Round($savedBytes / 1MB, 2)
    $origMB  = [math]::Round($TotalOriginalSize / 1MB, 2)
    $newMB   = [math]::Round($TotalNewSize / 1MB, 2)

    $totalPct = if ($TotalOriginalSize -gt 0) {
        100 - [math]::Round(($TotalNewSize / $TotalOriginalSize) * 100)
    } else { 0 }

    $savedColor = if ($totalPct -ge 0) { 'Green' } else { 'Yellow' }
    $errColor   = if ($ErrorCount -gt 0) { 'Red' } else { 'Green' }
    $timeStr    = Format-Duration -Seconds $ElapsedSeconds

    Write-BoxHeader 'SUMMARY'
    Write-BoxEmpty

    $bc = $script:BoxColor
    $innerWidth = 68
    $margin = 2

    # ── Row 1: Encoded / Skipped / Errors ──
    $errColor = if ($ErrorCount -gt 0) { 'Red' } else { 'Green' }

    $r1parts = @(
        @{ Label = 'Encoded: '; Value = "$SuccessCount"; Color = 'Green' }
        @{ Label = 'Skipped: '; Value = "$SkipCount";    Color = 'Yellow' }
        @{ Label = 'Errors: ';  Value = "$ErrorCount";   Color = $errColor }
    )

    # Calculate content length and gaps
    $r1contentLen = 0
    foreach ($p in $r1parts) { $r1contentLen += $p.Label.Length + $p.Value.Length }
    $r1available = $innerWidth - (2 * $margin) - $r1contentLen
    $r1gapCount  = $r1parts.Count - 1
    $r1gap = [Math]::Max(1, [Math]::Floor($r1available / $r1gapCount))
    $r1extra = $r1available - ($r1gap * $r1gapCount)

    Write-Host "  │" -NoNewline -ForegroundColor $bc
    Write-Host (' ' * $margin) -NoNewline

    for ($i = 0; $i -lt $r1parts.Count; $i++) {
        Write-Host $r1parts[$i].Label -NoNewline -ForegroundColor $bc
        Write-Host $r1parts[$i].Value -NoNewline -ForegroundColor $r1parts[$i].Color

        if ($i -lt $r1gapCount) {
            Write-Host (' ' * $r1gap) -NoNewline
        }
    }

    # Right padding
    $r1printed = $margin
    foreach ($p in $r1parts) { $r1printed += $p.Label.Length + $p.Value.Length }
    $r1printed += $r1gap * $r1gapCount
    $r1rightPad = $innerWidth - $r1printed - $margin
    if ($r1rightPad -lt 0) { $r1rightPad = 0 }
    Write-Host (' ' * ($r1rightPad + $margin)) -NoNewline
    Write-Host "│" -ForegroundColor $bc

    Write-BoxEmpty

    # ── Row 2: Size → Saved → Time ──
    $savedColor = if ($totalPct -ge 0) { 'Green' } else { 'Yellow' }

    $r2parts = @(
        @{ Text = "$origMB MB → $newMB MB";        Color = 'White' }
        @{ Text = "Saved: $savedMB MB ($totalPct%)"; Color = $savedColor }
        @{ Text = "Time: $timeStr";                  Color = 'White' }
    )

    $r2contentLen = 0
    foreach ($p in $r2parts) { $r2contentLen += $p.Text.Length }
    $r2available = $innerWidth - (2 * $margin) - $r2contentLen
    $r2gapCount  = $r2parts.Count - 1
    $r2gap = [Math]::Max(1, [Math]::Floor($r2available / $r2gapCount))

    Write-Host "  │" -NoNewline -ForegroundColor $bc
    Write-Host (' ' * $margin) -NoNewline

    for ($i = 0; $i -lt $r2parts.Count; $i++) {
        Write-Host $r2parts[$i].Text -NoNewline -ForegroundColor $r2parts[$i].Color

        if ($i -lt $r2gapCount) {
            Write-Host (' ' * $r2gap) -NoNewline
        }
    }

    $r2printed = $margin
    foreach ($p in $r2parts) { $r2printed += $p.Text.Length }
    $r2printed += $r2gap * $r2gapCount
    $r2rightPad = $innerWidth - $r2printed - $margin
    if ($r2rightPad -lt 0) { $r2rightPad = 0 }
    Write-Host (' ' * ($r2rightPad + $margin)) -NoNewline
    Write-Host "│" -ForegroundColor $bc

    Write-BoxEmpty
    Write-BoxFooter
}

# ═══════════════════════════════════════════════════════════════════════
# DETAILED REPORT
# ═══════════════════════════════════════════════════════════════════════

function Write-DetailedReport {
    param([hashtable]$FormatStats)

    if ($null -eq $FormatStats -or $FormatStats.Count -eq 0) { return }

    Write-Host
	Write-BorderTop -ColWidths $script:BoxCols -Indent $script:BoxIndent
    $headerLine = '  {0,-10} {1,8} {2,8} {3,8} {4,10}' -f 'Format', 'OK', 'Skip', 'Err', 'Saved %'
    Write-BoxLine -Text $headerLine
    Write-BorderMid -ColWidths $script:BoxCols -Indent $script:BoxIndent
	
    foreach ($key in ($FormatStats.Keys | Sort-Object)) {
        $s = $FormatStats[$key]
        $savedPct = if ($s.OriginalBytes -gt 0) {
            $pct = 100 - [math]::Round(($s.NewBytes / $s.OriginalBytes) * 100)
            "${pct}%"
        } else { '-' }

        $line = '  {0,-10} {1,8} {2,8} {3,8} {4,10}' -f $key, $s.Success, $s.Skip, $s.Error, $savedPct
        Write-BoxLine -Text $line
    }

    Write-BoxFooter
}

# ═══════════════════════════════════════════════════════════════════════
# LOG SUMMARY
# ═══════════════════════════════════════════════════════════════════════

<# function Write-LogSummary {
    param(
        [int]$ErrorCount,
        [bool]$HasWarnings,
        [string]$LogFilePath
    )

    if (-not $LogFilePath) { return }

    $logColor = if ($ErrorCount -gt 0) { 'Red' } else { 'DarkYellow' }
    $logTitle = if ($ErrorCount -gt 0 -and $HasWarnings) { 'ERRORS + WARNINGS' }
               elseif ($ErrorCount -gt 0) { 'ERRORS' }
               elseif ($HasWarnings) { 'WARNINGS' }
               else { 'LOG' }

    $logLeaf = Split-Path $LogFilePath -Leaf

    Write-Host
    Write-BoxHeader -Title $logTitle -Color $logColor
    Write-BoxEmpty -Color $logColor
    Write-BoxValueLine -Label 'File:' -Value $logLeaf -ValueColor White -BorderColor $logColor
    Write-BoxEmpty -Color $logColor
    Write-BoxFooter -Color $logColor
} #>
function Write-LogSummary {
    param(
        [int]$ErrorCount,
        [bool]$HasWarnings,
        [string]$LogFilePath
    )

    if (-not $LogFilePath) { return }

    $logColor = if ($ErrorCount -gt 0) { 'Red' } else { 'DarkYellow' }
    $logTitle = if ($ErrorCount -gt 0 -and $HasWarnings) { 'ERRORS + WARNINGS' }
               elseif ($ErrorCount -gt 0) { 'ERRORS' }
               elseif ($HasWarnings) { 'WARNINGS' }
               else { 'LOG' }

    $logLeaf = Split-Path $LogFilePath -Leaf

    Write-Host
    Write-BoxTitleOnly -Title "$logTitle — $logLeaf" -Color $logColor
}