# Lab 04 — Services de stockage : OpenStack Cinder et Swift

## Table des matières

- [Scénario](#scénario)
- [Partie 1 — Préparer l'environnement](#partie-1--préparer-lenvironnement)
- [Partie 2 — Concepts : stockage bloc et stockage objet](#partie-2--concepts--stockage-bloc-et-stockage-objet)
- [Partie 3 — Publier les fichiers du site dans Swift](#partie-3--publier-les-fichiers-du-site-dans-swift)
- [Partie 4 — Créer l'instance web et son volume](#partie-4--créer-linstance-web-et-son-volume)
- [Partie 5 — Préparer le volume dans l'instance](#partie-5--préparer-le-volume-dans-linstance)
- [Partie 6 — Déployer le site depuis Swift](#partie-6--déployer-le-site-depuis-swift)
- [Partie 7 — Prouver la persistance](#partie-7--prouver-la-persistance)
- [Partie 8 — Protéger les données : snapshot et sauvegarde](#partie-8--protéger-les-données--snapshot-et-sauvegarde)
- [Partie 9 — Nettoyage](#partie-9--nettoyage)

---

## Avant de commencer

1. Connectez-vous à votre instance EC2 avec `ssh devstack`. Si ce n'est pas encore configuré sur votre machine, suivez [common/ssh-setup.md](../common/ssh-setup.md).
2. Si votre instance EC2 a été redémarrée depuis la dernière séance, remettez DevStack en état : [common/restore-after-reboot.md](../common/restore-after-reboot.md), étapes 1 à 4.
3. Vérifiez qu'aucune ressource des labs précédents ne subsiste : même fichier, étape 5.
## Scénario

Vous devez déployer un petit site web sur une instance OpenStack, avec deux exigences :

- les **fichiers du site** sont publiés dans un espace de stockage accessible par HTTP, d'où n'importe quelle instance peut les récupérer → **Swift** (stockage objet) ;
- les **données du serveur** ne doivent pas disparaître si l'instance est supprimée → **Cinder** (stockage bloc).

---

## Partie 1 — Préparer l'environnement

Swift (stockage objet) et le service de sauvegarde de Cinder ne sont pas encore installés. On les ajoute, puis on réinstalle DevStack.

>  La réinstallation **remet à zéro toutes les bases OpenStack**

### 1.1 Modifier `local.conf`

```bash
cd ~/devstack
grep -n '^\[\[' local.conf      # liste les sections du fichier
nano local.conf
```

**Si `[[local|localrc]]` est la seule section, ajoutez les lignes à la fin du fichier ; sinon, juste avant la deuxième section.**

```ini
# Lab 04 - stockage objet (Swift) et sauvegardes Cinder
enable_service s-proxy s-object s-container s-account
enable_service c-bak
SWIFT_HASH=lab04swifthash2026
SWIFT_REPLICAS=1
```

> `SWIFT_HASH` sert à calculer l'emplacement des objets. Ne le modifiez jamais une fois Swift installé, sinon les objets existants deviennent introuvables.

### 1.2 Réinstaller dans `tmux`

```bash
tmux new -s stack
cd ~/devstack
./unstack.sh
./stack.sh
```

L'installation dure environ 20 minutes. Si la connexion SSH coupe : reconnectez-vous puis `tmux attach -t stack`.

> **Pendant l'installation, faites la partie 2.**

### 1.3 Vérifier

```bash
source ~/devstack/openrc admin admin
openstack service list | grep -Ei "cinder|volume|swift|object"   # services de stockage enregistrés
openstack volume service list                                    # état des services Cinder
openstack object store account show                              # compte Swift du projet
grep -i backup /etc/cinder/cinder.conf                           # configuration des sauvegardes
openstack network list                                           # réseaux recréés
ip addr show br-ex                                               # le pont externe a son adresse
```

| Commande | Attendu |
|---|---|
| `openstack service list` | `cinderv3` (block-storage) et `swift` (object-store) |
| `openstack volume service list` | `cinder-scheduler`, `cinder-volume`, `cinder-backup` à l'état `up` |
| `openstack object store account show` | compte `AUTH_<id>`, 0 conteneur |
| `grep -i backup` | `backup_driver = cinder.backup.drivers.swift.SwiftBackupDriver`, `backup_swift_url` vers le port 8080 |
| `openstack network list` | réseaux `public` et `private` |
| `ip addr show br-ex` | une adresse `172.24.4.1/24` sur le pont |

Dans Horizon, un menu **Project → Object Store → Containers** doit apparaître.

---

## Partie 2 — Concepts : stockage bloc et stockage objet

### 2.1 Deux façons de stocker des données

| | Stockage **bloc** (Cinder) | Stockage **objet** (Swift) |
|---|---|---|
| Ce qu'on manipule | un disque virtuel | des fichiers entiers (objets) avec des métadonnées |
| Accès | attaché à **une** instance, vu comme `/dev/vdb` | par **HTTP** (GET, PUT, DELETE), depuis n'importe où |
| Utilisation | on le formate, on le monte, on y écrit comme sur un disque | on dépose et on récupère des objets complets |
| Modifier une partie | oui, octet par octet | non : il faut renvoyer l'objet entier |
| Latence | faible | plus élevée (requêtes HTTP) |
| Cas typiques | base de données, système de fichiers d'un serveur | images, sauvegardes, archives, fichiers statiques d'un site |
| Équivalent AWS | EBS | S3 |

### 2.2 Cinder : volumes, snapshots, sauvegardes

- **Volume** : disque persistant, indépendant de l'instance. On peut le détacher et le rattacher à une autre instance, mais à une seule à la fois.
- **Snapshot** : copie en lecture seule d'un volume à un instant donné. Elle reste dans le même backend que le volume et sert à créer de nouveaux volumes.
- **Sauvegarde (backup)** : copie complète du volume exportée **vers Swift**. Elle survit même si le backend Cinder est perdu.

> **Provisionnement fin (*thin provisioning*)** : la taille d'un volume est une taille *promise*, pas une taille réservée. Le backend n'alloue l'espace réel qu'au moment où des données sont effectivement écrites. Un volume de 2 Gio vide n'occupe donc presque rien sur l'hyperviseur.

### 2.3 Swift : compte, conteneur, objet

Swift organise les données sur trois niveaux :

```
Compte (= projet OpenStack)          AUTH_<id du projet>
 └── Conteneur                       web-site
      └── Objet                      site.tar.gz
```

Chaque objet a une adresse HTTP qui reflète cette hiérarchie :

```
http://<IP>:8080/v1/AUTH_<id_projet>/<conteneur>/<objet>
```

Il n'y a **pas de vrais dossiers** dans un conteneur : le premier segment après le compte est le conteneur, et **tout le reste** est le nom de l'objet.

```
/v1/AUTH_abc123/web-site/images/logo.png
    └─ compte ─┘└conteneur┘└──── objet ───┘
```

Ici, le conteneur est `web-site` et l'objet s'appelle `images/logo.png` : c'est **un seul objet** dont le nom contient un `/`. Il n'existe pas d'objet ou de dossier `images` séparé ; Horizon l'affiche comme un dossier uniquement pour le confort de lecture.

L'accès à un conteneur est contrôlé par une liste de contrôle d'accès (ACL) : un conteneur **privé** exige un jeton Keystone ; un conteneur **public** est lisible par tous.

### Questions — Partie 2

**Q2.1** — Pour chacun des besoins suivants, choisissez bloc ou objet et justifiez en une phrase :
a) les fichiers de données d'une base PostgreSQL ;
b) 50 000 photos téléversées par les utilisateurs d'une application ;
c) les journaux (logs) archivés chaque nuit ;
d) le système de fichiers où un serveur web écrit ses fichiers temporaires.

**Q2.2** — Quelle différence faites-vous entre un snapshot et une sauvegarde ? Lequel protège contre une panne du serveur qui héberge les volumes ?

**Q2.3** — Dans Swift, on ne peut pas renommer ni modifier une partie d'un objet. Comment feriez-vous pour « renommer » `rapport.pdf` en `rapport-final.pdf` ?

**Q2.4** — Le compte Swift s'appelle `AUTH_<id du projet>`. Qu'est-ce que cela implique pour deux projets qui créent chacun un conteneur `web-site` ?

---

## Partie 3 — Publier les fichiers du site dans Swift

Objectif : déposer l'archive du site dans un conteneur public, pour que n'importe quelle instance puisse la télécharger par HTTP.

### 3.1 Préparer le site (sur votre PC)

Créez un dossier `site` contenant un fichier `index.html`. Remplacez `[LAST NAME First Name]` et `[group]` par vos informations :

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Lab 04 — Persistent Service</title>
</head>
<body>
  <h1>Lab 04 — Persistent Service</h1>
  <p>Name: <strong>[LAST NAME First Name]</strong> — Group: <strong>[group]</strong></p>
  <p>Files served from a Cinder volume, deployed from Swift.</p>
</body>
</html>
```

Créez l'archive (la commande `tar` existe sous Windows 10/11, Linux et macOS) :

```bash
tar czf site.tar.gz site      # compresse le dossier "site" dans l'archive site.tar.gz
```

### 3.2 Créer un conteneur public

Dans Horizon : **Project → Object Store → Containers → + Container**.

- Container Name : `web-site`
- Storage Policy : laissez **Policy-0** (politique par défaut)
- Container Access : cliquez sur **Public** (l'option sélectionnée apparaît en gris foncé ; par défaut, c'est **Not public**).

Créez aussi un second conteneur nommé `private`, en laissant **Not public**.

> Une **politique de stockage** est à Swift ce que le type de volume est à Cinder : chaque politique peut définir un nombre de réplicas, des disques ou une méthode de protection différents. Elle est fixée à la création du conteneur et ne peut plus être modifiée. DevStack crée `Policy-0` et `silver`, identiques ici puisque notre installation n'a qu'un nœud.

### 3.3 Téléverser des objets

1. Ouvrez le conteneur `web-site`, cliquez sur l'icône **Upload File** et envoyez `site.tar.gz`.
2. Toujours dans `web-site`, créez un **dossier** `docs` (bouton **+ Folder**), puis téléversez-y n'importe quel petit fichier (par exemple `index.html`).
3. Téléversez le même `index.html` dans le conteneur `private`.

### 3.4 Accéder aux objets par HTTP

Dans Horizon, ouvrez les détails du conteneur `web-site` et copiez le **Public URL**. Il a la forme :

```
http://<Private_IP_EC2>:8080/v1/AUTH_<project_id>/web-site
```

- `<Private_IP_EC2>` : l'adresse IP privée de votre instance EC2 ;
- `8080` : le port du proxy Swift ;
- `v1` : la version de l'API Swift (identique pour tous) ;
- `AUTH_<project_id>` : le compte Swift, c'est-à-dire l'identifiant de votre projet précédé de `AUTH_`.

Sur l'instance EC2, en SSH, définissez la variable `URL` avec ce lien **sans** le `/web-site` final :

```bash
URL=http://<Private_IP_EC2>:8080/v1/AUTH_<project_id>   # remplacez par les valeurs de votre lien

curl $URL/web-site                    # liste les objets du conteneur public
curl -I $URL/web-site/site.tar.gz     # en-têtes de l'objet : code HTTP, taille, ETag
curl -I $URL/private/index.html       # même requête sur le conteneur privé
```

### Questions — Partie 3

**Q3.1** — Comparez l'identifiant `AUTH_<id>` du lien public avec l'identifiant de votre projet (Horizon → **Identity → Projects**). Que constatez-vous ?

**Q3.2** — Que renvoie `curl $URL/web-site` ? Comment apparaît l'objet que vous avez placé dans le dossier `docs` ? Que confirme ce nom sur la notion de dossier dans Swift ?

**Q3.3** — Relevez le code HTTP renvoyé pour `site.tar.gz` et pour `private/index.html`. Expliquez la différence.

**Q3.4** — Dans les en-têtes de `site.tar.gz`, relevez `Content-Length` et `Etag`. À quoi sert l'`Etag` ? (Indice : comparez-le avec `md5sum site.tar.gz`.)

**Q3.5** — Pourquoi est-il pratique, pour la suite du lab, que l'archive soit dans un conteneur **public** ? Quel risque cela présenterait-il pour des données sensibles ?

---

## Partie 4 — Créer l'instance web et son volume

Objectif : lancer une instance Debian accessible en SSH, puis lui attacher un volume Cinder qui contiendra les données du site.

### 4.1 Ajouter l'image Debian (administrateur, en CLI)

CirrOS est trop limitée pour faire tourner un serveur web. On ajoute une image Debian 12, publique pour tous les projets. Sur l'instance EC2 :

```bash
cd ~
wget https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2   # image cloud officielle (~350 Mo)

source ~/devstack/openrc admin admin
openstack image create debian-12 \
  --file debian-12-genericcloud-amd64.qcow2 \
  --disk-format qcow2 --container-format bare \
  --public                                       # visible par tous les projets
```

Dans Horizon (connecté en `demo`) : **Project → Compute → Images**. L'image `debian-12` doit apparaître avec la visibilité **Public**.

### 4.2 Vérifier le réseau du projet

DevStack a déjà créé un réseau pour le projet `demo`. Ouvrez **Project → Network → Network Topology** et repérez :

- le réseau `private` (réseau du projet) ;
- le routeur `router1` ;
- le réseau externe `public`, auquel `router1` est relié.

> Le réseau Neutron `private` n'a aucun lien avec le conteneur Swift `private` créé en partie 3 : ce sont deux services différents.

### 4.3 Créer un groupe de sécurité pour le serveur web

**Project → Network → Security Groups → + Create Security Group**

- Name : `web-sg`

Puis **Manage Rules → + Add Rule**, trois fois :

| Rule | Remote | CIDR |
|---|---|---|
| SSH | CIDR | `0.0.0.0/0` |
| HTTP | CIDR | `0.0.0.0/0` |
| All ICMP | CIDR | `0.0.0.0/0` |

### 4.4 Créer la paire de clés

La connexion SSH à l'instance se fera **depuis l'EC2** (les IP flottantes ne sont joignables que depuis l'EC2). On génère donc la clé sur l'EC2, puis on importe sa partie publique dans OpenStack.

```bash
ssh-keygen -t ed25519 -f ~/.ssh/lab04-key -N ""   # crée la paire de clés, sans phrase de passe
cat ~/.ssh/lab04-key.pub                          # affiche la clé publique à copier
```

**Project → Compute → Key Pairs → Import Public Key**

- Key Pair Name : `lab04-key`
- Key Type : SSH Key
- Public Key : collez le contenu affiché par `cat`

> **Note : Deux façons d'obtenir une paire de clés**
> Aux labs précédents, vous avez utilisé :

```bash
openstack keypair create mykey > mykey.pem
```

> Ici, on procède autrement :

```bash
ssh-keygen -t ed25519 -f ~/.ssh/lab04-key -N ""      # génère la paire localement
# puis import de la clé publique (Horizon → Import Public Key)
```

| | `openstack keypair create` | `ssh-keygen` + import |
|---|---|---|
| Qui génère la paire ? | **Nova** (le serveur OpenStack) | **vous**, sur votre machine |
| Clé privée | produite côté serveur, puis renvoyée par l'API | créée localement, ne quitte jamais la machine |
| Ce que reçoit OpenStack | la paire complète, le temps de la générer | **uniquement la clé publique** |
| Si vous perdez le `.pem` | impossible de le récupérer | idem, mais la clé reste dans `~/.ssh` |
| Statut | ancienne méthode, retirée des versions récentes de l'API Nova (microversion 2.92 et suivantes) | méthode recommandée |

> **À retenir :** une clé privée ne devrait jamais être générée ni transiter ailleurs que chez son propriétaire. Avec `ssh-keygen`, OpenStack ne voit jamais votre clé privée : il ne fait qu'injecter la clé publique dans l'instance au démarrage.

### 4.5 Lancer l'instance

**Project → Compute → Instances → Launch Instance**

| Onglet          | Valeur                                                                            |
| --------------- | --------------------------------------------------------------------------------- |
| Details         | Instance Name : `web-01`                                                          |
| Source          | Select Boot Source : **Image** ; Create New Volume : **No** ; image : `debian-12` |
| Flavor          | `m1.small`                                                                        |
| Networks        | `private`                                                                         |
| Security Groups | `web-sg` (retirez `default`)                                                      |
| Key Pair        | `lab04-key`                                                                       |

> **Create New Volume : No** est important : le disque système de l'instance sera **éphémère**, il disparaîtra avec elle. C'est ce qui rendra la démonstration de persistance de la partie 7 significative.

Attendez l'état **Running**.

### 4.6 Allouer et associer une IP flottante, puis tester SSH

**Étape 1 — Allouer une IP flottante au projet**

**Project → Network → Floating IPs → Allocate IP To Project**

- Pool : `public`
- **Allocate IP**

L'adresse apparaît dans la liste, sans instance associée (**Mapped Fixed IP Address** vide).

**Étape 2 — L'associer à l'instance**

Sur la ligne de cette adresse : **Associate**

- Port to be associated : `web-01` (avec son adresse sur le réseau `private`)
- **Associate**

Dans **Project → Compute → Instances**, `web-01` affiche maintenant deux adresses : son adresse fixe sur `private` et son IP flottante.

**Étape 3 — Tester SSH depuis l'EC2**

```bash
ssh -i ~/.ssh/lab04-key debian@<floating_IP>   # l'utilisateur par défaut de l'image Debian est "debian"
```

Une fois connecté, tapez `exit` pour revenir sur l'EC2.

### 4.7 Créer et attacher le volume de données

**Project → Volumes → Volumes → + Create Volume**

| Champ         | Valeur                  |
| ------------- | ----------------------- |
| Volume Name   | `data-web`              |
| Volume Source | No source, empty volume |
| Type          | `lvmdriver-1`           |
| Size (GiB)    | `2`                     |

Observez la colonne **Status** pendant la création.

Puis, sur la ligne de `data-web` : menu déroulant **→ Manage Attachments → Attach to Instance : `web-01` → Attach Volume**.

Observez de nouveau **Status** et la colonne **Attached To**.

### Questions — Partie 4

**Q4.1** — Pourquoi avoir choisi **Create New Volume : No** au lancement de l'instance ? Où se trouve alors son disque système, et que deviendra-t-il si l'instance est supprimée ?

**Q4.2** — Relevez les états successifs du volume `data-web`, de sa création jusqu'à la fin de l'attachement. Que signifie chacun d'eux ?

**Q4.3** — Quel nom de périphérique Horizon indique-t-il dans **Attached To** ? Notez-le : vous le vérifierez depuis l'intérieur de l'instance en partie 5.

**Q4.4** — Le volume fait 2 Gio. En repensant au provisionnement fin (section 2.2), combien d'espace réel pensez-vous qu'il occupe à ce stade sur l'hyperviseur ? (Vous le vérifierez en 5.6.)

---

## Partie 5 — Préparer le volume dans l'instance

Objectif : faire du volume `data-web` un disque utilisable par le serveur, monté sur `/data`.

Connectez-vous à l'instance depuis l'EC2 :

```bash
ssh -i ~/.ssh/lab04-key debian@<floating_IP>
```

### 5.1 Identifier le disque attaché

```bash
lsblk                         # liste les disques : vda (système) et un nouveau disque de 2G
ls -l /dev/disk/by-id/        # liens vers les disques, nommés d'après leur identifiant
```

Dans Horizon, ouvrez **Project → Volumes → Volumes → data-web** et relevez son **ID**. Comparez-le avec le lien `virtio-...` affiché par `ls -l /dev/disk/by-id/`.

### 5.2 Formater le volume

Le volume est vide : il n'a pas encore de système de fichiers. On le formate en ext4, en lui donnant l'étiquette `data` :

```bash
sudo mkfs.ext4 -L data /dev/vdb      # crée un système de fichiers ext4 étiqueté "data" (remplacez vdb si lsblk indique un autre nom)
```

> Le formatage efface tout le contenu du disque. On ne le fait **qu'une seule fois**, sur un volume neuf. Vous ne devrez **jamais** le refaire dans la suite du lab.

### 5.3 Monter le volume

```bash
sudo mkdir /data                     # crée le point de montage
sudo mount LABEL=data /data          # monte le volume repéré par son étiquette
df -h /data                          # vérifie : environ 2G disponibles sur /data
```

### 5.4 Rendre le montage permanent

Sans configuration, le volume ne serait plus monté après un redémarrage de l'instance. On ajoute une ligne à `/etc/fstab` :

```bash
echo 'LABEL=data /data ext4 defaults,nofail 0 2' | sudo tee -a /etc/fstab   # ajoute la ligne à la fin du fichier
cat /etc/fstab                                                             # vérifie l'ajout
sudo systemctl daemon-reload
```

Testez la configuration en démontant puis en remontant tout ce qui est déclaré dans `fstab` :

```bash
sudo umount /data
sudo mount -a                        # monte tout ce qui est déclaré dans /etc/fstab
df -h /data                          # /data doit être de nouveau monté
```

### 5.5 Laisser une preuve sur le volume

Écrivez un fichier qui indique où et quand il a été créé. Il servira de preuve en partie 7 :

```bash
echo "File created on $(date) by instance $(hostname)" | sudo tee /data/proof.txt
cat /data/proof.txt
```

### 5.6 Observer l'espace réellement occupé (sur l'EC2)

Quittez l'instance (`exit`) et, sur l'EC2 :

```bash
sudo lvs          # volumes logiques LVM : chaque volume Cinder apparaît sous le nom volume-<ID>
```

Repérez la ligne `volume-<ID de data-web>` : la colonne `LSize` donne la taille annoncée, la colonne `Data%` le pourcentage réellement occupé.

> Si `Data%` est vide, le backend n'utilise pas le provisionnement fin : tout l'espace est réservé dès la création.

### Questions — Partie 5

**Q5.1** — Quel nom porte le volume dans `lsblk` ? Est-ce le même que celui indiqué par Horizon dans **Attached To** (Q4.3) ? Pourquoi ne peut-on pas toujours se fier à ce nom ?

**Q5.2** — Comparez le lien `virtio-...` de `/dev/disk/by-id/` avec l'ID du volume dans Horizon. Que constatez-vous ? En quoi est-ce utile quand plusieurs volumes sont attachés à la même instance ?

**Q5.3** — Dans `/etc/fstab`, on a utilisé `LABEL=data` plutôt que `/dev/vdb`. Pourquoi est-ce plus sûr ?

**Q5.4** — À quoi sert l'option `nofail` ? Que se passerait-il sans elle si l'instance redémarrait alors que le volume a été détaché ?

**Q5.5** — Le système de fichiers ext4 a été créé **à l'intérieur de l'instance**. D'après vous, Cinder sait-il que ce volume contient un système de fichiers ext4 ? Justifiez avec la notion de stockage bloc vue en partie 2.

---

## Partie 6 — Déployer le site depuis Swift

Objectif : récupérer l'archive du site depuis Swift, la décompresser **sur le volume** `/data`, et la faire servir par nginx.

Toutes les commandes de cette partie s'exécutent **dans l'instance** `web-01`, sauf indication contraire.

### 6.1 Installer nginx

```bash
sudo apt update                      # met à jour la liste des paquets
sudo apt install -y nginx            # installe le serveur web
sudo systemctl status nginx --no-pager    # nginx doit être "active (running)"
```

>  **Si `apt update` échoue** (pas d'accès Internet depuis l'instance) :
> - testez `ping -c 2 8.8.8.8` (accès réseau) puis `getent hosts deb.debian.org` (résolution DNS) ;
> - si le ping échoue, l'EC2 ne fait plus la traduction d'adresses pour le réseau public, ce qui arrive souvent après un redémarrage de l'EC2. Sur l'EC2 : `sudo iptables -t nat -A POSTROUTING -s 172.24.4.0/24 -j MASQUERADE` ;
> - si seul le DNS échoue : dans Horizon, **Project → Network → Networks → private → Subnets → Edit Subnet → Subnet Details → DNS Name Servers** : `8.8.8.8`, puis redémarrez l'instance.

### 6.2 Télécharger l'archive depuis Swift

L'archive est dans un conteneur **public** : un simple `curl` suffit, sans jeton Keystone. Utilisez l'URL de la partie 3 :

```bash
cd ~
curl -O http://<Private_IP_EC2>:8080/v1/AUTH_<project_id>/web-site/site.tar.gz   # -O : garde le nom du fichier distant
ls -lh site.tar.gz                                                               # vérifie la taille
md5sum site.tar.gz                                                               # empreinte du fichier reçu
```

### 6.3 Décompresser le site sur le volume

```bash
sudo tar xzf site.tar.gz -C /data    # décompresse l'archive dans /data
ls -l /data /data/site               # contenu du volume, puis du dossier du site : on doit trouver /data/site/index.html
```

### 6.4 Configurer nginx pour servir `/data/site`

Par défaut, nginx sert `/var/www/html`, qui se trouve sur le disque système (éphémère). On le fait pointer vers le volume :

```bash
sudo sed -i 's#root /var/www/html;#root /data/site;#' /etc/nginx/sites-available/default   # change le dossier servi
grep -n 'root ' /etc/nginx/sites-available/default                                          # vérifie : root /data/site;
sudo nginx -t                                                                               # vérifie la syntaxe de la configuration
sudo systemctl reload nginx                                                                 # applique la configuration
```

### 6.5 Tester le site

Depuis l'instance :

```bash
curl http://localhost                # doit afficher le code HTML de votre page
```

Depuis l'EC2 (tapez `exit` pour quitter l'instance) :

```bash
curl http://<floating_IP>            # même résultat, cette fois via l'IP flottante
```

### Questions — Partie 6

**Q6.1** — Le téléchargement de `site.tar.gz` depuis l'instance n'a demandé aucune authentification. Pourquoi ? Que faudrait-il faire si l'archive était dans le conteneur `private` ?

**Q6.2** — Comparez l'empreinte `md5sum` obtenue dans l'instance avec l'`Etag` relevé en Q3.4. Que garantit cette comparaison ?

**Q6.3** — L'instance a l'adresse `10.0.0.x` et le proxy Swift écoute sur l'adresse privée de l'EC2. Décrivez le chemin suivi par la requête `curl` (réseau `private`, routeur, réseau `public`, `br-ex`, EC2). Sur l'EC2, la commande `sudo journalctl -u devstack@s-proxy --no-pager | grep site.tar.gz` montre l'adresse source vue par Swift : laquelle est-ce, et pourquoi ?

**Q6.4** — nginx est installé sur le disque système, le site sur le volume. Si l'on supprimait l'instance maintenant, qu'est-ce qui serait perdu et qu'est-ce qui serait conservé ?

---

## Partie 7 — Prouver la persistance

Objectif : supprimer l'instance `web-01`, en lancer une nouvelle, lui rattacher le volume `data-web`… et retrouver le site intact, sans rien télécharger ni reformater.

### 7.1 Détacher proprement le volume

Dans l'instance `web-01`, démontez d'abord le système de fichiers, pour que toutes les écritures en attente soient enregistrées sur le volume :

```bash
sudo umount /data                    # termine les écritures et libère le volume
exit
```

Dans Horizon : **Project → Volumes → Volumes →** ligne `data-web` **→ Manage Attachments → Detach Volume**.

Observez l'évolution de la colonne **Status**.

### 7.2 Supprimer l'instance

**Project → Compute → Instances →** ligne `web-01` **→ Delete Instance**.

Vérifiez ensuite :

- **Project → Volumes → Volumes** : `data-web` existe toujours ;
- **Project → Network → Floating IPs** : l'IP flottante est toujours allouée au projet, mais n'est plus associée à aucune instance.

### 7.3 Lancer une nouvelle instance avec un script cloud-init

**Project → Compute → Instances → Launch Instance**, avec les mêmes paramètres qu'en 4.5, sauf le nom :

| Onglet          | Valeur                                         |
| --------------- | ---------------------------------------------- |
| Details         | Instance Name : `web-02`                       |
| Source          | Image `debian-12` ; Create New Volume : **No** |
| Flavor          | `m1.small`                                     |
| Networks        | `private`                                      |
| Security Groups | `web-sg`                                       |
| Key Pair        | `lab04-key`                                    |
| Configuration   | Customization Script : le script ci-dessous    |

```yaml
#cloud-config
package_update: true
packages:
  - nginx
runcmd:
  - mkdir -p /data
  - echo 'LABEL=data /data ext4 defaults,nofail 0 2' >> /etc/fstab
  - systemctl daemon-reload
  - sed -i 's#root /var/www/html;#root /data/site;#' /etc/nginx/sites-available/default
  - systemctl reload nginx
```

> Ce script est exécuté par **cloud-init** au premier démarrage de l'instance. Il refait automatiquement ce que vous avez fait à la main en parties 5 et 6 : installer nginx, préparer le point de montage `/data`, déclarer le volume dans `/etc/fstab`, et pointer nginx vers `/data/site`. Il ne formate **rien** : les données sont déjà sur le volume.

### 7.4 Réassocier l'IP flottante et attacher le volume

1. **Project → Network → Floating IPs →** l'IP libérée en 7.2 **→ Associate →** port de `web-02`.
2. **Project → Volumes → Volumes →** `data-web` **→ Manage Attachments → Attach to Instance : `web-02`**.

### 7.5 Retrouver le site

Depuis l'EC2, avant de vous connecter, supprimez l'empreinte enregistrée pour `web-01` :

```bash
ssh-keygen -R <floating_IP>                   # retire l'ancienne clé d'hôte de ~/.ssh/known_hosts
ssh -i ~/.ssh/lab04-key debian@<floating_IP>
```

> **Clé utilisateur et clé d'hôte.** Votre clé `lab04-key` est la même pour `web-01` et `web-02` : elle prouve **votre** identité à l'instance. Mais chaque instance génère au premier démarrage sa propre **clé d'hôte**, qui prouve **son** identité à vous. SSH a mémorisé la clé d'hôte de `web-01` pour cette adresse IP ; en trouvant une clé différente à la même adresse, il refuse la connexion (`REMOTE HOST IDENTIFICATION HAS CHANGED!`), car c'est exactement ce que provoquerait une machine usurpant cette adresse.

Dans `web-02` :

```bash
cloud-init status --wait             # attend la fin du script cloud-init (doit afficher "done")
lsblk                                # le volume est visible
sudo mount -a                        # monte le volume grâce à la ligne fstab ajoutée par cloud-init
df -h /data                          # /data est monté
cat /data/proof.txt                  # le fichier écrit par web-01 en partie 5
hostname                             # le nom de l'instance actuelle
curl http://localhost                # votre page s'affiche
```

> Ne lancez **surtout pas** `mkfs` : le volume contient déjà vos données.

Depuis l'EC2 :

```bash
curl http://<floating_IP>            # la page est de nouveau servie, à la même adresse
```

**Faites une capture d'écran de `cat /data/proof.txt`, `hostname` et de la page pour votre compte rendu.**

### Questions — Partie 7

**Q7.1** — Relevez l'état du volume `data-web` juste après le détachement, puis après la suppression de `web-01`. Qu'est-ce qui montre que le cycle de vie du volume est indépendant de celui de l'instance ? Même question pour l'IP flottante.

**Q7.2** — Que contient `/data/proof.txt` ? Comparez avec le résultat de `hostname`. Que prouve cette comparaison ?

**Q7.3** — Reprenez votre réponse à Q6.4. Qu'est-ce qui a été perdu avec `web-01`, et comment l'a-t-on reconstruit ? Qu'est-ce qui a été conservé, et grâce à quoi ?

**Q7.4** — Le script cloud-init ajoute la ligne `fstab` et configure nginx **avant** que le volume soit attaché. Pourquoi est-ce possible sans erreur ? (Pensez à l'option `nofail` et à la manière dont nginx lit les fichiers.)

**Q7.5** — Au chapitre 1, on a vu le principe d'infrastructure immuable : les serveurs sont remplaçables (*cattle*) et non réparés à la main (*pets*). En quoi cette partie l'illustre-t-elle ? Quel rôle jouent respectivement cloud-init et le volume Cinder ?

**Q7.6** — Pourquoi SSH a-t-il signalé un changement de clé d'hôte alors que l'adresse IP était la même ? Dans quel cas ce message devrait-il au contraire vous alerter ?

---

## Partie 8 — Protéger les données : snapshot et sauvegarde

Objectif : créer les deux types de copie proposés par Cinder, observer où chacune est stockée, puis récupérer un fichier perdu.

### 8.1 Créer un snapshot et une sauvegarde

Dans `web-02`, démontez le volume pour que toutes les écritures soient sur le disque :

```bash
sudo umount /data
```

Dans Horizon, sur la ligne `data-web` de **Project → Volumes → Volumes** :

1. **Create Snapshot** — Snapshot Name : `data-web-snap`. Le volume étant attaché, cliquez sur **Create Volume Snapshot (Force)**.
2. **Create Backup** — Backup Name : `data-web-backup` ; Container Name : laissez vide (conteneur par défaut).

Attendez l'état **Available** dans les onglets **Volume Snapshots** et **Volume Backups**, puis remontez le volume dans `web-02` :

```bash
sudo mount -a
```

> Si **Create Backup** n'est pas proposé pour un volume attaché, détachez d'abord `data-web`, créez la sauvegarde, puis rattachez-le.

### 8.2 Observer où se trouvent les copies

- **Snapshot** : sur l'EC2, `sudo lvs` affiche une nouvelle ligne `_snapshot-<ID>`, dans le même groupe de volumes LVM que `volume-<ID de data-web>`.
- **Sauvegarde** : **Project → Object Store → Containers** : un conteneur `volumebackups` est apparu. Ouvrez-le et observez les objets qu'il contient.

### 8.3 Simuler un accident

Dans `web-02` :

```bash
sudo rm /data/site/index.html        # suppression "par erreur"
curl -I http://localhost             # le site ne répond plus correctement (403 ou 404)
```

### 8.4 Restaurer depuis la sauvegarde

1. **Volume Backups →** `data-web-backup` **→ Restore Backup →** Select Volume : **Create a New Volume**. Un nouveau volume de 2 Gio apparaît dans **Volumes** (son nom est généré automatiquement) ; attendez l'état **Available**.
2. **Volumes →** volume restauré **→ Manage Attachments → Attach to Instance : `web-02`**

Dans `web-02` :

```bash
lsblk                                            # un nouveau disque de 2G apparaît (vdc)
sudo mkdir -p /restore
sudo mount -o ro /dev/vdc /restore               # monte la copie en lecture seule (remplacez vdc si lsblk indique un autre nom)
sudo cp /restore/site/index.html /data/site/     # récupère le fichier perdu
curl http://localhost                            # le site est de retour
sudo umount /restore
```

Enfin, détachez le volume restauré dans Horizon (**Manage Attachments → Detach Volume**).

> Le snapshot aurait permis la même récupération (**Volume Snapshots →** `data-web-snap` **→ Create Volume**), avec les mêmes étapes d'attachement et de montage.

### Questions — Partie 8

**Q8.1** — Pourquoi démonter `/data` avant de créer les copies ? Pourquoi Horizon impose-t-il l'option **Force** pour le snapshot d'un volume attaché ?

**Q8.2** — D'après vos observations en 8.2, où est stocké le snapshot ? Où est stockée la sauvegarde ? Qui a créé le conteneur `volumebackups`, et pourquoi le volume de 2 Gio n'y est-il pas stocké en un seul objet ?

**Q8.3** — Si le serveur qui héberge les volumes Cinder tombait en panne, laquelle des deux copies permettrait de récupérer les données ? Quel est en contrepartie l'inconvénient de la sauvegarde ?

**Q8.4** — Pourquoi a-t-on monté le volume restauré avec `/dev/vdc` et non avec `LABEL=data` ? (Que contient exactement une copie de volume ?)

---

## Partie 9 — Nettoyage

Objectif : supprimer toutes les ressources du lab, pour repartir d'un environnement propre au lab suivant.

Sur l'EC2 :

```bash
cd ~/Cloud-Native/lab04        # ou le dossier où se trouve le script
chmod +x lab04-clean.sh
./lab04-clean.sh
```

Vérifiez que tout a disparu :

```bash
source ~/devstack/openrc demo demo
openstack server list
openstack volume list
openstack volume snapshot list
openstack volume backup list
openstack floating ip list
openstack container list
```

Toutes ces commandes doivent renvoyer une liste vide.
