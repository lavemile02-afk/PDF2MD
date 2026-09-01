# Convertisseur PDF -> Markdown

Convertit des PDF en Markdown avec [Marker-PDF](https://github.com/VikParuchuri/marker) (via Docker), avec :
- decoupage automatique des PDF trop volumineux (via QPDF), refusionnes en un seul `.md` a la fin ;
- gestion des PDF telecharges par chapitres (un sous-dossier = un document, fusionne dans l'ordre) ;
- des noms d'images toujours uniques (aucun conflit une fois importe dans Obsidian) ;
- une interface graphique avec progression detaillee (etape Marker en cours, barre par etapes, progression globale), deux facons d'arreter un traitement (propre ou immediat), et une detection/installation automatique des prerequis.

## Installation (une seule fois)

1. Installe les deux prerequis :
   - [Docker Desktop](https://www.docker.com/products/docker-desktop/)
   - QPDF : ouvre PowerShell et tape `winget install qpdf.qpdf`
2. Telecharge ou clone ce depot n'importe ou sur ton ordinateur (le nom du dossier n'a pas d'importance : tout fonctionne depuis l'endroit ou tu le mets).
3. Dans ce dossier : clic droit sur **Installer.ps1** -> *Executer avec PowerShell*
   (ou ouvre un terminal PowerShell dans ce dossier et tape `.\Installer.ps1`).
4. Ferme puis rouvre PowerShell.

L'installateur relie automatiquement le module a ton profil PowerShell, cree la structure de dossiers, et construit l'image Docker `marker-local` la premiere fois. Il debloque aussi automatiquement les fichiers du projet (Windows les marque comme "telecharges depuis internet", ce qui empecherait PowerShell de les charger).

> Si tu vois une erreur mentionnant qu'un fichier "n'est pas signe numeriquement" en ouvrant un nouveau PowerShell, corrige avec :
> ```powershell
> Get-ChildItem -Path "chemin\vers\ce\dossier" -Recurse | Unblock-File
> ```
> puis rouvre PowerShell.

> QPDF est detecte meme si son installeur n'a pas ajoute son dossier au PATH (cas frequent) : le module verifie aussi l'emplacement standard sous `Program Files`.

## Utilisation

Tape simplement :

```powershell
pdf2md
```

dans un terminal PowerShell pour ouvrir l'interface graphique.

### Comment deposer tes PDF

- Un PDF depose **directement** dans `ToDo` = un document independant.
- Un **sous-dossier** depose dans `ToDo` contenant plusieurs PDF = un groupe de chapitres : ils sont convertis puis fusionnes automatiquement, dans l'ordre naturel des noms de fichiers (`Chapitre1`, `Chapitre2`, ... `Chapitre10`), en un seul document final.
- Les PDF de plus de **40 pages** (reglable dans l'interface) sont automatiquement decoupes en blocs avant conversion, puis refusionnes -- augmenter ce seuil reduit le nombre de rechargements de modele (un peu plus rapide) mais garde chaque bloc plus gros en memoire ; le diminuer va generalement a l'encontre de la vitesse, sans reduire le travail reel du GPU.

### Suivre la progression

- **Le journal de l'interface** n'affiche que les grandes etapes : debut de chaque fichier, decision de decoupage, debut/fin de chaque etape Marker, et la confirmation finale (PDF deplace dans `Did`, markdown dans `Output\Markdown`, images dans `Output\Images`).
- **Le terminal PowerShell** (celui ou `pdf2md` a ete lance) affiche en plus le detail : pourcentage precis de chaque etape Marker, sortie de QPDF, etc. -- utile pour diagnostiquer un traitement qui semble lent ou bloque, sans noyer le journal de l'interface.
- Deux facons d'arreter un traitement :
  - **"Arreter apres ce fichier"** : le fichier en cours va jusqu'au bout, puis le traitement s'arrete avant le suivant.
  - **"STOP"** (arret d'urgence) : interrompt immediatement, meme en plein milieu d'un fichier. Le conteneur Docker actif est arrete, les dossiers temporaires du fichier interrompu sont nettoyes, et le PDF original reste dans `ToDo` pour etre retraite plus tard. Fermer la fenetre pendant un traitement declenche la meme confirmation et le meme nettoyage (un conteneur Docker oublie continue sinon de tourner -- et de consommer GPU/CPU -- meme apres la fermeture de la fenetre).

### Ou retrouver les resultats

- `Output\Markdown\` : un fichier `.md` par document.
- `Output\Images\<NomDocument>\` : les images de ce document.
- `Did\` : les PDF source, une fois convertis (pour vider `ToDo` au fur et a mesure).
- `Output\Logs\` : un journal horodate (grandes etapes uniquement) de chaque execution complete, utile pour les traitements lances sans surveillance.

## Performance

Marker s'appuie sur le GPU (`--gpus all` par defaut) pour l'essentiel du calcul ; le CPU ne fait que de l'orchestration legere. Si `docker stats` montre un CPU proche de 0 pendant qu'un fichier se traite, c'est normal -- regarde plutot le GPU (`nvidia-smi`) pour voir si le traitement avance reellement. Le module utilise aussi plusieurs coeurs CPU pour l'extraction de texte (etape qui precede l'IA, independante du GPU) plutot que le comportement par defaut de Marker qui n'en utilise qu'un seul.

## Structure du depot

```
MarkerPDFConverter.psm1   Le module (toute la logique)
Installer.ps1             Installation en un clic
Dockerfile                Image Docker utilisee par le module
LICENSE                   Licence MIT
ToDo/ Did/ Output/        Structure de travail (vide au depart, tes fichiers n'y sont jamais versionnes)
```

## Utilisation avancee (sans passer par l'interface)

```powershell
# Traiter tout le dossier ToDo du projet
Traiter-ProjetMarker

# Convertir un PDF isole, ou que ce soit
Convertir-FichierPDF -CheminFichierPDF "C:\chemin\vers\document.pdf" -DossierSortie "C:\chemin\vers\sortie"
```

## Licence

Ce projet est distribue sous licence [MIT](LICENSE).
