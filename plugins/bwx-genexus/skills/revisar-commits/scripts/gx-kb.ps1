#requires -Version 5.1
<#
.SYNOPSIS
  Extrae diffs y fuentes de una KB GeneXus leyendo la base SQL, en modo lectura.

.DESCRIPTION
  GeneXus no guarda diffs. Cada version de cada objeto vive en
  EntityVersion.EntityVersionData: un header corto seguido de un stream gzip con XML.
  El fuente viene como TokenDataList (stream de tokens) y se reconstruye concatenando
  los <Word>, cargando el XML con PreserveWhitespace para no perder la indentacion.

  Cada cambio pertenece a una OPERACION (ModelEntityHistory.HistoryOperationSource, un
  GUID de sesion): abrir y guardar objetos, un update del server, un import de XPZ.
  Los objetos se comparan contra su estado previo a la operacion que los toco.

  Solo hace SELECT: no abre la KB ni toma locks. Funciona con el IDE abierto.
  Los timestamps de la KB estan en UTC y se convierten a hora local.

.EXAMPLE
  gx-kb.ps1 -Action doctor
  gx-kb.ps1 -Action list -LastOps 1
  gx-kb.ps1 -Action diff  -Objects UpdateOrder,ClientHasCash -OutDir C:\temp\rev
  gx-kb.ps1 -Action audit -Objects UpdateOrder
  gx-kb.ps1 -Action source -Objects UpdateOrder -OutDir C:\temp\rev
#>
[CmdletBinding()]
param(
  # doctor = verifica la instalacion y la conexion
  # ops    = operaciones recientes sobre la KB
  # list   = objetos cambiados
  # diff   = diff unificado por objeto
  # source = fuente completo reconstruido
  # audit  = checks mecanicos sobre el objeto entero
  # parts  = partes de un objeto y su tamano
  # kbs         = lista las KBs candidatas
  # set-default = fija la KB por defecto en el config
  [ValidateSet('doctor','kbs','set-default','ops','list','diff','source','audit','parts')]
  [string]$Action = 'list',

  # Carpeta de la KB. Si se omite: el directorio actual, y si no, el config.
  [string]$KbPath = '',

  [string]$Object,

  # Lista explicita. Match exacto primero, substring si no hay exacto.
  [string[]]$Objects,

  # Un nombre por linea. Para volcar la grilla de Pending Commits del IDE.
  [string]$ObjectsFile,

  [datetime]$Since,
  [int]$LastOps = 0,

  [ValidateSet('lastop','prev')]
  [string]$Against = 'lastop',

  [int]$Version = 0,
  [int]$MaxObjects = 40,
  [string]$OutDir,
  [int]$ModelId = 0
)

$ErrorActionPreference = 'Stop'
$script:ConfigPath = Join-Path $env:USERPROFILE '.bwx-genexus.json'

# ------------------------------------------------------- resolucion de la KB

function Test-KbFolder { param([string]$P) return ($P -and (Test-Path (Join-Path $P 'knowledgebase.connection'))) }

<#
  GeneXus mantiene su propia lista de KBs recientes en
  %APPDATA%\GeneXus\GeneXus\<version>\recentsKBs.xml, con path y ultimo acceso.
  Es la mejor fuente de autodeteccion: no hay que configurar nada ni escanear discos.
  Las entradas se repiten y pueden apuntar a KBs borradas, asi que hay que deduplicar
  por path y validar que la carpeta siga siendo una KB.
#>
function Get-RecentKbs {
  $root = Join-Path $env:APPDATA 'GeneXus'
  if (-not (Test-Path $root)) { return @() }
  $best = @{}
  foreach ($f in (Get-ChildItem -Path $root -Filter 'recentsKBs.xml' -Recurse -ErrorAction SilentlyContinue)) {
    try { $xml = [xml](Get-Content $f.FullName -Raw) } catch { continue }
    foreach ($kb in $xml.SelectNodes('//RecentKB')) {
      $p = $kb.Path
      if (-not (Test-KbFolder $p)) { continue }
      $when = [datetime]::MinValue
      try { $when = [datetime]::Parse($kb.LastAccess) } catch { }
      $k = $p.ToLower()
      if (-not $best.ContainsKey($k) -or $best[$k].LastAccess -lt $when) {
        $best[$k] = [pscustomobject]@{ Name = $kb.Name; Path = $p; LastAccess = $when }
      }
    }
  }
  @($best.Values | Sort-Object LastAccess -Descending)
}

<#
  Orden de resolucion, de mas explicito a mas automatico. Devuelve tambien de donde
  salio la KB: cuando se autodetecta hay que mostrarlo, porque elegir la KB equivocada
  en silencio (por ejemplo una PROD que quedo en los recientes) seria peor que fallar.
#>
function Resolve-Kb {
  param([string]$Explicit)
  if ($Explicit) {
    if (Test-KbFolder $Explicit) { return [pscustomobject]@{ Path = $Explicit; Source = 'parametro -KbPath' } }
    throw "'$Explicit' no contiene knowledgebase.connection: no es una carpeta de KB."
  }
  $cwd = (Get-Location).Path
  if (Test-KbFolder $cwd) { return [pscustomobject]@{ Path = $cwd; Source = 'directorio actual' } }

  if (Test-Path $script:ConfigPath) {
    try {
      $cfg = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
      if (Test-KbFolder $cfg.kbPath) { return [pscustomobject]@{ Path = $cfg.kbPath; Source = 'config' } }
    } catch { }
  }

  $recent = Get-RecentKbs
  if ($recent.Count -ge 1) {
    $r = $recent[0]
    return [pscustomobject]@{
      Path = $r.Path
      Source = "AUTODETECTADA de las KBs recientes de GeneXus (ultimo acceso $($r.LastAccess.ToString('yyyy-MM-dd HH:mm')))"
      Ambiguous = ($recent.Count -gt 1)
      Candidates = $recent
    }
  }

  throw @"
No encuentro ninguna KB. Formas de resolverlo:
  1) Corre el comando parado en la carpeta de la KB.
  2) Pasa -KbPath 'C:\KBs\MiKB'.
  3) Fija una por defecto:  -Action set-default -KbPath 'C:\KBs\MiKB'
Para ver las candidatas:    -Action kbs
"@
}

function Resolve-KbConnection {
  param([string]$Path)
  $ci = ([xml](Get-Content (Join-Path $Path 'knowledgebase.connection') -Raw)).ConnectionInformation
  if ([string]::IsNullOrWhiteSpace($ci.ServerInstance) -or [string]::IsNullOrWhiteSpace($ci.DBName)) {
    throw 'knowledgebase.connection incompleto (ServerInstance / DBName vacios).'
  }
  [pscustomobject]@{ Server = $ci.ServerInstance; Database = $ci.DBName; Path = $Path }
}

# ------------------------------------------------------------------- acceso

$script:Conn = $null

function Invoke-Sql {
  param([string]$Sql, [hashtable]$Params)
  $cmd = $script:Conn.CreateCommand()
  $cmd.CommandText = $Sql
  $cmd.CommandTimeout = 180
  if ($Params) {
    foreach ($k in $Params.Keys) {
      $v = $Params[$k]
      if ($null -eq $v) { $v = [DBNull]::Value }
      [void]$cmd.Parameters.AddWithValue("@$k", $v)
    }
  }
  $rd = $cmd.ExecuteReader()
  $out = New-Object System.Collections.ArrayList
  while ($rd.Read()) {
    $h = @{}
    for ($i = 0; $i -lt $rd.FieldCount; $i++) {
      $val = $rd.GetValue($i)
      if ($val -is [DBNull]) { $val = $null }
      $h[$rd.GetName($i)] = $val
    }
    [void]$out.Add([pscustomobject]$h)
  }
  $rd.Close()
  ,$out
}

function ConvertTo-Local { param([datetime]$Utc) [datetime]::SpecifyKind($Utc, 'Utc').ToLocalTime() }

# ---------------------------------------------------------- blobs y tokens

function Expand-VersionData {
  param([byte[]]$Bytes)
  if ($null -eq $Bytes -or $Bytes.Length -lt 12) { return '' }
  $i = 0
  $limit = [Math]::Min(64, $Bytes.Length - 2)
  while ($i -lt $limit -and -not ($Bytes[$i] -eq 0x1F -and $Bytes[$i+1] -eq 0x8B)) { $i++ }
  if ($i -ge $limit) { return '' }
  $ms = New-Object System.IO.MemoryStream(, $Bytes[$i..($Bytes.Length - 1)])
  $gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Decompress)
  $o  = New-Object System.IO.MemoryStream
  try { $gz.CopyTo($o) } catch { return '' } finally { $gz.Dispose(); $ms.Dispose() }
  [System.Text.Encoding]::UTF8.GetString($o.ToArray())
}

<#
  El token 25 es trivia: espacios, saltos y comentarios, guardados dentro de <Word>.
  Hay que cargar con PreserveWhitespace porque XmlDocument descarta por defecto los
  nodos de texto que son solo espacios, y el fuente saldria todo pegado.
#>
function ConvertFrom-TokenStream {
  param([string]$Raw)
  $doc = New-Object System.Xml.XmlDocument
  $doc.PreserveWhitespace = $true
  $doc.LoadXml($Raw)
  $sb = New-Object System.Text.StringBuilder
  foreach ($t in $doc.DocumentElement.ChildNodes) {
    $w = $t.SelectSingleNode('Word')
    if ($w) { [void]$sb.Append($w.InnerText) }
  }
  $sb.ToString()
}

<#
  La parte Variables es un XML enorme (30 KB para un proc mediano) donde cada variable
  arrastra propiedades y un WikiPage de documentacion. En crudo es ilegible y el diff
  es inservible. La colapsamos a una linea por variable, ordenada, para que el diff
  muestre solo altas, bajas y cambios de tipo.
#>
function ConvertFrom-VariablesXml {
  param([string]$Raw)
  $doc = New-Object System.Xml.XmlDocument
  $doc.LoadXml($Raw)
  $lines = New-Object System.Collections.ArrayList
  foreach ($v in $doc.DocumentElement.ChildNodes) {
    if ($v.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
    $name = $v.GetAttribute('Name')
    if (-not $name) { continue }

    $props = @{}
    foreach ($p in $v.SelectNodes('Properties/Property')) {
      $k = $p.SelectSingleNode('Name'); $val = $p.SelectSingleNode('Value')
      if ($k -and $val) { $props[$k.InnerText] = $val.InnerText }
    }

    $bits = New-Object System.Collections.ArrayList
    if ($props['ATTCUSTOMTYPE']) {
      $m = [regex]::Match($props['ATTCUSTOMTYPE'], '<DataType>(\d+)</DataType>')
      if ($m.Success) { [void]$bits.Add("DataType=$($m.Groups[1].Value)") }
    }
    foreach ($key in @('Length', 'Decimals', 'IsCollection', 'idBasedOn')) {
      if ($props[$key]) { [void]$bits.Add("$key=$($props[$key])") }
    }
    $tag = ''
    if ($v.LocalName -eq 'StandardVariable') { $tag = ' [standard]' }
    $desc = ''
    if ($props['Description'] -and $props['Description'] -ne $name) { $desc = "  // $($props['Description'])" }
    [void]$lines.Add(('&{0}{1}  {2}{3}' -f $name, $tag, ($bits -join ' '), $desc).TrimEnd())
  }
  # ordenadas: el orden interno del XML cambia solo y ensuciaria el diff
  ($lines | Sort-Object) -join "`n"
}

function ConvertTo-Part {
  param([string]$Raw, [string]$Name)
  if ([string]::IsNullOrWhiteSpace($Raw)) {
    return [pscustomobject]@{ Text = ''; IsCode = $false }
  }
  $head = $Raw.TrimStart()
  if ($head.StartsWith('<TokenDataList')) {
    try { return [pscustomobject]@{ Text = (ConvertFrom-TokenStream $Raw); IsCode = $true } }
    catch { return [pscustomobject]@{ Text = $Raw; IsCode = $true } }
  }
  if ($head.StartsWith('<Variables')) {
    try { return [pscustomobject]@{ Text = (ConvertFrom-VariablesXml $Raw); IsCode = $false } } catch { }
  }
  try {
    $doc = New-Object System.Xml.XmlDocument
    $doc.LoadXml($Raw)
    $sw = New-Object System.IO.StringWriter
    $xw = New-Object System.Xml.XmlTextWriter($sw)
    $xw.Formatting = [System.Xml.Formatting]::Indented
    $xw.Indentation = 2
    $doc.WriteContentTo($xw); $xw.Flush()
    return [pscustomobject]@{ Text = $sw.ToString(); IsCode = $false }
  } catch {
    return [pscustomobject]@{ Text = $Raw; IsCode = $false }
  }
}

# ------------------------------------------------------- objetos vs partes

<#
  ModelEntityHistory guarda filas para objetos Y para sus partes. Un objeto tambien
  aparece como componente de su revision de KB, asi que "es componente de algo" no
  alcanza para descartarlo.
  Regla: T es CONTENEDOR si alguno de sus componentes es a su vez compuesto
  (revision -> objeto -> parte). Una entidad es PARTE si solo es componente de un
  compuesto que no es contenedor.
#>
function Get-PartEntityKeys {
  $ct = New-Object 'System.Collections.Generic.HashSet[int]'
  foreach ($r in (Invoke-Sql @"
SELECT DISTINCT o.CompoundEntityTypeId AS t
FROM EntityVersionComposition o
WHERE EXISTS (SELECT 1 FROM EntityVersionComposition i
              WHERE i.CompoundEntityTypeId = o.ComponentEntityTypeId
                AND i.CompoundEntityId     = o.ComponentEntityId)
"@)) { [void]$ct.Add([int]$r.t) }

  $parts = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($r in (Invoke-Sql 'SELECT DISTINCT ComponentEntityTypeId AS ct, ComponentEntityId AS ci, CompoundEntityTypeId AS pt FROM EntityVersionComposition')) {
    if (-not $ct.Contains([int]$r.pt)) { [void]$parts.Add("$($r.ct)/$($r.ci)") }
  }
  ,$parts
}

function Get-TypeNameMap {
  $map = @{}
  foreach ($r in (Invoke-Sql 'SELECT EntityTypeId, EntityTypeName FROM EntityType')) {
    $map[[int]$r.EntityTypeId] = $r.EntityTypeName
  }
  $map
}

function Get-ObjectName {
  param([int]$TypeId, [int]$Id)
  $r = Invoke-Sql @"
SELECT TOP 1 EntityVersionName FROM EntityVersion
WHERE EntityTypeId=@t AND EntityId=@i AND EntityVersionName IS NOT NULL AND EntityVersionName<>''
ORDER BY EntityVersionId DESC
"@ @{ t = $TypeId; i = $Id }
  if ($r.Count -eq 0) { return "<$TypeId/$Id>" }
  $r[0].EntityVersionName
}

function Get-Operations {
  param([int]$Model)
  foreach ($r in (Invoke-Sql @"
SELECT HistoryOperationSource AS src, COUNT(*) AS n,
       MIN(HistoryTimestamp) AS t0, MAX(HistoryTimestamp) AS t1
FROM ModelEntityHistory WHERE ModelId=@model
GROUP BY HistoryOperationSource ORDER BY MAX(HistoryTimestamp) DESC
"@ @{ model = $Model })) {
    [pscustomobject]@{
      Source = $r.src.ToString(); Rows = [int]$r.n
      Start  = ConvertTo-Local ([datetime]$r.t0); End = ConvertTo-Local ([datetime]$r.t1)
    }
  }
}

function Get-ChangedObjects {
  param([int]$Model, $PartKeys, $AllowedOps, [bool]$IncludeNew)

  $byObj = @{}
  foreach ($h in (Invoke-Sql @"
SELECT EntityTypeId, EntityId, HistoryEntityVersionId, HistoryTimestamp, HistoryOperationSource
FROM ModelEntityHistory WHERE ModelId=@model
ORDER BY EntityTypeId, EntityId, HistoryEntityVersionId
"@ @{ model = $Model })) {
    $key = "$($h.EntityTypeId)/$($h.EntityId)"
    if (-not $byObj.ContainsKey($key)) { $byObj[$key] = New-Object System.Collections.ArrayList }
    [void]$byObj[$key].Add($h)
  }

  $result = New-Object System.Collections.ArrayList
  foreach ($key in $byObj.Keys) {
    if ($PartKeys.Contains($key)) { continue }
    $rows = $byObj[$key]
    $last = $rows[$rows.Count - 1]
    $lastOp = $last.HistoryOperationSource.ToString()
    if ($AllowedOps -and -not $AllowedOps.Contains($lastOp)) { continue }

    $baseIdx = -1
    for ($i = $rows.Count - 1; $i -ge 0; $i--) {
      if ($rows[$i].HistoryOperationSource.ToString() -ne $lastOp) { $baseIdx = $i; break }
    }
    # toda la historia es una sola operacion: el objeto nacio aca, no hay base.
    # Sin filtro explicito no los mostramos: la creacion inicial de la KB metio miles.
    $isNew = ($baseIdx -lt 0)
    if ($isNew -and -not $IncludeNew) { continue }

    if ($isNew) { $baseVer = 0; $prevVer = 0 }
    else {
      $baseVer = [int]$rows[$baseIdx].HistoryEntityVersionId
      $prevIdx = $rows.Count - 2
      if ($prevIdx -lt 0) { $prevIdx = $baseIdx }
      $prevVer = [int]$rows[$prevIdx].HistoryEntityVersionId
    }

    $p = $key -split '/'
    [void]$result.Add([pscustomobject]@{
      EntityTypeId = [int]$p[0]; EntityId = [int]$p[1]; IsNew = $isNew
      CurrentVersion = [int]$last.HistoryEntityVersionId
      LastOpVersion = $baseVer; PrevVersion = $prevVer
      ModifiedOn = ConvertTo-Local ([datetime]$last.HistoryTimestamp)
      Operation = $lastOp.Substring(0, 8)
      Edits = @($rows | Where-Object { $_.HistoryOperationSource.ToString() -eq $lastOp }).Count
    })
  }
  $result | Sort-Object ModifiedOn -Descending
}

function Get-PartTexts {
  param([int]$TypeId, [int]$Id, [int]$VersionId)
  $map = @{}
  foreach ($p in (Invoke-Sql @"
SELECT ev.EntityTypeId, ev.EntityVersionName, ev.EntityVersionData
FROM EntityVersionComposition c
JOIN EntityVersion ev ON ev.EntityTypeId=c.ComponentEntityTypeId
                     AND ev.EntityId=c.ComponentEntityId
                     AND ev.EntityVersionId=c.ComponentEntityVersionId
WHERE c.CompoundEntityTypeId=@t AND c.CompoundEntityId=@i AND c.CompoundEntityVersionId=@v
"@ @{ t = $TypeId; i = $Id; v = $VersionId })) {
    $name = $p.EntityVersionName
    if ([string]::IsNullOrWhiteSpace($name)) { $name = "part-$($p.EntityTypeId)" }
    $map[$name] = ConvertTo-Part -Raw (Expand-VersionData $p.EntityVersionData) -Name $name
  }
  $map
}

# -------------------------------------------------------------------- diff

$script:TmpRoot = Join-Path $env:TEMP ('gxkb-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))

function New-UnifiedDiff {
  param([string]$Old, [string]$New, [string]$Label)
  if (-not (Test-Path $script:TmpRoot)) { New-Item -ItemType Directory -Path $script:TmpRoot -Force | Out-Null }
  $a = Join-Path $script:TmpRoot 'a.txt'; $b = Join-Path $script:TmpRoot 'b.txt'
  Set-Content -Path $a -Value $Old -Encoding UTF8 -NoNewline
  Set-Content -Path $b -Value $New -Encoding UTF8 -NoNewline
  # autocrlf off: el warning "LF will be replaced by CRLF" sale por stderr y
  # PowerShell lo convertiria en un error del ejecutable nativo
  $out = & git -c core.autocrlf=false -c core.safecrlf=false diff --no-index --no-color `
               --unified=4 --no-prefix -- $a $b 2>&1 |
         Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }
  if ($LASTEXITCODE -eq 0) { return $null }
  $body = @($out | Select-Object -Skip 4)
  if (-not ($body | Where-Object { $_ -match '^[+-]' })) { return $null }
  ("--- $Label (antes)`n+++ $Label (ahora)`n" + ($body -join "`n"))
}

function Get-ObjectDiff {
  param($Obj, [string]$Name, [string]$Mode)
  if ($Mode -eq 'prev') { $fromVer = $Obj.PrevVersion } else { $fromVer = $Obj.LastOpVersion }
  $oldParts = Get-PartTexts -TypeId $Obj.EntityTypeId -Id $Obj.EntityId -VersionId $fromVer
  $newParts = Get-PartTexts -TypeId $Obj.EntityTypeId -Id $Obj.EntityId -VersionId $Obj.CurrentVersion

  $names = @(@($oldParts.Keys) + @($newParts.Keys) | Select-Object -Unique | Sort-Object)
  $chunks = New-Object System.Collections.ArrayList
  foreach ($n in $names) {
    if ($n -like '*Help*' -or $n -like '*Documentation*') { continue }
    $o = ''; $nw = ''
    if ($oldParts.ContainsKey($n)) { $o  = $oldParts[$n].Text }
    if ($newParts.ContainsKey($n)) { $nw = $newParts[$n].Text }
    if ($o -eq $nw) { continue }
    $d = New-UnifiedDiff -Old $o -New $nw -Label $n
    if ($d) { [void]$chunks.Add($d) }
  }
  if ($chunks.Count -eq 0) { return $null }

  if ($Obj.IsNew) { $verLine = "OBJETO NUEVO -> $($Obj.CurrentVersion)" }
  else            { $verLine = "$fromVer -> $($Obj.CurrentVersion)" }

  (@('================================================================',
     "OBJETO   : $Name", "ENTIDAD  : $($Obj.EntityTypeId)/$($Obj.EntityId)",
     "VERSIONES: $verLine",
     "OPERACION: $($Obj.Operation)  ($($Obj.ModifiedOn.ToString('yyyy-MM-dd HH:mm')) hora local)",
     '================================================================') -join "`n") +
  "`n" + ($chunks -join "`n`n")
}

# ------------------------------------------------------------------- audit

<#
  Checks mecanicos sobre el objeto ENTERO, no solo sobre lo que cambio.
  Son extracciones deterministas: no deciden si algo es un bug, le dan al revisor
  los puntos donde mirar. Lo que no se puede detectar de forma confiable
  (codigo inalcanzable, asignaciones via parametros out de otros procs) queda
  explicitamente marcado como no cubierto.
#>
function Invoke-Audit {
  param($Parts, [string]$Name, [string]$Kind, [int]$Ver)

  $code = @($Parts.Keys | Where-Object { $Parts[$_].IsCode })
  if ($code.Count -eq 0) { return "=== $Name [$Kind] v$Ver ===`n(sin partes de codigo)" }

  # la parte de codigo mas larga es el fuente principal
  $mainName = ($code | Sort-Object { $Parts[$_].Text.Length } -Descending)[0]
  $src = $Parts[$mainName].Text
  $lines = $src -split "`r?`n"
  $allCode = ($code | ForEach-Object { $Parts[$_].Text }) -join "`n"

  $out = New-Object System.Collections.ArrayList
  [void]$out.Add("=== $Name [$Kind] v$Ver ===")
  [void]$out.Add("fuente principal : $mainName ($($lines.Count) lineas)")

  # -- parm() y parametros de salida
  $parm = ''
  foreach ($k in $code) {
    $m = [regex]::Match($Parts[$k].Text, '(?is)\bparm\s*\((.*?)\)\s*;')
    if ($m.Success) { $parm = $m.Groups[1].Value -replace '\s+', ' '; break }
  }
  if ($parm) {
    [void]$out.Add("parm             : $parm")
    foreach ($mm in [regex]::Matches($parm, '(?i)\b(out|inout)\s*:\s*&(\w+)')) {
      $vn = $mm.Groups[2].Value
      $esc = [regex]::Escape($vn)
      $assigned = [regex]::IsMatch($src, "(?im)^\s*&$esc\b[^=\r\n]*=")
      $passed   = [regex]::IsMatch($src, "(?i)\(\s*[^)\r\n]*&$esc\b[^)\r\n]*\)")
      if (-not $assigned -and -not $passed) {
        [void]$out.Add("  ! &$vn ($($mm.Groups[1].Value)) nunca se asigna en este objeto")
      } elseif (-not $assigned) {
        [void]$out.Add("  ~ &$vn ($($mm.Groups[1].Value)) solo se asignaria via llamada a otro objeto")
      }
    }
  }

  # -- returns: cada uno es una salida temprana que puede dejar parametros out sin setear
  $ret = New-Object System.Collections.ArrayList
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '(?i)^\s*return\b') { [void]$ret.Add($i + 1) }
  }
  [void]$out.Add("returns          : $($ret.Count)$(if($ret.Count){' -> lineas ' + ($ret -join ', ')})")

  # -- for each: sin where (scan completo) y anidados (N+1)
  $noWhere = New-Object System.Collections.ArrayList
  $nested  = New-Object System.Collections.ArrayList
  $feTotal = 0
  $depth = 0
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $l = $lines[$i]
    if ($l -match '(?i)^\s*for\s+each\b') {
      $feTotal++
      if ($depth -gt 0) { [void]$nested.Add($i + 1) }
      $hasWhere = $false
      for ($j = $i + 1; $j -lt $lines.Count; $j++) {
        $n = $lines[$j]
        if ($n -match '^\s*$' -or $n -match '^\s*//') { continue }
        if ($n -match '(?i)^\s*where\b')  { $hasWhere = $true; continue }
        if ($n -match '(?i)^\s*(order|unique|using|blocking|defined\s+by|skip|count)\b') { continue }
        break
      }
      if (-not $hasWhere) { [void]$noWhere.Add($i + 1) }
      $depth++
    }
    elseif ($l -match '(?i)^\s*for\s+&')   { $depth++ }
    elseif ($l -match '(?i)^\s*endfor\b')  { if ($depth -gt 0) { $depth-- } }
  }
  [void]$out.Add("for each         : $feTotal total")
  if ($noWhere.Count) { [void]$out.Add("  ! sin where (scan completo): lineas $($noWhere -join ', ')") }
  if ($nested.Count)  { [void]$out.Add("  ! anidados (N+1): lineas $($nested -join ', ')") }

  # -- codigo inline por generador: no portable, y escapa al analisis de GeneXus
  $inline = New-Object System.Collections.ArrayList
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '(?i)^\s*(CSHARP|JAVA)\b') { [void]$inline.Add($i + 1) }
  }
  if ($inline.Count) { [void]$out.Add("codigo inline    : lineas $($inline -join ', ')") }

  # -- variables declaradas y nunca referenciadas
  $varsPart = $Parts.Keys | Where-Object { $_ -like '*Variables*' } | Select-Object -First 1
  if ($varsPart) {
    $unused = New-Object System.Collections.ArrayList
    $total = 0
    foreach ($vl in ($Parts[$varsPart].Text -split "`n")) {
      $m = [regex]::Match($vl, '^&(\w+)')
      if (-not $m.Success) { continue }
      if ($vl -match '\[standard\]') { continue }
      $total++
      $esc = [regex]::Escape($m.Groups[1].Value)
      if (-not [regex]::IsMatch($allCode, "(?i)(?<![\w])&$esc(?![\w])")) {
        [void]$unused.Add('&' + $m.Groups[1].Value)
      }
    }
    [void]$out.Add("variables        : $total declaradas")
    if ($unused.Count) { [void]$out.Add("  ! declaradas y nunca usadas ($($unused.Count)): $($unused -join ', ')") }
  }

  [void]$out.Add('NO cubierto por estos checks: codigo inalcanzable, nulos, redondeo,')
  [void]$out.Add('limites de transaccion y autorizacion. Eso se revisa leyendo el fuente.')
  ($out -join "`n")
}

# -------------------------------------------------------------------- main

try {
  if ($Action -eq 'kbs') {
    Write-Host '=== KBs candidatas ===' -ForegroundColor Cyan
    $cwd = (Get-Location).Path
    if (Test-KbFolder $cwd) { Write-Host "directorio actual : $cwd" -ForegroundColor Green }
    if (Test-Path $script:ConfigPath) {
      try {
        $cfg = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
        $ok = ''; if (-not (Test-KbFolder $cfg.kbPath)) { $ok = '  (NO VALIDA)' }
        Write-Host "config            : $($cfg.kbPath)$ok"
      } catch { Write-Host "config            : ilegible" -ForegroundColor Red }
    }
    Write-Host ''
    Write-Host 'recientes de GeneXus:'
    $rec = Get-RecentKbs
    if ($rec.Count -eq 0) { Write-Host '  (ninguna)' -ForegroundColor DarkGray }
    foreach ($r in $rec) { '  {0,-19} {1}' -f $r.LastAccess.ToString('yyyy-MM-dd HH:mm'), $r.Path }
    return
  }

  if ($Action -eq 'set-default') {
    if (-not $KbPath)            { throw 'Falta -KbPath con la carpeta de la KB.' }
    if (-not (Test-KbFolder $KbPath)) { throw "'$KbPath' no contiene knowledgebase.connection." }
    $full = (Resolve-Path $KbPath).Path
    (@{ kbPath = $full } | ConvertTo-Json) | Set-Content -Path $script:ConfigPath -Encoding UTF8
    Write-Host "KB por defecto: $full" -ForegroundColor Green
    Write-Host "guardada en   : $($script:ConfigPath)" -ForegroundColor DarkGray
    return
  }

  if ($Action -eq 'doctor') {
    Write-Host '=== BWX GeneXus :: verificacion ===' -ForegroundColor Cyan
    Write-Host "PowerShell   : $($PSVersionTable.PSVersion)"
    $g = (Get-Command git -ErrorAction SilentlyContinue)
    if ($g) { Write-Host "git          : OK ($(& git --version))" -ForegroundColor Green }
    else    { Write-Host 'git          : FALTA. Es necesario para generar diffs.' -ForegroundColor Red }
    if (Test-Path $script:ConfigPath) { Write-Host "config       : $($script:ConfigPath)" -ForegroundColor Green }
    else { Write-Host "config       : no existe (opcional) -> $($script:ConfigPath)" -ForegroundColor DarkGray }
    try {
      $r = Resolve-Kb -Explicit $KbPath
      Write-Host "KB           : $($r.Path)" -ForegroundColor Green
      Write-Host "  origen     : $($r.Source)" -ForegroundColor DarkGray
      if ($r.Ambiguous) {
        Write-Host "  ojo        : hay $($r.Candidates.Count) KBs recientes. Fijala con -Action set-default." -ForegroundColor Yellow
      }
      $info = Resolve-KbConnection -Path $r.Path
      Write-Host "SQL          : $($info.Database) @ $($info.Server)"
      $c = New-Object System.Data.SqlClient.SqlConnection "Server=$($info.Server);Database=$($info.Database);Integrated Security=True;Connect Timeout=10;"
      $c.Open(); $script:Conn = $c
      $m = Invoke-Sql 'SELECT TOP 1 ModelId, COUNT(*) AS n FROM ModelEntityHistory GROUP BY ModelId ORDER BY n DESC'
      Write-Host "conexion     : OK (model $($m[0].ModelId), $($m[0].n) filas de historia)" -ForegroundColor Green
      $ops = @(Get-Operations -Model ([int]$m[0].ModelId))
      Write-Host "ultima op    : $($ops[0].End.ToString('yyyy-MM-dd HH:mm')) ($($ops[0].Rows) filas)"
      Write-Host ''
      Write-Host 'Todo listo.' -ForegroundColor Green
    } catch {
      Write-Host "KB           : $($_.Exception.Message)" -ForegroundColor Red
    }
    return
  }

  $kb   = Resolve-Kb -Explicit $KbPath
  $info = Resolve-KbConnection -Path $kb.Path
  $script:Conn = New-Object System.Data.SqlClient.SqlConnection `
    "Server=$($info.Server);Database=$($info.Database);Integrated Security=True;Application Name=bwx-gx-readonly;"
  $script:Conn.Open()

  if ($ModelId -eq 0) {
    $m = Invoke-Sql 'SELECT TOP 1 ModelId, COUNT(*) AS n FROM ModelEntityHistory GROUP BY ModelId ORDER BY n DESC'
    if ($m.Count -eq 0) { throw 'ModelEntityHistory vacia: la KB no tiene historia de objetos.' }
    $ModelId = [int]$m[0].ModelId
  }
  Write-Host "KB    : $($info.Database) @ $($info.Server)   (model $ModelId)" -ForegroundColor DarkGray
  # si no fue explicita, decir de donde salio: elegir la KB equivocada en silencio
  # (una PROD que quedo en los recientes) es peor que fallar
  if ($kb.Source -ne 'parametro -KbPath') {
    Write-Host "        $($kb.Path)  <- $($kb.Source)" -ForegroundColor DarkGray
  }

  $ops = @(Get-Operations -Model $ModelId)
  if ($Action -eq 'ops') {
    Write-Host ''
    Write-Host ('{0,-10} {1,-18} {2,-18} {3}' -f 'OPERACION', 'DESDE', 'HASTA', 'FILAS') -ForegroundColor Cyan
    foreach ($o in ($ops | Select-Object -First 30)) {
      '{0,-10} {1,-18} {2,-18} {3}' -f $o.Source.Substring(0,8),
        $o.Start.ToString('yyyy-MM-dd HH:mm'), $o.End.ToString('yyyy-MM-dd HH:mm'), $o.Rows
    }
    return
  }

  $allowed = $null
  if ($Since -or $LastOps -gt 0) {
    $sel = $ops
    if ($Since)         { $sel = $sel | Where-Object { $_.End -ge $Since } }
    if ($LastOps -gt 0) { $sel = $sel | Select-Object -First $LastOps }
    $allowed = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($o in $sel) { [void]$allowed.Add($o.Source) }
  }

  $wanted = New-Object System.Collections.ArrayList
  foreach ($n in $Objects) {
    foreach ($piece in ($n -split ',')) { $t = $piece.Trim(); if ($t) { [void]$wanted.Add($t) } }
  }
  if ($ObjectsFile) {
    if (-not (Test-Path $ObjectsFile)) { throw "No existe el archivo de objetos '$ObjectsFile'." }
    foreach ($line in (Get-Content $ObjectsFile)) {
      $t = $line.Trim()
      if ($t -and -not $t.StartsWith('#')) { [void]$wanted.Add($t) }
    }
  }
  $hasList = ($wanted.Count -gt 0)

  $partKeys  = Get-PartEntityKeys
  $typeNames = Get-TypeNameMap
  $changed = @(Get-ChangedObjects -Model $ModelId -PartKeys $partKeys -AllowedOps $allowed `
                                  -IncludeNew ($hasList -or ($null -ne $allowed)))

  $all = New-Object System.Collections.ArrayList
  foreach ($o in $changed) {
    $k = $typeNames[$o.EntityTypeId]
    if (-not $k) { $k = "type$($o.EntityTypeId)" }
    # Udm.Types.* son nodos internos del metamodelo, no objetos que uno commitee
    if ($k -like 'Udm.Types.*') { continue }
    if ($k.Length -gt 14) { $k = $k.Substring(0, 14) }
    [void]$all.Add([pscustomobject]@{
      Name = (Get-ObjectName -TypeId $o.EntityTypeId -Id $o.EntityId); Kind = $k; Obj = $o })
  }

  $named = New-Object System.Collections.ArrayList
  if ($hasList) {
    $notFound = New-Object System.Collections.ArrayList
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($w in $wanted) {
      $hits = @($all | Where-Object { $_.Name -eq $w })
      if ($hits.Count -eq 0) { $hits = @($all | Where-Object { $_.Name -like "*$w*" }) }
      if ($hits.Count -eq 0) { [void]$notFound.Add($w); continue }
      foreach ($h in $hits) {
        if ($seen.Add("$($h.Obj.EntityTypeId)/$($h.Obj.EntityId)")) { [void]$named.Add($h) }
      }
    }
    if ($notFound.Count -gt 0) {
      Write-Host ''
      Write-Host "SIN CAMBIOS DETECTADOS ($($notFound.Count)): $($notFound -join ', ')" -ForegroundColor Yellow
      Write-Host 'Nombre mal escrito, objeto sin cambios, o unica version la inicial.' -ForegroundColor DarkGray
    }
    if ($MaxObjects -lt $named.Count) { $MaxObjects = $named.Count }
  } else {
    foreach ($x in $all) {
      if ($Object -and $x.Name -notlike "*$Object*") { continue }
      [void]$named.Add($x)
    }
  }

  $targets = @($named | Select-Object -First $MaxObjects)

  switch ($Action) {
    'list' {
      Write-Host ''
      Write-Host ('{0,-44} {1,-14} {2,-18} {3,-10} {4}' -f 'OBJETO','TIPO','MODIFICADO','OPERACION','VERSIONES') -ForegroundColor Cyan
      foreach ($x in $targets) {
        $o = $x.Obj
        $s = $x.Name; if ($s.Length -gt 44) { $s = $s.Substring(0,44) }
        if ($o.IsNew) { $v = "NUEVO -> $($o.CurrentVersion)" } else { $v = "$($o.LastOpVersion) -> $($o.CurrentVersion)" }
        '{0,-44} {1,-14} {2,-18} {3,-10} {4}' -f $s, $x.Kind, $o.ModifiedOn.ToString('yyyy-MM-dd HH:mm'), $o.Operation, $v
      }
      Write-Host ''
      Write-Host "Objetos: $($named.Count)" -ForegroundColor Green
    }

    'parts' {
      foreach ($x in $targets) {
        Write-Host "`n$($x.Name) [$($x.Kind)]:" -ForegroundColor Cyan
        $p = Get-PartTexts -TypeId $x.Obj.EntityTypeId -Id $x.Obj.EntityId -VersionId $x.Obj.CurrentVersion
        foreach ($k in ($p.Keys | Sort-Object)) { '{0,-42} {1,8} chars  code={2}' -f $k, $p[$k].Text.Length, $p[$k].IsCode }
      }
    }

    'audit' {
      if ($OutDir) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
      foreach ($x in $targets) {
        $ver = $Version; if ($ver -eq 0) { $ver = $x.Obj.CurrentVersion }
        $p = Get-PartTexts -TypeId $x.Obj.EntityTypeId -Id $x.Obj.EntityId -VersionId $ver
        $rep = Invoke-Audit -Parts $p -Name $x.Name -Kind $x.Kind -Ver $ver
        if ($OutDir) {
          $f = Join-Path $OutDir (($x.Name -replace '[^\w\.\-]','_') + '.' + ($x.Kind -replace '[^\w]','') + '.audit.txt')
          Set-Content -Path $f -Value $rep -Encoding UTF8
          Write-Host "escrito: $f" -ForegroundColor DarkGray
        } else { $rep; '' }
      }
    }

    'source' {
      if ($OutDir) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
      foreach ($x in $targets) {
        $ver = $Version; if ($ver -eq 0) { $ver = $x.Obj.CurrentVersion }
        $p = Get-PartTexts -TypeId $x.Obj.EntityTypeId -Id $x.Obj.EntityId -VersionId $ver
        foreach ($k in ($p.Keys | Sort-Object)) {
          if ([string]::IsNullOrWhiteSpace($p[$k].Text)) { continue }
          if ($k -like '*Help*' -or $k -like '*Documentation*') { continue }
          $body = "===== $($x.Name) [$($x.Kind)] v$ver :: $k =====`n" + $p[$k].Text
          if ($OutDir) {
            $f = Join-Path $OutDir (($x.Name -replace '[^\w\.\-]','_') + '.' + ($x.Kind -replace '[^\w]','') +
                                    '.v' + $ver + '.' + ($k -replace '[^\w]','_') + '.gx')
            Set-Content -Path $f -Value $body -Encoding UTF8
            Write-Host "escrito: $f" -ForegroundColor DarkGray
          } else { $body; '' }
        }
      }
    }

    'diff' {
      if ($OutDir) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
      $written = 0
      foreach ($x in $targets) {
        $d = Get-ObjectDiff -Obj $x.Obj -Name "$($x.Name)  [$($x.Kind)]" -Mode $Against
        if (-not $d) { continue }
        $written++
        if ($OutDir) {
          # el tipo va en el nombre: una Transaction y su Table son homonimas
          $f = Join-Path $OutDir (($x.Name -replace '[^\w\.\-]','_') + '.' + ($x.Kind -replace '[^\w]','') + '.diff')
          Set-Content -Path $f -Value $d -Encoding UTF8
          Write-Host "escrito: $f" -ForegroundColor DarkGray
        } else { $d; '' }
      }
      Write-Host ''
      Write-Host "Objetos con diff: $written" -ForegroundColor Green
    }
  }
}
catch {
  # los errores esperables (KB sin resolver, permisos, nombre invalido) son mensajes
  # para el usuario, no fallas del script: sin stack trace de PowerShell encima
  Write-Host ''
  Write-Host $_.Exception.Message -ForegroundColor Red
  $script:Failed = $true
}
finally {
  if ($script:Conn -and $script:Conn.State -eq 'Open') { $script:Conn.Close() }
  if (Test-Path $script:TmpRoot) { Remove-Item $script:TmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
  # git diff --no-index devuelve 1 cuando hay diferencias: no es un fallo
  $global:LASTEXITCODE = 0
}
