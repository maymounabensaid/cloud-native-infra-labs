#!/usr/bin/env bash
# =============================================================================
# clean_lab05.sh — Nettoyage complet du Lab 05 (Neutron)
# Supprime toutes les ressources créées dans le projet demo pendant le lab,
# pour que le lab suivant puisse repartir de zéro.
# Le script peut être relancé sans erreur : les ressources déjà absentes
# sont simplement ignorées.
# =============================================================================

source ~/devstack/openrc demo demo > /dev/null 2>&1

ok()   { echo "  [OK]  $1"; }
skip() { echo "  [--]  $1 (absent)"; }

# Exécute une commande si la ressource existe, sinon l'ignore
exists() { "$@" > /dev/null 2>&1; }

echo "=== Nettoyage du Lab 05 ==="

# -----------------------------------------------------------------------------
# 1. IP flottantes du lab (description "lab05")
# -----------------------------------------------------------------------------
echo "[1/7] IP flottantes"
FIPS=$(openstack floating ip list --long -f value -c "Floating IP Address" -c Description \
       | awk '$2 == "lab05" {print $1}')
if [ -n "$FIPS" ]; then
  for FIP in $FIPS; do
    ssh-keygen -R "$FIP" > /dev/null 2>&1      # évite l'alerte de clé d'hôte aux labs suivants
    openstack floating ip delete "$FIP" && ok "IP flottante $FIP"
  done
else
  skip "IP flottantes lab05"
fi

# -----------------------------------------------------------------------------
# 2. Instances
# -----------------------------------------------------------------------------
echo "[2/7] Instances"
for VM in vm-front vm-private; do
  if exists openstack server show "$VM"; then
    openstack server delete --wait "$VM" && ok "instance $VM"
  else
    skip "instance $VM"
  fi
done
ssh-keygen -R 10.20.20.10 > /dev/null 2>&1

# -----------------------------------------------------------------------------
# 3. Port réservé
# -----------------------------------------------------------------------------
echo "[3/7] Ports"
if exists openstack port show port-private; then
  openstack port delete port-private && ok "port port-private"
else
  skip "port port-private"
fi

# -----------------------------------------------------------------------------
# 4. Routeur (interfaces, passerelle externe, puis routeur)
# -----------------------------------------------------------------------------
echo "[4/7] Routeur"
if exists openstack router show router-lab05; then
  for SUBNET in subnet-front subnet-private; do
    openstack router remove subnet router-lab05 "$SUBNET" > /dev/null 2>&1 \
      && ok "interface $SUBNET retirée de router-lab05"
  done
  openstack router unset --external-gateway router-lab05 > /dev/null 2>&1 \
    && ok "passerelle externe retirée"
  openstack router delete router-lab05 && ok "routeur router-lab05"
else
  skip "routeur router-lab05"
fi

# -----------------------------------------------------------------------------
# 5. Réseaux (la suppression d'un réseau supprime aussi ses sous-réseaux)
# -----------------------------------------------------------------------------
echo "[5/7] Réseaux"
for NET in net-front net-private; do
  if exists openstack network show "$NET"; then
    openstack network delete "$NET" && ok "réseau $NET (et son sous-réseau)"
  else
    skip "réseau $NET"
  fi
done

# -----------------------------------------------------------------------------
# 6. Groupes de sécurité
#    sg-private d'abord : sa règle SSH référence sg-front (--remote-group)
# -----------------------------------------------------------------------------
echo "[6/7] Groupes de sécurité"
for SG in sg-private sg-front; do
  if exists openstack security group show "$SG"; then
    openstack security group delete "$SG" && ok "groupe $SG"
  else
    skip "groupe $SG"
  fi
done

# -----------------------------------------------------------------------------
# 7. Paire de clés (OpenStack + fichiers locaux)
# -----------------------------------------------------------------------------
echo "[7/7] Paire de clés"
if exists openstack keypair show lab05-key; then
  openstack keypair delete lab05-key && ok "paire de clés lab05-key"
else
  skip "paire de clés lab05-key"
fi
if [ -f ~/.ssh/lab05 ] || [ -f ~/.ssh/lab05.pub ]; then
  rm -f ~/.ssh/lab05 ~/.ssh/lab05.pub && ok "fichiers ~/.ssh/lab05*"
else
  skip "fichiers ~/.ssh/lab05*"
fi

# -----------------------------------------------------------------------------
# Vérification
# -----------------------------------------------------------------------------
echo
echo "=== Ressources restantes du projet demo ==="
openstack server list
openstack floating ip list
openstack router list
openstack network list
openstack security group list
openstack keypair list
echo
echo "Seuls les objets créés par DevStack (public, private, shared, router1, groupe default) doivent subsister."
