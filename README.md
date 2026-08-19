# bwx-genexus

Revision de commits de GeneXus desde Claude Code. Saca los diffs reales de los objetos de
una KB y audita el objeto completo antes de subirlo a GXserver.

GeneXus no guarda diffs en archivos. Cada version de cada objeto vive en la tabla
`EntityVersion` de la base SQL de la KB: un header corto, un stream gzip, y adentro XML
donde el fuente viene como stream de tokens. Este plugin reconstruye el fuente tal cual se
ve en el IDE y lo diffea con git.

**Solo hace `SELECT`. No abre la KB ni toma locks: funciona con el IDE abierto.**

## Instalacion

### Opcion A: instalador (funciona siempre)

Una linea en PowerShell. No necesita el CLI de Claude Code, asi que sirve tambien en la
app de escritorio:

```powershell
irm https://raw.githubusercontent.com/brokerware/bwx-genexus-plugin/main/install.ps1 | iex
```

Copia los skills a `~/.claude/skills`, que es donde Claude Code los busca en cualquier
instalacion. Corriendolo de nuevo actualiza a la ultima version.

Si ya tenes el repo clonado, desde la carpeta del clon:

```powershell
.\install.ps1
```

> El repo es privado: hace falta acceso a la org `brokerware` y tener git configurado con
> credenciales de GitHub.

### Opcion B: mecanismo de plugins

Solo si tenes instalado el **CLI** `claude` (requiere Node 18+). Dentro de la sesion
interactiva de Claude Code, no en la shell:

```
/plugin marketplace add brokerware/bwx-genexus-plugin
/plugin install bwx-genexus@bwx
```

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
