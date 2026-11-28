# ghostgrid for Windows: the Makefile's counterpart. Run it as build.cmd
# <task> (from PowerShell, cmd or Explorer, past the execution policy), or
# as .\build.ps1 <task> in PowerShell where scripts are allowed.
#
#   .\build.ps1 run       # dev build with hot reload (tauri dev)
#   .\build.ps1 test      # unit tests: TypeScript (vitest) and Rust (cargo test)
#   .\build.ps1 app       # release build of the app: target\release\ghostgrid.exe
#   .\build.ps1 check     # typecheck, lint, tests and the release app (what CI runs)
#   .\build.ps1 installer # NSIS installer: target\release\bundle\nsis\
#   .\build.ps1 install   # build the installer and install it for this user
#   .\build.ps1 release   # signed installer + updater feed (see README, Windows releases)
#   .\build.ps1 clean
param([Parameter(Position = 0)][string]$Task = "run")
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

function Invoke-Step([string]$Name, [scriptblock]$Body) {
    Write-Host "==> $Name" -ForegroundColor Cyan
    & $Body
    if ($LASTEXITCODE -ne 0) { throw "$Name failed (exit $LASTEXITCODE)" }
}

function Test-Running {
    return [bool](Get-Process -Name ghostgrid -ErrorAction SilentlyContinue)
}

function Install-Deps {
    if (-not (Test-Path node_modules)) { Invoke-Step "npm ci" { npm ci } }
}

function Invoke-Tests {
    Install-Deps
    Invoke-Step "prepare (session helper, icons)" { node scripts/prepare.mjs }
    Invoke-Step "vitest" { npx vitest run }
    Invoke-Step "cargo test" { cargo test --workspace }
}

function Get-Version {
    return (Get-Content package.json -Raw | ConvertFrom-Json).version
}

switch ($Task) {
    "run" { Install-Deps; Invoke-Step "tauri dev" { npx tauri dev } }
    "test" { Invoke-Tests }
    "app" { Install-Deps; Invoke-Step "tauri build (no installer)" { npx tauri build --no-bundle } }
    "check" {
        Install-Deps
        Invoke-Step "typecheck" { npx tsc --noEmit }
        Invoke-Tests
        Invoke-Step "clippy" { cargo clippy --workspace --all-targets -- -D warnings }
        Invoke-Step "tauri build (no installer)" { npx tauri build --no-bundle }
    }
    "installer" { Install-Deps; Invoke-Step "tauri build" { npx tauri build } }
    "install" {
        if (Test-Running) { throw "ghostgrid is running: quit it (Ctrl+Shift+Q) and run install again" }
        Install-Deps
        Invoke-Step "tauri build" { npx tauri build }
        $setup = Get-ChildItem target\release\bundle\nsis\*-setup.exe | Sort-Object LastWriteTime | Select-Object -Last 1
        Invoke-Step "install $($setup.Name)" { Start-Process $setup.FullName -ArgumentList "/S" -Wait; $global:LASTEXITCODE = 0 }
        Write-Host "Installed ghostgrid for this user. Settings > Put gg on PATH adds the gg command."
    }
    "release" {
        # Updates are signed with the key Tauri's signer made (README, Windows
        # releases); the app only accepts updates signed with it.
        if (-not $env:TAURI_SIGNING_PRIVATE_KEY) { throw "set TAURI_SIGNING_PRIVATE_KEY (and TAURI_SIGNING_PRIVATE_KEY_PASSWORD) first" }
        if (-not $env:GHOSTGRID_UPDATER_PUBKEY) { throw "set GHOSTGRID_UPDATER_PUBKEY to the public key, so the build can check its own updates" }
        $version = Get-Version
        $overrides = @{ bundle = @{ createUpdaterArtifacts = $true } }
        if ($env:GHOSTGRID_SIGN_THUMBPRINT) {
            # Authenticode signing with a certificate from the user's store.
            $overrides.bundle.windows = @{ certificateThumbprint = $env:GHOSTGRID_SIGN_THUMBPRINT; digestAlgorithm = "sha256"; timestampUrl = "http://timestamp.digicert.com" }
        }
        $config = Join-Path ([IO.Path]::GetTempPath()) "ghostgrid-release.json"
        $overrides | ConvertTo-Json -Depth 5 | Set-Content $config -Encoding utf8
        Install-Deps
        Invoke-Step "tauri build (release)" { npx tauri build --config $config }
        $setup = Get-ChildItem "target\release\bundle\nsis\ghostgrid_${version}_*-setup.exe" | Select-Object -First 1
        $signature = Get-Content "$($setup.FullName).sig" -Raw
        $out = New-Item -ItemType Directory -Force build\release
        Copy-Item $setup.FullName, "$($setup.FullName).sig" $out
        $hash = (Get-FileHash $setup.FullName -Algorithm SHA256).Hash.ToLower()
        "$hash  $($setup.Name)" | Set-Content (Join-Path $out "$($setup.Name).sha256") -Encoding ascii
        $feed = [ordered]@{
            version = $version
            notes = "ghostgrid $version"
            pub_date = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            platforms = @{ "windows-x86_64" = @{ signature = $signature.Trim(); url = "https://github.com/brettbergin/ghostgrid/releases/download/v$version/$($setup.Name)" } }
        }
        $feed | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $out "latest-windows.json") -Encoding utf8
        Write-Host "Wrote $out. Upload with: gh release upload v$version build\release\*"
    }
    "clean" { Remove-Item -Recurse -Force target, dist, node_modules, src-tauri\gen, src-tauri\binaries, src-tauri\icons -ErrorAction SilentlyContinue }
    default { throw "unknown task '$Task' (run, test, app, check, installer, install, release, clean)" }
}
