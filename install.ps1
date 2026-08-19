<#
.SYNOPSIS
  Instala o actualiza bwx-genexus como skills personales de Claude Code.

.DESCRIPTION
  Alternativa al mecanismo de plugins (/plugin marketplace add), que necesita el CLI
  `claude` instalado. Este script copia los skills a ~/.claude/skills, que es donde
  Claude Code los busca en cualquier instalacion, incluida la app de escritorio.

  Corriendolo de nuevo actualiza a la ultima version.

.EXAMPLE
  # desde un clon del repo
  .\install.ps1

  # sin clonar nada (se clona solo en LOCALAPPDATA)
  irm https://raw.githubusercontent.com/brokerware/bwx-genexus-plugin/main/install.ps1 | iex
#>
[CmdletBinding()]
param(
  [string]$Repo   = 'https://github.com/brokerware/bwx-genexus-plugin.git',
  [string]$Branch = 'main'
)

$ErrorActionPreference = 'Stop'

function Fail($msg) { Write-Host $msg -ForegroundColor Red; exit 1 }

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Fail 'Falta git. Es necesario para instalar y para generar los diffs.'
}

# Si el script vive dentro de un clon del repo, usamos ese. Si no, clonamos/actualizamos
# una copia en LOCALAPPDATA.
$here = $null
if ($PSScriptRoot) { $here = Join-Path $PSScriptRoot 'plugins\bwx-genexus\skills' }

if ($here -and (Test-Path $here)) {
  $srcSkills = $here
  Write-Host "origen : $PSScriptRoot (clon local)" -ForegroundColor DarkGray
} else {
  $cache = Join-Path $env:LOCALAPPDATA 'bwx-genexus-plugin'
  if (Test-Path (Join-Path $cache '.git')) {
    Write-Host "origen : $cache (actualizando)" -ForegroundColor DarkGray
    & git -C $cache fetch --quiet origin $Branch
    & git -C $cache reset --hard --quiet "origin/$Branch"
  } else {
    Write-Host "origen : clonando $Repo" -ForegroundColor DarkGray
    & git clone --quiet --branch $Branch --depth 1 $Repo $cache
  }
  if ($LASTEXITCODE -ne 0) { Fail "No pude clonar $Repo. Verifica que tengas acceso al repo (es privado)." }
  $srcSkills = Join-Path $cache 'plugins\bwx-genexus\skills'
}

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
Write-Host 'Para actualizar mas adelante, volve a correr este script.' -ForegroundColor DarkGray
