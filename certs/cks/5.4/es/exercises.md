# CKS 5.4 — Uso apropiado de herramientas de endurecimiento del kernel como AppArmor y seccomp

**Certificación:** Certified Kubernetes Security Specialist (CKS), currículum **v1.34**
**Dominio:** 5. Minimización de vulnerabilidades en microservicios — **peso de este tema en el examen: 2.5 %**
**Formato:** ejercicios guiados. Ejecuta cada paso numerado y luego responde las preguntas del bloque antes de continuar. Todas las respuestas están plegadas al final.

---

## Qué vas a poder hacer cuando termines

1. Explicar, a nivel de kernel, **qué media seccomp-bpf y qué no puede mediar**, y por qué AppArmor es el complemento y no la alternativa.
2. Distinguir `Unconfined`, `RuntimeDefault` y `Localhost` para **ambos** `seccompProfile` y `appArmorProfile`, usando los campos GA de la API (no las anotaciones obsoletas).
3. Construir un perfil de seccomp de forma empírica: ejecutar en **modo auditoría**, recolectar las syscalls del log de auditoría del kernel y convertir eso en una allowlist en modo enforcing.
4. Escribir, cargar e iterar un perfil de AppArmor en un nodo (`complain` → `enforce`), y adjuntarlo a un Pod.
5. Diagnosticar los cuatro modos de fallo que realmente cuestan puntos en el examen: perfil ausente en el nodo, sintaxis incorrecta de `localhostProfile`, override a nivel de contenedor y rechazo por Pod Security Admission.

---

## Topología del laboratorio y prerequisitos

Necesitas un clúster donde **tengas root en los nodos**. Dos opciones:

| Parte | Entorno que funciona | Por qué |
|---|---|---|
| Bloques 1–5 (seccomp) | `kind` ≥ 0.23, o cualquier clúster kubeadm | Los perfiles son archivos; `kind` puede montarlos por bind dentro del directorio raíz de seccomp del kubelet. |
| Bloques 6–9 (AppArmor) | Nodo kubeadm/VM sobre **Ubuntu/Debian/SUSE** con AppArmor habilitado | Los perfiles de AppArmor se cargan en el **kernel del host**. Dentro de `kind`, el nodo es a su vez un contenedor y `apparmor_parser` normalmente no puede cargar perfiles desde ahí. |

> **Chequeo de realidad para el examen.** El entorno de CKS te da SSH a `controlplane` y `node01`, y ambos son Ubuntu con AppArmor habilitado y containerd como runtime. Todo lo que sigue coincide con esa forma.

### Paso 0.1 — Levantar un clúster `kind` con un directorio de perfiles de seccomp

```bash
mkdir -p ~/cks-54/profiles && cd ~/cks-54

cat > kind-config.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraMounts:
  - hostPath: ./profiles
    containerPath: /var/lib/kubelet/seccomp/profiles
- role: worker
  extraMounts:
  - hostPath: ./profiles
    containerPath: /var/lib/kubelet/seccomp/profiles
EOF

kind create cluster --name cks54 --config kind-config.yaml
```

### Paso 0.2 — Crear el namespace de trabajo

```bash
kubectl create namespace cks-54
kubectl config set-context --current --namespace=cks-54
```

Esperado:

```
namespace/cks-54 created
Context "kind-cks54" modified.
```

---

## Bloque 1 — Verificar el sustrato del kernel antes de confiar en cualquier manifiesto

Un campo `securityContext` es un *pedido*. Si el kernel o el runtime no pueden honrarlo, obtienes o bien un fallo duro o —peor— un no-op silencioso. Establece siempre el sustrato primero.

### Paso 1.1 — Confirmar que el kernel se compiló con filtrado seccomp

En un nodo (`docker exec -it cks54-worker bash`, o por SSH):

```bash
grep -E 'CONFIG_SECCOMP=|CONFIG_SECCOMP_FILTER=' /boot/config-$(uname -r) 2>/dev/null \
  || zgrep -E 'CONFIG_SECCOMP=|CONFIG_SECCOMP_FILTER=' /proc/config.gz
```

Esperado:

```
CONFIG_SECCOMP=y
CONFIG_SECCOMP_FILTER=y
```

### Paso 1.2 — Confirmar qué LSMs están activos, y en qué orden

```bash
cat /sys/kernel/security/lsm
```

Esperado en Ubuntu 22.04/24.04:

```
lockdown,capability,landlock,yama,apparmor,bpf
```

Si `apparmor` no aparece en esa lista, AppArmor está compilado pero **no habilitado**; necesitarías `apparmor=1 security=apparmor` en la línea de comandos del kernel. En nodos de la familia RHEL vas a ver `selinux` en su lugar — AppArmor simplemente no está disponible.

### Paso 1.3 — Confirmar el espacio de usuario de AppArmor y los perfiles cargados actualmente

```bash
sudo aa-status | head -20
```

Esperado (abreviado):

```
apparmor module is loaded.
apparmor filesystem is mounted.
44 profiles are loaded.
41 profiles are in enforce mode.
   /usr/bin/man
   /usr/lib/snapd/snap-confine
   cri-containerd.apparmor.d
   ...
3 profiles are in complain mode.
17 processes have profiles defined.
```

La vista autoritativa del lado del kernel —y el archivo exacto que lee el **kubelet** para decidir si puede admitir un Pod— es:

```bash
sudo cat /sys/kernel/security/apparmor/profiles | sort | head
```

```
cri-containerd.apparmor.d (enforce)
/usr/bin/man (enforce)
/usr/sbin/chronyd (enforce)
...
```

### Paso 1.4 — Verificar si el kubelet aplica por defecto `RuntimeDefault` a los workloads

```bash
ps -o args= -C kubelet | tr ' ' '\n' | grep -i seccomp
grep -i seccomp /var/lib/kubelet/config.yaml
```

Si ninguno imprime nada, `seccompDefault` está apagado y **un Pod sin `seccompProfile` corre con seccomp completamente deshabilitado**.

### Paso 1.5 — Verificar qué acciones de seccomp está dispuesto a registrar el kernel

```bash
cat /proc/sys/kernel/seccomp/actions_avail
cat /proc/sys/kernel/seccomp/actions_logged
```

Esperado:

```
kill_process kill_thread trap errno user_notif trace log allow
kill_process kill_thread trap errno user_notif trace log
```

> **Preguntas — Bloque 1**
> **Q1.** `CONFIG_SECCOMP_FILTER=y` está presente pero `CONFIG_SECCOMP=y` no (hipotéticamente). ¿Qué capacidad perderías, y cuál de las dos es de la que Kubernetes realmente depende?
> **Q2.** Tu nodo muestra `selinux` en `/sys/kernel/security/lsm` y ningún `apparmor`. Un manifiesto de Pod lleva `appArmorProfile: {type: RuntimeDefault}`. ¿Qué pasa en el momento de la admisión, y cuál es la remediación correcta en un clúster con sistemas operativos mixtos?
> **Q3.** `actions_logged` **no** contiene `log`. Luego despliegas un perfil cuyo `defaultAction` es `SCMP_ACT_LOG`. ¿Se bloquearán las syscalls del contenedor? ¿Vas a ver algo en el log de auditoría? ¿Por qué esto hace de `actions_logged` un chequeo previo obligatorio y no una curiosidad?

---

## Bloque 2 — Los tres tipos de perfil seccomp, observados desde dentro del contenedor

### Paso 2.1 — Desplegar un Pod **sin** configuración de seccomp

```yaml
# 01-seccomp-none.yaml
apiVersion: v1
kind: Pod
metadata:
  name: seccomp-none
  namespace: cks-54
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
```

```bash
kubectl apply -f 01-seccomp-none.yaml
kubectl wait --for=condition=Ready pod/seccomp-none --timeout=60s
kubectl exec seccomp-none -- grep -E '^(Seccomp|Seccomp_filters|NoNewPrivs):' /proc/1/status
```

Esperado (asumiendo que `seccompDefault` está apagado, como en el Paso 1.4):

```
Seccomp:	0
Seccomp_filters:	0
NoNewPrivs:	0
```

### Paso 2.2 — Desplegar el mismo Pod con `RuntimeDefault`

```yaml
# 02-seccomp-runtimedefault.yaml
apiVersion: v1
kind: Pod
metadata:
  name: seccomp-rtd
  namespace: cks-54
spec:
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
```

```bash
kubectl apply -f 02-seccomp-runtimedefault.yaml
kubectl wait --for=condition=Ready pod/seccomp-rtd --timeout=60s
kubectl exec seccomp-rtd -- grep -E '^(Seccomp|Seccomp_filters|NoNewPrivs):' /proc/1/status
```

Esperado:

```
Seccomp:	2
Seccomp_filters:	1
NoNewPrivs:	1
```

### Paso 2.3 — Demostrar que `RuntimeDefault` realmente está bloqueando algo

```bash
kubectl exec seccomp-none -- sh -c 'unshare -U true; echo "exit=$?"'
kubectl exec seccomp-rtd  -- sh -c 'unshare -U true; echo "exit=$?"'
```

Esperado (el texto exacto del errno varía según la versión del runtime):

```
exit=0
```
```
unshare: unshare(0x10000000): Operation not permitted
exit=1
```

### Paso 2.4 — Leer el filtro real que instaló el runtime

En el nodo:

```bash
CID=$(sudo crictl ps --name app --label io.kubernetes.pod.name=seccomp-rtd -q)
sudo crictl inspect "$CID" | jq '.info.runtimeSpec.linux.seccomp | {defaultAction, defaultErrnoRet, architectures, rules: (.syscalls | length)}'
```

Esperado (abreviado, containerd):

```json
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "defaultErrnoRet": 38,
  "architectures": ["SCMP_ARCH_X86_64", "SCMP_ARCH_X86", "SCMP_ARCH_X32"],
  "rules": 60
}
```

`38` es `ENOSYS`, no `EPERM`. Esa elección es deliberada y es una de las lecciones de producción más importantes de todo este tema — ver Q7.

> **Preguntas — Bloque 2**
> **Q4.** `/proc/1/status` muestra `Seccomp: 2`. ¿Qué significan `0`, `1` y `2`, y en cuál puede estar realistamente un contenedor además de 0 o 2?
> **Q5.** `NoNewPrivs` pasó de `0` a `1` en el mismo momento en que apareció el filtro seccomp. ¿Por qué no es una coincidencia? Cita la regla del kernel que lo fuerza, y nombra la única capability que exime a un proceso de ella.
> **Q6.** Un colega argumenta que `RuntimeDefault` es "el perfil por defecto de Kubernetes" y por lo tanto idéntico en cada clúster. Corrige esa afirmación con precisión: ¿quién es dueño del perfil, dónde vive, y qué implica eso para un manifiesto que debe comportarse igual en containerd y en CRI-O?
> **Q7.** El perfil por defecto de containerd devuelve `ENOSYS` (38) para syscalls que no conoce, pero `EPERM` (1) para syscalls que deniega explícitamente. Explica el modo de fallo que `ENOSYS` previene cuando un contenedor compilado contra una glibc nueva corre sobre un nodo con un perfil más viejo.

---

## Bloque 3 — Descubrir las syscalls que un workload realmente necesita (modo auditoría)

Nunca escribes una allowlist desde la imaginación. La escribes desde la evidencia.

### Paso 3.1 — Escribir un perfil de solo auditoría en el nodo

En tu estación de trabajo (el directorio está montado por bind en ambos nodos):

```bash
cat > ~/cks-54/profiles/audit.json <<'EOF'
{
  "defaultAction": "SCMP_ACT_LOG"
}
EOF
```

En un clúster kubeadm, en cambio, cópialo a **cada nodo** en `/var/lib/kubelet/seccomp/profiles/audit.json`.

### Paso 3.2 — Ejecutar el workload bajo el perfil de auditoría

```yaml
# 03-seccomp-audit.yaml
apiVersion: v1
kind: Pod
metadata:
  name: seccomp-audit
  namespace: cks-54
spec:
  securityContext:
    seccompProfile:
      type: Localhost
      localhostProfile: profiles/audit.json
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
```

```bash
kubectl apply -f 03-seccomp-audit.yaml
kubectl wait --for=condition=Ready pod/seccomp-audit --timeout=60s

# Generate a small, known set of syscalls
kubectl exec seccomp-audit -- sh -c 'mkdir -p /tmp/demo && touch /tmp/demo/f && chmod 600 /tmp/demo/f && ls -l /tmp/demo'
```

Esperado:

```
-rw-------    1 root     root             0 Aug  4 10:12 /tmp/demo/f
```

Nada fue bloqueado — `SCMP_ACT_LOG` **permite y registra**.

### Paso 3.3 — Recolectar la evidencia del log del kernel del nodo

```bash
sudo journalctl -k --since "-5 min" | grep -i 'seccomp\|audit(' | tail -20
# or, where journald is not collecting kernel audit records:
sudo dmesg | grep -i seccomp | tail -20
# or, with auditd installed:
sudo ausearch -m SECCOMP -ts recent -i | tail -40
```

Esperado (una línea por cada syscall distinta, plegada aquí para que se lea mejor):

```
audit: type=1326 audit(1785838352.114:277): auid=4294967295 uid=0 gid=0 ses=4294967295
  pid=31465 comm="chmod" exe="/bin/busybox" sig=0 arch=c000003e syscall=268 compat=0
  ip=0x7f1c9d2a4b27 code=0x7ffc0000
```

### Paso 3.4 — Traducir los números a nombres

```bash
ausyscall x86_64 268        # from the auditd package
scmp_sys_resolver -a x86_64 268   # from libseccomp-tools
```

```
fchmodat
```

Decodifica el resto del registro:

| Campo | Valor | Significado |
|---|---|---|
| `type=1326` | — | `AUDIT_SECCOMP` |
| `arch=c000003e` | — | `AUDIT_ARCH_X86_64` (`0xc000003e`) |
| `syscall=268` | `fchmodat` | El número de syscall **para esa arquitectura** |
| `code=0x7ffc0000` | — | `SECCOMP_RET_LOG` |
| `comm` / `exe` | `chmod` | El binario infractor — tu pista más rápida |

Otros valores de `code` que debes reconocer de inmediato:

| `code` | Constante | Efecto |
|---|---|---|
| `0x00000000` | `SECCOMP_RET_KILL_THREAD` | El hilo es terminado con `SIGSYS` |
| `0x80000000` | `SECCOMP_RET_KILL_PROCESS` | Se termina todo el grupo de hilos |
| `0x00030000` | `SECCOMP_RET_TRAP` | Se entrega `SIGSYS` al proceso |
| `0x00050001` | `SECCOMP_RET_ERRNO` \| `EPERM` | La syscall devuelve `-EPERM` |
| `0x7ffc0000` | `SECCOMP_RET_LOG` | Permitida, registrada |
| `0x7fff0000` | `SECCOMP_RET_ALLOW` | Permitida, nunca registrada |

### Paso 3.5 — Convertir la cosecha en una allowlist candidata

```bash
sudo journalctl -k --since "-10 min" \
  | grep -oP 'syscall=\K[0-9]+' | sort -un \
  | while read -r n; do scmp_sys_resolver -a x86_64 "$n"; done \
  | sort -u | paste -sd'", "' - | sed 's/^/"/; s/$/"/'
```

Forma esperada:

```
"brk", "chmod", "close", "execve", "fchmodat", "mkdirat", "openat", "write", ...
```

> **Preguntas — Bloque 3**
> **Q8.** `localhostProfile` es `profiles/audit.json`, pero el archivo en disco es `/var/lib/kubelet/seccomp/profiles/audit.json`. Enuncia la regla que aplica el kubelet, y di exactamente qué pasa si escribes `/var/lib/kubelet/seccomp/profiles/audit.json` o `../../etc/audit.json` en su lugar.
> **Q9.** La corrida de auditoría produjo 41 syscalls distintas. ¿Por qué es una práctica *peligrosa* enviar exactamente esas 41 como tu allowlist en modo enforcing, y qué dos categorías de syscall casi seguramente no capturó tu corrida?
> **Q10.** Ves `arch=c000003e` en cada registro. Un binario auxiliar compilado a 32 bits dentro de la misma imagen produciría un `arch` distinto. Explica cómo puede un atacante explotar un perfil cuya lista `architectures` contiene solo `SCMP_ARCH_X86_64`.

---

## Bloque 4 — Un perfil en modo enforcing, y la trampa de la denylist

### Paso 4.1 — La denylist ingenua (esta es la trampa)

```bash
cat > ~/cks-54/profiles/deny-chmod-naive.json <<'EOF'
{
  "defaultAction": "SCMP_ACT_ALLOW",
  "architectures": ["SCMP_ARCH_X86_64", "SCMP_ARCH_X86", "SCMP_ARCH_X32"],
  "syscalls": [
    {
      "names": ["chmod"],
      "action": "SCMP_ACT_ERRNO",
      "errnoRet": 1
    }
  ]
}
EOF
```

```yaml
# 04-seccomp-deny-naive.yaml
apiVersion: v1
kind: Pod
metadata:
  name: seccomp-deny-naive
  namespace: cks-54
spec:
  securityContext:
    seccompProfile:
      type: Localhost
      localhostProfile: profiles/deny-chmod-naive.json
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
```

```bash
kubectl apply -f 04-seccomp-deny-naive.yaml
kubectl wait --for=condition=Ready pod/seccomp-deny-naive --timeout=60s
kubectl exec seccomp-deny-naive -- sh -c 'touch /tmp/f && chmod 777 /tmp/f && echo "CHMOD SUCCEEDED"'
```

Esperado — el "bloqueo" no hizo nada:

```
CHMOD SUCCEEDED
```

La syscall `chmod(2)` nunca se emitió. musl (y glibc) implementan `chmod()` como `fchmodat(AT_FDCWD, ...)`, syscall **268** — exactamente lo que el log de auditoría te dijo en el Paso 3.4.

### Paso 4.2 — Arreglarlo cubriendo toda la familia de syscalls

```bash
cat > ~/cks-54/profiles/deny-chmod.json <<'EOF'
{
  "defaultAction": "SCMP_ACT_ALLOW",
  "architectures": ["SCMP_ARCH_X86_64", "SCMP_ARCH_X86", "SCMP_ARCH_X32"],
  "syscalls": [
    {
      "names": ["chmod", "fchmod", "fchmodat", "fchmodat2"],
      "action": "SCMP_ACT_ERRNO",
      "errnoRet": 1
    }
  ]
}
EOF
```

```yaml
# 05-seccomp-deny.yaml
apiVersion: v1
kind: Pod
metadata:
  name: seccomp-deny
  namespace: cks-54
spec:
  securityContext:
    seccompProfile:
      type: Localhost
      localhostProfile: profiles/deny-chmod.json
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
```

```bash
kubectl apply -f 05-seccomp-deny.yaml
kubectl wait --for=condition=Ready pod/seccomp-deny --timeout=60s
kubectl exec seccomp-deny -- sh -c 'touch /tmp/f; chmod 777 /tmp/f; echo "exit=$?"'
```

Esperado:

```
chmod: /tmp/f: Operation not permitted
exit=1
```

> `fchmodat2` se agregó en Linux 6.6 (nr 452 en x86_64). Con una `libseccomp` más vieja el runtime puede rechazar el nombre desconocido. Si la creación del contenedor falla con `failed to load seccomp filter: unknown syscall "fchmodat2"`, elimina esa entrada — y toma nota de que acabas de descubrir que tu denylist tiene un agujero en kernels más nuevos.

### Paso 4.3 — Romper un workload deliberadamente con una allowlist

```bash
cat > ~/cks-54/profiles/too-strict.json <<'EOF'
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "defaultErrnoRet": 1,
  "architectures": ["SCMP_ARCH_X86_64", "SCMP_ARCH_X86", "SCMP_ARCH_X32"],
  "syscalls": [
    {
      "names": ["execve", "exit", "exit_group", "read", "write", "close"],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
EOF
```

```yaml
# 06-seccomp-too-strict.yaml
apiVersion: v1
kind: Pod
metadata:
  name: seccomp-too-strict
  namespace: cks-54
spec:
  restartPolicy: Never
  securityContext:
    seccompProfile:
      type: Localhost
      localhostProfile: profiles/too-strict.json
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
```

```bash
kubectl apply -f 06-seccomp-too-strict.yaml
sleep 5
kubectl get pod seccomp-too-strict
kubectl describe pod seccomp-too-strict | sed -n '/Events:/,$p'
```

Esperado:

```
NAME                 READY   STATUS             RESTARTS   AGE
seccomp-too-strict   0/1     ContainerCannotRun 0          5s
```

```
Events:
  Type     Reason     Age   From     Message
  ----     ------     ----  ----     -------
  Normal   Pulled     6s    kubelet  Container image "busybox:1.36" already present on machine
  Normal   Created    6s    kubelet  Created container: app
  Warning  Failed     5s    kubelet  Error: failed to start container "app": ...
```

Ahora encuentra el *porqué* en el nodo:

```bash
sudo journalctl -k --since "-2 min" | grep 'comm="sh"\|comm="runc"' | tail -5
```

```
audit: type=1326 audit(...): pid=31980 comm="sh" exe="/bin/busybox" sig=0
  arch=c000003e syscall=12 compat=0 ip=0x... code=0x00050001
```

`syscall=12` es `brk` — lo primerísimo que hace el runtime de C. `code=0x00050001` es `SECCOMP_RET_ERRNO | EPERM`.

> **Preguntas — Bloque 4**
> **Q11.** Reformula la lección general del Paso 4.1 en una sola oración, y nombra la clase de syscall (más allá de los alias) que vuelve las denylists estructuralmente irreparables en Linux.
> **Q12.** En el Paso 4.3 el log de auditoría se pobló igual aunque el `defaultAction` era `SCMP_ACT_ERRNO`, no `SCMP_ACT_LOG`. ¿Qué perilla del kernel hace eso posible, y por qué esa perilla es una decisión a *nivel de nodo* y no a nivel de Pod?
> **Q13.** Necesitas "este contenedor nunca debe escribir en `/etc/shadow`". ¿Puede seccomp expresar eso? Responde con la razón estructural concreta, refiriéndote a qué recibe como entrada un programa cBPF de seccomp.
> **Q14.** Compara `SCMP_ACT_ERRNO` y `SCMP_ACT_KILL_PROCESS` como `defaultAction` de un perfil de producción. ¿Cuál desplegarías primero durante un rollout, y cuál es el mejor estado final a largo plazo? Justifica ambas mitades.

---

## Bloque 5 — `RuntimeDefault` a escala: default del kubelet y Pod Security Admission

### Paso 5.1 — Confirmar que el override a nivel de contenedor le gana al nivel de Pod

```yaml
# 07-seccomp-override.yaml
apiVersion: v1
kind: Pod
metadata:
  name: seccomp-override
  namespace: cks-54
spec:
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: hardened
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
  - name: escaped
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    securityContext:
      seccompProfile:
        type: Unconfined
```

```bash
kubectl apply -f 07-seccomp-override.yaml
kubectl wait --for=condition=Ready pod/seccomp-override --timeout=60s
kubectl exec seccomp-override -c hardened -- grep ^Seccomp: /proc/1/status
kubectl exec seccomp-override -c escaped  -- grep ^Seccomp: /proc/1/status
```

Esperado:

```
Seccomp:	2
```
```
Seccomp:	0
```

Este es un patrón real de hallazgo de auditoría: el Pod parece endurecido a primera vista, y un sidecar no lo está. `kubectl get pod -o jsonpath` es la forma de detectarlo a escala:

```bash
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\t"}{.spec.securityContext.seccompProfile.type}{"\t"}{range .spec.containers[*]}{.name}{"="}{.securityContext.seccompProfile.type}{" "}{end}{"\n"}{end}' | column -t
```

### Paso 5.2 — Aplicarlo declarativamente con Pod Security Admission

```bash
kubectl label namespace cks-54 \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest --overwrite

kubectl delete pod seccomp-override --ignore-not-found
kubectl apply -f 07-seccomp-override.yaml
```

Esperado:

```
Error from server (Forbidden): error when creating "07-seccomp-override.yaml": pods "seccomp-override" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (containers "hardened", "escaped" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (containers "hardened", "escaped" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or containers "hardened", "escaped" must set securityContext.runAsNonRoot=true), seccompProfile (container "escaped" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

### Paso 5.3 — Un Pod totalmente conforme con `restricted`

```yaml
# 08-restricted.yaml
apiVersion: v1
kind: Pod
metadata:
  name: restricted-ok
  namespace: cks-54
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
```

```bash
kubectl apply -f 08-restricted.yaml
kubectl wait --for=condition=Ready pod/restricted-ok --timeout=60s
kubectl exec restricted-ok -- grep -E '^(Seccomp|NoNewPrivs):' /proc/1/status
```

```
Seccomp:	2
NoNewPrivs:	1
```

### Paso 5.4 — Default a nivel de clúster vía el kubelet (ejercicio de solo lectura)

El equivalente a nivel de nodo, definido en `/var/lib/kubelet/config.yaml`:

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
seccompDefault: true
```

seguido de `sudo systemctl restart kubelet`. Todo contenedor que no especifique un `seccompProfile` obtiene entonces `RuntimeDefault` en lugar de `Unconfined`.

Quita la etiqueta de nuevo para que PSA no bloquee los bloques siguientes:

```bash
kubectl label namespace cks-54 pod-security.kubernetes.io/enforce- pod-security.kubernetes.io/enforce-version-
```

> **Preguntas — Bloque 5**
> **Q15.** `seccompDefault: true` en el kubelet y `enforce=restricted` en el namespace empujan ambos a los workloads hacia `RuntimeDefault`. Describe la diferencia en *dónde* y *cuándo* actúa cada uno, y da un escenario que cada uno atrapa y el otro no.
> **Q16.** Bajo el nivel PSA `baseline` (no `restricted`), ¿qué valores de `spec.securityContext.seccompProfile.type` se aceptan, y cuál único valor se rechaza? Haz lo mismo para `appArmorProfile.type`.
> **Q17.** Activaste `seccompDefault: true` y un workload Java heredado empezó de inmediato a hacer crash-loop. Da la secuencia exacta de tres comandos que ejecutarías para identificar la syscall infractora, y di cuáles son tus opciones de remediación ordenadas de mejor a peor.

---

## Bloque 6 — AppArmor: escribir, cargar, iterar

> De aquí en adelante, usa un **nodo real** (kubeadm/VM). Todo el trabajo con `apparmor_parser` ocurre por SSH en el nodo, no a través de `kubectl`.

### Paso 6.1 — Escribir un perfil deliberadamente tosco

En `node01`:

```bash
sudo tee /etc/apparmor.d/k8s-deny-write > /dev/null <<'EOF'
abi <abi/3.0>,

#include <tunables/global>

profile k8s-deny-write flags=(attach_disconnected) {
  #include <abstractions/base>

  file,
  network,
  capability,

  # An explicit deny always wins over any allow rule, regardless of order.
  deny /** w,
}
EOF
```

> Si tu parser da error en la línea `abi`, tu AppArmor es 2.x — elimina esa línea. En Ubuntu 24.04 usa `abi <abi/4.0>,`.

### Paso 6.2 — Cargarlo primero en modo **complain**, nunca directo a enforce

```bash
sudo apparmor_parser -q -C -r -W /etc/apparmor.d/k8s-deny-write
sudo aa-status | grep -A2 'complain mode'
```

Esperado:

```
1 profiles are in complain mode.
   k8s-deny-write
```

Significados de los flags que debes saber de memoria:

| Flag | Efecto |
|---|---|
| `-r` | Reemplaza un perfil ya cargado (idempotente; este es el que quieres) |
| `-a` | Agrega — **falla** si el perfil ya está cargado |
| `-R` | Elimina el perfil del kernel |
| `-C` | Carga en modo **complain** (registra, no bloquea) |
| `-W` | Escribe la política compilada en la caché |
| `-q` | Silencioso |

### Paso 6.3 — Adjuntar el perfil a un Pod usando el **campo GA**

```yaml
# 09-apparmor-deny-write.yaml
apiVersion: v1
kind: Pod
metadata:
  name: aa-deny-write
  namespace: cks-54
spec:
  nodeName: node01          # the profile is only loaded here — see Block 7
  securityContext:
    appArmorProfile:
      type: Localhost
      localhostProfile: k8s-deny-write
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
```

```bash
kubectl apply -f 09-apparmor-deny-write.yaml
kubectl wait --for=condition=Ready pod/aa-deny-write --timeout=60s
kubectl exec aa-deny-write -- cat /proc/1/attr/current
```

Esperado:

```
k8s-deny-write (complain)
```

### Paso 6.4 — Observar el comportamiento en modo complain: permitido, pero registrado

```bash
kubectl exec aa-deny-write -- sh -c 'touch /tmp/probe; echo "exit=$?"'
```

```
exit=0
```

En `node01`:

```bash
sudo dmesg | grep -i apparmor | tail -3
```

```
[ 4127.882134] audit: type=1400 audit(1785840112.441:412): apparmor="ALLOWED"
  operation="mknod" class="file" profile="k8s-deny-write" name="/tmp/probe"
  pid=8842 comm="touch" requested_mask="c" denied_mask="c" fsuid=0 ouid=0
```

`apparmor="ALLOWED"` **con un `denied_mask` no vacío** es la firma del modo complain: "esto lo habría bloqueado".

### Paso 6.5 — Promover a enforce y volver a probar

```bash
sudo apparmor_parser -q -r -W /etc/apparmor.d/k8s-deny-write   # note: no -C
sudo aa-status | grep k8s-deny-write
```

```
   k8s-deny-write
```

El cambio de perfil se aplica a los procesos **ya en ejecución** — no hace falta reiniciar el Pod:

```bash
kubectl exec aa-deny-write -- cat /proc/1/attr/current
kubectl exec aa-deny-write -- sh -c 'touch /tmp/probe2; echo "exit=$?"'
kubectl exec aa-deny-write -- sh -c 'cat /etc/hostname; echo "read exit=$?"'
```

Esperado:

```
k8s-deny-write (enforce)
```
```
touch: /tmp/probe2: Permission denied
exit=1
```
```
aa-deny-write
read exit=0
```

Y el registro correspondiente del kernel:

```bash
sudo dmesg | grep 'apparmor="DENIED"' | tail -2
```

```
[ 4230.114872] audit: type=1400 audit(1785840215.673:418): apparmor="DENIED"
  operation="mknod" class="file" profile="k8s-deny-write" name="/tmp/probe2"
  pid=9013 comm="touch" requested_mask="c" denied_mask="c" fsuid=0 ouid=0
```

### Paso 6.6 — Escribir un perfil realista, con forma de producción

```bash
sudo tee /etc/apparmor.d/k8s-nginx > /dev/null <<'EOF'
abi <abi/3.0>,

#include <tunables/global>

profile k8s-nginx flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>
  #include <abstractions/nameservice>

  capability chown,
  capability dac_override,
  capability setgid,
  capability setuid,
  capability net_bind_service,

  network inet  stream,
  network inet6 stream,

  /usr/sbin/nginx            mr,
  /etc/nginx/**              r,
  /usr/share/nginx/**        r,
  /var/log/nginx/*.log       w,
  /var/cache/nginx/**        rw,
  /run/nginx.pid             rw,
  /proc/sys/kernel/ngroups_max r,

  # High-value denials: this app has no business reading any of these,
  # even though the kubelet mounts the ServiceAccount token into it.
  deny /var/run/secrets/kubernetes.io/serviceaccount/** rwklx,
  deny /etc/shadow  rwklx,
  deny /root/**     rwklx,
  deny /proc/*/mem  rwklx,
}
EOF

sudo apparmor_parser -q -r -W /etc/apparmor.d/k8s-nginx
```

```yaml
# 10-apparmor-nginx.yaml
apiVersion: v1
kind: Pod
metadata:
  name: aa-nginx
  namespace: cks-54
spec:
  nodeName: node01
  securityContext:
    appArmorProfile:
      type: Localhost
      localhostProfile: k8s-nginx
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: web
    image: nginx:1.27-alpine
    ports:
    - containerPort: 80
```

```bash
kubectl apply -f 10-apparmor-nginx.yaml
kubectl wait --for=condition=Ready pod/aa-nginx --timeout=90s

kubectl exec aa-nginx -- cat /proc/1/attr/current
kubectl exec aa-nginx -- cat /var/run/secrets/kubernetes.io/serviceaccount/token
```

Esperado:

```
k8s-nginx (enforce)
```
```
cat: can't open '/var/run/secrets/kubernetes.io/serviceaccount/token': Permission denied
command terminated with exit code 1
```

Ese es el resultado destacado: **el token está montado y aun así la aplicación no puede leerlo.** Un drop de capabilities no puede hacer eso; una NetworkPolicy no puede hacer eso; seccomp no puede hacer eso.

### Paso 6.7 — Usar `aa-logprof` para hacer crecer un perfil a partir de las denegaciones

```bash
sudo aa-logprof -f /var/log/syslog
```

`aa-logprof` reproduce los registros `DENIED`/`ALLOWED`-con-denied-mask y propone reglas de forma interactiva (`A`llow / `D`eny / `I`nherit / `S`ave). Este es el flujo de trabajo sancionado: ejecutar en complain, recorrer cada ruta de código (incluidas las rutas de error, la rotación de logs y el apagado), y luego dejar que `aa-logprof` escriba las reglas.

> **Preguntas — Bloque 6**
> **Q18.** En el Paso 6.1 el perfil contiene tanto `file,` (permitir todo acceso a archivos) como `deny /** w,`. Las lecturas siguieron funcionando y las escrituras no. Enuncia la regla de precedencia de AppArmor entre `allow` y `deny`, y di si reordenar las dos líneas cambiaría algo.
> **Q19.** En el Paso 6.5 el confinamiento del contenedor en ejecución cambió de `complain` a `enforce` sin reiniciar el Pod. Explica el mecanismo: ¿dónde vive el confinamiento, y qué mutó exactamente `apparmor_parser -r`?
> **Q20.** Contrasta la diferencia de sintaxis relevante para el examen: el valor de `localhostProfile` de **seccomp** frente al de **AppArmor**. Da el valor que toma cada uno y la razón de la diferencia.
> **Q21.** `flags=(attach_disconnected)` aparece prácticamente en todos los perfiles de AppArmor para contenedores. ¿Qué problema resuelve, y por qué es específicamente un problema de *contenedores*?

---

## Bloque 7 — Los cuatro modos de fallo que debes diagnosticar en menos de dos minutos

### Paso 7.1 — Modo de fallo A: perfil no cargado en el nodo planificado

El perfil del Bloque 6 existe solo en `node01`. Fuerza el Pod al plano de control:

```yaml
# 11-apparmor-wrong-node.yaml
apiVersion: v1
kind: Pod
metadata:
  name: aa-wrong-node
  namespace: cks-54
spec:
  nodeName: controlplane
  tolerations:
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule
  securityContext:
    appArmorProfile:
      type: Localhost
      localhostProfile: k8s-deny-write
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
```

```bash
kubectl apply -f 11-apparmor-wrong-node.yaml
sleep 5
kubectl get pod aa-wrong-node
kubectl get pod aa-wrong-node -o jsonpath='{.status.phase}{"\t"}{.status.reason}{"\t"}{.status.message}{"\n"}'
```

Esperado (la redacción varía ligeramente según la versión del kubelet):

```
NAME            READY   STATUS     RESTARTS   AGE
aa-wrong-node   0/1     AppArmor   0          5s
```
```
Failed	AppArmor	Cannot enforce AppArmor: profile "k8s-deny-write" is not loaded
```

El kubelet rechaza el Pod **en la admisión**, leyendo `/sys/kernel/security/apparmor/profiles` en su propio nodo. En algunas combinaciones de runtime/kubelet caes en cambio en `CreateContainerError` con un mensaje de containerd. En cualquier caso el diagnóstico es idéntico:

```bash
ssh controlplane -- 'sudo aa-status | grep k8s-deny-write || echo "NOT LOADED HERE"'
```

**Nota la asimetría respecto de seccomp:** un **archivo** `localhostProfile` faltante produce un error de creación del contenedor por parte del runtime, no un rechazo en la admisión:

```bash
kubectl run bad-seccomp --image=busybox:1.36 --restart=Never \
  --overrides='{"spec":{"securityContext":{"seccompProfile":{"type":"Localhost","localhostProfile":"profiles/nope.json"}}}}' \
  -- sleep 3600
kubectl describe pod bad-seccomp | grep -A3 'Warning'
```

```
  Warning  Failed  3s  kubelet  Error: failed to generate spec: cannot load seccomp profile
  "/var/lib/kubelet/seccomp/profiles/nope.json": open /var/lib/kubelet/seccomp/profiles/nope.json:
  no such file or directory
```

### Paso 7.2 — Distribuir perfiles a todos los nodos con un DaemonSet

```yaml
# 12-apparmor-loader.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: apparmor-profiles
  namespace: cks-54
data:
  k8s-deny-write: |
    #include <tunables/global>

    profile k8s-deny-write flags=(attach_disconnected) {
      #include <abstractions/base>
      file,
      network,
      capability,
      deny /** w,
    }
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: apparmor-loader
  namespace: cks-54
spec:
  selector:
    matchLabels:
      app: apparmor-loader
  template:
    metadata:
      labels:
        app: apparmor-loader
    spec:
      hostPID: true
      tolerations:
      - operator: Exists
      initContainers:
      - name: load
        image: ubuntu:24.04
        command:
        - sh
        - -c
        - |
          set -euo pipefail
          apt-get update -qq && apt-get install -y -qq apparmor-utils >/dev/null
          for f in /profiles/*; do
            apparmor_parser -q -r -W "$f"
            echo "loaded: $f"
          done
        securityContext:
          privileged: true
        volumeMounts:
        - name: profiles
          mountPath: /profiles
          readOnly: true
        - name: apparmorfs
          mountPath: /sys/kernel/security
      containers:
      - name: pause
        image: registry.k8s.io/pause:3.10
      volumes:
      - name: profiles
        configMap:
          name: apparmor-profiles
      - name: apparmorfs
        hostPath:
          path: /sys/kernel/security
          type: Directory
```

```bash
kubectl apply -f 12-apparmor-loader.yaml
kubectl rollout status ds/apparmor-loader --timeout=180s
kubectl delete pod aa-wrong-node --ignore-not-found
kubectl apply -f 11-apparmor-wrong-node.yaml
kubectl wait --for=condition=Ready pod/aa-wrong-node --timeout=60s
kubectl exec aa-wrong-node -- cat /proc/1/attr/current
```

```
k8s-deny-write (enforce)
```

> Este DaemonSet es **privilegiado y monta securityfs** — eso es inherente a cargar política del kernel desde un Pod, y es exactamente por eso que la recomendación upstream es hornear los perfiles en la imagen del nodo o distribuirlos con tu herramienta de gestión de configuración. Si aun así corres un loader, trátalo como un componente de la categoría del plano de control: su propio namespace, su propio RBAC, sin acceso de escritura de usuarios al ConfigMap.

### Paso 7.3 — Modo de fallo B: un override a nivel de contenedor deja un sidecar sin confinar en silencio

```yaml
# 13-apparmor-override.yaml
apiVersion: v1
kind: Pod
metadata:
  name: aa-override
  namespace: cks-54
spec:
  nodeName: node01
  securityContext:
    appArmorProfile:
      type: Localhost
      localhostProfile: k8s-deny-write
  containers:
  - name: confined
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
  - name: unconfined
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    securityContext:
      appArmorProfile:
        type: Unconfined
```

```bash
kubectl apply -f 13-apparmor-override.yaml
kubectl wait --for=condition=Ready pod/aa-override --timeout=60s
kubectl exec aa-override -c confined   -- cat /proc/1/attr/current
kubectl exec aa-override -c unconfined -- cat /proc/1/attr/current
kubectl exec aa-override -c unconfined -- sh -c 'touch /tmp/x && echo WROTE'
```

```
k8s-deny-write (enforce)
```
```
unconfined
```
```
WROTE
```

### Paso 7.4 — Modo de fallo C: la anotación obsoleta

```yaml
# 14-apparmor-annotation.yaml  -- LEGACY, do not use in new work
apiVersion: v1
kind: Pod
metadata:
  name: aa-annotation
  namespace: cks-54
  annotations:
    container.apparmor.security.beta.kubernetes.io/app: localhost/k8s-deny-write
spec:
  nodeName: node01
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
```

```bash
kubectl apply -f 14-apparmor-annotation.yaml
kubectl wait --for=condition=Ready pod/aa-annotation --timeout=60s
kubectl get pod aa-annotation -o jsonpath='{.spec.containers[0].securityContext.appArmorProfile}{"\n"}'
```

Esperado — el API server rellenó el campo a partir de la anotación:

```json
{"localhostProfile":"k8s-deny-write","type":"Localhost"}
```

La forma con anotación está **obsoleta desde Kubernetes v1.30**, cuando el campo `appArmorProfile` pasó a GA. Fíjate en el prefijo `localhost/` que la anotación requiere y el campo prohíbe — confundirlos es el error de sintaxis más común de este tema.

### Paso 7.5 — Modo de fallo D: auditar todo el clúster con un solo comando

```bash
kubectl get pods -A -o json | jq -r '
  .items[] |
  . as $p |
  ($p.spec.securityContext.appArmorProfile.type // "-") as $paa |
  ($p.spec.securityContext.seccompProfile.type // "-") as $psc |
  $p.spec.containers[] |
  [$p.metadata.namespace, $p.metadata.name, .name,
   (.securityContext.appArmorProfile.type // $paa),
   (.securityContext.seccompProfile.type  // $psc)] | @tsv
' | awk '$4=="-" || $5=="-" || $4=="Unconfined" || $5=="Unconfined"' | column -t
```

Cada fila que esto imprime está sin confinar o explícitamente excluida.

> **Preguntas — Bloque 7**
> **Q22.** Compara la firma de fallo de un perfil de **AppArmor** faltante contra la de un archivo de perfil de **seccomp** faltante. ¿En qué punto del ciclo de vida falla cada uno, qué componente produce el mensaje, y qué te dice eso sobre dónde el kubelet pre-valida y dónde no?
> **Q23.** El DaemonSet `apparmor-loader` es privilegiado y monta `/sys/kernel/security` del host. Nombra la escalada de privilegios concreta que gana un atacante con acceso de escritura al ConfigMap `apparmor-profiles`, y da dos mitigaciones.
> **Q24.** Un Pod en un namespace con `enforce=baseline` lleva `appArmorProfile: {type: Unconfined}` en un contenedor. ¿Qué pasa, y cuál es la razón exacta por la que a `baseline` —y no solo a `restricted`— le importa esto?

---

## Bloque 8 — Estratificar: por qué necesitas ambos, más el tooling que lo automatiza

### Paso 8.1 — Demostrar que seccomp no puede ver rutas y AppArmor no puede ver argumentos de syscall

```yaml
# 15-layered.yaml
apiVersion: v1
kind: Pod
metadata:
  name: layered
  namespace: cks-54
spec:
  nodeName: node01
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    seccompProfile:
      type: Localhost
      localhostProfile: profiles/deny-chmod.json
    appArmorProfile:
      type: Localhost
      localhostProfile: k8s-nginx
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
```

```bash
kubectl apply -f 15-layered.yaml
kubectl wait --for=condition=Ready pod/layered --timeout=60s

kubectl exec layered -- cat /proc/1/attr/current
kubectl exec layered -- grep -E '^(Seccomp|NoNewPrivs):' /proc/1/status
```

```
k8s-nginx (enforce)
```
```
Seccomp:	2
NoNewPrivs:	1
```

Completa esta tabla con tus propios experimentos antes de leer las respuestas:

| Objetivo de control | seccomp | AppArmor | capabilities |
|---|---|---|---|
| Bloquear `chmod` sobre **cualquier** archivo | ? | ? | ? |
| Bloquear escrituras **solo a `/etc/shadow`** | ? | ? | ? |
| Bloquear `mount(2)` por completo | ? | ? | ? |
| Bloquear sockets raw | ? | ? | ? |
| Bloquear `bpf(2)` / `perf_event_open(2)` | ? | ? | ? |
| Bloquear la lectura del archivo de token de la ServiceAccount | ? | ? | ? |

### Paso 8.2 — Saber que el problema del registro ya está resuelto (Security Profiles Operator)

Cosechar logs de auditoría a mano, como hiciste en el Bloque 3, no escala más allá de un puñado de workloads. El proyecto de la CNCF para esto es el **Security Profiles Operator**, que provee los CRDs `SeccompProfile` y `AppArmorProfile`, un CRD `ProfileRecording` que graba un workload en ejecución (vía eBPF o el enricher del log de auditoría) y emite un perfil, y un DaemonSet que distribuye los perfiles a los nodos y los reconcilia.

```yaml
# Illustrative only — requires the operator to be installed.
apiVersion: security-profiles-operator.x-k8s.io/v1alpha1
kind: ProfileRecording
metadata:
  name: record-nginx
  namespace: cks-54
spec:
  kind: SeccompProfile
  recorder: bpf
  podSelector:
    matchLabels:
      app: nginx
```

**No** se te exige operar SPO para el examen, pero sí se espera que sepas que existe y qué problema resuelve.

> **Preguntas — Bloque 8**
> **Q25.** Completa la tabla del Paso 8.1 y, para cada fila donde dos mecanismos funcionan, di cuál elegirías y por qué.
> **Q26.** Da la afirmación arquitectónica de una sola oración sobre por qué seccomp y AppArmor son complementarios y no redundantes, en términos de *qué está autorizado a inspeccionar cada uno*.
> **Q27.** Un `ProfileRecording` con `recorder: bpf` observó un workload durante una hora bajo carga normal y produjo un perfil de 74 syscalls. Nombra tres modos de fallo de llevar ese perfil a producción sin modificarlo.

---

## Matriz de troubleshooting — memoriza esta forma

| Síntoma | Causa más probable | Primer comando |
|---|---|---|
| `STATUS: AppArmor`, mensaje `profile "X" is not loaded` | Perfil ausente en el nodo **planificado** | `ssh <node> sudo aa-status \| grep X` |
| `cannot load seccomp profile ...: no such file` | Ruta de `localhostProfile` incorrecta, o archivo presente en un solo nodo | `ssh <node> ls -l /var/lib/kubelet/seccomp/profiles/` |
| El Pod corre pero `/proc/1/status` muestra `Seccomp: 0` | Override `Unconfined` a nivel de contenedor, o ningún perfil definido y `seccompDefault` apagado | `kubectl get pod X -o jsonpath='{.spec.containers[*].securityContext}'` |
| `/proc/1/attr/current` muestra `unconfined` | `appArmorProfile: Unconfined` a nivel de contenedor, o el runtime no soporta AppArmor | `kubectl get pod X -o yaml \| grep -A3 appArmorProfile` |
| El contenedor sale de inmediato, sin logs útiles | A la allowlist le falta una syscall de arranque | `sudo journalctl -k \| grep 'type=1326' \| tail` y luego `scmp_sys_resolver -a x86_64 <n>` |
| La app falla solo en una ruta de código | Denegación de AppArmor en una ruta poco frecuente | `sudo dmesg \| grep 'apparmor="DENIED"'` |
| `Forbidden ... violates PodSecurity` | PSA, no el kernel — nada llegó al nodo | lee el mensaje; nombra el campo y el contenedor |
| `unknown syscall "..."` al crear el contenedor | `libseccomp`/runtime más viejo que el nombre de la syscall | `crictl version`; elimina o condiciona la entrada |

**El reflejo de los dos archivos.** Cada vez que tengas delante una pregunta de endurecimiento:

```bash
kubectl exec <pod> [-c <ctr>] -- cat /proc/1/attr/current               # AppArmor: profile + mode
kubectl exec <pod> [-c <ctr>] -- grep -E '^(Seccomp|NoNewPrivs):' /proc/1/status   # seccomp
```

---

## Simulacro de examen — 8 minutos, sin documentación salvo kubernetes.io

1. En `node01`, crea y carga en modo **enforce** un perfil llamado `k8s-audit-block` que deniegue todas las escrituras bajo `/data/` pero permita todo lo demás.
2. Crea el Pod `drill` en el namespace `cks-54` sobre `node01`, imagen `busybox:1.36`, comando `sleep 3600`, confinado por `k8s-audit-block` **y** usando el perfil seccomp por defecto del runtime.
3. Demuestra que ambos están activos con un solo `kubectl exec` por mecanismo.
4. Agrega un segundo contenedor `sidecar` que sea explícitamente seccomp-`Unconfined`, aplica, y luego etiqueta el namespace con `enforce=baseline`. Predice el resultado **antes** de ejecutarlo, y después verifícalo.

Solución modelo:

```bash
sudo tee /etc/apparmor.d/k8s-audit-block > /dev/null <<'EOF'
#include <tunables/global>
profile k8s-audit-block flags=(attach_disconnected) {
  #include <abstractions/base>
  file,
  network,
  capability,
  deny /data/** w,
}
EOF
sudo apparmor_parser -q -r -W /etc/apparmor.d/k8s-audit-block
sudo aa-status | grep k8s-audit-block
```

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: drill
  namespace: cks-54
spec:
  nodeName: node01
  securityContext:
    appArmorProfile:
      type: Localhost
      localhostProfile: k8s-audit-block
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
```

```bash
kubectl exec drill -- cat /proc/1/attr/current      # k8s-audit-block (enforce)
kubectl exec drill -- grep ^Seccomp: /proc/1/status # Seccomp: 2
kubectl exec drill -- sh -c 'mkdir -p /data && touch /data/x'   # Permission denied
```

Para el paso 4: `baseline` **rechaza** `seccompProfile.type: Unconfined` — el Pod entero es rechazado en la admisión, incluido el contenedor que sí cumple.

---

## Limpieza

```bash
kubectl delete namespace cks-54
# On each node:
sudo apparmor_parser -R /etc/apparmor.d/k8s-deny-write
sudo apparmor_parser -R /etc/apparmor.d/k8s-nginx
sudo apparmor_parser -R /etc/apparmor.d/k8s-audit-block
sudo rm -f /etc/apparmor.d/k8s-deny-write /etc/apparmor.d/k8s-nginx /etc/apparmor.d/k8s-audit-block
sudo rm -f /var/lib/kubelet/seccomp/profiles/{audit,deny-chmod,deny-chmod-naive,too-strict}.json
# kind:
kind delete cluster --name cks54
```

---

## Fuentes

- CNCF, *CKS Curriculum v1.34* — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes, *Restrict a Container's Syscalls with seccomp* — https://kubernetes.io/docs/tutorials/security/seccomp/
- Kubernetes, *Restrict a Container's Access to Resources with AppArmor* — https://kubernetes.io/docs/tutorials/security/apparmor/
- Kubernetes, *Pod Security Standards* — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Kubernetes, *Pod API reference — SecurityContext* — https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/#security-context
- Kubernetes, *kubelet configuration (`seccompDefault`)* — https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
- Linux kernel, *Seccomp BPF (SECure COMPuting with filters)* — https://www.kernel.org/doc/html/latest/userspace-api/seccomp_filter.html
- `seccomp(2)` — https://man7.org/linux/man-pages/man2/seccomp.2.html
- `prctl(2)` (`PR_SET_NO_NEW_PRIVS`) — https://man7.org/linux/man-pages/man2/prctl.2.html
- OCI Runtime Specification, *Linux — Seccomp* — https://github.com/opencontainers/runtime-spec/blob/main/config-linux.md#seccomp
- Moby, perfil seccomp por defecto — https://github.com/moby/moby/blob/master/profiles/seccomp/default.json
- Documentación del proyecto AppArmor y lenguaje de políticas — https://gitlab.com/apparmor/apparmor/-/wikis/Documentation
- `apparmor.d(5)` — https://manpages.ubuntu.com/manpages/noble/man5/apparmor.d.5.html
- Kubernetes SIG Security, *Security Profiles Operator* — https://github.com/kubernetes-sigs/security-profiles-operator

---

<details>
<summary><strong>Respuestas</strong></summary>

### Bloque 1

**Q1.** `CONFIG_SECCOMP` provee el modo *strict* de seccomp (`SECCOMP_MODE_STRICT`: solo `read`, `write`, `_exit`, `sigreturn`); `CONFIG_SECCOMP_FILTER` provee el modo *filter* (`SECCOMP_MODE_FILTER`), el modo programable con cBPF. Kubernetes y todo runtime OCI dependen exclusivamente de `CONFIG_SECCOMP_FILTER` — el modo strict es inutilizable para un contenedor real. En kernels modernos `CONFIG_SECCOMP` está prácticamente siempre activo y el chequeo interesante es `CONFIG_SECCOMP_FILTER=y`.

**Q2.** El kubelet de ese nodo no puede aplicar AppArmor, así que rechaza el Pod en la admisión (razón de estado `AppArmor`, con el mensaje de que AppArmor no está habilitado/soportado en el host). La remediación en un clúster con sistemas operativos mixtos **no** es eliminar el campo: restringe la planificación para que los workloads confinados con AppArmor solo aterricen en nodos con AppArmor (`nodeSelector`/`nodeAffinity` sobre una etiqueta como `security.example.com/lsm=apparmor`), y provee una política SELinux equivalente (`seLinuxOptions`) para los nodos de la familia RHEL. Seccomp, en cambio, es independiente del LSM y portable entre ambos.

**Q3.** Las syscalls **no** se bloquean — `SCMP_ACT_LOG` permite incondicionalmente, ese es todo su propósito, y no se ve afectado por `actions_logged`. Pero **no** vas a ver nada en el log de auditoría, porque `actions_logged` es la allowlist del kernel de qué acciones de retorno de seccomp tienen permiso de emitir registros de auditoría. Así que una corrida en modo auditoría en un nodo así produce la ilusión de un workload limpio mientras recolecta silenciosamente cero evidencia. Por eso es un chequeo previo obligatorio: todo el método de descubrimiento del Bloque 3 depende de él.

### Bloque 2

**Q4.** `0` = `SECCOMP_MODE_DISABLED`, `1` = `SECCOMP_MODE_STRICT`, `2` = `SECCOMP_MODE_FILTER`. En la práctica un contenedor está o en `0` (Unconfined) o en `2` (cualquier perfil — `RuntimeDefault` o `Localhost`). `1` es una curiosidad que no verás desde Kubernetes. Ten en cuenta que `2` te dice que existe un filtro, no *cuál* filtro — combínalo con `Seccomp_filters` (cantidad de filtros apilados) y `crictl inspect` para ver el contenido.

**Q5.** No es coincidencia: `seccomp(2)` con `SECCOMP_SET_MODE_FILTER` **requiere** que quien llama o bien tenga `CAP_SYS_ADMIN` en su propio user namespace, o bien ya haya seteado `PR_SET_NO_NEW_PRIVS` (`prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)`). La regla existe para cerrar un ataque donde un proceso confinado hace `execve` de un binario setuid-root y el filtro hace que ese binario se comporte mal en un contexto privilegiado. Por eso el runtime setea `no_new_privs` antes de instalar el filtro. `CAP_SYS_ADMIN` es la excepción — lo cual también explica por qué `allowPrivilegeEscalation: true` más `CAP_SYS_ADMIN` es una combinación tan potente para buscar durante una auditoría.

**Q6.** `RuntimeDefault` significa "el perfil que el **runtime de contenedores de este nodo** trae como su default" — Kubernetes define la *indirección*, no el *contenido*. El default de containerd vive en el árbol de fuentes de containerd; CRI-O trae el suyo; ambos derivan históricamente del `profiles/seccomp/default.json` de Moby, pero no son idénticos byte a byte y divergen entre versiones. Implicancia: un manifiesto que deba comportarse igual entre runtimes, o que deba ser auditable, tiene que usar `type: Localhost` con un perfil que **tú** versiones y distribuyas. `RuntimeDefault` es la *línea base* correcta en todas partes; no es una *especificación*.

**Q7.** Con `EPERM` como default para syscalls desconocidas, un contenedor compilado contra una glibc más nueva que sondea una syscall nueva (por ejemplo `clone3`, `faccessat2`, `openat2`) ve "permiso denegado" y concluye que la syscall existe pero está prohibida — así que **no** cae al equivalente más viejo y la llamada falla duro. Con `ENOSYS` ve "este kernel no tiene esa syscall", toma su ruta de código heredada y funciona. Esto es exactamente la rotura de `clone3`/glibc 2.34 que golpeó a todas las distros en 2021. Regla: syscalls desconocidas/futuras → `ENOSYS`; syscalls deliberadamente prohibidas → `EPERM`.

### Bloque 3

**Q8.** `localhostProfile` se interpreta **relativo a la raíz de seccomp del kubelet**, que es `<kubelet-root-dir>/seccomp` (por defecto `/var/lib/kubelet/seccomp`). Debe ser una ruta relativa que se mantenga dentro de esa raíz. Una ruta absoluta (`/var/lib/kubelet/...`) o una que contenga `..` es rechazada por la validación de la API con `must be a relative path` / `must not contain '..'` — es una defensa contra path traversal que de otro modo permitiría al autor de un Pod hacer que el kubelet lea archivos arbitrarios del nodo como si fueran un perfil.

**Q9.** La corrida de auditoría solo observa las rutas de código que efectivamente ejercitaste. Enviar exactamente esas 41 syscalls significa que la primera ruta no ejercitada falla en producción, tal vez semanas después, tal vez solo bajo condiciones de fallo. Las dos categorías que casi seguro te perdiste son: **(a) rutas de error y apagado** — manejo de señales, `sigaltstack`, volcado de core, rotación de logs, drenaje ordenado, recolección de panics/backtraces; y **(b) comportamiento de runtime raro pero crítico** — GC o JIT (`mprotect`, `madvise`, `membarrier`), crecimiento del thread pool (`clone`/`clone3`, variantes de `futex`), re-resolución de DNS y re-handshake TLS (`socket`, `getrandom`), rutas de presión de memoria, y todo lo que se dispara solo cuando una dependencia no está alcanzable.

**Q10.** El filtro seccomp se selecciona por el campo `arch` de `struct seccomp_data`. Si el perfil solo lista `SCMP_ARCH_X86_64`, entonces un proceso que hace una syscall en modo compat de 32 bits (`int 0x80` / `SCMP_ARCH_X86`, o la ABI x32) llega con un valor de `arch` distinto y **números** de syscall distintos para los mismos nombres — así que las reglas simplemente no coinciden, y decide el `defaultAction` del filtro. Si el default es permisivo, el atacante obtiene la syscall gratis; si el default es `ERRNO`, obtiene una caída difícil de diagnosticar. Lista siempre `SCMP_ARCH_X86_64`, `SCMP_ARCH_X86` y `SCMP_ARCH_X32` (o el par equivalente `aarch64`/`arm`), que es exactamente lo que hacen los defaults del runtime.

### Bloque 4

**Q11.** *Nunca construyas una política de seccomp como denylist: tendrías que enumerar cada syscall que alcanza la misma funcionalidad del kernel, y libc va a elegir un nombre que no se te ocurrió.* La clase estructuralmente irreparable son las **syscalls multiplexadas / atrapatodo** — `socketcall` e `ipc` en 32 bits, `prctl`, `ioctl`, `fcntl`, `keyctl`, `arch_prctl`, `io_uring_enter` — donde un solo número de syscall alcanza decenas de operaciones distintas seleccionadas por un argumento. Como seccomp solo puede inspeccionar argumentos escalares (y no puede desreferenciar punteros), algunas de esas sub-operaciones son indistinguibles a nivel del filtro. Las denylists no se pueden completar; las allowlists sí.

**Q12.** `/proc/sys/kernel/seccomp/actions_logged`. Cualquier acción listada ahí produce un registro de auditoría cuando se dispara, así que las denegaciones de `SCMP_ACT_ERRNO` se registran igual que las autorizaciones de `SCMP_ACT_LOG`. Es a nivel de nodo porque es un sysctl del kernel que gobierna el subsistema de auditoría de toda la máquina — no hay equivalente por Pod ni por contenedor. Consecuencias prácticas: (a) tienes que configurarlo como parte del aprovisionamiento del nodo, junto con el envío de logs de auditd/journald, o estás ciego; (b) habilitar el registro para acciones de alta frecuencia en un nodo cargado tiene un costo real, así que es un trade-off operativo, no un interruptor gratis.

**Q13.** No. Un filtro seccomp es un programa cBPF cuya única entrada es `struct seccomp_data`: el número de syscall, la arquitectura, el instruction pointer y los seis argumentos de la syscall **como escalares crudos de 64 bits**. El programa corre en un contexto donde no debe desreferenciar punteros de usuario — el argumento de ruta de `openat(2)` es un puntero, así que el filtro no puede leer la cadena, y aun si pudiera, el valor puede ser mutado por otro hilo entre el chequeo y la propia copia del kernel (una condición de carrera TOCTOU). Es una restricción de diseño deliberada, no un descuido. La mediación basada en rutas es tarea de un LSM — AppArmor (basado en rutas) o SELinux (basado en etiquetas).

**Q14.** Despliega `SCMP_ACT_ERRNO` primero. Las denegaciones aparecen como fallos de errno comunes que la aplicación puede registrar, reintentar o degradar, y el contenedor sigue corriendo el tiempo suficiente para que recojas registros de auditoría y los correlaciones con los logs de la aplicación. `SCMP_ACT_KILL_PROCESS` es el mejor *estado final* para un perfil maduro y bien caracterizado: convierte una violación de política en un evento inequívoco e irrecuperable en vez de dejar que un proceso comprometido observe la denegación y se adapte — un atacante que aprende que `bpf(2)` devuelve `EPERM` simplemente prueba la técnica siguiente, mientras que una terminación corta la cadena de explotación y genera una señal ruidosa (`SIGSYS`, un reinicio, una alerta). La progresión `LOG` → `ERRNO` → `KILL_PROCESS` es la escalera estándar de rollout.

### Bloque 5

**Q15.** `seccompDefault: true` es una configuración del **kubelet**: actúa en el momento de crear el contenedor, solo en ese nodo, y *muta* la configuración efectiva sustituyendo por `RuntimeDefault` cuando la spec del Pod no dice nada. PSA `enforce=restricted` es una configuración de **admisión del API server**: actúa en el momento de crear el Pod, a nivel de todo el clúster para ese namespace, y *rechaza* en vez de mutar. Cada uno atrapa algo que el otro no: la configuración del kubelet protege Pods creados antes de que se etiquetara el namespace, Pods en namespaces que nadie etiquetó, y Pods estáticos — pero es invisible en el manifiesto y se evapora si el Pod se mueve a un nodo sin la opción. PSA garantiza que el manifiesto en sí es explícito y auditable en Git, y además bloquea `Unconfined` — cosa que `seccompDefault` no puede, porque un `Unconfined` explícito es exactamente el caso en que el default del kubelet no aplica.

**Q16.** Para **seccomp** bajo `baseline`: `RuntimeDefault`, `Localhost` y *sin definir* son todos aceptados; solo un `Unconfined` explícito se rechaza. (`restricted` además rechaza *sin definir* — el tipo debe ser explícitamente `RuntimeDefault` o `Localhost` en el Pod o en cada contenedor.) Para **AppArmor**: `baseline` acepta `RuntimeDefault`, `Localhost` y sin definir, y rechaza `Unconfined`; `restricted` hereda esa regla sin cambios — no agrega un requisito de "debe estar definido explícitamente" para AppArmor, porque AppArmor no está disponible en el sistema operativo de todos los nodos.

**Q17.**
```bash
kubectl describe pod <pod> | sed -n '/Events:/,$p'                       # 1. is it even the profile?
ssh <node> "sudo journalctl -k --since '-5 min' | grep 'type=1326' | tail"  # 2. which syscall number
ssh <node> "scmp_sys_resolver -a x86_64 <n>"                              # 3. what is its name
```
Remediación ordenada: **(1)** arreglar el workload — la syscall que necesita la JVM suele ser `membarrier`, `perf_event_open`, `sched_setattr` o `clone3`, y la corrección correcta a menudo es un flag de la JVM o una imagen base más nueva; **(2)** adjuntar un perfil `Localhost` *solo a ese workload*, derivado de `RuntimeDefault` más las adiciones específicas, versionado y distribuido por DaemonSet o imagen del nodo; **(3)** definir `seccompProfile: {type: Unconfined}` en ese único contenedor con una fecha de vencimiento y un ticket de seguimiento; **(4)** apagar `seccompDefault` a nivel de todo el clúster — lo que sacrifica la línea base de todos los demás workloads por una sola aplicación y casi nunca es la decisión correcta.

### Bloque 6

**Q18.** En AppArmor, una regla `deny` explícita tiene precedencia sobre cualquier regla de permiso para el mismo acceso, **sin importar el orden en que aparezcan en el perfil**. El parser compila el perfil en un DFA en el que las denegaciones se restan del conjunto permitido, así que reordenar las líneas no cambia nada. Esto es lo que hace seguro escribir el idioma "permiso amplio + denegación quirúrgica", y también significa que un `deny` que heredas de un `#include` no puede volver a permitirse más adelante en tu perfil — tienes que editar o evitar el include.

**Q19.** El confinamiento vive en la **tarea** dentro del kernel: cada proceso tiene una etiqueta de AppArmor que apunta a un perfil cargado (visible en `/proc/<pid>/attr/current`), y el perfil mismo es un objeto del kernel en el espacio de nombres de políticas de AppArmor. `apparmor_parser -r` realiza un *reemplazo* atómico de ese objeto del kernel — mismo nombre, nuevo DFA compilado y nuevo flag de modo — así que cada tarea ya etiquetada con `k8s-deny-write` pasa inmediatamente a ser mediada por la nueva política. Nada cambió respecto del contenedor, del árbol de procesos ni del estado de CRI. Dos consecuencias: puedes endurecer la política sobre una flota en ejecución sin reinicios (excelente), y un `apparmor_parser -r` descuidado puede romper al instante todos los workloads en ejecución ligados a ese perfil (peligroso — por eso importan el modo complain y el despliegue escalonado).

**Q20.** **seccomp:** `localhostProfile` es una **ruta relativa del sistema de archivos** bajo la raíz de seccomp del kubelet, por ejemplo `profiles/audit.json` → `/var/lib/kubelet/seccomp/profiles/audit.json`. Es un archivo que el runtime lee y compila en un filtro BPF. **AppArmor:** `localhostProfile` es el **nombre del perfil** tal como está cargado en el kernel, por ejemplo `k8s-deny-write` — sin ruta, sin `.json`, y crucialmente **sin el prefijo `localhost/`** (ese prefijo pertenecía a la forma obsoleta con anotación). La diferencia es arquitectónica: un perfil de seccomp es dato que el runtime consume por contenedor, mientras que un perfil de AppArmor es estado del kernel que ya debe existir en el nodo y se referencia por nombre.

**Q21.** `attach_disconnected` le dice a AppArmor cómo nombrar un objeto de archivo cuya ruta no puede resolverse de vuelta a la vista que el perfil tiene de la raíz del sistema de archivos — una ruta "desconectada". En un contenedor, el mount namespace, `pivot_root`, los bind mounts, las capas de overlayfs y los archivos borrados pero abiertos producen rutinariamente objetos cuya ruta el kernel no puede reconstruir del todo. Sin el flag, esos accesos se deniegan y se registran con un `name=` pelado que no te da nada contra qué escribir una regla; con él, AppArmor adjunta la ruta desconectada a la raíz del perfil y la media normalmente. Es específicamente un problema de contenedores porque los procesos no contenidos casi siempre viven en el mount namespace inicial, donde toda ruta se resuelve limpiamente.

### Bloque 7

**Q22.** **AppArmor** falla en la **admisión del kubelet**, *antes* de que se contacte al runtime: el kubelet lee `/sys/kernel/security/apparmor/profiles` en su propio nodo, no encuentra el nombre y rechaza el Pod con la razón `AppArmor` y el mensaje `Cannot enforce AppArmor: profile "X" is not loaded`. **seccomp** falla **más tarde**, dentro del runtime de contenedores, cuando intenta abrir el archivo del perfil para construir la spec OCI — el error viene de containerd/CRI-O y aparece como un evento `Failed` con `cannot load seccomp profile ...: no such file or directory`. La lección: el kubelet pre-valida AppArmor (porque puede enumerar la política del kernel de forma barata) pero **no** pre-valida la existencia del archivo de seccomp, así que un perfil de seccomp faltante te cuesta un viaje de ida y vuelta de planificación y un error del runtime en lugar de un fallo limpio de admisión — revisa el sistema de archivos del nodo, no solo `kubectl describe`.

**Q23.** Acceso de escritura al ConfigMap significa que el atacante elige el *contenido* de la política que un DaemonSet privilegiado carga en el kernel del host. Puede (a) reemplazar un perfil estricto por uno permisivo — incluso redefinir un perfil del que dependen otros Pods no relacionados, dejándolos silenciosamente sin confinar en la próxima reconciliación; o (b) cargar un perfil que otorgue `capability sys_admin`, `mount`, `ptrace` y `/** rwklx` bajo un nombre que ya referencia un workload que él controla. Combinado, eso es compromiso del nodo mediante un permiso de escritura con alcance de namespace. Mitigaciones: **(1)** no correr ningún loader de perfiles — hornea los perfiles en la imagen del nodo o distribúyelos con tu herramienta de gestión de configuración, de modo que el contenido de la política quede gobernado por el mismo circuito de revisión que el sistema operativo; **(2)** si tienes que hacerlo, aísla el loader en un namespace dedicado cuyos ConfigMaps solo puedan escribir los cluster-admin, restríngelo con una política de admisión (ValidatingAdmissionPolicy/OPA) que fije los nombres de perfil permitidos, y audita el verbo `update` sobre ese ConfigMap. Un tercer control complementario: ejecutar el loader desde una fuente inmutable (una imagen firmada que contenga los perfiles) en lugar de desde un ConfigMap mutable.

**Q24.** El Pod es **rechazado en la admisión** por Pod Security Admission con un mensaje de la forma `violates PodSecurity "baseline:latest": appArmorProfile (container "X" must not set securityContext.appArmorProfile.type to "Unconfined")`. A `baseline` le importa —en vez de dejárselo a `restricted`— porque en distribuciones que soportan AppArmor el runtime aplica su perfil por defecto automáticamente, y ese default es parte de lo que significa "un contenedor común, no exótico". Poner `Unconfined` es una *renuncia explícita a una protección que de otro modo habrías tenido gratis*, que es precisamente la categoría que `baseline` existe para prohibir: no exige endurecimiento extra, prohíbe quitar el endurecimiento que ya es el default.

### Bloque 8

**Q25.**

| Objetivo de control | seccomp | AppArmor | capabilities |
|---|---|---|---|
| Bloquear `chmod` sobre **cualquier** archivo | **Sí** (denegar `chmod`/`fchmod`/`fchmodat`/`fchmodat2`) | Parcialmente — vía la semántica de `deny <path> w`, pero AppArmor media los cambios de permisos de archivo por ruta, no la syscall como tal | No |
| Bloquear escrituras **solo a `/etc/shadow`** | **No** — no puede desreferenciar el puntero de la ruta | **Sí** — `deny /etc/shadow rwklx,` | No (quitar `CAP_DAC_OVERRIDE` solo ayuda para accesos de quien no es el dueño) |
| Bloquear `mount(2)` por completo | **Sí** | Sí (`deny mount,`) | Mayormente — quitar `CAP_SYS_ADMIN` |
| Bloquear sockets raw | Sí (denegar `socket` con `SOCK_RAW`, un chequeo de argumento) | Sí (`deny network raw,`) | **Sí y es lo más simple** — quitar `CAP_NET_RAW` |
| Bloquear `bpf(2)` / `perf_event_open(2)` | **Sí y es lo más simple** | Parcialmente (`deny capability bpf,`) | Parcialmente — `CAP_BPF`/`CAP_PERFMON`, pero root dentro del contenedor puede conservar caminos |
| Bloquear la lectura del archivo de token de la ServiceAccount | **No** — es ciego a las rutas | **Sí** — `deny /var/run/secrets/kubernetes.io/serviceaccount/** rwklx,` | No |

Donde funcionan dos: prefiere **capabilities** para privilegios gruesos y bien nombrados (`CAP_NET_RAW`, `CAP_SYS_ADMIN`) porque son portables, declarativos y revisables en el manifiesto; prefiere **seccomp** para controles con forma de syscall que ninguna capability nombra (`bpf`, `perf_event_open`, `keyctl`, `userfaultfd`) porque es independiente del LSM y funciona en el sistema operativo de cualquier nodo; prefiere **AppArmor** dondequiera que la respuesta dependa de *qué objeto* se está tocando, porque es el único de los tres que puede ver el objeto.

**Q26.** seccomp media la **interfaz de syscalls** — ve el número de syscall, la arquitectura y los argumentos escalares, y nada más — mientras que AppArmor media los **objetos** sobre los que actúan esas syscalls — archivos por ruta, capabilities, familias de direcciones de red, montajes, señales, objetivos de ptrace — y nunca ve el número de syscall. Ninguno puede expresar lo que expresa el otro, así que la postura correcta es ambos más un drop de capabilities, no elegir entre ellos.

**Q27.** **(1) Huecos de cobertura** — una hora de "carga normal" no ejercita el manejo de errores, el apagado, la rotación de logs, la renovación de certificados TLS, las rutas de fallo de dependencias, la compactación del GC bajo presión de memoria, ni el código anual de segundo intercalar/horario de verano; cualquiera de esos puede necesitar una syscall que nunca apareció. **(2) Puntos ciegos del grabador y sobreajuste** — un grabador BPF observa lo que se ejecutó, así que captura las syscalls de las versiones *específicas* de bibliotecas, kernel y hardware presentes durante la grabación; un salto de imagen base, un cambio de glibc, una característica de CPU distinta o una actualización de kernel pueden mover `clone` → `clone3`, `access` → `faccessat2`, o introducir `membarrier`, y ahora el perfil bloquea el arranque. **(3) Grabar una línea base comprometida o mal configurada** — el perfil codifica lo que el workload *hizo*, no lo que *debería* hacer; si el Pod grabado ya estaba haciendo algo indeseable (o ya estaba comprometido), la grabación lo permite fielmente para siempre. El uso correcto de una grabación es como *borrador* que un humano compara contra `RuntimeDefault` y luego despliega pasando por `SCMP_ACT_LOG` → `SCMP_ACT_ERRNO` en un entorno de staging antes de producción.

</details>