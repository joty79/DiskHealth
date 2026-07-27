[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'DiskHealth.ps1'
$source = Get-Content -LiteralPath $scriptPath -Raw

if ($source -notmatch '--id\s+smartmontools\.smartmontools') {
    throw 'The opt-in smartmontools install must use the exact official winget package ID.'
}
if ($source -notmatch '--scope\s+machine') {
    throw 'The opt-in smartmontools install must use machine scope.'
}
if ($source -notmatch "C:\\Program Files\\smartmontools\\bin\\smartctl\.exe") {
    throw 'The opt-in smartmontools install must verify the standard Program Files path.'
}

$forbiddenInstallPatterns = @(
    'downloads\.sourceforge\.net',
    'smartmontools-7\.4',
    'New-Item[^\r\n]+C:\\[^\r\n]+smartmontools',
    'Expand-Archive[^\r\n]+C:\\smartmontools',
    'DestinationPath\s+["'']C:\\smartmontools'
)
foreach ($pattern in $forbiddenInstallPatterns) {
    if ($source -match $pattern) {
        throw "Forbidden legacy smartmontools install pattern found: $pattern"
    }
}

Write-Host 'DiskHealth tooling policy tests passed.' -ForegroundColor Green
