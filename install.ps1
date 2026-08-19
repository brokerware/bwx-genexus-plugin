<#
.SYNOPSIS
  Instala o actualiza bwx-genexus como skills personales de Claude Code.

.DESCRIPTION
  Alternativa al mecanismo de plugins (/plugin marketplace add), que solo esta disponible
  dentro de la sesion interactiva del CLI `claude`. Este script copia los skills a
  ~/.claude/skills, que es donde Claude Code los busca en cualquier instalacion, incluida
  la app de escritorio.

  El repo es privado, asi que la descarga va por git (usa tus credenciales de GitHub).
  No se puede hacer por raw.githubusercontent.com: sin token devuelve 404.

  Corriendolo de nuevo actualiza a la ultima version.

.EXAMPLE
  # primera vez
  git clone https://github.com/brokerware/bwx-genexus-plugin.git "$env:LOCALAPPDATA\bwx-genexus-plugin"
  & "$env:LOCALAPPDATA\bwx-genexus-plugin\install.ps1"

  # actualizar despues
  & "$env:LOCALAPPDATA\bwx-genexus-plugin\install.ps1"

.PARAMETER NoPull
  No intenta actualizar el clon antes de copiar. Util cuando estas desarrollando el
  plugin y no queres que te toque el working tree.
#>
[CmdletBinding()]
param(
  [string]$Repo   = 'https://github.com/brokerware/bwx-genexus-plugin.git',
  [string]$Branch = 'main',
  [switch]$NoPull
)

$ErrorActionPreference = 'Stop'

function Fail($msg) { Write-Host $msg -ForegroundColor Red; exit 1 }

# git escribe avisos y progreso por stderr; PowerShell los convertiria en ErrorRecord
# y con ErrorActionPreference=Stop cortarian el script. Filtramos y miramos el exit code.
function Invoke-Git {
  $out = & git @args 2>&1 | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }
  return @{ Ok = ($LASTEXITCODE -eq 0); Output = ($out -join "`n") }
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Fail 'Falta git. Es necesario para instalar y para generar los diffs.'
}

# Si este script vive dentro de un clon del repo, usamos ese clon. Si no, clonamos o
# actualizamos una copia en LOCALAPPDATA.
$localSkills = $null
if ($PSScriptRoot) { $localSkills = Join-Path $PSScriptRoot 'plugins\bwx-genexus\skills' }

if ($localSkills -and (Test-Path $localSkills)) {
  $root = $PSScriptRoot
  Write-Host "origen : $root" -ForegroundColor DarkGray

  if (-not $NoPull -and (Test-Path (Join-Path $root '.git'))) {
    $st = Invoke-Git -C $root status --porcelain
    if ($st.Output) {
      Write-Host '  hay cambios locales sin commitear: no actualizo, uso la copia tal cual' -ForegroundColor Yellow
    } else {
      $pull = Invoke-Git -C $root pull --ff-only --quiet
      if ($pull.Ok) { Write-Host '  actualizado desde origin' -ForegroundColor DarkGray }
      else { Write-Host '  no pude actualizar, sigo con la copia local' -ForegroundColor Yellow }
    }
  }
} else {
  $root = Join-Path $env:LOCALAPPDATA 'bwx-genexus-plugin'
  if (Test-Path (Join-Path $root '.git')) {
    Write-Host "origen : $root (actualizando)" -ForegroundColor DarkGray
    $f = Invoke-Git -C $root fetch --quiet origin $Branch
    if (-not $f.Ok) { Fail "No pude actualizar el clon en '$root'.`n$($f.Output)" }
    $r = Invoke-Git -C $root reset --hard --quiet "origin/$Branch"
    if (-not $r.Ok) { Fail "No pude actualizar el clon en '$root'.`n$($r.Output)" }
  } else {
    Write-Host "origen : clonando $Repo" -ForegroundColor DarkGray
    $c = Invoke-Git clone --quiet --branch $Branch --depth 1 $Repo $root
    if (-not $c.Ok) {
      Fail @"
No pude clonar $Repo

El repo es privado. Verifica que:
  - tengas acceso a la organizacion brokerware en GitHub
  - git tenga tus credenciales (probar: git ls-remote $Repo)

Detalle: $($c.Output)
"@
    }
  }
}

$srcSkills = Join-Path $root 'plugins\bwx-genexus\skills'
if (-not (Test-Path $srcSkills)) { Fail "No encuentro los skills en '$srcSkills'." }

$dest = Join-Path $env:USERPROFILE '.claude\skills'
New-Item -ItemType Directory -Path $dest -Force | Out-Null

foreach ($skill in (Get-ChildItem $srcSkills -Directory)) {
  $target = Join-Path $dest $skill.Name
  if (Test-Path $target) { Remove-Item $target -Recurse -Force }
  Copy-Item $skill.FullName $target -Recurse -Force
  Write-Host "instalado: $target" -ForegroundColor Green
}

$script = Join-Path $dest 'revisar-commits\scripts\gx-kb.ps1'
if (-not (Test-Path $script)) { Fail 'La copia quedo incompleta: falta gx-kb.ps1.' }

Write-Host ''
& $script -Action doctor

Write-Host ''
Write-Host 'Listo. En Claude Code pedi: "BWX revisar commits"' -ForegroundColor Cyan
Write-Host "Para actualizar mas adelante, volve a correr:  $(Join-Path $root 'install.ps1')" -ForegroundColor DarkGray
