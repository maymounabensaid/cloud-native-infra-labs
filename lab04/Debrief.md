
## Note 1 : volume de boot pour une VM
Avec **Create New Volume : No**, le disque de démarrage n’est **pas** un volume Cinder. C’est un disque **éphémère**, géré directement par Nova :

- c’est un fichier sur l’hyperviseur, `/opt/stack/data/nova/instances/<ID de l'instance>/disk`, construit à partir de l’image Glance ;
- il n’apparaît pas dans **Project → Volumes** ;
- il est **supprimé avec l’instance**.

Avec **Create New Volume : Yes**, Nova demande à Cinder de créer un volume à partir de l’image, puis démarre l’instance dessus (_boot from volume_). Ce volume apparaît alors dans **Volumes**. Il peut survivre à l’instance si **Delete Volume on Instance Delete** vaut **No** : c’est ce que fait l’exercice complémentaire.

Ce choix compte d’autant plus que, dans les versions récentes d’Horizon, **Create New Volume vaut Yes par défaut**. C’est pour ça que le lab précise explicitement **No** en section 4.5.

Attention aussi au mot « éphémère » : il ne veut pas dire « perdu au redémarrage ». Le disque éphémère survit à un reboot, à un arrêt ou à une mise en pause de l’instance. Il ne disparaît qu’à la **suppression** de l’instance.

