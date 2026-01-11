# Tools

One-liner automation scripts for Headscale VPN setup.

## VPN Setup

Connect to a Headscale VPN server with a single command.

**Prerequisites:**

- Get a pre-auth key from your IT admin
- Know your Headscale server URL

### macOS / Linux

```bash
curl -fsSL https://raw.githubusercontent.com/zsoftly/tools/main/vpn/install.sh | bash -s -- --server <SERVER_URL> --key <YOUR_KEY>
```

Interactive mode (will prompt for pre-auth key):

```bash
curl -fsSL https://raw.githubusercontent.com/zsoftly/tools/main/vpn/install.sh | bash -s -- --server <SERVER_URL>
```

### Windows (PowerShell as Admin)

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/zsoftly/tools/main/vpn/install.ps1))) -Server <SERVER_URL> -Key <YOUR_KEY>
```

Interactive mode (will prompt for pre-auth key):

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/zsoftly/tools/main/vpn/install.ps1))) -Server <SERVER_URL>
```

## Available Tools

| Tool              | Description                | Platform     |
| ----------------- | -------------------------- | ------------ |
| `vpn/install.sh`  | Headscale VPN client setup | macOS, Linux |
| `vpn/install.ps1` | Headscale VPN client setup | Windows      |

## Security Note

Running scripts from the internet requires trust. Review scripts before executing.
