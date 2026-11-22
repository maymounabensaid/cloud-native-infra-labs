# Même schéma qu'au Lab 06 : réseau + sous-réseau + routeur vers le réseau public

data "openstack_networking_network_v2" "public" {
  name = var.external_network
}

resource "openstack_networking_network_v2" "k3s" {
  name           = "${var.prefix}-net"
  admin_state_up = true
}

resource "openstack_networking_subnet_v2" "k3s" {
  name            = "${var.prefix}-subnet"
  network_id      = openstack_networking_network_v2.k3s.id
  cidr            = var.subnet_cidr
  ip_version      = 4
  dns_nameservers = var.dns_nameservers
}

resource "openstack_networking_router_v2" "k3s" {
  name                = "${var.prefix}-router"
  admin_state_up      = true
  external_network_id = data.openstack_networking_network_v2.public.id
}

resource "openstack_networking_router_interface_v2" "k3s" {
  router_id = openstack_networking_router_v2.k3s.id
  subnet_id = openstack_networking_subnet_v2.k3s.id
}
