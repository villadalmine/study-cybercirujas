# 2.2 Troubleshoot cluster components

**Certificación:** CKA v1.35 · **Peso en el examen:** 6

## Introducción

Los cluster components son los procesos que forman el control plane (`kube-apiserver`, `kube-scheduler`, `kube-controller-manager`, `etcd`) y los que corren en cada node (`kubelet`, `kube-proxy`, container runtime). En un cluster desplegado con `kubeadm` —el escenario más común en el examen— casi todos estos componentes corren como **static Pods** administrados directamente por el kubelet de cada node de control plane, no por el API server. Entender esta arquitectura es la clave para troubleshootear: si el API server está caído, no podés usar `kubectl` para diagnosticarlo, así que hay que recurrir a herramientas de nivel sistema operativo (`systemctl`, `journalctl`, `crictl`, revisión de manifests).

## Arquitectura: static Pods del control plane

En clusters `kubeadm`, los manifests de los componentes del control plane viven en:

```bash
ls /etc/kubernetes/manifests/
# etcd.yaml
# kube-apiserver.yaml
# kube-controller-manager.yaml
# kube-scheduler.yaml
```

El kubelet vigila ese directorio (`staticPodPath` en `/var/lib/kubelet/config.yaml`) y crea/recrea Pods automáticamente cuando cambia un archivo. Esto significa:

- Editar un manifest ahí reinicia el componente sin necesidad de `kubectl apply`.
- Si un componente crashea en loop, el problema casi siempre está en ese YAML (flag mal escrito, imagen inexistente, certificado apuntando a un path que no existe).
- Los static Pods se ven en `kubectl get pods -n kube-system`, pero con el sufijo del nombre del node (ej. `kube-apiserver-controlplane`), y **no se pueden borrar con kubectl** (el kubelet los vuelve a crear). Para "borrarlos" hay que sacar el archivo del manifest path y volverlo a poner.

## Verificar el estado general del cluster

```bash
kubectl get nodes
kubectl get pods -n kube-system -o wide
kubectl cluster-info
```

Salida esperada cuando todo está sano:

```
NAME             STATUS   ROLES           AGE   VERSION
controlplane     Ready    control-plane   10d   v1.35.0
node01           Ready    <none>          10d   v1.35.0
```

Si un componente del control plane está caído, vas a ver algo como:

```
NAME                                READY   STATUS             RESTARTS   AGE
kube-apiserver-controlplane         0/1     CrashLoopBackOff   5          3m
etcd-controlplane                  1/1     Running            0          10d
kube-scheduler-controlplane         1/1     Running            0          10d
kube-controller-manager-controlplane 1/1   Running            0          10d
```

`kubectl get componentstatuses` (`kubectl get cs`) existe pero está **deprecated** desde 1.19 y suele devolver información inconsistente o vacía; no confiar en él para el examen.

## Troubleshooting cuando `kubectl` no responde

Si `kubectl get nodes` cuelga o tira `connection refused`, el problema probablemente es el `kube-apiserver`. Ahí `kubectl` no sirve — hay que ir directo al node de control plane:

```bash
# ¿Está corriendo el kubelet?
systemctl status kubelet

# Logs del kubelet (quien administra los static pods)
journalctl -u kubelet -f
journalctl -u kubelet --since "10 min ago" | grep -i error

# ¿Qué contenedores hay realmente corriendo? (containerd)
crictl ps -a
crictl logs <container-id>
```

Ejemplo de error típico en `crictl ps -a` cuando el manifest tiene un flag inválido:

```
CONTAINER ID   IMAGE                        CREATED         STATE      NAME             ATTEMPT
a1b2c3d4e5f6   registry.k8s.io/kube-apiserver   10s ago     Exited     kube-apiserver   6
```

```bash
crictl logs a1b2c3d4e5f6
# Error: unknown flag: --secure-port-typo
```

En ese caso, la solución es editar `/etc/kubernetes/manifests/kube-apiserver.yaml`, corregir el flag, guardar; el kubelet detecta el cambio y recrea el Pod automáticamente (no hace falta reiniciar nada más).

## Causas comunes de falla por componente

### kube-apiserver
- Flags inválidos o mal escritos en el manifest.
- Certificados vencidos o paths incorrectos (`--tls-cert-file`, `--client-ca-file`, `--etcd-cafile`, etc.) — chequear con:
  ```bash
  openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -dates
  ```
- No puede conectar a etcd (etcd caído o `--etcd-servers` apuntando mal).
- Puerto ya en uso (otro proceso escuchando en 6443).

### etcd
```bash
kubectl exec -n kube-system etcd-controlplane -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health
```
Salida sana:
```
127.0.0.1:2379 is healthy: successfully committed proposal: took = 12ms
```
Si etcd no arranca, revisar espacio en disco (`df -h /var/lib/etcd`), corrupción de datos, o que el `--data-dir` en el manifest coincida con el volumen montado.

### kube-scheduler / kube-controller-manager
Menos crítico para el API pero rompe scheduling o reconciliación (Deployments no crean Pods, Nodes no se marcan NotReady tras timeout, etc.). Diagnóstico:
```bash
kubectl logs -n kube-system kube-scheduler-controlplane
kubectl logs -n kube-system kube-controller-manager-controlplane
```
Buscar mensajes de "leader election" fallida (compite con otra instancia) o errores de conexión al API server.

### kubelet (en cualquier node, incluyendo workers)
Si un node aparece `NotReady`:
```bash
kubectl describe node node01
# Conditions: Ready=False, KubeletNotReady, PLEG is not healthy
```
En el node afectado:
```bash
systemctl status kubelet
journalctl -u kubelet -n 100 --no-pager
```
Causas típicas:
- kubelet no está corriendo (`systemctl start kubelet`) o falla al arrancar por config inválida (`/var/lib/kubelet/config.yaml`).
- `container runtime is down` — revisar `containerd`/`crio` con `systemctl status containerd`.
- Certificado del kubelet vencido (`/var/lib/kubelet/pki/kubelet-client-current.pem`).
- CNI plugin no instalado o mal configurado en `/etc/cni/net.d/`.

### kube-proxy
Si Services no resuelven tráfico a los Pods pero los Pods están `Running`:
```bash
kubectl get pods -n kube-system -l k8s-app=kube-proxy
kubectl logs -n kube-system kube-proxy-xxxxx
```
Revisar que las reglas de iptables/IPVS se estén generando:
```bash
iptables -t nat -L KUBE-SERVICES -n | head
```
Si no hay reglas, kube-proxy no está sincronizando — reiniciar el Pod (es un DaemonSet, no static Pod, así que sí se puede borrar con `kubectl delete pod` y se recrea).

## Estrategia general para el examen

1. `kubectl get nodes` y `kubectl get pods -n kube-system` primero, para localizar qué componente falla.
2. Si `kubectl` no responde en absoluto → SSH al control plane node, usar `systemctl`/`journalctl`/`crictl`.
3. `kubectl describe pod <componente>-<node> -n kube-system` para ver eventos y el último estado (`Last State: Terminated, Reason: Error`).
4. `kubectl logs <componente>-<node> -n kube-system` (si el Pod al menos se creó alguna vez) o `crictl logs` (si ni siquiera eso).
5. La causa casi siempre está en el manifest estático (`/etc/kubernetes/manifests/*.yaml`) o en certificados/paths de `/etc/kubernetes/pki/`.
6. Después de editar un manifest, esperar unos segundos a que el kubelet lo recargue; no hace falta `kubectl apply` ni reiniciar el kubelet.

## Referencias

- Kubernetes docs — Troubleshoot Clusters: https://kubernetes.io/docs/tasks/debug/debug-cluster/
- Kubernetes docs — Static Pods: https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/
- Kubernetes docs — kubeadm troubleshooting: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/troubleshooting-kubeadm/
- Kubernetes docs — Debug a StatefulSet / etcd operations reference: https://etcd.io/docs/latest/op-guide/maintenance/
- Kubernetes docs — kubelet: https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/
- CNCF CKA Curriculum v1.35: https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
