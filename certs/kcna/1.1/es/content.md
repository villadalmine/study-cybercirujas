# Kubernetes Core Concepts

## 1. ¿Qué es Kubernetes?

Kubernetes (K8s) es una plataforma de **container orchestration** open source que automatiza el deployment, scaling y management de aplicaciones containerizadas. Nace en Google (basado en el sistema interno Borg) y hoy es un proyecto graduado de la **CNCF** (Cloud Native Computing Foundation).

El problema que resuelve: cuando una aplicación se compone de decenas o cientos de containers corriendo en múltiples hosts, necesitás algo que decida *dónde* corre cada container, *qué hacer* si un container o un nodo entero falla, *cómo* exponer esos containers a la red, y *cómo* actualizar la aplicación sin downtime. Hacer esto manualmente no escala.

Kubernetes trabaja con un modelo **declarativo**: vos describís el **desired state** (cuántas réplicas de una app querés, qué imagen usar, qué recursos asignar) en manifiestos YAML, y Kubernetes corre continuamente un **reconciliation loop** (control loop) que compara el estado actual del cluster contra el estado deseado y toma acciones para converger hacia él. Esto es lo que le da **self-healing**: si un Pod muere, el control loop crea uno nuevo automáticamente.

## 2. Arquitectura de un cluster

Un cluster de Kubernetes tiene dos tipos de nodos: el **Control Plane** (antes llamado "master") y los **Worker Nodes**.

```
┌─────────────────────────────────────────┐
│              CONTROL PLANE                │
│  kube-apiserver   etcd                     │
│  kube-scheduler   kube-controller-manager  │
│  cloud-controller-manager (opcional)       │
└─────────────────────────────────────────┘
              │
   ┌──────────┼──────────┐
   ▼          ▼          ▼
┌───────┐ ┌───────┐ ┌───────┐
│ Node 1 │ │ Node 2 │ │ Node 3 │
│kubelet │ │kubelet │ │kubelet │
│kube-   │ │kube-   │ │kube-   │
│proxy   │ │proxy   │ │proxy   │
│runtime │ │runtime │ │runtime │
└───────┘ └───────┘ └───────┘
```

### 2.1 Componentes del Control Plane

- **kube-apiserver**: el front-end del control plane. Expone la API REST de Kubernetes; todo (kubectl, controllers, kubelet) interactúa con el cluster a través de él. Valida y persiste los objetos en etcd.
- **etcd**: base de datos key-value distribuida y consistente que almacena todo el estado del cluster (el "source of truth"). Es crítico hacer backup de etcd.
- **kube-scheduler**: decide en qué nodo corre cada Pod recién creado, evaluando requerimientos de recursos, afinidad/anti-afinidad, taints/tolerations, etc.
- **kube-controller-manager**: corre los **controllers** que implementan los reconciliation loops (Node controller, ReplicaSet controller, Deployment controller, etc.). Cada controller observa el estado vía el API server y actúa para acercarlo al desired state.
- **cloud-controller-manager**: integra Kubernetes con la API de un cloud provider específico (AWS, GCP, Azure) para cosas como LoadBalancers o nodos.

### 2.2 Componentes de los Worker Nodes

- **kubelet**: el agente que corre en cada nodo. Recibe **PodSpecs** del API server y se asegura de que los containers descritos ahí estén corriendo y saludables. Reporta el estado del nodo y los Pods de vuelta al control plane.
- **kube-proxy**: mantiene las reglas de red en cada nodo (vía iptables o IPVS) que permiten la comunicación hacia los Services.
- **Container runtime**: el software que efectivamente ejecuta los containers (containerd, CRI-O). Kubernetes se comunica con el runtime a través del **CRI** (Container Runtime Interface), lo que permite intercambiar runtimes sin cambiar el código de Kubernetes.

Ejemplo, ver los nodos de un cluster:

```bash
$ kubectl get nodes -o wide
NAME           STATUS   ROLES           AGE   VERSION   INTERNAL-IP   CONTAINER-RUNTIME
node-control   Ready    control-plane   30d   v1.29.2   10.0.0.10     containerd://1.7.11
node-worker-1  Ready    <none>          30d   v1.29.2   10.0.0.11     containerd://1.7.11
node-worker-2  Ready    <none>          30d   v1.29.2   10.0.0.12     containerd://1.7.11
```

## 3. El Pod: la unidad mínima de deployment

Un **Pod** es la unidad más pequeña que Kubernetes puede crear y gestionar. Representa uno o más containers que comparten **network namespace** (misma IP, mismo espacio de puertos, se comunican por `localhost`) y opcionalmente **storage** (volumes). Casi nunca se usan Pods "desnudos" en producción — se gestionan a través de controllers de nivel superior (Deployment, StatefulSet, etc.) que garantizan que el número deseado de réplicas exista.

Manifiesto mínimo de un Pod:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx-pod
  labels:
    app: nginx
spec:
  containers:
    - name: nginx
      image: nginx:1.25
      ports:
        - containerPort: 80
```

```bash
$ kubectl apply -f nginx-pod.yaml
pod/nginx-pod created

$ kubectl get pods
NAME        READY   STATUS    RESTARTS   AGE
nginx-pod   1/1     Running   0          5s

$ kubectl describe pod nginx-pod
Name:         nginx-pod
Status:       Running
IP:           10.244.1.5
Containers:
  nginx:
    Image:          nginx:1.25
    State:          Running
    Ready:          True
```

**Multi-container Pods** son comunes con el patrón **sidecar** (un container auxiliar que complementa al principal, ej. un proxy de logging o un service mesh sidecar como Envoy).

## 4. Controllers para el manejo de Pods

### 4.1 ReplicaSet

Garantiza que un número específico de réplicas idénticas de un Pod estén corriendo en todo momento. Usa **labels y selectors** para saber qué Pods gestiona. Rara vez se crea directamente: normalmente lo maneja un Deployment.

### 4.2 Deployment

El objeto más usado para aplicaciones **stateless**. Gestiona ReplicaSets y provee:
- **Rolling updates**: actualiza los Pods gradualmente sin downtime.
- **Rollback**: volver a una revisión anterior si algo falla.
- **Scaling** declarativo.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
spec:
  replicas: 3
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
        - name: nginx
          image: nginx:1.25
          ports:
            - containerPort: 80
```

```bash
$ kubectl apply -f nginx-deployment.yaml
deployment.apps/nginx-deployment created

$ kubectl get deployments
NAME               READY   UP-TO-DATE   AVAILABLE   AGE
nginx-deployment   3/3     3            3           10s

$ kubectl get replicasets
NAME                          DESIRED   CURRENT   READY   AGE
nginx-deployment-6d4b7d9f9c   3         3         3       10s

$ kubectl scale deployment nginx-deployment --replicas=5
deployment.apps/nginx-deployment scaled

$ kubectl set image deployment/nginx-deployment nginx=nginx:1.26
deployment.apps/nginx-deployment image updated

$ kubectl rollout status deployment/nginx-deployment
deployment "nginx-deployment" successfully rolled out

$ kubectl rollout undo deployment/nginx-deployment
deployment.apps/nginx-deployment rolled back
```

### 4.3 StatefulSet

Para aplicaciones **stateful** (bases de datos, ej. etcd, Kafka, Cassandra) que necesitan:
- Identidad de red **estable y única** por réplica (`pod-0`, `pod-1`, `pod-2`, ...).
- Orden garantizado de creación y eliminación.
- Storage persistente asociado a cada réplica que sobrevive a reprogramaciones (vía `volumeClaimTemplates`).

### 4.4 DaemonSet

Garantiza que **una copia de un Pod corra en cada nodo** del cluster (o en un subconjunto). Usado típicamente para agentes de nivel de nodo: log collectors (Fluentd), monitoring agents (node-exporter) o componentes de red (CNI plugins).

### 4.5 Job y CronJob

- **Job**: crea uno o más Pods y garantiza que terminen exitosamente (se usa para tareas batch, no procesos de larga duración).
- **CronJob**: crea Jobs en un schedule recurrente, con sintaxis cron estándar.

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: backup-job
spec:
  schedule: "0 2 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - name: backup
              image: my-backup-tool:1.0
          restartPolicy: OnFailure
```

## 5. Service: exponiendo Pods en la red

Los Pods son efímeros y su IP cambia cada vez que se recrean. Un **Service** provee un endpoint estable (IP virtual + DNS name) que balancea tráfico hacia el conjunto de Pods que matchean un **selector**, sin importar que los Pods individuales cambien.

Tipos principales:
- **ClusterIP** (default): expone el Service en una IP interna, solo accesible dentro del cluster.
- **NodePort**: expone el Service en un puerto estático en cada nodo (`<NodeIP>:<NodePort>`).
- **LoadBalancer**: provisiona un load balancer externo (requiere soporte del cloud provider).
- **ExternalName**: mapea el Service a un nombre DNS externo, sin proxy.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-service
spec:
  type: ClusterIP
  selector:
    app: nginx
  ports:
    - port: 80
      targetPort: 80
```

```bash
$ kubectl apply -f nginx-service.yaml
service/nginx-service created

$ kubectl get svc nginx-service
NAME            TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE
nginx-service   ClusterIP   10.96.45.12    <none>        80/TCP    8s

$ kubectl get endpoints nginx-service
NAME            ENDPOINTS                                AGE
nginx-service   10.244.1.5:80,10.244.2.3:80,10.244.3.9:80   8s
```

Cada Service recibe también un DNS name interno (vía CoreDNS) con el formato `<service-name>.<namespace>.svc.cluster.local`.

## 6. Namespaces

Un **Namespace** es una forma de dividir un cluster físico en múltiples clusters virtuales, útil para separar entornos o equipos (ej. `dev`, `staging`, `prod`) dentro del mismo cluster. La mayoría de los objetos (Pods, Services, Deployments) son namespaced; algunos son cluster-wide (Nodes, PersistentVolumes, Namespaces mismos).

```bash
$ kubectl create namespace staging
namespace/staging created

$ kubectl get namespaces
NAME              STATUS   AGE
default           Active   30d
kube-system       Active   30d
kube-public       Active   30d
staging           Active   5s

$ kubectl get pods -n staging
$ kubectl get pods --all-namespaces
```

## 7. ConfigMap y Secret

Permiten desacoplar la configuración del código de la imagen del container.

- **ConfigMap**: pares clave-valor con datos no sensibles (URLs, feature flags, archivos de configuración).
- **Secret**: similar, pero para datos sensibles (passwords, tokens, certificados). Se almacenan **base64-encoded** (no encriptados por default — requiere encryption at rest configurado en etcd para seguridad real).

```bash
$ kubectl create configmap app-config --from-literal=LOG_LEVEL=debug
configmap/app-config created

$ kubectl create secret generic db-secret --from-literal=password=s3cr3t
secret/db-secret created
```

Se consumen como variables de entorno o montados como volumes dentro de un Pod:

```yaml
spec:
  containers:
    - name: app
      image: my-app:1.0
      envFrom:
        - configMapRef:
            name: app-config
      env:
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: db-secret
              key: password
```

## 8. Labels, Selectors y Annotations

- **Labels**: pares clave-valor adjuntos a objetos (`app: nginx`, `env: prod`, `tier: frontend`) usados para identificar y agrupar recursos. Los Services y controllers (Deployment, ReplicaSet) usan **selectors** sobre labels para saber qué Pods les corresponden.
- **Annotations**: también pares clave-valor, pero para metadata no identificativa (usada por herramientas, no para selección) — ej. anotaciones de un ingress controller o metadata de build.

```bash
$ kubectl label pod nginx-pod tier=frontend
pod/nginx-pod labeled

$ kubectl get pods --selector=app=nginx
NAME        READY   STATUS    RESTARTS   AGE
nginx-pod   1/1     Running   0          2m
```

## 9. kubectl: interactuando con el cluster

`kubectl` es el CLI oficial para interactuar con el API server. Soporta comandos **imperativos** (`kubectl run`, `kubectl create`, `kubectl expose`) y el flujo **declarativo** recomendado (`kubectl apply -f manifest.yaml`), que es idempotente y versionable (GitOps).

```bash
$ kubectl get pods -o yaml          # ver el manifiesto completo devuelto por el API server
$ kubectl explain pod.spec.containers  # documentación inline del schema
$ kubectl logs nginx-pod             # logs del container
$ kubectl exec -it nginx-pod -- sh   # shell interactiva dentro del Pod
$ kubectl delete -f nginx-pod.yaml
```

## Referencias

- CNCF, *KCNA Curriculum*: https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf
- Kubernetes Documentation — Concepts: https://kubernetes.io/docs/concepts/
- Kubernetes Documentation — Pods: https://kubernetes.io/docs/concepts/workloads/pods/
- Kubernetes Documentation — Deployments: https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- Kubernetes Documentation — StatefulSets: https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/
- Kubernetes Documentation — DaemonSet: https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/
- Kubernetes Documentation — Jobs: https://kubernetes.io/docs/concepts/workloads/controllers/job/
- Kubernetes Documentation — Services: https://kubernetes.io/docs/concepts/services-networking/service/
- Kubernetes Documentation — Namespaces: https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/
- Kubernetes Documentation — ConfigMaps: https://kubernetes.io/docs/concepts/configuration/configmap/
- Kubernetes Documentation — Secrets: https://kubernetes.io/docs/concepts/configuration/secret/
- Kubernetes Documentation — Kubernetes Components: https://kubernetes.io/docs/concepts/overview/components/
- Kubernetes Documentation — kubectl Reference: https://kubernetes.io/docs/reference/kubectl/