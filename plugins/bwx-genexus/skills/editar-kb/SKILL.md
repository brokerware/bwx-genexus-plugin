---
name: editar-kb
description: Lee y modifica objetos de la KB GeneXus abierta en el IDE a traves del MCP bwx-gx-bridge (gx_status, gx_get_object, gx_set_source, gx_set_variables). Usar cuando pidan "BWX editar", aplicar un cambio en un procedure u otro objeto, agregar o borrar variables, agregar una reorg, o leer el fuente actual de un objeto tal como esta en el IDE. Para revisar diffs antes de un commit usar revisar-commits.
---

# Editar objetos de la KB con bwx-gx-bridge

El MCP `bwx-gx-bridge` habla con una extension instalada en GeneXus 18 que expone la KB
**abierta en el IDE**. Lo que se guarda por aca es lo mismo que guardar desde el editor:
queda como modificacion local, aparece en *Pending Commits* y el commit a GXserver lo
hace el usuario. **Nunca commitea.**

Diferencia con `revisar-commits`: aquel lee la base SQL de la KB (historia, diffs, sin
tocar nada). Este lee y escribe el estado actual a traves del IDE. Para editar, este.

## Reglas

- **Leer antes de escribir, siempre.** `gx_set_source` y `gx_set_variables` piden el hash
  que devolvio `gx_get_object`. Si alguien edito el objeto en el medio, el bridge rechaza
  el cambio ("el fuente cambio desde que se leyo"): volver a leer y reaplicar, nunca
  forzar.
- **Se reemplaza la parte entera.** `gx_set_source` recibe el fuente completo de la parte
  (Procedure, Rules, Conditions, Events...). Partir del fuente leido y tocar solo lo pedido.
- **GeneXus valida antes de guardar.** Si el parser encuentra errores no guarda nada y
  los devuelve en `messages`. Corregir y reintentar; no hay estado a medio escribir.
- **Nombres ambiguos.** Si hay un Procedure y un File con el mismo nombre el bridge
  devuelve 409 "nombre ambiguo": pasar `type`.
- **Objetos habilitados para escritura.** El bridge solo modifica objetos cuyo nombre
  empieza con alguno de los `WritePrefixes` de `%LOCALAPPDATA%\bwx-gx-bridge\config.json`
  (por defecto `ZZBridge`). Un 403 "no esta habilitado para escritura" es eso: decirle al
  usuario que lo habilite, no buscar otra via. `["*"]` habilita toda la KB.

## Flujo

### Objetos chicos (hasta unas cientos de lineas)

1. `gx_get_object(name, type)` → devuelve cada parte con su hash, y las variables.
2. Armar el fuente nuevo de la parte.
3. `gx_set_source(name, type, part, source, expected_hash)`.
4. Volver a leer y confirmar.

### Objetos grandes: trabajar con archivos

Un procedure de miles de lineas no se puede pasar comodo como parametro ni verificar a
ojo. Usar la carpeta scratchpad de la sesion:

1. `gx_get_object(name, type, out_dir="<ruta absoluta>")` → guarda
   `<Nombre>.<Parte>.gx` y `<Nombre>.variables.json`, y devuelve solo hashes y rutas.
2. Copiar el `.gx` a un archivo nuevo y editar la copia (insertar el bloque en la linea
   exacta, verificando antes que la linea ancla es la esperada).
3. **Diff entre original y copia**: tiene que mostrar solo el cambio pedido. Si aparece
   cualquier otra cosa (finales de linea, tabs convertidos, lineas corridas) no escribir.
4. `gx_set_source(name, type, part, source_file="<copia>", expected_hash=<hash del paso 1>)`.
5. Releer con `out_dir` a otra carpeta y comparar con la copia: tienen que ser iguales.

Mantener la indentacion del objeto (normalmente tabs) y los finales de linea tal como
vinieron.

### Variables

`gx_set_variables(name, type, expected_hash=<variablesHash>, upsert=[...], remove=[...])`.
El tipo de cada variable se da con **uno** de:

| Campo | Ejemplo |
|---|---|
| `basedOnAttribute` | `{"name":"y","basedOnAttribute":"AssetId"}` |
| `basedOnDomain` | `{"name":"amount","basedOnDomain":"money"}` |
| `customType` | `{"name":"info","customType":"AssetInformation, API.v1"}` para SDT, BC u objetos externos. Copiar el valor exacto de otra variable que ya lo use (leerla con `gx_get_object`) |
| `dataType` + `length` + `decimals` | `{"name":"z","dataType":"VARCHAR","length":40}` (NUMERIC, CHARACTER, VARCHAR, LONGVARCHAR, DATE, DATETIME, Boolean, GUID) |

`isCollection: true` para colecciones. Las variables estandar (`&Pgmname`, `&Today`...) no
se listan ni se pueden borrar.

## Reorganizaciones manuales (ApplyReorganizations_*)

Pedido tipico: agregar una reorg al final del procedure de reorganizaciones.

- Confirmar cual es la ultima reorg numerada y que la nueva va despues de ella y antes del
  comentario de cierre del bloque.
- **Copiar el formato de las anteriores** (`&reorgscript = "..." + newline() + ...` y
  `do 'commitAndUpdateVersion'`), no inventar uno.
- **Preguntar el usuario** que va en el comentario (`//556 USUARIO dd/mm/aaaa`); no
  deducirlo.
- DDL y DML que dependen entre si (ALTER TABLE ADD + UPDATE de la columna nueva) van en
  **reorgs separadas**: SQL Server compila el batch entero y el UPDATE falla por columna
  inexistente.
- Tipos: en SQL Server GeneXus mapea Date y DateTime a `DATETIME`. Verificar el tipo del
  atributo antes de escribir el DDL.
- Si la columna puede existir ya en algun ambiente, avisar: un `ALTER TABLE ADD` sin
  guarda falla ahi.

## Al terminar

Listar los objetos guardados para que el usuario los revise en *Pending Commits*, y
mencionar cualquier objeto de prueba que haya quedado modificado aunque su contenido
final sea el original (ej. ZZBridgeTest).

## Si algo falla

| Sintoma | Causa |
|---|---|
| "GeneXus no esta abierto o el bridge no arranco" | No existe `%LOCALAPPDATA%\bwx-gx-bridge\session.json`: IDE cerrado o extension no instalada. Ver skill `setup` |
| "el bridge no responde" | El IDE se cerro o se reinicio; reintentar cuando este abierto |
| `gx_status` tarda o da timeout | El hilo de UI del IDE esta ocupado (un build, un dialogo modal abierto). `gxb.ps1 ping` responde sin pasar por ese hilo: si ping anda y status no, esperar o cerrar el dialogo |
| `kbOpen: false` | El IDE esta abierto sin KB |

No rodear un problema del bridge escribiendo en la base SQL de la KB: esa base es solo
lectura para este plugin.
