---
name: comparar-con-xcale
description: Revisa que commits de GeneXus de un equipo no estan en xcale (fixes perdidos, cambios a medias o funcionalidad no migrada) y arma un Excel de seguimiento con motivo, evidencia, impacto y plataformas afectadas. Lee el historial del GeneXus Server con gx_history, saca el diff de cada commit de la KB y lo compara contra una rama de xcale. Solo lectura. Usar cuando pidan "BWX comparar con xcale", revisar que cambios del legacy faltan en xcale, el pasaje legacy a xcale de un equipo, o que commits de GeneXus no se migraron.
---

# Comparar commits de GeneXus contra xcale

El objetivo es que ningun cambio del legacy se pierda en el pasaje a xcale. Para cada
commit del equipo en GeneXus Server se decide si el cambio esta en xcale, y si no, por
que y donde deberia ir.

**Todo es solo lectura**: no se hace Update ni Commit en GeneXus, no se escribe en la KB
y no se toca el codigo de xcale. El resultado es un Excel (y, si lo piden, un resumen
para compartir).

## Paso 0: lo que hay que preguntar antes de arrancar

No lo adivines: pregunta lo que falte.

1. **El equipo y sus firmas.** El usuario del server es siempre `Local\gxuser`: el autor
   real sale del comentario del commit ("Arosa -> ...", "RR - ...", "BMendizabal - ...").
   Pedi el nombre de cada integrante y como firma (puede firmar de varias formas, o poner
   el nombre despues del numero de ticket).
2. **El periodo.** Por defecto el ultimo mes; despues se baja de a uno o dos meses.
3. **El repo de xcale y la rama** contra la que se compara (normalmente `test`), ya
   actualizada (`git pull`). Anota el hash: va en el Excel.
4. **Donde guardar el Excel** (la carpeta de documentacion del equipo).

Requisitos: GeneXus 18 abierto con la KB, el bridge 0.3.0 o mas (`gx_status`) y la
herramienta `gx_history` (si no aparece, actualizar el plugin e instalar el bridge con
`install-bridge.ps1 -Update`, ver README).

## Paso 1: traer el historial

```
gx_history  version=Testing  from=2026-10-26  to=2026-11-26  out_file=<ruta>\history.json
```

- Devuelve, por commit: `id`, `date` (hora local), `comment` y `objects` (nombre, tipo,
  descripcion, operacion). El `user` de cada objeto es la ultima maquina que lo edito, no
  el autor del commit.
- El server pagina de a 50 commits, del mas nuevo al mas viejo. Si `complete` da false,
  subi `max_pages`. Para un periodo viejo conviene `first_page` alto (cada pagina son 50).

Filtra por las firmas del equipo. Los comentarios **sin firma** (solo un ticket, "fix:",
iniciales desconocidas) se cargan igual marcados `Sin autor` para que el
usuario los confirme: suelen ser del equipo o de otro equipo que toca lo mismo.

## Paso 2: el Excel

Una hoja **Commits** con una fila por commit, ordenada del mas nuevo al mas viejo:

| Columna | Contenido |
|---|---|
| # | Numero de commit del server |
| Fecha | Del historial (hora local) |
| Mes | Formula `=YEAR(B2)&"-"&TEXT(MONTH(B2),"00")` (no `TEXT(B2,"yyyy-mm")`: falla en un Excel en espanol) |
| Autor | Nombre del integrante, `Sin autor` o el de otro equipo |
| Comentario | Completo |
| Objetos | Nombres separados por coma; los que no son Modified con `[Inserted]` / `[Deleted]` |
| Toca la plataforma del equipo | Si / No / A revisar |
| Por que | Motivo corto de la marca anterior |
| Esta en xcale | Si / Parcial / No / A revisar / No aplica |
| Motivo | Si es Parcial o No: que falta y por que. Distinguir **fix perdido** (xcale tiene la funcionalidad pero sin este cambio) de **funcionalidad no migrada** (el proceso o reporte entero no existe todavia) |
| Evidencia xcale | `archivo:linea` que lo confirma o donde falta |
| Impacto | Alto (plata o contabilidad) / Medio (dato o flujo incorrecto) / Bajo (cosmetico o borde) |
| Plataformas afectadas | Que apps de xcale usan ese codigo (ver Paso 5) |
| Cambios en front (bx-*) | Ramas o PRs de los repos `bx-*` que acompanan al commit, con "Si" o "Posible" (ver Paso 6) |
| Tipo / Documento de prueba | Solo si hay Trello conectado: bug, mejora o desarrollo, y el "Como probarlo" de la tarjeta (ver Paso 6) |
| Notas | Lo que no se pudo verificar, diffs mezclados, autor a confirmar |

Mas una hoja **Resumen** por mes (`COUNTIFS` sobre Mes, Toca la plataforma y Esta en xcale) y una
**Leyenda** con el criterio de cada columna. Listas desplegables en las columnas de
estado. Con openpyxl: fuente Arial, encabezado fijo, filtros.

Si el usuario tiene el Excel abierto, no lo sobrescribas: escribi por COM
(`[Runtime.InteropServices.Marshal]::GetActiveObject('Excel.Application')`), con los
valores casteados a `[string]` / `[double]` (un PSObject sin castear tira
`InvalidCastException`), y guarda con `$wb.Save()`. Antes de cerrarlo para regenerarlo,
verifica `$wb.Saved`: si hay cambios sin guardar, no lo cierres.

## Paso 3: el diff de cada commit

GeneXus no guarda diffs: cada version de cada objeto esta en `EntityVersion` de la base
de la KB. El script de `revisar-commits` reconstruye el fuente de una version:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<gx-kb.ps1>" -Action source -Objects <Objeto> -Version <N> -OutDir <dir>\<Objeto>\v<N>
```

Para elegir las versiones, lista las de cada objeto con su fecha:

```sql
SELECT EntityVersionName, EntityVersionId, EntityVersionTimestamp
FROM EntityVersion WHERE EntityVersionName IN ('Objeto1','Objeto2') AND EntityTypeId = 37
ORDER BY EntityVersionName, EntityVersionId
```

(37 = Procedure.) Despues `git diff --no-index` entre la version anterior y la del commit.

Trampas conocidas:

- **Cada version tarda ~45 s.** Corre la extraccion en segundo plano y, mientras tanto,
  busca en xcale.
- **Versiones que mezclan commits.** La KB guarda una version por Update, no por commit.
  Antes de atribuir un diff, mira en el historial que otros commits tocaron el mismo
  objeto entre esas dos versiones; si hay de otros equipos, quedate solo con lo del commit
  y anotalo en Notas.
- **Diff vacio.** A veces la version anterior y la del commit tienen el mismo codigo (el
  cambio no quedo en la KB local). No lo marques: queda `A revisar` y se mira con
  *Compare* en el History del IDE.
- **Sin version anterior** (commits viejos). Usa el objeto vivo (`gx_get_object`) y el
  comentario del commit para ubicar la logica, y decilo en Notas.
- **Lo comentado no cuenta.** Si en el objeto vivo la logica del commit esta comentada,
  no corresponde portarla.

## Paso 4: comparar contra xcale

1. **Ubica el equivalente.** xcale cita los nombres del legacy en minuscula en sus
   comentarios (`getinvoicestrade`, `pnewcorporateevent`, `managegcpool`): grepea el nombre
   del objeto y el de las variables o parametros que agrega el commit.
2. **Compara la logica puntual del diff**, no la existencia del objeto: un redondeo vs un
   truncado, la fecha que se usa, una condicion nueva, un parametro que se lee.
3. **Mira si se arreglo hace poco**: `git log -S"<texto>" -- <ruta>` (un hallazgo viejo
   puede estar resuelto en un PR de ayer).
4. Decidi el estado y escribi Motivo, Evidencia (`archivo:linea`) e Impacto.

Si hay un analisis previo de otra persona, cargalo en Notas marcado como tal ("Analisis
previo: ...") y verificalo: puede estar desactualizado o equivocado.

## Paso 5: plataformas afectadas

Sirve para avisarles a los otros equipos que un cambio los toca (y para que ellos nos
avisen a nosotros). Para cada commit:

1. **Endpoint de xcale** que ejecuta el codigo del cambio (el controller del use case o
   servicio que encontraste en el Paso 4).
2. **Que apps lo llaman**: grepea la ruta en `frontend/apps/*/src` (account, accounting,
   advisor, backoffice, compliance, config, finance, funds, middle, onboarding, portal,
   security, trader) y en `frontend/packages` (componentes compartidos: segui que apps los
   importan).
3. **Del lado de GeneXus**, quien llama al objeto: los `Client.v1.*` son del portal del
   cliente; los `API.v1.*` los usan los fronts `bx-*`.
4. Los procesos programados (jobs) y los calculos que cambian saldos o posiciones afectan
   tambien a quien ve esos datos: anotalo ("impacta lo que ven Advisor y Portal").

Escribilo como lista corta: `Backoffice (Ops), Advisor, Trader`. Si es una estimacion por
modulo y no se verifico pantalla por pantalla, decilo en la Leyenda.

## Paso 6: el resto del cambio (front y Trello)

Un commit de GeneXus muchas veces viene con cambios en los repos `bx-*` (bx-react-ui,
bx-api, bx-backoffice, bx-advisor-client, ...). Si el back esta en xcale pero el front no,
el cambio sigue incompleto.

**GitHub (siempre).** Los repos `bx-*` estan en la org de GitHub; se buscan sin clonarlos:

```bash
gh search commits --owner <org> "<ticket>" --json repository,commit,url
gh search prs     --owner <org> "<ticket>" --json repository,number,title,url
gh search commits --owner <org> --author <login> --author-date 2026-08-01..2026-11-30 --json repository,commit,url
```

- Quedate con los repos que empiezan con `bx`.
- El numero de ticket suele estar en el **nombre de la rama**, y queda en el mensaje del
  merge ("Merge branch '664277-Front-prod' into 'prod'"). El que mergea no es
  necesariamente el autor.
- Para los commits sin ticket: trae los commits de cada integrante en los `bx-*` del
  periodo (una busqueda por autor y rango, no una por commit) y cruzalos por fecha cercana
  y tema ("fix(collateral): validacion de maturity" con "Fix vencimiento de collaterals").
  Los logins salen de `gh api orgs/<org>/members`.
- Marca **Si** cuando coincide el ticket o el tema es inequivoco, y **Posible** cuando solo
  coinciden la epoca y el tema. Que no aparezca no prueba que no hubo front: hay commits
  firmados con mails no vinculados a GitHub.
- La busqueda de GitHub limita a ~30 consultas por minuto: espera 2-3 s entre consultas.

**Trello (si esta conectado el conector de Trello).** Las tarjetas se crean por proyecto
(una para el commit de GeneXus, otra por cada MR de `bx-*`) y se linkean entre si. Para cada
commit: busca la tarjeta por numero de commit ("Commit 5885") o de ticket, segui los links a
las tarjetas de los otros proyectos, y toma de la descripcion el tipo (bug, mejora o
desarrollo) y el "Como probarlo" como documento de prueba. El conector se autoriza por
espacio de trabajo: si no aparece ninguno, el usuario es invitado del tablero y no miembro
del Workspace, y tiene que pedir que lo agreguen. Sin Trello, el resto del flujo funciona
igual.

## Paso 7: reportar

Al cerrar cada periodo: una tabla corta con cada commit, que hace y si esta. Al final, el
total por estado y la lista de **fixes perdidos ordenada por impacto**: es lo primero que
hay que corregir. Lo que quedo `A revisar` va con lo que falta para cerrarlo (un diff, un
caso real, la confirmacion del autor).
