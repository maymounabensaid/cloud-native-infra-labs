
# Common — After an EC2 reboot

DevStack configures some elements **at runtime only**, without saving them: they are lost when your EC2 instance is stopped and started again. This folder provides a script that restores them, for **all labs**.

Run this procedure at the start of a lab session whenever your EC2 instance has been stopped since the previous session.

## Symptoms

After restarting your EC2 instance, you may observe:

- an instance shows **Active** in Horizon but does not respond (SSH, ping);
- `apt` or cloud-init fails inside an instance (no Internet access);
- an instance stays stuck in **powering off**;
- volumes or Swift objects are no longer accessible.

## What gets lost, and what the script restores

| Lost element | Consequence |
|---|---|
| IP address of `br-ex` | floating IPs unreachable from the EC2 |
| NAT rule (`MASQUERADE`) | no Internet access from instances |
| Cinder loop device (LVM) | volumes unavailable, instances stuck |
| Swift disk mount | Swift objects unavailable (Lab 04 onwards) |

The script checks each element first and only acts if needed: it is safe to run several times, and it works for every lab (steps that do not apply, such as Swift before Lab 04, are skipped).

## 1. Get the script

On your EC2 instance:

```bash
cd ~
wget -O restore_after_reboot.sh https://raw.githubusercontent.com/maymounabensaid/Cloud-Native/main/common/restore_after_reboot.sh
chmod +x restore_after_reboot.sh     # make it executable
```

> `-O` overwrites any previous copy, so running these commands again fetches the latest version of the script.

## 2. Restore the environment

```bash
~/restore_after_reboot.sh
```

## 3. Check the DevStack systemd units

```bash
sudo systemctl list-units 'devstack@*' --all --no-pager
```

All units must be `loaded active running`. If one is `failed` or `inactive`, check its logs, then restart it:

```bash
sudo journalctl -u <unit> -n 50 --no-pager
sudo systemctl restart <unit>        # e.g. sudo systemctl restart devstack@n-cpu.service
```

## 4. Check the services from OpenStack

```bash
source ~/devstack/openrc admin admin
openstack compute service list
openstack network agent list
```

All services must be `up` / `enabled`.

A unit can be `active running` in systemd while the matching service is still `down` in OpenStack (for example, when `nova-compute` cannot reach the message queue). Both checks are needed.

> **Note:** the name shown by `openstack compute service list` (e.g. `nova-compute`) is not the systemd unit name (e.g. `devstack@n-cpu.service`). If a service is `down`, use the table below to find the unit to restart.

| OpenStack service | systemd unit |
|---|---|
| nova-compute | `devstack@n-cpu.service` |
| nova-scheduler | `devstack@n-sch.service` |
| nova-conductor | `devstack@n-cond-cell1.service`, `devstack@n-super-cond.service` |
| nova-api | `devstack@n-api.service` |
| neutron-server | `devstack@q-svc.service` or `devstack@neutron-api.service` (depending on the version) |
| Keystone | `devstack@keystone.service` |
| Glance | `devstack@g-api.service` |
| Cinder | `devstack@c-api.service`, `devstack@c-vol.service` |
## 5. Start from a clean environment

Each lab assumes that the resources created in previous labs have been deleted. Check what remains:

```bash
openstack server list --all-projects
openstack floating ip list
openstack router list
openstack network list
```

Only the resources created by DevStack itself should appear (`public`, `private` and `shared` networks, `router1`). If other resources remain, the cleanup of a previous lab was skipped or failed: run the cleanup script found in that lab's folder (e.g. `lab02/clean_lab02.sh`), then run the commands above again to check.