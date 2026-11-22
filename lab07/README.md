# Lab 07 — Un cluster Kubernetes (k3s) sur OpenStack

> **Module :** Infrastructures cloud natives — volet *orchestration*
> **Durée :** ≈ 2 h
> **Prérequis :** Lab 06 (OpenTofu) terminé, DevStack fonctionnel sur votre EC2
> **Suite :** Lab 08 — déploiement d'une application sur ce cluster

## Objectifs

À la fin de ce lab, vous serez capable de :

- réutiliser votre code OpenTofu pour provisionner les VM d'un cluster Kubernetes : **1 serveur** et **1 ou 2 agents** ;
- installer **k3s** automatiquement au démarrage des VM avec **cloud-init** ;
- vérifier le cluster avec `kubectl get nodes`, depuis le serveur puis depuis l'EC2 ;
- relier ce que voit Kubernetes (nœuds, pods) à ce que fournit OpenStack (instances, ports, réseau).


## Topologie

![Topologie du Lab 07 : cluster k3s sur OpenStack](images/lab07-topology.jpeg)

> La bande **Kubernetes** représente le réseau des pods (10.42.0.0/16). Ce n'est pas un réseau OpenStack : les pods tournent **à l'intérieur** des VM, et leur trafic d'un nœud à l'autre passe dans un tunnel transporté par `k3s-net`. Neutron ne voit que les IP des VM (10.70.0.x), jamais celles des pods. Ce tunnel est créé par **flannel**, le composant réseau inclus dans k3s.

### Les nœuds du cluster

| Nœud          | Rôle Kubernetes      | Gabarit | vCPU | RAM  | Accès                                       |
| ------------- | -------------------- | ------- | ---- | ---- | ------------------------------------------- |
| `k3s-server`  | control plane + pods | `ds2G`  | 2    | 2 Go | IP privée + **IP flottante**                |
| `k3s-agent-1` | worker (pods)        | `ds1G`  | 1    | 1 Go | IP privée seulement (rebond par le serveur) |

### Plan d'adressage

| Réseau | Plage | Géré par | Contient |
|---|---|---|---|
| Réseau public | 172.24.4.0/24 | OpenStack (DevStack) | IP flottantes, passerelle du routeur |
| `k3s-net` | 10.70.0.0/24 | OpenStack (Neutron) | IP des VM |
| Réseau des pods | 10.42.0.0/16 | Kubernetes (k3s) | IP des pods |
| Réseau des Services | 10.43.0.0/16 | Kubernetes (k3s) | IP virtuelles des Services (Lab 08) |

### Flux réseau

| De                           | Vers                           | Port      | Rôle                       |
| ---------------------------- | ------------------------------ | --------- | -------------------------- |
| EC2                          | `k3s-server` (IP flottante)    | 22/tcp    | SSH                        |
| EC2                          | `k3s-server` (IP flottante)    | 6443/tcp  | `kubectl` → API Kubernetes |
| `k3s-agent-1`                | `k3s-server`                   | 6443/tcp  | l'agent rejoint le cluster |
| `k3s-server` ↔ `k3s-agent-1` |                                | 8472/udp  | tunnel du réseau des pods  |
| `k3s-server` ↔ `k3s-agent-1` |                                | 10250/tcp | kubelet (métriques, logs)  |
| VM                           | Internet (via SNAT du routeur) | 443/tcp   | téléchargement de k3s      |

> Chaque flux entrant correspond à une règle du groupe de sécurité `k3s-sg` (voir `security.tf`).

---

## 1. Avant de commencer : remettre DevStack en état

> Exécutez les deux scripts du dossier [`common/`](../common/) du dépôt, **dans cet ordre** :
>
> 1. **`restore_after_reboot.sh`** — remet DevStack en état après un redémarrage de l'EC2 ;
> 2. **`purge_all.sh`** — supprime toutes les ressources des labs précédents, pour démarrer sur un DevStack propre.
>
> Consultez `common/README.md` pour leur utilisation.

Puis, pour tout le reste du lab :

```bash
export OS_CLOUD=demo
```

```bash
openstack compute service list -c Binary -c State
openstack network agent list -c "Agent Type" -c Alive
```

Tous les services doivent être `up` / `:-)` avant de continuer.

## 1. Préparer l'image, la clé et `kubectl`

Toutes les commandes de ce lab s'exécutent avec l'utilisateur **demo** :

```bash
export OS_CLOUD=demo
```

### 1.1. Préparer l'image

**Télécharger l'image Ubuntu.** Cirros ne suffit pas pour k3s : il faut une vraie distribution (systemd, `curl`, cloud-init complet). Tout le monde utilise la **même version datée** de l'image officielle Ubuntu 24.04 (*release 20261017*).

```bash
REL=20261017
BASE=https://cloud-images.ubuntu.com/releases/noble/release-$REL
wget -q --show-progress $BASE/ubuntu-24.04-server-cloudimg-amd64.img
wget -q $BASE/SHA256SUMS
sha256sum -c SHA256SUMS --ignore-missing      # attendu : ubuntu-24.04-server-cloudimg-amd64.img: OK
```

**Créer l'image dans Glance** (dans le même terminal, pour que `$REL` soit toujours défini) :

```bash
openstack image create ubuntu-24.04 \
  --disk-format qcow2 --container-format bare \
  --property cloudimg_release=$REL \
  --file ubuntu-24.04-server-cloudimg-amd64.img
```

**Vérifier l'image** — attendu : `status` = `active`, `size` ≈ 620 000 000 octets, `cloudimg_release='20261017'` dans `properties` :

```bash
openstack image show ubuntu-24.04 -c status -c visibility -c size -c properties
```

> L'image est créée dans le projet `demo` avec la visibilité `shared` ou `private` : c'est suffisant, car OpenTofu travaille dans ce même projet. Seul un administrateur peut publier une image `public`.

**Supprimer les fichiers téléchargés** (l'image est maintenant stockée dans Glance) :

```bash
rm ubuntu-24.04-server-cloudimg-amd64.img SHA256SUMS
```

### 1.2. Préparer la clé

**Clé SSH dédiée au lab.** On crée une paire de clés propre au Lab 07 :

```bash
ssh-keygen -t ed25519 -N "" -C "lab07" -f ~/.ssh/lab07
cat ~/.ssh/lab07.pub
```

> Deux fichiers sont créés : `~/.ssh/lab07` (clé **privée**, qui ne quitte jamais l'EC2) et `~/.ssh/lab07.pub` (clé **publique**, qu'OpenTofu enverra à Nova pour l'injecter dans les VM). Si `ssh-keygen` demande `Overwrite (y/n)?`, la clé existe déjà : répondez **n**.

**Configuration de `ssh`.** Par défaut, `ssh` n'essaie que les clés standard (`id_ed25519`, `id_rsa`…). Sans configuration, il faudrait ajouter `-i ~/.ssh/lab07` à chaque commande `ssh` et `scp` du lab. On indique donc une fois pour toutes, dans `~/.ssh/config`, quelle clé utiliser pour les adresses du cluster.

* Ouvrez le fichier `~/.ssh/config` (il est créé s'il n'existe pas) :

```bash
nano ~/.ssh/config
```

* Ajoutez ce bloc à la fin du fichier, puis enregistrez (`Ctrl+O`, `Entrée`, `Ctrl+X`) :

```text
# Lab 07 - cluster k3s (IP flottantes DevStack + réseau privé du cluster)
Host 172.24.4.* 10.70.0.*
  User ubuntu
  IdentityFile ~/.ssh/lab07
  StrictHostKeyChecking accept-new
```

> `Host` : les adresses concernées (IP flottantes et réseau privé du cluster). `User ubuntu` : l'utilisateur des images cloud Ubuntu. `IdentityFile` : la clé privée du lab. `StrictHostKeyChecking accept-new` : accepte automatiquement la clé d'hôte d'une **nouvelle** VM, mais refuse une clé **différente** pour une adresse déjà connue.

* Restreignez les droits du fichier (lecture et écriture pour vous seul — `ssh` refuse un fichier de configuration accessible aux autres utilisateurs) :

```bash
chmod 600 ~/.ssh/config
```

### 1.3. Installer `kubectl`

**`kubectl` sur l'EC2** — il servira à piloter le cluster depuis l'extérieur :

```bash
curl -sLO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -m 0755 kubectl /usr/local/bin/kubectl && rm kubectl
kubectl version --client
```

**Ressources disponibles.** Vérifiez les gabarits et la mémoire libre sur l'hôte :

```bash
openstack flavor list -c Name -c RAM -c VCPUs -c Disk | grep -E "Name|ds1G|ds2G"
free -h
nproc
```

>Le cluster consomme ≈ 3 Go de RAM avec 1 agent (`ds2G` : 2 Go + `ds1G` : 1 Go). Sur une r8i.large (2 vCPU, 16 Gio), DevStack laisse ≈ 9 Gio disponibles : la mémoire n'est pas le problème. La limite est le **processeur** : les VM du cluster déclarent 3 vCPU, alors que l'hôte n'en a que 2, partagés avec tous les services DevStack. L'installation de k3s peut donc prendre jusqu'à 10 minutes. Gardez **`agent_count = 1`** ; vérifiez seulement que `free -h` affiche au moins 4 Go disponibles (sinon, des instances des labs précédents tournent encore).

## 2. Le projet OpenTofu du cluster

### 2.1. Télécharger le projet

```bash
mkdir -p ~/lab07-tofu && cd ~/lab07-tofu
curl -sL https://github.com/maymounabensaid/cloud-native-infra-labs/archive/refs/heads/main.tar.gz \
  | tar -xz --strip-components=3 cloud-native-infra-labs-main/lab07/tofu
ls -R
```

> `curl` télécharge l'archive du dépôt du cours ; `tar` n'en extrait que le dossier `lab07/tofu`, directement dans `~/lab07-tofu`.


`ls -R` doit afficher l'arborescence suivante :

```
~/lab07-tofu/
├── providers.tf               # providers OpenStack et random
├── variables.tf               # paramètres du projet
├── network.tf                 # réseau, sous-réseau, routeur
├── security.tf                # groupe de sécurité et ses règles
├── compute.tf                 # jeton, clé, ports, IP flottante, VM
├── outputs.tf                 # valeurs affichées après tofu apply
├── terraform.tfvars.example   # modèle de fichier de valeurs
└── cloud-init/
    ├── server.yaml.tftpl      # script d'installation de k3s (serveur)
    └── agent.yaml.tftpl       # script d'installation de k3s (agent)
```

Le dossier contient trois types de fichiers :

| Type | Fichiers | Rôle |
|---|---|---|
| Code OpenTofu (`.tf`) | `providers.tf`, `variables.tf`, `network.tf`, `security.tf`, `compute.tf`, `outputs.tf` | décrivent l'infrastructure à créer ; détaillés en section 2.2 |
| Valeurs (`.tfvars`) | `terraform.tfvars.example` | modèle des valeurs du projet ; on le copie en `terraform.tfvars` pour l'utiliser |
| Gabarits cloud-init (`.tftpl`) | `cloud-init/server.yaml.tftpl`, `cloud-init/agent.yaml.tftpl` | scripts exécutés au premier démarrage des VM ; OpenTofu les remplit avant de les envoyer à Nova (section 2.4) |

> D'autres fichiers apparaîtront dans ce dossier au fil du lab, créés par OpenTofu : `.terraform/` et `.terraform.lock.hcl` (après `tofu init`), `lab07.plan` (après `tofu plan`), et surtout `terraform.tfstate` (après `tofu apply`), qui garde la trace de toutes les ressources créées.


```bash
cp terraform.tfvars.example terraform.tfvars
cat terraform.tfvars
```


Vérifiez les valeurs de `terraform.tfvars` :

```hcl
cloud           = "demo"
agent_count     = 1
public_key_path = "~/.ssh/lab07.pub"
```

>  Lancez toujours `tofu` **depuis ce dossier** (`cd ~/lab07-tofu`). OpenTofu lit les fichiers `.tf` et écrit son état (`terraform.tfstate`) dans le dossier courant.

### 2.2. Ce que déclare chaque fichier

OpenTofu lit **tous** les fichiers `.tf` du dossier comme un seul ensemble : le découpage en fichiers sert seulement à organiser le code.

| Fichier                        | Ce qu'il déclare                                                                                                                                                                       |
| ------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `providers.tf`                 | les deux providers utilisés : **OpenStack** (authentification avec le profil `demo` de `clouds.yaml`) et **random** (génération du jeton k3s)                                          |
| `variables.tf`                 | les paramètres du projet : noms, gabarits, nombre d'agents, clé SSH, plages d'adresses (tableau ci-dessous)                                                                            |
| `network.tf`                   | le réseau privé `k3s-net`, son sous-réseau `10.70.0.0/24`, le routeur `k3s-router` relié au réseau `public`, et l'interface qui les connecte                                           |
| `security.tf`                  | le groupe de sécurité `k3s-sg` et ses 7 règles : 4 pour l'accès depuis l'EC2 (SSH, ICMP, API Kubernetes, NodePorts), 3 pour le trafic **entre les nœuds** (`remote_group_id`)          |
| `compute.tf`                   | le cœur du cluster : le jeton k3s, la paire de clés, un port Neutron par nœud, l'IP flottante du serveur, puis les instances `k3s-server` et `k3s-agent-N` (`count = var.agent_count`) |
| `outputs.tf`                   | les valeurs affichées après `tofu apply` : IP flottante, IP privées, commandes SSH                                                                                                     |
| `cloud-init/server.yaml.tftpl` | le script exécuté au premier démarrage du serveur : installe k3s en mode **server**                                                                                                    |
| `cloud-init/agent.yaml.tftpl`  | le script exécuté au premier démarrage d'un agent : installe k3s en mode **agent** et rejoint le serveur                                                                               |

### 2.3. Les variables

| Variable | Valeur par défaut | Rôle |
|---|---|---|
| `cloud` | `demo` | profil de `clouds.yaml` utilisé pour s'authentifier |
| `prefix` | `k3s` | préfixe du nom de toutes les ressources |
| `external_network` | `public` | réseau externe de DevStack, qui fournit les IP flottantes |
| `image_name` | `ubuntu-24.04` | image Glance créée en section 1 |
| `server_flavor` | `ds2G` | gabarit du serveur |
| `agent_flavor` | `ds1G` | gabarit des agents |
| `agent_count` | `1` | nombre d'agents |
| `public_key_path` | `~/.ssh/lab07.pub` | clé publique injectée dans les VM |
| `subnet_cidr` | `10.70.0.0/24` | plage d'adresses des VM |
| `dns_nameservers` | `8.8.8.8`, `1.1.1.1` | serveurs DNS donnés aux VM par Neutron |
| `admin_cidr` | `0.0.0.0/0` | origine autorisée pour SSH, l'API et les NodePorts |

> Pour changer une valeur sans modifier le code : `terraform.tfvars`, ou `tofu apply -var agent_count=1`.

### 2.4. Le lien entre OpenTofu et cloud-init

OpenTofu ne fait **pas** l'installation de Kubernetes : il crée les VM et leur transmet un script cloud-init (`user_data`), exécuté au premier démarrage. La fonction `templatefile()` remplit chaque script avec des valeurs que seul OpenTofu connaît :

| Valeur insérée | Dans le script | D'où vient-elle |
|---|---|---|
| `k3s_token` | serveur et agents | `random_password` : le même jeton pour tous les nœuds |
| `floating_ip` | serveur | l'IP flottante, allouée **avant** la VM |
| `server_ip` | agents | l'IP du port du serveur, connue **avant** la VM |
| `node_name` | serveur et agents | nom du nœud dans Kubernetes |

Script du serveur (`cloud-init/server.yaml.tftpl`) :

```yaml
#cloud-config
package_update: false

runcmd:
  - |
    for i in 1 2 3 4 5; do
      curl -sfL --retry 5 --retry-delay 5 --retry-all-errors https://get.k3s.io -o /tmp/install-k3s.sh \
        && K3S_TOKEN="${k3s_token}" sh /tmp/install-k3s.sh server \
             --node-name "${node_name}" \
             --write-kubeconfig-mode 644 \
             --tls-san "${floating_ip}" \
             --disable traefik \
        && break
      echo "Installation k3s : tentative $i échouée, nouvel essai dans 15 s"; sleep 15
    done
  - test -x /usr/local/bin/k3s && echo "k3s server installed" > /var/tmp/k3s-ready
```

Script de l'agent (`cloud-init/agent.yaml.tftpl`) :

```yaml
#cloud-config
package_update: false

runcmd:
  - |
    for i in 1 2 3 4 5; do
      curl -sfL --retry 5 --retry-delay 5 --retry-all-errors https://get.k3s.io -o /tmp/install-k3s.sh \
        && K3S_URL="https://${server_ip}:6443" K3S_TOKEN="${k3s_token}" \
           sh /tmp/install-k3s.sh agent --node-name "${node_name}" \
        && break
      echo "Installation k3s : tentative $i échouée, nouvel essai dans 15 s"; sleep 15
    done
  - test -x /usr/local/bin/k3s && echo "k3s agent installed" > /var/tmp/k3s-ready
```

## 3. Appliquer

```bash
tofu init
tofu plan -out lab07.plan
```

> **Q2.** Combien de ressources le plan va-t-il créer ? Lesquelles sont des ressources **OpenStack** et laquelle n'en est pas une ?

```bash
tofu apply lab07.plan
tofu output
```

## 4. Suivre le démarrage des nœuds

OpenStack a démarré les VM. Kubernetes n'existe pas encore : cloud-init est en train de l'installer.

```bash
openstack server list
openstack console log show k3s-server | tail -20
```

```bash
FIP=$(tofu output -raw server_floating_ip)
ssh -o StrictHostKeyChecking=accept-new ubuntu@$FIP 'cloud-init status --wait'
ssh ubuntu@$FIP 'cat /var/tmp/k3s-ready; sudo tail -5 /var/log/cloud-init-output.log'
```

> Comptez 3 à 6 minutes. La virtualisation est imbriquée : les VM sont lentes.

**En cas de problème** — les nœuds doivent pouvoir télécharger k3s depuis Internet :

```bash
ssh ubuntu@$FIP 'curl -sI https://get.k3s.io | head -1'   # attendu : HTTP/2 200
```

Si la commande échoue, vérifiez la NAT de DevStack vers Internet sur l'EC2 :
`sudo iptables -t nat -S POSTROUTING | grep 172.24.4` (voir `common/README.md`).

## 5. Vérifier le cluster

**Depuis le serveur** (k3s installe `kubectl`) :

```bash
ssh ubuntu@$FIP
kubectl get nodes -o wide
kubectl get pods -A
exit
```

**Depuis l'EC2**, en utilisant l'API exposée par l'IP flottante :

```bash
mkdir -p ~/.kube
scp ubuntu@$FIP:/etc/rancher/k3s/k3s.yaml ~/.kube/lab07.yaml
sed -i "s/127.0.0.1/$FIP/" ~/.kube/lab07.yaml
export KUBECONFIG=~/.kube/lab07.yaml
kubectl get nodes -o wide
```

Résultat attendu (les IP varient) :

```
NAME          STATUS   ROLES                  AGE   VERSION        INTERNAL-IP
k3s-agent-1   Ready    <none>                 3m    v1.3x.x+k3s1   10.70.0.x
k3s-server    Ready    control-plane,master   4m    v1.3x.x+k3s1   10.70.0.y
```

## 6. Le cluster vu d'OpenStack

Kubernetes voit des **nœuds**. OpenStack voit des **instances**, des **ports** et un **réseau**. Faisons le lien.

**Nœuds ↔ ports Neutron**

```bash
kubectl get nodes -o custom-columns=NODE:.metadata.name,IP:.status.addresses[0].address
openstack port list --network k3s-net -c Name -c "Fixed IP Addresses"
```

**Pods ↔ Neutron**

```bash
kubectl get pods -A -o wide
```

**MTU : un tunnel dans un tunnel**

```bash
openstack network show k3s-net -c mtu
ssh ubuntu@$FIP 'ip -br link show | grep -E "ens|flannel"'
```

**Instances ↔ hyperviseur**

```bash
sudo virsh list
openstack --os-cloud devstack-admin server show k3s-server -c OS-EXT-SRV-ATTR:instance_name
```

**Le jeton du cluster ↔ le service de métadonnées de Nova**

```bash
ssh ubuntu@$FIP 'curl -s http://169.254.169.254/openstack/latest/user_data | grep K3S_TOKEN'
grep '"result"' terraform.tfstate     # le jeton généré par random_password
```

## 7. Nettoyage (obligatoire)

Le cluster est entièrement décrit par votre code : on le **détruit**. Au Lab 08, vous le recréerez en quelques minutes avec `tofu apply`.

```bash
cd ~/lab07-tofu && tofu destroy
openstack server list
openstack floating ip list
openstack network list
rm -f ~/.kube/lab07.yaml && unset KUBECONFIG
```

> Gardez le dossier `~/lab07-tofu` et l'image `ubuntu-24.04` : ils resserviront au Lab 08.

---
