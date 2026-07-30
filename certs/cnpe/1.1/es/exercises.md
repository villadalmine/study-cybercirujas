# Tema 1.1 — Applying Platform Architecture Best Practices for Networking, Storage, and Compute

> Prerrequisitos: un cluster Kubernetes disponible (`kind`, `minikube` o equivalente), `kubectl` configurado, y permisos de cluster-admin para el namespace de pruebas.

---

## Ejercicio 1: Compute — Resource Management y Workload Isolation

En este ejercicio vas a aplicar buenas prácticas de **compute architecture**: definir `requests`/`limits`, aislar workloads críticos mediante `taints`/`tolerations` y usar `nodeAffinity` para ubicar cargas según el tipo de nodo.

### Pasos

1. <PERSON> namespace dedicado para el ejercicio:
   ```bash
   kubectl create namespace platform-lab
   ```

2. Etiquetá uno de tus nodos para simular un *node pool* especializado (por ejemplo, para cargas de alta prioridad):
   ```bash
   kubectl label node <nombre-del-nodo> workload-tier=critical
   ```

3. Aplicá un `taint` a <PERSON> workloads no autorizados se scheduleen ahí:
   ```bash
   kubectl taint node <nombre-del-nodo> dedicated=critical:<PERSON>. <PERSON> manifiesto `critical-deployment.yaml` que incluya `resources.requests`, `resources.limits`, `nodeAffinity` y la `toleration` correspondiente al taint:
   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: critical-app
     namespace: platform-lab
   spec:
     replicas: 2
     selector:
       matchLabels:
         app: critical-app
     template:
       metadata:
         labels:
           app: critical-app
       spec:
         tolerations:
         - key: "dedicated"
           operator: "Equal"
           value: "critical"
           effect: "NoSchedule"
         affinity:
           nodeAffinity:
             requiredDuringSchedulingIgnoredDuringExecution:
               nodeSelectorTerms:
               - matchExpressions:
                 - key: workload-tier
                   operator: In
                   values:
                   - critical
         containers:
         - name: app
           image: nginx:1.27
           resources:
             requests:
               cpu: "250m"
               memory: "256Mi"
             limits:
               cpu: "500m"
               memory: "512Mi"
   ```
   Aplicá el manifiesto:
   ```bash
   kubectl apply -f critical-deployment.yaml
   ```

5. <PERSON> pods hayan sido scheduleados únicamente en el nodo etiquetado:
   ```bash
   kubectl get pods -n platform-lab -o wide
   ```

6. <PERSON> `ResourceQuota` y un `LimitRange` en el namespace para reforzar governance de compute a nivel plataforma:
   ```yaml
   apiVersion: v1
   kind: ResourceQuota
   metadata:
     name: platform-lab-quota
     namespace: platform-lab
   spec:
     hard:
       requests.cpu: "2"
       requests.memory: 2Gi
       limits.cpu: "4"
       limits.memory: 4Gi
   ```

### Preguntas de verificación

1. ¿Por qué combinar `taints`/`tolerations` con `nodeAffinity` es una best practice, en lugar de usar solo uno de los dos mecanismos?
2. ¿Qué diferencia de comportamiento hay entre no definir `limits` de memoria y definir `requests` sin `limits` de CPU, en términos de estabilidad de la plataforma?
3. ¿Qué rol cumple el `LimitRange` frente al `ResourceQuota` en un diseño de plataforma multi-tenant?

---

## Ejercicio 2: Networking — Network Policies y <PERSON> el principio de **least privilege networking** dentro del cluster, un pilar de la arquitectura de plataforma segura.

### Pasos

1. <PERSON> `NetworkPolicy` (por ejemplo Calico, <PERSON>). Verificá con:
   ```bash
   kubectl get pods -n kube-system | grep -Ei "calico|cilium"
   ```

2. Desplegá dos aplicaciones en el namespace `platform-lab`: un `frontend` y un `backend`.
   ```bash
   kubectl create deployment backend --image=hashicorp/http-echo -n platform-lab -- -text="backend-response"
   kubectl create deployment frontend --image=busybox -n platform-lab -- sleep 3600
   kubectl expose deployment backend --port=5678 -n platform-lab
   ```

3. Probá la conectividad *antes* de aplicar políticas (comportamiento default: <PERSON>):
   ```bash
   kubectl exec -n platform-lab deploy/frontend -- wget -qO- backend:5678
   ```

4. Aplicá una política de **default deny** para todo el namespace:
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: <PERSON>
   metadata:
     name: default-deny-all
     namespace: platform-lab
   spec:
     podSelector: {}
     policyTypes:
     - Ingress
     - Egress
   ```

5. Creá una política explícita que permita únicamente al `frontend` alcanzar al `backend` por el puerto 5678:
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: <PERSON>
   metadata:
     name: allow-frontend-to-backend
     namespace: platform-lab
   spec:
     podSelector:
       matchLabels:
         app: backend
     policyTypes:
     - Ingress
     ingress:
     - from:
       - podSelector:
           matchLabels:
             app: frontend
       ports:
       - protocol: TCP
         port: 5678
   ```

6. Repetí la prueba de conectividad del paso 3 y confirmá el resultado.

### Preguntas de verificación

1. ¿Por qué la estrategia de **default deny + allow explícito** se considera una best practice de arquitectura de networking frente a "permitir todo y bloquear excepciones"?
2. <PERSON>frontend` necesitara resolver DNS <PERSON>default-deny-all` bloquea <PERSON>egress`, ¿qué regla adicional habría que agregar y por qué?
3. ¿Qué limitación tiene `NetworkPolicy` nativo de Kubernetes respecto a políticas L7 (por ejemplo, filtrado por método HTTP), y qué tipo de componente de plataforma resolvería esa brecha?

---

## Ejercicio 3: Storage — Dynamic Provisioning y Clases de Storage por Tier

Este ejercicio ilustra cómo diseñar el **storage layer** de la plataforma usando `StorageClass` para ofrecer distintos tiers de performance/durabilidad a los tenants.

### Pasos

1. <PERSON> las `StorageClass` disponibles en el cluster:
   ```bash
   kubectl get storageclass
   ```

2. <PERSON>StorageClass` que representen distintos tiers de servicio (ajustá el `provisioner` a tu entorno, por ejemplo `csi.provisioner.example.com`):
   ```yaml
   apiVersion: storage.k8s.io/v1
   kind: StorageClass
   metadata:
     name: fast-tier
   provisioner: <tu-csi-provisioner>
   parameters:
     type: ssd
   reclaimPolicy: Delete
   volumeBindingMode: WaitForFirstConsumer
   ---
   apiVersion: storage.k8s.io/v1
   kind: StorageClass
   metadata:
     name: standard-tier
   provisioner: <tu-csi-provisioner>
   parameters:
     type: hdd
   reclaimPolicy: Retain
   volumeBindingMode: Immediate
   ```

3. <PERSON> `PersistentVolumeClaim` que consuma el tier `fast-tier`:
   ```yaml
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: fast-pvc
     namespace: platform-lab
   spec:
     accessModes:
       - ReadWriteOnce
     storageClassName: fast-tier
     resources:
       requests:
         storage: 5Gi
   ```

4. <PERSON>` y notá el impacto de `volumeBindingMode: WaitForFirstConsumer`:
   ```bash
   kubectl get pvc -n platform-lab
   ```
   (Debería quedar `Pending` hasta que exista un Pod consumidor).

5. Montá el PVC en un Pod y confirmá que pase a `Bound`:
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: storage-consumer
     namespace: platform-lab
   spec:
     containers:
     - name: app
       image: nginx:1.27
       volumeMounts:
       - mountPath: "/data"
         name: fast-vol
     volumes:
     - name: fast-vol
       persistentVolumeClaim:
         claimName: fast-pvc
   ```
   ```bash
   kubectl apply -f storage-consumer.yaml
   kubectl get pvc -n platform-lab
   ```

6. Compará las políticas de `reclaimPolicy` (`Delete` vs `Retain`) eliminando el PVC y observando el estado del `PersistentVolume` subyacente:
   ```bash
   kubectl delete pvc fast-pvc -n platform-lab
   kubectl get pv
   ```

### Preguntas de verificación

1. ¿Qué ventaja arquitectónica ofrece `volumeBindingMode: WaitForFirstConsumer` en clusters con <PERSON>?
2. ¿Por qué usar `reclaimPolicy: Retain` en un tier de storage podría ser una best practice <PERSON>, a pesar de requerir limpieza manual?
3. Desde el punto de vista de plataforma multi-tenant, ¿qué riesgo mitiga exponer distintas `StorageClass` en lugar de dejar que cada tenant <PERSON>?

---

<details>
<summary><strong>Ver respuestas</strong></summary>

### Ejercicio 1

1. `taints`/`tolerations` **repelen** workloads no deseados de un nodo, pero no garantizan que un workload *tolerante* sea efectivamente ubicado ahí (podría ir a otro nodo sin taint). `nodeAffinity` **atrae** el workload <PERSON>, pero por sí sola no evita que otros workloads (sin afinidad) <PERSON> Combinar ambos mecanismos asegura aislamiento bidireccional: solo el workload correcto entra, y nada más se scheduleará allí sin autorización explícita.
2. No definir `limits` de memoria expone al nodo a **OOM** no controlado, ya <PERSON> kernel puede <PERSON> impredecible cuando la memoria del nodo se agota (afecta a otros pods). No definir `limits` de CPU es menos crítico porque CPU es un recurso *compresible*: el pod es limitado (throttled) <PERSON>, degradando performance <PERSON> del nodo.
3. `ResourceQuota` limita el consumo **agregado** de recursos en el namespace (totales de requests/limits). `LimitRange` define límites **por objeto individual** (por pod o contenedor), incluyendo defaults cuando no se especifican `requests`/`limits`, evitando que un solo pod monopolice la cuota del namespace o quede sin resources especificados.

### Ejercicio 2

1. La estrategia *default deny* sigue el principio de **least privilege**: reduce la superficie de ataque porque cualquier comunicación no declarada explícitamente queda bloqueada, <PERSON> a nuevos deployments futuros. La estrategia inversa (permitir todo y bloquear excepciones) requiere <PERSON> amenaza y <PERSON> insegura ante configuraciones incompletas.
2. Habría que agregar una regla de `egress` que permita tráfico hacia `kube-dns`/`CoreDNS` en el namespace `kube-system`, típicamente sobre el puerto UDP/TCP 53, seleccionando los pods de DNS mediante `namespaceSelector` y `podSelector`. Sin esta regla, el `frontend` no podría resolver nombres de servicio internos <PERSON>.
3. `<PERSON>` nativo opera en las capas L3/L4 (IP, puertos, protocolo) y no entiende contenido de aplicación (headers HTTP, métodos, paths, mTLS de identidad de servicio). Para políticas L7 se necesita un **service mesh** (por ejemplo Istio, Linkerd) o un CNI con capacidades L7 (<PERSON> con `CiliumNetworkPolicy`), que agregan un plano de control/datos adicional para inspección y control a nivel aplicación.

### Ejercicio 3

1. En clusters multi-zona, provisionar el volumen inmediatamente (`Immediate`) puede crear el volumen en una zona distinta a donde finalmente se schedulea el pod, causando fallos de montaje. `WaitForFirstConsumer` retrasa el binding hasta que el scheduler decide el nodo/zona del pod, garantizando que el volumen se cree en la zona correcta.
2. `Retain` evita el borrado automático de datos cuando se elimina el `PVC`, actuando como salvaguarda contra eliminaciones accidentales en datos críticos (por ejemplo, bases de datos). El costo es que el `PersistentVolume` queda en estado `Released` y requiere <PERSON> (limpieza y reciclado) antes de reutilizarse, <PERSON> cambio de mayor <PERSON>.
3. <PERSON> `StorageClass` predefinidas centraliza el control sobre backend de storage, parámetros de performance, políticas de retención y costos, evitando que cada tenant configure provisioners arbitrarios que podrían generar inconsistencias operativas, riesgos de seguridad (acceso directo a APIs de storage backend) o costos no gobernados. Es una aplicación del principio de **self-service dentro de límites curados por la plataforma**.

</details>