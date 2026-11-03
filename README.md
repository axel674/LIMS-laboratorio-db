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
| `migrations/20261030_01_validacion_orden.sql` | Validación final del bioquímico y cierre de la orden (LIMS-14): la función `validar_orden` guarda los valores, valida todos los resultados con quién y cuándo, pasa la orden a "completa" y crea el informe en borrador, todo o nada. Una orden validada no se puede modificar. |
| `migrations/20261030_02_informe_pdf.sql` | Informe PDF (LIMS-15): bucket privado `informes` (un PDF por orden en `<paciente_id>/<orden_id>.pdf`) con sus políticas (el paciente baja solo los suyos publicados, el personal los de su sucursal, solo el bioquímico sube), la función `publicar_informe` (deja el informe firmado con el SHA-256 del archivo, publicado, y la orden informada) y un trigger que impide modificar un informe publicado. |
| `migrations/20261031_01_aranceles.sql` | Aranceles (LIMS-32), según el Nomenclador Bioquímico Único: unidades bioquímicas (`ub`) y código NBU de cada estudio; tabla `valores_ub` (valor de la UB del particular y de cada obra social, con su coseguro en % y desde cuándo rige); cada estudio de la orden guarda su precio al cargarse (`importe_paciente` e `importe_obra_social`) y se recalcula si cambia la obra social de una orden abierta. Carga valores de ejemplo, a reemplazar por los reales. |
| `migrations/20261101_01_rangos_sin_superponer.sql` | Rangos por sexo y edad editables desde el panel (LIMS-29): dos rangos del mismo estudio y el mismo sexo no pueden cubrir la misma edad (un rango para "todos" sí convive con uno de un sexo, porque se elige primero el del sexo). |
| `migrations/20261101_02_mensaje_rango.sql` | El aviso de rango superpuesto muestra las edades como el panel ("18 años o más", "1 a 17 años"). |
| `migrations/20261101_03_portal_paciente.sql` | Portal del paciente (LIMS-17): deja que el paciente lea el médico de sus propias órdenes, para que el portal pueda mostrar quién pidió los estudios. Las órdenes y los informes publicados ya los veía por las políticas de RLS. |
| `migrations/20261102_01_acido_urico.sql` | Da de alta el ácido úrico (URIC) con los datos que tiene en Supabase (unidad, rango general, UB, su lugar en Sangre completa y sus rangos por sexo y edad), porque ninguna migración lo creaba. En Supabase no cambia nada. |
| `migrations/20261102_02_orden_sin_medico.sql` | Orden sin pedido médico (LIMS-33): el médico deja de ser obligatorio y una orden sin médico no puede tener obra social, así que se cobra a valor particular. |
| `migrations/20261102_03_rotulado_muestras.sql` | Rotulado de muestras en extracción (LIMS-28): número de muestra por paciente, correlativo del día por sucursal (`turnos.numero_muestra`, M1, M2…); la muestra pasa a pertenecer al turno (un tubo por tipo de muestra, compartido por todas las órdenes de la visita). Funciones `rotular_muestras` (asigna el número, crea los tubos y une cada estudio con su tubo) y `rechazar_muestra` (tubo no obtenido o rechazado, con motivo). |
| `migrations/20261102_04_reextraccion_muestras.sql` | Volver a extraer un tubo rechazado (LIMS-28): la regla de un tubo por tipo de muestra cuenta solo los no rechazados, y `rotular_muestras` crea el tubo nuevo (mismo número, con el intento al final: `S1-20261102-M1-3-2`) y le pasa los estudios del rechazado. |
| `migrations/20261102_05_cobros.sql` | Cobros por orden (LIMS-19): tabla `cobros` (monto, medio de pago, quién y cuándo, sucursal de la orden), se puede pagar en partes sin pasar del total que paga el paciente (suma de `importe_paciente`) y un cobro se anula con motivo, no se borra. Funciones `registrar_cobro` y `anular_cobro`; una orden con cobros vigentes no se puede anular ni cambiar sus estudios o su cobertura. |
| `migrations/20261102_06_caja_diaria.sql` | Caja diaria por sucursal (LIMS-20): tabla `cajas` (una por sucursal y día, con el efectivo inicial y el contado al cerrar). Funciones `abrir_caja`, `cerrar_caja`, `reabrir_caja` (solo el admin, con motivo) y `resumen_caja` (lo cobrado por medio de pago, lo esperado en efectivo y la diferencia). Para cobrar hay que tener abierta la caja del día; con la caja cerrada no se anulan cobros de ese día. |
| `migrations/20261102_07_metricas_dashboard.sql` | Dashboard de métricas del admin (LIMS-22): función `metricas_dashboard(desde, hasta, sucursal)` con órdenes, estudios, pacientes nuevos, facturado y cobrado del período, por día, por estado, por sucursal y por medio de pago, y los estudios más pedidos. No cuenta órdenes ni cobros anulados. Solo la puede llamar el admin. |
| `migrations/20261102_08_metricas_completas.sql` | Dashboard de métricas (LIMS-22): `metricas_dashboard` pasa a devolver también lo pendiente de cobro, las órdenes atrasadas, el detalle por obra social, los tiempos (días hasta informar y espera en la fila), la calidad (resultados fuera de rango y tubos rechazados con sus motivos) y los médicos que más derivan. |
| `migrations/20261102_09_metricas_fila_y_caja.sql` | Dashboard de métricas (LIMS-22): suma la fila de atención (llegadas, pacientes que se retiraron sin atenderse y horas pico por día de la semana) y el control de caja (cobros anulados y cajas cerradas con faltante o sobrante). |
| `migrations/20261103_01_pedidos_adjuntos.sql` | Pedido médico adjunto a la orden (LIMS-34): bucket privado `pedidos` (hasta 5 MB por archivo, solo JPG, PNG o PDF) y tabla `orden_adjuntos` (ruta `<orden_id>/<nombre>`, nombre original, tipo, tamaño, quién y cuándo). Hasta 5 por orden. Lo lee el personal de la sucursal; recepción y el admin suben y quitan mientras la orden está abierta. El paciente no lo ve. |
| `functions/crear-paciente/` | Edge Function: recepción o un admin dan de alta un paciente con contraseña provisoria, su obra social (o particular) y número de afiliado. Devuelve el id de la ficha. |
| `functions/generar-informe/` | Edge Function: el bioquímico firma el informe de una orden validada. Arma el PDF (`pdf.ts`, liviano: unos 8 KB), lo sube al bucket `informes` y llama a `publicar_informe`. Usa la sesión de quien llama, no la clave secreta. |
| `functions/crear-personal/` | Edge Function: un administrador da de alta a una persona del personal (cuenta, perfil y datos de personal) con contraseña provisoria. |
| `seed_usuarios_prueba.sql` | Usuarios de prueba (admin, recepción, bioquímico y un paciente). Solo para desarrollo. |
| `pruebas/rls_sucursal.sql` | Prueba del aislamiento por sucursal: arma datos en las dos sucursales, simula el ingreso de cada cuenta y verifica qué ve. Termina en `ROLLBACK`: no deja datos. |
| `pruebas/orden_sin_medico.sql` | Prueba de la orden sin pedido médico: se carga sin médico y particular, se rechaza con obra social y con médico sigue aceptando obra social. Termina en `ROLLBACK`: no deja datos. |
| `consultas/exportar_rangos.sql` | Consulta que exporta los valores de referencia de todos los estudios (unidad, rango general, rangos por sexo y edad y absolutos de la fórmula), para revisarlos con el bioquímico (LIMS-30). |
| `consultas/rangos_referencia.csv` | La misma lista tal como queda después de las migraciones, en CSV para Excel (separador `;`, coma decimal) con una columna al final para anotar correcciones. |

Las veintiocho migraciones se aplican en orden en el proyecto de Supabase; las tres Edge Functions se despliegan con la CLI.

## Revisión de los valores de referencia (LIMS-30)

Los rangos que se cargaron en LIMS-13 son orientativos: los tiene que confirmar el bioquímico, porque cada laboratorio usa los de su equipo y su método.

1. Correr `consultas/exportar_rangos.sql` en el SQL Editor y descargar el CSV: es la foto real de la base (puede tener cambios hechos desde el panel). Si no hay acceso, `consultas/rangos_referencia.csv` es la misma lista tal como queda después de las migraciones.
2. Anotar las correcciones en la última columna.
3. Cargarlas desde el panel, sin migración: **Análisis** (unidad, rango general y texto) y **Rangos** (por sexo y edad).

Lo que conviene preguntarle:

- **Ácido úrico (URIC):** en Supabase está completo (mg/dL, general 2,5 – 7 y tres rangos por sexo y edad), pero se había cargado desde el panel y ninguna migración lo creaba. Lo crea `20261102_01_acido_urico.sql` con esos mismos valores: confirmarlos como los demás.
- **Menores de 1 año:** no tienen rango propio y caen al general del catálogo, porque los pediátricos van de 1 a 17 años.
- **Estudios sin rango por sexo y edad:** usan el general del catálogo (plaquetas, glucemia, uremia, colesterol, triglicéridos, TSH, TP, HCM, CHCM, LDL, bilirrubinas, orina y sangre oculta).
- **Fórmula leucocitaria:** solo cambian los neutrófilos y los linfocitos en los chicos; los absolutos se calculan con los glóbulos blancos de la orden.
- **Unidades:** revisar sobre todo `mm/1ª hora` en la eritrosedimentación y que los absolutos de la fórmula vayan en `/mm³`.

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
