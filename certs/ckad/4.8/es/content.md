# 4.8 – Understand Application Security (SecurityContexts, Capabilities, etc.)

## ¿Qué es un SecurityContext?

Un **SecurityContext** define los privilegios y controles de acceso de un Pod o de un container específico a nivel de sistema operativo (usuario, grupo, capabilities de Linux, escalación de privilegios, etc.). Es la herramienta principal para aplicar el principio de **least privilege** en workloads de Kubernetes.

Se puede definir en dos niveles:

- **`spec.securityContext`** (Pod-level): aplica a todos los containers del Pod (y a los volumes, en el caso de `fsGroup`).
- **`spec.containers[].securityContext`** (Container-level): aplica solo a ese container y **sobreescribe** los valores equivalentes definidos a nivel Pod.

```
Pod securityContext
 └── Container securityContext (tiene precedencia si define el mismo campo)
```

## SecurityContext a nivel de Pod

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-secctx
spec:
  securityContext:
    runAsUser: 1000
    runAsGroup: 3000
    runAsNonRoot: true
    fsGroup: 2000
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    emptyDir: {}
```

- **`runAsUser` / `runAsGroup`**: fuerzan el UID/GID con el que corre el proceso principal del container, independientemente del `USER` definido en la imagen.
- **`runAsNonRoot: true`**: le indica al kubelet que **rechace** el arranque del container si terminaría corriendo como UID 0 (root). No cambia el UID por sí solo; es una validación.
- **`fsGroup`**: cambia el group ownership de los volumes montados (que lo soportan) para que el GID indicado tenga acceso de escritura.

Verificación:

```bash
kubectl apply -f pod-secctx.yaml
kubectl exec pod-secctx -- id
```

```
uid=1000 gid=3000 groups=3000,2000
```

## SecurityContext a nivel de Container

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-container-secctx
spec:
  containers:
  - name: app
    image: nginx:1.25
    securityContext:
      runAsUser: 101
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      privileged: false
      capabilities:
        drop: ["ALL"]
        add: ["NET_BIND_SERVICE"]
```

Campos clave a nivel container:

| Campo | Efecto |
|---|---|
| `privileged` | Si es `true`, el container tiene acceso equivalente a root en el host (todos los devices, sin aislamiento de namespaces de seguridad). Debe evitarse salvo necesidad explícita (drivers, CNI plugins, etc.). |
| `allowPrivilegeEscalation` | Si es `false`, evita que un proceso hijo obtenga más privilegios que el padre (bloquea binarios con setuid/setgid y `no_new_privs`). Se fuerza a `false` automáticamente si `privileged: false` y no se define `capabilities.add` con `SYS_ADMIN`. |
| `readOnlyRootFilesystem` | Monta el filesystem raíz del container como solo lectura; el proceso solo puede escribir en volumes montados explícitamente (útil junto a `emptyDir` para directorios de escritura como `/tmp`). |
| `capabilities` | Lista de Linux capabilities a agregar (`add`) o quitar (`drop`) sobre el set por defecto del container runtime. |

## Linux Capabilities

Los **capabilities** dividen los privilegios que tradicionalmente tenía el usuario root en unidades independientes. Container runtimes como `containerd`/`runc` arrancan los containers con un subconjunto reducido de capabilities (no el set completo de root), y desde ahí se puede **agregar** o **quitar**.

Algunas capabilities relevantes para el examen:

| Capability | Permite |
|---|---|
| `NET_ADMIN` | Configurar interfaces de red, rutas, firewall (iptables). |
| `NET_RAW` | Usar raw sockets (por ejemplo, `ping`). |
| `NET_BIND_SERVICE` | Bindear puertos < 1024 sin ser root. |
| `CHOWN` | Cambiar el owner de archivos. |
| `SYS_TIME` | Modificar el reloj del sistema. |
| `SYS_ADMIN` | Amplio conjunto de operaciones administrativas (montar filesystems, etc.) — evitar salvo necesidad real. |

Ejemplo: dropear todo y agregar solo lo necesario (buena práctica de hardening):

```yaml
securityContext:
  capabilities:
    drop:
    - ALL
    add:
    - NET_BIND_SERVICE
```

Ejemplo práctico: un container que necesita `NET_ADMIN` para manipular reglas de red:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: netadmin-pod
spec:
  containers:
  - name: net-tool
    image: nicolaka/netshoot
    command: ["sh", "-c", "sleep 3600"]
    securityContext:
      capabilities:
        add: ["NET_ADMIN"]
```

```bash
kubectl exec netadmin-pod -- sh -c "iptables -L"
```

Sin `NET_ADMIN`, ese comando fallaría con `Permission denied` (operation not permitted).

## seccompProfile

Restringe las syscalls que el container puede invocar.

```yaml
securityContext:
  seccompProfile:
    type: RuntimeDefault
```

Valores de `type`:

- **`RuntimeDefault`**: usa el perfil seccomp por defecto del container runtime (recomendado como baseline).
- **`Localhost`**: usa un perfil JSON personalizado ubicado en el nodo (requiere `localhostProfile: <ruta relativa>`).
- **`Unconfined`**: sin restricción de seccomp (evitar en producción).

## seLinuxOptions (breve mención)

En clusters con SELinux habilitado se puede fijar el label del proceso:

```yaml
securityContext:
  seLinuxOptions:
    level: "s0:c123,c456"
```

Es menos frecuente en el examen que `capabilities`/`runAsUser`, pero puede aparecer como distractor en preguntas de opción múltiple.

## Ejemplo combinado (Pod + Container)

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: hardened-pod
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 2000
  containers:
  - name: web
    image: nginx:1.25
    ports:
    - containerPort: 8080
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
        add: ["NET_BIND_SERVICE"]
    volumeMounts:
    - name: tmp
      mountPath: /tmp
    - name: cache
      mountPath: /var/cache/nginx
  volumes:
  - name: tmp
    emptyDir: {}
  - name: cache
    emptyDir: {}
```

Nota: `nginx` por default escribe en `/var/cache/nginx` y `/var/run`; con `readOnlyRootFilesystem: true` hay que montar `emptyDir` en esos paths o el container falla al iniciar.

## Verificación y troubleshooting

```bash
kubectl get pod hardened-pod -o jsonpath='{.spec.securityContext}'
kubectl get pod hardened-pod -o jsonpath='{.spec.containers[0].securityContext}'
```

Si un Pod con `runAsNonRoot: true` intenta correr una imagen cuyo `USER` es root (o no define `USER`) y no se especifica `runAsUser`, el Pod queda en estado `CreateContainerConfigError`:

```bash
kubectl describe pod hardened-pod
```

```
Warning  Failed  2s  kubelet  Error: container has runAsNonRoot and image will run as root
```

Solución: definir explícitamente `runAsUser` con un UID no-root, o usar una imagen que declare un `USER` no-root.

## Tips para el examen

- Recordá el **orden de precedencia**: container-level sobreescribe pod-level campo por campo (no reemplaza todo el bloque).
- `drop: ["ALL"]` + `add: [...]` es el patrón de hardening más pedido: negar todo y habilitar solo lo estrictamente necesario.
- `allowPrivilegeEscalation: false` es obligatorio (no se puede definir en `true`) si el container corre con `privileged: true` o tiene `CAP_SYS_ADMIN`.
- Practicá editar un Pod ya corriendo con `kubectl edit` no funciona para cambiar `securityContext` de un Pod vivo (es inmutable); hay que recrearlo o usar `kubectl replace --force` / editar el manifest y reaplicar.
- Usá `kubectl explain pod.spec.securityContext` y `kubectl explain pod.spec.containers.securityContext` durante el examen para no memorizar todos los campos.

## Referencias

- Configure a Security Context for a Pod or Container: https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- SecurityContext API reference: https://kubernetes.io/docs/reference/generated/kubernetes-api/v1.31/#securitycontext-v1-core
- Linux capabilities (man7): https://man7.org/linux/man-pages/man7/capabilities.7.html
- Seccomp security in Kubernetes: https://kubernetes.io/docs/tutorials/security/seccomp/
- CNCF CKAD Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf