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
| `functions/generar-informe/` | Edge Function: el bioquímico firma el informe de una orden validada. Arma el PDF (`pdf.ts`, liviano: unos 8 KB), lo sube al bucket `informes` y llama a `publicar_informe`. Al publicar, avisa al paciente por mail (ver `enviar-resultado`). Usa la sesión de quien llama, no la clave secreta. |
| `migrations/20261105_01_cambios_password.sql` | Recuperar y restablecer contraseñas (LIMS-45): tabla `cambios_password` (a quién, por qué vía, quién y cuándo; solo la lee el admin) y la función `completar_recuperacion_password`, que cierra la recuperación por mail si el paciente pidió el link en la última hora. |
| `migrations/20261106_01_rangos_pediatricos.sql` | Correcciones de los valores de referencia aprobadas por el bioquímico (LIMS-30): rangos pediátricos de 1 a 17 años para glucemia, uremia, TSH, transaminasas, colesterol, triglicéridos, LDL y HDL, y absolutos pediátricos de neutrófilos y linfocitos en `analisis_rangos`. Los menores de 1 año siguen usando el general. |
| `migrations/20261106_02_liquidacion_obras_sociales.sql` | Liquidación mensual a obras sociales (LIMS-47): función `liquidacion_obra_social(obra social, mes)`, solo para el admin, con una fila por estudio cubierto de las órdenes no anuladas del mes (fecha, orden, sucursal, paciente con DNI y número de afiliado, médico y matrícula, código NBU, UB, valor de la UB, lo que se le factura a la obra social y el coseguro). |
| `migrations/20261113_02_indices_claves_foraneas.sql` | Índices para las 26 claves foráneas que no tenían (ej: `ordenes.medico_id`, `ordenes.obra_social_id`, `orden_analisis.analisis_id`), para que cruzar tablas no recorra la tabla entera cuando crezcan los datos. |
| `functions/crear-personal/` | Edge Function: un administrador da de alta a una persona del personal (cuenta, perfil y datos de personal) con contraseña provisoria. |
| `functions/enviar-resultado/` | Edge Function (LIMS-18): avisa por mail al paciente que su informe está listo, con el link al portal (sin el PDF adjunto) y marca `informes.email_enviado_en`. `generar-informe` lo hace solo al publicar; esta función sirve para reenviarlo (`{ orden_id, reenviar: true }`). Si el paciente no tiene email, no envía nada. |
| `functions/restablecer-password/` | Edge Function (LIMS-45): recepción o el admin le dan a un paciente una contraseña provisoria nueva (al personal, solo el admin). Se pide cambiarla en el siguiente ingreso y queda registrado en `cambios_password`. Devuelve la provisoria una sola vez. |
| `functions/recuperar-password/` | Edge Function (LIMS-45): el paciente pide desde el login un link para restablecer su contraseña. Lo genera con la clave secreta y lo manda al email real del paciente (la cuenta de Auth usa un email interno). Responde siempre lo mismo y manda como mucho un mail cada 5 minutos. Se despliega con `verify_jwt` en false. |
| `functions/_shared/` | Código que comparten las Edge Functions: `correo.ts` (envío por la cuenta de Gmail del laboratorio, SMTP 465) y `aviso-resultado.ts` (el mail del informe listo). |
| `seed_usuarios_prueba.sql` | Usuarios de prueba (admin, recepción, bioquímico y un paciente). Solo para desarrollo. |
| `pruebas/rls_sucursal.sql` | Prueba del aislamiento por sucursal: arma datos en las dos sucursales, simula el ingreso de cada cuenta y verifica qué ve. Termina en `ROLLBACK`: no deja datos. |
| `pruebas/orden_sin_medico.sql` | Prueba de la orden sin pedido médico: se carga sin médico y particular, se rechaza con obra social y con médico sigue aceptando obra social. Termina en `ROLLBACK`: no deja datos. |
| `pruebas/rangos_pediatricos.sql` | Prueba de los rangos pediátricos de LIMS-30: verifica los valores de 1 a 17 años, los absolutos de neutrófilos y linfocitos y que el rango general no cambió. Termina en `ROLLBACK`: no deja datos. |
| `consultas/exportar_rangos.sql` | Consulta que exporta los valores de referencia de todos los estudios (unidad, rango general, rangos por sexo y edad y absolutos de la fórmula), para revisarlos con el bioquímico (LIMS-30). |
| `consultas/rangos_referencia.csv` | La misma lista tal como queda después de las migraciones, en CSV para Excel (separador `;`, coma decimal) con una columna al final para anotar correcciones. |

Las treinta y una migraciones se aplican en orden en el proyecto de Supabase. Las seis Edge Functions las despliega Agustín, que es el admin del proyecto, desde `dev` después de mergear, para que producción coincida con el repo. Ojo: `supabase functions deploy` busca las funciones en `supabase/functions/<nombre>/` y en este repo están en `functions/`, así que no alcanza con correr el comando desde la raíz.

### Secretos de las Edge Functions

Se cargan en Supabase (Edge Functions → Secrets) o con `supabase secrets set`. **Nunca van en el código ni en el repo**: acá solo se anotan los nombres.

| Secreto | Lo usa | Qué es |
|---|---|---|
| `GMAIL_USER` | `generar-informe`, `enviar-resultado`, `recuperar-password` | Dirección de la cuenta de Gmail del laboratorio que manda los mails. |
| `GMAIL_APP_PASSWORD` | `generar-informe`, `enviar-resultado`, `recuperar-password` | Contraseña de aplicación de esa cuenta (16 letras; no es la contraseña de la cuenta). |
| `SITIO_URL` (opcional) | `generar-informe`, `enviar-resultado`, `recuperar-password` | Dirección del sitio para el link del mail. Si no está, se usa la de Vercel. |

Sin `GMAIL_USER` y `GMAIL_APP_PASSWORD` el informe se publica igual, pero no se avisa por mail. Los secretos también los carga Agustín. Si se cambia algo de `_shared/`, hay que avisarle para que vuelva a desplegar las funciones que lo usan (hoy `generar-informe` y `enviar-resultado`).

## Revisión de los valores de referencia (LIMS-30)

Los rangos se cargaron orientativos en LIMS-13. El bioquímico revisó la planilla del 03/11 (los 32 estudios y el CSV adjunto) y aprobó las correcciones el 06/11. Quedaron en `migrations/20261106_01_rangos_pediatricos.sql`:

- **Menores de 1 año:** siguen usando el rango general del catálogo; no se agregan franjas de 0 a 1 año.
- **Rangos pediátricos de 1 a 17 años:** glucemia 60–100 mg/dL, uremia 15–40 mg/dL, TSH 0,7–5,0 µUI/mL, GOT ≤40 U/L, GPT ≤30 U/L, HDL ≥40 mg/dL, colesterol ≤170 mg/dL, triglicéridos ≤100 mg/dL y LDL ≤110 mg/dL.
- **Fórmula leucocitaria:** los neutrófilos y los linfocitos de 1 a 17 años llevan su propio absoluto (1.500–8.500 y 1.500–7.000 /mm³). Monocitos, eosinófilos y basófilos mantienen el absoluto general.
- **Unidades y valores puntuales:** confirmados sin cambios.

El rango por edad ahora puede guardar su propio absoluto (`analisis_rangos.absoluto_min/max`). Si no lo trae, se usa el general del catálogo. Los resultados ya cargados no cambian: guardan el rango con el que se compararon.

La lista completa, para revisar o volver a exportar, está en `consultas/exportar_rangos.sql` y `consultas/rangos_referencia.csv` (la foto después de esta migración).

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
