#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Provision a Windows machine as a GitHub Actions runner.

.DESCRIPTION
    Called via WinRM or SSH after bootstrap.ps1 has completed.
    - Installs Git (via winget)
    - Downloads and configures the GitHub Actions runner
    - Registers the runner as a Windows service

    This script is organization-agnostic. Pass the GitHub org/repo URL
    and runner token as parameters.

.PARAMETER RunnerToken
    GitHub Actions runner registration token. Can also be set via
    the RUNNER_TOKEN environment variable.

.PARAMETER RunnerName
    Name for this runner. Defaults to the computer name.

.PARAMETER GithubUrl
    Full GitHub URL for the runner scope.
    For org-level:  https://github.com/my-org
    For repo-level: https://github.com/my-org/my-repo

.PARAMETER RunnerLabels
    Comma-separated runner labels.
    Defaults to "self-hosted,windows,bare-metal".

.PARAMETER RunnerVersion
    GitHub Actions runner version to install. Defaults to "2.322.0".

.PARAMETER RunnerDir
    Directory to install the runner. Defaults to "C:\actions-runner".

.EXAMPLE
    .\provision-github-runner.ps1 -RunnerToken "AABCDEF..." -GithubUrl "https://github.com/my-org"
    .\provision-github-runner.ps1 -RunnerToken "AABCDEF..." -GithubUrl "https://github.com/my-org/my-repo" -RunnerLabels "self-hosted,windows,benchmark"
#>

param(
    [string]$RunnerToken = $env:RUNNER_TOKEN,
    [string]$RunnerName = $env:COMPUTERNAME,
    [string]$GithubUrl = "",
    [string]$RunnerLabels = "self-hosted,windows,bare-metal",
    [string]$RunnerVersion = "2.322.0",
    [string]$RunnerDir = "C:\actions-runner"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] $Message"
    Write-Host $line
    Add-Content -Path "C:\provision-runner-log.txt" -Value $line
}

# -- Validate prerequisites ---------------------------------------------------
if (-not (Test-Path "C:\ci-bootstrap-complete.txt")) {
    Write-Error "Bootstrap has not completed. Run bootstrap.ps1 first."
    exit 1
}

if ([string]::IsNullOrEmpty($RunnerToken)) {
    Write-Error "Runner token is required. Pass -RunnerToken or set RUNNER_TOKEN env var."
    exit 1
}

if ([string]::IsNullOrEmpty($GithubUrl)) {
    Write-Error "GithubUrl is required. Example: https://github.com/my-org"
    exit 1
}

# -- Install Git --------------------------------------------------------------
Write-Log "Installing Git..."
$gitCmd = Get-Command git -ErrorAction SilentlyContinue
if (-not $gitCmd) {
    winget install --id Git.Git --exact --accept-source-agreements --accept-package-agreements --silent
    # Refresh PATH
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path", "User")
    Write-Log "Git installed."
} else {
    Write-Log "Git already installed."
}

# -- Install GitHub Actions Runner --------------------------------------------
$runnerArch = "win-x64"
$runnerZip = "actions-runner-${runnerArch}-${RunnerVersion}.zip"
$runnerUrl = "https://github.com/actions/runner/releases/download/v${RunnerVersion}/${runnerZip}"

Write-Log "Installing GitHub Actions runner v${RunnerVersion}..."

if (-not (Test-Path $RunnerDir)) {
    New-Item -ItemType Directory -Path $RunnerDir -Force | Out-Null
}

# Download runner if not already present
$zipPath = Join-Path $RunnerDir $runnerZip
if (-not (Test-Path $zipPath)) {
    Write-Log "Downloading runner from $runnerUrl..."
    Invoke-WebRequest -Uri $runnerUrl -OutFile $zipPath -UseBasicParsing
    Write-Log "Runner downloaded."
}

# Extract
Write-Log "Extracting runner..."
Expand-Archive -Path $zipPath -DestinationPath $RunnerDir -Force

# Configure runner
Write-Log "Configuring runner..."
$configArgs = @(
    "--url", $GithubUrl,
    "--token", $RunnerToken,
    "--unattended",
    "--replace",
    "--name", $RunnerName,
    "--labels", $RunnerLabels,
    "--runasservice"
)

Push-Location $RunnerDir
& .\config.cmd @configArgs
Pop-Location

Write-Log "GitHub Actions runner configured and registered."

# -- Final marker -------------------------------------------------------------
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss UTC"
Set-Content -Path "C:\ci-runner-provision-complete.txt" -Value "Runner provisioning completed at $timestamp"
Write-Log "Runner provisioning complete."
