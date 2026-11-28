
# Common — Start from a clean DevStack

Each lab assumes that the resources created in previous labs have been deleted. If a cleanup step was skipped or failed, leftover resources can cause errors in the next lab: names already in use, IP addresses already taken, memory or quotas used by forgotten instances.

`purge_all.sh` deletes every resource created by the labs and keeps only what DevStack itself created (the `public`, `private` and `shared` networks, `router1`, the default security groups and flavors). It replaces the per-lab cleanup scripts when you are not sure what is left.

Run this procedure at the start of each lab, **after** [restore-after-reboot.md](restore-after-reboot.md) if your EC2 instance has been stopped.

> ⚠️ The script deletes resources permanently. Do not run it in the middle of a lab whose resources you still need.

## 1. Get the script

On your EC2 instance:

```bash
cd ~
wget -O purge_all.sh https://raw.githubusercontent.com/maymounabensaid/cloud-native-infra-labs/main/common/purge_all.sh
chmod +x purge_all.sh     # make it executable
```

> `-O` overwrites any previous copy, so running these commands again fetches the latest version of the script.

## 2. Purge the environment

```bash
~/purge_all.sh --yes
```

## 3. Check the result

```bash
source ~/devstack/openrc admin admin
openstack server list --all-projects
openstack floating ip list
openstack router list
openstack network list
openstack volume list --all-projects
```

Only the resources created by DevStack itself should appear (`public`, `private` and `shared` networks, `router1`). If something remains, run `~/purge_all.sh` again: some resources can only be deleted once the resources that depend on them are gone (for example, a network still used by an instance).

Then switch back to the user used in the labs:

```bash
export OS_CLOUD=demo
```