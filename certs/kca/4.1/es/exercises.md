# Ejercicios — 4.1 Aplicando políticas en el clúster

> **Alcance.** "Política" en un clúster de Kubernetes no es un único objeto: es una familia de puntos de aplicación que una solicitud atraviesa en su camino hacia `etcd`. Este laboratorio recorre la cadena completa: **política de autorización** (RBAC), **política de admisión** integrada en el API server (Pod Security Admission, `ResourceQuota`/`LimitRange`, `ValidatingAdmissionPolicy`), **política de red** (dataplane) y, finalmente, un **motor de políticas externo** (Kyverno) para reglas que las integradas no pueden expresar. Después de cada bloque respondés preguntas de verificación; todas las respuestas están en la sección plegable al final.

## El modelo mental: dónde se aplica la política

Cada solicitud de escritura al API server pasa por este pipeline. Saber *qué etapa* rechaza una solicitud es la habilidad de diagnóstico más útil para este tema.

```
kubectl apply
      │
      ▼
[ Authentication ]  who are you?            → certs / tokens / OIDC
      │
      ▼
[ Authorization ]   are you allowed?        → RBAC (Role/ClusterRole)      ← policy
      │
      ▼
[ Mutating admission ]   rewrite the object → MutatingWebhook, LimitRange defaults  ← policy
      │
      ▼
[ Object schema validation ]  is it valid Kubernetes?
      │
      ▼
[ Validating admission ]   accept / reject  → PodSecurity, ResourceQuota,
      │                                        ValidatingAdmissionPolicy,
      │                                        ValidatingWebhook (Kyverno/Gatekeeper)  ← policy
      ▼
   persisted to etcd
      │
      ▼
[ Dataplane, runtime ]   NetworkPolicy (CNI) enforces pod-to-pod traffic  ← policy
```

Dos hechos se desprenden de este diagrama y vale la pena interiorizarlos antes de tocar una terminal:

1. **Los fallos de RBAC devuelven `403 Forbidden` en la autorización** — antes de que siquiera se analice un objeto. Los fallos de admisión también devuelven `403 Forbidden`, pero el mensaje nombra el plugin de admisión (`violates PodSecurity`, `exceeded quota`, `ValidatingAdmissionPolicy ... denied`). El estado HTTP es el mismo; el *mensaje* te dice la etapa.
2. **La `NetworkPolicy` la aplica la CNI, no el API server.** El objeto siempre se acepta y se almacena; que el tráfico realmente se bloquee depende por completo del plugin del dataplane.

Fuentes: [Admission Controllers Reference](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/) · [Controlling Access to the API](https://kubernetes.io/docs/concepts/security/controlling-access/)

---

## Requisitos previos del laboratorio

Necesitás un clúster corriendo **Kubernetes v1.30 o más nuevo** (v1.30 es donde `ValidatingAdmissionPolicy` alcanzó GA). Para el **Ejercicio 4** necesitás una CNI que *aplique* `NetworkPolicy` — Calico, Cilium o Antrea. La CNI por defecto de `kind` (`kindnet`) crea los objetos pero silenciosamente **no** los aplica.

```bash
# Option A — minikube with a policy-enforcing CNI
minikube start --kubernetes-version=v1.31.0 --cni=calico

# Option B — kind (fine for Exercises 1,2,3,5; install Calico for Exercise 4)
kind create cluster --image kindest/node:v1.31.0

# Confirm version and that the PodSecurity + ValidatingAdmissionPolicy plugins are active
kubectl version -o json | grep -m1 gitVersion
kubectl api-resources | grep -Ei 'validatingadmissionpolicy|resourcequota|networkpolic'
```

Esperado (abreviado):

```
"gitVersion": "v1.31.0",
validatingadmissionpolicies             admissionregistration.k8s.io/v1   false   ValidatingAdmissionPolicy
validatingadmissionpolicybindings       admissionregistration.k8s.io/v1   false   ValidatingAdmissionPolicyBinding
resourcequotas               quotas     v1                                true    ResourceQuota
networkpolicies              netpol     networking.k8s.io/v1              true    NetworkPolicy
```

---

## Ejercicio 1 — Pod Security Admission (Pod Security Standards)

`PodSecurityPolicy` fue removido en v1.25. Su reemplazo integrado es **Pod Security Admission (PSA)**: un controlador de admisión de validación que aplica uno de tres **Pod Security Standards** — `privileged` (sin restricciones), `baseline` (bloquea escaladas de privilegios conocidas), `restricted` (endurecido, mejores prácticas) — a nivel de **namespace**, gobernado puramente por labels.

| Label | Valores | Efecto |
|---|---|---|
| `pod-security.kubernetes.io/enforce` | `privileged` `baseline` `restricted` | **rechaza** pods no conformes |
| `pod-security.kubernetes.io/audit`   | ídem | registra una violación en el audit log, el pod se admite |
| `pod-security.kubernetes.io/warn`    | ídem | devuelve un `Warning:` al cliente, el pod se admite |
| `pod-security.kubernetes.io/<mode>-version` | `v1.31` … `latest` | fija el estándar a una versión de Kubernetes |

**Pasos**

1. Creá un namespace y aplicá el estándar `restricted` en los tres modos. Fijar `enforce` a una versión mientras dejás que `warn`/`audit` sigan a `latest` es el patrón de despliegue estándar — obtenés advertencias con visión de futuro sin romper las cargas de trabajo existentes.

   ```bash
   kubectl create namespace secure

   kubectl label namespace secure \
     pod-security.kubernetes.io/enforce=restricted \
     pod-security.kubernetes.io/enforce-version=v1.31 \
     pod-security.kubernetes.io/warn=restricted \
     pod-security.kubernetes.io/audit=restricted
   ```

2. Confirmá que los labels quedaron aplicados:

   ```bash
   kubectl get namespace secure --show-labels
   ```
   ```
   NAME     STATUS   AGE   LABELS
   secure   Active   4s    kubernetes.io/metadata.name=secure,pod-security.kubernetes.io/audit=restricted,pod-security.kubernetes.io/enforce-version=v1.31,pod-security.kubernetes.io/enforce=restricted,pod-security.kubernetes.io/warn=restricted
   ```

3. Intentá crear un pod **sin** `securityContext`. Guardalo como `legacy-app.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: legacy-app
     namespace: secure
   spec:
     containers:
     - name: app
       image: busybox:1.36
       command: ["sh", "-c", "sleep 3600"]
   ```
   ```bash
   kubectl apply -f legacy-app.yaml
   ```
   ```
   Error from server (Forbidden): error when creating "legacy-app.yaml": pods "legacy-app" is
   forbidden: violates PodSecurity "restricted:v1.31": allowPrivilegeEscalation != false
   (container "app" must set securityContext.allowPrivilegeEscalation=false), unrestricted
   capabilities (container "app" must set securityContext.capabilities.drop=["ALL"]),
   runAsNonRoot != true (pod or container "app" must set securityContext.runAsNonRoot=true),
   seccompProfile (pod or container "app" must set securityContext.seccompProfile.type to
   "RuntimeDefault" or "Localhost")
   ```

4. Ahora creá un pod **conforme**. Guardalo como `hardened.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: hardened
     namespace: secure
   spec:
     securityContext:
       runAsNonRoot: true
       runAsUser: 1000
       seccompProfile:
         type: RuntimeDefault
     containers:
     - name: app
       image: busybox:1.36
       command: ["sh", "-c", "sleep 3600"]
       securityContext:
         allowPrivilegeEscalation: false
         capabilities:
           drop: ["ALL"]
   ```
   ```bash
   kubectl apply -f hardened.yaml
   kubectl get pod -n secure hardened
   ```
   ```
   pod/hardened created
   NAME       READY   STATUS    RESTARTS   AGE
   hardened   1/1     Running   0          6s
   ```

5. Demostrá que `enforce` actúa sobre el **namespace, no sobre la carga de trabajo**. Un `Deployment` se admite (no es un Pod), pero su `ReplicaSet` no puede crear el pod — apareciendo como `warn` al aplicar y como un evento en el ReplicaSet.

   ```bash
   kubectl create deployment bad --image=busybox:1.36 -n secure -- sleep 3600
   ```
   ```
   Warning: would violate PodSecurity "restricted:v1.31": allowPrivilegeEscalation != false ...
   deployment.apps/bad created
   ```
   ```bash
   kubectl get deploy,rs,pod -n secure -l app=bad
   ```
   ```
   NAME                  READY   UP-TO-DATE   AVAILABLE   AGE
   deployment.apps/bad   0/1     0            0           10s

   NAME                            DESIRED   CURRENT   READY   AGE
   replicaset.apps/bad-6c9f7bd94   1         0         0       10s
   ```
   ```bash
   kubectl describe rs -n secure -l app=bad | grep -A2 Events
   ```
   ```
   Events:
     Warning  FailedCreate  4s (x3 over 12s)  replicaset-controller  Error creating: pods
     "bad-6c9f7bd94-..." is forbidden: violates PodSecurity "restricted:v1.31": ...
   ```

> **Q1.** Un estudiante establece solo `pod-security.kubernetes.io/warn=restricted` en un namespace y reporta "la política no funciona — el pod malo sigue corriendo". ¿Qué está pasando realmente y qué label necesita?
>
> **Q2.** En el Paso 5 el comando `kubectl create deployment` *tuvo éxito* (exit 0), pero ningún pod corrió. Explicá con precisión por qué la aplicación no bloqueó el objeto `Deployment` en sí, y dónde apareció el rechazo en su lugar.
>
> **Q3.** Tu pod conforme pone `runAsNonRoot`/`seccompProfile` a nivel de **pod** pero `allowPrivilegeEscalation`/`capabilities` a nivel de **container**. ¿Por qué no pueden vivir los cuatro a nivel de pod?

Fuentes: [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/) · [Pod Security Admission](https://kubernetes.io/docs/concepts/security/pod-security-admission/) · [Enforce Standards with Namespace Labels](https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-namespace-labels/)

---

## Ejercicio 2 — Gobernanza de recursos: `ResourceQuota` + `LimitRange`

Estos dos objetos responden preguntas diferentes. Una **`ResourceQuota`** limita el consumo *agregado* de un namespace (CPU total, memoria total, cantidad de objetos). Un **`LimitRange`** restringe y aplica valores por defecto a *objetos individuales* (mín/máx por container, y requests/limits por defecto cuando el autor los omite). Se entrelazan: cuando una `ResourceQuota` limita un recurso de cómputo, **cada pod debe declarar ese request/limit** — y un `LimitRange` es lo que permite a los desarrolladores seguir omitiéndolos al proveer valores por defecto en la admisión de mutación.

**Pasos**

1. Creá un namespace con ambos objetos. Guardalo como `governance.yaml`:

   ```yaml
   apiVersion: v1
   kind: Namespace
   metadata:
     name: dev
   ---
   apiVersion: v1
   kind: ResourceQuota
   metadata:
     name: team-quota
     namespace: dev
   spec:
     hard:
       requests.cpu: "2"
       requests.memory: 2Gi
       limits.cpu: "4"
       limits.memory: 4Gi
       pods: "10"
       count/deployments.apps: "5"
   ---
   apiVersion: v1
   kind: LimitRange
   metadata:
     name: default-limits
     namespace: dev
   spec:
     limits:
     - type: Container
       default:            # applied as limits if container omits them
         cpu: 500m
         memory: 256Mi
       defaultRequest:     # applied as requests if container omits them
         cpu: 250m
         memory: 128Mi
       max:
         cpu: "2"
         memory: 2Gi
   ```
   ```bash
   kubectl apply -f governance.yaml
   kubectl describe resourcequota team-quota -n dev
   ```
   ```
   Name:                   team-quota
   Namespace:              dev
   Resource                Used  Hard
   --------                ----  ----
   count/deployments.apps  0     5
   limits.cpu              0     4
   limits.memory           0     4Gi
   pods                    0     10
   requests.cpu            0     2
   requests.memory         0     2Gi
   ```

2. Creá un pod que **no** declare recursos y observá cómo el `LimitRange` inyecta los valores por defecto para que la cuota quede satisfecha:

   ```bash
   kubectl run web --image=nginx:1.27-alpine -n dev
   kubectl get pod web -n dev -o jsonpath='{.spec.containers[0].resources}' | python3 -m json.tool
   ```
   ```json
   {
       "limits":   { "cpu": "500m", "memory": "256Mi" },
       "requests": { "cpu": "250m", "memory": "128Mi" }
   }
   ```

3. Ahora eliminá el `LimitRange` y repetí — los valores por defecto desaparecen y la cuota rechaza el pod pelado:

   ```bash
   kubectl delete limitrange default-limits -n dev
   kubectl run web2 --image=nginx:1.27-alpine -n dev
   ```
   ```
   Error from server (Forbidden): pods "web2" is forbidden: failed quota: team-quota: must
   specify limits.cpu for: web2; limits.memory for: web2; requests.cpu for: web2;
   requests.memory for: web2
   ```

4. Recreá el `LimitRange`, luego excedé la cuota **agregada** de request de CPU para ver el rechazo basado en conteo:

   ```bash
   kubectl apply -f governance.yaml    # restores the LimitRange
   # Each replica requests 250m; 2 CPU quota / 250m ≈ 8 pods, then the 9th trips requests.cpu
   kubectl create deployment fill --image=nginx:1.27-alpine -n dev --replicas=9
   kubectl get deploy fill -n dev
   ```
   ```
   NAME   READY   UP-TO-DATE   AVAILABLE   AGE
   fill   7/9     7            7           15s
   ```
   ```bash
   kubectl describe rs -n dev -l app=fill | grep -A2 Events
   ```
   ```
   Events:
     Warning  FailedCreate  ...  replicaset-controller  Error creating: pods "fill-..." is
     forbidden: exceeded quota: team-quota, requested: requests.cpu=250m, used:
     requests.cpu=2, limited: requests.cpu=2
   ```

> **Q4.** El pod `web` del Paso 2 pidió `250m` de CPU aunque el YAML que aplicaste no establecía recursos en absoluto. Nombrá las dos etapas de admisión involucradas y el orden en que se ejecutaron.
>
> **Q5.** En el Paso 4 el Deployment pidió 9 réplicas pero solo 7 se levantaron, y `kubectl get deploy` muestra `7/9` indefinidamente sin ningún error en el Deployment. ¿Dónde mirás para encontrar *por qué* está atascado, y cuál es el arreglo que mantiene las 9 dentro de la misma cuota?
>
> **Q6.** Tu compañero dice "tenemos un `LimitRange` con valores por defecto, así que no necesitamos requests en nuestros manifiestos". ¿Bajo qué condición de cuota es peligrosa esa afirmación, y cuál es el modo de fallo si el `LimitRange` alguna vez se elimina?

Fuentes: [Resource Quotas](https://kubernetes.io/docs/concepts/policy/resource-quotas/) · [Limit Ranges](https://kubernetes.io/docs/concepts/policy/limit-range/)

---

## Ejercicio 3 — Política de admisión nativa: `ValidatingAdmissionPolicy` (CEL)

Antes de v1.30 la única manera de escribir política de clúster personalizada era un webhook externo (Gatekeeper/Kyverno) — un salto de red, un pod que mantener vivo, una `failurePolicy` que razonar. **`ValidatingAdmissionPolicy` (VAP)** mueve las reglas simples *in-process*, evaluadas en el API server usando **CEL** (Common Expression Language). Sin webhook, sin pod extra, sin latencia. Dos objetos: la **política** (la regla) y el **binding** (dónde aplica).

**Pasos**

1. Escribí una política que limite las réplicas de un Deployment y exija que cada container establezca un límite de memoria. Guardala como `vap.yaml`:

   ```yaml
   apiVersion: admissionregistration.k8s.io/v1
   kind: ValidatingAdmissionPolicy
   metadata:
     name: workload-guardrails.policy.example.com
   spec:
     failurePolicy: Fail
     matchConstraints:
       resourceRules:
       - apiGroups:   ["apps"]
         apiVersions: ["v1"]
         operations:  ["CREATE", "UPDATE"]
         resources:   ["deployments"]
     validations:
       - expression: "object.spec.replicas <= 5"
         message: "Deployments may not exceed 5 replicas in this namespace."
         reason: Invalid
       - expression: >-
           object.spec.template.spec.containers.all(c,
             has(c.resources) && has(c.resources.limits) &&
             has(c.resources.limits.memory))
         message: "Every container must set spec...resources.limits.memory."
         reason: Invalid
   ```

2. La política por sí sola **no hace nada** hasta que un **binding** la activa. Guardalo como `vap-binding.yaml`:

   ```yaml
   apiVersion: admissionregistration.k8s.io/v1
   kind: ValidatingAdmissionPolicyBinding
   metadata:
     name: workload-guardrails-binding.example.com
   spec:
     policyName: workload-guardrails.policy.example.com
     validationActions: ["Deny"]        # Deny | Warn | Audit (combinable)
     matchResources:
       namespaceSelector:
         matchLabels:
           environment: prod
   ```
   ```bash
   kubectl apply -f vap.yaml
   kubectl apply -f vap-binding.yaml
   kubectl create namespace prod
   kubectl label namespace prod environment=prod
   ```

3. Violá el tope de réplicas:

   ```bash
   kubectl create deployment big --image=nginx:1.27-alpine -n prod --replicas=8
   ```
   ```
   error: failed to create deployment: deployments.apps "big" is forbidden:
   ValidatingAdmissionPolicy 'workload-guardrails.policy.example.com' with binding
   'workload-guardrails-binding.example.com' denied request: Deployments may not exceed
   5 replicas in this namespace.
   ```

4. Probá que el binding es de **alcance por namespace**: el mismo manifiesto se acepta en el namespace `dev` sin label.

   ```bash
   kubectl create deployment big --image=nginx:1.27-alpine -n dev --replicas=8
   ```
   ```
   deployment.apps/big created
   ```

5. (Avanzado) Cambiá el binding a observación no bloqueante antes de aplicar en todo el clúster — el orden de despliegue seguro para cualquier política. Editá `validationActions` a `["Warn", "Audit"]`, reaplicá, y una creación que viola ahora tiene éxito con una advertencia:

   ```bash
   kubectl create deployment big2 --image=nginx:1.27-alpine -n prod --replicas=8
   ```
   ```
   Warning: Validation failed for ValidatingAdmissionPolicy
   'workload-guardrails.policy.example.com' with binding
   'workload-guardrails-binding.example.com': Deployments may not exceed 5 replicas...
   deployment.apps/big2 created
   ```

> **Q7.** Aplicaste la `ValidatingAdmissionPolicy` pero un Deployment que viola en `prod` igual fue admitido. Confirmás que el objeto de política existe con `kubectl get validatingadmissionpolicy`. ¿Qué único objeto te falta, y cuál es su rol?
>
> **Q8.** `failurePolicy: Fail` en una VAP significa algo muy diferente de `failurePolicy: Fail` en una `ValidatingWebhookConfiguration` en términos de *riesgo de disponibilidad*. Explicá la diferencia y por qué la versión de VAP es mucho más segura.
>
> **Q9.** Dá la edición de una línea en CEL que haría que la regla de réplicas *saltee* los Deployments cuyo campo `spec.replicas` no esté establecido (para que nunca falle con un null), en lugar de asumir que el campo siempre está presente.

Fuentes: [Validating Admission Policy](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/) · [CEL in Kubernetes](https://kubernetes.io/docs/reference/using-api/cel/)

---

## Ejercicio 4 — Segmentación de red: `NetworkPolicy`

*(Requiere una CNI que aplique políticas — ver requisitos previos.)* Los pods están **no aislados por defecto**: cualquier pod puede alcanzar a cualquier pod. Una `NetworkPolicy` que selecciona un pod lo cambia a **denegación por defecto para la dirección seleccionada**, tras lo cual solo pasa el tráfico explícitamente permitido. Las políticas son **aditivas** (unión de whitelist) y las aplica la CNI en el dataplane — el API server siempre almacena el objeto.

**Pasos**

1. Desplegá una app de tres capas y confirmá primero la conectividad abierta:

   ```bash
   kubectl create namespace shop
   kubectl run api      --image=hashicorp/http-echo -n shop -l app=api      -- -text=api -listen=:8080
   kubectl run frontend --image=busybox:1.36        -n shop -l app=frontend -- sleep 3600
   kubectl run attacker --image=busybox:1.36        -n shop -l app=attacker -- sleep 3600
   kubectl expose pod api -n shop --port=8080

   kubectl exec -n shop frontend -- wget -qO- --timeout=2 http://api:8080; echo
   kubectl exec -n shop attacker -- wget -qO- --timeout=2 http://api:8080; echo
   ```
   ```
   api
   api
   ```

2. Aplicá una línea base de **default-deny-ingress** para todo el namespace. Guardala como `deny.yaml`:

   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: default-deny-ingress
     namespace: shop
   spec:
     podSelector: {}          # selects every pod in the namespace
     policyTypes:
     - Ingress                # no ingress rules ⇒ deny all inbound
   ```
   ```bash
   kubectl apply -f deny.yaml
   kubectl exec -n shop frontend -- wget -qO- --timeout=2 http://api:8080; echo "exit=$?"
   ```
   ```
   wget: download timed out
   exit=1
   ```

3. Reabrí **solo** `frontend → api:8080` con una política de permiso dirigida. Guardala como `allow.yaml`:

   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-frontend-to-api
     namespace: shop
   spec:
     podSelector:
       matchLabels:
         app: api
     policyTypes:
     - Ingress
     ingress:
     - from:
       - podSelector:
           matchLabels:
             app: frontend
       ports:
       - protocol: TCP
         port: 8080
   ```
   ```bash
   kubectl apply -f allow.yaml
   kubectl exec -n shop frontend -- wget -qO- --timeout=2 http://api:8080; echo   # allowed
   kubectl exec -n shop attacker -- wget -qO- --timeout=2 http://api:8080; echo "exit=$?"  # still denied
   ```
   ```
   api
   wget: download timed out
   exit=1
   ```

> **Q10.** Entre el Paso 1 y el Paso 2 aplicaste *solo* una política de denegación y la llamada `frontend → api` se rompió. Pero `attacker → api` también se rompió. Dado que la política de denegación tiene un `podSelector: {}` vacío, explicá por qué el modelo aditivo termina bloqueando a `attacker` incluso después de que el Paso 3 vuelve a permitir `frontend`.
>
> **Q11.** Aplicás exactamente los mismos manifiestos en un clúster `kind` recién creado con la CNI por defecto y *todos* los `wget` tienen éxito, haya política de denegación o no. Los objetos están presentes (`kubectl get netpol -n shop` los lista). ¿Qué está mal, y por qué el API server no te advierte?
>
> **Q12.** Un colega agrega una segunda política de permiso para que `frontend` también pueda alcanzar `api` en el puerto `9090`. ¿Necesitan modificar `allow-frontend-to-api`, o pueden agregar una política separada? ¿Qué propiedad de `NetworkPolicy` hace que esto sea así?

Fuentes: [Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)

---

## Ejercicio 5 — Política de autorización: RBAC + `auth can-i`

RBAC es la capa de política que corre *antes* de la admisión: decide si el llamante puede realizar un verbo sobre un recurso en absoluto. Los cuatro objetos son `Role`/`ClusterRole` (los permisos) y `RoleBinding`/`ClusterRoleBinding` (quién los obtiene). La mejor manera de *probar* una política de autorización sin suplantar credenciales es `kubectl auth can-i --as`.

**Pasos**

1. Creá un rol acotado, de mínimo privilegio, para una service account de CI — solo lectura de pods, nada más. Guardalo como `rbac.yaml`:

   ```yaml
   apiVersion: v1
   kind: ServiceAccount
   metadata:
     name: ci-bot
     namespace: dev
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     name: pod-reader
     namespace: dev
   rules:
   - apiGroups: [""]
     resources: ["pods", "pods/log"]
     verbs: ["get", "list", "watch"]
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: ci-bot-reads-pods
     namespace: dev
   subjects:
   - kind: ServiceAccount
     name: ci-bot
     namespace: dev
   roleRef:
     kind: Role
     name: pod-reader
     apiGroup: rbac.authorization.k8s.io
   ```
   ```bash
   kubectl apply -f rbac.yaml
   ```

2. Probá la política desde el punto de vista del sujeto con suplantación (`--as`). El formato del nombre de usuario de la service account es `system:serviceaccount:<namespace>:<name>`:

   ```bash
   kubectl auth can-i list pods   -n dev --as system:serviceaccount:dev:ci-bot
   kubectl auth can-i delete pods -n dev --as system:serviceaccount:dev:ci-bot
   kubectl auth can-i get pods    -n prod --as system:serviceaccount:dev:ci-bot
   kubectl auth can-i get secrets -n dev --as system:serviceaccount:dev:ci-bot
   ```
   ```
   yes
   no
   no
   no
   ```

3. Listá todo lo que el sujeto puede hacer — la auditoría más rápida de una política de autorización:

   ```bash
   kubectl auth can-i --list -n dev --as system:serviceaccount:dev:ci-bot
   ```
   ```
   Resources                                       Non-Resource URLs   Resource Names   Verbs
   pods                                            []                  []               [get list watch]
   pods/log                                        []                  []               [get list watch]
   selfsubjectreviews.authentication.k8s.io        []                  []               [create]
   selfsubjectaccessreviews.authorization.k8s.io   []                  []               [create]
   ...
   ```

> **Q13.** ¿Por qué `get pods -n prod` devolvió `no` aunque el rol otorga `get pods`? ¿Qué palabra en los kinds de objeto que creaste lo explica, y qué objeto crearías para otorgar el mismo acceso de lectura a nivel de clúster?
>
> **Q14.** `kubectl auth can-i --list` muestra `selfsubjectaccessreviews ... [create]` para una service account a la que nunca otorgaste nada más allá de lectura de pods. ¿De dónde viene ese permiso, y es una mala configuración de política?

Fuentes: [Using RBAC Authorization](https://kubernetes.io/docs/reference/access-authn-authz/rbac/) · [Authorization Overview](https://kubernetes.io/docs/reference/access-authn-authz/authorization/)

---

## Ejercicio 6 — Extendiendo la política con un motor: Kyverno

Las integradas se detienen donde comienza la lógica entre objetos, la generación o la mutación: "todo namespace debe tener un label de propietario", "inyectar una `NetworkPolicy` por defecto en los namespaces nuevos", "bloquear imágenes que no vengan de nuestro registry". **Kyverno** es un motor de políticas de la CNCF que corre como un admission webhook y expresa esto como objetos `ClusterPolicy` nativos de Kubernetes — sin un lenguaje nuevo para el caso `validate`.

**Pasos**

1. Instalá Kyverno:

   ```bash
   kubectl create -f https://github.com/kyverno/kyverno/releases/download/v1.13.0/install.yaml
   kubectl -n kyverno rollout status deploy/kyverno-admission-controller
   ```

2. Aplicá una política `validate` que bloquee imágenes de fuera de un registry confiable. Guardala como `kyverno-registry.yaml`:

   ```yaml
   apiVersion: kyverno.io/v1
   kind: ClusterPolicy
   metadata:
     name: restrict-image-registries
   spec:
     validationFailureAction: Enforce      # Enforce blocks; Audit only reports
     background: true
     rules:
     - name: only-trusted-registry
       match:
         any:
         - resources:
             kinds: ["Pod"]
       validate:
         message: "Images must come from registry.example.com/."
         pattern:
           spec:
             containers:
             - image: "registry.example.com/*"
   ```
   ```bash
   kubectl apply -f kyverno-registry.yaml
   kubectl run pub --image=nginx:1.27-alpine -n dev
   ```
   ```
   Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

   resource Pod/dev/pub was blocked due to the following policies

   restrict-image-registries:
     only-trusted-registry: 'validation error: Images must come from
       registry.example.com/. rule only-trusted-registry failed at path /spec/containers/0/image/'
   ```

3. Confirmá el reporte y el estado de la política:

   ```bash
   kubectl get clusterpolicy restrict-image-registries
   ```
   ```
   NAME                        ADMISSION   BACKGROUND   READY   AGE
   restrict-image-registries   true        true         True    30s
   ```

> **Q15.** El mensaje de rechazo de Kyverno nombra `admission webhook "validate.kyverno.svc-fail"`, mientras que el rechazo de la VAP del Ejercicio 3 no nombró ningún webhook. Rastreá cada rechazo hasta su etapa en el pipeline de admisión y establecé el costo operativo que el mecanismo del Ejercicio 3 evita.
>
> **Q16.** Kyverno puede hacer una cosa en esta familia de ejercicios que *ninguno* de los mecanismos integrados (PSA, ResourceQuota, VAP, NetworkPolicy, RBAC) puede hacer en tiempo de admisión. Nombrá el tipo de regla y dá un ejemplo de una línea de cuándo recurrirías a ella.

Fuentes: [Kyverno Documentation](https://kyverno.io/docs/) · [OPA/Gatekeeper](https://open-policy-agent.github.io/gatekeeper/website/docs/) · [Dynamic Admission Control](https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/)

---

## Limpieza

```bash
kubectl delete namespace secure dev prod shop --ignore-not-found
kubectl delete validatingadmissionpolicy workload-guardrails.policy.example.com --ignore-not-found
kubectl delete validatingadmissionpolicybinding workload-guardrails-binding.example.com --ignore-not-found
kubectl delete clusterpolicy restrict-image-registries --ignore-not-found
# Optional: kubectl delete -f https://github.com/kyverno/kyverno/releases/download/v1.13.0/install.yaml
```

---

## Respuestas

<details>
<summary>Hacé clic para revelar las respuestas (Q1–Q16)</summary>

**A1.** `warn` nunca bloquea nada — solo devuelve un `Warning:` del lado del cliente y admite el pod. Existe precisamente para *observar* el impacto antes de aplicar. Para rechazar pods no conformes deben establecer `pod-security.kubernetes.io/enforce=<standard>`. Los tres modos son independientes y aditivos; un namespace típicamente lleva `enforce` en una versión fija más `warn`/`audit` en `latest`.

**A2.** PSA es un controlador de admisión a nivel de Pod: inspecciona el `spec` del objeto `Pod`. Un `Deployment` es un kind diferente (`apps/v1`), así que nada en él viola un estándar de *pod* en el momento en que lo creás — el objeto se admite. El controlador del Deployment más tarde crea un `ReplicaSet`, cuyo controlador intenta crear el `Pod` real; *esa* creación llega a PSA y es rechazada. El fallo aparece como un `Warning` en el apply inicial (PSA advierte sobre el controlador contenedor) y como eventos `FailedCreate` recurrentes en el ReplicaSet — nunca como un exit distinto de cero en el comando `kubectl create deployment`. Por esto los huecos de aplicación se esconden: el objeto de nivel superior se ve sano.

**A3.** `runAsNonRoot` y `seccompProfile` existen en **ambos** `pod.spec.securityContext` y `container.spec.securityContext`, y un valor a nivel de pod aplica a cada container — así que pueden establecerse una sola vez a nivel de pod. `allowPrivilegeEscalation` y `capabilities` existen **solo** en el `securityContext` del *container* (son propiedades de un proceso/container, no del sandbox compartido del pod). No hay campo a nivel de pod para ellos, así que deben repetirse por container.

**A4.** (1) **La admisión de mutación** corrió primero: el plugin de admisión `LimitRange` inyectó `defaultRequest`/`default` en el pod porque el autor los omitió. (2) **La admisión de validación** corrió después: el plugin `ResourceQuota` entonces vio un pod que *sí* declaraba requests/limits y lo admitió contra la cuota. El orden importa — si la validación de cuota corriera antes de la mutación del LimitRange, el pod pelado sería rechazado. El pipeline es mutación → validación exactamente por esta razón.

**A5.** Los objetos Deployment/ReplicaSet están bien; los *pods* están siendo rechazados por la cuota. Mirá los eventos del ReplicaSet (`kubectl describe rs -n dev -l app=fill`) — verás `FailedCreate ... exceeded quota: team-quota`. `kubectl get deploy` muestra `7/9` sin error porque el controlador del Deployment sigue reintentando y el fallo vive en el objeto hijo. El arreglo es hacer entrar las 9 dentro de la cuota: bajar el request por container (p. ej. `100m` × 9 = `900m` < `2`) vía los valores por defecto del `LimitRange` o requests explícitos, o subir la cuota.

**A6.** Es peligrosa siempre que la `ResourceQuota` limite un **recurso de cómputo** (`requests.cpu`, `limits.memory`, …): la cuota entonces *requiere* que cada pod declare ese request/limit, y lo único que satisface ese requisito es el valor por defecto del `LimitRange`. Si el `LimitRange` se elimina (o nunca existió en un namespace nuevo copiado sin él), cada pod de manifiesto pelado es rechazado con `failed quota: ... must specify requests.cpu ...` — una caída para nuevos pods en todo el namespace, exactamente como se muestra en el Paso 3. Defensa en profundidad: poné requests/limits explícitos en los manifiestos *y* mantené el `LimitRange` como red de seguridad.

**A7.** El **`ValidatingAdmissionPolicyBinding`**. Una `ValidatingAdmissionPolicy` es inerte por sí sola — define la regla pero no dónde ni cómo se aplica. El binding establece `validationActions` (`Deny`/`Warn`/`Audit`) y `matchResources` (qué namespaces/recursos). Esta separación es deliberada: una política puede vincularse a muchos alcances con acciones diferentes (p. ej. `Deny` en `prod`, `Warn` en `staging`) sin duplicar el CEL.

**A8.** Para una `ValidatingWebhookConfiguration`, `failurePolicy: Fail` significa *si el pod del webhook externo es inalcanzable, la solicitud falla* — un deployment de Gatekeeper/Kyverno caído o sobrecargado puede atascar las escrituras de todo el clúster. VAP se evalúa **in-process dentro del API server**; no hay un endpoint externo que pueda estar no disponible. `failurePolicy: Fail` ahí solo gobierna qué pasa si la expresión CEL en sí falla en tiempo de ejecución (p. ej. un error de tipo), lo cual es un bug en la política, no una dependencia de disponibilidad. VAP elimina el modo de fallo "caída del motor de políticas = caída del clúster" por completo.

**A9.** Protegé el acceso al campo con `has()` y cortocircuitá:
`expression: "!has(object.spec.replicas) || object.spec.replicas <= 5"`
Esto admite Deployments que omiten `replicas` (el API server luego lo establece por defecto en 1) en lugar de fallar con un campo faltante.

**A10.** `NetworkPolicy` es una **unión de whitelist con denegación por defecto por dirección seleccionada**. El `podSelector: {}` vacío en la política de denegación selecciona a *todos* los pods en `shop` y los aísla a todos para `Ingress`. Una vez que cualquier política selecciona un pod, solo se permite el tráfico que coincide con *alguna* regla de ingress. La política de permiso del Paso 3 agrega una regla que permite `frontend → api:8080`, así que ese flujo se restaura — pero **no hay ninguna regla en ningún lado** que permita `attacker → api`, así que permanece denegado. Nunca "bloqueás a attacker" explícitamente; la denegación por defecto más la ausencia de una regla de permiso lo hacen.

**A11.** La CNI por defecto de `kind` (`kindnet`) no implementa la aplicación de `NetworkPolicy`. Los objetos son recursos válidos de Kubernetes, así que el **API server los acepta y los almacena** — la aplicación es enteramente tarea de la CNI en el dataplane, y el API server no tiene manera de saber que la CNI instalada los ignora. Este es el fallo silencioso clásico de las políticas de red: `kubectl get netpol` se ve correcto mientras nada se aplica. Arreglo: instalá Calico/Cilium/Antrea.

**A12.** Pueden agregar una política **separada**; no hace falta editar la existente. Las reglas de `NetworkPolicy` son **aditivas** — la lista de permisos efectiva para un pod es la unión de las reglas de ingress de *todas* las políticas que lo seleccionan. Una política nueva que selecciona `app: api` y permite `frontend → 9090` simplemente se suma a lo que `allow-frontend-to-api` ya permite en `8080`. (No hay un tipo de regla "deny" que pueda entrar en conflicto; solo agregás permisos).

**A13.** La palabra es **`Role`** (con namespace), vinculado por un `RoleBinding` — su otorgamiento se confina al namespace `dev`, así que el verbo/recurso idéntico en `prod` no está autorizado. Para otorgar el mismo acceso de lectura en todos los namespaces, creá un **`ClusterRole`** con las mismas reglas y un **`ClusterRoleBinding`** (o un `RoleBinding` por namespace que referencie el `ClusterRole` para un alcance selectivo).

**A14.** No es una mala configuración. `selfsubjectaccessreviews` y `selfsubjectreviews` se otorgan a los grupos integrados `system:basic-user` / `system:authenticated` vía ClusterRoleBindings por defecto que vienen con cada clúster — permiten que cualquier identidad autenticada pregunte "¿qué puedo hacer *yo*?" (que es lo que impulsa `auth can-i`). No otorgan acceso a recursos reales, solo a introspeccionar los permisos propios, así que el mínimo privilegio se mantiene intacto.

**A15.** Kyverno es una **`ValidatingWebhookConfiguration`**: el API server, en la etapa de admisión de validación, hace una llamada HTTPS saliente al pod del webhook `kyverno-svc`, cuya respuesta deniega la solicitud — de ahí que el mensaje nombre el webhook. La VAP del Ejercicio 3 se evalúa **in-process** por el API server (CEL), así que ningún webhook se nombra. El costo operativo que VAP evita: un pod de webhook desplegado por separado, siempre encendido, que agrega latencia y se convierte en una dependencia de disponibilidad (ver A8) y agrega un viaje de ida y vuelta de red a cada solicitud de admisión que coincida.

**A16.** Las reglas **`mutate`** (y `generate`) — Kyverno puede *reescribir* o *crear* objetos en la admisión: inyectar un label por defecto, agregar un sidecar, establecer `imagePullPolicy`, o autogenerar una `NetworkPolicy` de default-deny en cada namespace nuevo. De las integradas, PSA/validación-de-ResourceQuota/VAP/NetworkPolicy/RBAC son todas solo *validar-o-denegar* (LimitRange muta pero solo para su propio defaulting); ninguna puede agregar un objeto o campo arbitrario. Ejemplo: "en `CREATE Namespace`, generar una `NetworkPolicy` `default-deny-ingress` en él" — imposible con las integradas, una regla `generate` en Kyverno.

</details>