
# OpenTofu cheat sheet — OpenStack provider

Reference for the blocks and arguments used in Lab 06. For full details, see the provider documentation: <https://registry.terraform.io/providers/terraform-provider-openstack/openstack/latest/docs>

---

## 1. General syntax

```hcl
<block_type> "<object_type>" "<local_name>" {
  argument   = value
  sub_block {
    argument = value
  }
}
```

| Element | Role |
|---|---|
| `<block_type>` | Language keyword: `resource`, `data`, `variable`, `output`, `provider`, `terraform` |
| `<object_type>` | Type defined by the provider (e.g. `openstack_networking_network_v2`), **fixed** |
| `<local_name>` | Name you choose, used only inside the code to refer to the block |
| `argument = value` | Block parameter; the value can be a string, a number, a list or a reference |

### References

| To refer to… | Write |
|---|---|
| A variable | `var.<name>` |
| An attribute of a resource | `<object_type>.<local_name>.<attribute>` |
| An attribute of a data source | `data.<object_type>.<local_name>.<attribute>` |
| A list element | `<…>.<attribute>[0]` |

A reference creates an **implicit dependency**: the referenced object is created before the object that refers to it.

### Argument available on every resource

| Argument | Role |
|---|---|
| `depends_on = [<object_type>.<local_name>]` | Explicit dependency, when no reference links the two blocks |

### Functions used in the lab

| Function | Role | Example |
|---|---|---|
| `file(path)` | Reads the content of a file | `file("~/.ssh/key.pub")` |
| `pathexpand(path)` | Replaces `~` with the home directory | `pathexpand("~/.ssh/key.pub")` |

---

## 2. Language blocks

### `terraform` — requirements

```hcl
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 3.0"
    }
  }
}
```

| Argument | Role |
|---|---|
| `required_version` | Minimum OpenTofu version |
| `required_providers` | Plugins downloaded by `tofu init` |
| `source` | Plugin address in the registry (`publisher/name`) |
| `version` | Version constraint; `~> 3.0` accepts any 3.x version |

### `provider` — connection

```hcl
provider "openstack" {
  cloud = "my-profile"
}
```

| Argument | Role |
|---|---|
| `cloud` | Name of the profile to use in `~/.config/openstack/clouds.yaml` |

### `variable` — input parameter

```hcl
variable "example" {
  description = "Documentation text"
  type        = string
  default     = "value"
}
```

| Argument | Role |
|---|---|
| `description` | Documentation, no effect on execution |
| `type` | `string`, `number`, `bool`, `list(string)`, … |
| `default` | Value used when no other value is provided |

Override a value without editing the file: `tofu plan -var 'example=other_value'`

### `output` — value displayed after deployment

```hcl
output "example" {
  description = "Documentation text"
  value       = <reference>
}
```

Read an output: `tofu output` or `tofu output -raw example`

---

## 3. Data source used

### `data "openstack_networking_network_v2"` — read an existing network

| Argument | Role |
|---|---|
| `name` | Name of the network to look up |
| `external` | `true` to keep only external networks |

| Exported attribute | Content |
|---|---|
| `id` | Network ID |
| `name` | Network name |

---

## 4. Networking resources (Neutron)

### `openstack_networking_network_v2` — network

| Argument | Required | Role |
|---|---|---|
| `name` | no | Network name |
| `admin_state_up` | no | Administrative state (`true` by default) |

Useful exported attribute: `id`

### `openstack_networking_subnet_v2` — subnet

| Argument | Required | Role |
|---|---|---|
| `network_id` | **yes** | Network the subnet belongs to |
| `cidr` | **yes** | Address range (e.g. `192.168.1.0/24`) |
| `ip_version` | no | `4` or `6` |
| `name` | no | Subnet name |
| `gateway_ip` | no | Gateway address |
| `allocation_pool { start, end }` | no | Sub-block: range handed out by DHCP |
| `dns_nameservers` | no | List of DNS servers |
| `enable_dhcp` | no | `true` by default |

Useful exported attribute: `id`

### `openstack_networking_router_v2` — router

| Argument | Required | Role |
|---|---|---|
| `name` | no | Router name |
| `external_network_id` | no | ID of the external network used as gateway |

Useful exported attribute: `id`

### `openstack_networking_router_interface_v2` — attach a subnet to a router

| Argument | Required | Role |
|---|---|---|
| `router_id` | **yes** | Router |
| `subnet_id` | yes, or `port_id` | Subnet to attach |

### `openstack_networking_port_v2` — port

| Argument | Required | Role |
|---|---|---|
| `network_id` | **yes** | Network of the port |
| `name` | no | Port name |
| `fixed_ip { subnet_id, ip_address }` | no | Sub-block: subnet, and optional fixed address |
| `security_group_ids` | no | List of security groups; when set, the `default` group is not applied |

| Exported attribute | Content                                   |
| ------------------ | ----------------------------------------- |
| `id`               | Port ID                                   |
| `all_fixed_ips`    | List of IP addresses assigned to the port |
| `mac_address`      | MAC address                               |

### `openstack_networking_floatingip_v2` — allocate a floating IP

| Argument | Required | Role |
|---|---|---|
| `pool` | **yes** | Name of the external network to take the address from |
| `description` | no | Free text |

Useful exported attribute: `address`

### `openstack_networking_floatingip_associate_v2` — associate a floating IP with a port

| Argument | Required | Role |
|---|---|---|
| `floating_ip` | **yes** | Floating IP address |
| `port_id` | **yes** | Port that receives the floating IP |

---

## 5. Security resources (Neutron)

### `openstack_networking_secgroup_v2` — security group

| Argument | Required | Role |
|---|---|---|
| `name` | **yes** | Group name |
| `description` | no | Free text |

Useful exported attribute: `id`

### `openstack_networking_secgroup_rule_v2` — security group rule

| Argument | Required | Role |
|---|---|---|
| `security_group_id` | **yes** | Group the rule belongs to |
| `direction` | **yes** | `ingress` (inbound) or `egress` (outbound) |
| `ethertype` | **yes** | `IPv4` or `IPv6` |
| `protocol` | no | `tcp`, `udp`, `icmp`, … |
| `port_range_min`, `port_range_max` | no | Port range (same value for a single port) |
| `remote_ip_prefix` | no | Allowed source, as an address range |
| `remote_group_id` | no | Allowed source, as a security group: only its members are allowed |

`remote_ip_prefix` and `remote_group_id` are mutually exclusive: use one **or** the other.

---

## 6. Compute resources (Nova)

### `openstack_compute_keypair_v2` — key pair

| Argument | Required | Role |
|---|---|---|
| `name` | **yes** | Key name in Nova |
| `public_key` | no | Content of the public key to import |

Useful exported attribute: `name`

### `openstack_compute_instance_v2` — instance

| Argument | Required | Role |
|---|---|---|
| `name` | **yes** | Instance name |
| `image_name` or `image_id` | yes | Boot image |
| `flavor_name` or `flavor_id` | yes | Flavor |
| `key_pair` | no | Name of the key pair injected into the instance |
| `security_groups` | no | Groups applied to ports **created by Nova**; no effect on a pre-created port |
| `network { … }` | no | Sub-block: network attachment, see below |
| `user_data` | no | cloud-init script run at first boot |

The `network` sub-block accepts **one** of the following forms:

| Form | Effect |
|---|---|
| `network { uuid = <network id> }` | Nova creates a port on this network |
| `network { port = <port id> }` | Nova uses a pre-created port |

Useful exported attributes: `id`, `access_ip_v4`

---

## 7. Commands

| Command | Role | Changes the cloud? |
|---|---|---|
| `tofu init` | Downloads the provider | No |
| `tofu fmt` | Reformats the `.tf` files | No |
| `tofu validate` | Checks syntax and references | No |
| `tofu plan` | Computes the changes to apply | No |
| `tofu apply` | Applies the plan, after confirmation | **Yes** |
| `tofu destroy` | Deletes everything the code created | **Yes** |
| `tofu output` | Displays the outputs | No |
| `tofu state list` | Lists the managed resources | No |
| `tofu state show <address>` | Displays the attributes of a managed resource | No |

### Plan symbols

| Symbol | Meaning |
|---|---|
| `+` | Create |
| `~` | Update in place |
| `-` | Delete |
| `-/+` | Replace: delete, then create again |
| `(known after apply)` | Value known only after creation |
