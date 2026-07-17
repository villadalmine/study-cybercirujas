# CKA 1.35 — Tema 5.6: Understand and use CoreDNS (peso 3.34%)

> Fuente de referencia: [CKA Curriculum v1.35 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf)

Los siguientes ejercicios asumen un cluster funcional (kubeadm, kind o similar) con acceso `kubectl` como admin.

---

## Ejercicio 1: Explorar el Deployment y el Service de CoreDNS

1. Listá los pods de CoreDNS en `kube-system`:
   ```bash
   kubectl get pods -n kube-system -l k8s-app=kube-dns
   ```
2. Inspeccioná el Deployment:
   ```bash
   kubectl get deployment coredns -n kube-system -o wide
   ```
3. Revisá el Service que expone CoreDNS al resto del cluster:
   ```bash
   kubectl get svc kube-dns -n kube-system
   kubectl describe svc kube-dns -n kube-system
   ```
4. Confirmá qué IP de ese Service usan los pods como resolver, mirando el `ClusterDNS` configurado en el kubelet:
   ```bash
   ps aux | grep kubelet | grep -o -- '--cluster-dns=[^ ]*'
   ```
   (si no tenés acceso al nodo, alcanza con saber que ese valor coincide con el ClusterIP del Service).

**Preguntas de comprensión:**
- ¿Por qué el Service se llama `kube-dns` aunque el backend sea CoreDNS?
- ¿Qué pasaría si el ClusterIP de este Service cambiara sin actualizar la config del kubelet?

---

## Ejercicio 2: Leer el Corefile

1. Mostrá el ConfigMap que contiene la configuración de CoreDNS:
   ```bash
   kubectl get configmap coredns -n kube-system -o yaml
   ```
2. Identificá, dentro del bloque `Corefile:`, cada plugin listado (típicamente `errors`, `health`, `ready`, `kubernetes`, `prometheus`, `forward`, `cache`, `loop`, `reload`, `loadbalance`) y anotá en una línea qué hace cada uno.
3. Verificá que el ConfigMap está montado como volumen en el Deployment:
   ```bash
   kubectl get deployment coredns -n kube-system -o jsonpath='{.spec.template.spec.volumes}'
   ```

**Preguntas de comprensión:**
- ¿Qué plugin resuelve específicamente los nombres `*.svc.cluster.local` contra la API de Kubernetes?
- ¿Hacia dónde reenvía las consultas que no son del dominio del cluster el plugin `forward .`?
- ¿Qué detecta el plugin `loop` y por qué el pod entraría en `CrashLoopBackOff` si lo detecta?

---

## Ejercicio 3: Resolución DNS desde un pod

1. Creá un namespace de prueba y un Deployment con Service:
   ```bash
   kubectl create namespace dns-lab
   kubectl create deployment web --image=nginx -n dns-lab
   kubectl expose deployment web --port=80 -n dns-lab
   ```
2. Lanzá un pod de utilidades de red:
   ```bash
   kubectl run dnsutils --image=registry.k8s.io/e2e-test-images/jessie-dnsutils:1.7 \
     -n dns-lab --command -- sleep 3600
   ```
3. Resolvé el Service por su nombre corto y por su FQDN completo:
   ```bash
   kubectl exec -it dnsutils -n dns-lab -- nslookup web
   kubectl exec -it dnsutils -n dns-lab -- nslookup web.dns-lab.svc.cluster.local
   ```
4. Resolvé el Service `kubernetes` del namespace `default`:
   ```bash
   kubectl exec -it dnsutils -n dns-lab -- nslookup kubernetes.default
   ```
5. Mostrá la configuración de resolver que recibió el pod:
   ```bash
   kubectl exec -it dnsutils -n dns-lab -- cat /etc/resolv.conf
   ```

**Preguntas de comprensión:**
- ¿Por qué `nslookup web` (sin sufijos) funciona desde un pod del mismo namespace `dns-lab` pero no funcionaría igual desde un pod en `default`?
- ¿Qué rol cumple la opción `ndots` que ves en `/etc/resolv.conf`, y cómo afecta el número de consultas DNS que se disparan por cada resolución?

---

## Ejercicio 4: Services headless y registros SRV

1. Creá un Service headless (sin ClusterIP) apuntando al mismo Deployment `web`:
   ```yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: web-headless
     namespace: dns-lab
   spec:
     clusterIP: None
     selector:
       app: web
     ports:
       - port: 80
         name: http
   ```
   ```bash
   kubectl apply -f web-headless.yaml
   ```
2. Resolvé el Service headless y observá cuántos registros A devuelve:
   ```bash
   kubectl exec -it dnsutils -n dns-lab -- nslookup web-headless.dns-lab.svc.cluster.local
   ```
3. Consultá el registro SRV asociado al puerto nombrado:
   ```bash
   kubectl exec -it dnsutils -n dns-lab -- dig SRV _http._tcp.web-headless.dns-lab.svc.cluster.local
   ```

**Preguntas de comprensión:**
- ¿Qué diferencia hay entre lo que devuelve `nslookup` para un Service normal (ClusterIP) y para uno headless?
- ¿Por qué un StatefulSet suele usar un Service headless para el descubrimiento de sus pares?

---

## Ejercicio 5: dnsPolicy y dnsConfig personalizado

1. Creá un pod con `dnsPolicy: Default` (usa el resolver del nodo) y compará su `/etc/resolv.conf` contra el del `dnsutils` anterior:
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: dns-default-policy
     namespace: dns-lab
   spec:
     dnsPolicy: Default
     containers:
       - name: shell
         image: busybox
         command: ["sleep", "3600"]
   ```
2. Creá un pod con `dnsPolicy: None` y un `dnsConfig` explícito:
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: dns-custom-config
     namespace: dns-lab
   spec:
     dnsPolicy: None
     dnsConfig:
       nameservers:
         - 8.8.8.8
       searches:
         - dns-lab.svc.cluster.local
       options:
         - name: ndots
           value: "2"
     containers:
       - name: shell
         image: busybox
         command: ["sleep", "3600"]
   ```
3. Comparalos:
   ```bash
   kubectl exec -it dns-default-policy -n dns-lab -- cat /etc/resolv.conf
   kubectl exec -it dns-custom-config -n dns-lab -- cat /etc/resolv.conf
   ```

**Preguntas de comprensión:**
- Con `dnsPolicy: None`, ¿de dónde sale el contenido de `/etc/resolv.conf` del pod?
- ¿En qué escenario usarías `dnsPolicy: None` con `dnsConfig` en vez de dejar el valor por defecto (`ClusterFirst`)?

---

## Ejercicio 6: Extender CoreDNS con un stub domain

1. Editá el ConfigMap de CoreDNS para agregar un bloque de servidor adicional que reenvíe un dominio interno a un servidor DNS externo:
   ```bash
   kubectl edit configmap coredns -n kube-system
   ```
   Agregá, al final del `Corefile`, un bloque como:
   ```
   internal.example.com:53 {
       errors
       cache 30
       forward . 192.168.1.1
   }
   ```
2. Verificá que CoreDNS detectó el cambio (el plugin `reload` lo aplica automáticamente cada ~30s + jitter):
   ```bash
   kubectl logs -n kube-system -l k8s-app=kube-dns | grep -i reload
   ```
3. Si el cambio no se refleja, forzá un reinicio de los pods:
   ```bash
   kubectl rollout restart deployment coredns -n kube-system
   kubectl rollout status deployment coredns -n kube-system
   ```
4. Probá la resolución del nuevo dominio desde el pod `dnsutils`:
   ```bash
   kubectl exec -it dnsutils -n dns-lab -- nslookup host.internal.example.com
   ```

**Preguntas de comprensión:**
- ¿Por qué normalmente no hace falta reiniciar los pods de CoreDNS después de editar el ConfigMap?
- ¿Qué diferencia hay entre agregar un bloque de servidor nuevo (como en este ejercicio) y modificar el `forward .` del bloque principal?

---

## Ejercicio 7: Troubleshooting de CoreDNS

1. Simulá una falla escalando CoreDNS a 0 réplicas y observá el impacto:
   ```bash
   kubectl scale deployment coredns -n kube-system --replicas=0
   kubectl exec -it dnsutils -n dns-lab -- nslookup web.dns-lab.svc.cluster.local
   ```
2. Restaurá el servicio:
   ```bash
   kubectl scale deployment coredns -n kube-system --replicas=2
   kubectl rollout status deployment coredns -n kube-system
   ```
3. Revisá logs y eventos ante fallas reales:
   ```bash
   kubectl logs -n kube-system -l k8s-app=kube-dns --tail=50
   kubectl get events -n kube-system --sort-by='.lastTimestamp'
   ```
4. Verificá los endpoints del Service `kube-dns` para confirmar que los pods están registrados:
   ```bash
   kubectl get endpoints kube-dns -n kube-system
   ```

**Preguntas de comprensión:**
- Si `nslookup` desde un pod da timeout total, ¿qué dos verificaciones harías primero (endpoints del Service y estado de los pods) antes de mirar el Corefile?
- ¿Qué mensaje de log esperarías ver si el plugin `loop` detecta un bucle de reenvío hacia el propio CoreDNS?

---

<details>
<summary><strong>Ver respuestas</strong></summary>

**Ejercicio 1**
- El Service se llama `kube-dns` por compatibilidad histórica: antes de CoreDNS, Kubernetes usaba kube-dns (basado en dnsmasq/skydns), y el nombre del Service se mantuvo para no romper el flag `--cluster-dns` del kubelet ni el `/etc/resolv.conf` que ya apuntaba a ese nombre/IP.
- Si el ClusterIP cambiara sin actualizar el kubelet, todos los pods nuevos (y los existentes que ya montaron su `resolv.conf`) dejarían de poder resolver DNS interno, ya que `--cluster-dns` queda desincronizado del Service real.

**Ejercicio 2**
- `errors`: loguea errores a stdout. `health`/`ready`: exponen endpoints de healthcheck/readiness para el propio pod de CoreDNS. `kubernetes`: implementa la resolución de Services/Pods del cluster vía la API. `prometheus`: expone métricas. `forward .`: reenvía todo lo que no matchea el dominio del cluster (por defecto, al `/etc/resolv.conf` del nodo). `cache`: cachea respuestas. `loop`: detecta bucles de reenvío. `reload`: recarga el Corefile automáticamente al detectar cambios en el ConfigMap. `loadbalance`: hace round-robin de registros A/AAAA.
- El plugin `kubernetes` resuelve `*.svc.cluster.local` (y pods) contra la API.
- El plugin `forward .` reenvía hacia el resolver configurado en el nodo (normalmente el `/etc/resolv.conf` del host).
- El plugin `loop` detecta cuando una consulta reenviada termina volviendo al propio CoreDNS (bucle infinito), típicamente porque el `resolv.conf` del nodo apunta, directa o indirectamente, al Service `kube-dns`. Si lo detecta, el proceso hace `CrashLoopBackOff` para evitar consumir CPU/red en un loop.

**Ejercicio 3**
- Porque el `search` domain agregado en `/etc/resolv.conf` del pod incluye `dns-lab.svc.cluster.local` (y los niveles superiores), así que `web` se expande automáticamente a `web.dns-lab.svc.cluster.local`. Desde `default`, ese mismo nombre corto se expandiría a `web.default.svc.cluster.local`, que no existe.
- `ndots` define cuántos puntos debe tener un nombre para tratarlo como FQDN absoluto (no probar los `search` domains primero). Con `ndots:5` (valor por defecto en pods), casi cualquier nombre con menos de 5 puntos dispara primero una ronda de intentos contra cada `search` domain antes de probarlo como nombre absoluto, multiplicando las consultas DNS salientes.

**Ejercicio 4**
- Con un Service ClusterIP normal, `nslookup` devuelve una única IP (la ClusterIP virtual). Con un Service headless, devuelve una IP por cada pod backend (los A records de los pods directamente), sin IP virtual intermedia.
- Un StatefulSet usa Service headless para que cada pod tenga una identidad de red estable y resoluble individualmente (`pod-0.service.ns.svc.cluster.local`), necesario para que los réplicas se descubran entre sí por nombre en vez de depender de un balanceo transparente.

**Ejercicio 5**
- Ese `/etc/resolv.conf` sale enteramente de lo que se definió en `dnsConfig` (nameservers, searches, options); no se combina con el DNS del cluster salvo que también lo incluyas explícitamente en `nameservers`/`searches`.
- Se usa quiere un pod que necesite resolver únicamente contra un DNS externo específico (por ejemplo, para integrarse con un dominio corporativo fuera del cluster) sin heredar ni mezclar el comportamiento de `ClusterFirst`.

**Ejercicio 6**
- Porque el plugin `reload` vigila el archivo Corefile montado (que cambia cuando el ConfigMap se actualiza, vía symlink atómico de kubelet) y lo recarga automáticamente cada ~30 segundos más jitter, sin necesidad de reiniciar el pod.
- Modificar el `forward .` del bloque principal cambia el comportamiento para *todo* el tráfico que no sea `cluster.local` (afecta resolución externa global). Agregar un bloque de servidor nuevo (`internal.example.com:53 { ... }`) solo intercepta consultas para ese dominio específico, dejando el resto del comportamiento intacto.

**Ejercicio 7**
- Primero: `kubectl get endpoints kube-dns -n kube-system` (si está vacío, no hay pods de CoreDNS backend disponibles) y `kubectl get pods -n kube-system -l k8s-app=kube-dns` (para ver si están `Running`/`Ready` o en `CrashLoopBackOff`/`Pending`). Recién después tendría sentido revisar el contenido del Corefile.
- Un log típico sería algo como `Loop (127.0.0.1:XXXXX -> :53) detected for zone ".", see https://coredns.io/plugins/loop#troubleshooting...`, seguido del proceso terminando y el pod reiniciando.

</details>