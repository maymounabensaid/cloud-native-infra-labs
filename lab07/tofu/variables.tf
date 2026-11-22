variable "cloud" {
  description = "Nom du cloud dans clouds.yaml"
  type        = string
  default     = "demo"
}

variable "prefix" {
  description = "Préfixe de nommage de toutes les ressources du lab"
  type        = string
  default     = "k3s"
}

variable "external_network" {
  description = "Réseau externe (pool d'IP flottantes) de DevStack"
  type        = string
  default     = "public"
}

variable "image_name" {
  description = "Image Glance utilisée pour les nœuds (Ubuntu cloud image)"
  type        = string
  default     = "ubuntu-24.04"
}

variable "server_flavor" {
  description = "Gabarit du nœud serveur (control plane) : 2 vCPU / 2 Go"
  type        = string
  default     = "ds2G"
}

variable "agent_flavor" {
  description = "Gabarit des nœuds agents (workers) : 1 vCPU / 1 Go"
  type        = string
  default     = "ds1G"
}

variable "agent_count" {
  description = "Nombre de nœuds agents (1 ou 2 selon la mémoire disponible sur l'EC2)"
  type        = number
  default     = 1

  validation {
    condition     = var.agent_count >= 0 && var.agent_count <= 3
    error_message = "agent_count doit être compris entre 0 et 3."
  }
}

variable "public_key_path" {
  description = "Clé publique SSH injectée dans les nœuds"
  type        = string
  default     = "~/.ssh/lab07.pub"
}

variable "subnet_cidr" {
  description = "Sous-réseau des nœuds (ne doit PAS chevaucher 10.42.0.0/16 ni 10.43.0.0/16 utilisés par k3s)"
  type        = string
  default     = "10.70.0.0/24"
}

variable "dns_nameservers" {
  description = "Résolveurs DNS annoncés par le DHCP de Neutron"
  type        = list(string)
  default     = ["8.8.8.8", "1.1.1.1"]
}

variable "admin_cidr" {
  description = "Plage autorisée pour SSH, l'API Kubernetes et les NodePorts"
  type        = string
  default     = "0.0.0.0/0"
}
