#Requires -Version 7

<#
  01-probe.ps1 - Read-only environment probe for an AGV onboard HMI machine.

  Purpose: collect everything needed to design the remote-ops channel.
  Safety:  READ ONLY. Installs nothing, changes no setting, opens no port.
           Does NOT read any stored password value.

  Usage (on the HMI machine, in PowerShell 7 as Administrator):
      pwsh -ExecutionPolicy Bypass -File .\01-probe.ps1

  Output: probe-<hostname>-<timestamp>.txt written next to this script.
#>

param(
    # IPv4 of the control workstation, used for reachability tests.
    [string]$ControlHost = '172.19.162.241'
)

$ErrorActionPreference = 'Continue'
$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $outDir) { $outDir = (Get-Location).Path }
$script:Out = Join-Path $outDir "probe-$env:COMPUTERNAME-$stamp.txt"

function Section($title) {
    "`n=================== $title ===================" |
        Tee-Object -FilePath $script:Out -Append | Out-Host
}
function Emit($label, $value) {
    "{0,-32}: {1}" -f $label, $value |
        Tee-Object -FilePath $script:Out -Append | Out-Host
}
function Raw($text) {
    ($text | Out-String).TrimEnd() |
        Tee-Object -FilePath $script:Out -Append | Out-Host
}
function Safe($block, $fallback = '(unavailable)') {
    try { & $block } catch { $fallback }
}

"AGV HMI remote-ops probe"           | Set-Content -Path $script:Out
"generated: $(Get-Date -Format 'u')" | Add-Content -Path $script:Out

# ------------------------------------------------------------------ identity
Section 'IDENTITY'
Emit 'Hostname'        $env:COMPUTERNAME
Emit 'Current user'    "$env:USERDOMAIN\$env:USERNAME"
$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
Emit 'Running elevated' $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
Emit 'Domain joined'    (Safe { (Get-CimInstance Win32_ComputerSystem).PartOfDomain })
Emit 'Domain/workgroup' (Safe { (Get-CimInstance Win32_ComputerSystem).Domain })

Section 'LOCAL ADMINISTRATORS GROUP'
Raw (Safe { Get-LocalGroupMember -Group 'Administrators' |
            Select-Object Name, PrincipalSource | Format-Table -AutoSize })

Section 'LOCAL USER ACCOUNTS'
Raw (Safe { Get-LocalUser |
            Select-Object Name, Enabled, PasswordRequired, LastLogon |
            Format-Table -AutoSize })

# Autologon: report WHETHER it is configured and for WHOM, never the password.
Section 'AUTOLOGON CONFIG (password value intentionally not read)'
$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Emit 'AutoAdminLogon'    (Safe { (Get-ItemProperty $winlogon -Name AutoAdminLogon    -ErrorAction Stop).AutoAdminLogon }    '(not set)')
Emit 'DefaultUserName'   (Safe { (Get-ItemProperty $winlogon -Name DefaultUserName   -ErrorAction Stop).DefaultUserName }   '(not set)')
Emit 'DefaultDomainName' (Safe { (Get-ItemProperty $winlogon -Name DefaultDomainName -ErrorAction Stop).DefaultDomainName } '(not set)')
Emit 'DefaultPassword present' (Safe {
    if ((Get-ItemProperty $winlogon -Name DefaultPassword -ErrorAction Stop).DefaultPassword) {
        'YES - stored in cleartext registry (value not read by this probe)'
    } else { 'no' } } 'no')
Emit 'Winlogon Shell'    (Safe { (Get-ItemProperty $winlogon -Name Shell -ErrorAction Stop).Shell } '(default explorer.exe)')

# ----------------------------------------------------------------------- os
Section 'OPERATING SYSTEM'
Emit 'Caption'      (Safe { (Get-CimInstance Win32_OperatingSystem).Caption })
Emit 'Version'      (Safe { (Get-CimInstance Win32_OperatingSystem).Version })
Emit 'DisplayVersion' (Safe { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').DisplayVersion })
Emit 'Install date' (Safe { (Get-CimInstance Win32_OperatingSystem).InstallDate })
Emit 'Last boot'    (Safe { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime })
Emit 'Architecture' $env:PROCESSOR_ARCHITECTURE
Emit 'Manufacturer' (Safe { (Get-CimInstance Win32_ComputerSystem).Manufacturer })
Emit 'Model'        (Safe { (Get-CimInstance Win32_ComputerSystem).Model })
Emit 'BIOS serial'  (Safe { (Get-CimInstance Win32_BIOS).SerialNumber })
Emit 'RAM (GB)'     (Safe { [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1) })

Section 'DISK SPACE'
Raw (Safe { Get-PSDrive -PSProvider FileSystem |
            Select-Object Name,
                @{n='UsedGB'; e={[math]::Round($_.Used/1GB,1)}},
                @{n='FreeGB'; e={[math]::Round($_.Free/1GB,1)}} |
            Format-Table -AutoSize })

# --------------------------------------------------------------- powershell
Section 'POWERSHELL'
Emit 'Session version'     $PSVersionTable.PSVersion
Emit 'Session edition'     $PSVersionTable.PSEdition
Emit 'pwsh 7 path'         (Safe { (Get-Command pwsh -ErrorAction Stop).Source } '(pwsh not on PATH)')
Emit 'pwsh 7 version'      (Safe { & pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' } '(unavailable)')
Emit 'ExecutionPolicy LM'  (Safe { Get-ExecutionPolicy -Scope LocalMachine })
Emit 'ExecutionPolicy CU'  (Safe { Get-ExecutionPolicy -Scope CurrentUser })

# ---------------------------------------------------------------------- ssh
Section 'OPENSSH STATE'
Raw (Safe { Get-WindowsCapability -Online -Name 'OpenSSH*' |
            Select-Object Name, State | Format-Table -AutoSize } '(needs elevation)')
Emit 'ssh.exe'           (Safe { (Get-Command ssh  -ErrorAction Stop).Source } '(absent)')
Emit 'sshd.exe'          (Safe { (Get-Command sshd -ErrorAction Stop).Source } '(absent)')
Emit 'sshd service'      (Safe { (Get-Service sshd      -ErrorAction Stop).Status } '(not installed)')
Emit 'ssh-agent service' (Safe { (Get-Service ssh-agent -ErrorAction Stop).Status } '(not installed)')

Section 'OTHER REMOTE CHANNELS ALREADY PRESENT'
Emit 'WinRM status'      (Safe { (Get-Service WinRM -ErrorAction Stop).Status }    '(absent)')
Emit 'WinRM startup'     (Safe { (Get-Service WinRM -ErrorAction Stop).StartType } '(absent)')
Emit 'RDP enabled'       (Safe {
    if ((Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server').fDenyTSConnections -eq 0)
    { 'yes' } else { 'no' } })
Emit 'Remote-access apps' (Safe {
    $found = Get-Process |
        Where-Object { $_.ProcessName -match 'vnc|sunlogin|todesk|anydesk|teamviewer|rustdesk' } |
        Select-Object -ExpandProperty ProcessName -Unique
    if ($found) { $found -join ', ' } else { '(none running)' } } '(none)')

# --------------------------------------------------------------- networking
Section 'IP CONFIGURATION'
Raw (Safe {
    Get-NetIPConfiguration | ForEach-Object {
        [pscustomobject]@{
            Interface = $_.InterfaceAlias
            IPv4      = ($_.IPv4Address.IPAddress -join ', ')
            Gateway   = ($_.IPv4DefaultGateway.NextHop -join ', ')
            DNS       = (($_.DNSServer | Where-Object AddressFamily -eq 2).ServerAddresses -join ', ')
            Adapter   = $_.InterfaceDescription
        }
    } | Format-Table -AutoSize -Wrap })

Section 'IPV4 ADDRESSES'
Raw (Safe { Get-NetIPAddress -AddressFamily IPv4 |
            Select-Object InterfaceAlias, IPAddress, PrefixLength, PrefixOrigin |
            Format-Table -AutoSize })

Section 'DEFAULT ROUTES'
Raw (Safe { Get-NetRoute -DestinationPrefix '0.0.0.0/0' |
            Select-Object InterfaceAlias, NextHop, RouteMetric |
            Format-Table -AutoSize })

Section 'FIREWALL PROFILES'
Raw (Safe { Get-NetFirewallProfile |
            Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction |
            Format-Table -AutoSize })

Section "REACHABILITY TO CONTROL HOST ($ControlHost)"
Emit 'ICMP ping' (Safe {
    if (Test-Connection -ComputerName $ControlHost -Count 2 -Quiet -ErrorAction Stop)
    { 'reachable' } else { 'no reply (ICMP may simply be blocked)' } })
foreach ($port in 22, 445, 3389, 5985, 8000) {
    Emit ('TCP {0} port {1}' -f $ControlHost, $port) (Safe {
        (Test-NetConnection -ComputerName $ControlHost -Port $port -WarningAction SilentlyContinue).TcpTestSucceeded } 'error')
}
Emit 'Internet 1.1.1.1:443' (Safe {
    (Test-NetConnection -ComputerName '1.1.1.1' -Port 443 -WarningAction SilentlyContinue).TcpTestSucceeded } 'error')
Emit 'DNS resolve github.com' (Safe {
    (Resolve-DnsName github.com -ErrorAction Stop | Select-Object -First 1).IPAddress } 'FAILED')

Section 'TRACEROUTE TO CONTROL HOST (hop count = gateways in between)'
Raw (Safe { tracert -d -h 8 -w 800 $ControlHost } '(tracert failed)')

Section 'LISTENING TCP PORTS'
Raw (Safe { Get-NetTCPConnection -State Listen |
            Select-Object LocalAddress, LocalPort,
                @{n='Process'; e={(Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName}} |
            Sort-Object LocalPort | Format-Table -AutoSize })

# ------------------------------------------------------------------- the app
Section 'RUNNING PROCESSES (non-system, top 30 by working set)'
Raw (Safe { Get-Process |
            Where-Object { $_.Path -and $_.Path -notlike "$env:SystemRoot*" } |
            Sort-Object WS -Descending | Select-Object -First 30 ProcessName, Id,
                @{n='RAM_MB'; e={[math]::Round($_.WS/1MB,1)}}, Path |
            Format-Table -AutoSize -Wrap })

Section 'NON-MICROSOFT SERVICES'
Raw (Safe { Get-CimInstance Win32_Service |
            Where-Object { $_.PathName -and $_.PathName -notlike '*\Windows\*' } |
            Select-Object Name, State, StartMode, PathName |
            Format-Table -AutoSize -Wrap })

Section 'STARTUP ITEMS'
foreach ($key in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
                 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run') {
    "--- $key" | Tee-Object -FilePath $script:Out -Append | Out-Host
    Raw (Safe { Get-ItemProperty $key -ErrorAction Stop | Format-List } '(none)')
}
Raw (Safe { Get-ChildItem `
                "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp", `
                "$env:AppData\Microsoft\Windows\Start Menu\Programs\StartUp" `
                -ErrorAction SilentlyContinue |
            Select-Object FullName | Format-Table -AutoSize -Wrap } '(none)')

Section 'SCHEDULED TASKS (non-Microsoft)'
Raw (Safe { Get-ScheduledTask |
            Where-Object { $_.TaskPath -notlike '\Microsoft\*' } |
            Select-Object TaskPath, TaskName, State |
            Format-Table -AutoSize -Wrap })

Section 'DOTNET RUNTIMES'
Raw (Safe { & dotnet --list-runtimes } '(dotnet CLI absent)')

Section 'LIKELY APP INSTALL LOCATIONS'
foreach ($dir in 'C:\', 'C:\Program Files', 'C:\Program Files (x86)',
                 "$env:USERPROFILE\Desktop") {
    "--- $dir" | Tee-Object -FilePath $script:Out -Append | Out-Host
    Raw (Safe { Get-ChildItem $dir -Directory -ErrorAction SilentlyContinue |
                Select-Object -First 40 -ExpandProperty Name } '(unreadable)')
}

"`n`nPROBE COMPLETE -> $script:Out" |
    Tee-Object -FilePath $script:Out -Append | Out-Host
