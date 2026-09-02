# 1.4 Proteger los metadatos del nodo y los endpoints

## Por qué esto importa

Cada nodo worker expone dos clases de superficie privilegiada que son alcanzables *desde dentro de un Pod* por defecto:

1. **Metadatos de instancia de nube** — el servicio link-local en `169.254.169.254`, que entrega la identidad del nodo, su `user-data` (que a menudo contiene tokens de bootstrap o kubeconfigs) y, lo más peligroso, **credenciales de nube de corta duración para el rol IAM / la cuenta de servicio del nodo**.
2. **Endpoints del nodo y del plano de control** — la API del kubelet en `10250`, el puerto legacy de solo lectura `10255`, etcd en `2379`, el API server en `6443`, y los puertos de health del controller-manager / scheduler.

No hace falta un escape de contenedor para abusar de ninguno de los dos. Basta con un simple `curl` desde un Pod sin privilegios. La cadena de ataque clásica es:

```
compromised app Pod → curl 169.254.169.254 → node IAM credentials
                    → read cluster secrets from cloud storage / attach new nodes
```

o

```
compromised app Pod → curl -k https://NODE_IP:10250/pods → anonymous kubelet
                    → POST /run/<ns>/<pod>/<container> → RCE on any container on that node
```

Ambos son problemas a nivel de red, así que ambos se resuelven con controles a nivel de red y de authn/authz — no con Pod Security Standards.

---

## Parte 1 — Metadatos de instancia de nube

### Qué expone el endpoint

La dirección `169.254.169.254` es idéntica en AWS, GCP, Azure y la mayoría de las nubes basadas en OpenStack. Solo cambian las rutas y las cabeceras requeridas.

**GCP / GKE**

```bash
curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token
```

```json
{"access_token":"ya29.c.b0Aa...","expires_in":3599,"token_type":"Bearer"}
```

Las rutas legacy `v1beta1` no requerían la cabecera `Metadata-Flavor`, lo que las hacía trivialmente explotables vía SSRF. Están deshabilitadas en las instancias modernas.

**AWS / EKS**

IMDSv1 (sin autenticación, un único GET):

```bash
curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/
# eks-node-role
curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/eks-node-role
```

```json
{"Code":"Success","AccessKeyId":"ASIA...","SecretAccessKey":"...","Token":"...","Expiration":"2026-07-29T18:04:11Z"}
```

IMDSv2 requiere primero un token de sesión:

```bash
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/
```

**Azure / AKS**

```bash
curl -s -H "Metadata:true" \
  "http://169.254.169.254/metadata/instance?api-version=2021-02-01"
```

### Prueba rápida desde un Pod

```bash
kubectl run imds-test --rm -it --image=curlimages/curl --restart=Never -- \
  curl -s --connect-timeout 3 http://169.254.169.254/latest/meta-data/
```

Si recibís un listado de vuelta, cualquier workload de ese namespace puede robar las credenciales del nodo. Si la política está en su lugar, obtenés un timeout:

```
curl: (28) Connection timed out after 3001 milliseconds
pod "imds-test" deleted
pod default/imds-test terminated (Error)
```

### Mitigación 1 — NetworkPolicy (la respuesta del examen)

Las NetworkPolicies son listas de permitidos, así que "bloquear una IP" se expresa como *permitir todo excepto esa IP*. Aplicala por namespace:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-cloud-metadata
  namespace: default
spec:
  podSelector: {}          # every Pod in the namespace
  policyTypes:
  - Egress
  egress:
  - to:
    - ipBlock:
        cidr: 0.0.0.0/0
        except:
        - 169.254.169.254/32
  # keep cluster DNS working explicitly
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
```

```bash
kubectl apply -f deny-cloud-metadata.yaml
kubectl describe netpol deny-cloud-metadata
```

```
Allowing egress traffic:
  To Port: <any> (traffic allowed to all ports)
  To:
    IPBlock:
      CIDR: 0.0.0.0/0
      Except: 169.254.169.254/32
```

Tres advertencias que se evalúan con frecuencia:

- La política es **namespaced**. Una por namespace, o un equivalente a nivel de cluster (`CiliumClusterwideNetworkPolicy`, `GlobalNetworkPolicy` de Calico).
- Los Pods con `hostNetwork: true` comparten el netns del nodo y **no** están sujetos a NetworkPolicy. Bloqueá `hostNetwork` con Pod Security Admission (`baseline`/`restricted`) o una ValidatingAdmissionPolicy.
- Necesitás un CNI que aplique NetworkPolicy (Calico, Cilium, Weave…). En un cluster con flannel puro el objeto se acepta y se ignora silenciosamente.

### Mitigación 2 — Controles nativos de la nube

| Plataforma | Control |
|---|---|
| AWS/EKS | `--http-tokens required` (forzar IMDSv2) **y** `--http-put-response-hop-limit 1`, para que el TTL de la respuesta muera antes de llegar al netns de un Pod. Usá IRSA / EKS Pod Identity para las credenciales de los workloads. |
| GKE | Habilitá **Workload Identity** (`--workload-metadata-config=GKE_METADATA`); el servidor de metadatos de GKE solo sirve la identidad propia del Pod y bloquea la del nodo. |
| AKS | Restringí IMDS con una network policy y usá **Workload Identity** (federación OIDC) en lugar de la identidad del kubelet. |

```bash
aws ec2 modify-instance-metadata-options \
  --instance-id i-0abc123 --http-tokens required --http-put-response-hop-limit 1
```

### Mitigación 3 — Firewall a nivel de nodo (alternativa)

Solo cuando no existe un CNI capaz de aplicar políticas:

```bash
iptables -I FORWARD -d 169.254.169.254/32 -j DROP
```

Esto descarta el tráfico de metadatos que se *reenvía* desde los Pods, dejando intacto el acceso propio del nodo. No es idempotente entre reinicios — persistilo con el tooling de bootstrap de tus nodos.

---

## Parte 2 — Endpoints del nodo

### La API del kubelet (10250) y el puerto de solo lectura (10255)

El kubelet sirve `/pods`, `/runningpods/`, `/metrics`, `/logs/`, `/exec/`, `/run/` y `/attach/`. Con la autenticación anónima habilitada, `/run/` es ejecución remota de código sin autenticar sobre cualquier contenedor planificado en ese nodo.

Verificá la postura actual:

```bash
curl -sk https://NODE_IP:10250/pods | head -c 120
```

Nodo endurecido:

```
Unauthorized
```

Nodo vulnerable:

```json
{"kind":"PodList","apiVersion":"v1","metadata":{},"items":[{"metadata":{"name":"etcd-controlplane",...
```

Sondeá también el puerto de solo lectura, que no necesita TLS ni credenciales:

```bash
curl -s http://NODE_IP:10255/pods            # should refuse the connection
```

Corrección en `/var/lib/kubelet/config.yaml`:

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
authentication:
  anonymous:
    enabled: false          # no anonymous requests
  webhook:
    enabled: true           # bearer tokens validated via TokenReview
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt
authorization:
  mode: Webhook             # NOT AlwaysAllow — delegate to the API server
readOnlyPort: 0             # disable 10255
```

```bash
systemctl restart kubelet
systemctl status kubelet --no-pager | head -5
```

Verificá los flags efectivos si el kubelet todavía se arranca con argumentos de línea de comandos:

```bash
ps -ef | grep [k]ubelet | tr ' ' '\n' | grep -E 'anonymous|authorization-mode|read-only-port|config'
```

```
--config=/var/lib/kubelet/config.yaml
```

(Los flags tienen precedencia sobre el archivo de configuración; en clusters kubeadm los ajustes viven en el YAML.)

### Restringir quién puede alcanzar el kubelet a través del API server

Incluso un kubelet bien cerrado puede alcanzarse vía el proxy del API server:

```bash
kubectl get --raw /api/v1/nodes/node01/proxy/pods
```

Esto requiere el subrecurso `nodes/proxy`. Auditalo y quitalo de los roles que no son de administrador:

```bash
kubectl get clusterroles -o json | jq -r '
  .items[] | select(.rules[]?.resources[]? | test("nodes/proxy")) | .metadata.name'
```

### Endpoints del plano de control en el nodo

| Componente | Puerto | Binding esperado |
|---|---|---|
| kube-apiserver | 6443 | TLS + authn/authz; el puerto inseguro legacy `8080` ya no existe |
| kubelet | 10250 | TLS, authz `Webhook` |
| kubelet read-only | 10255 | deshabilitado (`readOnlyPort: 0`) |
| kube-scheduler | 10259 | `--bind-address=127.0.0.1` |
| kube-controller-manager | 10257 | `--bind-address=127.0.0.1` |
| etcd | 2379 / 2380 | autenticación por certificado de cliente + peer, solo `127.0.0.1`/IP del nodo |

```bash
ss -tlnp | grep -E ':(2379|2380|6443|10250|10255|10257|10259)'
```

```
LISTEN 0 4096 127.0.0.1:10257  0.0.0.0:*  users:(("kube-controller",pid=1421,fd=3))
LISTEN 0 4096 127.0.0.1:10259  0.0.0.0:*  users:(("kube-scheduler",pid=1388,fd=3))
LISTEN 0 4096         *:10250  *:*        users:(("kubelet",pid=902,fd=21))
```

Cualquier cosa enlazada a `0.0.0.0` que debería ser solo loopback es un hallazgo. Complementá esto con reglas de firewall en el host o security groups de la nube, de modo que `10250`, `2379-2380` y `6443` solo sean alcanzables desde miembros del cluster y redes de administración.

### Node authorization y NodeRestriction

Asegurate de que un kubelet comprometido no pueda leer secrets pertenecientes a Pods que no ejecuta, ni re-etiquetarse a sí mismo como un nodo privilegiado:

```bash
kubectl -n kube-system get pod kube-apiserver-controlplane -o yaml \
  | grep -E 'authorization-mode|enable-admission-plugins'
```

```
    - --authorization-mode=Node,RBAC
    - --enable-admission-plugins=NodeRestriction
```

La autorización `Node` acota las lecturas del kubelet a los objetos ligados a ese nodo; `NodeRestriction` impide que un kubelet modifique otros nodos o se ponga a sí mismo etiquetas `node-restriction.kubernetes.io/*`.

---

## Checklist de endurecimiento

- [ ] Egress denegado por defecto hacia `169.254.169.254/32` en cada namespace de workloads.
- [ ] `hostNetwork: true` bloqueado por admission (elude NetworkPolicy).
- [ ] Workload identity nativa de la nube en uso; el rol IAM del nodo tiene los permisos mínimos.
- [ ] IMDSv2 requerido con hop limit 1 (AWS) o servidor de metadatos de Workload Identity (GKE/AKS).
- [ ] `anonymous.enabled: false`, `authorization.mode: Webhook`, `readOnlyPort: 0`.
- [ ] `--authorization-mode=Node,RBAC` y `NodeRestriction` habilitados.
- [ ] scheduler/controller-manager enlazados a `127.0.0.1`; etcd exige certificados de cliente.
- [ ] `nodes/proxy` no concedido fuera de roles de emergencia (break-glass).
- [ ] Verificado desde un Pod descartable, no solo leyendo manifiestos.

---

## Referencias

- CKS Curriculum v1.34 — <https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf>
- Network Policies — <https://kubernetes.io/docs/concepts/services-networking/network-policies/>
- Kubelet authentication and authorization — <https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/>
- Kubelet configuration (v1beta1) reference — <https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/>
- Using Node Authorization — <https://kubernetes.io/docs/reference/access-authn-authz/node/>
- Admission controllers (NodeRestriction) — <https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#noderestriction>
- Ports and Protocols — <https://kubernetes.io/docs/reference/networking/ports-and-protocols/>
- Securing a Cluster — <https://kubernetes.io/docs/tasks/administer-cluster/securing-a-cluster/>
- Pod Security Standards — <https://kubernetes.io/docs/concepts/security/pod-security-standards/>
- AWS — Use IMDSv2 — <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-IMDS-new-instances.html>
- AWS — Restrict access to the instance profile assigned to the worker node (EKS Best Practices) — <https://docs.aws.amazon.com/eks/latest/best-practices/identity-and-access-management.html>
- GKE — Workload Identity Federation — <https://cloud.google.com/kubernetes-engine/docs/concepts/workload-identity>
- GCP — VM metadata server — <https://cloud.google.com/compute/docs/metadata/overview>
- Azure — Instance Metadata Service — <https://learn.microsoft.com/en-us/azure/virtual-machines/instance-metadata-service>
- CIS Kubernetes Benchmark (kubelet section 4.2) — <https://www.cisecurity.org/benchmark/kubernetes>