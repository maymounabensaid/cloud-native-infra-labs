
# Common resources

Resources shared by all the labs.

| File | What it is for | When to use it |
|---|---|---|
| [ssh-setup.md](ssh-setup.md) | Connect to your EC2 instance with a single `ssh devstack` command | Once, on your own computer, before the first lab (update it when the public DNS of the instance changes) |
| [restore-after-reboot.md](restore-after-reboot.md) | Bring DevStack back to a working state | On the EC2 instance, every time it has been stopped and started |
| [restore_after_reboot.sh](restore_after_reboot.sh) | Script used by `restore-after-reboot.md` | — |
