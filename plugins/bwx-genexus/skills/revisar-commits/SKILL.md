---
name: revisar-commits
description: Revisa objetos GeneXus antes de commitear a GXserver, buscando bugs tanto en los cambios como en el codigo preexistente del objeto. Extrae los diffs reales y el fuente completo leyendo la base SQL de la KB, sin lockearla y con el IDE abierto. Acepta una captura de pantalla de la grilla Pending Commits, una lista de nombres, o nada (usa la ultima sesion de trabajo). Usar cuando pidan "BWX revisar commits", revisar lo que van a subir, buscar bugs en un procedure, o ver el diff de un objeto GeneXus.
---

# Revision de commits de GeneXus

GeneXus no guarda diffs en archivos. Cada version de cada objeto vive en la tabla
`EntityVersion` de la base SQL de la KB, como header + gzip + XML, y el fuente viene
como stream de tokens. `scripts/gx-kb.ps1` reconstruye todo eso y emite diffs
unificados, el fuente completo, y una auditoria mecanica del objeto.

Solo hace `SELECT`: **no abre la KB ni toma locks**, asi que corre con el IDE abierto.

El script esta en `${CLAUDE_PLUGIN_ROOT}/skills/revisar-commits/scripts/gx-kb.ps1`.
Invocalo con `powershell -File <ruta> -Action ...`.

## Paso 0: la KB

El script la resuelve solo, en este orden: `-KbPath`, el directorio actual, el config
`~/.bwx-genexus.json`, y por ultimo la **lista de KBs recientes de GeneXus**
(`%APPDATA%\GeneXus\GeneXus\<version>\recentsKBs.xml`). En la practica no hay que
configurar nada. No inventes rutas ni cadenas de conexion: todo sale de
`knowledgebase.connection`.

Cuando la KB se autodetecta, el script imprime de donde salio. **Si dice
`AUTODETECTADA` y hay mas de una candidata, confirmá con el usuario cual es antes de
revisar nada** — en los recientes suelen convivir KBs de testing con una de PROD, y
revisar la equivocada hace perder el tiempo sin que se note. Para ver las candidatas:

```powershell
powershell -File "<script>" -Action kbs
```

Si el usuario quiere fijar una por defecto, no escribas el JSON a mano:

```powershell
powershell -File "<script>" -Action set-default -KbPath "C:\KBs\MiKB"
```

Si nada de esto resuelve, corré `-Action doctor` y seguí lo que dice.

## Paso 1: determinar QUE objetos revisar

Tres entradas posibles.

**Captura de pantalla.** Es el caso mas comun. Leé la columna `Name` de la grilla
*Pending Commits*. Los nombres suelen venir truncados con `...` y la lectura de una
imagen es falible, asi que **nunca pases directo al diff**: primero confirmá contra la KB
con `-Action list`, y para los truncados usá el prefijo (el match cae a substring solo).

```powershell
powershell -File "<script>" -Action list -Objects AssetQuote,UpdateOrder,ClientHasCash
```

Contrastá lo que devuelve con la captura antes de seguir, y **decile al usuario que
nombres no aparecieron**. Los que no matchean salen bajo `SIN CAMBIOS DETECTADOS`.

**Lista de nombres.** Igual que arriba con `-Objects`, o `-ObjectsFile` con un archivo
de un nombre por linea si son muchos.

**Nada.** Usá `-Action list -LastOps 1` (la ultima sesion de trabajo) y confirmá con el
usuario que ese es el alcance antes de gastar tiempo revisando.

Ojo con los homonimos: un nombre puede ser **varias entidades**. Una Transaction genera
ademas su Table; hay Procedures que conviven con un File del mismo nombre. La columna
`TIPO` los distingue. Al revisar una Transaction, mirá tambien su Table: los cambios de
estructura aparecen ahi.

## Paso 2: extraer

Para cada objeto confirmado, generá las tres vistas en un directorio temporal:

```powershell
powershell -File "<script>" -Action diff   -Objects <lista> -OutDir "$env:TEMP\bwxrev"
powershell -File "<script>" -Action audit  -Objects <lista> -OutDir "$env:TEMP\bwxrev"
powershell -File "<script>" -Action source -Objects <lista> -OutDir "$env:TEMP\bwxrev"
```

- **diff** (`.diff`): que cambio respecto del estado previo a la ultima operacion.
- **audit** (`.audit.txt`): checks mecanicos sobre el objeto entero.
- **source** (`.gx`): el fuente completo, necesario para juzgar el diff en contexto y
  para revisar el codigo que el usuario no toco.

Con `-Against prev` el diff compara contra la version inmediata anterior en vez del
estado pre-operacion; sirve cuando una sesion tuvo varios guardados.

## Paso 3: revisar

Revisá **las dos cosas**, y separalas al reportar:

1. **Lo que cambio** (el diff).
2. **El objeto completo** (el fuente), incluido codigo que el usuario no toco. Si el proc
   se sube, se sube entero: un bug preexistente en el mismo objeto es igual de relevante.

Empezá por el `.audit.txt`: te da los puntos donde mirar sin leer 4000 lineas. Despues
leé el fuente en esos puntos. Ignorá las partes `Help` y `Documentation`.

### Lo que el audit ya extrajo

Son extracciones deterministas, no veredictos. Confirmá cada una contra el fuente:

- **`parm` y parametros `out`/`inout`.** Marca los que nunca se asignan, o que solo se
  asignarian pasandolos a otro objeto. Cruzalo con la lista de `returns`: un parametro
  `out` que no se setea antes de un `return` temprano deja al llamador con basura.
- **`returns` con numero de linea.** Cada uno es una salida temprana. Verificá que en
  cada camino queden seteados los `out` y que no haya quedado codigo inalcanzable
  despues (ver abajo).
- **`for each` sin `where`.** Scan completo de tabla.
- **`for each` anidados.** N+1: una consulta por fila del externo.
- **Codigo inline (`CSHARP` / `JAVA`).** No portable y fuera del analisis de GeneXus.
- **Variables declaradas y nunca usadas.** Peso muerto; a veces son el resto de un
  refactor a medio hacer, y a veces delatan una asignacion que se perdio.

### Lo que el audit NO puede detectar y hay que leer

- **Codigo inalcanzable.** Un `return` incondicional agregado al final de una rama deja
  muerto todo lo que venia despues del `endif`. Es facil de introducir y silencioso:
  seguí el flujo desde cada `return` hasta el final del objeto y preguntate que se dejo
  de ejecutar. Mira especialmente si quedaron afuera validaciones, autorizaciones o
  registros de auditoria.
- **Linea comentada sin reemplazo.** Si una asignacion se comenta y no se pone otra, la
  variable queda en su default (`false`, 0, vacio), no en el valor anterior. Si el mismo
  cambio se aplico en varios lugares y en uno quedo solo el comentario, es un olvido.
  Compará todos los sitios que toca el diff.
- **Atributo nuevo dentro de un `for each`.** Puede extender la navegacion y meter otra
  tabla en el join, cambiando las filas que devuelve. Antes de reportarlo, verificá si
  ya habia otro atributo de esa misma tabla en el `for each`: si estaba, el join no
  cambia y no hay hallazgo.
- **Limites de transaccion.** `commit` movido, agregado dentro de un loop, o eliminado
  antes de un `return`.
- **Nulos.** `.SetNull()` que desaparece, o un valor donde antes se seteaba null. La
  diferencia entre null y 0 importa para las FK y para los `where`.
- **Plata y redondeo.** Cambios en `Round()`, `.Truncate()`, decimales, o el orden de
  multiplicaciones y divisiones. En este dominio (broker, custodia, eventos
  corporativos) un redondeo distinto es un bug de plata.
- **`.Call()` vs `.Udp()`.** `Call` no devuelve valor, `Udp` si. Cambiar uno por otro sin
  ajustar el uso deja la variable sin asignar.
- **Autorizacion desactivada por configuracion.** Un control de permisos que quede detras
  de un parametro que no es de permisos. Reportalo alto.
- **Errores tragados.** `try/catch` que ya no propaga, o un codigo de exito asignado en
  un camino que en realidad fallo.
- **`parm()` reordenado.** Rompe a todos los llamadores, y no se ve en el fuente del
  llamador. Si cambio el `parm`, avisá que hay que revisar los usos.
- **`Conditions`.** Filtran datos de forma global y no aparecen en el fuente principal.
- **IDs y literales hardcodeados.** Cuentas, monedas, tipos como constantes.

## Paso 4: reportar

Ordenado por severidad, y en cada hallazgo: objeto, parte, linea, que pasa y por que
importa. Distinguí siempre **introducido por este cambio** de **preexistente**, porque la
decision de si frena el commit es distinta.

Marcá explicitamente lo que no pudiste determinar (por ejemplo si una regla de negocio es
intencional) en vez de presentarlo como bug. Si no encontraste nada, decilo derecho en
lugar de rellenar con observaciones menores. Y si dejaste objetos sin revisar a fondo
porque el diff era muy grande, decí cuales.

## Limite conocido del alcance

La grilla *Pending Commits* del IDE **no se puede reproducir exactamente desde SQL**. Ese
estado lo lleva el cliente de Team Development, y un update del server que mergea deja
objetos modificados-y-pendientes sin que la historia de la KB los distinga de una edicion
local. Por eso el flujo normal es que el usuario diga que objetos va a subir (captura o
lista); `-LastOps` es una aproximacion util, no la verdad.

La lista autoritativa sale de la task MSBuild `PendingCommitObjectsTask`
(`Genexus.Server.Tasks.targets`), pero **requiere la KB cerrada** porque
`OpenKnowledgeBase` toma el lock exclusivo. Ofrecelo solo si lo piden.
