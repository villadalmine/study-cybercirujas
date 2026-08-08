# Guía de Estudio KCSA — Tema 6.2: Threat Modeling Frameworks

## 1. Motivación y Problema Arquitectónico de Producción

### 1.1 Declaración del Problema Arquitectónico
Las cargas de trabajo cloud-native desplegadas en Kubernetes incrementan dramáticamente la superficie de ataque en comparación con los entornos monolíticos legados o de máquinas virtuales tradicionales. En un entorno de Kubernetes, los límites de cómputo, red y almacenamiento son suaves, definidos por software y altamente dinámicos. 

Las vulnerabilidades arquitectónicas se manifiestan frecuentemente cuando el threat modeling se trata como un requisito de documentación estática en lugar de un bucle de control activo integrado en los pipelines de integración continua/despliegue continuo (CI/CD) y en el diseño de la arquitectura del cluster. Sin un threat modeling estructurado, las organizaciones experimentan fallas de producción predecibles:

* **Compromiso del Host y Cluster mediante Container Escape**: Runtimes de contenedor mal configurados, capacidades de Linux excesivas (`CAP_SYS_ADMIN`) o namespaces compartidos con el host (`hostPID`, `hostIPC`, `hostNetwork`) permiten que cargas de trabajo en contenedores no privilegiados escapen al nodo subyacente.
* **Exposición del API Server y Control Plane**: Puertos de solo lectura no autenticados del Kubelet (`10255`), endpoints del API server mal configurados, ServiceAccounts con demasiados privilegios vinculadas a clusterroles cluster-admin y datastores `etcd` no encriptados exponen el estado del cluster al movimiento lateral.
* **Movimiento Lateral Sin Restricciones**: Redes planas de contenedores sin recursos `NetworkPolicy` default-deny permiten que un microservicio front-end comprometido consulte bases de datos internas sensibles, Instance Metadata Services de proveedores cloud (IMDSv1 en `169.254.169.254`) o endpoints administrativos.
* **Ruptura de Non-Repudiation**: La ausencia de audit logging granular en el API Server, o la falla al reenviar los flujos de auditoría a plataformas de logging centralizadas e inmutables, impide la reconstrucción forense durante la respuesta activa a incidentes.

### 1.2 El Modelo de Seguridad de las 4K (4Ks Security Model)
El threat modeling en Kubernetes opera a través de las cuatro capas distintas de las **4Ks of Cloud Native Security**:

```
                  +-----------------------------------+
                  |              Cloud                |
                  |  (IAM, KMS, Network ACLs, IMDS)   |
                  +-----------------------------------+
                                    |
                  +-----------------------------------+
                  |             Cluster               |
                  |  (API Server, RBAC, etcd, Kubelet)|
                  +-----------------------------------+
                                    |
                  +-----------------------------------+
                  |            Container              |
                  | (Images, Runtimes, Capabilities)  |
                  +-----------------------------------+
                                    |
                  +-----------------------------------+
                  |              Code                 |
                  | (Dependencies, Static Analysis)   |
                  +-----------------------------------+
```

Cada capa se basa en la seguridad de la capa superior. Los threat modeling frameworks proporcionan la metodología formal requerida para evaluar amenazas en cada capa, identificar límites de seguridad, mapear vulnerabilidades a tácticas de ataque conocidas y aplicar mitigaciones arquitectónicas de manera sistemática.

---

## 2. Comparaciones Técnicas y Tablas de Trade-offs

### 2.1 Comparación de Threat Modeling Frameworks

| Framework | Enfoque Principal | Tipo de Metodología | Cuantificación de Riesgo | Mejor Caso de Uso en Kubernetes | Limitaciones / Trade-offs |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **STRIDE** | Descomposición de amenazas en componentes para desarrolladores/arquitectos | Centrada en software/arquitectura (Categoría) | Cualitativa (High/Medium/Low al emparejarse con DREAD/CVSS) | Mapeo de amenazas a objetos de API de Kubernetes específicos, límites del control plane y componentes de nodos worker | Puede ser excesivamente granular; no contempla de forma inherente la motivación del atacante o el impacto en el negocio |
| **PASTA** | Proceso centrado en el riesgo diseñado para alinear la seguridad con los objetivos del negocio | Centrada en el atacante y en el negocio (pipeline de 7 etapas) | Cuantitativa y ponderada por riesgo | Planificación arquitectónica de control planes críticos en plataformas financieras/de producción | Alto overhead; requiere participación transversal de negocio, compliance e ingeniería |
| **DREAD** | Fórmula de puntuación de riesgos para priorizar amenazas identificadas | Algoritmo de clasificación cuantitativa de riesgos | Puntaje numérico $$(D+R+E+A+D)/5$$ (Escala 1–10) | Priorización del backlog de remediación de vulnerabilidades señaladas por Trivy, Falco o Kube-bench | Altamente subjetivo; las calificaciones individuales dependen en gran medida del sesgo del revisor (desaprobado por Microsoft en favor de CVSS, pero aún evaluado en exámenes fundamentales de seguridad) |
| **MITRE ATT&CK for Containers** | Mapeo empírico de Tácticas, Técnicas y Procedimientos (TTPs) del adversario | Matriz empírica / Centrada en el adversario | Mapeado a actores de amenazas del mundo real e incidentes históricos | Ingeniería de detección en SIEM/Falco, mapeo de alertas de SOC y validación de penetration testing | Enfocado en técnicas de post-explotación y ejecución en lugar de diseño arquitectónico preventivo |

### 2.2 Mapeo de Amenazas STRIDE a la Arquitectura de Kubernetes

```
                       STRIDE Threat Vector Mapping in Kubernetes
+---------------------+---------------------------------------+----------------------------------+
| STRIDE Category     | Kubernetes Vulnerability Example      | Architectural Mitigation         |
+---------------------+---------------------------------------+----------------------------------+
| Spoofing            | Kubelet / API Server impersonation    | Strict mTLS, x509 NodeRestriction|
| Tampering           | Unauthorized image mutation in registry| Image Digest pinning, Cosign     |
| Repudiation         | Actions taken without audit trace     | API Audit Policies, Immutable Logs|
| Info Disclosure     | Unencrypted Secrets in etcd           | KMS Provider (Envelope Encryption)|
| Denial of Service   | Resource exhaustion via rogue pod     | ResourceQuotas & LimitRanges     |
| Elevation of Priv.  | Container escape via hostPath / CAPs  | Pod Security Admission (Restricted)|
+---------------------+---------------------------------------+----------------------------------+
```

---

## 3. Manifiestos de Producción y Configuraciones de Infraestructura

Para mitigar las amenazas identificadas a través de **STRIDE** y **MITRE ATT&CK for Containers**, desplegamos manifiestos de seguridad de Kubernetes sintácticamente completos y de nivel de producción.

### 3.1 Mitigación de Anti-Repudiation: Manifiesto `AuditPolicy` de Producción
Esta Audit Policy del API Server mitiga **STRIDE Repudiation** y aborda la **Técnica T1613 de MITRE ATT&CK (Container and Resource Discovery)** y **T1078 (Valid Accounts)** al capturar cuerpos completos de request/response para mutaciones administrativas críticas y rastreo a nivel de metadatos para cargas de trabajo operativas.

```yaml
apiVersion: audit.k8s.io/v1
kind: AuditPolicy
rules:
  # Stage 1: Do not log noisy, high-volume read-only system checks
  - level: None
    users:
      - "system:kube-proxy"
      - "system:nodes"
      - "system:apiserver"
    verbs: ["get", "list", "watch"]
    resources:
      - group: ""
        resources: ["endpoints", "services", "pods", "configmaps"]

  # Stage 2: Log RequestResponse for Secret and ConfigMap modifications (Detect Information Disclosure / Tampering)
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]
    verbs: ["create", "update", "patch", "delete"]

  # Stage 3: Log RequestResponse for RBAC modifications (Detect Elevation of Privilege)
  - level: RequestResponse
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
    verbs: ["create", "update", "patch", "delete"]

  # Stage 4: Log RequestBody for workloads creating pods/executing into containers (Detect T1609 Container Exec)
  - level: Request
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach", "pods/portforward"]
    verbs: ["create", "get"]

  # Stage 5: Log Metadata for all pod and workload updates across namespaces
  - level: Metadata
    resources:
      - group: ""
        resources: ["pods"]
      - group: "apps"
        resources: ["deployments", "daemonsets", "statefulsets"]
    verbs: ["create", "update", "patch", "delete"]

  # Stage 6: Fallback rule - log metadata for everything else at ResponseStarted
  - level: Metadata
    omitStages:
      - "RequestReceived"
```

### 3.2 Mitigación de Elevation of Privilege: `Deployment` Completamente Endurecido
Este manifiesto aplica el **perfil `restricted` de Pod Security Admission (PSA)**, mitigando **STRIDE Elevation of Privilege** y **MITRE ATT&CK T1611 (Escape to Host)** al deshabilitar la ejecución como root, descartar todas las capacidades de Linux, aplicar sistemas de archivos raíz de solo lectura, bloquear la escalada de privilegios y restringir los perfiles de seccomp.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-gateway-api
  namespace: production-payments
  labels:
    app.kubernetes.io/name: payment-gateway-api
    app.kubernetes.io/part-of: payment-system
    app.kubernetes.io/managed-by: argocd
    security.cncf.io/stride-mitigation: elevation-of-privilege
spec:
  replicas: 3
  selector:
    matchLabels:
      app: payment-gateway-api
  template:
    metadata:
      labels:
        app: payment-gateway-api
    spec:
      serviceAccountName: payment-gateway-sa
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: api-server
          image: internal-registry.enterprise.io/finance/payment-api:v2.4.1@sha256:8f2a1a892015383f982a7bb84f50125439c3e921d7b322a33f4a08c0250df7b0
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            runAsUser: 10001
            capabilities:
              drop:
                - ALL
          ports:
            - containerPort: 8443
              name: https
              protocol: TCP
          resources:
            requests:
              cpu: "250m"
              memory: "256Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"
          volumeMounts:
            - name: tmp-volume
              mountPath: /tmp
            - name: tls-certs
              mountPath: /etc/tls/certs
              readOnly: true
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8443
              scheme: HTTPS
            initialDelaySeconds: 15
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /ready
              port: 8443
              scheme: HTTPS
            initialDelaySeconds: 5
            periodSeconds: 5
      volumes:
        - name: tmp-volume
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
        - name: tls-certs
          secret:
            secretName: payment-api-tls
```

### 3.3 Mitigación de Information Disclosure: `NetworkPolicy` Default-Deny y Zero-Trust
Esta política mitiga **STRIDE Information Disclosure** y **MITRE ATT&CK T1210 (Exploitation of Remote Services)** al bloquear todo movimiento lateral no aprobado y prevenir el acceso a los endpoints IMDS del proveedor cloud (`169.254.169.254`).

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: payment-api-isolation-policy
  namespace: production-payments
spec:
  podSelector:
    matchLabels:
      app: payment-gateway-api
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # Allow ingress strictly from API Gateway instances in the ingress-nginx namespace
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
          podSelector:
            matchLabels:
              app.kubernetes.io/name: ingress-nginx
      ports:
        - protocol: TCP
          port: 8443
  egress:
    # Allow egress strictly to CoreDNS instances for service resolution
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
    # Allow egress strictly to the dedicated database namespace on port 5432
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: production-database
          podSelector:
            matchLabels:
              role: primary-db
      ports:
        - protocol: TCP
          port: 5432
```

### 3.4 Mitigación de Denial of Service: `ResourceQuota` y `LimitRange` de Namespace
Estos recursos mitigan **STRIDE Denial of Service** y **MITRE ATT&CK T1496 (Resource Hijacking)** estableciendo límites máximos estrictos en el consumo de recursos de cómputo.

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: compute-quota-strict
  namespace: production-payments
spec:
  hard:
    requests.cpu: "4"
    requests.memory: 8Gi
    limits.cpu: "8"
    limits.memory: 16Gi
    pods: "20"
    services: "5"
    persistentvolumeclaims: "2"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: default-container-limits
  namespace: production-payments
spec:
  limits:
    - type: Container
      default:
        cpu: "500m"
        memory: "512Mi"
      defaultRequest:
        cpu: "100m"
        memory: "128Mi"
      max:
        cpu: "2"
        memory: "4Gi"
      min:
        cpu: "50m"
        memory: "64Mi"
```

---

## 4. Comandos de CLI Reales y Salidas de Terminal Esperadas

### 4.1 Evaluación de Amenazas de RBAC: Identificación de Riesgos de Elevation of Privilege
Inspeccionamos el cluster en busca de permisos de comodín (wildcards) y verbos peligrosos de RBAC (`bind`, `impersonate`, `escalate`, `*`) utilizando consultas nativas de `kubectl`.

```bash
$ kubectl get clusterrolebindings -o json | jq -r '
  .items[] | 
  select(.roleRef.name | test("admin|cluster-admin|root")) | 
  "Binding: " + .metadata.name + " -> Subject: " + (.subjects[]? | .kind + "/" + .name + " (ns: " + (.namespace//"N/A") + ")")
'
```

**Salida de Terminal Esperada:**
```text
Binding: cluster-admin -> Subject: Group/system:masters (ns: N/A)
Binding: kube-state-metrics -> Subject: ServiceAccount/kube-state-metrics (ns: monitoring)
Binding: privileged-ci-cd-sa-binding -> Subject: ServiceAccount/gitlab-runner-sa (ns: ci-cd)
```

Evaluamos si una ServiceAccount específica puede hacer exec dentro de los pods (mapeando a **MITRE ATT&CK T1609**):

```bash
$ kubectl auth can-i create pods/exec --as=system:serviceaccount:production-payments:payment-gateway-sa -n production-payments
```

**Salida de Terminal Esperada:**
```text
no
```

### 4.2 Verificación de la Aplicación (Enforcement) de Pod Security Admission (PSA)
Intentamos desplegar una carga de trabajo no conforme con privilegios elevados (`privileged: true`, `hostNetwork: true`) para verificar el comportamiento de bloqueo de PSA (mitigación de **STRIDE Elevation of Privilege**).

```bash
$ kubectl run malicious-test-pod \
  --image=busybox:1.36 \
  --namespace=production-payments \
  --overrides='{
    "spec": {
      "hostNetwork": true,
      "containers": [{
        "name": "test",
        "image": "busybox:1.36",
        "command": ["sleep", "3600"],
        "securityContext": {
          "privileged": true
        }
      }]
    }
  }'
```

**Salida de Terminal Esperada:**
```text
Error from server (Forbidden): pods "malicious-test-pod" is forbidden: violates PodSecurity "restricted:latest": hostNetwork (hostNetwork=true), privileged (container "test" must not set securityContext.privileged=true), allowPrivilegeEscalation != false (container "test" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "test" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "test" must set securityContext.runAsNonRoot=true), runAsUser=0 (container "test" must not set runAsUser=0), seccompProfile (pod or container "test" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

### 4.3 Análisis de Audit Logs para Intentos de Ejecución No Autorizada
Consultamos los audit logs del API Server de Kubernetes usando `rg` (ripgrep) y `jq` para detectar intentos de pod exec no autorizados (**MITRE ATT&CK T1609**).

```bash
$ tail -n 5000 /var/log/kubernetes/audit/audit.log | rg '"resources":\["pods"\].*"subresource":"exec"' | jq -r '
  [.stageTimestamp, .user.username, .userAgent, .objectRef.namespace, .objectRef.name, .responseStatus.code] | 
  @tsv
'
```

**Salida de Terminal Esperada:**
```text
2026-08-07T19:42:11Z    system:serviceaccount:ci-cd:deployer    kubectl/v1.30.0 (linux/amd64)    production-payments    payment-gateway-api-7b8f9c-x2z1a    403
2026-08-07T19:45:02Z    admin-user@enterprise.io               kubectl/v1.30.0 (linux/amd64)    default                debug-pod-99b82                       200
```

### 4.4 Escaneo Automatizado de Vulnerabilidades y Amenazas mediante Trivy
Escaneamos la configuración de nuestro namespace de producción para detectar violaciones de amenazas arquitectónicas contra los estándares CIS Benchmark y NSA Pod Security.

```bash
$ trivy k8s --namespace production-payments --severity HIGH,CRITICAL --report summary
```

**Salida de Terminal Esperada:**
```text
Summary Report for production-payments

Workload Summary:
+---------------------+-------------------+-------------------+----------+-------------------+
|      NAMESPACE      |     RESOURCE      |       NAME        | SEVERITY |   VULNERABILITY   |
+---------------------+-------------------+-------------------+----------+-------------------+
| production-payments | Deployment        | payment-gateway   | OK       | 0 Critical, 0 High|
| production-payments | NetworkPolicy     | default-deny-all  | OK       | Pass              |
+---------------------+-------------------+-------------------+----------+-------------------+

Misconfiguration Summary:
+---------------------+---------------------+---------------+------------------------------------------------+
|      NAMESPACE      |      RESOURCE       |     ID        |                  TITLE                         |
+---------------------+---------------------+---------------+------------------------------------------------+
| production-payments | ServiceAccount/default| KSV036      | Service account tokens automatically mounted   |
+---------------------+---------------------+---------------+------------------------------------------------+
```

---

## 5. Resolución de Problemas, Guía de Diagnóstico y Modos de Falla

### 5.1 Matriz de Resolución de Problemas para Mitigación de Amenazas

```
                      Threat Mitigation Troubleshooting Flow
                       +----------------------------------+
                       |  Security Control Deployment     |
                       +----------------------------------+
                                        |
                   Does workload fail to start/communicate?
                                        |
                +-----------------------+-----------------------+
                |                                               |
         [ Workload Blocked ]                            [ Network Failed ]
                |                                               |
  Check PodSecurityAdmission logs                 Inspect CNI & NetworkPolicy
  (`kubectl get events`)                          (`cilium monitor` / `iptables`)
                |                                               |
  Fix: Adjust SecurityContext                     Fix: Add strict egress rules
  (Drop ALL caps, non-root)                       (Allow DNS on port 53)
```

| Síntomas / Modo de Falla | Causa Raíz | Comando de Diagnóstico | Pasos de Remediación |
| :--- | :--- | :--- | :--- |
| El Pod permanece en `CreateContainerConfigError` | El sistema de archivos raíz de solo lectura impide las operaciones de escritura de la aplicación (por ejemplo, generación de logs o archivos temporales) | `kubectl describe pod <pod-name> -n <namespace>` (Buscar `Failed to create container: read-only root filesystem`) | Montar un volumen en memoria `emptyDir` en `/tmp` o en directorios específicos de datos requeridos por la aplicación. |
| El Pod falla con `CrashLoopBackOff` o `permission denied` | La aplicación intenta ejecutarse como root o vincularse a puertos privilegiados ($< 1024$) mientras `runAsNonRoot: true` está configurado | `kubectl logs <pod-name> -n <namespace> --previous` | Reconfigurar la imagen de la aplicación para usar un puerto alto (por ejemplo, `8080` en lugar de `80`), configurar `runAsUser: 10001` y asegurar que los permisos de directorio coincidan con `fsGroup`. |
| Las solicitudes salientes de API o base de datos agotan el tiempo de espera (time out) | Una `NetworkPolicy` estricta de egress bloquea el tráfico (por ejemplo, falta la regla de egress de CoreDNS en UDP 53) | `kubectl exec -it <pod-name> -n <namespace> -- nc -zv -w 3 <target-service> <port>` | Actualizar la `NetworkPolicy` para incluir reglas de egress que permitan la resolución DNS (`kube-system/kube-dns` en el puerto 53) y namespaces de bases de datos de destino. |
| El API Server rechaza el envío del manifiesto con `forbidden: violates PodSecurity` | El namespace está etiquetado con `pod-security.kubernetes.io/enforce: restricted` pero a la carga de trabajo le faltan las configuraciones requeridas de `securityContext` | `kubectl get ns <namespace> --show-labels` | Actualizar la especificación de la carga de trabajo para incluir explícitamente `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `seccompProfile: {type: RuntimeDefault}` y `capabilities: {drop: ["ALL"]}`. |

### 5.2 Procedimiento de Diagnóstico Paso a Paso para Fallas en Políticas de Seguridad

#### Paso 1: Diagnosticar Rechazos de PodSecurityAdmission (PSA)
Cuando un manifiesto de Pod es rechazado por el pipeline de admisión del API Server:

```bash
$ kubectl get events -n production-payments --sort-by='.metadata.creationTimestamp' | rg 'FailedCreate'
```

Si la salida del evento indica una violación de la política de PSA:
1. Verificar los niveles de aplicación (enforcement) del namespace:
   ```bash
   $ kubectl get ns production-payments -o jsonpath='{.metadata.labels}' | jq .
   ```
2. Identificar los campos faltantes especificados en el mensaje de error. Asegurar que tanto `pod.spec.securityContext` como `pod.spec.containers[*].securityContext` estén completados de acuerdo con la Sección 3.2.

#### Paso 2: Depurar el Bloqueo de Tráfico de NetworkPolicy
Si los pods se despliegan exitosamente pero falla la comunicación entre servicios:
1. Verificar si la `NetworkPolicy` está activa en el namespace:
   ```bash
   $ kubectl get netpol -n production-payments
   ```
2. Comprobar la resolución DNS de egress desde el interior del pod:
   ```bash
   $ kubectl exec -it payment-gateway-api-7b8f9c-x2z1a -n production-payments -- nslookup production-db.production-database.svc.cluster.local
   ```
3. Si la búsqueda de DNS falla, confirmar que la `NetworkPolicy` permita egress al puerto `53` en el namespace `kube-system`.

---

## 6. Referencias

* **Curriculum KCSA de CNCF**: [https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
* **Documentación de Kubernetes — Threat Model**: [https://kubernetes.io/docs/concepts/security/threat-model/](https://kubernetes.io/docs/concepts/security/threat-model/)
* **Documentación de Kubernetes — Las 4Ks of Cloud Native Security**: [https://kubernetes.io/docs/concepts/security/overview/](https://kubernetes.io/docs/concepts/security/overview/)
* **Matriz MITRE ATT&CK para Contenedores**: [https://attack.mitre.org/matrices/enterprise/containers/](https://attack.mitre.org/matrices/enterprise/containers/)
* **Cheat Sheet de Threat Modeling de OWASP**: [https://cheatsheetseries.owasp.org/cheatsheets/Threat_Modeling_Cheat_Sheet.html](https://cheatsheetseries.owasp.org/cheatsheets/Threat_Modeling_Cheat_Sheet.html)
* **Documentación de Kubernetes — Pod Security Standards**: [https://kubernetes.io/docs/concepts/security/pod-security-standards/](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
* **Documentación de Kubernetes — Auditing**: [https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/](https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/)