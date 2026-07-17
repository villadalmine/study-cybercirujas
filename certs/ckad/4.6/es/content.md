# 4.6 — Create & consume Secrets

## ¿Qué es un Secret?

Un **Secret** es un objeto de Kubernetes pensado para almacenar pequeñas cantidades de datos sensibles: contraseñas, tokens, claves TLS, credenciales de registries de imágenes. Funciona de forma casi idéntica a un **ConfigMap**, pero con una diferencia conceptual clave: el Secret señala que el dato es confidencial, lo que permite al cluster aplicarle tratamientos especiales (montaje en `tmpfs`, encryption at rest si está configurada, políticas RBAC más restrictivas).

Un punto que el examen suele explotar: los valores en un Secret están codificados en **base64, que no es cifrado**. Cualquiera con permiso de lectura sobre el Secret puede decodificarlo trivialmente. La codificación existe para poder representar datos binarios en YAML/JSON, no para protegerlos.

```bash
echo "cGFzc3dvcmQxMjM=" | base64 -d
# password123
```

## Tipos de Secret

| Tipo (`type`) | Uso |
|---|---|
| `Opaque` | Datos arbitrarios clave-valor (el default) |
| `kubernetes.io/dockerconfigjson` | Credenciales para pull de imágenes privadas |
| `kubernetes.io/tls` | Certificado y clave TLS (`tls.crt` / `tls.key`) |
| `kubernetes.io/basic-auth` | Usuario y contraseña (`username` / `password`) |
| `kubernetes.io/ssh-auth` | Clave privada SSH (`ssh-privatekey`) |
| `kubernetes.io/service-account-token` | Token de ServiceAccount (gestión legacy) |

Para el CKAD, los que aparecen con frecuencia son `Opaque`, `docker-registry` y `tls`.

## Crear Secrets

### Imperativo con `kubectl` (la vía rápida en el examen)

**Desde literales:**

```bash
kubectl create secret generic db-creds \
  --from-literal=DB_USER=admin \
  --from-literal=DB_PASS='S3cr3t!'
```

**Desde archivos** (la clave es el nombre del archivo, salvo que se indique otra):

```bash
kubectl create secret generic app-keys \
  --from-file=api-key.txt \
  --from-file=custom-name=./token.txt
```

**Desde un env file** (una clave por línea `KEY=value`):

```bash
kubectl create secret generic app-env --from-env-file=prod.env
```

**Secret TLS:**

```bash
kubectl create secret tls web-tls --cert=tls.crt --key=tls.key
```

**Secret para registry privado:**

```bash
kubectl create secret docker-registry regcred \
  --docker-server=registry.example.com \
  --docker-username=deployer \
  --docker-password='p4ss' \
  --docker-email=dev@example.com
```

### Declarativo con YAML

Hay dos campos para los datos y conviene dominar ambos:

- `data`: valores **ya codificados** en base64.
- `stringData`: valores **en texto plano**; el API server los codifica por vos. Es de solo escritura (al leer el objeto, todo aparece en `data`).

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-creds
type: Opaque
stringData:
  DB_USER: admin
  DB_PASS: S3cr3t!
```

Equivalente con `data`:

```bash
echo -n 'admin' | base64      # YWRtaW4=
echo -n 'S3cr3t!' | base64    # UzNjcjN0IQ==
```

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-creds
type: Opaque
data:
  DB_USER: YWRtaW4=
  DB_PASS: UzNjcjN0IQ==
```

> **Cuidado con `echo`:** usá siempre `echo -n` para no incluir el newline final en el valor codificado. Es un error clásico que produce contraseñas "incorrectas" difíciles de depurar.

Un truco de examen: generar el YAML sin crear el objeto con `--dry-run=client -o yaml`:

```bash
kubectl create secret generic db-creds \
  --from-literal=DB_USER=admin \
  --dry-run=client -o yaml > secret.yaml
```

## Inspeccionar y decodificar

```bash
kubectl get secrets
# NAME       TYPE     DATA   AGE
# db-creds   Opaque   2      1m

kubectl describe secret db-creds
# Data
# ====
# DB_PASS:  7 bytes
# DB_USER:  5 bytes
```

`describe` muestra solo el tamaño, no el valor. Para ver un valor concreto:

```bash
kubectl get secret db-creds -o jsonpath='{.data.DB_PASS}' | base64 -d
# S3cr3t!
```

## Consumir Secrets en un Pod

### 1. Como variables de entorno individuales (`secretKeyRef`)

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app
spec:
  containers:
  - name: app
    image: nginx
    env:
    - name: DATABASE_PASSWORD
      valueFrom:
        secretKeyRef:
          name: db-creds
          key: DB_PASS
```

### 2. Todas las claves como variables (`envFrom`)

```yaml
    envFrom:
    - secretRef:
        name: db-creds
    # opcional: prefijo para cada variable
    - secretRef:
        name: db-creds
      prefix: DB_
```

Cada clave del Secret se convierte en una variable de entorno con su mismo nombre.

### 3. Como volumen (un archivo por clave)

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: app
spec:
  containers:
  - name: app
    image: nginx
    volumeMounts:
    - name: creds
      mountPath: /etc/creds
      readOnly: true
  volumes:
  - name: creds
    secret:
      secretName: db-creds
```

Dentro del container:

```bash
kubectl exec app -- ls /etc/creds
# DB_PASS
# DB_USER
kubectl exec app -- cat /etc/creds/DB_PASS
# S3cr3t!
```

Con `items` podés montar solo algunas claves y renombrar el archivo; con `defaultMode` ajustás permisos:

```yaml
  volumes:
  - name: creds
    secret:
      secretName: db-creds
      defaultMode: 0400
      items:
      - key: DB_PASS
        path: database/password
```

### 4. Como `imagePullSecrets`

```yaml
spec:
  imagePullSecrets:
  - name: regcred
  containers:
  - name: app
    image: registry.example.com/team/app:1.0
```

También puede asociarse al ServiceAccount para que aplique a todos los Pods que lo usen:

```bash
kubectl patch serviceaccount default \
  -p '{"imagePullSecrets": [{"name": "regcred"}]}'
```

## Comportamientos que hay que conocer

- **Volúmenes se actualizan, env vars no.** Si el Secret cambia, los archivos montados se refrescan automáticamente (con cierta latencia, y no aplica con `subPath`). Las variables de entorno quedan congeladas hasta reiniciar el Pod.
- **Secret inexistente:** si un Pod referencia un Secret que no existe, el Pod no arranca (`CreateContainerConfigError`), salvo que la referencia sea `optional: true`.
- **Mismo namespace:** un Pod solo puede consumir Secrets de su propio namespace.
- **Inmutabilidad:** con `immutable: true` el Secret no puede modificarse (solo borrarse y recrearse); mejora el rendimiento del cluster y evita cambios accidentales.
- **Límite de tamaño:** 1 MiB por Secret.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-creds
immutable: true
stringData:
  DB_PASS: S3cr3t!
```

## Secret vs ConfigMap (resumen para el examen)

| | ConfigMap | Secret |
|---|---|---|
| Datos | Configuración no sensible | Credenciales, claves, tokens |
| Codificación | Texto plano | base64 (`data`) o plano (`stringData`) |
| Consumo | env, `envFrom`, volumen | Igual, más `imagePullSecrets` |
| Referencia en env | `configMapKeyRef` | `secretKeyRef` |

## Estrategia para el examen

1. Creá los Secrets de forma **imperativa** (`kubectl create secret generic ... --from-literal=...`): es más rápido y evita errores de base64.
2. Si necesitás el YAML, usá `--dry-run=client -o yaml`.
3. Verificá siempre el consumo con `kubectl exec <pod> -- env | grep <VAR>` o `kubectl exec <pod> -- cat <ruta>`.
4. Si un Pod queda en `CreateContainerConfigError`, revisá con `kubectl describe pod` si falta el Secret o la clave referenciada.

## Referencias

- Secrets (conceptos): https://kubernetes.io/docs/concepts/configuration/secret/
- Managing Secrets using kubectl: https://kubernetes.io/docs/tasks/configmap-secret/managing-secret-using-kubectl/
- Managing Secrets using configuration files: https://kubernetes.io/docs/tasks/configmap-secret/managing-secret-using-config-file/
- Distribute credentials securely using Secrets: https://kubernetes.io/docs/tasks/inject-data-application/distribute-credentials-secure/
- Pull an image from a private registry: https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/
- CKAD Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf