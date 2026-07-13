<#
.SYNOPSIS
    Διαγνωστικό Υγείας Δίσκων (Disk Health Diagnostics) μέσω smartctl, WMI/CIM ή CDI Reports.
.DESCRIPTION
    Ανακτά στοιχεία δίσκων, S.M.A.R.T. δεδομένα και Reliability Counters natively.
    Χρησιμοποιεί κατά προτίμηση το smartctl (αν είναι εγκατεστημένο) για πλήρη NVMe/SATA διαγνωστικά.
    Υποστηρίζει επίσης την εισαγωγή και ανάλυση αποθηκευμένων CrystalDiskInfo txt reports.
    Παράγει ένα δομημένο report με emojis και χρώματα συμβατό με το Windows Terminal.
.PARAMETER ComputerName
    Το όνομα ή η IP διεύθυνση του απομακρυσμένου υπολογιστή.
.PARAMETER Username
    Το όνομα χρήστη για τη σύνδεση WinRM.
.PARAMETER Password
    Ο κωδικός πρόσβασης για τη σύνδεση WinRM (κενός από προεπιλογή).
.PARAMETER FilePath
    Τοπικό μονοπάτι σε ένα CrystalDiskInfo txt report για offline ανάλυση.
#>
[CmdletBinding()]
param(
    [string]$ComputerName = "192.168.1.118",
    [string]$Username = "user",
    [string]$Password = "",
    [string]$FilePath = ""
)

# 1. Καθορισμός Χρωμάτων (Console Colors)
$Cyan = "Cyan"
$Yellow = "Yellow"
$Red = "Red"
$Green = "Green"
$White = "White"
$Gray = "DarkGray"

# Λογική επίλυσης ονομάτων attributes ανάλογα με τη μάρκα/controller
function Get-AttributeName {
    param(
        [int]$id,
        [string]$brand
    )
    if ($brand -eq "Samsung") {
        switch ($id) {
            0xAF { return "Program Fail Count (Chip)" }
            0xB0 { return "Erase Fail Count (Chip)" }
            0xB1 { return "Wear Leveling Count" }
            0xB2 { return "Used Reserved Block Count (Chip)" }
            0xB3 { return "Used Reserved Block Count (Total)" }
            0xB4 { return "Available Reserved Blocks (Total)" }
            0xB7 { return "Runtime Bad Block (Total)" }
            0xC3 { return "ECC Error Rate" }
            0xEA { return "Total GB Written to NAND" }
            0xEB { return "POR Recovery Count" }
            0xEC { return "Manufacturer Specific (EC)" }
            0xED { return "Manufacturer Specific (ED)" }
            0xEE { return "Manufacturer Specific (EE)" }
        }
    }
    elseif ($brand -eq "Patriot") {
        switch ($id) {
            0xA0 { return "Uncorrectable Sectors Read/Write" }
            0xA1 { return "Number of Valid Spare Blocks" }
            0xA2 { return "Total Erase Count" }
            0xA3 { return "Max PE Cycle" }
            0xA4 { return "Average Erase Count" }
            0xA5 { return "Maximum Erase Count" }
            0xA6 { return "Total Bad Block Count" }
            0xA7 { return "SSD Protect Mode" }
            0xA8 { return "SATA Phy Error Count" }
            0xA9 { return "Remain Life" }
            0xAB { return "Program Fail Count" }
            0xAC { return "Erase Fail Count" }
            0xAE { return "Unexpected Power Loss Count" }
            0xAF { return "ECC Fail Count" }
            0xB2 { return "Runtime Invalid Block Count" }
            0xBB { return "Reported Uncorrectable Errors" }
            0xC2 { return "Enclosure Temperature" }
            0xC3 { return "Cumulative Corrected ECC" }
            0xC4 { return "Reallocation Event Count" }
            0xC7 { return "Ultra DMA CRC Error Count" }
            0xCE { return "Min. Erase Count" }
            0xCF { return "Max Erase Count" }
            0xE8 { return "Available Reserved Space" }
            0xF1 { return "Write Life Time" }
            0xF2 { return "Read Life Time" }
            0xF5 { return "Flash Write Sector Count (NAND)" }
            0xF9 { return "Total GB Written to NAND (TLC)" }
            0xFA { return "Total GB Written to NAND (SLC)" }
        }
    }
    elseif ($brand -eq "SanDisk") {
        switch ($id) {
            0xA5 { return "TLC Block Write/Erase Count" }
            0xA6 { return "Minimum Erase Count" }
            0xA7 { return "Maximum Erase Count" }
            0xA8 { return "SATA PHY Error Count" }
            0xA9 { return "Total Bad Blocks" }
            0xAA { return "Reserve Block Count" }
            0xAB { return "Program Fail Count" }
            0xAC { return "Erase Fail Count" }
            0xAD { return "Average Erase Count" }
            0xAE { return "Unexpected Power Loss Count" }
            0xE6 { return "Media Wearout Indicator" }
            0xE8 { return "Available Reserved Space" }
            0xEA { return "Total NAND GB Written" }
            0xF4 { return "Total NAND GB Written (Host)" }
        }
    }
    elseif ($brand -eq "NVMe") {
        switch ($id) {
            0x01 { return "Critical Warning" }
            0x02 { return "Composite Temperature" }
            0x03 { return "Available Spare" }
            0x04 { return "Available Spare Threshold" }
            0x05 { return "Percentage Used" }
            0x06 { return "Data Units Read" }
            0x07 { return "Data Units Written" }
            0x08 { return "Host Read Commands" }
            0x09 { return "Host Write Commands" }
            0x0A { return "Controller Busy Time" }
            0x0B { return "Power Cycles" }
            0x0C { return "Power On Hours" }
            0x0D { return "Unsafe Shutdowns" }
            0x0E { return "Media and Data Integrity Errors" }
            0x0F { return "Number of Error Information Log Entries" }
            0x10 { return "Warning Composite Temperature Time" }
            0x11 { return "Critical Composite Temperature Time" }
            0x12 { return "Temperature Sensor 1" }
            0x13 { return "Temperature Sensor 2" }
        }
    }
    
    # Generic / Standard fallback
    switch ($id) {
        0x01 { return "Raw Read Error Rate" }
        0x05 { return "Reallocated Sectors Count" }
        0x09 { return "Power-On Hours" }
        0x0C { return "Power Cycle Count" }
        0xB5 { return "Program Fail Count (Total)" }
        0xB6 { return "Erase Fail Count (Total)" }
        0xB8 { return "End-to-End Error / Error Detection" }
        0xBB { return "Uncorrectable Errors" }
        0xBC { return "Command Timeout" }
        0xBE { return "Airflow Temperature" }
        0xC2 { return "Temperature" }
        0xC4 { return "Reallocation Event Count" }
        0xC5 { return "Current Pending Sector Count" }
        0xC6 { return "Offline Uncorrectable Error Count" }
        0xC7 { return "UltraDMA CRC Error Count" }
        0xE9 { return "Normalized Media Wear-out" }
        default { return "Unknown Attribute" }
    }
}

Write-Host "`n======================================================================" -ForegroundColor $Cyan
Write-Host "  💾 ΔΙΑΓΝΩΣΤΙΚΟ ΥΓΕΙΑΣ ΔΙΣΚΩΝ (Disk Health Diagnostics)" -ForegroundColor $Cyan
Write-Host "======================================================================" -ForegroundColor $Cyan

# 2. Συλλογή Δεδομένων (WMI/WinRM ή File Import)
$collected = @()

if ($FilePath) {
    Write-Host "  📁 Ανάλυση Αρχείου Report: " -NoNewline -ForegroundColor $White
    Write-Host "$FilePath" -ForegroundColor $Yellow
    Write-Host "----------------------------------------------------------------------" -ForegroundColor $Cyan
    
    if (-not (Test-Path $FilePath)) {
        Write-Host "❌ Το αρχείο δεν βρέθηκε στο μονοπάτι $FilePath" -ForegroundColor $Red
        return
    }
    
    $lines = Get-Content -Path $FilePath
    $model = ""
    $firmware = ""
    $sn = ""
    $sizeBytes = 0
    $hours = 0
    $cycles = 0
    $temp = 0
    $healthVal = 100
    $healthText = "GOOD"
    $interface = "SATA"
    $standard = ""
    $transferMode = ""
    $rotationRate = ""
    $smartLines = @()
    
    $inSmart = $false
    foreach ($line in $lines) {
        if ($line -match "Model\s+:\s+(.+)") { $model = $Matches[1].Trim() }
        elseif ($line -match "Firmware\s+:\s+(.+)") { $firmware = $Matches[1].Trim() }
        elseif ($line -match "Serial Number\s+:\s+(.+)") { $sn = $Matches[1].Trim() }
        elseif ($line -match "Interface\s+:\s+(.+)") { $interface = $Matches[1].Trim() }
        elseif ($line -match "Standard\s+:\s+(.+)") { $standard = $Matches[1].Trim() }
        elseif ($line -match "Transfer Mode\s+:\s+(.+)") { $transferMode = $Matches[1].Trim() }
        elseif ($line -match "Rotation Rate\s+:\s+(.+)") { $rotationRate = $Matches[1].Trim() }
        elseif ($line -match "Disk Size\s+:\s+([0-9,.]+)\s+GB") { 
            $cleanSize = $Matches[1] -replace ',', '.'
            $sizeBytes = [double]$cleanSize * 1GB
        }
        elseif ($line -match "Power On Hours\s+:\s+(\d+)") { $hours = [int]$Matches[1] }
        elseif ($line -match "Power On Count\s+:\s+(\d+)") { $cycles = [int]$Matches[1] }
        elseif ($line -match "Temperature\s+:\s+(\d+)\s+C") { $temp = [int]$Matches[1] }
        elseif ($line -match "Health Status\s+:\s+(.+?)\s+\((\d+)\s+%\)") {
            $healthVal = [int]$Matches[2]
            $healthText = $Matches[1].Trim()
        }
        elseif ($line -match "-- S.M.A.R.T. --") {
            $inSmart = $true
            continue
        }
        elseif ($inSmart -and ($line -match "^--+" -or $line -match "^[A-Z_]+$")) {
            $inSmart = $false
        }
        elseif ($inSmart -and ($line -match "^([0-9A-F]{2})\s+([0-9_]+)\s+([0-9_]+)\s+([0-9_]+)\s+([0-9A-F]{12})\s+(.*)")) {
            $smartLines += [PSCustomObject]@{
                IDHex = "0x" + $Matches[1]
                ID = [int]("0x" + $Matches[1])
                Current = [int]($Matches[2] -replace '_', '')
                Worst = [int]($Matches[3] -replace '_', '')
                Threshold = [int]($Matches[4] -replace '_', '')
                RawVal = [System.Convert]::ToUInt64($Matches[5], 16)
                RawHex = "0x" + $Matches[5]
                Name = $Matches[6].Trim()
                IsNVMe = $false
            }
        }
        elseif ($inSmart -and ($line -match "^([0-9A-F]{2})\s+([0-9A-F]{12})\s+(.*)")) {
            $smartLines += [PSCustomObject]@{
                IDHex = "0x" + $Matches[1]
                ID = [int]("0x" + $Matches[1])
                Current = 100
                Worst = 100
                Threshold = 0
                RawVal = [System.Convert]::ToUInt64($Matches[2], 16)
                RawHex = "0x" + $Matches[2]
                Name = $Matches[3].Trim()
                IsNVMe = $true
            }
        }
    }
    
    $collected += [PSCustomObject]@{
        Index = 0
        Model = $model
        SerialNumber = $sn
        Size = $sizeBytes
        InterfaceType = $interface
        PNPDeviceID = "FILE_IMPORT"
        MediaType = "SSD"
        BusType = if ($interface -like "*NVM*" -or $interface -like "*Express*") { "NVMe" } else { "SATA" }
        Firmware = $firmware
        Letters = @("C:")
        SMARTData = $null
        SMARTThresholds = $null
        IsAdmin = $true
        ParsedAttributes = $smartLines
        ImportedFromFile = $true
        ReliabilityCounter = $null
        SmartctlJSON = $null
        Standard = $standard
        TransferMode = $transferMode
        RotationRate = $rotationRate
    }
} else {
    # Σύνδεση & WMI Query
    $isLocal = ($ComputerName -eq "localhost" -or $ComputerName -eq "127.0.0.1")
    if ($isLocal) {
        Write-Host "  📍 Στόχος: Τοπικό Σύστημα (Localhost)" -ForegroundColor $White
    } else {
        Write-Host "  🌐 Στόχος: $ComputerName (Χρήστης: $Username)" -ForegroundColor $White
    }
    Write-Host "  🔧 Μέθοδος: Native smartctl & WMI/CIM Queries" -ForegroundColor $White
    Write-Host "----------------------------------------------------------------------" -ForegroundColor $Cyan
    
    $secstr = New-Object System.Security.SecureString
    if ($Password) {
        foreach ($char in $Password.ToCharArray()) {
            $secstr.AppendChar($char)
        }
    }
    $cred = New-Object System.Management.Automation.PSCredential($Username, $secstr)

    $scriptBlock = {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        
        $disks = Get-CimInstance -ClassName Win32_DiskDrive
        $physicalDisks = Get-PhysicalDisk -ErrorAction SilentlyContinue
        $allData = Get-CimInstance -ClassName MSStorageDriver_FailurePredictData -Namespace root\wmi -ErrorAction SilentlyContinue
        $allThresholds = Get-CimInstance -ClassName MSStorageDriver_FailurePredictThresholds -Namespace root\wmi -ErrorAction SilentlyContinue
        $partitions = Get-CimInstance -ClassName Win32_DiskPartition
        $logicalToPart = Get-CimInstance -ClassName Win32_LogicalDiskToPartition
        
        $reliabilityCounters = @()
        if ($isAdmin -and $physicalDisks) {
            foreach ($pd in $physicalDisks) {
                $rc = Get-StorageReliabilityCounter -PhysicalDisk $pd -ErrorAction SilentlyContinue
                if ($rc) { $reliabilityCounters += $rc }
            }
        }

        # Ανίχνευση του smartctl
        $smartctlPath = $null
        $smartctlCmd = Get-Command smartctl -ErrorAction SilentlyContinue
        if ($smartctlCmd) {
            $smartctlPath = $smartctlCmd.Source
        } else {
            $commonPaths = @(
                "C:\Program Files\smartmontools\bin\smartctl.exe",
                "C:\Program Files (x86)\smartmontools\bin\smartctl.exe",
                "C:\smartmontools\smartctl.exe",
                "C:\smartmontools\bin\smartctl.exe"
            )
            foreach ($path in $commonPaths) {
                if (Test-Path $path) {
                    $smartctlPath = $path
                    break
                }
            }
        }

        $results = @()
        foreach ($disk in $disks) {
            $pnpClean = $disk.PNPDeviceID
            
            $dataInstance = $allData | Where-Object { 
                ($_.InstanceName -replace '_[0-9]+$', '') -eq $pnpClean 
            }
            $thresholdInstance = $allThresholds | Where-Object { 
                ($_.InstanceName -replace '_[0-9]+$', '') -eq $pnpClean 
            }
            
            $snClean = $disk.SerialNumber -replace '\s+', ''
            $physDisk = $null
            if ($physicalDisks) {
                $physDisk = $physicalDisks | Where-Object { 
                    ($_.SerialNumber -replace '\s+', '') -eq $snClean 
                }
            }
            
            $letters = @()
            $diskParts = $partitions | Where-Object { $_.DiskIndex -eq $disk.Index }
            foreach ($part in $diskParts) {
                $lp = $logicalToPart | Where-Object { $_.Antecedent.DeviceID -eq $part.DeviceID }
                if ($lp) {
                    $letters += $lp.Dependent.DeviceID
                }
            }
            
            $relCounter = $null
            if ($physDisk -and $reliabilityCounters) {
                $relCounter = $reliabilityCounters | Where-Object { $_.DeviceId -eq $physDisk.DeviceId }
            }

            # PCI Link Speed & Width Query natively via PnP Property
            $transferMode = "SATA (Link Speed Unknown)"
            $standard = "SATA (ACS-2)"
            $rotationRate = "---- (SSD)"
            if ($physDisk -and ($physDisk.MediaType -eq "HDD" -or $physDisk.MediaType -eq "Rotational")) {
                $rotationRate = "7200 RPM"
            }
            
            $isNVMe = ($physDisk -and $physDisk.BusType -eq "NVMe") -or ($disk.InterfaceType -like "*NVM*" -or $disk.InterfaceType -like "*Express*")
            if ($isNVMe) {
                $standard = "NVM Express"
                $pciDev = Get-PnpDevice -Class SCSIAdapter -ErrorAction SilentlyContinue | Where-Object { 
                    $_.FriendlyName -like "*NVM*" -or $_.FriendlyName -like "*NVMe*"
                } | Select-Object -First 1
                
                if ($pciDev) {
                    $curSpeed = Get-PnpDeviceProperty -InstanceId $pciDev.InstanceId -KeyName "DEVPKEY_PciDevice_CurrentLinkSpeed" -ErrorAction SilentlyContinue
                    $curWidth = Get-PnpDeviceProperty -InstanceId $pciDev.InstanceId -KeyName "DEVPKEY_PciDevice_CurrentLinkWidth" -ErrorAction SilentlyContinue
                    $maxSpeed = Get-PnpDeviceProperty -InstanceId $pciDev.InstanceId -KeyName "DEVPKEY_PciDevice_MaxLinkSpeed" -ErrorAction SilentlyContinue
                    $maxWidth = Get-PnpDeviceProperty -InstanceId $pciDev.InstanceId -KeyName "DEVPKEY_PciDevice_MaxLinkWidth" -ErrorAction SilentlyContinue
                    
                    if ($curSpeed -and $curWidth) {
                        $genMap = @{ 1 = "1.0"; 2 = "2.0"; 3 = "3.0"; 4 = "4.0"; 5 = "5.0" }
                        $cSpeed = if ($genMap.ContainsKey($curSpeed.Data)) { $genMap[$curSpeed.Data] } else { $curSpeed.Data }
                        $cWidth = $curWidth.Data
                        $mSpeed = if ($maxSpeed -and $genMap.ContainsKey($maxSpeed.Data)) { $genMap[$maxSpeed.Data] } else { $maxSpeed.Data }
                        $mWidth = if ($maxWidth) { $maxWidth.Data } else { $cWidth }
                        $transferMode = "PCIe $cSpeed x$cWidth | PCIe $mSpeed x$mWidth"
                    }
                }
            }

            # Ανάκτηση δεδομένων από smartctl
            $smartctlData = $null
            if ($smartctlPath -and $isAdmin) {
                $rawOutput = & $smartctlPath -a "/dev/pd$($disk.Index)" --json 2>$null
                if ($LASTEXITCODE -eq 0 -or $rawOutput) {
                    $smartctlData = $rawOutput | Out-String
                }
            }
            
            $results += [PSCustomObject]@{
                Index = $disk.Index
                Model = $disk.Model
                SerialNumber = $disk.SerialNumber.Trim()
                Size = $disk.Size
                InterfaceType = $disk.InterfaceType
                PNPDeviceID = $disk.PNPDeviceID
                MediaType = if ($physDisk) { $physDisk.MediaType } else { "SSD" }
                BusType = if ($physDisk) { $physDisk.BusType } else { "SATA" }
                Firmware = if ($physDisk) { $physDisk.FirmwareVersion } else { $disk.FirmwareRevision }
                Letters = $letters
                SMARTData = if ($dataInstance) { $dataInstance.VendorSpecific } else { $null }
                SMARTThresholds = if ($thresholdInstance) { $thresholdInstance.VendorSpecific } else { $null }
                IsAdmin = $isAdmin
                ReliabilityCounter = if ($relCounter) {
                    [PSCustomObject]@{
                        Wear = $relCounter.Wear
                        Temperature = $relCounter.Temperature
                        TemperatureMax = $relCounter.TemperatureMax
                        ReadErrorsTotal = $relCounter.ReadErrorsTotal
                        WriteErrorsTotal = $relCounter.WriteErrorsTotal
                        ReadLatencyMax = $relCounter.ReadLatencyMax
                        WriteLatencyMax = $relCounter.WriteLatencyMax
                    }
                } else { $null }
                ImportedFromFile = $false
                SmartctlJSON = $smartctlData
                Standard = $standard
                TransferMode = $transferMode
                RotationRate = $rotationRate
            }
        }
        $results
    }

    try {
        if ($isLocal) {
            $collected = Invoke-Command -ScriptBlock $scriptBlock
        } else {
            # Έλεγχος και αυτόματη προσθήκη στα TrustedHosts του WinRM Client
            $currentTrusted = (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction SilentlyContinue).Value
            $trustedList = if ($currentTrusted) { $currentTrusted -split ',' | ForEach-Object { $_.Trim() } } else { @() }
            
            if ($currentTrusted -ne "*" -and -not ($trustedList -contains $ComputerName)) {
                Write-Host "  ⚠️ Η IP/Hostname '$ComputerName' δεν είναι στα TrustedHosts του WinRM." -ForegroundColor $Yellow
                Write-Host "  🔧 Προσπάθεια αυτόματης προσθήκης..." -ForegroundColor $Cyan
                
                $newValue = if ($currentTrusted) { "$currentTrusted,$ComputerName" } else { $ComputerName }
                
                $currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
                $isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
                
                if ($isAdmin) {
                    try {
                        Set-Item WSMan:\localhost\Client\TrustedHosts -Value $newValue -Force -ErrorAction Stop
                        Write-Host "  ✅ Προστέθηκε με επιτυχία στα TrustedHosts!" -ForegroundColor $Green
                    } catch {
                        Write-Host "  ❌ Αποτυχία προσθήκης στα TrustedHosts: $_" -ForegroundColor $Red
                    }
                } else {
                    Write-Host "  🔑 Απαιτούνται δικαιώματα Administrator. Δοκιμή elevation..." -ForegroundColor $Yellow
                    
                    # Δημιουργία scratch script για αποφυγή command line/serialization errors (Κανόνας 4 & 3)
                    $scratchFile = Join-Path $env:TEMP "set-trustedhosts-$pid.ps1"
                    "Set-Item WSMan:\localhost\Client\TrustedHosts -Value '$newValue' -Force" | Out-File -FilePath $scratchFile -Encoding utf8 -Force
                    
                    $gsudoPath = Get-Command gsudo -ErrorAction SilentlyContinue
                    if ($gsudoPath) {
                        & gsudo pwsh -NoProfile -File $scratchFile
                        if ($LASTEXITCODE -eq 0) {
                            Write-Host "  ✅ Προστέθηκε στα TrustedHosts μέσω gsudo!" -ForegroundColor $Green
                        } else {
                            Write-Host "  ❌ Αποτυχία προσθήκης μέσω gsudo." -ForegroundColor $Red
                        }
                    } else {
                        try {
                            Start-Process pwsh -ArgumentList "-NoProfile -File `"$scratchFile`"" -Verb RunAs -Wait -ErrorAction Stop
                            Write-Host "  ✅ Προστέθηκε στα TrustedHosts μέσω UAC!" -ForegroundColor $Green
                        } catch {
                            Write-Host "  ❌ Αποτυχία προσθήκης (άρνηση UAC ή σφάλμα)." -ForegroundColor $Red
                        }
                    }
                    Remove-Item $scratchFile -ErrorAction SilentlyContinue
                }
            }

            try {
                $session = New-PSSession -ComputerName $ComputerName -Credential $cred -ErrorAction Stop
            } catch {
                $err = $_.ToString()
                $isAuthError = ($err -like "*Access is denied*" -or $err -like "*Authentication failed*" -or $err -like "*Credentials*")
                $isInteractive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
                
                if ($isAuthError -and $isInteractive) {
                    Write-Host "  ❌ WinRM: Άρνηση πρόσβασης (Access Denied) με τα τρέχοντα credentials." -ForegroundColor $Yellow
                    Write-Host "  👤 Παρακαλώ εισάγετε στοιχεία σύνδεσης για το PC '$ComputerName':" -ForegroundColor $Cyan
                    
                    $promptUser = Read-Host "     Username"
                    if (-not [string]::IsNullOrEmpty($promptUser)) {
                        Write-Host "     Password: " -NoNewline -ForegroundColor $White
                        $promptPass = Read-Host -AsSecureString
                        
                        $promptCred = New-Object System.Management.Automation.PSCredential($promptUser, $promptPass)
                        
                        Write-Host "  🔄 Προσπάθεια επανασύνδεσης με τα νέα στοιχεία..." -ForegroundColor $Cyan
                        try {
                            $session = New-PSSession -ComputerName $ComputerName -Credential $promptCred -ErrorAction Stop
                        } catch {
                            Write-Host "  ❌ Αποτυχία σύνδεσης και με τα νέα στοιχεία." -ForegroundColor $Red
                            throw $_
                        }
                    } else {
                        throw $_
                    }
                } else {
                    throw $_
                }
            }
            
            # Αυτόματη εγκατάσταση του smartctl.exe αν λείπει από το remote PC
            $remoteSmartctlExists = Invoke-Command -Session $session -ScriptBlock {
                $paths = @(
                    "smartctl",
                    "C:\Program Files\smartmontools\bin\smartctl.exe",
                    "C:\Program Files\smartmontools\smartctl.exe",
                    "C:\smartmontools\smartctl.exe",
                    "C:\smartmontools\bin\smartctl.exe"
                )
                $found = $false
                foreach ($p in $paths) {
                    if (Get-Command $p -ErrorAction SilentlyContinue) { $found = $true; break }
                }
                $found
            }
            
            if (-not $remoteSmartctlExists) {
                Write-Host "  ⚠️ Το remote PC δεν διαθέτει το εργαλείο smartctl. Έναρξη αυτόματης εγκατάστασης..." -ForegroundColor $Yellow
                
                # Προσπάθεια 1: Αντιγραφή από το τοπικό PC (offline/γρήγορη μέθοδος)
                $localSmartctl = $null
                $localPaths = @(
                    "C:\Program Files\smartmontools\bin\smartctl.exe",
                    "C:\Program Files\smartmontools\smartctl.exe",
                    "C:\smartmontools\smartctl.exe",
                    "C:\smartmontools\bin\smartctl.exe"
                )
                foreach ($lp in $localPaths) {
                    if (Test-Path $lp) { $localSmartctl = $lp; break }
                }
                
                $success = $false
                if ($localSmartctl) {
                    Write-Host "  📦 Αντιγραφή τοπικού smartctl.exe στο remote PC..." -ForegroundColor $Cyan
                    try {
                        Invoke-Command -Session $session -ScriptBlock {
                            if (-not (Test-Path "C:\smartmontools")) {
                                New-Item -Path "C:\" -Name "smartmontools" -ItemType "Directory" -Force | Out-Null
                            }
                        }
                        Copy-Item -Path $localSmartctl -Destination "C:\smartmontools\smartctl.exe" -ToSession $session -Force
                        Write-Host "  ✅ Το smartctl.exe μεταφέρθηκε και εγκαταστάθηκε επιτυχώς!" -ForegroundColor $Green
                        $success = $true
                    } catch {
                        Write-Host "  🔸 Αποτυχία τοπικής αντιγραφής: $_. Προσπάθεια λήψης από το Internet..." -ForegroundColor $Yellow
                    }
                }
                
                # Προσπάθεια 2: Λήψη από SourceForge (Internet fallback)
                if (-not $success) {
                    Write-Host "  🌐 Λήψη smartmontools zip από το SourceForge..." -ForegroundColor $Cyan
                    $installScript = {
                        try {
                            $url = "https://downloads.sourceforge.net/project/smartmontools/smartmontools/7.4/smartmontools-7.4-1.win32.zip"
                            $zipPath = "C:\smartmontools.zip"
                            if (-not (Test-Path "C:\smartmontools")) {
                                New-Item -Path "C:\" -Name "smartmontools" -ItemType "Directory" -Force | Out-Null
                            }
                            Write-Host "     - Κατέβασμα αρχείου..." -ForegroundColor $Gray
                            Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
                            Write-Host "     - Αποσυμπίεση αρχείου..." -ForegroundColor $Gray
                            Expand-Archive -Path $zipPath -DestinationPath "C:\smartmontools" -Force -ErrorAction Stop
                            Remove-Item $zipPath -Force
                            return $true
                        } catch {
                            Write-Host "     ❌ Σφάλμα κατά την εγκατάσταση: $_" -ForegroundColor $Red
                            return $false
                        }
                    }
                    $res = Invoke-Command -Session $session -ScriptBlock $installScript
                    if ($res) {
                        Write-Host "  ✅ Η εγκατάσταση του smartctl ολοκληρώθηκε με επιτυχία!" -ForegroundColor $Green
                    } else {
                        Write-Host "  ❌ Αποτυχία αυτόματης εγκατάστασης του smartctl." -ForegroundColor $Red
                    }
                }
            }

            $collected = Invoke-Command -Session $session -ScriptBlock $scriptBlock
            Remove-PSSession $session
        }
    } catch {
        Write-Host "❌ Σφάλμα κατά τη σύνδεση ή τη συλλογή δεδομένων: $_" -ForegroundColor $Red
        return
    }
}

function Show-DriveMenu {
    param (
        [array]$Drives
    )
    
    try {
        $selectedIndex = 0
        
        $options = @()
        foreach ($d in $Drives) {
            $lettersStr = if ($d.Letters) { "($($d.Letters -join ', '))" } else { "" }
            $options += "Disk $($d.Index): $($d.Model) - $([Math]::Round($d.Size / 1GB, 2)) GB $lettersStr"
        }
        $options += "Διάγνωση όλων των δίσκων (All Drives)"
        
        # Hide cursor
        try { [Console]::CursorVisible = $false } catch {}
        
        $firstRun = $true
        # 1 για header, options.Count για τις επιλογές, 1 για το ESC line
        $menuHeight = $options.Count + 2
        
        while ($true) {
            if (-not $firstRun) {
                try {
                    $pos = $Host.UI.RawUI.CursorPosition
                    $pos.Y = [Math]::Max(0, $pos.Y - $menuHeight)
                    $pos.X = 0
                    $Host.UI.RawUI.CursorPosition = $pos
                } catch {}
            } else {
                $firstRun = $false
            }
            
            Write-Host "### 🔵 Ανιχνεύθηκαν $($Drives.Count) φυσικοί δίσκοι. Επιλέξτε δίσκο για διάγνωση:" -ForegroundColor $Cyan
            for ($i = 0; $i -lt $options.Count; $i++) {
                if ($i -eq $selectedIndex) {
                    Write-Host "  ➔ [ " -NoNewline -ForegroundColor $Yellow
                    Write-Host $options[$i] -NoNewline -ForegroundColor $Cyan
                    Write-Host " ]" -ForegroundColor $Yellow
                } else {
                    Write-Host "     $($options[$i])" -ForegroundColor $Gray
                }
            }
            Write-Host "  💡 [ESC] Έξοδος από το πρόγραμμα (Exit)" -ForegroundColor $Red
            
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq "UpArrow") {
                $selectedIndex = if ($selectedIndex -eq 0) { $options.Count - 1 } else { $selectedIndex - 1 }
            }
            elseif ($key.Key -eq "DownArrow") {
                $selectedIndex = if ($selectedIndex -eq $options.Count - 1) { 0 } else { $selectedIndex + 1 }
            }
            elseif ($key.Key -eq "Escape") {
                $selectedIndex = -1
                break
            }
            elseif ($key.Key -eq "Enter") {
                break
            }
        }
        
        try { [Console]::CursorVisible = $true } catch {}
        Write-Host ""
        return $selectedIndex
    } catch {
        # Fallback αν αποτύχει το console interaction
        return $Drives.Count
    }
}

if (-not $collected) {
    Write-Host "⚠️ Δεν βρέθηκαν φυσικοί δίσκοι στο σύστημα." -ForegroundColor $Yellow
    return
}

$runLoop = $true
while ($runLoop) {
    $selectedDrives = $collected
    $isInteractive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected -and $Host.UI.RawUI -and $Host.Name -notlike "*Background*" -and $Host.Name -notlike "*Service*"
    
    if ($collected.Count -gt 1 -and $isInteractive) {
        Clear-Host
        Write-Host "======================================================================" -ForegroundColor $Cyan
        Write-Host "  💾 ΔΙΑΓΝΩΣΤΙΚΟ ΥΓΕΙΑΣ ΔΙΣΚΩΝ (Disk Health Diagnostics)" -ForegroundColor $Cyan
        Write-Host "======================================================================" -ForegroundColor $Cyan
        Write-Host "  🌐 Στόχος: $ComputerName (Χρήστης: $Username)" -ForegroundColor $White
        Write-Host "  🔧 Μέθοδος: Native smartctl & WMI/CIM Queries" -ForegroundColor $White
        Write-Host "----------------------------------------------------------------------" -ForegroundColor $Cyan
        
        $choice = Show-DriveMenu -Drives $collected
        if ($choice -eq -1) {
            Clear-Host
            Write-Host "👋 Αντίο! (Exiting...)" -ForegroundColor $Green
            break
        }
        
        if ($choice -lt $collected.Count) {
            $selectedDrives = @($collected[$choice])
        }
        Clear-Host
    } else {
        $runLoop = $false
    }

    # 3. Ανάλυση και Παρουσίαση για κάθε δίσκο
    foreach ($disk in $selectedDrives) {
    $isDiskNVMe = ($disk.BusType -eq "NVMe" -or $disk.InterfaceType -like "*NVM*" -or $disk.InterfaceType -like "*Express*")
    
    $brand = "Generic"
    if ($isDiskNVMe) {
        $brand = "NVMe"
    } elseif ($disk.Model -like "*SAMSUNG*") {
        $brand = "Samsung"
    } elseif ($disk.Model -like "*Patriot*" -or $disk.Model -like "*P210*" -or $disk.Model -like "*Silicon*" -or $disk.Model -like "*Intenso*") {
        $brand = "Patriot"
    } elseif ($disk.Model -like "*SanDisk*" -or $disk.Model -like "*WD*" -or $disk.Model -like "*Western*" -or $disk.Model -like "*WDC*") {
        $brand = "SanDisk"
    }

    # PARSE SMARTCTL JSON DATA IF AVAILABLE
    $smart = $null
    if ($disk.SmartctlJSON) {
        try {
            $smart = $disk.SmartctlJSON | ConvertFrom-Json
        } catch {}
    }

    if ($smart) {
        if ($smart.nvme_version.string) {
            $disk.Standard = "NVM Express " + $smart.nvme_version.string
        } elseif ($smart.ata_version.string) {
            $disk.Standard = $smart.ata_version.string
        }
        
        # Ανάκτηση SATA Link Speed (Transfer Mode)
        $speedObj = if ($smart.interface_speed) { $smart.interface_speed } else { $smart.sata_link_speed }
        if ($speedObj) {
            $curSpeed = $speedObj.current.string
            $maxSpeed = $speedObj.max.string
            if ($curSpeed -and $maxSpeed) {
                $speedMap = @{ "1.5 Gb/s" = "SATA/150"; "3.0 Gb/s" = "SATA/300"; "6.0 Gb/s" = "SATA/600" }
                $cSpeed = if ($speedMap.ContainsKey($curSpeed)) { $speedMap[$curSpeed] } else { $curSpeed }
                $mSpeed = if ($speedMap.ContainsKey($maxSpeed)) { $speedMap[$maxSpeed] } else { $maxSpeed }
                $disk.TransferMode = "$cSpeed | $mSpeed"
            }
        }
    }

    Write-Host "### 🔵 Στοιχεία Δίσκου (Index: $($disk.Index))" -ForegroundColor $Cyan
    Write-Host "  🔸 Μοντέλο: " -NoNewline -ForegroundColor $White
    Write-Host "***$($disk.Model)***" -ForegroundColor $Cyan
    Write-Host "  🔸 Serial Number: " -NoNewline -ForegroundColor $White
    Write-Host "***$($disk.SerialNumber)***" -ForegroundColor $Cyan
    Write-Host "  🔸 Χωρητικότητα: " -NoNewline -ForegroundColor $White
    Write-Host "$([Math]::Round($disk.Size / 1GB, 2)) GB" -ForegroundColor $Gray
    Write-Host "  🔸 Τύπος Μέσου: " -NoNewline -ForegroundColor $White
    Write-Host "$($disk.MediaType) ($($disk.BusType))" -ForegroundColor $Gray
    Write-Host "  🔸 Drive Letter(s): " -NoNewline -ForegroundColor $White
    Write-Host "$($disk.Letters -join ', ')" -ForegroundColor $Yellow
    Write-Host "  🔸 Firmware: " -NoNewline -ForegroundColor $White
    Write-Host "$($disk.Firmware)" -ForegroundColor $Gray
    
    if ($disk.Standard) {
        Write-Host "  🔸 Standard: " -NoNewline -ForegroundColor $White
        Write-Host "$($disk.Standard)" -ForegroundColor $Gray
    }
    if ($disk.TransferMode) {
        Write-Host "  🔸 Transfer Mode: " -NoNewline -ForegroundColor $White
        Write-Host "$($disk.TransferMode)" -ForegroundColor $Yellow
    }
    if ($disk.RotationRate) {
        Write-Host "  🔸 Rotation Rate: " -NoNewline -ForegroundColor $White
        Write-Host "$($disk.RotationRate)" -ForegroundColor $Gray
    }
    if (-not $disk.ImportedFromFile) {
        Write-Host "  🔸 Δικαιώματα: " -NoNewline -ForegroundColor $White
        if ($disk.IsAdmin) {
            Write-Host "[Verified with Admin rights]" -ForegroundColor $Green
        } else {
            Write-Host "[User level - SMART access might be limited]" -ForegroundColor $Yellow
        }
    }
    Write-Host ""

    $attributes = @()
    if ($smart) {
        if ($smart.nvme_smart_health_information_log) {
            $brand = "NVMe"
            $log = $smart.nvme_smart_health_information_log
            
            # Extract Temp Sensors
            $temp1 = if ($log.temperature_sensors -and $log.temperature_sensors.Count -gt 0) { $log.temperature_sensors[0] } else { 0 }
            $temp2 = if ($log.temperature_sensors -and $log.temperature_sensors.Count -gt 1) { $log.temperature_sensors[1] } else { 0 }
            
            # Extract thermal management values (if any)
            $thm1_trans = if ($log.thm_temp1_trans_count -ne $null) { $log.thm_temp1_trans_count } else { 0 }
            $thm2_trans = if ($log.thm_temp2_trans_count -ne $null) { $log.thm_temp2_trans_count } else { 0 }
            $thm1_time = if ($log.thm_temp1_total_time -ne $null) { $log.thm_temp1_total_time } else { 0 }
            $thm2_time = if ($log.thm_temp2_total_time -ne $null) { $log.thm_temp2_total_time } else { 0 }

            $nvmeMapping = @(
                @{ ID = 0x01; Name = "Critical Warning"; Raw = $log.critical_warning }
                @{ ID = 0x02; Name = "Composite Temperature"; Raw = $log.temperature; IsCelsius = $true }
                @{ ID = 0x03; Name = "Available Spare"; Raw = $log.available_spare }
                @{ ID = 0x04; Name = "Available Spare Threshold"; Raw = $log.available_spare_threshold }
                @{ ID = 0x05; Name = "Percentage Used"; Raw = $log.percentage_used }
                @{ ID = 0x06; Name = "Data Units Read"; Raw = $log.data_units_read }
                @{ ID = 0x07; Name = "Data Units Written"; Raw = $log.data_units_written }
                @{ ID = 0x08; Name = "Host Read Commands"; Raw = $log.host_reads }
                @{ ID = 0x09; Name = "Host Write Commands"; Raw = $log.host_writes }
                @{ ID = 0x0A; Name = "Controller Busy Time"; Raw = $log.controller_busy_time }
                @{ ID = 0x0B; Name = "Power Cycles"; Raw = $log.power_cycles }
                @{ ID = 0x0C; Name = "Power On Hours"; Raw = $log.power_on_hours }
                @{ ID = 0x0D; Name = "Unsafe Shutdowns"; Raw = $log.unsafe_shutdowns }
                @{ ID = 0x0E; Name = "Media and Data Integrity Errors"; Raw = $log.media_errors }
                @{ ID = 0x0F; Name = "Number of Error Information Log Entries"; Raw = $log.num_err_log_entries }
                @{ ID = 0x10; Name = "Warning Composite Temperature Time"; Raw = $log.warning_temp_time }
                @{ ID = 0x11; Name = "Critical Composite Temperature Time"; Raw = $log.critical_comp_time }
                @{ ID = 0x12; Name = "Temperature Sensor 1"; Raw = $temp1; IsCelsius = $true }
                @{ ID = 0x13; Name = "Temperature Sensor 2"; Raw = $temp2; IsCelsius = $true }
                @{ ID = 0x1A; Name = "Thermal Management Temperature 1 Transition Count"; Raw = $thm1_trans }
                @{ ID = 0x1B; Name = "Thermal Management Temperature 2 Transition Count"; Raw = $thm2_trans }
                @{ ID = 0x1C; Name = "Total Time For Thermal Management Temperature 1"; Raw = $thm1_time }
                @{ ID = 0x1D; Name = "Total Time For Thermal Management Temperature 2"; Raw = $thm2_time }
            )
            foreach ($item in $nvmeMapping) {
                $attributes += [PSCustomObject]@{
                    IDHex     = "0x{0:X2}" -f $item.ID
                    ID        = $item.ID
                    Name      = $item.Name
                    Current   = 100
                    Worst     = 100
                    Threshold = 0
                    Raw       = [uint64]$item.Raw
                    RawHex    = "0x{0:X12}" -f [uint64]$item.Raw
                    IsCelsius = $item.IsCelsius
                }
            }
        }
        elseif ($smart.ata_smart_attributes.table) {
            foreach ($attr in $smart.ata_smart_attributes.table) {
                $id = $attr.id
                $attrName = Get-AttributeName $id $brand
                $attributes += [PSCustomObject]@{
                    IDHex     = "0x{0:X2}" -f $id
                    ID        = $id
                    Name      = if ($attrName -ne "Unknown Attribute") { $attrName } else { $attr.name }
                    Current   = $attr.value
                    Worst     = $attr.worst
                    Threshold = $attr.thresh
                    Raw       = [uint64]$attr.raw.value
                    RawHex    = "0x{0:X12}" -f [uint64]$attr.raw.value
                }
            }
        }
    }
    elseif ($disk.ImportedFromFile) {
        foreach ($pAttr in $disk.ParsedAttributes) {
            $attrName = Get-AttributeName $pAttr.ID $brand
            $attributes += [PSCustomObject]@{
                IDHex     = $pAttr.IDHex
                ID        = $pAttr.ID
                Name      = if ($attrName -ne "Unknown Attribute") { $attrName } else { $pAttr.Name }
                Current   = $pAttr.Current
                Worst     = $pAttr.Worst
                Threshold = $pAttr.Threshold
                Raw       = $pAttr.RawVal
                RawHex    = $pAttr.RawHex
            }
        }
    } else {
        # FALLBACK TO WMI BYTES FOR SATA DRIVES
        if ($disk.SMARTData) {
            for ($offset = 2; $offset -lt 500; $offset += 12) {
                $id = $disk.SMARTData[$offset]
                if ($id -eq 0 -or $id -eq 255) { continue }
                
                $current = $disk.SMARTData[$offset + 3]
                $worst = $disk.SMARTData[$offset + 4]
                
                $rawBytes = $disk.SMARTData[($offset + 5)..($offset + 10)]
                $rawBytesExtended = $rawBytes + @(0, 0)
                $rawVal = [BitConverter]::ToUInt64($rawBytesExtended, 0)
                
                $thresholdVal = 0
                if ($disk.SMARTThresholds) {
                    for ($tOffset = 2; $tOffset -lt 500; $tOffset += 12) {
                        $tId = $disk.SMARTThresholds[$tOffset]
                        if ($tId -eq $id) {
                            $thresholdVal = $disk.SMARTThresholds[$tOffset + 1]
                            break
                        }
                    }
                }

                $idInt = [int]$id
                $attrName = Get-AttributeName $idInt $brand
                
                $attributes += [PSCustomObject]@{
                    IDHex     = "0x{0:X2}" -f $id
                    ID        = $idInt
                    Name      = $attrName
                    Current   = $current
                    Worst     = $worst
                    Threshold = $thresholdVal
                    Raw       = $rawVal
                    RawHex    = "0x{0:X12}" -f $rawVal
                }
            }
        }
    }

    # FALLBACK DIAGNOSTICS FOR NVMe (CIM-only, no file import, no smartctl)
    if (-not $attributes -and $isDiskNVMe -and -not $disk.ImportedFromFile) {
        # Ειδοποίηση 🚨🚨🚨 για εγκατάσταση smartctl
        Write-Host "🚨🚨🚨 ΠΡΟΕΙΔΟΠΟΙΗΣΗ: Για να λάβετε πλήρη S.M.A.R.T. ανάλυση για NVMe δίσκους, προτείνεται η εγκατάσταση του smartctl!" -ForegroundColor $Yellow
        Write-Host "       Μπορείτε να το εγκαταστήσετε τοπικά/remote εκτελώντας: winget install smartmontools`n" -ForegroundColor $Gray
        
        if ($disk.ReliabilityCounter) {
            $health = 100
            if ($disk.ReliabilityCounter.Wear -ne $null) {
                $health = 100 - $disk.ReliabilityCounter.Wear
            }
            
            $status = "GOOD"
            $statusColor = $Green
            $statusIcon = "✅"
            
            $cautionReasons = @()
            if ($disk.ReliabilityCounter.ReadErrorsTotal -gt 0) {
                $status = "CAUTION"
                $statusColor = $Yellow
                $statusIcon = "⚠️"
                $cautionReasons += "Total Read Errors ($($disk.ReliabilityCounter.ReadErrorsTotal))"
            }
            if ($disk.ReliabilityCounter.WriteErrorsTotal -gt 0) {
                $status = "CAUTION"
                $statusColor = $Yellow
                $statusIcon = "⚠️"
                $cautionReasons += "Total Write Errors ($($disk.ReliabilityCounter.WriteErrorsTotal))"
            }

            Write-Host "### 🔵 Κατάσταση Υγείας (Health Status) - NVMe/CIM Log" -ForegroundColor $Cyan
            Write-Host "  $statusIcon Κατάσταση: " -NoNewline -ForegroundColor $White
            Write-Host "$status " -NoNewline -ForegroundColor $statusColor
            Write-Host "(" -NoNewline -ForegroundColor $White
            Write-Host "$health%" -NoNewline -ForegroundColor $(if ($status -eq "GOOD") { $Green } else { $statusColor })
            Write-Host ")" -ForegroundColor $White
            
            if ($status -eq "GOOD") {
                Write-Host "  🔸 Ο δίσκος εμφανίζει εξαιρετική συμπεριφορά (Wear Leveling: $health% υγεία)." -ForegroundColor $Gray
                Write-Host "  🔸 Δεν καταγράφηκαν σφάλματα ανάγνωσης/εγγραφής (Read/Write Errors)." -ForegroundColor $Gray
            } else {
                Write-Host "  ⚠️ ΠΡΟΣΟΧΗ: Καταγράφηκαν σφάλματα αξιοπιστίας:" -ForegroundColor $Yellow
                foreach ($r in $cautionReasons) {
                    Write-Host "     - $r" -ForegroundColor $Yellow
                }
            }
            Write-Host ""
            
            Write-Host "### 🔵 Ανάλυση CIM Reliability Τιμών (NVMe Native)" -ForegroundColor $Cyan
            Write-Host "  +------------------------------------+---------------------+" -ForegroundColor $Gray
            Write-Host "  | Attribute Telemetry                | Value               |" -ForegroundColor $Gray
            Write-Host "  +------------------------------------+---------------------+" -ForegroundColor $Gray
            
            $rows = @(
                [PSCustomObject]@{ Name = "Estimated Health"; Value = "$health%"; Color = if ($health -le 60) { $Yellow } else { $Green } }
                [PSCustomObject]@{ Name = "Composite Temperature"; Value = if ($disk.ReliabilityCounter.Temperature -ne $null) { "$($disk.ReliabilityCounter.Temperature) C" } else { "---" }; Color = $Yellow }
                [PSCustomObject]@{ Name = "Composite Temperature (Max)"; Value = if ($disk.ReliabilityCounter.TemperatureMax -ne $null) { "$($disk.ReliabilityCounter.TemperatureMax) C" } else { "---" }; Color = $Gray }
                [PSCustomObject]@{ Name = "Total Read Errors"; Value = if ($disk.ReliabilityCounter.ReadErrorsTotal -ne $null) { $disk.ReliabilityCounter.ReadErrorsTotal } else { "0" }; Color = if ($disk.ReliabilityCounter.ReadErrorsTotal -gt 0) { $Yellow } else { $Gray } }
                [PSCustomObject]@{ Name = "Total Write Errors"; Value = if ($disk.ReliabilityCounter.WriteErrorsTotal -ne $null) { $disk.ReliabilityCounter.WriteErrorsTotal } else { "0" }; Color = if ($disk.ReliabilityCounter.WriteErrorsTotal -gt 0) { $Yellow } else { $Gray } }
                [PSCustomObject]@{ Name = "Max Read Latency"; Value = if ($disk.ReliabilityCounter.ReadLatencyMax -ne $null) { "$($disk.ReliabilityCounter.ReadLatencyMax) ms" } else { "---" }; Color = $Gray }
                [PSCustomObject]@{ Name = "Max Write Latency"; Value = if ($disk.ReliabilityCounter.WriteLatencyMax -ne $null) { "$($disk.ReliabilityCounter.WriteLatencyMax) ms" } else { "---" }; Color = $Gray }
            )
            
            foreach ($row in $rows) {
                $namePad = $row.Name.PadRight(34)
                $valPad = "$($row.Value)".PadRight(19)
                Write-Host "  | $namePad | $valPad |" -ForegroundColor ([ConsoleColor]$row.Color)
            }
            Write-Host "  +------------------------------------+---------------------+" -ForegroundColor $Gray
            
            Write-Host "`n### 🔵 Συμπέρασμα & Ενέργειες" -ForegroundColor $Cyan
            if ($status -eq "GOOD") {
                Write-Host "  ✅ Ο NVMe δίσκος είναι απόλυτα σταθερός και υγιής." -ForegroundColor $Green
            } else {
                Write-Host "  ⚠️ Συνιστάται backup λόγω καταγεγραμμένων σφαλμάτων read/write." -ForegroundColor $Yellow
            }
            Write-Host "`n"
            continue
        } else {
            Write-Host "⚠️ Δεν είναι δυνατή η ανάκτηση των δεδομένων S.M.A.R.T. ή Reliability Counters." -ForegroundColor $Yellow
            continue
        }
    }

    if (-not $attributes) {
        Write-Host "⚠️ Δεν βρέθηκαν S.M.A.R.T. δεδομένα για αυτόν τον δίσκο.`n" -ForegroundColor $Yellow
        continue
    }

    # 5. Υπολογισμός Υγείας (Health Calculation)
    $health = 100
    $healthSource = "Default"
    
    $wearB1 = $attributes | Where-Object { $_.ID -eq 0xB1 }
    $wearE9 = $attributes | Where-Object { $_.ID -eq 0xE9 }
    $wearA9 = $attributes | Where-Object { $_.ID -eq 0xA9 }
    $wear05 = $attributes | Where-Object { $_.ID -eq 0x05 }
    
    if ($brand -eq "Samsung" -and $wearB1) {
        $health = $wearB1.Current
        $healthSource = "Wear Leveling Count (0xB1)"
    } elseif ($brand -eq "Patriot" -and $wearA9) {
        $health = $wearA9.Raw
        $healthSource = "Remain Life (0xA9) Raw Value"
    } elseif ($brand -eq "NVMe" -and $wear05) {
        $health = 100 - $wear05.Raw
        $healthSource = "Percentage Used (0x05)"
    } elseif ($wearE9) {
        $health = $wearE9.Current
        $healthSource = "Media Wearout Indicator (0xE9)"
    } elseif ($wearB1) {
        $health = $wearB1.Current
        $healthSource = "Wear Leveling Count (0xB1)"
    }

    # Έλεγχος Κρίσιμων Σφαλμάτων (SATA & NVMe)
    $reallocated = $attributes | Where-Object { $_.ID -eq 0x05 }
    $uncorrectableA0 = $attributes | Where-Object { $_.ID -eq 0xA0 }
    $runtimeB2 = $attributes | Where-Object { $_.ID -eq 0xB2 }
    $runtimeB7 = $attributes | Where-Object { $_.ID -eq 0xB7 }
    $uncorrectableBB = $attributes | Where-Object { $_.ID -eq 0xBB }
    $reallocEventC4 = $attributes | Where-Object { $_.ID -eq 0xC4 }
    $pendingC5 = $attributes | Where-Object { $_.ID -eq 0xC5 }
    $uncorrectableC6 = $attributes | Where-Object { $_.ID -eq 0xC6 }
    
    $nvmeCriticalWarning = $attributes | Where-Object { $_.ID -eq 0x01 }
    $nvmeMediaErrors = $attributes | Where-Object { $_.ID -eq 0x0E }

    $status = "GOOD"
    $statusColor = $Green
    $statusIcon = "✅"
    $cautionReasons = @()
    $badReasons = @()
    
    if ($brand -ne "NVMe") {
        if ($reallocated -and $reallocated.Raw -gt 0) {
            $status = "CAUTION"
            $statusColor = $Yellow
            $statusIcon = "⚠️"
            $cautionReasons += "Reallocated Sectors ($($reallocated.Raw))"
        }
        if ($brand -eq "Patriot" -and $uncorrectableA0 -and $uncorrectableA0.Raw -gt 0) {
            $status = "CAUTION"
            $statusColor = $Yellow
            $statusIcon = "⚠️"
            $cautionReasons += "Uncorrectable Sectors Read/Write ($($uncorrectableA0.Raw))"
        }
        if ($runtimeB2 -and $runtimeB2.Raw -gt 0) {
            $status = "CAUTION"
            $statusColor = $Yellow
            $statusIcon = "⚠️"
            $cautionReasons += "Runtime Invalid Blocks ($($runtimeB2.Raw))"
        }
        if ($runtimeB7 -and $runtimeB7.Raw -gt 0) {
            $status = "CAUTION"
            $statusColor = $Yellow
            $statusIcon = "⚠️"
            $cautionReasons += "Runtime Bad Blocks ($($runtimeB7.Raw))"
        }
        if ($uncorrectableBB -and $uncorrectableBB.Raw -gt 0) {
            $status = "CAUTION"
            $statusColor = $Yellow
            $statusIcon = "⚠️"
            $cautionReasons += "Reported Uncorrectable Errors ($($uncorrectableBB.Raw))"
        }
        if ($reallocEventC4 -and $reallocEventC4.Raw -gt 0) {
            $status = "CAUTION"
            $statusColor = $Yellow
            $statusIcon = "⚠️"
            $cautionReasons += "Reallocation Events ($($reallocEventC4.Raw))"
        }
        if ($pendingC5 -and $pendingC5.Raw -gt 0) {
            $status = "CAUTION"
            $statusColor = $Yellow
            $statusIcon = "⚠️"
            $cautionReasons += "Current Pending Sectors ($($pendingC5.Raw))"
        }
        if ($uncorrectableC6 -and $uncorrectableC6.Raw -gt 0) {
            $status = "CAUTION"
            $statusColor = $Yellow
            $statusIcon = "⚠️"
            $cautionReasons += "Offline Uncorrectable Errors ($($uncorrectableC6.Raw))"
        }

        # Threshold crossings check
        foreach ($attr in $attributes) {
            if ($attr.Threshold -gt 0 -and $attr.Current -le $attr.Threshold) {
                $status = "BAD"
                $statusColor = $Red
                $statusIcon = "❌"
                $badReasons += "$($attr.Name) (Current $($attr.Current) <= Threshold $($attr.Threshold))"
            }
        }
    }
    else {
        if ($nvmeCriticalWarning -and $nvmeCriticalWarning.Raw -gt 0) {
            $status = "BAD"
            $statusColor = $Red
            $statusIcon = "❌"
            $badReasons += "Critical Warning (Status Code: $($nvmeCriticalWarning.RawHex))"
        }
        if ($nvmeMediaErrors -and $nvmeMediaErrors.Raw -gt 0) {
            $status = "CAUTION"
            $statusColor = $Yellow
            $statusIcon = "⚠️"
            $cautionReasons += "Media and Data Integrity Errors ($($nvmeMediaErrors.Raw))"
        }
    }

    # Health % color code
    $healthPercentColor = $Green
    if ($status -ne "GOOD") {
        $healthPercentColor = $statusColor
    } elseif ($health -le 60) {
        $healthPercentColor = $Yellow
    }

    Write-Host "### 🔵 Κατάσταση Υγείας (Health Status)" -ForegroundColor $Cyan
    Write-Host "  $statusIcon Κατάσταση: " -NoNewline -ForegroundColor $White
    Write-Host "$status " -NoNewline -ForegroundColor $statusColor
    Write-Host "(" -NoNewline -ForegroundColor $White
    Write-Host "$health%" -NoNewline -ForegroundColor $healthPercentColor
    Write-Host ")" -ForegroundColor $White

    if ($status -eq "GOOD") {
        Write-Host "  🔸 Ο δίσκος εμφανίζει φυσιολογική φθορά της NAND flash μνήμης (πηγή: $healthSource)." -ForegroundColor $Gray
        Write-Host "  🔸 Δεν υπάρχουν ενεργά σφάλματα υλικού (hardware failures) ή reallocated sectors." -ForegroundColor $Gray
    } elseif ($status -eq "CAUTION") {
        Write-Host "  ⚠️ ΠΡΟΣΟΧΗ: Εντοπίστηκαν προβλήματα στα παρακάτω κρίσιμα attributes:" -ForegroundColor $Yellow
        foreach ($r in $cautionReasons) {
            Write-Host "     - $r" -ForegroundColor $Yellow
        }
        Write-Host "  🔸 Συνιστάται η άμεση λήψη αντιγράφων ασφαλείας (backup) και η στενή παρακολούθηση των τιμών." -ForegroundColor $Gray
    } else {
        Write-Host "  🚨 ΚΡΙΣΙΜΟ: Ο δίσκος έχει ξεπεράσει τα όρια ασφαλείας του firmware!" -ForegroundColor $Red
        foreach ($r in $badReasons) {
            Write-Host "     - $r" -ForegroundColor $Red
        }
        Write-Host "  🚨 ALL CAPS: ΣΥΝΙΣΤΑΤΑΙ ΑΜΕΣΗ ΑΝΤΙΚΑΤΑΣΤΑΣΗ ΤΟΥ ΔΙΣΚΟΥ ΚΑΙ ΜΕΤΑΦΟΡΑ ΔΕΔΟΜΕΝΩΝ." -ForegroundColor $Red
    }
    Write-Host ""

    # 6. S.M.A.R.T. Table
    Write-Host "### 🔵 Ανάλυση S.M.A.R.T. Τιμών" -ForegroundColor $Cyan
    Write-Host "  +------+------------------------------------+---------+---------+-----------+-------------------+" -ForegroundColor $Gray
    Write-Host "  | ID   | Attribute Name                     | Current | Worst   | Threshold | Raw Value         |" -ForegroundColor $Gray
    Write-Host "  +------+------------------------------------+---------+---------+-----------+-------------------+" -ForegroundColor $Gray
    
    $visibleAttributes = $attributes | Sort-Object ID
    
    foreach ($attr in $visibleAttributes) {
        $nameTrunc = if ($attr.Name.Length -gt 34) { $attr.Name.Substring(0, 31) + "..." } else { $attr.Name.PadRight(34) }
        $idStr = $attr.IDHex.PadRight(4)
        
        $curStr = if ($brand -eq "NVMe") { "---".PadLeft(7) } else { "$($attr.Current)".PadLeft(7) }
        $worStr = if ($brand -eq "NVMe") { "---".PadLeft(7) } else { "$($attr.Worst)".PadLeft(7) }
        $thrStr = if ($brand -eq "NVMe") { "---".PadLeft(9) } else { "$($attr.Threshold)".PadLeft(9) }
        
        $rawDisplay = ""
        if ($attr.ID -eq 0x09 -or ($brand -eq "NVMe" -and $attr.ID -eq 0x0C)) {
            $rawDisplay = "$($attr.Raw) hrs".PadRight(17)
        } elseif ($attr.ID -eq 0x0C -or ($brand -eq "NVMe" -and $attr.ID -eq 0x0B)) {
            $rawDisplay = "$($attr.Raw) cycles".PadRight(17)
        } elseif ($attr.ID -eq 0xBE -or $attr.ID -eq 0xC2) {
            $rawDisplay = "$($attr.Raw) C".PadRight(17)
        } elseif ($brand -eq "NVMe" -and $attr.ID -eq 0x02) {
            $tempVal = if ($attr.IsCelsius) { $attr.Raw } elseif ($attr.Raw -gt 200) { $attr.Raw - 273 } else { $attr.Raw }
            $rawDisplay = "$tempVal C".PadRight(17)
        } elseif ($brand -eq "NVMe" -and ($attr.ID -eq 0x12 -or $attr.ID -eq 0x13)) {
            $tempVal = if ($attr.IsCelsius) { $attr.Raw } elseif ($attr.Raw -gt 200) { $attr.Raw - 273 } else { $attr.Raw }
            $rawDisplay = "$tempVal C".PadRight(17)
        } elseif ($brand -eq "NVMe" -and ($attr.ID -eq 0x06 -or $attr.ID -eq 0x07)) {
            $gbVal = [Math]::Round(($attr.Raw * 512000) / 1GB, 2)
            $rawDisplay = "$gbVal GB".PadRight(17)
        } else {
            $rawDisplay = "$($attr.Raw)".PadRight(17)
        }

        # Coloring
        $lineColor = $Gray
        if ($brand -ne "NVMe") {
            $isCriticalAttr = ($attr.ID -eq 0x01 -or $attr.ID -eq 0x05 -or $attr.ID -eq 0xA0 -or $attr.ID -eq 0xA1 -or $attr.ID -eq 0xB1 -or $attr.ID -eq 0xB2 -or $attr.ID -eq 0xB7 -or $attr.ID -eq 0xB8 -or $attr.ID -eq 0xBB -or $attr.ID -eq 0xBC -or $attr.ID -eq 0xC4 -or $attr.ID -eq 0xC5 -or $attr.ID -eq 0xC6 -or $attr.ID -eq 0xE8 -or $attr.ID -eq 0xE9 -or $attr.ID -eq 0xA9)
            if ($isCriticalAttr) {
                $isProblematic = $false
                $isFailed = $false
                
                if ($attr.ID -eq 0xA9 -or $attr.ID -eq 0xB1 -or $attr.ID -eq 0xE9 -or $attr.ID -eq 0xE8 -or $attr.ID -eq 0xA1) {
                    $val = if ($attr.ID -eq 0xA9) { $attr.Raw } else { $attr.Current }
                    if ($val -le 10) { $isFailed = $true }
                    elseif ($val -le 60) { $isProblematic = $true }
                } else {
                    if ($attr.Raw -gt 0) {
                        if ($attr.Current -le $attr.Threshold -and $attr.Threshold -gt 0) { $isFailed = $true }
                        else { $isProblematic = $true }
                    }
                }
                
                if ($isFailed) { $lineColor = $Red }
                elseif ($isProblematic) { $lineColor = $Yellow }
                else { $lineColor = $Green }
            }
            if ($attr.Threshold -gt 0 -and $attr.Current -le $attr.Threshold) {
                $lineColor = $Red
            }
        }
        else {
            $isCriticalAttr = ($attr.ID -eq 0x01 -or $attr.ID -eq 0x03 -or $attr.ID -eq 0x05 -or $attr.ID -eq 0x0E)
            if ($isCriticalAttr) {
                $isProblematic = $false
                $isFailed = $false
                
                if ($attr.ID -eq 0x01) {
                    if ($attr.Raw -gt 0) { $isFailed = $true }
                } elseif ($attr.ID -eq 0x0E) {
                    if ($attr.Raw -gt 0) { $isProblematic = $true }
                } elseif ($attr.ID -eq 0x03) {
                    if ($attr.Raw -lt 10) { $isFailed = $true }
                    elseif ($attr.Raw -lt 90) { $isProblematic = $true }
                } elseif ($attr.ID -eq 0x05) {
                    if ($attr.Raw -gt 50) { $isFailed = $true }
                    elseif ($attr.Raw -gt 10) { $isProblematic = $true }
                }
                
                if ($isFailed) { $lineColor = $Red }
                elseif ($isProblematic) { $lineColor = $Yellow }
                else { $lineColor = $Green }
            }
        }

        Write-Host "  | $idStr | $nameTrunc | $curStr | $worStr | $thrStr | $rawDisplay |" -ForegroundColor ([ConsoleColor]$lineColor)
    }
    Write-Host "  +------+------------------------------------+---------+---------+-----------+-------------------+" -ForegroundColor $Gray
    Write-Host ""

    # 7. Συμπέρασμα & Ενέργειες (Conclusion)
    Write-Host "### 🔵 Συμπέρασμα & Ενέργειες" -ForegroundColor $Cyan
    if ($status -eq "GOOD") {
        $phAttr = if ($brand -eq "NVMe") { $attributes | Where-Object {$_.ID -eq 0x0C} } else { $attributes | Where-Object {$_.ID -eq 0x09} }
        $phVal = if ($phAttr) { $phAttr.Raw } else { 0 }
        Write-Host "  ✅ Ο δίσκος είναι απόλυτα σταθερός, υγιής και ασφαλής για καθημερινή χρήση." -ForegroundColor $Green
        Write-Host "  💡 Συμβουλή: Λόγω της παλαιότητας και των $phVal ωρών του, η τήρηση backup παραμένει standard τακτική." -ForegroundColor $Gray
    } elseif ($status -eq "CAUTION") {
        Write-Host "  ⚠️ Ο δίσκος εμφανίζει ενεργά σημάδια φθοράς και media errors. Δεν συνιστάται να παραμείνει ως C: boot drive." -ForegroundColor $Yellow
        Write-Host "  🚨 ALL CAPS: ΠΡΟΧΩΡΗΣΤΕ ΑΜΕΣΑ ΣΕ BACKUP / CLONE ΚΑΙ ΑΝΤΙΚΑΤΑΣΤΑΣΗ ΤΟΥ ΔΙΣΚΟΥ." -ForegroundColor $Yellow
    } else {
        Write-Host "  🚨 Ο δίσκος βρίσκεται σε κρίσιμη κατάσταση αστοχίας." -ForegroundColor $Red
        Write-Host "  🚨 ALL CAPS: ΑΝΤΙΚΑΤΑΣΤΗΣΤΕ ΤΟΝ ΔΙΣΚΟ ΑΜΕΣΑ ΓΙΑ ΑΠΟΦΥΓΗ ΑΠΩΛΕΙΑΣ ΔΕΔΟΜΕΝΩΝ." -ForegroundColor $Red
    }

    # Samsung Specific Notes
    if ($brand -eq "Samsung") {
        $wearB1 = $attributes | Where-Object { $_.ID -eq 0xB1 }
        $unusedB4 = $attributes | Where-Object { $_.ID -eq 0xB4 }
        $porRecovery = $attributes | Where-Object { $_.ID -eq 0xEB }
        
        Write-Host "`n  🔵 Ειδική Παρατήρηση Samsung SSD:" -ForegroundColor $Cyan
        if ($wearB1) {
            Write-Host "  🔸 Το Wear Leveling Count (B1) δείχνει $($wearB1.Raw) κύκλους εγγραφής/διαγραφής (P/E cycles)." -ForegroundColor $Gray
        }
        if ($unusedB4) {
            Write-Host "  🔸 Το Available Reserved Blocks (B4) είναι $($unusedB4.Raw), που σημαίνει ότι τα εργοστασιακά spare blocks είναι εντελώς άθικτα." -ForegroundColor $Gray
        }
        if ($porRecovery -and $porRecovery.Raw -gt 0) {
            Write-Host "  🔸 Το POR Recovery Count (EB) είναι $($porRecovery.Raw). Αυτό δείχνει sudden power loss recoveries (απότομη απώλεια ρεύματος)." -ForegroundColor $Gray
        }
    }
    
    # Patriot Specific Notes
    if ($brand -eq "Patriot") {
        $wearA9 = $attributes | Where-Object { $_.ID -eq 0xA9 }
        $hostWritesF1 = $attributes | Where-Object { $_.ID -eq 0xF1 }
        $nandWritesF5 = $attributes | Where-Object { $_.ID -eq 0xF5 }
        
        Write-Host "`n  🔵 Ειδική Παρατήρηση Patriot SSD (Silicon Motion):" -ForegroundColor $Cyan
        if ($wearA9) {
            Write-Host "  🔸 Η υπολειπόμενη ζωή (Remain Life) είναι " -NoNewline -ForegroundColor $White
            Write-Host "$($wearA9.Raw)%" -ForegroundColor $Yellow
        }
        if ($hostWritesF1 -and $nandWritesF5) {
            $hostGB = [Math]::Round(($hostWritesF1.Raw * 32) / 1024, 2)
            $nandGB = [Math]::Round(($nandWritesF5.Raw * 32) / 1024, 2)
            $waf = if ($hostGB -gt 0) { [Math]::Round($nandGB / $hostGB, 2) } else { 0 }
            
            Write-Host "  🔸 Host Writes: " -NoNewline -ForegroundColor $White
            Write-Host "$hostGB GB" -ForegroundColor $Gray
            Write-Host "  🔸 NAND Writes: " -NoNewline -ForegroundColor $White
            Write-Host "$nandGB GB" -ForegroundColor $Gray
            Write-Host "  🔸 Write Amplification Factor (WAF): " -NoNewline -ForegroundColor $White
            Write-Host "$waf`x" -ForegroundColor $(if ($waf -gt 3) { "Yellow" } else { "Gray" })
            if ($waf -gt 3) {
                Write-Host "     (Υψηλό WAF: Ο controller γράφει πολύ περισσότερα δεδομένα στη NAND λόγω garbage collection.)" -ForegroundColor $Yellow
            }
        }
    }

    # SanDisk/WD Specific Notes
    if ($brand -eq "SanDisk") {
        $badBlocksA9 = $attributes | Where-Object { $_.ID -eq 0xA9 }
        $retiredAA = $attributes | Where-Object { $_.ID -eq 0xAA }
        $reallocated05 = $attributes | Where-Object { $_.ID -eq 0x05 }
        $spareE8 = $attributes | Where-Object { $_.ID -eq 0xE8 }
        
        Write-Host "`n  🔵 Ειδική Παρατήρηση SanDisk/WD SSD:" -ForegroundColor $Cyan
        if ($badBlocksA9) {
            Write-Host "  🔸 Total Bad Blocks (A9): " -NoNewline -ForegroundColor $White
            Write-Host "$($badBlocksA9.Raw)" -ForegroundColor $Gray
            
            $hasGrownBad = ($retiredAA -and $retiredAA.Raw -gt 0) -or ($reallocated05 -and $reallocated05.Raw -gt 0)
            if (-not $hasGrownBad) {
                Write-Host "     - Τα bad blocks είναι 100% εργοστασιακά (factory bad blocks) και απομονωμένα." -ForegroundColor $Green
                Write-Host "     - Δεν υπάρχουν grown bad blocks κατά τη χρήση (Reserve Block & Reallocated Sectors = 0)." -ForegroundColor $Green
                Write-Host "     💡 [Λογική: Αν ανιχνευτούν bad blocks (Total Bad Blocks (A9) > 0), αλλά οι δείκτες grown bad blocks" -ForegroundColor $Gray
                Write-Host "        (Reserve Block Count (AA) και Reallocated Sectors (05)) είναι μηδενικοί, ο δίσκος είναι υγιής.]" -ForegroundColor $Gray
            } else {
                Write-Host "     - ⚠️ Ο δίσκος έχει αναπτύξει grown bad blocks κατά τη χρήση (retired blocks detected)." -ForegroundColor $Yellow
                Write-Host "     💡 [Λογική: Αν ανιχνευτούν bad blocks και οι δείκτες grown bad blocks (Reserve Block Count (AA)" -ForegroundColor $Gray
                Write-Host "        ή Reallocated Sectors (05)) είναι πάνω από 0, ο δίσκος παρουσιάζει ενεργή φθορά.]" -ForegroundColor $Gray
            }
        }
        if ($spareE8) {
            Write-Host "  🔸 Available Reserved Space (E8): " -NoNewline -ForegroundColor $White
            Write-Host "$($spareE8.Raw)%" -ForegroundColor $(if ($spareE8.Raw -lt 100) { "Yellow" } else { "Gray" })
        }
    }

    # NVMe Specific Notes
    if ($brand -eq "NVMe") {
        $wear05 = $attributes | Where-Object { $_.ID -eq 0x05 }
        $readUnits06 = $attributes | Where-Object { $_.ID -eq 0x06 }
        $writeUnits07 = $attributes | Where-Object { $_.ID -eq 0x07 }
        $unsafeShutdowns0D = $attributes | Where-Object { $_.ID -eq 0x0D }
        
        Write-Host "`n  🔵 Ειδική Παρατήρηση NVMe SSD:" -ForegroundColor $Cyan
        if ($wear05) {
            Write-Host "  🔸 Η συνολική φθορά (Percentage Used) είναι " -NoNewline -ForegroundColor $White
            Write-Host "$($wear05.Raw)%" -ForegroundColor $Yellow
        }
        if ($readUnits06 -and $writeUnits07) {
            $readGB = [Math]::Round(($readUnits06.Raw * 512000) / 1GB, 2)
            $writeGB = [Math]::Round(($writeUnits07.Raw * 512000) / 1GB, 2)
            Write-Host "  🔸 Host Reads: " -NoNewline -ForegroundColor $White
            Write-Host "$readGB GB" -ForegroundColor $Gray
            Write-Host "  🔸 Host Writes: " -NoNewline -ForegroundColor $White
            Write-Host "$writeGB GB" -ForegroundColor $Gray
        }
        if ($unsafeShutdowns0D -and $unsafeShutdowns0D.Raw -gt 0) {
            Write-Host "  🔸 Απότομες Διακοπές Ρεύματος (Unsafe Shutdowns): " -NoNewline -ForegroundColor $White
            Write-Host "$($unsafeShutdowns0D.Raw)" -ForegroundColor $Yellow
        }
    }
    }

    if ($collected.Count -gt 1 -and $isInteractive -and $runLoop) {
        Write-Host "  Press any key to return to the selection menu..." -ForegroundColor $Yellow
        [Console]::ReadKey($true) | Out-Null
    }
}
