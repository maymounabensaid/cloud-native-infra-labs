
# Common — After an EC2 reboot

DevStack configures some elements **at runtime only**, without saving them: they are lost when your EC2 instance is stopped and started again. This folder provides a script that restores them, for **all labs**.

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

## Get the script

On your EC2 instance:

```bash
cd ~
wget https://raw.githubusercontent.com/maymounabensaid/Cloud-Native/main/common/restore_after_reboot.sh
chmod +x restore_after_reboot.sh     # make it executable (once)
```

## Restore the environment

```bash
~/restore_after_reboot.sh
```

Then, in Horizon, restart every stopped instance: **Project → Compute → Instances → Hard Reboot Instance**.

> **Why "Hard Reboot" and not "Start"?** After the EC2 reboot, the Nova database still says **Active** while the VM is actually stopped on the hypervisor (`sudo virsh list --all` shows `shut off`). Nova refuses to "start" an instance it believes is active; a **hard reboot** forces a stop and a restart, whatever the recorded state.

### Expected output (checks section)

```
== 6. Checks
br-ex            UNKNOWN        172.24.4.1/24 fe80::.../64
-A POSTROUTING -s 172.24.4.0/24 -o enp39s0 -j MASQUERADE
  VG                        #PV #LV #SN Attr   VSize   VFree
  stack-volumes-lvmdriver-1   1   2   0 wz--n- <30.00g 1.43g
/opt/stack/data/swift/drives/sdb1 is a mountpoint
```

- `br-ex` must carry `172.24.4.1/24`; the `UNKNOWN` state is normal for an Open vSwitch bridge.
- The interface name after `-o` (here `enp39s0`) depends on your EC2 instance type.
- The `#LV` count depends on the volumes you have created.
- The Swift line only appears from Lab 04 onwards.