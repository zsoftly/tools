# Headscale VPN Setup Script - Windows
# Usage: .\install.ps1 -Server <url> [-Key <authkey>]
# Run as Administrator for best results

param(
    [Parameter(Mandatory=$true)]
    [string]$Server,
    [string]$Key = ""
)

# Configuration
$MAX_SERVICE_WAIT_ATTEMPTS = 10

$HeadscaleUrl = $Server
$ErrorActionPreference = "Stop"

function Write-Info { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Success { param($msg) Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-Err { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red; exit 1 }

# Prompt for auth key if not provided
function Get-AuthKey {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor White
    Write-Host "  PRE-AUTH KEY" -ForegroundColor White
    Write-Host "============================================================" -ForegroundColor White
    Write-Host ""
    Write-Host "You need a pre-auth key from your IT admin to connect."
    Write-Host "The key determines your access level and network permissions."
    Write-Host ""
    Write-Host "If you don't have a key, you can still connect via SSO (browser)"
    Write-Host "but you'll have no access until an admin assigns tags."
    Write-Host ""
    $key = Read-Host "Enter pre-auth key (or press Enter to use SSO)"
    Write-Host ""
    return $key
}

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
            Write-Err "Tailscale installed but not found in PATH. Please restart your terminal and run: tailscale up --login-server=$HeadscaleUrl --accept-routes"
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

# Prompt for key if not provided
if ([string]::IsNullOrEmpty($Key)) {
    $Key = Get-AuthKey
}

# Connect to Headscale
Write-Host ""
Write-Info "Connecting to VPN..."

if ([string]::IsNullOrEmpty($Key)) {
    Write-Info "A browser window will open for SSO authentication."
    Write-Warn "Note: Without a pre-auth key, an admin will need to assign tags to your device."
    Write-Host ""
    try {
        & tailscale up --login-server=$HeadscaleUrl --accept-routes --reset
    } catch {
        Write-Err "Failed to connect: $_"
    }
} else {
    Write-Info "Using pre-auth key for registration..."
    try {
        & tailscale up --login-server=$HeadscaleUrl --authkey=$Key --accept-routes --reset
    } catch {
        Write-Err "Failed to connect: $_"
    }
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

if ([string]::IsNullOrEmpty($Key)) {
    Write-Warn "Reminder: Ask your admin to assign appropriate tags to your device."
}
