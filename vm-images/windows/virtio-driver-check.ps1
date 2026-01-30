# VirtIO Driver Verification Script for Windows VMs
#
# Copyright 2026 Schelling Point Labs Inc
# SPDX-License-Identifier: AGPL-3.0-only
#
# This script verifies that VirtIO drivers are properly loaded on a Windows VM
# running in QEMU/KVM. It checks for the essential VirtIO drivers required for
# optimal VM performance:
#
# - viostor (Red Hat VirtIO SCSI controller) - Block storage driver
# - netkvm (Red Hat VirtIO Ethernet Adapter) - Network driver
# - balloon (VirtIO Balloon Driver) - Memory ballooning
# - vioserial (VirtIO Serial Driver) - Serial port for host-guest communication
# - qxldod (Red Hat QXL controller) - Display driver
#
# Usage:
#   powershell.exe -ExecutionPolicy Bypass -File virtio-driver-check.ps1
#
# Exit codes:
#   0 - All essential drivers are loaded
#   1 - One or more essential drivers are missing
#   2 - Script execution error
#
# Output format (JSON):
#   {
#     "success": true/false,
#     "drivers": [
#       {"name": "driver_name", "device": "device_name", "version": "x.y.z", "status": "Running/Stopped"}
#     ],
#     "missing": ["driver_name", ...],
#     "summary": "human readable summary"
#   }
#
# References:
# - Fedora VirtIO drivers: https://fedorapeople.org/groups/virt/virtio-win/
# - VirtIO-Win GitHub: https://github.com/virtio-win/virtio-win-pkg-scripts
# - QEMU VirtIO documentation: https://www.qemu.org/docs/master/system/devices/virtio.html

# Strict mode for better error handling.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Essential VirtIO drivers that must be present for proper VM operation.
# These are the minimum required drivers for a functional QEMU/KVM Windows VM.
$EssentialDrivers = @(
    @{
        Name = "viostor"
        Description = "Red Hat VirtIO SCSI controller"
        DevicePatterns = @("*VirtIO*SCSI*", "*VirtIO*stor*", "*Red Hat VirtIO SCSI*")
        Required = $true
    },
    @{
        Name = "netkvm"
        Description = "Red Hat VirtIO Ethernet Adapter"
        DevicePatterns = @("*VirtIO*Ethernet*", "*VirtIO*Net*", "*Red Hat VirtIO Ethernet*")
        Required = $true
    }
)

# Optional VirtIO drivers that enhance VM functionality but are not required.
$OptionalDrivers = @(
    @{
        Name = "balloon"
        Description = "VirtIO Balloon Driver"
        DevicePatterns = @("*VirtIO*Balloon*", "*VirtIO Balloon*")
        Required = $false
    },
    @{
        Name = "vioserial"
        Description = "VirtIO Serial Driver"
        DevicePatterns = @("*VirtIO*Serial*", "*VirtIO Serial*")
        Required = $false
    },
    @{
        Name = "qxldod"
        Description = "Red Hat QXL controller"
        DevicePatterns = @("*QXL*", "*Red Hat QXL*")
        Required = $false
    },
    @{
        Name = "viorng"
        Description = "VirtIO RNG Device"
        DevicePatterns = @("*VirtIO*RNG*", "*VirtIO RNG*")
        Required = $false
    },
    @{
        Name = "vioinput"
        Description = "VirtIO Input Driver"
        DevicePatterns = @("*VirtIO*Input*", "*VirtIO Input*")
        Required = $false
    },
    @{
        Name = "viogpudo"
        Description = "VirtIO GPU DOD driver"
        DevicePatterns = @("*VirtIO*GPU*", "*VirtIO GPU*")
        Required = $false
    }
)

# All drivers to check (essential + optional).
$AllDrivers = $EssentialDrivers + $OptionalDrivers

<#
.SYNOPSIS
    Finds VirtIO drivers by checking PnP devices and signed drivers.

.DESCRIPTION
    This function queries both Get-PnPDevice and Win32_PnPSignedDriver to find
    VirtIO-related drivers. It uses multiple detection methods to ensure reliable
    driver discovery across different Windows versions.

.PARAMETER DriverSpec
    A hashtable containing driver specification with Name, DevicePatterns, and Required fields.

.OUTPUTS
    A hashtable with driver status information or $null if not found.
#>
function Find-VirtIODriver {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$DriverSpec
    )

    $result = $null

    # Method 1: Try Get-PnPDevice (more reliable on modern Windows).
    try {
        foreach ($pattern in $DriverSpec.DevicePatterns) {
            $devices = Get-PnpDevice -FriendlyName $pattern -ErrorAction SilentlyContinue
            if ($devices) {
                $device = $devices | Select-Object -First 1
                $result = @{
                    Name = $DriverSpec.Name
                    Device = $device.FriendlyName
                    Status = $device.Status
                    InstanceId = $device.InstanceId
                    Class = $device.Class
                    Version = "N/A"
                    Found = $true
                }
                break
            }
        }
    }
    catch {
        # Get-PnPDevice may not be available on older Windows versions.
        # Fall through to Win32_PnPSignedDriver method.
    }

    # Method 2: Fall back to Win32_PnPSignedDriver (works on all Windows versions).
    if (-not $result) {
        try {
            foreach ($pattern in $DriverSpec.DevicePatterns) {
                # Convert glob pattern to WQL LIKE pattern.
                $wqlPattern = $pattern.Replace("*", "%")
                $query = "SELECT * FROM Win32_PnPSignedDriver WHERE DeviceName LIKE '$wqlPattern'"
                $drivers = Get-WmiObject -Query $query -ErrorAction SilentlyContinue

                if ($drivers) {
                    $driver = $drivers | Select-Object -First 1
                    $result = @{
                        Name = $DriverSpec.Name
                        Device = $driver.DeviceName
                        Status = if ($driver.Started) { "Running" } else { "Stopped" }
                        InstanceId = $driver.DeviceID
                        Class = $driver.DeviceClass
                        Version = $driver.DriverVersion
                        Found = $true
                    }
                    break
                }
            }
        }
        catch {
            # WMI query failed, driver not found.
        }
    }

    # Method 3: Check by driver service name as last resort.
    if (-not $result) {
        try {
            $service = Get-Service -Name $DriverSpec.Name -ErrorAction SilentlyContinue
            if ($service) {
                $result = @{
                    Name = $DriverSpec.Name
                    Device = $DriverSpec.Description
                    Status = $service.Status.ToString()
                    InstanceId = "Service:" + $DriverSpec.Name
                    Class = "Driver"
                    Version = "N/A"
                    Found = $true
                }
            }
        }
        catch {
            # Service not found either.
        }
    }

    return $result
}

<#
.SYNOPSIS
    Main function to verify all VirtIO drivers.

.DESCRIPTION
    Checks for all essential and optional VirtIO drivers and returns a structured
    result indicating which drivers are present and which are missing.

.OUTPUTS
    A hashtable containing the verification results in JSON-compatible format.
#>
function Test-VirtIODrivers {
    $foundDrivers = @()
    $missingEssential = @()
    $missingOptional = @()

    # Check all drivers.
    foreach ($driverSpec in $AllDrivers) {
        $driverResult = Find-VirtIODriver -DriverSpec $driverSpec

        if ($driverResult) {
            $foundDrivers += @{
                name = $driverResult.Name
                device = $driverResult.Device
                version = $driverResult.Version
                status = $driverResult.Status
            }
        }
        else {
            if ($driverSpec.Required) {
                $missingEssential += $driverSpec.Name
            }
            else {
                $missingOptional += $driverSpec.Name
            }
        }
    }

    # Determine overall success (all essential drivers must be present).
    $success = $missingEssential.Count -eq 0

    # Build summary message.
    $summary = ""
    if ($success) {
        $summary = "All essential VirtIO drivers are loaded. "
        $summary += "Found $($foundDrivers.Count) driver(s). "
        if ($missingOptional.Count -gt 0) {
            $summary += "Optional drivers not found: $($missingOptional -join ', ')."
        }
    }
    else {
        $summary = "MISSING essential VirtIO drivers: $($missingEssential -join ', '). "
        $summary += "Found $($foundDrivers.Count) driver(s)."
    }

    return @{
        success = $success
        drivers = $foundDrivers
        missing_essential = $missingEssential
        missing_optional = $missingOptional
        summary = $summary
    }
}

# Main execution block.
try {
    $result = Test-VirtIODrivers

    # Output result as JSON for easy parsing by the Rust harness.
    $json = $result | ConvertTo-Json -Depth 3 -Compress
    Write-Output $json

    # Exit with appropriate code.
    if ($result.success) {
        exit 0
    }
    else {
        exit 1
    }
}
catch {
    # Handle unexpected errors.
    $errorResult = @{
        success = $false
        error = $_.Exception.Message
        summary = "Script execution failed: $($_.Exception.Message)"
    }
    $json = $errorResult | ConvertTo-Json -Depth 3 -Compress
    Write-Output $json
    exit 2
}
