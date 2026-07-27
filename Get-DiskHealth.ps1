<#
.SYNOPSIS
    Compatibility launcher for DiskHealth.ps1.
.DESCRIPTION
    Preserves existing Get-DiskHealth.ps1 commands while forwarding all explicitly
    supplied parameters to the canonical DiskHealth.ps1 entrypoint.
#>
[CmdletBinding()]
param(
    [string]$ComputerName = 'localhost',
    [string]$Username = 'user',
    [AllowEmptyString()]
    [string]$Password = '',
    [AllowEmptyString()]
    [string]$FilePath = '',
    [switch]$InstallSmartctl,
    [switch]$Discover,
    [AllowEmptyString()]
    [string]$DiscoveryStateRoot = '',
    [switch]$Benchmark,
    [Parameter(DontShow)]
    [switch]$NoUI,
    [Parameter(DontShow)]
    [switch]$EmbeddedRemote
)

$entrypoint = Join-Path -Path $PSScriptRoot -ChildPath 'DiskHealth.ps1'
if (-not (Test-Path -LiteralPath $entrypoint -PathType Leaf)) {
    throw "Missing canonical DiskHealth entrypoint: $entrypoint"
}

& $entrypoint @PSBoundParameters
