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
| `functions/crear-paciente/` | Edge Function: recepción o un admin dan de alta un paciente con contraseña provisoria, su obra social (o particular) y número de afiliado. Devuelve el id de la ficha. |
| `functions/crear-personal/` | Edge Function: un administrador da de alta a una persona del personal (cuenta, perfil y datos de personal) con contraseña provisoria. |
| `seed_usuarios_prueba.sql` | Usuarios de prueba (admin, recepción, bioquímico y un paciente). Solo para desarrollo. |

Las cinco migraciones y las dos Edge Functions ya están aplicadas en el proyecto.

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
- Cada alta o cambio de estado de una muestra queda registrado solo en `movimientos_muestra`,
  con usuario, fecha y hora. Esa tabla no se puede editar ni borrar.
- Una muestra no se puede rechazar sin `motivo_rechazo`.
