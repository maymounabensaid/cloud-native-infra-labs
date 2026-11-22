# Un seul groupe de sécurité pour tous les nœuds du cluster.
# Ports requis par k3s : https://docs.k3s.io/installation/requirements#inbound-rules-for-k3s-nodes

resource "openstack_networking_secgroup_v2" "k3s" {
  name        = "${var.prefix}-sg"
  description = "Lab 07 - noeuds du cluster k3s"
}

# --- Accès depuis l'extérieur (l'hôte EC2) ---------------------------------

resource "openstack_networking_secgroup_rule_v2" "ssh" {
  security_group_id = openstack_networking_secgroup_v2.k3s.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = var.admin_cidr
}

resource "openstack_networking_secgroup_rule_v2" "icmp" {
  security_group_id = openstack_networking_secgroup_v2.k3s.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "icmp"
  remote_ip_prefix  = var.admin_cidr
}

# API Kubernetes (kubectl depuis l'EC2)
resource "openstack_networking_secgroup_rule_v2" "kube_api" {
  security_group_id = openstack_networking_secgroup_v2.k3s.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 6443
  port_range_max    = 6443
  remote_ip_prefix  = var.admin_cidr
}

# Services Kubernetes de type NodePort (Partie B)
resource "openstack_networking_secgroup_rule_v2" "nodeports" {
  security_group_id = openstack_networking_secgroup_v2.k3s.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 30000
  port_range_max    = 32767
  remote_ip_prefix  = var.admin_cidr
}

# --- Trafic entre nœuds du cluster (source = membres du même groupe) -------

# Agents -> serveur : enregistrement et API
resource "openstack_networking_secgroup_rule_v2" "intra_api" {
  security_group_id = openstack_networking_secgroup_v2.k3s.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 6443
  port_range_max    = 6443
  remote_group_id   = openstack_networking_secgroup_v2.k3s.id
}

# Overlay flannel VXLAN (trafic pod <-> pod entre nœuds)
resource "openstack_networking_secgroup_rule_v2" "intra_vxlan" {
  security_group_id = openstack_networking_secgroup_v2.k3s.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "udp"
  port_range_min    = 8472
  port_range_max    = 8472
  remote_group_id   = openstack_networking_secgroup_v2.k3s.id
}

# Kubelet (métriques, logs, exec)
resource "openstack_networking_secgroup_rule_v2" "intra_kubelet" {
  security_group_id = openstack_networking_secgroup_v2.k3s.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 10250
  port_range_max    = 10250
  remote_group_id   = openstack_networking_secgroup_v2.k3s.id
}
