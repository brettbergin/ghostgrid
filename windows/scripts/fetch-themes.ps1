# Adds the full set of Ghostty color themes (iTerm2-Color-Schemes' ghostty
# folder, MIT) to resources\themes, next to the bundled Catppuccin ones, so
# any `theme = <name>` from a Ghostty config resolves. Needs git.
#
#   pwsh scripts/fetch-themes.ps1
param([string]$Destination = (Join-Path $PSScriptRoot "..\resources\themes"))
$ErrorActionPreference = "Stop"
$temp = Join-Path ([IO.Path]::GetTempPath()) "ghostgrid-themes-$([guid]::NewGuid())"
try {
    git clone --quiet --depth 1 --filter=blob:none --sparse https://github.com/mbadolato/iTerm2-Color-Schemes.git $temp
    git -C $temp sparse-checkout set ghostty
    New-Item -ItemType Directory -Force $Destination | Out-Null
    Get-ChildItem (Join-Path $temp "ghostty") -File | Copy-Item -Destination $Destination -Force
    Copy-Item (Join-Path $temp "LICENSE") (Join-Path $Destination "LICENSE-iTerm2-Color-Schemes") -Force
    $count = (Get-ChildItem (Join-Path $temp "ghostty") -File).Count
    Write-Host "Added $count themes to $Destination"
} finally {
    if (Test-Path $temp) { Remove-Item $temp -Recurse -Force }
}
