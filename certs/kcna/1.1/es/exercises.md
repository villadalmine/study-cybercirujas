# Ejercicios guiados — Kubernetes Core Concepts (KCNA)

> Fuente de referencia: [CNCF KCNA Curriculum](https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf)
> Requisitos: acceso a un cluster de Kubernetes (`minikube`, `kind` o `k3d`) y `kubectl` configurado contra ese cluster.

---

## Ejercicio 1 — Arquitectura del cluster: control plane y worker nodes

1. Verificá que `kubectl` está conectado a un cluster y mostrá la información básica:
   ```bash
   kubectl cluster-info
   ```
2. Listá los nodos del cluster junto con sus roles:
   ```bash
   kubectl get nodes -o wide
   ```
3. Inspeccioná en detalle uno de los nodos (reemplazá `<nombre-nodo>` por uno de los listados arriba):
   ```bash
   kubectl describe node <nombre-nodo>
   ```
   Prestá atención a las secciones `Conditions`, `Capacity` y `Allocatable`.
4. Listá los Pods del namespace `kube-system`, donde corren los componentes del control plane cuando el cluster los expone como Pods:
   ```bash
   kubectl get pods -n kube-system
   ```
5. Identificá en la salida anterior Pods correspondientes a `kube-apiserver`, `etcd`, `kube-scheduler` y `kube-controller-manager` (en clusters gestionados como GKE/EKS/AKS estos componentes no siempre son visibles como Pods, porque el proveedor los administra fuera del cluster).

**Preguntas de comprensión**
- ¿Qué componente del control plane es el único punto de entrada para todas las operaciones sobre el cluster (incluida la comunicación entre los demás componentes)?
- ¿Qué diferencia hay entre un nodo del control plane y un worker node en términos de qué cargas de trabajo del usuario pueden correr ahí por defecto?
- ¿Qué componente del control plane se encarga de decidir en qué nodo se ejecuta un Pod recién creado?

---

## Ejercicio 2 — Pods: la unidad mínima de despliegue

1. Creá un Pod de forma imperativa a partir de una imagen:
   ```bash
   kubectl run nginx-pod --image=nginx:1.25 --restart=Never
   ```
2. Verificá su estado hasta que pase a `Running`:
   ```bash
   kubectl get pod nginx-pod --watch
   ```
   (Salí con `Ctrl+C` una vez que veas `Running`.)
3. Generá el manifiesto YAML equivalente sin crearlo, para ver cómo Kubernetes lo representa internamente:
   ```bash
   kubectl run nginx-pod-2 --image=nginx:1.25 --restart=Never --dry-run=client -o yaml
   ```
4. Guardá ese YAML en un archivo `pod-multi.yaml` y agregá manualmente un segundo container dentro de `spec.containers`, por ejemplo un `busybox` con `command: ["sleep", "3600"]`. Aplicalo:
   ```bash
   kubectl apply -f pod-multi.yaml
   ```
5. Confirmá que el Pod tiene 2/2 containers listos:
   ```bash
   kubectl get pod nginx-pod-2
   ```
6. Revisá los logs de un container específico dentro del Pod multi-container:
   ```bash
   kubectl logs nginx-pod-2 -c nginx
   ```

**Preguntas de comprensión**
- ¿Por qué se dice que el Pod, y no el container, es la unidad mínima que Kubernetes programa (schedules) sobre un nodo?
- Si un Pod tiene dos containers, ¿qué recursos de red y de almacenamiento comparten entre sí?
- ¿Qué le pasa a un Pod creado directamente (como en el paso 1) si el nodo donde corre falla? ¿Por qué es distinto al comportamiento de un Pod gestionado por un Deployment?

---

## Ejercicio 3 — Labels y Selectors

1. Etiquetá el Pod creado en el ejercicio anterior:
   ```bash
   kubectl label pod nginx-pod-2 app=web env=dev
   ```
2. Listá los Pods mostrando sus labels:
   ```bash
   kubectl get pods --show-labels
   ```
3. Filtrá Pods usando un label selector:
   ```bash
   kubectl get pods -l app=web
   ```
4. Probá un selector más restrictivo combinando dos condiciones:
   ```bash
   kubectl get pods -l app=web,env=dev
   ```
5. Probá un selector negativo:
   ```bash
   kubectl get pods -l env!=prod
   ```

**Preguntas de comprensión**
- ¿Cuál es la diferencia conceptual entre una label y una annotation en Kubernetes?
- ¿Por qué los Services y los Deployments dependen de label selectors en lugar de referenciar Pods por su nombre?

---

## Ejercicio 4 — Deployments y ReplicaSets

1. Creá un Deployment:
   ```bash
   kubectl create deployment webapp --image=nginx:1.25 --replicas=3
   ```
2. Observá los objetos que el Deployment creó automáticamente:
   ```bash
   kubectl get deployments,replicasets,pods -l app=webapp
   ```
3. Escalá el Deployment a 5 réplicas:
   ```bash
   kubectl scale deployment webapp --replicas=5
   ```
   Volvé a listar los Pods y confirmá que ahora hay 5.
4. Simulá un rolling update cambiando la imagen:
   ```bash
   kubectl set image deployment/webapp nginx=nginx:1.27
   ```
5. Observá el progreso del rollout:
   ```bash
   kubectl rollout status deployment/webapp
   ```
6. Revisá el historial de revisiones:
   ```bash
   kubectl rollout history deployment/webapp
   ```
7. Volvé a la revisión anterior:
   ```bash
   kubectl rollout undo deployment/webapp
   ```

**Preguntas de comprensión**
- ¿Qué objeto crea y gestiona directamente los Pods cuando usás un Deployment: el Deployment o el ReplicaSet?
- Durante un rolling update, ¿por qué se crea un nuevo ReplicaSet en lugar de modificar los Pods del ReplicaSet existente?
- Si borrás manualmente uno de los Pods creados por el Deployment, ¿qué pasa y por qué?

---

## Ejercicio 5 — Services: exponiendo Pods dentro y fuera del cluster

1. Exponé el Deployment `webapp` con un Service de tipo `ClusterIP`:
   ```bash
   kubectl expose deployment webapp --port=80 --target-port=80 --name=webapp-svc
   ```
2. Inspeccioná el Service creado:
   ```bash
   kubectl describe service webapp-svc
   ```
   Anotá el `Endpoints` que muestra: deberían coincidir con las IPs de los Pods con label `app=webapp`.
3. Desde un Pod temporal dentro del cluster, probá resolver el Service por su nombre DNS:
   ```bash
   kubectl run curl-test --image=curlimages/curl --restart=Never -it --rm -- curl http://webapp-svc
   ```
4. Cambiá el tipo del Service a `NodePort` para exponerlo fuera del cluster:
   ```bash
   kubectl patch service webapp-svc -p '{"spec": {"type": "NodePort"}}'
   ```
5. Obtené el puerto asignado:
   ```bash
   kubectl get service webapp-svc
   ```

**Preguntas de comprensión**
- ¿Cómo sabe un Service de tipo `ClusterIP` a qué Pods enviar el tráfico?
- ¿Qué diferencia hay entre los tipos `ClusterIP`, `NodePort` y `LoadBalancer` en cuanto a desde dónde se puede acceder al Service?
- Si escalás el Deployment a más réplicas, ¿hace falta reconfigurar el Service para que incluya los Pods nuevos? ¿Por qué?

---

## Ejercicio 6 — Namespaces: aislamiento lógico de recursos

1. Listá los namespaces existentes:
   ```bash
   kubectl get namespaces
   ```
2. Creá un namespace nuevo:
   ```bash
   kubectl create namespace training
   ```
3. Creá un Deployment dentro de ese namespace:
   ```bash
   kubectl create deployment webapp --image=nginx:1.25 --namespace=training
   ```
4. Confirmá que el recurso no aparece en el namespace `default`:
   ```bash
   kubectl get deployments
   kubectl get deployments -n training
   ```
5. Cambiá el namespace por defecto de tu contexto actual para no tener que escribir `-n training` cada vez:
   ```bash
   kubectl config set-context --current --namespace=training
   ```
6. Verificá el cambio:
   ```bash
   kubectl get deployments
   ```

**Preguntas de comprensión**
- ¿Qué tipo de recursos de Kubernetes son "namespaced" (viven dentro de un namespace) y cuáles son "cluster-scoped" (globales al cluster)? Dá un ejemplo de cada uno.
- ¿Un Pod en el namespace `training` puede comunicarse por DNS corto (solo el nombre del Service) con un Service en el namespace `default`? ¿Qué tendría que usar en su lugar?

---

<details>
<summary><strong>Respuestas</strong></summary>

**Ejercicio 1**
- El `kube-apiserver` es el único punto de entrada: expone la API REST de Kubernetes y es el único componente que lee y escribe directamente en `etcd`. Todos los demás componentes (scheduler, controller-manager, kubelet, kubectl) interactúan con el cluster a través de él.
- Por defecto, los nodos del control plane tienen un `taint` que impide que se les asignen Pods de carga de trabajo del usuario, para reservar sus recursos a los componentes del propio control plane. Los worker nodes sí están disponibles para correr esas cargas de trabajo.
- El `kube-scheduler` es el componente responsable de asignar cada Pod recién creado (que aún no tiene nodo asignado) a un nodo específico, en base a los recursos disponibles, restricciones y políticas de scheduling.

**Ejercicio 2**
- Porque todos los containers dentro de un mismo Pod comparten el mismo Network Namespace (misma IP) y pueden compartir volúmenes; Kubernetes programa y escala en base a Pods completos, no containers individuales.
- Comparten la misma dirección IP y el mismo espacio de puertos (pueden comunicarse entre sí por `localhost`), y pueden compartir los mismos Volumes definidos a nivel Pod.
- Si el nodo falla, un Pod creado directamente (sin un controller como Deployment) no se vuelve a crear en otro nodo: se pierde. Un Pod gestionado por un Deployment sí es recreado, porque el ReplicaSet subyacente detecta que faltan réplicas respecto al estado deseado y crea un Pod nuevo.

**Ejercicio 3**
- Las labels son pares clave-valor pensados para identificar y seleccionar objetos (se usan en selectors); las annotations son metadata arbitraria (no usada para selección) para almacenar información adicional como descripciones, IDs externos o configuración de herramientas.
- Porque los Pods son efímeros: se destruyen y recrean constantemente (por ejemplo, en cada rolling update o reinicio). Un selector basado en labels sigue encontrando automáticamente a los Pods correctos sin importar sus nombres específicos, mientras que una referencia por nombre se rompería en cuanto el Pod fuera reemplazado.

**Ejercicio 4**
- El ReplicaSet gestiona directamente los Pods (los crea, los cuenta y los reemplaza si faltan). El Deployment gestiona ReplicaSets, agregando funcionalidad de versionado y rolling updates por encima.
- Porque así Kubernetes puede hacer un rollout gradual: mantiene el ReplicaSet viejo con Pods de la versión anterior mientras escala hacia arriba el ReplicaSet nuevo con la versión nueva, permitiendo actualizaciones sin downtime y rollback instantáneo simplemente volviendo a escalar el ReplicaSet anterior.
- El ReplicaSet detecta que el número de réplicas actuales (ahora una menos) no coincide con el número deseado especificado en su `spec.replicas`, y crea automáticamente un Pod nuevo para restaurar el estado deseado.

**Ejercicio 5**
- A través de un label selector definido en `spec.selector` del Service: cualquier Pod cuyas labels coincidan con ese selector es agregado automáticamente a los `Endpoints` del Service.
- `ClusterIP` solo es accesible dentro del cluster (IP virtual interna); `NodePort` además expone un puerto fijo en la IP de cada nodo, accesible desde fuera del cluster; `LoadBalancer` provisiona un balanceador externo (típicamente del cloud provider) que enruta tráfico externo hacia el Service, generalmente montado sobre un `NodePort`.
- No hace falta reconfigurar nada: el Service usa el label selector para descubrir Pods dinámicamente, así que cualquier Pod nuevo que coincida con las labels del selector se agrega automáticamente a los Endpoints.

**Ejercicio 6**
- Namespaced: por ejemplo Pods, Deployments, Services, ConfigMaps, Secrets. Cluster-scoped: por ejemplo Nodes, PersistentVolumes, Namespaces mismos, ClusterRoles.
- No directamente por el nombre corto del Service (por ejemplo `webapp-svc` solo resuelve dentro del mismo namespace). Para comunicarse entre namespaces hay que usar el nombre DNS completo, que incluye el namespace: `webapp-svc.default.svc.cluster.local` (o la forma corta `webapp-svc.default`).

</details>