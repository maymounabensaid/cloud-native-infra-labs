## Command reference

### Credentials

| Action | Command |
|---|---|
| Work as the `demo` project | `source ~/devstack/openrc demo demo` |
| Work as administrator | `source ~/devstack/openrc admin admin` |

### Exploring

| Action | Command |
|---|---|
| Network agents (admin only) | `openstack network agent list` |
| Networks / external networks | `openstack network list` / `openstack network list --external` |
| Network details | `openstack network show <net>` |
| Subnets / subnet details | `openstack subnet list` / `openstack subnet show <subnet>` |
| Routers / router details | `openstack router list` / `openstack router show <router>` |
| Ports of a network / of a router | `openstack port list --network <net> --long` / `openstack port list --router <router> --long` |
| Instances and their addresses | `openstack server list` |

### Building the topology

| Action | Command |
|---|---|
| Create a network / subnet | `openstack network create <net>` / `openstack subnet create <subnet> --network <net> --subnet-range <cidr> --gateway <ip> --allocation-pool start=<ip>,end=<ip> --dns-nameserver <ip> --dhcp` |
| Router + external gateway | `openstack router create <router>` / `openstack router set <router> --external-gateway public` |
| Attach a subnet to a router | `openstack router add subnet <router> <subnet>` |
| Port with a chosen IP address | `openstack port create <port> --network <net> --fixed-ip subnet=<subnet>,ip-address=<ip>` |
| Key pair | `openstack keypair create --public-key <file.pub> <key>` |
| Instance on a network / on an existing port | `openstack server create <server> --image <image> --flavor <flavor> --network <net> --key-name <key> --wait` / same with `--port <port>` |
| Floating IP | `openstack floating ip create public` / `openstack server add floating ip <server> <fip>` |

### Security groups

| Action | Command |
|---|---|
| List the rules of a group | `openstack security group rule list <sg>` |
| Create a group / a rule | `openstack security group create <sg>` / `openstack security group rule create <sg> --ingress --protocol <proto> --dst-port <port> --remote-ip <cidr>` (or `--remote-group <sg>`) |
| Attach a group | `openstack server add security group <server> <sg>` / `openstack port set <port> --security-group <sg>` |

### OVN view (read-only)

| Action | Command |
|---|---|
| Logical switches, routers and ports | `sudo ovn-nbctl show` |
| DHCP options written by Neutron | `sudo ovn-nbctl list DHCP_Options` |
| NAT rules of a router | `sudo ovn-nbctl lr-nat-list neutron-<router-id>` |
| ACLs of a security group | `sudo ovn-nbctl acl-list pg_<sg-id with - replaced by _>` |