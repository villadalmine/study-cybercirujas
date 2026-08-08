# The 4Cs of Cloud Native Security

> **KCSA · Dominio: Overview of Cloud Native Security · Peso: 2.33**
> Modelo de referencia para el resto del temario: cada control que se estudie después (RBAC, admission control, network policies, supply chain) cae dentro de una de estas cuatro capas. Entender *dónde* vive un control es la mitad de saber *por qué* falla.

---

## 1. Motivación y el problema arquitectónico

En una plataforma Kubernetes de producción la superficie de ataque no es un punto: es una **pila de capas anidadas**, cada una confiando en la que tiene debajo. El modelo *4Cs* —**Cloud, Cluster, Container, Code**— es la formalización que hace CNCF/Kubernetes de esa realidad como círculos concéntricos:

```
        ┌─────────────────────────────────────────┐
        │  CLOUD  (o Corporate Datacenter)         │
        │  ┌───────────────────────────────────┐   │
        │  │  CLUSTER                           │   │
        │  │  ┌─────────────────────────────┐   │   │
        │  │  │  CONTAINER                   │   │   │
        │  │  │  ┌───────────────────────┐   │   │   │
        │  │  │  │  CODE                  │   │   │   │
        │  │  │  └───────────────────────┘   │   │   │
        │  │  └─────────────────────────────┘   │   │
        │  └───────────────────────────────────┘   │
        └─────────────────────────────────────────┘
```

El principio arquitectónico que hay que interiorizar —y que el examen evalúa una y otra vez— es de **defensa en profundidad con dependencia direccional**:

> *"Each layer of the Cloud Native security model builds upon the next outermost layer. The Code layer benefits from strong base (Cloud, Cluster, Container) security layers. You cannot safeguard against poor security standards in the base layers by addressing security at the Code level."*
> — Kubernetes docs, *Overview of Cloud Native Security*

Traducido a la práctica de producción: **la seguridad de una capa está topada por la seguridad de la capa que la contiene.** Podés tener el mejor código —dependencias firmadas, SAST verde, cero secretos hardcodeados— pero si el `etcd` del cluster está sin cifrar y accesible en la red del datacenter (capa Cloud), un atacante lee todos tus `Secrets` en texto plano sin tocar tu aplicación. El esfuerzo invertido en la capa interna se desperdicia si la externa está comprometida.

### El anti-patrón que este modelo previene

El error clásico de equipos que vienen de un mundo de VMs y firewalls perimetrales es tratar la seguridad como **un solo perímetro** ("el firewall del datacenter me protege"). En cloud native eso se rompe por tres razones estructurales:

| Supuesto del perímetro tradicional | Realidad cloud native |
|---|---|
| El tráfico interno (east-west) es de confianza | Un Pod comprometido puede hablar con cualquier otro Pod por defecto (red plana) |
| La unidad de despliegue es estable y parcheable | El artefacto es una imagen inmutable de terceros con CVEs heredados |
| La identidad es la IP / la máquina | La identidad es el `ServiceAccount`, el certificado, el token efímero |
| El control es la configuración del host | El control es declarativo (RBAC, admission, PSA) y versionado |

El modelo 4Cs obliga a asignar **cada control a su capa correcta** y a reconocer que ningún control de una capa compensa el hueco de otra. Es el mapa mental sobre el que se construye todo el KCSA.

---

## 2. Las cuatro capas en detalle, con sus trade-offs

### 2.1 Cloud — el *trust base*

Es la infraestructura sobre la que todo corre: el proveedor cloud (AWS/GCP/Azure) o el datacenter corporativo. Es la **raíz de confianza**: si se compromete, nada por encima es defendible. La responsabilidad aquí sigue el *shared responsibility model* del proveedor.

Controles que viven en Cloud:
- **Acceso al API server**: no exponerlo a Internet; usar endpoints privados, `authorizedNetworks`/security groups.
- **Acceso a los nodos**: los nodos worker sólo deberían aceptar tráfico del control plane en puertos definidos; nada de SSH abierto al mundo.
- **Acceso a `etcd`**: sólo desde el API server, con mTLS. `etcd` es el punto único de fallo de confidencialidad del cluster entero.
- **IAM / control plane del proveedor**: quién puede crear/borrar clusters, leer credenciales, tocar el KMS.
- **Cifrado en reposo** del disco de `etcd` y de los volúmenes.

### 2.2 Cluster — los componentes de Kubernetes

Dos sub-dominios: **(a)** securizar los componentes configurables del cluster (API server, kubelet, controller-manager, scheduler, etcd) y **(b)** securizar las **aplicaciones que corren en** el cluster.

Controles que viven en Cluster:
- **AuthN / AuthZ**: RBAC como authorizer, autenticación por certificados/OIDC/tokens.
- **Admission control**: `ValidatingAdmissionPolicy`, webhooks, Pod Security Admission (PSA).
- **Network Policies**: microsegmentación east-west.
- **Secrets management**: cifrado en reposo (`EncryptionConfiguration`), integración con KMS externos.
- **TLS** para todo el tráfico del control plane.

### 2.3 Container — el artefacto y su runtime

Controles que viven en Container:
- **Supply chain**: escaneo de imágenes (CVEs), firma y verificación (cosign/sigstore), SBOM.
- **Hardening del runtime**: no correr como root, `readOnlyRootFilesystem`, drop de capabilities, `seccomp`, no privilegios.
- **Imágenes mínimas**: distroless/scratch para reducir superficie.

### 2.4 Code — la aplicación

Es la capa sobre la que el desarrollador tiene control total y la única cuyo código escribe el equipo.

Controles que viven en Code:
- **TLS en todo el tráfico** de la app, incluso interno.
- **Reducir la superficie de puertos**: exponer sólo lo estrictamente necesario.
- **Dependencias**: análisis de composición (SCA), pinning, escaneo continuo.
- **SAST/DAST** en el pipeline.
- **Gestión de secretos**: nunca en el código; inyección en runtime.

### 2.5 Tabla maestra de trade-offs

| Capa | Qué protege | Superficie de ataque típica | Controles clave | Coste / fricción | Radio de impacto si falla |
|---|---|---|---|---|---|
| **Cloud** | La raíz de confianza (infra, red, `etcd`, IAM) | API server público, `etcd` sin cifrar, SSH abierto, IAM laxo | Endpoints privados, cifrado en reposo, KMS, least-privilege IAM | Bajo esfuerzo runtime, alto esfuerzo organizativo | **Total** — compromete todo lo de arriba |
| **Cluster** | Componentes k8s + apps desplegadas | RBAC con `cluster-admin` regalado, red plana, secrets en claro | RBAC, PSA, NetworkPolicy, `EncryptionConfiguration` | Medio — fricción con devs (RBAC, PSA) | Multi-tenant — un namespace compromete a otros |
| **Container** | El artefacto y su ejecución | Imagen con CVEs, root, privileged, sin firmar | Scanning, cosign, seccomp, non-root, capabilities drop | Medio — CI más lento, imágenes que rompen | Un Pod / un workload |
| **Code** | Lógica de la aplicación | Inyección, deps vulnerables, secretos hardcodeados, puertos de más | TLS, SAST/SCA, secret injection, mínima superficie | Alto — es trabajo continuo del equipo dev | Una app / un endpoint |

**Regla de lectura de la tabla:** el *radio de impacto* crece hacia afuera y el *esfuerzo por unidad* tiende a crecer hacia adentro. Por eso la priorización de producción es **de afuera hacia adentro**: primero cerrás el `etcd` y el API server (barato de arreglar, catastrófico si falla), y sólo después perseguís el CVE de severidad media en una librería transitiva.

---

## 3. Manifiestos: un control representativo por capa

El 4Cs es conceptual, pero el KCSA espera que reconozcas **qué manifiesto materializa qué capa**. Estos cuatro, juntos, son un mínimo defendible.

### 3.1 Capa Cloud — cifrado de `Secrets` en reposo (`EncryptionConfiguration`)

Este archivo se pasa al API server con `--encryption-provider-config`. Sin él, `etcd` guarda tus `Secrets` en base64 (no cifrado). Es *frontera Cloud/Cluster*: protege el `etcd` (Cloud) mediante configuración del API server (Cluster).

```yaml
# /etc/kubernetes/enc/encryption-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      # KMS v2 con proveedor externo (envelope encryption) — preferido en prod
      - kms:
          apiVersion: v2
          name: kms-provider
          endpoint: unix:///var/run/kmsplugin/socket.sock
          timeout: 3s
      # AES-GCM local como fallback; NUNCA 'identity' como primero
      - aesgcm:
          keys:
            - name: key1
              secret: c2VjcmV0IGlzIHNlY3VyZSwgcm90YXRlIG1l
      # 'identity' al final = leído en claro; presente sólo para migración
      - identity: {}
```

> El **orden importa**: el primer provider cifra la escritura; todos se prueban en orden para la lectura. Poner `identity` primero desactiva el cifrado silenciosamente — error de auditoría clásico.

### 3.2 Capa Cluster — RBAC de mínimo privilegio + microsegmentación

```yaml
# rbac-least-privilege.yaml — un rol namespaced, jamás cluster-admin al deployer
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: payments
  name: deployer
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch", "update", "patch"]
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  namespace: payments
  name: deployer-binding
subjects:
  - kind: ServiceAccount
    name: ci-deployer
    namespace: payments
roleRef:
  kind: Role
  name: deployer
  apiGroup: rbac.authorization.k8s.io
```

```yaml
# netpol-default-deny.yaml — la red NO es plana por defecto; la hacemos zero-trust
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: payments
spec:
  podSelector: {}          # aplica a TODOS los Pods del namespace
  policyTypes:
    - Ingress
    - Egress
  # sin reglas ingress/egress = todo denegado
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-api-from-frontend
  namespace: payments
spec:
  podSelector:
    matchLabels:
      app: payments-api
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: frontend
      ports:
        - protocol: TCP
          port: 8443
```

```yaml
# psa-namespace.yaml — Pod Security Admission a nivel namespace, perfil 'restricted'
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

### 3.3 Capa Container — Pod hardened que satisface el perfil `restricted`

```yaml
# pod-hardened.yaml
apiVersion: v1
kind: Pod
metadata:
  name: payments-api
  namespace: payments
  labels:
    app: payments-api
spec:
  automountServiceAccountToken: false     # no montar el token si la app no lo usa
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault                # seccomp obligatorio en 'restricted'
  containers:
    - name: api
      image: registry.example.com/payments-api@sha256:9f2c...e1a7  # pin por digest
      ports:
        - containerPort: 8443
      securityContext:
        allowPrivilegeEscalation: false
        privileged: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]                   # dropear TODO; añadir sólo lo imprescindible
      resources:
        requests: { cpu: "100m", memory: "128Mi" }
        limits:   { cpu: "500m", memory: "256Mi" }
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
```

Puntos que el examen enlaza a la capa Container: `runAsNonRoot`, `readOnlyRootFilesystem`, `drop: ["ALL"]`, `allowPrivilegeEscalation: false`, `seccompProfile: RuntimeDefault`, imagen **por digest** (no por tag mutable).

### 3.4 Capa Container/Cluster — verificación de firma en admission (policy-controller / Kyverno)

```yaml
# kyverno-verify-images.yaml — sólo admite imágenes firmadas por nuestra clave cosign
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signatures
spec:
  validationFailureAction: Enforce
  webhookTimeoutSeconds: 30
  rules:
    - name: verify-payments-images
      match:
        any:
          - resources:
              kinds: ["Pod"]
              namespaces: ["payments"]
      verifyImages:
        - imageReferences:
            - "registry.example.com/*"
          attestors:
            - entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE...
                      -----END PUBLIC KEY-----
```

---

## 4. Comandos CLI y salidas reales

### 4.1 Cloud/Cluster — ¿está el `etcd` cifrando de verdad?

```bash
$ kubectl create secret generic canary --from-literal=token=supersecret -n payments
secret/canary created

# Leemos el blob CRUDO de etcd. Si vemos 'k8s:enc:kms:v2:' está cifrado.
$ sudo ETCDCTL_API=3 etcdctl \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    get /registry/secrets/payments/canary | hexdump -C | head -3
00000000  2f 72 65 67 69 73 74 72  79 2f 73 65 63 72 65 74  |/registry/secret|
00000010  73 2f 70 61 79 6d 65 6e  74 73 2f 63 61 6e 61 72  |s/payments/canar|
00000020  79 0a 6b 38 73 3a 65 6e  63 3a 6b 6d 73 3a 76 32  |y.k8s:enc:kms:v2|
```

> El marcador `k8s:enc:kms:v2` confirma cifrado por KMS. Si en su lugar apareciera `supersecret` en claro, el `etcd` está expuesto: **fallo de capa Cloud**, no de la app.

### 4.2 Cluster — auditar RBAC excesivo

```bash
$ kubectl get clusterrolebindings -o json \
  | jq -r '.items[] | select(.roleRef.name=="cluster-admin")
           | .subjects[]? | "\(.kind)/\(.namespace)/\(.name)"'
ServiceAccount/kube-system/clusterrole-aggregation-controller
ServiceAccount/payments/ci-deployer          # <-- ALERTA: un CI con cluster-admin

$ kubectl auth can-i --list --as=system:serviceaccount:payments:ci-deployer -n payments
Resources        Non-Resource URLs   Resource Names   Verbs
*.*              []                  []               [*]     # <-- puede TODO
```

### 4.3 Container — escaneo de CVEs con Trivy

```bash
$ trivy image --severity HIGH,CRITICAL registry.example.com/payments-api:1.4.0
2026-08-07T14:22:10Z  INFO  Vulnerability scanning is enabled
payments-api:1.4.0 (debian 12.5)

Total: 2 (HIGH: 1, CRITICAL: 1)

┌────────────┬────────────────┬──────────┬───────────────────┬───────────────┐
│  Library   │ Vulnerability  │ Severity │ Installed Version │ Fixed Version │
├────────────┼────────────────┼──────────┼───────────────────┼───────────────┤
│ libssl3    │ CVE-2024-XXXXX │ CRITICAL │ 3.0.11-1          │ 3.0.13-1      │
│ zlib1g     │ CVE-2023-YYYYY │ HIGH     │ 1:1.2.13.dfsg-1   │ 1:1.2.13-1+b1 │
└────────────┴────────────────┴──────────┴───────────────────┴───────────────┘

$ echo $?
1        # exit code != 0 → el CI falla y corta el pipeline
```

### 4.4 Container — verificar la firma antes de desplegar

```bash
$ cosign verify --key cosign.pub registry.example.com/payments-api@sha256:9f2c...e1a7
Verification for registry.example.com/payments-api@sha256:9f2c...e1a7 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - The signatures were verified against the specified public key
[{"critical":{"identity":{"docker-reference":"registry.example.com/payments-api"},
  "image":{"docker-manifest-digest":"sha256:9f2c...e1a7"},"type":"cosign container image signature"}}]
```

### 4.5 Cluster — benchmark CIS del control plane

```bash
$ kube-bench run --targets master
[INFO] 1 Control Plane Security Configuration
[PASS] 1.2.1 Ensure that the --anonymous-auth argument is set to false
[FAIL] 1.2.6 Ensure that the --kubelet-certificate-authority argument is set
[WARN] 1.2.16 Ensure that the --profiling argument is set to false

== Summary ==
44 checks PASS
3  checks FAIL
8  checks WARN
```

---

## 5. Guía de verificación y diagnóstico de fallas

La pregunta operativa correcta ante un incidente es siempre: **¿en qué C está el hueco?** Diagnosticar en la capa equivocada es perder tiempo mientras la brecha sigue abierta.

### 5.1 Checklist de verificación por capa

| Capa | Pregunta de verificación | Comando / evidencia | Verde si… |
|---|---|---|---|
| Cloud | ¿El API server es privado? | `kubectl cluster-info` + revisar el endpoint/IP | No resuelve a IP pública |
| Cloud | ¿`etcd` cifra en reposo? | `etcdctl get ... \| hexdump` (§4.1) | Aparece `k8s:enc:` |
| Cluster | ¿Alguien tiene `cluster-admin` de más? | §4.2 | Sólo controladores de sistema |
| Cluster | ¿La red niega por defecto? | `kubectl get netpol -A` | Existe `default-deny` por ns |
| Cluster | ¿PSA en modo enforce? | `kubectl get ns -L pod-security.kubernetes.io/enforce` | `restricted`/`baseline`, no vacío |
| Container | ¿Pods como root o privileged? | ver §5.2 | Salida vacía |
| Container | ¿Imágenes firmadas y sin CVE crítico? | §4.3 / §4.4 | `verify` OK, scan exit 0 |
| Code | ¿Secretos en la imagen/código? | `trivy image --scanners secret` | `Total: 0` |

### 5.2 Detectar Pods peligrosos en todo el cluster

```bash
# Pods corriendo como root o con privileged=true
$ kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\t"}{.spec.containers[*].securityContext.privileged}{"\t"}{.spec.securityContext.runAsNonRoot}{"\n"}{end}' \
  | awk -F'\t' '$2=="true" || $3!="true" {print}'
default/legacy-cron   true    <nil>     # <-- privileged + runAsNonRoot sin fijar
```

### 5.3 Árbol de decisión de diagnóstico

```
Un Pod fue rechazado en el deploy →
  ¿Mensaje "violates PodSecurity restricted:..."?
      SÍ → capa Container: falta hardening del securityContext (§3.3)
      NO → ¿Mensaje "failed to verify signature"?
              SÍ → capa Container/Cluster: imagen no firmada (§3.4)
              NO → ¿"forbidden: User cannot..."?
                      SÍ → capa Cluster: RBAC insuficiente (o excesivo si al revés)
                      NO → ¿"NetworkPolicy" / timeout entre Pods?
                              SÍ → capa Cluster: falta regla allow (§3.2)
                              NO → revisar capa Cloud (endpoint, KMS, IAM)
```

### 5.4 Fallo típico y su lectura correcta

```bash
$ kubectl apply -f pod-root.yaml -n payments
Error from server (Forbidden): error when creating "pod-root.yaml":
pods "legacy" is forbidden: violates PodSecurity "restricted:latest":
allowPrivilegeEscalation != false (container "app" must set
securityContext.allowPrivilegeEscalation=false), unrestricted capabilities
(container "app" must set securityContext.capabilities.drop=["ALL"]),
runAsNonRoot != true, seccompProfile ...
```

Lectura: **no es un bug de la app**, es la capa Cluster (PSA) haciendo cumplir hardening de capa Container. El arreglo es el `securityContext` de §3.3, no desactivar la política. Desactivar PSA para "que ande" es exactamente el anti-patrón que el modelo 4Cs advierte: comprometer una capa externa para tapar una carencia interna.

### 5.5 El punto ciego que ninguna herramienta free detecta

El modelo 4Cs cubre *estructura*, no *veracidad de la lógica*. Una app puede pasar SAST, correr non-root, con imagen firmada y NetworkPolicy correcta, y aun así implementar mal una verificación de autorización en su propio código. Ninguna de las capas base lo detecta: es responsabilidad exclusiva de la capa **Code** y de las pruebas de aplicación. Reconocer que **el 4Cs no es una garantía de corrección, sino un marco de asignación de responsabilidad** es la respuesta madura que distingue al profesional en el examen.

---

## 6. Referencias

- Kubernetes — *Overview of Cloud Native Security* (definición canónica de los 4Cs): https://kubernetes.io/docs/concepts/security/overview/
- Kubernetes — *Security* (índice de conceptos de seguridad): https://kubernetes.io/docs/concepts/security/
- Kubernetes — *Pod Security Standards*: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Kubernetes — *Enforcing Pod Security Standards (Admission)*: https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Kubernetes — *Encrypting Confidential Data at Rest*: https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
- Kubernetes — *Using RBAC Authorization*: https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Kubernetes — *Network Policies*: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes — *Configure a Security Context for a Pod or Container*: https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- CNCF — *Cloud Native Security Whitepaper* (TAG Security): https://github.com/cncf/tag-security/tree/main/community/resources/security-whitepaper
- CNCF — *Software Supply Chain Security Best Practices*: https://github.com/cncf/tag-security/tree/main/community/resources/supply-chain-security
- CNCF — *KCSA Curriculum*: https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
- Sigstore/cosign — *Verifying signatures*: https://docs.sigstore.dev/cosign/verifying/verify/
- CIS — *Kubernetes Benchmark* (vía kube-bench): https://github.com/aquasecurity/kube-bench
- Aqua Trivy — *Vulnerability & secret scanning*: https://trivy.dev/latest/docs/