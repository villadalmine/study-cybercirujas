# CKS 5.4 — Kernel hardening tools: AppArmor y seccomp

**Peso en el examen:** 2.5%
**Fuente de referencia:** [CKS Curriculum v1.34 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf)

AppArmor y seccomp son mecanismos de *kernel hardening* de Linux que Kubernetes puede orquestar por Pod/contenedor. Seccomp filtra qué **syscalls** puede invocar un proceso; AppArmor es un Mandatory Access Control (MAC) que restringe qué **recursos** (archivos, red, capabilities) puede tocar un binario específico, más allá de los permisos Unix normales. Ambos reducen el impacto de un container breakout aunque un atacante ya haya conseguido ejecución de código dentro del contenedor.

**Requisitos previos:** cluster kubeadm con acceso SSH a al menos un worker node, container runtime containerd o CRI-O, y AppArmor habilitado en el kernel del nodo (viene por default en Ubuntu/Debian; en RHEL/Fedora se usa SELinux en su lugar y estos ejercicios de AppArmor no aplican).

---

## Ejercicio 1 — Aplicar el seccomp profile `RuntimeDefault`

Si no se especifica nada, un contenedor corre con seccomp en modo `Unconfined` (sin filtro). `RuntimeDefault` activa el filtro que trae el container runtime, que ya bloquea decenas de syscalls peligrosas.

1. Creá un namespace de trabajo:
   ```
   kubectl create namespace kernel-hardening
   ```

2. Lanzá un Pod sin seccomp profile explícito y confirmá que corre `Unconfined`:
   ```
   kubectl run unconfined --image=nginx -n kernel-hardening --restart=Never
   kubectl exec unconfined -n kernel-hardening -- cat /proc/1/status | grep Seccomp
   ```
   El campo `Seccomp` en `0` indica que no hay filtro activo.

3. Creá el archivo `runtime-default-pod.yaml`:
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: runtime-default
     namespace: kernel-hardening
   spec:
     securityContext:
       seccompProfile:
         type: RuntimeDefault
     containers:
     - name: nginx
       image: nginx
   ```

4. Aplicalo y confirmá el cambio de modo:
   ```
   kubectl apply -f runtime-default-pod.yaml
   kubectl exec runtime-default -n kernel-hardening -- cat /proc/1/status | grep Seccomp
   ```
   Ahora el valor debe ser `2` (`SECCOMP_MODE_FILTER`).

**Preguntas de comprensión:**
1. ¿Por qué el valor por default de `seccompProfile` en Kubernetes es `Unconfined` y no `RuntimeDefault`?
2. ¿Qué diferencia hay entre setear `seccompProfile` en `spec.securityContext` (nivel Pod) y en `spec.containers[].securityContext` (nivel contenedor)?

---

## Ejercicio 2 — Crear y aplicar un seccomp profile personalizado (`Localhost`)

Cuando `RuntimeDefault` no alcanza, se usa un profile JSON propio, tipo `Localhost`, guardado en el filesystem del nodo.

5. Conectate al worker node y creá el directorio de profiles de seccomp de kubelet:
   ```
   ssh worker-node
   sudo mkdir -p /var/lib/kubelet/seccomp/profiles
   ```

6. Creá `deny-unshare.json`, bloqueando la syscall `unshare` (usada para crear nuevos namespaces) y permitiendo el resto:
   ```
   sudo tee /var/lib/kubelet/seccomp/profiles/deny-unshare.json <<'EOF'
   {
     "defaultAction": "SCMP_ACT_ALLOW",
     "syscalls": [
       {
         "names": ["unshare"],
         "action": "SCMP_ACT_ERRNO"
       }
     ]
   }
   EOF
   ```

7. Desde el control plane, creá `custom-seccomp-pod.yaml` referenciando el profile con `type: Localhost`:
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: custom-seccomp
     namespace: kernel-hardening
   spec:
     nodeName: worker-node
     securityContext:
       seccompProfile:
         type: Localhost
         localhostProfile: profiles/deny-unshare.json
     containers:
     - name: nginx
       image: nginx
   ```

8. Aplicalo y verificá que la syscall bloqueada falla:
   ```
   kubectl apply -f custom-seccomp-pod.yaml
   kubectl exec custom-seccomp -n kernel-hardening -- unshare --map-root-user echo hola
   ```
   Debería fallar con `Operation not permitted`.

**Preguntas de comprensión:**
3. ¿Por qué el Pod del paso 7 necesita `nodeName` fijo (o un mecanismo equivalente de scheduling)?
4. ¿Qué acción de seccomp usarías (`SCMP_ACT_ERRNO` vs `SCMP_ACT_KILL_PROCESS`) si además de bloquear la syscall quisieras que el proceso completo termine al intentarla?

---

## Ejercicio 3 — Habilitar y cargar un profile de AppArmor en el nodo

El profile de AppArmor vive y se carga en el kernel del nodo con `apparmor_parser`, no vía la API de Kubernetes.

9. En el worker node, confirmá que AppArmor está activo:
   ```
   ssh worker-node
   sudo aa-status
   ```
   Alternativa si `aa-status` no está instalado:
   ```
   cat /sys/module/apparmor/parameters/enabled
   ```

10. Creá el profile `/etc/apparmor.d/deny-write`, que deniega escritura en cualquier archivo:
    ```
    sudo tee /etc/apparmor.d/deny-write <<'EOF'
    #include <tunables/global>

    profile deny-write flags=(attach_disconnected) {
      #include <abstractions/base>

      file,
      deny /** w,
    }
    EOF
    ```

11. Cargalo en el kernel:
    ```
    sudo apparmor_parser -q /etc/apparmor.d/deny-write
    sudo aa-status | grep deny-write
    ```

**Preguntas de comprensión:**
5. ¿Por qué el profile de AppArmor se carga en cada nodo por separado en lugar de distribuirse vía un objeto de la API de Kubernetes?
6. Si programás un Pod que referencia este profile en un nodo donde `deny-write` todavía no fue cargado con `apparmor_parser`, ¿qué esperás que pase?

---

## Ejercicio 4 — Aplicar el profile de AppArmor a un Pod

12. Creá `apparmor-pod.yaml`. Desde Kubernetes v1.30 el campo estable es `securityContext.appArmorProfile` por contenedor (la annotation beta `container.apparmor.security.beta.kubernetes.io/<container>` está deprecada):
    ```yaml
    apiVersion: v1
    kind: Pod
    metadata:
      name: apparmor-demo
      namespace: kernel-hardening
    spec:
      nodeName: worker-node
      containers:
      - name: nginx
        image: nginx
        securityContext:
          appArmorProfile:
            type: Localhost
            localhostProfile: deny-write
    ```

13. Aplicalo y confirmá que el profile quedó asociado al proceso:
    ```
    kubectl apply -f apparmor-pod.yaml
    kubectl exec apparmor-demo -n kernel-hardening -- cat /proc/1/attr/current
    ```

14. Intentá escribir un archivo dentro del contenedor:
    ```
    kubectl exec apparmor-demo -n kernel-hardening -- touch /tmp/test
    ```
    Debería fallar con `Permission denied`, aunque el usuario dentro del contenedor tenga permisos Unix de sobra.

**Preguntas de comprensión:**
7. ¿Qué esperás que pase con el Pod (a nivel de estado, no del comando) si `localhostProfile` apunta a un nombre de profile que no existe en el nodo?
8. ¿Cómo describirías en una frase la diferencia entre lo que bloquea seccomp y lo que bloquea AppArmor?

---

## Ejercicio 5 — Modo `complain` y auditoría antes de `enforce`

En producción conviene correr un profile nuevo en modo `complain` (audita pero no bloquea) antes de pasarlo a `enforce`.

15. Poné el profile en modo complain:
    ```
    sudo aa-complain /etc/apparmor.d/deny-write
    sudo aa-status | grep -A2 complain
    ```

16. Repetí la escritura del paso 14 (ahora debería tener éxito) y revisá que quedó auditada:
    ```
    kubectl exec apparmor-demo -n kernel-hardening -- touch /tmp/test
    sudo dmesg | grep -i apparmor | tail -5
    ```
    Vas a ver una línea con `apparmor="ALLOWED"` para la operación de escritura, en lugar de `DENIED`.

17. Volvé el profile a modo enforce:
    ```
    sudo aa-enforce /etc/apparmor.d/deny-write
    ```

**Preguntas de comprensión:**
9. ¿Qué ventaja concreta da correr un profile en `complain` antes de pasarlo a `enforce` en un cluster productivo?
10. ¿Cómo identificarías en `dmesg`/`journalctl` si un evento de AppArmor corresponde a un bloqueo real en modo `enforce`?

---

## Respuestas

<details>
<summary>Ver respuestas</summary>

1. Porque cambiar el default a `RuntimeDefault` rompería compatibilidad hacia atrás: muchas imágenes existentes podrían necesitar syscalls que el filtro del runtime bloquea. Kubernetes deja `Unconfined` como default y hace del hardening un opt-in explícito por Pod.

2. El valor a nivel Pod (`spec.securityContext.seccompProfile`) establece el default para todos los contenedores del Pod. El valor a nivel contenedor (`spec.containers[].securityContext.seccompProfile`) lo sobreescribe solo para ese contenedor, permitiendo mezclar niveles de restricción distintos dentro del mismo Pod (por ejemplo, un init container más permisivo y el contenedor principal más restringido).

3. Porque un profile `Localhost` es un archivo en el filesystem del nodo (`/var/lib/kubelet/seccomp/profiles/...`), no un objeto de la API. Si el Pod es scheduleado en un nodo donde ese archivo no existe, kubelet no puede resolver el profile y el contenedor falla al crearse. En un escenario real esto se resuelve distribuyendo el archivo a todos los nodos candidatos (por ejemplo con un DaemonSet o herramienta de configuration management) en vez de fijar `nodeName`.

4. `SCMP_ACT_KILL_PROCESS` termina el proceso completo inmediatamente al invocar la syscall prohibida. `SCMP_ACT_ERRNO` en cambio devuelve un error a la llamada (como si la syscall hubiera fallado) y el proceso sigue corriendo, pudiendo manejar el error o no.

5. Porque AppArmor es un LSM (Linux Security Module) que opera a nivel de kernel de cada nodo individualmente; Kubernetes no tiene un objeto de la API que represente ni distribuya el contenido del profile (a diferencia de, por ejemplo, un ConfigMap). El Pod solo referencia el *nombre* de un profile que se asume ya cargado en el nodo vía `apparmor_parser`, típicamente provisto durante el bootstrap del nodo o con un DaemonSet.

6. El contenedor no llega a crearse: kubelet reporta un error (Pod queda en estado `Blocked` o con un evento de tipo `CreateContainerError`/`CreateContainerConfigError` indicando que el profile de AppArmor no fue encontrado en el nodo).

7. Igual que en la pregunta anterior: el contenedor falla al crearse y el Pod queda en un estado de error (`CreateContainerError` o similar), con un evento describiendo que el profile de AppArmor referenciado no existe en el nodo.

8. Seccomp filtra *qué syscalls* (funciones del kernel) puede invocar un proceso; AppArmor restringe *qué recursos* (rutas de archivos, operaciones de red, capabilities) puede usar un binario específico, independientemente de los permisos Unix que tenga.

9. Permite validar la política contra el comportamiento real de la carga de trabajo sin riesgo de romper producción: cualquier acceso legítimo que la regla bloquearía en `enforce` queda registrado como `ALLOWED` en modo `complain`, dando la oportunidad de ajustar el profile antes de aplicarlo en modo estricto.

10. Buscando líneas de `dmesg`/`journalctl` con `apparmor="DENIED"` (en contraste con `apparmor="ALLOWED"`, que corresponde a modo complain), incluyendo el nombre del profile, la operación y el path/recurso involucrados.

</details>