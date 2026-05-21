# Migrar campo `vence` de Date a Date+Time en Airtable

**Para:** Junior / persona que tenga acceso de edición de schema en la base de
Airtable de Guaicaramo Control.

**Tiempo estimado:** 2 minutos.

**Riesgo:** Bajo. Los datos existentes se conservan (las fechas YYYY-MM-DD
quedan con hora 00:00 por defecto). El gateway ya soporta ambos formatos
durante la transición, así que no hay downtime.

---

## Contexto rápido

El campo `vence` en las tablas **Placas** y **Personas** controla hasta cuándo
una placa o persona está autorizada a entrar a la finca.

Hoy el campo es tipo **Date** (solo guarda YYYY-MM-DD) → solo permite expirar
**al final del día**. Si queremos que un proveedor expire exactamente a las
4 pm de hoy, no podemos.

Cambiamos a tipo **Date and time** → permite poner `2026-05-21 16:00` y el
gateway respeta esa hora exacta.

---

## Pasos

### Tabla 1 — Placas

1. Abre la base: <https://airtable.com/apptwIqTras1uPNOc>
2. Entra a la tabla **Placas**.
3. Click en la flecha ▼ del header de la columna **`vence`**
   (o doble-click en el nombre de la columna).
4. Selecciona **"Customize field type"** (o "Edit field" según versión).
5. En el panel derecho, en **Type**, cambia de **Date** a **Date and time**.
6. Configura:
   - **Date format:** `ISO (YYYY-MM-DD)`
   - **Include a time field?:** ✅ ON
   - **Time format:** `24 hour`
   - **Use the same time zone (GMT) for all collaborators:** ✅ ON
   - **Time zone:** `Colombia (Bogota)` (o `America/Bogota`)
7. Click **Save** (esquina inferior derecha).
8. Si Airtable muestra "Existing data may be lost / converted" → confirma.
   Los valores actuales se mantienen con hora `00:00`.

### Tabla 2 — Personas

Repite los mismos 8 pasos en la columna `vence` de la tabla **Personas**.

---

## Verificación

Después de cambiar ambas tablas, abre dos registros que sirvan de prueba:

### En Placas → buscar `ASE213` (Fer Moreno)

1. Click en la celda `vence`.
2. El picker ahora muestra fecha + hora.
3. Cambia el valor a: **`2026-05-21 18:00`** (6 pm hoy).
4. Guarda (cierra el popup).

### En Personas → buscar CC `335577` (Pedro Manrriques)

1. Click en la celda `vence`.
2. Cambia el valor a: **`2026-05-21 16:00`** (4 pm hoy).
3. Guarda.

---

## Cómo probar que el gateway respeta la hora

Después de los pasos anteriores, desde un celular con la app instalada
(portero), pega lo siguiente en Recepción para validar la lógica:

| Cuándo | Acción | Resultado esperado |
|---|---|---|
| Antes de las 4 pm Bogota | 🚶 Peatón → CC `335577` → Verificar | ✅ **APROBADO** Pedro Manrriques |
| Después de las 4 pm Bogota | Mismo | ❌ **NO_APROBADO** (vencido) |
| Antes de las 6 pm Bogota | 🚗 Vehículo → CC `440088` placa `ASE213` → Verificar | ✅ **APROBADO** Fer Moreno |
| Después de las 6 pm Bogota | Mismo | ❌ **NO_APROBADO** (vencido) |

Si una placa/CC sigue APROBADO después de la hora de vencimiento:

1. Verifica que el campo en Airtable efectivamente tenga el time (no solo
   fecha). El picker debe mostrar `YYYY-MM-DD HH:MM`, no solo `YYYY-MM-DD`.
2. Verifica la zona horaria del campo (debe ser Bogota, no UTC ni Default).
3. Mira el journal del gateway en la Pi:
   ```
   sudo journalctl -u guaicaramo-gateway -n 30 --no-pager
   ```
   Debería decir "Placa ASE213 vencida" o similar cuando llegue la consulta.

---

## Si algo sale mal

| Síntoma | Solución |
|---|---|
| Airtable no deja cambiar el tipo de campo | Tu cuenta no tiene rol de Editor/Creator en esa base. Pide acceso a Pablo. |
| Después del cambio, el campo se ve vacío en algunas filas | Los valores se preservan en la celda interna pero el visualizador puede tardar un refresh. Recarga la página. |
| El gateway sigue dando APROBADO después de la hora | Reiniciar el service por si caché:`sudo systemctl restart guaicaramo-gateway` |
| No tengo claro si la columna ya cambió | Click en el header → "Customize field type" → mira el Type actual. Si dice "Date and time", listo. Si dice "Date", aún no. |

---

## Después de la migración (limpieza opcional)

- Las **notas** que pusimos en Fer Moreno y Pedro Manrriques explicando
  "campo vence solo guarda fecha…" ya no aplican. Puedes vaciar o reemplazar
  esos textos. No es urgente.
- Para placas/personas viejas con `vence` solo fecha, considera revisarlas
  y ponerles hora exacta si la conoces. Mientras tanto, el gateway las
  considera vigentes hasta el fin del día (23:59:59).

---

## Diff técnico (referencia)

El cambio en el código del gateway está en el commit
[`5cf436b`](https://github.com/pablofelipe01/guaicaramo-seguridad/commit/5cf436b)
— función `_is_expired` en `gateway/gateway.py`. Acepta ambos formatos
(date y dateTime) para no romper nada durante la migración.

---

*Última actualización: 2026-05-21*
