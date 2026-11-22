terraform {
  required_version = ">= 1.6.0"

  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 3.0" # garder la même contrainte que dans le Lab 06
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# Authentification : profil "demo" de clouds.yaml (~/.config/openstack/clouds.yaml)
provider "openstack" {
  cloud = var.cloud
}
