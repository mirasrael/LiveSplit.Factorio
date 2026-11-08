# Builds LiveSplit.FactorioStep.dll with the .NET Framework compiler that ships with Windows.
#   .\build.ps1 [-LiveSplit <LiveSplit folder>] [-Install]
# -Install copies the DLL into <LiveSplit>\Components (close LiveSplit first).
param(
    [string]$LiveSplit = "",
    [switch]$Install
)
$ErrorActionPreference = 'Stop'
if (-not $LiveSplit) {
    $candidates = @(
        "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\LiveSplit.LiveSplit__DefaultSource",
        "$env:ProgramFiles\LiveSplit",
        "${env:ProgramFiles(x86)}\LiveSplit"
    )
    $LiveSplit = $candidates | Where-Object { Test-Path (Join-Path $_ 'LiveSplit.Core.dll') } | Select-Object -First 1
}
if (-not $LiveSplit -or -not (Test-Path (Join-Path $LiveSplit 'LiveSplit.Core.dll'))) {
    throw "LiveSplit folder not found; pass -LiveSplit <folder with LiveSplit.Core.dll>"
}
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$out = Join-Path $PSScriptRoot 'bin\LiveSplit.FactorioStep.dll'
New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
& $csc /nologo /target:library /optimize+ /utf8output /codepage:65001 "/out:$out" `
    "/r:$LiveSplit\LiveSplit.Core.dll" "/r:$LiveSplit\UpdateManager.dll" `
    /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:System.Xml.dll `
    (Join-Path $PSScriptRoot 'FactorioStep.cs')
if ($LASTEXITCODE -ne 0) { throw "build failed" }
Write-Host "built $out"
if ($Install) {
    Copy-Item $out (Join-Path $LiveSplit 'Components') -Force
    Write-Host "installed to $LiveSplit\Components"
}
