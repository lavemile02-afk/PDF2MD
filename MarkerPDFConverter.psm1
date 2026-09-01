<#
====================================================================
 CONVERTISSEUR PDF -> MARKDOWN (Marker-PDF + QPDF + Docker)
====================================================================
 A placer dans ton profil PowerShell ($PROFILE).

 STRUCTURE DE PROJET ATTENDUE (auto-creee si absente) :

   <Racine>\ToDo               PDF a convertir. Un PDF depose ici
                                 directement = un document independant.
                                 Un SOUS-DOSSIER depose ici = un groupe
                                 de chapitres (tous les PDF qu'il
                                 contient seront fusionnes, dans l'ordre,
                                 en UN SEUL markdown final).
   <Racine>\Did                 Les PDF (ou dossiers de chapitres) sont
                                 deplaces ici une fois convertis. Un
                                 document qui echoue REDESTE dans ToDo.
   <Racine>\Output\Markdown     Un fichier .md par document final.
   <Racine>\Output\Images       Un sous-dossier d'images par document
                                 final (meme nom que le .md correspondant).
   <Racine>\Output\Logs         Un journal horodate par execution du
                                 traitement complet (utile pour les
                                 lots lances la nuit, sans surveillance).

 FONCTIONS PRINCIPALES
   - Traiter-ProjetMarker    : traite tout le contenu de ToDo (usage
                                recommande)
   - Convertir-FichierPDF    : convertit un seul PDF, ou que ce soit.
                                Retourne le CHEMIN du dossier de resultat
                                (contenant le .md + ses images) ou $null
                                en cas d'echec.
   - Convertir-DossierPDF    : convertit tous les PDF d'un dossier libre
                                (sans passer par la structure de projet)
   - Ouvrir-ConvertisseurPDF : interface graphique (les deux modes
                                ci-dessus y sont accessibles, plus une
                                verification/installation des prerequis)

 NOTES SUR LE PROTOCOLE DE PROGRESSION
 --------------------------------------------------------------
 Les fonctions de conversion emettent, en plus des messages normaux,
 des lignes commencant par "##" (ex: "##DOC|60|Conversion partie 2 sur
 3##", "##LOT|2|5|MonDocument.pdf##"). Ces lignes sont capturees par
 l'interface graphique pour animer les barres de progression, puis
 filtrees : elles ne s'affichent jamais telles quelles dans le journal
 ni dans le fichier de log. Si tu appelles ces fonctions toi-meme
 depuis un terminal (sans fournir de -Journal personnalise), elles
 sont automatiquement masquees egalement -- rien a faire de special.

 Tous les messages passent par Write-Host (jamais Write-Output) : cela
 evite qu'un message de journal ne se glisse par erreur dans la valeur
 de retour d'une fonction (bug corrige dans cette version -- voir
 Convertir-FichierPDF, qui retourne desormais le chemin exact du
 dossier de resultat detecte automatiquement, plutot que de supposer
 que Marker nomme ce dossier exactement comme le PDF d'origine).

 INSTALLATION
 --------------------------------------------------------------
 Ce fichier est un module PowerShell : ne le colle pas dans ton
 $PROFILE. Lance plutot Installer.ps1 (present a la racine de ce
 depot), qui se charge de relier ce module a ton profil pour toi.
 Voir README.md pour le detail.
#>

# ============================================================
# CONFIGURATION
# ============================================================
# La racine du projet est toujours le dossier ou se trouve CE fichier.
# Comme tout le depot (module + Installer.ps1 + ToDo/Did/Output) vit au
# meme endroit, il suffit de deplacer/cloner tout le dossier ou tu veux :
# aucun chemin a modifier.
$Global:RacineProjetDefaut = $PSScriptRoot
$Global:MarkerCachePath    = Join-Path $env:USERPROFILE ".marker_cache"
$Global:DockerImage        = "marker-local"
$Global:SeuilPagesDefaut   = 40
$Global:ExtensionsImages   = @('.png', '.jpg', '.jpeg', '.webp')
$Global:WingetIdQPDF       = "QPDF.QPDF"
$Global:WingetIdDocker     = "Docker.DockerDesktop"
# Etapes internes typiques de Marker (dans l'ordre ou elles apparaissent),
# utilisees par l'IHM pour la barre "par blocs". Une etape imprevue (nom
# absent de cette liste) est quand meme affichee, elle ne fait juste pas
# avancer cette barre-la.
$Global:EtapesMarkerConnues = @(
    'Recognizing Layout',
    'Running OCR Error Detection',
    'Detecting bboxes',
    'Recognizing text',
    'Recognizing tables'
)

# Journal par defaut : passe TOUJOURS par Write-Host (jamais Write-Output),
# pour ne jamais contaminer la valeur de retour des fonctions. Masque les
# signaux de barre de progression ("##...##", propres a l'IHM) mais affiche
# aussi bien les jalons que les details ("@@...@@") : appele directement
# depuis un terminal, il n'y a qu'une seule sortie possible, donc autant
# tout montrer (juste depouille de son marqueur "@@").
$Global:JournalConsoleParDefaut = {
    param($msg)
    if ($msg -match '^##') { return }
    if ($msg -match '^@@(.*)@@$') { Write-Host $Matches[1] } else { Write-Host $msg }
}


# ============================================================
# FONCTIONS INTERNES - OUTILS GENERAUX
# ============================================================

function Trouver-CheminQPDF {
    <#
      Retourne le chemin complet de qpdf.exe, ou $null si introuvable.
      Cherche d'abord dans le PATH (cas normal), puis dans l'emplacement
      d'installation standard sous Program Files : l'installeur officiel de
      QPDF (y compris via winget) n'ajoute PAS toujours son dossier "bin" au
      PATH, ce qui fait que Get-Command qpdf peut echouer alors que QPDF est
      bel et bien installe -- fermer/rouvrir PowerShell ne change rien dans
      ce cas, puisque le PATH lui-meme n'a jamais ete mis a jour.
    #>
    $commande = Get-Command qpdf -ErrorAction SilentlyContinue
    if ($commande) { return $commande.Source }

    $trouve = Get-ChildItem -Path (Join-Path ${env:ProgramFiles} "qpdf*\bin\qpdf.exe") -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
    if ($trouve) { return $trouve.FullName }

    return $null
}

function Test-PrerequisMarker {
    <# Verifie que Docker (obligatoire) et QPDF (optionnel) sont disponibles. #>
    param([scriptblock]$Journal = $Global:JournalConsoleParDefaut)

    $ok = $true
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        & $Journal "Docker est introuvable dans le PATH. Installe/ouvre Docker Desktop avant de continuer."
        $ok = $false
    }
    if (-not (Trouver-CheminQPDF)) {
        & $Journal "QPDF est introuvable : le decoupage automatique des gros PDF sera desactive (voir ta note QPDF)."
    }
    return $ok
}

function Get-CleTriNaturel {
    <# Transforme "Chapitre2" et "Chapitre10" en cles comparables dans le bon ordre numerique. #>
    param([Parameter(Mandatory)][string]$Nom)
    return [regex]::Replace($Nom, '\d+', { param($m) $m.Value.PadLeft(10, '0') })
}

function Initialiser-StructureProjet {
    <# Cree la structure ToDo / Did / Output(Markdown, Images, Logs) si elle n'existe pas encore. #>
    param(
        [Parameter(Mandatory)][string]$RacineProjet,
        [scriptblock]$Journal = $Global:JournalConsoleParDefaut
    )

    $dossiers = @(
        (Join-Path $RacineProjet "ToDo"),
        (Join-Path $RacineProjet "Did"),
        (Join-Path $RacineProjet "Output\Markdown"),
        (Join-Path $RacineProjet "Output\Images"),
        (Join-Path $RacineProjet "Output\Logs")
    )
    foreach ($d in $dossiers) {
        if (-not (Test-Path $d)) {
            New-Item -ItemType Directory -Force -Path $d | Out-Null
            & $Journal "Dossier cree : $d"
        }
    }
}

function Deplacer-VersDid {
    <# Deplace un fichier ou un dossier traite vers Did, en evitant d'ecraser un doublon. #>
    param(
        [Parameter(Mandatory)][string]$Chemin,
        [Parameter(Mandatory)][string]$DossierDid,
        [scriptblock]$Journal = $Global:JournalConsoleParDefaut
    )

    New-Item -ItemType Directory -Force -Path $DossierDid | Out-Null
    $nom = Split-Path -Leaf $Chemin
    $destination = Join-Path $DossierDid $nom

    if (Test-Path $destination) {
        $horodatage = Get-Date -Format "yyyyMMdd-HHmmss"
        $nomBase    = [System.IO.Path]::GetFileNameWithoutExtension($nom)
        $extension  = [System.IO.Path]::GetExtension($nom)
        $destination = Join-Path $DossierDid "$nomBase-$horodatage$extension"
    }

    try {
        Move-Item -Path $Chemin -Destination $destination -Force
        & $Journal "   Deplace vers Did : $(Split-Path -Leaf $destination)"
    } catch {
        & $Journal "   ATTENTION : impossible de deplacer '$nom' vers Did : $_"
    }
}

function Finaliser-DocumentConverti {
    <#
      Prend le dossier de resultat d'un document (contenant un .md + ses
      images), depose le .md dans Output\Markdown (renomme NomFinal.md) et
      ses images dans Output\Images\NomFinal, puis nettoie le dossier
      temporaire. Le fichier .md a l'interieur du dossier peut porter
      n'importe quel nom (celui que Marker lui a donne) : on le retrouve
      par simple recherche de *.md, jamais par un nom suppose.
    #>
    param(
        [Parameter(Mandatory)][string]$DossierDocument,
        [Parameter(Mandatory)][string]$NomFinal,
        [Parameter(Mandatory)][string]$DossierMarkdownFinal,
        [Parameter(Mandatory)][string]$DossierImagesFinal,
        [scriptblock]$Journal = $Global:JournalConsoleParDefaut
    )

    if (-not (Test-Path $DossierDocument)) {
        & $Journal "   ATTENTION : dossier de resultat introuvable pour '$NomFinal', rien a deplacer."
        return
    }

    New-Item -ItemType Directory -Force -Path $DossierMarkdownFinal | Out-Null
    $dossierImagesDoc = Join-Path $DossierImagesFinal $NomFinal
    New-Item -ItemType Directory -Force -Path $dossierImagesDoc | Out-Null

    $mdTrouve = Get-ChildItem -Path $DossierDocument -Filter "*.md" -File | Select-Object -First 1

    if ($mdTrouve) {
        $destinationMD = Join-Path $DossierMarkdownFinal "$NomFinal.md"
        if (Test-Path $destinationMD) {
            $horodatage = Get-Date -Format "yyyyMMdd-HHmmss"
            $destinationMD = Join-Path $DossierMarkdownFinal "$NomFinal-$horodatage.md"
        }
        Move-Item -Path $mdTrouve.FullName -Destination $destinationMD -Force
        & $Journal "   Markdown depose : Output\Markdown\$(Split-Path -Leaf $destinationMD)"
    } else {
        & $Journal "   ATTENTION : aucun fichier Markdown trouve pour '$NomFinal'."
    }

    $imagesRestantes = @(Get-ChildItem -Path $DossierDocument -File -ErrorAction SilentlyContinue)
    foreach ($img in $imagesRestantes) {
        Move-Item -Path $img.FullName -Destination (Join-Path $dossierImagesDoc $img.Name) -Force
    }
    & $Journal "   $($imagesRestantes.Count) image(s) deposee(s) : Output\Images\$NomFinal"

    Remove-Item -Path $DossierDocument -Recurse -Force -ErrorAction SilentlyContinue
}

function Finaliser-EtDeplacerDocument {
    <# Enchaine Finaliser-DocumentConverti + Deplacer-VersDid, avec les signaux de progression 95% et 100%. #>
    param(
        [Parameter(Mandatory)][string]$DossierDocument,
        [Parameter(Mandatory)][string]$NomFinal,
        [Parameter(Mandatory)][string]$DossierMarkdownFinal,
        [Parameter(Mandatory)][string]$DossierImagesFinal,
        [Parameter(Mandatory)][string]$CheminOriginal,
        [Parameter(Mandatory)][string]$DossierDid,
        [scriptblock]$Journal = $Global:JournalConsoleParDefaut
    )
    & $Journal "##DOC|95|Deplacement vers Output##"
    Finaliser-DocumentConverti -DossierDocument $DossierDocument -NomFinal $NomFinal -DossierMarkdownFinal $DossierMarkdownFinal -DossierImagesFinal $DossierImagesFinal -Journal $Journal
    Deplacer-VersDid -Chemin $CheminOriginal -DossierDid $DossierDid -Journal $Journal
    & $Journal "##DOC|100|Termine##"
}

function Trouver-NouveauDossier {
    <#
      Retourne le sous-dossier de $DossierParent qui n'existait pas dans
      $NomsAvant (liste de noms captures AVANT la conversion). Plus fiable
      que de deviner le nom que Marker va donner au dossier de sortie --
      Marker peut modifier legerement le nom d'origine (par exemple en
      presence d'espaces dans le nom du PDF).
    #>
    param(
        [Parameter(Mandatory)][string]$DossierParent,
        # Pas de [Parameter(Mandatory)] ici : un tableau VIDE est un cas
        # parfaitement normal (le tout premier appel, avant que Marker n'ait
        # cree quoi que ce soit) -- mais PowerShell refuse de lier un
        # tableau vide a un parametre Mandatory ("Impossible de lier
        # l'argument ... car il s'agit d'une collection vide"), ce qui
        # faisait planter la conversion de la premiere partie de tout PDF
        # decoupe en blocs.
        [array]$NomsAvant = @()
    )
    $apres = @(Get-ChildItem -Path $DossierParent -Directory -ErrorAction SilentlyContinue)
    return ($apres | Where-Object { $NomsAvant -notcontains $_.Name } | Select-Object -First 1)
}


# ============================================================
# FONCTIONS INTERNES - MOTEUR DE CONVERSION
# ============================================================

function Obtenir-NombrePages {
    <# Retourne le nombre de pages d'un PDF via QPDF, ou $null si indisponible. #>
    param([Parameter(Mandatory)][string]$CheminPDF)

    $cheminQPDF = Trouver-CheminQPDF
    if (-not $cheminQPDF) { return $null }
    try {
        $sortie = & $cheminQPDF --show-npages "$CheminPDF" 2>$null
        # Code de sortie QPDF : 0 = succes, 3 = succes avec avertissements
        # (PDF legerement non conforme mais parfaitement lisible -- tres
        # courant en pratique), 2 = veritable echec. Ne rejeter que le 2 :
        # traiter le 3 comme une erreur faisait perdre le decoupage
        # automatique sur des PDF pourtant valides (npages etait quand meme
        # imprime sur stdout).
        if ($LASTEXITCODE -in @(0, 3) -and $sortie -match '^\d+$') { return [int]$sortie }
        return $null
    } catch {
        return $null
    }
}

function Decouper-PDFVolumineux {
    <#
      Decoupe un PDF en blocs de $SeuilPages pages avec QPDF. Retourne les
      fichiers crees, tries dans l'ordre.
      La sortie de QPDF n'etait auparavant pas capturee (meme bug que
      l'ancienne Invoke-MarkerDocker) : tout texte que QPDF ecrirait se
      serait retrouve mele a la valeur de retour de la fonction. On la
      capture desormais et on la transmet en detail (terminal uniquement).
    #>
    param(
        [Parameter(Mandatory)][string]$CheminPDF,
        [Parameter(Mandatory)][int]$SeuilPages,
        [Parameter(Mandatory)][string]$DossierTemp,
        [scriptblock]$Journal = $Global:JournalConsoleParDefaut
    )

    $cheminQPDF = Trouver-CheminQPDF
    if (-not $cheminQPDF) {
        throw "QPDF est introuvable (ni dans le PATH, ni sous Program Files)."
    }

    New-Item -ItemType Directory -Force -Path $DossierTemp | Out-Null
    $nomBase = [System.IO.Path]::GetFileNameWithoutExtension($CheminPDF)
    $cheminModele = Join-Path $DossierTemp "$nomBase-partie.pdf"

    & $cheminQPDF "$CheminPDF" --split-pages=$SeuilPages "$cheminModele" 2>&1 | ForEach-Object {
        $ligne = $_.ToString()
        if (-not [string]::IsNullOrWhiteSpace($ligne) -and $ligne -ne 'System.Management.Automation.RemoteException') {
            & $Journal "@@   [qpdf] $ligne@@"
        }
    }
    if ($LASTEXITCODE -notin @(0, 3)) {
        throw "QPDF a echoue lors du decoupage de '$CheminPDF' (code $LASTEXITCODE)."
    }

    $parties = @(
        Get-ChildItem -Path $DossierTemp -Filter "$nomBase-partie-*.pdf" |
            Sort-Object { [int]([regex]::Match($_.BaseName, '-(\d+)$').Groups[1].Value) }
    )
    if ($parties.Count -eq 0) {
        throw "QPDF n'a produit aucun fichier pour '$CheminPDF'."
    }
    return $parties
}

function ConvertFrom-LigneMarkerProgres {
    <#
      Extrait (Etape, Pourcentage) d'une ligne de progression tqdm/rich
      emise par Marker (format habituel : "Recognizing Layout:  45%|##..").
      Retourne $null si la ligne n'est pas une ligne de progression.
    #>
    # Pas de [Parameter(Mandatory)] : comme pour NomsAvant plus haut,
    # PowerShell refuse de lier une CHAINE VIDE (pas seulement $null) a un
    # parametre Mandatory -- et Docker/Marker emettent forcement des lignes
    # vides de temps en temps, ce qui ferait planter toute la conversion.
    param([string]$Ligne = "")
    if ($Ligne -match '^\s*(?<etape>[A-Za-z][A-Za-z \-]*?):\s*(?<pct>\d{1,3})%') {
        return [pscustomobject]@{ Etape = $Matches['etape'].Trim(); Pourcentage = [int]$Matches['pct'] }
    }
    return $null
}

function Invoke-MarkerDocker {
    <#
      Lance marker_single dans Docker sur UN fichier PDF. Retourne le code
      de sortie.

      Marker tourne sans terminal attache (pas de -t sur docker run) : ses
      barres de progression tqdm/rich (Recognizing Layout, Detecting
      bboxes, ...) ne se redessinent donc pas sur place -- elles
      reimpriment le bloc complet a chaque rafraichissement, plusieurs fois
      par seconde, ce qui peut produire des dizaines de milliers de lignes
      par document. Comme ce flux part sur stderr, il echappait aussi a
      "$code = Invoke-MarkerDocker ..." (qui ne capture que stdout) et
      fuyait tel quel dans la console/le journal/le fichier de log. On
      capture ici stdout+stderr ligne par ligne et on classe chaque message
      en 3 niveaux (voir Journal ci-dessous) :
        - "##...##"  signal de barre de progression (jamais affiche)
        - "@@...@@"  detail (terminal PowerShell uniquement -- utile pour
                      voir precisement ce que fait Marker/QPDF)
        - texte nu   jalon (terminal + journal IHM + fichier de log) :
                      debut/fin de chaque etape Marker
    #>
    param(
        [Parameter(Mandatory)][string]$CheminPDF,
        [Parameter(Mandatory)][string]$DossierSortie,
        [bool]$UtiliserGPU = $true,
        [scriptblock]$Journal = $Global:JournalConsoleParDefaut
    )

    $dossierEntree = Split-Path -Parent $CheminPDF
    $nomFichier    = Split-Path -Leaf $CheminPDF

    New-Item -ItemType Directory -Force -Path $Global:MarkerCachePath | Out-Null
    New-Item -ItemType Directory -Force -Path $DossierSortie | Out-Null

    # Nombre de processus CPU pour l'extraction de texte des PDF (etape qui
    # precede l'IA, purement CPU -- sans lien avec le GPU). Par defaut,
    # Marker n'en utilise que 1 a 4 ; sur une machine multi-coeurs, le reste
    # des coeurs ne fait donc rien pendant cette etape. On en utilise
    # davantage, en gardant 2 coeurs de marge pour Windows et le reste des
    # applications.
    $nombrePdftextWorkers = [Math]::Max(1, [Environment]::ProcessorCount - 2)

    $argsDocker = @('run', '--rm')
    if ($UtiliserGPU) { $argsDocker += @('--gpus', 'all') }
    $argsDocker += @(
        '-v', "${dossierEntree}:/input",
        '-v', "${DossierSortie}:/output",
        '-v', "$($Global:MarkerCachePath):/root/.cache",
        $Global:DockerImage, 'marker_single', "/input/$nomFichier", '--output_dir', '/output',
        '--pdftext_workers', "$nombrePdftextWorkers"
    )

    $derniereEtape          = $null
    $dernierPourcentageEmis = -1
    & docker @argsDocker 2>&1 | ForEach-Object {
        $ligne = $_.ToString()
        # Lignes vides redirigees depuis stderr d'un job (ex: tqdm qui
        # ferme sa barre) : une fois serialisees a travers la frontiere du
        # job, leur ToString() ne rend pas une chaine vide mais le nom du
        # type "System.Management.Automation.RemoteException" -- sans
        # contenu utile, a ignorer.
        if ([string]::IsNullOrWhiteSpace($ligne) -or $ligne -eq 'System.Management.Automation.RemoteException') { return }

        $progres = ConvertFrom-LigneMarkerProgres -Ligne $ligne
        if ($progres) {
            $etapeChangee  = $progres.Etape -ne $derniereEtape
            $sautSuffisant = [Math]::Abs($progres.Pourcentage - $dernierPourcentageEmis) -ge 5
            if ($etapeChangee) {
                & $Journal "   Etape Marker : $($progres.Etape)..."
            }
            if ($etapeChangee -or $sautSuffisant -or $progres.Pourcentage -eq 100) {
                & $Journal "##ETAPE|$($progres.Etape)|$($progres.Pourcentage)##"
                & $Journal "@@   [Marker] $($progres.Etape) : $($progres.Pourcentage)%@@"
                $derniereEtape          = $progres.Etape
                $dernierPourcentageEmis = $progres.Pourcentage
            }
            if ($progres.Pourcentage -eq 100) {
                & $Journal "   Etape Marker terminee : $($progres.Etape)"
            }
        } else {
            & $Journal "@@   [marker] $ligne@@"
        }
    }
    return $LASTEXITCODE
}

function Renommer-ImagesEtReferences {
    <#
      Renomme les images d'un dossier de resultat en les prefixant du nom
      du document, et met a jour les references dans le(s) fichier(s) .md.
      Le remplacement cible uniquement les references Markdown "(nom_image.ext)"
      pour eviter de corrompre un nom qui serait une sous-chaine d'un autre.
      Prefixer systematiquement (partie/chapitre + document) garantit un nom
      d'image unique dans tout un vault Obsidian.
    #>
    param(
        [Parameter(Mandatory)][string]$DossierDoc,
        [Parameter(Mandatory)][string]$NomPropre
    )

    $fichiersMD = @(Get-ChildItem -Path $DossierDoc -Filter "*.md" -File)
    $images     = @(Get-ChildItem -Path $DossierDoc -File |
        Where-Object { $Global:ExtensionsImages -contains $_.Extension.ToLower() })

    if ($fichiersMD.Count -eq 0 -or $images.Count -eq 0) { return }

    foreach ($md in $fichiersMD) {
        $contenu = Get-Content -Path $md.FullName -Raw
        foreach ($img in $images) {
            $ancienNom = $img.Name
            if ($ancienNom.StartsWith($NomPropre)) { continue }

            $nomNettoye = $ancienNom -replace '^_', ''
            $nouveauNom = "${NomPropre}_${nomNettoye}"
            $motif      = "(?<=\()" + [regex]::Escape($ancienNom) + "(?=\))"
            $miseAJour  = [regex]::Replace($contenu, $motif, $nouveauNom)

            if ($miseAJour -ne $contenu) {
                $contenu = $miseAJour
                try {
                    Rename-Item -Path $img.FullName -NewName $nouveauNom -ErrorAction Stop
                } catch {
                    Write-Warning "Impossible de renommer '$ancienNom' : $_"
                }
            }
        }
        Set-Content -Path $md.FullName -Value $contenu -NoNewline
    }
}

function Fusionner-PartiesConverties {
    <#
      Assemble les .md issus de plusieurs DOSSIERS DE RESULTAT deja resolus
      (parties d'un meme PDF decoupe, OU chapitres d'un meme groupe) en un
      seul document, dans l'ordre du tableau $DossiersACombiner, en
      prefixant les images de chaque partie (p1_, p2_, ...) pour eviter
      toute collision de noms. Chaque entree de $DossiersACombiner doit deja
      etre un chemin de dossier resolu (voir Trouver-NouveauDossier) -- rien
      n'est devine a partir d'un nom de fichier PDF ici.
    #>
    param(
        [Parameter(Mandatory)][string]$NomDocumentFinal,
        [Parameter(Mandatory)][string]$DossierSortieFinal,
        [Parameter(Mandatory)][array]$DossiersACombiner,
        [scriptblock]$Journal = $Global:JournalConsoleParDefaut
    )

    $dossierFinal = Join-Path $DossierSortieFinal $NomDocumentFinal
    New-Item -ItemType Directory -Force -Path $dossierFinal | Out-Null
    $contenuComplet = New-Object System.Text.StringBuilder
    $numero = 1

    foreach ($dossierPartie in $DossiersACombiner) {
        if (-not $dossierPartie -or -not (Test-Path $dossierPartie)) {
            & $Journal "   Partie $numero manquante (echec de conversion), ignoree."
            $numero++
            continue
        }

        $mdPartie = Get-ChildItem -Path $dossierPartie -Filter "*.md" -File | Select-Object -First 1
        if (-not $mdPartie) {
            & $Journal "   Aucun .md trouve pour la partie $numero, ignoree."
            $numero++
            continue
        }

        $prefixePartie = "p$numero"
        $images       = @(Get-ChildItem -Path $dossierPartie -File |
            Where-Object { $Global:ExtensionsImages -contains $_.Extension.ToLower() })
        $contenuMD    = Get-Content -Path $mdPartie.FullName -Raw

        foreach ($img in $images) {
            $nouveauNomImg = "${prefixePartie}_$($img.Name)"
            $motif = "(?<=\()" + [regex]::Escape($img.Name) + "(?=\))"
            $contenuMD = [regex]::Replace($contenuMD, $motif, $nouveauNomImg)
            Copy-Item -Path $img.FullName -Destination (Join-Path $dossierFinal $nouveauNomImg) -Force
        }

        [void]$contenuComplet.AppendLine($contenuMD.TrimEnd())
        [void]$contenuComplet.AppendLine("")
        $numero++
    }

    $cheminMDFinal = Join-Path $dossierFinal "$NomDocumentFinal.md"
    Set-Content -Path $cheminMDFinal -Value $contenuComplet.ToString().TrimEnd() -NoNewline
    return $dossierFinal
}


# ============================================================
# FONCTIONS PUBLIQUES - CONVERSION LIBRE (dossier/fichier au choix)
# ============================================================

function Convertir-FichierPDF {
    <#
    .SYNOPSIS
        Convertit un seul PDF en Markdown avec Marker-PDF, en le decoupant
        automatiquement au besoin si il est trop volumineux (le decoupage
        et la refusion sont entierement transparents : peu importe le
        nombre de pages d'origine, tu obtiens toujours UN SEUL .md final).
    .OUTPUTS
        Le CHEMIN du dossier de resultat (contenant le .md + ses images) en
        cas de succes, ou $null en cas d'echec. Ce dossier est TOUJOURS
        detecte automatiquement (jamais suppose a partir du nom du PDF, qui
        peut differer legerement cote Marker -- par exemple en presence
        d'espaces).
    #>
    param(
        [Parameter(Mandatory=$true)][string]$CheminFichierPDF,
        [Parameter(Mandatory=$true)][string]$DossierSortie,
        [int]$SeuilPages = $Global:SeuilPagesDefaut,
        [bool]$UtiliserGPU = $true,
        [scriptblock]$Journal = $Global:JournalConsoleParDefaut
    )

    if (-not (Test-Path $CheminFichierPDF -PathType Leaf)) {
        & $Journal "Fichier introuvable : $CheminFichierPDF"
        return $null
    }
    New-Item -ItemType Directory -Force -Path $DossierSortie | Out-Null

    $pdf = Get-Item -Path $CheminFichierPDF
    $nomDocumentBase = $pdf.BaseName
    $nomPropre = $nomDocumentBase -replace '\s+', '-'

    & $Journal "##DOC|5|Analyse du fichier##"
    $nbPages = Obtenir-NombrePages -CheminPDF $pdf.FullName
    $descriptionPages = if ($nbPages) { "$nbPages pages" } else { "nombre de pages inconnu (QPDF absent ?)" }
    & $Journal "-> $($pdf.Name) ($descriptionPages)"

    $doitDecouper = ($nbPages -and $nbPages -gt $SeuilPages -and (Trouver-CheminQPDF))

    if ($doitDecouper) {
        & $Journal "   Fichier volumineux : decoupage en blocs de $SeuilPages pages via QPDF..."
        & $Journal "##DOC|10|Decoupage QPDF##"
        $dossierTemp = Join-Path $env:TEMP "marker_split_$([guid]::NewGuid().ToString('N'))"
        & $Journal "##TEMP|$dossierTemp##"
        try {
            $parties = Decouper-PDFVolumineux -CheminPDF $pdf.FullName -SeuilPages $SeuilPages -DossierTemp $dossierTemp -Journal $Journal
            & $Journal "   $($parties.Count) partie(s) creee(s)."
            $dossierTempSortie = Join-Path $dossierTemp "sortie"
            New-Item -ItemType Directory -Force -Path $dossierTempSortie | Out-Null

            $n = $parties.Count
            $numeroPartie = 1
            $dossiersParties = @()
            foreach ($partie in $parties) {
                & $Journal "   Conversion de la partie $numeroPartie/$n ($($partie.Name))..."
                & $Journal "##DOC|$([int][math]::Round(10 + ($numeroPartie / $n) * 60))|Conversion partie $numeroPartie sur $n##"
                $nomsAvant = @(Get-ChildItem -Path $dossierTempSortie -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
                $code = Invoke-MarkerDocker -CheminPDF $partie.FullName -DossierSortie $dossierTempSortie -UtiliserGPU $UtiliserGPU -Journal $Journal
                if ($code -ne 0) {
                    & $Journal "   ATTENTION : Marker a retourne le code $code pour $($partie.Name)."
                }
                $dossierPartieItem = Trouver-NouveauDossier -DossierParent $dossierTempSortie -NomsAvant $nomsAvant
                if ($dossierPartieItem) {
                    $dossiersParties += $dossierPartieItem.FullName
                } else {
                    & $Journal "   ATTENTION : dossier de resultat introuvable pour la partie $numeroPartie."
                    $dossiersParties += $null
                }
                $numeroPartie++
            }

            & $Journal "##DOC|75|Fusion des parties##"
            & $Journal "   Fusion des parties en un seul document..."
            $dossierFinal = Fusionner-PartiesConverties -NomDocumentFinal $nomDocumentBase -DossierSortieFinal $DossierSortie -DossiersACombiner $dossiersParties -Journal $Journal

            & $Journal "##DOC|85|Renommage des images##"
            Renommer-ImagesEtReferences -DossierDoc $dossierFinal -NomPropre $nomPropre
            & $Journal "OK : $($pdf.Name) converti et fusionne avec succes."
            return $dossierFinal
        } catch {
            & $Journal "ECHEC sur $($pdf.Name) : $_"
            return $null
        } finally {
            if (Test-Path $dossierTemp) {
                Remove-Item -Path $dossierTemp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    } else {
        & $Journal "##DOC|20|Conversion Marker en cours##"
        $nomsAvant = @(Get-ChildItem -Path $DossierSortie -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        $code = Invoke-MarkerDocker -CheminPDF $pdf.FullName -DossierSortie $DossierSortie -UtiliserGPU $UtiliserGPU -Journal $Journal
        if ($code -ne 0) {
            & $Journal "ECHEC : Marker a retourne le code $code pour $($pdf.Name)."
            return $null
        }
        $dossierDuDocItem = Trouver-NouveauDossier -DossierParent $DossierSortie -NomsAvant $nomsAvant
        if (-not $dossierDuDocItem) {
            & $Journal "ECHEC : impossible de retrouver le dossier de resultat de Marker pour $($pdf.Name)."
            return $null
        }
        & $Journal "##DOC|85|Renommage des images##"
        Renommer-ImagesEtReferences -DossierDoc $dossierDuDocItem.FullName -NomPropre $nomPropre
        & $Journal "OK : $($pdf.Name) converti avec succes."
        return $dossierDuDocItem.FullName
    }
}

function Convertir-DossierPDF {
    <#
    .SYNOPSIS
        Convertit tous les PDF presents DIRECTEMENT dans un dossier (sans
        gestion de sous-dossiers/chapitres -- pour ca, utilise
        Traiter-ProjetMarker).
    #>
    param(
        [Parameter(Mandatory=$true)][string]$DossierEntree,
        [Parameter(Mandatory=$true)][string]$DossierSortie,
        [int]$SeuilPages = $Global:SeuilPagesDefaut,
        [bool]$UtiliserGPU = $true,
        [string]$CheminSignalArret = $null,
        [scriptblock]$Journal = $Global:JournalConsoleParDefaut
    )

    if (-not (Test-PrerequisMarker -Journal $Journal)) { return }

    $fichiersPDF = @(Get-ChildItem -Path $DossierEntree -Filter "*.pdf" -File)
    $total = $fichiersPDF.Count
    & $Journal "$total fichier(s) PDF trouve(s) dans $DossierEntree"

    $i = 1
    $succes = 0
    foreach ($pdf in $fichiersPDF) {
        if ($CheminSignalArret -and (Test-Path $CheminSignalArret)) {
            & $Journal ""
            & $Journal "Arret demande : traitement interrompu. $($total - $i + 1) fichier(s) restant(s) non traite(s)."
            break
        }

        & $Journal ""
        & $Journal "[$i/$total] --------------------------------------------"
        & $Journal "##LOT|$i|$total|$($pdf.Name)##"
        if (Convertir-FichierPDF -CheminFichierPDF $pdf.FullName -DossierSortie $DossierSortie -SeuilPages $SeuilPages -UtiliserGPU $UtiliserGPU -Journal $Journal) {
            & $Journal "##DOC|100|Termine##"
            $succes++
        }
        $i++
    }

    & $Journal ""
    & $Journal "Termine : $succes / $total fichier(s) converti(s) avec succes."
}


# ============================================================
# FONCTION PUBLIQUE PRINCIPALE - PIPELINE DE PROJET (ToDo -> Output/Did)
# ============================================================

function Traiter-ProjetMarker {
    <#
    .SYNOPSIS
        Traite tout le contenu de <Racine>\ToDo :
          - chaque PDF depose directement dans ToDo est converti seul ;
          - chaque SOUS-DOSSIER depose dans ToDo est traite comme un
            groupe de chapitres : tous ses PDF sont convertis puis
            fusionnes (dans l'ordre naturel des noms de fichiers) en un
            seul document final.
        Pour chaque document final : le .md va dans Output\Markdown, ses
        images dans Output\Images\<NomDocument>, et le(s) PDF source(s)
        sont deplaces vers Did. Un document qui echoue reste dans ToDo
        (rien n'est perdu ni deplace sans un resultat verifie). La
        structure de dossiers est creee automatiquement si elle n'existe
        pas. Un journal horodate est ecrit dans Output\Logs a chaque
        execution.

        -CheminSignalArret : si fourni, le traitement du prochain document
        est annule (les documents deja en cours vont toujours jusqu'au
        bout) des que le fichier indique par ce chemin existe sur le disque.
    #>
    param(
        [string]$RacineProjet = $Global:RacineProjetDefaut,
        [int]$SeuilPages = $Global:SeuilPagesDefaut,
        [bool]$UtiliserGPU = $true,
        [string]$CheminSignalArret = $null,
        [scriptblock]$Journal = $Global:JournalConsoleParDefaut
    )

    if (-not (Test-PrerequisMarker -Journal $Journal)) { return }

    Initialiser-StructureProjet -RacineProjet $RacineProjet -Journal $Journal

    $dossierToDo          = Join-Path $RacineProjet "ToDo"
    $dossierDid           = Join-Path $RacineProjet "Did"
    $dossierMarkdownFinal = Join-Path $RacineProjet "Output\Markdown"
    $dossierImagesFinal   = Join-Path $RacineProjet "Output\Images"
    $dossierLogs          = Join-Path $RacineProjet "Output\Logs"
    $cheminLog            = Join-Path $dossierLogs "traitement_$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"

    # Journal enrichi : transmet tout a $Journal (pour l'IHM), et ecrit en
    # plus une copie horodatee sur disque des messages "humains" (les
    # lignes de protocole "##..." ne sont jamais ecrites dans le fichier).
    # $journalOriginal fige explicitement la valeur du parametre $Journal :
    # sans cela, PowerShell resoudrait "$Journal" dynamiquement au moment de
    # l'appel et retrouverait le parametre $Journal de la fonction appelee
    # (ex: Convertir-FichierPDF), provoquant un appel recursif infini.
    $journalOriginal = $Journal
    $journalAvecLog = {
        param($msg)
        & $journalOriginal $msg
        if ($msg -notmatch '^(##|@@)') {
            Add-Content -Path $cheminLog -Value "[$(Get-Date -Format 'HH:mm:ss')] $msg" -ErrorAction SilentlyContinue
        }
    }.GetNewClosure()

    $elementsToDo = @(Get-ChildItem -Path $dossierToDo)
    $pdfsRacine   = @($elementsToDo | Where-Object { -not $_.PSIsContainer -and $_.Extension -eq ".pdf" })
    $sousDossiers = @($elementsToDo | Where-Object { $_.PSIsContainer })

    $aTraiter = @()
    foreach ($pdf in $pdfsRacine) { $aTraiter += [pscustomobject]@{ Type = 'pdf'; Objet = $pdf; Nom = $pdf.Name } }
    foreach ($d in $sousDossiers) { $aTraiter += [pscustomobject]@{ Type = 'chapitres'; Objet = $d; Nom = $d.Name } }

    $total = $aTraiter.Count
    if ($total -eq 0) {
        & $journalAvecLog "Le dossier ToDo est vide ($dossierToDo), rien a traiter."
        return
    }
    & $journalAvecLog "$($pdfsRacine.Count) PDF simple(s) et $($sousDossiers.Count) groupe(s) de chapitres a traiter."

    $numero = 1
    foreach ($element in $aTraiter) {
        if ($CheminSignalArret -and (Test-Path $CheminSignalArret)) {
            & $journalAvecLog ""
            & $journalAvecLog "Arret demande : traitement interrompu. $($total - $numero + 1) element(s) restant(s) dans ToDo."
            break
        }

        & $journalAvecLog ""
        & $journalAvecLog "[$numero/$total] $(if ($element.Type -eq 'pdf') { 'Document simple' } else { 'Groupe de chapitres' }) : $($element.Nom)"
        & $journalAvecLog "##LOT|$numero|$total|$($element.Nom)##"

        if ($element.Type -eq 'pdf') {
            $pdf = $element.Objet
            $dossierTempSortie = Join-Path $env:TEMP "marker_projet_$([guid]::NewGuid().ToString('N'))"
            & $journalAvecLog "##TEMP|$dossierTempSortie##"
            try {
                $dossierDocument = Convertir-FichierPDF -CheminFichierPDF $pdf.FullName -DossierSortie $dossierTempSortie -SeuilPages $SeuilPages -UtiliserGPU $UtiliserGPU -Journal $journalAvecLog
                if ($dossierDocument) {
                    $nomFinal = $pdf.BaseName -replace '\s+', '-'
                    Finaliser-EtDeplacerDocument -DossierDocument $dossierDocument -NomFinal $nomFinal -DossierMarkdownFinal $dossierMarkdownFinal -DossierImagesFinal $dossierImagesFinal -CheminOriginal $pdf.FullName -DossierDid $dossierDid -Journal $journalAvecLog
                } else {
                    & $journalAvecLog "ECHEC : '$($pdf.Name)' n'a pas pu etre converti -- il reste dans ToDo pour un prochain essai."
                }
            } catch {
                & $journalAvecLog "ECHEC sur $($pdf.Name) : $_"
            } finally {
                if (Test-Path $dossierTempSortie) { Remove-Item -Path $dossierTempSortie -Recurse -Force -ErrorAction SilentlyContinue }
            }
        } else {
            $dossierChapitres = $element.Objet
            $chapitres = @(Get-ChildItem -Path $dossierChapitres.FullName -Filter "*.pdf" -File | Sort-Object { Get-CleTriNaturel $_.Name })

            if ($chapitres.Count -eq 0) {
                & $journalAvecLog "   Aucun PDF trouve dans ce dossier, ignore."
            } else {
                & $journalAvecLog "   $($chapitres.Count) chapitre(s) detecte(s), ordre : $($chapitres.Name -join ' -> ')"
                $nomFinal                = $dossierChapitres.Name -replace '\s+', '-'
                $dossierTempChapitres    = Join-Path $env:TEMP "marker_projet_$([guid]::NewGuid().ToString('N'))"
                $dossierTempSortieFinale = Join-Path $env:TEMP "marker_projet_final_$([guid]::NewGuid().ToString('N'))"
                & $journalAvecLog "##TEMP|$dossierTempChapitres##"
                & $journalAvecLog "##TEMP|$dossierTempSortieFinale##"

                # Pour les chapitres, la progression est pilotee ICI (au niveau du
                # groupe) : on filtre donc les signaux ##DOC## internes emis par
                # chaque appel individuel a Convertir-FichierPDF.
                $journalSansProgres = { param($msg) if ($msg -notmatch '^##DOC\|') { & $journalAvecLog $msg } }.GetNewClosure()

                try {
                    $n = $chapitres.Count
                    $i = 1
                    $dossiersChapitresConvertis = @()
                    foreach ($chapitre in $chapitres) {
                        & $journalAvecLog "   Conversion du chapitre : $($chapitre.Name)..."
                        & $journalAvecLog "##DOC|$([int][math]::Round(($i / $n) * 70))|Conversion chapitre $i sur $n ($($chapitre.Name))##"
                        $resultatChapitre = Convertir-FichierPDF -CheminFichierPDF $chapitre.FullName -DossierSortie $dossierTempChapitres -SeuilPages $SeuilPages -UtiliserGPU $UtiliserGPU -Journal $journalSansProgres
                        if (-not $resultatChapitre) {
                            & $journalAvecLog "   ATTENTION : le chapitre '$($chapitre.Name)' a echoue et sera absent du document final."
                        }
                        $dossiersChapitresConvertis += $resultatChapitre
                        $i++
                    }

                    & $journalAvecLog "##DOC|80|Fusion des chapitres##"
                    & $journalAvecLog "   Fusion des $($chapitres.Count) chapitres en un seul document..."
                    $dossierDocumentFinal = Fusionner-PartiesConverties -NomDocumentFinal $dossierChapitres.Name -DossierSortieFinal $dossierTempSortieFinale -DossiersACombiner $dossiersChapitresConvertis -Journal $journalAvecLog

                    & $journalAvecLog "##DOC|85|Renommage des images##"
                    Renommer-ImagesEtReferences -DossierDoc $dossierDocumentFinal -NomPropre $nomFinal

                    Finaliser-EtDeplacerDocument -DossierDocument $dossierDocumentFinal -NomFinal $nomFinal -DossierMarkdownFinal $dossierMarkdownFinal -DossierImagesFinal $dossierImagesFinal -CheminOriginal $dossierChapitres.FullName -DossierDid $dossierDid -Journal $journalAvecLog
                    & $journalAvecLog "OK : groupe '$($dossierChapitres.Name)' converti et fusionne avec succes."
                } catch {
                    & $journalAvecLog "ECHEC sur le groupe $($dossierChapitres.Name) : $_"
                } finally {
                    foreach ($d in @($dossierTempChapitres, $dossierTempSortieFinale)) {
                        if (Test-Path $d) { Remove-Item -Path $d -Recurse -Force -ErrorAction SilentlyContinue }
                    }
                }
            }
        }
        $numero++
    }

    & $journalAvecLog ""
    & $journalAvecLog "Traitement du projet termine. Journal complet : $cheminLog"
}


# ============================================================
# INTERFACE GRAPHIQUE
# ============================================================

function ConvertTo-TexteLigne {
    <# Extrait le texte d'un enregistrement Receive-Job (String ou InformationRecord issu de Write-Host). #>
    param($Item)
    if ($Item -is [System.Management.Automation.InformationRecord]) {
        $donnee = $Item.MessageData
        if ($donnee -is [System.Management.Automation.HostInformationMessage]) { return $donnee.Message }
        return $donnee.ToString()
    }
    return $Item.ToString()
}

function Nouveau-BoutonModerne {
    <# Bouton plat, sans bordure -- esthetique sobre et moderne, sans effet 3D. #>
    param(
        [string]$Texte, [int]$X, [int]$Y, [int]$Largeur, [int]$Hauteur,
        [System.Drawing.Color]$CouleurFond,
        [System.Drawing.Color]$CouleurTexte = [System.Drawing.Color]::White,
        [double]$TaillePolice = 10,
        [System.Drawing.FontStyle]$StylePolice = [System.Drawing.FontStyle]::Bold
    )
    $bouton = New-Object System.Windows.Forms.Button
    $bouton.Text = $Texte
    $bouton.Location = New-Object System.Drawing.Point($X, $Y)
    $bouton.Size = New-Object System.Drawing.Size($Largeur, $Hauteur)
    $bouton.BackColor = $CouleurFond
    $bouton.ForeColor = $CouleurTexte
    $bouton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $bouton.FlatAppearance.BorderSize = 0
    $bouton.Font = New-Object System.Drawing.Font("Segoe UI", $TaillePolice, $StylePolice)
    $bouton.Cursor = [System.Windows.Forms.Cursors]::Hand
    $bouton.UseVisualStyleBackColor = $false
    return $bouton
}

function Nouveau-PanneauCarte {
    <# Panneau de couleur unie, pour regrouper des controles sans la bordure grise d'un GroupBox classique. #>
    param([int]$X, [int]$Y, [int]$Largeur, [int]$Hauteur, [System.Drawing.Color]$CouleurFond)
    $panneau = New-Object System.Windows.Forms.Panel
    $panneau.Location = New-Object System.Drawing.Point($X, $Y)
    $panneau.Size = New-Object System.Drawing.Size($Largeur, $Hauteur)
    $panneau.BackColor = $CouleurFond
    return $panneau
}

function Nouvelle-BarreProgression {
    <# Barre de progression custom (piste + remplissage), plus sobre que le controle Windows natif. #>
    param([int]$X, [int]$Y, [int]$Largeur, [int]$Hauteur, [System.Drawing.Color]$CouleurRemplissage, [System.Drawing.Color]$CouleurPiste)
    $piste = New-Object System.Windows.Forms.Panel
    $piste.Location = New-Object System.Drawing.Point($X, $Y)
    $piste.Size = New-Object System.Drawing.Size($Largeur, $Hauteur)
    $piste.BackColor = $CouleurPiste

    $remplissage = New-Object System.Windows.Forms.Panel
    $remplissage.Location = New-Object System.Drawing.Point(0, 0)
    $remplissage.Size = New-Object System.Drawing.Size(0, $Hauteur)
    $remplissage.BackColor = $CouleurRemplissage
    $piste.Controls.Add($remplissage)

    return [pscustomobject]@{ Piste = $piste; Remplissage = $remplissage; Largeur = $Largeur }
}

function Set-ProgressionBarre {
    param($Barre, [int]$Pourcentage)
    $p = [Math]::Min([Math]::Max($Pourcentage, 0), 100)
    $Barre.Remplissage.Width = [Math]::Max(1, [int]($Barre.Largeur * $p / 100))
}

function Nouvelle-BarreBlocs {
    <# Barre segmentee en blocs distincts (un bloc = une etape franchie), pour une progression "par palier" plutot que continue. #>
    param([int]$X, [int]$Y, [int]$Largeur, [int]$Hauteur, [int]$NombreBlocs, [System.Drawing.Color]$CouleurRemplissage, [System.Drawing.Color]$CouleurPiste)
    $conteneur = New-Object System.Windows.Forms.Panel
    $conteneur.Location = New-Object System.Drawing.Point($X, $Y)
    $conteneur.Size = New-Object System.Drawing.Size($Largeur, $Hauteur)
    $conteneur.BackColor = [System.Drawing.Color]::Transparent

    $espacement  = 4
    $largeurBloc = [Math]::Max(1, [int](($Largeur - ($espacement * ($NombreBlocs - 1))) / $NombreBlocs))
    $blocs = @()
    for ($i = 0; $i -lt $NombreBlocs; $i++) {
        $bloc = New-Object System.Windows.Forms.Panel
        $bloc.Location = New-Object System.Drawing.Point(($i * ($largeurBloc + $espacement)), 0)
        $bloc.Size = New-Object System.Drawing.Size($largeurBloc, $Hauteur)
        $bloc.BackColor = $CouleurPiste
        $conteneur.Controls.Add($bloc)
        $blocs += $bloc
    }
    return [pscustomobject]@{ Conteneur = $conteneur; Blocs = $blocs; CouleurRemplissage = $CouleurRemplissage; CouleurPiste = $CouleurPiste }
}

function Set-ProgressionBlocs {
    param($Barre, [int]$NombreRemplis)
    for ($i = 0; $i -lt $Barre.Blocs.Count; $i++) {
        $Barre.Blocs[$i].BackColor = if ($i -lt $NombreRemplis) { $Barre.CouleurRemplissage } else { $Barre.CouleurPiste }
    }
}

function Ouvrir-ConvertisseurPDF {
    <#
    .SYNOPSIS
        Ouvre une fenetre pour lancer soit le traitement complet du projet
        (ToDo -> Output/Did, recommande), soit une conversion libre d'un
        dossier ou d'un fichier au choix -- avec barre de progression par
        document, barre de progression globale, deux chronometres, un
        bouton pour arreter proprement apres le fichier en cours, et une
        verification/installation des prerequis (Docker, QPDF).
    #>

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # --- Palette et polices ---
    $couleurFond            = [System.Drawing.Color]::FromArgb(245, 245, 247)
    $couleurCarte           = [System.Drawing.Color]::White
    $couleurTexte           = [System.Drawing.Color]::FromArgb(29, 29, 31)
    $couleurTexteSecondaire = [System.Drawing.Color]::FromArgb(110, 110, 115)
    $couleurAccent          = [System.Drawing.Color]::FromArgb(0, 113, 227)
    $couleurDanger          = [System.Drawing.Color]::FromArgb(255, 59, 48)
    $couleurSucces          = [System.Drawing.Color]::FromArgb(52, 199, 89)
    $couleurPiste           = [System.Drawing.Color]::FromArgb(229, 229, 234)
    $couleurSegmentInactif  = [System.Drawing.Color]::FromArgb(235, 235, 240)

    $policeTitre  = New-Object System.Drawing.Font("Segoe UI", 18, [System.Drawing.FontStyle]::Bold)
    $policeSous   = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Regular)
    $policeCorps  = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Regular)
    $policeGras   = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
    $policePetite = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Regular)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Convertisseur PDF -> Markdown"
    $form.Size = New-Object System.Drawing.Size(740, 1070)
    $form.MinimumSize = New-Object System.Drawing.Size(740, 870)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "Sizable"
    $form.MaximizeBox = $true
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $form.AutoScroll = $true
    $form.BackColor = $couleurFond
    $form.Font = $policeCorps

    # --- En-tete ---
    $lblTitre = New-Object System.Windows.Forms.Label
    $lblTitre.Text = "Convertisseur PDF"
    $lblTitre.Font = $policeTitre
    $lblTitre.ForeColor = $couleurTexte
    $lblTitre.AutoSize = $true
    $lblTitre.Location = New-Object System.Drawing.Point(24, 20)
    $form.Controls.Add($lblTitre)

    $lblSousTitre = New-Object System.Windows.Forms.Label
    $lblSousTitre.Text = "PDF vers Markdown, avec Marker, QPDF et Docker"
    $lblSousTitre.Font = $policeSous
    $lblSousTitre.ForeColor = $couleurTexteSecondaire
    $lblSousTitre.AutoSize = $true
    $lblSousTitre.Location = New-Object System.Drawing.Point(26, 54)
    $form.Controls.Add($lblSousTitre)

    # --- Carte : mode + source ---
    $carteSource = Nouveau-PanneauCarte -X 24 -Y 88 -Largeur 676 -Hauteur 216 -CouleurFond $couleurCarte
    $form.Controls.Add($carteSource)

    $btnSegProjet = Nouveau-BoutonModerne -Texte "Traiter le projet" -X 16 -Y 16 -Largeur 310 -Hauteur 36 -CouleurFond $couleurAccent -CouleurTexte White -TaillePolice 9.5
    $btnSegLibre  = Nouveau-BoutonModerne -Texte "Conversion libre" -X 334 -Y 16 -Largeur 310 -Hauteur 36 -CouleurFond $couleurSegmentInactif -CouleurTexte $couleurTexteSecondaire -TaillePolice 9.5
    $carteSource.Controls.AddRange(@($btnSegProjet, $btnSegLibre))

    # Champs mode "Projet"
    $lblRacine = New-Object System.Windows.Forms.Label
    $lblRacine.Text = "Racine du projet"
    $lblRacine.Font = $policeGras
    $lblRacine.ForeColor = $couleurTexte
    $lblRacine.AutoSize = $true
    $lblRacine.Location = New-Object System.Drawing.Point(16, 68)
    $txtRacine = New-Object System.Windows.Forms.TextBox
    $txtRacine.Location = New-Object System.Drawing.Point(16, 90)
    $txtRacine.Size = New-Object System.Drawing.Size(500, 26)
    $txtRacine.Font = $policeCorps
    $txtRacine.BorderStyle = "FixedSingle"
    $txtRacine.Text = $Global:RacineProjetDefaut
    $btnRacine = Nouveau-BoutonModerne -Texte "Parcourir" -X 532 -Y 88 -Largeur 100 -Hauteur 30 -CouleurFond $couleurSegmentInactif -CouleurTexte $couleurTexte -TaillePolice 9 -StylePolice Regular
    $lblAide = New-Object System.Windows.Forms.Label
    $lblAide.Text = "ToDo / Did / Output seront crees automatiquement dans ce dossier."
    $lblAide.Font = $policePetite
    $lblAide.ForeColor = $couleurTexteSecondaire
    $lblAide.AutoSize = $true
    $lblAide.Location = New-Object System.Drawing.Point(16, 128)
    $controlesProjet = @($lblRacine, $txtRacine, $btnRacine, $lblAide)
    $carteSource.Controls.AddRange($controlesProjet)

    $btnRacine.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        if (Test-Path $txtRacine.Text) { $dlg.SelectedPath = $txtRacine.Text }
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $txtRacine.Text = $dlg.SelectedPath }
    })

    # Champs mode "Libre"
    $rbDossierLibre = New-Object System.Windows.Forms.RadioButton
    $rbDossierLibre.Text = "Un dossier complet"
    $rbDossierLibre.Font = $policeCorps
    $rbDossierLibre.ForeColor = $couleurTexte
    $rbDossierLibre.Location = New-Object System.Drawing.Point(16, 70)
    $rbDossierLibre.Checked = $true
    $rbDossierLibre.AutoSize = $true
    $rbFichierLibre = New-Object System.Windows.Forms.RadioButton
    $rbFichierLibre.Text = "Un seul fichier PDF"
    $rbFichierLibre.Font = $policeCorps
    $rbFichierLibre.ForeColor = $couleurTexte
    $rbFichierLibre.Location = New-Object System.Drawing.Point(196, 70)
    $rbFichierLibre.AutoSize = $true

    $lblEntree = New-Object System.Windows.Forms.Label
    $lblEntree.Text = "Entree"
    $lblEntree.Font = $policeGras
    $lblEntree.ForeColor = $couleurTexte
    $lblEntree.AutoSize = $true
    $lblEntree.Location = New-Object System.Drawing.Point(16, 96)
    $txtEntree = New-Object System.Windows.Forms.TextBox
    $txtEntree.Location = New-Object System.Drawing.Point(76, 93)
    $txtEntree.Size = New-Object System.Drawing.Size(440, 26)
    $txtEntree.Font = $policeCorps
    $txtEntree.BorderStyle = "FixedSingle"
    $btnEntree = Nouveau-BoutonModerne -Texte "Parcourir" -X 532 -Y 91 -Largeur 100 -Hauteur 30 -CouleurFond $couleurSegmentInactif -CouleurTexte $couleurTexte -TaillePolice 9 -StylePolice Regular

    $lblSortie = New-Object System.Windows.Forms.Label
    $lblSortie.Text = "Sortie"
    $lblSortie.Font = $policeGras
    $lblSortie.ForeColor = $couleurTexte
    $lblSortie.AutoSize = $true
    $lblSortie.Location = New-Object System.Drawing.Point(16, 130)
    $txtSortie = New-Object System.Windows.Forms.TextBox
    $txtSortie.Location = New-Object System.Drawing.Point(76, 127)
    $txtSortie.Size = New-Object System.Drawing.Size(440, 26)
    $txtSortie.Font = $policeCorps
    $txtSortie.BorderStyle = "FixedSingle"
    $btnSortie = Nouveau-BoutonModerne -Texte "Parcourir" -X 532 -Y 125 -Largeur 100 -Hauteur 30 -CouleurFond $couleurSegmentInactif -CouleurTexte $couleurTexte -TaillePolice 9 -StylePolice Regular

    $controlesLibre = @($rbDossierLibre, $rbFichierLibre, $lblEntree, $txtEntree, $btnEntree, $lblSortie, $txtSortie, $btnSortie)
    $carteSource.Controls.AddRange($controlesLibre)
    foreach ($c in $controlesLibre) { $c.Visible = $false }

    $btnEntree.Add_Click({
        if ($rbDossierLibre.Checked) {
            $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $txtEntree.Text = $dlg.SelectedPath }
        } else {
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Filter = "Fichiers PDF (*.pdf)|*.pdf"
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $txtEntree.Text = $dlg.FileName }
        }
    })
    $btnSortie.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $txtSortie.Text = $dlg.SelectedPath }
    })

    $script:modeSelectionne = 'projet'
    function Rafraichir-Segments {
        if ($script:modeSelectionne -eq 'projet') {
            $btnSegProjet.BackColor = $couleurAccent; $btnSegProjet.ForeColor = [System.Drawing.Color]::White
            $btnSegLibre.BackColor  = $couleurSegmentInactif; $btnSegLibre.ForeColor = $couleurTexteSecondaire
            foreach ($c in $controlesProjet) { $c.Visible = $true }
            foreach ($c in $controlesLibre) { $c.Visible = $false }
        } else {
            $btnSegLibre.BackColor = $couleurAccent; $btnSegLibre.ForeColor = [System.Drawing.Color]::White
            $btnSegProjet.BackColor = $couleurSegmentInactif; $btnSegProjet.ForeColor = $couleurTexteSecondaire
            foreach ($c in $controlesProjet) { $c.Visible = $false }
            foreach ($c in $controlesLibre) { $c.Visible = $true }
        }
    }
    $btnSegProjet.Add_Click({ $script:modeSelectionne = 'projet'; Rafraichir-Segments })
    $btnSegLibre.Add_Click({ $script:modeSelectionne = 'libre'; Rafraichir-Segments })
    Rafraichir-Segments

    # --- Carte : options ---
    $carteOptions = Nouveau-PanneauCarte -X 24 -Y 316 -Largeur 676 -Hauteur 64 -CouleurFond $couleurCarte
    $form.Controls.Add($carteOptions)

    $lblSeuil = New-Object System.Windows.Forms.Label
    $lblSeuil.Text = "Decouper si plus de :"
    $lblSeuil.Font = $policeCorps
    $lblSeuil.ForeColor = $couleurTexte
    $lblSeuil.AutoSize = $true
    $lblSeuil.Location = New-Object System.Drawing.Point(16, 28)
    $numSeuil = New-Object System.Windows.Forms.NumericUpDown
    $numSeuil.Location = New-Object System.Drawing.Point(166, 25)
    $numSeuil.Size = New-Object System.Drawing.Size(70, 26)
    $numSeuil.Font = $policeCorps
    $numSeuil.Minimum = 5
    $numSeuil.Maximum = 2000
    $numSeuil.Value = $Global:SeuilPagesDefaut
    $lblSeuilFin = New-Object System.Windows.Forms.Label
    $lblSeuilFin.Text = "pages"
    $lblSeuilFin.Font = $policeCorps
    $lblSeuilFin.ForeColor = $couleurTexte
    $lblSeuilFin.AutoSize = $true
    $lblSeuilFin.Location = New-Object System.Drawing.Point(242, 28)
    $chkGPU = New-Object System.Windows.Forms.CheckBox
    $chkGPU.Text = "Utiliser le GPU (Docker --gpus all)"
    $chkGPU.Font = $policeCorps
    $chkGPU.ForeColor = $couleurTexte
    $chkGPU.Location = New-Object System.Drawing.Point(336, 28)
    $chkGPU.AutoSize = $true
    $chkGPU.Checked = $true
    $carteOptions.Controls.AddRange(@($lblSeuil, $numSeuil, $lblSeuilFin, $chkGPU))

    # --- Carte : prerequis ---
    $cartePrerequis = Nouveau-PanneauCarte -X 24 -Y 392 -Largeur 676 -Hauteur 68 -CouleurFond $couleurCarte
    $form.Controls.Add($cartePrerequis)

    $lblStatutDocker = New-Object System.Windows.Forms.Label
    $lblStatutDocker.Font = $policeCorps
    $lblStatutDocker.AutoSize = $true
    $lblStatutDocker.Location = New-Object System.Drawing.Point(16, 18)
    $lblStatutQPDF = New-Object System.Windows.Forms.Label
    $lblStatutQPDF.Font = $policeCorps
    $lblStatutQPDF.AutoSize = $true
    $lblStatutQPDF.Location = New-Object System.Drawing.Point(196, 18)
    $lblAidePrerequis = New-Object System.Windows.Forms.Label
    $lblAidePrerequis.Text = "Rouvre l'interface apres une installation pour rafraichir ce statut."
    $lblAidePrerequis.Font = $policePetite
    $lblAidePrerequis.ForeColor = $couleurTexteSecondaire
    $lblAidePrerequis.AutoSize = $true
    $lblAidePrerequis.Location = New-Object System.Drawing.Point(16, 42)
    $btnPrerequis = Nouveau-BoutonModerne -Texte "Verifier / installer" -X 446 -Y 10 -Largeur 210 -Hauteur 34 -CouleurFond $couleurSegmentInactif -CouleurTexte $couleurTexte -TaillePolice 9 -StylePolice Regular
    $cartePrerequis.Controls.AddRange(@($lblStatutDocker, $lblStatutQPDF, $lblAidePrerequis, $btnPrerequis))

    function Rafraichir-StatutsPrerequis {
        $dockerOK = [bool](Get-Command docker -ErrorAction SilentlyContinue)
        $qpdfOK   = [bool](Trouver-CheminQPDF)
        $lblStatutDocker.Text = if ($dockerOK) { "●  Docker pret" } else { "●  Docker manquant" }
        $lblStatutDocker.ForeColor = if ($dockerOK) { $couleurSucces } else { $couleurDanger }
        $lblStatutQPDF.Text = if ($qpdfOK) { "●  QPDF pret" } else { "●  QPDF manquant" }
        $lblStatutQPDF.ForeColor = if ($qpdfOK) { $couleurSucces } else { $couleurDanger }

        $toutPret = $dockerOK -and $qpdfOK
        $btnPrerequis.Enabled = -not $toutPret
        $btnPrerequis.Text = if ($toutPret) { "Prerequis reunis" } else { "Verifier / installer" }
        $btnPrerequis.ForeColor = if ($toutPret) { $couleurTexteSecondaire } else { $couleurTexte }
    }
    Rafraichir-StatutsPrerequis

    # --- Carte : progression ---
    $carteProgression = Nouveau-PanneauCarte -X 24 -Y 476 -Largeur 676 -Hauteur 190 -CouleurFond $couleurCarte
    $form.Controls.Add($carteProgression)

    $lblDocumentActuel = New-Object System.Windows.Forms.Label
    $lblDocumentActuel.Text = "Document en cours : -"
    $lblDocumentActuel.Font = $policeGras
    $lblDocumentActuel.ForeColor = $couleurTexte
    $lblDocumentActuel.AutoSize = $true
    $lblDocumentActuel.Location = New-Object System.Drawing.Point(16, 18)
    $carteProgression.Controls.Add($lblDocumentActuel)

    # Barre "etape en cours" : depuis les signaux ##ETAPE##, affiche le
    # pourcentage A L'INTERIEUR de l'etape Marker en cours (Recognizing
    # Layout, Detecting bboxes, ...), pas le pourcentage global du document.
    $barreDocument = Nouvelle-BarreProgression -X 16 -Y 42 -Largeur 570 -Hauteur 12 -CouleurRemplissage $couleurAccent -CouleurPiste $couleurPiste
    $carteProgression.Controls.Add($barreDocument.Piste)
    $lblPourcentDocument = New-Object System.Windows.Forms.Label
    $lblPourcentDocument.Text = "0 %"
    $lblPourcentDocument.Font = $policeCorps
    $lblPourcentDocument.ForeColor = $couleurTexteSecondaire
    $lblPourcentDocument.AutoSize = $true
    $lblPourcentDocument.Location = New-Object System.Drawing.Point(598, 38)
    $carteProgression.Controls.Add($lblPourcentDocument)

    $lblEtapeDocument = New-Object System.Windows.Forms.Label
    $lblEtapeDocument.Text = "Etape : -"
    $lblEtapeDocument.Font = $policePetite
    $lblEtapeDocument.ForeColor = $couleurTexteSecondaire
    $lblEtapeDocument.Location = New-Object System.Drawing.Point(16, 62)
    $lblEtapeDocument.Size = New-Object System.Drawing.Size(340, 18)
    $lblChronoFichier = New-Object System.Windows.Forms.Label
    $lblChronoFichier.Text = "Temps sur ce fichier : 00:00:00"
    $lblChronoFichier.Font = $policePetite
    $lblChronoFichier.ForeColor = $couleurTexteSecondaire
    $lblChronoFichier.AutoSize = $true
    $lblChronoFichier.Location = New-Object System.Drawing.Point(376, 62)
    $carteProgression.Controls.AddRange(@($lblEtapeDocument, $lblChronoFichier))

    # Barre "par blocs" : un bloc = une etape Marker franchie (independante
    # du pourcentage fin ci-dessus, qui repart a 0 a chaque nouvelle etape).
    $nombreEtapesMarker = $Global:EtapesMarkerConnues.Count
    $barreEtapesBlocs = Nouvelle-BarreBlocs -X 16 -Y 86 -Largeur 500 -Hauteur 10 -NombreBlocs $nombreEtapesMarker -CouleurRemplissage $couleurAccent -CouleurPiste $couleurPiste
    $carteProgression.Controls.Add($barreEtapesBlocs.Conteneur)
    $lblEtapesBlocs = New-Object System.Windows.Forms.Label
    $lblEtapesBlocs.Text = "Etapes : 0 / $nombreEtapesMarker"
    $lblEtapesBlocs.Font = $policePetite
    $lblEtapesBlocs.ForeColor = $couleurTexteSecondaire
    $lblEtapesBlocs.AutoSize = $true
    $lblEtapesBlocs.Location = New-Object System.Drawing.Point(526, 84)
    $carteProgression.Controls.Add($lblEtapesBlocs)

    $lblLotTitre = New-Object System.Windows.Forms.Label
    $lblLotTitre.Text = "Progression globale (0 / 0)"
    $lblLotTitre.Font = $policeGras
    $lblLotTitre.ForeColor = $couleurTexte
    $lblLotTitre.AutoSize = $true
    $lblLotTitre.Location = New-Object System.Drawing.Point(16, 110)
    $carteProgression.Controls.Add($lblLotTitre)

    $barreLot = Nouvelle-BarreProgression -X 16 -Y 134 -Largeur 570 -Hauteur 12 -CouleurRemplissage $couleurSucces -CouleurPiste $couleurPiste
    $carteProgression.Controls.Add($barreLot.Piste)
    $lblPourcentLot = New-Object System.Windows.Forms.Label
    $lblPourcentLot.Text = "0 / 0"
    $lblPourcentLot.Font = $policeCorps
    $lblPourcentLot.ForeColor = $couleurTexteSecondaire
    $lblPourcentLot.AutoSize = $true
    $lblPourcentLot.Location = New-Object System.Drawing.Point(598, 130)
    $carteProgression.Controls.Add($lblPourcentLot)

    $lblChronoLot = New-Object System.Windows.Forms.Label
    $lblChronoLot.Text = "Temps ecoule total : 00:00:00"
    $lblChronoLot.Font = $policePetite
    $lblChronoLot.ForeColor = $couleurTexteSecondaire
    $lblChronoLot.AutoSize = $true
    $lblChronoLot.Location = New-Object System.Drawing.Point(16, 158)
    $carteProgression.Controls.Add($lblChronoLot)

    # --- Actions ---
    $btnLancer = Nouveau-BoutonModerne -Texte "Lancer la conversion" -X 24 -Y 682 -Largeur 380 -Hauteur 42 -CouleurFond $couleurAccent -CouleurTexte White -TaillePolice 10.5
    $btnArreter = Nouveau-BoutonModerne -Texte "Arreter apres ce fichier" -X 412 -Y 682 -Largeur 220 -Hauteur 42 -CouleurFond $couleurDanger -CouleurTexte White -TaillePolice 9.5
    $btnArreter.Enabled = $false
    $btnArreter.BackColor = [System.Drawing.Color]::FromArgb(255, 190, 185)
    # Petit bouton distinct pour l'arret d'urgence : contrairement a
    # "Arreter apres ce fichier" (qui termine proprement le fichier en
    # cours avant de s'arreter), celui-ci coupe IMMEDIATEMENT, peu importe
    # l'etape en cours, et nettoie les artefacts du fichier interrompu.
    $btnUrgence = Nouveau-BoutonModerne -Texte "STOP" -X 640 -Y 682 -Largeur 60 -Hauteur 42 -CouleurFond $couleurDanger -CouleurTexte White -TaillePolice 9.5
    $btnUrgence.Enabled = $false
    $btnUrgence.BackColor = [System.Drawing.Color]::FromArgb(255, 190, 185)
    $form.Controls.AddRange(@($btnLancer, $btnArreter, $btnUrgence))

    $btnOuvrirSortie = Nouveau-BoutonModerne -Texte "Ouvrir le dossier de sortie" -X 24 -Y 732 -Largeur 676 -Hauteur 32 -CouleurFond $couleurSegmentInactif -CouleurTexte $couleurTexte -TaillePolice 9 -StylePolice Regular
    $form.Controls.Add($btnOuvrirSortie)
    $btnOuvrirSortie.Add_Click({
        $cheminAOuvrir = if ($script:modeSelectionne -eq 'projet') { Join-Path $txtRacine.Text "Output" } else { $txtSortie.Text }
        if ($cheminAOuvrir -and (Test-Path $cheminAOuvrir)) {
            Start-Process -FilePath $cheminAOuvrir
        } else {
            [System.Windows.Forms.MessageBox]::Show("Le dossier '$cheminAOuvrir' n'existe pas encore.", "Introuvable", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        }
    })

    # --- Journal ---
    $lblJournal = New-Object System.Windows.Forms.Label
    $lblJournal.Text = "Journal"
    $lblJournal.Font = $policeGras
    $lblJournal.ForeColor = $couleurTexte
    $lblJournal.AutoSize = $true
    $lblJournal.Location = New-Object System.Drawing.Point(26, 776)
    $form.Controls.Add($lblJournal)

    $txtJournal = New-Object System.Windows.Forms.TextBox
    $txtJournal.Location = New-Object System.Drawing.Point(24, 798)
    $txtJournal.Size = New-Object System.Drawing.Size(676, 200)
    $txtJournal.Multiline = $true
    $txtJournal.ScrollBars = "Vertical"
    $txtJournal.ReadOnly = $true
    $txtJournal.BorderStyle = "FixedSingle"
    $txtJournal.BackColor = [System.Drawing.Color]::FromArgb(28, 28, 30)
    $txtJournal.ForeColor = [System.Drawing.Color]::FromArgb(210, 245, 210)
    $txtJournal.Font = New-Object System.Drawing.Font("Cascadia Mono", 9)
    $form.Controls.Add($txtJournal)

    Test-PrerequisMarker -Journal { param($msg) $txtJournal.AppendText("$msg`r`n") } | Out-Null

    $script:jobConversion = $null
    $script:cheminJournalJob = $null
    $script:positionLectureJournal = 0
    $script:cheminSignalArret = $null
    $script:heureDebutLot = $null
    $script:heureDebutFichier = $null
    $script:totalLotCourant = 0

    $regexLot    = '^##LOT\|(\d+)\|(\d+)\|(.*)##$'
    $regexDoc    = '^##DOC\|(\d+)\|(.*)##$'
    $regexEtape  = '^##ETAPE\|(.+?)\|(\d+)##$'
    $regexTemp   = '^##TEMP\|(.*)##$'
    $regexDetail = '^@@(.*)@@$'
    $script:dossiersTempActifs = @()

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 400
    $timer.Add_Tick({
        if ($script:jobConversion) {
            # Lecture du fichier journal partage (voir le clic sur "Lancer" :
            # Receive-Job/Write-Host s'est revele peu fiable pour faire
            # remonter les messages du job vers cette fenetre). Ouverture en
            # partage lecture/ecriture pour ne jamais entrer en conflit avec
            # le job qui continue d'y ajouter des lignes.
            $nouvellesLignes = @()
            try {
                $flux = [System.IO.File]::Open($script:cheminJournalJob, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                $flux.Position = $script:positionLectureJournal
                $lecteur = New-Object System.IO.StreamReader($flux, [System.Text.Encoding]::UTF8)
                $texte = $lecteur.ReadToEnd()
                $script:positionLectureJournal = $flux.Position
                $lecteur.Close()
                $flux.Close()
                if ($texte) {
                    $nouvellesLignes = @($texte -split "`r?`n" | Where-Object { $_ -ne "" })
                }
            } catch {
                # Fichier momentanement verrouille par l'ecriture du job : on
                # reessaiera au prochain tick (400ms plus tard), rien de grave.
            }
            if ($nouvellesLignes.Count -gt 0) {
                foreach ($ligne in $nouvellesLignes) {
                    if ($ligne -match $regexLot) {
                        $index = [int]$Matches[1]; $totalLot = [int]$Matches[2]; $nomDoc = $Matches[3]
                        $script:totalLotCourant = $totalLot
                        $lblLotTitre.Text = "Progression globale ($index / $totalLot)"
                        $pct = if ($totalLot -gt 0) { [int](($index - 1) / $totalLot * 100) } else { 0 }
                        Set-ProgressionBarre -Barre $barreLot -Pourcentage $pct
                        $lblPourcentLot.Text = "$($index - 1) / $totalLot"
                        $lblDocumentActuel.Text = "Document en cours : $nomDoc"
                        Set-ProgressionBarre -Barre $barreDocument -Pourcentage 0
                        $lblPourcentDocument.Text = "0 %"
                        $lblEtapeDocument.Text = "Etape : demarrage..."
                        Set-ProgressionBlocs -Barre $barreEtapesBlocs -NombreRemplis 0
                        $lblEtapesBlocs.Text = "Etapes : 0 / $nombreEtapesMarker"
                        $script:heureDebutFichier = Get-Date
                        # Nouveau document : les dossiers temporaires du
                        # precedent sont soit deja nettoyes (succes/echec
                        # normal), soit obsoletes -- on repart a zero pour le
                        # suivi utilise par l'arret d'urgence.
                        $script:dossiersTempActifs = @()
                        Write-Host ""
                        Write-Host "[$index/$totalLot] $nomDoc"
                    } elseif ($ligne -match $regexTemp) {
                        $script:dossiersTempActifs += $Matches[1]
                    } elseif ($ligne -match $regexDetail) {
                        Write-Host $Matches[1]
                    } elseif ($ligne -match $regexEtape) {
                        $nomEtape = $Matches[1]; $pctEtape = [Math]::Min([Math]::Max([int]$Matches[2], 0), 100)
                        Set-ProgressionBarre -Barre $barreDocument -Pourcentage $pctEtape
                        $lblPourcentDocument.Text = "$pctEtape %"
                        $lblEtapeDocument.Text = "Etape : $nomEtape"

                        $indexEtape = -1
                        for ($k = 0; $k -lt $Global:EtapesMarkerConnues.Count; $k++) {
                            if ($Global:EtapesMarkerConnues[$k] -ieq $nomEtape) { $indexEtape = $k; break }
                        }
                        if ($indexEtape -ge 0) {
                            $remplis = $indexEtape + [int]($pctEtape -eq 100)
                            Set-ProgressionBlocs -Barre $barreEtapesBlocs -NombreRemplis $remplis
                            $lblEtapesBlocs.Text = "Etapes : $remplis / $nombreEtapesMarker"
                        }
                    } elseif ($ligne -match $regexDoc) {
                        # Etapes hors-Marker (analyse, decoupage QPDF, fusion,
                        # renommage, deplacement) : partagent la meme barre
                        # "etape en cours" que les etapes ##ETAPE##, avec leur
                        # propre pourcentage global (pas de barre par blocs
                        # pour celles-ci, elles ne font pas partie du pipeline
                        # Marker).
                        $pct = [Math]::Min([Math]::Max([int]$Matches[1], 0), 100)
                        Set-ProgressionBarre -Barre $barreDocument -Pourcentage $pct
                        $lblPourcentDocument.Text = "$pct %"
                        $lblEtapeDocument.Text = "Etape : $($Matches[2])"
                    } else {
                        $txtJournal.AppendText("$ligne`r`n")
                        Write-Host $ligne
                    }
                }
            }

            if ($script:heureDebutLot) {
                $lblChronoLot.Text = "Temps ecoule total : " + ((Get-Date) - $script:heureDebutLot).ToString('hh\:mm\:ss')
            }
            if ($script:heureDebutFichier) {
                $lblChronoFichier.Text = "Temps sur ce fichier : " + ((Get-Date) - $script:heureDebutFichier).ToString('hh\:mm\:ss')
            }

            if ($script:jobConversion.State -in @('Completed', 'Failed', 'Stopped')) {
                $timer.Stop()
                $btnLancer.Enabled = $true
                $btnLancer.Text = "Lancer la conversion"
                $btnArreter.Enabled = $false
                $btnArreter.Text = "Arreter apres ce fichier"
                $btnUrgence.Enabled = $false
                $arretDemande = [bool]($script:cheminSignalArret -and (Test-Path $script:cheminSignalArret))
                if ($script:jobConversion.State -eq 'Completed' -and -not $arretDemande) {
                    Set-ProgressionBarre -Barre $barreLot -Pourcentage 100
                    $lblPourcentLot.Text = "$($script:totalLotCourant) / $($script:totalLotCourant)"
                }
                if ($arretDemande) {
                    Remove-Item -Path $script:cheminSignalArret -Force -ErrorAction SilentlyContinue
                }
                if ($script:cheminJournalJob) {
                    Remove-Item -Path $script:cheminJournalJob -Force -ErrorAction SilentlyContinue
                }
                Remove-Job -Job $script:jobConversion -Force
                $script:jobConversion = $null
            }
        }
    })

    function Arreter-JobEtNettoyer {
        <#
          Coupe le job de conversion en cours, arrete tout conteneur Docker
          "marker-local" encore actif (docker run --rm ne suffit PAS : tuer
          le processus qui l'a lance ne stoppe pas le conteneur cote demon,
          il continuerait de tourner -- et de consommer GPU/CPU -- pour
          rien), et nettoie les dossiers temporaires du fichier interrompu.
          Utilisee par le bouton STOP ET par la fermeture de la fenetre.
        #>
        if ($script:jobConversion) {
            Stop-Job -Job $script:jobConversion -ErrorAction SilentlyContinue | Out-Null
            Remove-Job -Job $script:jobConversion -Force -ErrorAction SilentlyContinue
            $script:jobConversion = $null
        }

        try {
            $conteneurs = & docker ps -q --filter "ancestor=$($Global:DockerImage)" 2>$null
            foreach ($id in @($conteneurs | Where-Object { $_ })) {
                & docker stop $id 2>$null | Out-Null
                Write-Host "   Conteneur Docker arrete : $id"
            }
        } catch {}

        foreach ($dossier in $script:dossiersTempActifs) {
            if ($dossier -and (Test-Path $dossier)) {
                Remove-Item -Path $dossier -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "   Dossier temporaire nettoye : $dossier"
            }
        }
        $script:dossiersTempActifs = @()

        if ($script:cheminSignalArret -and (Test-Path $script:cheminSignalArret)) {
            Remove-Item -Path $script:cheminSignalArret -Force -ErrorAction SilentlyContinue
        }
        if ($script:cheminJournalJob -and (Test-Path $script:cheminJournalJob)) {
            Remove-Item -Path $script:cheminJournalJob -Force -ErrorAction SilentlyContinue
        }
    }

    $btnArreter.Add_Click({
        if ($script:cheminSignalArret) {
            New-Item -ItemType File -Force -Path $script:cheminSignalArret | Out-Null
            $btnArreter.Enabled = $false
            $btnArreter.Text = "Arret demande..."
            $txtJournal.AppendText("--- Arret demande : le fichier en cours sera termine, puis le traitement s'arretera. ---`r`n")
        }
    })

    $btnUrgence.Add_Click({
        if (-not $script:jobConversion) { return }
        $confirmation = [System.Windows.Forms.MessageBox]::Show(
            "Arreter IMMEDIATEMENT, meme en plein milieu du fichier en cours ?`n`nLe fichier en cours de traitement restera dans ToDo pour etre retraite plus tard ; tout ce qui a ete produit pour lui jusqu'ici sera supprime. Les fichiers deja termines avec succes ne sont pas affectes.",
            "Arret d'urgence", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($confirmation -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        $timer.Stop()
        $btnLancer.Enabled = $false
        $btnArreter.Enabled = $false
        $btnUrgence.Enabled = $false
        $btnUrgence.Text = "Arret..."
        $txtJournal.AppendText("--- Arret d'urgence demande : interruption immediate en cours... ---`r`n")
        Write-Host ""
        Write-Host "--- Arret d'urgence demande : interruption immediate en cours... ---"

        Arreter-JobEtNettoyer

        $nomDocInterrompu = $lblDocumentActuel.Text -replace '^Document en cours : ', ''
        $txtJournal.AppendText("--- Arret d'urgence effectue. '$nomDocInterrompu' reste dans ToDo pour un prochain essai. ---`r`n")
        Write-Host "--- Arret d'urgence effectue. '$nomDocInterrompu' reste dans ToDo pour un prochain essai. ---"

        $btnLancer.Enabled = $true
        $btnLancer.Text = "Lancer la conversion"
        $btnArreter.Text = "Arreter apres ce fichier"
        $btnUrgence.Text = "STOP"
        Set-ProgressionBarre -Barre $barreDocument -Pourcentage 0
        $lblPourcentDocument.Text = "0 %"
        $lblEtapeDocument.Text = "Etape : -"
        $lblDocumentActuel.Text = "Document en cours : -"
        Set-ProgressionBlocs -Barre $barreEtapesBlocs -NombreRemplis 0
        $lblEtapesBlocs.Text = "Etapes : 0 / $nombreEtapesMarker"
    })

    $btnLancer.Add_Click({
        $modeProjet = ($script:modeSelectionne -eq 'projet')

        if ($modeProjet) {
            if ([string]::IsNullOrWhiteSpace($txtRacine.Text)) {
                [System.Windows.Forms.MessageBox]::Show("Merci de choisir la racine du projet.", "Champ manquant", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                return
            }
        } elseif ([string]::IsNullOrWhiteSpace($txtEntree.Text) -or [string]::IsNullOrWhiteSpace($txtSortie.Text)) {
            [System.Windows.Forms.MessageBox]::Show("Merci de choisir une entree et une sortie.", "Champs manquants", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        $txtJournal.Clear()
        $btnLancer.Enabled = $false
        $btnLancer.Text = "Conversion en cours..."
        $btnArreter.Enabled = $true
        $btnArreter.Text = "Arreter apres ce fichier"
        $btnUrgence.Enabled = $true
        $script:dossiersTempActifs = @()
        $script:heureDebutLot = Get-Date
        $script:heureDebutFichier = Get-Date
        $script:totalLotCourant = 0
        Set-ProgressionBarre -Barre $barreDocument -Pourcentage 0
        Set-ProgressionBarre -Barre $barreLot -Pourcentage 0
        Set-ProgressionBlocs -Barre $barreEtapesBlocs -NombreRemplis 0
        $lblPourcentDocument.Text = "0 %"
        $lblPourcentLot.Text = "0 / 0"
        $lblEtapesBlocs.Text = "Etapes : 0 / $nombreEtapesMarker"
        $lblDocumentActuel.Text = "Document en cours : -"
        $lblEtapeDocument.Text = "Etape : -"
        $lblLotTitre.Text = "Progression globale (0 / 0)"
        $script:cheminSignalArret = Join-Path $env:TEMP "marker_stop_$([guid]::NewGuid().ToString('N')).flag"
        # Le journal du job passe par un FICHIER plutot que par Write-Host +
        # Receive-Job : ce dernier s'est revele peu fiable ici (le contenu
        # du job n'atteignait jamais l'IHM -- journal vide, barres figees --
        # alors que les messages etaient bien emis). Un fichier partage est
        # un canal beaucoup plus simple et robuste entre le job et l'IHM.
        $script:cheminJournalJob = Join-Path $env:TEMP "marker_journal_$([guid]::NewGuid().ToString('N')).log"
        New-Item -ItemType File -Force -Path $script:cheminJournalJob | Out-Null
        $script:positionLectureJournal = 0

        $nomsFonctions = @(
            'Trouver-CheminQPDF', 'Test-PrerequisMarker', 'Get-CleTriNaturel', 'Initialiser-StructureProjet',
            'Deplacer-VersDid', 'Finaliser-DocumentConverti', 'Finaliser-EtDeplacerDocument',
            'Trouver-NouveauDossier', 'Obtenir-NombrePages', 'Decouper-PDFVolumineux',
            'ConvertFrom-LigneMarkerProgres', 'Invoke-MarkerDocker', 'Renommer-ImagesEtReferences', 'Fusionner-PartiesConverties',
            'Convertir-FichierPDF', 'Convertir-DossierPDF', 'Traiter-ProjetMarker'
        )
        $definitions = ($nomsFonctions | ForEach-Object {
            "function $_ {`n$((Get-Item "function:$_").Definition)`n}"
        }) -join "`n"

        $blocPrincipal = {
            param($mode, $modeLibre, $racine, $entree, $sortie, $seuil, $gpu, $defs, $cheminCache, $imageDocker, $extensionsImg, $cheminArret, $cheminJournal)
            Invoke-Expression $defs
            $Global:MarkerCachePath   = $cheminCache
            $Global:DockerImage      = $imageDocker
            $Global:ExtensionsImages = $extensionsImg
            $journal = { param($msg) Add-Content -Path $cheminJournal -Value $msg -Encoding UTF8 }

            if ($mode -eq "projet") {
                Traiter-ProjetMarker -RacineProjet $racine -SeuilPages $seuil -UtiliserGPU $gpu -CheminSignalArret $cheminArret -Journal $journal
            } elseif ($modeLibre -eq "dossier") {
                Convertir-DossierPDF -DossierEntree $entree -DossierSortie $sortie -SeuilPages $seuil -UtiliserGPU $gpu -CheminSignalArret $cheminArret -Journal $journal
            } else {
                & $journal "##LOT|1|1|$(Split-Path -Leaf $entree)##"
                if (Convertir-FichierPDF -CheminFichierPDF $entree -DossierSortie $sortie -SeuilPages $seuil -UtiliserGPU $gpu -Journal $journal) {
                    & $journal "##DOC|100|Termine##"
                }
            }
        }

        $mode = if ($modeProjet) { "projet" } else { "libre" }
        $modeLibre = if ($rbDossierLibre.Checked) { "dossier" } else { "fichier" }

        $script:jobConversion = Start-Job -ScriptBlock $blocPrincipal -ArgumentList @(
            $mode, $modeLibre, $txtRacine.Text, $txtEntree.Text, $txtSortie.Text, [int]$numSeuil.Value, [bool]$chkGPU.Checked,
            $definitions, $Global:MarkerCachePath, $Global:DockerImage, $Global:ExtensionsImages, $script:cheminSignalArret, $script:cheminJournalJob
        )
        $timer.Start()
    })

    # --- Verification / installation des prerequis (Docker, QPDF) ---
    $btnPrerequis.Add_Click({
        $btnPrerequis.Enabled = $false
        $btnPrerequis.Text = "Verification..."
        $txtJournal.AppendText("--- Verification des prerequis... ---`r`n")

        $blocPrerequis = {
            param($idQPDF, $idDocker)
            $wingetOK = [bool](Get-Command winget -ErrorAction SilentlyContinue)
            $qpdfCommande = Get-Command qpdf -ErrorAction SilentlyContinue
            $qpdfOK   = [bool]$qpdfCommande -or [bool](Get-ChildItem -Path (Join-Path ${env:ProgramFiles} "qpdf*\bin\qpdf.exe") -ErrorAction SilentlyContinue | Select-Object -First 1)
            $dockerOK = [bool](Get-Command docker -ErrorAction SilentlyContinue)

            # NOTE : jamais de "| Out-Host" ici -- ecrire vers l'hote depuis un
            # Start-Job (l'hote du job n'existe pas vraiment) fait planter
            # chaque ligne de progression de winget avec une erreur "Out-Host",
            # d'ou un deluge de codes d'erreur dans la console au lancement du
            # job. La sortie standard de winget est de toute facon deja
            # capturee automatiquement par le job, sans avoir besoin d'Out-Host.
            if ($qpdfOK) {
                Write-Host "QPDF : deja installe."
            } elseif ($wingetOK) {
                Write-Host "QPDF manquant : installation via winget..."
                winget install --id $idQPDF -e --accept-source-agreements --accept-package-agreements
                Write-Host "QPDF : installation terminee. L'interface le detectera automatiquement (meme si son dossier n'a pas ete ajoute au PATH par l'installeur)."
            } else {
                Write-Host "QPDF manquant et winget indisponible sur ce systeme. Installe-le manuellement : https://qpdf.sourceforge.io/"
            }

            if ($dockerOK) {
                Write-Host "Docker : deja installe."
            } elseif ($wingetOK) {
                Write-Host "Docker manquant : installation via winget (peut prendre plusieurs minutes, et demander une confirmation Windows)..."
                winget install --id $idDocker -e --accept-source-agreements --accept-package-agreements
                Write-Host "Docker Desktop : installation terminee. Un redemarrage de Windows est probablement necessaire, puis lance Docker Desktop manuellement une premiere fois."
            } else {
                Write-Host "Docker manquant et winget indisponible sur ce systeme. Installe Docker Desktop manuellement : https://www.docker.com/products/docker-desktop/"
            }

            Write-Host "--- Verification terminee. ---"
        }

        $script:jobPrerequis = Start-Job -ScriptBlock $blocPrerequis -ArgumentList @($Global:WingetIdQPDF, $Global:WingetIdDocker)
        $script:derniereLignePrerequis = 0

        $timerPrerequis = New-Object System.Windows.Forms.Timer
        $timerPrerequis.Interval = 500
        $timerPrerequis.Add_Tick({
            $sortie = @(Receive-Job -Job $script:jobPrerequis -Keep | ForEach-Object { ConvertTo-TexteLigne $_ })
            if ($sortie.Count -gt $script:derniereLignePrerequis) {
                $nouvelles = $sortie[$script:derniereLignePrerequis..($sortie.Count - 1)]
                foreach ($ligne in $nouvelles) { $txtJournal.AppendText("$ligne`r`n") }
                $script:derniereLignePrerequis = $sortie.Count
            }
            if ($script:jobPrerequis.State -in @('Completed', 'Failed', 'Stopped')) {
                $timerPrerequis.Stop()
                Remove-Job -Job $script:jobPrerequis -Force
                $btnPrerequis.Enabled = $true
                $btnPrerequis.Text = "Verifier / installer"
                Rafraichir-StatutsPrerequis
            }
        })
        $timerPrerequis.Start()
    })

    $form.Add_FormClosing({
        if ($script:jobConversion) {
            $confirmation = [System.Windows.Forms.MessageBox]::Show(
                "Une conversion est en cours. Fermer quand meme ?`n`nLe fichier en cours sera interrompu (comme avec le bouton STOP) et devra etre retraite. Fermer sans passer par ici laisserait le conteneur Docker tourner pour rien en arriere-plan.",
                "Conversion en cours", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($confirmation -ne [System.Windows.Forms.DialogResult]::Yes) {
                $_.Cancel = $true
                return
            }
            Arreter-JobEtNettoyer
        }
    })

    $form.Add_Shown({ $form.Activate() })
    [System.Windows.Forms.Application]::Run($form)
}

# Alias pratique pour lancer l'interface rapidement depuis un terminal
Set-Alias -Name pdf2md -Value Ouvrir-ConvertisseurPDF

# Seules ces fonctions (+ l'alias pdf2md) sont visibles une fois le module
# importe ; les fonctions internes (Decouper-PDFVolumineux, Invoke-MarkerDocker,
# etc.) restent des details d'implementation.
Export-ModuleMember -Function Traiter-ProjetMarker, Convertir-FichierPDF, Convertir-DossierPDF, Ouvrir-ConvertisseurPDF, Initialiser-StructureProjet -Alias pdf2md
