# Guía de Estudio Avanzado para la Producción de KCSA: Dominio 5.7 – Admission Control

**Certificación Objetivo:** Kubernetes and Cloud Native Security Associate (KCSA)  
**Dominio 5.7:** Admission Control  
**Peso del Dominio:** 2.29%  

---

## 1. Mecánica Interna Profunda y Arquitectura

Admission Control en Kubernetes sirve como el gatekeeper definitivo que aplica políticas, gobernanza y postura de seguridad en las peticiones del API server **después** de que la autenticación y la autorización tienen éxito, pero **antes** de que el estado del objeto se persista en `etcd`.

```
                    +---------------------------------------------------------------------------------+
                    |                               Kube-APIServer                                    |
                    |                                                                                 |
Incoming HTTP Request ---> [ Authentication ] ---> [ Authorization ] ---> [ Mutating Admission ]      |
                    |                                                            |                    |
                    |                                                            v                    |
                    |                                                  [ Schema Validation ]          |
                    |                                                            |                    |
                    |                                                            v                    |
Persistence to etcd <--------------------------------------------------- [ Validating Admission ]     |
                    +---------------------------------------------------------------------------------+
```

### Las Fases del Pipeline de Admission

1. **Fase 1: Mutating Admission Phase**
   - **Orden de Ejecución:** Built-in Mutating Admission Controllers -> Extensible Webhooks (`MutatingWebhookConfiguration`).
   - **Comportamiento:** Las peticiones se evalúan secuencialmente. Los mutating webhooks pueden modificar el payload de la petición (respuesta `AdmissionReview` que contiene JSON patches).
   - **Política de Re-invocación:** Si un mutating webhook modifica un objeto, los mutating webhooks anteriores pueden ser re-invocados (hasta un límite fijo de iteraciones) si su `reinvocationPolicy` está configurada como `IfNeeded`.

2. **Fase 2: Object Schema Validation**
   - Valida la integridad estructural y el cumplimiento del esquema OpenAPI del objeto mutado.

3. **Fase 3: Validating Admission Phase**
   - **Orden de Ejecución:** Built-in Validating Admission Controllers -> Extensible Webhooks (`ValidatingWebhookConfiguration`) -> Políticas in-process de Common Expression Language (CEL) (`ValidatingAdmissionPolicy`).
   - **Comportamiento:** Se ejecutan en paralelo. Si **cualquier** validating controller o webhook deniega la petición, toda la operación de la API se aborta y se devuelve un error HTTP `402`/`403`/`422` al cliente.

### Configuraciones Arquitectónicas Clave y Trade-offs

| Parámetro / Característica | Función Operativa y Trade-Off |
| :--- | :--- |
| `failurePolicy: Fail` | Bloquea la petición de la API si el servidor del webhook no está accesible o supera el tiempo de espera. **Impacto en seguridad:** Alto (Previene workloads no validados). **Impacto en disponibilidad:** Alto (Riesgo de caídas en cascada del clúster si los webhooks fallan). |
| `failurePolicy: Ignore` | Permite que la petición de la API continúe si el webhook no está accesible. **Impacto en seguridad:** Comprometido (Omite los guardrails de seguridad durante interrupciones del webhook). **Impacto en disponibilidad:** Cero interrupción. |
| `timeoutSeconds` | Tiempo máximo que el API server espera la respuesta de un webhook (Por defecto: `10s` para webhooks, recomendado `1s-3s` en producción). Los tiempos de espera prolongados pueden agotar los worker threads de kube-apiserver. |
| `matchConditions` | Expresiones CEL de alto rendimiento evaluadas *dentro* de `kube-apiserver` para omitir llamadas a HTTP webhooks externos a menos que se cumplan condiciones específicas. Reduce la latencia de red. |
| `ValidatingAdmissionPolicy` | Motor CEL nativo que ejecuta políticas dentro de `kube-apiserver`. Elimina la latencia HTTP, la gestión de certificados TLS y el overhead de infraestructura de pods del servidor web. |

---

## 2. Referencias Oficiales y Enlaces de Citación

- [Documentación Oficial de Kubernetes: Using Admission Controllers](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/)
- [Documentación Oficial de Kubernetes: Dynamic Admission Control](https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/)
- [Documentación Oficial de Kubernetes: Validating Admission Policy](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/)
- [Documentación Oficial de Kubernetes: Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [Repositorio del Curriculum KCSA de CNCF](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)

---

## 3. Ejercicios Guiados

---

### Ejercicio 1: Built-in Admission Control & Pod Security Admission (PSA)

#### Descripción de la Tarea
Aplicar el Pod Security Standard `restricted` en un namespace objetivo utilizando etiquetas built-in de Pod Security Admission, verificar la aplicación de políticas y auditar violaciones de admisión.

#### Paso 1: Crear namespaces de prueba aislados
Crear dos namespaces: uno configurado para el enforcement de Pod Security (`sec-restricted`) y uno no restringido (`sec-legacy`).

```bash
kubectl create namespace sec-restricted
kubectl create namespace sec-legacy
```

**Salida Esperada:**
```text
namespace/sec-restricted created
namespace/sec-legacy created
```

#### Paso 2: Configurar Etiquetas de Pod Security en el Namespace
Aplicar etiquetas de Pod Security Standards a `sec-restricted` para aplicar el perfil `restricted` en la versión `latest`, emitiendo logs de auditoría y advertencias para las violaciones.

```bash
kubectl label --overwrite namespace sec-restricted \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/warn-version=latest \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/audit-version=latest
```

**Salida Esperada:**
```text
namespace/sec-restricted labeled
```

#### Paso 3: Intentar Desplegar un Workload No Conforme
Desplegar un manifiesto de pod que viola el perfil `restricted` ejecutándose como `root` (UID 0), permitiendo escalada de privilegios y omitiendo `seccompProfile`. Guardar este manifiesto como `privileged-pod.yaml`.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: insecure-workload
  namespace: sec-restricted
spec:
  containers:
  - name: nginx
    image: nginx:1.25.3
    securityContext:
      allowPrivilegeEscalation: true
      runAsUser: 0
```

Ejecutar creación:

```bash
kubectl apply -f privileged-pod.yaml
```

**Salida Esperada:**
```text
Error from server (Forbidden): error when creating "privileged-pod.yaml": pods "insecure-workload" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "nginx" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "nginx" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "nginx" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "nginx" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

#### Paso 4: Desplegar un Workload Totalmente Conforme
Crear un manifiesto totalmente conforme que adhiera estrictamente al Pod Security Standard `restricted`. Guardar como `compliant-pod.yaml`.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-workload
  namespace: sec-restricted
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: pause-container
    image: registry.k8s.io/pause:3.9
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop:
        - ALL
```

Ejecutar creación:

```bash
kubectl apply -f compliant-pod.yaml
```

**Salida Esperada:**
```text
pod/secure-workload created
```

#### Paso 5: Verificar el Estado del Despliegue
Verificar que el pod alcance el estado `Running`.

```bash
kubectl get pod secure-workload -n sec-restricted -o wide
```

**Salida Esperada:**
```text
NAME              READY   STATUS    RESTARTS   AGE   IP           NODE
secure-workload   1/1     Running   0          12s   10.244.0.5   node-01
```

---

#### Preguntas de Verificación (Ejercicio 1)

1. **Pregunta 1.1:** ¿Qué componente dentro del control plane de Kubernetes es responsable de evaluar la etiqueta de namespace `pod-security.kubernetes.io/enforce`, y durante qué fase exacta de admission control ocurre esta verificación?
2. **Pregunta 1.2:** Si se aplica un recurso deployment (`apps/v1`) que contiene una plantilla de pod no conforme en el namespace `sec-restricted`, ¿será rechazado el comando `kubectl apply -f deployment.yaml` a nivel de API server? Explicá el comportamiento técnico.

---

### Ejercicio 2: Native In-Process Policy Enforcement vía `ValidatingAdmissionPolicy` (CEL)

#### Descripción de la Tarea
Crear y vincular una `ValidatingAdmissionPolicy` de alto rendimiento y cero dependencias utilizando Common Expression Language (CEL) para rechazar Pods que intenten usar el tag de imagen `:latest` o pods a los que les falten las requests de recursos CPU/Memory.

#### Paso 1: Definir la `ValidatingAdmissionPolicy`
Crear un manifiesto completo `policy-cel-guardrails.yaml` especificando reglas estructurales a través de expresiones CEL.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: "enforce-resource-limits-and-tags"
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
    - apiGroups:   [""]
      apiVersions: ["v1"]
      operations:  ["CREATE", "UPDATE"]
      resources:   ["pods"]
  validations:
    - expression: "object.spec.containers.all(c, !c.image.endsWith(':latest'))"
      message: "Production Risk: Container images using the ':latest' tag are strictly prohibited."
    - expression: "object.spec.containers.all(c, has(c.resources) && has(c.resources.requests) && has(c.resources.requests.cpu))"
      message: "Resource Governance: Container must explicitly specify CPU requests."
```

Aplicar política:

```bash
kubectl apply -f policy-cel-guardrails.yaml
```

**Salida Esperada:**
```text
validatingadmissionpolicy.admissionregistration.k8s.io/enforce-resource-limits-and-tags created
```

#### Paso 2: Vincular la Política a Namespaces Objetivo usando `ValidatingAdmissionPolicyBinding`
Crear `policy-binding.yaml` para aplicar la política en cualquier namespace etiquetado con `environment: production`.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: "enforce-resource-limits-and-tags-binding"
spec:
  policyName: "enforce-resource-limits-and-tags"
  validationActions: [Deny]
  matchResources:
    namespaceSelector:
      matchLabels:
        environment: production
```

Aplicar binding y etiquetar el namespace:

```bash
kubectl apply -f policy-binding.yaml
kubectl label namespace sec-legacy environment=production --overwrite
```

**Salida Esperada:**
```text
validatingadmissionpolicybinding.admissionregistration.k8s.io/enforce-resource-limits-and-tags-binding created
namespace/sec-legacy labeled
```

#### Paso 3: Probar Violaciones de la Política CEL
Crear un manifiesto de prueba `violating-cel-pod.yaml` que viole ambas expresiones CEL.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: bad-cel-pod
  namespace: sec-legacy
spec:
  containers:
  - name: web
    image: nginx:latest
```

Ejecutar creación:

```bash
kubectl apply -f violating-cel-pod.yaml
```

**Salida Esperada:**
```text
Error from server (Invalid): error when creating "violating-cel-pod.yaml": Pod "bad-cel-pod" is invalid: : ValidatingAdmissionPolicy 'enforce-resource-limits-and-tags' with binding 'enforce-resource-limits-and-tags-binding' denied request: Production Risk: Container images using the ':latest' tag are strictly prohibited.
```

#### Paso 4: Validar Expresiones CEL mediante Diagnósticos dry-run
Corregir el tag de la imagen pero mantener las requests de CPU faltantes para observar cómo se activa la condición CEL secundaria. Guardar como `partial-fix-pod.yaml`.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: bad-cel-pod-2
  namespace: sec-legacy
spec:
  containers:
  - name: web
    image: nginx:1.25.3
```

Ejecutar creación:

```bash
kubectl apply -f partial-fix-pod.yaml
```

**Salida Esperada:**
```text
Error from server (Invalid): error when creating "partial-fix-pod.yaml": Pod "bad-cel-pod-2" is invalid: : ValidatingAdmissionPolicy 'enforce-resource-limits-and-tags' with binding 'enforce-resource-limits-and-tags-binding' denied request: Resource Governance: Container must explicitly specify CPU requests.
```

---

#### Preguntas de Verificación (Ejercicio 2)

1. **Pregunta 2.1:** ¿Cuáles son las ventajas clave de rendimiento arquitectónico de `ValidatingAdmissionPolicy` (CEL) sobre los HTTP webhooks dinámicos estándar (`ValidatingWebhookConfiguration`)?
2. **Pregunta 2.2:** ¿Qué ocurre si un `ValidatingAdmissionPolicyBinding` especifica `validationActions: [Audit, Warn]` en lugar de `Deny` cuando ocurre una violación de política?

---

### Ejercicio 3: Dynamic Dynamic Admission Webhooks, Failure Policies & Latency Troubleshooting

#### Descripción de la Tarea
Configurar un `ValidatingWebhookConfiguration` con `matchConditions` explícitas, investigar modos de falla de webhooks, analizar tiempos de espera del API server y evaluar el impacto de `failurePolicy: Fail` frente a `failurePolicy: Ignore`.

#### Paso 1: Desplegar Infraestructura de Webhook Mock
Desplegar un endpoint de webhook de validación HTTP mock y un servicio en el namespace `webhook-system`.

```bash
kubectl create namespace webhook-system
```

Crear `webhook-backend.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dummy-webhook
  namespace: webhook-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app: dummy-webhook
  template:
    metadata:
      labels:
        app: dummy-webhook
  spec:
    containers:
    - name: server
      image: registry.k8s.io/pause:3.9
      ports:
      - containerPort: 8443
---
apiVersion: v1
kind: Service
metadata:
  name: dummy-webhook-svc
  namespace: webhook-system
spec:
  ports:
  - port: 443
    targetPort: 8443
  selector:
    app: dummy-webhook
```

Aplicar recursos de backend:

```bash
kubectl apply -f webhook-backend.yaml
```

**Salida Esperada:**
```text
deployment.apps/dummy-webhook created
service/dummy-webhook-svc created
```

#### Paso 2: Registrar un `ValidatingWebhookConfiguration` con una Failure Policy Estricta
Guardar el siguiente manifiesto como `validating-webhook-strict.yaml`. Notar que `failurePolicy: Fail` apunta al servicio mock (el cual no maneja realmente peticiones HTTPS `AdmissionReview`, lo que causa errores de conexión).

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: strict-security-webhook
webhooks:
  - name: "check.security.domain.internal"
    rules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE"]
        resources:   ["pods"]
        scope:       "Namespaced"
    clientConfig:
      service:
        name: "dummy-webhook-svc"
        namespace: "webhook-system"
        path: "/validate"
        port: 443
      caBundle: "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCg=="
    admissionReviewVersions: ["v1"]
    sideEffects: None
    timeoutSeconds: 3
    failurePolicy: Fail
    namespaceSelector:
      matchLabels:
        webhook-enforce: "true"
```

Aplicar configuración de webhook:

```bash
kubectl apply -f validating-webhook-strict.yaml
```

**Salida Esperada:**
```text
validatingwebhookconfiguration.admissionregistration.k8s.io/strict-security-webhook created
```

#### Paso 3: Etiquetar el Namespace e Invocación de Webhook Disparada
Etiquetar el namespace `sec-legacy` para coincidir con el selector del webhook.

```bash
kubectl label namespace sec-legacy webhook-enforce=true --overwrite
```

Intentar desplegar un manifiesto de pod simple `test-webhook-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-webhook-pod
  namespace: sec-legacy
spec:
  containers:
  - name: pause
    image: registry.k8s.io/pause:3.9
```

Aplicar manifiesto:

```bash
kubectl apply -f test-webhook-pod.yaml
```

**Salida Esperada:**
```text
Error from server (InternalError): error when creating "test-webhook-pod.yaml": Internal error occurred: failed calling webhook "check.security.domain.internal": failed to call webhook: Post "https://dummy-webhook-svc.webhook-system.svc:443/validate?timeout=3s": dial tcp 10.96.142.88:443: connect: connection refused
```

#### Paso 4: Diagnóstico Avanzado de Fallas en Webhooks
Consultar métricas y eventos del API server para diagnosticar fallas en las llamadas a admission webhooks.

```bash
kubectl get events -n sec-legacy --field-selector reason=FailedAdmission
```

Inspeccionar los logs del API server en busca de trazas de error HTTP 500:

```bash
kubectl logs -n kube-system -l component=kube-apiserver --tail=100 | grep "failed calling webhook"
```

**Salida de Diagnóstico Esperada:**
```text
E0807 20:35:12.441102 1 dispatcher.go:205] failed calling webhook "check.security.domain.internal": Post "https://dummy-webhook-svc.webhook-system.svc:443/validate?timeout=3s": dial tcp 10.96.142.88:443: connect: connection refused
W0807 20:35:12.441145 1 handler.go:232] admission webhook "check.security.domain.internal" failed to complete request in 3s, failing open=false
```

#### Paso 5: Remediar la Interrupción Mediante Parcheo Dinámico de Políticas
Mitigar la interrupción operativa del clúster cambiando dinámicamente `failurePolicy` de `Fail` a `Ignore`.

```bash
kubectl patch validatingwebhookconfiguration strict-security-webhook \
  --type='json' -p='[{"op": "replace", "path": "/webhooks/0/failurePolicy", "value": "Ignore"}]'
```

**Salida Esperada:**
```text
validatingwebhookconfiguration.admissionregistration.k8s.io/strict-security-webhook patched
```

Reintentar la creación del pod:

```bash
kubectl apply -f test-webhook-pod.yaml
```

**Salida Esperada:**
```text
pod/test-webhook-pod created
```

#### Paso 6: Limpiar Recursos del Laboratorio
Limpiar todos los objetos creados durante los ejercicios.

```bash
kubectl delete namespace sec-restricted sec-legacy webhook-system
kubectl delete validatingadmissionpolicy enforce-resource-limits-and-tags
kubectl delete validatingadmissionpolicybinding enforce-resource-limits-and-tags-binding
kubectl delete validatingwebhookconfiguration strict-security-webhook
```

---

#### Preguntas de Verificación (Ejercicio 3)

1. **Pregunta 3.1:** Explicá el peligro de configurar `namespaceSelector` para que coincida con todos los namespaces (incluidos `kube-system` o el propio `webhook-system`) cuando se combina con `failurePolicy: Fail` en un `MutatingWebhookConfiguration` o `ValidatingWebhookConfiguration`.
2. **Pregunta 3.2:** ¿Cuál es el propósito del campo `reinvocationPolicy` en un `MutatingWebhookConfiguration`, y qué valor específico previene bucles infinitos durante las fases de mutación?

---

## 4. Soluciones y Explicaciones Técnicas

<details>
<summary><strong>Click to Expand Answers & Deep Technical Explanations</strong></summary>

### Soluciones del Ejercicio 1

* **Respuesta 1.1:**
  * **Componente:** El plugin de admission controller built-in **`PodSecurity`** compilado directamente dentro del binario de `kube-apiserver`.
  * **Fase:** Se ejecuta durante la **Fase 3 (Validating Admission Phase)**. Evalúa los parámetros del `securityContext` del pod frente al nivel de estándar definido (`privileged`, `baseline` o `restricted`) designado por la etiqueta de namespace `pod-security.kubernetes.io/enforce`.

* **Respuesta 1.2:**
  * **No**, el comando `kubectl apply -f deployment.yaml` **NO** será rechazado a nivel del API server en el envío inicial.
  * **Razón Técnica:** El admission controller de Pod Security verifica objetos `Pod` (`kind: Pod`), no controladores de nivel superior como `Deployments`, `ReplicaSets` o `Jobs`. El objeto `Deployment` se persistirá exitosamente en `etcd`.
  * **Consecuencia:** Posteriormente, el controlador del `ReplicaSet` intentará crear objetos `Pod` hijos. Cuando el `ReplicaSet` envíe las peticiones individuales de creación de `Pod`, el admission controller de `PodSecurity` rechazará esas peticiones de `Pod`. El `Deployment` mostrará `0/1` réplicas disponibles y los eventos de error se acumularán en el `ReplicaSet` (visibles mediante `kubectl describe replicaset`).
  * *Nota:* Para detectar violaciones a nivel de Deployment antes de la creación del pod, Pod Security Admission genera advertencias durante la creación del Deployment si está configurado con `pod-security.kubernetes.io/warn=restricted`, pero el enforcement ocurre estrictamente en las peticiones de creación de Pod.

---

### Soluciones del Ejercicio 2

* **Respuesta 2.1:**
  * **Ejecución In-Process (Cero Latencia):** `ValidatingAdmissionPolicy` evalúa expresiones CEL dentro del ciclo del proceso `kube-apiserver`. Evita ida y vuelta HTTP/HTTPS fuera del proceso a través de la red del pod, eliminando la latencia de red serializada.
  * **Alta Disponibilidad y Cero Dependencias:** Los webhooks dinámicos externos dependen de pods de servidor web externos, resolución DNS de Service y certificados TLS. Si esos pods fallan, el webhook falla. Las políticas CEL tienen cero dependencias de pods en tiempo de ejecución y no pueden fallar de forma independiente a `kube-apiserver`.
  * **Simplicidad Operativa:** Elimina la gestión del ciclo de vida de certificados TLS (caBundles, rotaciones de certificados) y el mantenimiento del despliegue de servidores web.

* **Respuesta 2.2:**
  * **Comportamiento:** El API server **permitirá y persistirá** la petición del recurso en `etcd` (la operación tiene éxito con estado HTTP 200/201).
  * **Auditoría (Audit):** Escribe una entrada en el log de auditoría etiquetada con los detalles de la falla de la política en el stream de logs de auditoría del API Server (`kube-apiserver-audit.log`).
  * **Advertencia (Warn):** Envía un encabezado de respuesta HTTP (`Warning: 299 - ...`) de vuelta al cliente (`kubectl`), imprimiendo el mensaje de advertencia directamente en la salida estándar/error (stdout/stderr) de la terminal para el ingeniero que ejecuta el comando.

---

### Soluciones del Ejercicio 3

* **Respuesta 3.1:**
  * **Deadlock / Dependencia Circular (Bloqueo del Control Plane):** Si un webhook intercepta todos los namespaces, incluidos `kube-system` y su propio namespace de despliegue (`webhook-system`), con `failurePolicy: Fail`, puede ocurrir un deadlock catastrófico:
    1. Si el pod del webhook se cae o el nodo que lo aloja se reinicia, el servicio del webhook deja de estar accesible.
    2. El API server bloquea todas las peticiones posteriores de creación de pods porque el webhook no se puede llamar.
    3. El scheduler de Kubernetes o los controladores de deployment no pueden crear un pod de reemplazo para el webhook (ni ningún pod de CNI/CoreDNS) porque el API server rechaza las peticiones de creación de pods debido al webhook roto.
  * **Prevención:** Configurar siempre `namespaceSelector` u `objectSelector` para excluir explícitamente los namespaces del sistema (`kube-system`, `kube-public`, namespaces del control plane y el propio namespace del webhook).

* **Respuesta 3.2:**
  * **Propósito:** `reinvocationPolicy` controla si un mutating webhook debe ser llamado por segunda vez si un mutating webhook *posterior* en el pipeline modifica el payload del objeto.
  * **Valores Permitidos:** `Never` (por defecto) e `IfNeeded`.
  * **Prevención de Bucles:** Configurar `reinvocationPolicy: Never` garantiza que el webhook sea llamado como máximo una vez por cada petición de admisión. Adicionalmente, `kube-apiserver` limita el número máximo de iteraciones de re-invocación (límite estricto de 5 ciclos) para prevenir bucles infinitos causados por mutating webhooks mutuamente conflictivos.

</details>