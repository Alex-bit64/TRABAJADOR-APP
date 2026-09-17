param([string]$Source = '')

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$projectDir = Split-Path -Parent $PSScriptRoot
if (!$Source) { $Source = Join-Path $projectDir 'assets/app_icon_source.jpeg' }
$sourceImage = [System.Drawing.Image]::FromFile((Resolve-Path -LiteralPath $Source))

function Save-Logo([string]$RelativePath, [int]$Width, [int]$Height) {
    $targetPath = Join-Path $projectDir $RelativePath
    $bitmap = New-Object System.Drawing.Bitmap($Width, $Height, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb))
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([System.Drawing.Color]::White)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $ratio = [Math]::Min($Width / $sourceImage.Width, $Height / $sourceImage.Height)
        $drawWidth = [int][Math]::Round($sourceImage.Width * $ratio)
        $drawHeight = [int][Math]::Round($sourceImage.Height * $ratio)
        $graphics.DrawImage($sourceImage, [int](($Width - $drawWidth) / 2), [int](($Height - $drawHeight) / 2), $drawWidth, $drawHeight)
        $bitmap.Save($targetPath, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

try {
    Save-Logo 'assets/logo.png' 1024 1024
    Save-Logo 'assets/launch_logo.png' 512 512
    $densities = @{mdpi = 48; hdpi = 72; xhdpi = 96; xxhdpi = 144; xxxhdpi = 192}
    foreach ($density in $densities.Keys) {
        Save-Logo "android/app/src/main/res/mipmap-$density/ic_launcher.png" $densities[$density] $densities[$density]
    }
    # Preserve the splash image dimensions specified by the existing platform setup.
    $splashes = Get-ChildItem -Path (Join-Path $projectDir 'android/app/src/main/res/drawable-*/launch_logo.png')
    $splashes += Get-ChildItem -Path (Join-Path $projectDir 'ios/Runner/Assets.xcassets/LaunchImage.imageset/*.png')
    foreach ($splash in $splashes) {
        $existing = [System.Drawing.Image]::FromFile($splash.FullName)
        $width = $existing.Width
        $height = $existing.Height
        $existing.Dispose()
        Save-Logo ($splash.FullName.Substring($projectDir.Length + 1)) $width $height
    }
    $iconSet = 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
    $contents = Get-Content -LiteralPath (Join-Path $projectDir "$iconSet/Contents.json") -Raw | ConvertFrom-Json
    foreach ($icon in $contents.images) {
        $points = [double]($icon.size.Split('x')[0])
        $scale = [double]($icon.scale.TrimEnd('x'))
        $pixels = [int][Math]::Round($points * $scale)
        Save-Logo "$iconSet/$($icon.filename)" $pixels $pixels
    }
    Write-Output 'Logos generados para Android, iOS y las pantallas de la aplicación.'
} finally {
    $sourceImage.Dispose()
}
