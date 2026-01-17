# Tools

One-liner automation scripts for endpoint setup.

## VPN Setup

Connect to a Headscale VPN server with a single command.

**Prerequisites:** Get a pre-auth key and server URL from your IT admin.

### macOS / Linux

```bash
curl -fsSL https://raw.githubusercontent.com/zsoftly/tools/main/vpn/install.sh | bash -s -- --server "SERVER_URL" --key "YOUR_KEY"
```

### Windows (PowerShell as Admin)

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/zsoftly/tools/main/vpn/install.ps1))) -Server "SERVER_URL" -Key "YOUR_KEY"
```

## Wazuh Agent Setup

Install the Wazuh security agent for endpoint monitoring.

**Prerequisites:** Get the manager address, agent group, and enrollment password from your IT admin.

### macOS / Linux

```bash
curl -fsSL https://raw.githubusercontent.com/zsoftly/tools/main/wazuh/install.sh | bash -s -- \
  --manager "MANAGER_ADDRESS" \
  --group "AGENT_GROUP" \
  --password "ENROLLMENT_PASSWORD"
```

| Option                     | Environment Variable         | Description                              |
| -------------------------- | ---------------------------- | ---------------------------------------- |
| `--manager`                | `WAZUH_MANAGER`              | Manager address (required)               |
| `--group`                  | `WAZUH_AGENT_GROUP`          | Agent group                              |
| `--password`               | -                            | Enrollment password (prompts if omitted) |
| `--version`                | -                            | Wazuh version (auto-detects if omitted)  |
| `--enable-remote-commands` | `WAZUH_REMOTE_COMMANDS=true` | Allow manager to run commands on agent   |

### Windows (PowerShell as Admin)

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/zsoftly/tools/main/wazuh/install.ps1))) `
  -Manager "MANAGER_ADDRESS" `
  -Group "AGENT_GROUP" `
  -Password "ENROLLMENT_PASSWORD"
```

| Option                  | Environment Variable         | Description                              |
| ----------------------- | ---------------------------- | ---------------------------------------- |
| `-Manager`              | -                            | Manager address (required)               |
| `-Group`                | -                            | Agent group                              |
| `-Password`             | -                            | Enrollment password (prompts if omitted) |
| `-Version`              | -                            | Wazuh version (auto-detects if omitted)  |
| `-EnableRemoteCommands` | `WAZUH_REMOTE_COMMANDS=true` | Allow manager to run commands on agent   |

## Available Tools

| Tool                | Description                | Platform     |
| ------------------- | -------------------------- | ------------ |
| `vpn/install.sh`    | Headscale VPN client setup | macOS, Linux |
| `vpn/install.ps1`   | Headscale VPN client setup | Windows      |
| `wazuh/install.sh`  | Wazuh security agent setup | macOS, Linux |
| `wazuh/install.ps1` | Wazuh security agent setup | Windows      |

## Security Note

Running scripts from the internet requires trust. Review scripts before executing.
