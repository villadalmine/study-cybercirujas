# 1.4 Protect node metadata and endpoints

## Introducción

Todo nodo de un cluster Kubernetes expone superficies adicionales más allá de la API server: el **metadata service** del cloud provider (accesible por IP desde cualquier pod que comparta la red del nodo) y los **endpoints del kubelet** (y de otros componentes como kube-proxy) que corren en cada worker node. Si un atacante compromete un container, estos dos puntos son de los primeros vectores que va a probar para escalar privilegios fuera del namespace del pod: robar credenciales del cloud provider o ejecutar comandos arbitrarios vía el kubelet API sin autenticación.

Proteger "node metadata and endpoints" significa: (1) bloquear el acceso de los pods al metadata service de la nube, y (2) asegurar que los endpoints del kubelet (y otros puertos de nodo) requieran autenticación y autorización, y no estén expuestos innecesariamente en la red.

## 1. El riesgo del metadata service del cloud provider

AWS, GCP y Azure exponen en cada instancia un servicio HTTP interno (Instance Metadata Service, IMDS) en la IP link-local `169.254.169.254`. Ese endpoint entrega información de la instancia y, más crítico, **credenciales temporales del IAM role/service account asociado al nodo**.

Por defecto, un pod sin `hostNetwork: true` corre en su propio namespace de red, pero esa IP link-local sigue siendo enrutable desde adentro del pod salvo que algo lo bloquee explícitamente. Esto significa que cualquier container comprometido puede intentar leer las credenciales del nodo:

```bash
kubectl run curlpod --image=curlimages/curl --restart=Never -it -- sh
```

```
/ $ curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/
eks-node-role
/ $ curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/eks-node-role
{
  "Code" : "Success",
  "AccessKeyId" : "ASIAABCDEFGHIJKLMNOP",
  "SecretAccessKey" : "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
  "Token" : "IQoJb3JpZ2luX2VjEA...",
  "Expiration" : "2026-07-18T02:00:00Z"
}
```

Con esas credenciales, el atacante ya no está limitado por RBAC de Kubernetes: tiene los permisos IAM del nodo en la cuenta cloud (ej. leer S3, describir instancias, asumir otros roles).

### Mitigaciones

**a) Bloquear el acceso vía NetworkPolicy** (defensa a nivel del cluster):

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-cloud-metadata
  namespace: default
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 169.254.169.254/32
```

Esto requiere un CNI que implemente `NetworkPolicy` (Calico, Cilium, etc.); con el CNI por defecto de `kubenet` no tiene efecto.

**b) Forzar IMDSv2 con hop limit (AWS)**: IMDSv2 exige un token obtenido con `PUT` antes de leer metadata, lo que corta los SSRF más simples. Además, bajar el `HttpPutResponseHopLimit` a `1` bloquea las peticiones que atraviesan un salto de red extra (el bridge del container), mientras que los procesos del propio nodo (que no cruzan ese salto) siguen funcionando:

```bash
aws ec2 modify-instance-metadata-options \
  --instance-id i-0123456789abcdef0 \
  --http-tokens required \
  --http-put-response-hop-limit 1
```

**c) Usar Workload Identity en vez de credenciales de nodo**: en GKE, activar **Workload Identity** (o el mecanismo legado de *metadata concealment*) evita que las credenciales del nodo estén disponibles para los pods; en AWS, **IRSA** (IAM Roles for Service Accounts) o **Pod Identity** logran lo mismo asignando credenciales por `ServiceAccount` en vez de por nodo. En Azure, **Azure AD Workload Identity** cumple el mismo rol. Esta es la mitigación más robusta porque elimina la necesidad de exponer credenciales de nodo en primer lugar.

**d) Cuidado con `hostNetwork: true`**: un pod con `hostNetwork: true` comparte el namespace de red del nodo, así que las `NetworkPolicy` (que operan a nivel del namespace de red del pod) **no lo protegen**. Restringir quién puede crear pods `hostNetwork` es responsabilidad de **Pod Security Admission** (perfil `restricted` o `baseline`), no de NetworkPolicy.

## 2. Proteger el Kubelet API

El kubelet expone una API HTTPS en el puerto **10250** en cada nodo. Versiones antiguas también tenían un puerto de solo lectura **sin autenticación** en el **10255**, ya eliminado en versiones actuales pero todavía mencionado en el CIS Benchmark. Un kubelet mal configurado permite, sin credenciales válidas, listar pods, leer logs y hasta ejecutar comandos dentro de containers (`exec`/`run`), lo que equivale a code execution en el nodo.

Verificar la configuración activa del kubelet en un nodo:

```bash
ps -ef | grep kubelet
```

```
root  2431  1  0 Jul16 ?  00:12:34 /usr/bin/kubelet --config=/var/lib/kubelet/config.yaml \
  --kubeconfig=/etc/kubernetes/kubelet.conf --network-plugin=cni ...
```

```bash
cat /var/lib/kubelet/config.yaml
```

Configuración correcta (autenticación por webhook, sin acceso anónimo, autorización delegada al API server):

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
```

Probar si el kubelet acepta acceso anónimo (esto es lo que un atacante — o vos en un lab de práctica — probaría):

```bash
curl -sk https://<node-ip>:10250/pods
```

- Si devuelve el JSON con la lista de pods sin haber mandado ningún token → `anonymous-auth` está habilitado, vulnerabilidad grave.
- Si devuelve `Unauthorized` → está bien configurado.

Con `anonymous.enabled: false` y `authorization.mode: Webhook`, cualquier request necesita un token válido (`Authorization: Bearer <token>`) que el kubelet valida contra la API server vía `SubjectAccessReview`, respetando RBAC.

**Restricción de red adicional (defensa en profundidad):** aunque el kubelet esté bien autenticado, conviene que el puerto 10250 solo sea alcanzable desde la red del control plane (security groups / firewall rules a nivel de infraestructura), no desde internet ni desde subredes de pods de otros tenants.

## 3. Otros endpoints de nodo a tener en cuenta

- **kube-proxy**: expone métricas en `10249` y un healthz en `10256`, sin autenticación por diseño. No deberían quedar accesibles fuera del nodo/cluster.
- **NodePort services** (rango `30000-32767`): cada NodePort abre un puerto en *todos* los nodos, sea o no ese nodo el que corre el pod destino. Minimizar su uso (preferir `ClusterIP` + `Ingress`) reduce superficie expuesta — esto conecta con el ítem 1.3 del curriculum (Ingress con controles de seguridad).
- **Puerto de métricas del API server / etcd**, aunque cubiertos más específicamente en 1.2 (CIS Benchmark), forman parte del mismo principio: minimizar y autenticar cada endpoint expuesto por un componente de control plane o de nodo.

Principio general para todos estos endpoints: **autenticación + autorización a nivel de aplicación**, y **restricción de red a nivel de infraestructura** (firewall/security groups/NetworkPolicy) como capa adicional — nunca confiar en una sola de las dos.

## Referencias

- CNCF, *CKS Curriculum v1.34*: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes docs — Kubelet authentication/authorization: https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/
- Kubernetes docs — Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Kubernetes docs — Pod Security Admission: https://kubernetes.io/docs/concepts/security/pod-security-admission/
- Kubernetes docs — Kubelet configuration (KubeletConfiguration): https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
- AWS docs — Configuring the instance metadata service (IMDSv2): https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html
- AWS docs — IAM roles for service accounts (IRSA): https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html
- GCP docs — GKE Workload Identity: https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity
- Azure docs — Azure AD Workload Identity: https://azure.github.io/azure-workload-identity/docs/
- CIS Kubernetes Benchmark: https://www.cisecurity.org/benchmark/kubernetes