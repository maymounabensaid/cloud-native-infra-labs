# Lab 03 — Compute & Images : Nova et Glance



---
## Objectifs


- Gérer des images avec **Glance** : import, formats, propriétés, visibilité et partage entre projets ;
- Définir des **gabarits (flavors)** adaptés à un besoin ;
- Personnaliser une instance au démarrage avec **cloud-init**;
- Piloter le **cycle de vie** d'une instance Nova (stop, pause, suspend, shelve, resize) et expliquer l'effet de chaque opération ;
- Créer un **snapshot d'instance** et redéployer à partir de celui-ci ;
- Observer côté hyperviseur (**libvirt / KVM**) ce que Nova a réellement créé.

---
## Avant de commencer

1. Connectez-vous à votre instance EC2 avec `ssh devstack`. Si ce n'est pas encore configuré sur votre machine, suivez [common/ssh-setup.md](../common/ssh-setup.md).
2. Si votre instance EC2 a été redémarrée depuis la dernière séance, remettez DevStack en état : [common/restore-after-reboot.md](../common/restore-after-reboot.md), étapes 1 à 4.
3. Vérifiez qu'aucune ressource des labs précédents ne subsiste : même fichier, étape 5.

---

## Partie 1 — Architecture de Nova

Nova n'est pas un service unique : il est composé de plusieurs processus qui coopèrent via une file de messages (RabbitMQ) et une base de données.

```bash
source ~/devstack/openrc admin admin
openstack compute service list
openstack hypervisor list
```

> **Q1.** Quels services Nova apparaissent dans `openstack compute service list` ? Expliquez en une phrase le rôle de chacun (`nova-scheduler`, `nova-conductor`, `nova-compute`).

> **Q2.** Observez les colonnes **Host**, **Zone** et **Updated At**.
>
> a) Tous les services tournent sur le même hôte : pourquoi ? Dans un déploiement en production avec plusieurs serveurs, où trouverait-on `nova-compute`, `nova-scheduler` et `nova-conductor` ? Déduisez-en pourquoi `nova-compute` est dans la zone `nova` et les autres dans la zone `internal`.
>
> b) Relancez la commande après quelques secondes : que remarquez-vous dans **Updated At** ? À quoi sert, selon vous, ce mécanisme ?

## Partie 2 — Glance : gestion des images

### 2.1 Explorer les images existantes

```bash
openstack image list
openstack image show <id-image-cirros>
```

> **Q3.** Relevez le format disque (`disk_format`), le format conteneur (`container_format`), la taille, la visibilité et le propriétaire de l'image CirrOS.

### 2.2 Importer une image Ubuntu cloud

```bash
wget https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-amd64.img
```
- Affichez les caractéristiques de l'image :
```bash
qemu-img info ubuntu-24.04-minimal-cloudimg-amd64.img
```

> **Q4.** Quel est le format réel du fichier selon `qemu-img info` ? Comparez sa taille sur disque (*disk size*) et sa taille virtuelle (*virtual size*). Pourquoi ces deux valeurs diffèrent-elles ?

Créez l'image dans Glance :

```bash
openstack image create ubuntu-24.04-minimal \
    --file ubuntu-24.04-minimal-cloudimg-amd64.img \
    --disk-format qcow2 \
    --container-format bare \
    --min-disk 4 \
    --min-ram 512 \
    --property os_distro=ubuntu \
    --property os_version=24.04 \
    --private
```

> **Q5.** À quoi servent `--min-disk` et `--min-ram` ?

### 2.3 Visibilité et partage entre projets

Glance propose quatre niveaux de visibilité : `private`, `shared`, `community`, `public`.

#### a) Créer un projet et un utilisateur de test

Avec les identifiants `admin` :

```bash
openstack project create project-lab03
openstack user create student-lab03 --project project-lab03 --password Lab03Pass
openstack role add --project project-lab03 --user student-lab03 member
```

> **Important :** un administrateur voit toutes les images, quelle que soit leur visibilité. Pour observer réellement l'effet du partage, il faut se placer du point de vue d'un utilisateur **non administrateur**.

#### b) Vérifier que l'image est invisible pour le nouveau projet

Ouvrez un **second terminal** sur l'instance EC2 et connectez-vous en tant que `student-lab03` :

```bash
source ~/devstack/openrc student-lab03 project-lab03
export OS_PASSWORD=Lab03Pass
openstack image list
```

> **Note :** `openrc` charge les paramètres communs à tout le cloud (adresse de Keystone, région, domaine) ; ses deux arguments fixent l'utilisateur et le projet. Le mot de passe doit être redéfini, car `openrc` utilise par défaut celui de l'administrateur. Vérifiez votre identité avec `env | grep OS_ | grep -v PASSWORD`.
>
> Chaque terminal conserve ses propres variables d'environnement : le premier reste connecté en `admin`, le second en `student-lab03`. Comparez la sortie de `openstack image list` dans les deux terminaux.

#### c) Partager l'image avec le projet

Dans le **premier terminal** (admin) :

```bash
openstack image set --shared ubuntu-24.04-minimal
openstack image add project ubuntu-24.04-minimal project-lab03
openstack image member list ubuntu-24.04-minimal
```

#### d) Accepter le partage

Dans le **second terminal** (`student-lab03`) :

```bash
openstack image list
openstack image set --accept <id-image-ubuntu>
openstack image list
```

Vérifiez à nouveau le statut du membre dans le premier terminal :

```bash
openstack image member list ubuntu-24.04-minimal
```

> **Q6.** L'image est-elle visible pour `student-lab03` **avant** le partage ? Après le partage mais **avant** l'acceptation ? Après l'acceptation ? Quel est le statut du membre (`pending`, `accepted`, `rejected`) à chaque étape ?
>
> **Q7.** Quelle différence entre une image `shared` et une image `community` ? Qui peut rendre une image `public` et pourquoi cette opération est-elle réservée à ce rôle ?

---

## Partie 3 — Les gabarits (flavors)

```bash
openstack flavor list
```

Créez deux gabarits (avec les identifiants `admin`) :

```bash
openstack flavor create lab03.small  --vcpus 1 --ram 1024 --disk 5
openstack flavor create lab03.medium --vcpus 2 --ram 2048 --disk 8
```

Créez un gabarit privé, réservé au projet du Lab 03 (`project-lab03`) :

```bash
openstack flavor create lab03.private --vcpus 1 --ram 512 --disk 4 --private
openstack flavor set lab03.private --project project-lab03
```

> **Q8.** Peut-on lancer l'image Ubuntu avec le gabarit `m1.tiny` ? Testez puis expliquez le message obtenu en lien avec `--min-disk` et `--min-ram`.
>
> **Q9.** Dans le **premier terminal** (`admin`), comparez `openstack flavor list` et `openstack flavor list --all`. Dans le **second terminal** (`student-lab03`), lancez `openstack flavor list`. Où le gabarit `lab03.private` apparaît-il, et pourquoi ? À quoi sert un gabarit privé dans un cloud d'entreprise ?

---
## Partie 4 — Personnalisation au démarrage avec cloud-init


- **cloud-init** est l'outil standard de configuration des instances cloud au premier démarrage. Il est préinstallé dans la plupart des images cloud (Ubuntu, Debian, Fedora, CentOS…).
- Au boot, il interroge le service de métadonnées d'OpenStack (`http://169.254.169.254`) pour récupérer le nom d'hôte, la clé SSH et les **user-data** fournies à la création de l'instance (`--user-data`), puis il les applique.

- Les user-data peuvent prendre deux formes, toutes deux exécutées par cloud-init :

|                     | Script shell (`#!/bin/bash`)                                         | Cloud-config (`#cloud-config`, YAML)                                                                        |
| ------------------- | -------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| Approche            | **impérative** : vous écrivez *comment* faire, commande par commande | **déclarative** : vous décrivez *l'état voulu* (paquets, utilisateurs, fichiers…) et cloud-init s'en charge |
| Portabilité         | dépend de la distribution (`apt`, `dnf`, chemins…)                   | les modules cloud-init s'adaptent à la distribution                                                         |

### 4.1 Préparer le réseau et l'accès à l'instance

Toutes les commandes de cette partie sont exécutées sur l'instance EC2, avec les identifiants `admin` (premier terminal).

Placez-vous dans votre répertoire personnel : la clé et le fichier user-data y seront créés.

```bash
cd ~
```

#### a) Réseau privé, sous-réseau et routeur

```bash
openstack network create net-lab03
openstack subnet create subnet-lab03 \
    --network net-lab03 \
    --subnet-range 192.168.30.0/24 \
    --dns-nameserver 8.8.8.8
openstack router create router-lab03
openstack router set router-lab03 --external-gateway public
openstack router add subnet router-lab03 subnet-lab03
```

#### b) Groupe de sécurité

Autorisez SSH, HTTP et le ping :

```bash
openstack security group create sg-lab03 --description "SSH, HTTP et ICMP pour le Lab 03"
openstack security group rule create --protocol tcp --dst-port 22 sg-lab03
openstack security group rule create --protocol tcp --dst-port 80 sg-lab03
openstack security group rule create --protocol icmp sg-lab03
openstack security group rule list sg-lab03
```

#### c) Paire de clés

```bash
openstack keypair create key-lab03 > key-lab03.pem
chmod 600 key-lab03.pem
```

### 4.2 Écrire le fichier user-data

Le fichier doit être créé dans le même répertoire que la clé (votre répertoire personnel), car la commande `openstack server create` de la section 4.3 y fera référence :

```bash
cd ~
nano web-init.yaml
```

Collez le contenu suivant, puis enregistrez et quittez :

```yaml
#cloud-config
hostname: vm-web
write_files:
  - path: /var/www/index.html
    content: |
      <h1> Lab 03 - Instance configured with cloud-init </h1>
runcmd:
  - cd /var/www && nohup python3 -m http.server 80 > /var/log/web.log 2>&1 &
```

> **Attention à l'indentation :** le YAML est sensible aux espaces. Utilisez des espaces, jamais de tabulations.

Signification des directives :

| Directive       | Rôle                                                                                                                |
| --------------- | ------------------------------------------------------------------------------------------------------------------- |
| `#cloud-config` | Première ligne **obligatoire** : indique à cloud-init que le fichier est au format cloud-config (YAML)              |
| `hostname`      | Nom d'hôte attribué à la VM                                                                                         |
| `write_files`   | Crée des fichiers dans la VM (ici la page d'accueil du site)                                                        |
| `runcmd`        | Commandes exécutées en `root` à la fin du premier démarrage (ici, lancement d'un serveur web Python sur le port 80) |

Vérifiez le fichier :

```bash
ls -l web-init.yaml
cat web-init.yaml
sudo cloud-init schema --config-file web-init.yaml
```

La dernière commande valide la syntaxe du fichier avec l'outil cloud-init installé sur l'instance EC2. Le résultat attendu est `Valid schema web-init.yaml`.

> **Sécurité :** le contenu du user-data reste lisible par tout processus de la VM pendant toute sa durée de vie. N'y placez jamais de mot de passe, de clé privée ou de jeton d'accès.

### 4.3 Lancer l'instance

#### a) Créer l'instance

```bash
openstack server create vm-web \
    --image ubuntu-24.04-minimal \
    --flavor lab03.small \
    --network net-lab03 \
    --security-group sg-lab03 \
    --key-name key-lab03 \
    --user-data web-init.yaml \
    --wait
```

L'option `--wait` rend la main une fois l'instance `ACTIVE`. À ce stade, elle ne possède qu'une adresse **privée** (`192.168.30.x`).

#### b) Associer une IP flottante

L'IP flottante est une ressource Neutron distincte de l'instance : on la réserve dans le réseau `public`, puis on l'associe à la VM. L'adresse est enregistrée dans la variable `FIP`, réutilisée dans la suite du lab :

```bash
FIP=$(openstack floating ip create public -f value -c floating_ip_address)
openstack server add floating ip vm-web $FIP
echo $FIP
```

#### c) Suivre le démarrage

Le premier démarrage peut prendre plusieurs minutes. Relancez la commande suivante jusqu'à voir la ligne `Cloud-init v. ... finished` :

```bash
openstack console log show vm-web | grep -i cloud-init
```

#### d) Tester le service web

Définissez les fonctions `web` et `relaunch_web`, qui testent et relancent le serveur web :

```bash
web() {
  curl -sS -m 5 http://$FIP || echo "=> no response from the web server"
}

relaunch_web() {
  ssh -n -i ~/key-lab03.pem \
      -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
      ubuntu@$FIP \
      "cd /var/www && sudo nohup python3 -m http.server 80 > /tmp/web.log 2>&1 < /dev/null &" \
    && echo "=> web server restarted"
}
```

Vérifiez la connectivité et le service :

```bash
ping -c 3 $FIP
web
```

Le résultat attendu est la page `<h1> Lab 03 - Instance configured with cloud-init </h1>`.

**Diagnostic :** si `web` ne répond pas, le message d'erreur de `curl` indique où chercher :

| Erreur                                            | Signification                                            | Action                                                                                                                    |
| ------------------------------------------------- | -------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| Refus immédiat (*Failed to connect … after 0 ms*) | La VM répond, mais aucun service n'écoute sur le port 80 | Relancer le serveur : `relaunch_web` puis `web`                                                                           |
| Délai dépassé (*timed out*) ou ping sans réponse  | Problème réseau, ou VM pas encore démarrée               | Vérifier `br-ex` (voir [`common/README.md`](ssh-setup.md)), attendre la fin du démarrage (console), puis réessayer |

## Partie 5 — Cycle de vie d'une instance

Une instance passe par plusieurs états au cours de sa vie : active, arrêtée, en pause, suspendue, mise en réserve… Dans cette partie, vous allez déclencher chacune de ces opérations et observer leur effet à deux niveaux : **côté Nova** (ce qu'OpenStack enregistre) et **côté hyperviseur** (ce que libvirt fait réellement sur l'hôte).

Toutes les commandes sont exécutées sur l'instance EC2, avec les identifiants `admin`, dans le **même terminal qu'en Partie 4** (la variable `FIP` et les fonctions `web` et `relaunch_web` y sont déjà définies).

### Outils d'observation

**L'état vu par Nova**

```bash
openstack server show vm-web -f shell \
  -c status -c OS-EXT-STS:vm_state -c OS-EXT-STS:power_state \
  -c OS-EXT-STS:task_state -c OS-EXT-SRV-ATTR:instance_name
```

| Champ | Signification |
|---|---|
| `status` | statut résumé, affiché dans Horizon et `openstack server list` (`ACTIVE`, `SHUTOFF`, `PAUSED`…) |
| `vm_state` | état stable de l'instance enregistré par Nova |
| `power_state` | état d'alimentation remonté par l'hyperviseur (`Running`, `Paused`, `Shutdown`…) |
| `task_state` | opération en cours ; `None` quand aucune opération n'est en cours |
| `instance_name` | nom de l'instance côté libvirt (`instance-0000000X`) |

**L'état vu par l'hyperviseur (libvirt)**

```bash
sudo virsh list --all
```

`virsh` est l'outil en ligne de commande de libvirt : il interroge directement l'hyperviseur, sans passer par OpenStack. libvirt ne connaît pas le nom `vm-web` : repérez la ligne dont la colonne **Name** correspond au champ `instance_name` ci-dessus.

- La colonne **State** donne l'état libvirt de l'instance : `running`, `paused` ou `shut off`.
- La colonne **Id** indique si le processus QEMU de l'instance tourne : un numéro s'il est en cours d'exécution, `-` s'il est arrêté.

**Fonction `state`**

Pour éviter de retaper ces deux commandes après chaque opération, regroupez-les dans une fonction :

```bash
state() {
  openstack server show vm-web -f shell \
    -c status -c OS-EXT-STS:vm_state -c OS-EXT-STS:power_state \
    -c OS-EXT-STS:task_state -c OS-EXT-SRV-ATTR:instance_name
  sudo virsh list --all
}
```

### 5.1 Consignes

- Pour chaque opération, relevez le **statut Nova**, le `vm_state`, le `power_state` et l'**état libvirt** : ces valeurs serviront à compléter la Q10.
- **Attendez la fin de chaque opération.** Les commandes de cycle de vie rendent la main avant la fin de l'opération. Relancez `state` jusqu'à ce que `task_state` vaille `None` avant de passer à la commande suivante, sinon vous obtiendrez une erreur `409 Conflict`.
- **Testez le serveur web après chaque opération inverse** (`start`, `unpause`, `resume`, `unshelve`, `reboot`) avec `web`. S'il ne répond pas, notez-le pour la Q10, puis relancez-le avec `relaunch_web` avant de passer à l'opération suivante.

> **Nouveau terminal ?** Les fonctions `web`, `relaunch_web` et `state` ainsi que la variable `FIP` n'existent que dans le terminal où elles ont été définies. Redéfinissez-les avant de continuer.

#### a) Arrêt et redémarrage

```bash
openstack server stop vm-web
state                                 # attendre : SHUTOFF, task_state None
openstack server start vm-web
state                                 # attendre : ACTIVE
web
```

#### b) Pause

```bash
openstack server pause vm-web
state
openstack server unpause vm-web
state
web
```

#### c) Suspension

```bash
openstack server suspend vm-web
state
openstack server resume vm-web
state
web
```

#### d) Mise en réserve (shelve)

La commande `openstack server shelve` met une instance « sur l'étagère » : l'instance est arrêtée puis **retirée du serveur de calcul**, afin de libérer les ressources (vCPU, RAM, disque local) qu'elle y occupait. Elle continue pourtant d'exister pour OpenStack : elle reste visible dans `openstack server list` et conserve son identité (UUID, nom, adresses IP, paire de clés). La commande inverse, `openstack server unshelve`, la fait revenir sur un serveur de calcul et la redémarre.

C'est l'opération adaptée à une instance qu'on n'utilisera pas pendant longtemps, mais qu'on souhaite retrouver telle quelle plus tard. Observez attentivement ce qui change dans Nova, dans libvirt **et** dans Glance.

```bash
openstack server shelve vm-web
state                                 # attendre : SHELVED_OFFLOADED
openstack image list                  # une nouvelle image est apparue
openstack server unshelve vm-web
state                                 # attendre : ACTIVE
openstack image list
web
```

#### e) Redémarrages

```bash
openstack server reboot --soft vm-web
state
openstack server reboot --hard vm-web
state
web
```

> **Q10.** Complétez le tableau suivant à partir de vos observations :

| Opération | Statut Nova (`status`) | État libvirt (colonne **State** de `virsh`) | Processus QEMU en cours ? (colonne **Id** de `virsh`) | Serveur web actif après l'opération inverse ? |
| --------- | ---------------------- | ------------------------------------------- | ----------------------------------------------------- | --------------------------------------------- |
| stop      |                        |                                             |                                                       |                                               |
| pause     |                        |                                             |                                                       |                                               |
| suspend   |                        |                                             |                                                       |                                               |
| shelve    |                        |                                             |                                                       |                                               |

> **Q11.** Après `unpause` et `resume`, le serveur web répond sans avoir été relancé ; après `start` et `unshelve`, il faut le relancer. Comment l'expliquez-vous ? Pour `pause` et `suspend`, où le contenu de la mémoire de l'instance est-il conservé ?

> **Q12.** Après `shelve`, une nouvelle image apparaît dans Glance. Pourquoi ? Que se passe-t-il au moment du `unshelve` ?
>
> **Q13.** Différence entre `reboot --soft` et `reboot --hard` ?

### 5.2 Redimensionnement (resize)

Redimensionnez l'instance vers le gabarit `lab03.medium`, puis **annulez** l'opération :

```bash
openstack server resize --flavor lab03.medium vm-web
state                                 # attendre : VERIFY_RESIZE, task_state None
openstack server resize revert vm-web
state                                 # attendre : ACTIVE — quel est le gabarit ?
```

Recommencez, puis **confirmez** cette fois :

```bash
openstack server resize --flavor lab03.medium vm-web
state                                 # attendre : VERIFY_RESIZE, task_state None
openstack server resize confirm vm-web
state                                 # ACTIVE avec lab03.medium
```

Essayez enfin de redimensionner vers un gabarit dont le disque est **plus petit** :

```bash
openstack server resize --flavor m1.tiny vm-web
openstack image show ubuntu-24.04-minimal -c min_disk
```

> **Q14.** Quel est le statut de l'instance juste après le resize, avant confirmation ? Que permettent `openstack server resize revert` et `openstack server resize confirm` ?
>
> **Q15.** Que se passe-t-il lors du redimensionnement vers `m1.tiny` et pourquoi ? Comparez la taille minimale indiquée dans le message d'erreur avec le `min_disk` de l'image Ubuntu : pourquoi ces deux valeurs diffèrent-elles ?

---

## Partie 6 — Snapshots d'instance

Connectez-vous à la VM et ajoutez une ligne à la page d'accueil :

```bash
ssh -i ~/key-lab03.pem ubuntu@$FIP
```

Dans la VM :

```bash
echo "<p> Changed after boot </p>" | sudo tee -a /var/www/index.html
exit
```

De retour sur l'instance EC2, vérifiez la modification, puis prenez un snapshot :

```bash
web
openstack server image create vm-web --name snap-vm-web --wait
openstack image show snap-vm-web -c status -c size -c min_disk -c properties
```

Lancez une nouvelle instance à partir du snapshot, **sans user-data**, et associez-lui une IP flottante :

```bash
openstack server create vm-web-clone \
    --image snap-vm-web \
    --flavor lab03.medium \
    --network net-lab03 \
    --security-group sg-lab03 \
    --key-name key-lab03 \
    --wait

FIP_CLONE=$(openstack floating ip create public -f value -c floating_ip_address)
openstack server add floating ip vm-web-clone $FIP_CLONE
echo $FIP_CLONE
```

Attendez la fin du démarrage (`openstack console log show vm-web-clone | tail -5`), puis testez le clone :

```bash
ping -c 3 $FIP_CLONE
curl -sS -m 5 http://$FIP_CLONE
ssh -i ~/key-lab03.pem ubuntu@$FIP_CLONE "cat /var/www/index.html"
```

> **Q16.** Le clone contient-il la modification faite à la main ? Le serveur web est-il démarré automatiquement ? Expliquez.

---

## Nettoyage

Supprimez toutes les ressources créées pendant ce lab avec le script fourni, depuis le **premier terminal** (`admin`) :

```bash 
source ~/devstack/openrc admin admin bash clean_lab03.sh 
``` 

> L'ordre compte : une ressource ne peut être supprimée tant qu'une autre en dépend (instance → IP flottante → routeur → réseau…). De plus, supprimer un projet **ne supprime pas** ses ressources : elles resteraient orphelines. Ouvrez `cleanup.sh` pour voir l'ordre suivi. 
> 

### Nettoyage manuel (si le script échoue ou pour procéder étape par étape)

### a) Instances, images et IP flottantes

```bash
openstack server delete vm-web vm-web-clone --wait
openstack image delete snap-vm-web ubuntu-24.04-minimal

# IP flottantes du lab (supprimer une instance ne les libère pas)
openstack floating ip delete $FIP $FIP_CLONE
```

> Si les variables `FIP` et `FIP_CLONE` ont été perdues (nouveau terminal), repérez les IP flottantes non associées avec `openstack floating ip list --status DOWN`, puis supprimez-les par leur ID.

### b) Réseau et accès

```bash
# Routeur, puis réseau (le sous-réseau est supprimé avec le réseau)
openstack router remove subnet router-lab03 subnet-lab03
openstack router unset --external-gateway router-lab03
openstack router delete router-lab03
openstack network delete net-lab03

# Groupe de sécurité, paire de clés et fichiers locaux
openstack security group delete sg-lab03
openstack keypair delete key-lab03
rm -f ~/key-lab03.pem ~/web-init.yaml
```

### c) Gabarits, utilisateur et projet

```bash
openstack flavor delete lab03.small lab03.medium lab03.private

# Groupe de sécurité "default" créé automatiquement dans le projet
openstack security group delete $(openstack security group list --project project-lab03 -f value -c ID)

openstack user delete student-lab03
openstack project delete project-lab03
```

### d) Vérification

```bash
openstack server list --all-projects
openstack floating ip list
openstack router list
openstack network list
openstack image list
openstack flavor list
```

Seules les ressources d'origine de DevStack doivent apparaître (réseaux `public`, `private`, `shared`, image `cirros`, gabarits `m1.*`…).

> Le fichier `ubuntu-24.04-minimal-cloudimg-amd64.img` peut être conservé : il évitera un nouveau téléchargement en cas de besoin.
