# 3.3 — Restringir el acceso a la API de Kubernetes

**Certificación:** CKS (Certified Kubernetes Security Specialist), versión de examen 1.34
**Dominio:** 3 — Cluster Hardening · **Peso del tema:** 3.75 %

---

## 1. El problema en producción

`kube-apiserver` es el único componente de un clúster de Kubernetes que escribe en etcd. Cualquier otro proceso del plano de control — scheduler, controller-manager, kubelet, CNI, CSI, operadores — es un *cliente*. Esa decisión arquitectónica es lo que vuelve coherente a Kubernetes, y es también lo que convierte al API server en el objetivo más valioso del clúster: **una sola petición autenticada y con privilegios excesivos al puerto 6443 equivale a root en todos los nodos.**

La cadena de escalada que los revisores ven una y otra vez en incidentes reales:

```
reachable :6443  →  identity accepted  →  create pods (any namespace)
                                       →  pod with hostPath: / + privileged
                                       →  chroot /host
                                       →  read /etc/kubernetes/pki/ca.key
                                       →  mint a client cert with O=system:masters
                                       →  permanent, unrevokable cluster-admin
```

Prestá atención al último paso. Un token de ServiceAccount robado puede revocarse; un certificado de cliente firmado por la CA del clúster **no** — Kubernetes no implementa ni CRL ni OCSP. La única remediación es rotar la CA del clúster, una operación de varias horas que toca todos los nodos y todos los kubeconfigs. Esa asimetría es la razón por la que "restringir el acceso a la API" es un tema de *defensa en profundidad* y no un único flag.

Hay cuatro barreras independientes, y un clúster en producción debe cerrar las cuatro. Fallar en una sola alcanza para un compromiso total:

| Barrera | Pregunta que responde | Control principal | Radio de impacto si falla |
|---|---|---|---|
| **1. Alcanzabilidad** | ¿Puede el paquete llegar al 6443? | Firewall / `--bind-address` / redes autorizadas | Global — escaneo de tu plano de control desde toda Internet |
| **2. Autenticación** | ¿Quién es este? | x509, OIDC, tokens de SA, `anonymous` | Falsificación de identidad, lecturas no autenticadas |
| **3. Autorización** | ¿Puede *esta* identidad hacer *esto*? | Cadena Node + RBAC + Webhook | Escalada de privilegios, movimiento lateral |
| **4. Admisión y limitación de caudal** | ¿Es aceptable el *objeto*? ¿A qué ritmo? | Plugins de admisión, ValidatingAdmissionPolicy, APF | Fuga del contenedor, DoS del plano de control |

El resto de este material recorre las cuatro barreras en el orden de la petición, exactamente como las evalúa `kube-apiserver`.

---

## 2. Anatomía de una petición (la mecánica que hay que saber recitar)

```
        TCP :6443
            │
            ▼
   ┌──────────────────┐
   │ TLS handshake    │  --tls-cert-file / --client-ca-file
   │ (mTLS optional)  │  --tls-min-version / --tls-cipher-suites
   └────────┬─────────┘
            ▼
   ┌──────────────────┐   Authenticator chain — FIRST success wins,
   │ Authentication   │   remaining authenticators are skipped.
   │                  │   Output: username + UID + groups[] + extra{}
   └────────┬─────────┘   Failure of ALL → anonymous (if enabled) else 401
            ▼
   ┌──────────────────┐   Audit stage: RequestReceived / ResponseStarted
   │ Audit            │
   └────────┬─────────┘
            ▼
   ┌──────────────────┐   Authorizer chain — each returns
   │ Authorization    │   Allow | Deny | NoOpinion.
   │                  │   FIRST Allow or Deny terminates the chain.
   └────────┬─────────┘   All NoOpinion → 403
            ▼
   ┌──────────────────┐
   │ APF (flow ctl)   │   FlowSchema → PriorityLevel → queue or 429
   └────────┬─────────┘
            ▼
   ┌──────────────────┐
   │ Mutating admission → schema validation → Validating admission │
   └────────┬─────────┘
            ▼
          etcd
```

Dos propiedades de este pipeline son relevantes para el examen y se malinterpretan constantemente:

1. **La autenticación es un `OR`; la autorización es de cortocircuito.** Agregar un autenticador solo puede *ampliar* quién entra. Agregar un autorizador *después* de RBAC nunca puede quitar lo que RBAC ya permitió — un webhook orientado a denegar debe ubicarse **antes** de RBAC en la cadena.
2. **401 vs 403 es una señal de diagnóstico, no un detalle.** `401 Unauthorized` = la barrera 2 te rechazó (no hay identidad). `403 Forbidden` = la barrera 2 te aceptó y la barrera 3 se negó. Si desactivás la autenticación anónima y una sonda empieza a devolver 403 en lugar de 401, tu cambio no tuvo efecto.

---

## 3. Barrera 1 — Alcanzabilidad de red

Los objetos `NetworkPolicy` de Kubernetes **no protegen al API server.** El plano de control corre en la red del host, fuera del dataplane del CNI; no existe ninguna `NetworkPolicy` que pueda filtrar el ingreso a `kube-apiserver`. Esto sorprende a la gente en absolutamente todas las auditorías.

### 3.1 Tabla de trade-offs

| Control | Dónde se aplica | ¿Sobrevive a la reconstrucción del nodo? | Granularidad | Modo de fallo | Veredicto |
|---|---|---|---|---|---|
| `--bind-address=<private IP>` | socket del apiserver | Sí (manifiesto de static pod) | Interfaz | Clúster inalcanzable si cambia la IP | Línea base para on-prem |
| Firewall del host (`nftables`/`firewalld`) | kernel del nodo del plano de control | No (una reimagen lo borra) | CIDR + puerto | Bloqueo silencioso, requiere acceso por consola | Bueno, pero debe estar gestionado por configuración |
| SG / NACL de la nube | fabric de red del proveedor | Sí | CIDR + puerto | Bloqueo, recuperable desde la consola | **Preferido en la nube** |
| "Redes autorizadas" gestionadas (EKS `publicAccessCidrs`, GKE `master-authorized-networks`, AKS `--api-server-authorized-ip-ranges`) | plano de control del proveedor | Sí | Lista de CIDR | La API devuelve timeout de conexión | **Preferido en servicios gestionados** |
| Solo endpoint privado (sin IP pública) | VPC del proveedor | Sí | VPC/peering | Requiere bastión/VPN para los operadores | El más fuerte; el de mayor costo operativo |
| Egreso vía `konnectivity` / túnel SSH | dirección plano de control → nodo | Sí | n/a | Se rompen exec/logs/port-forward | Complementa, no reemplaza |

### 3.2 Enlazar el API server a una interfaz privada

`/etc/kubernetes/manifests/kube-apiserver.yaml` en un nodo de plano de control de kubeadm. Esto es un **static pod** — el kubelet vigila el directorio y reinicia el contenedor ante cualquier cambio del archivo.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: kube-apiserver
  namespace: kube-system
  labels:
    component: kube-apiserver
    tier: control-plane
  annotations:
    kubeadm.kubernetes.io/kube-apiserver.advertise-address.endpoint: 10.0.10.11:6443
spec:
  hostNetwork: true
  priorityClassName: system-node-critical
  containers:
  - name: kube-apiserver
    image: registry.k8s.io/kube-apiserver:v1.34.0
    command:
    - kube-apiserver
    # ---- Gate 1: reachability ---------------------------------------------
    - --bind-address=10.0.10.11              # NOT 0.0.0.0
    - --advertise-address=10.0.10.11
    - --secure-port=6443
    # ---- TLS hardening (CIS 1.2.x) ----------------------------------------
    - --tls-cert-file=/etc/kubernetes/pki/apiserver.crt
    - --tls-private-key-file=/etc/kubernetes/pki/apiserver.key
    - --tls-min-version=VersionTLS12
    - --tls-cipher-suites=TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305
    - --profiling=false                      # closes /debug/pprof
    # ---- Gate 2: authentication -------------------------------------------
    - --client-ca-file=/etc/kubernetes/pki/ca.crt
    - --authentication-config=/etc/kubernetes/authn/authentication.yaml
    - --service-account-key-file=/etc/kubernetes/pki/sa.pub
    - --service-account-signing-key-file=/etc/kubernetes/pki/sa.key
    - --service-account-issuer=https://kubernetes.default.svc.cluster.local
    - --service-account-lookup=true          # revoke legacy tokens by deleting the Secret
    - --api-audiences=https://kubernetes.default.svc.cluster.local
    # ---- Gate 3: authorization --------------------------------------------
    - --authorization-config=/etc/kubernetes/authz/authorization.yaml
    # ---- Gate 4: admission + audit ----------------------------------------
    - --enable-admission-plugins=NodeRestriction
    - --audit-policy-file=/etc/kubernetes/audit/policy.yaml
    - --audit-log-path=/var/log/kubernetes/audit/audit.log
    - --audit-log-maxage=30
    - --audit-log-maxbackup=10
    - --audit-log-maxsize=100
    - --request-timeout=60s
    # ---- etcd / kubelet client identities ---------------------------------
    - --etcd-servers=https://10.0.10.11:2379
    - --etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt
    - --etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt
    - --etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key
    - --kubelet-client-certificate=/etc/kubernetes/pki/apiserver-kubelet-client.crt
    - --kubelet-client-key=/etc/kubernetes/pki/apiserver-kubelet-client.key
    - --kubelet-certificate-authority=/etc/kubernetes/pki/ca.crt
    - --allow-privileged=true
    livenessProbe:
      failureThreshold: 8
      httpGet:
        host: 10.0.10.11
        path: /livez
        port: 6443
        scheme: HTTPS
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 15
    readinessProbe:
      failureThreshold: 3
      httpGet:
        host: 10.0.10.11
        path: /readyz
        port: 6443
        scheme: HTTPS
      periodSeconds: 1
      timeoutSeconds: 15
    startupProbe:
      failureThreshold: 24
      httpGet:
        host: 10.0.10.11
        path: /livez
        port: 6443
        scheme: HTTPS
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 15
    volumeMounts:
    - name: k8s-certs
      mountPath: /etc/kubernetes/pki
      readOnly: true
    - name: authn
      mountPath: /etc/kubernetes/authn
      readOnly: true
    - name: authz
      mountPath: /etc/kubernetes/authz
      readOnly: true
    - name: audit-policy
      mountPath: /etc/kubernetes/audit
      readOnly: true
    - name: audit-log
      mountPath: /var/log/kubernetes/audit
      readOnly: false
    - name: ca-certs
      mountPath: /etc/ssl/certs
      readOnly: true
  volumes:
  - name: k8s-certs
    hostPath: {path: /etc/kubernetes/pki, type: DirectoryOrCreate}
  - name: authn
    hostPath: {path: /etc/kubernetes/authn, type: DirectoryOrCreate}
  - name: authz
    hostPath: {path: /etc/kubernetes/authz, type: DirectoryOrCreate}
  - name: audit-policy
    hostPath: {path: /etc/kubernetes/audit, type: DirectoryOrCreate}
  - name: audit-log
    hostPath: {path: /var/log/kubernetes/audit, type: DirectoryOrCreate}
  - name: ca-certs
    hostPath: {path: /etc/ssl/certs, type: DirectoryOrCreate}
```

> **Regla operativa:** todo archivo que referencies con un flag debe existir también como volumen `hostPath` **y** como `volumeMount`. Un montaje faltante es la causa número 1 de "agregué el flag y el API server nunca volvió" — el contenedor arranca, no puede abrir el archivo y termina antes de poder registrar algo útil en un lugar que puedas leer con `kubectl`.

### 3.3 Firewall del host (nftables), gestionado por configuración

```bash
$ cat /etc/nftables.d/k8s-controlplane.nft
table inet k8s_cp {
  set admin_nets {
    type ipv4_addr
    flags interval
    elements = { 10.0.10.0/24, 10.0.20.0/24, 203.0.113.7/32 }
  }
  chain input {
    type filter hook input priority filter; policy accept;

    # kube-apiserver: only nodes + the bastion range
    tcp dport 6443 ip saddr @admin_nets accept
    tcp dport 6443 counter log prefix "k8s-apiserver-drop " drop

    # etcd: control-plane peers only
    tcp dport { 2379, 2380 } ip saddr { 10.0.10.0/24 } accept
    tcp dport { 2379, 2380 } counter drop

    # kubelet read-write API
    tcp dport 10250 ip saddr { 10.0.10.0/24 } accept
    tcp dport 10250 counter drop
  }
}

$ sudo nft -f /etc/nftables.d/k8s-controlplane.nft
$ sudo nft list ruleset | grep -A3 'dport 6443'
		tcp dport 6443 ip saddr @admin_nets accept
		tcp dport 6443 counter packets 0 bytes 0 log prefix "k8s-apiserver-drop " drop
```

Verificación desde una red no autorizada:

```bash
$ nc -vz -w3 10.0.10.11 6443
nc: connect to 10.0.10.11 port 6443 (tcp) timed out: Operation now in progress
```

Un **timeout** (no `connection refused`, no un error TLS) es la firma de un filtro L3/L4 que funciona correctamente.

---

## 4. Barrera 2 — Autenticación

### 4.1 La cadena de autenticadores

| Método | Se habilita con | ¿Revocable? | Expiración | Origen de los grupos | Veredicto CKS |
|---|---|---|---|---|---|
| **Certificado de cliente x509** | `--client-ca-file` | ❌ **Sin soporte de CRL** | `notAfter` del certificado | Campos `O=` | Solo break-glass; vidas ≤ 24 h |
| **Archivo de tokens estáticos** | `--token-auth-file` | Solo con reinicio | Nunca | Columna del CSV | ❌ Prohibido — texto plano en disco |
| **Archivo de contraseñas estáticas** | *(eliminado en 1.19)* | — | — | — | ❌ No existe |
| **Bootstrap token** | `--enable-bootstrap-token-auth` | Borrar el Secret | Campo `expiration` | `system:bootstrappers:*` | Solo para unir nodos, TTL corto |
| **Token de SA — Secret heredado** | automático (comportamiento previo a 1.24) | Borrar el Secret *(requiere `--service-account-lookup=true`)* | **Nunca** | `system:serviceaccounts[:ns]` | Migrar fuera de esto |
| **Token de SA — TokenRequest / proyectado** | por defecto desde 1.21 | Borrar el Pod o la SA | 1 h, rotado automáticamente al ~80 % | igual + vínculo a pod/nodo | ✅ Predeterminado para cargas de trabajo |
| **OIDC / JWT estructurado** | `--authentication-config` | Del lado del IdP, inmediato | Minutos | Claim `groups`, mapeado con CEL | ✅ Personas en producción |
| **Webhook de token** | `--authentication-token-webhook-config-file` | Externo | Externo | Externo | Integración con IAM de la nube |
| **Anónimo** | `--anonymous-auth` / configuración | n/a | n/a | `system:unauthenticated` | Restringir a los endpoints de salud |
| **Cabeceras de proxy** | `--requestheader-*` | n/a | n/a | cabecera | Solo capa de agregación |

### 4.2 Acceso anónimo — y la trampa que rompe tu plano de control

Por defecto el API server acepta peticiones no autenticadas y les asigna:

```
username: system:anonymous
groups:   [system:unauthenticated]
```

La postura RBAC por defecto mantiene esto inofensivo: el único binding que apunta a `system:unauthenticated` es `system:public-info-viewer`.

```bash
$ kubectl auth can-i --list --as=system:anonymous
Resources   Non-Resource URLs   Resource Names   Verbs
            [/healthz]          []               [get]
            [/livez]            []               [get]
            [/readyz]           []               [get]
            [/version/]         []               [get]
            [/version]          []               [get]
```

```bash
$ curl -sk https://10.0.10.11:6443/api/v1/namespaces/kube-system/secrets | jq -c '{code,message}'
{"code":403,"message":"secrets is forbidden: User \"system:anonymous\" cannot list resource \"secrets\" in API group \"\" in the namespace \"kube-system\""}
```

La configuración catastrófica — vista en informes reales de brechas — es que alguien vincule un sujeto no autenticado a un rol amplio:

```yaml
# ☠️  NEVER. This is remote, unauthenticated cluster-admin.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: debug-please-remove-later
subjects:
- kind: Group
  name: system:unauthenticated       # or system:anonymous, or system:authenticated
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
```

**La trampa.** El paso obvio de endurecimiento es `--anonymous-auth=false`. En un clúster de kubeadm eso mata el plano de control, porque las sondas de liveness/readiness del kubelet contra `/livez` y `/readyz` son GET HTTP no autenticados:

```
$ sudo crictl ps -a --name kube-apiserver
CONTAINER      IMAGE          CREATED         STATE     NAME             ATTEMPT
a41c9e2f7b0d   c3ff0a2e2b1f   40 seconds ago  Exited    kube-apiserver   6

$ sudo journalctl -u kubelet --since -5min | grep -i probe
Aug 03 11:04:12 cp-1 kubelet[1180]: I0803 11:04:12.774 1180 prober.go:107] "Probe failed" probeType="Startup" pod="kube-system/kube-apiserver-cp-1" podUID="8c1..." containerName="kube-apiserver" result="Failure" output="HTTP probe failed with statuscode: 401"
Aug 03 11:04:22 cp-1 kubelet[1180]: I0803 11:04:22.781 1180 kuberuntime_manager.go:1027] "Container failed startup probe, will be restarted" pod="kube-system/kube-apiserver-cp-1"
```

`statuscode: 401` en un endpoint de salud es la huella digital de exactamente este error.

**La corrección correcta (1.32+): endpoints anónimos configurables.** Mantené viva la autenticación anónima *solo* para las rutas de las sondas, usando la configuración estructurada de autenticación:

```yaml
# /etc/kubernetes/authn/authentication.yaml
apiVersion: apiserver.config.k8s.io/v1beta1
kind: AuthenticationConfiguration

# Anonymous requests are accepted ONLY on these exact paths.
# Everything else from an unauthenticated client gets 401.
anonymous:
  enabled: true
  conditions:
  - path: /livez
  - path: /readyz
  - path: /healthz
```

> **Exclusión mutua:** si el archivo de configuración contiene una sección `anonymous`, **no** debés pasar además `--anonymous-auth` en la línea de comandos. El API server se niega a arrancar con ambos. Quitá el flag del manifiesto del static pod.

Verificación después del cambio:

```bash
$ curl -sk -o /dev/null -w '%{http_code}\n' https://10.0.10.11:6443/livez
200
$ curl -sk -o /dev/null -w '%{http_code}\n' https://10.0.10.11:6443/version
401
$ curl -sk https://10.0.10.11:6443/api/v1/nodes | jq -c '{code,message}'
{"code":401,"message":"Unauthorized"}
```

`200` en `/livez` y `401` en todo lo demás es exactamente el estado objetivo.

**Alternativa, cuando la política obliga a `--anonymous-auth=false`** (por ejemplo, un clúster más viejo, o un perfil CIS que verifica el flag literalmente): reescribí las sondas para que se autentiquen con un certificado de cliente mediante un wrapper `exec`, o apuntalas al `--secure-port` local del kubelet con un archivo de token. Esto es materialmente más frágil que el enfoque de endpoints configurables; preferí el archivo de configuración cuando la versión lo permita.

### 4.3 Configuración completa de JWT / OIDC con salvaguardas CEL

El mismo archivo lleva la configuración del proveedor de identidad. Este es el reemplazo moderno de los flags `--oidc-*`, y sus reglas CEL permiten imponer invariantes que los flags nunca pudieron:

```yaml
# /etc/kubernetes/authn/authentication.yaml (complete)
apiVersion: apiserver.config.k8s.io/v1beta1
kind: AuthenticationConfiguration

anonymous:
  enabled: true
  conditions:
  - path: /livez
  - path: /readyz
  - path: /healthz

jwt:
- issuer:
    url: https://sso.example.com/realms/platform
    audiences:
    - kubernetes-prod
    audienceMatchPolicy: MatchAny
    certificateAuthority: |
      -----BEGIN CERTIFICATE-----
      MIIDdzCCAl+gAwIBAgIEbY6prTANBgkqhkiG9w0BAQsFADBaMQswCQYDVQQGEwJV
      UzETMBEGA1UECBMKQ2FsaWZvcm5pYTEWMBQGA1UEBxMNU2FuIEZyYW5jaXNjbzEP
      MA0GA1UEChMGRXhhbXBsZTENMAsGA1UEAxMEcm9vdDAeFw0yNTAxMDEwMDAwMDBa
      -----END CERTIFICATE-----

  claimMappings:
    username:
      # Prefix is MANDATORY unless expression yields a value that cannot
      # collide with built-in identities. Never map raw `sub` without a prefix.
      expression: "'sso:' + claims.sub"
    groups:
      expression: "claims.groups.map(g, 'sso:' + g)"
    uid:
      expression: "claims.sub"
    extra:
    - key: "example.com/tenant"
      valueExpression: "claims.tenant_id"

  claimValidationRules:
  - expression: "claims.hd == 'example.com'"
    message: "the token must be issued to an example.com hosted-domain account"
  - expression: "'kubernetes-prod' in claims.aud"
    message: "audience must include kubernetes-prod"
  - expression: "has(claims.amr) && 'mfa' in claims.amr"
    message: "multi-factor authentication is required for cluster access"

  userValidationRules:
  - expression: "!user.groups.exists(g, g.startsWith('system:'))"
    message: "external identities must not claim any system: group"
  - expression: "user.username.startsWith('sso:')"
    message: "username must carry the sso: prefix"
```

Las dos `userValidationRules` de arriba cierran una vía de escalada genuina: sin ellas, un IdP al que se pueda inducir a emitir `groups: ["system:masters"]` otorga cluster-admin al portador, porque el autorizador RBAC resuelve nombres de grupos, no su procedencia.

Semántica de recarga: `--authentication-config` se vigila y se recarga en caliente — no hace falta reiniciar el API server para cambios de JWT (la sección `anonymous` se aplica al arrancar). Confirmá que la recarga tuvo éxito:

```bash
$ kubectl get --raw /metrics | grep apiserver_authentication_config_controller_automatic_reload_last_timestamp_seconds
apiserver_authentication_config_controller_automatic_reload_last_timestamp_seconds{apiserver_id_hash="sha256:9c1f...",status="success"} 1.754218e+09
```

> **Chequeo de versión antes de confiar en cualquiera de estas cosas en el examen o en producción:**
> ```bash
> $ kube-apiserver --help | grep -E 'authentication-config|anonymous-auth'
> $ kubectl get --raw /metrics | grep 'kubernetes_feature_enabled.*Anonymous'
> ```
> `apiserver.config.k8s.io/v1beta1` se sirve en 1.34; las versiones más nuevas pueden servir también `v1`. Leé la versión que reporta tu clúster en vez de asumirla.

### 4.4 Certificados de cliente: la identidad irrevocable

```bash
$ openssl x509 -in /etc/kubernetes/pki/apiserver-kubelet-client.crt -noout -subject -dates
subject=O=system:masters, CN=kube-apiserver-kubelet-client
notBefore=Jul 20 09:14:31 2026 GMT
notAfter=Jul 20 09:19:31 2027 GMT
```

El `CN` se convierte en el **nombre de usuario**; cada `O` se convierte en un **grupo**. Nada más del certificado le importa a Kubernetes.

Emití credenciales de vida corta y correctamente acotadas a través de la API de CSR en lugar de firmarlas a mano con `ca.key`:

```yaml
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: oncall-alice-2026-08-03
spec:
  request: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURSBSRVFVRVNU...   # base64 of the PEM CSR
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 3600          # 1 hour — honoured by kube-controller-manager
  usages:
  - client auth
```

```bash
$ openssl genrsa -out alice.key 3072
$ openssl req -new -key alice.key -out alice.csr \
    -subj "/CN=alice/O=platform-oncall"

$ kubectl create -f alice-csr.yaml
certificatesigningrequest.certificates.k8s.io/oncall-alice-2026-08-03 created

$ kubectl get csr oncall-alice-2026-08-03
NAME                      AGE   SIGNERNAME                            REQUESTOR           REQUESTEDDURATION   CONDITION
oncall-alice-2026-08-03   4s    kubernetes.io/kube-apiserver-client   kubernetes-admin    3600s               Pending

$ kubectl certificate approve oncall-alice-2026-08-03
certificatesigningrequest.certificates.k8s.io/oncall-alice-2026-08-03 approved

$ kubectl get csr oncall-alice-2026-08-03 -o jsonpath='{.status.certificate}' | base64 -d > alice.crt
$ openssl x509 -in alice.crt -noout -subject -dates
subject=O=platform-oncall, CN=alice
notBefore=Aug  3 11:22:00 2026 GMT
notAfter=Aug  3 12:22:00 2026 GMT
```

Como el certificado no se puede revocar, los *únicos* controles significativos son (a) un `expirationSeconds` corto, y (b) no emitir jamás `O=system:masters`. Vigilá la expiración de certificados de la flota como un SLI de primer nivel:

```bash
$ kubectl get --raw /metrics | grep apiserver_client_certificate_expiration_seconds_bucket | tail -4
apiserver_client_certificate_expiration_seconds_bucket{le="21600"} 3
apiserver_client_certificate_expiration_seconds_bucket{le="43200"} 3
apiserver_client_certificate_expiration_seconds_bucket{le="86400"} 41
apiserver_client_certificate_expiration_seconds_bucket{le="+Inf"} 44

$ sudo kubeadm certs check-expiration
CERTIFICATE                EXPIRES                  RESIDUAL TIME   EXTERNALLY MANAGED
admin.conf                 Jul 20, 2027 09:19 UTC   351d            no
apiserver                  Jul 20, 2027 09:19 UTC   351d            no
apiserver-kubelet-client   Jul 20, 2027 09:19 UTC   351d            no
super-admin.conf           Jul 20, 2027 09:19 UTC   351d            no
```

---

## 5. Barrera 3 — Autorización

### 5.1 Modos de autorización y semántica de la cadena

| Modo | ¿Devuelve Deny? | Alcance | Uso |
|---|---|---|---|
| `Node` | Sí (para identidades de kubelet fuera de alcance) | Restringe `system:nodes` a los objetos vinculados a ese nodo | **Obligatorio** |
| `RBAC` | No — solo Allow o NoOpinion | Roles namespaced y de clúster | **Obligatorio** |
| `ABAC` | Sí | Archivo de política estático, sin actualizaciones en vivo | ❌ Heredado, hay que reiniciar para cambiarlo |
| `Webhook` | Sí (`Deny`) o NoOpinion | Motor de políticas externo | Denegación por política, aislamiento de inquilinos |
| `AlwaysAllow` | n/a | Todo | ❌ Catastrófico |
| `AlwaysDeny` | Sí | Nada | Solo para pruebas |

Como RBAC **no puede denegar**, la regla de ordenamiento es decisiva:

- `Node,RBAC,Webhook` → el webhook solo ve peticiones que RBAC dejó como NoOpinion. Puede otorgar, pero **nunca** puede revocar una concesión de RBAC.
- `Webhook,Node,RBAC` → el webhook puede emitir un `Deny` autoritativo que termina la cadena. Ese es el orden correcto para compuertas de cumplimiento ("nadie toca el namespace `prod-payments` fuera de una ventana de cambios").

El costo es la disponibilidad: ahora cada petición espera al webhook. Usá `matchConditions` para acotarlo y `authorizedTTL`/`unauthorizedTTL` para cachear.

### 5.2 Configuración estructurada de autorización

```yaml
# /etc/kubernetes/authz/authorization.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AuthorizationConfiguration
authorizers:

# 1. Authoritative deny gate — evaluated FIRST so it can override RBAC.
#    matchConditions keep the blast radius (and the latency) small.
- type: Webhook
  name: change-window-guard
  webhook:
    connectionInfo:
      type: KubeConfigFile
      kubeConfigFile: /etc/kubernetes/authz/change-window-guard.kubeconfig
    subjectAccessReviewVersion: v1
    matchConditionSubjectAccessReviewVersion: v1
    authorizedTTL: 10s
    unauthorizedTTL: 10s
    timeout: 3s
    # Fail CLOSED. If the guard is down, mutations to the protected
    # namespaces are refused rather than silently permitted.
    failurePolicy: Deny
    matchConditions:
    # Only consult the webhook for writes into protected namespaces.
    - expression: >-
        has(request.resourceAttributes) &&
        request.resourceAttributes.namespace in ['prod-payments','prod-identity'] &&
        request.resourceAttributes.verb in ['create','update','patch','delete','deletecollection']
    # Never gate the control plane itself — this would deadlock the cluster.
    - expression: >-
        !request.user.username.startsWith('system:') &&
        !('system:nodes' in request.user.groups)

# 2. Node authorizer — kubelets may only read objects scheduled to them.
- type: Node
  name: node

# 3. RBAC — the normal grant path.
- type: RBAC
  name: rbac
```

Conectalo (es mutuamente excluyente con `--authorization-mode`):

```bash
$ sudo sed -i 's|--authorization-mode=Node,RBAC|--authorization-config=/etc/kubernetes/authz/authorization.yaml|' \
    /etc/kubernetes/manifests/kube-apiserver.yaml
```

`--authorization-config` se recarga en caliente. Confirmalo:

```bash
$ kubectl get --raw /metrics | grep apiserver_authorization_config_controller_automatic_reloads_total
apiserver_authorization_config_controller_automatic_reloads_total{apiserver_id_hash="sha256:9c1f...",status="success"} 3

$ kubectl get --raw /metrics | grep apiserver_authorization_decisions_total
apiserver_authorization_decisions_total{decision="allowed",type="RBAC"} 918447
apiserver_authorization_decisions_total{decision="denied",type="Webhook"} 12
apiserver_authorization_decisions_total{decision="no-opinion",type="Node"} 918459
```

> **Fallar cerrado es una decisión real de disponibilidad.** `failurePolicy: Deny` en un webhook de autorización significa que una caída de tu servicio de políticas se convierte en una caída de las escrituras a los namespaces protegidos. Ese suele ser el trade correcto para `prod-payments` y el incorrecto para una condición de coincidencia a nivel de todo el clúster. Acotá las `matchConditions` de forma estrecha *porque* elegiste `Deny`.

### 5.3 `system:masters` — la identidad que no se puede gobernar

`system:masters` está vinculado a `cluster-admin` por un `ClusterRoleBinding` de bootstrap que el API server **vuelve a crear en cada arranque**:

```bash
$ kubectl get clusterrolebinding cluster-admin -o yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cluster-admin
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"    # ← self-healing
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: system:masters
```

Consecuencias que hay que internalizar:

- Borrar este binding no persiste a menos que antes pongas `rbac.authorization.kubernetes.io/autoupdate: "false"`. Hacerlo es una forma documentada de dejarte afuera de manera permanente.
- `system:masters` también coincide con el flow schema `exempt` de APF, así que evita la limitación de prioridad y equidad.
- Un certificado que lleva `O=system:masters` es cluster-admin **para siempre**, sin más vía de revocación que rotar la CA.

**kubeadm ≥ 1.29 separó esto deliberadamente.** Aprendé la diferencia de memoria:

```bash
$ sudo grep -A2 'client-certificate-data' /etc/kubernetes/admin.conf >/dev/null; \
  sudo kubectl --kubeconfig /etc/kubernetes/admin.conf auth whoami
ATTRIBUTE   VALUE
Username    kubernetes-admin
Groups      [kubeadm:cluster-admins system:authenticated]

$ sudo kubectl --kubeconfig /etc/kubernetes/super-admin.conf auth whoami
ATTRIBUTE   VALUE
Username    kubernetes-super-admin
Groups      [system:masters system:authenticated]
```

| Archivo | Identidad | Camino al poder | Manejo |
|---|---|---|---|
| `admin.conf` | `CN=kubernetes-admin`, `O=kubeadm:cluster-admins` | `ClusterRoleBinding kubeadm:cluster-admins` común → `cluster-admin` — **revocable, auditable, visible para RBAC** | Administración del día a día |
| `super-admin.conf` | `CN=kubernetes-super-admin`, `O=system:masters` | Binding de bootstrap hardcodeado — evita APF, irrevocable | **Quitarlo del nodo**, guardarlo en una bóveda, solo break-glass |

```bash
# Break-glass hygiene on every control-plane node
$ sudo install -m 0600 /etc/kubernetes/super-admin.conf /root/breakglass/super-admin.conf
$ sudo shred -u /etc/kubernetes/super-admin.conf
$ ls -l /etc/kubernetes/*.conf
-rw------- 1 root root 5654 Aug  3 11:31 /etc/kubernetes/admin.conf
-rw------- 1 root root 5666 Aug  3 11:31 /etc/kubernetes/controller-manager.conf
-rw------- 1 root root 5610 Aug  3 11:31 /etc/kubernetes/kubelet.conf
-rw------- 1 root root 5614 Aug  3 11:31 /etc/kubernetes/scheduler.conf
```

### 5.4 Verbos que equivalen a cluster-admin

La revisión de RBAC es un tema aparte (3.2), pero para *restringir el acceso a la API* hay que reconocer las concesiones que silenciosamente devuelven control total:

| Concesión | Por qué es cluster-admin | Mitigación |
|---|---|---|
| `create pods` en cualquier namespace | Montar `hostPath: /`, `privileged: true`, leer `ca.key` | Pod Security Admission `restricted`; namespaces separados |
| `create pods/exec`, `pods/attach` | Entrar a cualquier contenedor, robar su token de SA | Otorgar por namespace, auditar en `RequestResponse` |
| `get/list secrets` | Lee todos los tokens de SA del alcance | Nunca a nivel de clúster; usar `resourceNames` |
| `escalate` sobre roles | Crear un rol con permisos que no tenés | No otorgarlo nunca |
| `bind` sobre clusterrolebindings | Vincularte a vos mismo a `cluster-admin` | No otorgarlo nunca |
| `impersonate` usuarios/grupos | Asumir `system:masters` | Restringir con `resourceNames` |
| `get nodes/proxy` | API del kubelet directa → exec en cualquier pod | No otorgarlo nunca a cargas de trabajo |
| `create` sobre `certificatesigningrequests/approval` + un signer | Acuñar certificados de cliente arbitrarios | Identidad aprobadora separada |
| `update` sobre `validatingwebhookconfigurations` | Desactivar la compuerta de admisión | Restringir al equipo de plataforma |
| `*` sobre `*` | Evidente | — |

Imponé lo peor de esto con una `ValidatingAdmissionPolicy`, que corre en la barrera 4 y por lo tanto atrapa incluso una mala configuración de RBAC:

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: forbid-privileged-subject-bindings
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
    - apiGroups:   ["rbac.authorization.k8s.io"]
      apiVersions: ["v1"]
      operations:  ["CREATE", "UPDATE"]
      resources:   ["clusterrolebindings", "rolebindings"]
  variables:
  - name: subjects
    expression: "has(object.subjects) ? object.subjects : []"
  validations:
  - expression: >-
      !variables.subjects.exists(s,
        s.name in ['system:anonymous','system:unauthenticated',
                   'system:authenticated','system:serviceaccounts'])
    message: "binding roles to anonymous, unauthenticated, all-authenticated or all-serviceaccounts subjects is forbidden"
    reason: Forbidden
  - expression: >-
      object.roleRef.name != 'cluster-admin' ||
      !variables.subjects.exists(s, s.kind == 'ServiceAccount')
    message: "ServiceAccounts must not be bound to cluster-admin"
    reason: Forbidden
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: forbid-privileged-subject-bindings
spec:
  policyName: forbid-privileged-subject-bindings
  validationActions: [Deny, Audit]
  matchResources:
    namespaceSelector: {}
```

```bash
$ kubectl apply -f forbid-privileged-subject-bindings.yaml
validatingadmissionpolicy.admissionregistration.k8s.io/forbid-privileged-subject-bindings created
validatingadmissionpolicybinding.admissionregistration.k8s.io/forbid-privileged-subject-bindings created

$ kubectl create clusterrolebinding oops --clusterrole=cluster-admin --group=system:unauthenticated
error: failed to create clusterrolebinding: clusterrolebindings.rbac.authorization.k8s.io "oops" is forbidden:
ValidatingAdmissionPolicy 'forbid-privileged-subject-bindings' with binding 'forbid-privileged-subject-bindings'
denied request: binding roles to anonymous, unauthenticated, all-authenticated or all-serviceaccounts subjects is forbidden
```

---

## 6. Restringir la superficie de API que una carga de trabajo puede alcanzar

Todo pod que monta un token de ServiceAccount es un cliente de la API. La mayor reducción individual de superficie de ataque de la API es desactivar eso para el ~90 % de las cargas de trabajo que nunca llaman a la API.

### 6.1 Desactivar el automontaje — en los dos niveles

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
  namespace: prod
automountServiceAccountToken: false        # covers every pod using this SA
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: prod
spec:
  replicas: 3
  selector:
    matchLabels: {app: frontend}
  template:
    metadata:
      labels: {app: frontend}
    spec:
      serviceAccountName: frontend
      automountServiceAccountToken: false  # pod-level; overrides the SA setting
      containers:
      - name: web
        image: registry.example.com/frontend@sha256:7f83b1657ff1fc53b92dc18148a1d65dfc2d4b1fa3d677284addd200126d9069
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          runAsNonRoot: true
          runAsUser: 10001
          capabilities: {drop: ["ALL"]}
          seccompProfile: {type: RuntimeDefault}
```

Precedencia: **el `automountServiceAccountToken` a nivel de pod siempre gana** sobre el ajuste a nivel de ServiceAccount.

```bash
$ kubectl exec -n prod deploy/frontend -- ls /var/run/secrets/kubernetes.io/serviceaccount
ls: cannot access '/var/run/secrets/kubernetes.io/serviceaccount': No such file or directory
command terminated with exit code 2
```

Auditoría a nivel de clúster de qué sigue montando un token:

```bash
$ kubectl get pods -A -o json | jq -r '
    .items[]
    | select((.spec.automountServiceAccountToken // true) == true)
    | "\(.metadata.namespace)\t\(.metadata.name)\t\(.spec.serviceAccountName)"' \
  | sort | uniq -c | sort -rn | head
     18	prod	api-7d9f8c6b5-*	api
      6	kube-system	kube-proxy-*	kube-proxy
      3	monitoring	prometheus-0	prometheus
```

### 6.2 Tokens vinculados, acotados por audiencia y de rotación automática

Para los pods que *sí* necesitan la API, el token proyectado lleva claims de vinculación que vuelven mucho menos útil su robo:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: api-client
  namespace: prod
spec:
  serviceAccountName: api
  automountServiceAccountToken: false      # suppress the default mount…
  containers:
  - name: app
    image: registry.example.com/api:1.9.2
    volumeMounts:
    - name: kube-api-token
      mountPath: /var/run/secrets/tokens
      readOnly: true
    - name: vault-token
      mountPath: /var/run/secrets/vault
      readOnly: true
  volumes:
  # …and project exactly the tokens this workload needs, with tight audiences.
  - name: kube-api-token
    projected:
      defaultMode: 0400
      sources:
      - serviceAccountToken:
          path: token
          audience: https://kubernetes.default.svc.cluster.local
          expirationSeconds: 3600
      - configMap:
          name: kube-root-ca.crt
          items: [{key: ca.crt, path: ca.crt}]
      - downwardAPI:
          items: [{path: namespace, fieldRef: {fieldPath: metadata.namespace}}]
  - name: vault-token
    projected:
      defaultMode: 0400
      sources:
      - serviceAccountToken:
          path: token
          audience: https://vault.example.com      # useless against kube-apiserver
          expirationSeconds: 600
```

Inspeccioná los claims — esto es lo que "vinculado" significa concretamente:

```bash
$ kubectl exec -n prod api-client -- cat /var/run/secrets/tokens/token \
  | cut -d. -f2 | base64 -d 2>/dev/null | jq
{
  "aud": ["https://kubernetes.default.svc.cluster.local"],
  "exp": 1785311820,
  "iat": 1785308220,
  "iss": "https://kubernetes.default.svc.cluster.local",
  "jti": "0f4a9c72-2d3e-4a6b-9f10-5c8e1a7b3d42",
  "kubernetes.io": {
    "namespace": "prod",
    "node": {"name": "worker-2", "uid": "b1e7f0c4-9a2d-4f31-8c55-0d6e2a91f7bb"},
    "pod":  {"name": "api-client", "uid": "3c9d1a55-77e4-4a08-9b2f-1e6c4d0a8f19"},
    "serviceaccount": {"name": "api", "uid": "8a5b2c1e-4f7d-49a3-b0c6-2e91d3f4a7c8"}
  },
  "nbf": 1785308220,
  "sub": "system:serviceaccount:prod:api"
}
```

Al borrar el pod, el token deja de funcionar de inmediato — el claim `pod` se valida contra el estado en vivo. Compará eso con un token heredado basado en Secret, que es una credencial al portador sin ninguna expiración.

Tokens ad-hoc y acotados en el tiempo para CI (reemplazan la creación de un Secret de larga vida):

```bash
$ kubectl create token ci-deployer -n ci --audience=https://kubernetes.default.svc.cluster.local --duration=15m
eyJhbGciOiJSUzI1NiIsImtpZCI6Ilo0RzRSNW1SVndoVWxmNXNBUlNoM0JJeEtGWk1uZ0IifQ.eyJhdWQiOl...

$ kubectl create token ci-deployer -n ci --duration=15m \
  | cut -d. -f2 | base64 -d 2>/dev/null | jq -r '.exp | tostring'
1785309150
```

Cacería de tokens heredados todavía en uso:

```bash
$ kubectl get --raw /metrics | grep -E 'serviceaccount_(legacy_token_uses|stale_tokens|legacy_tokens_used)_total'
serviceaccount_legacy_tokens_used_total 0
serviceaccount_stale_tokens_total 0

$ kubectl get secrets -A --field-selector type=kubernetes.io/service-account-token \
    -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,LASTUSED:.metadata.labels.kubernetes\.io/legacy-token-last-used'
NS            NAME                    LASTUSED
legacy-apps   jenkins-token-4x9qk     2026-07-28
```

Un `serviceaccount_legacy_tokens_used_total` distinto de cero significa que algo en el clúster todavía presenta un token de estilo previo a 1.24. Encontralo, migralo, borrá el Secret. Con `--service-account-lookup=true` (el valor por defecto), borrar el Secret revoca el token de inmediato.

---

## 7. Barrera 4 — Limitar el caudal del propio API server

Restringir el *acceso* también significa restringir el *volumen*. Un único controlador que se comporta mal haciendo `LIST pods` a nivel de clúster en un bucle caliente va a apagar el plano de control con la misma eficacia que un atacante. API Priority and Fairness te da un límite de aislamiento por clase de cliente.

```yaml
apiVersion: flowcontrol.apiserver.k8s.io/v1
kind: PriorityLevelConfiguration
metadata:
  name: restrict-unauthenticated
spec:
  type: Limited
  limited:
    nominalConcurrencyShares: 1     # a sliver of total concurrency
    lendablePercent: 100            # lend it all away when idle
    limitResponse:
      type: Reject                  # 429 immediately; never queue
---
apiVersion: flowcontrol.apiserver.k8s.io/v1
kind: FlowSchema
metadata:
  name: restrict-unauthenticated
spec:
  matchingPrecedence: 100           # lower number = evaluated earlier
  priorityLevelConfiguration:
    name: restrict-unauthenticated
  distinguisherMethod:
    type: ByUser
  rules:
  - subjects:
    - kind: Group
      group:
        name: system:unauthenticated
    resourceRules:
    - verbs: ["*"]
      apiGroups: ["*"]
      resources: ["*"]
      clusterScope: true
      namespaces: ["*"]
    nonResourceRules:
    - verbs: ["*"]
      nonResourceURLs: ["*"]
```

```bash
$ kubectl apply -f apf-unauthenticated.yaml
prioritylevelconfiguration.flowcontrol.apiserver.k8s.io/restrict-unauthenticated created
flowschema.flowcontrol.apiserver.k8s.io/restrict-unauthenticated created

$ kubectl get flowschemas.flowcontrol.apiserver.k8s.io --sort-by=.spec.matchingPrecedence | head
NAME                            PRIORITYLEVEL              MATCHINGPRECEDENCE   DISTINGUISHERMETHOD   AGE
exempt                          exempt                     1                    <none>                40d
probes                          exempt                     2                    <none>                40d
system-leader-election          leader-election            100                  ByUser                40d
restrict-unauthenticated        restrict-unauthenticated   100                  ByUser                12s
workload-leader-election        leader-election            200                  ByUser                40d

$ kubectl get --raw /metrics | grep apiserver_flowcontrol_rejected_requests_total
apiserver_flowcontrol_rejected_requests_total{flow_schema="restrict-unauthenticated",priority_level="restrict-unauthenticated",reason="concurrency-limit"} 1183
```

Recordá: `system:masters` coincide con el schema integrado `exempt`, lo que es una razón más para mantener ese grupo vacío en operación normal.

---

## 8. Auditoría — demostrar que la restricción se sostiene

Una restricción que no podés observar es una restricción que no podés defender. Esta política está afinada para mantener el volumen manejable a la vez que captura todo lo relevante para el acceso a la API:

```yaml
# /etc/kubernetes/audit/policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
- RequestReceived

rules:
# 1. Drop the highest-volume, lowest-value traffic first.
- level: None
  nonResourceURLs:
  - /healthz*
  - /livez*
  - /readyz*
  - /version*
  - /metrics
  - /openapi/*
- level: None
  users: ["system:kube-scheduler", "system:kube-controller-manager"]
  verbs: ["get", "list", "watch"]
- level: None
  userGroups: ["system:nodes"]
  verbs: ["get", "watch"]

# 2. Anything unauthenticated is a security event — capture the full exchange.
- level: RequestResponse
  users: ["system:anonymous"]
- level: RequestResponse
  userGroups: ["system:unauthenticated"]

# 3. Break-glass usage — full bodies, always.
- level: RequestResponse
  userGroups: ["system:masters"]

# 4. Impersonation and RBAC mutation — the escalation primitives.
- level: RequestResponse
  resources:
  - group: "rbac.authorization.k8s.io"
    resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
  - group: "certificates.k8s.io"
    resources: ["certificatesigningrequests", "certificatesigningrequests/approval"]
  - group: "admissionregistration.k8s.io"
    resources: ["validatingwebhookconfigurations", "mutatingwebhookconfigurations",
                "validatingadmissionpolicies", "validatingadmissionpolicybindings"]

# 5. Credential access — metadata only, never the payload.
- level: Metadata
  resources:
  - group: ""
    resources: ["secrets", "configmaps", "serviceaccounts/token"]

# 6. Interactive access to running containers.
- level: RequestResponse
  resources:
  - group: ""
    resources: ["pods/exec", "pods/attach", "pods/portforward", "nodes/proxy"]

# 7. Everything else: who did what to which object.
- level: Metadata
```

> `level: Metadata` sobre los Secrets es deliberado. `RequestResponse` sobre un Secret escribe el valor en texto plano dentro del log de auditoría, convirtiendo tu SIEM en un almacén de credenciales.

Consultarlo:

```bash
$ sudo jq -c 'select(.user.username=="system:anonymous")
              | {t:.requestReceivedTimestamp, ip:.sourceIPs[0], uri:.requestURI, code:.responseStatus.code}' \
     /var/log/kubernetes/audit/audit.log | tail -3
{"t":"2026-08-03T11:47:02.114Z","ip":"198.51.100.44","uri":"/apis/rbac.authorization.k8s.io/v1/clusterrolebindings","code":403}
{"t":"2026-08-03T11:47:02.331Z","ip":"198.51.100.44","uri":"/api/v1/secrets","code":403}
{"t":"2026-08-03T11:47:02.502Z","ip":"198.51.100.44","uri":"/api/v1/namespaces/kube-system/pods","code":403}
```

Tres intentos de enumeración desde una misma IP externa en 400 ms — eso es un escáner, y te dice que la barrera 1 está abierta cuando no debería estarlo.

---

## 9. Guía de verificación

Ejecutá esto en orden. Cada paso tiene una salida esperada definida; cualquier otra cosa es un hallazgo.

**1 — ¿Quién soy realmente?**

```bash
$ kubectl auth whoami
ATTRIBUTE   VALUE
Username    kubernetes-admin
Groups      [kubeadm:cluster-admins system:authenticated]
```
*Esperado:* nada de `system:masters` en la operación del día a día.

**2 — ¿Qué puede hacer un llamador no autenticado?**

```bash
$ kubectl auth can-i --list --as=system:anonymous
$ kubectl auth can-i --list --as-group=system:unauthenticated --as=system:anonymous
```
*Esperado:* únicamente las URLs no-recurso de salud/versión. **Ninguna fila de recursos.**

**3 — ¿Hay algún binding a sujetos no autenticados o a todos los autenticados?**

```bash
$ kubectl get clusterrolebindings,rolebindings -A -o json | jq -r '
    .items[]
    | select(.subjects != null)
    | select(any(.subjects[];
        .name == "system:anonymous" or
        .name == "system:unauthenticated" or
        .name == "system:authenticated" or
        .name == "system:serviceaccounts"))
    | "\(.kind)/\(.metadata.namespace // "-")/\(.metadata.name) -> \(.roleRef.kind)/\(.roleRef.name)"'
ClusterRoleBinding/-/system:public-info-viewer -> ClusterRole/system:public-info-viewer
ClusterRoleBinding/-/system:basic-user -> ClusterRole/system:basic-user
ClusterRoleBinding/-/system:discovery -> ClusterRole/system:discovery
ClusterRoleBinding/-/system:service-account-issuer-discovery -> ClusterRole/system:service-account-issuer-discovery
```
*Esperado:* solo estas entradas de bootstrap. Cualquier otra cosa es un hallazgo — investigalo antes de hacer nada más de esta lista.

**4 — ¿Quién tiene `cluster-admin`?**

```bash
$ kubectl get clusterrolebindings -o json | jq -r '
    .items[] | select(.roleRef.name=="cluster-admin")
    | .metadata.name as $n | (.subjects // [])[]
    | "\($n)\t\(.kind)\t\(.name)"'
cluster-admin	Group	system:masters
kubeadm:cluster-admins	Group	kubeadm:cluster-admins
```
*Esperado:* una lista corta y completamente explicada. Cada `ServiceAccount` que aparezca acá es un hallazgo.

**5 — Comportamiento anónimo de punta a punta**

```bash
$ API=https://10.0.10.11:6443
$ for p in /livez /readyz /version /api/v1/nodes /apis; do
    printf '%-16s %s\n' "$p" "$(curl -sk -o /dev/null -w '%{http_code}' $API$p)"
  done
/livez           200
/readyz          200
/version         401
/api/v1/nodes    401
/apis            401
```

**6 — Flags efectivos del API server**

```bash
$ kubectl -n kube-system get pod -l component=kube-apiserver \
    -o jsonpath='{.items[0].spec.containers[0].command}' | tr ',' '\n' | grep -E 'anonymous|authorization|authentication|profiling|insecure|service-account-lookup'
"--authentication-config=/etc/kubernetes/authn/authentication.yaml"
"--authorization-config=/etc/kubernetes/authz/authorization.yaml"
"--profiling=false"
"--service-account-lookup=true"
```
*Esperado:* nada de `--insecure-port`, nada de `--anonymous-auth` junto a un archivo de configuración, nada de `AlwaysAllow`, nada de `--token-auth-file`.

**7 — Alcanzabilidad de la suplantación**

```bash
$ kubectl auth can-i impersonate users --all-namespaces
no
$ kubectl auth can-i --list | grep -E 'escalate|bind|impersonate'
```
*Esperado:* `no` para cualquier identidad que no sea una cuenta break-glass del equipo de plataforma.

**8 — Chequeo CIS automatizado**

```bash
$ kube-bench run --targets master --check 1.2.1,1.2.2,1.2.5,1.2.6,1.2.7 2>/dev/null | grep -E '^\[(PASS|FAIL|WARN)\]'
[PASS] 1.2.1 Ensure that the --anonymous-auth argument is set to false
[PASS] 1.2.2 Ensure that the --token-auth-file parameter is not set
[PASS] 1.2.5 Ensure that the --kubelet-certificate-authority argument is set as appropriate
[PASS] 1.2.6 Ensure that the --authorization-mode argument is not set to AlwaysAllow
[PASS] 1.2.7 Ensure that the --authorization-mode argument includes Node
```

---

## 10. Diagnóstico de fallos

| Síntoma | Causa más probable | Cómo confirmarlo | Solución |
|---|---|---|---|
| API server en `CrashLoopBackOff`, logs del kubelet con `Probe failed … statuscode: 401` | `--anonymous-auth=false` con las sondas por defecto | `journalctl -u kubelet \| grep "Probe failed"` | Usar `AuthenticationConfiguration.anonymous.conditions` para `/livez`, `/readyz`, `/healthz` |
| El contenedor del API server termina al instante, sin logs | Un flag referencia un archivo sin volumen/montaje `hostPath` | `crictl logs <id>` → `open /etc/…: no such file or directory` | Agregar las entradas correspondientes de `volumes` + `volumeMounts` |
| `kube-apiserver` se niega a arrancar: *"--anonymous-auth and anonymous field in AuthenticationConfiguration are mutually exclusive"* | Ambos configurados | stderr del apiserver vía `crictl logs` | Quitar el flag de la línea de comandos |
| `Unable to connect to the server: EOF` después de editar un manifiesto | El static pod nunca quedó listo | `crictl ps -a --name kube-apiserver` | `mv` del manifiesto fuera de `/etc/kubernetes/manifests`, corregir, `mv` de vuelta |
| Todo devuelve `401`, incluidos kubeconfigs válidos | `--client-ca-file` equivocado, o certificado de cliente expirado | `openssl x509 -in ~/.kube/client.crt -noout -dates`; `kubeadm certs check-expiration` | Renovar el certificado / restaurar la CA correcta |
| Una identidad válida recibe `403` en todo | La cadena de autorizadores perdió `RBAC`, o el archivo de configuración reemplazó el modo | `kubectl auth can-i --list`; inspeccionar `--authorization-config` | Asegurar que `RBAC` esté presente en `authorizers:` |
| `403` esporádicos bajo carga, limpio con tráfico bajo | Webhook de autorización con `failurePolicy: Deny` haciendo timeout | `apiserver_authorization_webhook_duration_seconds`, logs del webhook | Ampliar `timeout`, subir `authorizedTTL`, acotar `matchConditions` |
| `429 Too Many Requests` para un controlador específico | Nivel de prioridad de APF saturado | `apiserver_flowcontrol_rejected_requests_total{flow_schema=…}` | `FlowSchema` dedicado, o corregir el patrón de watch/list del cliente |
| El pod recibe `401` al llamar a la API después de ~1 h | Cacheó el token proyectado al arrancar; el token rotó | Comparar el claim `exp` con la hora actual | Releer el archivo de token en cada petición (todas las bibliotecas cliente oficiales lo hacen) |
| El pod recibe `401` de inmediato | Token acuñado para una `audience` distinta | Decodificar el JWT, comparar `aud` con `--api-audiences` | Corregir la `audience` en el volumen proyectado |
| Un token de SA funciona desde fuera del clúster | Token heredado basado en Secret (sin claims de vinculación) | `kubectl get secrets -A --field-selector type=kubernetes.io/service-account-token` | Borrar el Secret; migrar a TokenRequest |
| Borraste un `ClusterRoleBinding` y reaparece | `rbac.authorization.kubernetes.io/autoupdate: "true"` | `kubectl get clusterrolebinding X -o yaml` | Poner la anotación en `"false"` primero — y entender que quizás estés eliminando tu propio acceso |
| `kubectl` funciona desde cualquier lugar de Internet | Barrera 1 abierta | `nc -vz <public-ip> 6443` desde un host no confiable | Redes autorizadas / endpoint privado / firewall |

### Recuperación de emergencia cuando el API server no arranca

`kubectl` no está disponible, así que hay que trabajar a nivel del runtime de contenedores en el nodo del plano de control:

```bash
$ sudo crictl ps -a --name kube-apiserver --latest
CONTAINER      IMAGE          CREATED          STATE    NAME             ATTEMPT   POD ID
7b3e1a9c4d02   c3ff0a2e2b1f   12 seconds ago   Exited   kube-apiserver   9         e21f...

$ sudo crictl logs 7b3e1a9c4d02 2>&1 | tail -5
E0803 12:03:41.229118       1 run.go:74] "command failed" err="error while parsing file: \
open /etc/kubernetes/authz/authorization.yaml: no such file or directory"

# Stop the crash loop, restore, restart
$ sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.broken
$ sudo cp /root/backups/kube-apiserver.yaml.2026-08-03 /etc/kubernetes/manifests/kube-apiserver.yaml
$ sudo systemctl restart kubelet
$ until sudo crictl ps --name kube-apiserver -q | grep -q .; do sleep 2; done
$ kubectl get --raw /readyz?verbose | tail -3
[+]shutdown ok
healthz check passed
```

> **Disciplina que se paga sola:** `cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/backups/kube-apiserver.yaml.$(date +%F)` antes de *cada* edición. Editar en el lugar sin respaldo es la forma en que un cambio de endurecimiento de cinco minutos se convierte en una caída de dos horas.

---

## 11. Referencia rápida para el día del examen

```bash
# Identity
kubectl auth whoami
kubectl auth can-i --list --as=system:anonymous
kubectl auth can-i create pods -n prod --as=system:serviceaccount:prod:api

# Anonymous probe
curl -sk -o /dev/null -w '%{http_code}\n' https://<cp>:6443/api/v1/nodes    # want 401

# API server flags (control-plane node)
sudo grep -nE 'anonymous|authorization|authentication|profiling|token-auth' \
  /etc/kubernetes/manifests/kube-apiserver.yaml

# Dangerous bindings
kubectl get clusterrolebindings -o json | jq -r \
  '.items[] | select(.roleRef.name=="cluster-admin") | .metadata.name'

# Token hygiene
kubectl get sa -A -o json | jq -r \
  '.items[] | select((.automountServiceAccountToken // true)==true)
   | "\(.metadata.namespace)/\(.metadata.name)"'
kubectl create token <sa> -n <ns> --duration=10m

# Certificates
sudo kubeadm certs check-expiration
openssl x509 -in <cert> -noout -subject -dates

# When kubectl is dead
sudo crictl ps -a --name kube-apiserver
sudo crictl logs <container-id> 2>&1 | tail -20
```

**Las cinco afirmaciones que hay que tener memorizadas:**

1. `NetworkPolicy` no puede proteger al API server — está en hostNetwork, fuera del dataplane del CNI.
2. La autenticación es "gana el primero que coincide" entre autenticadores; la autorización es "gana el primer `Allow` o `Deny`" entre autorizadores, y **RBAC nunca puede denegar**.
3. `--anonymous-auth=false` rompe las sondas de salud de kubeadm; `AuthenticationConfiguration.anonymous.conditions` es la corrección quirúrgica, y el flag y el campo de configuración son mutuamente excluyentes.
4. Los certificados de cliente x509 son irrevocables — las vidas cortas son el único control, y `O=system:masters` es una puerta trasera permanente y exenta de APF.
5. El `automountServiceAccountToken` a nivel de pod tiene prioridad sobre el ajuste del ServiceAccount; los tokens proyectados están vinculados a namespace + SA + pod + nodo y expiran en una hora.

---

## Referencias

- Controlling Access to the Kubernetes API — https://kubernetes.io/docs/concepts/security/controlling-access/
- Authenticating — https://kubernetes.io/docs/reference/access-authn-authz/authentication/
- Authorization — https://kubernetes.io/docs/reference/access-authn-authz/authorization/
- Using RBAC Authorization — https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Using Node Authorization — https://kubernetes.io/docs/reference/access-authn-authz/node/
- Webhook Mode — https://kubernetes.io/docs/reference/access-authn-authz/webhook/
- Certificate Signing Requests — https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/
- Managing Service Accounts — https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/
- Service Accounts (concepts) — https://kubernetes.io/docs/concepts/security/service-accounts/
- Admission Control in Kubernetes — https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- Validating Admission Policy — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- API Priority and Fairness — https://kubernetes.io/docs/concepts/cluster-administration/flow-control/
- Auditing — https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- kube-apiserver command-line reference — https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
- kube-apiserver configuration API (`apiserver.config.k8s.io`) — https://kubernetes.io/docs/reference/config-api/apiserver-config.v1/
- Audit configuration API (`audit.k8s.io/v1`) — https://kubernetes.io/docs/reference/config-api/apiserver-audit.v1/
- kubeadm configuration API v1beta4 — https://kubernetes.io/docs/reference/config-api/kubeadm-config.v1beta4/
- Certificate Management with kubeadm — https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/
- PKI certificates and requirements — https://kubernetes.io/docs/setup/best-practices/certificates/
- Securing a Cluster — https://kubernetes.io/docs/tasks/administer-cluster/securing-a-cluster/
- Ports and Protocols — https://kubernetes.io/docs/reference/networking/ports-and-protocols/
- CKS Curriculum v1.34 (CNCF) — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- CIS Kubernetes Benchmark — https://www.cisecurity.org/benchmark/kubernetes
- kube-bench — https://github.com/aquasecurity/kube-bench