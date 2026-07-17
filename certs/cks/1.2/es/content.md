# 1.2 — CIS Benchmark: revisar la configuración de seguridad de etcd, kubelet, kube-dns y kube-apiserver

## Qué es el CIS Benchmark for Kubernetes

El **CIS (Center for Internet Security) Kubernetes Benchmark** es un documento de buenas prácticas de hardening, organizado en checks numerados (ej. `1.2.1`, `4.2.5`), que cubre la configuración de los componentes del control plane, de etcd, de los worker nodes y de un conjunto de policies generales (RBAC, Pod Security, Network Policies, Secrets). Cada check indica:

- **Nivel**: `Automated` (se puede verificar/remediar mecánicamente) o `Manual` (requiere juicio del operador, por ejemplo "revisar que el admission plugin X esté configurado según la política de la organización").
- **Scored / Not Scored** en versiones antiguas del benchmark (terminología reemplazada por Automated/Manual desde CIS Kubernetes Benchmark v1.6+).
- Descripción del riesgo, remediación sugerida y comando de auditoría.

El benchmark se publica en distintas variantes según la distro (`cis-1.24` para kubeadm genérico, `eks-1.2.0`, `gke-1.2.0`, `aks-1.0`, etc.), porque en clusters managed (EKS/GKE/AKS) el control plane no es accesible y muchos checks de `etcd`/`kube-apiserver` no aplican o quedan como Manual.

## kube-bench: la herramienta que automatiza el benchmark

`kube-bench` (proyecto de Aqua Security, hoy parte del ecosistema CNCF) es la herramienta estándar para correr el CIS Benchmark contra un cluster real. Lee los targets (`master`, `etcd`, `node`, `policies`) y compara la configuración corriendo contra los checks del benchmark.

### Instalación y ejecución (binario en el nodo)

```bash
curl -L https://github.com/aquasecurity/kube-bench/releases/download/v0.9.3/kube-bench_0.9.3_linux_amd64.tar.gz -o kube-bench.tar.gz
tar -xvf kube-bench.tar.gz
sudo ./kube-bench run --targets master,etcd,node
```

### Ejecución como Job dentro del cluster (forma típica en un cluster kubeadm, y la más común en el examen)

```bash
kubectl apply -f https://raw.githubusercontent.com/aquasecurity/kube-bench/main/job.yaml
kubectl logs -f job/kube-bench
```

kube-bench detecta automáticamente el tipo de nodo (control plane vs worker) inspeccionando la presencia de manifiestos en `/etc/kubernetes/manifests/`. Si el detector falla (por ejemplo, en un nodo con nombres de servicio no estándar) se puede forzar con `--benchmark cis-1.24` o especificar `--config-dir`/`--kubeconfig`.

### Ejemplo de salida (resumida)

```
[INFO] 1 Control Plane Security Configuration
[INFO] 1.2 API Server
[PASS] 1.2.1 Ensure that the --anonymous-auth argument is set to false (Manual)
[FAIL] 1.2.6 Ensure that the --kubelet-certificate-authority argument is set as appropriate (Automated)
[WARN] 1.2.11 Ensure that the admission control plugin EventRateLimit is set (Manual)
[PASS] 1.2.20 Ensure that the --profiling argument is set to false (Automated)

[INFO] 2 Etcd Node Configuration
[PASS] 2.1 Ensure that the --cert-file and --key-file arguments are set as appropriate (Automated)
[FAIL] 2.3 Ensure that the --auto-tls argument is not set to true (Automated)
[PASS] 2.6 Ensure that the --peer-auto-tls argument is not set to true (Automated)

[INFO] 4 Worker Node Security Configuration
[INFO] 4.2 Kubelet
[FAIL] 4.2.1 Ensure that the --anonymous-auth argument is set to false (Automated)
[PASS] 4.2.2 Ensure that the --authorization-mode argument is not set to AlwaysAllow (Automated)
[WARN] 4.2.5 Ensure that the --streaming-connection-idle-timeout argument is not set to 0 (Manual)

== Summary ==
52 checks PASS
6 checks FAIL
14 checks WARN
0 checks INFO
```

Cada `FAIL`/`WARN` en la salida real de kube-bench viene acompañado de una sección **"Remediation"** con el comando o cambio de archivo exacto — en el examen conviene usar esa sugerencia como punto de partida y no memorizar cada flag de memoria.

## Sección 1 y 3 del benchmark: kube-apiserver

El grueso de los checks del `kube-apiserver` apunta a flags del manifiesto estático `/etc/kubernetes/manifests/kube-apiserver.yaml`. Los que más aparecen en el examen:

| Check (aprox.) | Flag | Valor esperado | Riesgo si está mal |
|---|---|---|---|
| 1.2.1 | `--anonymous-auth` | `false` | Requests sin autenticar se tratan como `system:anonymous` |
| 1.2.6 / 1.2.7 | `--kubelet-client-certificate` / `--kubelet-client-key` | seteados | apiserver no puede autenticarse contra kubelet en canal seguro |
| 1.2.8 | `--kubelet-certificate-authority` | seteado | apiserver no valida el cert del kubelet, riesgo MITM |
| 1.2.16-19 | `--authorization-mode` | incluye `Node,RBAC` (nunca `AlwaysAllow`) | cualquier request autenticado queda autorizado |
| 1.2.20 | `--profiling` | `false` | expone endpoints de pprof que filtran internals |
| 1.2.21 | `--audit-log-path` | seteado | sin logging de auditoría no hay trazabilidad forense |
| 1.2.22-24 | `--audit-log-maxage/maxbackup/maxsize` | seteados | logs de auditoría rotan sin retención mínima |
| 1.2.31 | `--encryption-provider-config` | seteado, con provider ≠ `identity` primero | Secrets quedan en texto plano en etcd |
| 1.2.32-33 | `--tls-cert-file` / `--tls-private-key-file` | seteados | tráfico API sin TLS server-side |

Remediación típica (editar el static pod manifest, kubelet lo reconcilia solo por file-watch):

```bash
sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml
```

```yaml
    - --anonymous-auth=false
    - --authorization-mode=Node,RBAC
    - --profiling=false
    - --audit-log-path=/var/log/kubernetes/audit/audit.log
    - --audit-log-maxage=30
    - --audit-log-maxbackup=10
    - --audit-log-maxsize=100
```

No hace falta `kubectl apply`: al ser un static pod, kubelet detecta el cambio en el archivo y recrea el pod automáticamente.

## Sección 2: etcd

etcd guarda **todo** el estado del cluster, incluyendo Secrets (a menos que haya encryption-at-rest configurado), así que su hardening es crítico:

| Check | Flag | Valor esperado |
|---|---|---|
| 2.1 | `--cert-file` / `--key-file` | seteados (TLS para client-to-server) |
| 2.2 | `--client-cert-auth` | `true` (exige mTLS a los clientes) |
| 2.3 | `--auto-tls` | `false` (no usar certs autogenerados sin CA propia) |
| 2.4 | `--peer-cert-file` / `--peer-key-file` | seteados (TLS entre miembros del cluster etcd) |
| 2.5 | `--peer-client-cert-auth` | `true` |
| 2.6 | `--peer-auto-tls` | `false` |
| — | permisos del data dir (`/var/lib/etcd`) | `700` o más restrictivo |
| — | permisos de `etcd.yaml` y de los certs | `600` |

```bash
sudo vi /etc/kubernetes/manifests/etcd.yaml
```

```yaml
    - --client-cert-auth=true
    - --auto-tls=false
    - --peer-client-cert-auth=true
    - --peer-auto-tls=false
```

```bash
sudo chmod 700 /var/lib/etcd
sudo chmod 600 /etc/kubernetes/pki/etcd/*.key
```

Verificación manual de que etcd exige mTLS (sin cert, la conexión debe ser rechazada):

```bash
ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 get / --prefix --keys-only
# Error: rpc error: code = Unavailable desc = transport is closing  (sin certs → falla, correcto)

ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get / --prefix --keys-only
```

## Sección 4.2: kubelet

El kubelet corre en cada nodo y expone una API HTTPS (puerto 10250) que, mal configurada, permite ejecutar comandos o leer logs sin autenticación. Los checks clave:

| Check | Config (`kubelet-config.yaml` o flag) | Valor esperado |
|---|---|---|
| 4.2.1 | `anonymous.enabled` | `false` |
| 4.2.2 | `authorization.mode` | `Webhook` (nunca `AlwaysAllow`) |
| 4.2.3 | `--client-ca-file` | seteado (valida certs de clientes contra la CA del cluster) |
| 4.2.4 | `readOnlyPort` | `0` (deshabilitado; el puerto 10255 sin auth no debería existir) |
| 4.2.5 | `streamingConnectionIdleTimeout` | ≠ `0` (ej. `4h`) |
| 4.2.6 | `protectKernelDefaults` | `true` |
| 4.2.7 | `makeIPTablesUtilChains` | `true` |
| 4.2.10 | `tlsCertFile` / `tlsPrivateKeyFile` | seteados |
| 4.2.12 | `rotateCertificates` | `true` |
| 4.2.13 | `--tls-cipher-suites` | solo cipher suites fuertes (excluir 3DES, RC4, etc.) |

Desde Kubernetes 1.10+ la config del kubelet vive en un archivo YAML (no solo flags), típicamente `/var/lib/kubelet/config.yaml`:

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt
authorization:
  mode: Webhook
readOnlyPort: 0
protectKernelDefaults: true
rotateCertificates: true
```

```bash
sudo systemctl restart kubelet
```

Además hay checks de permisos de archivo (Automated) muy fáciles de puntuar rápido en el examen:

```bash
sudo chmod 600 /var/lib/kubelet/config.yaml
sudo chmod 600 /etc/kubernetes/kubelet.conf
sudo chown root:root /var/lib/kubelet/config.yaml
```

## kube-dns / CoreDNS: por qué no aparece como sección propia del benchmark

A diferencia de etcd, kubelet y kube-apiserver, **CoreDNS (o kube-dns en clusters legacy) no tiene una sección dedicada en el CIS Kubernetes Benchmark**, porque no es un componente de control plane con manifiesto estático: corre como un `Deployment` normal en el namespace `kube-system`, expuesto vía el `Service` `kube-dns`. El temario CKS lo incluye porque su revisión de seguridad cae bajo los mismos criterios generales de la **Sección 5 (Policies)** del benchmark, aplicados a este workload crítico:

- **RBAC mínimo**: el `ServiceAccount` `coredns` no debería tener más permisos que `list/watch` sobre `endpoints`, `services`, `pods`, `namespaces` (verificar con `kubectl get clusterrole system:coredns -o yaml`).
- **Resource limits**: sin `limits` de CPU/memoria, un pico de queries puede tumbar CoreDNS y con eso la resolución de nombres de todo el cluster.
- **PodSecurity / securityContext**: correr como non-root, `readOnlyRootFilesystem: true`, sin capabilities extra.
- **Config del plugin**: evitar el plugin `proxy`/`forward` apuntando a resolvers externos no confiables, y no habilitar el plugin `log`/`debug` en producción salvo troubleshooting puntual (fuga de queries en logs).

Verificación rápida:

```bash
kubectl get deployment coredns -n kube-system -o jsonpath='{.spec.template.spec.containers[0].securityContext}'
kubectl get clusterrolebinding system:coredns -o yaml
```

## Flujo recomendado para el examen

1. Correr `kube-bench run --targets master,etcd,node` (o el Job in-cluster si no hay acceso SSH directo al nodo).
2. Filtrar por `FAIL` primero, `WARN` después — los `FAIL` automatizados son puntos garantizados.
3. Para cada finding, aplicar la remediación (editar static pod manifest, `kubelet-config.yaml`, o permisos de archivo) y re-correr kube-bench para confirmar que pasó a `PASS`.
4. Recordar que static pods (`kube-apiserver`, `etcd`, `controller-manager`, `scheduler`) se reconcilian solos al guardar el YAML; el kubelet en cambio necesita `systemctl restart kubelet` porque no es un static pod sino un servicio systemd.

## Referencias

- CNCF, *CKS Curriculum v1.34*: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- CIS Kubernetes Benchmark (descarga con registro gratuito): https://www.cisecurity.org/benchmark/kubernetes
- kube-bench (Aqua Security / CNCF): https://github.com/aquasecurity/kube-bench
- kube-bench, documentación de uso y targets: https://github.com/aquasecurity/kube-bench/blob/main/docs/running.md
- Kubernetes, referencia de flags de `kube-apiserver`: https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/
- Kubernetes, `KubeletConfiguration` v1beta1: https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
- Kubernetes, *Kubelet authentication/authorization*: https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/
- etcd, *Security model*: https://etcd.io/docs/v3.5/op-guide/security/
- Kubernetes, *Encrypting Confidential Data at Rest*: https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
- CoreDNS, documentación de seguridad y plugins: https://coredns.io/manual/security/