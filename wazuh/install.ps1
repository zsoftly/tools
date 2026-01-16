# Wazuh Agent Setup Script - Windows
# Usage: .\install.ps1 -Manager <address> [-Group <group>] [-Password <authd_password>]
# Run as Administrator

param(
    [Parameter(Mandatory=$true)]
    [string]$Manager,
    [string]$Group = "",
    [string]$Password = "",
    [string]$Version = ""  # Auto-detect latest if not specified
)

# Configuration
$WazuhManager = $Manager
$AgentGroup = $Group
$WazuhPort = "1514"
$WazuhEnrollmentPort = "1515"
$ErrorActionPreference = "Stop"

function Write-Info { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Success { param($msg) Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-Err { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red; exit 1 }

# Get latest Wazuh version from GitHub releases
function Get-LatestWazuhVersion {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/wazuh/wazuh/releases/latest" -UseBasicParsing
        $version = $release.tag_name -replace '^v', ''
        return $version
    } catch {
        return $null
    }
}

# Prompt for password if not provided
function Get-AuthPassword {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor White
    Write-Host "  WAZUH ENROLLMENT PASSWORD" -ForegroundColor White
    Write-Host "============================================================" -ForegroundColor White
    Write-Host ""
    Write-Host "You need the enrollment password from your IT admin."
    Write-Host "This is used to register your device with the Wazuh manager."
    Write-Host ""
    $password = Read-Host "Enter enrollment password"
    Write-Host ""
    return $password
}

# Check if running as admin
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Err "This script must be run as Administrator. Right-click PowerShell and select 'Run as Administrator'."
}

# Auto-detect latest version if not specified
if ([string]::IsNullOrEmpty($Version)) {
    Write-Info "Detecting latest Wazuh version..."
    $Version = Get-LatestWazuhVersion
    if ([string]::IsNullOrEmpty($Version)) {
        Write-Err "Failed to detect latest version. Specify with -Version parameter."
    }
    Write-Success "Using Wazuh v${Version}"
}

Write-Info "Wazuh Manager: $WazuhManager"
if (-not [string]::IsNullOrEmpty($AgentGroup)) {
    Write-Info "Agent Group: $AgentGroup"
}

# Check if Wazuh is already installed
$wazuhPath = "C:\Program Files (x86)\ossec-agent"
$installed = Test-Path "$wazuhPath\wazuh-agent.exe"

if ($installed) {
    Write-Success "Wazuh agent is already installed"
} else {
    Write-Info "Installing Wazuh agent v${Version}..."

    # Detect architecture
    $arch = $env:PROCESSOR_ARCHITECTURE
    switch ($arch) {
        "AMD64" { $msiArch = "x64" }
        "x86" { $msiArch = "x86" }
        default { $msiArch = "x64" }
    }
    Write-Info "Detected architecture: $arch -> $msiArch"

    # Download MSI
    $msiUrl = "https://packages.wazuh.com/4.x/windows/wazuh-agent-${Version}-1.msi"
    $msiPath = [System.IO.Path]::Combine($env:TEMP, "wazuh-agent-$([System.IO.Path]::GetRandomFileName()).msi")

    Write-Info "Downloading Wazuh agent..."
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing
    } catch {
        Write-Err "Failed to download Wazuh agent: $_"
    }

    # Install with manager address
    Write-Info "Installing Wazuh agent..."
    $installArgs = @(
        "/i", $msiPath,
        "/quiet",
        "/norestart",
        "WAZUH_MANAGER=$WazuhManager",
        "WAZUH_REGISTRATION_SERVER=$WazuhManager"
    )
    $process = Start-Process msiexec.exe -ArgumentList $installArgs -Wait -PassThru

    if ($process.ExitCode -ne 0) {
        Write-Err "Installation failed with exit code: $($process.ExitCode)"
    }

    Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
    Write-Success "Wazuh agent installed"
}

# Fix local_internal_options.conf if it has invalid XML content
$localInternalOptions = "$wazuhPath\local_internal_options.conf"
if (Test-Path $localInternalOptions) {
    $content = Get-Content $localInternalOptions -Raw -ErrorAction SilentlyContinue
    if ($content -match '<ossec_config>|</ossec_config>') {
        Write-Warn "Fixing invalid local_internal_options.conf (contains XML)"
        Set-Content $localInternalOptions "# Wazuh local internal options`n# Format: key=value`n"
    }
}

# Check if already enrolled
$clientKeysPath = "$wazuhPath\client.keys"
$enrolled = (Test-Path $clientKeysPath) -and ((Get-Item $clientKeysPath).Length -gt 0)

if ($enrolled) {
    Write-Success "Agent is already enrolled"
} else {
    # Prompt for password if not provided
    if ([string]::IsNullOrEmpty($Password)) {
        $Password = Get-AuthPassword
    }

    if ([string]::IsNullOrEmpty($Password)) {
        Write-Warn "No password provided. Agent will not be enrolled automatically."
        Write-Warn "Enroll manually using Wazuh Agent Manager GUI or command line."
    } else {
        Write-Info "Enrolling agent with manager..."
        $agentAuth = "$wazuhPath\agent-auth.exe"

        if (Test-Path $agentAuth) {
            try {
                $enrollArgs = @("-m", $WazuhManager, "-p", $WazuhEnrollmentPort)
                if (-not [string]::IsNullOrEmpty($AgentGroup)) {
                    $enrollArgs += @("-G", $AgentGroup)
                }
                $enrollArgs += @("-P", $Password)
                $result = & $agentAuth @enrollArgs 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Success "Agent enrolled"
                } else {
                    Write-Warn "Enrollment may have failed. Check logs."
                }
            } catch {
                Write-Warn "Enrollment error: $_"
            }
        } else {
            Write-Warn "agent-auth.exe not found. Enroll manually."
        }
    }
}

# Start service
Write-Info "Starting Wazuh agent service..."
try {
    $service = Get-Service -Name "WazuhSvc" -ErrorAction SilentlyContinue
    if ($service) {
        if ($service.Status -ne "Running") {
            Start-Service -Name "WazuhSvc"
        }
        Set-Service -Name "WazuhSvc" -StartupType Automatic
        Write-Success "Wazuh service started"
    } else {
        Write-Warn "Wazuh service not found. Start manually from Wazuh Agent Manager."
    }
} catch {
    Write-Warn "Failed to start service: $_"
}

# Verify agent status
Write-Info "Verifying agent status..."
Start-Sleep -Seconds 3

$service = Get-Service -Name "WazuhSvc" -ErrorAction SilentlyContinue
if ($service -and $service.Status -eq "Running") {
    Write-Success "Wazuh agent is running"
    # Check connection in logs (informational only)
    $logPath = "$wazuhPath\ossec.log"
    if (Test-Path $logPath) {
        $logContent = Get-Content $logPath -Tail 50 -ErrorAction SilentlyContinue
        if ($logContent -match "Connected to the server") {
            Write-Success "Connected to Wazuh manager!"
        } else {
            Write-Info "Agent running. Connection to manager may take a few seconds..."
        }
    }
} else {
    Write-Warn "Agent may not be running. Check: Get-Service WazuhSvc"
}

Write-Host ""
Write-Success "Wazuh agent setup complete!"
Write-Host ""
Write-Host "Useful commands:"
Write-Host "  Status:  Get-Service WazuhSvc"
Write-Host "  Logs:    Get-Content '$logPath' -Tail 50"
Write-Host "  Restart: Restart-Service WazuhSvc"
Write-Host ""
Write-Host "Or use the Wazuh Agent Manager GUI from Start Menu."
Write-Host ""
