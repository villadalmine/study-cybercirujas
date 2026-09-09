# 5.1 — Describir conceptos fundamentales de seguridad en la nube

**Certificación:** Google Cloud Digital Leader (guía del examen 2026-08-12)
**Dominio 5:** Confianza y seguridad con Google Cloud — **Peso del objetivo: 9.0**
**Perfil de profundidad:** Principal Platform Architect / Senior SRE

---

## 1. Motivación: el problema arquitectónico que este objetivo realmente resuelve

### 1.1 El modo de fallo que da origen al objetivo

Todo incidente de producción clasificado como "brecha de seguridad" en un patrimonio de nube pública se resuelve, en el post-mortem, en uno de cuatro defectos *arquitectónicos* — no en un zero-day:

| Clase de defecto | Manifestación concreta | Por qué no aplica el control clásico on-prem |
|---|---|---|
| **Propiedad ambigua** | Nadie parcheó el SO invitado en una flota de VMs `n2-standard-8` porque el equipo de plataforma asumió que "la nube lo parchea" | El firewall perimetral era el límite de propiedad on-prem; en la nube el límite se movió *hacia adentro* del stack de servicio y es distinto por modelo de servicio |
| **Proliferación de identidades** | Un JSON de clave de service account subido a un repo en 2023 sigue siendo válido en 2026 y tiene `roles/editor` a nivel de proyecto | On-prem, el radio de impacto de una credencial estaba acotado por la alcanzabilidad de red; en la nube, una API key es alcanzable desde cualquier IP del planeta |
| **Confianza implícita en la red** | Un atacante que aterriza en una VM de una VPC puede llegar a BigQuery y Cloud Storage usando la service account adjunta a la VM, desde dentro de la subred "confiable" | El axioma `10.0.0.0/8` "interno = confiable" es falso cuando el plano de datos es `*.googleapis.com`, que *no* está en tu red |
| **Egreso de datos sin límites** | Un principal comprometido o simplemente descuidado copia un dataset de BigQuery de 4 TB a un bucket de un proyecto personal. Toda verificación de IAM pasa — el principal genuinamente tenía `bigquery.dataViewer` | IAM responde "¿puede esta identidad actuar sobre este recurso?" **No** responde "¿puede este dato salir de este límite de confianza?" |

El examen Cloud Digital Leader plantea 5.1 como conceptual. Como Platform Architect deberías leerlo como la *taxonomía de controles* que mapea cada defecto de arriba a un mecanismo específico y verificable de Google Cloud. Ese mapeo es todo el contenido de este tema:

```
Ambiguous ownership   → Shared responsibility model → shared fate
Identity sprawl       → IAM: least privilege, deny policies, WIF, no keys
Implicit network trust→ Zero trust / BeyondCorp, IAP, Context-Aware Access
Unbounded egress      → VPC Service Controls (a control plane IAM cannot express)
```

Más dos ejes transversales que el examen separa explícitamente:

```
Privacy  ≠ Security   → data protection, residency, sovereignty, Access Transparency
Compliance            → attestations, Assured Workloads, auditability
```

### 1.2 Seguridad vs. privacidad — la distinción que evalúa el examen

Los candidatos las confunden rutinariamente. Son ortogonales, y un sistema puede satisfacer una mientras viola la otra.

| Eje | **Seguridad** | **Privacidad** |
|---|---|---|
| Pregunta que responde | *¿Está el dato protegido de acceso, modificación o pérdida no autorizados?* | *¿Se usa el dato solo para los fines que el sujeto de datos y el cliente acordaron?* |
| Actor de amenaza principal | Atacante externo, insider malicioso, ransomware | Uso interno excesivamente amplio, procesamiento no declarado, jurisdicción no autorizada |
| Mecanismos de Google Cloud | IAM, cifrado, VPC-SC, Cloud Armor, Security Command Center | Access Transparency, Access Approval, Key Access Justifications, controles de residencia de datos, Sensitive Data Protection, DPA contractual |
| Cómo se ve el fallo | Exfiltración, defacement, caída | Dato procesado en una región no aprobada; un ingeniero de soporte lee contenido sin un ticket |
| ¿Puede satisfacerse mientras la otra falla? | Sí — datos perfectamente cifrados replicados a una jurisdicción que el cliente prohibió | Sí — el dato nunca sale de la UE, y es legible públicamente |

**Los compromisos declarados de Google** (relevantes para la privacidad, no para la seguridad): los datos del cliente son del cliente; Google no vende datos del cliente; los datos del cliente no se usan para publicidad; y el cifrado en reposo y en tránsito es el comportamiento por defecto, no una opción.

### 1.3 La tríada CIA, reformulada para un plano de control distribuido

| Propiedad | Instrumento on-prem | Instrumento de Google Cloud | SLO / proxy medible |
|---|---|---|---|
| **Confidencialidad** | Segmentación de red, appliance de cifrado de disco | Políticas allow/deny de IAM, AES-256 por defecto en reposo, ALTS en tránsito, CMEK/EKM, VPC-SC, Confidential Computing | % de recursos con bindings IAM públicos = 0; % de buckets con CMEK |
| **Integridad** | Monitoreo de integridad de archivos, RAID | Shielded VM (Measured Boot, vTPM, integrity monitoring), Binary Authorization, versionado de objetos + retention lock, checksums (CRC32C/MD5) en cada objeto de GCS | Hallazgos de integrity monitoring = 0; % de imágenes firmadas por un attestor |
| **Disponibilidad** | HW redundante, UPS | Almacenamiento multi-región/dual-región, MIGs regionales, Cloud Armor + el edge de Google para absorción de DDoS, backups impuestos por org policy | Consumo del error budget; DDoS L3/L4 absorbido en el edge sin impacto en el origen |

---

## 2. El modelo de responsabilidad compartida — y por qué Google lo reformula como *destino compartido*

### 2.1 El límite se mueve con el modelo de servicio

El concepto más evaluado de 5.1. La regla: **cuanto más gestionado es el servicio, mayor parte del stack pertenece a Google — pero el cliente *siempre* es dueño de los datos, las identidades y la política de acceso.**

| Capa | On-prem | **IaaS** (Compute Engine) | **PaaS/CaaS** (GKE Standard, App Engine flex) | **CaaS autopilot / Serverless** (Cloud Run, GKE Autopilot) | **SaaS/Totalmente gestionado** (BigQuery, Cloud Storage, Spanner) |
|---|---|---|---|---|---|
| Contenido / datos | Cliente | Cliente | Cliente | Cliente | Cliente |
| Políticas de acceso (IAM) | Cliente | Cliente | Cliente | Cliente | Cliente |
| Gestión de identidades | Cliente | Cliente | Cliente | Cliente | Cliente (fed. vía Cloud Identity) |
| Uso / configuración | Cliente | Cliente | Cliente | Cliente | Cliente |
| Seguridad de la aplicación web | Cliente | Cliente | Cliente | Cliente | **Google** |
| Despliegue / código de la app | Cliente | Cliente | Cliente | Compartido | **Google** |
| SO invitado, parcheo, imagen | Cliente | **Cliente** | Compartido (imágenes de nodo auto-actualizables) | **Google** | **Google** |
| Seguridad de red (dentro de la VPC) | Cliente | Cliente | Compartido | Compartido | **Google** |
| Hardening de contenedor/runtime | Cliente | Cliente | Compartido | **Google** | **Google** |
| Hipervisor / SO del host | Cliente | **Google** | Google | Google | Google |
| Hardware, firmware (Titan) | Cliente | **Google** | Google | Google | Google |
| Seguridad física del datacenter | Cliente | **Google** | Google | Google | Google |

**Las tres líneas que nunca se mueven, en ningún modelo de servicio:** *tus datos*, *tus identidades*, *tus políticas de acceso*. Una pregunta de CDL que diga "Google asegura X por vos" es casi siempre falsa si X es una de esas tres.

### 2.2 Responsabilidad compartida → destino compartido

La responsabilidad compartida, evaluada honestamente, es un **contrato de asignación de responsabilidad legal**. Le dice al cliente de qué se lo va a culpar; no lo ayuda a tener éxito. La evolución declarada de Google es el **destino compartido** (*shared fate*): el proveedor toma un interés activo en el resultado seguro del cliente.

| Dimensión | Responsabilidad compartida (clásica) | **Destino compartido (el modelo de Google)** |
|---|---|---|
| Postura | "Acá está la línea. Debajo, respondemos nosotros." | "Te ayudamos a aterrizar a salvo por encima de la línea." |
| Artefactos | Matriz de responsabilidades, contrato | **Security foundations blueprint** con opinión, landing zones seguras por defecto, `terraform-google-modules` |
| Valores por defecto | El cliente debe endurecer | Valores seguros por defecto: cifrado en reposo activado por defecto, sin IPs públicas salvo que se pidan, uniform bucket-level access recomendado, Shielded VM activado por defecto en muchas imágenes |
| Barandas (guardrails) | Las construye el cliente | Restricciones de Organization Policy, paquetes de control de Assured Workloads |
| Visibilidad | El cliente construye el SIEM | Security Command Center, Cloud Audit Logs activados por defecto (Admin Activity), Access Transparency |
| Transferencia de riesgo | Ninguna | **Risk Protection Program** — datos de postura (de SCC) compartidos con aseguradoras para tarifar un ciberseguro |

**Consecuencia arquitectónica para un equipo de plataforma:** el destino compartido es la justificación para *construir un camino pavimentado*. Si tu landing zone entrega una fábrica de proyectos con org policies, perímetros de VPC-SC, log sinks y una imagen base endurecida ya adjunta, los equipos de aplicación heredan la postura correcta en lugar de re-derivarla. Ese es el patrón de destino compartido aplicado internamente.

---

## 3. La jerarquía de recursos: el sustrato al que se enlaza todo control

Nada de la seguridad en Google Cloud es comprensible sin esto. Las políticas se adjuntan a nodos y fluyen **hacia abajo**.

```
Organization  (1 per Cloud Identity / Workspace domain — the root of trust)
│
├── Folder: prod
│   ├── Folder: payments
│   │   ├── Project: pay-api-prod-4471
│   │   │   ├── VPC network, subnets, firewall rules
│   │   │   ├── Cloud SQL instance, GCS buckets, BigQuery datasets
│   │   │   └── Service accounts (project-scoped identities)
│   │   └── Project: pay-ledger-prod-9922
│   └── Folder: platform
├── Folder: nonprod
└── Folder: sandbox
```

Dos sistemas de políticas *distintos* se adjuntan a estos nodos, y confundirlos es una trampa clásica del examen:

| | **Política allow de IAM** | **Organization policy (restricción)** |
|---|---|---|
| Responde | *Quién puede hacer qué sobre qué recurso* | *Qué configuraciones se permite que existan siquiera* |
| Objetivo de la concesión | Principal → rol → recurso | Tipo de recurso / campo → valores permitidos |
| Herencia | **Unión aditiva.** Un hijo no puede restar una concesión hecha en el padre | Heredada; puede ser sobrescrita por un hijo **solo si** la restricción y la jerarquía lo permiten (`inheritFromParent`, `reset`) |
| Ejemplo | `alice@ → roles/storage.objectViewer on project pay-api-prod-4471` | `constraints/compute.vmExternalIpAccess: denyAll` en la folder `prod` |
| Se aplica en | Momento de autorización de la petición | Momento de creación/actualización del recurso (y evaluada sobre algunos recursos existentes) |
| El hueco que deja | No puede impedir que un principal *permitido* exfiltre | No puede expresar "esta identidad no puede leer este dataset" |

Como las políticas allow son puramente aditivas, las únicas formas de *restar* acceso efectivo son: **políticas deny de IAM**, **políticas de principal access boundary**, **organization policies** y **VPC Service Controls**. Memorizá esa lista — es la respuesta a "¿cómo restrinjo una concesión heredada con exceso de privilegios?"

---

## 4. Gestión de identidades y accesos: mecánica

### 4.1 Orden de evaluación de políticas

```
Request: principal P wants permission M on resource R
  │
  ├─ 1. Principal Access Boundary  → is R inside P's allowed boundary?   NO → DENY
  ├─ 2. IAM Deny policies (resource + all ancestors)
  │       any matching deny rule where P is not an exception principal?  YES → DENY
  ├─ 3. IAM Allow policies (resource + all ancestors, unioned)
  │       does any bound role contain M? (IAM Conditions evaluated here)  NO → DENY
  ├─ 4. VPC Service Controls perimeter check (for supported APIs)
  │       does the call cross a perimeter without a matching rule?       YES → DENY
  └─ ALLOW
```

**El deny gana. Siempre. El orden 1→4 es de cortocircuito.**

### 4.2 Tipos de principal y su radio de impacto

| Tipo de principal | Forma del identificador | Credencial | Rotación | Recomendado para |
|---|---|---|---|---|
| Cuenta de Google | `user:sre@example.com` | Contraseña + MFA resistente a phishing (Titan/FIDO2) | Humana | Solo humanos |
| Grupo de Google | `group:platform-sre@example.com` | n/a (membresía) | n/a | **Todas las concesiones a humanos** — nunca enlazar usuarios directamente |
| Service account | `serviceAccount:app@proj.iam.gserviceaccount.com` | Token OAuth de corta duración vía el metadata server | Automática (~1 h) | Cargas de trabajo en Google Cloud |
| **Clave** de SA (JSON) | igual, + `private_key` | Clave RSA estática | **Nunca expira por defecto** | ⚠️ Evitar. Es el vector n.º 1 de credencial filtrada |
| Workload identity federation | `principal://iam.googleapis.com/projects/.../subject/...` | Token OIDC/SAML de un IdP externo intercambiado por un token de Google de corta duración | Por petición | GitHub Actions, AWS, on-prem, GKE |
| Workforce identity federation | `principal://iam.googleapis.com/locations/global/workforcePools/...` | IdP externo (Okta, Entra ID) | Sesión | Humanos desde un IdP corporativo existente |

### 4.3 Compensación en la granularidad de roles

| Clase de rol | Ejemplo | Permisos | Compensación |
|---|---|---|---|
| **Básicos** (legacy) | `roles/owner`, `roles/editor`, `roles/viewer` | Miles, en todos los servicios | ❌ Nunca en producción. `roles/editor` puede modificar IAM en muchos recursos y leer casi todos los datos |
| **Predefinidos** | `roles/storage.objectViewer` | Curados por servicio, mantenidos por Google (los permisos nuevos se agregan automáticamente) | ✅ Opción por defecto. Sobre-concesión ocasional; Google puede agregar permisos que no auditaste |
| **Personalizados** | `roles/custom.bucketLister` | Exactamente los permisos que enumeres | Mínimo privilegio más ajustado, pero **vos** sos dueño del mantenimiento; permisos en etapa `SUPPORTED`/`TESTING` pueden romperse; solo con alcance de organización o proyecto |

**Regla práctica:** por defecto usá predefinidos; escalá a personalizados solo cuando una revisión guiada por Policy Analyzer muestre que un rol predefinido concede un permiso que ampliaría materialmente el radio de impacto (típicamente `*.setIamPolicy`, `*.getIamPolicy`, `*.keys.create`).

---

## 5. Infraestructura completa: un proyecto con mínimo privilegio y barandas

Todo lo de abajo es desplegable tal cual. Sustituí `ORG_ID`, `BILLING_ID` y los IDs de proyecto.

### 5.1 Organization policies (barandas) — YAML, aplicadas con `gcloud org-policies`

`policies/vm-external-ip.yaml`
```yaml
# Deny public IPs on Compute Engine VMs across the whole prod folder.
# Exception is granted per-project by an inheritFromParent=false override.
name: folders/641182299038/policies/compute.vmExternalIpAccess
spec:
  inheritFromParent: true
  rules:
    - denyAll: true
```

`policies/allowed-domains.yaml`
```yaml
# Only identities from our Cloud Identity customer ID may appear in any
# IAM allow policy. This single constraint blocks allUsers, allAuthenticatedUsers
# and every gmail.com account from ever being granted a role.
name: organizations/889201773455/policies/iam.allowedPolicyMemberDomains
spec:
  rules:
    - values:
        allowedValues:
          - is:C03xk9qz1          # Cloud Identity customer ID
```

`policies/uniform-bucket-level-access.yaml`
```yaml
# Kill per-object ACLs. Without this, an object can be world-readable
# even when the bucket IAM policy is clean.
name: organizations/889201773455/policies/storage.uniformBucketLevelAccess
spec:
  rules:
    - enforce: true
```

`policies/disable-sa-key-creation.yaml`
```yaml
# The single highest-value guardrail in the catalogue: it makes the
# "leaked JSON key" incident class structurally impossible.
name: organizations/889201773455/policies/iam.disableServiceAccountKeyCreation
spec:
  rules:
    - enforce: true
```

`policies/require-shielded-vm.yaml`
```yaml
name: organizations/889201773455/policies/compute.requireShieldedVm
spec:
  rules:
    - enforce: true
```

`policies/restrict-sql-public-ip.yaml`
```yaml
name: organizations/889201773455/policies/sql.restrictPublicIp
spec:
  rules:
    - enforce: true
```

`policies/resource-locations.yaml`
```yaml
# Data residency as a hard constraint, not a convention.
# Creation of any location-bound resource outside the EU fails at the API.
name: folders/641182299038/policies/gcp.resourceLocations
spec:
  inheritFromParent: false
  rules:
    - values:
        allowedValues:
          - in:eu-locations
```

Aplicalas:

```bash
$ for f in policies/*.yaml; do gcloud org-policies set-policy "$f"; done
Created policy [organizations/889201773455/policies/iam.allowedPolicyMemberDomains].
name: organizations/889201773455/policies/iam.allowedPolicyMemberDomains
spec:
  etag: CO7Rzr4GEJDh8bYB
  rules:
  - values:
      allowedValues:
      - is:C03xk9qz1
  updateTime: '2026-09-08T11:04:27.918433Z'
...
```

Verificá la política efectiva en un proyecto hoja (esto resuelve la herencia, cosa que `describe` no hace):

```bash
$ gcloud org-policies describe compute.vmExternalIpAccess \
    --project=pay-api-prod-4471 --effective
name: projects/pay-api-prod-4471/policies/compute.vmExternalIpAccess
spec:
  rules:
  - denyAll: true
```

### 5.2 Una restricción **personalizada** de organization policy

Las restricciones predefinidas no cubren todo. Las restricciones personalizadas evalúan una expresión CEL contra el recurso que se está creando o actualizando.

`policies/custom-require-cmek-gce.yaml`
```yaml
name: organizations/889201773455/customConstraints/custom.requireCmekOnBootDisk
resourceTypes:
  - compute.googleapis.com/Disk
methodTypes:
  - CREATE
condition: "has(resource.diskEncryptionKey) && resource.diskEncryptionKey.kmsKeyName.startsWith('projects/sec-kms-prod-1180/')"
actionType: ALLOW
displayName: Boot and data disks must use a CMEK from the central KMS project
description: >-
  Google-managed encryption is not sufficient for PCI-DSS scoped workloads;
  the key must be revocable by the security team.
```

```bash
$ gcloud org-policies set-custom-constraint policies/custom-require-cmek-gce.yaml
Created custom constraint [organizations/889201773455/customConstraints/custom.requireCmekOnBootDisk].
```

Después aplicala como cualquier otra restricción:

```yaml
name: folders/641182299038/policies/custom.requireCmekOnBootDisk
spec:
  rules:
    - enforce: true
```

### 5.3 Política deny de IAM — restar una concesión heredada

Las políticas deny se adjuntan a organización/folder/proyecto vía la API IAM v2 y son la única forma de decirle "no" a un principal al que un ancestro le concedió un rol.

`policies/deny-sa-impersonation.yaml`
```yaml
displayName: Block impersonation of break-glass service accounts
rules:
  - denyRule:
      deniedPrincipals:
        - principalSet://goog/public:all
      exceptionPrincipals:
        - principalSet://goog/group/breakglass-approvers@example.com
      deniedPermissions:
        - iam.googleapis.com/serviceAccounts.getAccessToken
        - iam.googleapis.com/serviceAccounts.getOpenIdToken
        - iam.googleapis.com/serviceAccounts.implicitDelegation
      denialCondition:
        title: Only break-glass SAs
        expression: >-
          resource.matchTag('889201773455/tier', 'breakglass')
```

```bash
$ gcloud iam policies create deny-breakglass-impersonation \
    --attachment-point=cloudresourcemanager.googleapis.com/organizations/889201773455 \
    --kind=denypolicies \
    --policy-file=policies/deny-sa-impersonation.yaml
Created policy [deny-breakglass-impersonation].

$ gcloud iam policies list \
    --attachment-point=cloudresourcemanager.googleapis.com/organizations/889201773455 \
    --kind=denypolicies --format="table(name.basename(), displayName)"
NAME                             DISPLAY_NAME
deny-breakglass-impersonation    Block impersonation of break-glass service accounts
```

### 5.4 Binding condicional de IAM (acceso acotado por tiempo y por recurso)

```bash
$ gcloud projects add-iam-policy-binding pay-api-prod-4471 \
  --member="group:oncall-payments@example.com" \
  --role="roles/cloudsql.client" \
  --condition='expression=request.time < timestamp("2026-09-15T00:00:00Z") && resource.name.startsWith("projects/pay-api-prod-4471/instances/ledger-"),title=oncall-window-w37,description=Sprint 37 on-call rotation only'
Updated IAM policy for project [pay-api-prod-4471].
bindings:
- condition:
    description: Sprint 37 on-call rotation only
    expression: request.time < timestamp("2026-09-15T00:00:00Z") && resource.name.startsWith("projects/pay-api-prod-4471/instances/ledger-")
    title: oncall-window-w37
  members:
  - group:oncall-payments@example.com
  role: roles/cloudsql.client
etag: BwYh0Z9pQ2s=
version: 3
```

### 5.5 Workload identity sin claves en GKE — conjunto completo de manifiestos

`k8s/serviceaccount.yaml`
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ledger-api
  namespace: payments
  annotations:
    # Legacy impersonation model. With direct IAM bindings on the
    # principal:// identifier this annotation is no longer required,
    # but it remains the most widely deployed pattern.
    iam.gke.io/gcp-service-account: ledger-api@pay-api-prod-4471.iam.gserviceaccount.com
---
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

`k8s/deployment.yaml`
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ledger-api
  namespace: payments
  labels:
    app: ledger-api
spec:
  replicas: 3
  selector:
    matchLabels:
      app: ledger-api
  template:
    metadata:
      labels:
        app: ledger-api
    spec:
      serviceAccountName: ledger-api
      automountServiceAccountToken: true
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      nodeSelector:
        cloud.google.com/gke-nodepool: confidential-pool
      containers:
        - name: api
          # Digest-pinned. Binary Authorization will reject anything unsigned.
          image: europe-west1-docker.pkg.dev/pay-api-prod-4471/apps/ledger-api@sha256:6b1e0f7f0b9c3f7d3a2e1c5a9d8b7f6e5d4c3b2a1908f7e6d5c4b3a2918f7e6d
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
          securityContext:
            allowPrivilegeEscalation: false
            privileged: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          env:
            # No credentials here. The metadata server mints tokens.
            - name: GOOGLE_CLOUD_PROJECT
              value: pay-api-prod-4471
            - name: SPANNER_INSTANCE
              value: ledger-eu
          resources:
            requests:
              cpu: "500m"
              memory: "512Mi"
            limits:
              cpu: "2"
              memory: "2Gi"
          livenessProbe:
            httpGet: { path: /healthz, port: http }
            initialDelaySeconds: 10
            periodSeconds: 10
          readinessProbe:
            httpGet: { path: /readyz, port: http }
            initialDelaySeconds: 5
            periodSeconds: 5
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ledger-api-default-deny
  namespace: payments
spec:
  podSelector: {}
  policyTypes: ["Ingress", "Egress"]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ledger-api-allow
  namespace: payments
spec:
  podSelector:
    matchLabels:
      app: ledger-api
  policyTypes: ["Ingress", "Egress"]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress
      ports:
        - protocol: TCP
          port: 8080
  egress:
    # DNS
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
    # Google APIs via Private Google Access (restricted VIP)
    - to:
        - ipBlock:
            cidr: 199.36.153.4/30
      ports:
        - protocol: TCP
          port: 443
    # GKE metadata server for token minting
    - to:
        - ipBlock:
            cidr: 169.254.169.254/32
      ports:
        - protocol: TCP
          port: 988
```

Enlazá la SA de Kubernetes con la SA de Google:

```bash
$ gcloud iam service-accounts add-iam-policy-binding \
    ledger-api@pay-api-prod-4471.iam.gserviceaccount.com \
    --role=roles/iam.workloadIdentityUser \
    --member="serviceAccount:pay-api-prod-4471.svc.id.goog[payments/ledger-api]"
Updated IAM policy for serviceAccount [ledger-api@pay-api-prod-4471.iam.gserviceaccount.com].
bindings:
- members:
  - serviceAccount:pay-api-prod-4471.svc.id.goog[payments/ledger-api]
  role: roles/iam.workloadIdentityUser
etag: BwYh1A2bC3d=
version: 1
```

Verificá desde dentro del pod que la identidad es la SA de Google y que no existe ningún archivo de clave:

```bash
$ kubectl -n payments exec -it deploy/ledger-api -- \
    curl -s -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email"
ledger-api@pay-api-prod-4471.iam.gserviceaccount.com

$ kubectl -n payments exec -it deploy/ledger-api -- ls /var/secrets 2>&1
ls: cannot access '/var/secrets': No such file or directory
```

### 5.6 Terraform: la misma postura como código

`security.tf`
```hcl
terraform {
  required_version = ">= 1.9"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

locals {
  org_id     = "889201773455"
  prod_folder = "folders/641182299038"
  kms_project = "sec-kms-prod-1180"
}

# ---------------------------------------------------------------------------
# Guardrails
# ---------------------------------------------------------------------------
resource "google_org_policy_policy" "no_sa_keys" {
  name   = "organizations/${local.org_id}/policies/iam.disableServiceAccountKeyCreation"
  parent = "organizations/${local.org_id}"

  spec {
    rules {
      enforce = "TRUE"
    }
  }
}

resource "google_org_policy_policy" "domain_restricted_sharing" {
  name   = "organizations/${local.org_id}/policies/iam.allowedPolicyMemberDomains"
  parent = "organizations/${local.org_id}"

  spec {
    rules {
      values {
        allowed_values = ["is:C03xk9qz1"]
      }
    }
  }
}

resource "google_org_policy_policy" "eu_only" {
  name   = "${local.prod_folder}/policies/gcp.resourceLocations"
  parent = local.prod_folder

  spec {
    inherit_from_parent = false
    rules {
      values {
        allowed_values = ["in:eu-locations"]
      }
    }
  }
}

# ---------------------------------------------------------------------------
# CMEK: key ring, key, rotation, and the service-agent grant everyone forgets
# ---------------------------------------------------------------------------
resource "google_kms_key_ring" "ledger" {
  project  = local.kms_project
  name     = "ledger-eu"
  location = "europe-west1"
}

resource "google_kms_crypto_key" "ledger_data" {
  name            = "ledger-data"
  key_ring        = google_kms_key_ring.ledger.id
  rotation_period = "7776000s" # 90 days
  purpose         = "ENCRYPT_DECRYPT"

  version_template {
    algorithm        = "GOOGLE_SYMMETRIC_ENCRYPTION"
    protection_level = "HSM" # FIPS 140-2 Level 3
  }

  lifecycle {
    prevent_destroy = true
  }
}

data "google_storage_project_service_account" "gcs_agent" {
  project = "pay-api-prod-4471"
}

# Without this binding the bucket create fails with a KMS permission error.
resource "google_kms_crypto_key_iam_member" "gcs_agent_use" {
  crypto_key_id = google_kms_crypto_key.ledger_data.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${data.google_storage_project_service_account.gcs_agent.email_address}"
}

resource "google_storage_bucket" "ledger_archive" {
  project                     = "pay-api-prod-4471"
  name                        = "pay-ledger-archive-eu"
  location                    = "EU"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning { enabled = true }

  encryption {
    default_kms_key_name = google_kms_crypto_key.ledger_data.id
  }

  retention_policy {
    retention_period = 220752000 # 7 years, regulatory hold
    is_locked        = false     # flip to true only when you are certain
  }

  logging {
    log_bucket        = "pay-audit-logs-eu"
    log_object_prefix = "gcs-access/"
  }

  depends_on = [google_kms_crypto_key_iam_member.gcs_agent_use]
}

# ---------------------------------------------------------------------------
# Org-wide audit log sink, immutable
# ---------------------------------------------------------------------------
resource "google_logging_organization_sink" "audit" {
  name             = "org-audit-to-bq"
  org_id           = local.org_id
  include_children = true
  destination      = "bigquery.googleapis.com/projects/sec-logging-prod-2201/datasets/cloud_audit"

  filter = <<-EOT
    logName:"logs/cloudaudit.googleapis.com%2Factivity" OR
    logName:"logs/cloudaudit.googleapis.com%2Fdata_access" OR
    logName:"logs/cloudaudit.googleapis.com%2Fsystem_event" OR
    logName:"logs/cloudaudit.googleapis.com%2Fpolicy"
  EOT
}
```

### 5.7 Habilitar los audit logs de Data Access (desactivados por defecto — el hueco clásico)

Los logs de Admin Activity están siempre activos y son gratuitos. **Los logs de Data Access son opt-in** (excepto BigQuery) y son los que te dicen *quién leyó los datos*.

`audit/policy.yaml`
```yaml
auditConfigs:
  - service: allServices
    auditLogConfigs:
      - logType: ADMIN_READ
      - logType: DATA_READ
      - logType: DATA_WRITE
        exemptedMembers:
          - serviceAccount:high-volume-etl@pay-api-prod-4471.iam.gserviceaccount.com
bindings:
  - members:
      - group:platform-sre@example.com
    role: roles/viewer
etag: BwYh0Z9pQ2s=
version: 3
```

```bash
$ gcloud projects set-iam-policy pay-api-prod-4471 audit/policy.yaml
Updated IAM policy for project [pay-api-prod-4471].

$ gcloud projects get-iam-policy pay-api-prod-4471 \
    --format="yaml(auditConfigs)"
auditConfigs:
- auditLogConfigs:
  - logType: ADMIN_READ
  - logType: DATA_READ
  - exemptedMembers:
    - serviceAccount:high-volume-etl@pay-api-prod-4471.iam.gserviceaccount.com
    logType: DATA_WRITE
  service: allServices
```

**Compensación de costo (real, y duele):** los logs de Data Access sobre una carga de trabajo de alto rendimiento en Cloud Storage o Spanner pueden generar cientos de GB/día. Habilitalos por servicio, exceptuá las service accounts conocidas de procesamiento masivo, y enrutalos a un sink de BigQuery con expiración de particiones en lugar de mantenerlos en el log bucket `_Default`.

---

## 6. Cifrado: en reposo, en tránsito, en uso

### 6.1 Cifrado de sobre (envelope encryption) — el comportamiento por defecto, sin acción de tu parte

```
Object / row / block
   │
   ├─ split into chunks
   │
   ▼
Each chunk ──AES-256-GCM──▶ ciphertext
   with a unique DEK (Data Encryption Key)
                 │
                 ▼
        DEK is itself encrypted (wrapped) by a KEK
                 │
                 ▼
        KEK lives in Google's internal KMS (Keystore)
                 │
                 ▼
        Keystore's own root keys live in Root KMS,
        backed by hardware, distributed, tightly ACL'd
```

Las DEKs envueltas se almacenan **junto al dato**; la KEK nunca sale de KMS. Rotar la KEK vuelve a envolver las DEKs — no requiere volver a cifrar petabytes.

### 6.2 Opciones de gestión de claves — tabla completa de compensaciones

| Opción | Dónde vive el material de la clave | Quién puede destruir la clave | ¿Google puede acceder al dato si se lo obliga legalmente? | Impacto en latencia / disponibilidad | Motivador típico |
|---|---|---|---|---|---|
| **Gestionada por Google (GMEK)** — por defecto | Keystore interno de Google | Google (gestión de ciclo de vida) | Sí | Ninguno | Por defecto; costo operativo cero |
| **CMEK** (Cloud KMS, software) | Cloud KMS, infraestructura de Google | **Vos** | Sí (la clave está en infraestructura de Google) | Pequeño; KMS es una dependencia del servicio de datos | Auditabilidad, crypto-shredding, política de rotación de claves |
| **CMEK con HSM** | Cloud HSM, FIPS 140-2 L3 | **Vos** | Sí | Levemente mayor que KMS por software | Requisito FIPS |
| **Cloud EKM** | **Gestor de terceros fuera de Google** (Fortanix, Thales, Virtru, Equinix) | **Vos** | **No** — la clave nunca entra a Google | El mayor; ida y vuelta externa al desenvolver; el gestor externo se vuelve una dependencia de disponibilidad de tus datos | Custodia externa de claves, soberanía |
| **EKM + Key Access Justifications** | Externo | Vos | No, y además ves + podés auto-denegar una justificación por acceso | Como EKM | El control más fuerte; soberanía regulada |
| **CSEK** (suministrada por el cliente) | **Vos**, enviada en cada llamada a la API | Vos | No (Google la conserva solo en memoria) | Debés suministrar la clave en cada operación | Acotado: solo discos de Compute Engine y Cloud Storage. Si perdés la clave → el dato es irrecuperable |

El **crypto-shredding** es la razón operativa por la que CMEK más importa: destruir una versión de clave vuelve permanentemente ilegible todo objeto cifrado con ella, lo que satisface "borrá los datos de este tenant" más rápido y de forma más demostrable que emitir millones de llamadas de borrado.

```bash
$ gcloud kms keys versions destroy 3 \
    --key=ledger-data --keyring=ledger-eu --location=europe-west1 \
    --project=sec-kms-prod-1180
You are about to destroy version [3] of key [ledger-data].
Do you want to continue (Y/n)?  Y
Destroyed version [3] of key [ledger-data].
name: projects/sec-kms-prod-1180/locations/europe-west1/keyRings/ledger-eu/cryptoKeys/ledger-data/cryptoKeyVersions/3
state: DESTROY_SCHEDULED
destroyTime: '2026-10-08T11:19:44.220Z'   # 24-hour minimum, default 30 days
```

Notá el `DESTROY_SCHEDULED`: la destrucción se demora (configurable, mínimo 24 h) precisamente para que una destrucción accidental o maliciosa pueda restaurarse.

### 6.3 Cifrado en tránsito

| Camino | Mecanismo | Notas |
|---|---|---|
| Internet → edge de Google (GFE) | TLS 1.2/1.3, BoringSSL, gestión automática de certificados en los balanceadores de carga | El GFE termina la conexión y es el punto de estrangulamiento para DDoS/L7 |
| Edge de Google → tu backend (misma VPC) | Cifrado en la capa de red donde sale de los límites físicos | El tráfico en la WAN privada de Google entre DCs está cifrado en la capa física/de red |
| Servicio de Google ↔ servicio de Google (RPC) | **ALTS** (Application Layer Transport Security) — autenticación mutua usando identidades de servicio, no nombres de host | No es TLS; es un protocolo interno con identidad por servicio |
| Carga de trabajo ↔ APIs de Google | TLS hacia `*.googleapis.com`, opcionalmente vía **Private Google Access** / **Private Service Connect** para que el tráfico nunca toque una IP pública | `restricted.googleapis.com` (199.36.153.4/30) solo resuelve servicios soportados por VPC-SC |
| Pod ↔ Pod (GKE) | No cifrado por defecto; agregá un service mesh (mTLS de Cloud Service Mesh) o Dataplane V2 con cifrado transparente entre nodos | Un hallazgo de auditoría común |

### 6.4 Cifrado en uso — Confidential Computing

El cifrado en reposo y en tránsito deja un hueco: texto plano en RAM, visible en principio para el hipervisor. Las Confidential VMs lo cierran cifrando la memoria con una clave generada y retenida en la CPU, no disponible para el host.

```bash
$ gcloud compute instances create ledger-confidential-1 \
    --project=pay-api-prod-4471 \
    --zone=europe-west1-b \
    --machine-type=n2d-standard-8 \
    --confidential-compute-type=SEV_SNP \
    --min-cpu-platform="AMD Milan" \
    --maintenance-policy=TERMINATE \
    --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring \
    --no-address \
    --service-account=ledger-api@pay-api-prod-4471.iam.gserviceaccount.com \
    --scopes=https://www.googleapis.com/auth/cloud-platform \
    --image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud
Created [https://www.googleapis.com/compute/v1/projects/pay-api-prod-4471/zones/europe-west1-b/instances/ledger-confidential-1].
NAME                   ZONE            MACHINE_TYPE   INTERNAL_IP  EXTERNAL_IP  STATUS
ledger-confidential-1  europe-west1-b  n2d-standard-8 10.20.4.19                RUNNING
```

Verificá que el cifrado de memoria esté realmente activo:

```bash
$ gcloud compute ssh ledger-confidential-1 --zone=europe-west1-b --tunnel-through-iap \
    --command="dmesg | grep -i -E 'sev|memory encryption'"
[    0.000000] Memory Encryption Features active: AMD SEV SEV-ES SEV-SNP
[    0.318442] SEV-SNP: RMP table physical address [0x0000000035600000 - 0x0000000075afffff]
```

**Tabla de compensaciones:**

| | VM estándar | Shielded VM | Confidential VM (SEV-SNP / TDX) |
|---|---|---|---|
| Protege contra | — | Rootkits a nivel de arranque, manipulación del kernel | Hipervisor malicioso/comprometido, raspado de memoria |
| Mecanismo | — | UEFI Secure Boot, vTPM, Measured Boot, integrity monitoring | Clave de cifrado de memoria por VM en la CPU + informe de atestación |
| Costo de rendimiento | 0 | ~0 | Típicamente un porcentaje bajo de un dígito; depende de la carga |
| Restricción de tipo de máquina | cualquiera | la mayoría | `n2d`, `c2d`, `c3d` (AMD SEV/SEV-SNP); `c3` (Intel TDX) |
| Migración en vivo | Sí | Sí | **No** — hay que fijar `--maintenance-policy=TERMINATE` |
| Costo | base | base | base + sobreprecio de confidential compute |

La restricción de migración en vivo es la operativamente significativa: una Confidential VM se termina ante mantenimiento del host. Diseñá para eso con un MIG regional y un `PodDisruptionBudget`, o no uses Confidential Computing para un singleton con estado.

---

## 7. Zero trust: eliminar la confianza implícita en la red

### 7.1 El modelo

| Supuesto | Modelo perimetral (castillo y foso) | **Zero trust / BeyondCorp** |
|---|---|---|
| Fuente de confianza | Ubicación de red (dentro de la VPN = confiable) | Identidad + postura del dispositivo + contexto, evaluados **por petición** |
| VPN | Requerida para apps internas | No requerida; las apps se publican en internet detrás de un proxy consciente de la identidad |
| Movimiento lateral tras un compromiso | Mayormente sin restricciones | Cada salto se re-autoriza de forma independiente |
| La decisión de acceso se cachea por | Sesión/duración del túnel VPN | Por petición |
| Productos de Google Cloud | Cloud VPN, reglas de firewall | **Identity-Aware Proxy (IAP)**, Access Context Manager (niveles de acceso), Context-Aware Access, Chrome Enterprise Premium, endpoint verification |

### 7.2 Nivel de acceso + IAP: configuración completa

`access-levels/corp-trusted.yaml`
```yaml
- name: accessPolicies/419320017722/accessLevels/corp_trusted
  title: Corporate trusted device and geography
  basic:
    combiningFunction: AND
    conditions:
      - regions:
          - ES
          - DE
          - IE
      - devicePolicy:
          requireScreenlock: true
          requireCorpOwned: true
          osConstraints:
            - osType: DESKTOP_MAC
              minimumVersion: "14.0.0"
            - osType: DESKTOP_LINUX
            - osType: DESKTOP_CHROME_OS
              requireVerifiedChromeOs: true
          allowedEncryptionStatuses:
            - ENCRYPTED
      - members:
          - group:employees@example.com
```

```bash
$ gcloud access-context-manager levels replace-all \
    --policy=419320017722 --source-file=access-levels/corp-trusted.yaml
Replaced all access levels in policy [419320017722].

# Publish an internal app through IAP — no VPN, no public path to the backend.
$ gcloud compute backend-services update ledger-admin-backend \
    --global --iap=enabled
Updated [https://www.googleapis.com/compute/v1/projects/pay-api-prod-4471/global/backendServices/ledger-admin-backend].

$ gcloud iap web add-iam-policy-binding \
    --resource-type=backend-services --service=ledger-admin-backend \
    --member="group:ledger-admins@example.com" \
    --role="roles/iap.httpsResourceAccessor" \
    --condition='expression=request.auth.claims.google.access_levels.exists(l, l == "accessPolicies/419320017722/accessLevels/corp_trusted"),title=corp-device-only'
Updated IAM policy for an IAP web resource.
```

Las reglas de firewall deben entonces admitir **solo** el rango de los forwarders de IAP, de modo que el backend no tenga ningún otro camino alcanzable:

```bash
$ gcloud compute firewall-rules create allow-iap-forwarders \
    --network=vpc-prod-eu --direction=INGRESS --action=ALLOW \
    --rules=tcp:8080 --source-ranges=35.235.240.0/20 \
    --target-tags=ledger-admin --priority=1000
Creating firewall...done.

$ gcloud compute firewall-rules create deny-all-ingress \
    --network=vpc-prod-eu --direction=INGRESS --action=DENY \
    --rules=all --source-ranges=0.0.0.0/0 --priority=65534
Creating firewall...done.
```

El mismo rango habilita SSH sin bastión ni IP pública:

```bash
$ gcloud compute ssh ledger-confidential-1 --zone=europe-west1-b --tunnel-through-iap
External IP address was not found; defaulting to using IAP tunneling.
WARNING: To increase the performance of the tunnel, consider installing NumPy.
Linux ledger-confidential-1 6.8.0-1021-gcp #23-Ubuntu SMP x86_64
ledger@ledger-confidential-1:~$
```

---

## 8. VPC Service Controls: el límite de exfiltración que IAM no puede expresar

**El problema reformulado:** `alice@example.com` tiene `roles/bigquery.dataViewer` sobre `projects/pay-ledger-prod-9922`. Es legítima. Corre una consulta desde su laptop en su casa y exporta el resultado a `gs://alice-personal-bucket`. **Toda verificación de IAM pasa.** IAM no tiene vocabulario para "este dato no puede salir de este conjunto de proyectos".

VPC-SC agrega ese vocabulario: un **perímetro de servicio** alrededor de un conjunto de proyectos, dentro del cual las APIs de Google especificadas rechazarán las llamadas que crucen el límite.

`perimeter/ledger-perimeter.yaml`
```yaml
name: accessPolicies/419320017722/servicePerimeters/ledger_eu
title: ledger_eu
perimeterType: PERIMETER_TYPE_REGULAR
status:
  resources:
    - projects/771820039411   # pay-ledger-prod-9922
    - projects/771820039412   # pay-api-prod-4471
    - projects/771820039413   # sec-kms-prod-1180
  restrictedServices:
    - bigquery.googleapis.com
    - storage.googleapis.com
    - cloudkms.googleapis.com
    - spanner.googleapis.com
    - logging.googleapis.com
    - pubsub.googleapis.com
  accessLevels:
    - accessPolicies/419320017722/accessLevels/corp_trusted
  vpcAccessibleServices:
    enableRestriction: true
    allowedServices:
      - bigquery.googleapis.com
      - storage.googleapis.com
      - cloudkms.googleapis.com
      - spanner.googleapis.com
      - logging.googleapis.com
      - pubsub.googleapis.com
```

`perimeter/egress-rules.yaml` — los agujeros estrechos y justificados:
```yaml
- egressFrom:
    identityType: ANY_SERVICE_ACCOUNT
    sources:
      - resource: projects/771820039411
    sourceRestriction: SOURCE_RESTRICTION_ENABLED
  egressTo:
    resources:
      - projects/992047711830          # regulator-facing reporting project
    operations:
      - serviceName: storage.googleapis.com
        methodSelectors:
          - method: google.storage.objects.create
```

`perimeter/ingress-rules.yaml`:
```yaml
- ingressFrom:
    identities:
      - serviceAccount:terraform-prod@sec-cicd-prod-3310.iam.gserviceaccount.com
    sources:
      - accessLevel: accessPolicies/419320017722/accessLevels/corp_trusted
  ingressTo:
    resources:
      - "*"
    operations:
      - serviceName: storage.googleapis.com
        methodSelectors:
          - method: "*"
      - serviceName: cloudkms.googleapis.com
        methodSelectors:
          - method: "*"
```

**Desplegá siempre primero en dry-run.** El dry-run puebla `spec` en lugar de `status`; las violaciones se registran, no se aplican.

```bash
$ gcloud access-context-manager perimeters dry-run create ledger_eu \
    --policy=419320017722 \
    --perimeter-title="ledger_eu" \
    --perimeter-type=regular \
    --perimeter-resources=projects/771820039411,projects/771820039412,projects/771820039413 \
    --perimeter-restricted-services=bigquery.googleapis.com,storage.googleapis.com,cloudkms.googleapis.com,spanner.googleapis.com \
    --perimeter-access-levels=accessPolicies/419320017722/accessLevels/corp_trusted
Create request issued for: [ledger_eu]
Waiting for operation [operations/accessPolicies/419320017722/servicePerimeters/ledger_eu/create/1757328117410] to complete...done.
Created.
```

Recolectá lo que *habría* sido bloqueado, a lo largo de un ciclo de negocio completo (una semana como mínimo — los jobs batch de fin de mes son la sorpresa clásica):

```bash
$ gcloud logging read '
    protoPayload.metadata."@type"="type.googleapis.com/google.cloud.audit.VpcServiceControlAuditMetadata"
    AND protoPayload.metadata.dryRun="true"
  ' --organization=889201773455 --freshness=7d --limit=500 \
  --format="table(
      protoPayload.authenticationInfo.principalEmail,
      protoPayload.serviceName,
      protoPayload.methodName,
      protoPayload.metadata.violationReason,
      protoPayload.metadata.ingressViolations[0].targetResource)"
PRINCIPAL_EMAIL                                        SERVICE_NAME             METHOD_NAME                       VIOLATION_REASON              TARGET_RESOURCE
etl-nightly@pay-data-prod-8890.iam.gserviceaccount.com bigquery.googleapis.com  google.cloud.bigquery.v2.JobService.InsertJob  NO_MATCHING_ACCESS_LEVEL  projects/771820039411
backup-agent@ops-prod-1120.iam.gserviceaccount.com     storage.googleapis.com   google.storage.objects.create     RESOURCES_NOT_IN_SAME_SERVICE_PERIMETER  projects/771820039411
alice@example.com                                      bigquery.googleapis.com  google.cloud.bigquery.v2.JobService.Query      NO_MATCHING_ACCESS_LEVEL  projects/771820039411
```

Cada línea es una decisión: agregar una regla de ingreso, mover el proyecto adentro, o aceptar el bloqueo. Solo cuando el log del dry-run queda en silencio pasás a aplicarlo:

```bash
$ gcloud access-context-manager perimeters dry-run enforce ledger_eu --policy=419320017722
Enforce request issued for: [ledger_eu]
Waiting for operation [operations/...]...done.
Enforced.
```

### 8.1 Qué control responde qué pregunta

| Pregunta | IAM | Org Policy | Firewall | **VPC-SC** | Cloud Armor |
|---|---|---|---|---|---|
| ¿Puede esta identidad llamar a esta API? | ✅ | — | — | — | — |
| ¿Puede crearse este recurso con esta configuración? | — | ✅ | — | — | — |
| ¿Puede este paquete llegar a esta VM en este puerto? | — | — | ✅ | — | — |
| ¿Puede este dato salir de este conjunto de proyectos? | ❌ | ❌ | ❌ | **✅** | — |
| ¿Puede esta petición de internet llegar a mi app L7? | — | — | parcial | — | **✅** |
| ¿Bloquea a un principal *legítimamente autorizado*? | No | No | No | **Sí** | No |

---

## 9. El edge: DDoS y defensa en la capa de aplicación

### 9.1 Panorama de amenazas mapeado a controles

| Amenaza | Mecanismo | Control de Google Cloud |
|---|---|---|
| DDoS volumétrico (L3/L4) | Inundación UDP/SYN, amplificación | Absorbido por el edge global de Google + anycast de Cloud Load Balancing, **siempre activo, sin configuración** |
| DDoS de aplicación (L7) | Inundación HTTP, slowloris | Rate limiting de Cloud Armor + Adaptive Protection (firmas derivadas por ML) |
| Inyección del OWASP Top 10 | SQLi, XSS, RCE, LFI | Reglas WAF preconfiguradas de Cloud Armor (derivadas del CRS de ModSecurity) |
| Phishing / robo de credenciales | Login falso, fatiga de MFA | MFA resistente a phishing (Titan Security Key / FIDO2), Context-Aware Access, Chrome Enterprise Premium |
| Malware / ransomware | Ejecución de payload, cifrado de datos | Shielded VM, Binary Authorization, versionado de objetos + política de retención **bloqueada**, detección de amenazas de SCC |
| Cadena de suministro | Imagen base / dependencia comprometida | Escaneo de vulnerabilidades de Artifact Analysis, atestaciones de Binary Authorization, Assured OSS, procedencia SLSA |
| Insider / acceso del proveedor | Un ingeniero de soporte lee contenido | Access Transparency (visibilidad), Access Approval (vos aprobás), Key Access Justifications (podés auto-denegar) |
| Exfiltración de datos por un usuario autorizado | Copia a un proyecto personal | **VPC Service Controls** |
| Configuración errónea | Bucket público, IAM amplio | Org Policy, SCC Security Health Analytics, recomendaciones de Policy Intelligence |

### 9.2 Política de Cloud Armor — definición completa

```bash
$ gcloud compute security-policies create ledger-edge-policy \
    --description="Edge protection for ledger public API" \
    --type=CLOUD_ARMOR
Created [https://www.googleapis.com/compute/v1/projects/pay-api-prod-4471/global/securityPolicies/ledger-edge-policy].

# Default action at the lowest priority
$ gcloud compute security-policies rules update 2147483647 \
    --security-policy=ledger-edge-policy --action=deny-403
Updated [ledger-edge-policy].

# Preconfigured WAF: SQL injection, sensitivity tuned down to reduce FPs
$ gcloud compute security-policies rules create 1000 \
    --security-policy=ledger-edge-policy \
    --expression="evaluatePreconfiguredWaf('sqli-v33-stable', {'sensitivity': 2})" \
    --action=deny-403 \
    --description="OWASP CRS 3.3 SQL injection"
Created rule [1000].

$ gcloud compute security-policies rules create 1001 \
    --security-policy=ledger-edge-policy \
    --expression="evaluatePreconfiguredWaf('xss-v33-stable', {'sensitivity': 2})" \
    --action=deny-403 \
    --description="OWASP CRS 3.3 cross-site scripting"
Created rule [1001].

# Rate limiting with a ban, keyed per client IP
$ gcloud compute security-policies rules create 2000 \
    --security-policy=ledger-edge-policy \
    --expression="request.path.matches('/api/v1/')" \
    --action=rate-based-ban \
    --rate-limit-threshold-count=600 \
    --rate-limit-threshold-interval-sec=60 \
    --ban-duration-sec=600 \
    --conform-action=allow \
    --exceed-action=deny-429 \
    --enforce-on-key=IP \
    --description="600 req/min per IP on the API surface"
Created rule [2000].

# Geo allow-list ahead of the deny-all default
$ gcloud compute security-policies rules create 500 \
    --security-policy=ledger-edge-policy \
    --expression="origin.region_code in ['ES','DE','IE','FR','PT','IT']" \
    --action=allow \
    --description="EU market only"
Created rule [500].

# Adaptive Protection (Cloud Armor Enterprise)
$ gcloud compute security-policies update ledger-edge-policy \
    --enable-layer7-ddos-defense
Updated [ledger-edge-policy].

$ gcloud compute backend-services update ledger-public-backend \
    --global --security-policy=ledger-edge-policy
Updated [ledger-public-backend].
```

Inspeccioná lo que construiste:

```bash
$ gcloud compute security-policies describe ledger-edge-policy \
    --format="table(rules[].priority, rules[].action, rules[].description)"
PRIORITY     ACTION          DESCRIPTION
500          allow           EU market only
1000         deny(403)       OWASP CRS 3.3 SQL injection
1001         deny(403)       OWASP CRS 3.3 cross-site scripting
2000         rate_based_ban  600 req/min per IP on the API surface
2147483647   deny(403)       Default rule, higher priority overrides it
```

**Compensación:** sensibilidad 1 del WAF → pocos falsos positivos, cobertura más débil; sensibilidad 4 → cobertura fuerte, bloqueará tráfico legítimo que contenga cadenas parecidas a SQL (un cuadro de búsqueda, un payload JSON con `--`). El despliegue correcto es `--action=preview` a sensibilidad de producción, recolectar `jsonPayload.enforcedSecurityPolicy.outcome="ACCEPT"` frente a lo que *habría* sido denegado, ajustar exclusiones por regla, y recién entonces aplicar.

---

## 10. Control, cumplimiento, residencia y soberanía

### 10.1 Cuatro conceptos distintos que se confunden rutinariamente

| Concepto | Pregunta que responde | Instrumento de Google Cloud |
|---|---|---|
| **Residencia de datos** | *¿Dónde está almacenado físicamente el dato?* | Org policy `gcp.resourceLocations`; selección de recursos regionales/dual-región/multi-región |
| **Soberanía de datos** | *¿La ley de qué jurisdicción gobierna el dato, y quién puede acceder a él técnicamente?* | Cloud EKM + Key Access Justifications (clave fuera de Google → Google técnicamente no puede descifrar) |
| **Soberanía operativa** | *¿Quién opera la infraestructura, y puedo restringir el soporte a personal dentro de la región?* | Controles de ubicación de datos del personal y de soporte de Assured Workloads; Access Approval |
| **Soberanía de software** | *¿Puedo correr mi carga de trabajo en otro lado sin lock-in?* | Estándares abiertos: Kubernetes, GKE Enterprise / Anthos, APIs open-source, Cloud Run (derivado de Knative) |

La residencia es la más débil de las cuatro y la que los clientes más a menudo confunden con las otras: un dato almacenado *en* Frankfurt sigue siendo alcanzable por una entidad bajo jurisdicción estadounidense en ausencia de los controles de soberanía.

### 10.2 Assured Workloads

```bash
$ gcloud assured workloads create \
    --location=europe-west1 \
    --organization=889201773455 \
    --display-name="ledger-eu-regions-support" \
    --compliance-regime=EU_REGIONS_AND_SUPPORT \
    --billing-account=billingAccounts/01F3A2-B9C4D1-77E210 \
    --next-rotation-time="2026-12-01T00:00:00Z" \
    --rotation-period="7776000s"
Create request issued.
Waiting for operation [operations/...] to complete...done.
Created workload [organizations/889201773455/locations/europe-west1/workloads/8891029384756].
```

Una folder de Assured Workloads aplica un **paquete de control**: fija las ubicaciones de los recursos, restringe qué personal de Google puede dar soporte a la carga de trabajo y desde dónde, habilita las org policies requeridas y pre-provisiona CMEK. La compensación es explícita: hay menos servicios disponibles dentro de la folder, y algunas funcionalidades van por detrás de la disponibilidad general.

| Paquete de control (ejemplos) | Régimen | Restricción principal |
|---|---|---|
| `FEDRAMP_MODERATE` / `FEDRAMP_HIGH` | Federal de EE.UU. | Ubicación de datos en EE.UU. + personal estadounidense verificado |
| `IL4` | DoD de EE.UU. | Verificación más estricta de personal y ubicación |
| `ITAR` | Control de exportaciones de EE.UU. | Solo personas estadounidenses |
| `EU_REGIONS_AND_SUPPORT` | UE | Ubicación de datos en la UE + personal de soporte basado en la UE |
| `CA_REGIONS_AND_SUPPORT` | Canadá | Datos y soporte canadienses |
| `HIPAA` / `HITRUST` | Salud en EE.UU. | Restricción de servicios aplicables + BAA |
| `IRS_1075` | Datos tributarios de EE.UU. | Controles de ubicación y de personal |

### 10.3 Access Transparency y Access Approval

| | **Access Transparency** | **Access Approval** | **Key Access Justifications** |
|---|---|---|---|
| Te da | Una entrada de log cada vez que personal de Google accede a tu contenido, con una justificación y una referencia de ticket | Una compuerta explícita de **aprobar/denegar** antes de que ese acceso ocurra | Una justificación adjunta a cada petición *criptográfica* de desenvolvimiento, que tu gestor de claves externo puede auto-denegar |
| ¿Bloquea el acceso? | No — solo visibilidad | **Sí** | **Sí**, y de forma unilateral, fuera del control de Google |
| Requiere | Nivel del plan de soporte | Access Transparency habilitado | Cloud EKM |

```bash
$ gcloud logging read 'logName:"cloudaudit.googleapis.com%2Faccess_transparency"' \
    --project=pay-api-prod-4471 --limit=3 \
    --format="table(timestamp, protoPayload.metadata.reason[0].type, protoPayload.metadata.reason[0].detail, protoPayload.resourceName)"
TIMESTAMP                       TYPE                    DETAIL                       RESOURCE_NAME
2026-09-04T08:12:44.101Z        CUSTOMER_INITIATED_SUPPORT  Case number: 61024488    projects/771820039412/instances/ledger-api-3
```

`CUSTOMER_INITIATED_SUPPORT` con un número de caso que vos abriste es la forma esperada. Una entrada con un tipo que no iniciaste es un disparador de respuesta a incidentes.

---

## 11. Detección: Security Command Center y audit logs

### 11.1 Tipos de audit log

| Tipo de log | Por defecto | Costo | Registra |
|---|---|---|---|
| **Admin Activity** | **Siempre activo, no se puede desactivar** | Gratis | Escrituras de configuración/metadatos — quién creó la VM, quién cambió IAM |
| **Data Access** | **Desactivado** (excepto BigQuery) | Con cargo | Quién leyó/escribió datos, y lecturas de configuración vía API |
| **System Event** | Siempre activo | Gratis | Acciones iniciadas por Google (migración en vivo, rotación automática de claves) |
| **Policy Denied** | Siempre activo cuando se genera | Con cargo | Denegaciones de VPC-SC y otras políticas de seguridad |

### 11.2 Niveles de SCC

| | **Standard** | **Premium** | **Enterprise** |
|---|---|---|---|
| Inventario de activos, Security Health Analytics (subconjunto) | ✅ | ✅ | ✅ | 
| Security Health Analytics completo + dashboards de cumplimiento (CIS, PCI-DSS, NIST, ISO) | — | ✅ | ✅ |
| Event Threat Detection, Container Threat Detection, VM Threat Detection | — | ✅ | ✅ |
| Simulación de rutas de ataque / puntuación de exposición | — | ✅ | ✅ |
| Postura multi-nube (AWS, Azure), SIEM/SOAR integrado, gestión de casos | — | — | ✅ |

```bash
$ gcloud scc findings list 889201773455 \
    --source=- \
    --filter='state="ACTIVE" AND severity="HIGH" OR severity="CRITICAL"' \
    --format="table(finding.category, finding.severity, finding.resourceName.basename(), finding.eventTime)" \
    --limit=8
CATEGORY                          SEVERITY  RESOURCE_NAME             EVENT_TIME
PUBLIC_BUCKET_ACL                 HIGH      legacy-reports-eu         2026-09-07T22:14:03Z
OVER_PRIVILEGED_SERVICE_ACCOUNT   HIGH      etl-nightly               2026-09-07T21:02:55Z
SERVICE_ACCOUNT_KEY_NOT_ROTATED   MEDIUM    reporting-legacy          2026-09-07T20:41:18Z
OPEN_FIREWALL                     CRITICAL  allow-all-legacy-2019     2026-09-07T19:33:07Z
NON_ORG_IAM_MEMBER                HIGH      contractor@gmail.com      2026-09-06T14:20:41Z
```

---

## 12. Verificación y diagnóstico de fallos

### 12.1 Una pasada de verificación que podés correr de punta a punta

```bash
# 1. No basic roles anywhere in the org
$ gcloud asset search-all-iam-policies \
    --scope=organizations/889201773455 \
    --query='policy:(roles/owner OR roles/editor)' \
    --format="table(resource, policy.bindings[].role, policy.bindings[].members)" \
  | head -20
RESOURCE                                                              ROLE           MEMBERS
//cloudresourcemanager.googleapis.com/projects/sandbox-dev-1902       roles/editor   ['user:contractor@example.com']

# 2. No external principals
$ gcloud asset search-all-iam-policies \
    --scope=organizations/889201773455 \
    --query='policy:(allUsers OR allAuthenticatedUsers)' \
    --format="value(resource)"
(no output — clean)

# 3. No user-managed service account keys
$ for p in $(gcloud projects list --format='value(projectId)'); do
    for sa in $(gcloud iam service-accounts list --project="$p" --format='value(email)' 2>/dev/null); do
      n=$(gcloud iam service-accounts keys list --iam-account="$sa" \
            --managed-by=user --format='value(name)' 2>/dev/null | wc -l)
      [ "$n" -gt 0 ] && echo "KEY  $p  $sa  ($n)"
    done
  done
KEY  reporting-legacy-3301  bi-extract@reporting-legacy-3301.iam.gserviceaccount.com  (2)

# 4. Buckets without CMEK or without public access prevention
$ gcloud storage buckets list --format="table(name, default_kms_key, public_access_prevention, uniform_bucket_level_access.enabled)"
NAME                     DEFAULT_KMS_KEY                                                                                   PUBLIC_ACCESS_PREVENTION  ENABLED
pay-ledger-archive-eu    projects/sec-kms-prod-1180/locations/europe-west1/keyRings/ledger-eu/cryptoKeys/ledger-data        enforced                  True
legacy-reports-eu                                                                                                          inherited                 False

# 5. Effective org policy resolution at a leaf
$ gcloud org-policies list --project=pay-api-prod-4471 --format="table(constraint, spec.rules[0])"

# 6. Resolve what a principal can actually do (Policy Analyzer)
$ gcloud asset analyze-iam-policy \
    --organization=889201773455 \
    --identity="user:alice@example.com" \
    --format="table(analysisResults[].iamBinding.role, analysisResults[].attachedResourceFullName)"
```

### 12.2 Catálogo de fallos — síntoma → causa raíz → solución

**A. Violación de organization policy**

```
$ gcloud compute instances create web-1 --zone=europe-west1-b --address=""
ERROR: (gcloud.compute.instances.create) Could not fetch resource:
 - Constraint constraints/compute.vmExternalIpAccess violated for project
   pay-api-prod-4471. Add instance projects/pay-api-prod-4471/zones/europe-west1-b/instances/web-1
   to the constraint to use external IP with it.
```
*Causa raíz:* la baranda funcionando como fue diseñada.
*Diagnóstico:* `gcloud org-policies describe compute.vmExternalIpAccess --project=... --effective` para averiguar si vino de la folder o de la organización.
*Solución:* poné la carga de trabajo detrás de un balanceador de carga y Cloud NAT — no abras un agujero. Si es genuinamente necesario, sobrescribí en el proyecto con una excepción documentada y una fecha de vencimiento.

---

**B. Denegación de VPC Service Controls — la más difícil de diagnosticar**

```
$ gcloud storage cp gs://pay-ledger-archive-eu/2026-08.parquet .
ERROR: (gcloud.storage.cp) HTTPError 403: Request is prohibited by organization's policy.
vpcServiceControlsUniqueIdentifier: L7cQ2mF9xR4tYb1oN8pW3sVzKj0aHdGe
```

El mensaje deliberadamente no revela nada. El identificador es la clave de unión hacia el audit log:

```bash
$ gcloud logging read '
    protoPayload.metadata."@type"="type.googleapis.com/google.cloud.audit.VpcServiceControlAuditMetadata"
    AND protoPayload.metadata.vpcServiceControlsUniqueId="L7cQ2mF9xR4tYb1oN8pW3sVzKj0aHdGe"
  ' --organization=889201773455 --limit=1 --format=json
```
```json
{
  "protoPayload": {
    "authenticationInfo": { "principalEmail": "alice@example.com" },
    "methodName": "google.storage.objects.get",
    "serviceName": "storage.googleapis.com",
    "metadata": {
      "dryRun": false,
      "violationReason": "NO_MATCHING_ACCESS_LEVEL",
      "securityPolicyInfo": {
        "servicePerimeterName": "accessPolicies/419320017722/servicePerimeters/ledger_eu"
      },
      "ingressViolations": [
        { "targetResource": "projects/771820039411",
          "servicePerimeter": "accessPolicies/419320017722/servicePerimeters/ledger_eu" }
      ]
    },
    "requestMetadata": { "callerIp": "203.0.113.44" }
  },
  "severity": "ERROR"
}
```

| `violationReason` | Significado | Solución |
|---|---|---|
| `NO_MATCHING_ACCESS_LEVEL` | El llamante está fuera del perímetro y no coincidió con ningún nivel de acceso | Agregar una regla de ingreso o llevar al llamante a un dispositivo/red corporativa de confianza |
| `RESOURCES_NOT_IN_SAME_SERVICE_PERIMETER` | Los proyectos origen y destino están en perímetros distintos | Regla de egreso, o un puente de perímetro |
| `SERVICE_NOT_ALLOWED_FROM_VPC` | La restricción de `vpcAccessibleServices` bloquea la API desde dentro de la VPC | Agregar el servicio a `allowedServices` |
| `NETWORK_NOT_IN_SAME_SERVICE_PERIMETER` | La VPC no está asociada al perímetro | Agregar el proyecto host al perímetro |

---

**C. Permiso del service agent para CMEK — el fallo más común de Terraform**

```
$ gcloud storage buckets create gs://ledger-new-eu --location=EU \
    --default-encryption-key=projects/sec-kms-prod-1180/locations/europe-west1/keyRings/ledger-eu/cryptoKeys/ledger-data
ERROR: (gcloud.storage.buckets.create) HTTPError 400: Permission denied on Cloud KMS key.
Please ensure that your Cloud Storage service agent
service-771820039412@gs-project-accounts.iam.gserviceaccount.com
has been granted the Cloud KMS CryptoKey Encrypter/Decrypter role.
```
*Causa raíz:* cada servicio de Google usa una identidad de **service agent** por proyecto para tocar KMS en tu nombre. No es la service account de tu carga de trabajo.
*Solución:*
```bash
$ gcloud kms keys add-iam-policy-binding ledger-data \
    --keyring=ledger-eu --location=europe-west1 --project=sec-kms-prod-1180 \
    --member="serviceAccount:service-771820039412@gs-project-accounts.iam.gserviceaccount.com" \
    --role="roles/cloudkms.cryptoKeyEncrypterDecrypter"
Updated IAM policy for key [ledger-data].
```
*Notá la regla de región:* la clave de KMS debe estar en la misma ubicación que el recurso (o en `global` donde esté soportado). Un bucket multi-región `EU` necesita una clave multi-región `europe`; una clave `europe-west1` será rechazada.

---

**D. Workload Identity en GKE devuelve la identidad del nodo, no la de la carga de trabajo**

```
$ kubectl -n payments exec deploy/ledger-api -- \
    curl -s -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email
771820039412-compute@developer.gserviceaccount.com
```
*Síntoma:* la service account **por defecto de Compute Engine**, no `ledger-api@…`.
*Causas raíz, por orden de frecuencia:*
1. Workload Identity no está habilitado en el **node pool** (habilitarlo a nivel de clúster no alcanza):
```bash
$ gcloud container node-pools update confidential-pool \
    --cluster=ledger-gke-eu --region=europe-west1 \
    --workload-metadata=GKE_METADATA
```
2. El namespace/nombre de la anotación de la KSA no coincide exactamente con la cadena del miembro de `workloadIdentityUser`.
3. Falta el binding de `roles/iam.workloadIdentityUser` en la service account de **Google**.

Verificá el binding:
```bash
$ gcloud iam service-accounts get-iam-policy \
    ledger-api@pay-api-prod-4471.iam.gserviceaccount.com --format=yaml
bindings:
- members:
  - serviceAccount:pay-api-prod-4471.svc.id.goog[payments/ledger-api]
  role: roles/iam.workloadIdentityUser
```

---

**E. "¿Por qué este principal no puede hacer X?" — Policy Troubleshooter**

```bash
$ gcloud policy-troubleshoot iam \
    //cloudresourcemanager.googleapis.com/projects/pay-ledger-prod-9922 \
    --principal-email=alice@example.com \
    --permission=bigquery.tables.getData
access: NOT_GRANTED
explainedPolicies:
- access: NOT_GRANTED
  bindingExplanations:
  - access: NOT_GRANTED
    role: roles/bigquery.dataViewer
    rolePermission: ROLE_PERMISSION_INCLUDED
    condition:
      expression: request.time < timestamp("2026-09-01T00:00:00Z")
    conditionRelevance: HEURISTICAL_RELEVANCE_HIGH
    memberships:
      user:alice@example.com:
        membership: MEMBERSHIP_INCLUDED
  fullResourceName: //cloudresourcemanager.googleapis.com/projects/pay-ledger-prod-9922
```
*Lectura:* el rol sí contiene el permiso y alice está en el binding — pero la **condición de IAM expiró**. Esta es la herramienta a la que hay que recurrir antes de agregar cualquier concesión nueva; evita la sobre-concesión refleja que crea el siguiente hallazgo de auditoría.

---

**F. Falso positivo de Cloud Armor**

```bash
$ gcloud logging read '
    resource.type="http_load_balancer"
    AND jsonPayload.enforcedSecurityPolicy.outcome="DENY"
  ' --project=pay-api-prod-4471 --limit=3 \
  --format="table(
      httpRequest.requestUrl,
      httpRequest.remoteIp,
      jsonPayload.enforcedSecurityPolicy.name,
      jsonPayload.enforcedSecurityPolicy.priority,
      jsonPayload.statusDetails)"
REQUEST_URL                                  REMOTE_IP        NAME                 PRIORITY  STATUS_DETAILS
https://api.example.com/v1/search?q=1--2     198.51.100.7     ledger-edge-policy   1000      denied_by_security_policy
```
*Causa raíz:* la cadena de búsqueda `1--2` coincidió con una firma de SQLi.
*Solución:* agregá una exclusión dirigida en lugar de bajar la sensibilidad global:
```bash
$ gcloud compute security-policies rules create 900 \
    --security-policy=ledger-edge-policy \
    --expression="request.path.matches('/v1/search')" \
    --action=allow \
    --description="Search endpoint: WAF exclusion, validated server-side with parameterised queries"
```
La descripción importa: una exclusión es una aceptación de riesgo documentada, y solo es defendible porque el endpoint usa consultas parametrizadas.

---

## 13. Síntesis: qué pregunta el examen, y qué exige producción

| Afirmación a nivel de examen (CDL) | Implicación a nivel de producción (Platform Architect) |
|---|---|
| "Google asegura la infraestructura; vos asegurás lo que ponés dentro de ella" | Escribí la matriz de responsabilidades *por servicio* que realmente usás; el límite es distinto para GKE Standard y GKE Autopilot |
| "Los datos están cifrados en reposo y en tránsito por defecto" | Cierto, e insuficiente para datos regulados — decidí GMEK vs CMEK vs EKM contra un requisito de un regulador concreto, y presupuestá la dependencia de disponibilidad de KMS |
| "Mínimo privilegio" | Sin roles básicos; grupos y no usuarios; predefinidos antes que personalizados; condiciones con vencimiento; cero claves de SA, impuesto por org policy |
| "Zero trust significa nunca confiar, siempre verificar" | IAP + niveles de acceso reemplazando la VPN; ingreso de firewall limitado a `35.235.240.0/20`; postura del dispositivo por petición |
| "La nube ayuda con el cumplimiento" | Las certificaciones de Google cubren la infraestructura; **tu configuración está dentro del alcance de tu auditoría**. Assured Workloads acorta la brecha; SCC Premium la evidencia |
| "La privacidad no es seguridad" | Access Transparency/Approval y KAJ son controles de privacidad; no endurecen nada, y el cifrado no los satisface |
| "IAM protege tus datos" | IAM protege el *acceso*. La exfiltración por un principal autorizado es un problema de VPC-SC, y VPC-SC es el control que más patrimonios no tienen |

**Las tres cosas a habilitar primero en cualquier organización nueva**, ordenadas por reducción de riesgo por unidad de esfuerzo:

1. `constraints/iam.disableServiceAccountKeyCreation` + `constraints/iam.allowedPolicyMemberDomains` — elimina estructuralmente los dos vectores de brecha más frecuentes.
2. Un log sink de auditoría a nivel de organización hacia un proyecto de logging separado y restringido — porque no podés investigar lo que no registraste, y los logs de Data Access están desactivados por defecto.
3. Un perímetro de VPC-SC en **dry-run** alrededor de tus proyectos con los datos joya de la corona — no cuesta nada, no bloquea nada, y produce el inventario de exfiltración que hoy no tenés.

---

## 14. Referencias

Fuentes oficiales de Google. Cada URL de abajo es un documento publicado por Google.

**Guía del examen**
- Cloud Digital Leader exam guide — https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
- Cloud Digital Leader certification — https://cloud.google.com/learn/certification/cloud-digital-leader

**Responsabilidad compartida, destino compartido, arquitectura**
- Shared responsibility and shared fate on Google Cloud — https://cloud.google.com/architecture/framework/security/shared-responsibility-shared-fate
- Google Cloud Architecture Framework: Security, privacy and compliance — https://cloud.google.com/architecture/framework/security
- Google Cloud security foundations blueprint — https://cloud.google.com/architecture/security-foundations
- Google infrastructure security design overview — https://cloud.google.com/docs/security/infrastructure/design

**Identidad y acceso**
- IAM overview — https://cloud.google.com/iam/docs/overview
- IAM roles and permissions — https://cloud.google.com/iam/docs/roles-overview
- Deny policies — https://cloud.google.com/iam/docs/deny-overview
- Principal access boundary policies — https://cloud.google.com/iam/docs/principal-access-boundary-policies
- IAM Conditions — https://cloud.google.com/iam/docs/conditions-overview
- Best practices for service accounts — https://cloud.google.com/iam/docs/best-practices-service-accounts
- Workload Identity Federation — https://cloud.google.com/iam/docs/workload-identity-federation
- Workforce Identity Federation — https://cloud.google.com/iam/docs/workforce-identity-federation
- GKE Workload Identity Federation — https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity
- Policy Troubleshooter — https://cloud.google.com/policy-intelligence/docs/troubleshoot-access

**Jerarquía de recursos y barandas**
- Resource hierarchy — https://cloud.google.com/resource-manager/docs/cloud-platform-resource-hierarchy
- Organization Policy Service — https://cloud.google.com/resource-manager/docs/organization-policy/overview
- Organization policy constraints — https://cloud.google.com/resource-manager/docs/organization-policy/org-policy-constraints
- Custom organization policy constraints — https://cloud.google.com/resource-manager/docs/organization-policy/creating-managing-custom-constraints

**Cifrado y gestión de claves**
- Default encryption at rest — https://cloud.google.com/docs/security/encryption/default-encryption
- Encryption in transit — https://cloud.google.com/docs/security/encryption-in-transit
- Customer-managed encryption keys (CMEK) — https://cloud.google.com/kms/docs/cmek
- Cloud External Key Manager (EKM) — https://cloud.google.com/kms/docs/ekm
- Key Access Justifications — https://cloud.google.com/cloud-provider-access-management/key-access-justifications/docs/overview
- Customer-supplied encryption keys — https://cloud.google.com/compute/docs/disks/customer-supplied-encryption
- Cloud HSM — https://cloud.google.com/kms/docs/hsm
- Confidential Computing — https://cloud.google.com/confidential-computing/docs
- Shielded VM — https://cloud.google.com/security/shielded-cloud/shielded-vm

**Red y perímetro**
- VPC Service Controls overview — https://cloud.google.com/vpc-service-controls/docs/overview
- VPC-SC dry-run mode — https://cloud.google.com/vpc-service-controls/docs/dry-run-mode
- VPC-SC troubleshooting — https://cloud.google.com/vpc-service-controls/docs/troubleshooting
- Access Context Manager — https://cloud.google.com/access-context-manager/docs/overview
- Identity-Aware Proxy — https://cloud.google.com/iap/docs/concepts-overview
- Private Google Access — https://cloud.google.com/vpc/docs/private-google-access
- Cloud Armor security policies — https://cloud.google.com/armor/docs/security-policy-overview
- Cloud Armor preconfigured WAF rules — https://cloud.google.com/armor/docs/waf-rules
- Cloud Armor Adaptive Protection — https://cloud.google.com/armor/docs/adaptive-protection-overview
- BeyondCorp / zero trust — https://cloud.google.com/beyondcorp

**Detección, cumplimiento, privacidad**
- Security Command Center overview — https://cloud.google.com/security-command-center/docs/security-command-center-overview
- Cloud Audit Logs — https://cloud.google.com/logging/docs/audit
- Configuring Data Access audit logs — https://cloud.google.com/logging/docs/audit/configure-data-access
- Sensitive Data Protection — https://cloud.google.com/sensitive-data-protection/docs
- Assured Workloads — https://cloud.google.com/assured-workloads/docs/overview
- Compliance offerings and resource centre — https://cloud.google.com/security/compliance/offerings
- Access Transparency — https://cloud.google.com/cloud-provider-access-management/access-transparency/docs/overview
- Access Approval — https://cloud.google.com/cloud-provider-access-management/access-approval/docs/overview
- Privacy commitments for Google Cloud — https://cloud.google.com/privacy
- Binary Authorization — https://cloud.google.com/binary-authorization/docs
- Risk Protection Program — https://cloud.google.com/security/risk-protection-program