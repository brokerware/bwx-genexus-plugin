<#
  Cliente del bridge. Lee puerto y token de %LOCALAPPDATA%\bwx-gx-bridge\session.json.

    gxb.ps1 ping      responde sin pasar por el hilo de UI del IDE
    gxb.ps1 status
    gxb.ps1 get  -Name ZZBridgeTest [-Type Procedure] [-OutDir dir]
    gxb.ps1 set  -Name ZZBridgeTest -Part Procedure -File nuevo.gx [-ExpectedHash h]
    gxb.ps1 history [-Version Testing] [-From 2026-10-26] [-To 2026-11-26] [-Page n] [-OutFile f.json]

  get guarda cada parte de fuente en <OutDir>\<Name>.<Parte>.gx e imprime su hash;
  set envia ese hash para que el bridge rechace el cambio si alguien edito en el medio.
  history lee los commits del GeneXus Server (Team Development > History), solo lectura.
#>
param(
  [Parameter(Position = 0, Mandatory)][ValidateSet('ping', 'status', 'get', 'set', 'history')][string]$Action,
  [string]$Name,
  [string]$Type,
  [string]$Part,
  [string]$File,
  [string]$ExpectedHash,
  [string]$OutDir = '.',
  [string]$Version,
  [string]$From,
  [string]$To,
  [string]$Query,
  [int]$Page = -1,
  [int]$MaxPages = 0,
  [string]$OutFile
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
  if ($script:RawJson) { return $text }
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
  'history' {
    $qs = @()
    foreach ($kv in @(@('version', $Version), @('from', $From), @('to', $To), @('query', $Query))) {
      if ($kv[1]) { $qs += "$($kv[0])=$([Uri]::EscapeDataString($kv[1]))" }
    }
    if ($Page -ge 0) { $qs += "page=$Page" }
    if ($MaxPages -gt 0) { $qs += "maxPages=$MaxPages" }
    $path = '/history' + $(if ($qs) { '?' + ($qs -join '&') } else { '' })
    if ($OutFile) {
      $script:RawJson = $true
      $json = Invoke-Bridge GET $path $null
      [IO.File]::WriteAllText($OutFile, $json, (New-Object Text.UTF8Encoding $false))
      $h = $json | ConvertFrom-Json
      "$($h.count) commits, $($h.pagesRead) paginas, completo=$($h.complete) -> $OutFile"
      return
    }
    $h = Invoke-Bridge GET $path $null
    if ($h.error) { $h; return }
    "version $($h.version): $($h.count) commits, $($h.pagesRead) paginas, completo=$($h.complete)"
    foreach ($r in $h.revisions) {
      "#$($r.id)  $($r.date)  $($r.user)"
      "  $($r.comment)"
      foreach ($o in $r.objects) { "    - $($o.name) ($($o.type)) $($o.operation)" }
    }
  }
}
