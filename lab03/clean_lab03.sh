#!/usr/bin/env bash
# =============================================================
# Lab 03 - Cleanup script
# Deletes every resource created during Lab 03, so that Lab 04
# starts from a clean DevStack environment.
# Usage: bash cleanup-lab03.sh
# =============================================================

DEVSTACK_DIR=~/devstack          # adjust if DevStack is installed elsewhere
STUDENT_USER=student-lab03
STUDENT_PASS=Lab03Pass
PROJECT=project-lab03

# Print a command, run it, and keep going if it fails
# (e.g. the resource was already deleted).
run() {
    echo "+ $*"
    "$@" || echo "  (skipped: resource not found or already deleted)"
}

# -------------------------------------------------------------
# 1. Project resources (as the student user)
# -------------------------------------------------------------
echo "=== 1. Project resources ($STUDENT_USER) ==="
source "$DEVSTACK_DIR/openrc" "$STUDENT_USER" "$PROJECT" > /dev/null
export OS_PASSWORD="$STUDENT_PASS"

if openstack token issue > /dev/null 2>&1; then
    # Instances first: they use the network, the security group and the key pair
    run openstack server delete vm-web vm-web-clone --wait
    run openstack image delete snap-vm-web

    # Floating IPs are not released when an instance is deleted
    for fip in $(openstack floating ip list -f value -c ID); do
        run openstack floating ip delete "$fip"
    done

    # Detach the router from the subnet and from the external network, then delete it
    run openstack router remove subnet router-lab03 subnet-lab03
    run openstack router unset --external-gateway router-lab03
    run openstack router delete router-lab03

    # Deleting the network also deletes its subnet
    run openstack network delete net-lab03

    run openstack security group delete sg-lab03

    # Key pairs belong to the user, not to the project
    run openstack keypair delete key-lab03
else
    echo "  Cannot log in as $STUDENT_USER (already deleted?): skipping this step."
fi
rm -f ~/key-lab03.pem

# -------------------------------------------------------------
# 2. Administration resources (as admin)
# -------------------------------------------------------------
echo "=== 2. Administration resources (admin) ==="
source "$DEVSTACK_DIR/openrc" admin admin > /dev/null

run openstack image delete ubuntu-24.04-minimal
run openstack flavor delete lab03.small lab03.medium lab03.private

if openstack project show "$PROJECT" > /dev/null 2>&1; then
    # Remaining security groups, including the "default" one created automatically
    for sg in $(openstack security group list --project "$PROJECT" -f value -c ID); do
        run openstack security group delete "$sg"
    done
fi

run openstack user delete "$STUDENT_USER"
run openstack project delete "$PROJECT"

# -------------------------------------------------------------
# 3. Verification: only the original DevStack resources should remain
# -------------------------------------------------------------
echo "=== 3. Remaining resources ==="
openstack server list --all-projects
openstack floating ip list
openstack router list
openstack network list
openstack image list
openstack flavor list

# Note: ubuntu-24.04-minimal-cloudimg-amd64.img is kept on purpose
# (avoids downloading it again).