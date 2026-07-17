# Ejercicios guiados — CKAD 4.5: Understand ConfigMaps

**Certificación:** CKAD v1.35 · **Dominio:** 4. Application Environment, Configuration and Security · **Tema:** 4.5 Understand ConfigMaps · **Peso:** 3

**Fuente de referencia:** [CNCF CKAD Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf)

Requisitos previos: un cluster con `kubectl` configurado (minikube, kind, o similar) y permisos para crear objetos en un namespace propio.

---

## Bloque 1 — Crear un ConfigMap desde distintas fuentes

1. Creá un namespace de trabajo para no interferir con otros recursos:

   ```bash
   kubectl create namespace ckad-cm
   kubectl config set-context --current --namespace=ckad-cm
   ```

2. Creá un ConfigMap a partir de pares literales `clave=valor`:

   ```bash
   kubectl create configmap app-config \
     --from-literal=APP_COLOR=blue \
     --from-literal=APP_MODE=production
   ```

3. Inspeccioná el objeto generado:

   ```bash
   kubectl get configmap app-config -o yaml
   ```

   Notá que ambas claves quedan bajo `data:` como pares independientes.

4. Creá un archivo de propiedades local:

   ```bash
   cat <<EOF > game.properties
   enemies=aliens
   lives=3
   EOF
   ```

5. Generá un ConfigMap a partir de ese archivo:

   ```bash
   kubectl create configmap game-config --from-file=game.properties
   kubectl describe configmap game-config
   ```

6. Repetí el paso anterior pero forzando el nombre de la clave (en vez de usar el nombre del archivo):

   ```bash
   kubectl create configmap game-config-2 \
     --from-file=game-conf=game.properties
   kubectl get configmap game-config-2 -o yaml
   ```

7. Creá un ConfigMap a partir de un "env file" (formato `CLAVE=valor` por línea, sin comillas ni espacios alrededor del `=`):

   ```bash
   cat <<EOF > app.env
   LOG_LEVEL=debug
   MAX_CONNECTIONS=100
   EOF

   kubectl create configmap env-config --from-env-file=app.env
   kubectl get configmap env-config -o yaml
   ```

**Preguntas de comprensión — Bloque 1**

1. ¿Qué diferencia estructural hay entre el ConfigMap creado con `--from-file=game.properties` (paso 5) y el creado con `--from-env-file=app.env` (paso 7)?
2. En el paso 6, ¿qué controla la sintaxis `--from-file=game-conf=game.properties`?
3. Si necesitaras que un ConfigMap contuviera todo el archivo `nginx.conf` como un único bloque de texto bajo una clave, ¿usarías `--from-literal`, `--from-file` o `--from-env-file`?

---

## Bloque 2 — Consumir un ConfigMap como variables de entorno

1. Creá un Pod que use una clave puntual del ConfigMap `app-config` como variable de entorno individual:

   ```yaml
   # pod-env-single.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-env-single
   spec:
     containers:
       - name: app
         image: busybox:1.36
         command: ["sh", "-c", "printenv COLOR && sleep 3600"]
         env:
           - name: COLOR
             valueFrom:
               configMapKeyRef:
                 name: app-config
                 key: APP_COLOR
   ```

   ```bash
   kubectl apply -f pod-env-single.yaml
   kubectl logs pod-env-single
   ```

2. Creá un segundo Pod que importe **todas** las claves del ConfigMap de una vez con `envFrom`:

   ```yaml
   # pod-envfrom.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-envfrom
   spec:
     containers:
       - name: app
         image: busybox:1.36
         command: ["sh", "-c", "printenv | sort && sleep 3600"]
         envFrom:
           - configMapRef:
               name: app-config
   ```

   ```bash
   kubectl apply -f pod-envfrom.yaml
   kubectl exec pod-envfrom -- printenv | grep APP_
   ```

3. Modificá `pod-env-single.yaml` para referenciar una clave inexistente (por ejemplo `APP_TIMEOUT`) y reaplicá con otro nombre de Pod. Observá el estado resultante:

   ```bash
   kubectl apply -f pod-env-single.yaml
   kubectl get pod pod-env-single
   kubectl describe pod pod-env-single
   ```

4. Agregá `optional: true` al `configMapKeyRef` de esa misma clave inexistente y volvé a aplicar. Verificá que el Pod ahora sí arranca (sin esa variable definida).

**Preguntas de comprensión — Bloque 2**

1. ¿Qué estado y motivo (`reason`) mostró `kubectl describe pod` en el paso 3, antes de agregar `optional: true`?
2. ¿Qué ventaja práctica tiene `envFrom` sobre declarar cada variable con `env` + `configMapKeyRef` cuando el ConfigMap tiene muchas claves?
3. Si una clave del ConfigMap se llama `app.mode` (con un punto) y la importás con `envFrom`, ¿qué ocurre con esa entrada al convertirse en variable de entorno del shell?

---

## Bloque 3 — Consumir un ConfigMap como volumen

1. Creá un Pod que monte `game-config` completo como volumen:

   ```yaml
   # pod-vol.yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-vol
   spec:
     containers:
       - name: app
         image: busybox:1.36
         command: ["sh", "-c", "sleep 3600"]
         volumeMounts:
           - name: config-volume
             mountPath: /etc/config
     volumes:
       - name: config-volume
         configMap:
           name: game-config
   ```

   ```bash
   kubectl apply -f pod-vol.yaml
   kubectl exec pod-vol -- ls /etc/config
   kubectl exec pod-vol -- cat /etc/config/game.properties
   ```

2. Modificá el volumen para proyectar solo una clave específica bajo un nombre de archivo distinto, usando `items`:

   ```yaml
   volumes:
     - name: config-volume
       configMap:
         name: game-config
         items:
           - key: game.properties
             path: game-settings.conf
   ```

   Reaplicá y confirmá que `/etc/config` ahora contiene únicamente `game-settings.conf`.

3. Cambiá el `mountPath` a un directorio del contenedor que ya tenga contenido propio (por ejemplo `/etc`) y observá qué pasa con los archivos preexistentes de esa ruta.

4. Revertí el `mountPath` a `/etc/config` y usá `subPath` para montar una única clave como archivo suelto dentro de un directorio existente sin ocultar el resto:

   ```yaml
   volumeMounts:
     - name: config-volume
       mountPath: /etc/config/game.properties
       subPath: game.properties
   ```

**Preguntas de comprensión — Bloque 3**

1. En el paso 3, ¿qué le pasó al contenido original del directorio montado?
2. ¿Qué diferencia práctica hay entre usar `items` (paso 2) y usar `subPath` (paso 4) para exponer una sola clave del ConfigMap?
3. ¿Por qué `subPath` es la opción recomendada cuando querés inyectar un único archivo de configuración dentro de un directorio que el propio container image ya usa (por ejemplo `/etc/nginx/conf.d/`)?

---

## Bloque 4 — Actualizar un ConfigMap y observar la propagación

1. Con `pod-vol.yaml` corriendo (volumen completo, sin `items` ni `subPath`), editá el ConfigMap:

   ```bash
   kubectl edit configmap game-config
   # cambiá lives=3 por lives=5 y guardá
   ```

2. Esperá alrededor de un minuto (el kubelet sincroniza los ConfigMaps montados como volumen periódicamente) y volvé a leer el archivo dentro del Pod:

   ```bash
   kubectl exec pod-vol -- cat /etc/config/game.properties
   ```

3. Ahora repetí el cambio y revisá el Pod que usa el ConfigMap como variables de entorno (`pod-env-single` o `pod-envfrom`):

   ```bash
   kubectl exec pod-envfrom -- printenv | grep APP_
   ```

4. Borrá y recreá ese Pod (o hacé un rollout restart si estuviera gestionado por un Deployment) y confirmá que ahí sí toma el valor nuevo.

**Preguntas de comprensión — Bloque 4**

1. ¿Por qué el archivo en `/etc/config/game.properties` terminó reflejando el cambio sin reiniciar el Pod, mientras que las variables de entorno no?
2. Si el volumen se montó con `subPath` (como al final del Bloque 3), ¿el archivo se actualiza igual que en el paso 2? Justificá.
3. ¿Qué estrategia común (aunque no sea un mecanismo nativo de Kubernetes) usan los equipos para forzar el reinicio de los Pods de un Deployment cuando cambia un ConfigMap consumido por variables de entorno?

---

## Bloque 5 — ConfigMaps inmutables

1. Creá un ConfigMap marcado como inmutable:

   ```yaml
   # cm-immutable.yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: static-config
   data:
     RELEASE: "1.0.0"
   immutable: true
   ```

   ```bash
   kubectl apply -f cm-immutable.yaml
   ```

2. Intentá modificar un valor existente:

   ```bash
   kubectl patch configmap static-config \
     --type merge -p '{"data":{"RELEASE":"1.0.1"}}'
   ```

3. Observá el error devuelto y, en su lugar, creá una nueva versión del ConfigMap con un nombre distinto (por ejemplo `static-config-v2`), actualizando la referencia en los Pods/Deployments que lo consumen.

**Preguntas de comprensión — Bloque 5**

1. ¿Qué mensaje de error (en términos generales) devuelve el API server ante el intento del paso 2?
2. ¿Qué dos beneficios concretos aporta marcar un ConfigMap como `immutable: true` en clusters grandes?
3. ¿Cuál es el patrón recomendado para "actualizar" un ConfigMap inmutable sin romper la inmutabilidad?

---

<details>
<summary><strong>Ver respuestas</strong></summary>

**Bloque 1**

1. `--from-file=game.properties` crea **una sola clave** llamada `game.properties` cuyo valor es el contenido completo del archivo tal cual. `--from-env-file=app.env` en cambio **parsea** el archivo línea por línea (`CLAVE=valor`) y genera **una clave por cada línea** (`LOG_LEVEL`, `MAX_CONNECTIONS`), igual que si hubieras usado varios `--from-literal`.
2. Controla el **nombre de la clave** bajo la cual se guarda el contenido del archivo: en vez de usar el nombre del archivo (`game.properties`) como clave, la clave pasa a ser `game-conf`.
3. `--from-file`, porque preserva el archivo completo como un único blob de texto bajo una clave (típicamente el nombre del archivo), que es el comportamiento esperado para montarlo luego como archivo de configuración vía volumen.

**Bloque 2**

1. `CreateContainerConfigError`, porque el kubelet no puede construir el entorno del container al no encontrar la clave `APP_TIMEOUT` referenciada en `configMapKeyRef`.
2. Evita tener que declarar una entrada `env` por cada clave: todas las claves del ConfigMap se inyectan automáticamente como variables de entorno con el mismo nombre que la clave, lo cual escala mejor y reduce el YAML.
3. Kubernetes **omite silenciosamente** esa entrada (no genera la variable de entorno) porque `app.mode` no es un identificador válido de variable de entorno de shell (contiene un carácter no permitido); el kubelet reporta un evento pero el resto de las variables válidas sí se inyectan.

**Bloque 3**

1. Quedó **oculto**: al montar un ConfigMap como volumen en una ruta existente, Kubernetes reemplaza todo el contenido de ese directorio por el contenido del volumen (comportamiento estándar de un mount de volumen en Linux), así que los archivos originales de la imagen dejan de ser visibles mientras dure el mount.
2. `items` proyecta la clave elegida como **único archivo en un directorio dedicado** (el resto del directorio queda compuesto solo por las claves listadas en `items`), mientras que `subPath` monta la clave como un archivo puntual **dentro de un directorio que puede tener otros archivos preexistentes**, sin ocultarlos.
3. Porque permite inyectar un solo archivo de configuración sin tapar el resto de los archivos que la imagen ya trae en ese directorio (por ejemplo otros `.conf` de Nginx), evitando romper la configuración por defecto de la imagen base.

**Bloque 4**

1. El kubelet sincroniza periódicamente el contenido de los volúmenes tipo ConfigMap (vía el mecanismo de actualización del kubelet, con un período de sincronización de hasta ~1 minuto más el TTL de caché), así que el archivo se actualiza "en caliente" sin reiniciar el Pod. Las variables de entorno, en cambio, se resuelven **una sola vez**, en el momento de creación del container, y no se vuelven a evaluar durante su ciclo de vida.
2. **No**: cuando se usa `subPath`, el kubelet no actualiza el archivo automáticamente ante cambios en el ConfigMap, porque el mecanismo de sincronización de volúmenes proyectados no aplica de la misma forma a montajes `subPath`. Para reflejar el cambio hace falta recrear el Pod.
3. Un patrón común es incluir un **hash o checksum del contenido del ConfigMap** como anotación en el `template` del Deployment (por ejemplo generado por herramientas como Helm) o usar `kubectl rollout restart deployment/<nombre>`, de modo que un cambio en el ConfigMap dispare un nuevo rollout de Pods.

**Bloque 5**

1. Un error indicando que el campo `data` (o `binaryData`) no puede modificarse porque el ConfigMap es inmutable (algo del estilo *"field is immutable when `immutable` is set"*), y el `kubectl patch` falla sin aplicar el cambio.
2. Primero, **reduce la carga sobre el kube-apiserver**, porque los kubelets ya no necesitan mantener un watch activo sobre ese ConfigMap para detectar cambios. Segundo, **protege contra cambios accidentales** en configuraciones críticas, ya que ningún cliente puede modificar sus datos una vez creado.
3. Crear una **nueva versión del ConfigMap con otro nombre** (por ejemplo agregando un sufijo o hash de contenido: `static-config-v2`) y actualizar la referencia (`configMapKeyRef`, `configMapRef` o `volumes.configMap.name`) en los Pods/Deployments que lo consumen, generalmente disparando un rollout nuevo.

</details>