# 3.1 Administration

> Fuente de referencia: [KCNA Curriculum (CNCF)](https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf)

Estos ejercicios asumen que ya tenés acceso a un cluster de Kubernetes (por ejemplo `kind` o `minikube`) y `kubectl` configurado.

## Ejercicio 1: kubeconfig y contexts

La administración de un cluster empieza por entender cómo `kubectl` sabe a qué cluster conectarse y con qué identidad.

1. Mostrá la configuración activa de `kubectl`:
   ```bash
   kubectl config view
   ```
2. Listá los contexts disponibles:
   ```bash
   kubectl config get-contexts
   ```
3. Identificá el context actual:
   ```bash
   kubectl config current-context
   ```
4. Creá un namespace de prueba y un context que apunte a él por default:
   ```bash
   kubectl create namespace admin-demo
   kubectl config set-context admin-demo-ctx \
     --cluster=$(kubectl config view -o jsonpath='{.clusters[0].name}') \
     --user=$(kubectl config view -o jsonpath='{.users[0].name}') \
     --namespace=admin-demo
   ```
5. Cambiá al nuevo context:
   ```bash
   kubectl config use-context admin-demo-ctx
   ```
6. Confirmá que los comandos ahora operan sobre `admin-demo` sin necesidad de `-n`:
   ```bash
   kubectl run nginx --image=nginx
   kubectl get pods
   ```

**Pregunta 1.1:** ¿Qué archivo lee `kubectl` por default para obtener clusters, users y contexts, y qué variable de entorno puede sobreescribir su ubicación?

**Pregunta 1.2:** ¿Qué diferencia hay entre un *cluster*, un *user* y un *context* dentro de un kubeconfig?

## Ejercicio 2: Namespaces como límite administrativo

1. Listá todos los namespaces del cluster:
   ```bash
   kubectl get namespaces
   ```
2. Volvé al context original (sin namespace fijo):
   ```bash
   kubectl config use-context <tu-context-original>
   ```
3. Creá un segundo namespace:
   ```bash
   kubectl create namespace equipo-b
   ```
4. Desplegá el mismo nombre de recurso en ambos namespaces para comprobar que no colisionan:
   ```bash
   kubectl -n admin-demo create deployment web --image=nginx
   kubectl -n equipo-b create deployment web --image=nginx
   ```
5. Listá los Deployments en todos los namespaces a la vez:
   ```bash
   kubectl get deployments --all-namespaces
   ```
6. Intentá acceder a un recurso de `equipo-b` sin especificar namespace estando en el context default:
   ```bash
   kubectl get deployment web
   ```

**Pregunta 2.1:** ¿Por qué no hay conflicto entre los dos Deployments llamados `web`?

**Pregunta 2.2:** Nombrá dos recursos de Kubernetes que **no** son namespaced (viven a nivel de cluster).

## Ejercicio 3: ConfigMaps y Secrets

1. Creá un ConfigMap a partir de literales:
   ```bash
   kubectl -n admin-demo create configmap app-config \
     --from-literal=LOG_LEVEL=debug \
     --from-literal=ENV=staging
   ```
2. Inspeccioná su contenido:
   ```bash
   kubectl -n admin-demo get configmap app-config -o yaml
   ```
3. Creá un Secret de tipo genérico:
   ```bash
   kubectl -n admin-demo create secret generic app-secret \
     --from-literal=DB_PASSWORD=s3cr3t
   ```
4. Confirmá que el valor está en Base64, no cifrado:
   ```bash
   kubectl -n admin-demo get secret app-secret -o jsonpath='{.data.DB_PASSWORD}' | base64 -d
   ```
5. Montá ambos como variables de entorno en un Pod nuevo:
   ```yaml
   # pod-config.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: app-with-config
     namespace: admin-demo
   spec:
     containers:
       - name: app
         image: nginx
         envFrom:
           - configMapRef:
               name: app-config
           - secretRef:
               name: app-secret
   ```
   ```bash
   kubectl apply -f pod-config.yaml
   ```
6. Verificá las variables dentro del contenedor:
   ```bash
   kubectl -n admin-demo exec app-with-config -- env | grep -E "LOG_LEVEL|DB_PASSWORD"
   ```

**Pregunta 3.1:** ¿Por qué un Secret no debe considerarse un mecanismo de cifrado por sí solo?

**Pregunta 3.2:** ¿Qué ventaja administrativa da separar la configuración (ConfigMap/Secret) de la imagen del contenedor?

## Ejercicio 4: RBAC básico

1. Creá un ServiceAccount dedicado:
   ```bash
   kubectl -n admin-demo create serviceaccount viewer-sa
   ```
2. Definí un Role con permisos de solo lectura sobre Pods:
   ```yaml
   # role-pod-reader.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: Role
   metadata:
     namespace: admin-demo
     name: pod-reader
   rules:
     - apiGroups: [""]
       resources: ["pods"]
       verbs: ["get", "list", "watch"]
   ```
   ```bash
   kubectl apply -f role-pod-reader.yaml
   ```
3. Enlazá el Role al ServiceAccount con un RoleBinding:
   ```yaml
   # rolebinding-pod-reader.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: pod-reader-binding
     namespace: admin-demo
   subjects:
     - kind: ServiceAccount
       name: viewer-sa
       namespace: admin-demo
   roleRef:
     kind: Role
     name: pod-reader
     apiGroup: rbac.authorization.k8s.io
   ```
   ```bash
   kubectl apply -f rolebinding-pod-reader.yaml
   ```
4. Verificá los permisos efectivos con `auth can-i`:
   ```bash
   kubectl auth can-i list pods \
     --namespace=admin-demo \
     --as=system:serviceaccount:admin-demo:viewer-sa

   kubectl auth can-i delete pods \
     --namespace=admin-demo \
     --as=system:serviceaccount:admin-demo:viewer-sa
   ```

**Pregunta 4.1:** ¿Qué diferencia hay entre un `Role` y un `ClusterRole`?

**Pregunta 4.2:** En el paso 4, ¿por qué el segundo comando debería devolver `no`?

## Ejercicio 5: Resource requests, limits y ResourceQuota

1. Desplegá un Pod con requests y limits explícitos:
   ```yaml
   # pod-resources.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: app-with-resources
     namespace: admin-demo
   spec:
     containers:
       - name: app
         image: nginx
         resources:
           requests:
             cpu: "100m"
             memory: "64Mi"
           limits:
             cpu: "250m"
             memory: "128Mi"
   ```
   ```bash
   kubectl apply -f pod-resources.yaml
   ```
2. Confirmá los valores asignados:
   ```bash
   kubectl -n admin-demo describe pod app-with-resources | grep -A4 Limits
   ```
3. Aplicá un ResourceQuota al namespace:
   ```yaml
   # quota-admin-demo.yaml
   apiVersion: v1
   kind: ResourceQuota
   metadata:
     name: cpu-mem-quota
     namespace: admin-demo
   spec:
     hard:
       requests.cpu: "1"
       requests.memory: 1Gi
       limits.cpu: "2"
       limits.memory: 2Gi
   ```
   ```bash
   kubectl apply -f quota-admin-demo.yaml
   ```
4. Consultá el uso actual contra la quota:
   ```bash
   kubectl -n admin-demo describe resourcequota cpu-mem-quota
   ```
5. Intentá crear un Pod **sin** requests/limits en ese namespace y observá qué ocurre:
   ```bash
   kubectl -n admin-demo run sin-limites --image=nginx
   ```

**Pregunta 5.1:** ¿Qué diferencia hay entre `requests` y `limits`?

**Pregunta 5.2:** Si un namespace tiene un `ResourceQuota` con `requests.cpu` definido, ¿qué pasa al intentar crear un Pod que no especifica `resources.requests`?

<details>
<summary><strong>Ver respuestas</strong></summary>

**1.1:** `kubectl` lee `~/.kube/config` por default. La variable `KUBECONFIG` puede apuntar a uno o varios archivos alternativos (separados por `:` en Linux/macOS o `;` en Windows), que se mergean.

**1.2:** El *cluster* define el endpoint de la API y su CA cert; el *user* define las credenciales de autenticación (cert, token, etc.); el *context* combina un cluster + un user + un namespace default en una única referencia con nombre.

**2.1:** El nombre de un recurso namespaced solo debe ser único dentro de su namespace, no en todo el cluster. `admin-demo/web` y `equipo-b/web` son objetos distintos con la misma clave de nombre pero distinto namespace.

**2.2:** Ejemplos de recursos cluster-scoped: `Node`, `PersistentVolume`, `ClusterRole`, `ClusterRoleBinding`, `Namespace` mismo. (Cualquiera de estos es válido.)

**3.1:** Por default los Secrets solo están codificados en Base64, no cifrados — cualquiera con acceso de lectura al objeto (o a etcd sin cifrado en reposo) puede decodificar el valor trivialmente. La confidencialidad real requiere encryption at rest en etcd y/o RBAC estricto sobre el recurso `secrets`.

**3.2:** Permite reusar la misma imagen de contenedor en distintos entornos (dev/staging/prod) cambiando solo el ConfigMap/Secret, sin rebuildear la imagen, y facilita rotar configuración o credenciales sin tocar el Deployment.

**4.1:** Un `Role` otorga permisos dentro de un namespace específico; un `ClusterRole` otorga permisos a nivel de todo el cluster (o sobre recursos no namespaced), y también puede usarse dentro de un namespace vía RoleBinding para reusar definiciones comunes.

**4.2:** Porque el Role `pod-reader` solo incluye los verbs `get`, `list` y `watch` — no incluye `delete`, así que el ServiceAccount `viewer-sa` no tiene permiso para borrar Pods.

**5.1:** `requests` es lo que el scheduler garantiza reservar para el contenedor al elegir un Node (mínimo garantizado); `limits` es el techo máximo que el contenedor puede consumir antes de ser throttled (CPU) o killed por OOM (memoria).

**5.2:** Si el ResourceQuota define `requests.cpu` (o `requests.memory`) como *hard limit*, todo Pod creado en ese namespace queda obligado a declarar `resources.requests` explícitamente — de lo contrario el API server rechaza la creación con un error de validación de quota.

</details>