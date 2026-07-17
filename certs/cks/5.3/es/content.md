# CKS 5.3 — Minimizar el acceso externo a la red

## Contexto

Este tema pertenece al dominio **System Hardening** del curriculum CKS: mientras que las **NetworkPolicies** (dominio *Minimize Microservice Vulnerabilities*) controlan el tráfico *dentro* del clúster (pod-to-pod), este punto se enfoca en la capa de **OS/red del nodo**: qué puertos están escuchando, quién puede alcanzarlos desde fuera del clúster, y cómo reducir esa superficie de ataque con firewalls de sistema operativo, security groups del cloud provider, y configuración de los componentes del control plane.

La idea central es **defense in depth**: cada componente (API server, etcd, kubelet, kube-proxy, scheduler, controller-manager) expone un puerto de red, y por defecto muchos de esos puertos son alcanzables desde cualquier interfaz. El trabajo del examen es identificar qué debería estar expuesto, a quién, y bloquear el resto.

## Superficie de ataque: puertos por componente

| Puerto | Componente | Protocolo | Exposición recomendada |
|---|---|---|---|
| 6443 | kube-apiserver | HTTPS | Solo desde red de administración / nodos |
| 2379-2380 | etcd (client/peer) | HTTPS | Solo entre nodos del control plane |
| 10250 | kubelet API | HTTPS | Solo desde el API server |
| 10255 | kubelet read-only (deprecado) | HTTP sin auth | **Deshabilitado** (`readOnlyPort: 0`) |
| 10257 | kube-controller-manager | HTTPS | Solo localhost / control plane |
| 10259 | kube-scheduler | HTTPS | Solo localhost / control plane |
| 10249 | kube-proxy metrics | HTTP sin auth | Solo localhost |
| 30000-32767 | NodePort range | TCP/UDP | Evitar exposición pública salvo necesidad explícita |
| 22 | SSH (nodos) | TCP | Solo desde bastion/VPN |

Esta tabla es la referencia oficial y conviene memorizarla para el examen: https://kubernetes.io/docs/reference/networking/ports-and-protocols/

## 1. Minimizar la exposición del API server

El API server es el punto de entrada crítico. Para clústeres self-managed:

- Bindear `--bind-address` a la interfaz interna, no `0.0.0.0` si no es necesario.
- Usar `--advertise-address` explícito para controlar qué IP se anuncia a los clientes.
- El puerto inseguro (`--insecure-port`) ya no existe desde Kubernetes 1.20+ — no hay nada que deshabilitar, pero es útil saber que en versiones viejas era un vector de ataque.

Para clústeres managed (EKS/GKE/AKS), la técnica principal es usar **endpoint privado**:

```bash
# EKS: deshabilitar acceso público al endpoint del API server
aws eks update-cluster-config \
  --name mi-cluster \
  --resources-vpc-config endpointPublicAccess=false,endpointPrivateAccess=true
```

```bash
# GKE: crear clúster privado, sin IP pública en el control plane
gcloud container clusters create mi-cluster \
  --enable-private-nodes \
  --enable-private-endpoint \
  --master-ipv4-cidr 172.16.0.0/28
```

Cuando el endpoint es privado, el acceso administrativo se hace vía VPN, bastion host, o VPC peering — nunca directo desde internet.

## 2. Hardening de etcd

etcd almacena todo el estado del clúster (incluyendo Secrets en texto plano si no hay encryption at rest). Debe:

- Bindear `--listen-client-urls` solo a la interfaz interna, no a `0.0.0.0`.
- Usar `--client-cert-auth=true` y `--peer-client-cert-auth=true` (mTLS obligatorio).
- No ser alcanzable desde workers ni desde fuera de la red del control plane.

```bash
# Fragmento típico de manifest estático de etcd
--listen-client-urls=https://127.0.0.1:2379,https://10.0.0.5:2379
--listen-peer-urls=https://10.0.0.5:2380
--client-cert-auth=true
--peer-client-cert-auth=true
--trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
```

Verificar que no responde sin certificado:

```bash
$ curl -k https://10.0.0.5:2379/version
curl: (35) error:1401E410:SSL routines:CONN_INIT:sslv3 alert handshake failure
```

## 3. Hardening de kubelet

kubelet expone una API HTTPS (10250) que permite ejecutar comandos en pods (`exec`, `logs`, `attach`). Sin autenticación/autorización correctas, es RCE directo.

```yaml
# /var/lib/kubelet/config.yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
readOnlyPort: 0            # deshabilita el puerto 10255 sin auth
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true           # delega auth al API server (SubjectAccessReview)
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt
authorization:
  mode: Webhook
```

Verificar desde un nodo externo que el acceso anónimo está bloqueado:

```bash
$ curl -sk https://<node-ip>:10250/pods
Unauthorized
```

Si en cambio devuelve JSON con la lista de pods sin autenticar, kubelet está mal hardenizado — este es un check clásico de examen.

## 4. Firewall a nivel de OS

Aunque el clúster use un CNI con NetworkPolicy, el **firewall del host** es una capa adicional que restringe qué puede llegar siquiera a la interfaz de red del nodo, independientemente de si Kubernetes está corriendo.

### iptables

```bash
# Permitir 6443 solo desde la red interna del clúster
iptables -A INPUT -p tcp --dport 6443 -s 10.0.0.0/16 -j ACCEPT
iptables -A INPUT -p tcp --dport 6443 -j DROP

# Bloquear kubelet (10250) salvo desde los control-plane nodes
iptables -A INPUT -p tcp --dport 10250 -s 10.0.0.10 -j ACCEPT
iptables -A INPUT -p tcp --dport 10250 -j DROP

# SSH solo desde el bastion
iptables -A INPUT -p tcp --dport 22 -s 10.0.1.5 -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -j DROP
```

### firewalld

```bash
firewall-cmd --permanent --zone=public --remove-service=ssh
firewall-cmd --permanent --zone=public --add-rich-rule='
  rule family="ipv4" source address="10.0.1.5/32" port port="22" protocol="tcp" accept'
firewall-cmd --permanent --zone=public --add-rich-rule='
  rule family="ipv4" source address="10.0.0.0/16" port port="6443" protocol="tcp" accept'
firewall-cmd --reload
```

### nftables (alternativa moderna a iptables)

```bash
nft add rule inet filter input tcp dport 6443 ip saddr 10.0.0.0/16 accept
nft add rule inet filter input tcp dport 6443 drop
```

## 5. Security groups / firewalls del cloud provider

La segunda capa de defense-in-depth: además del firewall del OS, el cloud provider debe restringir tráfico a nivel de red virtual.

```bash
# AWS: solo permitir 6443 desde el CIDR de la VPC de administración
aws ec2 authorize-security-group-ingress \
  --group-id sg-controlplane \
  --protocol tcp --port 6443 \
  --cidr 10.0.0.0/16
```

Principio: **el control plane no debería tener ningún security group rule con origen `0.0.0.0/0`** salvo, quizás, el puerto público del Ingress/LoadBalancer de la aplicación.

## 6. Minimizar exposición vía Services

- Preferir `ClusterIP` + Ingress controller sobre `NodePort`/`LoadBalancer` directo cuando el servicio no necesita ser público.
- Evitar `hostNetwork: true` y `hostPort` en pods — bypasean el CNI y exponen el pod directamente en la interfaz del nodo.
- Restringir el rango de NodePort si se usa (`--service-node-port-range` en el API server) y no abrir todo el rango 30000-32767 en el firewall, solo los puertos realmente usados.

```yaml
# Antipatrón a evitar en el examen
apiVersion: v1
kind: Pod
spec:
  hostNetwork: true   # el pod hereda la red del nodo, sin aislamiento
  containers:
  - name: app
    ports:
    - containerPort: 8080
      hostPort: 8080   # expone el puerto directo en el nodo
```

## 7. Verificación: auditar qué está expuesto

```bash
# Puertos escuchando en el nodo, y en qué interfaz
$ ss -tulnp | grep LISTEN
tcp   LISTEN 0 4096  127.0.0.1:10257   0.0.0.0:*   users:(("kube-controller",pid=1234))
tcp   LISTEN 0 4096    0.0.0.0:6443    0.0.0.0:*   users:(("kube-apiserver",pid=1200))
```

```bash
# Escaneo externo para confirmar qué es realmente alcanzable desde fuera
$ nmap -sT -p 22,2379,2380,6443,10250,10257,10259 10.0.0.5

PORT      STATE    SERVICE
22/tcp    filtered ssh
2379/tcp  filtered etcd-client
6443/tcp  open     sun-sr-https
10250/tcp filtered unknown
```

Un puerto `filtered` (bloqueado por firewall) para todo lo que no sea 6443 desde una red externa es el resultado esperado.

```bash
# kube-bench: automatiza buena parte de estos checks contra el CIS Benchmark
$ kube-bench run --targets master,node
[INFO] 3 System Hardening
[PASS] 3.2.1 Ensure that the kubelet configuration file has permissions...
[PASS] 4.2.1 Ensure that the --anonymous-auth argument is set to false
```

## 8. SSH y acceso administrativo

- Deshabilitar login por password (`PasswordAuthentication no` en `sshd_config`), solo claves.
- `PermitRootLogin no`.
- Acceso SSH únicamente desde un bastion/jump host, nunca directo desde internet a los nodos.
- Combinar con `fail2ban` o equivalente para mitigar brute-force si el bastion mismo está expuesto.

## Resumen para el examen

1. Conocé de memoria la tabla de puertos y qué componente escucha en cada uno.
2. El firewall del OS (iptables/nftables/firewalld) es una capa **independiente** de las NetworkPolicies de Kubernetes — el examen puede pedir configurarlo directamente en el nodo.
3. kubelet mal configurado (anonymous-auth habilitado, readOnlyPort activo) es un finding clásico — memorizá los flags de `KubeletConfiguration`.
4. `ss`/`netstat` desde el nodo y `nmap` desde fuera son las herramientas de verificación esperadas.
5. Preferir endpoints privados para el control plane en clústeres managed, y jump host/bastion para SSH.

## Referencias

- Ports and Protocols (tabla oficial): https://kubernetes.io/docs/reference/networking/ports-and-protocols/
- Securing a Cluster: https://kubernetes.io/docs/tasks/administer-cluster/securing-a-cluster/
- Kubelet Configuration (v1beta1 reference): https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
- etcd Security Model: https://etcd.io/docs/v3.5/op-guide/security/
- kube-bench (CIS Benchmark automation): https://github.com/aquasecurity/kube-bench
- CIS Kubernetes Benchmark: https://www.cisecurity.org/benchmark/kubernetes
- AWS EKS — Cluster endpoint access control: https://docs.aws.amazon.com/eks/latest/userguide/cluster-endpoint.html
- GKE — Private clusters: https://cloud.google.com/kubernetes-engine/docs/how-to/private-clusters
- AKS — Private clusters: https://learn.microsoft.com/en-us/azure/aks/private-clusters
- firewalld documentation: https://firewalld.org/documentation/
- nftables wiki: https://wiki.nftables.org/
- CKS Curriculum v1.34: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf