# Ejercicios guiados: Isolation techniques (multi-tenancy, sandboxed containers) — CKS 2.3

> Prerequisito: un cluster con al menos 2 nodos worker, `kubectl` configurado, y (para el Ejercicio 3) un containerd con un runtime handler alternativo instalado (`runsc`/gVisor o `kata`). Si tu cluster no tiene el binario instalado, podés seguir los pasos de creación del objeto `RuntimeClass` igual — es lo que se evalúa en el examen, no la instalación del runtime en sí.

---

## Ejercicio 1: Namespaces, ResourceQuota y LimitRange como base de soft multi-tenancy

1. Creá dos namespaces que representen dos tenants distintos:
   ```bash
   kubectl create namespace tenant-a
   kubectl create namespace tenant-b
   ```

2. Aplicá un `ResourceQuota` sobre `tenant-a` que limite la cantidad de Pods y el consumo agregado de CPU/memoria:
   ```yaml
   # quota-tenant-a.yaml
   apiVersion: v1
   kind: ResourceQuota
   metadata:
     name: tenant-a-quota
     namespace: tenant-a
   spec:
     hard:
       pods: "3"
       requests.cpu: "1"
       requests.memory: 1Gi
       limits.cpu: "2"
       limits.memory: 2Gi
   ```
   ```bash
   kubectl apply -f quota-tenant-a.yaml
   ```

3. Intentá crear un cuarto Pod en `tenant-a` (con al menos 3 corriendo) y observá el resultado:
   ```bash
   kubectl run test-pod --image=nginx -n tenant-a --restart=Never \
     --requests='cpu=100m,memory=128Mi'
   kubectl get events -n tenant-a --field-selector reason=FailedCreate
   ```

4. Agregá un `LimitRange` en `tenant-a` que fije valores por defecto de `request`/`limit` por contenedor:
   ```yaml
   # limitrange-tenant-a.yaml
   apiVersion: v1
   kind: LimitRange
   metadata:
     name: tenant-a-limits
     namespace: tenant-a
   spec:
     limits:
     - default:
         cpu: 500m
         memory: 256Mi
       defaultRequest:
         cpu: 100m
         memory: 128Mi
       type: Container
   ```
   ```bash
   kubectl apply -f limitrange-tenant-a.yaml
   ```

5. Desplegá un Pod en `tenant-a` **sin** especificar `resources` y confirmá que el `LimitRange` le inyectó los valores por defecto:
   ```bash
   kubectl run no-resources --image=nginx -n tenant-a --restart=Never
   kubectl get pod no-resources -n tenant-a -o jsonpath='{.spec.containers[0].resources}'
   ```

**Preguntas de comprensión — Ejercicio 1**
1. ¿Por qué un `Namespace` por sí solo no constituye un límite de seguridad ni de recursos entre tenants?
2. ¿Cuál es la diferencia funcional entre `ResourceQuota` y `LimitRange`?

---

## Ejercicio 2: Aislamiento de red entre tenants con NetworkPolicy

1. Desplegá un Pod de prueba en cada namespace:
   ```bash
   kubectl run web-a --image=nginx -n tenant-a --labels=app=web
   kubectl run web-b --image=nginx -n tenant-b --labels=app=web
   ```

2. Antes de aplicar ninguna política, verificá que hay conectividad cruzada entre tenants (esto es el estado por defecto e inseguro):
   ```bash
   kubectl run test-curl --image=busybox -n tenant-b --rm -it --restart=Never -- \
     wget -qO- --timeout=2 <IP_de_web-a>
   ```

3. Aplicá una política de **default-deny** para todo el tráfico entrante en `tenant-a`:
   ```yaml
   # default-deny-tenant-a.yaml
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
   kubectl apply -f default-deny-tenant-a.yaml
   ```

4. Repetí el `wget` del paso 2 y confirmá que ahora falla por timeout.

5. Agregá una segunda `NetworkPolicy` que permita únicamente tráfico interno de `tenant-a` hacia `web-a`, y repetí el test desde un Pod dentro de `tenant-a`:
   ```yaml
   # allow-intra-tenant-a.yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: allow-intra-tenant-a
     namespace: tenant-a
   spec:
     podSelector:
       matchLabels:
         app: web
     ingress:
     - from:
       - namespaceSelector:
           matchLabels:
             kubernetes.io/metadata.name: tenant-a
   ```

**Preguntas de comprensión — Ejercicio 2**
1. ¿Qué requisito de infraestructura es necesario para que `NetworkPolicy` tenga efecto real (más allá de existir como objeto en el API server)?
2. En un modelo de soft multi-tenancy, ¿por qué conviene arrancar con una política default-deny por namespace en lugar de escribir reglas de permiso caso por caso desde cero?

---

## Ejercicio 3: Sandboxed containers con RuntimeClass (gVisor)

1. Verificá qué runtime handlers tiene configurados containerd en el nodo (requiere acceso SSH/exec al nodo, o revisar vía `crictl` si el handler alternativo ya está instalado):
   ```bash
   cat /etc/containerd/config.toml | grep -A3 'runtimes\.'
   ```

2. Creá el objeto `RuntimeClass` que expone el handler sandboxed al API de Kubernetes:
   ```yaml
   # runtimeclass-gvisor.yaml
   apiVersion: node.k8s.io/v1
   kind: RuntimeClass
   metadata:
     name: gvisor
   handler: runsc
   ```
   ```bash
   kubectl apply -f runtimeclass-gvisor.yaml
   kubectl get runtimeclass
   ```

3. Desplegá un Pod que solicite explícitamente ese `RuntimeClass`:
   ```yaml
   # pod-sandboxed.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: sandboxed-pod
     namespace: tenant-a
   spec:
     runtimeClassName: gvisor
     containers:
     - name: app
       image: nginx
   ```
   ```bash
   kubectl apply -f pod-sandboxed.yaml
   kubectl get pod sandboxed-pod -n tenant-a -o jsonpath='{.spec.runtimeClassName}'
   ```

4. Confirmá que el Pod está corriendo efectivamente bajo el kernel de gVisor (el string de versión del kernel dentro del sandbox difiere del kernel real del nodo):
   ```bash
   kubectl exec -n tenant-a sandboxed-pod -- dmesg | head -1
   ```

5. Compará contra un Pod sin `runtimeClassName` (runtime por defecto, `runc`) corriendo `dmesg` de la misma forma, y notá la diferencia.

**Preguntas de comprensión — Ejercicio 3**
1. ¿Qué capa de aislamiento agrega gVisor (o Kata Containers) que los namespaces/cgroups de Linux no proveen por sí solos?
2. ¿En qué escenario de multi-tenancy tiene sentido pagar el costo de performance de un runtime sandboxed en lugar de usar únicamente `runc`?
3. Si un Pod define `runtimeClassName` pero el handler correspondiente no existe en el nodo asignado, ¿qué ocurre con la programación del Pod?

---

## Ejercicio 4: Aislamiento a nivel de nodo (node isolation) para tenants sensibles

1. Aplicá un `taint` a un nodo para reservarlo exclusivamente para `tenant-a`:
   ```bash
   kubectl taint nodes <nombre-nodo> dedicated=tenant-a:NoSchedule
   kubectl label nodes <nombre-nodo> dedicated=tenant-a
   ```

2. Desplegá un Pod en `tenant-b` sin `toleration` y confirmá que **no** puede ser programado en ese nodo:
   ```bash
   kubectl get pod -n tenant-b -o wide
   ```

3. Desplegá un Pod en `tenant-a` con la `toleration` y el `nodeAffinity` correspondientes para que caiga en el nodo dedicado:
   ```yaml
   # pod-dedicated-node.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: dedicated-pod
     namespace: tenant-a
   spec:
     tolerations:
     - key: "dedicated"
       operator: "Equal"
       value: "tenant-a"
       effect: "NoSchedule"
     affinity:
       nodeAffinity:
         requiredDuringSchedulingIgnoredDuringExecution:
           nodeSelectorTerms:
           - matchExpressions:
             - key: dedicated
               operator: In
               values: ["tenant-a"]
     containers:
     - name: app
       image: nginx
   ```
   ```bash
   kubectl apply -f pod-dedicated-node.yaml
   kubectl get pod dedicated-pod -n tenant-a -o wide
   ```

4. Confirmá que un Pod de `tenant-a` con `toleration` pero **sin** `nodeAffinity` puede terminar en cualquier nodo, no solo el dedicado — esto ilustra por qué ambos mecanismos se usan combinados.

**Preguntas de comprensión — Ejercicio 4**
1. ¿Por qué un `taint`/`toleration` por sí solo no garantiza que los Pods de `tenant-a` sean programados en el nodo dedicado?
2. ¿Cuándo se justifica escalar de soft multi-tenancy (namespaces + policies) a aislamiento por nodo dedicado, y cuándo se justifica ir directamente a hard multi-tenancy (clusters separados)?

---

<details>
<summary><strong>Respuestas</strong></summary>

**Ejercicio 1**
1. Un `Namespace` es solo una partición lógica del espacio de nombres de objetos (nombres, RBAC scope, DNS). No impone ningún límite de recursos ni aislamiento de red por defecto: sin `ResourceQuota`/`LimitRange` un tenant puede consumir todo el CPU/memoria del cluster, y sin `NetworkPolicy` cualquier Pod puede alcanzar cualquier otro Pod de otro namespace.
2. `ResourceQuota` limita el consumo **agregado** de un namespace completo (cantidad de objetos, suma de requests/limits de todos los Pods). `LimitRange` actúa a nivel de **cada Pod/Container individual**, imponiendo mínimos, máximos y valores por defecto cuando no se especifican explícitamente.

**Ejercicio 2**
1. Que el CNI plugin instalado en el cluster implemente (enforce) el recurso `NetworkPolicy`. Plugins como Calico, Cilium o Weave lo soportan; el CNI puente básico (`bridge`) o algunos plugins simples no lo hacen, en cuyo caso el objeto `NetworkPolicy` se crea sin error pero no tiene ningún efecto real.
2. Porque default-deny invierte el modelo de seguridad a "todo prohibido salvo lo explícitamente permitido" (fail-secure). Empezar permitiendo todo y luego restringir deja ventanas de exposición mientras se escriben las reglas, y es fácil olvidar bloquear un flujo.

**Ejercicio 3**
1. gVisor intercepta las syscalls del contenedor en espacio de usuario mediante su propio kernel (Sentry), evitando que el contenedor llegue directamente al kernel del host; Kata Containers logra un efecto similar corriendo cada Pod en una micro-VM con su propio kernel. Esto añade una capa de defensa adicional frente a vulnerabilidades de escape de contenedor (container breakout) que explotan el kernel compartido del host, algo que namespaces y cgroups —al ser mecanismos del mismo kernel— no pueden mitigar.
2. Cuando el cluster ejecuta cargas de trabajo no confiables o de código de terceros dentro del mismo cluster que cargas confiables: por ejemplo, ejecutores de CI/CD que corren jobs de usuarios externos, plataformas multi-tenant tipo PaaS/FaaS, o cualquier escenario donde el costo de un breakout (acceso al host o a otros tenants) sea alto y justifique el overhead de performance del sandboxing.
3. El scheduler no reprograma automáticamente el Pod en otro nodo por esta causa: el Pod queda en estado `Pending` (o falla al crear el contenedor) y el kubelet reporta un error indicando que el runtime handler solicitado no está registrado en ese nodo. Por eso en producción se combina `RuntimeClass` con `nodeAffinity`/`taints` para asegurar que el Pod solo se programe en nodos que tengan el handler instalado.

**Ejercicio 4**
1. Los `taints` solo repelen Pods que **no** tengan la `toleration` correspondiente; no atraen ni fuerzan a que los Pods que sí toleran el taint se programen ahí — esos Pods igual podrían caer en cualquier otro nodo sin taint. Para forzar la ubicación en el nodo dedicado hace falta combinar la `toleration` con `nodeAffinity` (o `nodeSelector`) apuntando a una label específica de ese nodo.
2. Aislamiento por nodo dedicado tiene sentido cuando un tenant requiere garantías de "noisy neighbor" o de compliance que las quotas de namespace no cubren (por ejemplo, requisitos regulatorios de que su carga nunca comparta kernel/hardware con otro tenant), pero sin justificar el costo operativo de un cluster completo aparte. Hard multi-tenancy (clusters separados) se justifica cuando los tenants son mutuamente no confiables a nivel de control plane, o cuando ni compartir el mismo API server/etcd es aceptable por motivos de seguridad o regulatorios.

</details>

---

*Fuente de referencia: [CKS Curriculum v1.34 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf)*