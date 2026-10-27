#!/bin/bash
# clean_lab04.sh — removes all Lab 04 resources (project "demo")
# Safe to run several times: missing resources are simply skipped.
# Networks, subnets and routers are NOT touched (they are reused by the next labs).

DELETE_IMAGE=yes     # set to "no" to keep the debian-12 image for the next labs

# Wait until a list command returns nothing (max ~2 min)
wait_empty() {
  for i in $(seq 1 40); do
    [ -z "$($@ 2>/dev/null)" ] && return 0
    sleep 3
  done
  echo "   (timeout: some resources are still being deleted)"
}

source ~/devstack/openrc demo demo

echo "== 1. Instances"
for vm in $(openstack server list -f value -c ID); do
  openstack server delete "$vm"                                           # also detaches attached volumes
done
wait_empty openstack server list -f value -c ID

echo "== 2. Volume backups"
for b in $(openstack volume backup list -f value -c ID); do
  openstack volume backup delete "$b" 2>/dev/null
done

echo "== 3. Volume snapshots"
for s in $(openstack volume snapshot list -f value -c ID); do
  openstack volume snapshot delete "$s"                                   # snapshots must go before their source volume
done
wait_empty openstack volume snapshot list -f value -c ID

echo "== 4. Volumes"
for v in $(openstack volume list -f value -c ID); do
  openstack volume delete "$v"
done
wait_empty openstack volume list -f value -c ID

echo "== 5. Floating IPs"
for ip in $(openstack floating ip list -f value -c "Floating IP Address"); do
  ssh-keygen -R "$ip" >/dev/null 2>&1                                     # forget the instance host key for this address
done
for id in $(openstack floating ip list -f value -c ID); do
  openstack floating ip delete "$id"                                      # release the address back to the "public" pool
done

echo "== 6. Security group and key pair"
openstack security group delete web-sg 2>/dev/null
openstack keypair delete lab04-key 2>/dev/null

echo "== 7. Swift containers"
for c in $(openstack container list -f value -c Name); do
  openstack container delete --recursive "$c"                             # --recursive also deletes the objects
done

echo "== 8. Admin-only cleanup"
source ~/devstack/openrc admin admin
for b in $(openstack volume backup list --project demo -f value -c ID); do
  openstack volume backup delete --force "$b" 2>/dev/null                 # retry stuck backups (e.g. in "error" state)
done
if [ "$DELETE_IMAGE" = "yes" ]; then
  openstack image delete debian-12 2>/dev/null
fi

echo "== 9. Local files on the EC2"
rm -f ~/.ssh/lab04-key ~/.ssh/lab04-key.pub
rm -f ~/debian-12-genericcloud-amd64.qcow2                               # ~350 MB downloaded in part 3

echo "== 10. Summary (project demo)"
source ~/devstack/openrc demo demo
echo "Instances : $(openstack server list -f value -c ID | wc -l)"
echo "Volumes   : $(openstack volume list -f value -c ID | wc -l)"
echo "Snapshots : $(openstack volume snapshot list -f value -c ID | wc -l)"
echo "Backups   : $(openstack volume backup list -f value -c ID | wc -l)"
echo "Containers: $(openstack container list -f value -c Name | wc -l)"
echo "Networks kept:"
openstack network list -c Name -f value
echo "Done. Every count above should be 0."