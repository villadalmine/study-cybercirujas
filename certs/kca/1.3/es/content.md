# Admission Controllers

> **KCA · Dominio 1 · Tema 1.3** — Peso en el examen: **4.5**
> Nivel: SRE de Producción / Arquitecto de Plataforma

---

## 1. El problema arquitectónico: por qué el API server no alcanza

La autenticación responde *quién* está llamando. La autorización (RBAC, ABAC, Node, Webhook) responde *qué verbos sobre qué recursos* puede usar el llamante. Ninguna responde la pregunta que domina los incidentes reales de producción:

> "Esta petición está autenticada y autorizada, pero ¿debería el objeto resultante **tener permitido existir tal como está escrito**, y si no, podemos **arreglarlo** antes de que se persista?"

RBAC es de grano grueso: concede `create pods` en un namespace o no. No puede expresar "podés crear Pods, pero solo desde registries bajo `registry.corp.internal`, nunca como root, siempre con límites de recursos, y cada Pod debe llevar una label `cost-center`". Esa política es una propiedad del *payload del objeto*, y RBAC nunca inspecciona el payload.

Los admission controllers son el punto de imposición donde el API server inspecciona y opcionalmente reescribe el payload, después de authZ y antes de la escritura en etcd. Son la última compuerta síncrona en el camino de escritura. Todo lo que está aguas abajo — el scheduler, el kubelet, los controllers — confía en que lo que sea que llegó a etcd ya satisface la política del cluster. Si un objeto no conforme aterriza en etcd, ninguna lógica de admisión volverá a examinarlo jamás; ahora estás haciendo detección-y-remediación en lugar de prevención.

### El camino de la petición

```
                    kube-apiserver request lifecycle (write path)
  ┌──────────────┐   ┌───────────────┐   ┌───────────────────────────────────────┐
  │  HTTP handler│──▶│ Authentication│──▶│ Authorization (RBAC / Node / Webhook)  │
  └──────────────┘   └───────────────┘   └───────────────────────────────────────┘
          │
          ▼
  ┌──────────────────────────────────────────────────────────────────────────────┐
  │ MUTATING ADMISSION (in fixed internal order)                                   │
  │   built-in mutating plugins (ServiceAccount, DefaultStorageClass, LimitRanger, │
  │   Priority, RuntimeClass...) + MutatingAdmissionWebhook + MutatingAdmissionPolicy│
  └──────────────────────────────────────────────────────────────────────────────┘
          │  (object may now differ from what the client sent)
          ▼
  ┌──────────────────────────────────────────────────────────────────────────────┐
  │ OBJECT SCHEMA VALIDATION + defaulting (OpenAPI / structural schema)            │
  └──────────────────────────────────────────────────────────────────────────────┘
          │
          ▼
  ┌──────────────────────────────────────────────────────────────────────────────┐
  │ VALIDATING ADMISSION (in fixed internal order, run in parallel where possible) │
  │   built-in validating plugins (PodSecurity, ResourceQuota, NamespaceLifecycle) │
  │   + ValidatingAdmissionPolicy (CEL) + ValidatingAdmissionWebhook               │
  └──────────────────────────────────────────────────────────────────────────────┘
          │  any single reject => whole request fails (atomic)
          ▼
  ┌──────────────┐
  │    etcd      │  persisted
  └──────────────┘
```

Dos invariantes que un Arquitecto de Plataforma debe internalizar:

1. **La mutación siempre precede a la validación.** No podés validar el objeto final hasta que todo mutador se haya ejecutado. Por eso un mutating webhook que inyecta un sidecar se ejecuta *antes* que el validating webhook que verifica que el sidecar está presente.
2. **La validación es un AND lógico.** Una petición se admite solo si **cada** etapa de validación dice sí. Un solo rechazo en cualquier lugar aborta toda la escritura — el objeto nunca se crea parcialmente.

---

## 2. Taxonomía: las tres generaciones del control de admisión

Hay tres mecanismos de implementación fundamentalmente distintos. Elegir entre ellos es la decisión de diseño central de este tema.

| Mecanismo | Dónde se ejecuta | Lenguaje | Latencia añadida | Riesgo de disponibilidad | Uso típico |
|---|---|---|---|---|---|
| **Plugins compilados** | Dentro de kube-apiserver | Go (incluido con k8s) | ~0 (en proceso) | Ninguno (parte del apiserver) | Valores por defecto a nivel de cluster, cuotas, PodSecurity, inyección de ServiceAccount |
| **Webhooks de admisión dinámicos** | Pod(s) HTTPS externos | Cualquiera (Go, Rust, Rego, JS…) | 1 ida y vuelta de red por petición que coincide (≤30s) | **Alto** — un webhook caído con `failurePolicy: Fail` puede congelar la API | Política específica de la organización, lógica entre objetos, búsquedas de datos externos |
| **Policies CEL (`ValidatingAdmissionPolicy` / `MutatingAdmissionPolicy`)** | Dentro de kube-apiserver | Expresiones CEL en CRs | ~0 (en proceso) | Ninguno (sin pod externo) | Validación declarativa y autocontenida y mutación simple sin operar un webhook |

### 2.1 Plugins compilados

Se habilitan/deshabilitan con flags de kube-apiserver. El **orden en la cadena de flags es irrelevante** — el API server ejecuta los plugins en un orden fijo codificado en duro.

```bash
$ ps -ef | grep kube-apiserver | tr ' ' '\n' | grep admission
--enable-admission-plugins=NodeRestriction,PodSecurity,ResourceQuota
--disable-admission-plugins=DefaultTolerationSeconds
--admission-control-config-file=/etc/kubernetes/admission/admission-config.yaml
```

Inspeccioná qué está compilado y habilitado por defecto:

```bash
$ kube-apiserver -h | grep -A3 'enable-admission-plugins'
--enable-admission-plugins strings
    admission plugins that should be enabled in addition to default enabled ones
    (NamespaceLifecycle, LimitRanger, ServiceAccount, TaintNodesByCondition,
    PodSecurity, Priority, DefaultTolerationSeconds, DefaultStorageClass,
    StorageObjectInUseProtection, PersistentVolumeClaimResize, RuntimeClass,
    CertificateApproval, CertificateSigning, ClusterTrustBundleAttest,
    CertificateSubjectRestriction, DefaultIngressClass, MutatingAdmissionWebhook,
    ValidatingAdmissionPolicy, ValidatingAdmissionWebhook, ResourceQuota).
    Comma-delimited list...
```

Dos entradas en esa lista por defecto son la **plomería** de todo lo que está en §2.2 y §2.3: `MutatingAdmissionWebhook` y `ValidatingAdmissionWebhook`. Si cualquiera está deshabilitado, tus webhooks se ignoran silenciosamente — sin error, simplemente nunca se disparan. `ValidatingAdmissionPolicy` es de igual manera la plomería de las policies CEL.

### 2.2 Webhooks de admisión dinámicos

Dos kinds de configuración, ambos `admissionregistration.k8s.io/v1`:

- `MutatingWebhookConfiguration` — puede devolver un JSON Patch para reescribir el objeto.
- `ValidatingWebhookConfiguration` — solo puede permitir o denegar (más advertencias).

El API server serializa el objeto entrante en un `AdmissionReview` (`admission.k8s.io/v1`), lo envía por POST sobre TLS a tu endpoint, y lee de vuelta un `AdmissionReview`.

### 2.3 Policies CEL

`ValidatingAdmissionPolicy` (GA en v1.30) y `MutatingAdmissionPolicy` (alpha en v1.32, beta en v1.34) te permiten expresar la política como expresiones CEL evaluadas *dentro* del API server. Sin pod de webhook, sin TLS, sin salto de red, sin acoplamiento de disponibilidad. Este es el valor por defecto moderno para política que no necesita datos externos.

---

## 3. Mutating vs Validating — la decisión que hace tropezar a la gente

| Propiedad | Mutating | Validating |
|---|---|---|
| ¿Puede cambiar el objeto? | **Sí** (devuelve un JSON Patch) | No |
| ¿Puede rechazar el objeto? | Sí (pero desaconsejado — rechazá en la validación) | Sí |
| ¿En qué fase se ejecuta? | Primera fase | Segunda fase |
| ¿Orden dentro de la fase garantizado? | **No** — tratalo como sin orden | No |
| ¿Re-invocación posible? | Sí, si `reinvocationPolicy: IfNeeded` | Nunca |
| ¿Puede observar la salida de otros mutadores? | Solo después de la re-invocación | Siempre ve el objeto final |
| Requisito de idempotencia | **Obligatorio** | N/A (solo lectura) |

**La trampa de la re-invocación.** Los mutating webhooks dentro de una fase se ejecutan en un **orden no especificado**, y un mutador posterior puede cambiar algo que uno anterior ya inspeccionó. Con `reinvocationPolicy: IfNeeded`, el API server puede llamar a tu mutating webhook **una segunda vez** después de que otros webhooks hayan mutado el objeto. Por lo tanto todo mutating webhook **debe ser idempotente**: aplicarlo a su propia salida no debe producir ningún cambio adicional. Un webhook que añade un contenedor sidecar sin chequear primero si ese sidecar ya existe lo inyectará dos veces.

**Regla general:** mutá para *dar valores por defecto e inyectar*; validá para *imponer y rechazar*. No rechaces dentro de un mutating webhook si podés evitarlo — una separación limpia hace mucho más fácil razonar sobre las fallas y te permite fijar distintos valores de `failurePolicy` por cada consideración.

---

## 4. El protocolo de cable AdmissionReview

Todo webhook habla este contrato. Entenderlo es lo que separa operar webhooks de meramente instalarlos.

**Petición que envía el API server (ejemplo de mutación):**

```json
{
  "apiVersion": "admission.k8s.io/v1",
  "kind": "AdmissionReview",
  "request": {
    "uid": "b4e3a9f2-6a1c-4f7e-9d0a-2c8f1e5b7a90",
    "kind": {"group": "", "version": "v1", "kind": "Pod"},
    "resource": {"group": "", "version": "v1", "resource": "pods"},
    "namespace": "payments",
    "operation": "CREATE",
    "userInfo": {"username": "system:serviceaccount:ci:deployer",
                 "groups": ["system:serviceaccounts", "system:authenticated"]},
    "object": { "kind": "Pod", "metadata": {"name": "api-7c9"}, "spec": {"...": "..."} },
    "oldObject": null,
    "dryRun": false,
    "options": {"kind": "CreateOptions", "apiVersion": "meta.k8s.io/v1"}
  }
}
```

**Respuesta que tu webhook debe devolver** — notá que `uid` **debe reflejar** el `uid` de la petición, o el API server rechaza la respuesta:

```json
{
  "apiVersion": "admission.k8s.io/v1",
  "kind": "AdmissionReview",
  "response": {
    "uid": "b4e3a9f2-6a1c-4f7e-9d0a-2c8f1e5b7a90",
    "allowed": true,
    "patchType": "JSONPatch",
    "patch": "W3sib3AiOiJhZGQiLCJwYXRoIjoiL21ldGFkYXRhL2xhYmVscy9pbmplY3RlZCIsInZhbHVlIjoidHJ1ZSJ9XQ=="
  }
}
```

Ese `patch` es **JSON Patch codificado en base64 (RFC 6902)**. Decodificado:

```bash
$ echo 'W3sib3AiOiJhZGQiLCJwYXRoIjoiL21ldGFkYXRhL2xhYmVscy9pbmplY3RlZCIsInZhbHVlIjoidHJ1ZSJ9XQ==' | base64 -d | jq
[
  {
    "op": "add",
    "path": "/metadata/labels/injected",
    "value": "true"
  }
]
```

**Una denegación** lleva un status estructurado que el cliente ve literalmente:

```json
{
  "apiVersion": "admission.k8s.io/v1",
  "kind": "AdmissionReview",
  "response": {
    "uid": "b4e3a9f2-6a1c-4f7e-9d0a-2c8f1e5b7a90",
    "allowed": false,
    "status": {
      "code": 403,
      "message": "image registry docker.io is not in the allowlist [registry.corp.internal]"
    }
  }
}
```

---

## 5. Construcción de producción: un validating webhook que impone la procedencia de las imágenes

Objetivo: rechazar cualquier Pod cuyos contenedores descarguen desde fuera de `registry.corp.internal`. Esta es la barrera de protección canónica de la cadena de suministro.

### 5.1 El servidor del webhook (Go, recortado a la lógica de admisión)

```go
package main

import (
	"crypto/tls"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"

	admissionv1 "k8s.io/api/admission/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

const allowedPrefix = "registry.corp.internal/"

func handleValidate(w http.ResponseWriter, r *http.Request) {
	var review admissionv1.AdmissionReview
	if err := json.NewDecoder(r.Body).Decode(&review); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	req := review.Request

	var pod corev1.Pod
	if err := json.Unmarshal(req.Object.Raw, &pod); err != nil {
		writeResponse(w, req.UID, false, "cannot decode Pod: "+err.Error())
		return
	}

	all := append(pod.Spec.InitContainers, pod.Spec.Containers...)
	for _, c := range all {
		if !strings.HasPrefix(c.Image, allowedPrefix) {
			msg := fmt.Sprintf("container %q uses disallowed image %q; only %s* is permitted",
				c.Name, c.Image, allowedPrefix)
			writeResponse(w, req.UID, false, msg)
			return
		}
	}
	writeResponse(w, req.UID, true, "")
}

func writeResponse(w http.ResponseWriter, uid string, allowed bool, msg string) {
	resp := admissionv1.AdmissionReview{
		TypeMeta: metav1.TypeMeta{APIVersion: "admission.k8s.io/v1", Kind: "AdmissionReview"},
		Response: &admissionv1.AdmissionResponse{UID: uid, Allowed: allowed},
	}
	if !allowed {
		resp.Response.Result = &metav1.Status{Code: 403, Message: msg}
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/validate", handleValidate)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(200) })
	srv := &http.Server{
		Addr:      ":8443",
		Handler:   mux,
		TLSConfig: &tls.Config{MinVersion: tls.VersionTLS12},
	}
	// Certs mounted by cert-manager into the pod.
	srv.ListenAndServeTLS("/tls/tls.crt", "/tls/tls.key")
}
```

### 5.2 TLS: el problema del caBundle

El API server solo hablará con un webhook por HTTPS, y debe confiar en el certificado del servidor. La CA que firmó el certificado de servicio del webhook tiene que fijarse en el campo `caBundle` de la configuración. En producción delegás esto a **cert-manager** con el `ca-injector`, que observa la configuración y escribe el `caBundle` por vos.

```yaml
# certificate issued by an internal CA ClusterIssuer, mounted into the webhook pod
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: image-guard-tls
  namespace: policy-system
spec:
  secretName: image-guard-tls
  dnsNames:
    - image-guard.policy-system.svc
    - image-guard.policy-system.svc.cluster.local
  issuerRef:
    name: internal-ca
    kind: ClusterIssuer
  duration: 2160h      # 90d
  renewBefore: 360h    # 15d
```

### 5.3 Deployment + Service

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: image-guard
  namespace: policy-system
spec:
  replicas: 3                      # HA is not optional for a Fail-closed webhook
  selector:
    matchLabels: {app: image-guard}
  template:
    metadata:
      labels: {app: image-guard}
    spec:
      topologySpreadConstraints:   # never lose all replicas to one node/zone
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels: {app: image-guard}
      containers:
        - name: server
          image: registry.corp.internal/policy/image-guard:v1.4.2
          args: ["--tls-cert=/tls/tls.crt", "--tls-key=/tls/tls.key"]
          ports:
            - {containerPort: 8443, name: https}
          readinessProbe:
            httpGet: {path: /healthz, port: 8443, scheme: HTTPS}
            periodSeconds: 5
          resources:
            requests: {cpu: 100m, memory: 128Mi}
            limits:   {cpu: 500m, memory: 256Mi}
          volumeMounts:
            - {name: tls, mountPath: /tls, readOnly: true}
      volumes:
        - name: tls
          secret: {secretName: image-guard-tls}
---
apiVersion: v1
kind: Service
metadata:
  name: image-guard
  namespace: policy-system
spec:
  selector: {app: image-guard}
  ports:
    - {port: 443, targetPort: 8443}
```

### 5.4 El ValidatingWebhookConfiguration — cada campo explicado

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: image-provenance.corp.internal
  annotations:
    cert-manager.io/inject-ca-from: policy-system/image-guard-tls   # ca-injector fills caBundle
webhooks:
  - name: image-provenance.corp.internal          # must be a fully-qualified DNS name
    admissionReviewVersions: ["v1"]               # versions your server understands
    sideEffects: None                             # no out-of-band writes; safe under dryRun
    failurePolicy: Fail                            # deny if the webhook is unreachable (fail-closed)
    matchPolicy: Equivalent                       # also match equivalent API group/version aliases
    timeoutSeconds: 5                              # 1..30; keep tight, it is on the write path
    reinvocationPolicy: Never                      # (validating; field exists only on mutating)
    clientConfig:
      service:
        namespace: policy-system
        name: image-guard
        path: /validate
        port: 443
      caBundle: ""                                 # injected by cert-manager; leave empty
    rules:
      - operations: ["CREATE", "UPDATE"]
        apiGroups: [""]
        apiVersions: ["v1"]
        resources: ["pods"]
        scope: Namespaced
    namespaceSelector:                             # scope the blast radius
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system", "policy-system"] # never gate the control plane or yourself
    objectSelector:                                # optional escape hatch for break-glass
      matchExpressions:
        - key: policy.corp/exempt
          operator: DoesNotExist
```

**Los cuatro campos que causan la mayoría de los incidentes de producción:**

| Campo | Valores | Por qué importa | Valor por defecto seguro |
|---|---|---|---|
| `failurePolicy` | `Fail` \| `Ignore` | `Fail` = un webhook roto bloquea todas las escrituras que coinciden (incluidas las de `kube-system` si te olvidaste de excluirlo). `Ignore` = la política deja de imponerse silenciosamente. | `Fail` **solo después** de excluir los namespaces del plano de control y correr en HA |
| `sideEffects` | `None` \| `NoneOnDryRun` | Si tu webhook escribe estado externo, declaralo, o `kubectl --dry-run=server` corrompe datos. v1 prohíbe `Some`/`Unknown`. | `None` |
| `timeoutSeconds` | `1`–`30` | Cada escritura que coincide espera hasta este tiempo. Un timeout de 30s × un webhook colgado = un API server estancado. | `5` o menos |
| `namespaceSelector` | selector | La barrera de protección más importante: **excluí `kube-system` y el propio namespace del webhook**, o una caída del webhook se convierte en una caída del cluster que no podés arreglar a través de la API. | excluir los ns del plano de control |

---

## 6. La alternativa moderna: `ValidatingAdmissionPolicy` (CEL, en proceso)

La misma regla de procedencia de imágenes, **sin pod, sin TLS, sin salto de red, sin acoplamiento de disponibilidad**. Esto es lo que un Arquitecto de Plataforma usa primero en clusters de 2024 en adelante.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: "image-provenance"
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups:   [""]
        apiVersions: ["v1"]
        operations:  ["CREATE", "UPDATE"]
        resources:   ["pods"]
  variables:
    - name: images
      expression: >-
        object.spec.containers.map(c, c.image) +
        object.spec.initContainers.map(c, c.image)
  validations:
    - expression: >-
        variables.images.all(img, img.startsWith('registry.corp.internal/'))
      message: "all images must come from registry.corp.internal"
      reason: Forbidden
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: "image-provenance-binding"
spec:
  policyName: "image-provenance"
  validationActions: [Deny]              # Deny | Warn | Audit — can combine
  matchResources:
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: ["kube-system"]
```

La **policy** define la lógica; el **binding** decide *dónde* se aplica y *qué hacer* (`Deny`, `Warn`, `Audit`). Esta separación es poderosa: desplegá una policy en modo `Audit` a nivel de cluster, observá las anotaciones de auditoría, luego cambiá el binding a `Deny` una vez que sabés qué habrías roto.

**Variables CEL disponibles en las expresiones:** `object`, `oldObject`, `request`, `params` (de `paramKind`), `namespaceObject`, `authorizer`, y cualquier `variables` que definas. Una policy parametrizada toma su lista de permitidos de un ConfigMap o CRD vía `paramKind`/`paramRef`, así la misma policy compilada sirve a muchos equipos.

### Webhook vs policy CEL — la tabla de selección

| Consideración | Webhook | `ValidatingAdmissionPolicy` (CEL) |
|---|---|---|
| Necesita datos externos (LDAP, escáner de imágenes, DB) | ✅ posible | ❌ CEL es autocontenido |
| Lógica compleja/Turing-completa | ✅ cualquier lenguaje | ⚠️ CEL es intencionalmente no Turing-completo |
| Mutación | ✅ (mutating webhook) | ⚠️ `MutatingAdmissionPolicy` (beta v1.34) |
| Costo operativo | Pod, HA, TLS, certificados, actualizaciones | Ninguno — viene en el objeto de configuración |
| Riesgo de disponibilidad para el API server | Alto (`Fail` + caída = API congelada) | Ninguno (en proceso) |
| Latencia | 1 ida y vuelta de red | Microsegundos |
| Despliegue auditar-luego-imponer | Manual | Integrado vía `validationActions` del binding |

**Guía:** si la regla puede expresarse como una función pura del/los objeto(s), usá una policy CEL. Recurrí a un webhook solo cuando necesitás datos externos o lógica de mutación que CEL no puede expresar.

---

## 7. Admisión PodSecurity — el built-in que tenés que conocer al dedillo

`PodSecurityPolicy` fue eliminado en **v1.25**. Su reemplazo es el plugin de admisión **PodSecurity**, que impone los tres **Pod Security Standards**:

| Estándar | Intención | Bloquea |
|---|---|---|
| `privileged` | Sin restricciones | nada |
| `baseline` | Prevenir escaladas de privilegios conocidas | hostNetwork, hostPID, privileged, la mayoría de hostPath, capabilities peligrosas añadidas |
| `restricted` | Mejor práctica endurecida | debe correr como non-root, `seccompProfile: RuntimeDefault`, descartar TODAS las caps, sin escalada de privilegios, tipos de volumen restringidos |

Aplicado por namespace mediante **labels**, en tres **modos** independientes:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    pod-security.kubernetes.io/enforce: restricted      # reject violating Pods
    pod-security.kubernetes.io/enforce-version: v1.31    # pin the standard to a version
    pod-security.kubernetes.io/audit: restricted        # record violations in the audit log
    pod-security.kubernetes.io/warn: restricted         # return a client warning
```

**Por qué tres modos:** `warn` y `audit` te permiten observar qué *rechazaría* `enforce: restricted` sin romper las cargas de trabajo — el camino de migración seguro para salir de un namespace permisivo. Cambiá `enforce` al final.

**Los valores por defecto y las excepciones a nivel de cluster** van en el archivo de configuración de admisión referenciado por `--admission-control-config-file`:

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
  - name: PodSecurity
    configuration:
      apiVersion: pod-security.admission.config.k8s.io/v1
      kind: PodSecurityConfiguration
      defaults:
        enforce: "baseline"
        enforce-version: "latest"
        warn: "restricted"
        audit: "restricted"
      exemptions:
        usernames: []
        runtimeClasses: []
        namespaces: ["kube-system"]   # the control plane needs privileged Pods
```

Observalo funcionando:

```bash
$ kubectl label ns payments pod-security.kubernetes.io/enforce=restricted --overwrite
namespace/payments labeled

$ kubectl -n payments run bad --image=registry.corp.internal/nginx:1.27 \
    --privileged
Error from server (Forbidden): pods "bad" is forbidden: violates PodSecurity
"restricted:v1.31": privileged (container "bad" must not set securityContext.privileged=true),
allowPrivilegeEscalation != false (container "bad" must set
securityContext.allowPrivilegeEscalation=false), unrestricted capabilities
(container "bad" must set securityContext.capabilities.drop=["ALL"]),
runAsNonRoot != true, seccompProfile (pod or container must set
securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

---

## 8. Motores de políticas: Gatekeeper vs Kyverno vs CEL nativo

Para flotas, los equipos se estandarizan en un motor de políticas en lugar de armar webhooks a mano. Tanto Gatekeeper como Kyverno son, por debajo, webhooks de admisión dinámicos empaquetados con un controlador y un lenguaje de políticas por CRD.

| Dimensión | OPA Gatekeeper | Kyverno | Políticas CEL nativas |
|---|---|---|---|
| Lenguaje de políticas | Rego | YAML (declarativo) + CEL | CEL |
| Mutación | Sí (`Assign`, `ModifySet`) | Sí (de primera clase) | `MutatingAdmissionPolicy` (beta) |
| Generar recursos | No | **Sí** (reglas `generate`) | No |
| Datos externos | `providers` / `data.inventory` | Llamadas a la API, verificación de imágenes | No |
| Se ejecuta como | Webhook + controlador | Webhook + controlador | Dentro del apiserver |
| Auditoría / dry-run | Modo `Audit`, estado de constraint | `Audit`/`Enforce`, PolicyReports | `Audit`/`Warn` del binding |
| Curva de aprendizaje | Empinada (Rego) | Suave (YAML nativo de K8s) | Moderada (CEL) |
| Acoplamiento de disponibilidad | Riesgo de caída del webhook | Riesgo de caída del webhook | Ninguno |

**Gatekeeper** — un `ConstraintTemplate` compila Rego en un nuevo CRD; las instancias de `Constraint` lo parametrizan:

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8srequiredlabels
spec:
  crd:
    spec:
      names: {kind: K8sRequiredLabels}
      validation:
        openAPIV3Schema:
          type: object
          properties: {labels: {type: array, items: {type: string}}}
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8srequiredlabels
        violation[{"msg": msg}] {
          required := input.parameters.labels
          provided := {k | input.review.object.metadata.labels[k]}
          missing := {x | x := required[_]} - provided
          count(missing) > 0
          msg := sprintf("missing required labels: %v", [missing])
        }
---
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sRequiredLabels
metadata: {name: ns-must-have-cost-center}
spec:
  match: {kinds: [{apiGroups: [""], kinds: ["Namespace"]}]}
  parameters: {labels: ["cost-center"]}
```

**Kyverno** — la misma intención, YAML puro, y puede *mutar* la label faltante en lugar de rechazar:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata: {name: require-cost-center}
spec:
  validationFailureAction: Enforce      # or Audit
  rules:
    - name: check-cost-center
      match:
        any: [{resources: {kinds: ["Namespace"]}}]
      validate:
        message: "namespace must carry a cost-center label"
        pattern:
          metadata:
            labels:
              cost-center: "?*"
```

**Guía:** para validación desde cero, preferí **CEL nativo** (sin superficie operativa). Elegí **Kyverno** cuando necesitás *generación* de recursos (auto-crear NetworkPolicy/ResourceQuota por namespace) o verificación de imágenes con un modelo de autoría nativo de K8s. Elegí **Gatekeeper** cuando ya corrés OPA y querés compartir Rego y `data.inventory` entre la admisión y otros puntos de decisión.

---

## 9. Verificación y diagnóstico de fallas

### 9.1 Confirmá que la plomería está habilitada

```bash
$ kubectl -n kube-system get pod -l component=kube-apiserver \
    -o jsonpath='{.items[0].spec.containers[0].command}' | tr ',' '\n' | grep admission
"--enable-admission-plugins=NodeRestriction,PodSecurity"

# Are webhook plugins actually on? (they are default-enabled unless disabled)
$ kubectl -n kube-system get pod -l component=kube-apiserver \
    -o yaml | grep -i disable-admission-plugins
# (empty output = nothing disabled = MutatingAdmissionWebhook/ValidatingAdmissionWebhook active)
```

### 9.2 Listá e inspeccioná las configuraciones

```bash
$ kubectl get validatingwebhookconfigurations
NAME                              WEBHOOKS   AGE
image-provenance.corp.internal    1          9d

$ kubectl get validatingwebhookconfiguration image-provenance.corp.internal \
    -o jsonpath='{.webhooks[0].failurePolicy}{"\t"}{.webhooks[0].timeoutSeconds}{"\n"}'
Fail	5

# Is the caBundle actually populated? A common cert-manager injection failure:
$ kubectl get validatingwebhookconfiguration image-provenance.corp.internal \
    -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | wc -c
1428        # >0 means injected; 0 means the API server has no CA to trust => TLS handshake fails
```

### 9.3 Reproducí un rechazo y leé la razón

```bash
$ kubectl -n payments run rogue --image=docker.io/library/nginx:latest
Error from server (Forbidden): pods "rogue" is forbidden:
container "rogue" uses disallowed image "docker.io/library/nginx:latest";
only registry.corp.internal/* is permitted
```

### 9.4 Las dos firmas de falla que todo SRE debe reconocer

**Firma A — webhook inalcanzable, `failurePolicy: Fail` (caída fail-closed):**

```bash
$ kubectl -n payments run ok --image=registry.corp.internal/nginx:1.27
Error from server (InternalError): Internal error occurred: failed calling webhook
"image-provenance.corp.internal": failed to call webhook: Post
"https://image-guard.policy-system.svc:443/validate?timeout=5s": no endpoints available
for service "image-guard"
```

Escalera de diagnóstico:

```bash
$ kubectl -n policy-system get endpoints image-guard
NAME          ENDPOINTS   AGE
image-guard   <none>      9d          # <-- zero ready pods: readiness probe failing or crashloop

$ kubectl -n policy-system get pods -l app=image-guard
NAME                           READY   STATUS             RESTARTS   AGE
image-guard-5f7c9d8b4d-2xk9p   0/1     CrashLoopBackOff   6          4m
```

Rompé el vidrio mientras lo arreglás — cambiá a `Ignore` (aceptá la no imposición temporal por sobre una API congelada), o usá la excepción `objectSelector` que construiste en §5.4:

```bash
$ kubectl patch validatingwebhookconfiguration image-provenance.corp.internal \
    --type=json -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"}]'
validatingwebhookconfiguration.admissionregistration.k8s.io/image-provenance.corp.internal patched
```

**Firma B — falla de confianza TLS (`caBundle` incorrecto o faltante):**

```
Error from server (InternalError): Internal error occurred: failed calling webhook
"image-provenance.corp.internal": failed to call webhook: Post "...": tls: failed to
verify certificate: x509: certificate signed by unknown authority
```

La causa raíz casi siempre es: el `ca-injector` de cert-manager no rellenó el `caBundle`, el SAN del certificado de servicio no coincide con `service.namespace.svc`, o el certificado rotó y el pod no lo recargó. Verificá el SAN:

```bash
$ kubectl -n policy-system get secret image-guard-tls -o jsonpath='{.data.tls\.crt}' \
    | base64 -d | openssl x509 -noout -text | grep -A1 'Subject Alternative Name'
    X509v3 Subject Alternative Name:
        DNS:image-guard.policy-system.svc, DNS:image-guard.policy-system.svc.cluster.local
```

### 9.5 Comprobá que una policy CEL está activa

```bash
$ kubectl get validatingadmissionpolicy image-provenance
NAME               VALIDATIONS   PARAMKIND   AGE
image-provenance   1            <unset>     3d

$ kubectl get validatingadmissionpolicybinding image-provenance-binding \
    -o jsonpath='{.spec.validationActions}'
["Deny"]
```

### 9.6 Confirmación por registro de auditoría

Con las acciones de admisión reflejadas en el registro de auditoría, podés confirmar qué etapa decidió una petición:

```bash
$ kubectl get --raw='/api/v1/namespaces/payments/pods' >/dev/null 2>&1
$ grep image-provenance /var/log/kubernetes/audit.log | jq '.annotations'
{
  "validation.policy.admission.k8s.io/validation_failure":
    "[{\"expression\":0,\"message\":\"all images must come from registry.corp.internal\",\"action\":\"Deny\"}]"
}
```

### 9.7 Lista de verificación de diagnóstico

| Síntoma | Causa probable | Primer comando |
|---|---|---|
| La política no se impone en absoluto | `ValidatingAdmissionWebhook` deshabilitado, o el `namespaceSelector` excluye el ns | `kubectl get pod -l component=kube-apiserver -o yaml \| grep disable-admission` |
| Todas las escrituras a un ns fallan de repente con `InternalError` | webhook caído + `failurePolicy: Fail` | `kubectl get endpoints <svc> -n <ns>` |
| `x509: certificate signed by unknown authority` | `caBundle` vacío/obsoleto o SAN que no coincide | inspeccioná `caBundle`, verificá el SAN del certificado |
| El webhook se dispara pero el objeto no cambia (mutación) | patch no está en base64, `patchType` incorrecto, o doble aplicación no idempotente | decodificá `patch`, revisá `reinvocationPolicy` |
| `dry-run` corrompe estado externo | `sideEffects` mal declarado | poné `sideEffects: None`/`NoneOnDryRun` |
| Escrituras de API lentas al azar | `timeoutSeconds` alto + webhook lento | bajá `timeoutSeconds`, añadí réplicas |

---

## 10. Principios de diseño (lista de verificación de producción)

1. **Nunca pongas una barrera al plano de control.** Excluí `kube-system` y el propio namespace del webhook del `namespaceSelector`. Un webhook `Fail`-closed que puede bloquear escrituras a su propio namespace es una caída irrecuperable.
2. **`failurePolicy: Fail` exige HA.** Múltiples réplicas, `topologySpreadConstraints`, un `PodDisruptionBudget`, un `readinessProbe` ajustado. Fail-closed sin HA es una caída autoinfligida esperando el reinicio de un nodo.
3. **Preferí CEL en proceso por sobre webhooks** siempre que la regla sea una función pura del objeto. Cero acoplamiento de disponibilidad vale más que la conveniencia sintáctica.
4. **Los mutadores deben ser idempotentes.** Asumí `reinvocationPolicy: IfNeeded` y reentrada. Chequeá-antes-de-inyectar, siempre.
5. **Desplegá en `Audit`/`Warn` antes de `Deny`/`Enforce`.** Los bindings CEL y PodSecurity hacen de esto un cambio de primera clase de dos líneas; usalo.
6. **Mantené `timeoutSeconds` pequeño (≤5s).** Está directamente en el camino de escritura síncrono de cada petición que coincide.
7. **Declará `sideEffects` honestamente** para que el dry-run del lado del servidor siga siendo seguro.
8. **Automatizá el `caBundle`** con el `ca-injector` de cert-manager; nunca pegues una CA en base64 a mano — rotará y se romperá silenciosamente.

---

## Referencias

- Admission Controllers Reference — https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- Dynamic Admission Control (webhooks) — https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/
- Validating Admission Policy (CEL) — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Mutating Admission Policy — https://kubernetes.io/docs/reference/access-authn-authz/mutating-admission-policy/
- AdmissionReview API (`admission.k8s.io/v1`) — https://kubernetes.io/docs/reference/config-api/apiserver-admission.v1/
- Admissionregistration API (`admissionregistration.k8s.io/v1`) — https://kubernetes.io/docs/reference/generated/kubernetes-api/v1.31/#validatingwebhookconfiguration-v1-admissionregistration-k8s-io
- Pod Security Admission — https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Common Expression Language in Kubernetes — https://kubernetes.io/docs/reference/using-api/cel/
- cert-manager CA Injector — https://cert-manager.io/docs/concepts/ca-injector/
- OPA Gatekeeper — https://open-policy-agent.github.io/gatekeeper/website/docs/
- Kyverno Policies — https://kyverno.io/docs/writing-policies/
- KCA Curriculum (CNCF) — https://github.com/cncf/curriculum/raw/master/KCA_Curriculum.pdf