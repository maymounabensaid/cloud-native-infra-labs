
# Connecting to your EC2 instance with an SSH config file

Instead of typing the full `ssh -i ... ubuntu@ec2-...` command every time, declare your EC2 instance once in an SSH configuration file. This also fixes the error:

```
Received disconnect from ... : Too many authentication failures
```

This error happens when your SSH client offers several keys (from `~/.ssh` or from the SSH agent) before the right one: the server closes the connection after 6 failed attempts. The option `IdentitiesOnly yes` forces SSH to use **only** the key you specify.

### Find the values you need

| Value | Where to find it |
|---|---|
| Public DNS of the instance | AWS Console → EC2 → Instances → your instance → **Public IPv4 DNS** |
| User | `ubuntu` (Ubuntu AMI) |
| Private key | the `.pem` file downloaded when you created the key pair |

> The public DNS **changes every time the instance is stopped and started** (unless you use an Elastic IP). Update the `HostName` line when it does.

###  Create the config file

The file is named `config`, **without extension**, in your `.ssh` folder (the folder that already contains `known_hosts`).

**Windows (PowerShell)** — replace the DNS and the key path with yours:

```powershell
@'
Host devstack
    HostName ec2-XX-XX-XX-XX.compute-1.amazonaws.com
    User ubuntu
    IdentityFile C:/Users/<your-user>/Documents/awskeys/<your-key>.pem
    IdentitiesOnly yes
'@ | Set-Content -Path "$env:USERPROFILE\.ssh\config" -Encoding ascii
```

**Linux / macOS:**

```bash
cat >> ~/.ssh/config <<'EOF'
Host devstack
    HostName ec2-XX-XX-XX-XX.compute-1.amazonaws.com
    User ubuntu
    IdentityFile ~/awskeys/<your-key>.pem
    IdentitiesOnly yes
EOF
chmod 600 ~/.ssh/config
chmod 400 ~/awskeys/<your-key>.pem
```

> **Windows pitfalls**
> - Use **forward slashes** `/` in `IdentityFile`, and write the full path: `C:/Users/...`. Do not use `$env:USERNAME` or `~\...`: SSH does not understand them.
> - Keep `-Encoding ascii`: with Windows PowerShell 5, `>` and `Out-File` write UTF-16, which SSH cannot read.
> - If you create the file with Notepad, choose **Save as type: All files**, otherwise it is saved as `config.txt` and ignored.
> - If your Documents folder is synced with OneDrive, the real path may be `C:/Users/<your-user>/OneDrive/Documents/...`. Check with `Test-Path "<path to your .pem>"`, which must return `True`.

### Connect

```bash
ssh devstack
```

### Troubleshooting

| Message | Cause | Fix |
|---|---|---|
| `Too many authentication failures` | several keys offered before the right one | add `IdentitiesOnly yes` |
| `no such identity: ...` | wrong path in `IdentityFile` | check the path, use `/` and a full path |
| `tilde_expand: No such user` | `~` followed by `\` | use `/` or a full path |
| `Permission denied (publickey)` | wrong key for this instance, or wrong user | check the key pair of the instance and use `ubuntu` |
| `UNPROTECTED PRIVATE KEY FILE` | `.pem` file readable by other users | Linux/macOS: `chmod 400 <key>.pem` — Windows: `icacls <key>.pem /inheritance:r /grant:r "$($env:USERNAME):R"` |
| `Connection timed out` | instance stopped, DNS changed, or port 22 closed | check the instance state, the `HostName`, and the security group (SSH from your IP) |
