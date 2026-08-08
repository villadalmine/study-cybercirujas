# Ejercicios guiados — Tema 3.5: Isolation and Segmentation (KCSA)

> **Dominio**: Kubernetes Security Fundamentals · **Peso**: 3,14 %
> **Fuente del temario**: [KCSA Curriculum (CNCF)](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
>
> **Idea rectora del tema**: en Kubernetes el aislamiento no es una única propiedad, sino una **pila de fronteras de distinta fuerza**. Un `Namespace` aísla *nombres y cuotas*, pero **no** la red ni el kernel; una `NetworkPolicy` segmenta la red *sólo si el CNI la implementa*; un `RuntimeClass` de sandbox (gVisor, Kata) aísla el *kernel del host*. KCSA evalúa que sepas **qué frontera protege contra qué amenaza** y cuáles son "soft multi-tenancy" (no un límite de seguridad frente a un contenedor comprometido).

## Prerrequisitos del entorno

- Un cluster de laboratorio (`kind`, `minikube`, o cluster real) con `kubectl` apuntando a él.
- Para los ejercicios de red, un **CNI que implemente NetworkPolicy** (Calico, Cilium, Antrea o Weave). `flannel` puro **no** las aplica.
- Para el ejercicio de sandboxing, un nodo con `containerd` y el runtime `runsc` (gVisor) instalado, o el aviso de que se puede *leer* el resultado esperado sin ejecutarlo.
- Un usuario con permisos de `cluster-admin` en el laboratorio.

Verificá el CNI antes de empezar:

```bash
kubectl get pods -n kube-system -o custom-columns=NAME:.metadata.name | \
  grep -E 'calico|cilium|antrea|weave|flannel'
```

```text
calico-node-4t7qz
calico-kube-controllers-7b9f6c9c8d-mzq2v
```

---

## Ejercicio 1 — El `Namespace` como frontera lógica (y lo que NO aísla)

**Objetivo**: comprobar en el terreno que un `Namespace` da *scope* de nombres, RBAC y cuotas, pero **no** aísla la red ni el kernel entre pods de distintos namespaces.

1. Creá dos namespaces que simulen dos "inquilinos" (tenants):

   ```bash
   kubectl create namespace tenant-a
   kubectl create namespace tenant-b
   ```

   ```text
   namespace/tenant-a created
   namespace/tenant-b created
   ```

2. Desplegá un servidor web en cada uno y expone su Service:

   ```bash
   kubectl -n tenant-a run web --image=nginx:1.27 --port=80 \
     --labels app=web
   kubectl -n tenant-a expose pod web --port=80

   kubectl -n tenant-b run web --image=nginx:1.27 --port=80 \
     --labels app=web
   kubectl -n tenant-b expose pod web --port=80
   ```

3. Lanzá un pod cliente en `tenant-b` y desde ahí intentá alcanzar el web de `tenant-a` **por FQDN de Service** (`<svc>.<ns>.svc.cluster.local`):

   ```bash
   kubectl -n tenant-b run probe --image=nicolaka/netshoot -it --rm \
     --restart=Never -- \
     curl -s -o /dev/null -w "%{http_code}\n" \
     http://web.tenant-a.svc.cluster.local
   ```

   ```text
   200
   pod "probe" deleted
   ```

4. Aplicá una `ResourceQuota` a `tenant-a` y comprobá que **sí** es una frontera de consumo dentro del namespace:

   ```yaml
   # quota-tenant-a.yaml
   apiVersion: v1
   kind: ResourceQuota
   metadata:
     name: tenant-a-quota
     namespace: tenant-a
   spec:
     hard:
       pods: "2"
       requests.cpu: "500m"
       requests.memory: 512Mi
       limits.cpu: "1"
       limits.memory: 1Gi
   ```

   ```bash
   kubectl apply -f quota-tenant-a.yaml
   kubectl -n tenant-a describe resourcequota tenant-a-quota
   ```

   ```text
   Name:            tenant-a-quota
   Namespace:       tenant-a
   Resource         Used   Hard
   --------         ----   ----
   limits.cpu       0      1
   limits.memory    0      1Gi
   pods             1      2
   requests.cpu     0      500m
   requests.memory  0      512Mi
   ```

5. Forzá el límite: intentá crear un tercer pod en `tenant-a`.

   ```bash
   kubectl -n tenant-a run overflow --image=pause:3.9
   kubectl -n tenant-a run overflow2 --image=pause:3.9
   ```

   ```text
   pod/overflow created
   Error from server (Forbidden): pods "overflow2" is forbidden: exceeded quota:
   tenant-a-quota, requested: pods=1, used: pods=2, limited: pods=2
   ```

> **Preguntas de comprensión (bloque 1)**
> 1.1 El `curl` del paso 3 devolvió `200`. ¿Qué demuestra eso sobre el aislamiento de red que ofrece un `Namespace` por defecto?
> 1.2 Nombrá tres cosas a las que **sí** da alcance (scope) un `Namespace`, y dos que **no**.
> 1.3 ¿Por qué se dice que separar tenants sólo con `Namespaces` es *soft multi-tenancy* y no un límite de seguridad frente a un contenedor comprometido?

---

## Ejercicio 2 — `NetworkPolicy`: de red plana a segmentación default-deny

**Objetivo**: convertir la red plana del Ejercicio 1 en un modelo de **least-privilege de red**, aplicando el patrón `default-deny` + `allow` explícito, y entender la semántica *aditiva* de las políticas.

1. Confirmá el punto de partida (red plana). Desde `tenant-b`, el web de `tenant-a` responde `200` (ya visto). Ahora agregá un cliente *dentro* de `tenant-a` para el resto del ejercicio:

   ```bash
   kubectl -n tenant-a run client --image=nicolaka/netshoot \
     --labels app=client --command -- sleep infinity
   kubectl -n tenant-a wait --for=condition=Ready pod/client
   ```

2. Aplicá una política **default-deny ingress** en `tenant-a`. El `podSelector: {}` selecciona *todos* los pods; el bloque `ingress` vacío significa "cero orígenes permitidos":

   ```yaml
   # default-deny-ingress.yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: default-deny-ingress
     namespace: tenant-a
   spec:
     podSelector: {}
     policyTypes:
       - Ingress
   ```

   ```bash
   kubectl apply -f default-deny-ingress.yaml
   ```

3. Verificá que el tráfico **entrante** a `web` quedó cortado — tanto desde otro namespace como desde dentro del mismo:

   ```bash
   # Desde tenant-b (debe fallar por timeout)
   kubectl -n tenant-b run probe --image=nicolaka/netshoot -it --rm \
     --restart=Never -- \
     curl -s -m 5 -o /dev/null -w "%{http_code}\n" \
     http://web.tenant-a.svc.cluster.local
   ```

   ```text
   000
   command terminated with exit code 28
   pod "probe" deleted
   ```

   > `000` + exit `28` = timeout de `curl`: el paquete se descartó, la conexión nunca se estableció (compará con un `Connection refused`, que sería una conexión *permitida* pero sin servicio escuchando).

4. Ahora permití **sólo** al pod `app=client` del propio namespace hablar con `app=web` en el puerto 80. Las `NetworkPolicy` son **aditivas**: esta segunda política *suma* un permiso sobre el default-deny:

   ```yaml
   # allow-client-to-web.yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-client-to-web
     namespace: tenant-a
   spec:
     podSelector:
       matchLabels:
         app: web
     policyTypes:
       - Ingress
     ingress:
       - from:
           - podSelector:
               matchLabels:
                 app: client
         ports:
           - protocol: TCP
             port: 80
   ```

   ```bash
   kubectl apply -f allow-client-to-web.yaml
   ```

5. Probá desde el cliente autorizado (debe funcionar) y desde `tenant-b` (debe seguir bloqueado):

   ```bash
   kubectl -n tenant-a exec client -- \
     curl -s -m 5 -o /dev/null -w "cliente-autorizado: %{http_code}\n" \
     http://web.tenant-a.svc.cluster.local

   kubectl -n tenant-b run probe --image=nicolaka/netshoot -it --rm \
     --restart=Never -- \
     curl -s -m 5 -o /dev/null -w "cross-namespace: %{http_code}\n" \
     http://web.tenant-a.svc.cluster.local
   ```

   ```text
   cliente-autorizado: 200
   cross-namespace: 000
   command terminated with exit code 28
   pod "probe" deleted
   ```

6. Para permitir un namespace entero como origen (patrón multi-tenant típico), etiquetá el namespace y usá `namespaceSelector`. Observá que `kubernetes.io/metadata.name` es una etiqueta que el API server pone automáticamente en cada namespace:

   ```bash
   kubectl get ns tenant-b --show-labels
   ```

   ```text
   NAME       STATUS   AGE   LABELS
   tenant-b   Active   9m    kubernetes.io/metadata.name=tenant-b
   ```

   ```yaml
   # allow-from-tenant-b.yaml  (ejemplo — NO lo apliques si querés mantener el corte)
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-from-tenant-b
     namespace: tenant-a
   spec:
     podSelector:
       matchLabels:
         app: web
     policyTypes:
       - Ingress
     ingress:
       - from:
           - namespaceSelector:
               matchLabels:
                 kubernetes.io/metadata.name: tenant-b
   ```

> **Preguntas de comprensión (bloque 2)**
> 2.1 Antes de aplicar `allow-client-to-web`, el default-deny ya estaba activo. ¿Qué hubiera pasado si aplicabas *primero* el `allow` y *después* el `default-deny`? Justificá con la semántica aditiva.
> 2.2 En el paso 3, `curl` devolvió `000`/timeout en vez de `Connection refused`. ¿Qué te dice esa diferencia sobre *dónde* se descartó el paquete?
> 2.3 La política del paso 4 sólo declara `policyTypes: [Ingress]`. ¿El tráfico **de salida** (egress) de `web` quedó restringido? ¿Qué habría que agregar para un modelo egress default-deny?
> 2.4 ¿Cuál es la diferencia práctica entre estas dos formas dentro de un `from`, y por qué la segunda es más restrictiva?
> ```yaml
> - namespaceSelector: {...}     # forma A
>   podSelector: {...}
> ---
> - namespaceSelector: {...}     # forma B (dos entradas de lista)
> - podSelector: {...}
> ```
> 2.5 Aplicaste todo correctamente pero el tráfico *nunca* se bloquea. Nombrá la causa más probable relacionada con el punto de "Prerrequisitos".

---

## Ejercicio 3 — Aislamiento del kernel: `RuntimeClass` y sandboxing (gVisor)

**Objetivo**: distinguir el aislamiento *namespace-de-Linux* de un contenedor normal (comparte el kernel del host) del aislamiento *fuerte* de un runtime sandbox como gVisor (`runsc`) o Kata Containers, y aprender a **detectar** en qué runtime corre un pod.

1. Comprobá qué `RuntimeClass` hay disponibles en el cluster (dependen de cómo esté configurado containerd en los nodos):

   ```bash
   kubectl get runtimeclass
   ```

   ```text
   NAME     HANDLER   AGE
   gvisor   runsc     3d
   kata     kata      3d
   ```

2. Como línea base, mirá el kernel que ve un contenedor **normal** (runtime por defecto). Comparte el kernel del host:

   ```bash
   kubectl run host-kernel --image=busybox:1.36 --restart=Never -it --rm -- \
     uname -r
   ```

   ```text
   6.8.0-45-generic
   pod "host-kernel" deleted
   ```

3. Ahora corré el **mismo comando** en un pod sandboxeado con gVisor. La clave es `spec.runtimeClassName`:

   ```yaml
   # sandboxed-pod.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: sandboxed
   spec:
     runtimeClassName: gvisor
     containers:
       - name: shell
         image: busybox:1.36
         command: ["sleep", "infinity"]
   ```

   ```bash
   kubectl apply -f sandboxed-pod.yaml
   kubectl wait --for=condition=Ready pod/sandboxed
   kubectl exec sandboxed -- uname -r
   ```

   ```text
   4.4.0
   ```

   > gVisor presenta un **kernel sintético** (implementado en user-space por el *Sentry*), no el `6.8.0-...` del host. El pod ya no comparte la superficie de syscalls del kernel real.

4. Confirmá el sandbox de otra forma muy visual: el `dmesg` "de mentira" que emite gVisor:

   ```bash
   kubectl exec sandboxed -- dmesg
   ```

   ```text
   [    0.000000] Starting gVisor...
   [    0.417392] Checking naughty and nice process list...
   [    0.623511] Generating random numbers by fair dice roll...
   [    0.845201] Creating process schedule...
   [    1.019874] Ready!
   ```

   (En un contenedor normal sin `CAP_SYSLOG`, `dmesg` daría `Operation not permitted`; el punto es que gVisor **simula** el kernel en vez de exponer el del host.)

5. Comprobá el impacto: intentá una operación que toque directamente el kernel del host. En gVisor muchas syscalls exóticas están *no implementadas* o interceptadas por el Sentry, no ejecutadas contra el kernel real:

   ```bash
   kubectl exec sandboxed -- sh -c 'cat /proc/version'
   ```

   ```text
   Linux version 4.4.0 #1 SMP Sun Jan 10 15:06:54 PST 2016
   ```

6. Limpieza:

   ```bash
   kubectl delete pod sandboxed --ignore-not-found
   ```

> **Preguntas de comprensión (bloque 3)**
> 3.1 En el paso 2 el contenedor normal reportó `6.8.0-45-generic` y en el paso 3 el sandbox reportó `4.4.0`. Explicá qué cambió respecto a la **superficie de ataque del kernel del host**.
> 3.2 gVisor y Kata Containers logran aislamiento fuerte de formas *arquitectónicamente distintas*. Describí ambas en una frase cada una.
> 3.3 ¿Qué campo del `PodSpec` selecciona el runtime, y a qué apunta el `HANDLER` que se ve en `kubectl get runtimeclass`?
> 3.4 Un compañero dice: "para aislar de verdad un workload no confiable, dropeo todas las capabilities y aplico seccomp `RuntimeDefault`; eso equivale a un sandbox". ¿En qué se diferencia eso de gVisor/Kata en términos de la frontera que cruzan las syscalls?

---

## Ejercicio 4 — Primitivas de aislamiento del contenedor: `securityContext`, capabilities y seccomp

**Objetivo**: ver que incluso sin sandbox, el aislamiento de un contenedor normal se *endurece* recortando lo que puede pedirle al kernel compartido — el corazón del "least privilege" a nivel de proceso que exige el temario.

1. Como base, observá que un contenedor *root sin restricciones* tiene un set amplio de capabilities:

   ```bash
   kubectl run caps-default --image=busybox:1.36 --restart=Never -it --rm -- \
     sh -c 'grep CapEff /proc/1/status'
   ```

   ```text
   CapEff:	00000000a80425fb
   pod "caps-default" deleted
   ```

   Decodificá ese bitmask (si tenés `capsh` a mano):

   ```bash
   capsh --decode=00000000a80425fb
   ```

   ```text
   0x00000000a80425fb=cap_chown,cap_dac_override,cap_fowner,cap_fsetid,
   cap_kill,cap_setgid,cap_setuid,cap_setpcap,cap_net_bind_service,
   cap_net_raw,cap_sys_chroot,cap_mknod,cap_audit_write,cap_setfcap
   ```

2. Desplegá un pod **endurecido**: no-root, sin privilege escalation, todas las capabilities dropeadas, root filesystem de sólo lectura y perfil seccomp `RuntimeDefault`:

   ```yaml
   # hardened-pod.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: hardened
   spec:
     securityContext:
       runAsNonRoot: true
       runAsUser: 10001
       seccompProfile:
         type: RuntimeDefault
     containers:
       - name: app
         image: busybox:1.36
         command: ["sleep", "infinity"]
         securityContext:
           allowPrivilegeEscalation: false
           readOnlyRootFilesystem: true
           capabilities:
             drop: ["ALL"]
   ```

   ```bash
   kubectl apply -f hardened-pod.yaml
   kubectl wait --for=condition=Ready pod/hardened
   ```

3. Verificá que las capabilities efectivas ahora son **cero**:

   ```bash
   kubectl exec hardened -- grep CapEff /proc/1/status
   ```

   ```text
   CapEff:	0000000000000000
   ```

4. Comprobá que las restricciones "muerden" de verdad. Un `ping` necesita `CAP_NET_RAW` (dropeada) y escribir en `/` está prohibido por `readOnlyRootFilesystem`:

   ```bash
   kubectl exec hardened -- ping -c1 127.0.0.1
   kubectl exec hardened -- sh -c 'echo x > /test'
   ```

   ```text
   ping: permission denied (are you root?)
   command terminated with exit code 1
   sh: can't create /test: Read-only file system
   command terminated with exit code 1
   ```

5. Relacioná esto con la admisión a nivel de namespace: etiquetá `tenant-a` con **Pod Security Admission** en modo `restricted` y probá que un pod inseguro es **rechazado en admission**, antes de llegar a scheduler:

   ```bash
   kubectl label ns tenant-a \
     pod-security.kubernetes.io/enforce=restricted --overwrite

   kubectl -n tenant-a run bad --image=busybox:1.36 --restart=Never -- \
     sleep 60
   ```

   ```text
   Error from server (Forbidden): pods "bad" is forbidden: violates PodSecurity
   "restricted:latest": allowPrivilegeEscalation != false (container "bad" must
   set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities
   (container "bad" must set securityContext.capabilities.drop=["ALL"]),
   runAsNonRoot != true (pod or container "bad" must set
   securityContext.runAsNonRoot=true), seccompProfile (pod or container "bad"
   must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
   ```

6. Limpieza:

   ```bash
   kubectl delete pod hardened --ignore-not-found
   kubectl label ns tenant-a pod-security.kubernetes.io/enforce-
   ```

> **Preguntas de comprensión (bloque 4)**
> 4.1 `CapEff` pasó de `a80425fb` a `0000...0`. ¿Qué relación tiene esto con la reducción de la superficie de ataque *sobre el kernel compartido del host*?
> 4.2 ¿Por qué `readOnlyRootFilesystem: true` es una medida de *segmentación* además de integridad? Pensá en un atacante que ya ejecuta código en el contenedor.
> 4.3 El pod inseguro del paso 5 fue rechazado por **Pod Security Admission**, no por seccomp ni capabilities. Explicá en qué **capa** actúa PSA y por qué es una defensa "más temprana" que el `securityContext` del propio pod.
> 4.4 seccomp `RuntimeDefault` no es lo mismo que gVisor. ¿Qué hace exactamente `RuntimeDefault` y por qué sigue dejando al contenedor sobre el kernel del host?

---

## Ejercicio 5 — Aislamiento de nodos y por qué NO es un límite de seguridad fuerte

**Objetivo**: distinguir *scheduling isolation* (colocar workloads en nodos dedicados con taints/tolerations y `nodeSelector`) del *aislamiento de seguridad*. El temario insiste en que dedicar nodos reduce el radio de impacto, pero **no** contiene por sí solo a un atacante con acceso al nodo.

1. Elegí un nodo y "reservalo" para cargas sensibles con un `taint` `NoSchedule`:

   ```bash
   NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
   kubectl taint nodes "$NODE" tier=secure:NoSchedule
   kubectl label nodes "$NODE" tier=secure --overwrite
   echo "$NODE"
   ```

   ```text
   node/kind-worker tainted
   node/kind-worker labeled
   kind-worker
   ```

2. Un pod **sin toleration** ya no puede aterrizar ahí. Forzalo con `nodeSelector` y observá que queda `Pending`:

   ```bash
   kubectl run intruder --image=pause:3.9 --restart=Never \
     --overrides='{"spec":{"nodeSelector":{"tier":"secure"}}}'
   kubectl get pod intruder -o wide
   kubectl describe pod intruder | grep -A2 Events
   ```

   ```text
   NAME       READY   STATUS    RESTARTS   AGE   NODE
   intruder   0/1     Pending   0          8s    <none>
   Events:
     Warning  FailedScheduling  ...  0/3 nodes are available: 1 node(s) had
     untolerated taint {tier: secure}, 2 node(s) didn't match nodeSelector.
   ```

3. Un pod **autorizado** declara la `toleration` + `nodeSelector` y sí se programa en el nodo dedicado:

   ```yaml
   # secure-workload.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: secure-workload
   spec:
     nodeSelector:
       tier: secure
     tolerations:
       - key: tier
         operator: Equal
         value: secure
         effect: NoSchedule
     containers:
       - name: app
         image: nginx:1.27
   ```

   ```bash
   kubectl apply -f secure-workload.yaml
   kubectl get pod secure-workload -o wide
   ```

   ```text
   NAME              READY   STATUS    RESTARTS   AGE   NODE
   secure-workload   1/1     Running   0          6s    kind-worker
   ```

4. **Demostrá el límite del "aislamiento por nodo"**: taints y nodeSelector son decisiones del *scheduler*, no controles de seguridad. Un actor con permiso para crear pods con `tolerations` (o un DaemonSet) puede colocarse en el nodo "seguro". Mostralo:

   ```bash
   kubectl run also-here --image=pause:3.9 --restart=Never --overrides='{
     "spec":{
       "nodeSelector":{"tier":"secure"},
       "tolerations":[{"key":"tier","operator":"Exists"}]
     }}'
   kubectl get pod also-here -o wide
   ```

   ```text
   NAME        READY   STATUS    RESTARTS   AGE   NODE
   also-here   1/1     Running   0          5s    kind-worker
   ```

   > El taint **no** impidió que un tercero llegara al nodo: alcanzó con declarar una toleration. La verdadera contención "por nodo" ante un contenedor que escapa se obtiene con **sandboxing (Ej. 3)**, RBAC estricto sobre creación de pods/tolerations y, en multi-tenant duro, **clusters separados**.

5. Limpieza:

   ```bash
   kubectl delete pod intruder secure-workload also-here --ignore-not-found
   kubectl taint nodes "$NODE" tier=secure:NoSchedule-
   kubectl label nodes "$NODE" tier-
   ```

6. Limpieza global de todo el laboratorio:

   ```bash
   kubectl delete namespace tenant-a tenant-b
   ```

> **Preguntas de comprensión (bloque 5)**
> 5.1 En el paso 4, `also-here` terminó en el nodo "seguro" pese al taint. ¿Por qué taints/tolerations son *scheduling isolation* y no *security isolation*?
> 5.2 Ordená de más débil a más fuerte estas fronteras frente a **un contenedor que logra un kernel exploit**: (a) `Namespace`, (b) `NetworkPolicy`, (c) taint de nodo, (d) `RuntimeClass` sandbox (gVisor/Kata), (e) cluster separado. Justificá los dos extremos.
> 5.3 En un escenario de *hard multi-tenancy* (inquilinos mutuamente desconfiados, p. ej. SaaS que corre código de usuarios), ¿por qué la guía de multi-tenancy de Kubernetes suele terminar recomendando **clusters separados** o al menos sandboxing obligatorio en lugar de sólo namespaces + NetworkPolicy?

---

## Respuestas

<details>
<summary>Mostrar / ocultar soluciones y explicaciones</summary>

### Bloque 1 — Namespaces

**1.1** Que el `Namespace` **no aísla la red**. Por defecto la red de pods de Kubernetes es *plana*: todo pod puede alcanzar a cualquier otro pod o Service del cluster, sin importar el namespace, salvo que exista una `NetworkPolicy`. El `200` prueba que el aislamiento de nombres no implica aislamiento de conectividad. Fuente: [Namespaces](https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/) y [Cluster Networking — el modelo asume conectividad pod-a-pod sin NAT](https://kubernetes.io/docs/concepts/cluster-administration/networking/).

**1.2** *Da scope a*: (1) nombres de objetos namespaced (no puede haber dos `Service web` en el mismo ns, pero sí uno por ns); (2) RBAC vía `Role`/`RoleBinding`; (3) `ResourceQuota` y `LimitRange`; (también `NetworkPolicy`, `ServiceAccount` por defecto). *No da scope a*: la **red** (plana por defecto) y el **kernel del nodo** (los pods de distintos namespaces pueden compartir el mismo nodo y kernel). Tampoco aísla objetos cluster-scoped (Nodes, PersistentVolumes, `ClusterRole`).

**1.3** Porque un `Namespace` es una construcción de la **capa de control (API/etcd)**, no del **kernel**. Si un contenedor de `tenant-a` escapa al nodo (kernel exploit, montaje del socket del container runtime, hostPath, privilegios), puede tocar contenedores de `tenant-b` que compartan ese nodo — el namespace de Kubernetes no lo detiene. Por eso separar tenants sólo con namespaces es *soft multi-tenancy*: sirve entre equipos que confían entre sí, no como barrera frente a un adversario. Fuente: [Multi-tenancy](https://kubernetes.io/docs/concepts/security/multi-tenancy/).

### Bloque 2 — NetworkPolicy

**2.1** No cambiaría nada: **el orden de aplicación es irrelevante**. Las `NetworkPolicy` son **aditivas** y no tienen prioridad ni orden — la conexión se permite si *alguna* política que seleccione al pod la permite. Un pod queda en "deny-by-default" para una dirección en cuanto es seleccionado por *al menos una* política con ese `policyType`; a partir de ahí, cada política que lo seleccione *agrega* orígenes/destinos permitidos (unión de reglas). Fuente: [Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/).

**2.2** `Connection refused` significaría que el paquete **llegó** al pod destino pero nada escuchaba en ese puerto (conexión permitida). `000` + timeout (`curl` exit `28`) significa que el paquete fue **descartado silenciosamente** por el enforcement del CNI (dropped), antes de establecer la conexión. La diferencia confirma que la `NetworkPolicy` está actuando a nivel de red y no es un simple error de servicio.

**2.3** No, el egress de `web` **no** quedó restringido: con `policyTypes: [Ingress]`, la política sólo gobierna el tráfico entrante. Para egress default-deny se agrega una política con `policyTypes: [Egress]`, `podSelector: {}` y `egress` vacío (recordando abrir explícitamente el **DNS**, puerto 53 UDP/TCP hacia `kube-system`, o casi todo se romperá):
```yaml
policyTypes: [Egress]
egress:
  - to: [{namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}}}]
    ports: [{protocol: UDP, port: 53}, {protocol: TCP, port: 53}]
```

**2.4** *Forma A* (un solo elemento de lista con `namespaceSelector` **y** `podSelector`) = **AND lógico**: "pods con esas labels que estén *además* en namespaces con esas labels". *Forma B* (dos elementos de lista `-`) = **OR lógico**: "pods con esas labels en *cualquier* namespace, **o** *cualquier* pod en esos namespaces". La forma A es más restrictiva porque exige que se cumplan ambas condiciones a la vez. Es un error de examen (y de producción) muy común. Fuente: [Network Policies — `namespaceSelector` and `podSelector`](https://kubernetes.io/docs/concepts/services-networking/network-policies/).

**2.5** El **CNI no implementa NetworkPolicy**. El objeto `NetworkPolicy` se acepta y se guarda en la API aunque el plugin de red no lo aplique — no hay error. Con `flannel` puro (sin Calico for policy), las políticas son inertes y el tráfico nunca se bloquea. Hay que usar un CNI que las enforce (Calico, Cilium, Antrea, Weave).

### Bloque 3 — RuntimeClass / Sandboxing

**3.1** Un contenedor normal **comparte el kernel del host** (mismo `6.8.0-45-generic`): todas sus syscalls van directo al kernel real, así que la superficie de ataque es el kernel completo del nodo. Con gVisor, el proceso ve un **kernel de aplicación en user-space (el Sentry)** que reimplementa la interfaz de syscalls de Linux e intercepta las llamadas; el kernel del host queda expuesto sólo a un conjunto reducido y controlado de syscalls que hace el propio Sentry. Un exploit del kernel dentro del contenedor golpea al Sentry, no al kernel del nodo — la superficie de ataque se reduce drásticamente. Fuente: [gVisor — What is gVisor](https://gvisor.dev/docs/) y [RuntimeClass](https://kubernetes.io/docs/concepts/containers/runtime-class/).

**3.2** **gVisor**: un "kernel de aplicación" en espacio de usuario (`runsc`/Sentry) que intercepta y reimplementa las syscalls del contenedor, sin ejecutar código no confiable directamente sobre el kernel del host. **Kata Containers**: ejecuta cada pod dentro de una **máquina virtual ligera** con su propio kernel invitado, usando virtualización de hardware, de modo que la frontera es el hipervisor en lugar de sólo los namespaces de Linux. Fuentes: [gVisor](https://gvisor.dev/docs/), [Kata Containers](https://katacontainers.io/).

**3.3** El campo es `spec.runtimeClassName`. Apunta al nombre de un objeto `RuntimeClass`, cuyo campo `handler` (columna `HANDLER`) identifica la configuración del runtime en el CRI del nodo — p. ej. containerd asocia el handler `runsc` a gVisor o `kata` a Kata en su `config.toml`. Fuente: [RuntimeClass](https://kubernetes.io/docs/concepts/containers/runtime-class/).

**3.4** Dropear capabilities + seccomp `RuntimeDefault` **endurece** el contenedor, pero las syscalls permitidas **siguen ejecutándose contra el kernel del host** (un solo kernel compartido). gVisor/Kata cambian *dónde* se resuelven las syscalls: gVisor las atiende en el Sentry (user-space), Kata dentro de un kernel invitado en una VM. Es la diferencia entre *restringir* qué le pedís al kernel del host y *no tocar* directamente ese kernel. Por eso el sandbox es una frontera más fuerte frente a kernel exploits.

### Bloque 4 — securityContext / capabilities / seccomp

**4.1** Cada capability es un permiso para invocar familias de syscalls privilegiadas sobre el **kernel compartido**. Con `CapEff = 0` el proceso pierde `CAP_NET_RAW`, `CAP_SYS_ADMIN`-adyacentes, `CAP_MKNOD`, etc.: aunque comparta el kernel del host, la superficie de syscalls privilegiadas que puede ejercer se reduce casi a cero, así que un bug de escalada que dependa de una capability deja de ser explotable. Fuente: [Set capabilities for a Container](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/#set-capabilities-for-a-container).

**4.2** Porque impide que el atacante **persista o modifique** el filesystem del contenedor: no puede dejar binarios, webshells, cron, ni sobrescribir configs/binarios existentes para movimiento lateral. Segmenta el "blast radius" temporal — cualquier cambio se pierde al reiniciar el pod — y obliga a montar volúmenes escribibles explícitos y acotados (`emptyDir`, etc.) para las rutas que realmente lo necesiten.

**4.3** **Pod Security Admission (PSA)** actúa en la fase de **admission control** del API server, *antes* de que el objeto se persista en etcd y llegue al scheduler/kubelet. Aplica los **Pod Security Standards** (`privileged`/`baseline`/`restricted`) por namespace vía labels `pod-security.kubernetes.io/enforce`. Es "más temprana" porque rechaza el pod inseguro en la puerta de entrada, mientras que un `securityContext` es una configuración *del propio pod* que un usuario podría simplemente omitir: PSA lo hace obligatorio a nivel de namespace. Fuentes: [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/), [Enforce Pod Security Standards with Namespace Labels](https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-namespace-labels/).

**4.4** seccomp `RuntimeDefault` aplica el **perfil de seccomp por defecto del container runtime** (containerd/CRI-O), que **filtra/bloquea** un conjunto de syscalls peligrosas o innecesarias (con `SCMP_ACT_ERRNO`) para los procesos del contenedor. Pero las syscalls que sí pasa el filtro se ejecutan **directamente sobre el kernel del host**: seccomp reduce la superficie, no introduce una capa de indirección como el Sentry de gVisor ni una VM como Kata. Sigue siendo un contenedor sobre el kernel compartido. Fuente: [Restrict a Container's Syscalls with seccomp](https://kubernetes.io/docs/tutorials/security/seccomp/).

### Bloque 5 — Aislamiento de nodos

**5.1** Porque taints/tolerations y `nodeSelector`/affinity son insumos de la **decisión de scheduling**: dicen *dónde prefiere/puede* aterrizar un pod, no *quién tiene derecho* a hacerlo. Cualquiera que pueda crear un pod (o DaemonSet) con la `toleration` correspondiente elude el taint, como mostró `also-here`. Son controles de *disponibilidad/colocación*, no de seguridad; para convertirlos en algo con valor de seguridad hace falta **RBAC** que limite quién puede crear pods con tolerations, sumado a controles de kernel. Fuente: [Taints and Tolerations](https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/).

**5.2** De más débil a más fuerte frente a un kernel exploit: **(a) Namespace → (c) taint de nodo → (b) NetworkPolicy → (d) RuntimeClass sandbox → (e) cluster separado**.
- Extremo débil — *(a) Namespace*: es puramente lógico (API/etcd); no interpone ninguna barrera de kernel ni de red frente a un contenedor que ya escapó al nodo. (Los taints, (c), y las NetworkPolicy, (b), tampoco frenan un escape de kernel; una NetworkPolicy al menos limita el movimiento lateral por red *después* del compromiso, de ahí que se lo ubique por encima del taint.)
- Extremo fuerte — *(e) cluster separado*: elimina el kernel compartido, la API compartida y la red compartida; el radio de impacto de un compromiso queda contenido en ese cluster. *(d) sandbox* es la frontera de kernel más fuerte *dentro* de un mismo cluster, pero comparte control plane. (Cualquier justificación coherente de los dos extremos es válida.)

**5.3** Porque namespaces + NetworkPolicy + RBAC son **soft multi-tenancy**: todos los tenants comparten un mismo **kernel de nodo** y un mismo **control plane/API server + etcd**. Frente a inquilinos mutuamente desconfiados que ejecutan código arbitrario, un solo escape de contenedor (kernel exploit, bug del runtime) o una escalada en el API server compromete a todos. La guía de multi-tenancy recomienda, para *hard multi-tenancy*, o bien **clusters separados** (aislamiento máximo de kernel y control plane) o, como mínimo, **sandboxing obligatorio** (gVisor/Kata) más políticas estrictas, precisamente porque las fronteras lógicas no contienen a un adversario a nivel de kernel. Fuente: [Multi-tenancy](https://kubernetes.io/docs/concepts/security/multi-tenancy/).

</details>