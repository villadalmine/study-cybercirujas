# 703.1 Kubernetes Architecture and Usage — Ejercicios guiados

**Certificación:** LPI DevOps Tools Engineer — Examen 701-100, objetivos v2.0.0
**Tema 703.1:** Kubernetes Architecture and Usage — peso en el examen **6.67**

Estos ejercicios son prácticos. Construís un clúster real multi-nodo y después lo desarmás desde adentro: los static Pods, la superficie HTTP del API server, el espacio de claves de etcd, los bucles de reconciliación, el registro de decisiones del scheduler, el contrato del kubelet con el nodo, y el dataplane que convierte una IP de `Service` en un paquete en el cable. Cada bloque termina con preguntas de verificación; todas las respuestas están plegadas al final del documento.

> **Seguridad.** Varios pasos rompen el control plane a propósito (mover un manifiesto de static Pod, aplicar taints a los nodos, leer etcd directamente). Ejecutalos **únicamente** contra el clúster `kind` descartable que se construye en el Ejercicio 0. Nunca contra un clúster compartido o de producción.

**Convenciones usadas más abajo**

* Las salidas fueron capturadas en un clúster `kind` corriendo Kubernetes **v1.33**. Tu versión de parche, los UIDs, las IPs, los hashes y las edades **van a diferir** — compará la *forma* de la salida, no los caracteres literales.
* `$` = tu estación de trabajo. `#` dentro de un `docker exec` = una shell dentro de un contenedor-nodo.
* Todo lo que esté entre `<angle brackets>` es un valor que tenés que sustituir con tu propia salida.

---

## Ejercicio 0 — Construir el laboratorio y establecer una línea base

**Prerrequisitos:** Docker (o Podman con `KIND_EXPERIMENTAL_PROVIDER=podman`), `kind` ≥ 0.29, `kubectl` que coincida con el clúster dentro de una versión menor, `jq`.

### Pasos

1. Escribí la definición del clúster. Un nodo de control plane más dos workers es la topología más chica que hace observables la planificación, los taints y el dataplane.

```bash
cat > kind-lpi703.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: lpi703
nodes:
  - role: control-plane
  - role: worker
  - role: worker
EOF
```

2. Creá el clúster, fijando la imagen de nodo para que el laboratorio sea reproducible.

```bash
kind create cluster --config kind-lpi703.yaml --image kindest/node:v1.33.1
```

3. Confirmá qué clúster e identidad está usando `kubectl` realmente. Esta es la causa más común de los incidentes tipo "en mi máquina funcionaba".

```bash
kubectl config current-context
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}{"\n"}'
kubectl cluster-info
```

Salida esperada:

```
kind-lpi703
https://127.0.0.1:39217
Kubernetes control plane is running at https://127.0.0.1:39217
CoreDNS is running at https://127.0.0.1:39217/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy
```

4. Inventariá los nodos y el runtime que corre debajo de ellos.

```bash
kubectl get nodes -o wide
```

```
NAME                    STATUS   ROLES           AGE   VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE                         KERNEL-VERSION        CONTAINER-RUNTIME
lpi703-control-plane    Ready    control-plane   96s   v1.33.1   172.18.0.4    <none>        Debian GNU/Linux 12 (bookworm)   6.16.3-200.fc42.x86_64   containerd://2.1.1
lpi703-worker           Ready    <none>          84s   v1.33.1   172.18.0.2    <none>        Debian GNU/Linux 12 (bookworm)   6.16.3-200.fc42.x86_64   containerd://2.1.1
lpi703-worker2          Ready    <none>          84s   v1.33.1   172.18.0.3    <none>        Debian GNU/Linux 12 (bookworm)   6.16.3-200.fc42.x86_64   containerd://2.1.1
```

5. Descubrí qué es lo que el API server realmente sirve. `api-resources` es la lista autoritativa para *este* clúster — incluye CRDs y APIs agregadas, así que nunca es la misma dos veces.

```bash
kubectl api-resources --sort-by=name | head -20
kubectl api-resources | wc -l
kubectl api-versions | wc -l
```

6. Leé el esquema del objeto desde el servidor, no desde un blog. `kubectl explain` se sirve desde el propio documento OpenAPI del clúster.

```bash
kubectl explain pod.spec.containers.resources
kubectl explain deployment.spec.strategy.rollingUpdate --recursive
```

### Comprobá tu comprensión

* **Q0.1** — La versión del kernel reportada para cada nodo es idéntica y coincide con la del kernel de tu estación de trabajo. ¿Qué te dice eso sobre lo que un nodo de `kind` realmente es, y qué parte del "aislamiento entre nodos" no puede demostrar fielmente este laboratorio?
* **Q0.2** — `kubectl api-resources` muestra columnas `SHORTNAMES`, `APIVERSION`, `NAMESPACED` y `KIND`. ¿Por qué dos clústeres distintos corriendo la misma versión de Kubernetes pueden devolver filas diferentes acá?
* **Q0.3** — `CONTAINER-RUNTIME` dice `containerd://2.1.1`, nunca `docker://`. ¿Qué componente arquitectónico se eliminó en Kubernetes v1.24 para que sea así, y qué interfaz habla hoy el kubelet con containerd?
* **Q0.4** — ¿De dónde saca `kubectl explain` la documentación de los campos, y por qué eso importa cuando trabajás con CustomResourceDefinitions?

---

## Ejercicio 1 — El control plane son solo Pods (que nadie planifica)

El control plane estilo kubeadm que usa `kind` corre `etcd`, `kube-apiserver`, `kube-controller-manager` y `kube-scheduler` como **static Pods**: el kubelet lee los manifiestos del disco local y los arranca él mismo, sin API server y sin scheduler en el circuito. Este es el truco de bootstrap que resuelve el problema del huevo y la gallina de un control plane que, de otro modo, se necesitaría a sí mismo para arrancar.

### Pasos

1. Listá las cargas de trabajo del control plane y fijate en el patrón de nombres.

```bash
kubectl -n kube-system get pods -o wide --sort-by=.spec.nodeName
```

```
NAME                                           READY   STATUS    RESTARTS   AGE     IP           NODE
coredns-668d6bf9bc-4kt2m                       1/1     Running   0          4m12s   10.244.0.3   lpi703-control-plane
coredns-668d6bf9bc-x9lq7                       1/1     Running   0          4m12s   10.244.0.2   lpi703-control-plane
etcd-lpi703-control-plane                      1/1     Running   0          4m18s   172.18.0.4   lpi703-control-plane
kindnet-2xq7v                                  1/1     Running   0          4m12s   172.18.0.4   lpi703-control-plane
kube-apiserver-lpi703-control-plane            1/1     Running   0          4m18s   172.18.0.4   lpi703-control-plane
kube-controller-manager-lpi703-control-plane   1/1     Running   0          4m18s   172.18.0.4   lpi703-control-plane
kube-proxy-9cqd2                               1/1     Running   0          4m12s   172.18.0.4   lpi703-control-plane
kube-scheduler-lpi703-control-plane            1/1     Running   0          4m18s   172.18.0.4   lpi703-control-plane
kube-proxy-hs4bk                               1/1     Running   0          4m05s   172.18.0.2   lpi703-worker
kindnet-8vlgc                                  1/1     Running   0          4m05s   172.18.0.2   lpi703-worker
...
```

2. Probá que son static, buscando la anotación de mirror-Pod y la ausencia de un controller como owner.

```bash
kubectl -n kube-system get pod kube-scheduler-lpi703-control-plane \
  -o jsonpath='{.metadata.annotations.kubernetes\.io/config\.source}{"\n"}{.metadata.ownerReferences}{"\n"}'
```

```
file
[{"apiVersion":"v1","controller":true,"kind":"Node","name":"lpi703-control-plane","uid":"6c0a..."}]
```

3. Leé los manifiestos en disco y el parámetro del kubelet que apunta a ellos.

```bash
docker exec lpi703-control-plane ls -l /etc/kubernetes/manifests/
docker exec lpi703-control-plane grep -i staticPodPath /var/lib/kubelet/config.yaml
```

```
-rw------- 1 root root 2405 Sep  3 09:12 etcd.yaml
-rw------- 1 root root 3896 Sep  3 09:12 kube-apiserver.yaml
-rw------- 1 root root 3428 Sep  3 09:12 kube-controller-manager.yaml
-rw------- 1 root root 1656 Sep  3 09:12 kube-scheduler.yaml
staticPodPath: /etc/kubernetes/manifests
```

4. Inspeccioná cómo fue configurado el API server. Cada decisión arquitectónica de este clúster es un argumento en esta línea de comandos.

```bash
docker exec lpi703-control-plane \
  grep -E 'etcd-servers|service-cluster-ip-range|admission|authorization-mode|client-ca|advertise-address' \
  /etc/kubernetes/manifests/kube-apiserver.yaml
```

```
    - --advertise-address=172.18.0.4
    - --authorization-mode=Node,RBAC
    - --client-ca-file=/etc/kubernetes/pki/ca.crt
    - --enable-admission-plugins=NodeRestriction
    - --etcd-servers=https://127.0.0.1:2379
    - --service-cluster-ip-range=10.96.0.0/16
```

5. Ahora rompelo a propósito. Movés el manifiesto del scheduler y mirás cómo el kubelet actúa de reconciliador.

```bash
docker exec lpi703-control-plane mv /etc/kubernetes/manifests/kube-scheduler.yaml /tmp/
sleep 20
kubectl -n kube-system get pod -l component=kube-scheduler
```

```
No resources found in kube-system namespace.
```

6. Sin scheduler corriendo, creá un Deployment y observá exactamente qué deja de funcionar — y qué no.

```bash
kubectl create deployment probe --image=registry.k8s.io/pause:3.10 --replicas=2
kubectl get pods -l app=probe -o wide
```

```
NAME                     READY   STATUS    RESTARTS   AGE   IP       NODE     NOMINATED NODE
probe-7d4f8b9c65-fs2vp   0/1     Pending   0          12s   <none>   <none>   <none>
probe-7d4f8b9c65-nk8zq   0/1     Pending   0          12s   <none>   <none>   <none>
```

7. Restaurá el scheduler y confirmá la autorreparación.

```bash
docker exec lpi703-control-plane mv /tmp/kube-scheduler.yaml /etc/kubernetes/manifests/
sleep 20
kubectl get pods -l app=probe -o wide
kubectl -n kube-system get lease | grep -E 'scheduler|controller'
```

```
NAME                                   HOLDER                                        AGE
kube-controller-manager                lpi703-control-plane_4e1b...                  9m
kube-scheduler                          lpi703-control-plane_a77c...                 22s
```

8. Limpiá.

```bash
kubectl delete deployment probe
```

### Comprobá tu comprensión

* **Q1.1** — Los static Pods tienen un `ownerReference` que apunta a un **Node**, no a un ReplicaSet ni a un DaemonSet. ¿Cómo se llama ese objeto en la API, quién lo crea, y qué pasa si ejecutás `kubectl delete pod kube-scheduler-lpi703-control-plane`?
* **Q1.2** — Con el scheduler caído, el ReplicaSet igual creó dos objetos Pod. ¿Qué componente los creó, y qué campo preciso distingue a un Pod que el scheduler todavía no procesó?
* **Q1.3** — `--etcd-servers=https://127.0.0.1:2379` en el API server. ¿Por qué esa dirección de loopback es arquitectónicamente significativa, y qué te dice sobre quién tiene permitido hablar con etcd?
* **Q1.4** — `kube-scheduler` y `kube-controller-manager` sostienen un objeto **Lease**; `kube-apiserver` no. Explicá la diferencia en el modelo de concurrencia entre estos componentes y por qué solo algunos necesitan elección de líder.
* **Q1.5** — El flag `--enable-admission-plugins=NodeRestriction` agrega un plugin a una lista por defecto. En el pipeline de la petición, ¿en qué etapa corre admission respecto de la autenticación, la autorización y la persistencia en etcd?

---

## Ejercicio 2 — kubectl es un cliente HTTP; el API server es la única puerta

Todo en Kubernetes es un recurso REST detrás de un único endpoint. Internalizar esto convierte la mayoría de los problemas del tipo "kubectl está haciendo algo raro" en "leé la petición".

### Pasos

1. Mirá el tráfico HTTP real de un comando trivial.

```bash
kubectl get pods -n kube-system -v=6 2>&1 | head -5
```

```
I0903 09:31:02.114  round_trippers.go:553] GET https://127.0.0.1:39217/api/v1/namespaces/kube-system/pods?limit=500 200 OK in 18 milliseconds
```

Subí la verbosidad para ver las cabeceras, el cuerpo y la negociación de contenido:

```bash
kubectl get pod -n kube-system etcd-lpi703-control-plane -v=8 2>&1 | grep -E 'Request Headers|Accept:|Response Status'
```

```
I0903 09:31:44.220  round_trippers.go:470] Request Headers:
I0903 09:31:44.220  round_trippers.go:474]     Accept: application/json;as=Table;v=v1;g=meta.k8s.io,application/json
I0903 09:31:44.240  round_trippers.go:577] Response Status: 200 OK in 19 milliseconds
```

2. Llamá a la API sin el formateo de `kubectl`, usando sus credenciales.

```bash
kubectl get --raw /api/v1/namespaces/kube-system/pods?limit=1 | jq '.items[0].metadata.name, .metadata.resourceVersion'
```

3. Consultá los endpoints de salud que deberían estar usando el balanceador de carga y tu monitoreo.

```bash
kubectl get --raw '/livez?verbose' | head -8
kubectl get --raw '/readyz?verbose' | tail -5
```

```
[+]ping ok
[+]log ok
[+]etcd ok
[+]poststarthook/start-apiserver-admission-initializer ok
[+]poststarthook/generic-apiserver-start-informers ok
...
readyz check passed
```

4. Compará con la forma obsoleta de hacer la misma pregunta.

```bash
kubectl get componentstatuses
```

```
Warning: v1 ComponentStatus is deprecated in v1.19+
NAME                 STATUS      MESSAGE                         ERROR
scheduler            Healthy     ok
controller-manager   Healthy     ok
etcd-0               Healthy     ok
```

5. Establecé qué tiene permitido hacer tu identidad. Así se verifica RBAC sin leer un solo Role.

```bash
kubectl auth whoami
kubectl auth can-i --list --namespace kube-system | head
kubectl auth can-i delete pods --all-namespaces
kubectl auth can-i create pods --as=system:serviceaccount:default:default
```

```
ATTRIBUTE   VALUE
Username    kubernetes-admin
Groups      [kubernetes-admin system:masters system:authenticated]
...
yes
no
```

6. Usá un `watch` para ver el flujo de eventos que consume cada controller. Dejalo corriendo en una terminal:

```bash
kubectl get pods -w --output-watch-events
```

En una segunda terminal:

```bash
kubectl run watched --image=registry.k8s.io/pause:3.10
```

La primera terminal muestra la secuencia ADDED/MODIFIED:

```
EVENT      NAME      READY   STATUS              RESTARTS   AGE
ADDED      watched   0/1     Pending             0          0s
MODIFIED   watched   0/1     Pending             0          0s
MODIFIED   watched   0/1     ContainerCreating   0          0s
MODIFIED   watched   1/1     Running             0          2s
```

7. Detené el watch y borrá el Pod.

```bash
kubectl delete pod watched
```

### Comprobá tu comprensión

* **Q2.1** — Con `-v=8`, la cabecera `Accept` pide `application/json;as=Table;v=v1;g=meta.k8s.io` antes que JSON plano. ¿Qué es el server-side printing, y qué se rompe en tu tooling si asumís que las columnas de `kubectl get` son estables?
* **Q2.2** — Distinguí `/healthz`, `/livez` y `/readyz`. ¿Cuál corresponde en el chequeo de backend de un balanceador de carga para un control plane multi-master, y qué saldría mal si usaras el equivocado durante una actualización progresiva?
* **Q2.3** — `kubectl auth can-i --list` devolvió respuestas al instante, sin que tu cliente parseara ningún Role ni RoleBinding. ¿Qué API se está llamando, y por qué preguntarle al servidor es estrictamente más correcto que leer los objetos RBAC vos mismo?
* **Q2.4** — Tus credenciales te ubican en el grupo `system:masters`. ¿Qué hace RBAC cuando ve ese grupo, y por qué es la línea más peligrosa de un archivo kubeconfig?
* **Q2.5** — En el flujo del watch viste `MODIFIED` dos veces antes de que se creara el contenedor. Explicá el rol de `resourceVersion` en un watch y qué debe hacer un cliente cuando el servidor devuelve `410 Gone`.

---

## Ejercicio 3 — etcd: lo único con estado en el clúster

Cada objeto que creaste vive como un valor serializado bajo una clave jerárquica en etcd. Leerlo directamente desmitifica el "¿dónde vive el estado?", y te muestra exactamente qué tiene que capturar un backup.

### Pasos

1. Abrí una shell contra etcd usando los certificados de cliente que generó kubeadm.

```bash
docker exec -it lpi703-control-plane sh -c '
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --write-out=table'
```

```
+------------------------+------------------+---------+---------+-----------+------------+
|        ENDPOINT        |        ID        | VERSION | DB SIZE | IS LEADER | RAFT TERM  |
+------------------------+------------------+---------+---------+-----------+------------+
| https://127.0.0.1:2379 | 9d1e5f2a3c4b6d78 |  3.5.21 |  3.1 MB | true      |          2 |
+------------------------+------------------+---------+---------+-----------+------------+
```

2. Definí un atajo y listá la parte superior del espacio de claves.

```bash
docker exec -it lpi703-control-plane sh -c '
alias e="ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
 --cacert=/etc/kubernetes/pki/etcd/ca.crt \
 --cert=/etc/kubernetes/pki/etcd/server.crt \
 --key=/etc/kubernetes/pki/etcd/server.key";
e get /registry --prefix --keys-only | sed "/^$/d" | cut -d/ -f1-3 | sort -u | head -25'
```

```
/registry/apiextensions.k8s.io
/registry/apiregistration.k8s.io
/registry/clusterrolebindings
/registry/clusterroles
/registry/configmaps
/registry/controllerrevisions
/registry/daemonsets
/registry/deployments
/registry/leases
/registry/masterleases
/registry/namespaces
/registry/pods
/registry/priorityclasses
/registry/replicasets
/registry/secrets
/registry/serviceaccounts
/registry/services
```

3. Creá un objeto y encontrá su clave exacta.

```bash
kubectl create configmap etcd-demo --from-literal=lesson=703.1
docker exec -it lpi703-control-plane sh -c '
ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
 --key=/etc/kubernetes/pki/etcd/server.key \
 get /registry/configmaps/default/etcd-demo'
```

```
/registry/configmaps/default/etcd-demo
k8s

v1 ConfigMap

etcd-demo default"*$3f9a1c02-7b41-4d1e-9c0b-1f2a6c8d40e12
lesson703.1
```

4. Compará con un Secret, y sacá la conclusión de seguridad.

```bash
kubectl create secret generic etcd-demo-secret --from-literal=token=s3cr3t-value
docker exec -it lpi703-control-plane sh -c '
ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
 --key=/etc/kubernetes/pki/etcd/server.key \
 get /registry/secrets/default/etcd-demo-secret' | strings | grep s3cr3t
```

```
s3cr3t-value
```

5. Tomá un snapshot — la operación que define el RPO de tu clúster.

```bash
docker exec lpi703-control-plane sh -c '
ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
 --key=/etc/kubernetes/pki/etcd/server.key \
 snapshot save /tmp/etcd-snapshot.db && ls -lh /tmp/etcd-snapshot.db'
```

```
{"level":"info","msg":"saved","path":"/tmp/etcd-snapshot.db"}
Snapshot saved at /tmp/etcd-snapshot.db
-rw------- 1 root root 3.2M Sep  3 09:44 /tmp/etcd-snapshot.db
```

6. Limpiá.

```bash
kubectl delete configmap etcd-demo
kubectl delete secret etcd-demo-secret
```

### Comprobá tu comprensión

* **Q3.1** — El valor del Secret volvió como texto plano legible. Dado que `kubectl get secret -o yaml` muestra base64, indicá con precisión qué aporta base64 acá y nombrá los dos mecanismos que realmente protegen los Secrets en reposo y en tránsito.
* **Q3.2** — Las claves siguen el patrón `/registry/<resource>/<namespace>/<name>`, pero `/registry/clusterroles/` tiene solo dos segmentos después de `registry`. ¿Qué codifica esa diferencia estructural, y cómo se relaciona con la columna `NAMESPACED` del Ejercicio 0?
* **Q3.3** — Un snapshot de etcd captura el estado del clúster, pero no los datos de los PersistentVolume ni las imágenes de contenedor. Después de restaurar sobre un clúster en marcha un snapshot tomado hace 30 minutos, nombrá tres categorías de divergencia que tenés que esperar reconciliar.
* **Q3.4** — En producción etcd corre con 3 o 5 miembros, nunca 4. Explicá la aritmética del quórum y por qué un número par de miembros no te compra nada.
* **Q3.5** — ¿Por qué `--etcd-servers` apunta a `https://` con certificados de cliente en lugar de HTTP plano sobre una red privada? Planteá la respuesta en términos de qué autoriza realmente una escritura en etcd.

---

## Ejercicio 4 — Controllers, propiedad y el bucle de reconciliación

Un Deployment no crea Pods. Crea un ReplicaSet, que crea Pods. Entender esa cadena — y los `ownerReferences` que la codifican — es lo que te permite predecir el efecto de un `kubectl delete`.

### Pasos

1. Aplicá un manifiesto de Deployment completo, con forma de producción.

```yaml
# web-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  labels:
    app: web
spec:
  replicas: 3
  revisionHistoryLimit: 3
  selector:
    matchLabels:
      app: web
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: web
        version: "1"
    spec:
      containers:
        - name: web
          image: registry.k8s.io/e2e-test-images/agnhost:2.53
          args: ["netexec", "--http-port=8080"]
          ports:
            - name: http
              containerPort: 8080
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 200m
              memory: 128Mi
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            initialDelaySeconds: 2
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
```

```bash
kubectl apply -f web-deployment.yaml
kubectl rollout status deployment/web --timeout=90s
```

```
deployment.apps/web created
Waiting for deployment "web" rollout to finish: 0 of 3 updated replicas are available...
deployment "web" successfully rolled out
```

2. Recorré la cadena de propiedad desde el Pod hasta el Deployment.

```bash
POD=$(kubectl get pod -l app=web -o jsonpath='{.items[0].metadata.name}')
kubectl get pod "$POD" -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}'
RS=$(kubectl get pod "$POD" -o jsonpath='{.metadata.ownerReferences[0].name}')
kubectl get rs "$RS" -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}'
```

```
ReplicaSet/web-6c9f47d5b8
Deployment/web
```

3. Mirá cómo se cierra el bucle de reconciliación. Borrá un Pod y cronometrá el reemplazo.

```bash
kubectl delete pod "$POD" --wait=false
kubectl get pods -l app=web --watch-only --output-watch-events &
sleep 8; kill %1
kubectl get pods -l app=web
```

4. Probá que el ReplicaSet es dueño por **selector**, no por nombre. Reetiquetá un Pod para sacarlo del conjunto.

```bash
VICTIM=$(kubectl get pod -l app=web -o jsonpath='{.items[0].metadata.name}')
kubectl label pod "$VICTIM" app=orphaned --overwrite
kubectl get pods -L app
```

```
NAME                   READY   STATUS    RESTARTS   AGE   APP
web-6c9f47d5b8-4nqz9   1/1     Running   0          19s   web
web-6c9f47d5b8-8dktp   1/1     Running   0          3m1s  web
web-6c9f47d5b8-p2rvc   1/1     Running   0          3s    web
web-6c9f47d5b8-x7mlk   1/1     Running   0          3m1s  orphaned
```

```bash
kubectl get pod "$VICTIM" -o jsonpath='{.metadata.ownerReferences}{"\n"}'
kubectl delete pod "$VICTIM"
```

5. Dispará un rollout y leé el historial de revisiones.

```bash
kubectl set image deployment/web web=registry.k8s.io/e2e-test-images/agnhost:2.52
kubectl rollout status deployment/web
kubectl get rs -l app=web
kubectl rollout history deployment/web
```

```
NAME              DESIRED   CURRENT   READY   AGE
web-6c9f47d5b8    0         0         0       5m
web-7f8b5c6d94    3         3         3       31s
```

6. Hacé rollback y confirmá que el ReplicaSet se reutiliza en lugar de recrearse.

```bash
kubectl rollout undo deployment/web
kubectl get rs -l app=web
```

7. Explorá el borrado en cascada. `orphan` desvincula a los hijos en vez de eliminarlos.

```bash
kubectl delete deployment web --cascade=orphan
kubectl get rs,pods -l app=web
```

```
NAME                             DESIRED   CURRENT   READY   AGE
replicaset.apps/web-6c9f47d5b8   3         3         3       7m

NAME                       READY   STATUS    RESTARTS   AGE
pod/web-6c9f47d5b8-4nqz9   1/1     Running   0          4m
...
```

```bash
kubectl delete rs -l app=web        # foreground/background cascade removes the Pods too
kubectl get pods -l app=web
```

### Comprobá tu comprensión

* **Q4.1** — Nombrá los tres objetos de la cadena de propiedad e indicá qué controller reconcilia cada arista. ¿Cuál de ellos es responsable de la aritmética de `maxSurge`/`maxUnavailable`?
* **Q4.2** — Reetiquetar el Pod como `app=orphaned` hizo que el ReplicaSet creara un cuarto Pod. ¿Qué pasó con los `ownerReferences` del Pod reetiquetado, y cuál es el uso operativo de este truco cuando depurás un Pod que falla en producción?
* **Q4.3** — Después de `kubectl rollout undo`, la cuenta de réplicas del ReplicaSet viejo volvió a subir en lugar de aparecer un ReplicaSet nuevo. Explicá cómo identifica el Deployment controller que se trata "del mismo" pod template entre revisiones, y qué acota realmente `revisionHistoryLimit: 3`.
* **Q4.4** — Contrastá `--cascade=background` (el valor por defecto), `--cascade=foreground` y `--cascade=orphan`. ¿Cuál bloquea el borrado del padre hasta que no queden hijos, y qué finalizer lo implementa?
* **Q4.5** — `spec.selector` en un Deployment es inmutable después de la creación. ¿Por qué los diseñadores de la API lo hicieron así, dado lo que acabás de observar sobre la propiedad basada en labels?

---

## Ejercicio 5 — El scheduler: filtrado, puntuación y la evidencia que deja

La única salida del scheduler es una sola escritura: fija `spec.nodeName` en un Pod creando un Binding. Todo lo demás es una decisión que podés reconstruir a partir de los Events.

### Pasos

1. Recreá la carga de trabajo, esta vez lo bastante grande como para exponer presión de recursos.

```bash
kubectl apply -f web-deployment.yaml
kubectl get pods -l app=web -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName
```

2. Leé el libro de capacidad de un nodo — los números sobre los que filtra el scheduler.

```bash
kubectl describe node lpi703-worker | sed -n '/Capacity:/,/Events:/p'
```

```
Capacity:
  cpu:                8
  ephemeral-storage:  1055762868Ki
  memory:             16117884Ki
  pods:               110
Allocatable:
  cpu:                8
  ephemeral-storage:  972991057649
  memory:             16015484Ki
  pods:               110
...
Allocated resources:
  (Total limits may be over 100 percent, i.e., overcommitted.)
  Resource           Requests     Limits
  --------           --------     ------
  cpu                250m (3%)    400m (5%)
  memory             182Mi (1%)   428Mi (2%)
```

3. Salteá el scheduler por completo para demostrar dónde vive la decisión.

```yaml
# pinned.yaml
apiVersion: v1
kind: Pod
metadata:
  name: pinned
spec:
  nodeName: lpi703-worker2
  containers:
    - name: pause
      image: registry.k8s.io/pause:3.10
```

```bash
kubectl apply -f pinned.yaml
kubectl get pod pinned -o wide
kubectl get events --field-selector involvedObject.name=pinned
```

```
LAST SEEN   TYPE     REASON      OBJECT        MESSAGE
9s          Normal   Pulled      pod/pinned    Container image "registry.k8s.io/pause:3.10" already present on machine
9s          Normal   Created     pod/pinned    Created container: pause
9s          Normal   Started     pod/pinned    Started container pause
```

Fijate qué está **ausente** en esa lista.

4. Hacé que la planificación falle, y leé el mensaje de error como un informe estructurado.

```bash
kubectl create deployment greedy --image=registry.k8s.io/pause:3.10 --replicas=1 -- \
  2>/dev/null || true
kubectl set resources deployment/greedy --requests=cpu=40 2>/dev/null || \
kubectl patch deployment greedy --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/resources","value":{"requests":{"cpu":"40"}}}]'
sleep 5
kubectl describe pod -l app=greedy | sed -n '/Events:/,$p'
```

```
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  14s   default-scheduler  0/3 nodes are available: 1 node(s) had untolerated taint
  {node-role.kubernetes.io/control-plane: }, 2 Insufficient cpu. preemption: 0/3 nodes are available:
  1 Preemption is not helpful for scheduling, 2 No preemption victims found for incoming pod.
```

5. Inspeccioná el taint que excluyó al nodo de control plane, después quitalo y volvé a leer el mensaje.

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
kubectl taint node lpi703-control-plane node-role.kubernetes.io/control-plane:NoSchedule-
sleep 10
kubectl describe pod -l app=greedy | grep -A3 'FailedScheduling' | tail -3
```

```
0/3 nodes are available: 3 Insufficient cpu.
```

6. Restaurá el taint y estudiá `NoExecute` frente a `NoSchedule`.

```bash
kubectl taint node lpi703-control-plane node-role.kubernetes.io/control-plane=:NoSchedule
kubectl taint node lpi703-worker2 maintenance=true:NoExecute
sleep 10
kubectl get pods -o wide
kubectl describe pod pinned 2>/dev/null | grep -i -A2 'Status\|Reason' | head
```

7. Deshacé el taint de mantenimiento y limpiá.

```bash
kubectl taint node lpi703-worker2 maintenance-
kubectl delete deployment greedy --ignore-not-found
kubectl delete pod pinned --ignore-not-found
```

8. Compará con la herramienta correcta en producción para la misma intención — el drenaje.

```bash
kubectl drain lpi703-worker2 --ignore-daemonsets --delete-emptydir-data --dry-run=server
kubectl uncordon lpi703-worker2
```

### Comprobá tu comprensión

* **Q5.1** — El Pod `pinned` produjo Events `Pulled`/`Created`/`Started` pero ningún Event `Scheduled`. ¿Qué componente emite `Scheduled`, y qué prueba su ausencia sobre cómo se honra `spec.nodeName`?
* **Q5.2** — Fijar `spec.nodeName` directamente igual resulta en un Pod corriendo, y sin embargo se considera un antipatrón. Nombrá tres garantías que perdés al saltear el scheduler.
* **Q5.3** — Descomponé `0/3 nodes are available: 1 node(s) had untolerated taint..., 2 Insufficient cpu`. ¿Qué fase del scheduler produjo cada cláusula, y qué te dice la frase final `preemption:` sobre las PriorityClasses de este clúster?
* **Q5.4** — Tu Pod pide `cpu: 40` en nodos con 8 CPUs asignables. Explicá qué significa un *request* de CPU para el scheduler frente a lo que significa un *limit* de CPU para el kubelet y el kernel — y cuál de los dos ignora el scheduler.
* **Q5.5** — `NoSchedule` frente a `NoExecute` frente a `PreferNoSchedule`: ¿cuál afecta a los Pods que ya están corriendo, y cómo logra `kubectl drain` el mismo resultado operativo con un mecanismo que respeta los PodDisruptionBudgets?

---

## Ejercicio 6 — El contrato del kubelet con el nodo

El kubelet es el único agente que toca el container runtime. Reporta el estado del nodo, hace cumplir el contrato de recursos, corre las probes y desaloja bajo presión.

### Pasos

1. Mirá el kubelet desde afuera — como una unidad de systemd dentro del contenedor-nodo.

```bash
docker exec lpi703-worker systemctl is-active kubelet
docker exec lpi703-worker journalctl -u kubelet --no-pager -n 8 -o cat
```

2. Leé la configuración propia del kubelet. Desde la v1.11 casi toda vive en un archivo de configuración, no en la línea de comandos.

```bash
docker exec lpi703-worker grep -E 'cgroupDriver|containerRuntimeEndpoint|evictionHard|imagefs|nodefs|maxPods|clusterDNS|clusterDomain' -A3 \
  /var/lib/kubelet/config.yaml
```

```
cgroupDriver: systemd
clusterDNS:
- 10.96.0.10
clusterDomain: cluster.local
containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
evictionHard:
  imagefs.available: 0%
  nodefs.available: 0%
  nodefs.inodesFree: 0%
```

3. Hablale al container runtime igual que lo hace el kubelet, vía CRI.

```bash
docker exec lpi703-worker crictl ps --output table | head -6
docker exec lpi703-worker crictl pods --output table | head -4
docker exec lpi703-worker crictl images | head -5
```

```
CONTAINER      IMAGE          CREATED         STATE     NAME         ATTEMPT   POD ID         POD
a4f2c1b8e0d13  9c1a8b7f...    3 minutes ago   Running   web          0         7e21d0f4a9c11  web-6c9f47d5b8-4nqz9
1b93de77c2a05  0f7e4a2c...    9 minutes ago   Running   kube-proxy   0         c8d5e1a3b7f92  kube-proxy-hs4bk
```

4. Observá el mecanismo de latido del nodo — Leases, no actualizaciones completas de status.

```bash
kubectl -n kube-node-lease get lease lpi703-worker -o yaml | grep -E 'holderIdentity|renewTime|leaseDurationSeconds'
kubectl get node lpi703-worker -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\n"}{end}'
```

```
DiskPressure     False   KubeletHasNoDiskPressure
MemoryPressure   False   KubeletHasSufficientMemory
PIDPressure      False   KubeletHasSufficientPID
Ready            True    KubeletReady
```

5. Mirá al kubelet hacer cumplir un límite de memoria. Este Pod pide más de lo que tiene permitido.

```yaml
# oom.yaml
apiVersion: v1
kind: Pod
metadata:
  name: oom
spec:
  restartPolicy: Never
  containers:
    - name: hog
      image: registry.k8s.io/e2e-test-images/agnhost:2.53
      command: ["sh","-c","dd if=/dev/zero of=/dev/shm/fill bs=1M count=200; sleep 300"]
      resources:
        requests:
          memory: 32Mi
        limits:
          memory: 64Mi
```

```bash
kubectl apply -f oom.yaml
sleep 15
kubectl get pod oom -o jsonpath='{.status.containerStatuses[0].state}{"\n"}{.status.containerStatuses[0].lastState}{"\n"}'
kubectl describe pod oom | grep -iE 'reason|exit code'
```

```
Last State:     Terminated
  Reason:       OOMKilled
  Exit Code:    137
```

6. Clasificá la Quality of Service — el ranking que usa el kubelet cuando tiene que desalojar.

```bash
kubectl get pod oom -o jsonpath='{.status.qosClass}{"\n"}'
kubectl get pods -l app=web -o custom-columns=NAME:.metadata.name,QOS:.status.qosClass
```

7. Limpiá.

```bash
kubectl delete pod oom
```

### Comprobá tu comprensión

* **Q6.1** — `cgroupDriver: systemd` tiene que coincidir con la configuración del container runtime. Describí el modo de falla cuando el kubelet y containerd no coinciden, y por qué es intermitente en lugar de un error inmediato de arranque.
* **Q6.2** — Los latidos del nodo escriben en un **Lease** en `kube-node-lease` cada pocos segundos, mientras que `node.status` se actualiza mucho menos seguido. ¿Qué problema de escalabilidad resuelve esa separación, y qué objeto observa el node-lifecycle controller para decidir que un nodo está `NotReady`?
* **Q6.3** — Código de salida 137 con razón `OOMKilled`. ¿Qué componente mató realmente al proceso — el kubelet, containerd o el kernel de Linux — y cómo se descompone el 137?
* **Q6.4** — Dá la regla exacta que asigna `Guaranteed`, `Burstable` y `BestEffort`, e indicá el orden de desalojo bajo presión de memoria en el nodo.
* **Q6.5** — `crictl ps` muestra contenedores que el API server nunca menciona individualmente (el sandbox `pause`). ¿Cuál es la función de ese contenedor, y qué se rompería en un Pod sin él?

---

## Ejercicio 7 — Services, EndpointSlices, kube-proxy y DNS

Un `Service` no es un proceso. Es un nombre estable y una IP virtual que tres mecanismos independientes cooperan para hacer funcionar: el endpoints controller puebla la membresía, kube-proxy programa el dataplane, y CoreDNS responde el nombre.

### Pasos

1. Exponé el Deployment e inspeccioná la ClusterIP asignada.

```bash
kubectl expose deployment web --name=web --port=80 --target-port=http
kubectl get svc web -o wide
```

```
NAME   TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE   SELECTOR
web    ClusterIP   10.96.115.24   <none>        80/TCP    5s    app=web
```

2. Mirá la membresía. `EndpointSlice` es el objeto moderno; la API `Endpoints` heredada está obsoleta desde la v1.33.

```bash
kubectl get endpointslices -l kubernetes.io/service-name=web
kubectl get endpointslices -l kubernetes.io/service-name=web \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"\t"}{.conditions.ready}{"\t"}{.nodeName}{"\n"}{end}'
```

```
NAME        ADDRESSTYPE   PORTS   ENDPOINTS                          AGE
web-9dk2n   IPv4          8080    10.244.1.5,10.244.2.4,10.244.1.6   12s

10.244.1.5   true   lpi703-worker
10.244.2.4   true   lpi703-worker2
10.244.1.6   true   lpi703-worker
```

3. Determiná en qué modo de dataplane está corriendo kube-proxy antes de buscar las reglas.

```bash
kubectl -n kube-system get configmap kube-proxy -o jsonpath='{.data.config\.conf}' | grep -E '^mode:|^    mode:'
```

Un valor vacío (`mode: ""`) significa el valor por defecto de la plataforma — `iptables` en Linux.

4. **Si el modo es `iptables` (o está vacío):** encontrá la cadena de reglas de tu ClusterIP.

```bash
SVCIP=$(kubectl get svc web -o jsonpath='{.spec.clusterIP}')
docker exec lpi703-worker iptables-save -t nat | grep "$SVCIP"
```

```
-A KUBE-SERVICES -d 10.96.115.24/32 -p tcp -m comment --comment "default/web cluster IP" -m tcp --dport 80 -j KUBE-SVC-LOLE4ISW44XBNF3G
-A KUBE-SVC-LOLE4ISW44XBNF3G ! -s 10.244.0.0/16 -d 10.96.115.24/32 -p tcp -m comment --comment "default/web cluster IP" -j KUBE-MARK-MASQ
```

```bash
docker exec lpi703-worker iptables-save -t nat | grep 'KUBE-SVC-LOLE4ISW44XBNF3G'
```

```
-A KUBE-SVC-LOLE4ISW44XBNF3G -m comment --comment "default/web -> 10.244.1.5:8080" -m statistic --mode random --probability 0.33333333349 -j KUBE-SEP-BSQ3E4L7QO2X
-A KUBE-SVC-LOLE4ISW44XBNF3G -m comment --comment "default/web -> 10.244.1.6:8080" -m statistic --mode random --probability 0.50000000000 -j KUBE-SEP-VN2ATRJKM6YZ
-A KUBE-SVC-LOLE4ISW44XBNF3G -m comment --comment "default/web -> 10.244.2.4:8080" -j KUBE-SEP-XR7Q1WFHDA9C
```

**Si el modo es `nftables`:** el equivalente es

```bash
docker exec lpi703-worker nft list table ip kube-proxy | grep -A6 "$SVCIP"
```

5. Resolvé el Service por nombre desde adentro del clúster.

```bash
kubectl run dns --rm -it --restart=Never \
  --image=registry.k8s.io/e2e-test-images/jessie-dnsutils:1.7 -- \
  sh -c 'cat /etc/resolv.conf; echo ---; nslookup web; echo ---; nslookup web.default.svc.cluster.local'
```

```
nameserver 10.96.0.10
search default.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
---
Name:   web.default.svc.cluster.local
Address: 10.96.115.24
```

6. Contrastá con un Service **headless**, que devuelve las IPs de los Pods en lugar de una VIP.

```bash
kubectl create service clusterip web-headless --clusterip=None --tcp=80:8080
kubectl patch service web-headless -p '{"spec":{"selector":{"app":"web"}}}'
kubectl run dns --rm -it --restart=Never \
  --image=registry.k8s.io/e2e-test-images/jessie-dnsutils:1.7 -- \
  nslookup web-headless.default.svc.cluster.local
```

```
Name:   web-headless.default.svc.cluster.local
Address: 10.244.1.5
Name:   web-headless.default.svc.cluster.local
Address: 10.244.1.6
Name:   web-headless.default.svc.cluster.local
Address: 10.244.2.4
```

7. Rompé la readiness y mirá cómo el endpoint desaparece del conjunto de balanceo en cuestión de segundos.

```bash
POD=$(kubectl get pod -l app=web -o jsonpath='{.items[0].metadata.name}')
kubectl exec "$POD" -- curl -s "http://localhost:8080/readyz?ok=false" >/dev/null 2>&1 || true
kubectl label pod "$POD" app=quarantine --overwrite
sleep 5
kubectl get endpointslices -l kubernetes.io/service-name=web \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"\n"}{end}'
kubectl delete pod "$POD"
```

8. Limpiá el Service extra.

```bash
kubectl delete svc web-headless
```

### Comprobá tu comprensión

* **Q7.1** — Nadie escucha en `10.96.115.24`. Explicá de punta a punta qué le pasa a un SYN de TCP enviado a esa dirección desde un Pod en `lpi703-worker`, nombrando el hook de netfilter y el subsistema del kernel que mantiene la conexión fijada a un mismo backend.
* **Q7.2** — Las probabilidades en la cadena `KUBE-SVC-*` dicen `0.3333`, `0.5`, y después ninguna. ¿Por qué esa secuencia es uniforme y no está sesgada hacia el último endpoint, y qué propiedad de balanceo de carga *no* ofrece entonces el modo iptables?
* **Q7.3** — `/etc/resolv.conf` fija `ndots:5` y una lista de búsqueda de tres entradas. Rastreá cuántas consultas DNS genera `nslookup web` frente a `nslookup web.default.svc.cluster.local.`, y explicá el problema de latencia en producción que esto causa para hostnames externos.
* **Q7.4** — Reetiquetar un Pod lo sacó del EndpointSlice. ¿Qué controller hizo esa eliminación, y qué otra condición a nivel de Pod produce el mismo efecto sin tocar los labels?
* **Q7.5** — Un Service headless tiene `clusterIP: None`. Nombrá dos patrones de carga de trabajo que lo requieren, y explicá qué programa kube-proxy para un Service así.

---

## Ejercicio 8 — Uso declarativo, propiedad de campos y cambios seguros

El objetivo del examen es *arquitectura **y uso***. Uso en producción significa manifiestos declarativos bajo control de versiones, aplicados con un mecanismo que detecte escritores concurrentes.

### Pasos

1. Namespaces, quotas y limits — las primitivas de multi-tenancy.

```yaml
# tenant.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-a
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: compute
  namespace: tenant-a
spec:
  hard:
    requests.cpu: "1"
    requests.memory: 1Gi
    limits.cpu: "2"
    limits.memory: 2Gi
    pods: "10"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: defaults
  namespace: tenant-a
spec:
  limits:
    - type: Container
      default:
        cpu: 200m
        memory: 128Mi
      defaultRequest:
        cpu: 50m
        memory: 64Mi
```

```bash
kubectl apply -f tenant.yaml
kubectl -n tenant-a describe quota compute
```

2. Mostrá que el LimitRange muta un Pod que no especifica nada.

```bash
kubectl -n tenant-a run bare --image=registry.k8s.io/pause:3.10
kubectl -n tenant-a get pod bare -o jsonpath='{.spec.containers[0].resources}{"\n"}'
```

```
{"limits":{"cpu":"200m","memory":"128Mi"},"requests":{"cpu":"50m","memory":"64Mi"}}
```

3. Probá que la quota se aplica en admission, no en la planificación.

```bash
kubectl -n tenant-a create deployment big --image=registry.k8s.io/pause:3.10 --replicas=1
kubectl -n tenant-a patch deployment big --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/resources","value":{"requests":{"cpu":"900m"},"limits":{"cpu":"1800m"}}}]'
sleep 5
kubectl -n tenant-a get deployment big -o jsonpath='{.status.conditions[?(@.type=="ReplicaFailure")].message}{"\n"}'
```

```
pods "big-..." is forbidden: exceeded quota: compute, requested: limits.cpu=1800m, used: limits.cpu=200m, limited: limits.cpu=2
```

4. Previsualizá un cambio antes de aplicarlo — el hábito que previene la mayoría de las caídas.

```bash
sed -i 's/replicas: 3/replicas: 5/' web-deployment.yaml
kubectl diff -f web-deployment.yaml
kubectl apply -f web-deployment.yaml --dry-run=server -o yaml | grep -E '^\s+replicas:'
```

5. Adoptá server-side apply e inspeccioná la propiedad de los campos.

```bash
kubectl apply -f web-deployment.yaml --server-side --field-manager=gitops
kubectl get deployment web -o jsonpath='{range .metadata.managedFields[*]}{.manager}{"\t"}{.operation}{"\n"}{end}'
```

```
gitops                   Apply
kube-controller-manager  Update
```

6. Creá un conflicto a propósito — el escenario exacto de un HPA peleando con tu manifiesto.

```bash
kubectl scale deployment web --replicas=2
kubectl apply -f web-deployment.yaml --server-side --field-manager=gitops
```

```
error: Apply failed with 1 conflict: conflict with "kubectl-scale" using apps/v1: .spec.replicas
Please review the fields above--they were changed at the same time by another
actor. ... use the --force-conflicts flag.
```

```bash
kubectl apply -f web-deployment.yaml --server-side --field-manager=gitops --force-conflicts
```

7. Practicá el vocabulario de diagnóstico de solo lectura que vas a necesitar bajo la presión de tiempo del examen.

```bash
kubectl get pods -A --field-selector=status.phase!=Running
kubectl get events -A --sort-by=.lastTimestamp | tail -10
kubectl top nodes 2>/dev/null || echo "metrics-server not installed — expected in kind"
kubectl logs deployment/web --all-containers --tail=5 --prefix
kubectl describe deployment web | sed -n '/Conditions:/,/Events:/p'
```

8. Desarmá el laboratorio.

```bash
kubectl delete namespace tenant-a
kind delete cluster --name lpi703
```

### Comprobá tu comprensión

* **Q8.1** — El Pod `bare` adquirió requests y limits que nunca declaró. ¿Qué etapa de admission hizo eso, y cómo interactúa con el ResourceQuota que, de otro modo, habría rechazado el Pod?
* **Q8.2** — La violación de la quota se manifestó como una condición `ReplicaFailure` en el Deployment y no como un Pod en `Pending`. Explicá por qué, y dónde tiene que buscar el mensaje quien opera.
* **Q8.3** — Contrastá `--dry-run=client` y `--dry-run=server`. ¿Cuál habría detectado el rechazo por quota del paso 3, y por qué?
* **Q8.4** — Server-side apply reportó un conflicto en `.spec.replicas` con el manager `kubectl-scale`. Describí qué almacena `managedFields`, e indicá la resolución correcta en GitOps cuando un HPA es legítimamente dueño de `replicas`.
* **Q8.5** — El `kubectl apply` del lado del cliente guardaba la intención en la anotación `kubectl.kubernetes.io/last-applied-configuration`. Nombrá dos modos de falla concretos de ese diseño que server-side apply elimina.

---

## Respuestas

<details>
<summary><strong>Hacé clic para revelar todas las respuestas</strong></summary>

### Ejercicio 0

**A0.1** — Un "nodo" de `kind` es un **contenedor** de Docker/Podman, no una máquina virtual. Comparte el kernel del host, así que todos los nodos reportan la versión de kernel del host y son idénticos por construcción. En consecuencia, el laboratorio no puede demostrar fielmente nada que dependa del aislamiento a nivel de kernel o de hardware entre nodos: tuning de kernel por nodo (diferencias de `sysctl`, divergencia entre cgroup v1 y v2), fallas de hardware reales, topología de almacenamiento local del nodo, o la frontera de seguridad entre nodos. También implica que un kernel panic o un cambio global de `sysctl` afecta a todos los "nodos" a la vez. Todo lo que está *por encima* del kernel — el kubelet, CRI, la contabilidad de cgroups, las reglas de netfilter por network namespace — se comporta fielmente, y por eso el resto de los ejercicios son válidos.

**A0.2** — `api-resources` se genera a partir del **documento de discovery** vivo del clúster, que refleja: (a) qué grupos de API integrados están habilitados en este API server (`--runtime-config` puede encender y apagar grupos y versiones); (b) cada **CustomResourceDefinition** instalada, que agrega filas dinámicamente; y (c) cada **APIService** registrada por un API server agregado (metrics-server publica `metrics.k8s.io`, por ejemplo). Dos clústeres con versiones idénticas de Kubernetes difieren apenas uno tiene un operador, un service mesh o metrics-server instalado. Por eso hardcodear una lista de recursos en el tooling es un bug: siempre hay que hacer discovery.

**A0.3** — **dockershim**, el adaptador in-tree que permitía al kubelet manejar Docker Engine, se eliminó en la v1.24. El kubelet ahora habla la **Container Runtime Interface (CRI)** — una API gRPC con un `RuntimeService` y un `ImageService` — sobre un socket Unix, con containerd, CRI-O o cualquier otro runtime conforme a CRI. Docker Engine todavía puede *construir* imágenes; simplemente ya no es lo que las ejecuta en un nodo. El prefijo `containerd://` en `CONTAINER-RUNTIME` es el endpoint del runtime que el kubelet le reportó al API server.

**A0.4** — Del **esquema OpenAPI publicado por el propio API server** (`/openapi/v3`), no de una copia compilada dentro del binario. Por eso `kubectl explain` documenta CRDs: cuando una CRD lleva un `schema` OpenAPI v3 en su `spec.versions[].schema.openAPIV3Schema`, el API server lo integra en el documento publicado y `kubectl explain mycrd.spec.foo` funciona con las descripciones que escribió quien autoró la CRD. También implica que la salida de `explain` sigue la versión del clúster, así que nunca contradice lo que el servidor va a aceptar realmente.

### Ejercicio 1

**A1.1** — El objeto de la API es un **mirror Pod**. El kubelet lo crea *en nombre de* un static Pod para que ese static Pod sea visible a través de la API; la propiedad se le atribuye al Node porque ningún controller lo gestiona. Borrar el mirror Pod borra solo el objeto de la API — el contenedor real sigue corriendo, y el kubelet recrea el mirror Pod dentro de un período de sincronización. Para detener realmente un static Pod hay que mover o editar su manifiesto en `staticPodPath` (que es lo que hizo el paso 5). Esta asimetría es un incidente clásico: "borré el Pod del apiserver y no pasó nada".

**A1.2** — El **ReplicaSet controller**, que corre dentro de `kube-controller-manager` y no se vio afectado por la ausencia del scheduler. El campo distintivo es **`spec.nodeName`**: está vacío en un Pod sin planificar. `status.phase` es `Pending` y la condición `PodScheduled` está en `False` con razón `Unschedulable`, pero `spec.nodeName == ""` es el marcador autoritativo. Esto separa limpiamente las dos responsabilidades: los controllers deciden *cuántos* Pods deben existir; el scheduler decide *dónde* va cada uno.

**A1.3** — El API server llega a etcd por la interfaz de loopback del nodo porque ambos corren en el mismo host y — más importante — porque **etcd nunca debería ser alcanzable desde la red del clúster**. No hay capa de autorización delante del espacio de claves de etcd: un cliente con un certificado de cliente etcd válido puede leer todos los Secrets y escribir cualquier objeto, salteándose por completo RBAC, admission control y validación. Por eso el modelo de amenaza de etcd es "el API server es el único cliente", forzado por la ubicación en la red más TLS mutuo. Exponer etcd equivale a repartir `cluster-admin` más la capacidad de falsificar estado.

**A1.4** — `kube-apiserver` es **stateless y escalable horizontalmente**: N réplicas pueden atender peticiones simultáneamente porque todo el estado compartido vive en etcd y las escrituras concurrentes se resuelven por concurrencia optimista sobre `resourceVersion`. `kube-scheduler` y `kube-controller-manager` son **activo/pasivo**: corren bucles de reconciliación que toman decisiones (bindear este Pod, crear aquel ReplicaSet). Dos schedulers activos competirían por bindear el mismo Pod a nodos distintos; dos controller-managers crearían réplicas por duplicado. Por eso disputan un objeto `Lease` en `kube-system`, y solo quien lo sostiene corre sus bucles — los demás quedan en hot-standby, mirando si la lease expira.

**A1.5** — El pipeline es: **autenticación → autorización → mutating admission → validación de esquema → validating admission → persistencia en etcd**. Admission corre, entonces, *después* de que la petición fue autenticada y autorizada, y *antes* de que se escriba nada. Los plugins mutantes pueden cambiar el objeto (defaults de LimitRange, proyección del token de ServiceAccount, inyección de sidecars por un webhook); los validantes solo pueden aceptar o rechazar (ResourceQuota, NodeRestriction, Pod Security admission). `NodeRestriction` en particular limita qué puede modificar un kubelet con sus propias credenciales — no puede editar otros nodos ni Pods que no estén bindeados a él, lo que contiene el radio de impacto de un certificado de nodo robado.

### Ejercicio 2

**A2.1** — Server-side printing significa que el **API server renderiza la tabla** — nombres de columnas, orden y contenido de las celdas — y devuelve un objeto `Table` de `meta.k8s.io/v1`; `kubectl` solo alinea el texto. Existe para que las CRDs puedan definir sus propias columnas (`additionalPrinterColumns`) y para que el cliente no necesite conocimiento específico del tipo. La consecuencia: **las columnas son un contrato de presentación propiedad del servidor y pueden cambiar entre versiones o con una actualización de CRD**. Cualquier script que haga `kubectl get pods | awk '{print $3}'` está parseando una interfaz inestable. Usá `-o jsonpath`, `-o json | jq` o `--output=custom-columns`, que leen los campos reales del objeto.

**A2.2** — `/livez` responde "¿este proceso está sano, o hay que reiniciarlo?". `/readyz` responde "¿esta instancia está lista para *servir tráfico*?" — además espera a que los informers sincronicen, a que la API termine los hooks de arranque, y reporta falla durante el apagado ordenado. `/healthz` es el endpoint heredado que confundía ambos y está obsoleto. Un balanceador de carga tiene que usar **`/readyz`**: con `/livez` el LB mandaría tráfico a un API server que está arriba pero no terminó de inicializar sus cachés, y durante una actualización progresiva seguiría mandando peticiones a una instancia que entró en apagado y está drenando — produciendo resets de conexión justo cuando menos podés tolerarlos. Agregá `?exclude=etcd` solo cuando deliberadamente quieras que la instancia siga en rotación mientras etcd está degradado.

**A2.3** — `SelfSubjectRulesReview` (y `SelfSubjectAccessReview` / `SubjectAccessReview` para chequeos individuales) en el grupo `authorization.k8s.io/v1`. Preguntarle al servidor es estrictamente más correcto porque el servidor evalúa la cadena de autorización *completa* en el orden configurado: `Node`, `RBAC`, posiblemente `ABAC` o un autorizador `Webhook`, más cada ClusterRoleBinding y RoleBinding que coincida con tu usuario **y con todos tus grupos**, incluidos los grupos inyectados por un proveedor OIDC o por los campos `O=` de un certificado. Leer los objetos RBAC a mano no reproduce nada de eso, y omite silenciosamente a los autorizadores que no son RBAC.

**A2.4** — `system:masters` está **cortocircuitado**: el autorizador RBAC lo concede incondicionalmente a través de un binding hardcodeado a `cluster-admin`, y se evalúa antes de cualquier búsqueda de Roles. No se puede revocar editando RBAC, no está sujeto a las restricciones en admission que podrías esperar, y — crítico — **los certificados de cliente no se pueden revocar** en Kubernetes (el autenticador estándar no soporta CRL ni OCSP). Un kubeconfig filtrado con un certificado `O=system:masters` es root permanente y a nivel de todo el clúster hasta que rotes la CA entera del clúster. El acceso humano debería venir de OIDC o de credenciales de corta duración, nunca del certificado de admin generado por kubeadm.

**A2.5** — Cada objeto lleva un `metadata.resourceVersion`, un token opaco derivado del contador de revisiones de etcd. Un watch se inicia con `resourceVersion=<N>` y el servidor transmite cada cambio *posterior* a N, así que un cliente puede desconectarse y retomar sin perder ni repetir eventos — esta es la base de la caché de informers de todo controller. **`410 Gone`** significa que la resourceVersion pedida se cayó de la ventana de la watch cache del servidor (compactación de etcd, o una caída larga del cliente). El cliente tiene entonces que hacer un **re-LIST** para obtener un estado completo fresco y una nueva resourceVersion, y reiniciar el watch desde ahí. Tratar a resourceVersion como un número para incrementar o comparar entre tipos de recursos es un bug: es opaco.

### Ejercicio 3

**A3.1** — base64 es una **codificación de transporte**, no cifrado; existe para que datos binarios arbitrarios puedan vivir en un campo de texto JSON/YAML. Aporta cero confidencialidad. Los dos mecanismos que sí lo hacen: (1) **cifrado en reposo** vía el `--encryption-provider-config` del API server, que cifra recursos (típicamente `secrets`) con AES-GCM o, mejor, con un proveedor KMS que mantiene el material de la clave en un HSM/KMS externo, de modo que una imagen del disco de etcd sea inútil por sí sola; y (2) **TLS en todos lados** — TLS entre peers y clientes de etcd, y el certificado de servicio del API server — para confidencialidad en tránsito. Más allá de eso, RBAC tiene que restringir quién puede hacer `get` de Secrets, y conviene preferir tokens proyectados de ServiceAccount de corta duración o un almacén de secretos externo antes que objetos Secret de larga vida.

**A3.2** — La cantidad de segmentos codifica el **alcance**. Los recursos con namespace se indexan como `/registry/<resource>/<namespace>/<name>`, así que el namespace es un prefijo real en el espacio de claves; borrar un namespace es una operación por prefijo, y un LIST acotado a un namespace es una lectura de rango por prefijo — por eso los LIST con namespace son más baratos que los de todo el clúster. Los recursos con alcance de clúster (`clusterroles`, `nodes`, `persistentvolumes`, los propios `namespaces`) no tienen segmento de namespace. Esto es exactamente la columna booleana `NAMESPACED` de `kubectl api-resources`, y es la razón por la que `kubectl get clusterrole -n foo` ignora silenciosamente el flag de namespace.

**A3.3** — (1) **Almacenamiento**: los objetos PersistentVolume se restauran apuntando a volúmenes cuyos datos reales avanzaron 30 minutos; una base de datos restaurada con un binding de PV desactualizado puede volver con split-brain o con un conjunto de réplicas corrupto. (2) **Identidad de las cargas de trabajo y estado externo**: los Pods registrados en el snapshot ya no existen en los nodos (los kubelets reportarán el estado real y los controllers los recrearán o adoptarán), mientras que todo lo que el clúster hizo en el mundo exterior durante esos 30 minutos — balanceadores de carga en la nube creados por el cloud-controller-manager, registros DNS, volúmenes aprovisionados, webhooks externos registrados — queda huérfano o duplicado. (3) **Tokens, leases y certificados**: los bindings de tokens de ServiceAccount, las Leases, y cualquier certificado emitido a través de la API de CSR en esa ventana desaparecen del estado restaurado, así que puede que ciertos agentes tengan que volver a registrarse; a la inversa, los bootstrap tokens que rotaste vuelven a la vida. Por eso el procedimiento correcto de restauración detiene todo el control plane, restaura cada miembro de etcd desde el *mismo* snapshot, y trata al clúster como algo que después necesita una auditoría de reconciliación.

**A3.4** — etcd usa **Raft**, que requiere una mayoría estricta (quórum) de `(N/2)+1` miembros para confirmar una escritura. N=3 → quórum 2 → tolera **1** falla. N=4 → quórum 3 → sigue tolerando solo **1** falla, mientras agrega una cuarta máquina que puede fallar y aumenta la latencia de escritura (cada commit tiene que alcanzar a un miembro más). N=5 → quórum 3 → tolera **2**. Así que los números pares agregan costo y superficie de falla sin agregar tolerancia a fallos. Más allá de 5, la latencia de escritura crece más rápido que el beneficio en disponibilidad; 7 se usa solo en despliegues muy grandes multi-AZ, y el escalado de lecturas se resuelve mejor con la watch cache del API server.

**A3.5** — Porque una escritura en etcd es **autoridad no mediada sobre el clúster**. No hay RBAC, ni admission control, ni validación entre un cliente de etcd y el espacio de claves: quien pueda escribir `/registry/clusterrolebindings/...` se otorga `cluster-admin`; quien pueda leer `/registry/secrets/...` tiene todas las credenciales del clúster. Los certificados de cliente son la única autenticación que tiene etcd, y TLS es la única confidencialidad. "Es una red privada" no es un control — es una suposición que falla en el instante en que un Pod con `hostNetwork: true`, un nodo comprometido o un CNI mal ruteado alcanzan el puerto 2379.

### Ejercicio 4

**A4.1** — **Deployment → ReplicaSet → Pod.** El **Deployment controller** reconcilia la arista Deployment→ReplicaSet: crea un ReplicaSet nuevo por cada revisión del pod template y orquesta el rollout escalando hacia arriba y hacia abajo los ReplicaSets viejo y nuevo. El **ReplicaSet controller** reconcilia la arista ReplicaSet→Pod: cuenta los Pods que coinciden con su selector y crea o borra hasta alcanzar `spec.replicas`. Ambos viven dentro de `kube-controller-manager`. **La aritmética de `maxSurge`/`maxUnavailable` es del Deployment controller** — el ReplicaSet controller no sabe nada de rollouts; solo converge una cuenta.

**A4.2** — El ReplicaSet controller **quitó** el `ownerReference` del Pod. Cuando un Pod deja de coincidir con el selector de un ReplicaSet, el controller lo *libera* (elimina el ownerReference), y como el ReplicaSet ahora ve solo 2 Pods coincidentes, crea un tercero. El Pod liberado queda sin dueño y sobrevive — ningún controller lo va a borrar, y ninguno lo va a reiniciar si muere. Operativamente esto es el **patrón de cuarentena**: cuando una réplica se comporta mal, la sacás con un reetiquetado del selector del Service y del ReplicaSet, y te queda una copia viva, aislada y que ya no sirve tráfico para hacerle `exec`, sacarle un heap dump o correr `tcpdump`, mientras el Deployment restaura la capacidad completa de inmediato. Acordate de borrarla después — nada más lo va a hacer.

**A4.3** — El Deployment controller calcula un **hash del pod template** (`pod-template-hash`), lo estampa como label en el ReplicaSet y en los Pods, y lo agrega al selector del ReplicaSet. Dos revisiones con templates idénticos byte a byte producen el mismo hash, así que `rollout undo` simplemente **encuentra el ReplicaSet existente con ese hash y lo vuelve a escalar** en lugar de crear uno nuevo — por eso el rollback es rápido y por eso las capas de la imagen ya están presentes en los nodos. `revisionHistoryLimit: 3` acota la cantidad de **ReplicaSets viejos, escalados a cero,** que se conservan; esos ReplicaSets vacíos *son* el historial de rollback, así que ponerlo en 0 hace imposible el `rollout undo`.

**A4.4** — **`background`** (por defecto): el padre se borra de inmediato y el recolector de basura elimina a los hijos de forma asíncrona después. **`foreground`**: el API server agrega el finalizer `foregroundDeletion` al padre, fija `deletionTimestamp` y mantiene vivo al objeto padre — visible, marcado para borrado — hasta que no quede ningún dependiente con `blockOwnerDeletion: true`; recién ahí se elimina el padre. **`orphan`**: se les quitan los `ownerReferences` a los dependientes y sobreviven de forma independiente. Así que `foreground` es el que bloquea, y está implementado por el **finalizer `foregroundDeletion`** que procesa el recolector de basura en `kube-controller-manager`.

**A4.5** — Como la propiedad se establece puramente por **coincidencia de label selector**, un selector mutable permitiría que un Deployment adoptara o abandonara silenciosamente Pods y ReplicaSets que pertenecen a otro controller — incluido otro Deployment. Dos Deployments cuyos selectores fueran editados hasta solaparse pelearían, cada uno tratando de converger los Pods compartidos a su propia cuenta y su propio template, en un bucle infinito. Hacer `spec.selector` inmutable después de la creación (aplicado en `apps/v1`) elimina toda esa clase de ambigüedad: el grafo de propiedad solo se puede cambiar borrando y recreando el objeto. Cuando tenés que cambiar un selector, creás un Deployment nuevo y migrás el tráfico.

### Ejercicio 5

**A5.1** — `Scheduled` lo emite el **`default-scheduler`**, y solo cuando el propio scheduler realiza el binding. Su ausencia prueba que el scheduler nunca intervino: `spec.nodeName` ya estaba fijado en el momento de la creación, así que el Pod nunca estuvo en la cola del scheduler. El **kubelet del nodo nombrado** observa los Pods cuyo `spec.nodeName` es igual al nombre de su propio nodo y los ejecuta directamente — el campo, no el scheduler, es sobre lo que actúa el kubelet. Por eso al scheduler se lo entiende mejor como "el componente que completa un campo vacío", no como un guardián.

**A5.2** — (1) **Viabilidad de recursos.** El kubelet va a admitir el Pod aunque la capacidad asignable restante del nodo no pueda satisfacer los requests — podés sobrecomprometer un nodo hasta llevarlo a desalojos, o bien el kubelet lo rechaza con `OutOfcpu` y, como nada lo replanifica, el Pod simplemente queda trabado. (2) **Aplicación de políticas.** Taints/tolerations, node affinity/anti-affinity, (anti)afinidad entre pods, topology spread constraints y la preempción por PriorityClass los evalúa el scheduler y se saltean silenciosamente. (3) **Capacidad de replanificación.** Un Pod fijado por nombre no puede moverse: si el nodo muere, el objeto Pod no se recoloca en ningún lado — con un Pod suelto simplemente se pierde, e incluso bajo un controller el reemplazo hereda el mismo nodo hardcodeado. Además perdés la observabilidad del scheduler (sin diagnósticos `FailedScheduling`) y cualquier comportamiento de plugins del scheduler, como la asignación dinámica de recursos.

**A5.3** — El scheduler corre **filter** (predicados) y después **score** (prioridades). La cláusula `1 node(s) had untolerated taint {node-role.kubernetes.io/control-plane: }` es el filtro **TaintToleration** rechazando al nodo de control plane; `2 Insufficient cpu` es el filtro **NodeResourcesFit** rechazando a ambos workers porque `requests.cpu` supera lo asignable menos lo ya solicitado. La fase de scoring nunca corrió, porque ningún nodo sobrevivió al filtrado. La frase final `preemption: ... Preemption is not helpful ... No preemption victims found` significa que el scheduler intentó después la **preempción**: buscó Pods de menor prioridad que pudiera desalojar para hacer lugar. "Not helpful" para el nodo con taint (desalojar Pods no arregla un taint), y "no victims" en los workers significa que, o bien ningún Pod ahí tiene una PriorityClass menor que la del Pod pendiente, o bien desalojar a todos los elegibles igual no liberaría 40 CPUs. En la práctica, este clúster no tiene configurada ninguna jerarquía de PriorityClass significativa.

**A5.4** — Un **request** es un reclamo de *planificación*: el scheduler suma `requests.cpu` sobre todos los Pods no terminados de un nodo y se niega a colocar un Pod si la suma superaría `allocatable.cpu`. Es contabilidad — no se hace cumplir en tiempo de ejecución, salvo como un piso de **`cpu.weight`/`cpu.shares`** en el cgroup, que solo importa bajo contención. Un **limit** es un tope de *ejecución* que el kubelet hace cumplir a través del cgroup: para CPU se convierte en `cpu.max` (cuota CFS), así que el proceso es **estrangulado (throttled)**, nunca matado; para memoria se convierte en `memory.max`, y excederlo hace que el proceso sea **matado por OOM**. **El scheduler ignora los limits por completo** — que es exactamente por qué un nodo puede quedar planificado al 100% de los requests mientras la suma de sus limits llega al 400% de la capacidad. Esa brecha es el sobrecompromiso que viste anotado en `describe node` como "Total limits may be over 100 percent".

**A5.5** — **`NoSchedule`** impide que se coloquen Pods *nuevos* sin una toleration coincidente; los Pods que ya están corriendo quedan intactos. **`PreferNoSchedule`** es la versión suave — una penalización en el scoring, no un filtro. **`NoExecute`** es el que afecta a los Pods en ejecución: los Pods sin una toleration coincidente son **desalojados**, de inmediato o después de `tolerationSeconds`. `kubectl drain` logra el mismo resultado correctamente porque (a) **acordona (cordon)** el nodo primero (fija `spec.unschedulable`, equivalente a un taint `NoSchedule`) para que no aterrice nada nuevo, y (b) desaloja cada Pod a través de la **Eviction API** (`policy/v1`), que se contrasta contra los **PodDisruptionBudgets** — así que un desalojo que dejaría a un Deployment por debajo de su `minAvailable` se rechaza con `429 Too Many Requests` y el drain espera en lugar de provocar una caída. Un taint `NoExecute` ignora los PDBs por completo; el drain los respeta. Fijate también que drain necesita `--ignore-daemonsets`, porque los Pods de DaemonSet se recrean de inmediato por diseño.

### Ejercicio 6

**A6.1** — Si el kubelet y containerd usan drivers de cgroup distintos, se crean **dos jerarquías de cgroups separadas** para los mismos contenedores: containerd ubica al contenedor en su propio árbol mientras el kubelet contabiliza y hace cumplir en otro. El resultado no es un error de arranque — ambos procesos arrancan bien y los Pods corren — pero la aplicación y la contabilidad de recursos se vuelven poco confiables: puede que los limits no se apliquen, `kubectl top` y las señales de desalojo reportan valores erróneos, y bajo presión de memoria el nodo se comporta de forma errática o el kubelet desaloja basándose en cifras que no coinciden con la realidad. Se manifiesta de forma intermitente, solo bajo carga, y por eso es célebremente difícil de diagnosticar. En un host con systemd, ambos tienen que ser `systemd` — esta es la mala configuración más común de kubeadm.

**A6.2** — Escribir el objeto `node.status` completo (docenas de campos, incluidas las imágenes y lo asignable) cada pocos segundos desde miles de nodos generaba una **carga de escritura enorme y mayormente redundante sobre etcd**, porque cada latido era una actualización de objeto completo que había que persistir y empujar a cada watcher. La Lease lo dividió: el kubelet renueva un objeto `Lease` diminuto en el namespace `kube-node-lease` cada `nodeLeaseDurationSeconds/4` (latido por defecto de 10s), mientras que `node.status` se escribe solo cuando algo cambia realmente, o cada `nodeStatusReportFrequency` (por defecto 5m). El **node-lifecycle controller** observa la **Lease** para decidir la vitalidad; si no se renueva dentro del período de gracia de monitoreo (por defecto 40s) la condición `Ready` del nodo pasa a `Unknown` y, después de `--pod-eviction-timeout` / los `tolerationSeconds` del taint `node.kubernetes.io/unreachable:NoExecute` (por defecto 300s), sus Pods son desalojados.

**A6.3** — Lo mató el **OOM killer del kernel de Linux**. Cuando el cgroup del contenedor alcanza `memory.max`, el subsistema de memory cgroup del kernel selecciona y mata un proceso dentro de ese cgroup — el kubelet no está en el camino y no puede impedirlo. Lo que el kubelet hace es *observar* el resultado: containerd reporta el estado de salida, el kubelet lee el evento OOM del cgroup y fija `reason: OOMKilled` en el status del contenedor. **137 = 128 + 9**: por convención de shell POSIX, un código de salida mayor a 128 significa "terminado por la señal N", y 9 es `SIGKILL`, que el OOM kill siempre usa (no es capturable). Contrastá con 143 = 128 + 15 (`SIGTERM`), que es una detención ordenada normal.

**A6.4** — **`Guaranteed`**: *todos* los contenedores del Pod (incluidos los init containers) especifican requests y limits para **ambos**, CPU y memoria, y para cada uno los requests son iguales a los limits. **`BestEffort`**: *ningún* contenedor especifica request ni limit alguno. **`Burstable`**: todo lo demás — hay al menos un request o limit fijado, pero no se cumple la condición de Guaranteed. Bajo presión de memoria del nodo, el kubelet desaloja en el orden **BestEffort → Burstable → Guaranteed**, y dentro de una clase ordena según cuánto excede el uso de memoria del Pod a su request (y según la prioridad del Pod). Los Pods Guaranteed se desalojan solo si exceden sus propios limits o si el nodo está en un estado que lo exige — por eso a las cargas críticas en latencia o con estado se les da `requests == limits`.

**A6.5** — Es el contenedor **sandbox / "pause"**. Es el primer contenedor que arranca en un Pod y, esencialmente, no hace nada: asigna y **mantiene abiertos los namespaces compartidos del Pod** — principalmente el network namespace (de ahí la IP del Pod), más IPC y, cuando se configura, el PID namespace — y recolecta los procesos zombie huérfanos. Todos los contenedores de aplicación del Pod después *se unen* a esos namespaces, y por eso precisamente comparten `localhost` y una única IP. Sin él no habría nada que mantuviera vivo el network namespace entre reinicios del contenedor de aplicación: la IP del Pod cambiaría cada vez que tu app se cayera, y el plugin CNI tendría que volver a correr en cada reinicio. No aparece como contenedor en la spec del Pod porque es un detalle de implementación del runtime CRI, que es la razón por la que solo lo ves con `crictl`.

### Ejercicio 7

**A7.1** — El SYN sale del network namespace del Pod con destino `10.96.115.24:80` — una dirección que no pertenece a ninguna interfaz y no responde ARP. Se rutea al namespace raíz del nodo, donde las reglas de kube-proxy en la **tabla `nat`** lo interceptan. En concreto, a la cadena `KUBE-SERVICES` se llega desde **`PREROUTING`** (para el tráfico que entra desde un veth de Pod) y desde **`OUTPUT`** (para el tráfico originado en el host); una coincidencia de IP y puerto de destino salta a la cadena del servicio, que elige un endpoint y hace **DNAT** hacia esa IP de Pod y su target port (`10.244.1.5:8080`). El subsistema **conntrack** registra la traducción, así que cada paquete posterior de ese flujo — y el camino de vuelta, des-DNATeado automáticamente — sigue al mismo backend. `KUBE-MARK-MASQ` marca los paquetes que necesitan SNAT a la salida (tráfico que no se originó dentro del CIDR de Pods) para que las respuestas vuelvan por el nodo. El cliente, entonces, nunca conoce la IP real del backend; la ClusterIP existe únicamente como estado de netfilter.

**A7.2** — iptables evalúa la cadena **secuencialmente**, y `-m statistic --mode random --probability p` es un tiro de moneda por regla que solo ve los paquetes que llegaron hasta esa regla. La primera regla se lleva 1/3 de todos los paquetes; la segunda ve los 2/3 restantes y se lleva la mitad = 1/3 del total; la tercera es incondicional y captura el último 1/3. Las probabilidades se calculan como `1/(n-i)` precisamente para que el resultado sea uniforme. Lo que este diseño **no** provee es ninguna conciencia del estado del backend: es selección aleatoria sin estado, así que **no hay least-connections, ni balanceo consciente de latencia o carga, ni reintento ante un backend caído, ni drenaje de conexiones** — una conexión DNATeada a un Pod que muere en medio del flujo simplemente se resetea, y conntrack la mantiene fijada ahí hasta que la entrada expire. El balanceo real consciente de la carga requiere el modo IPVS (que ofrece `rr`, `lc`, `sh` y otros), o un proxy L7 / service mesh.

**A7.3** — `ndots:5` significa: si el nombre consultado contiene **menos de 5 puntos** y no está totalmente calificado con un punto final, el resolver prueba **primero** cada entrada de la lista `search`, antes que el nombre tal como se dio. `nslookup web` (0 puntos) emite entonces, en orden: `web.default.svc.cluster.local` → acierto al primer intento (así que 1 consulta exitosa, aunque A y AAAA son consultas separadas). `nslookup web.default.svc.cluster.local` (4 puntos — ¡todavía < 5!) también recorre primero la lista de búsqueda: `web.default.svc.cluster.local.default.svc.cluster.local` (NXDOMAIN), `...svc.cluster.local` (NXDOMAIN), `...cluster.local` (NXDOMAIN), y recién después el nombre absoluto — **4 búsquedas en lugar de 1**. La consecuencia en producción es severa para nombres externos: `api.stripe.com` (2 puntos) genera tres NXDOMAIN dentro del clúster antes de la consulta real, multiplicando la carga de CoreDNS y agregando latencia a cada llamada saliente. Mitigaciones: agregar un **punto final** para que el nombre quede totalmente calificado (`api.stripe.com.`), bajar `ndots` por Pod vía `spec.dnsConfig.options`, o desplegar **NodeLocal DNSCache**.

**A7.4** — El **EndpointSlice controller** (en `kube-controller-manager`), que observa Services y Pods y mantiene los objetos EndpointSlice cuyo label `kubernetes.io/service-name` coincide. Sacó al Pod porque ya no coincidía con `spec.selector: app=web`. La condición que produce el mismo efecto sin tocar labels es la **readiness**: cuando la condición `Ready` de un Pod pasa a `False` — una `readinessProbe` que falla, o el Pod entrando en `Terminating` — el controller fija `conditions.ready: false` en ese endpoint, y kube-proxy deja de programarlo como destino. (Con `publishNotReadyAddresses: true` en el Service, o mediante `conditions.serving`/`terminating` para el manejo del apagado ordenado, la entrada sigue visible pero se trata distinto.) Este es justamente el mecanismo que convierte a la `readinessProbe` en tu control de admisión de tráfico.

**A7.5** — (1) **StatefulSets y software en clúster** — bases de datos, Kafka, Elasticsearch, el propio etcd — donde un cliente tiene que dirigirse a un miembro *específico*, no a uno al azar. Un Service headless combinado con un StatefulSet le da a cada Pod un nombre DNS estable, `<pod>.<service>.<namespace>.svc.cluster.local`, que es cómo los peers se descubren entre sí y cómo se configuran los destinos de replicación. (2) **Balanceo de carga del lado del cliente / descubrimiento de servicios**, donde un balanceador gRPC o a nivel de aplicación quiere la lista completa de endpoints para mantener conexiones persistentes a cada backend y hacer su propio balanceo por menor cantidad de peticiones — imposible a través de una VIP única, que fija cada conexión a un backend. Para un Service headless, **kube-proxy no programa absolutamente nada**: no hay ClusterIP que DNATear, así que no se crean reglas de iptables/nftables/IPVS. Todo el mecanismo es CoreDNS devolviendo múltiples registros A/AAAA leídos del EndpointSlice.

### Ejercicio 8

**A8.1** — El **plugin de admission LimitRange**, que corre durante la fase de **mutating admission**, inyectó `defaultRequest` como requests y `default` como limits en cada contenedor que los omitió. El orden es lo que hace que esto funcione: la mutación ocurre **antes** de la validating admission, así que para cuando el plugin **ResourceQuota** (un plugin validante) evalúa el Pod, los campos de recursos existen y pueden contarse contra la quota. Este orden no es accidental — es necesario, porque un ResourceQuota que restringe `requests.cpu` **rechaza cualquier Pod con un request sin fijar**. Sin un LimitRange que aporte los defaults, cada `kubectl run` en un namespace con quota fallaría con "must specify requests.cpu". LimitRange además hace cumplir cotas `min`/`max` y puede rechazar Pods directamente.

**A8.2** — Porque el rechazo ocurre cuando el **ReplicaSet controller** intenta crear el Pod — el objeto Pod nunca se admite, así que no hay un Pod en Pending para describir ni un Event a nivel de Pod. El controller registra la falla fijando la condición `ReplicaFailure` del ReplicaSet, que el Deployment controller expone en el Deployment. Quien opera tiene que mirar **`kubectl describe replicaset`** / las `status.conditions` del Deployment, o los Events del objeto **ReplicaSet** (`kubectl get events --field-selector involvedObject.kind=ReplicaSet`). Esta es una trampa diagnóstica clásica: `kubectl get pods` no muestra nada mal porque no hay nada ahí, y el Deployment simplemente reporta menos réplicas listas de las deseadas. Cualquier rechazo en admission — quota, Pod Security admission, un webhook validante — se comporta así para los Pods creados por controllers.

**A8.3** — `--dry-run=client` renderiza el objeto localmente y lo imprime; nunca contacta al API server, así que no valida nada más allá del parseo básico de esquema del lado del cliente. `--dry-run=server` envía la petición con `dryRun=All`, así que el API server corre el **pipeline completo — autenticación, autorización, mutating admission (incluidos los webhooks), validación de esquema, validating admission — y después descarta el objeto en lugar de persistirlo**. Solo el dry-run del lado del servidor habría detectado el rechazo por quota, porque ResourceQuota es un plugin de admission validante evaluado por el servidor. Es además la única variante que te muestra el objeto *después* del defaulting y la mutación, que es lo que `kubectl diff` usa por debajo y por qué `kubectl diff` es confiable para revisar cambios.

**A8.4** — `metadata.managedFields` registra, por cada **field manager** (una cadena de identidad, que por defecto es el nombre del binario), qué **campos específicos** posee, con qué operación (`Apply` o `Update`) y en qué versión de la API. Un server-side apply que intenta fijar un campo perteneciente a otro manager con un valor *diferente* produce un **conflicto**, en lugar de pisarlo silenciosamente. Acá `kubectl scale` tomó posesión de `.spec.replicas`, así que el apply del manager `gitops` fue rechazado. `--force-conflicts` roba la propiedad — correcto cuando el error fue el cambio imperativo. Pero cuando un **HPA es legítimamente dueño de `replicas`**, forzar es exactamente lo incorrecto: arranca una pelea en la que el manifiesto resetea la cuenta y el HPA la vuelve a escalar, en cada reconciliación. La resolución correcta es **quitar `spec.replicas` del manifiesto por completo**, para que el manager de GitOps nunca reclame ese campo y el HPA sea su único dueño. (Argo CD y Flux documentan esto como el caso canónico.)

**A8.5** — (1) **Borrado de campos no gestionados.** El apply del lado del cliente calcula una fusión a tres vías a partir de la anotación last-applied; si otro actor agregó un campo al objeto vivo (un HPA, un webhook mutante, un operador) y ese campo está ausente de tu manifiesto, la lógica de diff puede decidir borrarlo — o, peor, la semántica difiere según si el campo alguna vez estuvo en tu last-applied. El server-side apply nunca toca campos que no poseés. (2) **La anotación en sí.** Guarda una copia completa de tu manifiesto dentro de la metadata del objeto, lo que duplica el tamaño del objeto en etcd y, para recursos grandes como CRDs con esquemas voluminosos o ConfigMaps, puede **exceder el límite de 262144 bytes de las anotaciones y hacer que el apply falle de plano** (el conocido error `metadata.annotations: Too long` al hacer `kubectl apply` de CRDs grandes). El server-side apply mantiene la propiedad como `managedFields` estructurados en lugar de un blob serializado. Un tercer beneficio que vale nombrar: los conflictos se vuelven **errores explícitos** en lugar de un último-que-escribe-gana silencioso, así que dos controllers peleando por un campo es detectable y no un misterio intermitente de oscilaciones.

</details>

---

## Referencias de las fuentes

* LPI — Exam 701 Objectives (DevOps Tools Engineer v2.0): <https://www.lpi.org/our-certifications/exam-701-objectives/>
* Kubernetes Components: <https://kubernetes.io/docs/concepts/overview/components/>
* Control Plane–Node Communication: <https://kubernetes.io/docs/concepts/architecture/control-plane-node-communication/>
* Nodes: <https://kubernetes.io/docs/concepts/architecture/nodes/>
* Static Pods: <https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/>
* Kubernetes API Concepts (resourceVersion, watch, Table printing): <https://kubernetes.io/docs/reference/using-api/api-concepts/>
* API Server health endpoints: <https://kubernetes.io/docs/reference/using-api/health-checks/>
* Admission Controllers Reference: <https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/>
* RBAC Authorization: <https://kubernetes.io/docs/reference/access-authn-authz/rbac/>
* Encrypting Confidential Data at Rest: <https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/>
* Operating etcd clusters for Kubernetes: <https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/>
* etcd documentation (Raft, quorum, snapshots): <https://etcd.io/docs/v3.5/op-guide/>
* Deployments: <https://kubernetes.io/docs/concepts/workloads/controllers/deployment/>
* ReplicaSet: <https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/>
* Owners and Dependents / Garbage Collection: <https://kubernetes.io/docs/concepts/architecture/garbage-collection/>
* kube-scheduler: <https://kubernetes.io/docs/concepts/scheduling-eviction/kube-scheduler/>
* Taints and Tolerations: <https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/>
* Safely Drain a Node: <https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/>
* Container Runtime Interface / CRI: <https://kubernetes.io/docs/concepts/architecture/cri/>
* Configuring a cgroup driver: <https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/configure-cgroup-driver/>
* Node-pressure Eviction: <https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/>
* Pod Quality of Service Classes: <https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/>
* Service: <https://kubernetes.io/docs/concepts/services-networking/service/>
* EndpointSlices: <https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/>
* Virtual IPs and Service Proxies (proxy modes): <https://kubernetes.io/docs/reference/networking/virtual-ips/>
* DNS for Services and Pods: <https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/>
* Resource Quotas: <https://kubernetes.io/docs/concepts/policy/resource-quotas/>
* Limit Ranges: <https://kubernetes.io/docs/concepts/policy/limit-range/>
* Server-Side Apply: <https://kubernetes.io/docs/reference/using-api/server-side-apply/>
* kind — Quick Start: <https://kind.sigs.k8s.io/docs/user/quick-start/>