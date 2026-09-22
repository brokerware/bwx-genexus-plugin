<#
.SYNOPSIS
  Instala, actualiza o desinstala la extension Bwx.GxBridge en GeneXus 18.

.DESCRIPTION
  El bridge es un package del IDE que expone la KB abierta por HTTP local
  (127.0.0.1, con token) para el servidor MCP bwx-gx-bridge del plugin.

  Siempre con el IDE cerrado: GeneXus mantiene el DLL bloqueado mientras corre.

    Instalar     PowerShell como administrador. Copia el DLL a <GeneXus>\Packages,
                 le da al usuario permiso de modificacion sobre ese archivo y corre
                 "GeneXus.exe /install" para que el IDE registre el package.
    -Update      Sin administrador. Reemplaza el DLL ya instalado; el package ya esta
                 registrado, asi que no hace falta /install.
    -Uninstall   Como administrador. Borra el DLL y vuelve a correr /install.

  De donde sale el DLL: si esta el .NET SDK (comando dotnet), se compila desde
  bridge\src contra los ensamblados de la instalacion de GeneXus de esta maquina.
  Es lo preferido: un DLL compilado contra otro build de GeneXus 18 puede no cargar
  despues de un upgrade. Sin SDK, o con -FromRelease, se baja del ultimo Release del
  repo.

.EXAMPLE
  # como administrador, con GeneXus cerrado
  & "$env:LOCALAPPDATA\bwx-genexus-plugin\bridge\install-bridge.ps1"

.EXAMPLE
  # despues de actualizar el repo; sin administrador
  & "$env:LOCALAPPDATA\bwx-genexus-plugin\bridge\install-bridge.ps1" -Update
#>
[CmdletBinding()]
param(
  [string]$GxDir = 'C:\Program Files (x86)\GeneXus\GeneXus18',
  [switch]$Update,
  [switch]$Uninstall,
  [switch]$FromRelease,
  [string]$ReleaseUrl = 'https://github.com/brokerware/bwx-genexus-plugin/releases/latest/download/Bwx.GxBridge.dll'
)
$ErrorActionPreference = 'Stop'

function Fail($msg) { Write-Host $msg -ForegroundColor Red; exit 1 }

$exe = Join-Path $GxDir 'GeneXus.exe'
if (-not (Test-Path $exe)) { Fail "No encuentro GeneXus en '$GxDir'. Pasar -GxDir con la carpeta de instalacion." }
if (Get-Process -Name GeneXus -ErrorAction SilentlyContinue) { Fail 'Cerrar GeneXus antes de seguir: mantiene el DLL bloqueado.' }

$packages = Join-Path $GxDir 'Packages'
$target   = Join-Path $packages 'Bwx.GxBridge.dll'
$pdb      = [IO.Path]::ChangeExtension($target, '.pdb')

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)

function Register-Packages {
  Write-Host 'Registrando packages (GeneXus.exe /install)...'
  $p = Start-Process -FilePath $exe -ArgumentList '/install' -Wait -PassThru
  if ($p.ExitCode -ne 0) { Fail "GeneXus /install termino con codigo $($p.ExitCode)." }
}

if ($Uninstall) {
  if (-not $admin) { Fail 'Para desinstalar, correr desde un PowerShell abierto como administrador.' }
  Remove-Item $target, $pdb -ErrorAction SilentlyContinue
  Register-Packages
  Write-Host 'Bridge desinstalado.' -ForegroundColor Green
  exit 0
}

if ($Update) {
  if (-not (Test-Path $target)) { Fail 'El bridge no esta instalado. Correr este script sin -Update, como administrador.' }
} elseif (-not $admin) {
  Fail 'La primera instalacion necesita un PowerShell abierto como administrador (escribe en Program Files y registra el package). Para actualizar: -Update.'
}

# --- conseguir el DLL ---------------------------------------------------------------
$out = Join-Path $env:TEMP 'bwx-gx-bridge-build'
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Path $out | Out-Null

$useRelease = $FromRelease -or -not (Get-Command dotnet -ErrorAction SilentlyContinue)
if (-not $useRelease) {
  $csproj = Join-Path $PSScriptRoot 'src\Bwx.GxBridge\Bwx.GxBridge.csproj'
  Write-Host "Compilando contra $GxDir ..."
  dotnet build $csproj -c Release -o $out "-p:GxDir=$GxDir" --nologo -v q
  if ($LASTEXITCODE -ne 0) { Fail 'La compilacion fallo. Alternativa: -FromRelease para bajar el DLL publicado.' }
} else {
  if (-not $FromRelease) { Write-Host 'No hay .NET SDK (dotnet); bajo el DLL del ultimo Release.' -ForegroundColor Yellow }
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  try {
    Invoke-WebRequest -Uri $ReleaseUrl -OutFile (Join-Path $out 'Bwx.GxBridge.dll') -UseBasicParsing
  } catch {
    Fail "No pude bajar $ReleaseUrl`n$($_.Exception.Message)`nInstalar el .NET SDK (https://dot.net) para compilarlo localmente."
  }
}

$dll = Join-Path $out 'Bwx.GxBridge.dll'
if (-not (Test-Path $dll)) { Fail "No se genero $dll." }

# --- copiar ---------------------------------------------------------------------------
Copy-Item $dll $target -Force
$builtPdb = Join-Path $out 'Bwx.GxBridge.pdb'
if (Test-Path $builtPdb) { Copy-Item $builtPdb $pdb -Force }
Write-Host "Copiado a $target"

if (-not $Update) {
  # Permiso de modificacion para el usuario solo sobre estos dos archivos: asi -Update
  # puede reemplazarlos sin elevar. El resto de la carpeta de GeneXus no cambia.
  $user = "$env:USERDOMAIN\$env:USERNAME"
  foreach ($f in $target, $pdb) {
    if (Test-Path $f) { icacls $f /grant "${user}:(M)" | Out-Null }
  }
  Register-Packages
}

$version = (Get-Item $target).VersionInfo.FileVersion
Write-Host ''
Write-Host "Bridge $version listo. Abrir GeneXus y la KB." -ForegroundColor Green
Write-Host 'Log: %LOCALAPPDATA%\bwx-gx-bridge\bridge.log' -ForegroundColor DarkGray
Write-Host 'Por defecto solo se pueden modificar objetos ZZBridge*; ver WritePrefixes en %LOCALAPPDATA%\bwx-gx-bridge\config.json' -ForegroundColor DarkGray
