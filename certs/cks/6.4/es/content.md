# Ensure immutability of containers at runtime

## Qué significa "immutability" en runtime

Un contenedor es *immutable en runtime* cuando su filesystem no puede modificarse mientras el proceso está corriendo: no se pueden crear, borrar ni sobreescribir archivos dentro de la imagen en ejecución. Esto reduce drásticamente la superficie de ataque porque, aunque un atacante consiga ejecución de código dentro del contenedor (vía una vulnerabilidad de la app), no puede:

- Instalar herramientas adicionales (`apt install`, `curl` de un payload, etc.).
- Modificar binarios existentes o plantar un backdoor persistente.
- Alterar archivos de configuración para escalar privilegios o moverse lateralmente.

La immutability en runtime es un control *preventivo* que complementa (no reemplaza) la detección en runtime (Falco, auditoría) y el hardening de imágenes (distroless, sin shell, supply chain). En el CKS, el mecanismo principal para lograrla es `securityContext.readOnlyRootFilesystem`, reforzado con políticas de admisión que lo hagan obligatorio a nivel de cluster.

## `readOnlyRootFilesystem`

El campo `securityContext.readOnlyRootFilesystem: true` monta el rootfs del contenedor en modo lectura únicamente. Se define por contenedor, no a nivel de Pod.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: immutable-nginx
spec:
  containers:
  - name: nginx
    image: nginx:1.27-alpine
    securityContext:
      readOnlyRootFilesystem: true
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
    volumeMounts:
    - name: tmp
      mountPath: /tmp
    - name: cache
      mountPath: /var/cache/nginx
    - name: run
      mountPath: /var/run
  volumes:
  - name: tmp
    emptyDir: {}
  - name: cache
    emptyDir: {}
  - name: run
    emptyDir: {}
```

Muchas imágenes (como nginx) necesitan escribir en rutas puntuales (`/tmp`, cache, PID files) aunque el resto del filesystem sea inmutable. La solución es montar `emptyDir` (en memoria con `medium: Memory` si se quiere evitar tocar disco) solo sobre esas rutas específicas, dejando todo lo demás read-only.

### Verificación

```
$ kubectl exec -it immutable-nginx -- sh -c "echo pwned > /etc/passwd"
sh: can't create /etc/passwd: Read-only file system

$ kubectl exec -it immutable-nginx -- sh -c "touch /tmp/ok && echo listo"
listo
```

El primer intento falla porque `/etc` pertenece al rootfs inmutable; el segundo funciona porque `/tmp` está respaldado por un `emptyDir` escribible.

## Por qué combinarlo con `allowPrivilegeEscalation: false` y `capabilities: drop: ["ALL"]`

`readOnlyRootFilesystem` protege el filesystem, pero no evita que el proceso escale privilegios y remonte el filesystem como read-write (por ejemplo con `mount -o remount,rw /` si tuviera `CAP_SYS_ADMIN` y `allowPrivilegeEscalation: true`). Por eso en el examen siempre se espera ver el trío junto:

```yaml
securityContext:
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  runAsNonRoot: true
  capabilities:
    drop: ["ALL"]
```

## Enforcement a nivel de cluster

Un Pod individual con `readOnlyRootFilesystem: true` es solo buena práctica si nadie la fuerza. Para garantizar immutability en todo el cluster hace falta un control de admisión.

**Nota de examen:** el perfil `restricted` de Pod Security Standards (`pod-security.kubernetes.io/enforce=restricted`) **no** exige `readOnlyRootFilesystem`. Cubre `allowPrivilegeEscalation`, `runAsNonRoot`, `capabilities.drop: ["ALL"]`, `seccompProfile`, pero no el filesystem. Para imponer immutability del rootfs se necesita un motor de políticas como Kyverno u OPA/Gatekeeper.

### Ejemplo con Kyverno

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-ro-rootfs
spec:
  validationFailureAction: Enforce
  background: true
  rules:
  - name: check-ro-rootfs
    match:
      any:
      - resources:
          kinds: ["Pod"]
    validate:
      message: "Todos los containers deben tener securityContext.readOnlyRootFilesystem=true"
      pattern:
        spec:
          containers:
          - securityContext:
              readOnlyRootFilesystem: true
```

```
$ kubectl apply -f mutable-pod.yaml
Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:

resource Pod/default/mutable-pod was blocked due to the following policies

require-ro-rootfs:
  check-ro-rootfs: 'validation error: Todos los containers deben tener
    securityContext.readOnlyRootFilesystem=true. rule check-ro-rootfs failed
    at path /spec/containers/0/securityContext/readOnlyRootFilesystem/'
```

### Ejemplo con OPA/Gatekeeper

El equivalente es un `ConstraintTemplate` con Rego que recorra `input.review.object.spec.containers[*].securityContext.readOnlyRootFilesystem` y rechace si es `false` o está ausente, instanciado luego con un `Constraint` (`kind: K8sRequiredReadOnlyRootFilesystem`) apuntando a `Pod`. La lógica es la misma que con Kyverno: la política vive en el cluster (no en cada manifiesto) y es imposible de saltear desde un Pod individual.

## Restringir `kubectl exec` como complemento

Un shell interactivo dentro de un contenedor "inmutable" es, en la práctica, una puerta de escritura si el atacante logra montar un volumen escribible o hay un directorio no cubierto por el rootfs read-only. RBAC no tiene un "deny" explícito, pero como es allow-only alcanza con **no otorgar** el verbo `create` sobre el subrecurso `pods/exec`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: view-no-exec
rules:
- apiGroups: [""]
  resources: ["pods", "pods/log"]
  verbs: ["get", "list", "watch"]
# pods/exec y pods/attach deliberadamente ausentes
```

Si el usuario o ServiceAccount solo tiene este rol (sin otro binding que otorgue `pods/exec`), `kubectl exec` falla con `Forbidden`.

## Detección de drift en runtime (defensa en profundidad)

Aunque el filesystem sea read-only, conviene tener una regla de Falco que alerte si algo intenta escribir en rutas sensibles — cubre bypasses como un `hostPath` mal configurado o un volumen adicional escribible que anule la protección:

```yaml
- rule: Write below binary dir despite immutability
  desc: Escritura en directorio de binarios pese a readOnlyRootFilesystem (posible bypass)
  condition: >
    open_write and container
    and fd.directory in (/bin, /sbin, /usr/bin, /usr/sbin)
  output: >
    Escritura sospechosa en binario (user=%user.name command=%proc.cmdline
    file=%fd.name container=%container.name image=%container.image.repository)
  priority: WARNING
```

## Relación con imágenes inmutables

La immutability en runtime se apoya en imágenes construidas para necesitar el mínimo de escritura: builds multi-stage, imágenes `distroless` o `alpine` sin gestor de paquetes ni shell interactivo, y tags fijados por digest (`image@sha256:...`) en vez de `:latest`. Esto no es en sí el control de runtime, pero facilita que `readOnlyRootFilesystem: true` funcione sin romper la aplicación (menos rutas que la app espera poder escribir).

## Resumen para el examen

| Control | Qué hace | A nivel de |
|---|---|---|
| `securityContext.readOnlyRootFilesystem: true` | Monta el rootfs en solo lectura | Pod/container |
| `emptyDir` en rutas puntuales | Permite escritura controlada donde la app la necesita | Pod |
| `allowPrivilegeEscalation: false` + `capabilities.drop: ["ALL"]` | Evita remount rw vía escalada de privilegios | Pod/container |
| Kyverno/OPA Gatekeeper | Fuerza `readOnlyRootFilesystem=true` en todo el cluster | Cluster (admission) |
| RBAC sin `pods/exec` | Evita shells interactivos en producción | Cluster |
| Falco | Detecta intentos de escritura pese a las protecciones | Runtime |

## Referencias

- CNCF, *CKS Curriculum v1.34*: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes docs, *Configure a Security Context for a Pod or Container*: https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- Kubernetes docs, *Pod Security Standards*: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Kubernetes docs, *emptyDir volume*: https://kubernetes.io/docs/concepts/storage/volumes/#emptydir
- Kubernetes docs, *RBAC Authorization*: https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Kyverno docs, *Require Read-Only Root Filesystem*: https://kyverno.io/policies/other/require-ro-rootfs/require-ro-rootfs/
- OPA Gatekeeper docs: https://open-policy-agent.github.io/gatekeeper/website/docs/
- Falco docs, *Rules*: https://falco.org/docs/rules/