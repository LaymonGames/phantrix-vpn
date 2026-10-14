# Regenerates every platform's app icon from assets/icon.png.
#
# The source of truth for the Phantrix mark is assets/icon.png (1024x1024).
# Each platform keeps its icons as generated copies in its own tree, because
# Windows wants an .ico, Android wants five density buckets, and iOS/macOS
# want an asset catalogue. This script rebuilds all of them from the one
# source, so the mark never drifts between platforms.
#
#   powershell -ExecutionPolicy Bypass -File tools\generate_app_icons.ps1
#
# No image library is required: System.Drawing ships with Windows PowerShell,
# and downscaling goes through repeated halving because a single-step resize
# from 1024 to 16 throws away most of the detail.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSScriptRoot
$source = Join-Path $root 'assets\icon.png'

if (-not (Test-Path $source)) {
	throw "Missing icon source: $source"
}

# Loads the source once; every size below is produced from this handle.
$src = [System.Drawing.Image]::FromFile($source)

# The icon's own corner colour, used as the backdrop for the maskable web
# icons so the safe-zone padding is invisible rather than white.
$corner = New-Object System.Drawing.Bitmap 1, 1
$cornerG = [System.Drawing.Graphics]::FromImage($corner)
$cornerG.DrawImage($src, (New-Object System.Drawing.Rectangle 0, 0, 1, 1))
$backdrop = $corner.GetPixel(0, 0)
$cornerG.Dispose()
$corner.Dispose()

function Get-Downscaled {
	param([int]$size)
	# Halve repeatedly from the largest working surface, which keeps the
	# small sizes (16px, 20px) legible instead of mushy.
	$current = New-Object System.Drawing.Bitmap $src
	$g = [System.Drawing.Graphics]::FromImage($current)
	$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
	$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
	$g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
	$g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
	while (($current.Width -shr 1) -ge $size) {
		$next = New-Object System.Drawing.Bitmap ($current.Width -shr 1), ($current.Width -shr 1)
		$ng = [System.Drawing.Graphics]::FromImage($next)
		$ng.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
		$ng.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
		$ng.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
		$ng.DrawImage($current, 0, 0, $next.Width, $next.Height)
		$ng.Dispose()
		$current.Dispose()
		$current = $next
	}
	$out = New-Object System.Drawing.Bitmap $size, $size
	$og = [System.Drawing.Graphics]::FromImage($out)
	$og.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
	$og.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
	$og.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
	$og.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
	$og.DrawImage($current, 0, 0, $size, $size)
	$og.Dispose()
	$current.Dispose()
	return $out
}

function Save-Png {
	param([System.Drawing.Bitmap]$image, [string]$path)
	$dir = Split-Path -Parent $path
	if (-not (Test-Path $dir)) {
		New-Item -ItemType Directory -Force -Path $dir | Out-Null
	}
	$image.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
	$image.Dispose()
	Write-Host "  $path"
}

function New-Icon {
	param([int]$size)
	return Get-Downscaled $size
}

# The mark inset inside a full-bleed square. Android adaptive icons and web
# maskable icons are cropped to a circle or squircle by the launcher, so the
# artwork has to sit inside a safe zone or its edges get shaved off.
function New-Maskable {
	param([int]$size)
	$out = New-Object System.Drawing.Bitmap $size, $size
	$g = [System.Drawing.Graphics]::FromImage($out)
	$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
	$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
	$g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
	$brush = New-Object System.Drawing.SolidBrush $backdrop
	$g.FillRectangle($brush, 0, 0, $size, $size)
	$brush.Dispose()
	$inner = [int]($size * 0.80)
	$offset = [int](($size - $inner) / 2)
	$srcRect = New-Object System.Drawing.Rectangle 0, 0, $src.Width, $src.Height
	$dstRect = New-Object System.Drawing.Rectangle $offset, $offset, $inner, $inner
	$g.DrawImage($src, $dstRect, $srcRect, [System.Drawing.GraphicsUnit]::Pixel)
	$g.Dispose()
	return $out
}

Write-Host 'android'
Save-Png (New-Icon 48)  (Join-Path $root 'android\app\src\main\res\mipmap-mdpi\ic_launcher.png')
Save-Png (New-Icon 72)  (Join-Path $root 'android\app\src\main\res\mipmap-hdpi\ic_launcher.png')
Save-Png (New-Icon 96)  (Join-Path $root 'android\app\src\main\res\mipmap-xhdpi\ic_launcher.png')
Save-Png (New-Icon 144) (Join-Path $root 'android\app\src\main\res\mipmap-xxhdpi\ic_launcher.png')
Save-Png (New-Icon 192) (Join-Path $root 'android\app\src\main\res\mipmap-xxxhdpi\ic_launcher.png')

Write-Host 'web'
Save-Png (New-Icon 16)  (Join-Path $root 'web\favicon.png')
Save-Png (New-Icon 192) (Join-Path $root 'web\icons\Icon-192.png')
Save-Png (New-Icon 512) (Join-Path $root 'web\icons\Icon-512.png')
Save-Png (New-Maskable 192) (Join-Path $root 'web\icons\Icon-maskable-192.png')
Save-Png (New-Maskable 512) (Join-Path $root 'web\icons\Icon-maskable-512.png')

Write-Host 'ios'
$ios = 'ios\Runner\Assets.xcassets\AppIcon.appiconset'
Save-Png (New-Icon 20)  (Join-Path $root "$ios\Icon-App-20x20@1x.png")
Save-Png (New-Icon 40)  (Join-Path $root "$ios\Icon-App-20x20@2x.png")
Save-Png (New-Icon 60)  (Join-Path $root "$ios\Icon-App-20x20@3x.png")
Save-Png (New-Icon 29)  (Join-Path $root "$ios\Icon-App-29x29@1x.png")
Save-Png (New-Icon 58)  (Join-Path $root "$ios\Icon-App-29x29@2x.png")
Save-Png (New-Icon 87)  (Join-Path $root "$ios\Icon-App-29x29@3x.png")
Save-Png (New-Icon 40)  (Join-Path $root "$ios\Icon-App-40x40@1x.png")
Save-Png (New-Icon 80)  (Join-Path $root "$ios\Icon-App-40x40@2x.png")
Save-Png (New-Icon 120) (Join-Path $root "$ios\Icon-App-40x40@3x.png")
Save-Png (New-Icon 120) (Join-Path $root "$ios\Icon-App-60x60@2x.png")
Save-Png (New-Icon 180) (Join-Path $root "$ios\Icon-App-60x60@3x.png")
Save-Png (New-Icon 76)  (Join-Path $root "$ios\Icon-App-76x76@1x.png")
Save-Png (New-Icon 152) (Join-Path $root "$ios\Icon-App-76x76@2x.png")
Save-Png (New-Icon 167) (Join-Path $root "$ios\Icon-App-83.5x83.5@2x.png")
Save-Png (New-Icon 1024) (Join-Path $root "$ios\Icon-App-1024x1024@1x.png")

Write-Host 'macos'
$macos = 'macos\Runner\Assets.xcassets\AppIcon.appiconset'
Save-Png (New-Icon 16)   (Join-Path $root "$macos\app_icon_16.png")
Save-Png (New-Icon 32)   (Join-Path $root "$macos\app_icon_32.png")
Save-Png (New-Icon 64)   (Join-Path $root "$macos\app_icon_64.png")
Save-Png (New-Icon 128)  (Join-Path $root "$macos\app_icon_128.png")
Save-Png (New-Icon 256)  (Join-Path $root "$macos\app_icon_256.png")
Save-Png (New-Icon 512)  (Join-Path $root "$macos\app_icon_512.png")
Save-Png (New-Icon 1024) (Join-Path $root "$macos\app_icon_1024.png")

Write-Host 'windows'
# An .ico is a flat header, one directory entry per image, then the image
# payloads. Windows accepts PNG payloads in every slot since Vista, which
# avoids writing a BMP encoder for the small sizes.
$icoSizes = @(16, 24, 32, 48, 64, 128, 256)
$images = @()
foreach ($s in $icoSizes) {
	$ms = New-Object System.IO.MemoryStream
	$bmp = New-Icon $s
	$bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
	$bmp.Dispose()
	$images += [PSCustomObject]@{ Size = $s; Data = $ms.ToArray() }
	$ms.Dispose()
}

$icoPath = Join-Path $root 'windows\runner\resources\app_icon.ico'
$fs = [System.IO.File]::Create($icoPath)
$bw = New-Object System.IO.BinaryWriter $fs
$bw.Write([uint16]0)                    # reserved
$bw.Write([uint16]1)                    # type: icon
$bw.Write([uint16]$images.Count)
$offset = 6 + (16 * $images.Count)
foreach ($img in $images) {
	$dim = if ($img.Size -ge 256) { 0 } else { [byte]$img.Size }
	$bw.Write([byte]$dim)               # width (0 = 256)
	$bw.Write([byte]$dim)               # height
	$bw.Write([byte]0)                  # palette size
	$bw.Write([byte]0)                  # reserved
	$bw.Write([uint16]1)                # colour planes
	$bw.Write([uint16]32)               # bits per pixel
	$bw.Write([uint32]$img.Data.Length)
	$bw.Write([uint32]$offset)
	$offset += $img.Data.Length
}
foreach ($img in $images) {
	$bw.Write($img.Data)
}
$bw.Dispose()
$fs.Dispose()
Write-Host "  $icoPath"

$src.Dispose()
Write-Host 'done'
