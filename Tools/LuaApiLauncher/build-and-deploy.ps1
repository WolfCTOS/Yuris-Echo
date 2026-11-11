# Builds the launcher and deploys it into the game folder.
#   .\build-and-deploy.ps1            -> Release, win-x64
#   .\build-and-deploy.ps1 -Debug
#
# The executable is shipped as "Yuri's Echo.exe"; the assembly itself stays
# "YurisEcho" because WPF bakes the assembly name into the XAML resource URI
# and an apostrophe there breaks the lookup at startup.

param([switch]$Debug)

$ErrorActionPreference = "Stop"

$project = Join-Path $PSScriptRoot "LuaApiLauncher"
$config = if ($Debug) { "Debug" } else { "Release" }
$out = Join-Path $project "bin\$config\net10.0-windows\win-x64"
$game = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Write-Host "Building $config ..." -ForegroundColor Cyan
dotnet build $project -c $config -r win-x64 --self-contained false
if ($LASTEXITCODE -ne 0) { throw "build failed" }

Write-Host "Deploying to $game ..." -ForegroundColor Cyan
Get-Process | Where-Object { $_.ProcessName -like "Yuri*" } | Stop-Process -Force -ErrorAction SilentlyContinue

$files = @(
    @{ From = "Yuri's Echo.exe";                To = "Yuri's Echo.exe" },
    @{ From = "YurisEcho.dll";                  To = "YurisEcho.dll" },
    @{ From = "YurisEcho.runtimeconfig.json";   To = "YurisEcho.runtimeconfig.json" },
    @{ From = "YurisEcho.deps.json";            To = "YurisEcho.deps.json" },
    @{ From = "YurisEcho.pdb";                  To = "YurisEcho.pdb" }
)

foreach ($f in $files) {
    $src = Join-Path $out $f.From
    if (-not (Test-Path $src)) { Write-Warning "missing: $($f.From)"; continue }
    Copy-Item $src (Join-Path $game $f.To) -Force
    Write-Host "  $($f.To)" -ForegroundColor DarkGray
}

Write-Host "Done. Run 'Yuri's Echo.exe' from $game" -ForegroundColor Green
