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
.PARAMETER Discover
    Εντοπίζει υπολογιστές στο τοπικό δίκτυο και εμφανίζει selector πριν από τη σύνδεση WinRM.
.PARAMETER DiscoveryStateRoot
    Προαιρετικό absolute path για network-scoped discovery history/cache.
.PARAMETER Benchmark
    Καταγράφει discovery, WinRM και storage-probe phase timings στο local DiskHealth state folder.
#>
[CmdletBinding()]
param(
    [string]$ComputerName = "localhost",
    [string]$Username = "user",
    [AllowEmptyString()]
    [string]$Password = "",
    [AllowEmptyString()]
    [string]$FilePath = "",
    [switch]$InstallSmartctl,
    [switch]$Discover,
    [AllowEmptyString()]
    [string]$DiscoveryStateRoot = "",
    [switch]$Benchmark,
    [Parameter(DontShow)]
    [System.Management.Automation.PSCredential]$Credential,
    [Parameter(DontShow)]
    [AllowEmptyString()]
    [string]$ConnectionNetworkId = "",
    [Parameter(DontShow)]
    [AllowEmptyString()]
    [string]$ConnectionDisplayName = "",
    [Parameter(DontShow)]
    [AllowEmptyString()]
    [string]$ConnectionMacAddress = "",
    [Parameter(DontShow)]
    [switch]$NoUI,
    [Parameter(DontShow)]
    [switch]$EmbeddedRemote,
    [Parameter(DontShow)]
    [switch]$CredentialFromSavedProfile
)

# 1. Καθορισμός Χρωμάτων (Console Colors)
$Cyan = "Cyan"
$Yellow = "Yellow"
$Red = "Red"
$Green = "Green"
$White = "White"
$Gray = "DarkGray"
$script:DiskHealthBenchmarkEnabled = [bool]$Benchmark
$script:DiskHealthBenchmarkLogPath = ""
$script:IsHomeLauncher = (
    -not $PSBoundParameters.ContainsKey('ComputerName') -and
    -not $PSBoundParameters.ContainsKey('FilePath') -and
    -not $PSBoundParameters.ContainsKey('Discover') -and
    -not $EmbeddedRemote
)

function Get-DiskHealthLocalStateRoot {
    param(
        [AllowEmptyString()]
        [string]$StateRoot = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($StateRoot)) {
        return [Environment]::ExpandEnvironmentVariables($StateRoot)
    }

    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        $localAppData = Join-Path -Path $env:USERPROFILE -ChildPath 'AppData\Local'
    }
    return Join-Path -Path $localAppData -ChildPath 'DiskHealth'
}

function Get-DiskHealthStoredCredential {
    param(
        [Parameter(Mandatory)][string]$NetworkId,
        [Parameter(Mandatory)][string[]]$ComputerNames,
        [AllowEmptyString()][string]$StateRoot = ''
    )

    if ([string]::IsNullOrWhiteSpace($NetworkId)) { return $null }
    return Get-WinRMCredentialProfile `
        -ComputerName $ComputerNames `
        -Scope $NetworkId `
        -StateRoot $StateRoot
}

function Save-DiskHealthStoredCredential {
    param(
        [Parameter(Mandatory)][string]$NetworkId,
        [Parameter(Mandatory)][string[]]$ComputerNames,
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]$CredentialToStore,
        [AllowEmptyString()][string]$StateRoot = ''
    )

    if ([string]::IsNullOrWhiteSpace($NetworkId) -or $null -eq $CredentialToStore) { return }
    Save-WinRMCredentialProfile `
        -ComputerName $ComputerNames `
        -Credential $CredentialToStore `
        -Scope $NetworkId `
        -StateRoot $StateRoot
}

function Remove-DiskHealthStoredCredential {
    param(
        [Parameter(Mandatory)][string]$NetworkId,
        [Parameter(Mandatory)][string[]]$ComputerNames,
        [AllowEmptyString()][string]$StateRoot = ''
    )

    if ([string]::IsNullOrWhiteSpace($NetworkId)) { return }
    Remove-WinRMCredentialProfile `
        -ComputerName $ComputerNames `
        -Scope $NetworkId `
        -StateRoot $StateRoot `
        -Confirm:$false
}

function Write-DiskHealthBenchmarkLine {
    param(
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][double]$Milliseconds,
        [AllowEmptyString()][string]$Details = ''
    )

    if (-not $script:DiskHealthBenchmarkEnabled) { return }
    if ([string]::IsNullOrWhiteSpace($script:DiskHealthBenchmarkLogPath)) {
        $logRoot = Join-Path -Path (Get-DiskHealthLocalStateRoot) -ChildPath 'logs'
        $null = New-Item -ItemType Directory -Path $logRoot -Force
        $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss_fff'
        $script:DiskHealthBenchmarkLogPath = Join-Path -Path $logRoot -ChildPath "probe_benchmark_${stamp}_$PID.log"
        "[DiskHealth Benchmark] $(Get-Date -Format 'o')" | Set-Content -LiteralPath $script:DiskHealthBenchmarkLogPath -Encoding UTF8
    }

    $detailSuffix = if ([string]::IsNullOrWhiteSpace($Details)) { '' } else { " | $Details" }
    "{0,-34} {1,10:N1} ms{2}" -f $Phase, $Milliseconds, $detailSuffix |
        Add-Content -LiteralPath $script:DiskHealthBenchmarkLogPath -Encoding UTF8
}

function Import-DiskHealthWinRMDiscovery {
    param([AllowEmptyString()][string]$StateRoot = '')

    $manifest = Join-Path -Path $PSScriptRoot -ChildPath '.assets\WinRMDiscovery\WinRMDiscovery.psd1'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        throw "Το WinRMDiscovery module δεν βρέθηκε: $manifest"
    }

    if (-not (Get-Module -Name WinRMDiscovery)) {
        Import-Module -Name $manifest -Force -ErrorAction Stop
    }
    if (-not [string]::IsNullOrWhiteSpace($StateRoot)) {
        Set-WinRMDiscoveryStateRoot -Path $StateRoot
    }
}

function Import-DiskHealthWinRMConnection {
    $manifest = Join-Path -Path $PSScriptRoot -ChildPath '.assets\WinRMConnection\WinRMConnection.psd1'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        throw "Το WinRMConnection module δεν βρέθηκε: $manifest"
    }

    if (-not (Get-Module -Name WinRMConnection)) {
        Import-Module -Name $manifest -Force -ErrorAction Stop
    }
}

function Write-DiskHealthWinRMConnectionStatus {
    param([Parameter(Mandatory)]$Status)

    $statusColor = if ($Status.State -in @('AttemptFailed', 'Failed')) {
        $Yellow
    } elseif ($Status.State -eq 'Connected') {
        $Green
    } else {
        $Cyan
    }
    Write-Host "  🔌 $($Status.Message)" -ForegroundColor $statusColor
}

function Get-MenuDisplayText {
    param(
        [Parameter(Mandatory)][string]$Text,
        [int]$ReservedColumns = 10
    )

    $windowWidth = 80
    try { $windowWidth = [Math]::Max(30, $Host.UI.RawUI.WindowSize.Width) } catch {}
    $maximumLength = [Math]::Max(20, $windowWidth - $ReservedColumns)
    if ($Text.Length -le $maximumLength) { return $Text }
    return $Text.Substring(0, $maximumLength - 3) + '...'
}

function Show-SmartctlInstallMenu {
    param(
        [Parameter(DontShow)]
        [scriptblock]$ReadKey = { [Console]::ReadKey($true) }
    )

    $options = @(
        [PSCustomObject]@{
            Action = 'Install'
            Label  = 'Install smartctl now (official winget package)'
        }
        [PSCustomObject]@{
            Action = 'Continue'
            Label  = 'Continue with limited WMI/CIM diagnostics'
        }
    )
    $selectedIndex = 0
    $firstRender = $true
    $menuHeight = $options.Count + 3

    try {
        try { [Console]::CursorVisible = $false } catch {}
        while ($true) {
            if (-not $firstRender) {
                try {
                    $position = $Host.UI.RawUI.CursorPosition
                    $position.Y = [Math]::Max(0, $position.Y - $menuHeight)
                    $position.X = 0
                    $Host.UI.RawUI.CursorPosition = $position
                } catch {}
            }
            $firstRender = $false

            Write-Host '### 🔵 Το smartctl δεν βρέθηκε. Επιλέξτε ενέργεια:' -ForegroundColor Cyan
            for ($index = 0; $index -lt $options.Count; $index++) {
                $label = Get-MenuDisplayText -Text "[$($index + 1)] $($options[$index].Label)"
                if ($index -eq $selectedIndex) {
                    Write-Host '  ➔ [ ' -NoNewline -ForegroundColor Yellow
                    Write-Host $label -NoNewline -ForegroundColor White
                    Write-Host ' ]' -ForegroundColor Yellow
                } else {
                    Write-Host "     $label" -ForegroundColor Gray
                }
            }
            Write-Host '  ↑/↓ Navigation  Enter Select  1-2 Shortcut' -ForegroundColor DarkGray
            Write-Host '  ESC Back' -ForegroundColor Red

            $key = & $ReadKey
            if ($key.Key -eq 'UpArrow') {
                $selectedIndex = if ($selectedIndex -eq 0) { $options.Count - 1 } else { $selectedIndex - 1 }
            } elseif ($key.Key -eq 'DownArrow') {
                $selectedIndex = if ($selectedIndex -eq $options.Count - 1) { 0 } else { $selectedIndex + 1 }
            } elseif ($key.Key -eq 'Escape') {
                return 'Back'
            } elseif ($key.Key -eq 'Enter') {
                return $options[$selectedIndex].Action
            } elseif ($key.KeyChar -match '^[1-2]$') {
                return $options[[int][string]$key.KeyChar - 1].Action
            }
        }
    } finally {
        try { [Console]::CursorVisible = $true } catch {}
    }
}

function Get-DiskHealthWinRMComputers {
    param([string]$StateRoot = '')

    Import-DiskHealthWinRMDiscovery -StateRoot $StateRoot
    Write-Host "  🔎 Αναζήτηση Windows PCs στο τοπικό δίκτυο..." -ForegroundColor Cyan
    $scanWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $computers = @(Find-WinRMComputer -StateRoot $StateRoot -IncludeDiagnostics:$Benchmark)
    $scanWatch.Stop()
    Write-DiskHealthBenchmarkLine -Phase 'Discovery.FullScan' -Milliseconds $scanWatch.Elapsed.TotalMilliseconds -Details "$($computers.Count) PCs"
    if ($Benchmark) {
        foreach ($diagnosticLine in @(Get-WinRMDiscoveryDiagnostics)) {
            Write-DiskHealthBenchmarkLine -Phase 'Discovery.ModuleDetail' -Milliseconds 0 -Details ([string]$diagnosticLine)
        }
    }
    if ($computers.Count -eq 0) {
        throw 'Δεν εντοπίστηκαν Windows PCs μέσω WS-Discovery ή των WinRM/SMB/RDP ports.'
    }

    return $computers
}

function Get-DiskHealthSavedWinRMTargets {
    param([string]$StateRoot = '')

    Import-DiskHealthWinRMDiscovery -StateRoot $StateRoot
    $networkInfo = Get-WinRMNetworkIdentity
    $history = @(Get-WinRMConnectionHistory -NetworkId $networkInfo.NetworkId | Sort-Object { [datetime]$_.LastConnected } -Descending)
    $targets = [System.Collections.Generic.List[object]]::new()

    foreach ($entry in $history) {
        $resolveWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $resolvedAddress = Resolve-WinRMHistoryTargetAddress `
            -ComputerName $entry.ComputerName `
            -LastIPAddress $entry.LastIPAddress `
            -MACAddress $entry.MACAddress
        $resolveWatch.Stop()
        Write-DiskHealthBenchmarkLine `
            -Phase 'Discovery.SavedTargetProbe' `
            -Milliseconds $resolveWatch.Elapsed.TotalMilliseconds `
            -Details "$($entry.ComputerName) -> $resolvedAddress"

        if ([string]::IsNullOrWhiteSpace($resolvedAddress)) { continue }
        $targets.Add([PSCustomObject]@{
            ComputerName  = $entry.ComputerName
            IPAddress     = $resolvedAddress
            MACAddress    = $entry.MACAddress
            UserName      = $entry.UserName
            LastConnected = $entry.LastConnected
            WinRMHttpOpen = $true
            SMBOpen       = $false
            DetectedOnly  = $false
            Status        = 'Saved / WinRMReady'
            Source        = 'History'
        })
    }

    return [PSCustomObject]@{
        NetworkInfo = $networkInfo
        Targets     = @($targets)
    }
}

function Select-WinRMDiscoveryTarget {
    param(
        [string]$StateRoot = '',
        [AllowNull()]
        [array]$Computers,
        [switch]$AllowScan
    )

    if ($null -eq $Computers -or $Computers.Count -eq 0) {
        $Computers = @(Get-DiskHealthWinRMComputers -StateRoot $StateRoot)
    }

    $selectedIndex = 0
    for ($index = 0; $index -lt $Computers.Count; $index++) {
        if ($Computers[$index].WinRMHttpOpen) { $selectedIndex = $index; break }
    }

    $options = [System.Collections.Generic.List[object]]::new()
    foreach ($computer in @($Computers)) {
        $options.Add($computer)
    }
    if ($AllowScan) {
        $options.Add([PSCustomObject]@{
            Action        = 'Scan'
            ComputerName  = 'Scan network for more PCs'
            IPAddress     = ''
            WinRMHttpOpen = $false
            Status        = 'Discovery'
        })
    }

    $firstRender = $true
    $menuHeight = $options.Count + 3
    try {
        try { [Console]::CursorVisible = $false } catch {}
        while ($true) {
            if (-not $firstRender) {
                try {
                    $position = $Host.UI.RawUI.CursorPosition
                    $position.Y = [Math]::Max(0, $position.Y - $menuHeight)
                    $position.X = 0
                    $Host.UI.RawUI.CursorPosition = $position
                } catch {}
            }
            $firstRender = $false

            Write-Host '### 🔵 Επιλέξτε WinRM υπολογιστή:' -ForegroundColor Cyan
            for ($index = 0; $index -lt $options.Count; $index++) {
                $computer = $options[$index]
                $label = if ($computer.Action -eq 'Scan') {
                    Get-MenuDisplayText -Text "[$($index + 1)] 🔎 $($computer.ComputerName)"
                } else {
                    Get-MenuDisplayText -Text "[$($index + 1)] $($computer.ComputerName)  $($computer.IPAddress)  [$($computer.Status)]"
                }
                if ($index -eq $selectedIndex) {
                    $statusColor = if ($computer.Action -eq 'Scan') { $Cyan } elseif ($computer.WinRMHttpOpen) { $Green } else { $Yellow }
                    Write-Host '  ➔ [ ' -NoNewline -ForegroundColor Yellow
                    Write-Host $label -NoNewline -ForegroundColor $statusColor
                    Write-Host ' ]' -ForegroundColor Yellow
                } else {
                    Write-Host "     $label" -ForegroundColor Gray
                }
            }
            Write-Host '  ↑/↓ Navigation  Enter Select  1-9 Shortcut' -ForegroundColor DarkGray
            Write-Host '  ESC Back' -ForegroundColor Red

            $key = [Console]::ReadKey($true)
            if ($key.Key -eq 'UpArrow') {
                $selectedIndex = if ($selectedIndex -eq 0) { $options.Count - 1 } else { $selectedIndex - 1 }
            } elseif ($key.Key -eq 'DownArrow') {
                $selectedIndex = if ($selectedIndex -eq $options.Count - 1) { 0 } else { $selectedIndex + 1 }
            } elseif ($key.Key -eq 'Escape') {
                return $null
            } elseif ($key.Key -eq 'Enter') {
                return $options[$selectedIndex]
            } elseif ($key.KeyChar -match '^[1-9]$') {
                $numberIndex = [int][string]$key.KeyChar - 1
                if ($numberIndex -lt $options.Count) { return $options[$numberIndex] }
            }
        }
    } finally {
        try { [Console]::CursorVisible = $true } catch {}
    }
}

function Invoke-DiscoveredWinRMTarget {
    param(
        [Parameter(Mandatory)]$Target,
        [string]$DefaultUsername = 'user',
        [AllowNull()]$NetworkInfo
    )

    Import-DiskHealthWinRMDiscovery -StateRoot $DiscoveryStateRoot
    Import-DiskHealthWinRMConnection
    if ($null -eq $NetworkInfo) {
        $NetworkInfo = Get-WinRMNetworkIdentity
    }
    $networkId = [string]$NetworkInfo.NetworkId
    $historyMatch = Get-WinRMConnectionHistory -NetworkId $networkId |
        Where-Object {
            $_.ComputerName -eq $Target.ComputerName -or
            $_.LastIPAddress -eq $Target.IPAddress
        } |
        Select-Object -First 1
    $preferredUsername = if ($historyMatch -and -not [string]::IsNullOrWhiteSpace($historyMatch.UserName) -and $historyMatch.UserName -ne 'Unknown') {
        [string]$historyMatch.UserName
    } elseif (-not [string]::IsNullOrWhiteSpace($Target.UserName) -and $Target.UserName -ne 'Unknown') {
        [string]$Target.UserName
    } else {
        $DefaultUsername
    }
    $credentialAliases = @(
        @($Target.ComputerName, $Target.IPAddress, $historyMatch.ComputerName) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )
    $storedCredential = Get-DiskHealthStoredCredential -NetworkId $networkId -ComputerNames $credentialAliases
    if ($storedCredential) {
        $preferredUsername = $storedCredential.UserName
    }

    Clear-Host
    Write-Host '======================================================================' -ForegroundColor Cyan
    Write-Host '  🌐 WINRM LOGIN' -ForegroundColor Cyan
    Write-Host '======================================================================' -ForegroundColor Cyan
    Write-Host "  Target: $($Target.ComputerName) ($($Target.IPAddress))" -ForegroundColor White
    $credentialToUse = $storedCredential
    if ($credentialToUse) {
        Write-Host "  🔐 Αποθηκευμένα credentials: $($credentialToUse.UserName)" -ForegroundColor Green
        Write-Host "  🔄 Δοκιμή αυτόματης σύνδεσης στο ίδιο αποθηκευμένο δίκτυο..." -ForegroundColor DarkGray
    } else {
        Write-Host "  Username: ENTER = '$preferredUsername'" -ForegroundColor DarkGray
        $enteredUsername = (Read-Host '  Username').Trim()
        $remoteUsername = if ([string]::IsNullOrWhiteSpace($enteredUsername)) { $preferredUsername } else { $enteredUsername }
        Write-Host '  Password: ENTER = blank' -ForegroundColor DarkGray
        $securePassword = Read-Host '  Password' -AsSecureString
        $credentialToUse = [System.Management.Automation.PSCredential]::new($remoteUsername, $securePassword)
    }

    & $PSCommandPath `
        -ComputerName $Target.IPAddress `
        -Username $credentialToUse.UserName `
        -Credential $credentialToUse `
        -InstallSmartctl:$InstallSmartctl `
        -DiscoveryStateRoot $DiscoveryStateRoot `
        -Benchmark:$Benchmark `
        -ConnectionNetworkId $networkId `
        -ConnectionDisplayName $Target.ComputerName `
        -ConnectionMacAddress $Target.MACAddress `
        -CredentialFromSavedProfile:($null -ne $storedCredential) `
        -NoUI:$NoUI `
        -EmbeddedRemote
}

function Show-StartupTargetMenu {
    $options = @(
        [PSCustomObject]@{ Action = 'Local'; Label = '💻 Local computer' },
        [PSCustomObject]@{ Action = 'Network'; Label = '🌐 Network computer (WinRM)' }
    )
    $selectedIndex = 0
    $firstRender = $true
    $menuHeight = $options.Count + 8

    Clear-Host
    try {
        try { [Console]::CursorVisible = $false } catch {}
        while ($true) {
            if (-not $firstRender) {
                try {
                    $position = $Host.UI.RawUI.CursorPosition
                    $position.Y = [Math]::Max(0, $position.Y - $menuHeight)
                    $position.X = 0
                    $Host.UI.RawUI.CursorPosition = $position
                } catch {}
            }
            $firstRender = $false

            Write-Host '======================================================================' -ForegroundColor Cyan
            Write-Host '  💾 DISKHEALTH' -ForegroundColor Cyan
            Write-Host '======================================================================' -ForegroundColor Cyan
            Write-Host '  Επιλέξτε πηγή δίσκων:' -ForegroundColor White
            Write-Host
            for ($index = 0; $index -lt $options.Count; $index++) {
                $label = Get-MenuDisplayText -Text "[$($index + 1)] $($options[$index].Label)"
                if ($index -eq $selectedIndex) {
                    Write-Host '  ➔ [ ' -NoNewline -ForegroundColor Yellow
                    Write-Host $label -NoNewline -ForegroundColor White
                    Write-Host ' ]' -ForegroundColor Yellow
                } else {
                    Write-Host "     $label" -ForegroundColor Gray
                }
            }
            Write-Host
            Write-Host '  ↑/↓ Navigation  Enter Select  1-2 Shortcut' -ForegroundColor DarkGray
            Write-Host '  ESC Exit' -ForegroundColor Red

            $key = [Console]::ReadKey($true)
            if ($key.Key -eq 'UpArrow') {
                $selectedIndex = if ($selectedIndex -eq 0) { $options.Count - 1 } else { $selectedIndex - 1 }
            } elseif ($key.Key -eq 'DownArrow') {
                $selectedIndex = if ($selectedIndex -eq $options.Count - 1) { 0 } else { $selectedIndex + 1 }
            } elseif ($key.Key -eq 'Escape') {
                return 'Exit'
            } elseif ($key.Key -eq 'Enter') {
                return $options[$selectedIndex].Action
            } elseif ($key.KeyChar -match '^[1-2]$') {
                return $options[[int][string]$key.KeyChar - 1].Action
            }
        }
    } finally {
        try { [Console]::CursorVisible = $true } catch {}
    }
}

if ($script:IsHomeLauncher) {
    while ($true) {
        $startupChoice = Show-StartupTargetMenu
        if ($startupChoice -eq 'Exit') {
            Clear-Host
            return
        }
        if ($startupChoice -eq 'Local') {
            & $PSCommandPath `
                -ComputerName 'localhost' `
                -Username $Username `
                -InstallSmartctl:$InstallSmartctl `
                -DiscoveryStateRoot $DiscoveryStateRoot `
                -Benchmark:$Benchmark `
                -NoUI:$NoUI `
                -EmbeddedRemote
            continue
        }

        if ($startupChoice -eq 'Network') {
            Clear-Host
            $savedState = Get-DiskHealthSavedWinRMTargets -StateRoot $DiscoveryStateRoot
            $networkInfo = $savedState.NetworkInfo
            $networkComputers = @($savedState.Targets)
            $allowNetworkScan = $true
            if ($networkComputers.Count -eq 0) {
                $networkComputers = @(Get-DiskHealthWinRMComputers -StateRoot $DiscoveryStateRoot)
                $allowNetworkScan = $false
            }
            while ($true) {
                Clear-Host
                $discoveredTarget = Select-WinRMDiscoveryTarget -Computers $networkComputers -AllowScan:$allowNetworkScan
                if ($null -eq $discoveredTarget) {
                    break
                }
                if ($discoveredTarget.Action -eq 'Scan') {
                    Clear-Host
                    $networkComputers = @(Get-DiskHealthWinRMComputers -StateRoot $DiscoveryStateRoot)
                    $allowNetworkScan = $false
                    continue
                }
                Invoke-DiscoveredWinRMTarget -Target $discoveredTarget -DefaultUsername $Username -NetworkInfo $networkInfo
            }
        }
    }
}

if ($Discover) {
    if (-not [string]::IsNullOrWhiteSpace($FilePath)) {
        throw 'Τα -Discover και -FilePath δεν μπορούν να χρησιμοποιηθούν μαζί.'
    }
    $discoveredTarget = Select-WinRMDiscoveryTarget -StateRoot $DiscoveryStateRoot
    if ($null -eq $discoveredTarget) {
        Write-Host 'Η επιλογή στόχου ακυρώθηκε.' -ForegroundColor Yellow
        return
    }
    $ComputerName = $discoveredTarget.IPAddress
    Import-DiskHealthWinRMDiscovery -StateRoot $DiscoveryStateRoot
    $discoverNetworkInfo = Get-WinRMNetworkIdentity
    $ConnectionNetworkId = $discoverNetworkInfo.NetworkId
    $ConnectionDisplayName = $discoveredTarget.ComputerName
    $ConnectionMacAddress = $discoveredTarget.MACAddress
    if ($null -eq $Credential -and [string]::IsNullOrWhiteSpace($Password)) {
        $Credential = Get-DiskHealthStoredCredential `
            -NetworkId $ConnectionNetworkId `
            -ComputerNames @($discoveredTarget.ComputerName, $discoveredTarget.IPAddress)
        if ($Credential) {
            $Username = $Credential.UserName
        }
    }
    Write-Host "  ✅ Επιλέχθηκε: $($discoveredTarget.ComputerName) ($ComputerName)" -ForegroundColor Green
}

function ConvertTo-NvmeCounter {
    param(
        [AllowNull()]
        [object]$Value,

        [AllowNull()]
        [string]$StringValue
    )

    $candidate = if ($StringValue -match '^\d+$') { $StringValue } else { [string]$Value }
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return [System.Numerics.BigInteger]::Zero
    }

    $parsed = [System.Numerics.BigInteger]::Zero
    if ([System.Numerics.BigInteger]::TryParse(
            $candidate,
            [System.Globalization.NumberStyles]::Integer,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$parsed)) {
        return $parsed
    }

    throw "Invalid NVMe counter value: '$candidate'"
}

function Get-NvmeMediaErrorAssessment {
    param(
        [System.Numerics.BigInteger]$MediaErrors,
        [System.Numerics.BigInteger]$ErrorLogEntries,
        [System.Numerics.BigInteger]$CriticalWarning
    )

    $twoTo64 = [System.Numerics.BigInteger]::Pow([System.Numerics.BigInteger]2, 64)
    $low64 = $MediaErrors % $twoTo64
    $upper64 = $MediaErrors / $twoTo64

    # NVMe counters are 128-bit. A non-zero upper half paired with a zero low
    # half, no critical warning and no error-log entries is internally
    # inconsistent telemetry. Preserve it; never rewrite it to zero.
    $isStructuralAnomaly = (
        $MediaErrors -gt [System.Numerics.BigInteger][uint64]::MaxValue -and
        $low64 -eq [System.Numerics.BigInteger]::Zero -and
        $upper64 -gt [System.Numerics.BigInteger]::Zero -and
        $ErrorLogEntries -eq [System.Numerics.BigInteger]::Zero -and
        $CriticalWarning -eq [System.Numerics.BigInteger]::Zero
    )

    [PSCustomObject]@{
        FullValue           = $MediaErrors
        Low64               = $low64
        Upper64             = $upper64
        IsStructuralAnomaly = $isStructuralAnomaly
    }
}

function Get-AtaTemperatureCelsius {
    param(
        [Parameter(Mandatory)]$Attribute,
        [AllowNull()]$SmartData
    )

    $rawStringProperty = $Attribute.PSObject.Properties['RawString']
    if ($null -ne $rawStringProperty -and [string]$rawStringProperty.Value -match '^\s*(-?\d+)') {
        $stringTemperature = [int]$Matches[1]
        if ($stringTemperature -ge -40 -and $stringTemperature -le 200) {
            return $stringTemperature
        }
    }

    if ($null -ne $SmartData -and $null -ne $SmartData.temperature -and $null -ne $SmartData.temperature.current) {
        $reportedTemperature = [int]$SmartData.temperature.current
        if ($reportedTemperature -ge -40 -and $reportedTemperature -le 200) {
            return $reportedTemperature
        }
    }

    $rawTemperature = [long]$Attribute.Raw
    if ($rawTemperature -ge -40 -and $rawTemperature -le 200) {
        return [int]$rawTemperature
    }

    return $null
}

function Get-AtaSpinUpTimeDisplay {
    param([long]$RawMilliseconds)

    if ($RawMilliseconds -lt 0 -or $RawMilliseconds -gt 600000) {
        return "$RawMilliseconds"
    }

    $seconds = [Math]::Round($RawMilliseconds / 1000.0, 2)
    return "$RawMilliseconds ms ($seconds s)"
}

function Get-AtaPowerOnHoursValue {
    param(
        [Parameter(Mandatory)]$Attribute,
        [AllowNull()]$SmartData
    )

    $powerOnProperty = if ($null -ne $SmartData) { $SmartData.PSObject.Properties['power_on_time'] } else { $null }
    $hoursProperty = if ($null -ne $powerOnProperty -and $null -ne $powerOnProperty.Value) { $powerOnProperty.Value.PSObject.Properties['hours'] } else { $null }
    if ($null -ne $hoursProperty -and $null -ne $hoursProperty.Value) {
        return [long]$hoursProperty.Value
    }

    $rawStringProperty = $Attribute.PSObject.Properties['RawString']
    if ($null -ne $rawStringProperty -and [string]$rawStringProperty.Value -match '^\s*(\d+)h(?:\+|\s|$)') {
        return [long]$Matches[1]
    }

    if ($null -ne $Attribute.Raw -and [long]$Attribute.Raw -ge 0 -and [long]$Attribute.Raw -le 10000000) {
        return [long]$Attribute.Raw
    }

    return $null
}

# Επιλογή ATA telemetry profile από model/firmware και, κυρίως, από το πραγματικό
# attribute layout. Το brand μόνο του δεν αρκεί: διαφορετικά Patriot/Intenso SSDs
# χρησιμοποιούν διαφορετικούς controllers και διαφορετική σημασία για τα ίδια IDs.
function Get-AtaTelemetryProfile {
    param(
        [AllowEmptyString()][string]$Model = '',
        [AllowEmptyString()][string]$Firmware = '',
        [AllowNull()][object[]]$Attributes
    )

    if ($Model -match '(?i)SAMSUNG') { return 'Samsung' }
    # Do not classify every WDC/WD model as this SSD family: WD HDDs use unrelated
    # attribute layouts. WDS model numbers and explicit SanDisk/WD SSD names are
    # the reliable model hints for the shared WD/SanDisk SATA SSD mapping.
    if ($Model -match '(?i)SanDisk|(?:^|\s)WDC?\s+WDS\d|^WDS\d|WD\s+(?:Green|Blue|Red).*SSD|Western Digital.*SSD') { return 'SanDisk' }

    $ids = @{}
    $names = @{}
    $a9Raw = $null
    $e7Raw = $null
    foreach ($attribute in @($Attributes)) {
        if ($null -eq $attribute) { continue }

        $idProperty = if ($attribute.PSObject.Properties['id']) { $attribute.PSObject.Properties['id'] } elseif ($attribute.PSObject.Properties['ID']) { $attribute.PSObject.Properties['ID'] } else { $null }
        if ($null -eq $idProperty) { continue }

        $id = [int]$idProperty.Value
        $ids[$id] = $true
        $nameProperty = if ($attribute.PSObject.Properties['name']) { $attribute.PSObject.Properties['name'] } elseif ($attribute.PSObject.Properties['Name']) { $attribute.PSObject.Properties['Name'] } else { $null }
        if ($nameProperty) { $names[$id] = [string]$nameProperty.Value }
        if ($id -eq 0xA9) {
            if ($attribute.PSObject.Properties['raw'] -and $null -ne $attribute.raw) {
                if ($attribute.raw.PSObject.Properties['value']) { $a9Raw = [long]$attribute.raw.value }
                else { $a9Raw = [long]$attribute.raw }
            } elseif ($attribute.PSObject.Properties['Raw']) {
                $a9Raw = [long]$attribute.Raw
            } elseif ($attribute.PSObject.Properties['RawVal']) {
                $a9Raw = [long]$attribute.RawVal
            }
        }
        if ($id -eq 0xE7) {
            if ($attribute.PSObject.Properties['raw'] -and $null -ne $attribute.raw) {
                if ($attribute.raw.PSObject.Properties['value']) { $e7Raw = [long]$attribute.raw.value }
                else { $e7Raw = [long]$attribute.raw }
            } elseif ($attribute.PSObject.Properties['Raw']) {
                $e7Raw = [long]$attribute.Raw
            } elseif ($attribute.PSObject.Properties['RawVal']) {
                $e7Raw = [long]$attribute.RawVal
            }
        }
    }

    $hasPlausibleA9Lifetime = ($null -ne $a9Raw -and $a9Raw -ge 0 -and $a9Raw -le 100)
    $hasPlausibleE7Lifetime = ($null -ne $e7Raw -and $e7Raw -ge 0 -and $e7Raw -le 100)
    $smiOemIds = @(0xA0, 0xA1, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xB1, 0xB2)
    $smiOemMatches = @($smiOemIds | Where-Object { $ids.ContainsKey($_) }).Count
    $patriotBurstIds = @(0xA1, 0xA2, 0xA3, 0xA4, 0xA6, 0xA7, 0xA8, 0xA9, 0xAB, 0xAC, 0xAE, 0xCE, 0xCF)
    $patriotBurstMatches = @($patriotBurstIds | Where-Object { $ids.ContainsKey($_) }).Count

    if ($hasPlausibleE7Lifetime -and $names.ContainsKey(0xE7) -and $names[0xE7] -match '(?i)SSD[_ ]Life[_ ]Left|Life(?:time)?[_ ]Left') {
        return 'Phison'
    }
    if ($hasPlausibleE7Lifetime -and $Model -match '(?i)^Patriot Burst(?:\s|$)' -and $Firmware -match '(?i)^S[AB]FM') {
        return 'Phison'
    }
    if ($hasPlausibleA9Lifetime -and $patriotBurstMatches -ge 10 -and $ids.ContainsKey(0xAB) -and $ids.ContainsKey(0xAC)) {
        return 'PatriotBurst'
    }
    if ($hasPlausibleA9Lifetime -and $smiOemMatches -ge 9 -and $ids.ContainsKey(0xA0) -and $ids.ContainsKey(0xB2)) {
        return 'SiliconMotionOEM'
    }

    # Known model hints are accepted only together with a plausible A9 lifetime.
    if ($hasPlausibleA9Lifetime -and $Model -match '(?i)P210|Silicon Motion') {
        return 'SiliconMotionOEM'
    }
    if ($hasPlausibleA9Lifetime -and $Model -match '(?i)Patriot.*Burst') {
        return 'PatriotBurst'
    }

    return 'Generic'
}

function Get-AtaHealthEstimate {
    param(
        [Parameter(Mandatory)][string]$Profile,
        [Parameter(Mandatory)][object[]]$Attributes
    )

    $result = [ordered]@{
        Percentage = $null
        Source = 'No trusted vendor wear attribute'
        MetricLabel = 'Health'
        IsTrusted = $false
    }

    if ($Profile -eq 'Samsung') {
        $wear = $Attributes | Where-Object { $_.ID -eq 0xB1 } | Select-Object -First 1
        if ($wear -and $null -ne $wear.Current -and [int]$wear.Current -ge 0 -and [int]$wear.Current -le 100) {
            $result.Percentage = [int]$wear.Current
            $result.Source = 'Wear Leveling Count (0xB1 normalized)'
            $result.IsTrusted = $true
        }
    } elseif ($Profile -in @('SiliconMotionOEM', 'PatriotBurst')) {
        $wear = $Attributes | Where-Object { $_.ID -eq 0xA9 } | Select-Object -First 1
        if ($wear -and $null -ne $wear.Raw -and [long]$wear.Raw -ge 0 -and [long]$wear.Raw -le 100) {
            $result.Percentage = [int]$wear.Raw
            $result.Source = 'Remaining Lifetime Percentage (0xA9 raw)'
            $result.IsTrusted = $true
        }
    } elseif ($Profile -eq 'Phison') {
        $wear = $Attributes | Where-Object { $_.ID -eq 0xE7 } | Select-Object -First 1
        if ($wear -and $null -ne $wear.Raw -and [long]$wear.Raw -ge 0 -and [long]$wear.Raw -le 100) {
            $result.Percentage = [int]$wear.Raw
            $result.Source = 'SSD Life Left (0xE7 raw)'
            $result.IsTrusted = $true
        }
    } elseif ($Profile -eq 'SanDisk') {
        $reserve = $Attributes | Where-Object { $_.ID -eq 0xE8 } | Select-Object -First 1
        if ($reserve -and $null -ne $reserve.Raw -and [long]$reserve.Raw -ge 0 -and [long]$reserve.Raw -le 100) {
            $result.Percentage = [int]$reserve.Raw
            $result.Source = 'Available Reserved Space (0xE8 raw)'
            $result.MetricLabel = 'Reserve'
            $result.IsTrusted = $true
        }
    }

    return [PSCustomObject]$result
}

# Λογική επίλυσης ονομάτων attributes ανάλογα με το επιβεβαιωμένο controller profile
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
    elseif ($brand -eq 'SiliconMotionOEM') {
        switch ($id) {
            0xA0 { return "Uncorrectable Error Count" }
            0xA1 { return "Valid Spare Block Count" }
            0xA3 { return "Initial Bad Block Count" }
            0xA4 { return "Total Erase Count" }
            0xA5 { return "Maximum Erase Count" }
            0xA6 { return "Minimum Erase Count" }
            0xA7 { return "Average Erase Count" }
            0xA8 { return "Maximum Erase Count of Spec" }
            0xA9 { return "Remaining Lifetime Percentage" }
            0xAF { return "Program Fail Count (Worst Die)" }
            0xB0 { return "Erase Fail Count (Worst Die)" }
            0xB1 { return "Total Wear Level Count" }
            0xB2 { return "Runtime Invalid Block Count" }
            0xF1 { return "Host Writes (32 MiB)" }
            0xF2 { return "Host Reads (32 MiB)" }
            0xF5 { return "TLC Writes (32 MiB)" }
        }
    }
    elseif ($brand -eq 'PatriotBurst') {
        switch ($id) {
            0xA1 { return "GDN" }
            0xA2 { return "Total Erase Count" }
            0xA3 { return "Max PE Cycle" }
            0xA4 { return "Average Erase Count" }
            0xA6 { return "Total Bad Block Count" }
            0xA7 { return "SSD Protect Mode" }
            0xA8 { return "SATA PHY Error Count" }
            0xA9 { return "Health / Remaining Lifetime" }
            0xAB { return "Program Fail Count" }
            0xAC { return "Erase Fail Count" }
            0xAE { return "Unexpected Power Loss Count" }
            0xAF { return "ECC Fail Count" }
            0xBB { return "Reported Uncorrectable Errors" }
            0xC2 { return "Enclosure Temperature" }
            0xC3 { return "Cumulative Corrected ECC" }
            0xCE { return "Minimum Erase Count" }
            0xCF { return "Maximum Erase Count" }
            0xE8 { return "Available Reserved Space" }
            0xF1 { return "Write Life Time" }
            0xF2 { return "Read Life Time" }
            0xF9 { return "Total GB Written to NAND (TLC)" }
        }
    }
    elseif ($brand -eq 'Phison') {
        switch ($id) {
            0xA8 { return "SATA PHY Error Count" }
            0xAA { return "Bad Block Count (Later/Early)" }
            0xAD { return "Maximum/Average Erase Count" }
            0xC0 { return "Unsafe Shutdown Count" }
            0xDA { return "CRC Error Count" }
            0xE7 { return "SSD Life Left" }
            0xF1 { return "Lifetime Writes (GiB)" }
        }
    }
    elseif ($brand -eq "SanDisk") {
        switch ($id) {
            0xA5 { return "Block Erase Count" }
            0xA6 { return "Minimum P/E Cycles (TLC)" }
            0xA7 { return "Max Bad Blocks per Die" }
            0xA8 { return "Maximum P/E Cycles (TLC)" }
            0xA9 { return "Total Bad Blocks" }
            0xAA { return "Grown Bad Blocks" }
            0xAB { return "Program Fail Count" }
            0xAC { return "Erase Fail Count" }
            0xAD { return "Average P/E Cycles (TLC)" }
            0xAE { return "Unexpected Power Loss Count" }
            0xE6 { return "Media Wearout Indicator" }
            0xE8 { return "Available Reserved Space" }
            0xE9 { return "NAND GB Written (TLC)" }
            0xEA { return "NAND GB Written (SLC)" }
            0xF1 { return "Host Writes (GiB)" }
            0xF2 { return "Host Reads (GiB)" }
            0xF4 { return "Temperature Throttle Status" }
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
        Write-Host "  💻 Στόχος: Τοπικός υπολογιστής (localhost)" -ForegroundColor $White
    } else {
        if ($isLocal) {
            Write-Host "  💻 Στόχος: Τοπικός υπολογιστής (localhost)" -ForegroundColor $White
        } else {
            Write-Host "  🌐 Στόχος: $ComputerName (Χρήστης: $Username)" -ForegroundColor $White
        }
    }
    Write-Host "  🔧 Μέθοδος: Native smartctl & WMI/CIM Queries" -ForegroundColor $White
    Write-Host "----------------------------------------------------------------------" -ForegroundColor $Cyan

    $operationWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $connectionAliases = @(
        @($ComputerName, $ConnectionDisplayName) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )
    if (-not $isLocal) {
        Import-DiskHealthWinRMConnection
        try {
            Import-DiskHealthWinRMDiscovery -StateRoot $DiscoveryStateRoot
            if ([string]::IsNullOrWhiteSpace($ConnectionNetworkId)) {
                $ConnectionNetworkId = (Get-WinRMNetworkIdentity).NetworkId
            }
            $matchingHistory = Get-WinRMConnectionHistory -NetworkId $ConnectionNetworkId |
                Where-Object {
                    $_.ComputerName -eq $ComputerName -or
                    $_.LastIPAddress -eq $ComputerName -or
                    $_.ComputerName -eq $ConnectionDisplayName
                } |
                Select-Object -First 1
            if ($matchingHistory) {
                $connectionAliases = @(
                    @($connectionAliases) + @(
                        $matchingHistory.ComputerName
                        $matchingHistory.LastIPAddress
                    ) |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                        Select-Object -Unique
                )
                if ($Username -eq 'user' -and -not [string]::IsNullOrWhiteSpace($matchingHistory.UserName) -and $matchingHistory.UserName -ne 'Unknown') {
                    $Username = $matchingHistory.UserName
                }
            }
            if ($null -eq $Credential -and [string]::IsNullOrWhiteSpace($Password)) {
                $Credential = Get-DiskHealthStoredCredential -NetworkId $ConnectionNetworkId -ComputerNames $connectionAliases
                if ($Credential) {
                    $CredentialFromSavedProfile = $true
                    $Username = $Credential.UserName
                    Write-Host "  🔐 Χρήση αποθηκευμένων DPAPI credentials για $Username." -ForegroundColor Green
                }
            }
        } catch {
            Write-Host "  ⚠️ Δεν φορτώθηκε το connection history: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    if ($Credential) {
        $cred = $Credential
        $Username = $cred.UserName
    } elseif (-not $isLocal -and [string]::IsNullOrEmpty($Password)) {
        $cred = New-WinRMBlankPasswordCredential -UserName $Username
    } else {
        $secstr = New-Object System.Security.SecureString
        if ($Password) {
            foreach ($char in $Password.ToCharArray()) {
                $secstr.AppendChar($char)
            }
        }
        $cred = New-Object System.Management.Automation.PSCredential($Username, $secstr)
    }

    $scriptBlock = {
        param([bool]$BenchmarkEnabled)

        function Get-SmartctlWindowsDeviceIndex {
            param(
                [AllowNull()]
                [string]$DeviceName
            )

            if ([string]::IsNullOrWhiteSpace($DeviceName)) {
                return $null
            }

            if ($DeviceName -match '^/dev/pd(\d+)$' -or $DeviceName -match '^\\\\\.\\PhysicalDrive(\d+)$') {
                return [int]$Matches[1]
            }

            if ($DeviceName -notmatch '^/dev/sd([a-z]+)$') {
                return $null
            }

            # smartmontools for Windows maps /dev/sda to PhysicalDrive0,
            # /dev/sdz to PhysicalDrive25, /dev/sdaa to PhysicalDrive26, etc.
            $oneBasedIndex = 0
            foreach ($character in $Matches[1].ToCharArray()) {
                $oneBasedIndex = ($oneBasedIndex * 26) + ([int]$character - [int][char]'a' + 1)
            }

            return $oneBasedIndex - 1
        }

        function Test-SmartctlTelemetryPayload {
            param([AllowNull()]$Payload)

            return [bool](
                $Payload -and
                ($Payload.ata_smart_attributes -or $Payload.nvme_smart_health_information_log)
            )
        }

        function Get-KnownUsbNvmeBridgeType {
            param(
                [AllowNull()]
                [string[]]$InstanceIds
            )

            foreach ($instanceId in @($InstanceIds)) {
                if ($instanceId -notmatch '^USB\\VID_([0-9A-F]{4})&PID_([0-9A-F]{4})(?:\\|$)') {
                    continue
                }

                $usbId = "$($Matches[1]):$($Matches[2])".ToUpperInvariant()
                switch ($usbId) {
                    '152D:0581' {
                        return [PSCustomObject]@{
                            UsbId = $usbId
                            SmartctlType = 'sntjmicron'
                            Description = 'JMicron JMS583-compatible USB-to-NVMe bridge'
                        }
                    }
                }
            }

            return $null
        }

        $collectorWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $benchmarkRows = [System.Collections.Generic.List[object]]::new()
        $inventoryWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        $disks = Get-CimInstance -ClassName Win32_DiskDrive
        $physicalDisks = Get-PhysicalDisk -ErrorAction SilentlyContinue
        $allData = Get-CimInstance -ClassName MSStorageDriver_FailurePredictData -Namespace root\wmi -ErrorAction SilentlyContinue
        $allThresholds = Get-CimInstance -ClassName MSStorageDriver_FailurePredictThresholds -Namespace root\wmi -ErrorAction SilentlyContinue
        $partitions = Get-CimInstance -ClassName Win32_DiskPartition
        $logicalToPart = Get-CimInstance -ClassName Win32_LogicalDiskToPartition
        $inventoryWatch.Stop()
        if ($BenchmarkEnabled) {
            $benchmarkRows.Add([PSCustomObject]@{
                Phase        = 'Collector.Inventory'
                Milliseconds = $inventoryWatch.Elapsed.TotalMilliseconds
                Details      = "$(@($disks).Count) disks"
            })
        }

        # Reliability counters are queried lazily only when NVMe smartctl data
        # is unavailable. USB bridges may block this call for tens of seconds.
        $reliabilityCounters = @{}

        # smartctl scanning is also lazy and shared across all disks.
        $smartctlScanLoaded = $false
        $smartctlScanData = $null
        $smartctlScanSummary = @()

        function Add-CollectorBenchmark {
            param(
                [string]$Phase,
                [System.Diagnostics.Stopwatch]$Watch,
                [string]$Details = ''
            )
            if ($BenchmarkEnabled) {
                $benchmarkRows.Add([PSCustomObject]@{
                    Phase        = $Phase
                    Milliseconds = $Watch.Elapsed.TotalMilliseconds
                    Details      = $Details
                })
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
            $smartctlDevice = "/dev/pd$($disk.Index)"
            $smartctlType = "auto"
            $smartctlIssue = ""
            $resolvedModel = $disk.Model
            $resolvedSerial = $disk.SerialNumber.Trim()
            $resolvedFirmware = if ($physDisk) { $physDisk.FirmwareVersion } else { $disk.FirmwareRevision }
            if ($smartctlPath -and $isAdmin) {
                $rawOutput = $null
                $parsedCheck = $null
                $isUsbDisk = $physDisk -and $physDisk.BusType -eq "USB"

                # USB bridges frequently fail auto-detection. Go directly to the
                # cached scan map and avoid a known-failing extra probe.
                if (-not $isUsbDisk) {
                    $autoWatch = [System.Diagnostics.Stopwatch]::StartNew()
                    $rawOutput = & $smartctlPath -a $smartctlDevice --json 2>$null
                    $autoWatch.Stop()
                    Add-CollectorBenchmark -Phase "Collector.SmartctlAuto.Disk$($disk.Index)" -Watch $autoWatch -Details $smartctlDevice
                    $parsedCheck = if ($rawOutput) { try { $rawOutput | ConvertFrom-Json } catch { $null } } else { $null }
                }

                if (-not (Test-SmartctlTelemetryPayload -Payload $parsedCheck)) {
                    if (-not $smartctlScanLoaded) {
                        $scanWatch = [System.Diagnostics.Stopwatch]::StartNew()
                        $scanOutput = & $smartctlPath --scan-open --json 2>$null
                        $scanWatch.Stop()
                        Add-CollectorBenchmark -Phase 'Collector.SmartctlScanOpen' -Watch $scanWatch
                        $smartctlScanData = if ($scanOutput) { try { $scanOutput | ConvertFrom-Json } catch { $null } } else { $null }
                        $smartctlScanLoaded = $true
                        foreach ($scanCandidate in @($smartctlScanData.devices)) {
                            $scanIndex = Get-SmartctlWindowsDeviceIndex -DeviceName $scanCandidate.name
                            $smartctlScanSummary += "$($scanCandidate.name) (-d $($scanCandidate.type), index=$scanIndex)"
                        }
                    }
                    $scanData = $smartctlScanData

                    $knownUsbBridge = $null
                    if ($isUsbDisk) {
                        $pnpWatch = [System.Diagnostics.Stopwatch]::StartNew()
                        $pnpAncestry = @()
                        $currentInstanceId = $disk.PNPDeviceID
                        for ($depth = 0; $depth -lt 8 -and $currentInstanceId; $depth++) {
                            $pnpAncestry += $currentInstanceId
                            $parentProperty = Get-PnpDeviceProperty `
                                -InstanceId $currentInstanceId `
                                -KeyName 'DEVPKEY_Device_Parent' `
                                -ErrorAction SilentlyContinue
                            $parentInstanceId = [string]$parentProperty.Data
                            if ([string]::IsNullOrWhiteSpace($parentInstanceId) -or $parentInstanceId -eq $currentInstanceId) {
                                break
                            }
                            $currentInstanceId = $parentInstanceId
                        }
                        $knownUsbBridge = Get-KnownUsbNvmeBridgeType -InstanceIds $pnpAncestry
                        $pnpWatch.Stop()
                        Add-CollectorBenchmark `
                            -Phase "Collector.UsbBridge.Disk$($disk.Index)" `
                            -Watch $pnpWatch `
                            -Details $(if ($knownUsbBridge) { $knownUsbBridge.UsbId } else { 'unknown' })
                    }

                    $indexedDevices = @()
                    $identityDevices = @()
                    foreach ($candidate in @($scanData.devices)) {
                        $candidateIndex = Get-SmartctlWindowsDeviceIndex -DeviceName $candidate.name
                        $candidateRecord = [PSCustomObject]@{
                            Scan          = $candidate
                            Identity      = $null
                            EffectiveType = if (
                                $knownUsbBridge -and
                                $null -ne $candidateIndex -and
                                $candidateIndex -eq [int]$disk.Index
                            ) {
                                $knownUsbBridge.SmartctlType
                            } else {
                                $candidate.type
                            }
                        }
                        if ($null -ne $candidateIndex -and $candidateIndex -eq [int]$disk.Index) {
                            $indexedDevices += $candidateRecord
                        }
                    }

                    # Identity probing is a fallback only. Some SCSI wrappers take
                    # more than six seconds even for -i, while index mapping is exact.
                    if ($indexedDevices.Count -eq 0) {
                        $identityWatch = [System.Diagnostics.Stopwatch]::StartNew()
                        foreach ($candidate in @($scanData.devices)) {
                            $identityOutput = & $smartctlPath -i -d $candidate.type $candidate.name --json 2>$null
                            $identity = if ($identityOutput) { try { $identityOutput | ConvertFrom-Json } catch { $null } } else { $null }
                            if (-not $identity) { continue }

                            $wmiSerial = $disk.SerialNumber -replace '\s+', ''
                            $smartSerial = $identity.serial_number -replace '\s+', ''
                            $serialMatch = $wmiSerial -and $smartSerial -and $wmiSerial -eq $smartSerial
                            $modelMatch = $identity.model_name -and $disk.Model -and $identity.model_name.Trim() -eq $disk.Model.Trim()
                            if ($serialMatch -or $modelMatch) {
                                $identityDevices += [PSCustomObject]@{
                                    Scan          = $candidate
                                    Identity      = $identity
                                    EffectiveType = $candidate.type
                                }
                            }
                        }
                        $identityWatch.Stop()
                        Add-CollectorBenchmark -Phase "Collector.IdentityFallback.Disk$($disk.Index)" -Watch $identityWatch
                    }

                    # PhysicalDrive index is the deterministic Windows mapping and
                    # survives USB/UASP wrappers that rewrite model and serial data.
                    # The outer @() is required: assignment from an if expression
                    # otherwise unwraps a single PSCustomObject and .Count is null.
                    $matchingDevices = @(
                        if ($indexedDevices.Count -gt 0) {
                            $indexedDevices
                        } else {
                            $identityDevices
                        }
                    )

                    if ($matchingDevices.Count -eq 1) {
                        $smartctlDevice = $matchingDevices[0].Scan.name
                        $smartctlType = $matchingDevices[0].EffectiveType
                        $resolvedWatch = [System.Diagnostics.Stopwatch]::StartNew()
                        $rawOutput = & $smartctlPath -a -d $smartctlType $smartctlDevice --json 2>$null
                        $resolvedWatch.Stop()
                        Add-CollectorBenchmark `
                            -Phase "Collector.SmartctlResolved.Disk$($disk.Index)" `
                            -Watch $resolvedWatch `
                            -Details "$smartctlDevice -d $smartctlType"
                        $parsedCheck = if ($rawOutput) { try { $rawOutput | ConvertFrom-Json } catch { $null } } else { $null }
                    } elseif ($matchingDevices.Count -gt 1) {
                        $smartctlIssue = "Το smartctl επέστρεψε πολλαπλά candidates για PhysicalDrive$($disk.Index). Δεν έγινε αυθαίρετη επιλογή."
                    } else {
                        $scanDetails = if ($smartctlScanSummary.Count -gt 0) {
                            $smartctlScanSummary -join '; '
                        } else {
                            'κανένα parsed candidate'
                        }
                        $smartctlIssue = "Δεν βρέθηκε --scan-open candidate για PhysicalDrive$($disk.Index). Scan: $scanDetails"
                    }
                }
                if (Test-SmartctlTelemetryPayload -Payload $parsedCheck) {
                    $smartctlData = $rawOutput | Out-String
                    $smartctlIssue = ""

                    if ($parsedCheck.model_name) {
                        $resolvedModel = $parsedCheck.model_name
                    }
                    if ($parsedCheck.serial_number) {
                        $resolvedSerial = $parsedCheck.serial_number
                    }
                    if ($parsedCheck.firmware_version) {
                        $resolvedFirmware = $parsedCheck.firmware_version
                    }

                    if ($parsedCheck.nvme_smart_health_information_log -or $parsedCheck.device.protocol -eq "NVMe") {
                        $isNVMe = $true
                        $standard = "NVM Express"
                        if ($physDisk -and $physDisk.BusType -eq "USB") {
                            $transferMode = "USB/UASP bridge -> NVMe (link speed unavailable)"
                        }
                    }
                } elseif (-not $smartctlIssue) {
                    $smartctlIssue = "Το smartctl άνοιξε τη συσκευή αλλά δεν επέστρεψε ATA/NVMe health telemetry."
                }
            } elseif (-not $smartctlPath) {
                $smartctlIssue = "Το smartctl δεν είναι εγκατεστημένο ή δεν βρέθηκε στο PATH/Program Files."
            } elseif (-not $isAdmin) {
                $smartctlIssue = "Η συλλογή smartctl δεν εκτελέστηκε χωρίς Administrator δικαιώματα."
            }

            if (
                $isAdmin -and
                $physDisk -and
                $isNVMe -and
                -not $smartctlData -and
                $physDisk.BusType -ne "USB"
            ) {
                $reliabilityKey = [string]$physDisk.DeviceId
                if (-not $reliabilityCounters.ContainsKey($reliabilityKey)) {
                    $reliabilityWatch = [System.Diagnostics.Stopwatch]::StartNew()
                    $reliabilityCounters[$reliabilityKey] = Get-StorageReliabilityCounter `
                        -PhysicalDisk $physDisk `
                        -ErrorAction SilentlyContinue
                    $reliabilityWatch.Stop()
                    Add-CollectorBenchmark `
                        -Phase "Collector.Reliability.Disk$($disk.Index)" `
                        -Watch $reliabilityWatch `
                        -Details 'NVMe fallback'
                }
                $relCounter = $reliabilityCounters[$reliabilityKey]
            } elseif ($BenchmarkEnabled -and $physDisk -and $physDisk.BusType -eq "USB") {
                $benchmarkRows.Add([PSCustomObject]@{
                    Phase        = "Collector.Reliability.Disk$($disk.Index)"
                    Milliseconds = 0
                    Details      = 'Skipped USB timeout path'
                })
            }

            $results += [PSCustomObject]@{
                Index = $disk.Index
                Model = $resolvedModel
                SerialNumber = $resolvedSerial
                Size = $disk.Size
                InterfaceType = $disk.InterfaceType
                PNPDeviceID = $disk.PNPDeviceID
                MediaType = if ($physDisk) { $physDisk.MediaType } else { "SSD" }
                BusType = if ($physDisk) { $physDisk.BusType } else { "SATA" }
                Firmware = $resolvedFirmware
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
                SmartctlDevice = $smartctlDevice
                SmartctlType = $smartctlType
                SmartctlIssue = $smartctlIssue
                Standard = $standard
                TransferMode = $transferMode
                RotationRate = $rotationRate
            }
        }
        $collectorWatch.Stop()
        if ($BenchmarkEnabled) {
            $benchmarkRows.Add([PSCustomObject]@{
                Phase        = 'Collector.Total'
                Milliseconds = $collectorWatch.Elapsed.TotalMilliseconds
                Details      = "$($results.Count) disks"
            })
        }

        [PSCustomObject]@{
            ComputerName = $env:COMPUTERNAME
            Disks        = @($results)
            Benchmarks   = @($benchmarkRows)
        }
    }

    $session = $null
    try {
        if ($isLocal) {
            $collectorInvokeWatch = [System.Diagnostics.Stopwatch]::StartNew()
            $collectionPayload = Invoke-Command `
                -ScriptBlock $scriptBlock `
                -ArgumentList ([bool]$Benchmark)
            $collectorInvokeWatch.Stop()
            Write-DiskHealthBenchmarkLine `
                -Phase 'Collector.Invoke.Local' `
                -Milliseconds $collectorInvokeWatch.Elapsed.TotalMilliseconds
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

            $sessionWatch = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $session = Connect-WinRMSession `
                    -ComputerName $ComputerName `
                    -Credential $cred `
                    -OnStatus ${function:Write-DiskHealthWinRMConnectionStatus}
                $sessionWatch.Stop()
            } catch {
                $sessionWatch.Stop()
                $connectionCategory = Get-WinRMConnectionErrorCategory -ErrorObject $_
                $isAuthError = $connectionCategory -eq 'AuthenticationRejected'
                $isInteractive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
                if ($isAuthError -and $CredentialFromSavedProfile -and -not [string]::IsNullOrWhiteSpace($ConnectionNetworkId)) {
                    Remove-DiskHealthStoredCredential `
                        -NetworkId $ConnectionNetworkId `
                        -ComputerNames $connectionAliases
                }

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
                            $retryWatch = [System.Diagnostics.Stopwatch]::StartNew()
                            $session = Connect-WinRMSession `
                                -ComputerName $ComputerName `
                                -Credential $promptCred `
                                -OnStatus ${function:Write-DiskHealthWinRMConnectionStatus}
                            $retryWatch.Stop()
                            $cred = $promptCred
                            $CredentialFromSavedProfile = $false
                            $Username = $cred.UserName
                            Write-DiskHealthBenchmarkLine `
                                -Phase 'WinRM.NewPSSession.Retry' `
                                -Milliseconds $retryWatch.Elapsed.TotalMilliseconds `
                                -Details $ComputerName
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
            Write-DiskHealthBenchmarkLine `
                -Phase 'WinRM.NewPSSession' `
                -Milliseconds $sessionWatch.Elapsed.TotalMilliseconds `
                -Details $ComputerName

            if (-not [string]::IsNullOrWhiteSpace($ConnectionNetworkId)) {
                Save-DiskHealthStoredCredential `
                    -NetworkId $ConnectionNetworkId `
                    -ComputerNames $connectionAliases `
                    -CredentialToStore $cred
                Write-Host "  🔐 Το credential αποθηκεύτηκε με DPAPI για αυτό το PC και δίκτυο." -ForegroundColor $Green
            }

            # Detect the dependency first. Interactive users choose in-app;
            # -InstallSmartctl remains the non-interactive automation override.
            $prerequisiteWatch = [System.Diagnostics.Stopwatch]::StartNew()
            $remoteInfo = Invoke-Command -Session $session -ScriptBlock {
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
                [PSCustomObject]@{
                    ComputerName   = $env:COMPUTERNAME
                    SmartctlExists = $found
                }
            }
            $prerequisiteWatch.Stop()
            Write-DiskHealthBenchmarkLine `
                -Phase 'WinRM.PrerequisiteProbe' `
                -Milliseconds $prerequisiteWatch.Elapsed.TotalMilliseconds `
                -Details "$($remoteInfo.ComputerName); smartctl=$($remoteInfo.SmartctlExists)"
            $remoteSmartctlExists = [bool]$remoteInfo.SmartctlExists

            $installSmartctlNow = [bool]$InstallSmartctl
            if (-not $remoteSmartctlExists -and -not $installSmartctlNow) {
                $canPromptForInstall = (
                    -not $NoUI -and
                    [Environment]::UserInteractive -and
                    -not [Console]::IsInputRedirected
                )
                if ($canPromptForInstall) {
                    $installChoice = Show-SmartctlInstallMenu
                    if ($installChoice -eq 'Back') {
                        return
                    }
                    $installSmartctlNow = $installChoice -eq 'Install'
                } else {
                    Write-Host "⚠️⚠️⚠️ NEED TOOL: Το remote PC δεν διαθέτει smartctl. Συνεχίζουμε με περιορισμένα WMI/CIM diagnostics." -ForegroundColor $Yellow
                    Write-Host "       Για automation χρησιμοποιήστε -InstallSmartctl ή εγκαταστήστε το από trusted source." -ForegroundColor $Gray
                }
            }

            if (-not $remoteSmartctlExists -and $installSmartctlNow) {
                Write-Host "  ⚠️ Το remote PC δεν διαθέτει smartctl. Εκκίνηση επίσημης εγκατάστασης μέσω winget..." -ForegroundColor $Yellow
                $installResult = Invoke-Command -Session $session -ScriptBlock {
                    function Get-WingetSmartctlInstallArguments {
                        param([AllowEmptyString()][string]$InstallHelp = '')

                        $arguments = @(
                            'install'
                            '--id'
                            'smartmontools.smartmontools'
                            '--exact'
                            '--source'
                            'winget'
                            '--scope'
                            'machine'
                            '--silent'
                        )
                        # winget 1.3 does not support this switch. Detect the
                        # actual CLI capability instead of assuming a version.
                        if ($InstallHelp -match '(?m)^\s*--disable-interactivity(?:\s|$)') {
                            $arguments += '--disable-interactivity'
                        }

                        return $arguments
                    }

                    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
                    if (-not $winget) {
                        return [PSCustomObject]@{
                            Success = $false
                            Message = 'Το winget.exe δεν είναι διαθέσιμο στο remote session.'
                            Version = ''
                        }
                    }

                    $wingetInstallHelp = (& $winget.Source install --help 2>&1 | Out-String)
                    $wingetArguments = Get-WingetSmartctlInstallArguments -InstallHelp $wingetInstallHelp
                    $wingetOutput = & $winget.Source @wingetArguments 2>&1 | Out-String
                    $wingetExitCode = $LASTEXITCODE
                    $installedPath = 'C:\Program Files\smartmontools\bin\smartctl.exe'
                    if ($wingetExitCode -ne 0 -or -not (Test-Path -LiteralPath $installedPath -PathType Leaf)) {
                        return [PSCustomObject]@{
                            Success = $false
                            Message = "winget exit $wingetExitCode. $($wingetOutput.Trim())"
                            Version = ''
                        }
                    }

                    $versionLine = (& $installedPath --version 2>&1 | Select-Object -First 1)
                    [PSCustomObject]@{
                        Success = $true
                        Message = 'Εγκαταστάθηκε στο C:\Program Files\smartmontools.'
                        Version = [string]$versionLine
                    }
                }

                if ($installResult.Success) {
                    Write-Host "  ✅ $($installResult.Message)" -ForegroundColor $Green
                    Write-Host "     $($installResult.Version)" -ForegroundColor $Gray
                } else {
                    Write-Host "⚠️⚠️⚠️ INSTALL FAILED: $($installResult.Message)" -ForegroundColor $Red
                    Write-Host "       Δεν δημιουργήθηκε fallback φάκελος στο C:\." -ForegroundColor $Yellow
                }
            }

            $collectorInvokeWatch = [System.Diagnostics.Stopwatch]::StartNew()
            $collectionPayload = Invoke-Command `
                -Session $session `
                -ScriptBlock $scriptBlock `
                -ArgumentList ([bool]$Benchmark)
            $collectorInvokeWatch.Stop()
            Write-DiskHealthBenchmarkLine `
                -Phase 'Collector.Invoke.Remote' `
                -Milliseconds $collectorInvokeWatch.Elapsed.TotalMilliseconds `
                -Details $ComputerName

            if (-not [string]::IsNullOrWhiteSpace($ConnectionNetworkId)) {
                $resolvedComputerName = if (
                    -not [string]::IsNullOrWhiteSpace([string]$collectionPayload.ComputerName)
                ) {
                    [string]$collectionPayload.ComputerName
                } else {
                    [string]$remoteInfo.ComputerName
                }
                $resolvedMacAddress = $ConnectionMacAddress
                if ([string]::IsNullOrWhiteSpace($resolvedMacAddress)) {
                    $neighbor = Get-NetNeighbor -IPAddress $ComputerName -ErrorAction SilentlyContinue |
                        Where-Object { $_.LinkLayerAddress -and $_.LinkLayerAddress -ne '00-00-00-00-00-00' } |
                        Select-Object -First 1
                    if ($neighbor) {
                        $resolvedMacAddress = [string]$neighbor.LinkLayerAddress
                    }
                }
                if ([string]::IsNullOrWhiteSpace($resolvedMacAddress)) {
                    $resolvedMacAddress = 'Unknown'
                }

                Add-WinRMConnectionHistoryEntry `
                    -ComputerName $resolvedComputerName `
                    -LastIPAddress $ComputerName `
                    -MACAddress $resolvedMacAddress `
                    -UserName $cred.UserName `
                    -NetworkId $ConnectionNetworkId
                $credentialAliases = @(
                    $connectionAliases
                    $resolvedComputerName
                    $ComputerName
                ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
                Save-DiskHealthStoredCredential `
                    -NetworkId $ConnectionNetworkId `
                    -ComputerNames $credentialAliases `
                    -CredentialToStore $cred
            }
        }

        $collected = @($collectionPayload.Disks)
        foreach ($benchmarkRow in @($collectionPayload.Benchmarks)) {
            Write-DiskHealthBenchmarkLine `
                -Phase ([string]$benchmarkRow.Phase) `
                -Milliseconds ([double]$benchmarkRow.Milliseconds) `
                -Details ([string]$benchmarkRow.Details)
        }
        $operationWatch.Stop()
        Write-DiskHealthBenchmarkLine `
            -Phase 'Operation.Total' `
            -Milliseconds $operationWatch.Elapsed.TotalMilliseconds `
            -Details $(if ($isLocal) { 'localhost' } else { $ComputerName })
        if ($Benchmark -and -not [string]::IsNullOrWhiteSpace($script:DiskHealthBenchmarkLogPath)) {
            Write-Host "  ⏱️ Benchmark log: $script:DiskHealthBenchmarkLogPath" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "❌ Σφάλμα κατά τη σύνδεση ή τη συλλογή δεδομένων: $_" -ForegroundColor $Red
        return
    } finally {
        if ($session) {
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        }
    }
}

function Show-DriveMenu {
    param (
        [array]$Drives,
        [switch]$AllowBack
    )

    try {
        $selectedIndex = 0

        $options = [System.Collections.Generic.List[object]]::new()
        for ($driveIndex = 0; $driveIndex -lt $Drives.Count; $driveIndex++) {
            $d = $Drives[$driveIndex]
            $lettersStr = if ($d.Letters) { "($($d.Letters -join ', '))" } else { "" }
            $options.Add([PSCustomObject]@{
                Action     = 'Drive'
                DriveIndex = $driveIndex
                Label      = "Disk $($d.Index): $($d.Model) - $([Math]::Round($d.Size / 1GB, 2)) GB $lettersStr"
            })
        }
        if ($Drives.Count -gt 1) {
            $options.Add([PSCustomObject]@{ Action = 'All'; DriveIndex = -1; Label = 'Διάγνωση όλων των δίσκων (All Drives)' })
        }

        # Hide cursor
        try { [Console]::CursorVisible = $false } catch {}

        $firstRun = $true
        # Header + options + navigation footer + ESC footer.
        $menuHeight = $options.Count + 3

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
                $optionLabel = Get-MenuDisplayText -Text "[$($i + 1)] $($options[$i].Label)"
                if ($i -eq $selectedIndex) {
                    Write-Host "  ➔ [ " -NoNewline -ForegroundColor $Yellow
                    Write-Host $optionLabel -NoNewline -ForegroundColor $Cyan
                    Write-Host " ]" -ForegroundColor $Yellow
                } else {
                    Write-Host "     $optionLabel" -ForegroundColor $Gray
                }
            }
            Write-Host '  ↑/↓ Navigation  Enter Select  1-9 Shortcut' -ForegroundColor $Gray
            Write-Host $(if ($AllowBack) { '  ESC Back' } else { '  ESC Exit' }) -ForegroundColor $Red

            $key = [Console]::ReadKey($true)
            if ($key.Key -eq "UpArrow") {
                $selectedIndex = if ($selectedIndex -eq 0) { $options.Count - 1 } else { $selectedIndex - 1 }
            }
            elseif ($key.Key -eq "DownArrow") {
                $selectedIndex = if ($selectedIndex -eq $options.Count - 1) { 0 } else { $selectedIndex + 1 }
            }
            elseif ($key.Key -eq "Escape") {
                return [PSCustomObject]@{
                    Action     = $(if ($AllowBack) { 'Back' } else { 'Exit' })
                    DriveIndex = -1
                    Label      = ''
                }
            }
            elseif ($key.Key -eq "Enter") {
                break
            }
            elseif ($key.KeyChar -match '^[1-9]$') {
                $numberIndex = [int][string]$key.KeyChar - 1
                if ($numberIndex -lt $options.Count) {
                    $selectedIndex = $numberIndex
                    break
                }
            }
        }

        try { [Console]::CursorVisible = $true } catch {}
        Write-Host ""
        return $options[$selectedIndex]
    } catch {
        # Fallback αν αποτύχει το console interaction
        if ($Drives.Count -gt 1) {
            return [PSCustomObject]@{ Action = 'All'; DriveIndex = -1; Label = 'All Drives' }
        }
        return [PSCustomObject]@{ Action = 'Drive'; DriveIndex = 0; Label = 'Disk' }
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
    $allowBack = [bool]$EmbeddedRemote
    $menuEnabled = -not $NoUI -and $isInteractive -and ($collected.Count -gt 1 -or $allowBack)

    if ($menuEnabled) {
        Clear-Host
        Write-Host "======================================================================" -ForegroundColor $Cyan
        Write-Host "  💾 ΔΙΑΓΝΩΣΤΙΚΟ ΥΓΕΙΑΣ ΔΙΣΚΩΝ (Disk Health Diagnostics)" -ForegroundColor $Cyan
        Write-Host "======================================================================" -ForegroundColor $Cyan
        Write-Host "  🌐 Στόχος: $ComputerName (Χρήστης: $Username)" -ForegroundColor $White
        Write-Host "  🔧 Μέθοδος: Native smartctl & WMI/CIM Queries" -ForegroundColor $White
        Write-Host "----------------------------------------------------------------------" -ForegroundColor $Cyan

        $menuChoice = Show-DriveMenu -Drives $collected -AllowBack:$allowBack
        if ($menuChoice.Action -eq 'Exit') {
            Clear-Host
            Write-Host "👋 Αντίο! (Exiting...)" -ForegroundColor $Green
            break
        }
        if ($menuChoice.Action -eq 'Back') {
            break
        }
        if ($menuChoice.Action -eq 'Drive') {
            $selectedDrives = @($collected[$menuChoice.DriveIndex])
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
    } else {
        $brand = Get-AtaTelemetryProfile -Model $disk.Model -Firmware $disk.Firmware -Attributes @()
    }

    # PARSE SMARTCTL JSON DATA IF AVAILABLE
    $smart = $null
    if ($disk.SmartctlJSON) {
        try {
            $smart = $disk.SmartctlJSON | ConvertFrom-Json
        } catch {}
    }

    if ($smart) {
        if ($smart.nvme_smart_health_information_log -or $smart.device.protocol -eq "NVMe") {
            $isDiskNVMe = $true
            $brand = "NVMe"
        }
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

    if (-not $isDiskNVMe) {
        $profileAttributes = if ($smart -and $smart.ata_smart_attributes.table) {
            @($smart.ata_smart_attributes.table)
        } elseif ($disk.ImportedFromFile -and $disk.ParsedAttributes) {
            @($disk.ParsedAttributes)
        } else {
            @()
        }
        $brand = Get-AtaTelemetryProfile -Model $disk.Model -Firmware $disk.Firmware -Attributes $profileAttributes
    }

    $isRotationalMedia = (-not $isDiskNVMe) -and (
        $disk.MediaType -match '(?i)HDD|Hard Disk' -or
        $disk.RotationRate -match '^\s*\d+\s*RPM'
    )

    Write-Host "### 🔵 Στοιχεία Δίσκου (Index: $($disk.Index))" -ForegroundColor $Cyan
    Write-Host "  🔸 Μοντέλο: " -NoNewline -ForegroundColor $White
    Write-Host "$($disk.Model)" -ForegroundColor $Cyan
    Write-Host "  🔸 Serial Number: " -NoNewline -ForegroundColor $White
    Write-Host "$($disk.SerialNumber)" -ForegroundColor $Cyan
    Write-Host "  🔸 Χωρητικότητα: " -NoNewline -ForegroundColor $White
    Write-Host "$([Math]::Round($disk.Size / 1GB, 2)) GB" -ForegroundColor $Gray
    Write-Host "  🔸 Τύπος Μέσου: " -NoNewline -ForegroundColor $White
    Write-Host "$($disk.MediaType) ($($disk.BusType))" -ForegroundColor $Gray
    Write-Host "  🔸 Drive Letter(s): " -NoNewline -ForegroundColor $White
    Write-Host "$($disk.Letters -join ', ')" -ForegroundColor $Cyan
    Write-Host "  🔸 Firmware: " -NoNewline -ForegroundColor $White
    Write-Host "$($disk.Firmware)" -ForegroundColor $Gray
    if ($disk.SmartctlJSON) {
        Write-Host "  🔸 SMART Source: " -NoNewline -ForegroundColor $White
        Write-Host "$($disk.SmartctlDevice) (-d $($disk.SmartctlType))" -ForegroundColor $Gray
    }

    if ($disk.Standard) {
        Write-Host "  🔸 Standard: " -NoNewline -ForegroundColor $White
        Write-Host "$($disk.Standard)" -ForegroundColor $Gray
    }
    if ($disk.TransferMode) {
        Write-Host "  🔸 Transfer Mode: " -NoNewline -ForegroundColor $White
        Write-Host "$($disk.TransferMode)" -ForegroundColor $Cyan
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

            $criticalWarningValue = ConvertTo-NvmeCounter -Value $log.critical_warning
            $errorLogEntryValue = ConvertTo-NvmeCounter -Value $log.num_err_log_entries -StringValue $log.num_err_log_entries_s
            $mediaErrorValue = ConvertTo-NvmeCounter -Value $log.media_errors -StringValue $log.media_errors_s
            $mediaErrorAssessment = Get-NvmeMediaErrorAssessment -MediaErrors $mediaErrorValue -ErrorLogEntries $errorLogEntryValue -CriticalWarning $criticalWarningValue

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
                @{ ID = 0x0E; Name = "Media and Data Integrity Errors"; Raw = $log.media_errors; RawString = $log.media_errors_s }
                @{ ID = 0x0F; Name = "Number of Error Information Log Entries"; Raw = $log.num_err_log_entries; RawString = $log.num_err_log_entries_s }
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
                $rawVal = ConvertTo-NvmeCounter -Value $item.Raw -StringValue $item.RawString
                $attributes += [PSCustomObject]@{
                    IDHex     = "0x{0:X2}" -f $item.ID
                    ID        = $item.ID
                    Name      = $item.Name
                    Current   = 100
                    Worst     = 100
                    Threshold = 0
                    Raw       = $rawVal
                    RawHex    = "0x$($rawVal.ToString('X').PadLeft(12, [char]'0'))"
                    IsCelsius = $item.IsCelsius
                    IsTelemetryAnomaly = ($item.ID -eq 0x0E -and $mediaErrorAssessment.IsStructuralAnomaly)
                    Low64 = if ($item.ID -eq 0x0E) { $mediaErrorAssessment.Low64 } else { $null }
                    Upper64 = if ($item.ID -eq 0x0E) { $mediaErrorAssessment.Upper64 } else { $null }
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
                    RawString = [string]$attr.raw.string
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
        if ($disk.SmartctlIssue) {
            Write-Host "  🔧 smartctl: $($disk.SmartctlIssue)" -ForegroundColor $Gray
        }
        Write-Host "⚠️ Δεν βρέθηκαν S.M.A.R.T. δεδομένα για αυτόν τον δίσκο.`n" -ForegroundColor $Yellow
        continue
    }

    # 5. Υπολογισμός Υγείας (Health Calculation)
    $health = $null
    $healthSource = "No trusted vendor wear attribute"
    $healthMetricLabel = "Health"

    $wearB1 = $attributes | Where-Object { $_.ID -eq 0xB1 }
    $wearE9 = $attributes | Where-Object { $_.ID -eq 0xE9 }
    $wearA9 = $attributes | Where-Object { $_.ID -eq 0xA9 }
    $wear05 = $attributes | Where-Object { $_.ID -eq 0x05 }

    if ($brand -eq "NVMe" -and $wear05) {
        $health = 100 - $wear05.Raw
        $healthSource = "Percentage Used (0x05)"
    } elseif ($brand -ne 'NVMe') {
        $ataHealth = Get-AtaHealthEstimate -Profile $brand -Attributes $attributes
        if ($ataHealth.IsTrusted) {
            $health = $ataHealth.Percentage
            $healthSource = $ataHealth.Source
            $healthMetricLabel = $ataHealth.MetricLabel
        }
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
    $grownBadAA = $attributes | Where-Object { $_.ID -eq 0xAA }
    $programFailAB = $attributes | Where-Object { $_.ID -eq 0xAB }
    $eraseFailAC = $attributes | Where-Object { $_.ID -eq 0xAC }

    $nvmeCriticalWarning = $attributes | Where-Object { $_.ID -eq 0x01 }
    $nvmeMediaErrors = $attributes | Where-Object { $_.ID -eq 0x0E }

    $status = "GOOD"
    $statusColor = $Green
    $statusIcon = "✅"
    $cautionReasons = @()
    $badReasons = @()
    $retiredBlocksOnly = $false
    $hasActiveMediaErrors = $false

    if ($brand -ne "NVMe") {
        if ($brand -eq 'SanDisk' -and (($reallocated -and $reallocated.Raw -gt 0) -or ($grownBadAA -and $grownBadAA.Raw -gt 0))) {
            $status = "CAUTION"
            $statusColor = $Yellow
            $statusIcon = "⚠️"
            $grownCount = [Math]::Max($(if ($reallocated) { [long]$reallocated.Raw } else { 0 }), $(if ($grownBadAA) { [long]$grownBadAA.Raw } else { 0 }))
            $cautionReasons += "Grown/reassigned NAND blocks ($grownCount)"
            $retiredBlocksOnly = $true
        } elseif ($reallocated -and $reallocated.Raw -gt 0) {
            $status = "CAUTION"
            $statusColor = $Yellow
            $statusIcon = "⚠️"
            $cautionReasons += "Reallocated Sectors ($($reallocated.Raw))"
        }
        if ($brand -eq "SiliconMotionOEM" -and $uncorrectableA0 -and $uncorrectableA0.Raw -gt 0) {
            $status = "CAUTION"
            $statusColor = $Yellow
            $statusIcon = "⚠️"
            $cautionReasons += "Uncorrectable Sectors Read/Write ($($uncorrectableA0.Raw))"
            $hasActiveMediaErrors = $true
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
            $hasActiveMediaErrors = $true
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
            $hasActiveMediaErrors = $true
        }
        if ($uncorrectableC6 -and $uncorrectableC6.Raw -gt 0) {
            $status = "CAUTION"
            $statusColor = $Yellow
            $statusIcon = "⚠️"
            $cautionReasons += "Offline Uncorrectable Errors ($($uncorrectableC6.Raw))"
            $hasActiveMediaErrors = $true
        }
        if ($brand -eq 'SanDisk' -and $programFailAB -and $programFailAB.Raw -gt 0) {
            $status = "CAUTION"
            $statusColor = $Yellow
            $statusIcon = "⚠️"
            $cautionReasons += "Program Fail Count ($($programFailAB.Raw))"
            $hasActiveMediaErrors = $true
        }
        if ($brand -eq 'SanDisk' -and $eraseFailAC -and $eraseFailAC.Raw -gt 0) {
            $status = "CAUTION"
            $statusColor = $Yellow
            $statusIcon = "⚠️"
            $cautionReasons += "Erase Fail Count ($($eraseFailAC.Raw))"
            $hasActiveMediaErrors = $true
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
        if ($smart.smart_status -and $smart.smart_status.passed -eq $false) {
            $status = "BAD"
            $statusColor = $Red
            $statusIcon = "❌"
            $badReasons += "smartctl overall-health result is FAILED"
        }
        if ($nvmeCriticalWarning -and $nvmeCriticalWarning.Raw -gt 0) {
            $status = "BAD"
            $statusColor = $Red
            $statusIcon = "❌"
            $badReasons += "Critical Warning (Status Code: $($nvmeCriticalWarning.RawHex))"
        }
        if ($nvmeMediaErrors -and $nvmeMediaErrors.Raw -gt 0) {
            if ($nvmeMediaErrors.IsTelemetryAnomaly) {
                if ($status -eq "GOOD") {
                    $status = "REVIEW"
                    $statusColor = $Yellow
                    $statusIcon = "🔎"
                }
                $cautionReasons += "Inconsistent 128-bit NVMe telemetry: full=$($nvmeMediaErrors.Raw), low64=$($nvmeMediaErrors.Low64), error-log entries=0"
            } elseif ($status -ne "BAD") {
                $status = "CAUTION"
                $statusColor = $Yellow
                $statusIcon = "⚠️"
                $cautionReasons += "Media and Data Integrity Errors ($($nvmeMediaErrors.Raw))"
            }
        }
    }

    # Health % color code
    $healthPercentColor = $Green
    if ($status -ne "GOOD") {
        $healthPercentColor = $statusColor
    } elseif ($null -ne $health -and $health -le 60) {
        $healthPercentColor = $Yellow
    }

    Write-Host "### 🔵 Κατάσταση Υγείας (Health Status)" -ForegroundColor $Cyan
    Write-Host "  $statusIcon Κατάσταση: " -NoNewline -ForegroundColor $White
    Write-Host "$status " -NoNewline -ForegroundColor $statusColor
    Write-Host "(" -NoNewline -ForegroundColor $White
    $healthDisplay = if ($null -eq $health -and $isRotationalMedia) { 'SMART' } elseif ($null -eq $health) { 'N/A' } elseif ($healthMetricLabel -eq 'Health') { "$health%" } else { "$healthMetricLabel $health%" }
    Write-Host $healthDisplay -NoNewline -ForegroundColor $healthPercentColor
    Write-Host ")" -ForegroundColor $White

    if ($status -eq "GOOD") {
        if ($isRotationalMedia) {
            Write-Host "  🔸 Οι μηχανικοί HDD δεν διαθέτουν τυποποιημένο wear/health percentage. Η αξιολόγηση βασίζεται στο SMART overall status, στα thresholds και στους κρίσιμους raw counters." -ForegroundColor $Gray
        } elseif ($null -eq $health) {
            Write-Host "  🔸 Το SMART overall status είναι επιτυχές, αλλά δεν υπάρχει αξιόπιστο vendor mapping για ποσοστό ζωής NAND." -ForegroundColor $Gray
        } else {
            Write-Host "  🔸 Ο δίσκος εμφανίζει φυσιολογική φθορά της NAND flash μνήμης (πηγή: $healthSource)." -ForegroundColor $Gray
        }
        Write-Host "  🔸 Δεν ανιχνεύθηκαν ενεργά SMART failure indicators κατά τη συγκεκριμένη συλλογή." -ForegroundColor $Gray
    } elseif ($status -eq "REVIEW") {
        Write-Host "  🔎 ΑΠΑΙΤΕΙ ΕΛΕΓΧΟ: Εντοπίστηκε ασυνεπής NVMe telemetry που δεν πρέπει να μετατραπεί ούτε σε 0 ούτε σε αυτόματη αστοχία:" -ForegroundColor $Yellow
        foreach ($r in $cautionReasons) {
            Write-Host "     - $r" -ForegroundColor $Yellow
        }
        Write-Host "  🔸 Η ένδειξη ζωής NAND παραμένει ανεξάρτητη από αυτή την ανωμαλία. Απαιτείται επιβεβαίωση με raw log, firmware/vendor στοιχεία και διαγνωστικό test." -ForegroundColor $Gray
    } elseif ($status -eq "CAUTION") {
        Write-Host "  ⚠️ ΠΡΟΣΟΧΗ: Εντοπίστηκαν προβλήματα στα παρακάτω κρίσιμα attributes:" -ForegroundColor $Yellow
        foreach ($r in $cautionReasons) {
            Write-Host "     - $r" -ForegroundColor $Yellow
        }
        if ($brand -eq 'SanDisk' -and $retiredBlocksOnly -and -not $hasActiveMediaErrors) {
            Write-Host "  🔸 Καταγράφηκε ιστορική απόσυρση NAND blocks, αλλά όχι τρέχον uncorrectable/program/erase error σε αυτό το snapshot." -ForegroundColor $Gray
        }
        Write-Host "  🔸 Συνιστάται άμεσο backup, SMART self-test και αποθήκευση baseline για έλεγχο αν οι μετρητές αυξάνονται." -ForegroundColor $Gray
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
        if ($brand -eq "NVMe" -and $attr.ID -eq 0x0E -and $attr.IsTelemetryAnomaly) {
            $rawDisplay = "ANOMALY (low64=$($attr.Low64))".PadRight(17)
        } elseif (($brand -ne "NVMe" -and $attr.ID -eq 0x09) -or ($brand -eq "NVMe" -and $attr.ID -eq 0x0C)) {
            if ($brand -eq 'NVMe') {
                $rawDisplay = "$($attr.Raw) hrs".PadRight(17)
            } else {
                $decodedHours = Get-AtaPowerOnHoursValue -Attribute $attr -SmartData $smart
                $rawDisplay = if ($null -eq $decodedHours) { "raw=$($attr.Raw)".PadRight(17) } else { "$decodedHours hrs".PadRight(17) }
            }
        } elseif (($brand -ne "NVMe" -and $attr.ID -eq 0x0C) -or ($brand -eq "NVMe" -and $attr.ID -eq 0x0B)) {
            $rawDisplay = "$($attr.Raw) cycles".PadRight(17)
        } elseif ($isRotationalMedia -and $disk.Model -match '(?i)^(?:WDC|Western Digital|WD\s)' -and $attr.ID -eq 0x03) {
            $rawDisplay = (Get-AtaSpinUpTimeDisplay -RawMilliseconds ([long]$attr.Raw)).PadRight(17)
        } elseif ($attr.ID -eq 0xBE -or $attr.ID -eq 0xC2) {
            $temperatureCelsius = Get-AtaTemperatureCelsius -Attribute $attr -SmartData $smart
            $rawDisplay = if ($null -eq $temperatureCelsius) { "raw=$($attr.Raw)".PadRight(17) } else { "$temperatureCelsius C".PadRight(17) }
        } elseif ($brand -eq "NVMe" -and $attr.ID -eq 0x02) {
            $tempVal = if ($attr.IsCelsius) { $attr.Raw } elseif ($attr.Raw -gt 200) { $attr.Raw - 273 } else { $attr.Raw }
            $rawDisplay = "$tempVal C".PadRight(17)
        } elseif ($brand -eq "NVMe" -and ($attr.ID -eq 0x12 -or $attr.ID -eq 0x13)) {
            $tempVal = if ($attr.IsCelsius) { $attr.Raw } elseif ($attr.Raw -gt 200) { $attr.Raw - 273 } else { $attr.Raw }
            $rawDisplay = "$tempVal C".PadRight(17)
        } elseif ($brand -eq "NVMe" -and ($attr.ID -eq 0x06 -or $attr.ID -eq 0x07)) {
            $gbVal = [Math]::Round(([decimal]$attr.Raw * 512000) / 1GB, 2)
            $rawDisplay = "$gbVal GB".PadRight(17)
        } else {
            $rawDisplay = "$($attr.Raw)".PadRight(17)
        }

        # Coloring
        $lineColor = $Gray
        if ($brand -ne "NVMe") {
            if ($brand -eq 'SanDisk') {
                $sanDiskErrorIds = @(0x05, 0xAA, 0xAB, 0xAC, 0xB8, 0xBB, 0xBC, 0xC4, 0xC5, 0xC6)
                if ($attr.ID -in $sanDiskErrorIds) {
                    $lineColor = if ($attr.Raw -gt 0) { $Yellow } else { $Green }
                } elseif ($attr.ID -eq 0xE8) {
                    if ($attr.Raw -le $attr.Threshold -and $attr.Threshold -gt 0) { $lineColor = $Red }
                    elseif ($attr.Raw -lt 100) { $lineColor = $Yellow }
                    else { $lineColor = $Green }
                }
            } else {
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
        $phVal = if (-not $phAttr) { $null } elseif ($brand -eq 'NVMe') { [long]$phAttr.Raw } else { Get-AtaPowerOnHoursValue -Attribute $phAttr -SmartData $smart }
        Write-Host "  ✅ Δεν ανιχνεύθηκαν ενεργά SMART failure indicators κατά τη συγκεκριμένη συλλογή." -ForegroundColor $Green
        if ($null -ne $phVal) {
            Write-Host "  💡 Συμβουλή: Με $phVal ώρες λειτουργίας, η τήρηση τακτικού backup παραμένει standard πρακτική." -ForegroundColor $Gray
        } else {
            Write-Host "  💡 Συμβουλή: Η τήρηση τακτικού backup παραμένει standard πρακτική." -ForegroundColor $Gray
        }
    } elseif ($status -eq "REVIEW") {
        Write-Host "  🔎 Η εκτίμηση ζωής NAND είναι $health%, αλλά υπάρχει ασυνεπής raw NVMe telemetry." -ForegroundColor $Yellow
        Write-Host "  ⚠️ Μην αποφασίσετε αντικατάσταση ή αθώωση του δίσκου μόνο από αυτό το counter. Διατηρήστε backup και εκτελέστε πρόσθετο non-destructive validation." -ForegroundColor $Yellow
    } elseif ($status -eq "CAUTION") {
        if ($brand -eq 'SanDisk' -and $retiredBlocksOnly -and -not $hasActiveMediaErrors) {
            Write-Host "  ⚠️ Έχουν αποσυρθεί NAND blocks, όμως η συγκεκριμένη συλλογή δεν αποδεικνύει ότι η φθορά συνεχίζεται τώρα." -ForegroundColor $Yellow
            Write-Host "  🔸 Κρατήστε backup, εκτελέστε extended SMART self-test και επαναλάβετε τη μέτρηση. Αν τα 05/AA αυξηθούν, εμφανιστούν uncorrectable/program/erase errors ή αποτύχει το self-test, προχωρήστε σε αντικατάσταση." -ForegroundColor $Yellow
        } elseif ($hasActiveMediaErrors) {
            Write-Host "  ⚠️ Εντοπίστηκαν ενεργοί δείκτες media/data errors. Απαιτείται άμεσο backup και επιβεβαίωση με extended SMART self-test." -ForegroundColor $Yellow
            Write-Host "  🔸 Αν το self-test αποτύχει ή οι μετρητές αυξάνονται, αντικαταστήστε τον δίσκο." -ForegroundColor $Yellow
        } else {
            Write-Host "  ⚠️ Εντοπίστηκαν SMART warning indicators. Ένα μόνο snapshot δεν αρκεί για να αποδείξει επιδείνωση." -ForegroundColor $Yellow
            Write-Host "  🔸 Κρατήστε backup, εκτελέστε extended SMART self-test και συγκρίνετε με νέα μέτρηση πριν αποφασίσετε αντικατάσταση." -ForegroundColor $Yellow
        }
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

    # Silicon Motion / Patriot controller-specific notes
    if ($brand -in @('SiliconMotionOEM', 'PatriotBurst')) {
        $wearA9 = $attributes | Where-Object { $_.ID -eq 0xA9 }
        $hostWritesF1 = $attributes | Where-Object { $_.ID -eq 0xF1 }
        $nandWritesF5 = $attributes | Where-Object { $_.ID -eq 0xF5 }

        $profileLabel = if ($brand -eq 'SiliconMotionOEM') { 'Silicon Motion OEM' } else { 'Patriot Burst' }
        Write-Host "`n  🔵 Ειδική Παρατήρηση $profileLabel profile:" -ForegroundColor $Cyan
        if ($wearA9) {
            Write-Host "  🔸 Η υπολειπόμενη ζωή (Remain Life) είναι " -NoNewline -ForegroundColor $White
            Write-Host "$($wearA9.Raw)%" -ForegroundColor $Yellow
        }
        if ($brand -eq 'SiliconMotionOEM' -and $hostWritesF1 -and $nandWritesF5) {
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

    if ($brand -eq 'Phison') {
        $lifeE7 = $attributes | Where-Object { $_.ID -eq 0xE7 } | Select-Object -First 1
        $writesF1 = $attributes | Where-Object { $_.ID -eq 0xF1 } | Select-Object -First 1

        Write-Host "`n  🔵 Ειδική Παρατήρηση Phison profile:" -ForegroundColor $Cyan
        if ($lifeE7) {
            Write-Host "  🔸 Η υπολειπόμενη ζωή (SSD Life Left) είναι " -NoNewline -ForegroundColor $White
            Write-Host "$($lifeE7.Raw)%" -ForegroundColor $Yellow
        }
        if ($writesF1) {
            Write-Host "  🔸 Lifetime Writes: " -NoNewline -ForegroundColor $White
            Write-Host "$($writesF1.Raw) GiB" -ForegroundColor $Gray
        }
    }

    # SanDisk/WD Specific Notes
    if ($brand -eq "SanDisk") {
        $badBlocksA9 = $attributes | Where-Object { $_.ID -eq 0xA9 }
        $grownAA = $attributes | Where-Object { $_.ID -eq 0xAA }
        $reallocated05 = $attributes | Where-Object { $_.ID -eq 0x05 }
        $spareE8 = $attributes | Where-Object { $_.ID -eq 0xE8 }

        Write-Host "`n  🔵 Ειδική Παρατήρηση SanDisk/WD SSD:" -ForegroundColor $Cyan
        if ($badBlocksA9) {
            Write-Host "  🔸 Total Bad Blocks (A9): " -NoNewline -ForegroundColor $White
            Write-Host "$($badBlocksA9.Raw)" -ForegroundColor $Gray

            $hasGrownBad = ($grownAA -and $grownAA.Raw -gt 0) -or ($reallocated05 -and $reallocated05.Raw -gt 0)
            if (-not $hasGrownBad) {
                Write-Host "     - Δεν καταγράφονται grown/reassigned blocks (AA/05 = 0). Το A9 μόνο του δεν αποδεικνύει operational degradation." -ForegroundColor $Green
            } else {
                Write-Host "     - ⚠️ Έχουν καταγραφεί grown/reassigned NAND blocks κατά τη χρήση (AA/05 > 0)." -ForegroundColor $Yellow
                Write-Host "     - Αυτό αποδεικνύει ότι έγινε block retirement, όχι ότι ο ρυθμός βλάβης παραμένει ενεργός χωρίς σύγκριση με παλαιότερο baseline." -ForegroundColor $Gray
            }
        }
        if ($spareE8) {
            Write-Host "  🔸 Available Reserved Space (E8): " -NoNewline -ForegroundColor $White
            Write-Host "$($spareE8.Raw)%" -ForegroundColor $(if ($spareE8.Raw -lt 100) { "Yellow" } else { "Gray" })
            Write-Host "     - Είναι vendor reserve/endurance metric και όχι το proprietary συνολικό Health % του Hard Disk Sentinel." -ForegroundColor $Gray
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
            $readGB = [Math]::Round(([decimal]$readUnits06.Raw * 512000) / 1GB, 2)
            $writeGB = [Math]::Round(([decimal]$writeUnits07.Raw * 512000) / 1GB, 2)
            Write-Host "  🔸 Host Reads: " -NoNewline -ForegroundColor $White
            Write-Host "$readGB GB" -ForegroundColor $Gray
            Write-Host "  🔸 Host Writes: " -NoNewline -ForegroundColor $White
            Write-Host "$writeGB GB" -ForegroundColor $Gray
        }
        if ($unsafeShutdowns0D -and $unsafeShutdowns0D.Raw -gt 0) {
            Write-Host "  🔸 Απότομες Διακοπές Ρεύματος (Unsafe Shutdowns): " -NoNewline -ForegroundColor $White
            Write-Host "$($unsafeShutdowns0D.Raw)" -ForegroundColor $Yellow
        }
        if ($smart.nvme_self_test_log) {
            $currentTest = $smart.nvme_self_test_log.current_self_test_operation
            if ($currentTest -and $currentTest.value -gt 0) {
                $completion = $smart.nvme_self_test_log.current_self_test_completion_percent
                Write-Host "  🔸 NVMe Self-Test: " -NoNewline -ForegroundColor $White
                Write-Host "$($currentTest.string) ($completion%)" -ForegroundColor $Yellow
            }

            $latestTest = $smart.nvme_self_test_log.table | Select-Object -First 1
            if ($latestTest) {
                Write-Host "  🔸 Latest Completed Self-Test: " -NoNewline -ForegroundColor $White
                Write-Host "$($latestTest.self_test_code.string) — $($latestTest.self_test_result.string)" -ForegroundColor $(if ($latestTest.self_test_result.value -eq 0) { $Green } else { $Yellow })
            }
        }
    }
    }

    if ($menuEnabled -and $runLoop) {
        Write-Host "  Press any key to return to the selection menu..." -ForegroundColor $Yellow
        [Console]::ReadKey($true) | Out-Null
    }
}
