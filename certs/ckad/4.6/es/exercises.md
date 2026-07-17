# Ejercicios guiados — 4.6 Create & consume Secrets

> **Requisitos:** un cluster de Kubernetes funcionando (minikube, kind o similar) y `kubectl` configurado. Trabajá en un namespace limpio para poder borrar todo al final:
>
> ```bash
> kubectl create namespace secrets-lab
> kubectl config set-context --current --namespace=secrets-lab
> ```

---

## Ejercicio 1 — Crear un Secret de forma imperativa

La forma más rápida en el examen es el comando `kubectl create secret`. Un **Secret** de tipo `Opaque` (el genérico) se crea con el subcomando `generic`.

1. Creá un Secret con dos claves pasadas como literales:

   ```bash
   kubectl create secret generic db-creds \
     --from-literal=DB_USER=admin \
     --from-literal=DB_PASS='S3cr3t!'
   ```

2. Listá los Secrets del namespace y mirá el tipo y la cantidad de claves:

   ```bash
   kubectl get secrets
   ```

3. Inspeccioná el contenido:

   ```bash
   kubectl describe secret db-creds
   kubectl get secret db-creds -o yaml
   ```

4. Fijate que `describe` muestra solo el **tamaño en bytes** de cada clave, mientras que `get -o yaml` muestra los valores codificados en **base64**. Decodificá uno:

   ```bash
   kubectl get secret db-creds -o jsonpath='{.data.DB_PASS}' | base64 -d; echo
   ```

**Preguntas de comprensión:**

- **1.a)** ¿Por qué `kubectl describe secret` no muestra los valores, pero `kubectl get -o yaml` sí?
- **1.b)** ¿Base64 es un mecanismo de cifrado? ¿Qué implica eso sobre quién puede leer un Secret?

---

## Ejercicio 2 — Crear un Secret desde archivos

Cuando el valor es un archivo completo (una clave SSH, un certificado, un archivo de configuración), conviene `--from-file`.

1. Generá dos archivos locales:

   ```bash
   echo -n 'admin' > ./username.txt
   echo -n 'S3cr3t!' > ./password.txt
   ```

   (El `-n` evita un salto de línea final que después rompería la autenticación.)

2. Creá el Secret desde los archivos:

   ```bash
   kubectl create secret generic file-creds \
     --from-file=./username.txt \
     --from-file=pass=./password.txt
   ```

3. Verificá qué nombres de clave quedaron:

   ```bash
   kubectl describe secret file-creds
   ```

**Preguntas de comprensión:**

- **2.a)** ¿Qué nombre de clave recibió cada archivo dentro del Secret? ¿Por qué son distintos?
- **2.b)** Si hubieras creado `password.txt` con `echo 'S3cr3t!'` (sin `-n`), ¿qué contendría exactamente la clave del Secret?

---

## Ejercicio 3 — Crear un Secret declarativo: `data` vs `stringData`

En un manifiesto YAML podés usar dos campos: `data` (valores ya en base64) o `stringData` (texto plano que Kubernetes codifica por vos).

1. Codificá un valor a mano:

   ```bash
   echo -n 'api-token-123' | base64
   ```

2. Creá el archivo `secret-declarativo.yaml`:

   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: app-secret
   type: Opaque
   data:
     API_TOKEN: YXBpLXRva2VuLTEyMw==
   stringData:
     ENVIRONMENT: production
   ```

3. Aplicalo y verificá que **ambas** claves terminaron en `data`, codificadas:

   ```bash
   kubectl apply -f secret-declarativo.yaml
   kubectl get secret app-secret -o yaml
   ```

4. Truco de examen: generá el YAML sin escribirlo a mano, con `--dry-run`:

   ```bash
   kubectl create secret generic app-secret2 \
     --from-literal=KEY=value \
     --dry-run=client -o yaml > secret2.yaml
   ```

**Preguntas de comprensión:**

- **3.a)** ¿Qué ventaja práctica tiene `stringData` sobre `data` al escribir manifiestos a mano?
- **3.b)** Si una misma clave aparece en `data` y en `stringData`, ¿cuál gana?

---

## Ejercicio 4 — Consumir un Secret como variables de entorno

Hay dos formas: clave por clave con `secretKeyRef`, o todas las claves de una con `envFrom`.

1. Creá el archivo `pod-env.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-env
   spec:
     containers:
     - name: app
       image: busybox:1.36
       command: ["sh", "-c", "env | grep -E 'DB_|API_|ENVIRONMENT' && sleep 3600"]
       env:
       - name: DB_USER
         valueFrom:
           secretKeyRef:
             name: db-creds
             key: DB_USER
       envFrom:
       - secretRef:
           name: app-secret
   ```

2. Aplicalo y mirá los logs:

   ```bash
   kubectl apply -f pod-env.yaml
   kubectl logs pod-env
   ```

   Deberías ver `DB_USER`, `API_TOKEN` y `ENVIRONMENT` con sus valores en texto plano.

3. Ahora modificá el Secret y comprobá si el Pod ve el cambio:

   ```bash
   kubectl patch secret db-creds -p '{"stringData":{"DB_USER":"nuevo-admin"}}'
   kubectl exec pod-env -- sh -c 'echo $DB_USER'
   ```

**Preguntas de comprensión:**

- **4.a)** Después del `patch`, ¿el contenedor ve `admin` o `nuevo-admin`? ¿Por qué?
- **4.b)** ¿Qué pasa si el Pod referencia con `secretKeyRef` una clave que no existe en el Secret? ¿Y cómo lo evitás con el campo `optional`?
- **4.c)** ¿Qué diferencia hay entre `envFrom.secretRef` y `env[].valueFrom.secretKeyRef` en cuanto a control sobre los nombres de las variables?

---

## Ejercicio 5 — Consumir un Secret como volumen

Montado como volumen, cada clave se convierte en un archivo dentro del contenedor.

1. Creá el archivo `pod-vol.yaml`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-vol
   spec:
     containers:
     - name: app
       image: busybox:1.36
       command: ["sleep", "3600"]
       volumeMounts:
       - name: creds
         mountPath: /etc/creds
         readOnly: true
     volumes:
     - name: creds
       secret:
         secretName: db-creds
         defaultMode: 0400
   ```

2. Aplicalo y explorá el volumen:

   ```bash
   kubectl apply -f pod-vol.yaml
   kubectl exec pod-vol -- ls -l /etc/creds
   kubectl exec pod-vol -- cat /etc/creds/DB_PASS; echo
   ```

3. Modificá el Secret y esperá un rato (hasta ~1 minuto):

   ```bash
   kubectl patch secret db-creds -p '{"stringData":{"DB_PASS":"rotated!"}}'
   sleep 70
   kubectl exec pod-vol -- cat /etc/creds/DB_PASS; echo
   ```

4. Variante con `items` para montar **solo una clave** con otro nombre de archivo — reemplazá la sección `volumes` por:

   ```yaml
   volumes:
   - name: creds
     secret:
       secretName: db-creds
       items:
       - key: DB_PASS
         path: db/password.txt
   ```

**Preguntas de comprensión:**

- **5.a)** A diferencia de las variables de entorno, ¿qué pasó con el archivo montado cuando rotaste el Secret?
- **5.b)** ¿Qué efecto tiene `defaultMode: 0400` y por qué es una buena práctica en Secrets?
- **5.c)** Con la variante de `items`, ¿en qué ruta completa queda el password dentro del contenedor?

---

## Ejercicio 6 — Tipos especiales: `docker-registry` y `tls`

Además de `generic`, `kubectl create secret` tiene subcomandos para dos casos de uso frecuentes.

1. Creá un Secret para autenticarte contra un registry privado:

   ```bash
   kubectl create secret docker-registry regcred \
     --docker-server=registry.example.com \
     --docker-username=deployer \
     --docker-password='p4ss' \
     --docker-email=deployer@example.com
   ```

2. Mirá su tipo y su única clave:

   ```bash
   kubectl get secret regcred -o yaml
   ```

3. Usalo en un Pod mediante `imagePullSecrets`:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pod-privado
   spec:
     imagePullSecrets:
     - name: regcred
     containers:
     - name: app
       image: registry.example.com/team/app:1.0
   ```

   (No hace falta aplicarlo: el registry no existe. Lo importante es la estructura.)

4. Creá un Secret TLS a partir de un certificado autofirmado:

   ```bash
   openssl req -x509 -nodes -newkey rsa:2048 \
     -keyout tls.key -out tls.crt -days 1 -subj "/CN=demo.local"
   kubectl create secret tls demo-tls --cert=tls.crt --key=tls.key
   kubectl describe secret demo-tls
   ```

**Preguntas de comprensión:**

- **6.a)** ¿Qué tipo (`type`) tiene el Secret `regcred` y qué clave contiene?
- **6.b)** ¿En qué nivel del manifiesto va `imagePullSecrets`: en el contenedor o en la `spec` del Pod?
- **6.c)** ¿Qué dos claves exige siempre un Secret de tipo `kubernetes.io/tls`?

---

## Ejercicio 7 — Secrets inmutables

Marcar un Secret como `immutable` evita cambios accidentales y reduce carga en el API server (el kubelet deja de vigilarlo).

1. Hacé inmutable el Secret `app-secret`:

   ```bash
   kubectl patch secret app-secret -p '{"immutable": true}'
   ```

2. Intentá modificarlo:

   ```bash
   kubectl patch secret app-secret -p '{"stringData":{"ENVIRONMENT":"staging"}}'
   ```

3. Leé el mensaje de error con atención.

**Preguntas de comprensión:**

- **7.a)** ¿Qué única operación te queda disponible para "cambiar" un Secret inmutable?
- **7.b)** ¿Se puede volver un Secret inmutable a mutable con otro `patch`?

---

## Limpieza

```bash
kubectl delete namespace secrets-lab
kubectl config set-context --current --namespace=default
rm -f username.txt password.txt tls.key tls.crt secret-declarativo.yaml secret2.yaml pod-env.yaml pod-vol.yaml
```

---

<details>
<summary><strong>Respuestas</strong></summary>

**1.a)** `describe` oculta los valores a propósito para evitar exposiciones accidentales en pantalla (muestra solo los bytes por clave). `get -o yaml` devuelve el objeto completo tal como está en la API, incluyendo `data` en base64. Cualquiera con permiso de `get` sobre Secrets puede leer los valores.

**1.b)** No: base64 es solo **codificación**, no cifrado — se revierte con `base64 -d` sin ninguna clave. Por eso el acceso a Secrets debe restringirse con RBAC, y para protección real en reposo se configura *encryption at rest* en etcd.

**2.a)** `username.txt` (el nombre del archivo, porque no se especificó clave) y `pass` (porque se usó la sintaxis `--from-file=pass=./password.txt`, que permite elegir el nombre de la clave).

**2.b)** Contendría `S3cr3t!\n` — el valor más un salto de línea final. Es un error clásico: la aplicación autentica con un password que "se ve igual" pero no coincide.

**3.a)** Con `stringData` escribís los valores en texto plano y Kubernetes los codifica al guardar; evitás el paso manual de `base64` y los errores de copiar/pegar cadenas codificadas.

**3.b)** Gana `stringData`: si la misma clave está en ambos campos, el valor de `stringData` sobrescribe al de `data`.

**4.a)** Sigue viendo `admin`. Las variables de entorno se resuelven **una sola vez, al crear el contenedor**; cambiar el Secret no las actualiza. Para que el Pod vea el valor nuevo hay que recrearlo (o forzar un rollout si es un Deployment).

**4.b)** El contenedor falla al arrancar (el Pod queda en `CreateContainerConfigError`). Se evita agregando `optional: true` dentro de `secretKeyRef`: la variable simplemente no se define si falta la clave o el Secret.

**4.c)** `envFrom.secretRef` inyecta **todas** las claves del Secret como variables, usando los nombres de las claves tal cual (opcionalmente con un `prefix`). `secretKeyRef` inyecta una clave puntual y te deja elegir libremente el nombre de la variable.

**5.a)** El archivo **sí se actualizó**: los volúmenes de tipo `secret` se refrescan automáticamente (el kubelet los sincroniza periódicamente, típicamente en menos de un minuto). Es la diferencia clave frente a las variables de entorno. Excepción: los montajes con `subPath` no se actualizan.

**5.b)** Fija los permisos de los archivos montados en `r--------` (solo lectura para el owner). Reduce el riesgo de que otros procesos o usuarios dentro del contenedor lean las credenciales. Nota: en YAML se escribe en octal (`0400`) o decimal (`256`).

**5.c)** En `/etc/creds/db/password.txt`: el `mountPath` (`/etc/creds`) más el `path` del item (`db/password.txt`), que puede incluir subdirectorios. Solo esa clave se monta; `DB_USER` ya no aparece.

**6.a)** Tipo `kubernetes.io/dockerconfigjson`, con una única clave llamada `.dockerconfigjson` que contiene el archivo de configuración de Docker (JSON con las credenciales del registry) en base64.

**6.b)** En la `spec` del Pod, al mismo nivel que `containers` — no dentro del contenedor. Aplica a todas las imágenes que el Pod necesite descargar. También puede asociarse a un ServiceAccount para no repetirlo en cada Pod.

**6.c)** `tls.crt` (el certificado) y `tls.key` (la clave privada). El subcomando `kubectl create secret tls` las genera automáticamente a partir de `--cert` y `--key`.

**7.a)** Borrarlo y recrearlo (`kubectl delete` + `kubectl create/apply`). Los Pods que lo consumen deben recrearse para ver el nuevo contenido.

**7.b)** No. Una vez que `immutable: true` está establecido, el campo no puede revertirse ni el contenido modificarse; la API rechaza ambos cambios. Solo la eliminación del Secret es posible.

</details>

---

**Fuentes:**

- CNCF — CKAD Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf
- Kubernetes — Secrets (conceptos): https://kubernetes.io/docs/concepts/configuration/secret/
- Kubernetes — Distribute Credentials Securely Using Secrets: https://kubernetes.io/docs/tasks/inject-data-application/distribute-credentials-secure/
- Kubernetes — Pull an Image from a Private Registry: https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/