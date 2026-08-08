# Guía de Estudio KCSA — Dominio 6.2: Frameworks de Modelado de Amenazas

**Objetivo del examen:** Kubernetes and Cloud Native Security Associate (KCSA)  
**Dominio 6:** Seguridad Cloud Native y panorama de amenazas  
**Subtema 6.2:** Frameworks de modelado de amenazas  
**Ponderación:** 2.5%  
**Referencias oficiales:**
* [CNCF KCSA Curriculum (v1.0+)](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
* [CNCF Cloud Native Security Whitepaper v2](https://github.com/cncf/tag-security/blob/main/security-whitepaper/v2/cncf-security-whitepaper-v2.pdf)
* [MITRE ATT&CK® Matrix for Containers](https://attack.mitre.org/matrices/enterprise/containers/)
* [NIST SP 800-190: Application Container Security Guide](https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-190.pdf)

---

## Visión General Técnica y Arquitectura

El modelado de amenazas en entornos cloud-native requiere descomponer una arquitectura de Kubernetes en sus componentes principales (API server, etcd, Kubelet, container runtime, ingress controllers, service mesh, workloads) y evaluar sistemáticamente los vectores de ataque.

```
       +-----------------------------------------------------------------------+
       |                      TRUST BOUNDARY: EXTERNAL / INGRESS              |
       +-----------------------------------------------------------------------+
                                           |
                                           v
    +-----------------------------------------------------------------------------+
    |                         KUBERNETES CONTROL PLANE                            |
    |  +--------------------+     +-------------------+     +------------------+  |
    |  | kube-apiserver     |<--->| kube-scheduler    |<--->| etcd (TLS/mTLS)  |  |
    |  | (AuthN/AuthZ/RBAC) |     +-------------------+     +------------------+  |
    |  +--------------------+                                                     |
    +-----------------------------------------------------------------------------+
               |                                                   |
     TRUST BOUNDARY: CONTROL PLANE TO WORKER             TRUST BOUNDARY: INTER-POD
               |                                                   |
               v                                                   v
    +-----------------------------+                     +-------------------------+
    |      WORKER NODE 01         |                     |     WORKER NODE 02      |
    |  +-----------------------+  |    NetworkPolicy    |  +-------------------+  |
    |  | kubelet (Port 10250)  |  | <-----------------> |  | Pod B (Restricted)|  |
    |  +-----------------------+  |   (mTLS via CNI)    |  +-------------------+  |
    |  | Pod A (Compromised)   |  |                     +-------------------------+
    |  | - ServiceAccount Token|  |
    |  | - HostPath Mount      |  |
    |  +-----------------------+  |
    +-----------------------------+
```

### Frameworks Principales en el Modelado de Amenazas Cloud Native
1. **STRIDE** (*Spoofing, Tampering, Repudiation, Information Disclosure, Denial of Service, Elevation of Privilege*): Una taxonomía utilizada para identificar categorías de amenazas específicas a través de los flujos de datos y límites de confianza (trust boundaries) dentro de clusters de Kubernetes.
2. **MITRE ATT&CK® for Containers**: Una matriz que detalla las tácticas, técnicas y procedimientos (TTPs) de adversarios del mundo real específicos para entornos de ejecución de contenedores (container runtime), orquestadores de contenedores e infraestructuras cloud.
3. **DREAD** (*Damage, Reproducibility, Exploitability, Affected Users, Discoverability*): Una metodología de calificación de riesgos para cuantificar la gravedad de las amenazas con el fin de priorizar los esfuerzos de mitigación.
4. **PASTA** (*Process for Attack Simulation and Threat Analysis*): Una metodología de modelado de amenazas centrada en el riesgo empresarial que alinea las vulnerabilidades técnicas con el impacto en el negocio.

---

## Ejercicios Prácticos Guiados

### Ejercicio 1: Aplicación del Framework STRIDE a Workloads y Control Plane de Kubernetes

#### Paso 1.1: Desplegar un Workload Objetivo Sobreprivilegiado
Inspecciona y despliega un manifiesto de Kubernetes sintácticamente válido que contiene malas configuraciones de seguridad arquitectónicas comunes (montajes de host path, capabilities no confinadas, tokens de service account montados automáticamente).

```bash
cat << 'EOF' > stride-target.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payment-system
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: payment-processor-sa
  namespace: payment-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: payment-processor-admin-binding
subjects:
- kind: ServiceAccount
  name: payment-processor-sa
  namespace: payment-system
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-api
  namespace: payment-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app: payment-api
  template:
    metadata:
      labels:
        app: payment-api
    spec:
      serviceAccountName: payment-processor-sa
      automountServiceAccountToken: true
      containers:
      - name: api-container
        image: nginx:1.25-alpine
        securityContext:
          privileged: true
          runAsUser: 0
        volumeMounts:
        - mountPath: /host/etc
          name: host-etc
      volumes:
      - name: host-etc
        hostPath:
          path: /etc
          type: Directory
EOF

kubectl apply -f stride-target.yaml
```

**Salida esperada:**
```
namespace/payment-system created
serviceaccount/payment-processor-sa created
clusterrolebinding.rbac.authorization.k8s.io/payment-processor-admin-binding created
deployment.apps/payment-api created
```

#### Paso 1.2: Realizar una Auditoría de Diagnóstico para Detectar Amenazas STRIDE
Ejecuta comandos de verificación en tiempo de ejecución para identificar dónde se materializan las amenazas STRIDE en la arquitectura desplegada.

```bash
# 1. Verify Service Account Token exposure (Information Disclosure / Elevation of Privilege)
kubectl exec -it deploy/payment-api -n payment-system -- ls -la /var/run/secrets/kubernetes.io/serviceaccount/

# 2. Check token permissions via SelfSubjectAccessReview (Elevation of Privilege)
TOKEN=$(kubectl exec -it deploy/payment-api -n payment-system -- cat /var/run/secrets/kubernetes.io/serviceaccount/token)
kubectl auth can-i --list --token="$TOKEN"
```

**Salida esperada:**
```
total 0
drwxrwxrwx    3 root     root           140 Aug  7 20:00 .
drwxr-xr-x    3 root     root            70 Aug  7 20:00 ..
lrwxrwxrwx    1 root     root            13 Aug  7 20:00 ca.crt -> ..data/ca.crt
lrwxrwxrwx    1 root     root            16 Aug  7 20:00 namespace -> ..data/namespace
lrwxrwxrwx    1 root     root            12 Aug  7 20:00 token -> ..data/token

Resources                                       Non-Resource URLs   Resource Names   Verbs
*.*                                             [*]                 []               [*]
                                                [*]                 []               [*]
```

#### Paso 1.3: Remediar el Workload Utilizando Restricciones de Hardening basadas en STRIDE
Aplica un manifiesto endurecido (hardened) que enforce el Principio de Menor Privilegio (PoLP) a través de la identidad y los contextos de seguridad del contenedor (securityContext).

```bash
cat << 'EOF' > stride-hardened.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: payment-processor-sa-hardened
  namespace: payment-system
automountServiceAccountToken: false
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-api-hardened
  namespace: payment-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app: payment-api-hardened
  template:
    metadata:
      labels:
        app: payment-api-hardened
    spec:
      serviceAccountName: payment-processor-sa-hardened
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: api-container
        image: nginxinc/nginx-unprivileged:1.25-alpine
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop:
            - ALL
EOF

kubectl apply -f stride-hardened.yaml
```

**Salida esperada:**
```
serviceaccount/payment-processor-sa-hardened created
deployment.apps/payment-api-hardened created
```

---

#### Preguntas de Verificación — Ejercicio 1
1. **[Spoofing]** ¿Cómo previene la configuración `automountServiceAccountToken: false` los ataques de suplantación de identidad (identity spoofing) dentro de un cluster de Kubernetes?
2. **[Elevation of Privilege / Tampering]** ¿Por qué el montaje de un directorio `hostPath` (como `/etc`) combinado con `privileged: true` permite a un atacante escapar del container runtime y comprometer el nodo host subyacente?
3. **[Information Disclosure]** ¿A qué endpoint de API estándar o protocolo puede hacer consultas un atacante desde dentro de un Pod para exfiltrar metadatos del nodo o credenciales del proveedor cloud si no está bloqueado por una `NetworkPolicy`?

---

### Ejercicio 2: Mapeo de Vectores de Ataque a MITRE ATT&CK® for Containers y Auditoría de Diagnóstico

#### Paso 2.1: Simular MITRE ATT&CK T1613 (Container and Resource Discovery)
Simula a un adversario descubriendo recursos dentro del cluster utilizando comandos no autenticados o parcialmente autenticados contra endpoints del nodo.

```bash
# Query the anonymous Kubelet read-only port or standard API server endpoint
kubectl get pods --all-namespaces -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,SA:.spec.serviceAccountName
```

**Salida esperada:**
```
NAME                                    NODE       SA
payment-api-7b89799b6-x492l             worker-1   payment-processor-sa
payment-api-hardened-6c5df58c97-m9q2z   worker-2   payment-processor-sa-hardened
coredns-558bd4d5db-2l4z8                master-1   coredns
```

#### Paso 2.2: Simular MITRE ATT&CK T1059.004 (Unix Shell Access) y T1609 (Execution in Container)
Ejecuta una auditoría de inyección de comandos en memoria para rastrear llamadas de exec en los logs de auditoría del API server.

```bash
# 1. Trigger container execution
kubectl exec -n payment-system deploy/payment-api -- id

# 2. Inspect API Server Audit Log for the Exec Event (Run on Master/Control Plane node)
# Note: Path may vary depending on audit sink configuration (/var/log/kubernetes/audit.log)
grep -E '"verb":"create".*"subresource":"exec"' /var/log/kubernetes/audit.log | tail -n 1 | jq .
```

**Salida esperada:**
```json
{
  "kind": "Event",
  "apiVersion": "audit.k8s.io/v1",
  "level": "RequestResponse",
  "verb": "create",
  "user": {
    "username": "kubernetes-admin",
    "groups": ["system:masters", "system:authenticated"]
  },
  "objectRef": {
    "resource": "pods",
    "namespace": "payment-system",
    "name": "payment-api-7b89799b6-x492l",
    "subresource": "exec"
  },
  "responseStatus": {
    "metadata": {},
    "status": "Success",
    "code": 101
  }
}
```

#### Paso 2.3: Mitigar el Movimiento Lateral (T1210) Utilizando una NetworkPolicy Estricta
Despliega una NetworkPolicy default-deny basada en zero-trust para aislar namespaces y bloquear el movimiento lateral entre contenedores.

```bash
cat << 'EOF' > default-deny-all.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: payment-system
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
EOF

kubectl apply -f default-deny-all.yaml
```

**Salida esperada:**
```
networkpolicy.networking.k8s.io/default-deny-all created
```

---

#### Preguntas de Verificación — Ejercicio 2
1. En la matriz de MITRE ATT&CK® for Containers, ¿bajo qué táctica cae la **Técnica T1611 (Escape to Host)** y qué parámetros del securityContext del contenedor la previenen?
2. ¿Qué campo del log de auditoría en `audit.k8s.io/v1` registra la identidad de una ServiceAccount comprometida que intenta realizar llamadas a la API laterales?
3. ¿Cuál es la diferencia fundamental en la exposición al riesgo entre la técnica de MITRE **T1068 (Exploitation for Privilege Escalation)** ocurrida dentro de un contenedor no confinado (unconfined) en comparación con un contenedor reforzado con un perfil personalizado de AppArmor/Seccomp?

---

### Ejercicio 3: Priorización Cuantitativa de Amenazas Utilizando las Metodologías DREAD y PASTA

#### Paso 3.1: Construcción de la Matriz de Puntuación de Riesgo
Evalúa tres escenarios de producción de Kubernetes distintos utilizando el sistema de puntuación DREAD (Escala: 1 [Bajo] a 10 [Alto]).

**Fórmula DREAD:**
$$\text{Risk Score} = \frac{\text{Damage} + \text{Reproducibility} + \text{Exploitability} + \text{Affected Users} + \text{Discoverability}}{5}$$

| ID de Amenaza | Descripción de la Amenaza | Daño | Repr. | Explot. | Usu. Afec. | Desc. | DREAD General | Prioridad |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **TH-01** | Kubelet API expuesto (Puerto 10250) con `Anonymous.Enabled=true` | 10 | 10 | 10 | 10 | 9 | **9.8** | Crítica |
| **TH-02** | Almacén de datos (datastore) etcd no cifrado accesible desde nodos worker | 10 | 8 | 7 | 10 | 6 | **8.2** | Alta |
| **TH-03** | Falta de NetworkPolicy de Egress que permite tráfico saliente a internet | 7 | 9 | 6 | 4 | 5 | **6.2** | Media |

#### Paso 3.2: Aplicar las 7 Etapas de PASTA a Arquitecturas de Kubernetes
Comprende cómo PASTA mapea el impacto en el negocio con las operaciones de seguridad de contenedores:

```
Stage 1: Define Objectives (Business Impact & Compliance Requirements)
   └── Stage 2: Define Technical Scope (Assets, Nodes, CNI, Control Plane)
        └── Stage 3: Application Decomposition (Data Flow Diagrams, Trust Boundaries)
             └── Stage 4: Threat Analysis (STRIDE, Threat Intelligence, ATT&CK)
                  └── Stage 5: Vulnerability Analysis (CVE Scanning, Misconfigurations)
                       └── Stage 6: Attack Modeling (Attack Trees, Exploitation Proof-of-Concepts)
                            └── Stage 7: Risk & Impact Analysis (Countermeasures, Remediation Cost)
```

#### Paso 3.3: Validación Diagnóstica del Cifrado en Reposo (Encryption at Rest) de etcd (Mitigación de TH-02)
Verifica si los secrets sensibles de etcd están cifrados en disco para proteger contra la exfiltración de datos a nivel de host.

```bash
# Check API server configuration for encryption-provider-config flag
kubectl get pod -n kube-system -l component=kube-apiserver -o yaml | grep -- --encryption-provider-config
```

**Salida esperada (si está configurado):**
```
- --encryption-provider-config=/etc/kubernetes/enc/config.yaml
```

Si falta, los secrets almacenados en etcd permanecen en codificación base64 en texto plano, lo que resulta en una puntuación DREAD alta para Information Disclosure.

---

#### Preguntas de Verificación — Ejercicio 3
1. Calcula la puntuación DREAD para un escenario donde un Pod tiene acceso a `/var/run/docker.sock`:  
   * Damage: 10, Reproducibility: 9, Exploitability: 8, Affected Users: 9, Discoverability: 8. ¿Cuál es la puntuación DREAD calculada y la clasificación de gravedad?
2. En la Etapa 3 de PASTA (Application Decomposition), ¿qué abstracción específica de Kubernetes sirve como el límite de confianza (trust boundary) lógico principal entre microservicios?
3. ¿Por qué se considera que PASTA es más adecuado para el cumplimiento de riesgos empresariales (ej. PCI-DSS, SOC 2) en despliegues cloud-native que un análisis STRIDE puro?

---

<details>
<summary><strong>Haz clic para ver las soluciones y respuestas a las preguntas de verificación</strong></summary>

### Respuestas — Ejercicio 1
1. **Solución a Spoofing:** Deshabilitar `automountServiceAccountToken` evita que Kubernetes proyecte la credencial JWT en `/var/run/secrets/kubernetes.io/serviceaccount/`. Sin este token, un atacante que obtenga ejecución remota de código (RCE) dentro de un contenedor no puede autenticarse ante el `kube-apiserver` con la identidad del Pod.
2. **Solución a Elevation of Privilege / Tampering:** Un contenedor con `privileged: true` deshabilita las protecciones de namespaces del kernel de Linux y expone dispositivos del host (`/dev`). Combinado con un montaje `hostPath` de `/etc`, un atacante puede modificar archivos críticos del host (ej. `/etc/shadow`, `/etc/kubernetes/manifests`), inyectar servicios de systemd maliciosos o reescribir configuraciones del Kubelet para escalar privilegios al usuario root del nodo worker subyacente.
3. **Solución a Information Disclosure:** El endpoint de la Metadata API del proveedor cloud (ej. `169.254.169.254` para AWS/GCP/Azure) puede ser consultado por Pods no mitigados para extraer credenciales de roles de IAM, tokens de bootstrap del nodo o documentos de identidad de la instancia. Se deben utilizar objetos `NetworkPolicy` de Egress o saltos forzados de Instance Metadata Service versión 2 (IMDSv2) para bloquear el acceso no autorizado.

### Respuestas — Ejercicio 2
1. **Solución a la Matriz MITRE ATT&CK:** La Técnica **T1611** cae bajo la táctica **Privilege Escalation** (y **Privilege Escalation / Execution**). Se previene aplicando:
   * `allowPrivilegeEscalation: false`
   * `readOnlyRootFilesystem: true`
   * `capabilities.drop: ["ALL"]`
   * Ejecución como no-root (`runAsNonRoot: true`)
   * Restringiendo `hostPath` y `hostPID`/`hostIPC`/`hostNetwork` en los Pod Security Standards (perfil Restricted).
2. **Solución a la Identificación en Logs de Auditoría:** El campo `user.username` (ej. `system:serviceaccount:payment-system:payment-processor-sa`) y `user.groups` identifican la credencial de la ServiceAccount que realiza la solicitud a la API.
3. **Solución a la Exposición de Vulnerabilidades de Escalación de Privilegios:** Un contenedor no confinado (unconfined) ejecutándose sin restricciones de perfil de Seccomp o AppArmor permite llamadas al sistema (syscalls) directamente al kernel de Linux del host (ej. `unshare`, `ptrace`, `bpf`). Un contenedor restringido con `seccompProfile: {type: RuntimeDefault}` bloquea syscalls peligrosas, neutralizando primitivas de explotación del kernel incluso si existe una vulnerabilidad zero-day en el kernel.

### Respuestas — Ejercicio 3
1. **Cálculo de la Puntuación DREAD:**
   $$\text{Score} = \frac{10 + 9 + 8 + 9 + 8}{5} = \frac{44}{5} = 8.8$$
   * **Clasificación:** Crítica (Puntuaciones $\ge 8.0$ se clasifican como Altas/Críticas). Montar interfaces de socket otorga control total sobre el engine runtime del host.
2. **Solución al Límite de Confianza en PASTA:** El **Namespace** de Kubernetes sirve como el límite lógico fundamental, aplicado junto con roles de RBAC, `ResourceQuotas` y `NetworkPolicies`.
3. **Solución a la Ventaja de Cumplimiento Empresarial de PASTA:** PASTA incorpora el análisis de impacto en el negocio (Etapa 1) e inteligencia de amenazas (Etapa 4) directamente en la simulación de ataques (Etapa 6), permitiendo a los equipos de seguridad justificar las inversiones en controles de seguridad basándose en pérdidas financieras, multas por incumplimiento normativo y disrupción operativa, en lugar de bugs de software puramente técnicos.

</details>