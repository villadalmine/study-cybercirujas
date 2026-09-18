# 701.1 — Desarrollo de software moderno

**Certificación:** LPI DevOps Tools Engineer · **Examen:** 701-100 (versión 2.0.0) · **Peso del tema:** 10.0

> **Alcance de este objetivo.** Se espera que *diseñes* componentes de software que sobrevivan a ser distribuidos: descomposición en servicios, contratos de API, manejo de estado y configuración, containerización, modelos de despliegue en la nube, el perfil de riesgo de migrar un monolito heredado y las clases de fallo habituales en seguridad de aplicaciones. Es un objetivo de diseño, no de herramientas — pero cada decisión de diseño de más abajo está escrita junto al fallo en producción que evita, y junto a los comandos que realmente vas a tipear cuando falle igual.

---

## 1. El problema arquitectónico que este objetivo existe para resolver

### 1.1 El modo de fallo del monolito acoplado al despliegue

Una única unidad desplegable que contiene todo el dominio de negocio no es, en sí misma, un defecto. Los monolitos son más simples de razonar, no tienen una red en medio de una llamada a función y te dan transacciones ACID reales gratis. El defecto aparece cuando la *organización* escala y la *unidad de despliegue* no.

Considerá una forma concreta de producción — una plataforma de retail: catálogo, carrito, checkout, pagos, facturación, búsqueda, notificaciones. Un archivo WAR, un esquema de base de datos, 38 personas de ingeniería, una release cada dos semanas.

Las patologías medibles:

| Síntoma | Mecanismo | Métrica que se degrada |
|---|---|---|
| La cadencia de release colapsa | El cambio sin mergear de cualquier equipo bloquea el tren; la rama de integración es un lock global | Frecuencia de despliegue, lead time for change |
| El radio de impacto es total | Una fuga de memoria en el renderizador de facturas PDF mata por OOM al proceso que sirve el checkout | Disponibilidad, MTTR |
| El escalado es indiferenciado | La búsqueda necesita 32 GB de heap; las notificaciones necesitan 256 MB. Comprás 32 GB × N réplicas | Costo por request, eficiencia de recursos |
| La tasa de fallo por cambio sube | La superficie de regresión de una release es la unión de los cambios de 38 personas | Change failure rate |
| La tecnología queda congelada | Todo el artefacto debe cambiar de versión de JVM en conjunto | Time-to-adopt, contratación |

Estas cuatro — frecuencia de despliegue, lead time, change failure rate, tiempo de restauración — son las métricas DORA. El punto del "desarrollo de software moderno" en el sentido de LPI es que *la arquitectura es la palanca principal sobre esas métricas*, y la arquitectura que las mueve es aquella donde **la unidad de despliegue coincide con la unidad de propiedad**.

### 1.2 El costo con el que estás comprando

La descomposición no elimina complejidad; la reubica del compilador a la red. La enumeración clásica (Deutsch/Gosling, "Fallacies of Distributed Computing") es la lista relevante para el examen de las cosas que dejan de ser ciertas en el momento en que una llamada a método se convierte en una llamada HTTP:

1. La red es confiable — no lo es; cada llamada necesita un timeout, una política de reintentos y una historia de idempotencia.
2. La latencia es cero — una llamada in-process de 200 µs se convierte en un RPC de 2–20 ms; una refactorización charlatana de un bucle se convierte en una caída.
3. El ancho de banda es infinito — los patrones de consulta N+1 a través de un límite de servicio saturan los enlaces.
4. La red es segura — ahora necesitás mTLS, authN/authZ en cada salto y network policy.
5. La topología no cambia — los pods se reprograman continuamente; nunca cachees una IP.
6. Hay un solo administrador — la propiedad está distribuida; la guardia también.
7. El costo de transporte es cero — la serialización, los handshakes TLS y los bytes de egreso son dinero real.
8. La red es homogénea — MTU, proxies, HTTP/2 vs HTTP/1.1 y middleboxes L7 difieren por salto.

**Regla de diseño:** toda llamada síncrona que cruce un límite de servicio debe declarar, en código, un timeout de conexión, un timeout de lectura, un presupuesto de reintentos (con jitter) y un fallback. Una llamada sin timeout es un bug de disponibilidad que todavía no se disparó.

### 1.3 El acoplamiento débil es el objetivo real

"Microservicios" es una topología de despliegue. **El acoplamiento débil** es la propiedad que buscás, y podés no conseguirla con cualquier topología. Un sistema está débilmente acoplado cuando un cambio en un componente no fuerza un cambio coordinado en otro. Los acoplamientos a cazar:

| Tipo de acoplamiento | Cómo se manifiesta | Técnica de eliminación |
|---|---|---|
| Acoplamiento de despliegue | Los servicios deben liberarse juntos en un orden fijo | Contratos compatibles hacia atrás/adelante, migraciones expand-contract |
| Acoplamiento de esquema | Dos servicios escriben la misma tabla | Base de datos por servicio; un escritor, los demás leen vía API o eventos |
| Acoplamiento temporal | El llamador se bloquea hasta que el llamado responde | Mensajería asíncrona, event-carried state transfer |
| Acoplamiento en tiempo de ejecución | El llamado caído ⇒ el llamador caído | Circuit breaker, bulkhead, fallback cacheado/degradado |
| Acoplamiento semántico | El modelo de dominio interno del llamado se filtra al llamador | Capa anticorrupción, contrato publicado ≠ modelo interno |
| Acoplamiento tecnológico | Biblioteca compartida que fija una versión de lenguaje/runtime | Contrato sobre el cable (HTTP/gRPC/AMQP), no binarios compartidos |

Un "microservicio" que comparte una tabla de base de datos con tres hermanos es un monolito distribuido: pagaste el costo completo de red y no compraste nada de independencia.

---

## 2. Granularidad de servicios: monolito → SOA → microservicios

### 2.1 Tabla comparativa de compromisos

| Dimensión | Monolito modular | SOA (clásico, centrado en ESB) | Microservicios | Serverless / FaaS |
|---|---|---|---|---|
| Unidad de despliegue | Un artefacto | Pocos servicios gruesos + ESB | Muchos servicios finos | Una función |
| Comunicación | Llamada in-process | SOAP/XML sobre ESB, orquestación en el bus | REST/gRPC/eventos, dumb pipes, smart endpoints | Disparadores de eventos, gateway HTTP |
| Propiedad de los datos | Un esquema | A menudo una BD empresarial compartida | Un almacén por servicio | Solo almacenes externos |
| Transacciones | ACID | ACID adentro, XA a través (frágil) | Saga / consistencia eventual | Saga / consistencia eventual |
| Aislamiento de fallos | Ninguno (proceso compartido) | Parcial (el ESB es un SPOF) | Alto, si hay bulkheads | Alto |
| Escalado independiente | No | Grueso | Por servicio | Por invocación |
| Carga operativa | Baja | Alta (el ESB es un producto de especialista) | Alta (necesita plataforma: CI/CD, observabilidad, descubrimiento de servicios) | Poca infra, alto acoplamiento al proveedor |
| Perfil de latencia | El mejor | Pobre (salto por el bus + XML) | Medio, sensible a la latencia de cola | Cold starts |
| Adecuado para | <15 personas de ingeniería, dominio único, producto no validado | Integración empresarial de sistemas heredados heterogéneos | Múltiples equipos autónomos, escalado diferenciado | Cargas con picos, dirigidas por eventos, sin estado |
| Modo de fallo principal | Bloqueo del tren de releases | El ESB se convierte en el monolito | Monolito distribuido; deuda de observabilidad | Lock-in de proveedor, sorpresa de costo con carga sostenida |

**Distinción relevante para el examen entre SOA y microservicios:** SOA pone la inteligencia en la capa de integración (el Enterprise Service Bus realiza orquestación, transformación, enrutamiento); los microservicios empujan la inteligencia a los endpoints y mantienen el transporte tonto. La consecuencia es organizativa: un ESB requiere un equipo central de integración, lo que recrea el cuello de botella de coordinación que la descomposición debía eliminar.

### 2.2 Elegir los límites

Los límites trazados a lo largo de capas técnicas (un "servicio de controladores", un "servicio DAO") producen acoplamiento máximo — cada funcionalidad cruza cada servicio. Los límites trazados a lo largo de **capacidades de negocio** (Order, Payment, Inventory) producen cambios que aterrizan dentro de un solo servicio.

Dos heurísticas que sobreviven a producción:

- **Ley de Conway**: el sistema reflejará la estructura de comunicación de la organización. Si querés tres servicios independientes, necesitás tres equipos con hojas de ruta independientes; si no, los límites se van a erosionar.
- **La prueba de las dos transacciones**: si una única operación visible para el usuario requiere una escritura atómica a través de dos servicios candidatos, el límite probablemente está mal. O los unís, o aceptás una saga con acciones compensatorias explícitas y hacés visible la consistencia eventual en la UX ("pago pendiente").

### 2.3 Datos distribuidos: saga en lugar de 2PC

El commit en dos fases a través de servicios acopla la disponibilidad de forma multiplicativa (un servicio con 99,9 % por tres ⇒ 99,7 %) y mantiene locks a través de la red. El patrón de producción es una **saga**: una secuencia de transacciones locales, cada una publicando un evento, con una transacción compensatoria explícita por paso.

```
Order placed  ──▶ Payment authorised ──▶ Stock reserved ──▶ Shipment created
     │                    │                     │
     │                    │                     └─ compensate: release stock
     │                    └─ compensate: void authorisation
     └─ compensate: cancel order, notify customer
```

Los detalles de implementación no negociables:

- **Idempotencia**: todo consumidor debe tolerar la entrega duplicada. Los brokers de mensajes dan at-least-once; el exactly-once de punta a punta no existe sin un destino idempotente. Persistí una tabla de mensajes procesados indexada por ID de mensaje, o hacé que la escritura sea naturalmente idempotente (`UPDATE ... WHERE state = 'PENDING'`).
- **Outbox transaccional**: escribir en la base de datos y publicar en el broker son dos sistemas. Escribí el evento en una tabla `outbox` *dentro de la misma transacción local*, y transmitilo de forma asíncrona (change-data-capture o un poller). De lo contrario, una caída entre ambas produce un evento perdido o fantasma.
- **Ordenamiento**: solo garantizado por partición/clave. Particioná por ID de agregado (ID de orden), nunca round-robin, si el orden importa.

---

## 3. La Twelve-Factor App como contrato operativo

La metodología twelve-factor es la lista de verificación canónica para "software diseñado para ejecutarse en contenedores y desplegarse en un servicio de nube". Leela como un conjunto de *restricciones que la plataforma requiere*, no como consejos de estilo.

| # | Factor | Requisito de plataforma que satisface | Fallo si se viola |
|---|---|---|---|
| I | Código base — un repo, muchos deploys | Trazabilidad de un artefacto a un commit | No se puede responder "¿qué está corriendo en prod?" |
| II | Dependencias — declaradas explícitamente y aisladas | Builds reproducibles | "Funciona en mi máquina"; los paquetes de sistema implícitos desaparecen en una imagen base slim |
| III | Configuración — en el entorno | La misma imagen promovida dev→stage→prod | Rebuild por entorno; secretos horneados en la imagen |
| IV | Servicios de respaldo — recursos adjuntos | BD/caché/broker intercambiables por URL | Nombres de host hardcodeados; sin failover, sin pruebas locales |
| V | Build, release, run — estrictamente separados | Releases inmutables y redesplegables | Parchear en caliente un contenedor en ejecución; drift |
| VI | Procesos — sin estado, share-nothing | Cualquier réplica sirve cualquier request | Se requieren sesiones sticky; el scale-in pierde datos del usuario |
| VII | Vinculación de puertos — exportar vía un puerto | La app es autocontenida, sin servidor de aplicaciones externo | Necesita un runtime de contenedor/servlet preinstalado |
| VIII | Concurrencia — escalar horizontalmente con el modelo de procesos | Autoescalado horizontal | Escalado solo vertical; cuello de botella de proceso único |
| IX | Descartabilidad — arranque rápido, apagado elegante | Reprogramación, preempción, autoescalado, actualizaciones progresivas | 502 en cada deploy; paradas de terminación de pod de 30 s |
| X | Paridad dev/prod | Los bugs aparecen antes de prod | SQLite en dev, PostgreSQL en prod ⇒ fallos exclusivos de prod |
| XI | Logs — flujos de eventos a stdout | Recolección centralizada por la plataforma | Los logs mueren con el contenedor; sin rotación dentro de la imagen |
| XII | Procesos de administración — puntuales, misma release | Las migraciones corren con el código desplegado | Drift de esquema entre el código y la BD |

### 3.1 El factor III en la práctica — configuración, no secretos, y nunca ambos en la imagen

Tres niveles, y hay que distinguirlos:

| Nivel | Ejemplo | Mecanismo | Rotación |
|---|---|---|---|
| Constantes de build | Flags del compilador, imagen base | Dockerfile / build args | Imagen nueva |
| Configuración de runtime | Nivel de log, feature flags, URLs upstream, tamaños de pool | Variables de entorno / ConfigMap montado | Reinicio, o recarga en caliente al cambiar el archivo |
| Secretos | Contraseña de BD, claves de API, claves privadas TLS | Almacén de secretos, montado como archivo (preferentemente proyectado/de vida corta) | Rotar sin rebuild |

**Variables de entorno vs archivos montados** — esto aparece en el examen y en cada revisión de incidentes:

| Propiedad | Variable de entorno | Archivo montado |
|---|---|---|
| Visible en `/proc/<pid>/environ` | Sí | No |
| Se filtra a volcados de caída, trackers de errores, `docker inspect` | Sí, con frecuencia | Rara vez |
| Actualización en caliente sin reinicio | No — el entorno queda fijo en `execve()` | Sí — el kubelet actualiza el volumen (volúmenes ConfigMap/Secret; no los montajes `subPath`) |
| Límite de tamaño | ~2 MB argv+env (ARG_MAX) | Prácticamente ilimitado |
| Apto para certificados / multilínea | No | Sí |

**Regla:** la configuración en variables de entorno está bien; los secretos van en archivos con modo `0400`, e idealmente credenciales de vida corta emitidas en tiempo de ejecución en lugar de cadenas de larga duración.

### 3.2 El factor IX — la descartabilidad es código, no configuración

El runtime de contenedores envía `SIGTERM`, espera `terminationGracePeriodSeconds` y luego envía `SIGKILL`. En la práctica acá se rompen dos cosas:

1. **El PID 1 no tiene manejadores de señales por defecto.** En el kernel de Linux, el PID 1 ignora las señales para las que no instaló un manejador. Si tu app es PID 1 y nunca registra un manejador de `SIGTERM`, `SIGTERM` se descarta y cada apagado consume el período de gracia completo y después un kill duro — en medio de un request.
2. **La forma shell de `CMD` hace que `/bin/sh` sea PID 1**, y `sh` no reenvía señales a su hijo. Usá la forma exec: `CMD ["./server"]`, o `ENTRYPOINT ["/usr/bin/tini", "--"]` cuando genuinamente necesitás un reaper para imágenes multiproceso.

Secuencia de apagado correcta — el orden importa:

```go
// main.go — graceful shutdown that actually drains
func main() {
	srv := &http.Server{Addr: ":8080", Handler: router()}

	// readiness flips to false first, so the endpoint controller
	// removes this pod from the Service before the listener closes.
	go func() {
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("listen: %v", err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	<-stop

	ready.Store(false)                    // 1. fail the readiness probe
	time.Sleep(5 * time.Second)           // 2. let endpoint propagation catch up

	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil { // 3. drain in-flight requests
		log.Printf("forced shutdown: %v", err)
	}
	db.Close()                            // 4. release backing services
	log.Print("exited cleanly")
}
```

El `time.Sleep` no es superstición: la eliminación del pod envía `SIGTERM` y quita el endpoint **de forma concurrente**, y los planos de datos de kube-proxy/ingress convergen de manera asíncrona. Cerrar el listener en el instante en que llega `SIGTERM` produce errores de conexión rechazada durante varios cientos de milisegundos a segundos de tráfico. La forma declarativa equivalente es un hook `preStop` con `sleep` (mostrado en §6.4).

### 3.3 El factor XI — los logs como flujo de eventos

Escribí a `stdout`/`stderr`, sin buffer, un evento por línea, estructurado. No abras archivos de log, no configures rotación dentro del contenedor, no envíes logs desde la aplicación directamente al agregador (eso acopla la disponibilidad de tu app al backend de logging).

Estructurado es la palabra operativa: una línea que el recolector puede indexar sin regex.

```
{"ts":"2026-09-18T09:14:22.418Z","level":"error","service":"orders","trace_id":"4bf92f3577b34da6a3ce929d0e0e4736","span_id":"00f067aa0ba902b7","event":"payment_authorise_failed","order_id":"ord_01J8X","upstream":"payments","status":502,"latency_ms":3021,"retry":2}
```

El `trace_id` debe propagarse desde el encabezado `traceparent` entrante (W3C Trace Context) — sin él, correlacionar un 500 visible para el usuario a través de siete servicios es arqueología manual. Logs, métricas y trazas son las tres señales; el requisito de diseño es que las tres lleven el mismo ID de correlación.

---

## 4. Conceptos y estándares de API

### 4.1 REST, y qué restringe realmente ser "RESTful"

REST es un estilo arquitectónico (Fielding, 2000) con restricciones concretas: cliente–servidor, **ausencia de estado**, cacheabilidad, interfaz uniforme, sistema en capas y código bajo demanda opcional. La restricción que importa operativamente es la ausencia de estado: *cada request contiene toda la información necesaria para atenderlo*. Eso es lo que permite a un balanceador de carga enrutar cualquier request a cualquier réplica, que es lo que permite el escalado horizontal y las actualizaciones progresivas.

El Richardson Maturity Model es la escala habitual:

| Nivel | Característica | Nota práctica |
|---|---|---|
| 0 | Una URI, un verbo (POST), RPC sobre HTTP | Estilo SOAP; no se usa la semántica HTTP |
| 1 | Recursos — muchas URIs | `/orders/42`, `/customers/7` |
| 2 | Verbos HTTP y códigos de estado | GET es seguro y cacheable, PUT/DELETE idempotentes, 201/404/409/422 usados correctamente |
| 3 | Controles de hipermedia (HATEOAS) | Raro en la práctica; valioso para APIs públicas de larga vida |

El nivel 2 es el objetivo realista de producción. La semántica que le importa tanto al examen como a la CDN:

| Método | Seguro | Idempotente | Cacheable | Uso típico |
|---|---|---|---|---|
| GET | Sí | Sí | Sí | Lectura |
| HEAD | Sí | Sí | Sí | Metadatos / existencia |
| PUT | No | **Sí** | No | Reemplazo completo en una URI conocida |
| DELETE | No | **Sí** | No | Eliminación (repetir ⇒ 404 o 204) |
| POST | No | **No** | Rara vez | Crear en una URI elegida por el servidor, acción no-CRUD |
| PATCH | No | No | No | Actualización parcial (merge-patch de RFC 7396 o JSON Patch de RFC 6902) |

**Como POST no es idempotente, un reintento tras un timeout puede cobrarle dos veces a un cliente.** La mitigación estándar es un encabezado de request `Idempotency-Key`: el servidor guarda la clave con la respuesta durante un TTL y reproduce la respuesta almacenada en una repetición. Cualquier API que mueva dinero o cree recursos sobre una red no confiable necesita esto.

### 4.2 JSON y la disciplina de los tipos de medio

JSON (RFC 8259) es la representación por defecto: UTF-8, sin comentarios, sin comas finales, sin NaN/Infinity. Los riesgos de producción:

- **Precisión numérica.** Los números JSON son dobles IEEE-754 en la mayoría de los parsers; los enteros por encima de 2^53 pierden precisión. Serializá los IDs de 64 bits y los importes monetarios como cadenas, o usá unidades menores (centavos enteros) — nunca floats para dinero.
- **Fechas.** Siempre RFC 3339 / ISO 8601 con un desplazamiento explícito (`2026-09-18T09:14:22Z`). Nunca una cadena formateada por localización, nunca un epoch pelado sin documentar la unidad.
- **Campos desconocidos.** Los consumidores deben ignorar los campos que no conocen (lector tolerante). Eso es lo que hace que los cambios aditivos no sean rupturistas.
- **Errores.** Usá `application/problem+json` (RFC 9457) en lugar de inventar un sobre de error por equipo.

Una respuesta de problema, que es un único documento JSON:

```json
{
  "type": "https://api.example.com/problems/insufficient-funds",
  "title": "Insufficient funds",
  "status": 409,
  "detail": "Account acc_8812 has a balance of 24.50 EUR; the authorisation requires 89.90 EUR.",
  "instance": "/orders/ord_01J8X/payments",
  "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
  "balance_minor_units": 2450,
  "required_minor_units": 8990
}
```

### 4.3 El contrato es un archivo, y está versionado

Una API sin un contrato legible por máquina no puede validarse en CI, no puede generar clientes y no puede diferenciarse para detectar cambios rupturistas. OpenAPI es el estándar para APIs HTTP.

```yaml
openapi: 3.1.0
info:
  title: Orders API
  version: 2.3.0
  description: "Order lifecycle: creation, authorisation and cancellation."
  contact:
    name: Platform Team
    url: "https://internal.example.com/teams/platform"
servers:
  - url: "https://api.example.com/v2"
    description: Production
  - url: "https://api.staging.example.com/v2"
    description: Staging
security:
  - bearerAuth: []
paths:
  /orders:
    get:
      summary: List orders
      operationId: listOrders
      parameters:
        - name: cursor
          in: query
          required: false
          description: "Opaque cursor returned by the previous page."
          schema:
            type: string
        - name: limit
          in: query
          required: false
          schema:
            type: integer
            minimum: 1
            maximum: 200
            default: 50
      responses:
        "200":
          description: A page of orders
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/OrderPage"
        "429":
          $ref: "#/components/responses/RateLimited"
    post:
      summary: Create an order
      operationId: createOrder
      parameters:
        - name: Idempotency-Key
          in: header
          required: true
          description: "Client-generated UUIDv4; replays return the original response."
          schema:
            type: string
            format: uuid
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: "#/components/schemas/OrderCreate"
      responses:
        "201":
          description: Created
          headers:
            Location:
              description: "URI of the created order."
              schema:
                type: string
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/Order"
        "409":
          description: Idempotency key reused with a different payload
          content:
            application/problem+json:
              schema:
                $ref: "#/components/schemas/Problem"
  /orders/{orderId}:
    parameters:
      - name: orderId
        in: path
        required: true
        schema:
          type: string
    get:
      summary: Fetch a single order
      operationId: getOrder
      responses:
        "200":
          description: The order
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/Order"
        "404":
          description: No such order
          content:
            application/problem+json:
              schema:
                $ref: "#/components/schemas/Problem"
components:
  securitySchemes:
    bearerAuth:
      type: http
      scheme: bearer
      bearerFormat: JWT
  responses:
    RateLimited:
      description: Too many requests
      headers:
        Retry-After:
          description: "Seconds to wait before retrying."
          schema:
            type: integer
      content:
        application/problem+json:
          schema:
            $ref: "#/components/schemas/Problem"
  schemas:
    OrderCreate:
      type: object
      required:
        - customerId
        - lines
      properties:
        customerId:
          type: string
        lines:
          type: array
          minItems: 1
          items:
            $ref: "#/components/schemas/OrderLine"
    OrderLine:
      type: object
      required:
        - sku
        - quantity
      properties:
        sku:
          type: string
        quantity:
          type: integer
          minimum: 1
        unitPriceMinor:
          type: integer
          description: "Price in minor units, for example cents. Never a float."
    Order:
      type: object
      required:
        - id
        - status
        - createdAt
      properties:
        id:
          type: string
        status:
          type: string
          enum:
            - pending
            - authorised
            - shipped
            - cancelled
        createdAt:
          type: string
          format: date-time
        totalMinor:
          type: integer
        currency:
          type: string
          example: EUR
    OrderPage:
      type: object
      required:
        - items
      properties:
        items:
          type: array
          items:
            $ref: "#/components/schemas/Order"
        nextCursor:
          type: string
          nullable: true
    Problem:
      type: object
      properties:
        type:
          type: string
        title:
          type: string
        status:
          type: integer
        detail:
          type: string
        instance:
          type: string
```

Validalo en CI — un contrato que no se valida es documentación, y la documentación deriva:

```
$ redocly lint openapi.yaml
validating openapi.yaml...
openapi.yaml: validated in 84ms

Woohoo! Your API description is valid. 🎉

$ oasdiff breaking https://api.example.com/v2/openapi.yaml ./openapi.yaml
1 breaking changes: 1 error, 0 warning
error   [response-property-removed] at ./openapi.yaml
        in API GET /orders/{orderId}
                removed the response property 'discountMinor' from the response with the '200' status
```

### 4.4 Estrategias de versionado

| Estrategia | Ejemplo | Ventajas | Desventajas |
|---|---|---|---|
| Ruta en la URI | `/v2/orders` | Trivialmente visible, amigable con la caché, enrutamiento fácil en el gateway | Viola "un recurso, una URI"; fuerza cambios en el código cliente |
| Tipo de medio | `Accept: application/vnd.example.order+json;version=2` | El REST más puro, evolución por recurso | Más difícil de probar a mano; los proxies/CDN deben variar por `Accept` |
| Parámetro de consulta | `/orders?version=2` | Simple | Fácil de olvidar; contamina las claves de caché |
| Encabezado | `X-API-Version: 2` | URIs limpias | Invisible en logs/navegadores salvo que se registre explícitamente |
| **Sin versión — solo aditivo** | — | Sin proliferación de implementaciones | Requiere disciplina estricta: solo agregar campos opcionales, nunca quitar ni cambiar el tipo |

Guía de producción: versioná el contrato *mayor* en la ruta para APIs públicas, y dentro de la versión mayor permití solo cambios compatibles hacia atrás (agregar campos opcionales, agregar valores de enum solo si los clientes están documentados como tolerantes a valores desconocidos, nunca cambiar el tipo o la semántica de un campo). Internamente, preferí sin versión más pruebas de contrato dirigidas por el consumidor.

### 4.5 REST frente a las alternativas

| | REST/JSON sobre HTTP/1.1 | gRPC (HTTP/2 + protobuf) | GraphQL | Mensajería asíncrona (AMQP/Kafka) |
|---|---|---|---|---|
| Contrato | OpenAPI (opcional) | `.proto` (obligatorio, compilado) | Esquema SDL (obligatorio) | Registro de esquemas (Avro/Protobuf/JSON Schema) |
| Carga útil | Texto, verbosa, legible por humanos | Binaria, compacta | JSON | Binaria o JSON |
| Sobrecarga de latencia típica | Línea base | 30–60 % menor; flujos multiplexados | Línea base + fan-out de resolvers | Desacoplada — no comparable |
| Soporte del navegador | Nativo | Necesita grpc-web + proxy | Nativo | Vía puente WebSocket |
| Streaming | SSE / WebSocket añadido | Bidireccional nativo | Suscripciones | Nativo |
| Caché | Caché HTTP (ETag, Cache-Control, CDN) | Ninguna estándar | Difícil (un único endpoint POST) | N/A |
| Sobre/sub-obtención | Común | Común | Resuelto por diseño | N/A |
| Acoplamiento temporal | Síncrono | Síncrono | Síncrono | **Eliminado** |
| Depurabilidad | `curl` | `grpcurl`, necesita reflexión | GraphiQL | CLI del broker + inspección de DLQ |
| Mejor uso | APIs públicas, CRUD, todo lo que llame un navegador | Interno este-oeste, alto QPS, poliglota | Agregación para clientes heterogéneos (móvil/web) | Eventos, colas de trabajo, fan-out, amortiguación |
| Riesgo principal | N+1 charlatán a través de límites | Opaco en el cable; desfase de versiones en los stubs generados | Una sola consulta puede tirar el backend (necesita límites de profundidad/complejidad) | Duplicados at-least-once; orden solo por partición |

**Regla de diseño práctica:** request/response síncrono para las consultas en las que un usuario está esperando; eventos asíncronos para la propagación de estado entre servicios. Si el servicio A llama a B que llama a C que llama a D de forma síncrona para servir un request, tu disponibilidad es el producto de cuatro servicios y tu p99 es la suma de cuatro p99.

### 4.6 CORS — la política del mismo origen y su relajación controlada

Los navegadores aplican la **política del mismo origen**: un documento del origen `https://app.example.com` no puede leer una respuesta de `https://api.example.com`. Un origen es la tripleta *(esquema, host, puerto)* — `https://app.example.com` y `https://app.example.com:8443` son orígenes distintos, igual que las variantes `http://` y `https://`.

**CORS (Cross-Origin Resource Sharing)** es el mecanismo por el cual el *servidor* le dice al navegador que relaje esa restricción. Tres puntos que se malinterpretan constantemente:

1. CORS lo aplica **el navegador**, no el servidor. `curl` lo ignora por completo — un request que falla en Chrome y funciona en `curl` es un problema de CORS, siempre.
2. CORS **no** es un control de seguridad del lado del servidor. No protege la API; protege la sesión del navegador *del usuario* de ser leída por una página hostil. Tu API sigue necesitando autenticación y autorización.
3. Un chequeo de CORS fallido no impide que el request llegue al servidor en un request simple — impide que *la respuesta se lea*. Los efectos secundarios pueden haber ocurrido ya, y por eso sigue siendo necesaria la protección contra CSRF.

**Requests simples vs con preflight.** Un request es "simple" (sin preflight) solo si el método es `GET`, `HEAD` o `POST`, los encabezados se limitan al conjunto de la lista segura de CORS, y `Content-Type` es uno de `application/x-www-form-urlencoded`, `multipart/form-data` o `text/plain`. **`Content-Type: application/json` por lo tanto siempre dispara un preflight** — que es la razón por la que casi toda API REST debe manejar `OPTIONS`.

El intercambio de preflight, observado:

```
$ curl -i -X OPTIONS https://api.example.com/v2/orders \
    -H 'Origin: https://app.example.com' \
    -H 'Access-Control-Request-Method: POST' \
    -H 'Access-Control-Request-Headers: content-type,authorization,idempotency-key'
HTTP/2 204
access-control-allow-origin: https://app.example.com
access-control-allow-methods: GET, POST, PUT, DELETE, PATCH, OPTIONS
access-control-allow-headers: content-type,authorization,idempotency-key
access-control-allow-credentials: true
access-control-max-age: 600
vary: Origin
date: Fri, 18 Sep 2026 09:22:41 GMT
```

Después, el request real:

```
$ curl -i -X POST https://api.example.com/v2/orders \
    -H 'Origin: https://app.example.com' \
    -H 'Content-Type: application/json' \
    -H 'Authorization: Bearer eyJhbGciOi...' \
    -H 'Idempotency-Key: 6f1c2a3e-9b4d-4f2a-8c11-77d0f5a1b2c3' \
    -d '{"customerId":"cus_7","lines":[{"sku":"SKU-1","quantity":2}]}'
HTTP/2 201
location: /v2/orders/ord_01J8X
access-control-allow-origin: https://app.example.com
access-control-expose-headers: Location, X-Request-Id
access-control-allow-credentials: true
vary: Origin
content-type: application/json
```

Referencia de encabezados:

| Encabezado | Dirección | Significado |
|---|---|---|
| `Origin` | Request | El origen del documento solicitante; lo define el navegador, no falsificable por el JS de la página |
| `Access-Control-Request-Method` | Preflight | Método que usará el request real |
| `Access-Control-Request-Headers` | Preflight | Encabezados fuera de la lista segura que enviará el request real |
| `Access-Control-Allow-Origin` | Respuesta | Origen permitido, o `*` |
| `Access-Control-Allow-Methods` | Respuesta de preflight | Métodos permitidos |
| `Access-Control-Allow-Headers` | Respuesta de preflight | Encabezados de request permitidos |
| `Access-Control-Allow-Credentials` | Respuesta | `true` permite cookies/certificados de cliente TLS; **incompatible con `*`** |
| `Access-Control-Expose-Headers` | Respuesta | Encabezados de respuesta que el JS puede leer (por defecto solo los seis de la lista segura) |
| `Access-Control-Max-Age` | Respuesta de preflight | Segundos que el navegador puede cachear el preflight |
| `Vary: Origin` | Respuesta | **Obligatorio** cuando el origen permitido se calcula — si no, una caché compartida sirve los encabezados del origen A al origen B |

Los cuatro bugs de CORS que realmente vas a encontrar:

1. `Access-Control-Allow-Origin: *` junto con `Access-Control-Allow-Credentials: true` — el navegador rechaza la combinación de plano. Con credenciales debés devolver el origen exacto (desde una lista de permitidos) y emitir `Vary: Origin`.
2. Reflejar `Origin` sin validarlo — esto permite que cualquier sitio lea respuestas autenticadas. Compará siempre contra una lista de permitidos explícita.
3. La ruta `OPTIONS` requiere autenticación — el navegador no envía credenciales en un preflight, así que recibe 401 y el request real nunca ocurre. El preflight debe responderse antes del middleware de autenticación.
4. Un `Vary: Origin` ausente detrás de una CDN — fallos intermitentes, dependientes del origen, que "solo le pasan a algunos usuarios".

---

## 5. Almacenamiento de datos, estado y configuración

### 5.1 Sin estado es una propiedad del proceso, no del sistema

El estado no desaparece; se mueve a un servicio de respaldo construido a propósito. El objetivo de diseño es que **cualquier réplica pueda servir cualquier request**, y que matar una réplica no pierda más que el trabajo en vuelo.

| Categoría de estado | Hogar incorrecto | Hogar correcto |
|---|---|---|
| Sesión de usuario | Memoria del proceso | Redis/Memcached, o un token firmado en poder del cliente |
| Archivos subidos | Sistema de archivos del contenedor | Almacenamiento de objetos (compatible con S3) |
| Caché | Mapa por réplica (inconsistente entre réplicas) | Caché compartida, o por réplica con un TTL corto e inconsistencia aceptada |
| Trabajos programados / líder | "El primer pod" | Elección de líder vía la plataforma (objeto Lease), o una cola |
| Trabajo en vuelo | Cola local en memoria | Broker durable con visibility timeout |
| Datos de negocio | SQLite local en el contenedor | Base de datos gestionada/operada por operator con backups |

### 5.2 Manejo de sesiones: sticky sessions vs estado externalizado vs tokens

| Enfoque | Cómo funciona | Comportamiento en scale-in | Modo de fallo |
|---|---|---|---|
| **En memoria + sticky sessions** | El LB fija un cliente a una réplica por cookie o hash de IP de origen | Los usuarios de la réplica terminada pierden la sesión | Carga desigual; las actualizaciones progresivas desloguean a todos; bloquea el autoescalado |
| **Almacén de sesiones externo** | Cookie con ID de sesión; estado en Redis con TTL | Sin interrupciones | Redis queda ahora en el camino crítico — necesita HA y un presupuesto de latencia |
| **Token del lado del cliente (JWT)** | Claims firmados en la cookie/encabezado; el servidor verifica la firma | Sin interrupciones, sin estado en el servidor | **La revocación es difícil**; el token crece; los claims quedan obsoletos hasta la expiración |
| **Híbrido** | Token de acceso de vida corta (5–15 min) + token de refresco del lado del servidor | Sin interrupciones | El mejor compromiso práctico; se revoca invalidando el token de refresco |

Las sticky sessions en Kubernetes son `service.spec.sessionAffinity: ClientIP` (L4, grueso, se rompe detrás de NAT) o una anotación de cookie en el ingress (L7). Tratá a ambas como una muleta de migración para apps heredadas, no como un diseño.

**Detalles de JWT que causan incidentes:** validá `alg` contra una lista de permitidos (rechazá `none` y rechazá la confusión de algoritmos entre HMAC y RSA), validá `iss`, `aud`, `exp` y `nbf`, mantené una expiración corta, y nunca pongas nada secreto en el payload — un JWT está firmado, no cifrado, y cualquiera que lo tenga lo decodifica trivialmente desde base64.

### 5.3 Elegir un almacén de datos

| Tipo de almacén | Modelo | Consistencia | Escala por | Usalo para | No lo uses para |
|---|---|---|---|---|---|
| Relacional (PostgreSQL, MySQL) | Tablas, joins, restricciones | Fuerte, ACID | Vertical + réplicas de lectura; el sharding es manual | Datos de negocio transaccionales, todo lo que tenga invariantes | Blobs; throughput de escritura ilimitado |
| Clave-valor (Redis, Memcached) | `key → value` | Típicamente last-write-wins | Horizontal (sharding) | Caché, sesiones, limitadores de tasa, locks | Sistema de registro (salvo que la persistencia esté configurada y comprendida) |
| Documental (MongoDB, CouchDB) | Documentos JSON | Atómica por documento; ajustable | Horizontal | Agregados leídos como un todo, esquemas flexibles | Invariantes transaccionales entre documentos |
| Wide-column (Cassandra, ScyllaDB) | Claves de partición + clustering | Ajustable (quórum) | Horizontal, lineal | Throughput de escritura masivo, series temporales | Consultas ad-hoc; la forma de la consulta debe conocerse primero |
| Búsqueda (OpenSearch, Elasticsearch) | Índice invertido | Casi en tiempo real | Horizontal | Texto completo, agregaciones | Sistema de registro |
| Almacenamiento de objetos (compatible con S3) | Bucket/clave → blob | Lectura tras escritura para objetos nuevos | Efectivamente ilimitado | Archivos, backups, artefactos, activos estáticos | Cualquier cosa que necesite un motor de consultas |
| Broker de mensajes (Kafka, RabbitMQ) | Log / cola | At-least-once | Particiones / colas | Desacoplamiento, amortiguación, flujos de eventos | Almacenamiento de acceso aleatorio |
| Series temporales (Prometheus, VictoriaMetrics) | Series etiquetadas | Eventualmente consistente | Sharding/federación | Métricas | Eventos que necesitan retención/auditoría exacta |

**CAP y PACELC en un párrafo.** Bajo una **P**artición de red debés elegir **C**onsistencia o **A**vailability (disponibilidad); las particiones no son opcionales, así que CAP es en realidad una elección CP/AP. PACELC agrega el resto del tiempo: **E**lse (si no), elegí **L**atencia o **C**onsistencia. Una base de datos replicada de forma síncrona compra consistencia con latencia de escritura; una réplica asíncrona compra latencia con una ventana de obsolescencia y posible pérdida de datos en el failover. Hacé esa elección explícitamente por conjunto de datos — un libro mayor de órdenes y una lista de "vistos recientemente" no necesitan la misma garantía.

---

## 6. Diseñar software para correr en contenedores

### 6.1 Reglas de diseño de contenedores

1. **Una preocupación por contenedor.** No "un proceso" — un servidor web con un pool de workers está bien — sino una razón para ser reiniciado, un ciclo de vida, una dimensión de escalado. Los sidecars (proxy, enviador de logs) pertenecen al mismo pod, no al mismo contenedor.
2. **La imagen es inmutable y agnóstica del entorno.** Se construye exactamente una imagen por commit y se promueve por los entornos. Si construís `myapp:prod`, no probaste lo que desplegás.
3. **Fijá por digest en producción.** Los tags son mutables: `image: registry/orders@sha256:…` es reproducible; `orders:v2.3.0` es una promesa que alguien puede romper.
4. **Base pequeña, sin root, rootfs de solo lectura.** Cada binario en la imagen es superficie de ataque y ruido en el escaneo de CVE.
5. **El PID 1 maneja señales** (§3.2).
6. **Sin secretos en las capas.** Un `RUN` que hace curl con un token deja el token en la capa para siempre, aunque una capa posterior borre el archivo. Usá montajes de secretos de build.
7. **Exponé endpoints de salud** que sean baratos y honestos (§6.3).

### 6.2 Un build multietapa completo, con forma de producción

```dockerfile
# syntax=docker/dockerfile:1.7

########## Stage 1 — build ##########
FROM golang:1.23-bookworm AS build
WORKDIR /src

# Dependency layer: cached unless go.mod/go.sum change.
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download

COPY . .
ARG VERSION=dev
ARG COMMIT=unknown
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux go build \
      -trimpath \
      -ldflags="-s -w -X main.version=${VERSION} -X main.commit=${COMMIT}" \
      -o /out/orders ./cmd/orders

########## Stage 2 — test (fails the build, not the pipeline afterwards) ##########
FROM build AS test
RUN CGO_ENABLED=0 go vet ./... && go test -count=1 ./...

########## Stage 3 — runtime ##########
FROM gcr.io/distroless/static-debian12:nonroot AS runtime
# distroless/static:nonroot runs as UID/GID 65532 and ships CA certificates
# and /etc/passwd, but no shell, no package manager, no busybox.
COPY --from=build /out/orders /usr/local/bin/orders

USER 65532:65532
EXPOSE 8080
ENV GOMAXPROCS=0 \
    OTEL_SERVICE_NAME=orders

# Exec form: the binary is PID 1 and receives SIGTERM directly.
ENTRYPOINT ["/usr/local/bin/orders"]
```

Construir e inspeccionar:

```
$ docker buildx build \
    --build-arg VERSION=2.3.0 \
    --build-arg COMMIT=$(git rev-parse --short HEAD) \
    --target runtime \
    --provenance=true --sbom=true \
    -t registry.example.com/orders:2.3.0 --push .
[+] Building 41.7s (18/18) FINISHED
 => [build 5/6] RUN --mount=type=cache ... go build                     28.4s
 => [test 1/1] RUN go vet ./... && go test -count=1 ./...                9.1s
 => exporting to image                                                   1.2s
 => => pushing manifest for registry.example.com/orders:2.3.0@sha256:9f2c...

$ docker image ls registry.example.com/orders:2.3.0
REPOSITORY                         TAG     IMAGE ID       CREATED          SIZE
registry.example.com/orders        2.3.0   3b1f8e0c7a55   12 seconds ago   14.8MB

$ docker run --rm registry.example.com/orders:2.3.0 --version
orders 2.3.0 (commit 8c41d0a, go1.23.4)
```

Verificá que el proceso realmente es PID 1 y realmente muere con `SIGTERM`:

```
$ docker run -d --name orders-t registry.example.com/orders:2.3.0
c81f2a44e19b
$ docker top orders-t
UID    PID    PPID   C   STIME   TTY   TIME       CMD
65532  41207  41185  0   09:31   ?     00:00:00   /usr/local/bin/orders
$ time docker stop orders-t
orders-t

real    0m0.412s
```

`real 0m0.4s` prueba que el manejador se ejecutó. Un `real 0m10.0s` acá significa que `SIGTERM` se ignoró y el runtime recurrió a `SIGKILL` — el defecto de containerización más común de todos.

### 6.3 Endpoints de salud: tres preguntas distintas

| Sonda | Pregunta | Acción ante fallo | NO debe verificar |
|---|---|---|---|
| **Startup** | ¿Terminó la inicialización? | Mantiene suspendidas liveness/readiness hasta que pase | — |
| **Liveness** | ¿Este proceso está trabado sin posibilidad de recuperación? | **Reiniciar el contenedor** | Dependencias. Una sonda de liveness que verifica la base de datos reinicia todos los pods cuando la BD parpadea — una caída autoinfligida |
| **Readiness** | ¿Esta réplica puede servir tráfico *ahora mismo*? | Quitar de los endpoints del Service (sin reinicio) | Cualquier cosa lenta o costosa |

`/livez` debería ser una respuesta de tiempo constante desde el manejador HTTP — si responde, el bucle de eventos está vivo. `/readyz` puede verificar el pool de conexiones y las cachés sin las que no puede servir, y debe pasar a fallar ante `SIGTERM`. Ambos deben excluirse de la autenticación y de los logs de acceso, y ninguno debería exponerse a través del ingress.

### 6.4 Conjunto completo de manifiestos de Kubernetes

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: shop
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: orders
  namespace: shop
automountServiceAccountToken: false
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: orders-config
  namespace: shop
data:
  LOG_LEVEL: info
  LOG_FORMAT: json
  HTTP_PORT: "8080"
  PAYMENTS_BASE_URL: "http://payments.shop.svc.cluster.local:8080"
  PAYMENTS_TIMEOUT: 2s
  PAYMENTS_RETRIES: "2"
  DB_POOL_MAX_CONNS: "20"
  DB_POOL_MAX_CONN_LIFETIME: 30m
  CORS_ALLOWED_ORIGINS: "https://app.example.com,https://admin.example.com"
  OTEL_EXPORTER_OTLP_ENDPOINT: "http://otel-collector.observability.svc.cluster.local:4317"
---
apiVersion: v1
kind: Secret
metadata:
  name: orders-secrets
  namespace: shop
type: Opaque
stringData:
  DATABASE_URL: "postgres://orders_app:S3cr3t-Pa55@postgres-rw.shop.svc.cluster.local:5432/orders?sslmode=verify-full"
  JWT_PUBLIC_KEY_PEM: |
    -----BEGIN PUBLIC KEY-----
    MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA0vx7agoebGcQSuuPiLJX
    ZptN9nndrQmbXEps2aiAFbWhM78LhWx4cbbfAAtVT86zwu1RK7aPFFxuhDR1L6tS
    oc_TRUNCATED_FOR_BREVITY_REPLACE_WITH_REAL_KEY
    -----END PUBLIC KEY-----
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: orders
  namespace: shop
  labels:
    app.kubernetes.io/name: orders
    app.kubernetes.io/version: 2.3.0
    app.kubernetes.io/part-of: shop
spec:
  replicas: 4
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: orders
  template:
    metadata:
      labels:
        app.kubernetes.io/name: orders
        app.kubernetes.io/version: 2.3.0
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9090"
        prometheus.io/path: /metrics
    spec:
      serviceAccountName: orders
      automountServiceAccountToken: false
      terminationGracePeriodSeconds: 45
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        fsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: orders
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: orders
      containers:
        - name: orders
          image: "registry.example.com/orders@sha256:9f2c4d1b8ae0a7c3f5d69b21c0e4a7f8d3b6c19e25aa70fd1c8b4e39a6d2f701"
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
            - name: metrics
              containerPort: 9090
          envFrom:
            - configMapRef:
                name: orders-config
            - secretRef:
                name: orders-secrets
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            - name: NODE_ZONE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.labels['topology.kubernetes.io/zone']
            - name: GOMEMLIMIT
              valueFrom:
                resourceFieldRef:
                  resource: limits.memory
          resources:
            requests:
              cpu: 200m
              memory: 256Mi
            limits:
              memory: 512Mi
          startupProbe:
            httpGet:
              path: /startupz
              port: http
            periodSeconds: 2
            failureThreshold: 30
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 2
          livenessProbe:
            httpGet:
              path: /livez
              port: http
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
          lifecycle:
            preStop:
              exec:
                command:
                  - /usr/local/bin/orders
                  - drain
                  - --wait=10s
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir:
            sizeLimit: 64Mi
---
apiVersion: v1
kind: Service
metadata:
  name: orders
  namespace: shop
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: orders
  ports:
    - name: http
      port: 8080
      targetPort: http
    - name: metrics
      port: 9090
      targetPort: metrics
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: orders
  namespace: shop
spec:
  minAvailable: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: orders
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: orders
  namespace: shop
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: orders
  minReplicas: 4
  maxReplicas: 40
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 65
    - type: Pods
      pods:
        metric:
          name: http_requests_inflight
        target:
          type: AverageValue
          averageValue: "25"
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - type: Percent
          value: 100
          periodSeconds: 30
        - type: Pods
          value: 8
          periodSeconds: 30
      selectPolicy: Max
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Percent
          value: 20
          periodSeconds: 60
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: orders
  namespace: shop
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: orders
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
      ports:
        - protocol: TCP
          port: 8080
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
      ports:
        - protocol: TCP
          port: 9090
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: payments
      ports:
        - protocol: TCP
          port: 8080
    - to:
        - podSelector:
            matchLabels:
              cnpg.io/cluster: postgres
      ports:
        - protocol: TCP
          port: 5432
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: orders
  namespace: shop
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/enable-cors: "true"
    nginx.ingress.kubernetes.io/cors-allow-origin: "https://app.example.com"
    nginx.ingress.kubernetes.io/cors-allow-methods: "GET, POST, PUT, PATCH, DELETE, OPTIONS"
    nginx.ingress.kubernetes.io/cors-allow-headers: "Content-Type, Authorization, Idempotency-Key, traceparent"
    nginx.ingress.kubernetes.io/cors-expose-headers: "Location, X-Request-Id"
    nginx.ingress.kubernetes.io/cors-allow-credentials: "true"
    nginx.ingress.kubernetes.io/cors-max-age: "600"
    nginx.ingress.kubernetes.io/proxy-next-upstream: "error timeout"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "30"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - api.example.com
      secretName: api-example-com-tls
  rules:
    - host: api.example.com
      http:
        paths:
          - path: /v2/orders
            pathType: Prefix
            backend:
              service:
                name: orders
                port:
                  name: http
```

Notas que quien diseña debería poder defender en una revisión:

- **`maxUnavailable: 0`** — durante una actualización progresiva la capacidad nunca cae por debajo de `replicas`; el pod de surge debe ser programable, así que dejá margen.
- **Sin límite de CPU, con límite de memoria** — los límites de CPU causan throttling de CFS y precipicios de latencia p99; la memoria es incompresible, así que necesita un límite para proteger el nodo. `GOMEMLIMIT` derivado del límite mantiene al GC de Go bajo el techo del cgroup en lugar de terminar OOMKilled.
- **`terminationGracePeriodSeconds: 45` > drenaje de preStop (10 s) + timeout de apagado (25 s)** — si el período de gracia es más corto que el drenaje, el kernel mata el proceso en medio de un request.
- **`topologySpreadConstraints` sobre zonas con `DoNotSchedule`** — esto es lo que hace que "multi-AZ" sea real y no aspiracional; sin esto el planificador puede ubicar las cuatro réplicas en una sola zona.
- **`automountServiceAccountToken: false`** — una aplicación que no llama a la API de Kubernetes no tiene por qué sostener un token que sí puede hacerlo.
- **Egreso denegado por defecto** — la NetworkPolicy de arriba es una lista de permitidos completa; notá que DNS debe permitirse explícitamente o toda resolución de nombres falla, lo que se presenta como errores de conexión aleatorios, no como un error de política.

---

## 7. Modelos de despliegue en la nube, elasticidad e inmutabilidad

### 7.1 Reparto de responsabilidades

| Modelo | Vos gestionás | El proveedor gestiona | Unidad de escalado | Lock-in típico |
|---|---|---|---|---|
| **On-premises** | Todo | Nada | Rack | Ninguno |
| **IaaS** | SO, runtime, app, datos | Virtualización, hardware, tejido de red | VM | Bajo (imágenes, redes) |
| **CaaS** (Kubernetes gestionado) | Imagen de contenedor, manifiestos, app, datos | Plano de control, ciclo de vida de nodos | Pod | Medio (portable vía la API de Kubernetes) |
| **PaaS** | Código de la app + configuración | SO, runtime, escalado, parcheo | Instancia de app | Alto (buildpacks, servicios propietarios) |
| **FaaS** | Código de la función | Todo lo demás | Invocación | Muy alto (modelo de eventos, límites del runtime) |
| **SaaS** | Datos y configuración | La aplicación entera | Asiento/uso | Muy alto (la exportación de datos es la única salida) |

El encuadre del examen: IaaS ⇒ vos seguís parcheando el SO; PaaS ⇒ empujás código, no máquinas; SaaS ⇒ consumís, no desplegás.

### 7.2 Regiones, zonas de disponibilidad, y contra qué protegen realmente

- **Zona de disponibilidad**: un dominio de fallo independiente dentro de una región — energía, refrigeración y red separadas, pero con interconexión de baja latencia (típicamente <2 ms). Protege contra un fallo a nivel de datacenter. Barata de usar: la replicación síncrona entre AZ es viable.
- **Región**: una ubicación geográficamente distinta. Protege contra una caída regional y satisface requisitos de residencia de datos. La replicación entre regiones es asíncrona en la práctica (velocidad de la luz), así que viene con un RPO > 0.

| Fallo a sobrevivir | Topología mínima | Costo | Consistencia de datos |
|---|---|---|---|
| Nodo/VM individual | ≥2 réplicas, antiafinidad | Insignificante | Sin afectar |
| Rack / dominio de energía | Distribuidas entre hosts | Insignificante | Sin afectar |
| Zona de disponibilidad | ≥3 réplicas en ≥3 AZ; almacén de datos basado en quórum | Cargos de tráfico entre AZ | Fuerte, síncrona |
| Región | Activo/pasivo o activo/activo multirregión | Alto (doble huella, egreso) | Eventual; definí RPO/RTO explícitamente |

**Elasticidad vs escalabilidad** — la escalabilidad es la capacidad de manejar más carga agregando recursos; la elasticidad es hacer eso *automáticamente y en ambas direcciones* en respuesta a la demanda. La elasticidad requiere ausencia de estado (§5.1), arranque rápido (factor IX) y una métrica que anticipe la demanda en lugar de rezagarse. La utilización de CPU se rezaga; la profundidad de cola y los requests en vuelo anticipan — por eso el HPA de arriba usa ambas.

### 7.3 Infraestructura inmutable

| | Servidores mutables ("mascotas") | Servidores inmutables ("ganado") |
|---|---|---|
| Mecanismo de cambio | SSH, gestión de configuración ejecutada in situ | Construir una imagen nueva, reemplazar la instancia |
| Drift | Se acumula en silencio; servidores copo de nieve | Estructuralmente imposible |
| Rollback | Volver a ejecutar una configuración vieja y cruzar los dedos | Redesplegar la imagen/digest anterior |
| Depurar un incidente en vivo | Entrar y hurgar | Reproducir desde la misma imagen localmente |
| Tiempo de aprovisionamiento | Minutos (ejecución de configuración) | Minutos (horneado de imagen) + segundos (arranque) |
| Evidencia de cumplimiento | Escaneos de inventario | El digest de la imagen *es* la evidencia |
| Punto débil | "Funcionó la última vez que corrimos Ansible" | Requiere un pipeline de build real y un almacén de artefactos |

Los contenedores hacen de la inmutabilidad el valor por defecto. En VMs, el equivalente es el horneado de imágenes (Packer) más un despliegue de reemplazar-en-lugar-de-parchear. En ambos casos la disciplina es la misma: **ningún cambio interactivo a la infraestructura en ejecución** — si hacés `kubectl exec` y editás un archivo, la próxima reprogramación lo revierte en silencio, y acabás de inventar un bug que se reproduce solo a veces.

Infraestructura como código, declarada y revisable:

```hcl
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
  backend "s3" {
    bucket         = "example-tfstate-prod"
    key            = "shop/orders/terraform.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}

variable "image_digest" {
  description = "Immutable image reference promoted from staging."
  type        = string
}

resource "aws_db_instance" "orders" {
  identifier                   = "orders-prod"
  engine                       = "postgres"
  engine_version               = "16.4"
  instance_class               = "db.r6g.xlarge"
  allocated_storage            = 200
  storage_encrypted            = true
  multi_az                     = true # synchronous standby in a second AZ
  backup_retention_period      = 14
  performance_insights_enabled = true
  deletion_protection          = true
  apply_immediately            = false

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Service     = "orders"
    Environment = "production"
    ManagedBy   = "terraform"
  }
}
```

```
$ terraform plan -out=orders.tfplan
Terraform used the selected providers to generate the following execution plan.
Resource actions are indicated with the following symbols:
  ~ update in-place

Terraform will perform the following actions:

  # aws_db_instance.orders will be updated in-place
  ~ resource "aws_db_instance" "orders" {
        id                      = "orders-prod"
      ~ backup_retention_period = 7 -> 14
        # (48 unchanged attributes hidden)
    }

Plan: 0 to add, 1 to change, 0 to destroy.
```

### 7.4 Estrategias de despliegue

| Estrategia | Mecanismo | Tiempo de inactividad | Capacidad extra | Velocidad de rollback | Detecta releases malas por |
|---|---|---|---|---|---|
| **Recreate** | Parar todo, arrancar lo nuevo | Sí | Ninguna | Redesplegar (lento) | Usuarios quejándose |
| **Rolling** | Reemplazar N a la vez | No | `maxSurge` | Rollback = otra actualización progresiva | Sondas + métricas a posteriori |
| **Blue-green** | Dos entornos completos, se conmuta el enrutador | No | **100 %** | Instantáneo (volver a conmutar) | Pruebas de humo en green antes de la conmutación |
| **Canary** | Un % pequeño del tráfico vivo a la versión nueva, se incrementa | No | Pequeña | Rápido (devolver el tráfico) | Métricas reales de producción sobre tráfico real |
| **A/B testing** | Enrutar por atributo del usuario (encabezado/cookie) | No | Pequeña | Rápido | Métricas de negocio, no solo errores |
| **Shadow / mirror** | Duplicar el tráfico a la versión nueva, descartar las respuestas | No | Duplicado completo de la versión nueva | N/A (nunca sirve a usuarios) | Comparación, con cero riesgo para el usuario |

Blue-green y canary requieren ambos **datos compatibles hacia atrás**: durante la transición, dos versiones de código leen y escriben la misma base de datos. Este es el patrón expand-contract (cambio paralelo):

1. **Expand** — agregar la nueva columna/tabla anulable; desplegar código que escribe tanto lo viejo como lo nuevo y lee lo viejo.
2. **Migrate** — rellenar la columna nueva; desplegar código que escribe ambas y lee la nueva.
3. **Contract** — desplegar código que escribe y lee solo lo nuevo; eliminar la columna vieja en una release posterior.

Nunca combines un cambio de esquema y un cambio de código que dependa de él en el mismo despliegue. Eso es lo que hace imposible el rollback, y el rollback es la única mitigación confiable de incidentes.

Un canary con análisis automatizado, para que la decisión de rollback no sea una persona mirando un dashboard a las 03:00:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: orders
  namespace: shop
spec:
  replicas: 10
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app.kubernetes.io/name: orders
  template:
    metadata:
      labels:
        app.kubernetes.io/name: orders
    spec:
      containers:
        - name: orders
          image: "registry.example.com/orders@sha256:9f2c4d1b8ae0a7c3f5d69b21c0e4a7f8d3b6c19e25aa70fd1c8b4e39a6d2f701"
          ports:
            - name: http
              containerPort: 8080
  strategy:
    canary:
      canaryService: orders-canary
      stableService: orders-stable
      trafficRouting:
        nginx:
          stableIngress: orders
      analysis:
        templates:
          - templateName: orders-success-rate
        startingStep: 2
        args:
          - name: service-name
            value: orders-canary
      steps:
        - setWeight: 5
        - pause:
            duration: 5m
        - setWeight: 20
        - pause:
            duration: 10m
        - setWeight: 50
        - pause:
            duration: 10m
        - setWeight: 100
---
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: orders-success-rate
  namespace: shop
spec:
  args:
    - name: service-name
  metrics:
    - name: success-rate
      interval: 60s
      count: 20
      successCondition: "result[0] >= 0.995"
      failureLimit: 2
      provider:
        prometheus:
          address: "http://prometheus.monitoring.svc.cluster.local:9090"
          query: |
            sum(rate(http_requests_total{service="{{args.service-name}}",code!~"5.."}[2m]))
            /
            sum(rate(http_requests_total{service="{{args.service-name}}"}[2m]))
    - name: latency-p99
      interval: 60s
      count: 20
      successCondition: "result[0] <= 0.750"
      failureLimit: 2
      provider:
        prometheus:
          address: "http://prometheus.monitoring.svc.cluster.local:9090"
          query: |
            histogram_quantile(
              0.99,
              sum by (le) (
                rate(http_request_duration_seconds_bucket{service="{{args.service-name}}"}[2m])
              )
            )
```

Observado durante un rollout:

```
$ kubectl argo rollouts get rollout orders -n shop --watch
Name:            orders
Namespace:       shop
Status:          ॥ Paused
Message:         CanaryPauseStep
Strategy:        Canary
  Step:          3/7
  SetWeight:     20
  ActualWeight:  20
Images:          registry.example.com/orders@sha256:9f2c... (canary)
                 registry.example.com/orders@sha256:1a7e... (stable)
Replicas:
  Desired:       10
  Current:       10
  Updated:       2
  Ready:         10
  Available:     10

NAME                                 KIND         STATUS     AGE   INFO
⟳ orders                             Rollout      ॥ Paused   6d
├──# revision:12
│  └──⧉ orders-7c9f6d4bb8            ReplicaSet   ✔ Healthy  4m    canary
│     ├──□ orders-7c9f6d4bb8-2xk9d   Pod          ✔ Running  4m    ready:1/1
│     └──□ orders-7c9f6d4bb8-9wq4p   Pod          ✔ Running  4m    ready:1/1
│  └──α orders-7c9f6d4bb8-2          AnalysisRun  ✔ Success  4m    ✔ 4
└──# revision:11
   └──⧉ orders-6b4d7c9f55            ReplicaSet   ✔ Healthy  6d    stable
```

Y un canary fallando que se aborta solo:

```
$ kubectl argo rollouts status orders -n shop
Error: The rollout is in a degraded state with message: RolloutAborted: Rollout aborted update to revision 13

$ kubectl describe analysisrun orders-8f6c2a1dd9-4 -n shop | tail -12
Status:
  Phase:  Failed
  Metric Results:
    Name:   success-rate
    Phase:  Failed
    Measurements:
      Value:  0.9713   Phase: Failed
      Value:  0.9688   Phase: Failed
      Value:  0.9702   Phase: Failed
Events:
  Type     Reason         Age   From                 Message
  Warning  MetricFailed   90s   rollouts-controller  metric 'success-rate' failure limit exceeded (2)
```

---

## 8. Migrar e integrar un sistema monolítico heredado

### 8.1 Registro de riesgos

| Riesgo | Por qué duele | Control |
|---|---|---|
| Reescritura big-bang | Dos sistemas a mantener, congelamiento de funcionalidades por 18 meses, sin valor incremental | Strangler fig — incremental, siempre entregable |
| La base de datos compartida persiste | El servicio extraído sigue escribiendo las tablas del monolito ⇒ monolito distribuido | Un escritor por tabla; lectura vía API o eventos replicados |
| Garantías transaccionales perdidas | Una operación que era un `COMMIT` ahora abarca dos servicios | Saga + compensación, o mantenerla dentro de un mismo límite |
| El modelo de dominio heredado se filtra | Los servicios nuevos heredan 15 años de semántica accidental | Capa anticorrupción que traduce en el límite |
| Comportamiento no documentado | Los bugs del monolito son estructurales para los consumidores aguas abajo | Tráfico en sombra / ejecución paralela y comparación de salidas |
| Sin pruebas | La refactorización es inverificable | Pruebas de caracterización: capturar el comportamiento actual antes de cambiarlo |
| Regresión de latencia | Una llamada in-process se convierte en una llamada de red dentro de un bucle caliente | Medí primero; hacé la API más gruesa; agrupá en lotes |
| Suposiciones con estado | Sesión en memoria, escrituras a archivos locales, planificadores singleton | Externalizá el estado antes de containerizar (§5) |
| Riesgo de corte big-bang | Sin camino de rollback | Ejecución dual con feature flag; enrutar un %; mantener el camino viejo caliente |

### 8.2 El strangler fig, en concreto

Poné una fachada (ingress, API gateway, proxy inverso) delante del monolito desde el día uno. Al principio enruta el 100 % al monolito. Cada capacidad extraída se vuelve una ruta nueva.

```
            ┌───────────────┐
  client ──▶│  API gateway  │
            └───┬───────┬───┘
   /v2/orders   │       │   everything else
                ▼       ▼
        ┌─────────────┐  ┌────────────────────┐
        │   orders    │  │  legacy monolith   │
        │  (new svc)  │  │                    │
        └──────┬──────┘  └─────────┬──────────┘
               │                   │
               ▼                   ▼
        ┌─────────────┐  ┌────────────────────┐
        │ orders DB   │  │   legacy schema    │
        └─────────────┘  └────────────────────┘
                ▲                  │
                └── CDC / events ◀──┘  (one-way, during transition)
```

Enrutamiento a nivel de ingress que hace la extracción invisible para los clientes:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: shop-facade
  namespace: shop
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "60"
spec:
  ingressClassName: nginx
  rules:
    - host: api.example.com
      http:
        paths:
          - path: /v2/orders
            pathType: Prefix
            backend:
              service:
                name: orders
                port:
                  name: http
          - path: /
            pathType: Prefix
            backend:
              service:
                name: legacy-monolith
                port:
                  number: 8080
```

**Branch by abstraction** es el análogo dentro del código cuando la costura no es una ruta HTTP: introducí una interfaz en el monolito, implementala dos veces (camino heredado y camino de llamada remota), seleccioná en tiempo de ejecución con un feature flag, escalá el porcentaje y después borrá la implementación heredada. Mantiene el trunk siempre liberable, que es el prerrequisito para la entrega continua.

---

## 9. Riesgos de seguridad de aplicaciones y mitigaciones

### 9.1 El OWASP Top 10 (edición 2021) en un contexto cloud-native

> El OWASP Top 10 se revisa periódicamente; la edición 2021 es la que más habitualmente referencian los objetivos de examen y las herramientas. Consultá `https://owasp.org/www-project-top-ten/` para ver la edición publicada actualmente antes de citar números de categoría en una auditoría.

| ID | Categoría | Manifestación cloud-native | Mitigación que podés implementar |
|---|---|---|---|
| A01 | Broken Access Control | IDOR (`GET /orders/{id}` sin chequeo de propiedad); llamadas servicio a servicio confiadas porque "están dentro del clúster" | Autorizá en cada request contra el sujeto, no contra la ubicación de red; denegá por defecto; NetworkPolicy + mTLS como defensa en profundidad, nunca como el control |
| A02 | Cryptographic Failures | TLS terminado en el ingress y texto plano dentro de la malla; secretos en Git; backups sin cifrar | TLS en todas partes (mTLS en la malla), cifrado en reposo, HSTS, nada de criptografía casera |
| A03 | Injection | Inyección SQL/NoSQL/comandos/LDAP; inyección de plantillas | Solo consultas parametrizadas; nunca construir SQL por concatenación; validar/lista de permitidos en la entrada; evitar ejecución estilo `shell=True` |
| A04 | Insecure Design | Sin modelo de amenazas; sin limitación de tasa; consultas sin límite | Modelá amenazas en cada límite nuevo; diseñá casos de abuso; cuotas y límites como requisitos |
| A05 | Security Misconfiguration | `privileged: true`, contenedores como root, endpoints de depuración expuestos, credenciales por defecto, CORS permisivo | Pod Security Admission `restricted`; política de admisión en CI; escaneo de configuración (`kubescape`, `trivy config`) |
| A06 | Vulnerable and Outdated Components | Una imagen base con 180 CVE; una dependencia transitiva con un RCE conocido | SBOM por build, escaneo en CI *y* de forma continua en el registro, actualizaciones automatizadas de dependencias |
| A07 | Identification and Authentication Failures | Tokens de larga vida, sin MFA, `alg: none` aceptado, fijación de sesión | Tokens de vida corta, validación estricta de JWT, rotación al cambiar privilegios, MFA para rutas de administración |
| A08 | Software and Data Integrity Failures | Imágenes sin firmar, CI descargando `latest` desde un registro sin fijar, deserialización insegura | Firmá artefactos (Sigstore/cosign), verificá firmas en un controlador de admisión, fijá por digest, atestaciones de procedencia (SLSA) |
| A09 | Security Logging and Monitoring Failures | Fallos de autenticación no registrados; sin alerta ante un pico de 401/403; logs sin IDs de correlación | Registrá eventos de seguridad de forma estructurada; alertá ante anomalías; retené según la política; nunca registres secretos ni tokens |
| A10 | Server-Side Request Forgery | Un servicio que descarga una URL provista por el usuario alcanza el endpoint de metadatos de la nube y roba credenciales de instancia | Lista de permitidos de destinos salientes; bloqueá la link-local `169.254.169.254` con NetworkPolicy; forzá IMDSv2; validá la URL después de la resolución DNS |

### 9.2 Secretos: la respuesta en capas

| Capa | Práctica | Antipatrón que reemplaza |
|---|---|---|
| Fuente | Secretos nunca en Git; escaneo pre-commit (`gitleaks`) | `config/prod.yaml` con una contraseña |
| Build | Montajes de secretos de BuildKit (`--mount=type=secret`) | `ARG TOKEN` — visible en el historial de la imagen para siempre |
| Almacenamiento | Gestor externo (Vault, almacén respaldado por KMS de la nube), o como mínimo cifrado de etcd en reposo | Base64 en un manifiesto — base64 es codificación, no cifrado |
| Entrega | Archivos montados, TTL corto, rotados automáticamente (CSI Secrets Store / External Secrets Operator) | Un `Secret` creado a mano hace dos años |
| Runtime | Leer al arrancar o al cambiar el archivo; nunca registrar; redactar en los manejadores de error | Imprimir la estructura de configuración al arrancar |
| Rotación | Automatizada, probada, sin necesidad de redespliegue | "Rotamos cuando alguien se va" |

```
$ gitleaks detect --source . --redact --no-banner
Finding:     DATABASE_URL="postgres://orders:REDACTED@db.internal:5432/orders"
Secret:      REDACTED
RuleID:      generic-api-key
File:        deploy/overlays/prod/env.properties
Line:        12
Commit:      8c41d0aa9f1e2b3c4d5e6f708192a3b4c5d6e7f8

1 leak found
```

### 9.3 Cadena de suministro: SBOM, escanear, firmar, verificar

```
$ syft registry.example.com/orders:2.3.0 -o spdx-json > sbom.spdx.json
 ✔ Parsed image      sha256:9f2c4d1b8ae0
 ✔ Cataloged contents
   ├── ✔ Packages           [37 packages]
   └── ✔ Executables        [1 executables]

$ grype sbom:sbom.spdx.json --fail-on high
NAME                  INSTALLED  FIXED-IN  TYPE    VULNERABILITY   SEVERITY
golang.org/x/net      v0.28.0    v0.33.0   go-mod  GHSA-w32m-9786  Medium
stdlib                go1.23.2   go1.23.5  go-mod  CVE-2024-45341  Medium

2 vulnerabilities found (0 critical, 0 high, 2 medium, 0 low)

$ cosign sign --yes registry.example.com/orders@sha256:9f2c4d1b8ae0...
tlog entry created with index: 148820417

$ cosign verify \
    --certificate-identity-regexp 'https://github.com/example/orders/.*' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    registry.example.com/orders@sha256:9f2c4d1b8ae0... | jq '.[0].optional.Subject'
Verification for registry.example.com/orders@sha256:9f2c4d1b8ae0... --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified offline
  - The code-signing certificate was verified using trusted certificate authority certificates
"https://github.com/example/orders/.github/workflows/release.yml@refs/tags/v2.3.0"
```

---

## 10. Automatización del build y el pipeline de CI/CD

Las herramientas de automatización de build (Maven, Gradle, npm/pnpm, Make, Bazel, Cargo, módulos de Go) existen para hacer el build **declarativo, reproducible y consciente de las dependencias**. Su contribución operativa:

| Propiedad | Por qué importa en producción |
|---|---|
| Dependencias declaradas con un archivo de bloqueo | El build es reproducible seis meses después y en otra máquina (factor II) |
| Resolución determinista de dependencias | `npm ci` desde `package-lock.json`, no `npm install` — si no, CI y prod difieren |
| Un grafo de dependencias | Builds incrementales; solo se reconstruye y se vuelve a probar lo que cambió |
| Fases de ciclo de vida estándar | `compile → test → package → verify` es el mismo verbo en todos los repos |
| Publicación de artefactos con coordenadas | Un artefacto inmutable y direccionable (GAV, semver + digest) es lo que se promueve |

Un pipeline que hace cumplir las reglas de diseño de arriba, de punta a punta:

```yaml
name: release
on:
  push:
    tags:
      - "v*"

permissions:
  contents: read
  packages: write
  id-token: write

jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Secret scan
        run: |
          docker run --rm -v "$PWD:/repo" zricethezav/gitleaks:latest \
            detect --source /repo --redact --no-banner

      - name: Contract lint and breaking-change gate
        run: |
          npx @redocly/cli@latest lint openapi.yaml
          docker run --rm -v "$PWD:/w" -w /w tufin/oasdiff:latest \
            breaking "https://api.example.com/v2/openapi.yaml" openapi.yaml

      - name: Build, test and push
        id: build
        run: |
          VERSION="${GITHUB_REF_NAME#v}"
          IMAGE="registry.example.com/orders"
          docker buildx build \
            --build-arg "VERSION=${VERSION}" \
            --build-arg "COMMIT=${GITHUB_SHA::7}" \
            --target runtime \
            --provenance=true --sbom=true \
            --tag "${IMAGE}:${VERSION}" \
            --push .
          DIGEST=$(docker buildx imagetools inspect "${IMAGE}:${VERSION}" \
            --format '{{ "{{" }}.Manifest.Digest{{ "}}" }}')
          echo "ref=${IMAGE}@${DIGEST}" >> "$GITHUB_OUTPUT"

      - name: Vulnerability gate
        run: |
          docker run --rm aquasec/trivy:latest image \
            --exit-code 1 --severity CRITICAL,HIGH --ignore-unfixed \
            "${{ steps.build.outputs.ref }}"

      - name: Sign
        run: cosign sign --yes "${{ steps.build.outputs.ref }}"

      - name: Promote by digest
        run: |
          yq -i '.spec.template.spec.containers[0].image = strenv(REF)' \
            deploy/overlays/prod/deployment.yaml
        env:
          REF: ${{ steps.build.outputs.ref }}
```

Los principios de diseño codificados acá: construir una vez y promover el **digest**; poner una compuerta de compatibilidad de contrato antes de que algo llegue a un entorno; hacer fallar el build ante secretos y ante CVE de severidad alta con arreglo disponible; y firmar el artefacto para que el clúster pueda rechazar cualquier cosa sin firmar.

---

## 11. Verificación y diagnóstico de fallos

### 11.1 Escalera de verificación previa al despliegue

| Pregunta | Comando | Costo |
|---|---|---|
| ¿El YAML es válido y correcto según el esquema? | `kubeconform -strict -summary -kubernetes-version 1.31.0 deploy/` | Gratis |
| ¿Viola alguna política de seguridad? | `trivy config deploy/` · `kubescape scan framework nsa deploy/` | Gratis |
| ¿El contenedor corre sin root y con rootfs de solo lectura? | `docker run --rm --read-only <img> id` | Gratis |
| ¿El PID 1 maneja SIGTERM? | `time docker stop <container>` (esperar < 1 s) | Gratis |
| ¿El contrato de la API es compatible hacia atrás? | `oasdiff breaking <old> <new>` | Gratis |
| ¿Las sondas responden correctamente? | `curl -sf localhost:8080/readyz` | Gratis |
| ¿La app arranca solo con su configuración declarada? | `docker run --env-file env.prod.example <img>` | Gratis |
| ¿Sobrevive a que una dependencia esté caída? | Caos: escalá la dependencia a 0, mirá la tasa de error y el fallback | Barato |

```
$ kubeconform -strict -summary -kubernetes-version 1.31.0 deploy/base/
Summary: 8 resources found parsing 8 files - Valid: 8, Invalid: 0, Errors: 0, Skipped: 0

$ trivy config --severity HIGH,CRITICAL deploy/base/
deploy/base/deployment.yaml (kubernetes)
Tests: 128 (SUCCESSES: 127, FAILURES: 1)
Failures: 1 (HIGH: 1, CRITICAL: 0)

HIGH: Container 'orders' of Deployment 'orders' should set 'resources.limits.cpu'
════════════════════════════════════════════════════════════════════════════════
Enforcing a CPU limit prevents DoS by a runaway container.
See https://avd.aquasec.com/misconfig/ksv011
```

*(Ese hallazgo en particular es uno para anular deliberadamente — ver §6.4 sobre el throttling de CFS. Documentá la excepción en lugar de silenciar el escáner globalmente.)*

### 11.2 Catálogo de fallos

#### A. `CrashLoopBackOff` inmediatamente después del deploy

```
$ kubectl get pods -n shop -l app.kubernetes.io/name=orders
NAME                      READY   STATUS             RESTARTS      AGE
orders-7c9f6d4bb8-2xk9d   0/1     CrashLoopBackOff   4 (38s ago)   2m14s

$ kubectl logs -n shop orders-7c9f6d4bb8-2xk9d --previous
{"ts":"2026-09-18T09:41:02.117Z","level":"fatal","event":"config_invalid","error":"required environment variable DATABASE_URL is not set"}

$ kubectl get deploy orders -n shop -o jsonpath='{.spec.template.spec.containers[0].envFrom}' | jq .
[
  {
    "configMapRef": {
      "name": "orders-config"
    }
  }
]
```

Causa raíz: la entrada `secretRef` se perdió en un merge. **Valor diagnóstico del diseño:** la app falla rápido y ruidosamente ante configuración faltante en el arranque en lugar de en el primer request — validá la configuración en `main()`, antes de vincular el puerto.

#### B. La actualización progresiva produce 502

```
$ kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --tail=5
10.244.2.9 - - [18/Sep/2026:09:52:11 +0000] "POST /v2/orders HTTP/2.0" 502 150 "-" 0.002 [shop-orders-http] 10.244.3.41:8080 - - 502

$ kubectl get events -n shop --sort-by=.lastTimestamp | tail -5
2m    Normal   Killing   pod/orders-6b4d7c9f55-kk29x   Stopping container orders
2m    Normal   Started   pod/orders-7c9f6d4bb8-2xk9d   Started container orders

$ kubectl get deploy orders -n shop -o jsonpath='{.spec.template.spec.terminationGracePeriodSeconds}{"\n"}'
30
$ kubectl exec -n shop orders-7c9f6d4bb8-2xk9d -- sh -c 'echo $SHUTDOWN_TIMEOUT'
60s
```

Causa raíz: el propio timeout de apagado de la aplicación (60 s) excede `terminationGracePeriodSeconds` (30 s), así que el kubelet hace `SIGKILL` en medio del drenaje; y no hay retardo `preStop`, así que el listener se cierra antes de que el endpoint se retire de todos los planos de datos. Arreglá ambas cosas: período de gracia > preStop + timeout de apagado, y agregá el drenaje preStop (§6.4).

#### C. "Funciona en `curl` pero no en el navegador"

```
$ curl -s -o /dev/null -w '%{http_code}\n' https://api.example.com/v2/orders
200

$ curl -i -X OPTIONS https://api.example.com/v2/orders \
    -H 'Origin: https://app.example.com' \
    -H 'Access-Control-Request-Method: POST' \
    -H 'Access-Control-Request-Headers: content-type' | head -8
HTTP/2 401
www-authenticate: Bearer realm="api"
content-type: application/problem+json
```

Causa raíz: el middleware de autenticación corre antes del manejo de CORS, así que el preflight — que por diseño no lleva credenciales — se rechaza con 401 y el navegador nunca emite el request real. El manejador de `OPTIONS` debe registrarse antes del middleware de autenticación. Segunda variante de la misma clase:

```
$ curl -sI https://api.example.com/v2/orders -H 'Origin: https://app.example.com' \
  | grep -i -E 'access-control|vary'
access-control-allow-origin: *
access-control-allow-credentials: true
```

Causa raíz: `*` con credenciales es rechazado de plano por todos los navegadores. Devolvé el origen validado y agregá `Vary: Origin`.

#### D. Pérdida de sesiones tras un scale-in

```
$ kubectl get hpa orders -n shop
NAME     REFERENCE           TARGETS            MINPODS   MAXPODS   REPLICAS   AGE
orders   Deployment/orders   31%/65%, 4/25      4         40        4          19d

$ kubectl logs -n shop -l app.kubernetes.io/name=orders --tail=200 \
  | jq -r 'select(.event=="session_not_found") | .session_id' | wc -l
1184

$ kubectl exec -n shop orders-7c9f6d4bb8-2xk9d -- sh -c 'echo $SESSION_STORE'
memory
```

Causa raíz: violación del factor VI — estado de sesión en la memoria del proceso. El HPA redujo de 12 a 4 y expulsó las sesiones equivalentes a ocho réplicas. Arreglo: externalizar a un almacén compartido, o pasar a tokens firmados de vida corta (§5.2). Las sticky sessions enmascararían el síntoma y mutilarían permanentemente la elasticidad.

#### E. `OOMKilled` bajo carga

```
$ kubectl get pod orders-7c9f6d4bb8-9wq4p -n shop -o jsonpath='{.status.containerStatuses[0].lastState.terminated}' | jq .
{
  "exitCode": 137,
  "finishedAt": "2026-09-18T10:04:51Z",
  "reason": "OOMKilled",
  "startedAt": "2026-09-18T09:58:12Z"
}

$ kubectl top pod -n shop -l app.kubernetes.io/name=orders
NAME                      CPU(cores)   MEMORY(bytes)
orders-7c9f6d4bb8-2xk9d   243m         498Mi
orders-7c9f6d4bb8-9wq4p   251m         511Mi
```

Código de salida 137 = 128 + 9 (`SIGKILL`), razón `OOMKilled`: se alcanzó el límite de memoria del cgroup. Distinguí dos causas raíz antes de subir el límite — una fuga genuina (la memoria crece monotónicamente a lo largo de horas sin importar la carga) frente a un límite subdimensionado (la memoria sigue la tasa de requests y se estabiliza). Para un runtime con su propio GC, verificá además que el techo del heap se derive del límite del cgroup (`GOMEMLIMIT`, `-XX:MaxRAMPercentage`); si no, el recolector nunca siente la presión y el kernel mata el proceso primero.

#### F. `connection refused` intermitente hacia un servicio hermano

```
$ kubectl exec -n shop deploy/orders -- nslookup payments.shop.svc.cluster.local
;; connection timed out; no servers could be reached

$ kubectl get networkpolicy orders -n shop -o jsonpath='{.spec.egress[*].ports[*].port}'
8080 5432
```

Causa raíz: una política de egreso de denegación por defecto sin un permiso explícito para DNS (UDP/TCP 53 hacia `kube-dns`). El síntoma no es "política denegada" — es la resolución DNS agotando su tiempo, lo que aflora como errores de conexión con latencia de varios segundos. Toda política de egreso de denegación por defecto necesita la regla de DNS mostrada en §6.4.

#### G. Los reintentos en estampida amplifican una caída parcial

```
$ kubectl logs -n shop -l app.kubernetes.io/name=payments --tail=3
{"level":"warn","event":"pool_exhausted","waiters":412,"max_conns":20}

$ curl -s "http://prometheus.monitoring.svc:9090/api/v1/query" \
    --data-urlencode 'query=sum(rate(http_client_requests_total{service="orders",upstream="payments"}[1m]))' \
  | jq -r '.data.result[0].value[1]'
3184.6
```

Causa raíz: amplificación por reintentos. Tres reintentos sin jitter y sin presupuesto convirtieron un parpadeo upstream de 1 000 rps en más de 3 000 rps. Controles, en orden de efectividad: un **presupuesto de reintentos** (limitar los reintentos a ~10 % del tráfico base), **backoff exponencial con full jitter**, un **circuit breaker** que falle rápido mientras el upstream esté insano, y **nunca reintentar operaciones no idempotentes sin una clave de idempotencia**.

### 11.3 Una auditoría twelve-factor que podés correr sobre cualquier servicio

```
$ kubectl get deploy orders -n shop -o yaml > /tmp/d.yaml

# III  — config from the environment, not baked in
$ yq '.spec.template.spec.containers[0].envFrom' /tmp/d.yaml
# VI   — no persistent volumes, no local state
$ yq '.spec.template.spec.volumes' /tmp/d.yaml
# VII  — port binding
$ yq '.spec.template.spec.containers[0].ports' /tmp/d.yaml
# IX   — disposability: grace period and preStop present
$ yq '.spec.template.spec | {"grace": .terminationGracePeriodSeconds, "preStop": .containers[0].lifecycle.preStop}' /tmp/d.yaml
# V    — immutable release: image pinned by digest
$ yq '.spec.template.spec.containers[0].image' /tmp/d.yaml | grep -q '@sha256:' \
    && echo "pinned by digest" || echo "MUTABLE TAG — not a reproducible release"
# XI   — logs go to stdout only
$ kubectl exec -n shop deploy/orders -- ls -l /proc/1/fd/1 /proc/1/fd/2
```

```
pinned by digest
l-wx------ 1 65532 65532 64 Sep 18 10:11 /proc/1/fd/1 -> pipe:[418822]
l-wx------ 1 65532 65532 64 Sep 18 10:11 /proc/1/fd/2 -> pipe:[418823]
```

---

## 12. Resumen orientado al examen

- **El acoplamiento débil** es la meta; los microservicios son un medio. Un servicio que comparte una tabla de base de datos con otro servicio no está débilmente acoplado.
- **SOA** pone la orquestación en el bus; **los microservicios** la ponen en los endpoints y mantienen las tuberías tontas.
- **Restricciones de REST** que importan: ausencia de estado, interfaz uniforme, cacheabilidad. GET/PUT/DELETE son idempotentes; **POST no**.
- **JSON**: UTF-8, sin comentarios, fechas RFC 3339, dinero en unidades menores enteras.
- **CORS** lo aplica el navegador y relaja la política del mismo origen; `Content-Type: application/json` siempre dispara un preflight `OPTIONS`; `Allow-Origin: *` es incompatible con `Allow-Credentials: true`; enviá siempre `Vary: Origin`.
- **Twelve-factor**: configuración en el entorno, procesos sin estado, logs a stdout, arranque rápido y apagado elegante, separación estricta de build/release/run.
- **Contenedores**: una preocupación, sin root, rootfs de solo lectura, el PID 1 maneja `SIGTERM`, `CMD` en forma exec, fijado por digest, sin secretos en las capas.
- **Sondas**: liveness reinicia y no debe probar dependencias; readiness controla el tráfico y debe fallar al apagarse; startup cubre la inicialización lenta.
- **El estado** vive en servicios de respaldo (factor IV), adjuntados por URL; las sticky sessions son una muleta heredada que bloquea la elasticidad.
- **IaaS/PaaS/SaaS**: quién parchea el SO es la pregunta que los distingue. Una **AZ** protege contra un datacenter; una **región**, contra una geografía.
- **Servidores inmutables**: reemplazar, nunca parchear. El rollback es redesplegar el digest anterior.
- **Blue-green** necesita el doble de capacidad y da una conmutación instantánea; **canary** incrementa tráfico real y detecta problemas con señales de producción. Ambas necesitan esquemas compatibles hacia atrás (expand–contract).
- **Migración de sistemas heredados**: strangler fig detrás de una fachada, capa anticorrupción en el límite, pruebas de caracterización primero, nunca una reescritura big-bang.
- **Seguridad**: el OWASP Top 10 como taxonomía de riesgos; secretos nunca en Git ni en capas de imagen; firmá y verificá los artefactos; SSRF alcanza el endpoint de metadatos salvo que lo bloquees.

---

## 13. Referencias

**Objetivos oficiales del examen**
- LPI — Exam 701 Objectives (DevOps Tools Engineer, 701-100): https://www.lpi.org/our-certifications/exam-701-objectives/
- LPI — DevOps Tools Engineer certification overview: https://www.lpi.org/our-certifications/devops-overview/

**Arquitectura y metodología**
- The Twelve-Factor App: https://12factor.net/
- Fielding, R. T., *Architectural Styles and the Design of Network-based Software Architectures*, Cap. 5 (REST): https://ics.uci.edu/~fielding/pubs/dissertation/rest_arch_style.htm
- CNCF Cloud Native Definition v1.1: https://github.com/cncf/toc/blob/main/DEFINITION.md
- CNCF Cloud Native Landscape: https://landscape.cncf.io/
- NIST SP 800-145, *The NIST Definition of Cloud Computing* (IaaS/PaaS/SaaS): https://csrc.nist.gov/pubs/sp/800/145/final
- NIST SP 800-190, *Application Container Security Guide*: https://csrc.nist.gov/pubs/sp/800/190/final

**APIs y estándares web**
- RFC 9110 — HTTP Semantics: https://www.rfc-editor.org/rfc/rfc9110.html
- RFC 8259 — The JavaScript Object Notation (JSON) Data Interchange Format: https://www.rfc-editor.org/rfc/rfc8259.html
- RFC 9457 — Problem Details for HTTP APIs: https://www.rfc-editor.org/rfc/rfc9457.html
- RFC 3339 — Date and Time on the Internet: https://www.rfc-editor.org/rfc/rfc3339.html
- RFC 7396 — JSON Merge Patch: https://www.rfc-editor.org/rfc/rfc7396.html
- RFC 6902 — JavaScript Object Notation (JSON) Patch: https://www.rfc-editor.org/rfc/rfc6902.html
- RFC 7519 — JSON Web Token (JWT): https://www.rfc-editor.org/rfc/rfc7519.html
- WHATWG Fetch Standard (protocolo CORS): https://fetch.spec.whatwg.org/#http-cors-protocol
- MDN — Cross-Origin Resource Sharing (CORS): https://developer.mozilla.org/en-US/docs/Web/HTTP/CORS
- MDN — Same-origin policy: https://developer.mozilla.org/en-US/docs/Web/Security/Same-origin_policy
- OpenAPI Specification 3.1.0: https://spec.openapis.org/oas/v3.1.0.html
- W3C Trace Context: https://www.w3.org/TR/trace-context/
- Documentación de gRPC: https://grpc.io/docs/
- Especificación de GraphQL: https://spec.graphql.org/

**Contenedores y orquestación**
- OCI Image Format Specification: https://github.com/opencontainers/image-spec/blob/main/spec.md
- OCI Runtime Specification: https://github.com/opencontainers/runtime-spec/blob/main/spec.md
- Referencia de Dockerfile: https://docs.docker.com/reference/dockerfile/
- Docker — Multi-stage builds: https://docs.docker.com/build/building/multi-stage/
- Docker — Build secrets: https://docs.docker.com/build/building/secrets/
- Kubernetes — Configure Liveness, Readiness and Startup Probes: https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- Kubernetes — Pod Lifecycle (terminación): https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/
- Kubernetes — Configure a Pod to Use a ConfigMap: https://kubernetes.io/docs/tasks/configure-pod-container/configure-pod-configmap/
- Kubernetes — Secrets: https://kubernetes.io/docs/concepts/configuration/secret/
- Kubernetes — Horizontal Pod Autoscaling: https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
- Kubernetes — Pod Topology Spread Constraints: https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/
- Kubernetes — Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes — Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Kubernetes — Pod Disruption Budgets: https://kubernetes.io/docs/concepts/workloads/pods/disruptions/
- Argo Rollouts — Canary strategy: https://argo-rollouts.readthedocs.io/en/stable/features/canary/
- Argo Rollouts — Analysis and progressive delivery: https://argo-rollouts.readthedocs.io/en/stable/features/analysis/

**Seguridad y cadena de suministro**
- OWASP Top 10: https://owasp.org/www-project-top-ten/
- OWASP Application Security Verification Standard (ASVS): https://owasp.org/www-project-application-security-verification-standard/
- OWASP Cheat Sheet Series: https://cheatsheetseries.owasp.org/
- OWASP Kubernetes Top Ten: https://owasp.org/www-project-kubernetes-top-ten/
- SLSA — Supply-chain Levels for Software Artifacts: https://slsa.dev/spec/v1.0/
- Documentación de Sigstore / cosign: https://docs.sigstore.dev/
- Especificación SPDX: https://spdx.dev/use/specifications/
- Especificación CycloneDX: https://cyclonedx.org/specification/overview/

**Infraestructura como código y automatización del build**
- Documentación de Terraform: https://developer.hashicorp.com/terraform/docs
- Documentación de HashiCorp Packer: https://developer.hashicorp.com/packer/docs
- Apache Maven — Build lifecycle reference: https://maven.apache.org/guides/introduction/introduction-to-the-lifecycle.html
- Gradle user manual: https://docs.gradle.org/current/userguide/userguide.html
- npm CLI — `npm ci`: https://docs.npmjs.com/cli/v10/commands/npm-ci
- Documentación de GitHub Actions: https://docs.github.com/en/actions
- Documentación de GitLab CI/CD: https://docs.gitlab.com/ee/ci/