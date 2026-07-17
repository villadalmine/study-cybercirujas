# CKS 2.2 — Manage Kubernetes Secrets

Ejercicios guiados sobre creación, almacenamiento, cifrado en reposo, control de acceso y consumo seguro de `Secrets` en Kubernetes. Fuente de referencia: [CKS Curriculum v1.34](https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf).

> Requisitos: cluster kubeadm con acceso `root` al control plane (para editar el manifest del `kube-apiserver` y consultar `etcd` directamente).

## Ejercicio 1: Crear y decodificar Secrets

1. Creá un `Secret` de forma imperativa con dos claves:

```bash
kubectl create secret generic app-db-creds \
  --from-literal=username=admin \
  --from-literal=password='S3cr3t-Pass!'
```

2. Inspeccioná el objeto en formato YAML:

```bash
kubectl get secret app-db-creds -o yaml
```

3. Decodificá el valor de `password` que aparece en `data`:

```bash
kubectl get secret app-db-creds -o jsonpath='{.data.password}' | base64 -d
echo
```

4. Ahora creá el mismo `Secret` de forma declarativa usando `stringData` (Kubernetes se encarga de codificar a base64 al guardarlo):

```yaml
# db-creds.yaml
apiVersion: v1
kind: Secret
metadata:
  name: app-db-creds-declarative
type: Opaque
stringData:
  username: admin
  password: S3cr3t-Pass!
```

```bash
kubectl apply -f db-creds.yaml
kubectl get secret app-db-creds-declarative -o yaml
```

**Preguntas de verificación**
- ¿Por qué la codificación base64 en `data` no debe considerarse una medida de seguridad?
- ¿Qué riesgo concreto implica versionar en Git un manifest de `Secret` con `stringData` en texto plano?

## Ejercicio 2: Verificar cómo se almacena un Secret en etcd por defecto

1. Ubicá los certificados de cliente que usa el `kube-apiserver` para hablar con `etcd` (en un cluster kubeadm típico):

```bash
ls /etc/kubernetes/pki/apiserver-etcd-client.crt /etc/kubernetes/pki/apiserver-etcd-client.key /etc/kubernetes/pki/etcd/ca.crt
```

2. Consultá directamente el registro del `Secret` creado en el Ejercicio 1, sin pasar por la API de Kubernetes:

```bash
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/apiserver-etcd-client.crt \
  --key=/etc/kubernetes/pki/apiserver-etcd-client.key \
  get /registry/secrets/default/app-db-creds
```

3. Observá que el valor `S3cr3t-Pass!` aparece codificado en base64 dentro del objeto, sin ningún prefijo de cifrado.

**Preguntas de verificación**
- ¿Qué componente del control plane es el único que debería tener acceso directo a `etcd`, y por qué el acceso a los discos/backups de `etcd` equivale a acceso de lectura a todos los Secrets del cluster?
- Si alguien obtiene un `etcd` snapshot sin que el cluster tenga *encryption at rest* habilitado, ¿qué puede hacer con él?

## Ejercicio 3: Habilitar encryption at rest para Secrets

1. Generá una clave AES de 32 bytes y armá el `EncryptionConfiguration`:

```bash
sudo mkdir -p /etc/kubernetes/enc
KEY=$(head -c 32 /dev/urandom | base64)
cat <<EOF | sudo tee /etc/kubernetes/enc/encryption-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${KEY}
      - identity: {}
EOF
```

2. Editá el manifest estático del `kube-apiserver` para que use este archivo:

```bash
sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml
```

Agregá el flag y el `volumeMount`/`hostPath` correspondientes:

```yaml
    - --encryption-provider-config=/etc/kubernetes/enc/encryption-config.yaml
```

```yaml
    volumeMounts:
      - name: enc
        mountPath: /etc/kubernetes/enc
        readOnly: true
  volumes:
    - name: enc
      hostPath:
        path: /etc/kubernetes/enc
        type: DirectoryOrCreate
```

3. Esperá a que el `kube-apiserver` (kubelet lo reinicia automáticamente al detectar el cambio del manifest) esté disponible de nuevo:

```bash
kubectl get pods -n kube-system -l component=kube-apiserver -w
```

4. Los Secrets creados **antes** de este cambio no se re-escriben solos. Forzá la reescritura del que ya existe:

```bash
kubectl get secret app-db-creds -o json | kubectl replace -f -
```

5. Repetí la consulta directa a `etcd` del Ejercicio 2 y compará el resultado.

**Preguntas de verificación**
- Tras el paso 5, ¿qué prefijo esperás ver antes del valor cifrado en la salida de `etcdctl get`?
- El `EncryptionConfiguration` lista `aescbc` antes que `identity`. ¿Qué provider se usa para **escribir** datos nuevos y qué rol cumplen los providers restantes en la lista al **leer**?
- ¿Por qué `app-db-creds-declarative` (creado en el Ejercicio 1) seguiría en texto plano en `etcd` si no se lo vuelve a escribir?

## Ejercicio 4: Restringir el acceso a Secrets con RBAC

1. Creá un namespace y un `ServiceAccount` de aplicación:

```bash
kubectl create namespace app-ns
kubectl create serviceaccount app-sa -n app-ns
```

2. Definí un `Role` que solo permita `get` sobre un `Secret` puntual (no `list`, no acceso al resto):

```yaml
# role-secret-reader.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: app-ns
  name: secret-reader
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["app-db-creds"]
    verbs: ["get"]
```

```bash
kubectl apply -f role-secret-reader.yaml
kubectl create rolebinding secret-reader-binding \
  --role=secret-reader --serviceaccount=app-ns:app-sa -n app-ns
```

3. Validá los permisos efectivos:

```bash
kubectl auth can-i get secret/app-db-creds -n app-ns \
  --as=system:serviceaccount:app-ns:app-sa
kubectl auth can-i list secrets -n app-ns \
  --as=system:serviceaccount:app-ns:app-sa
```

**Preguntas de verificación**
- ¿Por qué otorgar el verbo `list` sobre `secrets` es más riesgoso que otorgar `get` con `resourceNames` acotado, aunque ninguno de los dos incluya `watch`?
- Si necesitás que la aplicación lea múltiples Secrets sin conocer sus nombres de antemano, ¿qué alternativa de diseño (fuera de ampliar el RBAC) reduce el radio de exposición?

## Ejercicio 5: Consumir Secrets de forma segura en un Pod

1. Montá el `Secret` como volumen (patrón preferido) en lugar de inyectarlo como variable de entorno:

```yaml
# pod-secret-volume.yaml
apiVersion: v1
kind: Pod
metadata:
  name: app-secret-vol
  namespace: app-ns
spec:
  serviceAccountName: app-sa
  containers:
    - name: app
      image: nginx:1.27
      volumeMounts:
        - name: db-creds
          mountPath: /etc/secrets/db-creds
          readOnly: true
  volumes:
    - name: db-creds
      secret:
        secretName: app-db-creds
```

```bash
kubectl apply -f pod-secret-volume.yaml
kubectl exec app-secret-vol -n app-ns -- ls /etc/secrets/db-creds
kubectl exec app-secret-vol -n app-ns -- cat /etc/secrets/db-creds/password
```

2. Marcá el `Secret` como inmutable para evitar modificaciones accidentales o maliciosas:

```bash
kubectl patch secret app-db-creds -p '{"immutable": true}'
```

3. Intentá modificar un valor del `Secret` inmutable y observá el error:

```bash
kubectl patch secret app-db-creds -p '{"stringData":{"password":"otra-clave"}}'
```

**Preguntas de verificación**
- ¿Por qué montar el `Secret` como volumen es más seguro que inyectarlo vía `env`/`envFrom` (pensá en `kubectl exec ... env`, logs de crash y procesos hijo)?
- ¿Qué error devuelve el paso 3 y qué acción hay que tomar en su lugar para "actualizar" un `Secret` inmutable?
- Además de la seguridad, ¿qué ventaja de rendimiento en el `kube-apiserver` aporta marcar Secrets como `immutable: true`?

---

<details>
<summary>Ver respuestas</summary>

### Ejercicio 1
- Base64 es una **codificación**, no un cifrado: cualquiera con acceso de lectura al objeto (`kubectl get secret -o yaml`, un backup de `etcd`, o el YAML mismo) puede revertirla con `base64 -d` sin ninguna clave. No aporta confidencialidad.
- Versionar `stringData` en Git deja la credencial en texto plano en el historial del repositorio para siempre (incluso si se borra en un commit posterior), accesible a cualquiera con acceso al repo o a un fork/clon previo.

### Ejercicio 2
- Solo el `kube-apiserver` debería tener credenciales de cliente TLS para hablar con `etcd`. Como `etcd` almacena **todos** los objetos del cluster —incluidos todos los Secrets de todos los namespaces— sin cifrado por defecto, cualquiera con acceso al disco de `etcd` o a sus snapshots tiene de facto acceso de lectura a cada Secret del cluster, sin pasar por RBAC.
- Con un snapshot de `etcd` sin *encryption at rest*, se puede extraer y decodificar en base64 el valor de cualquier Secret directamente, sin necesitar credenciales de Kubernetes ni pasar controles de RBAC.

### Ejercicio 3
- El prefijo esperado es `k8s:enc:aescbc:v1:key1:` seguido de los bytes cifrados.
- El primer provider de la lista (`aescbc`) es el que se usa para **escribir** (cifrar) datos nuevos. Todos los providers listados se intentan en orden al **leer** (descifrar), lo que permite mantener `identity` (sin cifrar) como fallback para leer objetos viejos durante una migración, o rotar de un provider/clave a otro sin perder acceso a datos ya escritos.
- Porque el `EncryptionConfiguration` solo afecta escrituras nuevas hacia `etcd`; los objetos existentes no se reescriben automáticamente al habilitar cifrado. Sin un `kubectl replace`/`get | replace` (o el `kube-controller-manager` en un rollout masivo tipo `kubectl get secrets --all-namespaces -o json | kubectl replace -f -`), siguen almacenados como estaban antes del cambio.

### Ejercicio 4
- `list` devuelve (o permite enumerar mediante `watch`/paginación) el conjunto completo de Secrets del namespace, revelando nombres y metadata de credenciales que la aplicación no necesita conocer, y amplía la superficie si el `ServiceAccount` se ve comprometido. `get` con `resourceNames` acotado limita el acceso a un objeto puntual y conocido de antemano — principio de mínimo privilegio.
- Usar un secret-store externo (Vault, un *External Secrets Operator*, o inyección vía *sidecar*/CSI driver de secretos) para que la aplicación obtenga credenciales fuera de la API de Kubernetes, evitando ampliar los permisos RBAC sobre el recurso `secrets`.

### Ejercicio 5
- Un volumen montado no queda expuesto en `kubectl exec ... env`, no aparece en variables de entorno heredadas por procesos hijo del contenedor, y no suele filtrarse en logs de crash/dump de proceso como sí puede pasar con variables de entorno. Además, Kubernetes actualiza el contenido del archivo montado cuando cambia el Secret (con volúmenes no proyectados esto no aplica igual a env vars, que quedan fijas hasta reiniciar el Pod).
- Devuelve un error indicando que el campo `data`/`stringData` no puede modificarse porque el objeto es inmutable (`Secret ... is immutable`). Para "actualizar" hay que borrar y recrear el `Secret` (o crear uno nuevo con otro nombre y actualizar las referencias en los Pods).
- Reduce la carga del `kube-apiserver`: como el contenido no puede cambiar, el `kubelet` no necesita mantener un `watch` activo sobre ese Secret para detectar actualizaciones, lo que baja la presión sobre el apiserver en clusters con muchos Secrets.

</details>