# Ejercicios Guiados — CKS 2.1: Usar los pod security standards apropiados

> **Peso en el examen:** 5 · **Versión de Kubernetes:** v1.34
> Todos los pasos son ejecutables. Ejecutá el bloque, observá la salida y respondé las preguntas antes de seguir. Las respuestas están plegadas al final.

---

## Tabla de referencia (mantenela abierta mientras trabajás)

| Nivel | Qué hace |
|---|---|
| `privileged` | Sin restricciones. Ningún control. |
| `baseline` | Bloquea escaladas de privilegio conocidas: `privileged`, `hostNetwork/hostPID/hostIPC`, host ports, `hostPath`, capabilities agregadas (excepto `NET_BIND_SERVICE`), `seccompProfile: Unconfined`, sysctls inseguros, sobrescritura de montajes de `/proc`. |
| `restricted` | Baseline **más**: `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`, `seccompProfile.type: RuntimeDefault\|Localhost`, y una lista blanca de tipos de volumen. |

| Etiqueta de modo | Efecto |
|---|---|
| `pod-security.kubernetes.io/enforce` | Rechaza el Pod en admisión. |
| `pod-security.kubernetes.io/audit` | Lo permite, escribe una anotación en el audit log. |
| `pod-security.kubernetes.io/warn` | Lo permite, devuelve una advertencia al cliente. |

Cada modo tiene su etiqueta `-version` correspondiente (`latest` o `v1.34`).

---

## Ejercicio 0 — Preparar el entorno

```bash
# 0.1 Confirm the server version (PSA is GA since v1.25 and enabled by default)
kubectl version

# 0.2 Working directory
mkdir -p ~/cks-2.1 && cd ~/cks-2.1

# 0.3 See which namespaces already carry PSA labels
kubectl get ns -L pod-security.kubernetes.io/enforce \
               -L pod-security.kubernetes.io/warn \
               -L pod-security.kubernetes.io/audit
```

**Verificá tu comprensión**

1. **Q1.** En el paso 0.3, la mayoría (o todos) los namespaces muestran columnas vacías. ¿Qué nivel de política se aplica efectivamente a un namespace sin ninguna etiqueta PSA en un clúster por defecto?
2. **Q2.** `kube-system` normalmente está etiquetado con `pod-security.kubernetes.io/enforce=privileged` por kubeadm, o queda sin etiquetar. ¿Por qué es mala idea aplicar `restricted` ahí?

---

## Ejercicio 1 — Comprobar que el plugin de admisión está activo

```bash
# 1.1 Create a scratch namespace
kubectl create namespace psa-lab

# 1.2 Turn on warn-only mode at the strictest level (nothing is blocked yet)
kubectl label namespace psa-lab \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/warn-version=latest

# 1.3 Write a deliberately sloppy Pod
cat > sloppy-pod.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: sloppy
spec:
  containers:
  - name: app
    image: nginx:1.27
EOF

# 1.4 Create it and read the client output carefully
kubectl -n psa-lab apply -f sloppy-pod.yaml

# 1.5 Confirm the Pod actually exists
kubectl -n psa-lab get pod sloppy
```

Forma esperada de la salida en 1.4:

```
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false
(container "app" must set securityContext.allowPrivilegeEscalation=false), unrestricted
capabilities (container "app" must set securityContext.capabilities.drop=["ALL"]),
runAsNonRoot != true (pod or container "app" must set securityContext.runAsNonRoot=true),
seccompProfile (pod or container "app" must set securityContext.seccompProfile.type to
"RuntimeDefault" or "Localhost")
pod/sloppy created
```

**Verificá tu comprensión**

3. **Q3.** El Pod se creó a pesar de cuatro violaciones. ¿Cuál de los tres modos produjo ese mensaje, y cuál habría impedido la creación?
4. **Q4.** Un Pod simple `nginx:1.27` sin `securityContext` — ¿viola `baseline`? Justificá usando la lista de violaciones de arriba.
5. **Q5.** ¿Dónde escribe sus hallazgos el modo `audit`, y por qué ese modo es inútil en un clúster cuyo API server no tiene configurada una política de auditoría?

---

## Ejercicio 2 — Aplicar `baseline` y observar un rechazo

```bash
# 2.1 Add enforcement at baseline, pinned to the cluster version
kubectl label namespace psa-lab --overwrite \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/enforce-version=v1.34

# 2.2 A Pod that baseline must reject
cat > privileged-pod.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: breaker
spec:
  hostNetwork: true
  containers:
  - name: app
    image: nginx:1.27
    securityContext:
      privileged: true
      capabilities:
        add: ["SYS_ADMIN"]
    volumeMounts:
    - name: host
      mountPath: /host
  volumes:
  - name: host
    hostPath:
      path: /
EOF

kubectl -n psa-lab apply -f privileged-pod.yaml

# 2.3 The already-running "sloppy" Pod is still there
kubectl -n psa-lab get pods
```

**Verificá tu comprensión**

6. **Q6.** Enumerá cada control distinto de `baseline` que viola el Pod `breaker`.
7. **Q7.** El Pod `sloppy` del Ejercicio 1 sigue `Running` aunque el enforcement ya está activo. Explicá el mecanismo, y decí qué pasaría si se drenara el nodo donde corre.
8. **Q8.** Seguís viendo una línea `Warning:` sobre `restricted` cuando creás Pods conformes. ¿Por qué?

---

## Ejercicio 3 — Hacer que un Pod cumpla con `restricted`

```bash
# 3.1 Raise enforcement to restricted
kubectl label namespace psa-lab --overwrite \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=v1.34

# 3.2 Delete the legacy Pod so the namespace is consistent
kubectl -n psa-lab delete pod sloppy

# 3.3 Recreate it — now it must fail
kubectl -n psa-lab apply -f sloppy-pod.yaml

# 3.4 Fix it, field by field
cat > hardened-pod.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: hardened
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
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
    volumeMounts:
    - name: scratch
      mountPath: /tmp
  volumes:
  - name: scratch
    emptyDir: {}
EOF

kubectl -n psa-lab apply -f hardened-pod.yaml
kubectl -n psa-lab get pod hardened
```

```bash
# 3.5 Prove the runtime posture from inside the container
kubectl -n psa-lab exec hardened -- id
kubectl -n psa-lab exec hardened -- cat /proc/1/status | grep -i cap
```

**Verificá tu comprensión**

9. **Q9.** En 3.4, cuatro campos de seguridad viven a nivel de Pod y dos a nivel de contenedor. ¿Cuáles de ellos **deben** establecerse por contenedor y no pueden heredarse del Pod?
10. **Q10.** Quitaste `runAsUser: 10001` pero mantuviste `runAsNonRoot: true`. ¿El Pod sigue pasando la admisión de `restricted`? ¿Sigue arrancando?
11. **Q11.** `restricted` **no** requiere `readOnlyRootFilesystem: true`. ¿Ese campo forma parte de algún Pod Security Standard? ¿Deberías establecerlo igualmente?
12. **Q12.** El volumen `emptyDir` fue aceptado. Nombrá tres tipos de volumen que `restricted` (v1.25+) rechaza pero que `baseline` permite.

---

## Ejercicio 4 — Dónde se esconde el error cuando usás un Deployment

```bash
# 4.1 Deploy a non-compliant workload through a controller
kubectl -n psa-lab create deployment web --image=nginx:1.27

# 4.2 Look at the objects
kubectl -n psa-lab get deploy,rs,pods

# 4.3 Find the real error
kubectl -n psa-lab describe rs -l app=web | tail -20
kubectl -n psa-lab get events --sort-by=.lastTimestamp | tail -10
```

**Verificá tu comprensión**

13. **Q13.** El Deployment se creó con éxito pero reporta `0/1` ready. ¿Qué controlador chocó con la denegación de admisión, y bajo qué identidad de ServiceAccount se hizo la petición del Pod?
14. **Q14.** `kubectl create deployment` imprimió una línea `Warning:`. ¿Qué modo de PSA la generó, y por qué `enforce` **no** rechaza el objeto Deployment en sí?
15. **Q15.** En una tarea de examen te dicen "la aplicación no arranca después de endurecer el namespace". Escribí los dos comandos que ejecutarías primero.

---

## Ejercicio 5 — Evaluar antes de aplicar (dry run del lado del servidor)

```bash
# 5.1 Build a namespace with pre-existing, non-compliant workloads
kubectl create namespace legacy
kubectl -n legacy run nginx --image=nginx:1.27
kubectl -n legacy run tools --image=busybox:1.36 --command -- sleep 3600
kubectl -n legacy get pods

# 5.2 Ask the API server what WOULD break, without changing anything
kubectl label --dry-run=server --overwrite namespace legacy \
  pod-security.kubernetes.io/enforce=restricted

# 5.3 Confirm nothing changed
kubectl get namespace legacy -o jsonpath='{.metadata.labels}' ; echo

# 5.4 The safe rollout order
kubectl label namespace legacy --overwrite \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted
```

Forma esperada de 5.2:

```
Warning: existing pods in namespace "legacy" violate the new PodSecurity enforce level "restricted:latest"
Warning: nginx: allowPrivilegeEscalation != false, unrestricted capabilities, runAsNonRoot != true, seccompProfile
Warning: tools: allowPrivilegeEscalation != false, unrestricted capabilities, runAsNonRoot != true, seccompProfile
namespace/legacy labeled (server dry run)
```

**Verificá tu comprensión**

16. **Q16.** ¿Por qué `--dry-run=server` expone estas advertencias mientras que `--dry-run=client` no puede?
17. **Q17.** Describí la secuencia de migración de cuatro pasos que usarías para llevar un namespace de producción con carga desde sin etiquetar hasta `enforce=restricted` sin caída de servicio.
18. **Q18.** Escribí un one-liner que liste todos los namespaces del clúster **sin** etiqueta `enforce`.

---

## Ejercicio 6 — Fijar la versión, y ver por qué importa

```bash
# 6.1 Namespace pinned to an older policy revision
kubectl create namespace pinned
kubectl label namespace pinned \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=v1.24

# 6.2 Same thing, unpinned
kubectl create namespace unpinned
kubectl label namespace unpinned \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest

# 6.3 A compliant Pod that also mounts an NFS volume
cat > nfs-pod.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: nfs-user
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
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
    volumeMounts:
    - name: share
      mountPath: /data
  volumes:
  - name: share
    nfs:
      server: 10.0.0.99
      path: /exports
EOF

kubectl -n pinned   apply -f nfs-pod.yaml
kubectl -n unpinned apply -f nfs-pod.yaml
```

Anotá el resultado exacto de cada uno de los dos comandos `apply`.

**Verificá tu comprensión**

19. **Q19.** Los dos namespaces dicen `restricted`, y sin embargo el resultado de admisión difiere. ¿Qué control explica la diferencia, y en qué versión de Kubernetes se agregó?
20. **Q20.** ¿Cuál es el argumento operativo **a favor** de fijar `enforce-version` en `v1.34`, y cuál es el argumento **en contra**?
21. **Q21.** ¿Qué pasa si establecés `enforce-version` en una versión más nueva que el API server, por ejemplo `v1.99`?

---

## Ejercicio 7 — Valores por defecto a nivel de clúster con `AdmissionConfiguration`

> Ejecutá esto en un nodo del plano de control de kubeadm. Un error de tipeo acá detiene el API server — leé el paso 7.5 antes de empezar.

```bash
# 7.1 Create the PodSecurity plugin configuration
sudo mkdir -p /etc/kubernetes/admission
sudo tee /etc/kubernetes/admission/pod-security.yaml >/dev/null <<'EOF'
apiVersion: pod-security.admission.config.k8s.io/v1
kind: PodSecurityConfiguration
defaults:
  enforce: "baseline"
  enforce-version: "v1.34"
  audit: "restricted"
  audit-version: "v1.34"
  warn: "restricted"
  warn-version: "v1.34"
exemptions:
  usernames: []
  runtimeClasses: []
  namespaces: ["kube-system"]
EOF

# 7.2 Point the AdmissionConfiguration at it
sudo tee /etc/kubernetes/admission/admission-config.yaml >/dev/null <<'EOF'
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
- name: PodSecurity
  path: /etc/kubernetes/admission/pod-security.yaml
EOF
```

```bash
# 7.3 Back up the static Pod manifest FIRST
sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.bak

# 7.4 Edit the manifest
sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml
```

Agregá a `spec.containers[0].command`:

```yaml
    - --admission-control-config-file=/etc/kubernetes/admission/admission-config.yaml
```

Agregá a `spec.containers[0].volumeMounts`:

```yaml
    - name: admission-config
      mountPath: /etc/kubernetes/admission
      readOnly: true
```

Agregá a `spec.volumes`:

```yaml
  - name: admission-config
    hostPath:
      path: /etc/kubernetes/admission
      type: DirectoryOrCreate
```

```bash
# 7.5 Watch the API server come back (this takes 30-90 seconds)
sudo crictl ps | grep kube-apiserver
kubectl get --raw='/healthz' ; echo
# If it never returns: sudo crictl logs $(sudo crictl ps -a --name kube-apiserver -q | head -1)
# Recovery: sudo cp /root/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml

# 7.6 Test the new cluster-wide default on a brand-new, unlabelled namespace
kubectl create namespace defaults-test
kubectl -n defaults-test apply -f privileged-pod.yaml     # expect: rejected
kubectl -n defaults-test apply -f sloppy-pod.yaml         # expect: warning, then created
```

**Verificá tu comprensión**

22. **Q22.** El namespace `psa-lab` lleva `enforce=restricted`; el valor por defecto del clúster ahora es `enforce=baseline`. ¿Cuál gana para un Pod creado en `psa-lab`?
23. **Q23.** ¿Por qué se monta `--admission-control-config-file` con `readOnly: true`, y por qué el volumen debe ser un `hostPath` en lugar de un ConfigMap?
24. **Q24.** El API server entra en crash loop después de tu edición. ¿Qué log leés, y cómo hacés rollback sin un `kubectl` funcional?
25. **Q25.** ¿Cuál es la diferencia práctica entre el bloque `defaults:` de acá y simplemente etiquetar todos los namespaces?

---

## Ejercicio 8 — Exenciones, y el agujero que abren

```bash
# 8.1 A namespace for a workload that genuinely needs host access
kubectl create namespace node-agents
kubectl label namespace node-agents \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/warn=privileged \
  pod-security.kubernetes.io/audit=baseline

# 8.2 The privileged Pod is now accepted here
kubectl -n node-agents apply -f privileged-pod.yaml
kubectl -n node-agents get pod breaker
```

```bash
# 8.3 Close the hole with RBAC — nobody but the agent's SA may create Pods here
kubectl -n node-agents create serviceaccount node-agent

cat > agent-rbac.yaml <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: node-agents
  name: pod-creator
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["create", "get", "list", "watch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  namespace: node-agents
  name: pod-creator
subjects:
- kind: ServiceAccount
  name: node-agent
  namespace: node-agents
roleRef:
  kind: Role
  name: pod-creator
  apiGroup: rbac.authorization.k8s.io
EOF

kubectl apply -f agent-rbac.yaml

# 8.4 Verify with auth can-i
kubectl auth can-i create pods -n node-agents \
  --as=system:serviceaccount:node-agents:node-agent
kubectl auth can-i create pods -n node-agents \
  --as=system:serviceaccount:default:default
```

**Verificá tu comprensión**

26. **Q26.** `exemptions.usernames: ["system:serviceaccount:ci:deployer"]` en la configuración del API server — ¿en qué namespaces se aplica esa exención?
27. **Q27.** ¿Por qué un **namespace** `privileged` (Ejercicio 8.1) es en general más seguro que una exención por `usernames` o `runtimeClasses` en la configuración de admisión?
28. **Q28.** PSA tiene alcance de namespace y se basa en niveles. Nombrá dos requisitos concretos que **no** puede expresar, y la clase de herramienta a la que recurrirías en su lugar.
29. **Q29.** Pod Security Policy fue eliminado en v1.25. Nombrá dos capacidades que tenía PSP y que PSA descartó deliberadamente.

---

## Ejercicio 9 — Limpieza

```bash
kubectl delete namespace psa-lab legacy pinned unpinned defaults-test node-agents
# Optional: revert the API server change
sudo cp /root/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml
kubectl get --raw='/healthz' ; echo
```

---

<details>
<summary><strong>Respuestas</strong></summary>

### Ejercicio 0

**A1.** `privileged` — la ausencia de etiquetas significa que no se aplica ninguna política. PSA es fail-open por diseño: un namespace sin etiquetar está completamente sin restricciones. Por eso "el clúster tiene PSA habilitado" no dice nada sobre si realmente está protegiendo algo. En un clúster endurecido, o etiquetás todos los namespaces o establecés un valor por defecto a nivel de clúster mediante `AdmissionConfiguration` (Ejercicio 7).

**A2.** Los componentes del plano de control y de los nodos que corren en `kube-system` necesitan legítimamente acceso al host: `kube-proxy` necesita `hostNetwork` y `NET_ADMIN`, los agentes CNI necesitan montajes `hostPath` y `privileged`, los drivers CSI necesitan propagación de montaje bidireccional. Aplicar `restricted` ahí bloquearía la recreación de sus Pods, y perderías la red del clúster en el próximo reinicio de nodo o rollout de DaemonSet. `kube-system` es la exención canónica.

---

### Ejercicio 1

**A3.** Lo produjo `warn` — la redacción `would violate` es la pista. `enforce` habría rechazado la petición con `Error from server (Forbidden)`. `warn` y `audit` nunca bloquean.

**A4.** No. Un Pod `nginx:1.27` pelado satisface `baseline` — no es privilegiado, no agrega capabilities, no usa namespaces del host, ni host ports, ni `hostPath`. Las cuatro violaciones reportadas son controles exclusivos de `restricted` (`allowPrivilegeEscalation`, `capabilities.drop`, `runAsNonRoot`, `seccompProfile`). Notá que `baseline` permite correr como UID 0 dentro del contenedor — esa es precisamente la brecha que `restricted` cierra.

**A5.** `audit` agrega una anotación `pod-security.kubernetes.io/audit-violations` al **evento de auditoría del API server** para esa petición. Si no hay configurado un `--audit-policy-file` / `--audit-log-path`, el evento nunca se escribe en ningún lado y el modo es silenciosamente un no-op. `warn` es el modo que da retroalimentación inmediata y visible a la persona que ejecuta `kubectl`.

---

### Ejercicio 2

**A6.** Cuatro:
- `hostNetwork: true` → control de Host Namespaces
- `securityContext.privileged: true` → control de Privileged Containers
- `capabilities.add: ["SYS_ADMIN"]` → control de Capabilities (solo se puede agregar `NET_BIND_SERVICE`)
- volumen `hostPath` → control de HostPath Volumes

**A7.** PSA es un controlador de **admisión validante**: solo se ejecuta en peticiones `CREATE` y `UPDATE` de Pods. No tiene bucle de reconciliación y nunca desaloja nada, así que los Pods ya admitidos sobreviven intactos a un cambio de etiqueta. Si se drenara el nodo, el Pod se eliminaría y — si pertenece a un controlador — se recrearía, y *esa* petición de creación sería evaluada y rechazada. Es el clásico fallo de "funcionó hasta que se reinició el nodo".

**A8.** Porque el namespace ahora lleva dos etiquetas independientes: `enforce=baseline` y `warn=restricted` (establecida en el paso 1.2). Los modos se evalúan de forma independiente, así que obtenés bloqueo en `baseline` y retroalimentación informativa en `restricted`. Esta combinación — aplicar un nivel más abajo, advertir un nivel más arriba — es el patrón de producción recomendado.

---

### Ejercicio 3

**A9.** `allowPrivilegeEscalation: false` y `capabilities.drop: ["ALL"]` son **exclusivamente a nivel de contenedor**; no hay equivalente a nivel de Pod, así que deben repetirse en cada contenedor, incluyendo `initContainers` y `ephemeralContainers`. `runAsNonRoot`, `runAsUser`, `runAsGroup`, `fsGroup` y `seccompProfile` existen a nivel de Pod y son heredados por los contenedores que no los sobrescriben.

**A10.** La admisión sigue pasando — `restricted` requiere que `runAsNonRoot: true` esté establecido (o que `runAsUser` sea distinto de cero); no requiere que `runAsUser` esté presente. Que *arranque* depende de la imagen: el kubelet resuelve la directiva `USER` de la imagen al iniciar el contenedor y falla el Pod con `CreateContainerConfigError: container has runAsNonRoot and image will run as root` si resuelve a UID 0. `busybox:1.36` corre como root, así que fallaría en tiempo de ejecución. Esta es la distinción clave: **PSA valida el manifiesto, el kubelet valida la identidad en ejecución.**

**A11.** No — `readOnlyRootFilesystem` no forma parte de `baseline` ni de `restricted` en ninguna versión. Es una medida de endurecimiento ampliamente recomendada que PSA sencillamente no cubre, lo que ilustra bien el techo de las políticas basadas en niveles. Establecelo donde la carga de trabajo lo tolere, respaldado por montajes `emptyDir` para `/tmp` y cualquier ruta escribible, pero esperá tener que aplicarlo con un motor de políticas en lugar de PSA.

**A12.** `restricted` (v1.25+) permite solamente: `configMap`, `csi`, `downwardAPI`, `emptyDir`, `ephemeral`, `persistentVolumeClaim`, `projected`, `secret`. Así que `nfs`, `iscsi`, `cephfs`, `fc`, `rbd` y `glusterfs` son todos aceptados por `baseline` y rechazados por `restricted`. Notá la intención: los volúmenes de red in-tree son reemplazados por `persistentVolumeClaim`, que enruta el mismo almacenamiento a través de un PV que controla el administrador del clúster.

---

### Ejercicio 4

**A13.** Chocó el **controlador de ReplicaSet**. La petición de creación del Pod la hizo `system:serviceaccount:kube-system:replicaset-controller`, no tu usuario. Esto importa para `exemptions.usernames`: eximir *tu* nombre de usuario no ayudaría acá, porque no sos la identidad que crea el Pod.

**A14.** La generó `warn`. `warn` y `audit` evalúan las **plantillas de Pod** embebidas en recursos de carga de trabajo (Deployment, StatefulSet, DaemonSet, Job, CronJob, ReplicaSet, ReplicationController, PodTemplate), y por eso obtenés retroalimentación en el momento del `kubectl apply`. `enforce` evalúa deliberadamente **solo Pods** — aplicar sobre plantillas crearía problemas de desfase de versiones y reportaría dos veces la misma violación. La consecuencia práctica es que una etiqueta `warn` es lo que hace usable a `enforce` con controladores.

**A15.**
```bash
kubectl -n <ns> describe rs -l app=<app>          # FailedCreate event with the violation text
kubectl get ns <ns> -o jsonpath='{.metadata.labels}'   # which level is enforced
```
Después reconciliá el `securityContext` de la plantilla del Pod contra las violaciones reportadas.

---

### Ejercicio 5

**A16.** `--dry-run=server` envía la petición al API server con `dryRun=All`; la petición atraviesa toda la cadena de admisión, así que el plugin PodSecurity ejecuta su hook de cambio de etiquetas de namespace, que enumera los **Pods existentes** en ese namespace y los evalúa contra el nivel propuesto. Nada se persiste en etcd. `--dry-run=client` nunca contacta al API server para validar, así que no tiene acceso a los Pods en ejecución y no se ejecuta ningún plugin de admisión.

**A17.**
1. `kubectl label --dry-run=server ... enforce=restricted` para obtener la lista de impacto.
2. Aplicar solo `warn=restricted` y `audit=restricted`; dejar `enforce` apagado. Recolectar violaciones durante un ciclo completo de despliegue.
3. Corregir las plantillas de Pod (`securityContext` en cada contenedor más el Pod), redesplegar, confirmar que las advertencias cesan.
4. Aplicar `enforce=restricted` con un `enforce-version` fijado. Opcionalmente pasar primero por `enforce=baseline` en un namespace legacy grande.

**A18.**
```bash
kubectl get ns -o json | jq -r '.items[] | select(.metadata.labels["pod-security.kubernetes.io/enforce"] == null) | .metadata.name'
```
Sin `jq`, el equivalente legible es `kubectl get ns -L pod-security.kubernetes.io/enforce` y buscar las celdas en blanco.

---

### Ejercicio 6

**A19.** El control de **Volume Types**. `restricted` obtuvo su lista blanca explícita de volúmenes en **v1.25**. Fijado a `restricted:v1.24`, el volumen `nfs` se evalúa solo contra las reglas de `baseline` (que prohíben `hostPath` pero permiten `nfs`), así que el Pod es admitido. En `restricted:latest` (= v1.34) `nfs` no está en la lista blanca y el Pod es rechazado. Todo lo demás en el manifiesto ya satisface ambas revisiones.

**A20.** **A favor de fijar:** las definiciones de política evolucionan entre releases menores. Fijar garantiza que actualizar el clúster de v1.34 a v1.35 no pueda de golpe rechazar cargas de trabajo que ayer cumplían — vos decidís cuándo adoptar las nuevas reglas subiendo la etiqueta. También mantiene el comportamiento idéntico en todo el plano de control durante una actualización. **En contra de fijar:** te perdés silenciosamente protecciones nuevas, y las versiones fijadas se pudren; `latest` significa que siempre obtenés el endurecimiento actual. El compromiso habitual es fijar `enforce-version` y dejar `warn`/`audit` en `latest`, de modo que las reglas nuevas aparezcan como advertencias antes de que puedan llegar a bloquear.

**A21.** La etiqueta se acepta (las etiquetas de namespace no se rechazan por esto), pero el API server emite una advertencia de que la versión es desconocida y **cae de vuelta a `latest`** para la evaluación. Falla cerrado, no abierto — obtenés la interpretación actual y más estricta en lugar de ninguna política. Verificá con `kubectl describe ns <name>` y observando la advertencia en la llamada a `kubectl label`.

---

### Ejercicio 7

**A22.** Ganan las **etiquetas del namespace**. El bloque `defaults:` de `PodSecurityConfiguration` solo aporta valores para los modos que el namespace no especifica. `psa-lab` establece `enforce=restricted`, así que ahí aplica `restricted` para el enforcement; sus valores de `audit`/`warn` seguirían viniendo de las etiquetas de namespace que estableciste antes, y cualquier modo que quede sin definir en el namespace cae al valor por defecto del clúster. Orden de precedencia: exención > etiqueta de namespace > valor por defecto del clúster.

**A23.** `readOnly: true` porque el API server solo necesita parsear el archivo al arrancar; un montaje escribible permitiría que cualquier cosa que comprometa el contenedor del API server debilite su propia política de admisión. Debe ser un `hostPath` porque `kube-apiserver` es un **static Pod** gestionado directamente por el kubelet — arranca antes (e independientemente) del API server, así que ningún ConfigMap puede resolverse en ese punto. Por la misma razón `--audit-policy-file` y la configuración de cifrado en reposo son archivos del host.

**A24.**
```bash
sudo crictl ps -a --name kube-apiserver          # find the exited container
sudo crictl logs <container-id>
# or, if the container never starts:
sudo journalctl -u kubelet -f
```
Causas típicas: error de indentación YAML en el manifiesto, una ruta en `--admission-control-config-file` que no está dentro del directorio montado, o un `apiVersion` incorrecto en `pod-security.yaml`. Hacé rollback con el backup — el kubelet vigila `/etc/kubernetes/manifests` y reinicia el static Pod automáticamente, sin necesidad de `kubectl`:
```bash
sudo cp /root/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml
```

**A25.** El valor por defecto del clúster es **fail-closed para namespaces nuevos**. Cualquier namespace creado después — por un usuario, por un pipeline de CI, por un operador — está protegido desde el momento en que existe. Etiquetar namespaces individualmente es fail-open: cada namespace nuevo es `privileged` hasta que alguien se acuerda de etiquetarlo, que es exactamente la brecha que usa un atacante con permiso para crear namespaces. La mejor práctica es ambas cosas: un valor por defecto `baseline` (o `restricted`) a nivel de clúster, más etiquetas explícitas por namespace donde haga falta un nivel distinto.

---

### Ejercicio 8

**A26.** En **todos** los namespaces, incondicionalmente. Las exenciones por nombre de usuario se evalúan antes que las etiquetas de namespace, así que esa ServiceAccount puede crear un Pod `privileged` en un namespace etiquetado `enforce=restricted` y PSA no va a objetar. Por eso las exenciones por nombre de usuario son las más peligrosas de las tres — combinadas con una ServiceAccount de CI demasiado permisiva, anulan PSA en todo el clúster.

**A27.** Porque un namespace `privileged` sigue siendo una frontera **evaluada por PSA** que podés acotar con las herramientas que ya tenés: RBAC controla quién puede crear Pods ahí, ResourceQuota limita cuántos, NetworkPolicy limita a qué llegan, y su nombre aparece en `kubectl get ns -L pod-security.kubernetes.io/enforce` durante cualquier auditoría. Una exención por `usernames` o `runtimeClasses` es invisible desde la API del clúster — vive solo en un archivo del nodo del plano de control — y se aplica en todas partes. Mantené la lista de exenciones vacía salvo por `kube-system`, y expresá "esta carga de trabajo necesita acceso al host" como un namespace dedicado y cerrado con RBAC.

**A28.** Ejemplos que PSA no puede expresar: exigir `readOnlyRootFilesystem: true`; restringir imágenes a un registry específico; exigir un `runAsUser` dentro de un rango de UID dado; prohibir tags de imagen `latest`; exigir límites de recursos; exigir etiquetas o anotaciones específicas. PSA tiene exactamente tres niveles fijos y ninguna forma de agregar, quitar o parametrizar una regla. Para cualquiera de estos necesitás un motor de políticas de propósito general — **Kyverno** u **OPA Gatekeeper** — corriendo como un `ValidatingAdmissionWebhook`, o **ValidatingAdmissionPolicy** nativo de Kubernetes (basado en CEL, GA desde v1.30) para reglas que puedas expresar sin un controlador externo.

**A29.** PSP podía **mutar** peticiones — inyectaba valores por defecto como `runAsUser`, `fsGroup`, o quitaba capabilities en Pods que las omitían. PSA es puramente validante: rechaza o permite, nunca reescribe. PSP también se vinculaba **por usuario vía RBAC** (verbo `use` sobre un recurso `podsecuritypolicy`), lo que permitía políticas distintas para identidades distintas en el mismo namespace; el alcance de PSA es el namespace, no quien hace la petición. El comportamiento de ordenamiento de PSP cuando coincidían múltiples políticas era la principal fuente de su imprevisibilidad, y descartar la mutación es lo que hace determinista el resultado de PSA.

</details>

---

## Fuentes

- CNCF, *Certified Kubernetes Security Specialist (CKS) Curriculum v1.34* — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Documentación de Kubernetes, *Pod Security Standards* — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Documentación de Kubernetes, *Pod Security Admission* — https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Documentación de Kubernetes, *Enforce Pod Security Standards with Namespace Labels* — https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-namespace-labels/
- Documentación de Kubernetes, *Enforce Pod Security Standards by Configuring the Built-in Admission Controller* — https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-admission-controller/
- Documentación de Kubernetes, *Migrate from PodSecurityPolicy to the Built-In PodSecurity Admission Controller* — https://kubernetes.io/docs/tasks/configure-pod-container/migrate-from-psp/
- Documentación de Kubernetes, *Configure a Security Context for a Pod or Container* — https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- Documentación de Kubernetes, *Validating Admission Policy* — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/