# ImageProbe.ps1
# File inspection: format detection, dimensions, alpha, animation
# Parsers: .NET BitmapDecoder, GIF/WebP binary, ffprobe fallback, decode test

# ═══════════════════════════════════════════════════════════════════════
# CONSTANTS
# ═══════════════════════════════════════════════════════════════════════

$script:DotNetAlphaFormats = @(
    'Bgra32', 'Rgba64', 'Rgba128Float',
    'Pbgra32', 'Prgba64', 'Prgba128Float'
)

$script:AlphaPixelFormats = @(
    'bgra', 'rgba', 'rgba64', 'bgra64',
    'ya8', 'ya16',
    'yuva420p', 'yuva422p', 'yuva444p',
    'yuva420p10le', 'yuva422p10le', 'yuva444p10le',
    'pal8'
)

# ═══════════════════════════════════════════════════════════════════════
# .NET ANALYSIS (JPG, JPEG, BMP, TIFF, PNG)
# ═══════════════════════════════════════════════════════════════════════

function Invoke-DotNetAnalysis {
    <#
    .SYNOPSIS
    Analyzes image files using .NET BitmapDecoder (WPF).
    Returns results dictionary and list of files that failed.
    #>
    param(
        [System.IO.FileInfo[]]$Files,
        [int]$ThrottleLimit = 8
    )

    $results  = [System.Collections.Concurrent.ConcurrentDictionary[string, hashtable]]::new()
    $fallback = [System.Collections.Concurrent.ConcurrentBag[PSObject]]::new()

    if ($null -eq $Files -or $Files.Count -eq 0) {
        return [PSCustomObject]@{ Results = $results; Fallback = $fallback }
    }

    $alphaFmts = $script:DotNetAlphaFormats

    $Files | ForEach-Object -Parallel {
        $file         = $_
        $ext          = $file.Extension.ToLowerInvariant()
        $alphaFormats = $using:alphaFmts
        $resultDict   = $using:results
        $fallbackBag  = $using:fallback

        $r = @{
            Success    = $false
            Width      = 0
            Height     = 0
            HasAlpha   = $false
            FrameCount = 1
            Error      = ''
        }

        $stream = $null
        try {
            Add-Type -AssemblyName PresentationCore -ErrorAction SilentlyContinue

            $stream = [System.IO.File]::OpenRead($file.FullName)
            $decoder = [System.Windows.Media.Imaging.BitmapDecoder]::Create(
                $stream,
                [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
                [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            )

            $frame    = $decoder.Frames[0]
            $r.Width  = $frame.PixelWidth
            $r.Height = $frame.PixelHeight

            # Alpha detection by format
            if ($ext -eq '.png') {
                $formatName = $frame.Format.ToString()
                if ($alphaFormats -contains $formatName) {
                    $r.HasAlpha = $true
                }
                elseif ($formatName -match 'Indexed' -or $formatName -eq 'BlackWhite') {
                    # Indexed/palette: convert and sample pixels
                    try {
                        $converted = New-Object System.Windows.Media.Imaging.FormatConvertedBitmap(
                            $frame,
                            [System.Windows.Media.PixelFormats]::Bgra32,
                            $null, 0.0
                        )
                        $stride  = $converted.PixelWidth * 4
                        $rows    = [Math]::Min($converted.PixelHeight, 4)
                        $bufSize = $stride * $rows
                        $buf     = [byte[]]::new($bufSize)
                        $converted.CopyPixels($buf, $stride, 0)

                        for ($i = 3; $i -lt $buf.Length; $i += 4) {
                            if ($buf[$i] -lt 255) {
                                $r.HasAlpha = $true
                                break
                            }
                        }
                    }
                    catch { }
                }
            }
            elseif ($ext -in @('.tiff', '.tif')) {
                $formatName = $frame.Format.ToString()
                $r.HasAlpha = $alphaFormats -contains $formatName
            }
            else {
                # JPG, JPEG, BMP — no alpha
                $r.HasAlpha = $false
            }

            $r.Success = $true
        }
        catch {
            $r.Error = $_.Exception.Message
        }
        finally {
            if ($stream) {
                try { $stream.Dispose() } catch { }
            }
        }

        if ($r.Success) {
            $resultDict[$file.FullName] = $r
        }
        else {
            $fallbackBag.Add($file)
        }
    } -ThrottleLimit $ThrottleLimit

    return [PSCustomObject]@{ Results = $results; Fallback = $fallback }
}

# ═══════════════════════════════════════════════════════════════════════
# BINARY PARSER DISPATCH (GIF + WebP, parallel)
# ═══════════════════════════════════════════════════════════════════════

function Invoke-BinaryParserAnalysis {
    <#
    .SYNOPSIS
    Runs binary parsers for GIF and WebP files in parallel.
    Parsers are inline because ForEach-Object -Parallel
    cannot access external functions or scriptblocks.
    GIF: animated → skip alpha; static → detect alpha.
    WebP: animated → skip (will be filtered out).
    .OUTPUTS
    PSCustomObject with Results and Suspicious bags.
    #>
    param(
        [System.IO.FileInfo[]]$Files,
        [int]$ThrottleLimit = 8
    )

    $results    = [System.Collections.Concurrent.ConcurrentDictionary[string, hashtable]]::new()
    $suspicious = [System.Collections.Concurrent.ConcurrentBag[PSObject]]::new()

    if ($null -eq $Files -or $Files.Count -eq 0) {
        return [PSCustomObject]@{ Results = $results; Suspicious = $suspicious }
    }

    $Files | ForEach-Object -Parallel {
        $file       = $_
        $ext        = $file.Extension.ToLowerInvariant()
        $resultDict = $using:results
        $suspBag    = $using:suspicious

        $r = $null

        # ── GIF Parser ──
        if ($ext -eq '.gif') {
            $r = @{
                Success = $false; Width = 0; Height = 0
                HasAlpha = $false; FrameCount = 0; IsAnimated = $false; Error = ''
            }
            $stream = $null; $reader = $null
            try {
                $stream = [System.IO.File]::OpenRead($file.FullName)
                $reader = New-Object System.IO.BinaryReader($stream)

                $sig = -join ($reader.ReadChars(6))
                if ($sig -ne 'GIF87a' -and $sig -ne 'GIF89a') {
                    $r.Error = "Not a valid GIF (sig: $sig)"
                }
                else {
                    $r.Width  = $reader.ReadUInt16()
                    $r.Height = $reader.ReadUInt16()
                    $packed = $reader.ReadByte()
                    $hasGCT = ($packed -band 0x80) -ne 0
                    $gctSize = if ($hasGCT) { 3 * [math]::Pow(2, ($packed -band 0x07) + 1) } else { 0 }
                    [void]$reader.ReadByte(); [void]$reader.ReadByte()
                    if ($hasGCT) { [void]$reader.ReadBytes([int]$gctSize) }

                    $hasTransparency = $false
                    $parseOk = $true

                    while ($stream.Position -lt $stream.Length) {
                        $bt = $reader.ReadByte()
                        if ($bt -eq 0x2C) {
                            $r.FrameCount++
                            [void]$reader.ReadBytes(8)
                            $imgPacked = $reader.ReadByte()
                            $hasLCT = ($imgPacked -band 0x80) -ne 0
                            $lctSize = if ($hasLCT) { 3 * [math]::Pow(2, ($imgPacked -band 0x07) + 1) } else { 0 }
                            if ($hasLCT) { [void]$reader.ReadBytes([int]$lctSize) }
                            [void]$reader.ReadByte()
                            while ($true) {
                                $sb = $reader.ReadByte()
                                if ($sb -eq 0) { break }
                                [void]$reader.ReadBytes($sb)
                            }
                            if ($r.FrameCount -ge 2) { $r.IsAnimated = $true; break }
                        }
                        elseif ($bt -eq 0x21) {
                            $extType = $reader.ReadByte()
                            if ($extType -eq 0xF9) {
                                $gcBlockSize = $reader.ReadByte()
                                if ($gcBlockSize -ge 4) {
                                    $gcPacked = $reader.ReadByte()
                                    if (($gcPacked -band 0x01) -ne 0) { $hasTransparency = $true }
                                    [void]$reader.ReadBytes($gcBlockSize - 1)
                                }
                                elseif ($gcBlockSize -gt 0) {
                                    [void]$reader.ReadBytes($gcBlockSize)
                                }
                                [void]$reader.ReadByte()
                            }
                            else {
                                while ($true) {
                                    $sb = $reader.ReadByte()
                                    if ($sb -eq 0) { break }
                                    [void]$reader.ReadBytes($sb)
                                }
                            }
                        }
                        elseif ($bt -eq 0x3B) { break }
                        else {
                            $parseOk = $false
                            $r.Error = "Unexpected GIF block: 0x$($bt.ToString('X2'))"
                            break
                        }
                    }

                    if ($parseOk -and $r.FrameCount -gt 0) {
                        if (-not $r.IsAnimated) {
                            $r.HasAlpha = $hasTransparency
                        }
                        $r.Success = $true
                    }
                    elseif ($parseOk) {
                        $r.Error = 'No image descriptors found'
                    }
                }
            }
            catch { $r.Error = $_.Exception.Message }
            finally {
                if ($reader) { try { $reader.Dispose() } catch {} }
                if ($stream) { try { $stream.Dispose() } catch {} }
            }
        }

        # ── WebP Parser ──
        elseif ($ext -eq '.webp') {
            $r = @{
                Success = $false; Width = 0; Height = 0
                HasAlpha = $false; FrameCount = 1; IsAnimated = $false; Error = ''
            }
            $stream = $null; $reader = $null
            try {
                $stream = [System.IO.File]::OpenRead($file.FullName)
                $reader = New-Object System.IO.BinaryReader($stream)

                $riff = -join ($reader.ReadChars(4))
                [void]$reader.ReadUInt32()
                $webp = -join ($reader.ReadChars(4))

                if ($riff -ne 'RIFF' -or $webp -ne 'WEBP') {
                    $r.Error = 'Not a valid WebP'
                }
                else {
                    $chunkHeader = -join ($reader.ReadChars(4))
                    $chunkSize = $reader.ReadUInt32()

                    switch ($chunkHeader) {
                        'VP8X' {
                            $flagsByte    = $reader.ReadByte()
                            $r.IsAnimated = ($flagsByte -band 0x02) -ne 0
                            $r.HasAlpha   = ($flagsByte -band 0x10) -ne 0
                            [void]$reader.ReadBytes(3)

                            $b = $reader.ReadBytes(3)
                            $r.Width = ([int]$b[0]) + ([int]$b[1] -shl 8) + ([int]$b[2] -shl 16) + 1
                            $b = $reader.ReadBytes(3)
                            $r.Height = ([int]$b[0]) + ([int]$b[1] -shl 8) + ([int]$b[2] -shl 16) + 1

                            if ($r.IsAnimated) { $r.FrameCount = 999 }
                            $r.Success = $true
                        }
                        'VP8 ' {
                            if ($chunkSize -ge 10) {
                                $frameTag = $reader.ReadBytes(3)
                                $isKeyframe = ($frameTag[0] -band 0x01) -eq 0
                                if ($isKeyframe) {
                                    $startCode = $reader.ReadBytes(3)
                                    if ($startCode[0] -eq 0x9D -and $startCode[1] -eq 0x01 -and $startCode[2] -eq 0x2A) {
                                        $widthInfo  = $reader.ReadUInt16()
                                        $heightInfo = $reader.ReadUInt16()
                                        $r.Width  = $widthInfo -band 0x3FFF
                                        $r.Height = $heightInfo -band 0x3FFF
                                    }
                                }
                            }
                            $r.HasAlpha = $false
                            $r.Success  = $true
                        }
                        'VP8L' {
                            if ($chunkSize -ge 5) {
                                $signature = $reader.ReadByte()
                                if ($signature -eq 0x2F) {
                                    $bits = $reader.ReadUInt32()
                                    $r.Width    = ($bits -band 0x3FFF) + 1
                                    $r.Height   = (($bits -shr 14) -band 0x3FFF) + 1
                                    $r.HasAlpha = (($bits -shr 28) -band 0x01) -ne 0
                                }
                            }
                            $r.Success = $true
                        }
                        default {
                            $r.Error = "Unknown WebP chunk: $chunkHeader"
                        }
                    }
                }
            }
            catch { $r.Error = $_.Exception.Message }
            finally {
                if ($reader) { try { $reader.Dispose() } catch {} }
                if ($stream) { try { $stream.Dispose() } catch {} }
            }
        }

        # ── Store result ──
        if ($null -ne $r -and $r.Success) {
            $resultDict[$file.FullName] = $r
        }
        else {
            $suspBag.Add($file)
        }
    } -ThrottleLimit $ThrottleLimit

    return [PSCustomObject]@{ Results = $results; Suspicious = $suspicious }
}

# ═══════════════════════════════════════════════════════════════════════
# FFPROBE FALLBACK
# ═══════════════════════════════════════════════════════════════════════

function Invoke-FfprobeFallback {
    <#
    .SYNOPSIS
    Uses ffprobe to analyze files that failed other methods.
    Extracts width, height, alpha, frame count.
    #>
    param(
        [System.IO.FileInfo[]]$Files,
        [int]$ThrottleLimit = 8
    )

    $results    = [System.Collections.Concurrent.ConcurrentDictionary[string, hashtable]]::new()
    $suspicious = [System.Collections.Concurrent.ConcurrentBag[PSObject]]::new()

    if ($null -eq $Files -or $Files.Count -eq 0) {
        return [PSCustomObject]@{ Results = $results; Suspicious = $suspicious }
    }

    $knownAlphaFmts = $script:AlphaPixelFormats

    $Files | ForEach-Object -Parallel {
        $file       = $_
        $alphaFmts  = $using:knownAlphaFmts
        $resultDict = $using:results
        $suspBag    = $using:suspicious

        $r = @{
            Success    = $false
            Width      = 0
            Height     = 0
            HasAlpha   = $false
            FrameCount = 1
            Error      = ''
        }

        try {
            # Run ffprobe, capture only stdout (stderr suppressed)
            $jsonText = ''
            $proc = New-Object System.Diagnostics.Process
            $proc.StartInfo.FileName  = 'ffprobe'
            $proc.StartInfo.Arguments = "-v error -select_streams v:0 -show_entries stream=width,height,pix_fmt,nb_frames -of json `"$($file.FullName)`""
            $proc.StartInfo.UseShellExecute = $false
            $proc.StartInfo.RedirectStandardOutput = $true
            $proc.StartInfo.RedirectStandardError  = $true
            $proc.StartInfo.CreateNoWindow = $true
            [void]$proc.Start()

            $jsonText = $proc.StandardOutput.ReadToEnd()
            [void]$proc.StandardError.ReadToEnd()
            $proc.WaitForExit()

            if ($proc.ExitCode -eq 0 -and $jsonText) {
                $data = $jsonText | ConvertFrom-Json

                if ($data.streams -and $data.streams.Count -gt 0) {
                    $s = $data.streams[0]
                    $r.Width  = [int]$s.width
                    $r.Height = [int]$s.height

                    $pixFmt = if ($s.pix_fmt) { $s.pix_fmt } else { '' }
                    $r.HasAlpha = $alphaFmts -contains $pixFmt

                    # nb_frames may be N/A or missing
                    $nbFrames = 1
                    if ($s.nb_frames -and $s.nb_frames -match '^\d+$') {
                        $nbFrames = [int]$s.nb_frames
                    }
                    $r.FrameCount = [Math]::Max(1, $nbFrames)

                    if ($r.Width -gt 0 -and $r.Height -gt 0) {
                        $r.Success = $true
                    }
                    else {
                        $r.Error = 'ffprobe returned zero dimensions'
                    }
                }
                else {
                    $r.Error = 'ffprobe returned no streams'
                }
            }
            else {
                $r.Error = "ffprobe exit code: $($proc.ExitCode)"
            }
        }
        catch {
            $r.Error = $_.Exception.Message
        }
        finally {
            if ($proc) { try { $proc.Dispose() } catch { } }
        }

        if ($r.Success) {
            $resultDict[$file.FullName] = $r
        }
        else {
            $suspBag.Add($file)
        }
    } -ThrottleLimit $ThrottleLimit

    return [PSCustomObject]@{ Results = $results; Suspicious = $suspicious }
}

# ═══════════════════════════════════════════════════════════════════════
# DECODE TEST (suspicious files → decodable or corrupt)
# ═══════════════════════════════════════════════════════════════════════

function Test-CanDecode {
    <#
    .SYNOPSIS
    Tests if files can be decoded by ffmpeg (1 frame decode test).
    Returns decodable paths and corrupt file objects.
    #>
    param(
        [System.IO.FileInfo[]]$Files,
        [int]$ThrottleLimit = 4
    )

    $decodable = [System.Collections.Concurrent.ConcurrentBag[string]]::new()
    $corrupt   = [System.Collections.Concurrent.ConcurrentBag[PSObject]]::new()

    if ($null -eq $Files -or $Files.Count -eq 0) {
        return [PSCustomObject]@{ Decodable = $decodable; Corrupt = $corrupt }
    }

    $Files | ForEach-Object -Parallel {
        $file   = $_
        $decBag = $using:decodable
        $corBag = $using:corrupt

        $canDecode = $false
        try {
            $proc = New-Object System.Diagnostics.Process
            $proc.StartInfo.FileName  = 'ffmpeg'
            $proc.StartInfo.Arguments = "-hide_banner -v error -i `"$($file.FullName)`" -map 0:v:0 -frames:v 1 -f null -"
            $proc.StartInfo.UseShellExecute = $false
            $proc.StartInfo.RedirectStandardOutput = $false
            $proc.StartInfo.RedirectStandardError  = $true
            $proc.StartInfo.CreateNoWindow = $true
            [void]$proc.Start()

            $stderr = $proc.StandardError.ReadToEnd()
            $proc.WaitForExit()

            if ($proc.ExitCode -eq 0) {
                if ($stderr -notmatch 'Invalid data|Decode error|0 bytes left') {
                    $canDecode = $true
                }
            }
        }
        catch { }
        finally {
            if ($proc) { try { $proc.Dispose() } catch { } }
        }

        if ($canDecode) {
            $decBag.Add($file.FullName)
        }
        else {
            $corBag.Add($file)
        }
    } -ThrottleLimit $ThrottleLimit

    return [PSCustomObject]@{ Decodable = $decodable; Corrupt = $corrupt }
}