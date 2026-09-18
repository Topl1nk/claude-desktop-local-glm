# Builds the shortcut/taskbar icons from the Claude Desktop installed on THIS computer:
#   assets\claude-subscription-orange.ico - the app's own logo, unchanged
#   assets\claude-local-grey.ico          - the same logo in greyscale, for the local window
# The Claude logo is Anthropic's trademark, so the repository ships no icon files: each user derives
# them locally from their own copy of the app. Called by install.ps1 and desktop-mode.ps1.
param([string]$OutDir = (Join-Path (Split-Path $PSScriptRoot -Parent) 'assets'))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$package = Get-AppxPackage -Name Claude | Select-Object -First 1
if (-not $package) { throw 'Claude Desktop is not installed - no logo to build the icons from.' }
$source = Join-Path $package.InstallLocation 'assets\Square150x150Logo.scale-200.png'
if (-not (Test-Path -LiteralPath $source)) { throw "Claude Desktop logo not found: $source" }

function Get-Cropped([System.Drawing.Bitmap]$bmp) {
  # Drop the transparent margin so the logo fills the icon.
  $minX = $bmp.Width; $minY = $bmp.Height; $maxX = -1; $maxY = -1
  for ($y = 0; $y -lt $bmp.Height; $y++) {
    for ($x = 0; $x -lt $bmp.Width; $x++) {
      if ($bmp.GetPixel($x, $y).A -gt 0) {
        if ($x -lt $minX) { $minX = $x }; if ($x -gt $maxX) { $maxX = $x }
        if ($y -lt $minY) { $minY = $y }; if ($y -gt $maxY) { $maxY = $y }
      }
    }
  }
  if ($maxX -lt 0) { return $bmp }
  $bmp.Clone((New-Object System.Drawing.Rectangle($minX, $minY, ($maxX - $minX + 1), ($maxY - $minY + 1))), $bmp.PixelFormat)
}

function Get-Resized([System.Drawing.Image]$img, [int]$size, [bool]$grey) {
  $out = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($out)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $attr = New-Object System.Drawing.Imaging.ImageAttributes
  if ($grey) {
    # Luminance, slightly darkened, alpha kept.
    $l = 0.85
    $r = [single](0.299 * $l); $gr = [single](0.587 * $l); $b = [single](0.114 * $l)
    $matrix = New-Object System.Drawing.Imaging.ColorMatrix(,[single[][]]@(
      [single[]]@($r, $r, $r, 0, 0), [single[]]@($gr, $gr, $gr, 0, 0), [single[]]@($b, $b, $b, 0, 0),
      [single[]]@(0, 0, 0, 1, 0), [single[]]@(0, 0, 0, 0, 1)))
    $attr.SetColorMatrix($matrix)
  }
  $g.DrawImage($img, (New-Object System.Drawing.Rectangle(0, 0, $size, $size)), 0, 0, $img.Width, $img.Height, [System.Drawing.GraphicsUnit]::Pixel, $attr)
  $g.Dispose()
  $out
}

function Get-DibBytes([System.Drawing.Bitmap]$bmp) {
  # Classic icon frame: BITMAPINFOHEADER + bottom-up 32-bit BGRA pixels + an empty AND mask.
  # .NET's Icon class (used for the tray icon) renders only this format correctly at small sizes;
  # PNG-compressed frames come out as noise.
  $s = $bmp.Width
  $rect = New-Object System.Drawing.Rectangle(0, 0, $s, $s)
  $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $pixels = New-Object byte[] ($s * $s * 4)
  [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $pixels, 0, $pixels.Length)
  $bmp.UnlockBits($data)
  $maskRow = [int]([math]::Ceiling($s / 32) * 4)
  $ms = New-Object System.IO.MemoryStream
  $w = New-Object System.IO.BinaryWriter($ms)
  $w.Write([uint32]40); $w.Write([int32]$s); $w.Write([int32]($s * 2)); $w.Write([uint16]1); $w.Write([uint16]32)
  $w.Write([uint32]0); $w.Write([uint32]($pixels.Length + $maskRow * $s)); $w.Write([int32]0); $w.Write([int32]0)
  $w.Write([uint32]0); $w.Write([uint32]0)
  for ($y = $s - 1; $y -ge 0; $y--) { $w.Write($pixels, $y * $s * 4, $s * 4) }
  $w.Write((New-Object byte[] ($maskRow * $s)))
  $w.Flush()
  , $ms.ToArray()
}

function Save-Ico([System.Drawing.Image]$img, [bool]$grey, [string]$path) {
  # An .ico is a directory of images, one per size: classic frames below 256 px, PNG for 256 px.
  $sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256
  $pngs = foreach ($s in $sizes) {
    $bmp = Get-Resized $img $s $grey
    if ($s -lt 256) { , (Get-DibBytes $bmp) }
    else {
      $ms = New-Object System.IO.MemoryStream
      $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
      , $ms.ToArray()
    }
    $bmp.Dispose()
  }
  $fs = [System.IO.File]::Create($path)
  $w = New-Object System.IO.BinaryWriter($fs)
  $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
  $offset = 6 + 16 * $sizes.Count
  for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]; $dim = if ($s -ge 256) { 0 } else { $s }
    $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$pngs[$i].Length); $w.Write([uint32]$offset)
    $offset += $pngs[$i].Length
  }
  foreach ($p in $pngs) { $w.Write($p) }
  $w.Close()
}

New-Item -ItemType Directory -Force $OutDir | Out-Null
$logo = Get-Cropped (New-Object System.Drawing.Bitmap($source))
Save-Ico $logo $false (Join-Path $OutDir 'claude-subscription-orange.ico')
Save-Ico $logo $true (Join-Path $OutDir 'claude-local-grey.ico')
$logo.Dispose()
Write-Host "Icons written to $OutDir"
