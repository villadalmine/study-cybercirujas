# 4.5 Understand ConfigMaps

## ¿Qué es un ConfigMap?

Un **ConfigMap** es un objeto de la API de Kubernetes que permite desacoplar la configuración de una aplicación de la imagen de contenedor que la ejecuta. En lugar de hardcodear valores como URLs de servicios, flags de features, niveles de log o archivos de configuración dentro de la imagen, se externalizan en un ConfigMap y se inyectan en el Pod en tiempo de ejecución.

Un ConfigMap almacena pares `clave: valor` como texto plano (no binario). **No está pensado para datos sensibles** — para eso existe el objeto `Secret` (tema 4.6), que tiene el mismo modelo de uso pero con algunas protecciones adicionales (aunque por defecto tampoco cifra en reposo sin configuración extra).

Puntos clave que evalúa el examen:
- Crear ConfigMaps de forma imperativa y declarativa.
- Consumirlos como **variables de entorno** o como **archivos montados** (volumes).
- Entender qué pasa cuando se actualiza un ConfigMap ya en uso por un Pod.

## Creación de ConfigMaps

### Forma imperativa

```bash
# Desde literales clave=valor
kubectl create configmap app-config \
  --from-literal=LOG_LEVEL=debug \
  --from-literal=GREETING="hola mundo"

# Desde un archivo (la clave será el nombre del archivo)
echo "color.background=blue" > ui.properties
kubectl create configmap ui-config --from-file=ui.properties

# Desde un archivo con una clave explícita
kubectl create configmap ui-config --from-file=ui.properties=ui.properties

# Desde un directorio completo (una clave por archivo)
kubectl create configmap ui-config --from-file=./config-dir/

# Desde un env-file (formato KEY=VALUE por línea, sin comillas)
cat <<EOF > app.env
LOG_LEVEL=debug
GREETING=hola mundo
EOF
kubectl create configmap app-config --from-env-file=app.env
```

### Forma declarativa

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
data:
  LOG_LEVEL: "debug"
  GREETING: "hola mundo"
  app.properties: |
    max.connections=100
    timeout=30s
```

```bash
kubectl apply -f app-config.yaml
```

### Inspeccionar ConfigMaps

```bash
kubectl get configmaps
```

```
NAME               DATA   AGE
app-config         3      12s
kube-root-ca.crt   1      4d
```

```bash
kubectl describe configmap app-config
```

```
Name:         app-config
Namespace:    default
Labels:       <none>
Annotations:  <none>

Data
====
LOG_LEVEL:
----
debug
GREETING:
----
hola mundo
app.properties:
----
max.connections=100
timeout=30s

BinaryData
====

Events:  <none>
```

## Consumo de ConfigMaps en un Pod

### Como variables de entorno individuales

Se referencia una clave específica con `env.valueFrom.configMapKeyRef`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: envvar-pod
spec:
  containers:
  - name: app
    image: nginx
    env:
    - name: LOG_LEVEL
      valueFrom:
        configMapKeyRef:
          name: app-config
          key: LOG_LEVEL
```

### Todas las claves como variables de entorno

Con `envFrom` se inyectan todas las claves del ConfigMap de una vez; cada clave se convierte en el nombre de la variable:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: envfrom-pod
spec:
  containers:
  - name: app
    image: nginx
    envFrom:
    - configMapRef:
        name: app-config
```

```bash
kubectl exec envfrom-pod -- env | grep -E 'LOG_LEVEL|GREETING'
```

```
LOG_LEVEL=debug
GREETING=hola mundo
```

> Nota: `envFrom` solo funciona con claves cuyo nombre sea válido como variable de entorno (letras, números y `_`). Las claves inválidas se omiten y Kubernetes genera un evento de tipo `Warning` (`InvalidVariableNames`).

### Como archivos montados (volume)

Es la forma recomendada cuando la aplicación espera un archivo de configuración (por ejemplo, `app.properties`, `nginx.conf`) en lugar de variables de entorno:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: volume-pod
spec:
  containers:
  - name: app
    image: nginx
    volumeMounts:
    - name: config-vol
      mountPath: /etc/config
  volumes:
  - name: config-vol
    configMap:
      name: app-config
```

Cada clave del ConfigMap aparece como un archivo dentro de `/etc/config`, con el contenido de la clave como contenido del archivo:

```bash
kubectl exec volume-pod -- ls /etc/config
```

```
GREETING
LOG_LEVEL
app.properties
```

```bash
kubectl exec volume-pod -- cat /etc/config/app.properties
```

```
max.connections=100
timeout=30s
```

### Montar solo una clave con `subPath`

Si solo se necesita un archivo puntual (evitando que el volumen sobrescriba todo el directorio destino):

```yaml
    volumeMounts:
    - name: config-vol
      mountPath: /etc/nginx/nginx.conf
      subPath: nginx.conf
```

> Importante: cuando se usa `subPath`, ese archivo **no se actualiza automáticamente** al cambiar el ConfigMap (a diferencia del montaje de directorio completo). Es una diferencia sutil que el examen puede evaluar.

### Selección de claves específicas en el volume

También se puede filtrar/renombrar qué claves se proyectan:

```yaml
  volumes:
  - name: config-vol
    configMap:
      name: app-config
      items:
      - key: app.properties
        path: application.properties
```

## Actualización de ConfigMaps y propagación de cambios

```bash
kubectl edit configmap app-config
# o
kubectl create configmap app-config --from-literal=LOG_LEVEL=info --dry-run=client -o yaml | kubectl apply -f -
```

Comportamiento a tener en cuenta:

| Método de consumo | ¿Se actualiza en caliente? |
|---|---|
| Variables de entorno (`env` / `envFrom`) | **No.** El Pod debe reiniciarse (recrear el contenedor) para tomar el nuevo valor. |
| Volume montado (directorio completo) | **Sí**, el kubelet sincroniza el contenido periódicamente (por defecto cada ~1 minuto, según el `sync period` del kubelet), pero la aplicación dentro del contenedor debe soportar recargar el archivo en caliente. |
| Volume con `subPath` | **No.** El archivo queda fijo al valor del momento del montaje. |

Un patrón común para forzar un rollout cuando cambia la config es incluir un hash del ConfigMap como anotación o label en el `template` del Deployment, de modo que el cambio dispare un nuevo rollout de Pods.

### `immutable: true`

Desde Kubernetes 1.21 los ConfigMaps soportan el campo `immutable`, que impide modificaciones posteriores. Se usa para configuraciones que no deben cambiar en la vida del objeto, mejorando performance del `kube-apiserver` (evita que el kubelet tenga que hacer watch de esos ConfigMaps) y previniendo cambios accidentales:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
data:
  LOG_LEVEL: "debug"
immutable: true
```

Para cambiar un valor de un ConfigMap inmutable hay que crear uno nuevo (por ejemplo con sufijo de versión o hash) y actualizar la referencia en el Pod/Deployment.

## Límites y buenas prácticas

- Un ConfigMap tiene un límite de tamaño total de **1 MiB** (limitación de `etcd`).
- Si una clave referenciada en `configMapKeyRef` no existe, el Pod queda en `CreateContainerConfigError` a menos que se marque `optional: true`.
- Para archivos de configuración grandes o binarios, evaluar volúmenes persistentes o `initContainers` en lugar de ConfigMaps.
- Usar nombres de ConfigMap versionados (o `immutable: true`) en producción para tener rollbacks predecibles junto con el Deployment.

## Referencias

- ConfigMaps — documentación oficial: https://kubernetes.io/docs/concepts/configuration/configmap/
- Configure a Pod to Use a ConfigMap: https://kubernetes.io/docs/tasks/configure-pod-container/configure-pod-configmap/
- kubectl create configmap — referencia de CLI: https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#create-configmap
- CKAD Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf