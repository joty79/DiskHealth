[CmdletBinding()]
param()

$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'DiskHealth.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors) {
    throw "Production script has parser errors: $($parseErrors -join '; ')"
}

$requiredFunctions = @('Get-SmartctlWindowsDeviceIndex', 'Get-KnownUsbNvmeBridgeType')
foreach ($functionName in $requiredFunctions) {
    $functionAst = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq $functionName
    }, $true) | Select-Object -First 1

    if (-not $functionAst) {
        throw "Required production function not found: $functionName"
    }
    Invoke-Expression $functionAst.Extent.Text
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Label)
    if ($Actual -ne $Expected) {
        throw "$Label failed. Expected '$Expected', got '$Actual'."
    }
}

Assert-Equal (Get-SmartctlWindowsDeviceIndex '/dev/sda') 0 'First smartctl drive'
Assert-Equal (Get-SmartctlWindowsDeviceIndex '/dev/sdz') 25 'Last single-letter smartctl drive'
Assert-Equal (Get-SmartctlWindowsDeviceIndex '/dev/sdaa') 26 'First double-letter smartctl drive'
Assert-Equal (Get-SmartctlWindowsDeviceIndex '/dev/sdab') 27 'Second double-letter smartctl drive'
Assert-Equal (Get-SmartctlWindowsDeviceIndex '/dev/pd2') 2 'PhysicalDrive alias'
Assert-Equal (Get-SmartctlWindowsDeviceIndex '\\.\PhysicalDrive2') 2 'Native PhysicalDrive path'
Assert-Equal (Get-SmartctlWindowsDeviceIndex '/dev/nvme0') $null 'Unsupported device path'

# Regression sample: Windows exposes the USB/UASP wrapper as Disk 2 with a
# different model/serial, while smartctl exposes the underlying SK hynix NVMe.
$windowsDisk = [PSCustomObject]@{
    Index = 2
    Model = 'SKHynix_ HFS256GD9TNG8075 SCSI Disk Device'
    SerialNumber = '{D}'
}
$scanCandidate = [PSCustomObject]@{
    name = '/dev/sdc'
    type = 'sntjmicron'
}
$underlyingIdentity = [PSCustomObject]@{
    model_name = 'SKHynix_HFS256GD9TNG-L5B0B'
    serial_number = 'NJ03N7065108Y3N41'
}

$serialMatch = ($windowsDisk.SerialNumber -replace '\s+', '') -eq ($underlyingIdentity.serial_number -replace '\s+', '')
$modelMatch = $windowsDisk.Model.Trim() -eq $underlyingIdentity.model_name.Trim()
Assert-Equal ($serialMatch -or $modelMatch) $false 'USB wrapper identity intentionally differs'
Assert-Equal (Get-SmartctlWindowsDeviceIndex $scanCandidate.name) $windowsDisk.Index 'PhysicalDrive index survives USB wrapper'

$knownBridge = Get-KnownUsbNvmeBridgeType @(
    'SCSI\DISK&VEN_SKHYNIX_&PROD_HFS256GD9TNG8075\6&185859FC&2&000000',
    'USB\VID_152D&PID_0581\MSFT30DB0000000001',
    'USB\ROOT_HUB30\4&2A872284&0&0'
)
Assert-Equal $knownBridge.UsbId '152D:0581' 'Known bridge USB ID'
Assert-Equal $knownBridge.SmartctlType 'sntjmicron' 'Known bridge smartctl type'
Assert-Equal (Get-KnownUsbNvmeBridgeType @('USB\VID_1234&PID_5678\UNKNOWN')) $null 'Unknown bridge is not guessed'

$source = Get-Content -LiteralPath $scriptPath -Raw
if ($source -notmatch '\$parsedCheck\.device\.protocol\s+-eq\s+"NVMe"') {
    throw 'Production script does not promote the underlying smartctl NVMe protocol.'
}
if ($source -notmatch 'USB/UASP bridge -> NVMe') {
    throw 'Production script does not report NVMe behind the USB/UASP bridge.'
}
if ($source -notmatch '(?s)\$matchingDevices\s*=\s*@\(\s*if\s*\(\$indexedDevices\.Count') {
    throw 'Production script does not preserve a single matching candidate as an array.'
}

Write-Host 'PASS: smartctl Windows device-index and USB/UASP NVMe bridge regressions.' -ForegroundColor Green
