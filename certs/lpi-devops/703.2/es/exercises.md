# 703.2 — Operaciones básicas de Kubernetes
## Ejercicios guiados (LPI DevOps Tools Engineer, examen 701-100 v2.0.0)

> **Peso en el examen:** 11.67 — el objetivo más pesado del Tema 703.
> **Qué estás practicando:** la superficie de comandos de `kubectl`, la cadena de propiedad Pod → ReplicaSet → Deployment, Services y DNS del clúster, ConfigMaps y Secrets, labels/selectores/annotations, namespaces, probes y resource requests, y el ciclo de diagnóstico que vas a usar realmente en producción.
>
> Cada paso de abajo es ejecutable. Las salidas mostradas son formas reales de un clúster `kind` corriendo Kubernetes v1.33; los hashes, las IPs y las marcas de tiempo van a diferir en tu máquina — la *estructura* es lo que tenés que verificar.

---

## Ejercicio 0 — Construir el clúster de laboratorio

Necesitás un clúster descartable que puedas romper. `kind` (Kubernetes IN Docker) te da un clúster de tres nodos en aproximadamente un minuto y es desechable por diseño.

**Pasos**

1. Verificá las herramientas del cliente:

   ```bash
   docker version --format '{{.Server.Version}}'
   kind version
   kubectl version --client
   ```

   ```
   27.3.1
   kind v0.27.0 go1.23.6 linux/amd64
   Client Version: v1.33.1
   Kustomize Version: v5.6.0
   ```

2. Escribí la definición del clúster. El bloque `extraPortMappings` publica el NodePort `30080` desde el contenedor del control-plane hacia tu host — lo vas a necesitar en el Ejercicio 5.

   ```yaml
   # kind-703.yaml
   kind: Cluster
   apiVersion: kind.x-k8s.io/v1alpha4
   name: lpi-703
   nodes:
     - role: control-plane
       extraPortMappings:
         - containerPort: 30080
           hostPort: 30080
           protocol: TCP
     - role: worker
     - role: worker
   ```

3. Creá el clúster:

   ```bash
   kind create cluster --config kind-703.yaml
   ```

   ```
   Creating cluster "lpi-703" ...
    ✓ Ensuring node image (kindest/node:v1.33.1) 🖼
    ✓ Preparing nodes 📦 📦 📦
    ✓ Writing configuration 📜
    ✓ Starting control-plane 🕹️
    ✓ Installing CNI 🔌
    ✓ Installing StorageClass 💾
    ✓ Joining worker nodes 🚜
   Set kubectl context to "kind-lpi-703"
   ```

4. Confirmá que los nodos estén `Ready` y anotá sus roles:

   ```bash
   kubectl get nodes -o wide
   ```

   ```
   NAME                     STATUS   ROLES           AGE   VERSION   INTERNAL-IP   OS-IMAGE
   lpi-703-control-plane    Ready    control-plane   84s   v1.33.1   172.18.0.4    Debian GNU/Linux 12
   lpi-703-worker           Ready    <none>          71s   v1.33.1   172.18.0.2    Debian GNU/Linux 12
   lpi-703-worker2          Ready    <none>          71s   v1.33.1   172.18.0.3    Debian GNU/Linux 12
   ```

5. Inspeccioná qué hace diferente al nodo del control-plane respecto de los workers:

   ```bash
   kubectl get node lpi-703-control-plane \
     -o jsonpath='{.spec.taints}{"\n"}'
   ```

   ```
   [{"effect":"NoSchedule","key":"node-role.kubernetes.io/control-plane"}]
   ```

**Preguntas de control**

- **Q0.1** — Dos de los nodos muestran `ROLES: <none>`. ¿De dónde sale el rol `control-plane` en esa columna — es un campo del spec del Node?
- **Q0.2** — ¿Qué efecto concreto tiene el taint impreso en el paso 5 sobre una carga de trabajo que crees más adelante, y qué necesitaría un Pod para aterrizar ahí de todos modos?
- **Q0.3** — `kubectl version --client` imprimió una versión de *Kustomize*. ¿Por qué un CLI de Kubernetes reporta eso siquiera?

---

## Ejercicio 1 — kubectl, kubeconfig y descubrimiento de la API

Antes de crear nada, aprendé a interrogar al API server. La mayoría de los incidentes de "kubectl no funciona" son problemas de contexto o de RBAC, no problemas del clúster.

**Pasos**

1. Listá los contextos que conoce tu kubeconfig e identificá el activo:

   ```bash
   kubectl config get-contexts
   ```

   ```
   CURRENT   NAME            CLUSTER         AUTHINFO        NAMESPACE
   *         kind-lpi-703    kind-lpi-703    kind-lpi-703
   ```

2. Mostrá solo el contexto activo, con las credenciales redactadas, y extraé el endpoint de la API:

   ```bash
   kubectl config view --minify
   kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}{"\n"}'
   ```

   ```
   https://127.0.0.1:38471
   ```

3. Averiguá qué archivo leyó realmente kubectl:

   ```bash
   echo "${KUBECONFIG:-$HOME/.kube/config}"
   kubectl config view --raw -o jsonpath='{.users[0].name}{"\n"}'
   ```

4. Preguntale al API server qué sirve. Estos dos comandos responden preguntas *diferentes*:

   ```bash
   kubectl api-versions | sort | head -20
   kubectl api-resources --namespaced=true -o wide | head -12
   ```

   ```
   NAME          SHORTNAMES   APIVERSION   NAMESPACED   KIND         VERBS
   configmaps    cm           v1           true         ConfigMap    [create delete deletecollection get list patch update watch]
   endpoints     ep           v1           true         Endpoints    [create delete deletecollection get list patch update watch]
   events        ev           v1           true         Event        [create delete deletecollection get list patch update watch]
   pods          po           v1           true         Pod          [create delete deletecollection get list patch update watch]
   secrets                    v1           true         Secret       [create delete deletecollection get list patch update watch]
   services      svc          v1           true         Service      [create delete deletecollection get list patch update watch]
   daemonsets    ds           apps/v1      true         DaemonSet    [create delete deletecollection get list patch update watch]
   deployments   deploy       apps/v1      true         Deployment   [create delete deletecollection get list patch update watch]
   replicasets   rs           apps/v1      true         ReplicaSet   [create delete deletecollection get list patch update watch]
   ```

5. Listá los recursos de alcance de clúster — los que un namespace no puede contener:

   ```bash
   kubectl api-resources --namespaced=false -o name | sort
   ```

   ```
   apiservices.apiregistration.k8s.io
   clusterrolebindings.rbac.authorization.k8s.io
   clusterroles.rbac.authorization.k8s.io
   csidrivers.storage.k8s.io
   ingressclasses.networking.k8s.io
   namespaces
   nodes
   persistentvolumes
   priorityclasses.scheduling.k8s.io
   runtimeclasses.node.k8s.io
   storageclasses.storage.k8s.io
   ...
   ```

6. Leé el esquema directamente del servidor en lugar de adivinar nombres de campos:

   ```bash
   kubectl explain deployment.spec.strategy.rollingUpdate
   kubectl explain pod.spec.containers.livenessProbe --recursive | head -25
   ```

   ```
   GROUP:      apps
   KIND:       Deployment
   VERSION:    v1

   FIELD: rollingUpdate <RollingUpdateDeployment>

   DESCRIPTION:
       Rolling update config params. Present only if DeploymentStrategyType =
       RollingUpdate.

   FIELDS:
     maxSurge      <IntOrString>
     maxUnavailable        <IntOrString>
   ```

7. Verificá tus propios permisos antes de culpar al clúster:

   ```bash
   kubectl auth can-i create deployments --namespace default
   kubectl auth can-i delete nodes
   kubectl auth can-i --list --namespace default | head -6
   ```

   ```
   yes
   yes
   ```

8. Hablá con un endpoint crudo, salteando la capa de objetos de kubectl:

   ```bash
   kubectl get --raw='/readyz?verbose' | tail -8
   kubectl get --raw='/api/v1/namespaces/kube-system/pods' | head -c 200; echo
   ```

   ```
   [+]poststarthook/start-legacy-token-tracking-controller ok
   [+]poststarthook/start-service-ip-repair-controllers ok
   [+]shutdown ok
   readyz check passed
   ```

**Preguntas de control**

- **Q1.1** — En orden de precedencia, ¿qué determina qué archivo kubeconfig usa kubectl, y cómo apuntás a uno distinto para un solo comando sin exportar nada permanentemente?
- **Q1.2** — Explicá la diferencia entre `kubectl api-versions` y `kubectl api-resources`. ¿Cuál te diría que hay disponible un Custom Resource llamado `Certificate` y cuál es su nombre corto?
- **Q1.3** — ¿Por qué `kubectl explain` es más confiable que la documentación upstream cuando estás trabajando en el clúster de otra persona?
- **Q1.4** — `kubectl auth can-i --list` devolvió resultados sin que crearas ningún RBAC. ¿Qué identidad está usando kubectl, y cómo verificarías los permisos de *otro* sujeto desde tu cuenta de admin?

---

## Ejercicio 2 — Namespaces y las dos formas de crear objetos

**Pasos**

1. Creá un namespace e inspeccioná el resultado:

   ```bash
   kubectl create namespace ops-lab
   kubectl get ns
   ```

   ```
   namespace/ops-lab created
   NAME                 STATUS   AGE
   default              Active   6m
   kube-node-lease      Active   6m
   kube-public          Active   6m
   kube-system          Active   6m
   local-path-storage   Active   6m
   ops-lab              Active   2s
   ```

2. Hacelo el predeterminado del contexto actual para dejar de tipear `-n`:

   ```bash
   kubectl config set-context --current --namespace=ops-lab
   kubectl config view --minify -o jsonpath='{..namespace}{"\n"}'
   ```

   ```
   Context "kind-lpi-703" modified.
   ops-lab
   ```

3. Usá los comandos imperativos como **generadores de manifiestos**, no como método de despliegue:

   ```bash
   kubectl run sandbox --image=busybox:1.36 --restart=Never \
     --dry-run=client -o yaml -- sleep 3600
   ```

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     creationTimestamp: null
     labels:
       run: sandbox
     name: sandbox
   spec:
     containers:
     - args:
       - sleep
       - "3600"
       image: busybox:1.36
       name: sandbox
       resources: {}
     dnsPolicy: ClusterFirst
     restartPolicy: Never
   status: {}
   ```

4. Ahora escribí la versión declarativa que realmente commitearías a Git:

   ```yaml
   # 01-pods.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: sandbox
     namespace: ops-lab
     labels:
       app: sandbox
       tier: tooling
   spec:
     containers:
       - name: shell
         image: busybox:1.36
         command: ["sleep", "3600"]
         resources:
           requests:
             cpu: 10m
             memory: 16Mi
           limits:
             cpu: 100m
             memory: 64Mi
   ---
   apiVersion: v1
   kind: Pod
   metadata:
     name: nginx-solo
     namespace: ops-lab
     labels:
       app: nginx-solo
       tier: frontend
   spec:
     containers:
       - name: nginx
         image: nginx:1.27.4-alpine
         ports:
           - name: http
             containerPort: 80
         resources:
           requests:
             cpu: 50m
             memory: 32Mi
           limits:
             cpu: 200m
             memory: 128Mi
   ```

   ```bash
   kubectl apply -f 01-pods.yaml
   ```

   ```
   pod/sandbox created
   pod/nginx-solo created
   ```

5. Mirá cómo arrancan, y después observá la ubicación:

   ```bash
   kubectl get pods -o wide
   ```

   ```
   NAME         READY   STATUS    RESTARTS   AGE   IP           NODE              NOMINATED NODE   READINESS GATES
   nginx-solo   1/1     Running   0          22s   10.244.1.5   lpi-703-worker    <none>           <none>
   sandbox      1/1     Running   0          22s   10.244.2.4   lpi-703-worker2   <none>           <none>
   ```

6. Leé la historia completa de un Pod:

   ```bash
   kubectl describe pod nginx-solo | sed -n '1,12p;/Events:/,$p'
   ```

   ```
   Name:             nginx-solo
   Namespace:        ops-lab
   Priority:         0
   Service Account:  default
   Node:             lpi-703-worker/172.18.0.2
   Start Time:       Thu, 03 Sep 2026 09:14:02 -0300
   Labels:           app=nginx-solo
                     tier=frontend
   Annotations:      <none>
   Status:           Running
   IP:               10.244.1.5
   Events:
     Type    Reason     Age   From               Message
     ----    ------     ----  ----               -------
     Normal  Scheduled  32s   default-scheduler  Successfully assigned ops-lab/nginx-solo to lpi-703-worker
     Normal  Pulling    31s   kubelet            Pulling image "nginx:1.27.4-alpine"
     Normal  Pulled     29s   kubelet            Successfully pulled image "nginx:1.27.4-alpine" in 1.84s
     Normal  Created    29s   kubelet            Created container: nginx
     Normal  Started    29s   kubelet            Started container nginx
   ```

7. Demostrá que `create` y `apply` no son intercambiables:

   ```bash
   kubectl create -f 01-pods.yaml
   kubectl apply -f 01-pods.yaml
   ```

   ```
   Error from server (AlreadyExists): error when creating "01-pods.yaml": pods "sandbox" already exists
   Error from server (AlreadyExists): error when creating "01-pods.yaml": pods "nginx-solo" already exists

   pod/sandbox unchanged
   pod/nginx-solo unchanged
   ```

**Preguntas de control**

- **Q2.1** — Tanto `--dry-run=client` como `--dry-run=server` imprimen un objeto sin persistirlo. ¿Qué detecta la variante del lado del servidor que la del lado del cliente no puede?
- **Q2.2** — En el paso 5 los dos Pods aterrizaron en nodos distintos. ¿Qué componente tomó esa decisión, y en qué momento existió por primera vez el objeto Pod en etcd respecto de esa decisión?
- **Q2.3** — `sandbox` se creó con `restartPolicy: Never` en el YAML generado, pero el manifiesto commiteado omite `restartPolicy`. ¿Qué valor almacena el API server, y por qué importa eso para un Pod suelto?
- **Q2.4** — Si ejecutás `kubectl delete namespace ops-lab`, ¿qué les pasa a los dos Pods, y por qué el namespace puede quedarse en `Terminating` por mucho tiempo?
- **Q2.5** — Ninguno de los dos Pods está gestionado por un controlador. Nombrá dos modos de falla de los que, en consecuencia, *no* se van a recuperar.

---

## Ejercicio 3 — Labels, selectores y annotations

Las labels son la clave de join de todo el sistema. Los Services, los ReplicaSets, las NetworkPolicies y el propio `kubectl` direccionan objetos a través de selectores — nunca a través de nombres.

**Pasos**

1. Creá una población pequeña y deliberadamente heterogénea:

   ```bash
   kubectl run cache   --image=redis:7.4-alpine --labels='app=cache,tier=backend,env=dev'
   kubectl run api-dev --image=nginx:1.27.4-alpine --labels='app=api,tier=backend,env=dev'
   kubectl run api-prd --image=nginx:1.27.4-alpine --labels='app=api,tier=backend,env=prod'
   kubectl get pods --show-labels
   ```

   ```
   NAME         READY   STATUS    RESTARTS   AGE   LABELS
   api-dev      1/1     Running   0          9s    app=api,env=dev,tier=backend
   api-prd      1/1     Running   0          8s    app=api,env=prod,tier=backend
   cache        1/1     Running   0          10s   app=cache,env=dev,tier=backend
   nginx-solo   1/1     Running   0          4m    app=nginx-solo,tier=frontend
   sandbox      1/1     Running   0          4m    app=sandbox,tier=tooling
   ```

2. Selección basada en igualdad, y después promové una label a columna:

   ```bash
   kubectl get pods -l tier=backend
   kubectl get pods -l 'app=api,env=prod'
   kubectl get pods -L env,tier
   ```

   ```
   NAME      READY   STATUS    RESTARTS   AGE   ENV    TIER
   api-dev   1/1     Running   0          40s   dev    backend
   api-prd   1/1     Running   0          39s   prod   backend
   cache     1/1     Running   0          41s   dev    backend
   nginx-solo 1/1    Running   0          5m    <none> frontend
   sandbox   1/1     Running   0          5m    <none> tooling
   ```

3. Selección basada en conjuntos — la forma que no tiene equivalente por igualdad:

   ```bash
   kubectl get pods -l 'env in (dev,staging)'
   kubectl get pods -l 'app notin (cache,sandbox)'
   kubectl get pods -l 'env'          # has the key, any value
   kubectl get pods -l '!env'         # does NOT have the key
   ```

   ```
   NAME         READY   STATUS    RESTARTS   AGE
   nginx-solo   1/1     Running   0          6m
   sandbox      1/1     Running   0          6m
   ```

4. Mutá labels en el lugar, incluyendo la guarda de sobrescritura:

   ```bash
   kubectl label pod cache env=prod
   kubectl label pod cache env=prod --overwrite
   kubectl label pod cache retention-              # trailing dash removes a key
   ```

   ```
   error: 'env' already has a value (dev), and --overwrite is false
   pod/cache labeled
   pod/cache not labeled
   ```

5. Adjuntá una annotation — metadato arbitrario, no seleccionable:

   ```bash
   kubectl annotate pod api-prd \
     owner='sre-platform@example.com' \
     runbook='https://wiki.example.com/runbooks/api' \
     kubernetes.io/change-cause='initial manual placement'
   kubectl get pod api-prd -o jsonpath='{.metadata.annotations}{"\n"}' | tr ',' '\n'
   ```

   ```
   {"kubernetes.io/change-cause":"initial manual placement"
   "owner":"sre-platform@example.com"
   "runbook":"https://wiki.example.com/runbooks/api"}
   ```

6. Intentá seleccionar sobre la annotation, y después sobre un *field*:

   ```bash
   kubectl get pods -l owner=sre-platform@example.com
   kubectl get pods --field-selector status.phase=Running
   kubectl get pods --field-selector spec.nodeName=lpi-703-worker2
   kubectl get pods --field-selector metadata.annotations.owner=x
   ```

   ```
   No resources found in ops-lab namespace.

   NAME         READY   STATUS    RESTARTS   AGE
   api-dev      1/1     Running   0          3m
   ...
   NAME      READY   STATUS    RESTARTS   AGE
   sandbox   1/1     Running   0          9m
   cache     1/1     Running   0          3m

   Error from server (BadRequest): Unable to find "/v1, Resource=pods" that match label selector "",
   field selector "metadata.annotations.owner=x": "metadata.annotations.owner" is not a known field selector...
   ```

7. Operaciones masivas guiadas por un selector:

   ```bash
   kubectl get pods -l env=dev -o name
   kubectl delete pods -l env=dev
   ```

   ```
   pod/api-dev
   pod/cache
   pod "api-dev" deleted
   pod "cache" deleted
   ```

**Preguntas de control**

- **Q3.1** — Enunciá la regla que decide si un metadato va en `labels` o en `annotations`. Dá un ejemplo de cada uno tomado de un clúster real.
- **Q3.2** — Escribí el selector que significa "tier backend, en producción, pero no la app `cache`" en una sola expresión `-l`.
- **Q3.3** — El paso 6 muestra que las annotations no son seleccionables y que solo algunos campos son field selectors válidos. ¿Por qué existe esa restricción — qué está haciendo el API server de manera diferente con las labels?
- **Q3.4** — El `.spec.selector.matchLabels` de un Deployment es inmutable en `apps/v1`. ¿Por qué los diseñadores de la API lo hicieron inmutable, y cuál es el procedimiento práctico cuando tenés que cambiarlo?
- **Q3.5** — ¿Cuáles son las restricciones sintácticas sobre el *valor* de una label (longitud, caracteres permitidos), y por qué no podés poner una URL en uno?

---

## Ejercicio 4 — Deployments, ReplicaSets y rollouts

**Pasos**

1. Creá un Deployment de forma declarativa:

   ```yaml
   # 02-deploy.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: web
     namespace: ops-lab
     labels:
       app: web
   spec:
     replicas: 3
     revisionHistoryLimit: 5
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
           tier: frontend
       spec:
         containers:
           - name: nginx
             image: nginx:1.27.4-alpine
             ports:
               - name: http
                 containerPort: 80
             resources:
               requests:
                 cpu: 25m
                 memory: 32Mi
               limits:
                 cpu: 250m
                 memory: 128Mi
   ```

   ```bash
   kubectl apply -f 02-deploy.yaml
   kubectl rollout status deployment/web --timeout=90s
   ```

   ```
   deployment.apps/web created
   Waiting for deployment "web" rollout to finish: 0 of 3 updated replicas are available...
   deployment "web" successfully rolled out
   ```

2. Observá la cadena de propiedad de tres niveles:

   ```bash
   kubectl get deploy,rs,pods -l app=web
   ```

   ```
   NAME                  READY   UP-TO-DATE   AVAILABLE   AGE
   deployment.apps/web   3/3     3            3           35s

   NAME                            DESIRED   CURRENT   READY   AGE
   replicaset.apps/web-7d9c8b6f45  3         3         3       35s

   NAME                      READY   STATUS    RESTARTS   AGE
   pod/web-7d9c8b6f45-4kxq7  1/1     Running   0          35s
   pod/web-7d9c8b6f45-9v2mt  1/1     Running   0          35s
   pod/web-7d9c8b6f45-tz8n6  1/1     Running   0          35s
   ```

3. Seguí los enlaces de propiedad explícitamente:

   ```bash
   kubectl get pod web-7d9c8b6f45-4kxq7 \
     -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}'
   kubectl get rs web-7d9c8b6f45 \
     -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}'
   kubectl get pod web-7d9c8b6f45-4kxq7 --show-labels
   ```

   ```
   ReplicaSet/web-7d9c8b6f45
   Deployment/web
   NAME                   READY   STATUS    RESTARTS   AGE   LABELS
   web-7d9c8b6f45-4kxq7   1/1     Running   0          2m    app=web,pod-template-hash=7d9c8b6f45,tier=frontend
   ```

4. Escalá de forma imperativa, y después notá la deriva que acabás de introducir:

   ```bash
   kubectl scale deployment/web --replicas=5
   kubectl get deploy web
   kubectl scale deployment/web --replicas=3 --current-replicas=5
   ```

   ```
   deployment.apps/web scaled
   NAME   READY   UP-TO-DATE   AVAILABLE   AGE
   web    5/5      5           5           3m
   deployment.apps/web scaled
   ```

5. Lanzá una imagen nueva y registrá *por qué*:

   ```bash
   kubectl set image deployment/web nginx=nginx:1.27.5-alpine
   kubectl annotate deployment/web kubernetes.io/change-cause='CVE patch: nginx 1.27.4 -> 1.27.5'
   kubectl rollout status deployment/web
   kubectl get rs -l app=web
   ```

   ```
   deployment.apps/web image updated
   deployment.apps/web annotated
   Waiting for deployment "web" rollout to finish: 2 out of 3 new replicas have been updated...
   deployment "web" successfully rolled out

   NAME             DESIRED   CURRENT   READY   AGE
   web-58f6c4d9c7   3         3         3       48s
   web-7d9c8b6f45   0         0         0       6m
   ```

6. Leé y usá el historial de revisiones:

   ```bash
   kubectl rollout history deployment/web
   kubectl rollout history deployment/web --revision=2
   ```

   ```
   deployment.apps/web
   REVISION  CHANGE-CAUSE
   1         <none>
   2         CVE patch: nginx 1.27.4 -> 1.27.5
   ```

7. Rompé el rollout a propósito y mirá cómo se detiene en lugar de destruir capacidad:

   ```bash
   kubectl set image deployment/web nginx=nginx:1.27.5-alpin   # typo: no 'e'
   kubectl rollout status deployment/web --timeout=45s
   kubectl get pods -l app=web
   ```

   ```
   deployment.apps/web image updated
   Waiting for deployment "web" rollout to finish: 1 out of 3 new replicas have been updated...
   error: timed out waiting for the condition

   NAME                   READY   STATUS             RESTARTS   AGE
   web-58f6c4d9c7-7bqhr   1/1     Running            0          3m
   web-58f6c4d9c7-h4z9m   1/1     Running            0          3m
   web-58f6c4d9c7-m2xkd   1/1     Running            0          3m
   web-6f4b9dd58c-nkw8t   0/1     ImagePullBackOff   0          46s
   ```

8. Hacé rollback, y después verificá:

   ```bash
   kubectl rollout undo deployment/web
   kubectl rollout status deployment/web
   kubectl get deploy web -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
   ```

   ```
   deployment.apps/web rolled back
   deployment "web" successfully rolled out
   nginx:1.27.5-alpine
   ```

9. Pausá un Deployment para agrupar varias ediciones en un solo rollout:

   ```bash
   kubectl rollout pause deployment/web
   kubectl set image deployment/web nginx=nginx:1.27.4-alpine
   kubectl set resources deployment/web -c nginx --limits=memory=192Mi
   kubectl get rs -l app=web --no-headers | wc -l
   kubectl rollout resume deployment/web
   kubectl rollout status deployment/web
   ```

   ```
   deployment.apps/web paused
   deployment.apps/web image updated
   deployment.apps/web resource requirements updated
   3
   deployment.apps/web resumed
   deployment "web" successfully rolled out
   ```

10. Borrá el ReplicaSet activo y observá la respuesta del controlador:

    ```bash
    RS=$(kubectl get rs -l app=web -o jsonpath='{range .items[?(@.spec.replicas>0)]}{.metadata.name}{end}')
    kubectl delete rs "$RS"
    sleep 5
    kubectl get rs,pods -l app=web
    ```

    ```
    replicaset.apps "web-7d9c8b6f45" deleted
    NAME                            DESIRED   CURRENT   READY   AGE
    replicaset.apps/web-7d9c8b6f45  3         3         2       6s

    NAME                       READY   STATUS    RESTARTS   AGE
    pod/web-7d9c8b6f45-6dlzs   1/1     Running   0          6s
    pod/web-7d9c8b6f45-c8m4v   1/1     Running   0          6s
    pod/web-7d9c8b6f45-qq7pn   0/1     Running   0          6s
    ```

11. Ahora hacelo de forma no destructiva, con orphaning:

    ```bash
    RS=$(kubectl get rs -l app=web -o jsonpath='{range .items[?(@.spec.replicas>0)]}{.metadata.name}{end}')
    kubectl delete rs "$RS" --cascade=orphan
    sleep 5
    kubectl get rs,pods -l app=web
    ```

    ```
    replicaset.apps "web-7d9c8b6f45" deleted
    NAME                            DESIRED   CURRENT   READY   AGE
    replicaset.apps/web-7d9c8b6f45  3         3         3       4s

    NAME                       READY   STATUS    RESTARTS   AGE
    pod/web-7d9c8b6f45-6dlzs   1/1     Running   0          2m14s
    pod/web-7d9c8b6f45-c8m4v   1/1     Running   0          2m14s
    pod/web-7d9c8b6f45-qq7pn   1/1     Running   0          2m14s
    ```

**Preguntas de control**

- **Q4.1** — ¿Qué es `pod-template-hash`, quién lo computa, y qué dos objetos lo llevan? ¿Qué se rompería si el controlador de Deployment no lo agregara al selector del ReplicaSet?
- **Q4.2** — En el paso 7 el rollout se detuvo con un Pod roto y tres sanos. ¿Qué dos campos del manifiesto produjeron exactamente ese comportamiento, y qué habría pasado con `maxUnavailable: 1`?
- **Q4.3** — La revisión 1 muestra `CHANGE-CAUSE: <none>`. ¿De dónde sale esa columna, y por qué `kubectl annotate` en el paso 5 la pobló para la revisión 2?
- **Q4.4** — `kubectl rollout undo` no borra el ReplicaSet actual. Describí mecánicamente qué cambia, y predecí los números de revisión en `rollout history` después.
- **Q4.5** — Compará los resultados de los pasos 10 y 11. En el paso 11 no se crearon Pods nuevos aunque el objeto ReplicaSet fue borrado — explicá el mecanismo de adopción que lo hizo posible.
- **Q4.6** — En el manifiesto está fijado `revisionHistoryLimit: 5`. ¿Cuál es el valor por defecto, qué se retiene, y cuál es el costo operativo de ponerlo en `0`?
- **Q4.7** — El paso 4 escaló a 5 réplicas de forma imperativa mientras `02-deploy.yaml` sigue diciendo `replicas: 3`. ¿Qué pasa la próxima vez que CI ejecute `kubectl apply -f 02-deploy.yaml`, y cómo harías que el Deployment sea seguro de co-gestionar con un HorizontalPodAutoscaler?

---

## Ejercicio 5 — Services, EndpointSlices y DNS del clúster

**Pasos**

1. Exponé el Deployment con un Service ClusterIP, escrito de forma declarativa:

   ```yaml
   # 03-svc.yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: web
     namespace: ops-lab
   spec:
     type: ClusterIP
     selector:
       app: web
     ports:
       - name: http
         port: 8080          # the Service port
         targetPort: http    # the *named* container port
         protocol: TCP
   ```

   ```bash
   kubectl apply -f 03-svc.yaml
   kubectl get svc web
   ```

   ```
   service/web created
   NAME   TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
   web    ClusterIP   10.96.183.24    <none>        8080/TCP   3s
   ```

2. Inspeccioná a qué resolvió realmente el Service:

   ```bash
   kubectl get endpointslices -l kubernetes.io/service-name=web
   kubectl get endpointslice -l kubernetes.io/service-name=web \
     -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"\t"}{.conditions.ready}{"\t"}{.targetRef.name}{"\n"}{end}'
   ```

   ```
   NAME        ADDRESSTYPE   PORTS   ENDPOINTS                          AGE
   web-lq2f7   IPv4          80      10.244.1.7,10.244.2.6,10.244.1.8   40s

   10.244.1.7   true   web-7d9c8b6f45-6dlzs
   10.244.2.6   true   web-7d9c8b6f45-c8m4v
   10.244.1.8   true   web-7d9c8b6f45-qq7pn
   ```

3. Consumilo desde adentro del clúster, por DNS:

   ```bash
   kubectl run tmp --rm -it --image=busybox:1.36 --restart=Never -- sh
   ```

   ```sh
   / # nslookup web
   Server:    10.96.0.10
   Address:   10.96.0.10:53
   Name:      web.ops-lab.svc.cluster.local
   Address:   10.96.183.24

   / # wget -qO- http://web:8080 | head -4
   <!DOCTYPE html>
   <html>
   <head>
   <title>Welcome to nginx!</title>

   / # cat /etc/resolv.conf
   search ops-lab.svc.cluster.local svc.cluster.local cluster.local
   nameserver 10.96.0.10
   options ndots:5

   / # wget -qO- http://web.ops-lab.svc.cluster.local:8080 -O /dev/null && echo FQDN-OK
   FQDN-OK
   / # exit
   ```

4. Agregá un Service headless sobre los mismos Pods y compará la respuesta DNS:

   ```yaml
   # 04-svc-headless.yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: web-headless
     namespace: ops-lab
   spec:
     clusterIP: None
     selector:
       app: web
     ports:
       - name: http
         port: 80
         targetPort: http
   ```

   ```bash
   kubectl apply -f 04-svc-headless.yaml
   kubectl run tmp --rm -it --image=busybox:1.36 --restart=Never -- \
     nslookup web-headless.ops-lab.svc.cluster.local
   ```

   ```
   Name:      web-headless.ops-lab.svc.cluster.local
   Address 1: 10.244.1.7 10-244-1-7.web-headless.ops-lab.svc.cluster.local
   Address 2: 10.244.1.8 10-244-1-8.web-headless.ops-lab.svc.cluster.local
   Address 3: 10.244.2.6 10-244-2-6.web-headless.ops-lab.svc.cluster.local
   ```

5. Publicá externamente con un NodePort en el puerto que mapeaste en el Ejercicio 0:

   ```bash
   kubectl patch svc web -p '{"spec":{"type":"NodePort","ports":[{"name":"http","port":8080,"targetPort":"http","nodePort":30080}]}}'
   kubectl get svc web
   curl -s -o /dev/null -w '%{http_code}\n' http://localhost:30080
   ```

   ```
   service/web patched
   NAME   TYPE       CLUSTER-IP     EXTERNAL-IP   PORT(S)          AGE
   web    NodePort   10.96.183.24   <none>        8080:30080/TCP   6m
   200
   ```

6. Rompé el selector y mirá cómo se evaporan los endpoints:

   ```bash
   kubectl patch svc web -p '{"spec":{"selector":{"app":"web-typo"}}}'
   kubectl get endpointslice -l kubernetes.io/service-name=web
   curl -s -m 5 -o /dev/null -w '%{http_code}\n' http://localhost:30080 || echo "connection failed"
   kubectl patch svc web -p '{"spec":{"selector":{"app":"web"}}}'
   ```

   ```
   NAME        ADDRESSTYPE   PORTS   ENDPOINTS   AGE
   web-lq2f7   IPv4          <unset> <unset>     7m
   000
   connection failed
   service/web patched
   ```

7. Alcanzá un solo Pod sin ningún Service:

   ```bash
   POD=$(kubectl get pod -l app=web -o name | head -1)
   kubectl port-forward "$POD" 8888:80 &
   sleep 2
   curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8888
   kill %1
   ```

   ```
   Forwarding from 127.0.0.1:8888 -> 80
   Handling connection for 8888
   200
   ```

**Preguntas de control**

- **Q5.1** — `targetPort: http` es un string, no un número. ¿Dónde está definido ese nombre, y qué se rompe si renombrás el puerto del contenedor pero no el Service?
- **Q5.2** — Trazá el camino completo de `wget http://web:8080` desde adentro del Pod `tmp`: qué sufijo DNS coincidió primero (y por qué importa `ndots:5`), qué componente reescribió la IP de destino, y qué dirección llevó finalmente el paquete.
- **Q5.3** — ¿Cuál es la diferencia entre el objeto legacy `Endpoints` y `EndpointSlice`, y qué problema resolvió la API más nueva?
- **Q5.4** — Un Service headless devolvió IPs de Pods en lugar de una única IP virtual. Nombrá un tipo de carga de trabajo donde eso es exactamente lo que querés, y explicá por qué un ClusterIP estaría mal ahí.
- **Q5.5** — ¿Qué rango de puertos puede usar `nodePort` por defecto, y qué habría pasado en el paso 5 si hubieras pedido `nodePort: 8080`?
- **Q5.6** — En el paso 6 el Service seguía teniendo un `CLUSTER-IP` y el NodePort seguía asignado, y aun así las conexiones fallaron. Explicá en términos del controlador de EndpointSlice y de kube-proxy qué le hace "sin endpoints" al tráfico.
- **Q5.7** — `kubectl port-forward` funcionó sin Service y sin NodePort. ¿Qué componente hizo de proxy en esa conexión, y por qué esto la convierte en una herramienta de depuración y no en un mecanismo de exposición?

---

## Ejercicio 6 — ConfigMaps y Secrets

**Pasos**

1. Creá un ConfigMap de tres maneras e inspeccioná las claves resultantes:

   ```bash
   printf 'server.port=8080\nserver.mode=production\n' > app.properties
   kubectl create configmap web-config \
     --from-literal=LOG_LEVEL=info \
     --from-literal=GREETING='hello from ops-lab' \
     --from-file=app.properties
   kubectl get configmap web-config -o yaml
   ```

   ```yaml
   apiVersion: v1
   data:
     GREETING: hello from ops-lab
     LOG_LEVEL: info
     app.properties: |
       server.port=8080
       server.mode=production
   kind: ConfigMap
   metadata:
     name: web-config
     namespace: ops-lab
   ```

2. Creá un Secret y mirá de cerca cómo se almacena:

   ```bash
   kubectl create secret generic web-secret \
     --from-literal=DB_PASSWORD='s3cr3t-p@ss' \
     --from-literal=API_TOKEN='tok_live_9f3a'
   kubectl get secret web-secret -o yaml | sed -n '1,10p'
   kubectl get secret web-secret -o jsonpath='{.data.DB_PASSWORD}' | base64 -d; echo
   ```

   ```yaml
   apiVersion: v1
   data:
     API_TOKEN: dG9rX2xpdmVfOWYzYQ==
     DB_PASSWORD: czNjcjN0LXBAc3M=
   kind: Secret
   metadata:
     name: web-secret
     namespace: ops-lab
   type: Opaque
   ```
   ```
   s3cr3t-p@ss
   ```

3. Consumí ambos, como variables de entorno *y* como volumen proyectado:

   ```yaml
   # 05-consumer.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: consumer
     namespace: ops-lab
   spec:
     replicas: 1
     selector:
       matchLabels:
         app: consumer
     template:
       metadata:
         labels:
           app: consumer
       spec:
         containers:
           - name: shell
             image: busybox:1.36
             command: ["sh", "-c", "while true; do sleep 30; done"]
             env:
               - name: LOG_LEVEL                     # one explicit key
                 valueFrom:
                   configMapKeyRef:
                     name: web-config
                     key: LOG_LEVEL
               - name: DB_PASSWORD
                 valueFrom:
                   secretKeyRef:
                     name: web-secret
                     key: DB_PASSWORD
             envFrom:
               - configMapRef:                       # every key, as-is
                   name: web-config
                   optional: true
             volumeMounts:
               - name: config
                 mountPath: /etc/app
                 readOnly: true
               - name: creds
                 mountPath: /etc/creds
                 readOnly: true
             resources:
               requests: {cpu: 10m, memory: 16Mi}
               limits:   {cpu: 100m, memory: 64Mi}
         volumes:
           - name: config
             configMap:
               name: web-config
               items:
                 - key: app.properties
                   path: app.properties
           - name: creds
             secret:
               secretName: web-secret
               defaultMode: 0400
   ```

   ```bash
   kubectl apply -f 05-consumer.yaml
   kubectl rollout status deploy/consumer
   POD=$(kubectl get pod -l app=consumer -o jsonpath='{.items[0].metadata.name}')
   kubectl exec "$POD" -- env | grep -E 'LOG_LEVEL|GREETING|DB_PASSWORD'
   kubectl exec "$POD" -- sh -c 'ls -l /etc/app /etc/creds; cat /etc/app/app.properties'
   ```

   ```
   LOG_LEVEL=info
   GREETING=hello from ops-lab
   DB_PASSWORD=s3cr3t-p@ss

   /etc/app:
   lrwxrwxrwx    1 root root   21 Sep  3 12:41 app.properties -> ..data/app.properties
   /etc/creds:
   lrwxrwxrwx    1 root root   18 Sep  3 12:41 API_TOKEN -> ..data/API_TOKEN
   lrwxrwxrwx    1 root root   20 Sep  3 12:41 DB_PASSWORD -> ..data/DB_PASSWORD
   server.port=8080
   server.mode=production
   ```

4. Cambiá el ConfigMap y medí qué se actualiza y qué no:

   ```bash
   kubectl patch configmap web-config \
     --type merge -p '{"data":{"LOG_LEVEL":"debug","app.properties":"server.port=9090\nserver.mode=canary\n"}}'
   sleep 75
   kubectl exec "$POD" -- sh -c 'echo "ENV:  $LOG_LEVEL"; echo "FILE:"; cat /etc/app/app.properties'
   ```

   ```
   ENV:  info
   FILE:
   server.port=9090
   server.mode=canary
   ```

5. Forzá que las variables de entorno se refresquen de la única manera que funciona:

   ```bash
   kubectl rollout restart deployment/consumer
   kubectl rollout status deploy/consumer
   POD=$(kubectl get pod -l app=consumer -o jsonpath='{.items[0].metadata.name}')
   kubectl exec "$POD" -- printenv LOG_LEVEL
   ```

   ```
   deployment.apps/consumer restarted
   deployment "consumer" successfully rolled out
   debug
   ```

6. Hacé inmutable un ConfigMap y observá la reacción del API server:

   ```bash
   kubectl create configmap pinned --from-literal=VERSION=1.0.0
   kubectl patch configmap pinned -p '{"immutable":true}'
   kubectl patch configmap pinned --type merge -p '{"data":{"VERSION":"1.0.1"}}'
   ```

   ```
   configmap/pinned created
   configmap/pinned patched
   The ConfigMap "pinned" is invalid: data: Forbidden: field is immutable when `immutable` is set
   ```

7. Referenciá una clave que no existe, y mirá el modo de falla:

   ```bash
   kubectl set env deployment/consumer --from=configmap/missing-cm --prefix=X_
   kubectl get pods -l app=consumer
   kubectl describe pod -l app=consumer | grep -A3 'Events:'
   ```

   ```
   NAME                       READY   STATUS                       RESTARTS   AGE
   consumer-6b9f7c4d8-2hpvz   0/1     CreateContainerConfigError   0          18s

   Events:
     Type     Reason     Age   From       Message
     ----     ------     ----  ----       -------
     Warning  Failed     6s    kubelet    Error: configmap "missing-cm" not found
   ```

   ```bash
   kubectl rollout undo deployment/consumer
   ```

**Preguntas de control**

- **Q6.1** — Un colega dice que los Secrets están "encriptados". Corregí la afirmación con precisión: ¿qué le hace la API al valor, y qué tiene que configurar un administrador del clúster para que el cifrado en reposo sea real?
- **Q6.2** — Explicá la asimetría vista en el paso 4: el archivo montado cambió, la variable de entorno no. ¿Cuál es el mecanismo en cada caso, y aproximadamente cuánto es el peor caso de retardo de propagación para el volumen?
- **Q6.3** — ¿Qué habría pasado en el paso 4 si el volumen se hubiera montado con `subPath: app.properties` en lugar de vía `items`?
- **Q6.4** — ¿Para qué está el symlink `..data` en el directorio montado?
- **Q6.5** — Dá dos razones operativas para marcar un ConfigMap como `immutable: true`, y describí el procedimiento de actualización una vez que lo hiciste.
- **Q6.6** — Compará `env.valueFrom.configMapKeyRef` con `envFrom.configMapRef`. ¿Cuál es seguro frente a un ConfigMap que contiene una clave llamada `PATH`, y por qué?
- **Q6.7** — El Pod del paso 7 está en `CreateContainerConfigError`, no en `CrashLoopBackOff` ni en `Pending`. ¿Qué te dice esa distinción sobre *dónde* falló dentro del ciclo de vida del Pod?
- **Q6.8** — ¿Por qué listar Secrets con `kubectl get secret -o yaml` sigue contando como un evento de seguridad aunque el valor parezca revuelto? Nombrá el verbo RBAC que restringirías.

---

## Ejercicio 7 — Probes, resource requests y QoS

**Pasos**

1. Desplegá una carga de trabajo con los tres tipos de probe y un perfil de recursos explícito:

   ```yaml
   # 06-probes.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: health
     namespace: ops-lab
   spec:
     replicas: 2
     selector:
       matchLabels:
         app: health
     template:
       metadata:
         labels:
           app: health
       spec:
         containers:
           - name: nginx
             image: nginx:1.27.4-alpine
             ports:
               - name: http
                 containerPort: 80
             lifecycle:
               postStart:
                 exec:
                   command: ["sh", "-c", "echo ok > /usr/share/nginx/html/healthz"]
             startupProbe:
               httpGet: {path: /healthz, port: http}
               periodSeconds: 2
               failureThreshold: 30        # up to 60s to boot
             readinessProbe:
               httpGet: {path: /healthz, port: http}
               periodSeconds: 3
               failureThreshold: 2
             livenessProbe:
               httpGet: {path: /, port: http}
               periodSeconds: 5
               failureThreshold: 3
             resources:
               requests:
                 cpu: 50m
                 memory: 64Mi
               limits:
                 cpu: 50m
                 memory: 64Mi
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: health
     namespace: ops-lab
   spec:
     selector:
       app: health
     ports:
       - port: 80
         targetPort: http
   ```

   ```bash
   kubectl apply -f 06-probes.yaml
   kubectl rollout status deploy/health
   kubectl get endpointslice -l kubernetes.io/service-name=health \
     -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}={.conditions.ready}{"\n"}{end}'
   ```

   ```
   10.244.1.11=true
   10.244.2.9=true
   ```

2. Leé la clase de QoS que asignó el scheduler:

   ```bash
   kubectl get pods -l app=health \
     -o custom-columns='NAME:.metadata.name,QOS:.status.qosClass,NODE:.spec.nodeName'
   kubectl get pod nginx-solo -o jsonpath='{.status.qosClass}{"\n"}'
   kubectl run bare --image=busybox:1.36 --restart=Never -- sleep 300
   kubectl get pod bare -o jsonpath='{.status.qosClass}{"\n"}'
   ```

   ```
   NAME                     QOS         NODE
   health-84c6d5b7f9-jr2wq  Guaranteed  lpi-703-worker
   health-84c6d5b7f9-x8t4b  Guaranteed  lpi-703-worker2
   Burstable
   BestEffort
   ```

3. Hacé fallar *solo la readiness*, y mirá cómo desaparece el endpoint mientras el contenedor sigue corriendo:

   ```bash
   POD=$(kubectl get pod -l app=health -o jsonpath='{.items[0].metadata.name}')
   kubectl exec "$POD" -- rm /usr/share/nginx/html/healthz
   sleep 10
   kubectl get pod "$POD"
   kubectl get endpointslice -l kubernetes.io/service-name=health \
     -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}={.conditions.ready}{"\n"}{end}'
   kubectl describe pod "$POD" | grep -A2 'Readiness'
   ```

   ```
   NAME                      READY   STATUS    RESTARTS   AGE
   health-84c6d5b7f9-jr2wq   0/1     Running   0          3m

   10.244.1.11=false
   10.244.2.9=true

   Readiness probe failed: HTTP probe failed with statuscode: 404
   ```

4. Restaurá la readiness:

   ```bash
   kubectl exec "$POD" -- sh -c 'echo ok > /usr/share/nginx/html/healthz'
   sleep 8
   kubectl get pod "$POD"
   ```

   ```
   NAME                      READY   STATUS    RESTARTS   AGE
   health-84c6d5b7f9-jr2wq   1/1     Running   0          4m
   ```

5. Ahora hacé fallar la *liveness* y compará la consecuencia:

   ```bash
   kubectl exec "$POD" -- sh -c 'mv /usr/share/nginx/html/index.html /tmp/'
   sleep 30
   kubectl get pod "$POD"
   kubectl describe pod "$POD" | grep -E 'Restart Count|Last State|Reason|Liveness probe failed' | head
   ```

   ```
   NAME                      READY   STATUS    RESTARTS      AGE
   health-84c6d5b7f9-jr2wq   1/1     Running   1 (12s ago)   5m

   Last State:     Terminated
     Reason:       Error
     Exit Code:    137
   Restart Count:  1
   Warning  Unhealthy  35s  kubelet  Liveness probe failed: HTTP probe failed with statuscode: 403
   ```

6. Excedé un límite de memoria y leé el veredicto del kernel:

   ```yaml
   # 07-oom.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: memory-hog
     namespace: ops-lab
   spec:
     containers:
       - name: stress
         image: polinux/stress
         command: ["stress"]
         args: ["--vm", "1", "--vm-bytes", "250M", "--vm-hang", "1"]
         resources:
           requests:
             memory: 50Mi
           limits:
             memory: 100Mi
   ```

   ```bash
   kubectl apply -f 07-oom.yaml
   sleep 20
   kubectl get pod memory-hog
   kubectl describe pod memory-hog | grep -E 'Reason|Exit Code|Restart Count'
   ```

   ```
   NAME         READY   STATUS             RESTARTS      AGE
   memory-hog   0/1     CrashLoopBackOff   2 (14s ago)   38s

       Reason:       OOMKilled
       Exit Code:    137
   Restart Count:    2
   ```

7. Intentá agendar algo que el clúster no puede satisfacer:

   ```bash
   kubectl run too-big --image=nginx:1.27.4-alpine \
     --overrides='{"spec":{"containers":[{"name":"nginx","image":"nginx:1.27.4-alpine","resources":{"requests":{"memory":"64Gi"}}}]}}'
   sleep 5
   kubectl get pod too-big
   kubectl describe pod too-big | sed -n '/Events:/,$p'
   ```

   ```
   NAME      READY   STATUS    RESTARTS   AGE
   too-big   0/1     Pending   0          6s

   Events:
     Type     Reason            Age   From               Message
     ----     ------            ----  ----               -------
     Warning  FailedScheduling  5s    default-scheduler  0/3 nodes are available: 1 node(s) had untolerated taint
       {node-role.kubernetes.io/control-plane: }, 2 Insufficient memory. preemption: 0/3 nodes are available:
       1 Preemption is not helpful for scheduling, 2 No preemption victims found for incoming pod.
   ```

   ```bash
   kubectl delete pod too-big memory-hog bare --now
   ```

**Preguntas de control**

- **Q7.1** — Enunciá la consecuencia de una readiness probe fallida y de una liveness probe fallida, en una oración cada una, refiriéndote a lo que observaste en los pasos 3 y 5.
- **Q7.2** — ¿Por qué existe siquiera una `startupProbe`, dado que `initialDelaySeconds` en la liveness probe podría demorar la primera verificación? ¿Qué modo de falla previene en una aplicación JVM de arranque lento?
- **Q7.3** — Derivá la clase de QoS de cada uno de estos y justificá: (a) `requests.cpu=100m, limits.cpu=100m, requests.memory=128Mi, limits.memory=128Mi`; (b) solo `limits.memory=128Mi`; (c) nada especificado; (d) dos contenedores, uno Guaranteed y uno Burstable.
- **Q7.4** — Bajo presión de memoria del nodo, ¿en qué orden desaloja el kubelet los Pods según la clase de QoS, y dónde se ubica en ese orden un Pod Burstable que está *por debajo* de su request?
- **Q7.5** — El exit code 137 apareció dos veces, con `Reason: Error` en el paso 5 y `Reason: OOMKilled` en el paso 6. ¿En qué se descompone 137, y qué distingue a los dos casos?
- **Q7.6** — En el paso 7 el scheduler reportó "2 Insufficient memory" mientras los nodos tenían RAM libre. ¿Contra qué número está comparando realmente el scheduler, y por qué la moneda de scheduling son los `requests` y no los `limits`?
- **Q7.7** — Ambos contenedores del Deployment `health` son `Guaranteed`. Si fijaras solo `limits` y omitieras `requests` por completo, ¿cuál sería la clase de QoS y por qué?

---

## Ejercicio 8 — El ciclo de diagnóstico

Este es el ejercicio que se paga solo. Practicá la secuencia hasta que sea memoria muscular: **get → describe → events → logs → exec/debug**.

**Pasos**

1. Fabricá una falla de imagen:

   ```bash
   kubectl create deployment broken --image=nginx:does-not-exist
   sleep 20
   kubectl get pods -l app=broken
   kubectl describe pod -l app=broken | sed -n '/Events:/,$p'
   ```

   ```
   NAME                       READY   STATUS             RESTARTS   AGE
   broken-6d8c47f5b9-lm4zc    0/1     ImagePullBackOff   0          21s

   Events:
     Type     Reason     Age                From               Message
     ----     ------     ----               ----               -------
     Normal   Scheduled  21s                default-scheduler  Successfully assigned ops-lab/broken-...
     Normal   Pulling    20s                kubelet            Pulling image "nginx:does-not-exist"
     Warning  Failed     18s                kubelet            Failed to pull image "nginx:does-not-exist":
       failed to resolve reference "docker.io/library/nginx:does-not-exist": docker.io/library/nginx:does-not-exist:
       not found
     Warning  Failed     18s                kubelet            Error: ErrImagePull
     Normal   BackOff    5s (x2 over 17s)   kubelet            Back-off pulling image "nginx:does-not-exist"
     Warning  Failed     5s                 kubelet            Error: ImagePullBackOff
   ```

2. Fabricá un crash loop, y después leé los logs del contenedor *anterior*:

   ```bash
   kubectl run crasher --image=busybox:1.36 --restart=Always -- \
     sh -c 'echo "starting up"; sleep 5; echo "fatal: config missing" >&2; exit 1'
   sleep 45
   kubectl get pod crasher
   kubectl logs crasher
   kubectl logs crasher --previous
   ```

   ```
   NAME      READY   STATUS             RESTARTS      AGE
   crasher   0/1     CrashLoopBackOff   3 (18s ago)   47s

   starting up
   fatal: config missing

   starting up
   fatal: config missing
   ```

3. Leé la progresión del backoff en los eventos:

   ```bash
   kubectl get events --field-selector involvedObject.name=crasher --sort-by=.lastTimestamp | tail -6
   ```

   ```
   LAST SEEN   TYPE      REASON      OBJECT        MESSAGE
   62s         Normal    Created     pod/crasher   Created container: crasher
   62s         Normal    Started     pod/crasher   Started container crasher
   35s         Warning   BackOff     pod/crasher   Back-off restarting failed container crasher in pod crasher_ops-lab(...)
   ```

4. Agregá logs de todo un Deployment, con flags útiles:

   ```bash
   kubectl logs -l app=web --all-containers --prefix --tail=3 --timestamps
   kubectl logs deploy/web --since=5m | tail -3
   kubectl logs -f deploy/web --max-log-requests=6 &   # streaming; Ctrl-C or kill to stop
   sleep 3; kill %1
   ```

   ```
   [pod/web-7d9c8b6f45-6dlzs/nginx] 2026-09-03T12:58:11.104Z 10.244.0.5 - - [03/Sep/2026:12:58:11 +0000] "GET / HTTP/1.1" 200 615 "-" "Wget"
   ```

5. Conseguí una shell en un contenedor en ejecución, y entendé sus límites:

   ```bash
   POD=$(kubectl get pod -l app=web -o jsonpath='{.items[0].metadata.name}')
   kubectl exec -it "$POD" -c nginx -- sh -c 'id; nginx -v; ls /usr/share/nginx/html'
   ```

   ```
   uid=0(root) gid=0(root) groups=0(root),...
   nginx version: nginx/1.27.4
   50x.html  index.html
   ```

6. Adjuntá un contenedor de depuración a un Pod cuya imagen no tiene herramientas de shell:

   ```bash
   kubectl debug -it "$POD" --image=busybox:1.36 --target=nginx -- sh
   ```

   ```sh
   Defaulting debug container name to debugger-7zqm4.
   / # ps aux | head -4
   PID   USER     TIME  COMMAND
       1 root      0:00 nginx: master process nginx -g daemon off;
      29 101       0:00 nginx: worker process
       1 root      0:00 sh
   / # wget -qO- http://localhost:80 | head -2
   <!DOCTYPE html>
   <html>
   / # exit
   ```

   ```bash
   kubectl get pod "$POD" -o jsonpath='{range .spec.ephemeralContainers[*]}{.name}{"\t"}{.image}{"\n"}{end}'
   ```

   ```
   debugger-7zqm4   busybox:1.36
   ```

7. Copiá un archivo desde un contenedor e inspeccioná el uso de recursos:

   ```bash
   kubectl cp "$POD:/etc/nginx/nginx.conf" ./nginx.conf -c nginx
   head -3 ./nginx.conf
   kubectl top pods 2>&1 | head -3
   ```

   ```
   user  nginx;
   worker_processes  auto;

   error: Metrics API not available
   ```

8. Limpiá las fallas deliberadas:

   ```bash
   kubectl delete deploy broken --now
   kubectl delete pod crasher --now
   ```

**Preguntas de control**

- **Q8.1** — Distinguí `ErrImagePull` de `ImagePullBackOff`. ¿Cuál te dice que el kubelet dejó de reintentar a máxima velocidad, y cuál es el comportamiento del backoff?
- **Q8.2** — ¿Por qué `kubectl logs crasher` funcionó en el paso 2 aunque el contenedor no estaba corriendo en ese momento? ¿Qué devuelve exactamente `--previous`, y cuándo no está disponible?
- **Q8.3** — ¿Cuál es el intervalo máximo por defecto entre intentos de reinicio en `CrashLoopBackOff`, cómo se llega a él, y qué lo resetea?
- **Q8.4** — `kubectl logs deploy/web` imprimió logs de un Pod, no de tres, salvo que agregaras un selector. Explicá a qué resuelve realmente `kubectl logs deploy/...`, y la forma correcta de seguir todas las réplicas.
- **Q8.5** — En el paso 6, `ps` dentro del contenedor de depuración listó el proceso master de nginx. ¿Qué flag causó eso, y qué habrías visto sin él?
- **Q8.6** — ¿Podés quitar un contenedor efímero de un Pod en ejecución? ¿Cuál es la consecuencia sobre el ciclo de vida de usar `kubectl debug` en un Pod de producción?
- **Q8.7** — `kubectl top pods` falló. ¿Qué falta y — lo importante — esa falla afecta al scheduler, al HorizontalPodAutoscaler, o a ambos?
- **Q8.8** — Te entregan un Pod atascado en `Pending` sin ningún evento. Enumerá, en orden, las tres verificaciones que harías y qué distinguiría cada una.

---

## Ejercicio 9 — Gestión declarativa: apply, deriva y Server-Side Apply

**Pasos**

1. Establecé una línea base y confirmá la annotation que deja el apply del lado del cliente:

   ```bash
   kubectl apply -f 02-deploy.yaml
   kubectl get deploy web \
     -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}' \
     | head -c 120; echo
   ```

   ```
   {"apiVersion":"apps/v1","kind":"Deployment","metadata":{"annotations":{},"labels":{"app":"web"},"name":"web","na
   ```

2. Introducí deriva de forma imperativa, y después previsualizá qué haría un re-apply:

   ```bash
   kubectl scale deploy/web --replicas=6
   kubectl label deploy web owner=sre                 # a field the manifest never mentions
   kubectl diff -f 02-deploy.yaml
   ```

   ```diff
   diff -u -N /tmp/LIVE-.../apps.v1.Deployment.ops-lab.web /tmp/MERGED-.../apps.v1.Deployment.ops-lab.web
   --- LIVE
   +++ MERGED
   @@ -6,6 +6,7 @@
      labels:
        app: web
   -    owner: sre
      name: web
   @@ -14,7 +15,7 @@
    spec:
   -  replicas: 6
   +  replicas: 3
   ```

3. Re-aplicá y confirmá qué deriva sobrevivió:

   ```bash
   kubectl apply -f 02-deploy.yaml
   kubectl get deploy web -o jsonpath='replicas={.spec.replicas} owner={.metadata.labels.owner}{"\n"}'
   ```

   ```
   deployment.apps/web configured
   replicas=3 owner=sre
   ```

4. Demostrá que quitar un campo del manifiesto lo borra del objeto vivo:

   ```bash
   kubectl apply -f 02-deploy.yaml     # manifest has revisionHistoryLimit: 5
   sed -i '/revisionHistoryLimit/d' 02-deploy.yaml
   kubectl apply -f 02-deploy.yaml
   kubectl get deploy web -o jsonpath='{.spec.revisionHistoryLimit}{"\n"}'
   ```

   ```
   deployment.apps/web configured
   10
   ```

5. Pasá a Server-Side Apply e inspeccioná el libro mayor de propiedad:

   ```bash
   kubectl apply -f 02-deploy.yaml --server-side --field-manager=platform-ci
   kubectl get deploy web --show-managed-fields -o json \
     | jq -r '.metadata.managedFields[] | "\(.manager)\t\(.operation)\t\(.subresource // "-")"'
   ```

   ```
   deployment.apps/web serverside-applied
   kubectl-client-side-apply   Update   -
   platform-ci                 Apply    -
   kube-controller-manager     Update   status
   ```

6. Creá un conflicto a propósito:

   ```bash
   kubectl patch deploy web --field-manager=hotfix-operator --type merge -p '{"spec":{"replicas":8}}'
   kubectl apply -f 02-deploy.yaml --server-side --field-manager=platform-ci
   ```

   ```
   deployment.apps/web patched
   error: Apply failed with 1 conflict: conflict with "hotfix-operator" using apps/v1:
     .spec.replicas
   Please review the fields above--they currently have conflicting field ownership...
   ```

7. Resolvelo deliberadamente:

   ```bash
   kubectl apply -f 02-deploy.yaml --server-side --field-manager=platform-ci --force-conflicts
   kubectl get deploy web -o jsonpath='{.spec.replicas}{"\n"}'
   ```

   ```
   deployment.apps/web serverside-applied
   3
   ```

8. Ensamblá los mismos objetos con el soporte de kustomize integrado en kubectl:

   ```yaml
   # kustomization.yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   namespace: ops-lab
   commonLabels:
     managed-by: kustomize
   resources:
     - 02-deploy.yaml
     - 03-svc.yaml
   images:
     - name: nginx
       newTag: 1.27.5-alpine
   ```

   ```bash
   kubectl kustomize . | grep -E 'image:|managed-by' | head
   kubectl apply -k .
   ```

   ```
       managed-by: kustomize
         image: nginx:1.27.5-alpine
   deployment.apps/web configured
   service/web configured
   ```

**Preguntas de control**

- **Q9.1** — El apply del lado del cliente hace un merge *de tres vías*. Nombrá las tres entradas y decí cuál se almacena en la annotation `last-applied-configuration`.
- **Q9.2** — En el paso 3, `replicas` fue revertido pero la label `owner=sre` sobrevivió. Explicá por qué, usando las tres entradas de Q9.1.
- **Q9.3** — El paso 4 muestra que `revisionHistoryLimit` vuelve a `10` después de ser eliminado del archivo. ¿Habría pasado lo mismo si el campo se hubiera fijado con `kubectl patch` en lugar de haber sido aplicado antes? ¿Por qué?
- **Q9.4** — ¿Qué problema resuelve Server-Side Apply que la annotation `last-applied-configuration` no podía? Nombrá dos desventajas concretas del enfoque de la annotation.
- **Q9.5** — `--force-conflicts` arregló el error en el paso 7. Describí qué le hizo al registro de propiedad de `hotfix-operator`, y cuándo usarlo es la respuesta *equivocada*.
- **Q9.6** — Ejecutás un HorizontalPodAutoscaler sobre `web` y CI aplica un manifiesto que contiene `replicas: 3` cada diez minutos. Describí la falla, y dá el arreglo correcto tanto para flujos de trabajo de apply del lado del cliente como del lado del servidor.
- **Q9.7** — ¿Cuándo es genuinamente correcto `kubectl replace -f`, y qué hace que `apply` nunca hace?

---

## Ejercicio 10 — DaemonSets, Jobs y CronJobs

**Pasos**

1. Desplegá un agente a nivel de nodo:

   ```yaml
   # 08-daemonset.yaml
   apiVersion: apps/v1
   kind: DaemonSet
   metadata:
     name: node-agent
     namespace: ops-lab
   spec:
     selector:
       matchLabels:
         app: node-agent
     template:
       metadata:
         labels:
           app: node-agent
       spec:
         containers:
           - name: agent
             image: busybox:1.36
             command: ["sh", "-c", "while true; do echo \"$(date) heartbeat from $NODE\"; sleep 60; done"]
             env:
               - name: NODE
                 valueFrom:
                   fieldRef:
                     fieldPath: spec.nodeName
             resources:
               requests: {cpu: 10m, memory: 16Mi}
               limits:   {cpu: 50m, memory: 32Mi}
   ```

   ```bash
   kubectl apply -f 08-daemonset.yaml
   sleep 10
   kubectl get ds node-agent
   kubectl get pods -l app=node-agent -o wide --no-headers | awk '{print $1, $7}'
   ```

   ```
   NAME         DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
   node-agent   2         2         2       2            2           <none>          10s

   node-agent-4mfq7 lpi-703-worker
   node-agent-t9k2p lpi-703-worker2
   ```

2. Hacé que corra también en el control-plane, tolerando el taint:

   ```bash
   kubectl patch ds node-agent --type merge -p '{"spec":{"template":{"spec":{"tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]}}}}'
   sleep 10
   kubectl get ds node-agent
   ```

   ```
   NAME         DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
   node-agent   3         3         3       3            3           <none>          72s
   ```

3. Ejecutá un Job por lotes con paralelismo y un presupuesto de reintentos:

   ```yaml
   # 09-job.yaml
   apiVersion: batch/v1
   kind: Job
   metadata:
     name: digest
     namespace: ops-lab
   spec:
     completions: 6
     parallelism: 2
     backoffLimit: 3
     ttlSecondsAfterFinished: 300
     template:
       spec:
         restartPolicy: Never
         containers:
           - name: worker
             image: busybox:1.36
             command: ["sh", "-c", "echo processing shard $RANDOM; sleep 5"]
             resources:
               requests: {cpu: 10m, memory: 16Mi}
   ```

   ```bash
   kubectl apply -f 09-job.yaml
   kubectl get job digest -w &
   sleep 25; kill %1
   kubectl get pods -l job-name=digest --no-headers | awk '{print $1, $3}'
   ```

   ```
   NAME     STATUS     COMPLETIONS   DURATION   AGE
   digest   Running    0/6           2s         2s
   digest   Running    2/6           9s         9s
   digest   Running    4/6           16s        16s
   digest   Complete   6/6           23s        23s

   digest-2jx8p Completed
   digest-6vkzq Completed
   digest-9dt4m Completed
   digest-hcn7w Completed
   digest-mq5rl Completed
   digest-xw2fb Completed
   ```

4. Hacé fallar un Job y observá al `backoffLimit` haciendo su trabajo:

   ```bash
   kubectl create job doomed --image=busybox:1.36 -- sh -c 'exit 3'
   kubectl patch job doomed --type merge -p '{"spec":{"backoffLimit":2}}' 2>&1 | tail -1
   sleep 60
   kubectl get job doomed
   kubectl get pods -l job-name=doomed --no-headers | wc -l
   kubectl describe job doomed | grep -E 'Pods Statuses|Warning'
   ```

   ```
   NAME     STATUS   COMPLETIONS   DURATION   AGE
   doomed   Failed   0/1           58s        60s

   7
   Pods Statuses:  0 Active (0 Ready) / 0 Succeeded / 7 Failed
     Warning  BackoffLimitExceeded  4s   job-controller  Job has reached the specified backoff limit
   ```

5. Programá trabajo recurrente:

   ```bash
   kubectl create cronjob heartbeat \
     --image=busybox:1.36 \
     --schedule='*/1 * * * *' \
     -- /bin/sh -c 'date -Is; echo "cron tick ok"'
   kubectl get cronjob heartbeat
   sleep 130
   kubectl get jobs -l batch.kubernetes.io/cronjob-name=heartbeat
   kubectl logs job/$(kubectl get jobs -l batch.kubernetes.io/cronjob-name=heartbeat \
     -o jsonpath='{.items[0].metadata.name}')
   ```

   ```
   NAME        SCHEDULE      TIMEZONE   SUSPEND   ACTIVE   LAST SCHEDULE   AGE
   heartbeat   */1 * * * *   <none>     False     0        <none>          3s

   NAME                 STATUS     COMPLETIONS   DURATION   AGE
   heartbeat-29360281   Complete   1/1           4s         2m
   heartbeat-29360282   Complete   1/1           3s         62s

   2026-09-03T13:41:02+00:00
   cron tick ok
   ```

6. Disparar una ejecución fuera de banda, y suspender la programación:

   ```bash
   kubectl create job manual-run --from=cronjob/heartbeat
   kubectl patch cronjob heartbeat -p '{"spec":{"suspend":true}}'
   kubectl get cronjob heartbeat -o jsonpath='suspend={.spec.suspend}{"\n"}'
   ```

   ```
   job.batch/manual-run created
   cronjob.batch/heartbeat patched
   suspend=true
   ```

7. Inspeccioná las perillas de retención de historial:

   ```bash
   kubectl get cronjob heartbeat \
     -o jsonpath='{.spec.successfulJobsHistoryLimit}/{.spec.failedJobsHistoryLimit}/{.spec.concurrencyPolicy}{"\n"}'
   ```

   ```
   3/1/Allow
   ```

**Preguntas de control**

- **Q10.1** — En el paso 1 el DaemonSet reportó `DESIRED: 2` en un clúster de tres nodos, y `3` después del paso 2. Explicá qué computa `DESIRED` y por qué un DaemonSet no tiene campo `replicas`.
- **Q10.2** — ¿Cuál es la diferencia entre `completions` y `parallelism` de un Job? ¿Qué significa un Job con `completions` sin fijar pero `parallelism: 4`?
- **Q10.3** — ¿Qué valores de `restartPolicy` son legales en la plantilla de Pod de un Job, y cuál hace que `backoffLimit` cuente reinicios de *contenedor* en lugar de fallas de Pod?
- **Q10.4** — El paso 4 produjo 7 Pods fallidos contra `backoffLimit: 2`. Explicá la discrepancia — ¿qué hizo realmente el `kubectl patch` sobre un Job?
- **Q10.5** — ¿Para qué sirve `ttlSecondsAfterFinished`, y qué les pasa a los Pods y los logs del Job cuando se dispara?
- **Q10.6** — El controlador de un CronJob se perdió varias programaciones mientras el control plane estaba caído. ¿Qué determina si esas ejecuciones se hacen tarde o se saltean por completo, y qué es `startingDeadlineSeconds`?
- **Q10.7** — Compará los tres valores de `concurrencyPolicy` y dá una carga de trabajo que requiera cada uno.
- **Q10.8** — ¿Por qué `kubectl create job --from=cronjob/...` es preferible a copiar el manifiesto del Job a mano para una ejecución manual fuera de horario?

---

## Ejercicio 11 — Capstone

Hacé este sin consultar nada. Veinte minutos, un namespace, sin atajos imperativos salvo para generar manifiestos.

**Pasos**

1. Creá el namespace `capstone` y hacelo el namespace por defecto de tu contexto.
2. Escribí un único archivo YAML que contenga:
   - un ConfigMap `site` con una clave `index.html` cuyo valor sea `<h1>703.2 capstone</h1>`;
   - un Secret `site-auth` con `TOKEN=abc123`;
   - un Deployment `site` con 3 réplicas de `nginx:1.27.5-alpine`, montando el ConfigMap en `/usr/share/nginx/html`, exponiendo `TOKEN` como variable de entorno, con `requests == limits` (`50m` de CPU / `64Mi` de memoria), una readiness probe en `/`, y `maxUnavailable: 0`;
   - un Service ClusterIP `site` en el puerto `80` apuntando a un puerto de contenedor *nombrado*.
3. Aplicalo con `--server-side --field-manager=capstone`.
4. Verificá: 3 endpoints listos, la clase de QoS correcta, que el cuerpo servido coincida con el ConfigMap, y que la variable de entorno esté presente.
5. Rotá la imagen a `nginx:1.27.4-alpine`, anotá la causa del cambio, confirmá que existen dos ReplicaSets, después hacé rollback y confirmá la imagen.
6. Cambiá el `index.html` del ConfigMap, y lográ que el cambio sea servido por las tres réplicas — deliberadamente, no esperando.
7. Producí un reporte de una línea:

   ```bash
   kubectl get deploy site \
     -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image,READY:.status.readyReplicas,GEN:.metadata.generation'
   ```

**Preguntas de control**

- **Q11.1** — En el paso 6, ¿por qué `kubectl rollout restart` es el instrumento correcto en lugar de editar la imagen del Deployment o borrar Pods, y qué cambia en la plantilla de Pod para forzar el rollout?
- **Q11.2** — `.metadata.generation` y `.status.observedGeneration` difieren transitoriamente durante un rollout. ¿Cómo usarías ese par como verificación legible por máquina de "el rollout terminó" en un pipeline de CI, y qué usa `kubectl rollout status`?
- **Q11.3** — Con `maxUnavailable: 0` y `maxSurge` sin fijar (por defecto 25%), ¿cuántos Pods existen en el pico durante el rollout del paso 5 de 3 réplicas?

---

## Limpieza

```bash
kubectl config set-context --current --namespace=default
kubectl delete namespace ops-lab capstone --wait=false
kind delete cluster --name lpi-703
```

```
Context "kind-lpi-703" modified.
namespace "ops-lab" deleted
namespace "capstone" deleted
Deleting cluster "lpi-703" ...
Deleted nodes: ["lpi-703-control-plane" "lpi-703-worker" "lpi-703-worker2"]
```

---

<details>
<summary><strong>Clave de respuestas — clic para desplegar</strong></summary>

### Ejercicio 0

**A0.1** — No. La columna `ROLES` la renderiza kubectl a partir de las **labels** del Node que coinciden con `node-role.kubernetes.io/<role>` (más la legacy `kubernetes.io/role`). Los roles son una convención de etiquetado, no un campo de la API; nada en el control plane impone comportamiento en base a ellos. Lo que *sí* cambia el comportamiento es el taint (A0.2) y el hecho de que los componentes del control-plane corren ahí como static Pods.

**A0.2** — El taint `node-role.kubernetes.io/control-plane:NoSchedule` hace que el scheduler se niegue a ubicar cualquier Pod en ese nodo salvo que el Pod lleve una toleration coincidente. `NoSchedule` afecta solo al scheduling — los Pods que ya están corriendo no son desalojados (eso sería `NoExecute`). Un Pod aterriza ahí igualmente si su spec contiene, por ejemplo:

```yaml
tolerations:
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule
```

Eso es exactamente lo que agregó el paso 2 del Ejercicio 10, y por eso `DESIRED` pasó de 2 a 3.

**A0.3** — kubectl embebe kustomize como biblioteca para que `kubectl apply -k` / `kubectl kustomize` funcionen sin binario extra. La versión se reporta porque el kustomize vendorizado va atrás del release standalone: un `kustomization.yaml` que use un transformer más nuevo puede fallar contra el vendorizado, y conocer el número te dice si conviene instalar el `kustomize` standalone.

### Ejercicio 1

**A1.1** — Precedencia: (1) el flag `--kubeconfig`; (2) la variable de entorno `KUBECONFIG`, que puede ser una *lista* separada por dos puntos que se fusiona, ganando el primer archivo por clave; (3) `$HOME/.kube/config`. Para un solo comando: `kubectl --kubeconfig=/path/to/other.yaml get pods`, o `KUBECONFIG=/path/to/other.yaml kubectl get pods`. Usá `kubectl config use-context` / `--context <name>` para cambiar de contexto dentro de un mismo archivo.

**A1.2** — `api-versions` lista solo strings grupo/versión (`apps/v1`, `batch/v1`, `discovery.k8s.io/v1`). `api-resources` lista los *recursos* servidos por esos grupos, con kind, nombres cortos, flag de namespaced y verbos permitidos. Para encontrar un CRD llamado `Certificate` y su nombre corto necesitás `api-resources` (por ejemplo `kubectl api-resources | grep -i certificate` → `certificates cert cert-manager.io/v1 true Certificate`). Ambos se sirven desde los endpoints de discovery (`/api`, `/apis`) y reflejan *este* clúster, incluyendo CRDs y APIs agregadas.

**A1.3** — `kubectl explain` lee el esquema OpenAPI publicado por el API server al que estás conectado. Por lo tanto describe las versiones exactas instaladas ahí, incluyendo CRDs provistos por operadores que no tienen ninguna documentación upstream, y no te va a mostrar campos que se agregaron en un release más nuevo que el que corre el clúster. La documentación pública describe *una* versión; `explain` describe *la tuya*.

**A1.4** — La identidad del contexto activo del kubeconfig (columna `AUTHINFO`) — para kind, un certificado de cliente cluster-admin, de ahí el `yes` generalizado. Para verificar otro sujeto lo impersonás: `kubectl auth can-i list secrets --as=system:serviceaccount:ops-lab:default -n ops-lab`, o `--as-group=`. La impersonación en sí requiere el verbo `impersonate`, que cluster-admin tiene.

### Ejercicio 2

**A2.1** — `--dry-run=client` nunca contacta al API server para validar: renderiza el objeto localmente, así que no puede detectar campos desconocidos contra el esquema vivo, rechazos de admission webhooks, defaulting, violaciones de cuota, ni colisiones de nombre. `--dry-run=server` envía el objeto por todo el pipeline de la petición — decodificación, validación, defaulting, admission mutante y validante — y devuelve el objeto que el servidor *habría* persistido, sin escribir en etcd. Usá el dry run del lado del servidor para probar políticas de admission; usá el del lado del cliente para andamiar YAML sin conexión.

**A2.2** — `kube-scheduler`. El objeto Pod lo escribe en etcd el API server **antes** de cualquier decisión de scheduling, con `.spec.nodeName` vacío y `status.phase: Pending`. El scheduler observa esos Pods, corre su ciclo de filtrado/puntuación, y escribe la decisión creando un Binding (que fija `.spec.nodeName`). Recién ahí el kubelet de ese nodo nota el Pod y arranca los contenedores. Por eso un Pod puede existir, ser listado y ser descripto sin que ningún contenedor haya corrido nunca.

**A2.3** — `Always`. Omitido, `restartPolicy` toma por defecto `Always` en un Pod. Para un Pod suelto eso significa que el kubelet reinicia el contenedor en el lugar para siempre si termina — obtenés `CrashLoopBackOff` en lugar de un estado terminal. Con `restartPolicy: Never` el Pod alcanza `Failed` o `Succeeded` y se queda ahí. Para Pods sueltos de tipo batch, fijalo siempre explícitamente; notá que los Jobs solo permiten `Never` u `OnFailure`.

**A2.4** — Borrar un namespace borra todos los objetos namespaced que hay adentro, en cascada. El objeto namespace lleva `spec.finalizers: ["kubernetes"]`; el controlador de namespaces tiene que borrar todo el contenido y después quitar el finalizer para que el objeto desaparezca. `Terminating` persiste mientras algún recurso contenido se niegue a irse — un Pod con un `terminationGracePeriodSeconds` largo, un PVC retenido por un finalizer, o (clásicamente) un CRD cuyo API server agregado está caído, de modo que sus recursos no pueden enumerarse. Diagnosticá con `kubectl api-resources --verbs=list --namespaced -o name | xargs -n1 kubectl get -n <ns> --show-kind --ignore-not-found`.

**A2.5** — (1) Si el nodo que aloja el Pod es drenado, muere o se borra, nada recrea el Pod en otro lado — simplemente desapareció. (2) Si el contenedor termina permanentemente y `restartPolicy: Never`, nada lo reemplaza. Además: sin camino de rolling update, sin escalado, sin historial de `pod-template-hash`, y no va a ser adoptado por ninguna estrategia de rollout de Service. Los Pods sueltos son solo para depuración y tareas de una sola vez.

### Ejercicio 3

**A3.1** — Las labels son metadatos *identificatorios* usados por selectores — el API server las indexa y los controladores consultan sobre ellas; mantenelas cortas y de baja cardinalidad (`app`, `tier`, `env`, `version`, `app.kubernetes.io/name`). Las annotations son metadatos *no identificatorios* para herramientas y humanos — nunca seleccionables, pueden ser grandes y arbitrarias (URLs, JSON, checksums, direcciones de correo). Ejemplos reales: label `app.kubernetes.io/component=api`; annotation `kubectl.kubernetes.io/last-applied-configuration` o `prometheus.io/scrape: "true"`.

**A3.2** — `kubectl get pods -l 'tier=backend,env=prod,app notin (cache)'` — la coma es un AND lógico entre todos los términos, y los requisitos basados en igualdad y en conjuntos pueden mezclarse en una sola expresión.

**A3.3** — Los selectores de labels se sirven desde un índice que el API server mantiene sobre `metadata.labels`, así que una consulta por selector no requiere escanear cada objeto; la sintaxis de las labels está deliberadamente restringida para que ese índice sea barato. Los field selectors *no* están indexados genéricamente — solo se soporta un conjunto fijo de campos por recurso (para Pods: `metadata.name`, `metadata.namespace`, `spec.nodeName`, `spec.schedulerName`, `status.phase`, `status.podIP`, `spec.restartPolicy`, `spec.serviceAccountName`). Cualquier otra cosa se rechaza con `BadRequest` en lugar de hacer silenciosamente un escaneo completo. Las annotations están excluidas de ambos, por diseño, porque no tienen límite de tamaño ni de cardinalidad.

**A3.4** — La inmutabilidad mantiene estable el conjunto de propiedad del controlador. Si el selector de un Deployment vivo pudiera cambiar, los ReplicaSets y Pods existentes dejarían de coincidir instantáneamente y quedarían huérfanos sin controlador que los gestione, mientras que el Deployment levantaría un conjunto nuevo completo — una duplicación silenciosa de la capacidad con sobras no gestionadas. El procedimiento: creá un Deployment *nuevo* con el selector nuevo al lado del viejo, desplazá el tráfico (el selector del Service sí es mutable), y después borrá el Deployment viejo. `kubectl replace --force` también funciona, pero borra y recrea, causando caída total.

**A3.5** — El valor de una label debe tener 63 caracteres o menos, puede estar vacío, y si no está vacío debe empezar y terminar con un alfanumérico (`[a-z0-9A-Z]`) con guiones, guiones bajos, puntos y alfanuméricos en el medio. Las claves pueden tener opcionalmente un prefijo de subdominio DNS (≤253 caracteres) seguido de `/`. Una URL falla por `:` y `//`, que no son caracteres permitidos — por eso la URL del runbook del paso 5 fue a una annotation.

### Ejercicio 4

**A4.1** — `pod-template-hash` es un hash del `.spec.template` del Deployment, computado por el controlador de Deployment y agregado tanto al nombre del ReplicaSet como a una label añadida al `.spec.selector` del ReplicaSet, a su `.metadata.labels`, y a cada Pod que crea. Sin él, todos los ReplicaSets pertenecientes a un mismo Deployment compartirían un selector idéntico (`app=web`) y cada uno contaría *todos* los Pods, incluidos los de la otra revisión — un rolling update sería imposible porque escalar el RS nuevo haría que el RS viejo creyera que está sobre-replicado y borrara los Pods nuevos. El hash particiona la población de Pods por revisión.

**A4.2** — `maxUnavailable: 0` y `maxSurge: 1`. El controlador puede agregar exactamente un Pod extra por encima de `replicas` y no puede llevar ningún Pod existente por debajo del conteo deseado hasta que un reemplazo esté Ready. Como el Pod nuevo nunca queda Ready (`ImagePullBackOff`), el controlador nunca avanza — 3 sanos + 1 roto, indefinidamente, y `rollout status` da timeout. Con `maxUnavailable: 1` al controlador se le habría permitido terminar primero un Pod sano, así que una imagen rota te habría costado un tercio de tu capacidad de servicio antes de que el rollout se detuviera. `maxUnavailable: 0` es el valor por defecto seguro en producción para servicios HTTP sin estado.

**A4.3** — De la annotation `kubernetes.io/change-cause` en la plantilla de Pod del Deployment al momento en que se creó la revisión; el controlador de Deployment copia las annotations del Deployment al ReplicaSet nuevo, y `rollout history` la vuelve a leer desde el ReplicaSet. La revisión 1 la creó `kubectl apply` sin esa annotation. El viejo flag `--record` que la poblaba automáticamente está deprecado; anotá explícitamente, idealmente con el SHA del commit de Git.

**A4.4** — `undo` no borra nada. Lee la plantilla de Pod del ReplicaSet objetivo (la revisión anterior por defecto, o `--to-revision=N`), la escribe de vuelta en el `.spec.template` del Deployment, y deja que la maquinaria normal de rolling update corra hacia adelante. La consecuencia es que el número de revisión *viejo* no se reutiliza: después de deshacer desde la revisión 3 hacia la plantilla de la revisión 2, `rollout history` muestra las revisiones 1, 3 y una nueva 4 — la revisión a la que se volvió se renumera como la más nueva. `--to-revision=0` significa "la anterior".

**A4.5** — La cascada por defecto es `background`: borrar el ReplicaSet le fija `deletionTimestamp` y el garbage collector borra cada objeto cuyas `ownerReferences` apunten a él — los tres Pods. El controlador de Deployment entonces no encuentra ningún ReplicaSet para el hash de su plantilla actual, crea uno nuevo con el *mismo* hash (la plantilla no cambió), y ese ReplicaSet crea tres Pods frescos. Con `--cascade=orphan`, el GC despoja las `ownerReferences` de los Pods en lugar de borrarlos. El ReplicaSet recreado entonces los **adopta**: un ReplicaSet adopta cualquier Pod de su namespace que coincida con su selector (incluyendo `pod-template-hash`) y no tenga owner reference de controlador, así que alcanza su cuenta deseada sin crear nada. Fijate en la columna AGE — los Pods son los originales.

**A4.6** — El valor por defecto es `10`. Lo que se retiene son los *objetos ReplicaSet viejos* con `replicas: 0` — no contienen nada más que la plantilla de Pod, que es lo que hace posible el rollback. Ponerlo en `0` borra los ReplicaSets viejos inmediatamente y hace imposible `kubectl rollout undo`: no hay plantilla almacenada a la cual volver. El costo de un valor alto son objetos en etcd y ruido en `kubectl get rs`, lo cual es trivial; mantené al menos 2–3.

**A4.7** — El siguiente `apply` escala el Deployment de vuelta a 3, porque `replicas` está presente en el manifiesto y por lo tanto en `last-applied-configuration` — el merge ve el valor del archivo como autoritativo. Para co-gestionarlo con un HPA, **quitá `replicas` del manifiesto por completo**: con el apply del lado del cliente, un campo ausente tanto del archivo como de la annotation last-applied queda intacto en el objeto vivo. Con Server-Side Apply el equivalente es no incluir `replicas` en la configuración aplicada, dejando `.spec.replicas` en poder del field manager del controlador del HPA. Dejar `replicas` en el archivo mientras un HPA está activo produce una pelea entre dos controladores que se manifiesta como churn masivo y periódico de Pods.

### Ejercicio 5

**A5.1** — En la plantilla de Pod: `ports: [{name: http, containerPort: 80}]`. `targetPort` acepta o bien un número o bien el *nombre* de un puerto declarado en el contenedor. Si renombrás el puerto del contenedor a `web` sin actualizar el Service, el controlador de EndpointSlice no puede resolver el nombre y los endpoints quedan sin puerto — el tráfico se rompe aunque los selectores sigan coincidiendo. Los puertos nombrados valen la pena porque permiten que Pods heterogéneos detrás de un mismo Service escuchen en números distintos.

**A5.2** — (1) `web` tiene 0 puntos, que es menos que `ndots:5`, así que el resolver prueba primero los sufijos de `search`: `web.ops-lab.svc.cluster.local` coincide inmediatamente en CoreDNS (`10.96.0.10`), devolviendo el ClusterIP del Service `10.96.183.24`. (2) El paquete sale del Pod dirigido a `10.96.183.24:8080`. Esa dirección es virtual — nadie la posee, nadie responde ARP por ella. `kube-proxy` programó reglas (iptables o nftables, o un equivalente eBPF del CNI) en cada nodo que hacen DNAT del destino hacia una de las direcciones de endpoints listos, elegida aproximadamente al azar. (3) El paquete que llega al cable lleva destino `10.244.x.y:80` — una IP de Pod y el puerto del *contenedor*, no el puerto del Service. El tráfico de vuelta lo des-NATea conntrack. Verificá el modo con `kubectl -n kube-system get cm kube-proxy -o yaml | grep -A1 mode`.

**A5.3** — `Endpoints` es un único objeto por Service que contiene *todas* las direcciones backend en una sola lista. Con unos pocos miles de endpoints ese objeto se vuelve grande, y cualquier cambio de un solo Pod reescribe y retransmite la cosa entera a cada nodo — un patrón de tráfico O(n²) durante los rollouts. `EndpointSlice` (`discovery.k8s.io/v1`) fragmenta la misma información en slices de ~100 endpoints cada uno, así que un cambio toca un solo slice; además agrega `conditions` por endpoint (`ready`, `serving`, `terminating`), hints de topología para el ruteo topology-aware, y soporte dual-stack vía `addressType`. El control plane todavía refleja los slices de vuelta en objetos `Endpoints` legacy por compatibilidad, pero `Endpoints` está deprecado y el código nuevo debería leer EndpointSlices.

**A5.4** — Cargas de trabajo StatefulSet: bases de datos y sistemas de quórum (Cassandra, etcd, Kafka, réplicas de PostgreSQL) donde un cliente debe direccionar a un miembro *específico*, no a uno aleatorio. Un ClusterIP balancearía una escritura destinada al primario hacia una réplica. Con `clusterIP: None` la consulta DNS devuelve todos los registros A de los Pods, y combinado con un StatefulSet cada Pod además obtiene un nombre estable por Pod (`web-0.web-headless.ops-lab.svc.cluster.local`) que sobrevive al reagendamiento. Los Services headless también son cómo los balanceadores del lado del cliente (gRPC) descubren la lista completa de endpoints.

**A5.5** — `30000–32767` por defecto, configurable con `--service-node-port-range` del API server. Pedir `nodePort: 8080` falla la validación: `The Service "web" is invalid: spec.ports[0].nodePort: Invalid value: 8080: provided port is not in the valid range. The range of valid ports is 30000-32767`. La restricción evita colisionar con servicios del host y con el rango de puertos efímeros.

**A5.6** — El objeto Service es una asignación estable (el ClusterIP y el nodePort quedan reservados durante su vida), pero es solo una *especificación*. El controlador de EndpointSlice recomputa el conjunto de respaldo cada vez que cambian el selector o las labels de los Pods; con `app=web-typo` sin coincidir con nada, vació el slice. kube-proxy entonces quita las reglas de DNAT para ese ClusterIP/nodePort, así que las conexiones son rechazadas o dan timeout inmediatamente, y el DNS sigue resolviendo el nombre. "El Service existe, tiene ClusterIP asignado, cero endpoints" es la falla de red de Kubernetes más común de todas — verificá `kubectl get endpointslice -l kubernetes.io/service-name=<svc>` antes que nada, y recordá las dos causas: selector desalineado, o todos los Pods fallando la readiness.

**A5.7** — Lo hizo de proxy el **API server**. `kubectl port-forward` abre una conexión de streaming (SPDY/WebSocket) al subrecurso `pods/portforward`; el API server la reenvía al kubelet de ese nodo, que arma el túnel hacia el network namespace del Pod. kube-proxy, los Services y los EndpointSlices no están involucrados en absoluto, ni tampoco el estado de readiness del Pod — por eso port-forward alcanza un Pod al que un Service se niega a rutear. Eso también es por qué es una herramienta de depuración: es un túnel de un solo Pod, un solo usuario, sin cifrado en el extremo lejano, atado a tu estación de trabajo, que muere con tu shell, sin balanceo de carga y sin alta disponibilidad, y requiere credenciales de API con `create` sobre `pods/portforward`.

### Ejercicio 6

**A6.1** — No hay nada encriptado. Los valores de `data` están **codificados en base64**, que es una codificación de transporte, no un cifrado — cualquiera con `get` sobre el Secret tiene el texto plano, como demostró el paso 2. Lo que los Secrets *sí* hacen distinto de los ConfigMaps: se almacenan con un tipo propio, el kubelet los monta en `tmpfs` (nunca en disco), se omiten de algunos caminos de log/describe, y pueden restringirse por separado en RBAC. Para protección real en reposo, el administrador del clúster debe configurar un `EncryptionConfiguration` en el API server (`--encryption-provider-config`) con un proveedor KMS o `aescbc`/`secretbox`, y reescribir los Secrets existentes; alternativamente, usar un almacén externo (Vault, gestor de secretos en la nube) vía driver CSI u operador.

**A6.2** — Las variables de entorno se materializan **una sola vez**, por el kubelet, cuando se crea el contenedor; son el entorno de proceso ordinario y no hay mecanismo para mutar el entorno de un proceso en ejecución. Un **volumen** de ConfigMap/Secret lo proyecta el kubelet, que observa el objeto y reescribe el directorio de respaldo ante cada cambio, así que un proceso que relea el archivo ve el contenido nuevo. El peor caso de retardo ≈ el período de sincronización del kubelet (1 minuto por defecto) + el TTL del caché de ConfigMap/Secret del kubelet — presupuestá del orden de uno a dos minutos, y notá que la *aplicación* igual tiene que darse cuenta (inotify, SIGHUP, o polling).

**A6.3** — No se habría actualizado nada. Un montaje `subPath` se resuelve a un único archivo bind-montado al arranque del contenedor; no forma parte del directorio proyectado que se intercambia atómicamente, así que nunca recibe actualizaciones durante toda la vida del contenedor. Esta es una trampa clásica de producción: los equipos usan `subPath` para dejar un archivo de configuración en un directorio que ya tiene contenido, y después se preguntan por qué dejaron de funcionar las recargas de configuración. Usá `items` con un directorio de montaje dedicado (como en el paso 3), o aceptá que vas a tener que reiniciar.

**A6.4** — Atomicidad. El kubelet escribe cada versión en un directorio oculto con marca de tiempo (`..2026_09_03_12_41_07.1839284`), después intercambia un único symlink `..data` para que apunte a él, y las entradas visibles son symlinks a través de `..data`. Como el intercambio de un symlink es atómico, una aplicación nunca puede observar un conjunto de claves escrito a medias — o todo viejo o todo nuevo. También significa que la actualización es un cambio de symlink y no una escritura in situ, lo cual afecta cómo configurás los watches de inotify.

**A6.5** — (1) Rendimiento y escala: el kubelet no necesita observar un objeto inmutable, lo que elimina un watch por Pod del API server — significativo en clústeres con miles de Pods. (2) Seguridad: vuelve imposibles las ediciones accidentales in situ, así que un cambio de configuración no puede alterar silenciosamente los archivos montados de Pods en ejecución sin rollout, sin historial de revisiones y sin rollback. El procedimiento de actualización pasa a ser: crear un ConfigMap *nuevo* con sufijo de versión (`web-config-v2`, o un hash de contenido — que es lo que hace automáticamente el `configMapGenerator` de kustomize), apuntar la plantilla del Deployment a él, y hacer el rollout. Ese cambio en la plantilla dispara un rollout normal y reversible.

**A6.6** — `env.valueFrom.configMapKeyRef` importa exactamente una clave bajo un nombre que elegís vos; `envFrom.configMapRef` importa *todas* las claves usando los nombres de clave tal cual. Solo la forma explícita es segura: con `envFrom`, una clave llamada `PATH`, `HOME` o `LD_PRELOAD` en el ConfigMap sobrescribe silenciosamente el entorno del contenedor y puede romper o subvertir el proceso. `envFrom` además saltea claves que no son nombres válidos de variable de entorno, reportándolas como un evento `InvalidVariableNames` en lugar de fallar — una importación parcial silenciosa. Usá `envFrom` solo con ConfigMaps que controlás por completo, y preferí prefijos (`envFrom: [{prefix: APP_, configMapRef: ...}]`).

**A6.7** — Falló *después* del scheduling pero *antes* de que el contenedor fuera creado. El Pod está atado a un nodo (así que no está `Pending`), el kubelet lo aceptó e intentó ensamblar la configuración del contenedor — entorno, montajes — y no pudo resolver una referencia, así que nunca se arrancó ninguna imagen de contenedor. De ahí `CreateContainerConfigError`, distinto de `CrashLoopBackOff` (el contenedor arrancó y terminó) y de `Pending` (nunca fue agendado). El kubelet reintenta, así que arreglar el ConfigMap lo resuelve sin recrear el Pod. `CreateContainerError` es el hermano para fallas a nivel de runtime, como una ruta de comando incorrecta.

**A6.8** — Porque `get` sobre un Secret devuelve el texto plano a cualquiera que sepa decodificar base64 — la codificación no aporta ningún control de acceso. Los verbos a restringir son `get`, `list` y `watch` sobre `secrets`; notá que `list` por sí solo alcanza para leer todos los valores, dado que una respuesta de listado embebe los objetos completos, así que otorgar `list` sin `get` no protege nada. Preferí `resourceNames` por Secret en los Roles, acceso acotado por service account, y logs de auditoría sobre el recurso `secrets`.

### Ejercicio 7

**A7.1** — Readiness: la condición `Ready` del Pod pasa a falso y es removido de los endpoints de todos los Services, así que no recibe tráfico nuevo — pero el contenedor sigue corriendo y no se reinicia, que es exactamente lo que querés mientras un proceso está calentando un caché o está temporalmente sobrecargado. Liveness: el kubelet mata el contenedor y lo reinicia en el lugar según el `restartPolicy` del Pod; el objeto Pod, su nombre, su nodo y su IP no cambian, y `RESTARTS` se incrementa.

**A7.2** — `initialDelaySeconds` te obliga a elegir un único número que debe ser mayor que el *peor* arranque que jamás esperes, lo cual significa que los cuelgues genuinos también quedan sin detectar durante todo ese período. Una `startupProbe` desacopla las dos cosas: mientras está fallando, las probes de liveness y readiness quedan suspendidas por completo; una vez que tiene éxito, no vuelve a correr nunca y toma el control la liveness probe agresiva. Una app JVM que ocasionalmente tarda 4 minutos en calentar puede entonces tener `startupProbe: failureThreshold: 30, periodSeconds: 10` (5 minutos de gracia) junto con `livenessProbe: periodSeconds: 5, failureThreshold: 3` (detección en 15 segundos a partir de ahí). Sin ella, necesitarías `initialDelaySeconds: 300` en la liveness probe y estarías ciego a los cuelgues durante cinco minutos después de cada reinicio.

**A7.3** — (a) **Guaranteed**: cada contenedor tiene límites de CPU y memoria, y los requests igualan a los límites en ambos. (b) **Burstable**: hay al menos un request o límite fijado pero no se cumplen las condiciones de Guaranteed. Notá el defaulting — un contenedor con solo `limits.memory` obtiene `requests.memory` por defecto igual al límite, pero sin límite de CPU fijado el contenedor no es Guaranteed. (c) **BestEffort**: sin requests ni límites en ningún contenedor. (d) **Burstable**: la clase es una propiedad de todo el Pod, y *cada* contenedor (init containers incluidos) debe satisfacer las condiciones de Guaranteed; un contenedor Burstable degrada al Pod.

**A7.4** — Bajo presión de memoria del nodo, el kubelet ordena los candidatos a desalojo por, primero, si el uso de memoria del Pod excede su request, y después por la prioridad del Pod y por cuánto excede el uso al request. En la práctica: **BestEffort primero** (sin request, así que cualquier uso lo excede), después los **Pods Burstable que están por encima de su request**, y **Guaranteed último** — un Pod Guaranteed solo es desalojado si nada más puede liberar memoria, o si excede su propio límite (en cuyo caso el kernel OOM-matea el contenedor en lugar de que el kubelet desaloje el Pod). Un Pod Burstable que usa *menos* que su request se trata como bien portado y se ubica junto a los Guaranteed al fondo de la lista de matanza; esta es la razón concreta para fijar requests honestos.

**A7.5** — 137 = 128 + 9, es decir, el proceso fue terminado por la señal 9 (`SIGKILL`). En el paso 5 el kubelet mandó el kill porque falló la liveness probe (manda primero `SIGTERM` y escala a `SIGKILL` después del período de gracia), y el estado del contenedor muestra `Reason: Error`. En el paso 6 el OOM killer de cgroups del **kernel** terminó el proceso por exceder el límite de memoria, y el CRI lo reporta de vuelta, así que el estado dice `Reason: OOMKilled`. Mismo exit code, remediación completamente distinta: arreglar el endpoint de salud versus subir el límite o arreglar la fuga.

**A7.6** — El scheduler compara los **requests** del Pod contra la capacidad *allocatable* del nodo menos la **suma de los requests** de todos los Pods ya asignados a ese nodo. Nunca mira la utilización real, por eso un nodo con 6 GiB de RAM libre igual puede reportar "Insufficient memory". Los requests son la moneda de scheduling porque son el único número que constituye una *reserva*: los límites son permisos para hacer burst, y si el scheduler empaquetara por límites, o bien subutilizaría drásticamente los nodos (todos reservando su pico) o bien sobrecomprometería de forma impredecible. El corolario es que un Pod sin request puede agendarse en cualquier nodo, no contribuye nada a la contabilidad, y es lo primero en ser desalojado.

**A7.7** — Sigue siendo **Guaranteed**. Cuando un contenedor especifica un límite pero no un request, el API server pone el request por defecto igual al límite. Así que `limits: {cpu: 50m, memory: 64Mi}` sin bloque de requests da requests iguales a los límites en ambos recursos — la condición de Guaranteed. (Contrastá con A7.3(b), donde solo la *memoria* tenía límite: la falta del límite de CPU es lo que impidió Guaranteed ahí.)

### Ejercicio 8

**A8.1** — `ErrImagePull` es el resultado inmediato de un intento de pull fallido — registry inalcanzable, tag no encontrado, autenticación rechazada. `ImagePullBackOff` significa que el kubelet entró en backoff exponencial entre reintentos tras fallas repetidas: arranca alrededor de 10 segundos y duplica hasta un tope de 5 minutos. La consecuencia práctica es que después de que arreglás el problema de fondo (pushear el tag, agregar el `imagePullSecret`), la recuperación puede tardar hasta cinco minutos; borrar el Pod fuerza un reintento inmediato.

**A8.2** — El kubelet retiene el archivo de log del contenedor terminado en el nodo hasta que el contenedor es recolectado por el GC, así que `kubectl logs` sobre un Pod en backoff sirve la salida del último contenedor completado. `--previous` (`-p`) pide explícitamente el log de la instancia *anterior*, que es lo que necesitás cuando el contenedor ya reinició y la instancia actual todavía no produjo nada. No está disponible cuando no hubo instancia previa, o después de que la rotación de logs / el GC de contenedores del nodo la eliminó (`previous terminated container "x" in pod "y" not found`) — por eso el diagnóstico de crashes depende de enviar los logs fuera del nodo.

**A8.3** — 5 minutos (300 s). El kubelet arranca en 10 s y duplica en cada falla consecutiva: 10, 20, 40, 80, 160, 300, 300… El temporizador se resetea después de que el contenedor corrió exitosamente durante 10 minutos. Por eso un Pod que crashea cada 3 minutos nunca alcanza el tope y nunca aparece en `CrashLoopBackOff` por mucho tiempo — y por eso un conteo de `RESTARTS` que trepa lentamente suele ser más alarmante que uno atascado en backoff.

**A8.4** — `kubectl logs deploy/web` resuelve el Deployment a su selector, elige **un** Pod, y transmite ese. Es una comodidad, no una agregación. Para cubrir todas las réplicas usá un selector de labels: `kubectl logs -l app=web --all-containers --prefix --max-log-requests=10`. `--prefix` es esencial porque sin él no podés saber qué Pod emitió cada línea, y `--max-log-requests` (5 por defecto) tiene que subirse por encima del número de réplicas o el comando da error.

**A8.5** — `--target=nginx`. Pone el contenedor efímero en el **process namespace** del contenedor objetivo, así que ve y puede señalizar los procesos del objetivo e inspeccionar `/proc/1/`. Sin `--target` el contenedor de depuración comparte solo los namespaces de red e IPC del Pod: `curl localhost` sigue funcionando, pero `ps` muestra solo los procesos del propio contenedor de depuración. Notá que el *sistema de archivos* del objetivo sigue estando separado — para leer los archivos del objetivo usá `/proc/1/root/...` desde el contenedor de depuración.

**A8.6** — No. Los contenedores efímeros pueden agregarse a un Pod en ejecución pero nunca removerse ni reiniciarse; no tienen probes, ni recursos, ni acciones de ciclo de vida, y persisten en `.spec.ephemeralContainers` durante toda la vida del Pod. Consecuencias en producción: el spec del Pod queda permanentemente anotado con la sesión de depuración (visible en auditorías), el uso de recursos de la imagen de depuración no queda contabilizado contra los límites del Pod a nivel de QoS del Pod, y la única forma de removerlo es borrar y recrear el Pod. Preferí `kubectl debug --copy-to=web-debug` sobre una copia para cualquier cosa invasiva.

**A8.7** — El Deployment `metrics-server` (u otro proveedor de la API agregada `metrics.k8s.io`) no está instalado; `kind` no lo trae. Afecta al **HorizontalPodAutoscaler** — que lee `metrics.k8s.io` y va a reportar `unknown` para las métricas de recursos y a negarse a escalar — y a `kubectl top`. **No** afecta al scheduler, que toma decisiones a partir de los `requests` del spec del Pod y del allocatable del nodo, nunca de la utilización en vivo. Confundir estas cosas es una trampa común de entrevista: un clúster sin métricas agenda perfectamente.

**A8.8** — (1) `kubectl describe pod <name>` — si `Events` está genuinamente vacío *y* `Node:` está vacío, el scheduler ni siquiera lo intentó, lo que apunta a un scheduler faltante/fallado o a un `schedulerName` que refiere a un scheduler que no existe. (2) `kubectl get events -A --sort-by=.lastTimestamp | grep <name>` — los eventos tienen un TTL por defecto de 1 hora, así que el `FailedScheduling` de un Pod viejo puede haber expirado; verificar a nivel de todo el clúster también atrapa eventos de cuota sobre el namespace (`exceeded quota`). (3) `kubectl get pod <name> -o yaml` y leer `.spec` — `nodeSelector`/`nodeAffinity` inagendables, `topologySpreadConstraints` insatisfacibles, un `priorityClassName` que no existe, o un PVC en `Pending` porque ninguna StorageClass puede bindearlo (verificá con `kubectl get pvc`). Esos tres separan "nadie está agendando", "alguien intentó y falló" y "el spec es insatisfacible".

### Ejercicio 9

**A9.1** — Las tres entradas son: (1) la **última configuración aplicada**, almacenada en la annotation `kubectl.kubernetes.io/last-applied-configuration` sobre el objeto vivo — esto es lo que contiene la annotation; (2) el **manifiesto nuevo** que estás aplicando; (3) el **objeto vivo** tal como existe actualmente en el servidor. El patch se computa así: los campos presentes en (1) pero ausentes de (2) se *borran*; los campos en (2) se *fijan*; los campos presentes solo en (3) se *dejan en paz*.

**A9.2** — `replicas: 3` está presente tanto en la annotation last-applied como en el manifiesto nuevo, así que el merge impone el valor del manifiesto y sobrescribe el `6` vivo. `owner=sre` aparece solo en el objeto vivo — nunca estuvo en ninguna configuración aplicada — así que aplica la tercera regla y el campo se preserva. Esta es la regla que permite que un HPA, un inyector de service mesh o un operador agreguen campos a un objeto que CI también aplica, sin pelea, *siempre que* el manifiesto nunca mencione esos campos.

**A9.3** — No. La reversión ocurrió solo porque `revisionHistoryLimit: 5` estaba en la configuración aplicada *previa*, así que quitarlo del archivo hizo que el merge computara un borrado, y el API server entonces reaplicó su valor por defecto de `10`. Si el campo se hubiera fijado con `kubectl patch` o `kubectl edit`, nunca habría entrado en la annotation, así que quitarlo del archivo no computaría ningún borrado y el valor parcheado sobreviviría indefinidamente. Esta asimetría — "apply solo puede borrar lo que apply fijó previamente" — es la fuente de una gran cantidad de basura sin borrar en objetos de larga vida.

**A9.4** — Server-Side Apply mueve la detección de conflictos al API server y rastrea, campo por campo, *qué manager lo posee* en `.metadata.managedFields`. Dos desventajas del enfoque de la annotation que arregla: (1) la annotation es una copia completa del manifiesto almacenada en el objeto, lo que duplica el tamaño del objeto y puede exceder el límite de 256 KB de annotations en CRs grandes; y (2) la resolución del merge ocurre en el *cliente*, así que distintas versiones de kubectl y otras herramientas (Helm, operadores) computan patches distintos, y nada detecta que dos actores están escribiendo el mismo campo — el último que escribe gana silenciosamente, sin error. SSA convierte esa sobrescritura silenciosa en el conflicto explícito que viste en el paso 6.

**A9.5** — `--force-conflicts` transfiere la propiedad de los campos en conflicto a tu field manager y los quita de la entrada de `hotfix-operator` en `managedFields`; se escribe tu valor. Es la respuesta correcta cuando *sos* el propietario autoritativo y el otro manager fue un parche humano de una sola vez. Es la respuesta **equivocada** cuando el otro manager es un controlador activo que va a seguir escribiendo el campo — un HPA sobre `.spec.replicas`, un inyector de mesh sobre la plantilla de Pod, un cert manager sobre un Secret. Ahí solo vas a iniciar un bucle de escrituras; el arreglo correcto es quitar el campo de tu configuración aplicada para que el controlador conserve la propiedad.

**A9.6** — La falla: cada diez minutos CI resetea `replicas` a 3, el HPA observa la carga y escala de vuelta hacia arriba, y obtenés un diente de sierra de churn de Pods — capacidad oscilando, conexiones cortadas en cada escalado hacia abajo, y eventos de rollout inundando el namespace. Arreglo, del lado del cliente: borrá `replicas` del manifiesto **y** limpialo de la annotation last-applied (lo lográs aplicando el archivo una vez sin el campo, lo que dispara el borrado descripto en A9.3, y después dejando que el HPA lo fije — o reestableciendo la línea base con `kubectl apply --server-side`). Arreglo, del lado del servidor: simplemente omití `replicas` de la configuración aplicada; el field manager del HPA posee `.spec.replicas` y SSA lo deja en paz. Nunca uses `--force-conflicts` acá.

**A9.7** — `kubectl replace -f` hace un `PUT` completo: sobrescribe el objeto entero con el contenido del archivo, requiriendo `metadata.resourceVersion` para concurrencia optimista. Es correcto cuando querés *garantizar* que el objeto vivo coincide exactamente con el archivo sin semántica de merge — por ejemplo, quitar un campo que fue fijado con `kubectl edit` y nunca entró en la annotation last-applied, o restaurar un objeto conocido-bueno desde un backup. Lo que hace que `apply` nunca hace: **borrar campos fijados por otros actores**, incluyendo campos que agregó un controlador. Eso lo vuelve peligroso por defecto y es la razón por la que `apply` es el flujo de trabajo recomendado; `kubectl replace --force` va más allá y borra-y-recrea el objeto, causando caída del servicio y un UID nuevo.

### Ejercicio 10

**A10.1** — El controlador de DaemonSet computa la cuenta deseada como el número de nodos cuyos taints, `nodeSelector`, `nodeAffinity` y recursos disponibles permiten que la plantilla sea agendada — `status.desiredNumberScheduled`. Agregar la toleration hizo elegible al nodo del control-plane, así que la cuenta pasó a 3. No hay campo `replicas` porque la cantidad de réplicas no es una política que elegís; es una *derivación* de la membresía del clúster, y debe cambiar automáticamente cuando los nodos entran o salen. Escalar un DaemonSet significa cambiar su selector de nodos o el conjunto de nodos del clúster. (Para suspender uno sin borrarlo, fijá un `nodeSelector` imposible — la pausa idiomática.)

**A10.2** — `completions` es cuántos Pods deben tener éxito para que el Job quede `Complete`; `parallelism` es cuántos pueden correr a la vez. Con `completions: 6, parallelism: 2` el controlador corre un par rodante hasta acumular seis éxitos. Con `completions` sin fijar y `parallelism: 4`, el Job es un Job de **cola de trabajo**: cuatro Pods corren concurrentemente y el Job tiene éxito apenas *cualquiera* de los Pods termina exitosamente y no hay otros corriendo — se espera que los workers se coordinen a través de una cola externa y que cada uno termine cuando la cola se vacía.

**A10.3** — Solo `Never` y `OnFailure`; `Always` se rechaza en la validación, porque un Job que reinicia para siempre nunca puede completarse. Con `Never`, un contenedor fallido significa un **Pod** fallido, el controlador del Job crea un Pod *nuevo*, y `backoffLimit` cuenta esas fallas de Pod — obtenés un objeto Pod por intento, y los logs de cada uno son recuperables individualmente. Con `OnFailure`, el kubelet reinicia el contenedor **en el lugar** en el mismo Pod; `.status.failed` se maneja por reinicios de contenedor, ves un conteo de `RESTARTS` que sube en lugar de Pods nuevos, y perdés los objetos Pod por intento. Usá `Never` cuando querés preservar los logs de cada intento.

**A10.4** — El patch no hizo nada útil: la mayor parte del spec de un Job, incluidos `backoffLimit`, `completions` y la plantilla de Pod, es inmutable después de la creación (solo `parallelism`, `suspend` y los campos de TTL/managed-by pueden cambiarse), así que el API server lo rechazó y el Job conservó el `backoffLimit: 6` por defecto. Seis reintentos más el intento original son siete Pods — exactamente lo que contó `kubectl get pods`. La lección es que la política de reintentos de un Job tiene que estar bien al momento de la creación; para cambiarla lo borrás y lo recreás.

**A10.5** — Es la autolimpieza del Job: el controlador TTL-after-finished borra el objeto Job *N* segundos después de que alcanza `Complete` o `Failed`. Borrar el Job cascadea a sus Pods, así que **los Pods y sus logs desaparecen con él** — cualquier cosa que necesitaras de esos logs ya tiene que haber sido enviada a un almacén de logs. Sin esto, los Jobs terminados se acumulan indefinidamente (especialmente los de CronJobs) y se vuelven una fuente real de inflado de etcd.

**A10.6** — El controlador de CronJob compara la hora actual contra `.status.lastScheduleTime` y enumera las programaciones perdidas. El comportamiento lo gobierna `startingDeadlineSeconds`: si no está fijado, el controlador va a arrancar una ejecución perdida cuando vuelva, pero cuenta las programaciones perdidas y si se acumularon más de 100 se rinde y registra un evento `FailedNeedsStart` en lugar de lanzar una tormenta. Si está fijado `startingDeadlineSeconds: N`, una ejecución perdida solo arranca si transcurrieron menos de N segundos desde que era debida; las más viejas se saltean permanentemente y se cuentan como perdidas. Fijalo deliberadamente: demasiado chico y cortes breves legítimos descartan ejecuciones; sin fijar y un corte largo puede o bien saltear todo o, peor, chocar contra el muro de las 100 perdidas.

**A10.7** — `Allow` (por defecto): se permiten ejecuciones superpuestas — correcto para trabajo corto, idempotente y mutuamente independiente, como un scrape de métricas. `Forbid`: si la ejecución anterior sigue activa, la nueva se saltea y se registra como perdida — correcto para un job que muta estado compartido, como un backup de base de datos o un reindexado, donde dos ejecuciones concurrentes corromperían o generarían un deadlock. `Replace`: el Job en ejecución se borra y se reemplaza por el nuevo — correcto cuando solo importa el resultado más fresco y una ejecución en vuelo obsoleta no vale nada, como recomputar un caché o una tabla de posiciones.

**A10.8** — `--from=cronjob/heartbeat` copia el `jobTemplate` del CronJob textualmente, así que la ejecución manual usa exactamente la imagen, el comando, el entorno, la service account, los recursos y las restricciones de nodo de la ejecución programada. Copiar el manifiesto a mano a las 3 de la mañana diverge sin falta — un tag de imagen viejo, un `imagePullSecret` faltante, la service account equivocada — y produce el misterio de "la ejecución manual funcionó / la programada falla". Además no perturba `.status.lastScheduleTime`, así que la programación continúa sin afectarse.

### Ejercicio 11

**A11.1** — `kubectl rollout restart` parchea `.spec.template.metadata.annotations` con `kubectl.kubernetes.io/restartedAt: <timestamp RFC3339>`. Como la plantilla de Pod cambió, el controlador de Deployment computa un `pod-template-hash` nuevo, crea un ReplicaSet nuevo, y realiza un **rolling update normal respetando `maxUnavailable: 0`** — así que el cambio del ConfigMap llega a todas las réplicas sin caída del servicio, y queda una revisión en `rollout history` a la cual volver. Editar la imagen sería una mentira sobre qué cambió (y no hay imagen nueva); borrar Pods esquiva la política de rollout por completo, bajando la capacidad en los pedazos que borres, sin registro y sin rollback.

**A11.2** — `.metadata.generation` se incrementa con cada cambio al *spec* del Deployment; `.status.observedGeneration` registra la generación sobre la que el controlador terminó de actuar. Esperar a que `observedGeneration >= generation` **y** `status.updatedReplicas == status.replicas == status.readyReplicas == spec.replicas` es la prueba de completitud legible por máquina. `kubectl rollout status` hace efectivamente esto: observa el Deployment y evalúa la condición `Progressing` — teniendo éxito con `reason: NewReplicaSetAvailable` y fallando con `ProgressDeadlineExceeded` (600 s por defecto, de `.spec.progressDeadlineSeconds`). En CI, `kubectl rollout status --timeout=5m` y su código de salida son la compuerta correcta; un `sleep` pelado no lo es.

**A11.3** — 4 en el pico. `maxSurge: 25%` de 3 réplicas es 0,75, que se redondea **hacia arriba** para el surge, dando 1 Pod extra; `maxUnavailable: 25%` se redondearía **hacia abajo** a 0, pero acá está explícitamente en 0 de todos modos. Así que el controlador agrega un Pod nuevo (4 en total), espera a que esté Ready, termina un Pod viejo (3), agrega otro nuevo (4), y repite — sin bajar nunca de 3 disponibles y sin exceder nunca 4 en total. Las direcciones de redondeo son deliberadas: el surge redondea hacia arriba y la indisponibilidad hacia abajo, así que los porcentajes siempre erran hacia más capacidad.

</details>

---

## Fuentes

- LPI, *DevOps Tools Engineer — Exam 701 Objectives (version 2.0)* — https://www.lpi.org/our-certifications/exam-701-objectives/
- Kubernetes, *kubectl reference* — https://kubernetes.io/docs/reference/kubectl/
- Kubernetes, *Organizing Cluster Access Using kubeconfig Files* — https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
- Kubernetes, *Labels and Selectors* — https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/
- Kubernetes, *Annotations* — https://kubernetes.io/docs/concepts/overview/working-with-objects/annotations/
- Kubernetes, *Namespaces* — https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/
- Kubernetes, *Deployments* — https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- Kubernetes, *ReplicaSet* — https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/
- Kubernetes, *DaemonSet* — https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/
- Kubernetes, *Jobs* — https://kubernetes.io/docs/concepts/workloads/controllers/job/
- Kubernetes, *CronJob* — https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/
- Kubernetes, *Garbage Collection* (owner references, borrado en cascada) — https://kubernetes.io/docs/concepts/architecture/garbage-collection/
- Kubernetes, *Service* — https://kubernetes.io/docs/concepts/services-networking/service/
- Kubernetes, *EndpointSlices* — https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/
- Kubernetes, *DNS for Services and Pods* — https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/
- Kubernetes, *ConfigMaps* — https://kubernetes.io/docs/concepts/configuration/configmap/
- Kubernetes, *Secrets* — https://kubernetes.io/docs/concepts/configuration/secret/
- Kubernetes, *Encrypting Confidential Data at Rest* — https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
- Kubernetes, *Configure Liveness, Readiness and Startup Probes* — https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- Kubernetes, *Resource Management for Pods and Containers* — https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
- Kubernetes, *Assign Memory Resources to Containers and Pods* (el ejercicio de OOM con `polinux/stress`) — https://kubernetes.io/docs/tasks/configure-pod-container/assign-memory-resource/
- Kubernetes, *Pod Quality of Service Classes* — https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/
- Kubernetes, *Node-pressure Eviction* — https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/
- Kubernetes, *Taints and Tolerations* — https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/
- Kubernetes, *Debug Running Pods* (contenedores efímeros, `kubectl debug`) — https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/
- Kubernetes, *Server-Side Apply* — https://kubernetes.io/docs/reference/using-api/server-side-apply/
- Kubernetes, *Declarative Management of Kubernetes Objects Using Configuration Files* — https://kubernetes.io/docs/tasks/manage-kubernetes-objects/declarative-config/
- Kubernetes, *Declarative Management Using Kustomize* — https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/
- Kubernetes, *Field Selectors* — https://kubernetes.io/docs/concepts/overview/working-with-objects/field-selectors/
- kind, *Quick Start* — https://kind.sigs.k8s.io/docs/user/quick-start/