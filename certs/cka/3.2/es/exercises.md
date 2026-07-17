# CKA 1.35 — Tema 3.2: Use ConfigMaps and Secrets to configure applications

**Peso en el examen:** 2.5
**Fuente de referencia:** [CKA Curriculum v1.35 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)

Antes de empezar, asegurate de tener un cluster disponible y el namespace de trabajo:

```bash
kubectl create namespace cm-secrets-lab
kubectl config set-context --current --namespace=cm-secrets-lab
```

---

## Ejercicio 1 — Crear un ConfigMap desde literales

1. Creá un ConfigMap con dos pares clave-valor usando `--from-literal`:

```bash
kubectl create configmap app-config \
  --from-literal=APP_COLOR=blue \
  --from-literal=APP_MODE=production
```

2. Inspeccioná el objeto creado:

```bash
kubectl get configmap app-config -o yaml
kubectl describe configmap app-config
```

> **Pregunta 1:** ¿En qué campo del manifiesto YAML de un ConfigMap se almacenan los pares clave-valor?
>
> **Pregunta 2:** ¿Un ConfigMap puede contener datos binarios? Si no es así, ¿qué campo se usa para eso?

---

## Ejercicio 2 — Crear un ConfigMap desde un archivo

1. Generá un archivo de propiedades local:

```bash
cat <<EOF > app.properties
LOG_LEVEL=debug
MAX_CONNECTIONS=100
EOF
```

2. Creá el ConfigMap a partir del archivo:

```bash
kubectl create configmap app-config-file --from-file=app.properties
```

3. Observá cómo se nombra la clave dentro del ConfigMap:

```bash
kubectl get configmap app-config-file -o jsonpath='{.data}'
```

4. Repetí la creación pero forzando un nombre de clave distinto al del archivo:

```bash
kubectl create configmap app-config-file-2 --from-file=custom-key=app.properties
```

> **Pregunta 3:** ¿Qué clave usa Kubernetes por defecto cuando creás un ConfigMap con `--from-file=app.properties` sin especificar nombre de clave?
>
> **Pregunta 4:** ¿Qué diferencia práctica hay entre usar `--from-file` con un archivo individual y usar `--from-file` apuntando a un directorio?

---

## Ejercicio 3 — Consumir un ConfigMap como variables de entorno individuales

1. Creá un manifiesto de Pod que consuma claves puntuales del ConfigMap `app-config` vía `env`:

```yaml
# pod-env-single.yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-env-single
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "env | grep APP_ && sleep 3600"]
    env:
    - name: APP_COLOR
      valueFrom:
        configMapKeyRef:
          name: app-config
          key: APP_COLOR
```

2. Aplicá el manifiesto y verificá el resultado en los logs:

```bash
kubectl apply -f pod-env-single.yaml
kubectl logs pod-env-single
```

> **Pregunta 5:** Si la clave `APP_COLOR` no existiera en el ConfigMap `app-config`, ¿qué le pasaría al Pod al iniciar?

---

## Ejercicio 4 — Inyectar todas las claves de un ConfigMap con `envFrom`

1. Modificá el manifiesto anterior para traer **todas** las claves de `app-config` de una sola vez:

```yaml
# pod-envfrom.yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-envfrom
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "env | sort && sleep 3600"]
    envFrom:
    - configMapRef:
        name: app-config
      prefix: CFG_
```

2. Aplicá y revisá que las variables aparezcan con el prefijo `CFG_`:

```bash
kubectl apply -f pod-envfrom.yaml
kubectl logs pod-envfrom | grep CFG_
```

> **Pregunta 6:** ¿Qué ocurre si dos fuentes distintas en `envFrom` (por ejemplo dos ConfigMaps) definen la misma clave?
>
> **Pregunta 7:** ¿Para qué sirve el campo `prefix` dentro de `envFrom`?

---

## Ejercicio 5 — Montar un ConfigMap como volumen

1. Creá un Pod que monte `app-config-file` como un volumen de solo lectura:

```yaml
# pod-cm-volume.yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-cm-volume
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: config-vol
      mountPath: /etc/config
      readOnly: true
  volumes:
  - name: config-vol
    configMap:
      name: app-config-file
```

2. Aplicá el manifiesto y listá el contenido montado:

```bash
kubectl apply -f pod-cm-volume.yaml
kubectl exec pod-cm-volume -- ls /etc/config
kubectl exec pod-cm-volume -- cat /etc/config/app.properties
```

> **Pregunta 8:** ¿Cómo se traduce cada clave del ConfigMap dentro del directorio montado?
>
> **Pregunta 9:** Si querés montar solo una clave específica del ConfigMap (en vez de todas), ¿qué campo del volumen usarías?

---

## Ejercicio 6 — Crear un Secret genérico

1. Creá un Secret de tipo `generic` con una credencial:

```bash
kubectl create secret generic db-secret \
  --from-literal=DB_USER=admin \
  --from-literal=DB_PASSWORD='S3cr3tP@ss'
```

2. Inspeccioná el objeto y notá cómo se almacenan los valores:

```bash
kubectl get secret db-secret -o yaml
```

3. Decodificá manualmente un valor:

```bash
kubectl get secret db-secret -o jsonpath='{.data.DB_PASSWORD}' | base64 -d
echo
```

> **Pregunta 10:** ¿El campo `data` de un Secret almacena los valores cifrados o solo codificados en base64?
>
> **Pregunta 11:** ¿Qué medidas adicionales del cluster (fuera del objeto Secret en sí) hacen falta para que los Secrets estén realmente protegidos en `etcd`?

---

## Ejercicio 7 — Consumir un Secret como variable de entorno

1. Creá un Pod que use `secretKeyRef` para inyectar `DB_PASSWORD`:

```yaml
# pod-secret-env.yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-secret-env
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "echo DB_PASSWORD=$DB_PASSWORD && sleep 3600"]
    env:
    - name: DB_PASSWORD
      valueFrom:
        secretKeyRef:
          name: db-secret
          key: DB_PASSWORD
```

2. Aplicá y verificá:

```bash
kubectl apply -f pod-secret-env.yaml
kubectl logs pod-secret-env
```

> **Pregunta 12:** ¿Por qué inyectar Secrets como variables de entorno se considera más riesgoso que montarlos como volumen, en términos de exposición (por ejemplo en `kubectl describe pod` o en logs de crash)?

---

## Ejercicio 8 — Montar un Secret como volumen

1. Creá un Pod que monte `db-secret` como volumen con permisos restringidos:

```yaml
# pod-secret-volume.yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-secret-volume
spec:
  containers:
  - name: app
    image: busybox
    command: ["sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: secret-vol
      mountPath: /etc/secret
      readOnly: true
  volumes:
  - name: secret-vol
    secret:
      secretName: db-secret
      defaultMode: 0400
```

2. Aplicá y verificá los permisos y contenido de los archivos:

```bash
kubectl apply -f pod-secret-volume.yaml
kubectl exec pod-secret-volume -- ls -l /etc/secret
kubectl exec pod-secret-volume -- cat /etc/secret/DB_USER
```

> **Pregunta 13:** ¿En qué unidad se expresa `defaultMode` y qué representa el valor `0400`?

---

## Ejercicio 9 — Propagación de actualizaciones

1. Actualizá una clave del ConfigMap `app-config-file` con `kubectl edit` o `kubectl patch`:

```bash
kubectl patch configmap app-config-file \
  --type merge \
  -p '{"data":{"app.properties":"LOG_LEVEL=info\nMAX_CONNECTIONS=200\n"}}'
```

2. Esperá un minuto (el kubelet sincroniza periódicamente) y revisá el archivo montado en `pod-cm-volume`:

```bash
kubectl exec pod-cm-volume -- cat /etc/config/app.properties
```

3. Ahora revisá si la variable de entorno inyectada en `pod-envfrom` (Ejercicio 4) cambió:

```bash
kubectl exec pod-envfrom -- env | grep CFG_LOG_LEVEL
```

> **Pregunta 14:** ¿Por qué el volumen montado eventualmente refleja el cambio, pero la variable de entorno no?
>
> **Pregunta 15:** Si el volumen usa `subPath` para montar una única clave (en vez de todo el ConfigMap como directorio), ¿el archivo se actualiza igual cuando el ConfigMap cambia?

---

## Ejercicio 10 — ConfigMaps y Secrets inmutables

1. Creá un ConfigMap marcado como inmutable:

```yaml
# cm-immutable.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config-immutable
data:
  APP_VERSION: "1.0.0"
immutable: true
```

```bash
kubectl apply -f cm-immutable.yaml
```

2. Intentá modificar una clave:

```bash
kubectl patch configmap app-config-immutable \
  --type merge -p '{"data":{"APP_VERSION":"2.0.0"}}'
```

3. Observá el mensaje de error devuelto por el API server.

> **Pregunta 16:** ¿Qué dos beneficios operativos trae marcar un ConfigMap o Secret como `immutable: true` en clusters grandes?
>
> **Pregunta 17:** Si necesitás cambiar el valor de un ConfigMap inmutable, ¿cuál es el flujo de trabajo correcto?

---

## Limpieza

```bash
kubectl delete namespace cm-secrets-lab
```

---

<details>
<summary><strong>Respuestas</strong></summary>

**1.** En el campo `data` (pares clave-valor de texto plano). Si son datos binarios codificados en base64, van en `binaryData`.

**2.** No directamente en `data` (que espera strings UTF-8); para datos binarios se usa el campo `binaryData`, donde el valor va codificado en base64.

**3.** Usa el nombre base del archivo como clave, en este caso `app.properties`.

**4.** Con un archivo individual, la clave del ConfigMap es el nombre de ese archivo y el valor es su contenido completo. Con un directorio, `--from-file` crea una clave por cada archivo del directorio (los subdirectorios se ignoran), útil para cargar múltiples archivos de configuración de una sola vez.

**5.** El contenedor no arranca: el kubelet queda en estado `CreateContainerConfigError` (el Pod se ve como `Pending`/`Error` según el kubectl que se use) hasta que la clave exista o se corrija la referencia.

**6.** Se produce un conflicto: si `envFrom` combina fuentes con claves duplicadas, la última fuente listada en el arreglo sobrescribe a las anteriores, y Kubernetes emite un warning (visible en `kubectl describe pod`) indicando la variable ignorada.

**7.** Antepone un prefijo a cada nombre de variable importada, para evitar colisiones de nombres o para namespacing lógico dentro del contenedor (por ejemplo `CFG_APP_COLOR` en vez de `APP_COLOR`).

**8.** Cada clave del ConfigMap se convierte en un archivo dentro del `mountPath`, y el contenido de ese archivo es el valor de la clave.

**9.** El campo `items` dentro de la definición del volumen (`configMap.items`), donde se especifica `key` y `path` para proyectar solo las claves deseadas y, opcionalmente, renombrarlas.

**10.** Solo están codificados en base64, no cifrados. Es una codificación reversible sin clave, pensada para poder almacenar bytes arbitrarios en YAML/JSON, no para dar confidencialidad.

**11.** Habilitar **encryption at rest** para el recurso `secrets` en el API server (`--encryption-provider-config`), restringir el acceso a `etcd`, usar RBAC estricto sobre el recurso `secrets`, y considerar un proveedor externo de secretos (KMS, Vault, etc.) vía CSI driver.

**12.** Las variables de entorno quedan visibles en `kubectl describe pod` (si no está redactado según el rol) y suelen filtrarse en dumps de proceso, mensajes de error o herramientas de terceros que loguean el entorno del proceso; un volumen montado no aparece de esa forma y puede protegerse mejor con permisos de archivo.

**13.** Se expresa en notación octal de permisos Unix (como `chmod`). `0400` significa lectura solo para el propietario (owner), sin permisos de escritura ni ejecución, y sin acceso para grupo u otros.

**14.** El volumen es sincronizado periódicamente por el kubelet (vía el mecanismo de proyección de `ConfigMap`/`Secret`, con un intervalo por defecto de sync del kubelet), por lo que el archivo se actualiza sin reiniciar el Pod. Las variables de entorno, en cambio, se resuelven una única vez al crear el contenedor; para reflejar el cambio hace falta recrear el Pod (por ejemplo, con un rollout del Deployment).

**15.** No. Cuando se usa `subPath` para montar un archivo individual, ese archivo **no** recibe actualizaciones automáticas al cambiar el ConfigMap/Secret de origen; es una limitación conocida del kubelet.

**16.** Evita actualizaciones accidentales que podrían romper aplicaciones que dependen de ese ConfigMap/Secret, y reduce la carga sobre el `kube-apiserver` porque el kubelet deja de hacer *watch* sobre esos objetos (mejora el rendimiento en clusters con muchos ConfigMaps/Secrets).

**17.** Crear un nuevo ConfigMap con otro nombre (por ejemplo, con un sufijo de versión o hash del contenido) y actualizar la referencia en el Pod/Deployment para que apunte al nuevo objeto, en vez de editar el existente.

</details>