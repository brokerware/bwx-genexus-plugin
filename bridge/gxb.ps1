<#
  Cliente del bridge. Lee puerto y token de %LOCALAPPDATA%\bwx-gx-bridge\session.json.

    gxb.ps1 ping      responde sin pasar por el hilo de UI del IDE
    gxb.ps1 status
    gxb.ps1 get  -Name ZZBridgeTest [-Type Procedure] [-OutDir dir]
    gxb.ps1 set  -Name ZZBridgeTest -Part Procedure -File nuevo.gx [-ExpectedHash h]

  get guarda cada parte de fuente en <OutDir>\<Name>.<Parte>.gx e imprime su hash;
  set envia ese hash para que el bridge rechace el cambio si alguien edito en el medio.
#>
param(
  [Parameter(Position = 0, Mandatory)][ValidateSet('ping', 'status', 'get', 'set')][string]$Action,
  [string]$Name,
  [string]$Type,
  [string]$Part,
  [string]$File,
  [string]$ExpectedHash,
  [string]$OutDir = '.'
)
$ErrorActionPreference = 'Stop'

$sessionPath = Join-Path $env:LOCALAPPDATA 'bwx-gx-bridge\session.json'
if (-not (Test-Path $sessionPath)) { throw 'No hay sesion: GeneXus no esta abierto o el bridge no arranco (ver bridge.log).' }
$session = Get-Content $sessionPath -Raw | ConvertFrom-Json
$base = "http://127.0.0.1:$($session.port)"
$headers = @{ 'X-Bridge-Token' = $session.token }

function Invoke-Bridge([string]$Method, [string]$Path, $Body) {
  $params = @{ Uri = "$base$Path"; Method = $Method; Headers = $headers; UseBasicParsing = $true; TimeoutSec = 300 }
  if ($null -ne $Body) {
    $params.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 5))
    $params.ContentType = 'application/json; charset=utf-8'
  }
  try {
    $r = Invoke-WebRequest @params
    $text = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
  } catch [System.Net.WebException] {
    $resp = $_.Exception.Response
    if (-not $resp) { throw }
    # PowerShell 5.1 ya consumio el stream de la respuesta; el cuerpo queda en ErrorDetails.
    $text = $_.ErrorDetails.Message
    Write-Host "HTTP $([int]$resp.StatusCode)" -ForegroundColor Red
  }
  $text | ConvertFrom-Json
}

switch ($Action) {
  # Si ping responde y status no, el bridge esta vivo pero el hilo de UI del IDE esta ocupado.
  'ping'   { Invoke-Bridge GET '/ping' $null | Format-List }
  'status' { Invoke-Bridge GET '/status' $null | Format-List }
  'get' {
    $q = "/object?name=$([Uri]::EscapeDataString($Name))"
    if ($Type) { $q += "&type=$([Uri]::EscapeDataString($Type))" }
    $o = Invoke-Bridge GET $q $null
    if ($o.error) { $o; return }
    New-Item -ItemType Directory -Force $OutDir | Out-Null
    "$($o.type) $($o.name)  (modificado $($o.lastUpdate))"
    foreach ($p in $o.parts) {
      if (-not $p.isSource) { "  $($p.name)  (sin fuente)"; continue }
      $f = Join-Path $OutDir "$($o.name).$($p.name).gx"
      [IO.File]::WriteAllText($f, $p.source, (New-Object Text.UTF8Encoding $false))
      "  $($p.name)  hash=$($p.hash)  -> $f"
    }
  }
  'set' {
    $src = [IO.File]::ReadAllText((Resolve-Path $File))
    Invoke-Bridge POST '/source' @{ name = $Name; type = $Type; part = $Part; source = $src; expectedHash = $ExpectedHash } | Format-List
  }
}
