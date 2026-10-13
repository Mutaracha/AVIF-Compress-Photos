@{
    # ══════════════════════════════════════════════════
    # GENERAL
    # ══════════════════════════════════════════════════
    General = @{
        # Global AVIF quality override (0..100 or empty)
        # Convenient for quick quality adjustment without editing each section
        # When set: overrides Q in Opaque, AlphaPng, AlphaGif
        # When empty ($null): uses individual Q values from each section
        AvifQuality = 65

        # Delete original files after successful conversion (0 or 1)
        # Files are moved to Recycle Bin (recoverable)
        DeleteOriginals = 1

		# Limits parallel file analysis (.NET decoder, binary parsers, ffprobe)
        # 0 = auto (CPU cores, max 16), 1-16 = fixed
        # 1 or 2 reduces disk load on HDD
        AnalysisThreads = 2

        # Minimum file size to process (KB)
        # Files smaller than this will be skipped
        MinProcessSizeKB = 50

        # Timeout for a single encoding task in batch mode (seconds)
        # If ffmpeg/avifenc doesn't finish in time, process is killed
        TimeoutSec = 120

        # Timeout for single file mode (seconds)
        # 0 = no timeout (wait until encoding completes)
        TimeoutSecSingleFile = 0

        # Debug mode: 0 = show errors in console only
        # 1 = also save crash log to logs/ and show stack trace
        DebugMode = 1

        # Write debug log for single file mode (0 or 1)
        # When 1: log is always written, even on success
        # When 0: log is written only on error
        DebugLogSingleFile = 0

        # Save encoding plan to logs folder (0 or 1)
        # When 1: creates EncodingPlan_%datetime%.log with full plan details
        # Only for batch/folder mode
        DebugLogEncodingPlan = 0
    }

    # ══════════════════════════════════════════════════
    # FFMPEG
    # ══════════════════════════════════════════════════
    FFmpeg = @{
        # Pixel format for static images without alpha (pipe mode)
        # yuv420p - standard, slightly smaller files
        # yuv444p - preserves color detail, safer for graphics
        StaticPixFmt = "yuv444p"
    }

    # ══════════════════════════════════════════════════
    # Settings for AVIF encoding via avifenc
    # ══════════════════════════════════════════════════
    Avifenc = @{
        # ── Static images without alpha ──
        Opaque = @{
            # Quality (0..100, lower = smaller file, more artifacts)
            # 55 - good for photos
            # 65 - better for detailed graphics/illustrations
            Q = 55

            # Speed (0..10, where 0 is the slowest, 10 is the fastest)
            # 6 - default
            # 5 - optimal for detail preservation
            S = 6

            # Sharpness (0..7, higher = sharper edges, default: 0)
            # Values above 2 may introduce ringing artifacts
            Sharpness = 2

            # Chroma delta-q: improves color accuracy
			# 0=disable (default), 1=enable
			# 1 - best perceptual quality
            EnableChromaDeltaQ = 1

            # Adaptive quantization mode (0-3)
			# 0=off (default), 1=variance, 
			# 2=complexity, 3=cyclic
            # 3 - best perceptual quality
            AqMode = 3

            # Tune target
			# Tune the encoder for distortion metric, one of 'psnr', 'ssim' or 'iq'.
			# Default for color: still non-RGB images: iq, otherwise: ssim; 
			# default for alpha: psnr)
            # iq - image quality (best for photos/graphics)
            # ssim - structural similarity
            Tune = "iq"

            # Automatic tile sizing (1/0)
            # Improves encoding speed for large images
            AutoTiling= 1
        }

        # ── Static images with alpha: PNG ──
        AlphaPng = @{
            # Quality for color channels (0..100)
            Q = 55

            # Quality for alpha channel (0..100)
            # Higher = better alpha preservation
            # 60-100 recommended range
            QAlpha = 80

            # YUV range
            # One of 'limited' or 'l', 'full' or 'f'. 
			# JPEG/PNG only, default: full
            Rate = "f"

            # Tune target
            Tune = "iq"

            # avifenc starts in automatic tiling mode (0 or 1)
            AutoTiling = 1

            # Speed adjustment relative to Opaque.S
            # Final speed = Opaque.S + SpeedDelta
            # -1 means one step slower for better alpha quality
            SpeedDelta = -1
        }

        # ── Static GIF (1 frame) ──
        AlphaGif = @{
            # Quality for color channels (0..100)
            Q = 55

            # Quality for alpha channel
            # Always 100 for GIF to preserve sharp transparency edges
            QAlpha = 100

            # Chroma subsampling for GIF
            # 420 is sufficient for palette-based images
            Y = 420

            # Full range flag
            Rate = "f"

            # Tune target
            # ssim works better for GIF palette images
            Tune = "ssim"

            # Automatic tile sizing
            AutoTiling = 1

            # Speed adjustment relative to Opaque.S
            SpeedDelta = -1
        }
    }

    # ══════════════════════════════════════════════════
    # WEBP (animated GIF conversion via gif2webp)
    # ══════════════════════════════════════════════════
    WebP = @{
        # Quality (0..100)
        # 80 - optimal balance of quality and size
        Qv = 85

        # Compression effort (1..6, higher = better compression, slower)
        CompressionLevel = 6
    }
}