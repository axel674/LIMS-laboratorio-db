# LIMS Laboratorio — Base de datos

Modelo, migraciones y funciones de servidor del LIMS, sobre Supabase (PostgreSQL).

- **Proyecto Supabase:** `lims-laboratorio` (región São Paulo, `sa-east-1`)
- **Documentación del modelo:** https://dbdocs.io/maidanadiazagustin/lims-laboratorio

## Archivos

| Archivo | Qué es |
|---|---|
| `schema.dbml` | Modelo de la base, fuente de verdad. Se ve en dbdiagram.io o dbdocs. |
| `schema.sql` | El modelo en SQL de PostgreSQL, generado desde `schema.dbml`. Sirve para importar en drawDB o ChartDB. **No se ejecuta en Supabase**: incluye `auth.users`, que Supabase ya trae. |
| `migrations/20261002_01_esquema.sql` | Crea tipos, tablas, claves e índices. |
| `migrations/20261002_02_seguridad.sql` | Roles, trazabilidad automática de muestras, primer ingreso del paciente y políticas RLS. |
| `migrations/20261013_01_primer_ingreso_personal.sql` | Función `completar_primer_ingreso_personal()`: el personal baja su indicador de contraseña provisoria al elegir una propia. |
| `migrations/20261021_01_catalogo_analisis.sql` | Reglas del catálogo (código, rango de referencia, demora) y carga inicial de 5 tipos de muestra y 13 análisis de rutina. Los valores de referencia son orientativos: los tiene que revisar un bioquímico. |
| `migrations/20261022_01_fila_atencion.sql` | Fila de atención del día (se atiende por orden de llegada): `turnos` pasa a guardar el número de atención de cada paciente por día, con las funciones `registrar_llegada`, `llamar_siguiente` y `finalizar_atencion`. Agrega `configuracion` (cantidad de boxes), carga las obras sociales y exige número de afiliado cuando hay obra social. |
| `migrations/20261023_01_sucursales.sql` | Tabla `sucursales` (2 provisorias, S1 y S2, con su prefijo y sus boxes). La fila de atención, su numeración del día y los boxes pasan a ser por sucursal; `registrar_llegada` y `llamar_siguiente` reciben la sucursal (si no llega, usan la primera). `configuracion` queda sin uso. |
| `migrations/20261023_02_localidad_sucursal.sql` | `sucursales.localidad` (San Miguel y Concepción), que el panel muestra al lado del logo. |
| `migrations/20261028_01_rls_sucursal.sql` | RLS por sucursal: `personal.sucursal_id` y `ordenes.sucursal_id`, la función `privado.sucursal_actual()` y las políticas de órdenes, estudios, muestras, resultados e informes filtradas por la sucursal del empleado. El admin sigue viendo todo. |
| `migrations/20261029_01_ordenes.sql` | Órdenes médicas (LIMS-10): el número lo genera la base (prefijo de la sucursal + año + correlativo, ej. `S1-2026-000123`); un turno puede tener varias órdenes; médico obligatorio; `fecha_orden`, anulación con motivo y `orden_analisis.cubierto` (estudios que la obra social no cubre). Funciones `crear_orden`, `modificar_orden` y `anular_orden`, que guardan la orden y sus estudios juntos. |
| `migrations/20261029_02_grupos_estudios.sql` | Grupos de estudios (LIMS-27): carga los estudios de rutina que faltaban (hemograma completo, eritrosedimentación, HDL, LDL y hepatograma), las reglas de `grupos_analisis`, los grupos "Sangre completa" y "Hepatograma", la función `guardar_grupo` (grupo y estudios juntos) y el grupo de cada estudio en `crear_orden` y `modificar_orden`. |
| `migrations/20261029_03_resultados.sql` | Carga de resultados y fuera de rango (LIMS-12 y LIMS-13): `analisis_rangos` (valores de referencia por sexo y edad, orientativos), `rango_de_estudio` / `rangos_de_orden`, reglas del resultado (número o texto según el estudio, marca fuera de rango, se corrige hasta que se valida, quién lo cargó), recepción también carga, la orden pasa a "en proceso" con el primer resultado y `guardar_resultados`. |
| `migrations/20261029_04_componentes_y_llegada.sql` | Estudios con componentes: la fórmula leucocitaria se informa con 5 valores en % (con su rango) y la base calcula el absoluto con los glóbulos blancos de la orden y lo recalcula si cambian; al agregar el estudio a una orden se agregan sus componentes. Una orden cargada antes de la llegada del paciente se une sola al turno cuando se registra su llegada ese día. |
| `functions/crear-paciente/` | Edge Function: recepción o un admin dan de alta un paciente con contraseña provisoria, su obra social (o particular) y número de afiliado. Devuelve el id de la ficha. |
| `functions/crear-personal/` | Edge Function: un administrador da de alta a una persona del personal (cuenta, perfil y datos de personal) con contraseña provisoria. |
| `seed_usuarios_prueba.sql` | Usuarios de prueba (admin, recepción, bioquímico y un paciente). Solo para desarrollo. |
| `pruebas/rls_sucursal.sql` | Prueba del aislamiento por sucursal: arma datos en las dos sucursales, simula el ingreso de cada cuenta y verifica qué ve. Termina en `ROLLBACK`: no deja datos. |

Las doce migraciones se aplican en orden en el proyecto de Supabase; las dos Edge Functions se despliegan con la CLI.

## Cómo se actualiza el modelo

1. Editar `schema.dbml`.
2. Regenerar el SQL: `npx -p @dbml/cli dbml2sql schema.dbml --postgres -o schema.sql`
   El modelo usa `?>?` (relación opcional de dbdiagram), que el CLI todavía no reconoce. Si falla, generar desde
   una copia con `?>?` cambiado por `>`: en SQL la clave foránea es la misma, la opcionalidad la da la columna que acepta nulos.
3. Escribir el cambio como una **migración nueva** en `migrations/` (no editar las ya aplicadas).
4. Publicar la documentación: `dbdocs build schema.dbml --project lims-laboratorio`

## Seguridad en pocas palabras

- Todas las tablas tienen RLS. Sin sesión no se accede a nada.
- Un paciente solo ve su ficha, sus turnos, sus órdenes y sus informes **publicados**.
- El personal ve según su rol (`admin`, `bioquimico`, `tecnico`, `recepcion`).
- Cada empleado pertenece a una sucursal (`personal.sucursal_id`) y solo ve las órdenes, muestras, resultados e
  informes de esa sucursal. El admin ve todas y puede elegir con cuál trabajar. Una cuenta sin sucursal asignada
  no ve datos de ninguna hasta que el admin se la asigne.
- Cada alta o cambio de estado de una muestra queda registrado solo en `movimientos_muestra`,
  con usuario, fecha y hora. Esa tabla no se puede editar ni borrar.
- Una muestra no se puede rechazar sin `motivo_rechazo`.
