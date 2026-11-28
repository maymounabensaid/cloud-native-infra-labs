#!/usr/bin/env bash
# =============================================================================
# purge_all.sh — Deletes the resources of ALL OpenStack projects,
#                EXCEPT the objects created by default by DevStack.
# =============================================================================

set -o pipefail

if [ ! -f ~/devstack/openrc ]; then
  echo "ERROR: ~/devstack/openrc not found."
  exit 1
fi

source ~/devstack/openrc admin admin > /dev/null 2>&1

KEEP_PROJECTS="admin demo alt_demo service invisible_to_admin"
KEEP_USERS="admin demo alt_demo"
KEEP_IMAGE_PATTERN="cirros"
KEEP_FLAVOR_REGEX='^(m1\.|ds[0-9]|cirros256)'

# DevStack network objects kept: "name@project"
KEEP_NETS="public@admin shared@admin private@demo"
KEEP_ROUTERS="router1@demo"

APPLY=false
[ "$1" = "--yes" ] && APPLY=true

run() {
  if $APPLY; then
    echo "  - $*"
    local OUT
    if ! OUT=$("$@" 2>&1); then
      echo "    FAILED: $*"
      echo "    REASON: $OUT"
      return 1
    fi
  else
    echo "  [dry-run] $*"
  fi
}

in_list() { [[ " $2 " == *" $1 "* ]]; }

# Project ID -> name mapping (handles spaces safely via JSON/CSV or tab)
declare -A PNAME
while IFS=$'\t' read -r ID NAME; do
  [ -n "$ID" ] && PNAME["$ID"]="$NAME"
done < <(openstack project list -f csv --quote none | tail -n +2 | tr ',' '\t')

pname() { echo "${PNAME[$1]:-unknown}"; }

$APPLY && echo "=== ACTUAL DELETION — all projects ===" \
       || echo "=== DRY RUN — nothing is deleted. Run again with --yes to delete ==="

# -----------------------------------------------------------------------------
echo "[1/13] Instances"
for ID in $(openstack server list --all-projects -f value -c ID); do
  run openstack server delete --wait "$ID"
done

echo "[2/13] Floating IPs"
for ID in $(openstack floating ip list -f value -c ID); do
  run openstack floating ip delete "$ID"
done

echo "[3/13] Volume backups"
for ID in $(openstack volume backup list --all-projects -f value -c ID 2>/dev/null); do
  run openstack volume backup delete --force "$ID"
done

echo "[4/13] Volume snapshots"
for ID in $(openstack volume snapshot list --all-projects -f value -c ID); do
  run openstack volume snapshot delete --force "$ID"
done
$APPLY && sleep 3

echo "[5/13] Volumes"
for ID in $(openstack volume list --all-projects -f value -c ID); do
  if ! run openstack volume delete --force "$ID"; then
    run openstack volume set --state available --detached "$ID"
    run openstack volume delete --force "$ID"
  fi
done

echo "[6/13] Images (except CirrOS)"
while IFS= read -r ID; do
  [ -z "$ID" ] && continue
  NAME=$(openstack image show "$ID" -f value -c name 2>/dev/null)
  [[ "${NAME,,}" == *"$KEEP_IMAGE_PATTERN"* ]] && continue
  run openstack image set --unprotected "$ID"
  run openstack image delete "$ID"
done < <(openstack image list -f value -c ID)

# -----------------------------------------------------------------------------
echo "[7/13] Routers (except router1 in the demo project)"
for ID in $(openstack router list -f value -c ID); do
  INFO=$(openstack router show "$ID" -f value -c name -c project_id 2>/dev/null)
  NAME=$(echo "$INFO" | sed -n '1p')
  PROJ=$(echo "$INFO" | sed -n '2p')
  P_NAME=$(pname "$PROJ")

  if in_list "$NAME@$P_NAME" "$KEEP_ROUTERS"; then
    continue
  fi

  # Remove all router interfaces (standard, distributed, HA)
  for P in $(openstack port list --router "$ID" -f value -c ID); do
    run openstack router remove port "$ID" "$P"
  done
  run openstack router unset --external-gateway "$ID"
  run openstack router delete "$ID"
done

echo "[8/13] Manually created ports (empty device_owner)"
for ID in $(openstack port list -f value -c ID); do
  OWNER=$(openstack port show "$ID" -f value -c device_owner 2>/dev/null)
  [ -z "$OWNER" ] && run openstack port delete "$ID"
done

echo "[9/13] Networks (except public, shared, private)"
for ID in $(openstack network list -f value -c ID); do
  INFO=$(openstack network show "$ID" -f value -c name -c project_id 2>/dev/null)
  NAME=$(echo "$INFO" | sed -n '1p')
  PROJ=$(echo "$INFO" | sed -n '2p')
  P_NAME=$(pname "$PROJ")

  if in_list "$NAME@$P_NAME" "$KEEP_NETS"; then
    continue
  fi

  # Delete all non-system ports on this network (including orphaned compute/router ports)
  for P in $(openstack port list --network "$ID" -f value -c ID); do
    P_OWNER=$(openstack port show "$P" -f value -c device_owner 2>/dev/null)
    case "$P_OWNER" in
      network:dhcp|network:distributed|network:ovn-metadata)
        # Automatically deleted with the subnet/network
        continue
        ;;
      *)
        run openstack port delete "$P"
        ;;
    esac
  done

  # Delete subnets explicitly before the network
  for S in $(openstack subnet list --network "$ID" -f value -c ID); do
    run openstack subnet delete "$S"
  done

  run openstack network delete "$ID"
done

echo "[10/13] Security groups (except default in kept projects)"
for PASS in 1 2; do
  [ $PASS -eq 2 ] && ! $APPLY && break
  for ID in $(openstack security group list -f value -c ID); do
    INFO=$(openstack security group show "$ID" -f value -c name -c project_id 2>/dev/null) || continue
    NAME=$(echo "$INFO" | sed -n '1p')
    PROJ=$(echo "$INFO" | sed -n '2p')
    P_NAME=$(pname "$PROJ")

    if [ "$NAME" = "default" ] && in_list "$P_NAME" "$KEEP_PROJECTS"; then
      continue
    fi
    run openstack security group delete "$ID"
  done
done

# -----------------------------------------------------------------------------
echo "[11/13] Key pairs (all users) and Swift containers"
for USER_ID in $(openstack user list -f value -c ID); do
  for K in $(openstack --os-compute-api-version 2.10 keypair list --user "$USER_ID" -f value -c Name 2>/dev/null); do
    run openstack --os-compute-api-version 2.10 keypair delete --user "$USER_ID" "$K"
  done
done

for P in admin demo alt_demo; do
  (
    source ~/devstack/openrc "$P" "$P" > /dev/null 2>&1
    openstack container list -f value -c Name 2>/dev/null | while read -r C; do
      [ -n "$C" ] && run openstack container delete --recursive "$C"
    done
  )
done

echo "[12/13] Flavors (except m1.*, ds*, cirros256)"
for ID in $(openstack flavor list --all -f value -c ID); do
  NAME=$(openstack flavor show "$ID" -f value -c name 2>/dev/null)
  [[ "$NAME" =~ $KEEP_FLAVOR_REGEX ]] && continue
  run openstack flavor delete "$ID"
done

# -----------------------------------------------------------------------------
echo "[13/13] Keystone: projects and users not created by DevStack"
SERVICE_USERS=$(openstack role assignment list --project service --names -f value -c User | cut -d@ -f1 | sort -u)

for U in $(openstack user list -f value -c Name); do
  in_list "$U" "$KEEP_USERS" && continue
  in_list "$U" "$(echo $SERVICE_USERS)" && continue
  run openstack user delete "$U"
done

for P in $(openstack project list -f value -c Name); do
  in_list "$P" "$KEEP_PROJECTS" && continue
  run openstack project delete "$P"
done

# -----------------------------------------------------------------------------
if $APPLY; then
  echo
  echo "=== Remaining resources ==="
  openstack server list --all-projects
  openstack volume list --all-projects
  openstack router list --long -c Name -c Project
  openstack network list --long -c Name -c Project
  openstack security group list -c Name -c Project
  openstack image list
  openstack project list
fi
