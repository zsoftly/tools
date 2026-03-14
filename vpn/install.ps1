# Headscale VPN Setup Script - Windows
# Usage: .\install.ps1 [[-User] john.d] [-Key AUTH_KEY]
# Run as Administrator for best results
#
# Required environment variable:
#   HEADSCALE_URL  - URL of your Headscale server
#   Set it with: $env:HEADSCALE_URL = "https://your-headscale-server"

param(
    [Parameter(Position=0)]
    [string]$User = "",
    [string]$Key = ""
)

# Configuration
$MAX_SERVICE_WAIT_ATTEMPTS = 10
$ErrorActionPreference = "Stop"

$HeadscaleUrl = $env:HEADSCALE_URL
if ([string]::IsNullOrEmpty($HeadscaleUrl)) {
    Write-Host "[ERROR] HEADSCALE_URL environment variable is required." -ForegroundColor Red
    Write-Host "  Set it with: `$env:HEADSCALE_URL = 'https://your-headscale-server'" -ForegroundColor Red
    exit 1
}

function Write-Info { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Success { param($msg) Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-Err { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red; exit 1 }

# Prompt for name if not provided
if ([string]::IsNullOrEmpty($User)) {
    Write-Host ""
    $User = Read-Host "Enter your name (e.g. john.d)"
    Write-Host ""
}

if ([string]::IsNullOrEmpty($User)) {
    Write-Err "Name is required to set the device hostname."
}

$Hostname = "$User-win"

# Check if running as admin
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Note: Running without admin privileges. Some features may require elevation." -ForegroundColor Yellow
}

# Check if Tailscale is already installed
$tailscale = Get-Command tailscale -ErrorAction SilentlyContinue

if ($tailscale) {
    Write-Success "Tailscale is already installed"
} else {
    Write-Info "Installing Tailscale VPN client..."

    # Try winget first (Windows 10 1709+ and Windows 11)
    $winget = Get-Command winget -ErrorAction SilentlyContinue

    if ($winget) {
        Write-Info "Installing via winget..."
        try {
            winget install --id Tailscale.Tailscale --silent --accept-package-agreements --accept-source-agreements
        } catch {
            Write-Info "winget install failed, falling back to direct download..."
            $winget = $null
        }
    }

    if (-not $winget) {
        # Detect architecture
        $arch = $env:PROCESSOR_ARCHITECTURE
        switch ($arch) {
            "ARM64" { $msiArch = "arm64" }
            "AMD64" { $msiArch = "amd64" }
            default { $msiArch = "amd64" }  # Fallback to x64
        }
        Write-Info "Detected architecture: $arch -> $msiArch"

        # Direct MSI download
        Write-Info "Downloading Tailscale installer..."
        $msiUrl = "https://pkgs.tailscale.com/stable/tailscale-setup-latest-$msiArch.msi"
        $msiPath = [System.IO.Path]::Combine($env:TEMP, "tailscale-setup-$([System.IO.Path]::GetRandomFileName()).msi")

        try {
            Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing
        } catch {
            Write-Err "Failed to download Tailscale installer: $_"
        }

        Write-Info "Installing Tailscale..."
        $installArgs = "/i", $msiPath, "/quiet", "/norestart"
        $process = Start-Process msiexec.exe -ArgumentList $installArgs -Wait -PassThru

        if ($process.ExitCode -ne 0) {
            Write-Err "Installation failed with exit code: $($process.ExitCode)"
        }

        Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
    }

    # Refresh PATH
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

    # Verify installation
    $tailscale = Get-Command tailscale -ErrorAction SilentlyContinue
    if (-not $tailscale) {
        # Try common install path
        $defaultPath = "C:\Program Files\Tailscale\tailscale.exe"
        if (Test-Path $defaultPath) {
            $env:Path += ";C:\Program Files\Tailscale"
        } else {
            Write-Err "Tailscale installed but not found in PATH. Please restart your terminal and run: tailscale up --login-server=$HeadscaleUrl --hostname=$Hostname --accept-routes"
        }
    }

    Write-Success "Tailscale installed"
}

# Wait for Tailscale service to start
Write-Info "Waiting for Tailscale service..."
$attempts = 0

while ($attempts -lt $MAX_SERVICE_WAIT_ATTEMPTS) {
    try {
        $status = & tailscale status 2>&1
        if ($LASTEXITCODE -eq 0 -or $status -match "Logged out") {
            break
        }
    } catch {}

    Start-Sleep -Seconds 1
    $attempts++
}

if ($attempts -ge $MAX_SERVICE_WAIT_ATTEMPTS) {
    Write-Warn "Tailscale service may not be ready. Continuing anyway..."
}

# Connect to Headscale
Write-Host ""
Write-Info "Connecting to VPN (hostname: $Hostname)..."

try {
    if (-not [string]::IsNullOrEmpty($Key)) {
        & tailscale up --login-server=$HeadscaleUrl --hostname=$Hostname --authkey=$Key --accept-routes --reset
    } else {
        & tailscale up --login-server=$HeadscaleUrl --hostname=$Hostname --accept-routes --reset
        Write-Host ""
        Write-Info "A browser window will open — log in with your company SSO credentials via Authentik."
    }
} catch {
    Write-Err "Failed to connect: $_"
}
Write-Host ""
Write-Success "VPN setup complete!"
Write-Host ""
Write-Host "Verify connection with: tailscale status"

try {
    $vpnIp = & tailscale ip -4 2>$null
    if ($vpnIp) {
        Write-Host "Your VPN IP: $vpnIp"
    }
} catch {}

Write-Host ""
