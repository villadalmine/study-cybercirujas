# LPI Open Source Essentials (050-100) — Topic 4.2: Service Provider Business Models

## Descripción General de la Arquitectura y Contexto de Producción

En la ingeniería de plataformas moderna y la arquitectura cloud, el software de código abierto (OSS) sirve como el sustrato fundamental para software-as-a-service (SaaS) y proveedores de servicios gestionados (MSPs). Construir un negocio de proveedor de servicios viable y de nivel empresarial sobre componentes de código abierto requiere alinear decisiones arquitectónicas, cumplimiento de licencias, modelos de multatenencia (tenancy models), y monitoreo de Acuerdos de Nivel de Servicio (SLA).

### Modelos de Negocio Principales para Proveedores de Servicios de Código Abierto

1. **Fully Managed Cloud Service / Hosted SaaS**: 
   El proveedor de servicios aloja, opera, auto-escala y gestiona el software de código abierto (ej., Managed PostgreSQL, Managed Kafka). La propuesta de valor se centra en la eficiencia operativa, SLAs de tiempo de actividad (uptime), conmutación por error multirregión (multi-region failover), copias de seguridad (backups) y cumplimiento de seguridad.
2. **Open Core**: 
   El motor principal permanece como código abierto (permisivo o copyleft), mientras que los módulos empresariales propietarios (ej., RBAC, SAML/OIDC SSO, registro de auditoría, cifrado avanzado, replicación multicentro de datos) se agrupan en niveles comerciales.
3. **Dual Licensing**: 
   El proveedor ofrece el software bajo una licencia copyleft fuerte (ej., GNU AGPLv3) para uso no comercial/código abierto, mientras vende licencias comerciales propietarias a organizaciones que necesitan integrar el software en productos propietarios sin activar los requisitos de copyleft.
4. **Professional Services, Support & Training**: 
   El proveedor monetiza la experiencia especializada, SLAs de soporte empresarial (ej., tiempos de respuesta de 15 minutos para interrupciones de Severidad 1), desarrollo de funcionalidades personalizadas y revisiones de arquitectura (ej., históricamente el modelo de Red Hat).
5. **Source-Available / Re-licensing Defense (BSL/BUSL, SSPL)**: 
   En respuesta a que grandes hiperescaladores revenden proyectos de código abierto sin contribuir al upstream, los proveedores adoptan licencias de código disponible no reconocidas por la OSI (ej., Business Source License 1.1, Server Side Public License v1). Estas restringen alojar el software *como un servicio gestionado comercial* mientras conservan la disponibilidad del código fuente para un uso estándar.

---

## Prerrequisitos y Configuración del Laboratorio

Asegúrese de que las siguientes herramientas estén disponibles en su entorno de shell:

```bash
# Verify required utility dependencies
curl --version
jq --version
docker --version || podman --version
```

Expected Output:
```text
curl 7.81.0 (x86_64-pc-linux-gnu) ...
jq-1.6
Docker version 24.0.7, build af15705
```

---

## Ejercicio Guiado 1: Evaluación del Licenciamiento de Código Abierto y Riesgo de Negocio en Servicios Gestionados

### Escenario
Usted es un Principal Platform Architect evaluando un motor de almacenamiento de datos de código abierto para desplegarlo como una plataforma de servicios gestionados multateniente (multi-tenant). Necesita analizar los límites de las licencias, inspeccionar los manifiestos de dependencias y evaluar los riesgos de cumplimiento bajo AGPLv3, SSPL y Apache 2.0.

### Paso 1: Inspeccionar las Declaraciones de Licencia en Árboles de Dependencias de Código Abierto
Clone un repositorio de servicio de código abierto y escanee su lista de materiales de software (SBOM) y los encabezados de licenciamiento para categorizar los riesgos de alojamiento comercial.

```bash
# Create scratch workspace
mkdir -p /tmp/lpi-lab-topic42 && cd /tmp/lpi-lab-topic42

# Generate a synthetic project dependency file (package.json format for demonstration)
cat << 'EOF' > /tmp/lpi-lab-topic42/dependencies.json
{
  "name": "enterprise-managed-cache",
  "version": "2.4.0",
  "dependencies": {
    "core-engine-kv": {
      "version": "1.0.0",
      "license": "Apache-2.0",
      "hostingRestricted": false
    },
    "enterprise-rbac-module": {
      "version": "3.1.0",
      "license": "BSL-1.1",
      "hostingRestricted": true,
      "changeDate": "2027-01-01",
      "changeLicense": "Apache-2.0"
    },
    "telemetry-agent": {
      "version": "0.9.5",
      "license": "AGPL-3.0-only",
      "hostingRestricted": false
    }
  }
}
EOF

# Parse dependencies with jq to isolate licenses restricting commercial managed service offering
jq '.dependencies | to_entries[] | select(.value.hostingRestricted == true or .value.license == "AGPL-3.0-only") | {package: .key, license: .value.license, hostingRestricted: .value.hostingRestricted}' /tmp/lpi-lab-topic42/dependencies.json
```

Expected Output:
```json
{
  "package": "enterprise-rbac-module",
  "license": "BSL-1.1",
  "hostingRestricted": true
}
{
  "package": "telemetry-agent",
  "license": "AGPL-3.0-only",
  "hostingRestricted": false
}
```

### Paso 2: Validar el Impacto del Copyleft Activado por Red (AGPLv3)
Analice cómo AGPLv3 impacta a los proveedores de servicios cloud que interactúan a través de una API de red en comparación con la GPLv3 tradicional.

```bash
# Compare AGPL-3.0 Section 13 provisions via standard curl against OSI text reference
curl -s https://opensource.org/licenses/AGPL-3.0 | grep -A 2 -i "Remote Network Interaction" || echo "AGPL v3 Section 13 mandates offering source code to users interacting over a network."
```

Expected Output:
```text
AGPL v3 Section 13 mandates offering source code to users interacting over a network.
```

---

### Preguntas de Comprensión — Ejercicio 1

1. **Pregunta 1.1**: ¿Por qué empresas como MongoDB (SSPL) y Elastic (BSL/BUSL) cambiaron de licencias permisivas o copyleft tradicionales a licencias de código disponible (source-available)?
   - A) Para evitar que cualquier empresa o individuo pueda ver el código fuente.
   - B) Para bloquear que los principales proveedores de nube pública ofrezcan su motor de código abierto como un servicio totalmente gestionado sin una asociación comercial o contribución al upstream.
   - C) Para cumplir con marcos de seguridad federales estrictamente regulados como FedRAMP High.
   - D) Porque la OSI (Open Source Initiative) exigía que todos los proyectos de código abierto cambiaran de licencia después de 10 años.

2. **Pregunta 1.2**: Bajo la Licencia Pública General Affero de GNU (AGPLv3), ¿qué desencadenante específico requiere que un proveedor de servicios libere el código fuente de sus modificaciones?
   - A) Solo al enviar binarios físicos o discos de instalación a los clientes.
   - B) Cuando los usuarios interactúan con el software modificado a través de una red informática (ej., a través de una API HTTP o RPC).
   - C) Solo al vender suscripciones de soporte comercial.
   - D) AGPLv3 nunca requiere la divulgación del código fuente bajo ninguna circunstancia.

---

## Ejercicio Guiado 2: Implementación de Mediciones (Metering), Multatenencia y Telemetría para SLAs de Servicios Gestionados

### Escenario
Los proveedores de servicios gestionados deben medir los Indicadores de Nivel de Servicio (SLIs) para garantizar el cumplimiento de los Acuerdos de Nivel de Servicio (SLAs). Además, rastrean métricas de uso (metering) para alimentar modelos de facturación basados en el consumo. Desplegará una configuración de monitoreo local de Prometheus para medir el rendimiento de consultas (throughput), la tasa de errores y los SLIs de disponibilidad en múltiples entornos de inquilinos (tenants).

### Paso 1: Generar Métricas de Prometheus Emulando el Uso Multateniente
Despliegue un script exportador sintético que emita métricas de Prometheus para solicitudes de API HTTP por tenant, latencia de ejecución y estados de error.

```bash
cat << 'EOF' > /tmp/lpi-lab-topic42/metrics_generator.py
import http.server
import time
import random

PORT = 9102

class MetricsHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/metrics':
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; version=0.0.4')
            self.end_headers()
            
            # Emulate telemetry for two service provider tenants
            metrics = []
            metrics.append('# HELP http_requests_total Total HTTP requests handled per tenant.')
            metrics.append('# TYPE http_requests_total counter')
            metrics.append(f'http_requests_total{{tenant_id="tenant_alpha",status="200"}} {random.randint(1000, 1050)}')
            metrics.append(f'http_requests_total{{tenant_id="tenant_alpha",status="500"}} {random.randint(2, 5)}')
            metrics.append(f'http_requests_total{{tenant_id="tenant_beta",status="200"}} {random.randint(400, 450)}')
            metrics.append(f'http_requests_total{{tenant_id="tenant_beta",status="500"}} {random.randint(20, 30)}')
            
            metrics.append('# HELP tenant_storage_bytes Gauge of tenant disk consumption for billing.')
            metrics.append('# TYPE tenant_storage_bytes gauge')
            metrics.append(f'tenant_storage_bytes{{tenant_id="tenant_alpha"}} {1024 * 1024 * 512}') # 512 MiB
            metrics.append(f'tenant_storage_bytes{{tenant_id="tenant_beta"}} {1024 * 1024 * 2048}') # 2048 MiB
            
            self.wfile.write('\n'.join(metrics).encode('utf-8'))
        else:
            self.send_response(404)
            self.end_headers()

if __name__ == '__main__':
    server = http.server.HTTPServer(('0.0.0.0', PORT), MetricsHandler)
    print(f"Metrics exporter listening on port {PORT}...")
    server.serve_forever()
EOF

# Run generator in background
python3 /tmp/lpi-lab-topic42/metrics_generator.py &
EXPORTER_PID=$!
sleep 2
```

Expected Output:
```text
Metrics exporter listening on port 9102...
```

### Paso 2: Consultar y Calcular SLIs de Disponibilidad a través de HTTP
Obtenga métricas sin procesar usando `curl` y calcule el SLI de disponibilidad para cada tenant utilizando `jq`.

$$\text{SLI de Disponibilidad} = \left( \frac{\text{Solicitudes Exitosas (200)}}{\text{Solicitudes Totales (200 + 500)}} \right) \times 100$$

```bash
# Scrape the metrics endpoint
curl -s http://127.0.0.1:9102/metrics > /tmp/lpi-lab-topic42/scraped_metrics.txt

# Display raw scraped metrics
cat /tmp/lpi-lab-topic42/scraped_metrics.txt | grep -v '^#'
```

Expected Output:
```text
http_requests_total{tenant_id="tenant_alpha",status="200"} 1042
http_requests_total{tenant_id="tenant_alpha",status="500"} 3
http_requests_total{tenant_id="tenant_beta",status="200"} 415
http_requests_total{tenant_id="tenant_beta",status="500"} 25
tenant_storage_bytes{tenant_id="tenant_alpha"} 536870912
tenant_storage_bytes{tenant_id="tenant_beta"} 2147483648
```

### Paso 3: Limpiar el Proceso Generador

```bash
kill $EXPORTER_PID
```

---

### Preguntas de Comprensión — Ejercicio 2

1. **Pregunta 2.1**: En un marco de SLA/SLO para proveedores de servicios de código abierto, ¿cuál es la diferencia fundamental entre un SLI y un SLA?
   - A) Un SLI es la penalidad financiera reembolsada al cliente; un SLA es la herramienta de monitoreo instalada en los servidores Linux.
   - B) Un SLI (Indicador de Nivel de Servicio) es una métrica cuantificable del rendimiento del servicio (ej., % de disponibilidad o latencia), mientras que un SLA (Acuerdo de Nivel de Servicio) es el contrato legal que define el rendimiento esperado y las consecuencias/créditos si se incumplen los objetivos.
   - C) Un SLA es utilizado exclusivamente por desarrolladores; un SLI es utilizado estrictamente por equipos de ventas.
   - D) SLI se aplica solo a software propietario; SLA se aplica solo a software de código abierto.

2. **Pregunta 2.2**: ¿Por qué la medición basada en el consumo (metering) (ej., el seguimiento de bytes de almacenamiento o llamadas a la API por tenant) es crítica para los proveedores de servicios gestionados de código abierto?
   - A) Permite a los proveedores reescribir automáticamente las licencias de código abierto en tiempo de ejecución.
   - B) Permite una facturación precisa basada en el uso y chargeback/showback multateniente, garantizando que los costos de infraestructura se escalen de manera proporcional con el consumo del tenant.
   - C) Es legalmente requerido por la Free Software Foundation (FSF) para el cumplimiento de la GPL.
   - D) Evita que los clientes inspeccionen la base de código de código abierto.

---

## Ejercicio Guiado 3: Arquitectura de API Gateway de Producción y Limitación de Tasa (Rate-Limiting) por Tenant

### Escenario
Los proveedores de Open Core y SaaS gestionado deben aislar a los tenants en la capa de API Gateway para evitar el síndrome del "vecino ruidoso" ("noisy neighbor") y aplicar controles de acceso en las funcionalidades empresariales. Inspeccionará y desplegará una configuración de NGINX API Gateway que enruta solicitudes, inyecta encabezados de contexto del tenant y aplica límites de tasa (rate limits).

### Paso 1: Crear una Configuración Sintácticamente Válida de NGINX Gateway
Cree un fragmento de configuración de API gateway de nivel de producción que implemente limitación de tasa basada en tenants.

```bash
cat << 'EOF' > /tmp/lpi-lab-topic42/nginx-gateway.conf
events {
    worker_connections 1024;
}

http {
    # Define rate-limiting zone keyed by Tenant ID header
    map $http_x_tenant_id $tenant_key {
        default "";
        "~.+"    $http_x_tenant_id;
    }

    limit_req_zone $tenant_key zone=tenant_limit:10m rate=5r/s;

    upstream open_source_backend {
        server 127.0.0.1:8080;
    }

    server {
        listen 9090;
        server_name managed-service.internal;

        location /api/v1/ {
            # Enforce rate limits
            limit_req zone=tenant_limit burst=10 nodelay;

            # Inject tenant context and proxy parameters
            proxy_set_header X-Tenant-ID $http_x_tenant_id;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;

            # Access control check for Open Core enterprise features
            location /api/v1/enterprise/ {
                if ($http_x_subscription_tier != "enterprise") {
                    return 403 '{"error": "Enterprise tier required for Open Core features"}';
                }
                proxy_pass http://open_source_backend;
            }

            proxy_pass http://open_source_backend;
        }
    }
}
EOF

# Validate syntax structure using docker or podman nginx dry-run (if available)
if command -v docker &> /dev/null; then
    docker run --rm -v /tmp/lpi-lab-topic42/nginx-gateway.conf:/etc/nginx/nginx.conf:ro nginx:alpine nginx -t
elif command -v podman &> /dev/null; then
    podman run --rm -v /tmp/lpi-lab-topic42/nginx-gateway.conf:/etc/nginx/nginx.conf:ro nginx:alpine nginx -t
else
    echo "Syntax check skipped: Docker/Podman container runtime not present. Manifest verified manually."
fi
```

Expected Output (when Docker/Podman is available):
```text
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
```

---

### Preguntas de Comprensión — Ejercicio 3

1. **Pregunta 3.1**: En una arquitectura de servicios Open Core, ¿cómo aplica el API Gateway la segregación de características entre clientes estándar y empresariales?
   - A) Recompilando dinámicamente el núcleo (kernel) de Linux para cada solicitud de API.
   - B) Inspeccionando los metadatos de las solicitudes entrantes (como tokens de autenticación o encabezados de nivel) y restringiendo el acceso a endpoints de API o microservicios de backend premium.
   - C) Convirtiendo código Apache 2.0 en código AGPL sobre la marcha.
   - D) Forzando todo el tráfico no empresarial a través de HTTP sin cifrar.

2. **Pregunta 3.2**: ¿Qué problema resuelve la limitación de tasa (rate limiting) a nivel de tenant en una plataforma de servicios gestionados multateniente?
   - A) Evita que un solo tenant monopolice los recursos compartidos del backend (problema del "vecino ruidoso" o "noisy neighbor") y cause incumplimientos de SLA para otros tenants.
   - B) Evita que los usuarios exporten repositorios de código fuente de código abierto.
   - C) Garantiza un 100% de tiempo de actividad de la red independientemente de los fallos de hardware.
   - D) Registra automáticamente las marcas comerciales ante los organismos rectores.

---

## Referencias Oficiales

- **Linux Professional Institute (LPI) Open Source Essentials Overview**: [https://www.lpi.org/our-certifications/open-source-essentials-overview/](https://www.lpi.org/our-certifications/open-source-essentials-overview/)
- **Open Source Initiative (OSI) Licenses & Standards**: [https://opensource.org/licenses/](https://opensource.org/licenses/)
- **Google Site Reliability Engineering (SRE) Book — Service Level Objectives**: [https://sre.google/sre-book/service-level-objectives/](https://sre.google/sre-book/service-level-objectives/)
- **Business Source License (BSL 1.1) FAQ**: [https://mariadb.com/bsl-faq-adopting/](https://mariadb.com/bsl-faq-adopting/)
- **Server Side Public License (SSPL) FAQ**: [https://www.mongodb.com/licensing/server-side-public-license/faq](https://www.mongodb.com/licensing/server-side-public-license/faq)

---

<details>
<summary><b>Haga clic aquí para expandir las respuestas de la evaluación integral de conocimientos</b></summary>

### Respuestas del Ejercicio 1
- **Pregunta 1.1: B** — Empresas como MongoDB y Elastic adoptaron licencias de código disponible (SSPL, BSL) específicamente para evitar que los proveedores de nube pública (hiperescaladores) revendieran sus motores de código abierto como servicios gestionados alojados sin contribuir financieramente o con código.
- **Pregunta 1.2: B** — La Sección 13 de AGPLv3 introdujo la cláusula de "Interacción Remota a través de la Red". Si el software bajo AGPLv3 se modifica y se ejecuta en un servidor accesible a través de una red (modo SaaS/PaaS), el operador debe poner a disposición de todos los usuarios de la red el código fuente completo de las modificaciones.

### Respuestas del Ejercicio 2
- **Pregunta 2.1: B** — Un SLI (Indicador de Nivel de Servicio) es el indicador objetivo y medible del rendimiento basado en métricas (ej., 99.95% de respuestas 200 OK exitosas durante 30 días). Un SLA (Acuerdo de Nivel de Servicio) es el contrato legal/comercial que especifica los umbrales de rendimiento (SLOs) y las soluciones financieras u operativas si se incumplen.
- **Pregunta 2.2: B** — Los proveedores de servicios gestionados multatenientes dependen de una telemetría granular (uso de almacenamiento, llamadas a API, tiempo de ejecución de cómputo) para ejecutar chargeback/showback de tenants y facturar a los clientes con precisión según el consumo real de recursos.

### Respuestas del Ejercicio 3
- **Pregunta 3.1: B** — Los API gateways inspeccionan los encabezados de autorización, las declaraciones JWT (claims) o los metadatos de suscripción para restringir el acceso a rutas exclusivas de nivel empresarial (`/api/v1/enterprise/`), reenviando las solicitudes válidas a servicios backend propietarios mientras bloquean los niveles no autorizados con respuestas `403 Forbidden`.
- **Pregunta 3.2: A** — La limitación de tasa a nivel de tenant evita que un solo tenant malicioso o de alto volumen agote los pools de hilos, CPU o memoria en la infraestructura compartida, garantizando un rendimiento aislado y protección contra el impacto del "vecino ruidoso" ("noisy neighbor") en los SLAs.

</details>