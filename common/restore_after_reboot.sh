#!/bin/bash
# restore_after_reboot.sh — restores DevStack after an EC2 reboot
# Safe to run several times: each step first checks what already exists.
set -u

PUBLIC_CIDR=172.24.4.0/24
PUBLIC_GW=172.24.4.1/24
VG=stack-volumes-lvmdriver-1
BACKING=/opt/stack/data/${VG}-backing-file
SWIFT_IMG=/opt/stack/data/swift/drives/images/swift.img
SWIFT_MNT=/opt/stack/data/swift/drives/sdb1

echo "== 1. External network (br-ex)"
for i in $(seq 1 30); do ip link show br-ex >/dev/null 2>&1 && break; sleep 2; done   # wait for Open vSwitch to recreate br-ex
if ! ip addr show br-ex | grep -q "inet ${PUBLIC_GW}"; then
  sudo ip addr add "$PUBLIC_GW" dev br-ex                                             # give the host its address on the public network
fi
sudo ip link set br-ex up

echo "== 2. Routing and NAT to the Internet"
sudo sysctl -qw net.ipv4.ip_forward=1                                                 # let the EC2 forward packets like a router
EXT_IF=$(ip route show default | awk '{print $5; exit}')                              # EC2 outgoing interface (e.g. ens5)
sudo iptables -t nat -C POSTROUTING -s "$PUBLIC_CIDR" -o "$EXT_IF" -j MASQUERADE 2>/dev/null \
  || sudo iptables -t nat -A POSTROUTING -s "$PUBLIC_CIDR" -o "$EXT_IF" -j MASQUERADE  # add the NAT rule only if missing

echo "== 3. Block storage (Cinder / LVM)"
if [ -f "$BACKING" ]; then
  sudo losetup -j "$BACKING" | grep -q loop || sudo losetup -f --show "$BACKING"     # reattach the backing file to a loop device
  sudo vgchange -ay "$VG"                                                             # reactivate the volume group
fi

echo "== 4. Object storage (Swift)"
if [ -f "$SWIFT_IMG" ] && ! mountpoint -q "$SWIFT_MNT"; then
  sudo mount -t xfs -o loop,noatime "$SWIFT_IMG" "$SWIFT_MNT"                         # remount the Swift disk image
fi

echo "== 5. Restarting storage and compute services"
for svc in c-vol c-bak s-account s-container s-object s-proxy n-cpu; do
  if systemctl list-unit-files "devstack@${svc}.service" | grep -q "devstack@${svc}"; then
    sudo systemctl restart "devstack@${svc}"                                          # restart only services that exist
  fi
done

echo "== 6. Checks"
ip -br addr show br-ex
sudo iptables -t nat -S POSTROUTING | grep "$PUBLIC_CIDR"
sudo vgs "$VG" 2>/dev/null
mountpoint "$SWIFT_MNT" 2>/dev/null
echo "Done. Stopped instances must be restarted: Horizon → Hard Reboot Instance."