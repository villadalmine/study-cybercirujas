# 3.2 — Use ConfigMaps and Secrets to configure applications

## Por qué separar la configuración del código

Los `Pods` no deberían tener valores de configuración (endpoints, feature flags, credenciales, certificados) hardcodeados en la imagen del container. Kubernetes ofrece dos objetos nativos para desacoplar esa configuración del código de la aplicación:

- **ConfigMap**: datos de configuración no sensibles, en texto plano (key-value).
- **Secret**: datos sensibles (passwords, tokens, certificados, claves SSH). Se almacenan codificados en `base64`, **no cifrados** por defecto — la codificación no es una medida de seguridad, solo permite guardar bytes arbitrarios en JSON/YAML.

Ambos objetos son namespaced y se inyectan en los Pods de dos formas: como **variables de entorno** o como **volúmenes montados** (archivos dentro del filesystem del container).

---

## ConfigMaps

### Crear un ConfigMap (imperativo)

```bash
# desde literales
kubectl create configmap app-config \
  --from-literal=APP_MODE=production \
  --from-literal=LOG_LEVEL=info

# desde un archivo (la key será el nombre del archivo)
kubectl create configmap nginx-config --from-file=nginx.conf

# desde un directorio completo (una key por archivo)
kubectl create configmap app-files --from-file=./config-dir/

# desde un archivo .env (KEY=VALUE por línea)
kubectl create configmap app-env --from-env-file=app.env
```

Verificación:

```bash
kubectl get configmap app-config -o yaml
```

Salida (resumida):

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
  namespace: default
data:
  APP_MODE: production
  LOG_LEVEL: info
```

### Crear un ConfigMap (declarativo)

```yaml
# configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
data:
  APP_MODE: "production"
  LOG_LEVEL: "info"
  app.properties: |
    db.host=postgres.svc
    db.port=5432
```

```bash
kubectl apply -f configmap.yaml
```

Notar el campo `app.properties`: una key puede contener un bloque multilínea completo, útil para inyectar archivos de configuración completos (nginx.conf, application.yaml, etc.) usando `|` (literal block scalar).

### Consumir un ConfigMap como variables de entorno

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: demo-pod
spec:
  containers:
  - name: app
    image: nginx:1.27
    env:
    - name: APP_MODE          # variable individual
      valueFrom:
        configMapKeyRef:
          name: app-config
          key: APP_MODE
    envFrom:
    - configMapRef:            # todas las keys como env vars
        name: app-config
```

Con `envFrom`, cada key del ConfigMap se convierte en una variable de entorno con el mismo nombre. Si una key no es un nombre de variable de entorno válido, Kubernetes la omite y lo reporta como evento (no falla el Pod).

### Consumir un ConfigMap como volumen

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: demo-pod-vol
spec:
  containers:
  - name: app
    image: nginx:1.27
    volumeMounts:
    - name: config-volume
      mountPath: /etc/config
  volumes:
  - name: config-volume
    configMap:
      name: app-config
```

Cada key del ConfigMap aparece como un archivo dentro de `/etc/config` (`/etc/config/APP_MODE`, `/etc/config/LOG_LEVEL`, etc.), con el value como contenido del archivo. Se puede restringir a keys puntuales con `items`:

```yaml
  volumes:
  - name: config-volume
    configMap:
      name: app-config
      items:
      - key: app.properties
        path: application.properties
```

---

## Secrets

### Tipos comunes

| Tipo | Uso |
|---|---|
| `Opaque` | genérico, key-value arbitrario (default) |
| `kubernetes.io/dockerconfigjson` | credenciales para pull de imágenes privadas |
| `kubernetes.io/tls` | certificado + clave privada TLS |
| `kubernetes.io/basic-auth` | usuario/contraseña |
| `kubernetes.io/ssh-auth` | clave privada SSH |
| `kubernetes.io/service-account-token` | token de una ServiceAccount |

### Crear un Secret (imperativo)

```bash
kubectl create secret generic db-secret \
  --from-literal=DB_USER=admin \
  --from-literal=DB_PASSWORD='S3cr3tP@ss'

# secret para pull de imágenes privadas
kubectl create secret docker-registry regcred \
  --docker-server=registry.example.com \
  --docker-username=user \
  --docker-password=pass \
  --docker-email=user@example.com

# secret TLS
kubectl create secret tls web-tls \
  --cert=tls.crt --key=tls.key
```

### Crear un Secret (declarativo)

Los valores deben ir codificados en base64:

```bash
echo -n 'admin' | base64        # YWRtaW4=
echo -n 'S3cr3tP@ss' | base64   # UzNjcjN0UEBzcw==
```

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-secret
type: Opaque
data:
  DB_USER: YWRtaW4=
  DB_PASSWORD: UzNjcjN0UEBzcw==
```

Alternativa: usar `stringData` para escribir valores en texto plano; el API server los codifica automáticamente al persistir el objeto.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-secret
type: Opaque
stringData:
  DB_USER: admin
  DB_PASSWORD: S3cr3tP@ss
```

### Consumir un Secret

Mismo patrón que ConfigMap, cambiando `configMapKeyRef`/`configMapRef`/`configMap` por `secretKeyRef`/`secretRef`/`secret`:

```yaml
    env:
    - name: DB_PASSWORD
      valueFrom:
        secretKeyRef:
          name: db-secret
          key: DB_PASSWORD
    envFrom:
    - secretRef:
        name: db-secret
```

```yaml
  volumes:
  - name: secret-volume
    secret:
      secretName: db-secret
      defaultMode: 0400        # permisos del archivo montado
```

Para el pull de imágenes privadas, el Secret se referencia a nivel de Pod, no de container:

```yaml
spec:
  imagePullSecrets:
  - name: regcred
  containers:
  - name: app
    image: registry.example.com/app:1.0
```

### Verificación

```bash
kubectl get secret db-secret -o jsonpath='{.data.DB_PASSWORD}' | base64 -d
# S3cr3tP@ss
```

`kubectl describe secret` **no** muestra los valores (solo tamaños en bytes) — es intencional, para evitar exponerlos accidentalmente en pantalla o logs.

---

## Comportamiento de actualización

- **Como env var**: el valor se inyecta al crear el container; si se edita el ConfigMap/Secret después, el Pod **no** se entera hasta que se recree (rolling restart del Deployment, por ejemplo).
- **Como volumen**: kubelet sincroniza periódicamente (según `--sync-frequency`, default ~1 minuto) y actualiza el archivo montado **sin reiniciar el Pod**. La aplicación debe soportar recarga (watch del archivo) para aprovechar esto.
- **subPath**: si se monta un ConfigMap/Secret usando `subPath` (para mapear una sola key a una ruta arbitraria dentro de un volumen ya existente), ese archivo **no** recibe actualizaciones automáticas.

## `immutable: true`

Desde Kubernetes 1.21 (GA), tanto ConfigMap como Secret aceptan el campo `immutable`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
immutable: true
data:
  APP_MODE: production
```

Evita cambios accidentales, reduce la carga sobre el API server (kube-apiserver deja de watchear ese objeto para propagar updates) y obliga a versionar el nombre del ConfigMap/Secret (ej. `app-config-v2`) en cada cambio, lo cual además soluciona el problema de propagación tardía descripto arriba.

---

## Buenas prácticas para el examen

- Usar `kubectl create configmap|secret ... --dry-run=client -o yaml > file.yaml` para generar manifiestos rápido y después editarlos.
- Recordar que `kubectl edit secret <name>` muestra los valores en base64, no en texto plano.
- Un Secret **no** cifra datos en reposo por sí solo; el cifrado en etcd requiere configurar `EncryptionConfiguration` en el API server (tema aparte de seguridad del cluster).
- Diferenciar `env` (referencia puntual, permite `optional: true`) de `envFrom` (bulk, más simple pero menos control por key).
- Si una key referenciada en `configMapKeyRef`/`secretKeyRef` no existe y no se marca `optional: true`, el Pod queda en `CreateContainerConfigError`.

---

## Referencias

- Configure a Pod to Use a ConfigMap — https://kubernetes.io/docs/tasks/configure-pod-container/configure-pod-configmap/
- ConfigMaps (concepto) — https://kubernetes.io/docs/concepts/configuration/configmap/
- Secrets (concepto) — https://kubernetes.io/docs/concepts/configuration/secret/
- Distribute Credentials Securely Using Secrets — https://kubernetes.io/docs/tasks/inject-data-application/distribute-credentials-secure/
- Managing Secrets using kubectl — https://kubernetes.io/docs/tasks/configmap-secret/managing-secret-using-kubectl/
- Define Environment Variables for a Container — https://kubernetes.io/docs/tasks/inject-data-application/define-environment-variable-container/
- Pull an Image from a Private Registry — https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/
- CKA Curriculum v1.35 (CNCF) — https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf