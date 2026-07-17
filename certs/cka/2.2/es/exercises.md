# 2.2 Troubleshoot cluster components

> Referencia curricular: [CKA Curriculum v1.35 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf). Este material es contenido original elaborado a partir de esa referencia; no reproduce texto de la fuente.

Estos ejercicios asumen un cluster `kubeadm` de al menos un control plane node y un worker node, con acceso `ssh` a ambos y `kubectl` configurado con permisos de administrador (`cluster-admin`). Ejecutá cada bloque en orden: cada uno depende del estado dejado por el anterior.

---

## Ejercicio 1 — Diagnóstico de un node en estado `NotReady` (kubelet)

1. Verificá el estado de los nodes:
   ```
   kubectl get nodes -o wide
   ```
2. Elegí un worker node y conectate por `ssh`. Revisá si el proceso del `kubelet` está corriendo:
   ```
   systemctl status kubelet
   ```
3. Si está `inactive` o en `failed`, inspeccioná las últimas líneas de log del servicio:
   ```
   journalctl -u kubelet -n 100 --no-pager
   ```
4. Buscá el archivo de configuración del `kubelet` que carga `systemd` y confirmá que el `kubeconfig` que usa existe y apunta al `kube-apiserver` correcto:
   ```
   cat /var/lib/kubelet/config.yaml
   cat /etc/kubernetes/kubelet.conf
   ```
5. Simulá una causa común de falla: renombrá temporalmente el `kubeconfig` del kubelet y reiniciá el servicio:
   ```
   sudo mv /etc/kubernetes/kubelet.conf /etc/kubernetes/kubelet.conf.bak
   sudo systemctl restart kubelet
   journalctl -u kubelet -n 20 --no-pager
   ```
6. Restaurá el archivo y confirmá que el `kubelet` vuelve a un estado sano:
   ```
   sudo mv /etc/kubernetes/kubelet.conf.bak /etc/kubernetes/kubelet.conf
   sudo systemctl restart kubelet
   systemctl status kubelet
   ```
7. Desde una terminal con acceso al `kube-apiserver`, confirmá que el node volvió a `Ready`:
   ```
   kubectl get node <nombre-del-node> -w
   ```

**Preguntas de comprensión**

- ¿Por qué un `kubelet` sin `kubeconfig` válido puede seguir corriendo como proceso pero el node nunca pasa a `Ready`?
- Además de journalctl, ¿qué otro archivo revisarías si sospechás que el problema es de espacio en disco o de `PID` del node (condiciones que afectan el node status)?

---

## Ejercicio 2 — Fallas del control plane administrado como static pods

1. Conectate por `ssh` al control plane node y listá los manifiestos de static pods:
   ```
   ls -l /etc/kubernetes/manifests/
   ```
2. Confirmá que `kubelet` está vigilando ese directorio como fuente de static pods:
   ```
   grep -A2 staticPodPath /var/lib/kubelet/config.yaml
   ```
3. Desde `kubectl`, listá los pods del control plane en el namespace `kube-system`:
   ```
   kubectl get pods -n kube-system -o wide | grep -E "kube-apiserver|kube-scheduler|kube-controller-manager|etcd"
   ```
4. Provocá una falla controlada: editá el manifiesto del `kube-scheduler` e introducí un flag inválido, por ejemplo agregando `- --this-flag-no-existe=true` a la lista de `command`:
   ```
   sudo vi /etc/kubernetes/manifests/kube-scheduler.yaml
   ```
5. Esperá unos segundos y observá cómo `kubelet` recrea el static pod fallido:
   ```
   kubectl get pods -n kube-system -w
   ```
6. Cuando el pod entre en `CrashLoopBackOff` o `Error`, revisá la causa con `describe` y con los logs del container en el runtime (no con `kubectl logs`, porque el `kube-apiserver` puede no estar disponible si el error fuera en ese componente):
   ```
   kubectl describe pod -n kube-system <pod-kube-scheduler>
   sudo crictl ps -a | grep scheduler
   sudo crictl logs <container-id>
   ```
7. Revertí el cambio en el manifiesto y confirmá la recuperación:
   ```
   sudo vi /etc/kubernetes/manifests/kube-scheduler.yaml
   kubectl get pods -n kube-system -w
   ```

**Preguntas de comprensión**

- ¿Por qué editar un manifiesto en `/etc/kubernetes/manifests/` no requiere hacer `kubectl apply`, ni `kubectl delete pod`, para que el cambio tome efecto?
- Si el componente que falla es el propio `kube-apiserver`, ¿por qué `kubectl logs` puede no ser una herramienta confiable en ese momento, y qué herramienta de nivel container runtime usarías en su lugar?

---

## Ejercicio 3 — Salud de `etcd`

1. Identificá el static pod de `etcd` y los certificados que usa, leyendo su manifiesto:
   ```
   cat /etc/kubernetes/manifests/etcd.yaml | grep -E "cert-file|key-file|trusted-ca-file|listen-client-urls"
   ```
2. Ejecutá un chequeo de salud de endpoint usando `etcdctl` dentro del container (o localmente si el binario está instalado), apuntando a los certificados detectados en el paso anterior:
   ```
   sudo ETCDCTL_API=3 etcdctl \
     --endpoints=https://127.0.0.1:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     endpoint health
   ```
3. Listá los members del cluster de `etcd` para descartar un problema de quorum (relevante si el cluster tiene varios control plane nodes):
   ```
   sudo ETCDCTL_API=3 etcdctl \
     --endpoints=https://127.0.0.1:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     member list
   ```
4. Revisá el uso de disco del directorio de datos de `etcd`, una causa frecuente de degradación de performance:
   ```
   du -sh /var/lib/etcd
   df -h /var/lib/etcd
   ```
5. Consultá los logs del container de `etcd` buscando mensajes de `slow request` o `wal` (write-ahead log) que indiquen latencia de disco:
   ```
   sudo crictl ps -a | grep etcd
   sudo crictl logs <container-id-etcd> 2>&1 | grep -i "slow\|wal"
   ```

**Preguntas de comprensión**

- ¿Por qué `endpoint health` puede reportar `healthy` en un member individual mientras el cluster completo de `etcd` sigue sin quorum?
- ¿Qué relación hay entre latencia de disco y mensajes de `apply request took too long` en los logs de `etcd`?

---

## Ejercicio 4 — `kube-proxy` y fallas de networking a nivel node

1. Confirmá que `kube-proxy` corre como `DaemonSet` y que hay un pod por cada node:
   ```
   kubectl get daemonset -n kube-system kube-proxy
   kubectl get pods -n kube-system -l k8s-app=kube-proxy -o wide
   ```
2. Elegí el pod de `kube-proxy` de un worker específico y revisá sus logs:
   ```
   kubectl logs -n kube-system <pod-kube-proxy-worker>
   ```
3. Conectate por `ssh` a ese worker y confirmá el modo de proxy configurado (`iptables` o `ipvs`) y que las reglas existen:
   ```
   sudo cat /var/lib/kube-proxy/config.conf | grep mode
   sudo iptables -t nat -L KUBE-SERVICES -n | head -20
   ```
4. Creá un Deployment y un Service de tipo `ClusterIP` de prueba, y verificá resolución y conectividad desde un pod temporal en otro node:
   ```
   kubectl create deployment web-test --image=nginx --replicas=1
   kubectl expose deployment web-test --port=80
   kubectl run test-client --rm -it --image=busybox --restart=Never -- wget -qO- web-test.default.svc.cluster.local
   ```
5. Si el paso anterior falla, comparalo con un acceso directo por `ClusterIP` (salteando DNS) para aislar si el problema es de resolución de nombres o de forwarding de `kube-proxy`:
   ```
   kubectl get svc web-test -o jsonpath='{.spec.clusterIP}'
   kubectl run test-client2 --rm -it --image=busybox --restart=Never -- wget -qO- <clusterIP>:80
   ```

**Preguntas de comprensión**

- Si `wget` contra el `ClusterIP` funciona pero contra el nombre DNS del Service falla, ¿en qué componente concentrarías la investigación y por qué ese resultado descarta a `kube-proxy` como causa?
- ¿Por qué reiniciar el pod de `kube-proxy` de un node puede "arreglar" temporalmente un problema de reglas de `iptables` desincronizadas, sin que eso resuelva la causa raíz?

---

## Ejercicio 5 — Certificados vencidos o inválidos del control plane

1. Revisá la fecha de expiración de todos los certificados gestionados por `kubeadm`:
   ```
   sudo kubeadm certs check-expiration
   ```
2. Inspeccioná manualmente un certificado puntual, por ejemplo el del `kube-apiserver`, para confirmar su `Subject`, `Issuer` y fecha de validez:
   ```
   sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -subject -issuer -dates
   ```
3. Provocá (en un cluster de laboratorio, nunca en producción) una falla de confianza copiando un `kubeconfig` de admin a un usuario sin permisos y probando acceso:
   ```
   cp /etc/kubernetes/admin.conf /tmp/test.conf
   KUBECONFIG=/tmp/test.conf kubectl get nodes
   ```
4. Si un certificado está vencido, renovalo con `kubeadm` y reiniciá los static pods afectados moviendo momentáneamente su manifiesto fuera del directorio vigilado:
   ```
   sudo kubeadm certs renew apiserver
   sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
   sleep 5
   sudo mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
   ```
5. Confirmá que el `kube-apiserver` volvió a responder con el certificado renovado:
   ```
   kubectl get --raw='/readyz?verbose'
   ```

**Preguntas de comprensión**

- ¿Por qué mover el manifiesto fuera de `/etc/kubernetes/manifests/` y volver a colocarlo es una forma válida de forzar que `kubelet` recree el static pod con el certificado nuevo?
- ¿Qué diferencia hay entre un error de certificado vencido (`x509: certificate has expired`) y uno de CA no confiable (`x509: certificate signed by unknown authority`) a la hora de decidir el fix?

---

<details>
<summary>Respuestas</summary>

**Ejercicio 1**
- El `kubelet` puede arrancar como proceso de sistema aunque su `kubeconfig` sea inválido o falte, pero sin ese archivo no puede autenticarse contra el `kube-apiserver` para registrar el node ni enviar `NodeStatus` heartbeats. El `kube-apiserver` marca el node como `NotReady` (o directamente no lo lista) porque nunca recibe las actualizaciones de estado esperadas, aunque el proceso del kubelet siga vivo localmente.
- Conviene revisar `/var/log/syslog` o `dmesg` para descartar problemas de kernel/disco, y también las `node conditions` con `kubectl describe node <nombre>`, que exponen directamente `DiskPressure`, `MemoryPressure` y `PIDPressure` reportadas por el kubelet.

**Ejercicio 2**
- Porque `kubelet` monitorea el directorio `staticPodPath` con un watcher de filesystem: cualquier cambio en un manifiesto ahí dentro dispara automáticamente la recreación del pod correspondiente, sin pasar por el `kube-apiserver`. Esto es justamente lo que permite que el `kube-apiserver` mismo se autogestione como static pod, resolviendo el problema de "quién arranca al que arranca a todos".
- Porque `kubectl logs` depende de que el `kube-apiserver` esté disponible y pueda hacer proxy de la solicitud al `kubelet`/runtime del node. Si el propio `kube-apiserver` es el componente caído, no hay forma de usar `kubectl` contra él. La alternativa es conectarse directamente al node y usar el container runtime CLI (`crictl ps`, `crictl logs`) para inspeccionar el container fallido.

**Ejercicio 3**
- Porque `endpoint health` evalúa la salud de ese member puntual (si responde y puede leer/escribir su propio WAL), pero el quorum es una propiedad del cluster completo: se necesita que la mayoría (`N/2 + 1`) de los members estén disponibles y de acuerdo para poder commitear escrituras. Un member puede estar "sano" individualmente y aun así el cluster estar sin quorum si los demás members están caídos.
- Cuando el disco subyacente tiene alta latencia, las escrituras al WAL (que `etcd` usa para garantizar durabilidad antes de aplicar cambios) tardan más de lo esperado. Los mensajes `apply request took too long` son la forma en que `etcd` reporta que superó el umbral de latencia configurado (`--quota-backend-bytes`/tiempos de fsync), señal directa de que el storage no cumple los requisitos de IOPS recomendados para `etcd`.

**Ejercicio 4**
- El foco debería moverse a CoreDNS: ese resultado indica que el forwarding de `kube-proxy` hacia el `ClusterIP` funciona correctamente, así que el service networking está sano. Lo que falla es la resolución del nombre `web-test.default.svc.cluster.local`, algo que depende de los pods de CoreDNS, del `ConfigMap` `coredns` y del `Service` `kube-dns`, no de `kube-proxy`.
- `kube-proxy` reconstruye la tabla de reglas de `iptables`/`ipvs` de ese node completa cada vez que arranca, sincronizándola contra el estado actual de `Services` y `Endpoints` en el `kube-apiserver`. Si las reglas estaban desincronizadas por una actualización que no se propagó (por ejemplo, el proceso quedó colgado sin procesar un watch event), reiniciar el pod fuerza una resincronización completa. Pero si la causa raíz es, por ejemplo, un problema de conectividad hacia el `kube-apiserver` que hace que `kube-proxy` deje de recibir updates, el reinicio sólo "resetea" el síntoma hasta que vuelva a desincronizarse.

**Ejercicio 5**
- El `kubelet` sólo evalúa el contenido del directorio `staticPodPath` para decidir qué static pods deben existir; al detectar que el manifiesto desapareció, termina el pod correspondiente, y al detectar que reapareció, lo vuelve a crear desde cero, incluyendo el remontaje de los certificados desde el filesystem del node (que ya fueron renovados por `kubeadm certs renew`). No hace falta reiniciar `kubelet` ni el nodo completo.
- `certificate has expired` es un problema de tiempo: el certificado fue válido pero ya pasó su `notAfter`, y se resuelve renovándolo con `kubeadm certs renew` (o regenerando manualmente y reiniciando el componente). `certificate signed by unknown authority` es un problema de confianza/cadena: el verificador no tiene la CA que firmó ese certificado en su `trust store` (por ejemplo, un `kubeconfig` apuntando a la CA equivocada tras una rotación), y el fix pasa por corregir qué CA se está usando para validar, no por renovar fechas.

</details>