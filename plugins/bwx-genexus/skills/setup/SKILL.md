---
name: setup
description: Verifica la instalacion del plugin bwx-genexus y el acceso a la base SQL de una KB GeneXus, y fija la KB por defecto. Usar la primera vez que alguien instala el plugin, cuando "BWX revisar commits" no encuentra la KB o apunta a la KB equivocada, o cuando pidan configurar la ruta de la KB o diagnosticar problemas de conexion.
---

# Puesta en marcha de bwx-genexus

`<script>` en los ejemplos es `scripts/gx-kb.ps1` del skill `revisar-commits`. Segun la
instalacion: `${CLAUDE_PLUGIN_ROOT}/skills/revisar-commits/scripts/gx-kb.ps1` si se
instalo como plugin, o `~/.claude/skills/revisar-commits/scripts/gx-kb.ps1` si se instalo
con `install.ps1`.

**Normalmente no hay nada que configurar.** El script encuentra la KB solo, y de la KB
saca la instancia de SQL Server y el nombre de la base leyendo
`knowledgebase.connection`. La autenticacion es la integrada de Windows, la misma que usa
GeneXus, asi que quien puede abrir la KB en el IDE ya tiene permiso de lectura.

Orden de resolucion: `-KbPath`, el directorio actual, el config `~/.bwx-genexus.json`, y
por ultimo la lista de KBs recientes de GeneXus
(`%APPDATA%\GeneXus\GeneXus\<version>\recentsKBs.xml`).

Este skill sirve para tres cosas: verificar que quedo funcionando, elegir la KB por
defecto cuando hay varias, y diagnosticar cuando algo falla.

## Paso 1: verificar

```powershell
powershell -File "<script>" -Action doctor
```

Chequea PowerShell, git, la resolucion de la KB y la conexion a SQL. Terminá cuando diga
`Todo listo`.

## Paso 2: elegir la KB por defecto si hay varias

Si `doctor` dice `AUTODETECTADA` y avisa que hay varias KBs recientes, mostrale las
candidatas al usuario y **preguntale cual quiere por defecto**. No elijas vos: es habitual
que en la lista convivan KBs de testing con una de PROD.

```powershell
powershell -File "<script>" -Action kbs
powershell -File "<script>" -Action set-default -KbPath "C:\KBs\MiKB"
```

`set-default` escribe el config por vos. No armes el JSON a mano: las rutas de Windows
necesitan barras invertidas dobles y es facil equivocarse.

El `-KbPath` explicito y el directorio actual siempre le ganan al config, asi que fijar
una por defecto no impide trabajar con otra.

## Paso 3: diagnosticar si algo falla

**`git : FALTA`** — los diffs se generan con `git diff --no-index`. Sin git no hay diffs.
Que lo instalen y este en el PATH.

**No encuentra ninguna KB** — pasa cuando GeneXus nunca se abrio en esa maquina (no hay
recientes) y se corre desde un directorio cualquiera. Que abran la KB una vez con
GeneXus, o pasar `-KbPath`.

**Falla la conexion a SQL** — en este orden:

- La instancia que sale en `knowledgebase.connection` tiene que estar levantada. Suele ser
  una instancia local con el nombre de la maquina.
- El usuario Windows necesita lectura sobre la base de la KB. Si abre la KB con GeneXus
  normalmente, ya la tiene.
- Si la KB nunca se abrio en esa maquina, el `.mdf` puede no estar attacheado todavia. Que
  la abran una vez con GeneXus y reintenten.

El script solo hace `SELECT` y no toma locks: **no hace falta cerrar el IDE**. Si algo
falla, cerrar GeneXus no es la solucion.

## Paso 4: prueba real

```powershell
powershell -File "<script>" -Action list -LastOps 1
```

Si lista objetos, quedo funcionando. Decile al usuario que ya puede pedir **"BWX revisar
commits"** con una captura de la grilla *Pending Commits* o con una lista de nombres.
