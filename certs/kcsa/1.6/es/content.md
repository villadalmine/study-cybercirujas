# Guía de Estudio KCSA: Dominio 1.6 – Seguridad de Workloads y Código de Aplicaciones

## 1. Motivación y Problema Arquitectónico en Producción

En entornos de producción cloud-native, el límite del container runtime es la última línea de defensa contra el compromiso de la infraestructura. Las aplicaciones desplegadas en clusters de Kubernetes ingieren continuamente entradas no confiables a través de redes públicas e internas. Si una aplicación contiene vulnerabilidades (como Ejecución Remota de Código, Inyección SQL o escritura arbitraria de archivos), un atacante puede explotar el proceso para obtener capacidades de ejecución dentro del contenedor.

### El Panorama de Amenazas en Producción

Sin controles rigurosos de seguridad de workloads, un proceso de contenedor comprometido se puede traducir directamente en una brecha a nivel de todo el cluster:

1. **Escalación de Privilegios mediante Ejecución por Defecto como Root**: Por defecto, los contenedores a menudo se ejecutan como `root` (UID 0). Si una vulnerabilidad de la aplicación permite la ejecución arbitraria de código, el atacante hereda el acceso root dentro del filesystem del contenedor. Combinado con Linux capabilities no eliminadas (por ejemplo, `CAP_SYS_ADMIN`, `CAP_NET_RAW`), el atacante puede escapar de los namespaces del contenedor o alterar estados del sistema.
2. **Filesystems Raíz de Escritura como Terreno de Preparación**: Un filesystem raíz de escritura permite a los actores maliciosos descargar payloads binarios, inyectar librerías compartidas dinámicas (`.so`), modificar binarios de aplicaciones o escribir scripts persistentes de reverse shell en directorios del sistema como `/tmp`, `/var/tmp` o `/usr/local/bin`.
3. **Envenenamiento de la Cadena de Suministro y Artefactos No Firmados**: Desplegar imágenes de contenedor provenientes de registries públicos o pipelines de build no validados introduce comportamientos no deterministas en runtime. Los atacantes que apuntan a dependencias upstream (a través de typosquatting, confusión de dependencias o agentes de build comprometidos) pueden inyectar código backdoor. Si las imágenes se identifican solo mediante tags mutables (por ejemplo, `:latest` o `:v1.2.0`), los motores de contenedores pueden descargar capas modificadas y maliciosas sin detección.
4. **Exposición de Namespaces del Host y Dispositivos**: Las malas configuraciones como definir `hostNetwork: true`, `hostPID: true`, `hostIPC: true` o montar rutas del host (`hostPath`) exponen las interfaces de red, árboles de procesos e interfaces del kernel del nodo subyacente directamente al workload del contenedor.

### Estrategia Arquitectónica: Defensa en Profundidad

```
  +-----------------------------------------------------------------------+
  |                    Build & Supply Chain Layer                         |
  |  - Minimal Base Images (Distroless / Scratch)                         |
  |  - Static Vulnerability Scanning & SBOM Generation (Trivy/Syft)        |
  |  - Cryptographic Artifact Signing (Cosign / Sigstore)                |
  +-----------------------------------------------------------------------+
                                      |
                                      v
  +-----------------------------------------------------------------------+
  |                    Admission & Policy Control Layer                   |
  |  - Immutable Digest Enforcement (sha256 validation)                    |
  |  - In-Cluster Signature Verification (Kyverno / OPA Gatekeeper)       |
  |  - Pod Security Admission (Restricted PSS Enforcement)                |
  +-----------------------------------------------------------------------+
                                      |
                                      v
  +-----------------------------------------------------------------------+
  |                   Workload Runtime Isolation Layer                    |
  |  - Non-Root Execution (runAsNonRoot: true, runAsUser > 10000)         |
  |  - Immutable Filesystem (readOnlyRootFilesystem: true)                |
  |  - Privilege Restrictions (allowPrivilegeEscalation: false)            |
  |  - Capability Stripping (capabilities: drop: ["ALL"])                |
  |  - System Call Filtering (seccompProfile: RuntimeDefault)             |
  +-----------------------------------------------------------------------+
```

Para eliminar estos vectores de ataque, los Platform Architects imponen una Arquitectura de Contenedores Zero-Trust centrada en tres pilares fundamentales:
* **Integridad de Build**: Verificación de la procedencia de la imagen del contenedor, generación de SBOM y firmas criptográficas antes de la ejecución.
* **Control de Admisión Declarativo**: Rechazo automatizado de manifiestos no conformes a través de Kubernetes Pod Security Admission (PSA) y motores de Policy-as-Code (Kyverno / OPA Gatekeeper).
* **Restricciones de Runtime de Menor Privilegio**: Entornos de ejecución inmutables y non-root configurados estrictamente mediante atributos de `securityContext` de Kubernetes respaldados por primitivas del kernel de Linux (Namespaces, cgroups v2, Capabilities, Seccomp y LSMs).

---

## 2. Comparativas Técnicas y Tablas de Trade-offs

### 2.1 Estrategia de Arquitectura de Imágenes Base

| Característica / Métrica | OS Estándar (Debian / Ubuntu) | Linux Mínimo (Alpine) | Distroless (gcr.io/distroless) | Scratch (`scratch`) |
| :--- | :--- | :--- | :--- | :--- |
| **Tamaño de Imagen Base** | ~70MB - 200MB | ~5MB - 8MB | ~2MB - 20MB | 0 B |
| **Librería Estándar de C** | `glibc` | `musl` | `glibc` (mínima) o ninguna | Ninguna |
| **Disponibilidad de Shell** | `/bin/bash`, `/bin/sh` | `/bin/ash`, `/bin/sh` | Ninguna | Ninguna |
| **Gestor de Paquetes** | `apt`, `dpkg` | `apk` | Ninguno | Ninguno |
| **Superficie de Ataque de CVE** | Alta (Incluye binarios de utilidad) | Baja (CVEs ocasionales en `musl`/`apk`) | Muy Baja (Solo librerías de runtime) | Cero (Solo el binario de la aplicación) |
| **Observabilidad en Producción**| Alta (Depuración vía shell `exec`) | Media (Herramientas básicas disponibles) | Baja (Requiere Ephemeral Containers) | Baja (Requiere Ephemeral Containers) |
| **Complejidad de Build** | Baja | Baja a Media | Media (Multi-stage build) | Alta (Compilación estática) |

---

### 2.2 Niveles de Admisión de Pod Security Standards (PSS)

| Métrica / Parámetro | Privileged | Baseline | Restricted |
| :--- | :--- | :--- | :--- |
| **Objetivo Previsto** | Agentes de infraestructura (CNI, CSI, Componentes del sistema) | Workloads por defecto, microservicios internos | Servicios de producción endurecidos, workloads multitenant |
| **Acceso a Host Namespace** | Permitido (`hostNetwork`, `hostPID`, `hostIPC`) | Denegado | Denegado |
| **Contenedores Privilegiados** | Permitido (`privileged: true`) | Denegado | Denegado |
| **Capabilities** | Sin restricciones | Previene agregar caps peligrosas (`CAP_SYS_ADMIN`) | Elimina **TODAS** las capabilities; permite re-agregar específicas (`NET_BIND_SERVICE`) |
| **Puertos del Host** | Sin restricciones | Sin restricciones | Denegado (`hostPort` debe estar vacío/no establecido) |
| **Tipos de Volúmenes** | Todos los tipos de volumen permitidos | Restringido (Bloquea `hostPath` crudo) | Restringido (Bloquea `hostPath` crudo) |
| **`runAsNonRoot`** | No requerido | No requerido | Requerido (`true` obligatorio) |
| **`allowPrivilegeEscalation`**| Permitido | Permitido | Denegado (`false` obligatorio) |
| **`seccompProfile`** | Sin restricciones | Sin restricciones | Requerido (`RuntimeDefault` o `Localhost` obligatorio) |

---

### 2.3 Mecanismos de Identificación y Verificación de Imágenes de Contenedor

| Mecanismo | Especificador de Ejemplo | Garantía Criptográfica | Riesgo de Mutación de Tag | Rendimiento de Admisión |
| :--- | :--- | :--- | :--- | :--- |
| **Tag Semántico Mutable** | `myapp:v1.2.0` | Ninguna | **Alto** (El tag puede ser sobrescrito en el registry) | Rápido (Solo búsqueda en el manifest) |
| **Tag Flotante de Entorno**| `myapp:production` | Ninguna | **Crítico** (Mutación continua del tag) | Rápido (Solo búsqueda en el manifest) |
| **Digest Inmutable de Imagen** | `myapp@sha256:4f8a...` | Alta (Fallo en mismatch de hash direccionable por contenido) | **Cero** (Contenido bloqueado criptográficamente) | Rápido (Comprobación directa de hash) |
| **Verificación de Firma Cosign**| `myapp@sha256:4f8a...` + Firma Key/Keyless | Alta (Atestigua procedencia de build e identidad de la imagen) | **Cero** (Validación de firma requerida en la admisión) | Medio (Llamada externa de validación de clave/reclave) |

---

## 3. Manifiestos YAML Completos Sintácticamente Válidos y Configuraciones de Infraestructura

### 3.1 Configuración de Pod Security Admission a Nivel de Cluster (`/etc/kubernetes/admission/pod-security-config.yaml`)

Este manifiesto configura el plugin integrado Pod Security Admission del API server de Kubernetes con estándares por defecto a nivel de cluster y reglas de exención explícitas.

```yaml
apiVersion: pod-security.admission.config.k8s.io/v1
kind: PodSecurityConfiguration
defaults:
  enforce: "restricted"
  enforce-version: "latest"
  audit: "restricted"
  audit-version: "latest"
  warn: "restricted"
  warn-version: "latest"
exemptions:
  usernames: []
  runtimeClasses: []
  namespaces:
    - kube-system
    - cert-manager
    - ingress-nginx
```

---

### 3.2 Configuración del Control de Admisión del API Server de Kubernetes (`/etc/kubernetes/admission/admission-config.yaml`)

Referenciado por el flag del API server `--admission-control-config-file=/etc/kubernetes/admission/admission-config.yaml`.

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
  - name: PodSecurity
    configuration:
      apiVersion: pod-security.admission.config.k8s.io/v1
      kind: PodSecurityConfiguration
      defaults:
        enforce: "restricted"
        enforce-version: "latest"
        audit: "restricted"
        audit-version: "latest"
        warn: "restricted"
        warn-version: "latest"
      exemptions:
        usernames: []
        runtimeClasses: []
        namespaces:
          - kube-system
          - cert-manager
```

---

### 3.3 Manifiesto del Namespace de Producción Objetivo (`namespace-restricted.yaml`)

Define sobrescrituras de Pod Security Standards a nivel de namespace mediante etiquetas declarativas en los metadatos.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payment-processing
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.30
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.30
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.30
```

---

### 3.4 Manifiesto de Deployment Endurecido para Producción (`deployment-hardened.yaml`)

Un manifiesto completamente conforme que se adhiere estrictamente al perfil `Restricted` de PSS, incluyendo ejecución non-root, eliminación de capabilities, filesystem raíz de solo lectura, aplicación de seccomp y montajes de volumen `tmpfs`.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-gateway
  namespace: payment-processing
  labels:
    app.kubernetes.io/name: payment-gateway
    app.kubernetes.io/component: backend
    app.kubernetes.io/part-of: payment-system
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: payment-gateway
  template:
    metadata:
      labels:
        app.kubernetes.io/name: payment-gateway
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        fsGroupChangePolicy: Always
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: payment-api
          image: registry.enterprise.internal/finance/payment-api@sha256:a3c8e434f9a0c2394d2112e4b01e3d09a25e19741e97d1b315b741001416e788
          imagePullPolicy: IfNotPresent
          command:
            - "/app/payment-api-binary"
          args:
            - "--config=/etc/payment/config.json"
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 10001
            runAsGroup: 10001
            capabilities:
              drop:
                - ALL
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
          ports:
            - name: http-api
              containerPort: 8443
              protocol: TCP
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8443
              scheme: HTTP
            initialDelaySeconds: 10
            periodSeconds: 15
            timeoutSeconds: 3
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /ready
              port: 8443
              scheme: HTTP
            initialDelaySeconds: 5
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 2
          volumeMounts:
            - name: tmp-volume
              mountPath: /tmp
            - name: config-volume
              mountPath: /etc/payment
              readOnly: true
      volumes:
        - name: tmp-volume
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
        - name: config-volume
          configMap:
            name: payment-api-config
```

---

### 3.5 Política de Verificación de Imagen y Digest Pinning de Kyverno (`kyverno-image-verification.yaml`)

Esta política exige que todas las imágenes desplegadas en namespaces no exentos deban estar fijadas explícitamente mediante un digest SHA256 y firmadas por la clave pública interna de Cosign de la organización.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signature-and-digest
  annotations:
    policies.kyverno.io/title: Verify Image Signatures and Force Immutable Digest
    policies.kyverno.io/subject: Pod, Deployment
    policies.kyverno.io/description: >-
      Requires all container images to use explicit digest SHA256 references
      and verifies Cosign cryptographic signatures against an internal trusted public key.
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: check-image-digest-format
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "Container image must use an immutable digest (e.g., repo/image@sha256:hash)."
        pattern:
          spec:
            containers:
              - image: "*@sha256:*"
    - name: verify-cosign-signature
      match:
        any:
          - resources:
              kinds:
                - Pod
      verifyImages:
        - imageReferences:
            - "registry.enterprise.internal/*"
          key: |-
            -----BEGIN PUBLIC KEY-----
            MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE4N2sNfUj3k7R6vW+v8g0zK1oR1zN
            Y4vD8mQ0Z8V1V9mP2W6K5l2N0b3V4c5d6e7f8g9h0i1j2k3l4m5n6o==
            -----END PUBLIC KEY-----
          attestations: []
```

---

## 4. Comandos de CLI Reales ($) con Salidas de Terminal Esperadas

### 4.1 Escaneo de Vulnerabilidades y Generación de SBOM

#### Escanear una imagen en busca de vulnerabilidades HIGH y CRITICAL usando Trivy

```bash
$ trivy image --severity HIGH,CRITICAL --exit-code 1 registry.enterprise.internal/finance/payment-api@sha256:a3c8e434f9a0c2394d2112e4b01e3d09a25e19741e97d1b315b741001416e788
```

```text
2026-08-07T14:22:01.102-0400	INFO	Vulnerability scanning is enabled
2026-08-07T14:22:01.102-0400	INFO	Identified OS: alpine (3.19.1)
2026-08-07T14:22:01.103-0400	INFO	Detecting Alpine vulnerabilities...
2026-08-07T14:22:01.115-0400	INFO	Number of language-specific files: 1
2026-08-07T14:22:01.115-0400	INFO	Detecting gobinary vulnerabilities...

registry.enterprise.internal/finance/payment-api@sha256:a3c8e434f9a0c2394d2112e4b01e3d09a25e19741e97d1b315b741001416e788 (alpine 3.19.1)
===================================================================================================================================
Total: 0 (HIGH: 0, CRITICAL: 0)

$ echo $?
0
```

#### Generar un Software Bill of Materials (SBOM) CycloneDX usando Syft

```bash
$ syft registry.enterprise.internal/finance/payment-api:v1.2.0 -o cyclonedx-json --file sbom.cdx.json
```

```text
 ✔ Cataloged packages      [24 packages]
 ✔ Created BOM             [cyclonedx-json format] -> sbom.cdx.json
$ head -n 25 sbom.cdx.json
{
  "$schema": "http://cyclonedx.org/schema/bom-1.5.schema.json",
  "bomFormat": "CycloneDX",
  "specVersion": "1.5",
  "serialNumber": "urn:uuid:7f3b89b4-11e2-419b-a621-392019a8bc43",
  "version": 1,
  "metadata": {
    "timestamp": "2026-08-07T14:24:12Z",
    "tools": [
      {
        "vendor": "anchore",
        "name": "syft",
        "version": "1.3.0"
      }
    ],
    "component": {
      "bom-ref": "8c3e809b431e5f12",
      "type": "container",
      "name": "registry.enterprise.internal/finance/payment-api",
      "version": "v1.2.0"
    }
  }
}
```

---

### 4.2 Firma y Verificación de Imágenes con Cosign

#### Firmar la imagen de contenedor usando Cosign y una clave privada local

```bash
$ cosign sign --key cosign.key registry.enterprise.internal/finance/payment-api@sha256:a3c8e434f9a0c2394d2112e4b01e3d09a25e19741e97d1b315b741001416e788
```

```text
Enter password for private key: 
Pushing signature to: registry.enterprise.internal/finance/payment-api:sha256-a3c8e434f9a0c2394d2112e4b01e3d09a25e19741e97d1b315b741001416e788.sig
```

#### Verificar la firma usando la clave pública correspondiente

```bash
$ cosign verify --key cosign.pub registry.enterprise.internal/finance/payment-api@sha256:a3c8e434f9a0c2394d2112e4b01e3d09a25e19741e97d1b315b741001416e788
```

```text
Verification for registry.enterprise.internal/finance/payment-api@sha256:a3c8e434f9a0c2394d2112e4b01e3d09a25e19741e97d1b315b741001416e788 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - The signatures were verified against the specified public key

[{"critical":{"identity":{"docker-reference":"registry.enterprise.internal/finance/payment-api"},"image":{"docker-manifest-digest":"sha256:a3c8e434f9a0c2394d2112e4b01e3d09a25e19741e97d1b315b741001416e788"},"type":"cosign container image signature"},"optional":null}]
```

---

### 4.3 Pruebas de Aplicación de Pod Security Admission (PSA)

#### Intentar aplicar un manifiesto de pod no conforme en un namespace Restricted

```bash
$ kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: privileged-test-pod
  namespace: payment-processing
spec:
  containers:
    - name: nginx
      image: nginx:latest
EOF
```

```text
Error from server (Forbidden): error when creating "STDIN": pods "privileged-test-pod" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "nginx" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "nginx" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "nginx" must set securityContext.runAsNonRoot=true), runAsUser=0 (container "nginx" must not set runAsUser=0), seccompProfile (pod or container "nginx" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

---

### 4.4 Verificación de Seguridad en Runtime Dentro del Pod

#### Verificar el User ID y Privilegios dentro del pod endurecido en ejecución

```bash
$ kubectl exec -n payment-processing deployment/payment-gateway -- id
```

```text
uid=10001(payment) gid=10001(payment) groups=10001(payment)
```

#### Confirmar la aplicación del Filesystem Raíz de Solo Lectura

```bash
$ kubectl exec -n payment-processing deployment/payment-gateway -- touch /root_test.txt
```

```text
touch: /root_test.txt: Read-only file system
command terminated with exit code 1
```

#### Confirmar `/tmp` de Escritura sobre `tmpfs` Respaldado en Memoria

```bash
$ kubectl exec -n payment-processing deployment/payment-gateway -- sh -c "echo 'temp_data' > /tmp/test.txt && cat /tmp/test.txt"
```

```text
temp_data
```

---

### 4.5 Inspección a Nivel de CRI mediante `crictl` en un Nodo Worker de Kubernetes

#### Localizar el ID del contenedor e inspeccionar el estado de runtime de seguridad de Linux de bajo nivel

```bash
$ sudo crictl ps --name payment-api
```

```text
CONTAINER           IMAGE               CREATED             STATE               NAME                ATTEMPT             POD ID              DEFAULT
e7b1a29f4c5d        a3c8e434f9a0c       10 minutes ago      Running             payment-api         0                   c9f8e7d6c5b4        (default)
```

```bash
$ sudo crictl inspect e7b1a29f4c5d | jq '.info.runtimeSpec.linux.securityContext'
```

```json
{
  "seccomp": {
    "profileType": "RuntimeDefault"
  },
  "capabilities": {
    "bounding": [],
    "effective": [],
    "inheritable": [],
    "permitted": []
  },
  "readonlyPaths": [
    "/proc/sys",
    "/proc/sysrq-trigger",
    "/proc/irq",
    "/proc/bus"
  ],
  "maskedPaths": [
    "/proc/asound",
    "/proc/acpi",
    "/proc/kcore",
    "/proc/keys"
  ]
}
```

---

## 5. Guía de Verificación, Diagnóstico y Solución de Fallos

```
                         Workload Security Diagnostic Flowchart
                         
                        [ Deployment Attempt / Pod Creation ]
                                         |
                                         v
                            Is Pod Accepted by API Server?
                                /                 \
                             (No)                 (Yes)
                              /                     \
                             v                       v
               Check Admission Webhook          Is Pod Running?
            & Pod Security Standard (PSA)          /        \
                          |                     (No)        (Yes)
                          v                      /            \
                Review PSA Rejection          v                v
                   (Section 5.1)         Check Container     Verify Runtime
                                        Security Violations   Constraints
                                           (Section 5.2)      (Section 5.3)
```

### 5.1 Diagnóstico de Rechazos de Admisión (Errores `Forbidden` / `PodSecurity`)

#### Síntoma
El pipeline de CI/CD falla durante `kubectl apply` con errores HTTP 403 Forbidden indicando `violates PodSecurity "restricted:latest"`.

#### Flujo de Trabajo de Análisis de Causa Raíz
1. **Identificar Atributos de Seguridad Faltantes**: Analizar el texto de rechazo devuelto por el API server. Buscar parámetros específicos de security context faltantes ya sea en `.spec.securityContext` (nivel de Pod) o en `.spec.containers[*].securityContext` (nivel de Contenedor).
2. **Validar Requisitos Requeridos de Restricted**:
   - `allowPrivilegeEscalation: false` debe declararse explícitamente en **todos** los contenedores.
   - `capabilities: drop: ["ALL"]` debe declararse en **todos** los contenedores.
   - `runAsNonRoot: true` debe establecerse a nivel de Pod o de Contenedor.
   - `seccompProfile: type: "RuntimeDefault"` (o `Localhost`) debe estar configurado.
3. **Inspeccionar Advertencias de Auditoría del Namespace**:
   ```bash
   kubectl label namespace payment-processing pod-security.kubernetes.io/warn=restricted --overwrite
   kubectl apply --dry-run=server -f deployment-legacy.yaml
   ```

---

### 5.2 Diagnóstico de Caídas de Container Runtime (`CrashLoopBackOff`, `CreateContainerError`)

#### Síntoma A: `CreateContainerConfigError` debido a UID non-root faltante
- **Indicación**: El estado del Pod es `CreateContainerConfigError`.
- **Comando de Diagnóstico**:
  ```bash
  kubectl describe pod <pod-name> -n <namespace>
  ```
- **Patrón de Error**: `container has runAsNonRoot and image will run as root (UID 0)`
- **Remediación**: La imagen base del contenedor especifica `USER root` o carece de una instrucción `USER`, y se omitió `.spec.containers[*].securityContext.runAsUser` en la especificación del pod. Actualizar el manifiesto para definir explícitamente `runAsUser: 10001`.

#### Síntoma B: Caída de la Aplicación al Iniciar (`Permission Denied` / Read-Only Filesystem)
- **Indicación**: El Pod entra en `CrashLoopBackOff` con código de salida 1 o 126.
- **Comando de Diagnóstico**:
  ```bash
  kubectl logs <pod-name> -n <namespace> --previous
  ```
- **Patrón de Error**: `open /app/logs/app.log: read-only file system` o `mkdir /tmp/cache: permission denied`
- **Remediación**:
  1. Si la aplicación escribe estado en `/tmp` o en directorios de caché, montar un volumen `emptyDir` en memoria en esa ruta.
  2. Modificar la configuración de la aplicación para redirigir las salidas de logs a la salida estándar (`/dev/stdout`) en lugar de archivos locales.

---

### 5.3 Fallos de Aplicación en Kyverno y Motores de Políticas

#### Síntoma
Las imágenes no se despliegan con `admission webhook "validate.kyverno.svc" denied the request`.

#### Flujo de Trabajo de Diagnóstico
1. Comprobar los logs de ejecución de políticas de Kyverno:
   ```bash
   kubectl logs -n kyverno -l app.kubernetes.io/name=kyverno --tail=100 | grep -i "deny"
   ```
2. Verificar el estado del reporte de políticas para los workloads existentes:
   ```bash
   kubectl get clusterpolicyreport -o wide
   ```
3. Causas Raíz Comunes:
   - **Omisión del Digest de Imagen**: La imagen fue especificada como `image: myapp:v1.2` en lugar de `image: myapp@sha256:<digest>`.
   - **Mismatch de Clave Cosign**: La clave pública configurada en la `ClusterPolicy` no coincide con la clave privada utilizada por el pipeline de CI para firmar el artefacto de imagen.

---

### 5.4 Matriz de Referencia de Comandos de Diagnóstico

| Objetivo Diagnóstico | Objeto Destino | Línea de Comando Exacta |
| :--- | :--- | :--- |
| **Inspeccionar Eventos de Pod Security Admission** | Eventos | `kubectl get events -n <ns> --field-selector reason=FailedCreate` |
| **Ver Logs de Auditoría para Violaciones de Seguridad**| K8s API Server | `grep -i "pod-security" /var/log/kubernetes/audit/audit.log` |
| **Verificar el Seccomp Profile Efectivo** | Container Runtime | `crictl inspect <container-id> \| jq '.info.runtimeSpec.linux.securityContext.seccomp'` |
| **Verificar las Linux Capabilities Aplicadas** | Container Runtime | `crictl inspect <container-id> \| jq '.info.runtimeSpec.linux.capabilities'` |
| **Auditar Firmas de Imágenes en el Cluster** | Motor Kyverno | `kubectl get policyreport -n <ns> -o yaml` |

---

## 6. Referencias

* **CNCF KCSA Curriculum**: [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
* **Kubernetes Official Documentation – Pod Security Standards**: [https://kubernetes.io/docs/concepts/security/pod-security-standards/](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
* **Kubernetes Official Documentation – Pod Security Admission**: [https://kubernetes.io/docs/concepts/security/pod-security-admission/](https://kubernetes.io/docs/concepts/security/pod-security-admission/)
* **Kubernetes Official Documentation – Configure a Security Context for a Pod or Container**: [https://kubernetes.io/docs/tasks/configure-pod-container/security-context/](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/)
* **Sigstore Cosign Documentation**: [https://docs.sigstore.dev/cosign/overview/](https://docs.sigstore.dev/cosign/overview/)
* **Kyverno Policy Engine – Image Verification**: [https://kyverno.io/docs/writing-policies/verify-images/](https://kyverno.io/docs/writing-policies/verify-images/)
* **NIST SP 800-190 (Application Container Security Guide)**: [https://csrc.nist.gov/publications/detail/sp/800-190/final](https://csrc.nist.gov/publications/detail/sp/800-190/final)
* **Trivy Vulnerability Scanner Documentation**: [https://aquasecurity.github.io/trivy/latest/](https://aquasecurity.github.io/trivy/latest/)