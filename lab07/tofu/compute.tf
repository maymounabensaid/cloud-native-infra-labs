# Nouveautés par rapport au Lab 06 :
#   - un jeton partagé généré par OpenTofu (random_password)
#   - des ports Neutron créés explicitement (on connaît l'IP du serveur avant son démarrage)
#   - cloud-init généré avec templatefile() pour installer k3s
#   - count pour créer N agents identiques

data "openstack_images_image_v2" "ubuntu" {
  name        = var.image_name
  most_recent = true
}

resource "random_password" "k3s_token" {
  length  = 48
  special = false
}

resource "openstack_compute_keypair_v2" "k3s" {
  name       = "${var.prefix}-key"
  public_key = file(pathexpand(var.public_key_path))
}

# ---------------------------------------------------------------------------
# Nœud serveur (control plane)
# ---------------------------------------------------------------------------

resource "openstack_networking_port_v2" "server" {
  name               = "${var.prefix}-server-port"
  network_id         = openstack_networking_network_v2.k3s.id
  admin_state_up     = true
  security_group_ids = [openstack_networking_secgroup_v2.k3s.id]

  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.k3s.id
  }
}

# L'IP flottante est allouée AVANT l'instance : son adresse peut donc être
# inscrite dans le certificat de l'API (tls-san) via cloud-init.
resource "openstack_networking_floatingip_v2" "server" {
  pool        = var.external_network
  description = "lab07-${var.prefix}-server"
}

resource "openstack_compute_instance_v2" "server" {
  name        = "${var.prefix}-server"
  image_id    = data.openstack_images_image_v2.ubuntu.id
  flavor_name = var.server_flavor
  key_pair    = openstack_compute_keypair_v2.k3s.name

  user_data = templatefile("${path.module}/cloud-init/server.yaml.tftpl", {
    node_name   = "${var.prefix}-server"
    k3s_token   = random_password.k3s_token.result
    floating_ip = openstack_networking_floatingip_v2.server.address
  })

  network {
    port = openstack_networking_port_v2.server.id
  }

  # Le nœud doit pouvoir sortir sur Internet (téléchargement de k3s) dès le boot
  depends_on = [openstack_networking_router_interface_v2.k3s]
}

resource "openstack_networking_floatingip_associate_v2" "server" {
  floating_ip = openstack_networking_floatingip_v2.server.address
  port_id     = openstack_networking_port_v2.server.id

  depends_on = [openstack_networking_router_interface_v2.k3s]
}

# ---------------------------------------------------------------------------
# Nœuds agents (workers) — pas d'IP flottante
# ---------------------------------------------------------------------------

resource "openstack_networking_port_v2" "agent" {
  count              = var.agent_count
  name               = "${var.prefix}-agent-${count.index + 1}-port"
  network_id         = openstack_networking_network_v2.k3s.id
  admin_state_up     = true
  security_group_ids = [openstack_networking_secgroup_v2.k3s.id]

  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.k3s.id
  }
}

resource "openstack_compute_instance_v2" "agent" {
  count       = var.agent_count
  name        = "${var.prefix}-agent-${count.index + 1}"
  image_id    = data.openstack_images_image_v2.ubuntu.id
  flavor_name = var.agent_flavor
  key_pair    = openstack_compute_keypair_v2.k3s.name

  user_data = templatefile("${path.module}/cloud-init/agent.yaml.tftpl", {
    node_name = "${var.prefix}-agent-${count.index + 1}"
    k3s_token = random_password.k3s_token.result
    server_ip = openstack_networking_port_v2.server.all_fixed_ips[0]
  })

  network {
    port = openstack_networking_port_v2.agent[count.index].id
  }

  depends_on = [openstack_networking_router_interface_v2.k3s]
}
