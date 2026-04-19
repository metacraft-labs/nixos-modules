#Requires -RunAsAdministrator
<#
.SYNOPSIS
    First-run bootstrap script for Windows CI runners.
    Called by Autounattend.xml FirstLogonCommands.

.DESCRIPTION
    - Enables WinRM (HTTPS with self-signed cert)
    - Enables and starts OpenSSH Server
    - Opens firewall for WinRM (5985/5986) and SSH (22)
    - Installs winget if not present
    - Sets execution policy to RemoteSigned
    - Creates a marker file when done

.NOTES
    This script is generic and organization-agnostic.
    It prepares the machine for remote provisioning via WinRM or SSH.
#>

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$MarkerFile = "C:\ci-bootstrap-complete.txt"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] $Message"
    Write-Host $line
    Add-Content -Path "C:\bootstrap-log-detailed.txt" -Value $line
}

# -- Execution Policy --------------------------------------------------------
Write-Log "Setting execution policy to RemoteSigned..."
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force

# -- WinRM --------------------------------------------------------------------
Write-Log "Configuring WinRM..."

# Enable WinRM service
Enable-PSRemoting -Force -SkipNetworkProfileCheck

# Create a self-signed certificate for HTTPS
$hostname = $env:COMPUTERNAME
$cert = New-SelfSignedCertificate `
    -DnsName $hostname, "localhost" `
    -CertStoreLocation "Cert:\LocalMachine\My" `
    -NotAfter (Get-Date).AddYears(10) `
    -FriendlyName "WinRM HTTPS Certificate"

Write-Log "Created self-signed certificate: $($cert.Thumbprint)"

# Remove existing HTTPS listener if any, then create one
$existingHttps = Get-WSManInstance -ResourceURI winrm/config/Listener -Enumerate 2>$null |
    Where-Object { $_.Transport -eq "HTTPS" }
if ($existingHttps) {
    Remove-WSManInstance -ResourceURI winrm/config/Listener `
        -SelectorSet @{Address="*"; Transport="HTTPS"} 2>$null
}

New-WSManInstance -ResourceURI winrm/config/Listener `
    -SelectorSet @{Address="*"; Transport="HTTPS"} `
    -ValueSet @{CertificateThumbprint=$cert.Thumbprint; Port="5986"}

# Configure WinRM settings
Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $false
Set-Item WSMan:\localhost\Service\Auth\Basic -Value $true
Set-Item WSMan:\localhost\Service\Auth\CredSSP -Value $false
Set-Item WSMan:\localhost\MaxEnvelopeSizekb -Value 8192

# Ensure WinRM service starts automatically
Set-Service -Name WinRM -StartupType Automatic
Restart-Service WinRM

Write-Log "WinRM configured with HTTPS listener on port 5986."

# -- Firewall Rules -----------------------------------------------------------
Write-Log "Configuring firewall rules..."

# WinRM HTTP (5985) -- kept for internal/trusted networks
New-NetFirewallRule -Name "WinRM-HTTP-In" `
    -DisplayName "WinRM HTTP (5985)" `
    -Direction Inbound -Protocol TCP -LocalPort 5985 `
    -Action Allow -Profile Any -ErrorAction SilentlyContinue

# WinRM HTTPS (5986)
New-NetFirewallRule -Name "WinRM-HTTPS-In" `
    -DisplayName "WinRM HTTPS (5986)" `
    -Direction Inbound -Protocol TCP -LocalPort 5986 `
    -Action Allow -Profile Any -ErrorAction SilentlyContinue

# SSH (22)
New-NetFirewallRule -Name "SSH-In" `
    -DisplayName "SSH (22)" `
    -Direction Inbound -Protocol TCP -LocalPort 22 `
    -Action Allow -Profile Any -ErrorAction SilentlyContinue

Write-Log "Firewall rules configured."

# -- OpenSSH Server -----------------------------------------------------------
Write-Log "Installing and configuring OpenSSH Server..."

# Install OpenSSH Server capability
$sshCapability = Get-WindowsCapability -Online | Where-Object { $_.Name -like "OpenSSH.Server*" }
if ($sshCapability.State -ne "Installed") {
    Add-WindowsCapability -Online -Name $sshCapability.Name
    Write-Log "OpenSSH Server capability installed."
} else {
    Write-Log "OpenSSH Server already installed."
}

# Configure and start sshd
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd

# Set default shell to PowerShell for SSH sessions
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" `
    -Name DefaultShell `
    -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -PropertyType String -Force

Write-Log "OpenSSH Server started with PowerShell as default shell."

# -- Winget -------------------------------------------------------------------
Write-Log "Checking for winget..."

$wingetPath = Get-Command winget -ErrorAction SilentlyContinue
if (-not $wingetPath) {
    Write-Log "winget not found, installing via Add-AppxPackage..."

    # Download the latest winget msixbundle and its dependencies
    $wingetUrl = "https://aka.ms/getwinget"
    $vcLibsUrl = "https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx"

    $downloadDir = "$env:TEMP\winget-install"
    New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null

    try {
        # Install VCLibs dependency
        $vcLibsPath = Join-Path $downloadDir "Microsoft.VCLibs.x64.appx"
        Invoke-WebRequest -Uri $vcLibsUrl -OutFile $vcLibsPath -UseBasicParsing
        Add-AppxPackage -Path $vcLibsPath -ErrorAction SilentlyContinue

        # Install winget
        $wingetMsix = Join-Path $downloadDir "Microsoft.DesktopAppInstaller.msixbundle"
        Invoke-WebRequest -Uri $wingetUrl -OutFile $wingetMsix -UseBasicParsing
        Add-AppxPackage -Path $wingetMsix

        Write-Log "winget installed successfully."
    } catch {
        Write-Log "WARNING: Failed to install winget: $_"
        Write-Log "winget can be installed manually later via the Microsoft Store."
    } finally {
        Remove-Item -Recurse -Force $downloadDir -ErrorAction SilentlyContinue
    }
} else {
    Write-Log "winget already available at $($wingetPath.Source)."
}

# -- Marker File --------------------------------------------------------------
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss UTC"
Set-Content -Path $MarkerFile -Value "Bootstrap completed at $timestamp"
Write-Log "Bootstrap complete. Marker written to $MarkerFile."
