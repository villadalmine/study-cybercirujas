# Guía de Estudio KCSA: Tema 1.3 — Controles y Frameworks

**Dominio:** Cloud Native Security Basics  
**Peso:** 14% (Subtema 1.3: Controles y Frameworks ~ 2.33%)  
**Certificación Objetivo:** CNCF Kubernetes and Cloud Native Security Associate (KCSA)  

---

## 1. Mecánica Técnica Profunda y Visión General de la Arquitectura

Los controles y frameworks de seguridad establecen líneas base estandarizadas para evaluar riesgos, hacer cumplir el cumplimiento normativo e implementar defensa en profundidad a lo largo del ciclo de vida del contenedor. En entornos de producción de Kubernetes, las plataformas deben adherirse a estándares regulatorios y técnicos superpuestos.

```
+-----------------------------------------------------------------------------------+
|                        SECURITY CONTROLS & FRAMEWORKS ARCHITECTURE                |
+-----------------------------------------------------------------------------------+
|                                                                                   |
|  +---------------------+   +---------------------+   +--------------------------+ |
|  | NIST SP 800-190       |   | CIS Benchmarks      |   | NSA/CISA K8s Hardening   | |
|  | Container Risk Domains| |   | Technical Audits    |   | Operational Baselines    | |
|  +----------+----------+   +----------+----------+   +------------+-------------+ |
|             |                         |                           |               |
|             v                         v                           v               |
|  +------------------------------------------------------------------------------+ |
|  |                         MITRE ATT&CK for Containers                          | |
|  |                 Threat Vectors & Adversary Tactic Mapping                    | |
|  +------------------------------------+-----------------------------------------+ |
|                                       |                                           |
|                                       v                                           |
|  +------------------------------------------------------------------------------+ |
|  |                     POLICY ENFORCEMENT ENGINE IN K8S                         | |
|  | (Pod Security Standards / OPA Gatekeeper / Kyverno Admission Controllers)     | |
|  +------------------------------------------------------------------------------+ |
|                                                                                   |
+-----------------------------------------------------------------------------------+
```

### Desglose de Frameworks Clave y Matriz de Trade-Offs

1. **NIST SP 800-190 (Application Container Security Guide)**
   - **Enfoque Principal:** Categoriza los riesgos de seguridad de contenedores en 5 niveles distintos: Image, Registry, Orchestrator, Container y Host OS.
   - **Trade-off Arquitectónico:** Hacer cumplir puertas estrictas de firma y escaneo de imágenes en el nivel de registry reduce la velocidad de despliegue, pero elimina binarios vulnerables antes del runtime.

2. **CIS Kubernetes Benchmarks**
   - **Enfoque Principal:** Verificaciones prescriptivas de hardening de configuración a nivel de sistema para API server, Kubelet, etcd, Controller Manager, Scheduler y nodos worker.
   - **Trade-off Arquitectónico:** Deshabilitar `anonymous-auth` en el API Server o hacer cumplir `TLS 1.3` endurece el transporte del control plane, pero rompe colectores de telemetría heredados y health probes de balanceadores de carga externos si no se reconfiguran con los certificados de cliente adecuados.

3. **NSA/CISA Kubernetes Hardening Guidance**
   - **Enfoque Principal:** Guías de mitigación de amenazas operativas enfocadas en la seguridad de Pods (ejecución sin root, sistemas de archivos raíz inmutables), aislamiento de red, mínimo privilegio en RBAC, registro de auditoría (audit logging) y cifrado de datos en reposo.
   - **Trade-off Arquitectónico:** Hacer cumplir sistemas de archivos raíz de solo lectura requiere montajes explícitos de `emptyDir` o volúmenes persistentes para las rutas de escritura de las aplicaciones (por ejemplo, `/tmp`, directorios de logs), lo que aumenta la complejidad de los manifiestos.

4. **MITRE ATT&CK® for Containers**
   - **Enfoque Principal:** Matriz de tácticas de adversarios del mundo real (por ejemplo, Initial Access `T1610`, Execution `T1609`, Escape to Host `T1611`, Privilege Escalation `T1612`, Discovery `T1613`).
   - **Trade-off Arquitectónico:** Restringir el acceso a la API `pods/exec` mitiga `T1609` (Execution into Container), pero dificulta la depuración interactiva tradicional, requiriendo que los SREs adopten contenedores de depuración efímeros (`kubectl debug`).

---

## 2. Ejercicios Guiados de Producción

### Ejercicio 1: Auditar el Control Plane y Nodos Worker de Kubernetes Usando `kube-bench` (Cumplimiento de CIS Benchmark)

#### Paso 1: Desplegar `kube-bench` Como un Job de Kubernetes Dirigido a Configuraciones del Nodo Master
Ejecutar `kube-bench` utilizando la especificación oficial de CIS benchmark dirigida a configuraciones del control plane de Kubernetes 1.28+.

Crear el archivo `kube-bench-job.yaml`:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: kube-bench-master
  namespace: default
spec:
  template:
    metadata:
      labels:
        app: kube-bench
    spec:
      hostPID: true
      nodeSelector:
        node-role.kubernetes.io/control-plane: ""
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
        - key: node-role.kubernetes.io/master
          operator: Exists
          effect: NoSchedule
      restartPolicy: Never
      containers:
        - name: kube-bench
          image: aquasec/kube-bench:v0.7.3
          command: ["kube-bench", "run", "--targets", "master", "--json"]
          volumeMounts:
            - name: var-lib-etcd
              mountPath: /var/lib/etcd
              readOnly: true
            - name: var-lib-kubelet
              mountPath: /var/lib/kubelet
              readOnly: true
            - name: etc-systemd
              mountPath: /etc/systemd
              readOnly: true
            - name: etc-kubernetes
              mountPath: /etc/kubernetes
              readOnly: true
      volumes:
        - name: var-lib-etcd
          hostPath:
            path: /var/lib/etcd
        - name: var-lib-kubelet
          hostPath:
            path: /var/lib/kubelet
        - name: etc-systemd
          hostPath:
            path: /etc/systemd
        - name: etc-kubernetes
          hostPath:
            path: /etc/kubernetes
```

Enviar el Job y obtener los logs:

```bash
kubectl apply -f kube-bench-job.yaml
kubectl wait --for=condition=complete job/kube-bench-master --timeout=60s
kubectl logs job/kube-bench-master | jq '.tests[] | .results[] | select(.status=="FAIL")'
```

**Salida de Terminal Esperada:**

```json
{
  "test_number": "1.1.12",
  "test_desc": "Ensure that the --anonymous-auth argument is set to false (Automated)",
  "audit": "/bin/ps -ef | grep kube-apiserver | grep -v grep",
  "status": "FAIL",
  "remediation": "Edit the manifest file /etc/kubernetes/manifests/kube-apiserver.yaml on the control plane node and set --anonymous-auth=false",
  "scored": true
}
{
  "test_number": "1.2.19",
  "test_desc": "Ensure that the --profiling argument is set to false (Automated)",
  "audit": "/bin/ps -ef | grep kube-scheduler | grep -v grep",
  "status": "FAIL",
  "remediation": "Edit the manifest file /etc/kubernetes/manifests/kube-scheduler.yaml on the control plane node and set --profiling=false",
  "scored": true
}
```

#### Paso 2: Remediar el Ítem CIS 1.1.12 en el Kube-APIServer
Inspeccionar `/etc/kubernetes/manifests/kube-apiserver.yaml` en el nodo master y aplicar la remediación.

```bash
# Verify current process arguments on control plane node
ps aux | grep kube-apiserver | grep anonymous-auth
```

**Salida de Terminal Esperada:**

```text
root     12431  4.2  8.1 1143200 663410 ?    Ssl  18:10   0:45 kube-apiserver --anonymous-auth=true --authorization-mode=Node,RBAC ...
```

Editar `/etc/kubernetes/manifests/kube-apiserver.yaml` para incluir:

```yaml
spec:
  containers:
  - command:
    - kube-apiserver
    - --anonymous-auth=false
```

Verificar que Kubelet reinicie automáticamente el contenedor del Pod estático:

```bash
crictl ps --name kube-apiserver
```

#### Paso 3: Volver a Verificar el Cumplimiento de CIS

```bash
kubectl delete job kube-bench-master
kubectl apply -f kube-bench-job.yaml
kubectl wait --for=condition=complete job/kube-bench-master --timeout=60s
kubectl logs job/kube-bench-master | jq '.tests[].results[] | select(.test_number=="1.1.12")'
```

**Salida de Terminal Esperada:**

```json
{
  "test_number": "1.1.12",
  "test_desc": "Ensure that the --anonymous-auth argument is set to false (Automated)",
  "audit": "/bin/ps -ef | grep kube-apiserver | grep -v grep",
  "status": "PASS",
  "remediation": "",
  "scored": true
}
```

---

### Preguntas de Verificación — Sección 1

1. **Pregunta 1.1:** ¿Por qué CIS Benchmark 1.1.12 requiere explícitamente `--anonymous-auth=false` en el API server, y qué mecanismo debe configurarse si los health checks no autenticados (`/healthz` o `/livez`) fallan después de aplicar este control?
2. **Pregunta 1.2:** En NIST SP 800-190, ¿bajo qué vector cae principalmente la ejecución de cargas de trabajo en contenedores con privilegios de root, y cómo el kernel del SO host aisla el UID 0 dentro de un contenedor del UID 0 del host si los namespaces de usuario están deshabilitados?

---

### Ejercicio 2: Implementar Líneas Base de Hardening de NSA/CISA con Pod Security Standards (PSS) y Enforcing de Políticas de Kyverno

#### Paso 1: Etiquetar el Namespace para el Modo Enforce de PSS
Hacer cumplir el Pod Security Standard (PSS) `restricted` nativo de Kubernetes a nivel de namespace como se especifica en las recomendaciones de Hardening de NSA/CISA.

```bash
kubectl create namespace production-sec
kubectl label --overwrite namespace production-sec \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/warn-version=latest
```

**Salida de Terminal Esperada:**

```text
namespace/production-sec created
namespace/production-sec labeled
```

#### Paso 2: Desplegar un Pod de Producción Cumplimentado y Sintácticamente Completo
Crear `compliant-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-api-worker
  namespace: production-sec
  labels:
    app.kubernetes.io/name: secure-api-worker
    app.kubernetes.io/part-of: payment-pipeline
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: ccr.io/google-containers/pause:3.9
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop:
            - ALL
      resources:
        limits:
          cpu: "250m"
          memory: "128Mi"
        requests:
          cpu: "100m"
          memory: "64Mi"
      volumeMounts:
        - name: tmp-volume
          mountPath: /tmp
  volumes:
    - name: tmp-volume
      emptyDir: {}
```

Aplicar el manifiesto:

```bash
kubectl apply -f compliant-pod.yaml
```

**Salida de Terminal Esperada:**

```text
pod/secure-api-worker created
```

#### Paso 3: Implementar un Guardrail de Política Empresarial Usando Kyverno
Desplegar un `ClusterPolicy` de Kyverno para hacer cumplir que NINGÚN pod a lo largo del cluster pueda ejecutarse sin una configuración explícita de `readOnlyRootFilesystem: true` (Sección de Hardening de NSA/CISA: Container Security).

Crear `kyverno-readonly-rootfs.yaml`:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: enforce-readonly-rootfilesystem
  annotations:
    policies.kyverno.io/title: Enforce Read-Only Root Filesystem
    policies.kyverno.io/category: NSA/CISA Pod Security Hardening
    policies.kyverno.io/severity: high
    policies.kyverno.io/subject: Pod
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: validate-read-only-rootfs
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "NSA/CISA Compliance Violation: Container root filesystem must be read-only (securityContext.readOnlyRootFilesystem=true)."
        pattern:
          spec:
            containers:
              - securityContext:
                  readOnlyRootFilesystem: true
```

Aplicar la política:

```bash
kubectl apply -f kyverno-readonly-rootfs.yaml
```

#### Paso 4: Probar el Enforcement de la Política con un Manifiesto de Pod No Cumplimentado
Crear `non-compliant-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: insecure-worker
  namespace: production-sec
spec:
  containers:
    - name: app
      image: nginx:alpine
```

Intentar aplicar el manifiesto no cumplimentado:

```bash
kubectl apply -f non-compliant-pod.yaml
```

**Salida de Terminal Esperada:**

```text
Error from server (Forbidden): error when creating "non-compliant-pod.yaml": pods "insecure-worker" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "app" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "app" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "app" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "app" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

---

### Preguntas de Verificación — Sección 2

1. **Pregunta 2.1:** Un contenedor define `securityContext.readOnlyRootFilesystem: true`. Sin embargo, la aplicación requiere escribir archivos de bloqueo (lock files) temporales en `/run/lock`. ¿Cuál es el patrón arquitectónico seguro recomendado por las guías de NSA/CISA para admitir este requisito sin configurar `readOnlyRootFilesystem: false`?
2. **Pregunta 2.2:** ¿Cuál es la diferencia técnica operacional entre aplicar etiquetas PSS en modo `enforce` versus modo `warn` o `audit` en un namespace que contiene cargas de trabajo activas existentes?

---

### Ejercicio 3: Modelado de Amenazas y Mitigación de Tácticas de MITRE ATT&CK (T1609 y T1611) con RBAC y NetworkPolicies

#### Paso 1: Analizar el Vector de Amenaza T1609 (Execution into Container)
Los adversarios aprovechan el subrecurso de la API `pods/exec` para obtener shells interactivas dentro de contenedores comprometidos para movimiento lateral (`T1210`) y descubrimiento de credenciales (`T1552`).

Auditar los permisos de cluster roles existentes para encontrar identidades capaces de ejecutar comandos dentro de contenedores:

```bash
kubectl get clusterroles -o json | jq -r '.items[] | select(.rules[]? | select(.resources[]? == "pods/exec" and (.verbs[]? == "create" or .verbs[]? == "*"))) | .metadata.name'
```

**Salida de Terminal Esperada:**

```text
admin
cluster-admin
edit
developer-exec-role
```

#### Paso 2: Implementar RBAC con Alcance de Mínimo Privilegio para Depuración
Restringir `pods/exec` a un rol de emergencia dedicado limitado a namespaces específicos, evitando el acceso arbitrario a la shell a nivel de todo el cluster.

Crear `exec-least-privilege-rbac.yaml`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: production-sec
  name: SreContainerDebugger
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list"]
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: bind-sre-debugger
  namespace: production-sec
subjects:
  - kind: User
    name: platform-sre@company.internal
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: SreContainerDebugger
  apiGroup: rbac.authorization.k8s.io
```

Aplicar la política RBAC:

```bash
kubectl apply -f exec-least-privilege-rbac.yaml
```

Validar los permisos del usuario a través de `kubectl auth can-i`:

```bash
kubectl auth can-i create pods/exec --as=platform-sre@company.internal -n production-sec
kubectl auth can-i create pods/exec --as=platform-sre@company.internal -n kube-system
```

**Salida de Terminal Esperada:**

```text
yes
no
```

#### Paso 3: Mitigar el Escape de Contenedores y Movimiento Lateral (MITRE T1611 / T1210) a Través de NetworkPolicy
Bloquear el acceso de contenedores a servicios de metadatos (por ejemplo, AWS/GCP Instance Metadata Service `169.254.169.254`) y hacer cumplir un default-deny estricto de egress basado en zero-trust.

Crear `default-deny-egress-metadata.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: block-cloud-metadata-and-default-deny-egress
  namespace: production-sec
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    # Allow intra-namespace pod-to-pod communication
    - to:
        - podSelector: {}
    # Allow CoreDNS access (port 53 UDP/TCP)
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
    # Explicitly exclusion rule: Traffic to external services allowed EXCEPT 169.254.169.254/32
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 169.254.169.254/32
```

Aplicar la NetworkPolicy:

```bash
kubectl apply -f default-deny-egress-metadata.yaml
```

Probar el bloqueo de metadatos desde el interior del Pod cumplimentado:

```bash
kubectl exec -n production-sec secure-api-worker -- wget -qO- --timeout=2 http://169.254.169.254/latest/meta-data/
```

**Salida de Terminal Esperada:**

```text
wget: download timed out
command terminated with exit code 1
```

---

### Preguntas de Verificación — Sección 3

1. **Pregunta 3.1:** Según MITRE ATT&CK for Containers, ¿cuál es el mecanismo exacto detrás de la táctica `T1611` (Escape to Host) cuando un contenedor se ejecuta con `hostPID: true` y `privileged: true`?
2. **Pregunta 3.2:** ¿Por qué se requiere explícitamente el acceso a CoreDNS (puerto UDP/TCP 53) en la regla de egress de una NetworkPolicy de tipo default-deny, y qué vulnerabilidad de seguridad se introduce si una regla de egress permite `0.0.0.0/0` en todos los puertos sin restricciones de DNS?

---

## 3. Referencias Oficiales y URLs

- **CNCF KCSA Curriculum Specification:**  
  [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)

- **NIST Special Publication 800-190 (Application Container Security Guide):**  
  [https://csrc.nist.gov/publications/detail/sp/800-190/final](https://csrc.nist.gov/publications/detail/sp/800-190/final)

- **NSA/CISA Kubernetes Hardening Guidance:**  
  [https://media.defense.gov/2022/Aug/29/2003066362/-1/-1/0/CTR_KUBERNETES_HARDENING_GUIDANCE_FINAL_20220829.PDF](https://media.defense.gov/2022/Aug/29/2003066362/-1/-1/0/CTR_KUBERNETES_HARDENING_GUIDANCE_FINAL_20220829.PDF)

- **CIS Kubernetes Benchmarks:**  
  [https://www.cisecurity.org/benchmark/kubernetes](https://www.cisecurity.org/benchmark/kubernetes)

- **MITRE ATT&CK® for Containers Matrix:**  
  [https://attack.mitre.org/matrices/enterprise/containers/](https://attack.mitre.org/matrices/enterprise/containers/)

- **Kubernetes Pod Security Standards (PSS):**  
  [https://kubernetes.io/docs/concepts/security/pod-security-standards/](https://kubernetes.io/docs/concepts/security/pod-security-standards/)

---

## 4. Respuestas y Explicaciones de Verificación

<details>
<summary>Hacé clic aquí para expandir las soluciones de todas las preguntas de verificación</summary>

### Respuestas de la Sección 1

* **Respuesta 1.1:**  
  Configurar `--anonymous-auth=false` garantiza que cualquier solicitud presentada sin credenciales explícitas (como certificados de cliente, bearer tokens o encabezados de autenticación básica HTTP) sea rechazada inmediatamente con HTTP `401 Unauthorized` en lugar de asignarse al usuario `system:anonymous` y grupo `system:unauthenticated`.  
  *Remediación para Health Checks:* Si los health checks fallan después de deshabilitar la autenticación anónima, el Kubelet o el sistema de monitoreo deben configurarse para pasar credenciales de cliente válidas o aprovechar los endpoints no autenticados designados (`/livez`, `/readyz`, `/healthz`), los cuales se pueden exponer de forma segura a través de excepciones de autorización dedicadas del API Server (configuración de `--authorization-mode` que permita rutas de health a `system:anonymous` explícitamente a través de `ClusterRoleBinding` a `system:public-info-viewer` si es necesario, o permitiendo que los probes locales del Kubelet se autentiquen a través de service account/certificados de cliente).

* **Respuesta 1.2:**  
  En NIST SP 800-190, la ejecución de contenedores como root cae bajo **Container Risks (Sección 3.4: App Vulnerabilities & Runtime Privileges)** y **Host OS Risks (Sección 3.5)**.  
  Si los User Namespaces de Linux (`userns`) están *deshabilitados* (la configuración predeterminada en los runtimes de contenedores estándar Docker/containerd), el UID 0 dentro del contenedor se mapea directamente al UID 0 en el kernel del host subyacente. El aislamiento depende únicamente de los Linux Control Groups (cgroups), Namespaces (mnt, pid, net, ipc, uts), Linux Capabilities y LSMs (AppArmor/SELinux). Si un atacante escapa del límite del contenedor mediante una vulnerabilidad del kernel o un exploit de montaje de volumen, obtiene instantáneamente privilegios completos de root a nivel de host.

---

### Respuestas de la Sección 2

* **Respuesta 2.1:**  
  El patrón arquitectónico recomendado es mantener `readOnlyRootFilesystem: true` en el security context del contenedor y montar explícitamente un volumen efímero en memoria (`emptyDir` con `medium: Memory` o `emptyDir: {}` estándar) en la ruta específica que requiere capacidades de escritura (por ejemplo, `/run/lock` o `/tmp`). Esto aisla la mutación a un volumen temporal mientras deja inmutable el sistema de archivos base del contenedor, lo que previene la manipulación de archivos o ataques de persistencia (`T1543`).

* **Respuesta 2.2:**  
  Aplicar etiquetas de Pod Security Standards en modo `enforce` hace que el admission controller del API server de Kubernetes rechace inmediatamente cualquier creación de pod nuevo o actualización de deployment que viole la política. Sin embargo, el modo `enforce` **no** termina ni modifica los pods que ya se estaban ejecutando antes de aplicar la etiqueta.  
  Por el contrario, el modo `warn` permite la creación de pods mientras devuelve un encabezado de advertencia legible por humanos en la salida de `kubectl` o en la respuesta de la API, y el modo `audit` registra un log de evento de auditoría sin bloquear la creación de pods. Los equipos de SRE usan `warn` y `audit` para evaluar el impacto de las políticas en las cargas de trabajo existentes antes de cambiar al modo `enforce`.

---

### Respuestas de la Sección 3

* **Respuesta 3.1:**  
  Cuando un contenedor se despliega con `hostPID: true`, comparte el namespace de procesos del nodo host, lo que le permite ver e interactuar con todos los procesos que se ejecutan en el SO host. Cuando se combina con `privileged: true`, el runtime del contenedor deshabilita todas las restricciones de capacidades de Linux (otorgando `CAP_SYS_ADMIN`, `CAP_SYS_PTRACE`, etc.), desactiva los perfiles de AppArmor/SELinux y expone los dispositivos del host en `/dev`.  
  Un adversario puede usar `nsenter` (o acceder a `/host/proc/1/ns/mnt`) para cambiar al namespace de montaje del host, escapando efectivamente de los límites de contenerización del contenedor (`T1611`) y obteniendo acceso completo a una shell de root en el nodo subyacente.

* **Respuesta 3.2:**  
  La resolución de CoreDNS es requerida porque los servicios de Kubernetes y los endpoints de API externas se referencian a través de nombres de dominio (FQDNs). Si el tráfico DNS (puerto UDP/TCP 53 hacia `kube-dns`) se bloquea por una política de egress default-deny, la aplicación no puede resolver direcciones IP de servicios, lo que rompe la comunicación entre servicios y las llamadas a APIs externas.  
  Si una política de egress permite `0.0.0.0/0` en todos los puertos sin segmentación de red o filtrado de DNS, un adversario que ejecute código dentro de un contenedor comprometido puede establecer canales salientes de Command & Control (C2) (`T1071`), exfiltrar datos/tokens sensibles hacia direcciones IP públicas arbitrarias o conectarse a endpoints externos maliciosos.

</details>