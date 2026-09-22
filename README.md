# bwx-genexus

GeneXus desde Claude Code. Dos funcionalidades independientes:

- **Revision de commits** (`BWX revisar commits`). Saca los diffs reales de los objetos
  de una KB y audita el objeto completo antes de subirlo a GXserver. Solo lectura.
- **Edicion de objetos** (`BWX editar`). Lee y modifica objetos de la KB abierta en el
  IDE, a traves de una extension de GeneXus 18 y el servidor MCP `bwx-gx-bridge`. Ver
  [Editar objetos](#editar-objetos-bwx-gx-bridge).

## Revision de commits

GeneXus no guarda diffs en archivos. Cada version de cada objeto vive en la tabla
`EntityVersion` de la base SQL de la KB: un header corto, un stream gzip, y adentro XML
donde el fuente viene como stream de tokens. Este plugin reconstruye el fuente tal cual se
ve en el IDE y lo diffea con git.

**Solo hace `SELECT`. No abre la KB ni toma locks: funciona con el IDE abierto.**

## Instalacion

### Opcion A: instalador (funciona siempre)

No necesita el CLI de Claude Code, asi que sirve tambien en la app de escritorio. Una
linea en PowerShell:

```powershell
irm https://raw.githubusercontent.com/brokerware/bwx-genexus-plugin/main/install.ps1 | iex
```

Clona el repo en `%LOCALAPPDATA%\bwx-genexus-plugin` y copia los skills a
`~/.claude/skills`, que es donde Claude Code los busca en cualquier instalacion.

Si hay Node 18+ en el PATH, registra ademas el servidor MCP `bwx-gx-bridge` en
`~/.claude.json` (sin Node se instalan solo los skills). El MCP necesita la extension del
IDE, que se instala aparte: ver [Editar objetos](#editar-objetos-bwx-gx-bridge).

Para **actualizar**, el mismo comando: si ya esta clonado hace `git pull` y recopia.

Requiere `git` en el PATH (que igual hace falta para generar los diffs).

### Opcion B: mecanismo de plugins

Solo si tenes instalado el **CLI** `claude` (requiere Node 18+). Se tipea dentro de la
sesion interactiva de Claude Code, **no en la shell**:

```
/plugin marketplace add brokerware/bwx-genexus-plugin
/plugin install bwx-genexus@bwx
```

Esta opcion ya trae el servidor MCP. Si ademas corres el instalador de la Opcion A (por
ejemplo para tener el clon con el instalador de la extension), pasale `-NoMcp` para no
registrar el MCP dos veces:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/brokerware/bwx-genexus-plugin/main/install.ps1))) -NoMcp
```

### Configuracion

**No hay nada que configurar.** El plugin encuentra la KB solo y de ahi saca la instancia
de SQL Server y el nombre de la base, leyendo `knowledgebase.connection`. La autenticacion
es la integrada de Windows, la misma que usa GeneXus: quien puede abrir la KB en el IDE ya
tiene permiso de lectura.

Orden de resolucion: `-KbPath`, el directorio actual, el config `~/.bwx-genexus.json`, y
por ultimo la **lista de KBs recientes de GeneXus** (el mismo `recentsKBs.xml` que usa el
IDE). Por eso alcanza con haber abierto la KB una vez.

Si hay varias KBs recientes, el plugin usa la de acceso mas reciente y **avisa que la
autodetecto**. Para fijar una:

```
BWX setup
```

o directo:

```powershell
& gx-kb.ps1 -Action kbs                                    # ver candidatas
& gx-kb.ps1 -Action set-default -KbPath "C:\KBs\MiKB"      # fijar por defecto
```

Requiere Windows, PowerShell 5.1+ y `git` en el PATH.

## Uso

```
BWX revisar commits
```

Con una captura de la grilla *Pending Commits* pegada, con una lista de nombres, o sin
nada (usa la ultima sesion de trabajo). Revisa dos cosas y las reporta separadas: lo que
cambio, y el objeto completo — incluido codigo preexistente que no tocaste, porque si el
proc se sube, se sube entero.

## El script directo

`plugins/bwx-genexus/skills/revisar-commits/scripts/gx-kb.ps1` se puede usar suelto:

| Accion | Que hace |
|---|---|
| `-Action doctor` | Verifica instalacion, resolucion de la KB y conexion |
| `-Action kbs` | Lista las KBs candidatas (actual, config, recientes de GeneXus) |
| `-Action set-default` | Fija la KB por defecto en `~/.bwx-genexus.json` |
| `-Action ops` | Operaciones recientes sobre la KB (sesiones de trabajo, updates, imports) |
| `-Action list` | Objetos cambiados, con tipo y versiones |
| `-Action diff` | Diff unificado por objeto |
| `-Action source` | Fuente completo reconstruido |
| `-Action audit` | Checks mecanicos sobre el objeto entero |
| `-Action parts` | Partes de un objeto y su tamano |

Seleccion de objetos: `-Objects a,b,c`, `-ObjectsFile lista.txt`, `-Object <substring>`,
`-LastOps N`, `-Since <fecha>`. Salida a archivos con `-OutDir`.

```powershell
$s = "$env:USERPROFILE\.claude\plugins\...\gx-kb.ps1"
& $s -Action diff  -Objects UpdateOrder,ClientHasCash -OutDir "$env:TEMP\rev"
& $s -Action audit -Objects UpdateOrder
```

## Detalles que importan

- **Los timestamps de la KB estan en UTC.** El script los pasa a hora local; un
  `15:31` de la grilla es `18:31` en la base.
- **Un nombre puede ser varias entidades.** Una Transaction genera ademas su Table, y hay
  Procedures con un File homonimo. Por eso hay columna `TIPO` y los archivos se llaman
  `<Nombre>.<Tipo>.diff`.
- **La grilla *Pending Commits* no se puede reproducir exactamente desde SQL.** Ese estado
  lo lleva el cliente de Team Development: un update del server que mergea deja objetos
  modificados-y-pendientes sin que la historia de la KB los distinga de una edicion local.
  Por eso lo normal es decirle que objetos vas a subir. `-LastOps` es una aproximacion.
  La lista autoritativa sale de la task MSBuild `PendingCommitObjectsTask`, pero esa
  **requiere la KB cerrada**.
- **La parte `Variables` se colapsa a una linea por variable**, ordenada. En crudo son 30 KB
  de XML por procedure y el diff es inservible.

## Editar objetos (bwx-gx-bridge)

Claude lee y modifica objetos de la KB **abierta en el IDE**: el fuente de cada parte
(Procedure, Rules, Conditions, Events...) y las variables. Guardar por aca es lo mismo
que guardar desde el editor: el cambio queda como modificacion local, aparece en
*Pending Commits* y el commit a GXserver lo haces vos. **Nunca commitea.**

```
Claude Code --stdio--> MCP bwx-gx-bridge (Node) --HTTP 127.0.0.1 + token--> extension Bwx.GxBridge (dentro del IDE)
```

- La extension es un package de GeneXus 18. Al cargar levanta un servidor HTTP solo en
  `127.0.0.1`, con un token aleatorio por sesion, y escribe puerto y token en
  `%LOCALAPPDATA%\bwx-gx-bridge\session.json`. El MCP lee ese archivo en cada llamada,
  asi que sobrevive a reinicios del IDE.
- Todo acceso a la KB corre en el hilo de UI del IDE, el mismo en el que editas: no hay
  carreras con el editor.
- **GeneXus valida antes de guardar.** Si el fuente tiene errores no se guarda nada y
  vuelven los mensajes del parser.
- **Control de concurrencia por hash.** Cada escritura lleva el hash de lo que se leyo;
  si el objeto cambio en el medio (lo editaste vos, o un update), se rechaza.

### Setup

Requisitos: GeneXus 18, Node 18+ y, para compilar la extension, el
[.NET SDK](https://dot.net) (opcional: sin SDK se baja el DLL del ultimo Release).

1. **MCP.** Viene con el plugin: con la Opcion A lo registra `install.ps1`; con la
   Opcion B ya esta. Reiniciar Claude Code despues de instalar.
2. **Extension del IDE.** Una sola vez, con **GeneXus cerrado**, en un PowerShell **como
   administrador**:

   ```powershell
   & "$env:LOCALAPPDATA\bwx-genexus-plugin\bridge\install-bridge.ps1"
   ```

   Compila `bridge/src` contra los ensamblados de tu instalacion de GeneXus (o baja el
   DLL si no hay .NET SDK), lo copia a `<GeneXus18>\Packages`, te da permiso de escritura
   sobre ese archivo y corre `GeneXus.exe /install` para registrar el package. Si GeneXus
   no esta en la ruta por defecto: `-GxDir "D:\GeneXus18"`.
3. **Probar.** Abrir GeneXus y la KB, y pedirle a Claude `BWX setup`, o directamente
   `gx_status`: tiene que devolver `kbOpen: true` y el nombre de la KB.

**Actualizar la extension** (despues de actualizar el repo), con GeneXus cerrado y sin
administrador:

```powershell
& "$env:LOCALAPPDATA\bwx-genexus-plugin\bridge\install-bridge.ps1" -Update
```

**Desinstalar:** el mismo script con `-Uninstall`, como administrador.

### Que objetos se pueden modificar

Lo decide `WritePrefixes` en `%LOCALAPPDATA%\bwx-gx-bridge\config.json`, que se crea la
primera vez que arranca el bridge. **Por defecto solo los objetos que empiezan con
`ZZBridge`**, para probar sin riesgo:

```json
{"Port":0,"WritePrefixes":["ZZBridge"]}
```

Para trabajar de verdad, agregar prefijos (`["ZZBridge","Asset","CDA_"]`) o `["*"]` para
toda la KB. Se relee en cada escritura: no hace falta reiniciar el IDE. La lectura no
tiene restricciones. `Port: 0` elige un puerto libre.

### Uso

```
BWX editar
```

o directamente el pedido: "agrega este fallback en CDA_V1 dentro del For Each de
getOrder", "agrega una variable &x basada en AssetId a ZZBridgeTest", "agrega la reorg
556 con este ALTER TABLE". El skill `editar-kb` le indica a Claude como trabajar: leer
antes de escribir, tocar solo lo pedido, verificar con diff y releer despues de guardar.
Al terminar te lista los objetos que quedaron para revisar en *Pending Commits*.

Herramientas del MCP:

| Herramienta | Que hace |
|---|---|
| `gx_status` | KB abierta, modelo, version del bridge y `WritePrefixes` |
| `gx_get_object` | Fuente de cada parte con su hash, y variables con su hash. Con `out_dir` guarda las partes en archivos (`<Nombre>.<Parte>.gx`) y devuelve solo hashes y rutas: es lo que se usa con objetos grandes |
| `gx_set_source` | Reemplaza el fuente completo de una parte y guarda. El fuente va en `source` o, para objetos grandes, en un archivo (`source_file`). Requiere el hash leido |
| `gx_set_variables` | Agrega, modifica o borra variables. Tipo por atributo, dominio, `customType` (SDT/BC/externos) o `dataType` + `length` + `decimals` |

### Cliente de consola

`bridge/gxb.ps1` habla con la extension sin pasar por Claude. Sirve para diagnosticar:

```powershell
$g = "$env:LOCALAPPDATA\bwx-genexus-plugin\bridge\gxb.ps1"
& $g ping                                   # responde aunque el IDE este ocupado
& $g status
& $g get -Name ZZBridgeTest -OutDir "$env:TEMP\gx"
& $g set -Name ZZBridgeTest -Part Procedure -File "$env:TEMP\gx\ZZBridgeTest.Procedure.gx" -ExpectedHash <hash>
```

### Si algo falla

| Sintoma | Que mirar |
|---|---|
| "GeneXus no esta abierto o el bridge no arranco" | No hay `session.json`: el IDE esta cerrado o la extension no cargo. Ver `%LOCALAPPDATA%\bwx-gx-bridge\bridge.log` y que el DLL este en `Packages` |
| `gx_status` tarda o da timeout | `gxb.ps1 ping`: si responde, el bridge esta vivo y el hilo de UI del IDE esta ocupado (dialogo modal, build). En el log tiene que figurar `contexto de UI` |
| "no esta habilitado para escritura" | El objeto no esta en `WritePrefixes` |
| "el fuente cambio desde que se leyo" | Alguien modifico el objeto despues de la lectura: volver a leer y reaplicar |
| "nombre ambiguo" | Hay varios objetos con ese nombre (ej. Procedure y File): indicar el tipo |
| El MCP no aparece en Claude Code | Reiniciar Claude Code. Con la Opcion A, verificar `mcpServers.bwx-gx-bridge` en `~/.claude.json`; si falta, reinstalar con Node en el PATH |
