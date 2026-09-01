<#
====================================================================
 INSTALLATEUR - Convertisseur PDF -> Markdown
====================================================================
 A executer UNE SEULE FOIS (clic droit sur ce fichier -> "Executer
 avec PowerShell", ou ouvre un terminal PowerShell dans ce dossier et
 tape ".\Installer.ps1"). Il peut etre relance sans risque : il ne
 duplique rien s'il detecte que c'est deja installe.
====================================================================
#>

$ErrorActionPreference = "Stop"
$racineProjet = $PSScriptRoot
$cheminModule = Join-Path $racineProjet "MarkerPDFConverter.psm1"

Write-Host "=== Installation du Convertisseur PDF -> Markdown ===" -ForegroundColor Cyan
Write-Host "Dossier du projet : $racineProjet`n"

# Debloque tous les fichiers du projet : un depot telecharge depuis internet
# (zip GitHub, navigateur, etc.) est marque par Windows comme "distant", ce qui
# empeche PowerShell de charger le module tant qu'il n'est pas debloque.
Get-ChildItem -Path $racineProjet -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
Write-Host "Fichiers du projet debloques (suppression du marquage 'telecharge depuis internet')."

try {

if (-not (Test-Path $cheminModule)) {
    Write-Error "MarkerPDFConverter.psm1 est introuvable a cote de ce script. Verifie que tout le depot a bien ete telecharge (pas juste ce fichier)."
    return
}

# --- 1. Structure de dossiers ---
foreach ($sousDossier in @("ToDo", "Did", "Output\Markdown", "Output\Images", "Output\Logs")) {
    $chemin = Join-Path $racineProjet $sousDossier
    if (-not (Test-Path $chemin)) {
        New-Item -ItemType Directory -Force -Path $chemin | Out-Null
        Write-Host "Dossier cree : $sousDossier"
    }
}

# --- 2. Relier le module a ton profil PowerShell ---
if (-not (Test-Path $PROFILE)) {
    New-Item -ItemType File -Force -Path $PROFILE | Out-Null
    Write-Host "Profil PowerShell cree : $PROFILE"
}

$contenuProfil = Get-Content -Path $PROFILE -Raw -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($contenuProfil) -or ($contenuProfil -notlike "*$cheminModule*")) {
    Add-Content -Path $PROFILE -Value "`n# --- Convertisseur PDF -> Markdown (ne pas modifier a la main) ---`nImport-Module `"$cheminModule`" -Force"
    Write-Host "Ligne ajoutee a ton profil PowerShell ($PROFILE)." -ForegroundColor Green
} else {
    Write-Host "Ton profil pointe deja vers ce module, rien a ajouter."
}

# --- 3. Verification des prerequis ---
$dockerOK = [bool](Get-Command docker -ErrorAction SilentlyContinue)
$qpdfOK   = [bool](Get-Command qpdf -ErrorAction SilentlyContinue)

Write-Host ""
if ($dockerOK) {
    Write-Host "Docker detecte." -ForegroundColor Green
} else {
    Write-Warning "Docker n'est pas detecte. Installe Docker Desktop : https://www.docker.com/products/docker-desktop/"
}
if ($qpdfOK) {
    Write-Host "QPDF detecte." -ForegroundColor Green
} else {
    Write-Warning "QPDF n'est pas detecte. Installe-le avec : winget install qpdf.qpdf"
}

# --- 4. Construire l'image Docker 'marker-local' si besoin ---
$cheminDockerfile = Join-Path $racineProjet "Dockerfile"
if ($dockerOK -and (Test-Path $cheminDockerfile)) {
    $imageExiste = (docker images -q marker-local 2>$null)
    if (-not $imageExiste) {
        Write-Host "`nConstruction de l'image Docker 'marker-local' (premiere fois seulement, peut prendre quelques minutes)..." -ForegroundColor Cyan
        docker build -t marker-local $racineProjet
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Image 'marker-local' construite avec succes." -ForegroundColor Green
        } else {
            Write-Warning "La construction de l'image a echoue. Tu pourras reessayer plus tard avec :`n  docker build -t marker-local `"$racineProjet`""
        }
    } else {
        Write-Host "L'image Docker 'marker-local' existe deja, rien a construire."
    }
} elseif (-not $dockerOK) {
    Write-Host "Construction de l'image Docker ignoree (Docker non detecte). Relance Installer.ps1 une fois Docker installe."
}

# --- 5. Recapitulatif ---
Write-Host "`n=== Installation terminee ! ===" -ForegroundColor Green
Write-Host "1. Ferme puis rouvre PowerShell (ou tape . `$PROFILE dans ce terminal)."
Write-Host "2. Tape 'pdf2md' pour ouvrir l'interface graphique." -ForegroundColor Yellow
Write-Host "3. Depose tes PDF dans le dossier 'ToDo' de ce projet et lance la conversion."

} catch {
    Write-Host ""
    Write-Host "Une erreur est survenue pendant l'installation :" -ForegroundColor Red
    Write-Host $_ -ForegroundColor Red
} finally {
    Write-Host "`nAppuie sur Entree pour fermer cette fenetre..." -ForegroundColor DarkGray
    Read-Host | Out-Null
}
