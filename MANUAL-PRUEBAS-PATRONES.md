# Manual de pruebas de patrones

Esta guía reúne las pruebas realizadas para los siete patrones de la maqueta. Distingue las pruebas hechas paso a paso en Postman de las verificaciones realizadas con scripts o llamadas directas a las réplicas.

## Preparar Postman

La API está disponible en:

```text
http://localhost:5050
```

Las solicitudes a `/api/...` requieren este header:

```http
X-API-Key: dev-key-12345
```

Los endpoints `/health` y `/debug/...` son públicos. Si se usa una colección con autorización heredada, desactivarla en las solicitudes públicas para comprobar correctamente que no requieren clave.

## 1. Health Endpoint Monitoring

**Probado en Postman.**

1. Crear una solicitud `GET` a:

   ```text
   http://localhost:5050/health
   ```

2. No enviar API key.
3. Enviar la solicitud.

**Resultado observado:** `200 OK`, cuerpo `{ "status": "ok" }` y header `X-Api-Instance` con el nombre de la réplica que atendió la llamada (`api1` o `api2`).

Este es un chequeo básico de que la API responde. No verifica que PostgreSQL esté disponible.

## 2. Gatekeeper

Usar `GET http://localhost:5050/api/productos` para los tres casos.

### Sin API key

1. En **Authorization**, seleccionar `No Auth`.
2. Confirmar que no se envíe un header `X-API-Key` heredado.
3. Enviar la solicitud.

**Resultado observado:** `401 Unauthorized`.

```json
{
  "error": "API Key requerida"
}
```

### API key inválida

Agregar el header:

```http
X-API-Key: clave-invalida
```

**Resultado observado:** `401 Unauthorized`.

```json
{
  "error": "API Key inválida"
}
```

### API key válida

Cambiar el header a:

```http
X-API-Key: dev-key-12345
```

**Resultado observado:** `200 OK` y catálogo de productos. El stock de `prod-001` era `71` durante esta prueba; el stock puede cambiar cuando se ejecutan pedidos.

## 3. Cache-Aside

### Lectura del catálogo y de un producto

**Probado en Postman.**

Enviar dos veces cada solicitud, con `X-API-Key: dev-key-12345`:

```http
GET http://localhost:5050/api/catalogo
GET http://localhost:5050/api/catalogo/prod-001
```

**Resultado observado:** ambas solicitudes del catálogo devolvieron los mismos dos productos. La consulta individual devolvió `prod-001`, Producto A, con stock `71`.

Dos respuestas iguales son compatibles con un cache hit, pero por sí solas no lo demuestran: la API no expone un indicador de hit/miss en la respuesta.

### Invalidación después de registrar un producto

La invalidación se verificó con llamadas directas a la réplica, usando un producto temporal que luego se eliminó. El `POST` en `api1` hizo que el producto apareciera en una lectura posterior atendida por `api1`.

**Resultado importante:** `api2` conservó su copia anterior del catálogo y no mostró el alta hasta actualizar su caché. `IMemoryCache` es local a cada proceso; invalidar una instancia no invalida la otra.

Esta parte no se ejecutó paso a paso en Postman. Repetirla requiere crear un producto y limpiar después PostgreSQL y la caché de la réplica; no hay endpoint `DELETE` para productos.

## 4. Materialized View

**Probado en Postman.** Enviar las dos solicitudes con `X-API-Key: dev-key-12345`:

```http
GET http://localhost:5050/api/reportes/ventas-por-producto?directo=false
GET http://localhost:5050/api/reportes/ventas-por-producto?directo=true
```

- `directo=false` consulta la vista materializada.
- `directo=true` calcula el reporte desde las tablas.

**Resultado observado en la sesión:** ambas respuestas devolvieron `29` unidades y `1450.00` de ingresos para `prod-001`. La medición de la vista fue `12 ms` y la directa `39 ms`. Son tiempos puntuales; pueden variar entre ejecuciones.

También se ejecutó `scripts/prueba-vista.ps1`: compara los reportes y crea un pedido para observar que la vista se pone al día en el siguiente refresco. Ese script cambia los datos persistentes.

## 5. Valet Key

Todas las solicitudes de esta sección usan:

```http
X-API-Key: dev-key-12345
Content-Type: application/json
```

### Generar un token

Enviar `POST` a:

```text
http://localhost:5050/api/valetkey/generar
```

Body:

```json
{
  "recursoId": "prod-001",
  "permiso": "lectura",
  "minutosExpiracion": 30
}
```

La respuesta incluye `tokenId`, `recursoId`, `permiso`, `expiraEn` y `usosRestantes`. Anotar el `tokenId` y el header `X-Api-Instance`. Validar el token pronto, antes de su expiración.

### Validar el primer uso

Enviar `POST` a:

```text
http://localhost:5050/api/valetkey/validar
```

Body, sustituyendo `<tokenId>` por el valor recibido:

```json
{
  "tokenId": "<tokenId>",
  "recursoId": "prod-001",
  "permiso": "lectura"
}
```

Si el token sigue vigente y la solicitud llega a la instancia que lo generó, se espera `200 OK` con `{"valido": true}`.

### Comprobar uso único

Enviar otra vez el mismo body. Después de una validación exitosa, se espera `{"valido": false}` porque el token fue consumido.

**Resultado observado en Postman:** un token generado en `api2` validó como `true` en `api2`; las validaciones posteriores devolvieron `false`.

### Estado local a cada réplica

Comparar siempre `X-Api-Instance` en la generación y en la validación. El servicio actual guarda tokens en memoria local: una instancia distinta no encuentra el token. Una prueba de integración directa confirmó que un token generado en `api1` falla al validarse en `api2`.

En la primera prueba manual, un token de cinco minutos generado en `api1` dio `false` en `api2`; al intentar validarlo más tarde en `api1`, también dio `false` porque ya había expirado. Por tanto, esa secuencia manual no aisló por sí sola el efecto de cambiar de réplica.

### Expiración y revocación

Se verificaron mediante llamadas de integración directas, no paso a paso en Postman:

- Un token generado con `minutosExpiracion: 0` se rechazó.
- Un token revocado mediante `DELETE /api/valetkey/{tokenId}` se rechazó al validarlo.

## 6. External Configuration Store

### Consultar configuración

**Probado en Postman.** Enviar:

```http
GET http://localhost:5050/debug/config/reintentos.maxIntentos
```

No necesita API key. El valor inicial observado fue `"4"`.

### Cambiar el valor temporalmente

En PowerShell, desde la carpeta del proyecto:

```powershell
$sql = "UPDATE config.parametros SET `"Valor`" = '7' WHERE `"Clave`" = 'reintentos.maxIntentos';"
$sql | docker compose exec -T db psql -U postgres -d maquetaapi -v ON_ERROR_STOP=1
```

Se espera `UPDATE 1`. Volver a enviar en Postman el `GET` anterior. La respuesta debe mostrar `"valor": "7"` sin reiniciar la API.

### Restaurar el valor

Restaurar el valor original después de la prueba:

```powershell
$sql = "UPDATE config.parametros SET `"Valor`" = '4' WHERE `"Clave`" = 'reintentos.maxIntentos';"
$sql | docker compose exec -T db psql -U postgres -d maquetaapi -v ON_ERROR_STOP=1
```

Consultar nuevamente en Postman y confirmar `"valor": "4"`.

**Resultado observado:** el cambio `4` → `7` fue visible desde la API sin reinicio; luego se restauró y verificó `4`.

## 7. Retry

El error transitorio de PostgreSQL que activa Retry no se puede solicitar directamente desde un endpoint público. Por eso este patrón se comprobó con el script de concurrencia, no con una solicitud de Postman:

```powershell
.\scripts\prueba-retry.ps1 -Pedidos 5
```

El script envía pedidos concurrentes, consulta el stock directamente en PostgreSQL y busca los reintentos en los logs de las réplicas.

**Resultado observado:** 5 respuestas `HTTP 200`, reducción de stock de 5 unidades y 6 reintentos registrados. El número de reintentos varía con la concurrencia y el momento de ejecución.

**Aviso:** el script crea pedidos persistentes y reduce el stock. `simularError=true` no prueba Retry; prueba el rollback porque produce un error de aplicación no transitorio.

## Resumen

| Patrón | Prueba realizada | Observación |
|---|---|---|
| Health Endpoint | Postman | Respuesta básica `200`; no comprueba PostgreSQL. |
| Gatekeeper | Postman | Sin clave `401`; clave inválida `401`; válida `200`. |
| Cache-Aside | Lecturas en Postman e integración directa | Hay caché local por réplica; la invalidación no se propaga a la otra. |
| Materialized View | Postman y script | Los datos coincidieron; el tiempo observado favoreció a la vista. |
| Valet Key | Postman e integración directa | Uso único probado; el estado de tokens no se comparte entre réplicas. |
| External Configuration Store | Postman y actualización SQL temporal | El cambio se reflejó sin reiniciar y se restauró a `4`. |
| Retry | Script de concurrencia | Se observaron reintentos de PostgreSQL y el stock coincidió con pedidos exitosos. |
