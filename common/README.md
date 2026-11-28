
# Common resources

Resources shared by all the labs.

| File | What it is for | When to use it |
|---|---|---|
| [ssh-setup.md](ssh-setup.md) | Connect to your EC2 instance with a single `ssh devstack` command | Once, on your own computer, before the first lab (update it when the public DNS of the instance changes) |
| [restore-after-reboot.md](restore-after-reboot.md) | Bring DevStack back to a working state | On the EC2 instance, every time it has been stopped and started |
| [restore_after_reboot.sh](restore_after_reboot.sh) | Script used by `restore-after-reboot.md` | — |
| [purge-all.md](purge-all.md) | Delete every resource left by previous labs, to start from a clean DevStack | On the EC2 instance, at the start of each lab, **after** `restore_after_reboot.sh` |
| [purge_all.sh](purge_all.sh) | Script used by `purge-all.md` | — |

## At the start of each lab

On the EC2 instance, in this order:

1. `~/restore_after_reboot.sh` — only if the instance has been stopped since the previous session;
2. `~/purge_all.sh` — every time.

> The order matters: `purge_all.sh` needs the OpenStack services to be running, which is what `restore_after_reboot.sh` ensures.
