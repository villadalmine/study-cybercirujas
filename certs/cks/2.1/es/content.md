# 2.1 Usar los estándares de seguridad de pods apropiados

## Por qué esto importa

Un Pod es, en el fondo, un pedido al kubelet para que ejecute procesos en un nodo. Sin restricciones, ese pedido puede solicitar cosas que disuelven la frontera entre contenedor y host: `privileged: true`, `hostPID: true`, un montaje `hostPath` de `/`, la capability `SYS_ADMIN`, un perfil de seccomp sin confinar. Cualquiera de esas convierte "comprometer una carga de trabajo" en "adueñarse del nodo", y desde ahí frecuentemente en "adueñarse del clúster" (las credenciales del kubelet del nodo, los tokens de service account de todos los Pods de ese nodo, el socket del runtime de contenedores).

Los **Pod Security Standards (PSS)** son la respuesta de Kubernetes a esto: tres niveles de política con nombre y versión que describen *cuánto* se le permite pedir a un Pod. El controlador **Pod Security Admission (PSA)** es el mecanismo de aplicación incorporado que aplica esos niveles en la frontera del namespace. PSA es un plugin de admisión *validante* compilado dentro de `kube-apiserver` y habilitado por defecto desde v1.23 (GA desde v1.25). Reemplazó a la API PodSecurityPolicy (PSP), ya eliminada.

Dos propiedades definen cómo hay que pensar PSA:

1. **Tiene alcance de namespace.** Un namespace se adhiere a un nivel mediante labels. No hay selector por Pod, por ServiceAccount ni por usuario como tenía PSP.
2. **Nunca muta.** PSA sólo dice sí o no. No va a agregar `runAsNonRoot: true` por vos, ni a descartar capabilities por vos. Hacer que una carga de trabajo sea conforme es tarea de quien escribe el manifiesto (o de un motor de políticas mutante).

---

## Los tres niveles

| Nivel | Intención | Uso típico |
|---|---|---|
| `privileged` | Sin restricciones. Deliberadamente abierto, permite escaladas de privilegio conocidas. | Namespaces de sistema/infraestructura: CNI, drivers CSI, agentes de nodo, `kube-system`. |
| `baseline` | Bloquea escaladas de privilegio conocidas manteniendo compatibilidad con la mayoría de las cargas de trabajo ordinarias. No requiere cambios en un manifiesto típico. | Común denominador para namespaces de aplicaciones durante la migración. |
| `restricted` | Fuertemente restringido, sigue las buenas prácticas actuales de endurecimiento de Pods. Cuesta compatibilidad. | El objetivo para namespaces de inquilinos/aplicaciones. |

Los niveles son **acumulativos**: `restricted` incluye todo lo que `baseline` prohíbe, y más.

### Qué prohíbe `baseline`

| Control | Regla |
|---|---|
| HostProcess | `securityContext.windowsOptions.hostProcess` debe estar sin definir o en `false` (pod y contenedores). |
| Namespaces del host | `hostNetwork`, `hostPID`, `hostIPC` deben estar sin definir o en `false`. |
| Contenedores privilegiados | `securityContext.privileged` debe estar sin definir o en `false`. |
| Capabilities | No puede **agregar** ninguna capability más allá de `NET_BIND_SERVICE`. |
| Volúmenes HostPath | Los volúmenes `hostPath` están prohibidos. |
| Puertos del host | `containerPort.hostPort` debe estar sin definir o en `0`. |
| AppArmor | `appArmorProfile.type` (o la anotación heredada) debe ser `RuntimeDefault` o `Localhost`; `Unconfined` está prohibido. |
| SELinux | `seLinuxOptions.type` debe estar sin definir, o ser `container_t`, `container_init_t`, `container_kvm_t` o `container_engine_t`. `seLinuxOptions.user` y `.role` deben estar sin definir. |
| Tipo de montaje de `/proc` | `procMount` debe estar sin definir o ser `Default` (es decir, no `Unmasked`). |
| Seccomp | `seccompProfile.type` puede estar sin definir, pero si se define no debe ser `Unconfined`. |
| Sysctls | Sólo una pequeña lista permitida de sysctls con namespace (por ejemplo `kernel.shm_rmid_forced`, `net.ipv4.ip_local_port_range`, `net.ipv4.ip_unprivileged_port_start`, `net.ipv4.tcp_syncookies`, `net.ipv4.ping_group_range`). La lista crece con las versiones de política. |

Fijate en lo que `baseline` **no** exige: no te obliga a ejecutar como no-root, no requiere descartar capabilities, no requiere un perfil de seccomp. Un Deployment de `nginx` estándar pasa `baseline` sin cambios.

### Qué agrega `restricted`

| Control | Regla |
|---|---|
| Tipos de volumen | Sólo `configMap`, `csi`, `downwardAPI`, `emptyDir`, `ephemeral`, `persistentVolumeClaim`, `projected`, `secret`. (La lista permitida exacta es parte de la versión de política.) |
| Escalada de privilegios | `allowPrivilegeEscalation` debe ser **explícitamente** `false` en cada contenedor (pods Linux). |
| Ejecutar como no-root | `runAsNonRoot` debe ser `true` a nivel de pod o en cada contenedor. |
| Ejecutar como *usuario* no-root | `runAsUser` no debe ser `0` (puede estar sin definir). |
| Seccomp | `seccompProfile.type` debe estar **explícitamente definido** en `RuntimeDefault` o `Localhost`. Sin definir es una violación (un contenedor puede omitirlo si el campo a nivel de pod está definido). |
| Capabilities | Cada contenedor debe tener `capabilities.drop: ["ALL"]`. Sólo se puede volver a agregar `NET_BIND_SERVICE`. |

Los campos de `restricted` deben cumplirse en **todos** los `containers`, `initContainers` y `ephemeralContainers`.

---

## Pod Security Admission: modos y labels

Un namespace se adhiere con labels de la forma:

```
pod-security.kubernetes.io/<MODE>: <LEVEL>
pod-security.kubernetes.io/<MODE>-version: <POLICY_VERSION>   # optional
```

`<MODE>` es uno de:

| Modo | Efecto | Se aplica a |
|---|---|---|
| `enforce` | Los **Pods** que violan la política son rechazados en la admisión. | Sólo Pods. |
| `audit` | La violación se registra como una anotación en el log de auditoría del API server. El objeto se admite. | Pods **y** controladores de carga de trabajo (Deployment, Job, CronJob, …). |
| `warn` | La violación se devuelve al cliente como un encabezado `Warning:`. El objeto se admite. | Pods **y** controladores de carga de trabajo. |

`<LEVEL>` es `privileged`, `baseline` o `restricted`. `<POLICY_VERSION>` es una versión menor como `v1.34`, o `latest` (el valor por defecto).

### La trampa de que `enforce` sólo se aplica a Pods

Esta es la fuente de confusión más común, y aparece constantemente en escenarios de estilo examen.

`enforce` se evalúa contra el objeto **Pod**. Cuando creás un Deployment, el Deployment se admite; el ReplicaSet se admite; después el controlador de ReplicaSet intenta crear Pods y *esos* son rechazados. Tu `kubectl apply` tiene éxito y no se ejecuta nada.

```console
$ kubectl -n prod create deployment web --image=nginx
deployment.apps/web created

$ kubectl -n prod get deploy web
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
web    0/1     0            0           14s

$ kubectl -n prod get pods
No resources found in prod namespace.

$ kubectl -n prod describe rs -l app=web | tail -6
Events:
  Type     Reason        Age   From                   Message
  ----     ------        ----  ----                   -------
  Warning  FailedCreate  12s   replicaset-controller  Error creating: pods "web-6c9b7f4b8d-" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "nginx" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "nginx" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "nginx" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "nginx" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

El camino de diagnóstico es: el Deployment tiene 0 réplicas → `describe rs` (o `kubectl get events -n <ns>`) → leer el mensaje `FailedCreate`.

Por esto exactamente conviene definir `warn` junto con `enforce`: con `warn` habilitado la retroalimentación llega de inmediato, en el momento del `kubectl apply`, sobre el Deployment mismo.

```console
$ kubectl -n prod create deployment web --image=nginx
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "nginx" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "nginx" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "nginx" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "nginx" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
deployment.apps/web created
```

---

## Aplicar los labels

### De forma declarativa

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: prod
  labels:
    # Hard requirement
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/enforce-version: v1.34
    # Tell me now, at apply time, if I'm not ready for restricted
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: latest
    # And record it for the security team
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: latest
```

Esta combinación "enforce baseline / warn+audit restricted" es el patrón canónico de migración: obtenés un piso duro hoy y un camino medible hacia `restricted`.

### De forma imperativa

```console
$ kubectl label namespace prod \
    pod-security.kubernetes.io/enforce=restricted \
    pod-security.kubernetes.io/enforce-version=v1.34 --overwrite
namespace/prod labeled
```

Un modo se elimina borrando el label:

```console
$ kubectl label namespace prod pod-security.kubernetes.io/enforce-
namespace/prod unlabeled
```

Los valores son validados por el API server, así que los errores de tipeo fallan ruidosamente:

```console
$ kubectl label ns prod pod-security.kubernetes.io/enforce=restrict --overwrite
The Namespace "prod" is invalid: metadata.labels[pod-security.kubernetes.io/enforce]: Invalid value: "restrict": must be one of ["privileged" "baseline" "restricted"]
```

### Auditar qué namespaces están cubiertos

```console
$ kubectl get ns -L pod-security.kubernetes.io/enforce,pod-security.kubernetes.io/warn
NAME              STATUS   AGE   ENFORCE      WARN
default           Active   21d
dev               Active   4h    baseline     restricted
kube-node-lease   Active   21d
kube-public       Active   21d
kube-system       Active   21d   privileged
prod              Active   4h    restricted   restricted
```

Un `ENFORCE` vacío significa **ninguna aplicación de política en absoluto** para ese namespace, a menos que haya un valor por defecto configurado a nivel de clúster (ver más abajo). Un namespace sin labels es efectivamente `privileged`. No asumas "sin label = seguro".

---

## Probar en seco un nivel contra cargas de trabajo existentes

Antes de activar `enforce`, averiguá qué se rompería. PSA evalúa los Pods existentes en el namespace cuando cambia el label, y un **dry run del lado del servidor** te da esa evaluación sin persistir nada:

```console
$ kubectl label --dry-run=server --overwrite ns dev \
    pod-security.kubernetes.io/enforce=restricted
Warning: existing pods in namespace "dev" violate the new PodSecurity enforce level "restricted:latest"
Warning: legacy-app-7f9d4c85b-2xk9p (and 2 other pods): allowPrivilegeEscalation != false, unrestricted capabilities, runAsNonRoot != true, seccompProfile
Warning: node-exporter-nq7lb: host namespaces, hostPath volumes, allowPrivilegeEscalation != false, unrestricted capabilities, restricted volume types, runAsNonRoot != true, seccompProfile
namespace/dev labeled
```

En realidad no se aplicó ningún label — `--dry-run=server` significa que el API server evaluó la petición y la descartó. Esta es la forma segura más rápida de responder "¿puede este namespace pasar a restricted?" y vale la pena memorizarla para el examen.

Para barrer todo el clúster:

```console
$ kubectl label --dry-run=server --overwrite ns --all \
    pod-security.kubernetes.io/enforce=baseline 2>&1 | grep -A100 Warning
```

---

## Valores por defecto y exenciones a nivel de clúster

Los labels de namespace son de adhesión voluntaria, lo que significa que un namespace recién creado está desprotegido. Para establecer un piso para todo el clúster, configurá el plugin de admisión `PodSecurity` mediante un archivo `AdmissionConfiguration`.

`/etc/kubernetes/admission/pod-security.yaml`:

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
  - name: PodSecurity
    configuration:
      apiVersion: pod-security.admission.config.k8s.io/v1
      kind: PodSecurityConfiguration
      # Applied to any namespace that does not carry the corresponding label.
      defaults:
        enforce: "baseline"
        enforce-version: "latest"
        audit: "restricted"
        audit-version: "latest"
        warn: "restricted"
        warn-version: "latest"
      exemptions:
        # Requests by these users bypass PSA entirely.
        usernames: []
        # Pods using these RuntimeClasses are exempt (e.g. sandboxed runtimes).
        runtimeClasses: []
        # Pods in these namespaces are exempt.
        namespaces: ["kube-system"]
```

Conectalo al API server. En un clúster kubeadm, editá el manifiesto del Pod estático `/etc/kubernetes/manifests/kube-apiserver.yaml`:

```yaml
spec:
  containers:
    - command:
        - kube-apiserver
        - --admission-control-config-file=/etc/kubernetes/admission/pod-security.yaml
        # ...
      volumeMounts:
        - name: admission-config
          mountPath: /etc/kubernetes/admission
          readOnly: true
  volumes:
    - name: admission-config
      hostPath:
        path: /etc/kubernetes/admission
        type: DirectoryOrCreate
```

El kubelet reinicia el API server automáticamente cuando cambia el manifiesto:

```console
$ sudo crictl ps | grep kube-apiserver
b3f1c2a9e77d5  ...  Running  kube-apiserver  1  9f2a1c...

$ kubectl -n kube-system logs kube-apiserver-controlplane | grep -i podsecurity
```

Si el API server no vuelve, el manifiesto o el archivo de configuración están mal formados — revisá `sudo crictl ps -a`, después `sudo crictl logs <container-id>`, o `/var/log/pods/`.

### Notas sobre las exenciones

- Las exenciones se evalúan **antes** que la política, así que una petición exenta ni siquiera se verifica (tampoco se audita).
- Eximir por `username` es una verdadera puerta de escape: cualquier principal en esa lista puede crear un Pod privilegiado en cualquier lado. Tratá esa lista como cluster-admin.
- **No** existe exención por ServiceAccount ni por nombre de Pod. Si necesitás granularidad por carga de trabajo, eso es trabajo de un motor de políticas, no de PSA.
- El label siempre gana sobre el valor por defecto configurado para ese modo.

---

## Hacer que una carga de trabajo cumpla con `restricted`

El manifiesto de partida que falla:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web
spec:
  containers:
    - name: web
      image: nginx:1.27
```

```console
$ kubectl -n prod apply -f web.yaml
Error from server (Forbidden): error when creating "web.yaml": pods "web" is forbidden: violates PodSecurity "restricted:v1.34": allowPrivilegeEscalation != false (container "web" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "web" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "web" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "web" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

La versión conforme — esta es la forma que vale la pena poder escribir de memoria:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web
spec:
  securityContext:                    # pod level: inherited by all containers
    runAsNonRoot: true
    runAsUser: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: web
      image: nginxinc/nginx-unprivileged:1.27
      ports:
        - containerPort: 8080
      securityContext:                # container level: cannot be set at pod level
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
        readOnlyRootFilesystem: true  # not required by PSS, but good practice
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
```

```console
$ kubectl -n prod apply -f web.yaml
pod/web created

$ kubectl -n prod get pod web
NAME   READY   STATUS    RESTARTS   AGE
web    1/1     Running   0          6s
```

Dos reglas de ubicación para internalizar:

- `runAsNonRoot`, `runAsUser`, `seccompProfile`, `seLinuxOptions`, `fsGroup` pueden definirse a nivel de **pod** (`spec.securityContext`) y se heredan.
- `allowPrivilegeEscalation`, `capabilities`, `privileged`, `readOnlyRootFilesystem`, `procMount` existen **sólo** a nivel de contenedor (`spec.containers[].securityContext`). Un valor a nivel de contenedor siempre sobrescribe al de nivel de pod.

### La falla en tiempo de ejecución de `runAsNonRoot`

`runAsNonRoot: true` sin `runAsUser` es admitido por PSA, pero el kubelet lo hace cumplir al arrancar el contenedor inspeccionando el `USER` de la imagen. Una imagen que corre como root falla entonces *después* de la admisión:

```console
$ kubectl -n prod get pod web
NAME   READY   STATUS                       RESTARTS   AGE
web    0/1     CreateContainerConfigError   0          8s

$ kubectl -n prod describe pod web | grep -A3 Warning
  Warning  Failed  3s (x3 over 18s)  kubelet  Error: container has runAsNonRoot and image will run as root (pod: "web_prod(...)", container: web)
```

Se arregla usando una imagen construida con un `USER` no-root, o definiendo un `runAsUser` explícito distinto de cero **y** asegurando que los permisos del sistema de archivos en la imagen permitan que ese UID se ejecute.

---

## Leer el rastro de auditoría

Con `audit` habilitado, las violaciones caen en el log de auditoría del API server como anotaciones en lugar de bloquear nada:

```json
{
  "kind": "Event",
  "verb": "create",
  "objectRef": { "resource": "pods", "namespace": "dev", "name": "legacy-app" },
  "annotations": {
    "pod-security.kubernetes.io/audit-violations": "would violate PodSecurity \"restricted:latest\": allowPrivilegeEscalation != false (container \"app\" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container \"app\" must set securityContext.capabilities.drop=[\"ALL\"])"
  }
}
```

Esto requiere que el log de auditoría del API server esté configurado (`--audit-policy-file`, `--audit-log-path`) — es el instrumento de medición que te dice cuándo un namespace está finalmente listo para pasar de `baseline` a `restricted`.

---

## Versionado de políticas

Fijar `*-version` a una versión menor concreta (`v1.34`) congela la definición de la política. Si una versión posterior de Kubernetes agrega una verificación nueva a `restricted`, un namespace fijado sigue evaluando el conjunto de reglas anterior y tus cargas de trabajo en ejecución no son rechazadas de golpe al actualizar el clúster.

- Usá una **versión fijada para `enforce`** en producción, para que una actualización no pueda romper la admisión de cargas de trabajo existentes.
- Usá **`latest` para `warn` y `audit`**, para enterarte de las verificaciones nuevas antes de que muerdan.
- Subí la versión fijada de `enforce` deliberadamente, después de que los datos de auditoría digan que estás limpio.

Si la versión fijada de un namespace es más vieja que la versión más antigua que el API server todavía conoce, PSA cae a la política soportada más antigua y emite una advertencia.

---

## Dónde termina PSA, y qué usar después

PSA es intencionalmente acotado. No puede expresar:

- "las imágenes deben venir de `registry.internal.example.com`"
- "todo Pod debe definir límites de recursos"
- "esta ServiceAccount puede usar `hostNetwork`, otras no"
- ninguna **mutación** (agregar un `securityContext` por defecto)

Para eso, superponé un motor de políticas o una política basada en CEL:

- **ValidatingAdmissionPolicy** (incorporada, CEL, GA desde v1.30) y **MutatingAdmissionPolicy** — sin webhook externo que ejecutar o mantener disponible.
- **Kyverno** / **OPA Gatekeeper** — ambos traen conjuntos de políticas PSS prearmados y además pueden mutar manifiestos para hacerlos conformes.

La composición recomendada es: PSA para el piso grueso a nivel de namespace, un motor de políticas para todo lo más fino.

Una `ValidatingAdmissionPolicy` mínima que ilustra el complemento:

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: require-approved-registry
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
  validations:
    - expression: >-
        object.spec.containers.all(c,
          c.image.startsWith('registry.internal.example.com/'))
      message: "images must come from the internal registry"
```

---

## Errores comunes

- **Los namespaces sin labels están completamente abiertos.** Enumeralos (`kubectl get ns -L pod-security.kubernetes.io/enforce`) o definí un valor por defecto a nivel de clúster.
- **`enforce` solo produce fallas silenciosas** a través de los controladores. Emparejalo siempre con `warn`.
- **PSA no desaloja retroactivamente.** Poner un label en un namespace sólo afecta a los Pods creados *después* del cambio; los Pods existentes que violan la política siguen corriendo (sólo recibís una advertencia). Recrealos para converger.
- **`restricted` requiere que `seccompProfile` esté explícitamente definido.** Sin definir es una violación, a diferencia de `baseline`.
- **`capabilities.drop: ["ALL"]` es obligatorio incluso si no volvés a agregar nada.** "No agregué capabilities" no es lo mismo que "descarté todas".
- **`privileged` no es "sin política configurada".** Es una declaración explícita, y etiquetar los namespaces de infraestructura como `privileged` documenta la intención — y los hace visibles en una auditoría.
- **Eximir `kube-system` es normal; eximir tus namespaces de aplicaciones no lo es.**
- Cualquier manifiesto que necesite `hostPath`, `hostNetwork` o `privileged` (agentes de nodo, CNI, exporters de monitoreo) pertenece a un namespace `privileged` dedicado con un RBAC de alcance estrecho — no a un namespace compartido con aplicaciones.

---

## Laboratorio práctico

```console
# 1. Create a namespace that enforces baseline but warns on restricted
kubectl create ns lab
kubectl label ns lab \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/enforce-version=v1.34 \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted

# 2. A plain pod is admitted (baseline), but warns about restricted
kubectl -n lab run web --image=nginx

# 3. A privileged pod is rejected
kubectl -n lab run bad --image=nginx --privileged
# Error from server (Forbidden): pods "bad" is forbidden: violates PodSecurity
# "baseline:v1.34": privileged (container "bad" must not set securityContext.privileged=true)

# 4. A hostPath pod is rejected
kubectl -n lab apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: { name: mounter }
spec:
  containers:
    - name: c
      image: busybox
      command: ["sleep","3600"]
      volumeMounts: [{ name: host, mountPath: /host }]
  volumes:
    - name: host
      hostPath: { path: / }
EOF
# Error from server (Forbidden): ... violates PodSecurity "baseline:v1.34":
# hostPath volumes (volume "host")

# 5. Dry-run the upgrade to restricted and read what would break
kubectl label --dry-run=server --overwrite ns lab \
  pod-security.kubernetes.io/enforce=restricted

# 6. Fix the workload, then commit the upgrade
kubectl -n lab delete pod web
kubectl label --overwrite ns lab pod-security.kubernetes.io/enforce=restricted
kubectl -n lab apply -f web-restricted.yaml   # the compliant manifest above

# 7. Clean up
kubectl delete ns lab
```

---

## Referencias

- Pod Security Standards — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Pod Security Admission — https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Enforce Pod Security Standards with Namespace Labels — https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-namespace-labels/
- Enforce Pod Security Standards by Configuring the Built-in Admission Controller — https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-admission-controller/
- Migrate from PodSecurityPolicy to the Built-In PodSecurity Admission Controller — https://kubernetes.io/docs/tasks/configure-pod-container/migrate-from-psp/
- Configure a Security Context for a Pod or Container — https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- Restrict a Container's Syscalls with seccomp — https://kubernetes.io/docs/tutorials/security/seccomp/
- Restrict a Container's Access to Resources with AppArmor — https://kubernetes.io/docs/tutorials/security/apparmor/
- Admission Controllers Reference — https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/
- Validating Admission Policy — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Auditing — https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- CKS Curriculum v1.34 (CNCF) — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf