#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Configure a Windows CI runner for benchmark isolation.

.DESCRIPTION
    Sets up power management, CPU affinity, and other isolation settings
    to ensure stable and reproducible benchmark results. Can be run
    independently of the GitHub runner provisioning.

    - Sets High Performance power plan
    - Disables sleep, hibernate, and monitor timeout
    - Configures Windows Update active hours
    - Sets CPU affinity for the runner service (if 16+ cores available)
    - Disables background maintenance tasks that could skew benchmarks

.PARAMETER RunnerServicePattern
    Pattern to match the runner service name.
    Defaults to "actions.runner*".

.PARAMETER AffinityStartCore
    First core to assign to the runner. Defaults to 8.

.PARAMETER AffinityCoreCount
    Number of cores to assign. Defaults to 8.

.EXAMPLE
    .\configure-benchmark-isolation.ps1
    .\configure-benchmark-isolation.ps1 -AffinityStartCore 4 -AffinityCoreCount 12
#>

param(
    [string]$RunnerServicePattern = "actions.runner*",
    [int]$AffinityStartCore = 8,
    [int]$AffinityCoreCount = 8
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] $Message"
    Write-Host $line
    Add-Content -Path "C:\benchmark-isolation-log.txt" -Value $line
}

# -- Power plan: High Performance ---------------------------------------------
Write-Log "Setting power plan to High Performance..."
powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c

# Disable sleep and hibernate
powercfg /change standby-timeout-ac 0
powercfg /change standby-timeout-dc 0
powercfg /change monitor-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /hibernate off

Write-Log "Power plan configured. Sleep and hibernate disabled."

# -- Disable Windows Update during benchmark hours ----------------------------
Write-Log "Configuring Windows Update active hours..."
$updatePath = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"
if (-not (Test-Path $updatePath)) {
    New-Item -Path $updatePath -Force | Out-Null
}
# Set active hours 06:00 - 02:00 (20h window, effectively most of the day)
Set-ItemProperty -Path $updatePath -Name "ActiveHoursStart" -Value 6 -Type DWord
Set-ItemProperty -Path $updatePath -Name "ActiveHoursEnd" -Value 2 -Type DWord
Set-ItemProperty -Path $updatePath -Name "IsActiveHoursEnabled" -Value 1 -Type DWord

Write-Log "Windows Update active hours set."

# -- Disable Scheduled Maintenance --------------------------------------------
Write-Log "Disabling automatic maintenance..."
$maintPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance"
if (-not (Test-Path $maintPath)) {
    New-Item -Path $maintPath -Force | Out-Null
}
Set-ItemProperty -Path $maintPath -Name "MaintenanceDisabled" -Value 1 -Type DWord

# Disable Superfetch/SysMain (can cause I/O spikes)
$sysmain = Get-Service -Name SysMain -ErrorAction SilentlyContinue
if ($sysmain -and $sysmain.Status -eq "Running") {
    Stop-Service SysMain -Force
    Set-Service SysMain -StartupType Disabled
    Write-Log "SysMain (Superfetch) disabled."
}

# Disable Windows Search indexer (can cause CPU/I/O spikes)
$wsearch = Get-Service -Name WSearch -ErrorAction SilentlyContinue
if ($wsearch -and $wsearch.Status -eq "Running") {
    Stop-Service WSearch -Force
    Set-Service WSearch -StartupType Disabled
    Write-Log "Windows Search indexer disabled."
}

Write-Log "Background maintenance tasks disabled."

# -- Set CPU Affinity for runner service --------------------------------------
Write-Log "Configuring CPU affinity for runner service..."

$cpuCount = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
Write-Log "Detected $cpuCount logical processors."

$requiredCores = $AffinityStartCore + $AffinityCoreCount
if ($cpuCount -ge $requiredCores) {
    # Build affinity bitmask for the specified core range
    $affinityMask = 0
    for ($i = $AffinityStartCore; $i -lt ($AffinityStartCore + $AffinityCoreCount); $i++) {
        $affinityMask = $affinityMask -bor (1 -shl $i)
    }
    Write-Log "Setting runner affinity to cores ${AffinityStartCore}-$($AffinityStartCore + $AffinityCoreCount - 1) (mask: 0x$($affinityMask.ToString('X')))."

    # Create a scheduled task that sets affinity on runner service process at startup
    $affinityScript = @"
`$svc = Get-CimInstance Win32_Service -Filter "Name LIKE '$RunnerServicePattern'"
if (`$svc) {
    `$proc = Get-Process -Id `$svc.ProcessId -ErrorAction SilentlyContinue
    if (`$proc) {
        `$proc.ProcessorAffinity = [IntPtr]$affinityMask
    }
}
"@
    $affinityScriptPath = "C:\set-runner-affinity.ps1"
    Set-Content -Path $affinityScriptPath -Value $affinityScript

    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File $affinityScriptPath"
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = "PT60S"  # 60 second delay to let runner start
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
    Register-ScheduledTask -TaskName "SetRunnerCPUAffinity" `
        -Action $action -Trigger $trigger -Principal $principal -Force

    Write-Log "CPU affinity scheduled task created."
} else {
    Write-Log "Fewer than $requiredCores cores detected ($cpuCount available); skipping CPU affinity configuration."
}

# -- Final marker -------------------------------------------------------------
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss UTC"
Set-Content -Path "C:\ci-benchmark-isolation-complete.txt" -Value "Benchmark isolation configured at $timestamp"
Write-Log "Benchmark isolation configuration complete."
