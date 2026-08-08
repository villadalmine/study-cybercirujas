# KCSA 1.2 — Cloud Provider and Infrastructure Security

**Dominio:** Overview of Cloud Native Security · **Peso en el examen:** 2.33% · **Nivel:** Avanzado (SRE / Arquitecto de Plataforma)

---

## 1. El problema de arquitectura

En el modelo de las 4Cs (Cloud → Cluster → Container → Code), la capa **Cloud** es la única cuya compromiso es irrecuperable desde el interior de Kubernetes. Cada control de Kubernetes que estudiarás más adelante — RBAC, NetworkPolicy, Pod Security Standards, control de admisión — es aplicado por procesos que se ejecutan *sobre* infraestructura que no construiste y que, en un cluster administrado, ni siquiera puedes ver. Si un atacante toma control del rol de IAM del nodo, el disco de etcd o la tabla de rutas de la VPC, ninguno de esos controles se aplica a él.

El modo de falla en producción no es exótico. Casi siempre es la misma cadena de tres pasos:

```
RCE / SSRF in an application pod
        ↓
reach the link-local metadata endpoint 169.254.169.254
        ↓
mint cloud credentials for the NODE's instance profile / service account
        ↓
that role can read S3/GCS, describe the whole VPC, and frequently
call eks:DescribeCluster + sts:AssumeRole on other roles
        ↓
cluster-admin, or lateral movement out of Kubernetes entirely
```

Es por esto que "Cloud Provider and Infrastructure Security" es un objetivo de examen distinto en lugar de un apéndice del endurecimiento de clusters. Concretamente, el arquitecto de plataforma es dueño de cinco decisiones en esta capa:

| # | Decisión | Qué previene | Falla si se omite |
|---|---|---|---|
| 1 | Postura del servicio de metadatos (IMDSv2 + hop limit / ocultamiento de metadatos) | Robo de credenciales Pod → nodo | Un SSRF = compromiso de la cuenta de cloud |
| 2 | Federación de identidad de carga de trabajo en lugar de roles de nodo | Credenciales demasiado amplias y de larga duración | Cada pod hereda el poder de IAM del nodo |
| 3 | Exposición de red del control plane (endpoint privado, redes autorizadas) | `6443` y `2379` expuestos a Internet | Credential stuffing / robo de datos de etcd |
| 4 | Cifrado en reposo con un KMS externo (envelope encryption) | Secrets legibles desde un snapshot de etcd o imagen de disco | Robo de respaldo = Secrets en texto plano |
| 5 | Integridad de imagen de nodo y arranque (OS mínimo, Secure Boot, vTPM) | Implantes persistentes a nivel de nodo | Rootkit sobrevive a reinicios y parches |

Todo lo que sigue es la mecánica de esas cinco decisiones.

---

## 2. El modelo de responsabilidad compartida, establecido con precisión

"Responsabilidad compartida" es una frase de marketing hasta que la conviertes en un límite que nombra componentes *específicos*. Para Kubernetes, el límite se mueve dependiendo de cómo lo consumas.

| Componente | Self-managed (kubeadm sobre IaaS) | Control plane administrado (EKS / GKE Standard / AKS) | Nodos totalmente administrados (GKE Autopilot, EKS Fargate) |
|---|---|---|---|
| Hipervisor / firmware | Proveedor | Proveedor | Proveedor |
| Entorno físico + red | Proveedor | Proveedor | Proveedor |
| Proceso etcd, respaldos, claves de cifrado | **Tú** | Proveedor (tú eliges la clave KMS) | Proveedor (tú eliges la clave KMS) |
| Flags de `kube-apiserver` (`--audit-policy-file`, `--encryption-provider-config`) | **Tú** | Proveedor — expuesto solo como una superficie de API estrecha | Proveedor |
| Parcheo del control plane | **Tú** | Proveedor (tú eliges la ventana/versión) | Proveedor |
| CVEs de kernel y OS del nodo | **Tú** | **Tú** (el proveedor publica imágenes) | Proveedor |
| Configuración de kubelet | **Tú** | **Tú** (vía plantilla de lanzamiento / configuración de nodo) | Proveedor |
| CNI, CSI, ingress | **Tú** | **Tú** (a menos que uses add-ons del proveedor) | Parcialmente el proveedor |
| RBAC, NetworkPolicy, admisión | **Tú** | **Tú** | **Tú** |
| Vinculaciones de identidad de carga de trabajo | **Tú** | **Tú** | **Tú** |
| Imágenes de contenedores y código | **Tú** | **Tú** | **Tú** |

**La trampa para los arquitectos y para el examen:** en un control plane administrado no puedes ejecutar `ps aux` en el servidor de API, por lo que no puedes verificar un control CIS como "`--anonymous-auth=false`" leyendo la línea del proceso. Lo verificas a través de la documentación del proveedor, la API del proveedor y sondas *conductuales* (Sección 10). Un control que no puedes observar es un control en el que estás confiando, no aplicando — documenta esa confianza explícitamente en tu modelo de amenazas.

---

## 3. El servicio de metadatos de la instancia: la ruta principal de escalación

### 3.1 Por qué `169.254.169.254` es peligroso

Cada nube principal expone un endpoint HTTP sin autenticación en la dirección de enlace local `169.254.169.254`. Es accesible desde cualquier proceso en la instancia, incluyendo cualquier contenedor, porque por defecto los contenedores comparten la ruta de enrutamiento del nodo hacia el espacio link-local. Sirve, entre otras cosas, **credenciales de corta duración para la identidad de la instancia**.

| Proveedor | Endpoint | Encabezado requerido | Ruta de credenciales |
|---|---|---|---|
| AWS | `http://169.254.169.254/latest/meta-data/` | IMDSv2: `X-aws-ec2-metadata-token` | `/latest/meta-data/iam/security-credentials/<role>` |
| GCP | `http://metadata.google.internal/computeMetadata/v1/` | `Metadata-Flavor: Google` | `/instance/service-accounts/default/token` |
| Azure | `http://169.254.169.254/metadata/instance?api-version=2021-02-01` | `Metadata: true` | `/metadata/identity/oauth2/token?resource=...` |

GCP y Azure siempre han requerido un encabezado no reenviable, lo que incidentalmente frustra el SSRF simple (un navegador o un cliente HTTP ingenuo no lo agregará). **AWS IMDSv1 no requería ningún encabezado en absoluto** — un solo `GET` desde un extractor de URL vulnerable era suficiente. IMDSv2 soluciona esto requiriendo un `PUT` para obtener primero un token de sesión, lo que la mayoría de las primitivas de SSRF no pueden realizar.

### 3.2 Demostrando el ataque, luego la solución

En un cluster donde el grupo de nodos todavía permite IMDSv1 (`http_tokens = optional`):

```console
$ kubectl run imds-probe --rm -it --restart=Never \
    --image=curlimages/curl:8.8.0 -- sh
If you don't see a command prompt, try pressing enter.
/ $ curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/
eksctl-prod-euw1-nodegroup-ng-sys-NodeInstanceRole-1F8H2J3K4L5M6
/ $ curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/eksctl-prod-euw1-nodegroup-ng-sys-NodeInstanceRole-1F8H2J3K4L5M6
{
  "Code" : "Success",
  "LastUpdated" : "2026-08-06T09:12:44Z",
  "Type" : "AWS-HMAC",
  "AccessKeyId" : "ASIA2XQ7EXAMPLE4KZ9",
  "SecretAccessKey" : "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
  "Token" : "IQoJb3JpZ2luX2VjEJr//////////wEaCWV1LXdlc3QtMSJH...",
  "Expiration" : "2026-08-06T15:38:11Z"
}
```

Esas credenciales llevan `AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryReadOnly`, `AmazonEKS_CNI_Policy` y — en la mayoría de los clusters reales — lo que sea que el equipo de plataforma haya acoplado para el cluster-autoscaler, external-dns o el controlador CSI de EBS. La política de CNI por sí sola otorga `ec2:CreateNetworkInterface`, `ec2:AttachNetworkInterface` y `ec2:ModifyNetworkInterfaceAttribute`, lo cual es suficiente para moverse lateralmente dentro de la VPC.

**La solución tiene dos partes independientes, y necesitas ambas.**

`http_tokens = required` detiene el acceso de estilo SSRF. `http_put_response_hop_limit = 1` detiene el acceso desde **pods**: un pod en su propio namespace de red llega al espacio link-local a través del host que actúa como enrutador, lo que decrementa el TTL de IP. Con un límite de saltos (hop limit) de 1, la respuesta nunca regresa.

```hcl
# terraform/eks-nodegroup.tf
data "aws_ssm_parameter" "bottlerocket_ami" {
  name = "/aws/service/bottlerocket/aws-k8s-1.31/x86_64/latest/image_id"
}

resource "aws_launch_template" "eks_nodes" {
  name_prefix   = "prod-euw1-ng-sys-"
  image_id      = data.aws_ssm_parameter.bottlerocket_ami.value
  instance_type = "m6i.xlarge"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only — kills SSRF
    http_put_response_hop_limit = 1          # kills pod access (extra hop)
    instance_metadata_tags      = "disabled"
  }

  # Bottlerocket uses two volumes: xvda = immutable OS, xvdb = container data
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 4
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = aws_kms_key.ebs.arn
      delete_on_termination = true
    }
  }

  block_device_mappings {
    device_name = "/dev/xvdb"
    ebs {
      volume_size           = 100
      volume_type           = "gp3"
      throughput            = 250
      iops                  = 3000
      encrypted             = true
      kms_key_id            = aws_kms_key.ebs.arn
      delete_on_termination = true
    }
  }

  monitoring { enabled = true }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name                                        = "prod-euw1-ng-sys"
      "kubernetes.io/cluster/prod-euw1"           = "owned"
      "k8s.io/cluster-autoscaler/enabled"         = "true"
    }
  }

  lifecycle { create_before_destroy = true }
}

resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.prod.name
  node_group_name = "ng-sys"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids   # private subnets only

  launch_template {
    id      = aws_launch_template.eks_nodes.id
    version = aws_launch_template.eks_nodes.latest_version
  }

  scaling_config {
    desired_size = 3
    min_size     = 3
    max_size     = 6
  }

  update_config { max_unavailable_percentage = 33 }

  labels = {
    "node-restriction.kubernetes.io/pool" = "system"
  }

  taint {
    key    = "dedicated"
    value  = "system"
    effect = "NO_SCHEDULE"
  }
}
```

Verificación después del reemplazo gradual del grupo de nodos:

```console
$ aws ec2 describe-instances \
    --filters "Name=tag:eks:nodegroup-name,Values=ng-sys" \
    --query 'Reservations[].Instances[].{Id:InstanceId,Tokens:MetadataOptions.HttpTokens,Hops:MetadataOptions.HttpPutResponseHopLimit}' \
    --output table
-------------------------------------------------
|               DescribeInstances               |
+------+----------------------+-----------------+
| Hops |          Id          |     Tokens      |
+------+----------------------+-----------------+
|  1   |  i-0a4b8c1d2e3f4a5b6 |  required       |
|  1   |  i-0c7d9e2f3a4b5c6d7 |  required       |
|  1   |  i-0e1f2a3b4c5d6e7f8 |  required       |
+------+----------------------+-----------------+

$ kubectl run imds-probe --rm -it --restart=Never \
    --image=curlimages/curl:8.8.0 -- \
    sh -c 'curl -s --connect-timeout 4 -X PUT \
      "http://169.254.169.254/latest/api/token" \
      -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"; echo "curl_exit=$?"'
curl_exit=28
pod "imds-probe" deleted
```

`curl_exit=28` es `CURLE_OPERATION_TIMEDOUT` — el pod no puede llegar a IMDS de ninguna manera. Ese es el estado deseado.

> **Advertencia que debes conocer:** los pods con `hostNetwork: true` comparten el namespace de red del nodo, por lo que no hay un salto adicional y *aún pueden* alcanzar IMDS. Esto es intencional (el CNI de AWS VPC y kube-proxy lo necesitan) y es exactamente la razón por la cual hostNetwork debe estar restringido por Pod Security Admission `restricted`/`baseline` y por políticas de admisión.

### 3.3 GKE: ocultamiento de metadatos mediante Workload Identity

GKE no utiliza un límite de saltos. Habilitar Workload Identity en un node pool despliega el DaemonSet `gke-metadata-server`, el cual intercepta el tráfico del pod hacia `169.254.169.254` y sirve una vista *filtrada*: se rechazan los atributos vinculados al nodo como `kube-env` (que históricamente contenía credenciales de arranque del nodo), y las solicitudes de tokens son respondidas solo con la cuenta de servicio de Google federada a la ServiceAccount de Kubernetes de ese pod.

```console
$ gcloud container clusters create prod-euw1 \
    --region europe-west1 \
    --workload-pool=my-project-1234.svc.id.goog \
    --enable-private-nodes \
    --enable-private-endpoint \
    --master-ipv4-cidr 172.16.0.32/28 \
    --enable-master-authorized-networks \
    --master-authorized-networks 10.20.0.0/24 \
    --enable-shielded-nodes \
    --shielded-secure-boot \
    --shielded-integrity-monitoring \
    --image-type COS_CONTAINERD \
    --enable-network-policy \
    --metadata disable-legacy-endpoints=true \
    --release-channel regular

$ kubectl -n kube-system get ds gke-metadata-server
NAME                  DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   AGE
gke-metadata-server   3         3         3       3            3           6m14s

$ kubectl run md-probe --rm -it --restart=Never --image=curlimages/curl:8.8.0 -- \
    sh -c 'curl -s -w "\nhttp=%{http_code}\n" -H "Metadata-Flavor: Google" \
      http://metadata.google.internal/computeMetadata/v1/instance/attributes/kube-env'
This metadata endpoint is concealed.
http=403
pod "md-probe" deleted
```

Sin una vinculación de Workload Identity, el endpoint de tokens falla en modo cerrado:

```console
/ $ curl -s -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token
{"error":"unable to generate token","error_description":"Unable to generate access token; IAM returned 403 Forbidden: The caller does not have permission"}
```

### 3.4 Comparativa de los mecanismos de bloqueo disponibles

| Mecanismo | Capa | ¿Bloquea pods hostNetwork? | ¿Sobrevive al reemplazo de nodos? | Costo operativo | Veredicto |
|---|---|---|---|---|---|
| IMDSv2 `http_tokens=required` | Cloud API | No (no es su función) | Sí (launch template) | Muy bajo; algunos SDKs antiguos fallan | **Línea base obligatoria** |
| `http_put_response_hop_limit = 1` | IP TTL | No | Sí (launch template) | Bajo; rompe herramientas hostNetwork que esperan IMDS | **Obligatorio en AWS** |
| Servidor de metadatos GKE Workload Identity | Agente de nodo | Sí (oculto para todos los pods en el pool) | Sí (propiedad del node pool) | Bajo | **Obligatorio en GKE** |
| Denegación de egress en `NetworkPolicy` a `169.254.169.254/32` | CNI | Depende del CNI | Sí | Medio — requiere una línea base de egress denegada por defecto | Solo defensa en profundidad |
| `iptables -I FORWARD -d 169.254.169.254 -j DROP` en el nodo | Firewall del host | No (`hostNetwork` usa `OUTPUT`) | **No** — se pierde en nuevos nodos a menos que esté en user-data | Alto, frágil | Solución alternativa heredada |
| Variable de entorno `AWS_EC2_METADATA_DISABLED=true` | Cliente SDK | No | n/a | n/a | **No es un control de seguridad** — controlado por el atacante |

Una versión con NetworkPolicy, para la capa de defensa en profundidad:

```yaml
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  namespace: payments
spec:
  podSelector: {}
  policyTypes:
    - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-except-metadata
  namespace: payments
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    # DNS to CoreDNS only
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
    # Everything else on the internet, with link-local and RFC1918 carved out
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 169.254.0.0/16     # all link-local: IMDS, EKS Pod Identity agent
              - 10.0.0.0/8
              - 172.16.0.0/12
              - 192.168.0.0/16
      ports:
        - protocol: TCP
          port: 443
```

> Ten en cuenta que `except` cubre `169.254.0.0/16`, no solo `.169.254`. AWS también sirve credenciales de EKS Pod Identity en `169.254.170.23` y credenciales de tareas de ECS en `169.254.170.2`; GCP publica `metadata.google.internal` como `169.254.169.254`. Si tus cargas de trabajo usan legítimamente EKS Pod Identity, debes volver a permitir `169.254.170.23/32` explícitamente.

---

## 4. Identidad de carga de trabajo: eliminando el rol del nodo del radio de impacto

Incluso con IMDS asegurado, la pregunta persiste: ¿cómo obtiene credenciales un pod que legítimamente necesita acceso a S3? Las respuestas incorrectas son (a) heredar el rol del nodo, (b) montar una clave de acceso estática en un Secret. Ambas son de larga duración y compartidas.

La respuesta correcta en todas partes es la misma primitiva: **el cluster actúa como un proveedor de identidad OIDC, el pod recibe un token de ServiceAccount proyectado de corta duración, y el sistema de IAM de la nube intercambia ese token por credenciales de la nube delimitadas a esa KSA específica.**

```
ServiceAccountTokenVolumeProjection
  → JWT signed by the cluster's OIDC signing key
    (aud=sts.amazonaws.com, sub=system:serviceaccount:payments:ledger, exp=1h)
      → provider STS validates via the cluster's public JWKS
        → returns credentials for exactly one IAM role
```

| Característica | EKS IRSA | EKS Pod Identity | GKE Workload Identity | Azure Workload Identity |
|---|---|---|---|---|
| Mecanismo | Federación OIDC + `sts:AssumeRoleWithWebIdentity` | DaemonSet del agente en `169.254.170.23` | Servidor de metadatos GKE + `iam.gke.io` | Federación OIDC + MSAL |
| Configuración de IdP por cluster | Sí — un proveedor OIDC por cluster | No | No (workload pool por proyecto) | Sí — emisor OIDC por cluster |
| Escalabilidad de la política de confianza | Deficiente: la política de confianza del rol nombra el ARN OIDC de cada cluster | Buena: API de asociación, rol independiente del cluster | Buena | Media |
| Roles entre cuentas (cross-account) | Sí, complejo | Sí, nativo | n/a | n/a |
| Vinculación | Anotación de Pod en la **ServiceAccount** | `aws eks create-pod-identity-association` | Anotación en KSA + vinculación de política IAM | Anotación + etiqueta en el pod |
| Soporte en SDK | Universal (todos los SDKs modernos de AWS) | Requiere versiones recientes del SDK | Universal (ADC) | Requiere SDK de Azure Identity |
| Funciona en Fargate | Sí | No | n/a | n/a |
| Duración del token | 1 h por defecto, `expirationSeconds` ajustable | ~15 min, auto-rotado | 1 h | 1 h |
| Cuándo elegir | Fargate, cross-account, SDKs antiguos | Nuevos clusters basados en EC2, muchos clusters comparten roles | Cualquier GKE | Cualquier AKS |

### 4.1 EKS IRSA, de extremo a extremo

```console
$ aws eks describe-cluster --name prod-euw1 \
    --query 'cluster.identity.oidc.issuer' --output text
https://oidc.eks.eu-west-1.amazonaws.com/id/9C2A4B6D8E0F1A3B5C7D9E1F2A4B6C8D

$ eksctl utils associate-iam-oidc-provider --cluster prod-euw1 --approve
2026-08-06 09:31:02 [ℹ]  will create IAM Open ID Connect provider for cluster "prod-euw1"
2026-08-06 09:31:03 [✔]  created IAM Open ID Connect provider for cluster "prod-euw1"
```

La política de confianza del rol de IAM es el límite de seguridad — observa la condición `sub`, que es la que fija la credencial a un namespace *y* a una ServiceAccount específica:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowLedgerKSAOnly",
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::123456789012:oidc-provider/oidc.eks.eu-west-1.amazonaws.com/id/9C2A4B6D8E0F1A3B5C7D9E1F2A4B6C8D"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.eu-west-1.amazonaws.com/id/9C2A4B6D8E0F1A3B5C7D9E1F2A4B6C8D:aud": "sts.amazonaws.com",
          "oidc.eks.eu-west-1.amazonaws.com/id/9C2A4B6D8E0F1A3B5C7D9E1F2A4B6C8D:sub": "system:serviceaccount:payments:ledger"
        }
      }
    }
  ]
}
```

> **Punto crítico de revisión:** usar `StringLike` con `...:sub": "system:serviceaccount:*"` — un error real y común — permite que *cualquier* ServiceAccount en *cualquier* namespace de ese cluster asuma el rol. Usa siempre `StringEquals`, siempre totalmente calificado. De la misma manera, omitir la condición `:aud` permite que un token emitido para una audiencia diferente pueda ser reutilizado.

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ledger
  namespace: payments
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/prod-euw1-payments-ledger
    eks.amazonaws.com/sts-regional-endpoints: "true"
    eks.amazonaws.com/token-expiration: "3600"
automountServiceAccountToken: false      # opt in per pod, not per SA
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ledger
  namespace: payments
  labels:
    app.kubernetes.io/name: ledger
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: ledger
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ledger
    spec:
      serviceAccountName: ledger
      automountServiceAccountToken: true
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        fsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: ledger
          image: 123456789012.dkr.ecr.eu-west-1.amazonaws.com/ledger@sha256:5f4d3c2b1a0998877665544332211ffeeddccbbaa99887766554433221100ffee
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            privileged: false
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 200m
              memory: 256Mi
            limits:
              cpu: "1"
              memory: 512Mi
          volumeMounts:
            - name: tmp
              mountPath: /tmp
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            periodSeconds: 5
      volumes:
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
      nodeSelector:
        kubernetes.io/os: linux
```

El webhook `eks-pod-identity-webhook` muta el pod en el momento de la admisión. Confirma que se aplicó correctamente:

```console
$ kubectl -n payments get pod -l app.kubernetes.io/name=ledger \
    -o jsonpath='{.items[0].spec.containers[0].env}' | jq
[
  {
    "name": "AWS_STS_REGIONAL_ENDPOINTS",
    "value": "regional"
  },
  {
    "name": "AWS_DEFAULT_REGION",
    "value": "eu-west-1"
  },
  {
    "name": "AWS_REGION",
    "value": "eu-west-1"
  },
  {
    "name": "AWS_ROLE_ARN",
    "value": "arn:aws:iam::123456789012:role/prod-euw1-payments-ledger"
  },
  {
    "name": "AWS_WEB_IDENTITY_TOKEN_FILE",
    "value": "/var/run/secrets/eks.amazonaws.com/serviceaccount/token"
  }
]

$ kubectl -n payments exec deploy/ledger -- \
    aws sts get-caller-identity
{
    "UserId": "AROA2XQ7EXAMPLE9J3K:botocore-session-1785312904",
    "Account": "123456789012",
    "Arn": "arn:aws:sts::123456789012:assumed-role/prod-euw1-payments-ledger/botocore-session-1785312904"
}
```

El ARN de rol asumido — no el rol de la instancia del nodo — es la prueba de que el acoplamiento funciona.

### 4.2 GKE Workload Identity

```console
$ gcloud iam service-accounts create ledger-gsa --project my-project-1234

$ gcloud projects add-iam-policy-binding my-project-1234 \
    --member "serviceAccount:ledger-gsa@my-project-1234.iam.gserviceaccount.com" \
    --role "roles/storage.objectViewer" \
    --condition='expression=resource.name.startsWith("projects/_/buckets/ledger-prod"),title=ledger-bucket-only'

$ gcloud iam service-accounts add-iam-policy-binding \
    ledger-gsa@my-project-1234.iam.gserviceaccount.com \
    --role roles/iam.workloadIdentityUser \
    --member "serviceAccount:my-project-1234.svc.id.goog[payments/ledger]"
Updated IAM policy for serviceAccount [ledger-gsa@my-project-1234.iam.gserviceaccount.com].
```

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ledger
  namespace: payments
  annotations:
    iam.gke.io/gcp-service-account: ledger-gsa@my-project-1234.iam.gserviceaccount.com
```

```console
$ kubectl -n payments exec deploy/ledger -- \
    curl -s -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email
ledger-gsa@my-project-1234.iam.gserviceaccount.com
```

### 4.3 Azure Workload Identity

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ledger
  namespace: payments
  annotations:
    azure.workload.identity/client-id: 3f9c1a2b-4d5e-6f70-8192-a3b4c5d6e7f8
    azure.workload.identity/tenant-id: 7a8b9c0d-1e2f-3a4b-5c6d-7e8f9a0b1c2d
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ledger
  namespace: payments
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: ledger
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ledger
        azure.workload.identity/use: "true"   # REQUIRED: triggers the mutating webhook
    spec:
      serviceAccountName: ledger
      containers:
        - name: ledger
          image: myacr.azurecr.io/ledger@sha256:5f4d3c2b1a0998877665544332211ffeeddccbbaa99887766554433221100ffee
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
```

La credencial federada se crea en el lado de Azure y fija el mismo `sub`:

```console
$ az identity federated-credential create \
    --name ledger-federated \
    --identity-name ledger-mi \
    --resource-group rg-prod \
    --issuer "$(az aks show -g rg-prod -n prod-euw1 --query oidcIssuerProfile.issuerUrl -o tsv)" \
    --subject "system:serviceaccount:payments:ledger" \
    --audience api://AzureADTokenExchange
```

**En las tres nubes, el rol del nodo debe reducirse al mínimo indispensable requerido para unirse al cluster y descargar imágenes.** Cualquier permiso adicional en el rol del nodo es un permiso que has otorgado a cada carga de trabajo que pueda alcanzar IMDS.

---

## 5. Exposición de red del control plane

### 5.1 El inventario de puertos que se espera que conozcas

| Componente | Puerto | Protocolo | Dirección | Quién debe alcanzarlo |
|---|---|---|---|---|
| `kube-apiserver` | 6443 (443 en administrado) | TCP/TLS | Entrante hacia CP | Administradores, nodos, clientes internos del cluster |
| Cliente `etcd` | 2379 | TCP/mTLS | Interno del CP | Solo el servidor de API |
| Par (peer) `etcd` | 2380 | TCP/mTLS | Interno del CP | Solo otros miembros de etcd |
| `kube-scheduler` | 10259 | HTTPS | localhost | Métricas/salud (puerto inseguro 10251 eliminado en v1.23) |
| `kube-controller-manager` | 10257 | HTTPS | localhost | Métricas/salud (10252 eliminado en v1.23) |
| API de `kubelet` | 10250 | HTTPS | Entrante hacia el nodo | Servidor de API, metrics-server |
| Lectura de `kubelet` (read-only) | 10255 | **HTTP, sin autenticación** | — | **Nadie. Debe ser 0.** |
| healthz de `kube-proxy` | 10256 | HTTP | Local del nodo | Balanceadores de carga |
| Rango de NodePort | 30000–32767 | TCP/UDP | Entrante hacia el nodo | Solo si se usan Servicios de tipo NodePort |

Un `etcd/2379` alcanzable desde cualquier lugar que no sea el servidor de API implica un compromiso total del cluster: etcd no tiene RBAC ni autorización por clave. Quien posea un certificado de cliente válido lee y escribe cada objeto, incluyendo cada Secret.

### 5.2 Clusters privados: los tres modelos de exposición

| Modelo | Endpoint del control-plane | Egress del nodo | Ruta de acceso de administración | Comparativa |
|---|---|---|---|---|
| Endpoint público, abierto | Internet, `0.0.0.0/0` | Gateway NAT | `kubectl` directo | El más simple. La autenticación es el *único* control. Susceptible a fuerza bruta y escaneos. No usar en producción. |
| Endpoint público + redes autorizadas | Internet, restringido por CIDR | Gateway NAT | `kubectl` desde CIDRs de oficina/VPN | Buen equilibrio. Se rompe con IPs dinámicas de runners de CI; requiere gestión de lista de permitidos. |
| Solo endpoint privado | Solo interno de VPC | NAT o totalmente privado (endpoints VPC) | Bastión, VPN o proxy administrado por el proveedor | El más sólido. CI/CD debe ejecutarse dentro de la VPC; funciones de consola del proveedor pueden degradarse; acceso de emergencia es más complejo. |

```console
$ aws eks update-cluster-config --name prod-euw1 \
    --resources-vpc-config \
      endpointPublicAccess=true,endpointPrivateAccess=true,publicAccessCidrs="203.0.113.0/24,198.51.100.7/32"
{
    "update": {
        "id": "b91f4e7a-2c3d-4e5f-6a7b-8c9d0e1f2a3b",
        "status": "InProgress",
        "type": "EndpointAccessUpdate",
        "params": [
            {"type": "EndpointPublicAccess",  "value": "true"},
            {"type": "EndpointPrivateAccess", "value": "true"},
            {"type": "PublicAccessCidrs",     "value": "[\"203.0.113.0/24\",\"198.51.100.7/32\"]"}
        ],
        "createdAt": "2026-08-06T10:02:11.442000+02:00"
    }
}

$ aws eks describe-cluster --name prod-euw1 \
    --query 'cluster.resourcesVpcConfig.{Pub:endpointPublicAccess,Priv:endpointPrivateAccess,Cidrs:publicAccessCidrs}'
{
    "Pub": true,
    "Priv": true,
    "Cidrs": [
        "198.51.100.7/32",
        "203.0.113.0/24"
    ]
}
```

Verificación conductual desde fuera de la lista de permitidos — esta es la prueba que realmente demuestra el funcionamiento del control:

```console
$ curl -sk --connect-timeout 5 https://9C2A4B6D8E0F1A3B5C7D9E1F2A4B6C8D.gr7.eu-west-1.eks.amazonaws.com/version
curl: (28) Failed to connect to 9C2A4B6D8E0F1A3B5C7D9E1F2A4B6C8D.gr7.eu-west-1.eks.amazonaws.com port 443 after 5001 ms: Timeout was reached
```

Y desde una dirección permitida, confirma que el acceso anónimo sigue siendo rechazado:

```console
$ curl -sk https://9C2A4B6D8E0F1A3B5C7D9E1F2A4B6C8D.gr7.eu-west-1.eks.amazonaws.com/api/v1/namespaces/kube-system/secrets | jq
{
  "kind": "Status",
  "apiVersion": "v1",
  "metadata": {},
  "status": "Failure",
  "message": "secrets is forbidden: User \"system:anonymous\" cannot list resource \"secrets\" in API group \"\" in the namespace \"kube-system\"",
  "reason": "Forbidden",
  "details": {"kind": "secrets"},
  "code": 403
}
```

Un `200` aquí significaría que existen vinculaciones de RBAC anónimas — una incidencia P1 inmediata.

### 5.3 Cortafuegos a nivel de nodo (clusters autogestionados)

Para un cluster de kubeadm sobre IaaS, las reglas de grupos de seguridad / firewall son tu responsabilidad. Conjunto mínimo viable:

```hcl
resource "aws_security_group_rule" "cp_api_from_nodes" {
  security_group_id        = aws_security_group.control_plane.id
  type                     = "ingress"
  from_port                = 6443
  to_port                  = 6443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.nodes.id
  description              = "kubelet/kube-proxy -> kube-apiserver"
}

resource "aws_security_group_rule" "etcd_peer" {
  security_group_id        = aws_security_group.control_plane.id
  type                     = "ingress"
  from_port                = 2379
  to_port                  = 2380
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.control_plane.id  # CP members only
  description              = "etcd client+peer, control plane only"
}

resource "aws_security_group_rule" "kubelet_from_cp" {
  security_group_id        = aws_security_group.nodes.id
  type                     = "ingress"
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.control_plane.id
  description              = "kube-apiserver -> kubelet (exec, logs, port-forward)"
}
```

Observa que **no hay regla para 10255**. Ese puerto simplemente no debe estar escuchando.

---

## 6. Endurecimiento de la infraestructura del nodo

### 6.1 Elección del sistema operativo del nodo

| OS | Gestor de paquetes | Shell en nodo | Root FS | Integridad | Modelo de actualización | Ideal para |
|---|---|---|---|---|---|---|
| Amazon Linux 2023 | `dnf` | Sí | Lectura-escritura | — | Reemplazo de AMI o in situ | Compatibilidad con agentes/DaemonSets |
| Bottlerocket | **Ninguno** | **No** (solo vía contenedor `admin`) | **Solo lectura, dm-verity** | dm-verity + Secure Boot opcional | Intercambio de imagen atómico A/B, rollback | Nodos EKS/ECS de máxima seguridad |
| Container-Optimized OS (COS) | Ninguno | Limitada | **Solo lectura** | Arranque verificado + monitoreo de integridad | Actualización automática con node pool | Valor por defecto en GKE |
| Flatcar Container Linux | Ninguno | Sí | Solo lectura `/usr` | — | Atómico A/B | Autogestionado, agnóstico a la nube |
| Ubuntu (variantes GKE/AKS/EKS) | `apt` | Sí | Lectura-escritura | — | In situ | Requiere módulos de kernel personalizados, controladores de GPU |
| Azure Linux (Mariner) | `tdnf` | Sí | Lectura-escritura | — | In situ | Nativo de AKS, superficie reducida |

Bottlerocket es la opción por defecto más sólida en AWS por una razón estructural: el nodo no tiene shell, no tiene gestor de paquetes y no tiene un root escribible, por lo que el kit de herramientas estándar posterior a la explotación (`curl | sh`, instalar una unidad de persistencia, soltar un binario en `/usr/local/bin`) no funciona. El acceso administrativo requiere habilitar deliberadamente el contenedor host `admin`, lo cual representa en sí mismo una llamada de API auditable.

```console
$ kubectl get nodes -o custom-columns=\
NAME:.metadata.name,OS:.status.nodeInfo.osImage,KERNEL:.status.nodeInfo.kernelVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion,KUBELET:.status.nodeInfo.kubeletVersion
NAME                                        OS                          KERNEL           RUNTIME                  KUBELET
ip-10-40-12-31.eu-west-1.compute.internal   Bottlerocket OS 1.29.0      6.1.115          containerd://1.7.24+bottlerocket   v1.31.4-eks-2d5f260
ip-10-40-13-88.eu-west-1.compute.internal   Bottlerocket OS 1.29.0      6.1.115          containerd://1.7.24+bottlerocket   v1.31.4-eks-2d5f260
ip-10-40-14-19.eu-west-1.compute.internal   Bottlerocket OS 1.29.0      6.1.115          containerd://1.7.24+bottlerocket   v1.31.4-eks-2d5f260
```

### 6.2 Configuración endurecida de kubelet

El kubelet es infraestructura, no carga de trabajo, y es el componente más atacado en el nodo. Un kubelet con `anonymous.enabled: true` y `authorization.mode: AlwaysAllow` otorga a cualquiera que alcance el puerto 10250 la capacidad de hacer `exec` en cada contenedor de ese nodo — sin que intervenga el RBAC de Kubernetes.

```yaml
# /var/lib/kubelet/config.yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration

authentication:
  anonymous:
    enabled: false                 # CIS 4.2.1
  webhook:
    enabled: true                  # delegate authn to the API server
    cacheTTL: 2m0s
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt   # CIS 4.2.3

authorization:
  mode: Webhook                    # CIS 4.2.2 — never AlwaysAllow
  webhook:
    cacheAuthorizedTTL: 5m0s
    cacheUnauthorizedTTL: 30s

readOnlyPort: 0                    # CIS 4.2.4 — disable 10255 entirely
protectKernelDefaults: true        # CIS 4.2.6 — refuse to start if sysctls are wrong
makeIPTablesUtilChains: true       # CIS 4.2.7
streamingConnectionIdleTimeout: 5m # CIS 4.2.5
eventRecordQPS: 5
seccompDefault: true               # RuntimeDefault seccomp for every pod

# Serving certificate: bootstrap + rotate, never a static self-signed cert
serverTLSBootstrap: true           # CIS 4.2.10 — CSR must be approved
rotateCertificates: true           # CIS 4.2.11 — client cert auto-rotation

tlsCipherSuites:
  - TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384
  - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
  - TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305
  - TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305
  - TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
  - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256

clusterDNS:
  - 172.20.0.10
clusterDomain: cluster.local

# Resource isolation so a workload cannot starve the kubelet or the OS
systemReserved:
  cpu: 200m
  memory: 512Mi
  ephemeral-storage: 2Gi
kubeReserved:
  cpu: 200m
  memory: 1Gi
  ephemeral-storage: 2Gi
evictionHard:
  memory.available: "200Mi"
  nodefs.available: "10%"
  imagefs.available: "15%"

cgroupDriver: systemd
containerLogMaxSize: 50Mi
containerLogMaxFiles: 3
```

`serverTLSBootstrap: true` significa que los certificados de servicio del kubelet provienen de una CSR que alguien debe aprobar. Si se dejan sin aprobar, `kubectl logs` y `kubectl top` fallarán:

```console
$ kubectl get csr
NAME        AGE   SIGNERNAME                                    REQUESTOR                                        REQUESTEDDURATION   CONDITION
csr-7k2pq   4m    kubernetes.io/kubelet-serving                 system:node:ip-10-40-12-31.eu-west-1.compute.internal   <none>        Pending
csr-9m4tv   4m    kubernetes.io/kubelet-serving                 system:node:ip-10-40-13-88.eu-west-1.compute.internal   <none>        Pending

$ kubectl top nodes
Error from server (ServiceUnavailable): the server is currently unable to handle the request (get nodes.metrics.k8s.io)
```

Kubernetes deliberadamente no auto-aprueba las CSRs de `kubelet-serving` (el firmante integrado no puede validar las IPs/nombres DNS solicitados). En producción, utiliza `kubelet-csr-approver` o un controlador equivalente con una expresión regular para el nombre de host, nunca una aprobación ciega.

### 6.3 Autorización de nodo y el plugin NodeRestriction

Dos controles del lado del servidor limitan lo que puede hacer un kubelet comprometido:

- **Autorizador de nodo (Node authorizer)** (`--authorization-mode=Node,RBAC`): un kubelet en el grupo `system:nodes` solo puede leer Secrets, ConfigMaps, PVs y PVCs que estén referenciados por pods **programados en su propio nodo**.
- **Plugin de admisión NodeRestriction** (`--enable-admission-plugins=NodeRestriction`): un kubelet solo puede modificar su propio objeto `Node` y solo los objetos `Pod` vinculados a él, y no puede autoasignarse etiquetas con el prefijo `node-restriction.kubernetes.io/`.

Ese segundo prefijo es el punto clave: si me asignas cargas de trabajo sensibles con `nodeSelector: {node-restriction.kubernetes.io/pool: pci}`, un kubelet comprometido en un nodo general no puede re-etiquetarse a sí mismo para atraer esos pods. Una simple etiqueta `pool: pci` no ofrece tal protección.

```console
$ kubectl auth can-i --list \
    --as=system:node:ip-10-40-12-31.eu-west-1.compute.internal \
    --as-group=system:nodes | head -12
Resources                                       Non-Resource URLs   Resource Names   Verbs
selfsubjectreviews.authentication.k8s.io        []                  []               [create]
selfsubjectaccessreviews.authorization.k8s.io   []                  []               [create]
selfsubjectrulesreviews.authorization.k8s.io    []                  []               [create]
                                                [/healthz]          []               [get]
                                                [/livez]            []               [get]
                                                [/readyz]           []               [get]
                                                [/version]          []               [get]
```

Ten en cuenta que el alcance por nodo del autorizador de nodo no aparece en `can-i --list` — se evalúa por solicitud contra el gráfico real de pod-a-nodo.

### 6.4 Integridad de arranque y computación confidencial

| Control | AWS | GCP | Azure | Amenaza abordada |
|---|---|---|---|---|
| Secure Boot | Nitro UEFI Secure Boot | Shielded VM `--shielded-secure-boot` | Trusted Launch | Bootloader/kernel/rootkit no firmado |
| vTPM / arranque medido | NitroTPM | Shielded VM vTPM | vTPM | Detectar alteración en la cadena de arranque |
| Monitoreo de integridad | — (vía atestación NitroTPM) | `--shielded-integrity-monitoring` | Atestación de invitado | Alertar sobre desviación de mediciones |
| Cifrado de memoria | AMD SEV-SNP / Nitro Enclaves | Nodos confidenciales (SEV/SEV-SNP/TDX) | VMs confidenciales | Hipervisor / operador del host leyendo RAM |
| Cifrado de disco | EBS + KMS | PD + CMEK | Managed Disk + CMK | Volúmenes robados o en snapshots |

La computación confidencial es el control que mueve al **propio proveedor cloud** fuera de tu límite de confianza. Tiene un costo de rendimiento medible y limita la elección del tipo de instancia, por lo que debe reservarse para cargas de trabajo con requerimientos regulatorios o de hosts adversarios; Secure Boot + vTPM + monitoreo de integridad debe ser la opción por defecto sensata en cualquier otro lugar ya que es efectivamente gratuita.

---

## 7. Cifrado en reposo: etcd y cifrado de sobre

### 7.1 Por qué "Secrets son base64" importa en la capa de infraestructura

Un Secret de Kubernetes se almacena en etcd. Por defecto se almacena **sin cifrar** — base64 es una codificación, no un cifrado. Cualquiera que obtenga un snapshot de etcd, una imagen de disco o un objeto en un bucket de respaldo puede leer cada Secret del cluster en texto plano:

```console
# On a self-managed control-plane node, WITHOUT encryption at rest:
$ sudo ETCDCTL_API=3 etcdctl \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    get /registry/secrets/payments/db-creds | hexdump -C | head -6
00000000  2f 72 65 67 69 73 74 72  79 2f 73 65 63 72 65 74  |/registry/secret|
00000010  73 2f 70 61 79 6d 65 6e  74 73 2f 64 62 2d 63 72  |s/payments/db-cr|
00000020  65 64 73 0a 6b 38 73 00  0a 0c 0a 02 76 31 12 06  |eds.k8s.....v1..|
00000030  53 65 63 72 65 74 12 b8  01 0a 8e 01 0a 08 64 62  |Secret........db|
00000040  2d 63 72 65 64 73 12 00  1a 08 70 61 79 6d 65 6e  |-creds....paymen|
00000050  74 73 22 00 2a 24 39 62  31 34 63 32 65 30 2d ...  |ts".*$9b14c2e0-|
```

Observa la marca mágica `k8s\x00` y el protobuf legible. Con el cifrado habilitado, la misma clave devuelve `k8s:enc:kms:v2:aws-kms-primary:` seguido del texto cifrado.

### 7.2 EncryptionConfiguration — comparativa de proveedores

| Proveedor | Ubicación de la clave | Fortaleza | Rotación | Notas |
|---|---|---|---|---|
| `identity` | — | **Ninguna** (texto plano) | n/a | El valor por defecto. Debe ir al *final* de la lista para permitir leer datos heredados. |
| `secretbox` | En disco, en el archivo de config | XSalsa20-Poly1305 | Manual, edición de config + reescritura | Rápido; la clave reside junto a los datos que protege. |
| `aescbc` | En disco | AES-CBC + PKCS#7 | Manual | **Heredado — vulnerable a problemas de tipo padding-oracle; no recomendado para nuevos clusters.** |
| `aesgcm` | En disco | AES-GCM | **Debe rotarse cada ~200k escrituras** | Riesgo de reutilización de nonce si se descuida la rotación; solo para configuraciones de rotación automatizada. |
| `kms` v1 | KMS externo | Cifrado de sobre, DEK por recurso | Rotar la KEK en el KMS | **Obsoleto desde v1.28.** Cada escritura es una llamada a KMS — costoso y una dependencia rígida. |
| `kms` v2 | KMS externo | Cifrado de sobre, DEK derivada por escritura vía KDF | Rotar la KEK; sin límites de cantidad de claves | **GA en v1.29. La opción correcta.** Almacena en caché la KEK, ~1 llamada a KMS por rotación de clave, con chequeo de estado. |

Configuración completa para producción (`/etc/kubernetes/enc/encryption-config.yaml`, referenciada por `kube-apiserver --encryption-provider-config=...`):

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  # Highest-value resources first, with the strongest provider
  - resources:
      - secrets
    providers:
      - kms:
          apiVersion: v2
          name: aws-kms-primary
          endpoint: unix:///var/run/kmsplugin/socket.sock
          timeout: 3s
      - secretbox:
          keys:
            - name: break-glass-2026-08
              secret: c2VjcmV0aXNzZWNyZXQxMjM0NTY3ODkwYWJjZGVmZ2g=
      - identity: {}

  # Tokens and bindings also carry credentials
  - resources:
      - serviceaccounts
      - configmaps
    providers:
      - kms:
          apiVersion: v2
          name: aws-kms-primary
          endpoint: unix:///var/run/kmsplugin/socket.sock
          timeout: 3s
      - identity: {}

  # CRDs that store credentials (e.g. cert-manager, external-secrets)
  - resources:
      - certificaterequests.cert-manager.io
      - externalsecrets.external-secrets.io
    providers:
      - kms:
          apiVersion: v2
          name: aws-kms-primary
          endpoint: unix:///var/run/kmsplugin/socket.sock
          timeout: 3s
      - identity: {}
```

**Reglas que determinan si esto funciona:**

1. **El primer proveedor en la lista cifra; cada proveedor listado puede descifrar.** Para *habilitar* el cifrado, coloca `kms` primero y mantén `identity` al final. Para *deshabilitarlo*, coloca `identity` primero — y solo entonces reescribe los datos.
2. Cambiar la configuración no cifra nada de lo que ya existe. Los objetos solo se vuelven a cifrar al ser reescritos:
   ```console
   $ kubectl get secrets --all-namespaces -o json | kubectl replace -f -
   secret/db-creds replaced
   secret/tls-ingress replaced
   ...
   ```
3. Desde v1.27 puedes usar comodines (`*.` para un comodín del grupo core, `*.*` para todo), pero los comodines junto con una entrada explícita para el mismo recurso es un error de configuración y el servidor de API se negará a iniciar.
4. Desde v1.29, KMS v2 soporta **recarga automática de configuración** (`--encryption-provider-config-automatic-reload=true`) — pero ese flag hace que todas las verificaciones de salud se colapsen en un único endpoint `/healthz/kms-providers`.

Verifica el prefijo del texto cifrado:

```console
$ kubectl -n payments create secret generic canary --from-literal=probe=itworks
secret/canary created

$ sudo ETCDCTL_API=3 etcdctl \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    get /registry/secrets/payments/canary | hexdump -C | head -4
00000000  2f 72 65 67 69 73 74 72  79 2f 73 65 63 72 65 74  |/registry/secret|
00000010  73 2f 70 61 79 6d 65 6e  74 73 2f 63 61 6e 61 72  |s/payments/canar|
00000020  79 0a 6b 38 73 3a 65 6e  63 3a 6b 6d 73 3a 76 32  |y.k8s:enc:kms:v2|
00000030  3a 61 77 73 2d 6b 6d 73  2d 70 72 69 6d 61 72 79  |:aws-kms-primary|

$ kubectl get --raw='/healthz/kms-provider-0'
ok
```

`k8s:enc:kms:v2:aws-kms-primary` es la prueba. Si todavía ves `k8s\x00\n\x0c\n\x02v1`, el objeto es anterior al cambio de configuración y requiere la reescritura del paso 2.

### 7.3 Clusters administrados: el mismo control, una superficie más pequeña

No editas `EncryptionConfiguration` en EKS/GKE/AKS. Proporcionas una clave:

```console
$ aws eks associate-encryption-config \
    --cluster-name prod-euw1 \
    --encryption-config '[{"provider":{"keyArn":"arn:aws:kms:eu-west-1:123456789012:key/8f7e6d5c-4b3a-2918-0765-4a3b2c1d0e9f"},"resources":["secrets"]}]'
{
    "update": {
        "id": "c8d9e0f1-a2b3-4c5d-6e7f-8a9b0c1d2e3f",
        "status": "InProgress",
        "type": "AssociateEncryptionConfig",
        "createdAt": "2026-08-06T10:44:07.913000+02:00"
    }
}
```

> **Irreversible.** En EKS, el cifrado de sobre no se puede remover una vez asociado, y eliminar o deshabilitar la clave KMS deja inservibles permanentemente los Secrets del cluster. Establece una política de protección contra eliminación y una denegación de `kms:ScheduleKeyDeletion` en esa clave, y alerta sobre `DisableKey`. El equivalente en GKE es `--database-encryption-key`; en AKS, `--enable-encryption-at-host` más el cifrado de etcd con KMS.

### 7.4 Cifrado de nodos y volúmenes

El cifrado de etcd protege los datos del control plane. Los datos de las cargas de trabajo en PersistentVolumes necesitan su propia clave:

```yaml
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3-encrypted
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  iops: "3000"
  throughput: "250"
  encrypted: "true"
  kmsKeyId: arn:aws:kms:eu-west-1:123456789012:key/1a2b3c4d-5e6f-7081-92a3-b4c5d6e7f809
  csi.storage.k8s.io/fstype: ext4
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ledger-data
  namespace: payments
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: gp3-encrypted
  resources:
    requests:
      storage: 50Gi
```

`WaitForFirstConsumer` no es solo una optimización de programación — evita que un volumen sea aprovisionado en una zona de disponibilidad donde no exista un nodo elegible (correctamente marcado con taints, correctamente etiquetado), lo cual en clusters multitenant es la forma en que las cargas de trabajo terminan en el node pool equivocado.

---

## 8. Auditoría de infraestructura y telemetría

El registro de auditoría de Kubernetes te dice qué sucedió *en* el cluster. El registro de auditoría de la nube te dice qué sucedió *con* él. Necesitas ambos, y deben aterrizar en un lugar que las propias identidades del cluster no puedan eliminar.

| Señal | Fuente | Responde a |
|---|---|---|
| Registro de auditoría de Kubernetes | `kube-apiserver --audit-policy-file` / registro del control plane del proveedor | "¿Quién leyó ese Secret? ¿Quién creó esa vinculación ClusterRoleBinding?" |
| CloudTrail / Cloud Audit Logs / Azure Activity Log | API de la nube | "¿Quién cambió la configuración de IMDS del grupo de nodos? ¿Quién deshabilitó la clave KMS?" |
| Registros de flujo de VPC (VPC Flow Logs) | Red | "¿Realizó el egress del nodo de un pod una conexión a un AS inesperado?" |
| GuardDuty EKS Protection / Container Threat Detection | Detección en tiempo de ejecución del proveedor | "¿Leyó un proceso `/var/run/secrets/...` y luego llamó a IMDS?" |

Una política de auditoría mínima que captura la cadena de robo de credenciales sin ahogarte en ruido:

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - RequestReceived
rules:
  # Never log the token review chatter or the health endpoints
  - level: None
    users: ["system:kube-proxy"]
    verbs: ["watch"]
    resources:
      - group: ""
        resources: ["endpoints", "services", "services/status"]
  - level: None
    nonResourceURLs:
      - /healthz*
      - /livez*
      - /readyz*
      - /version
      - /metrics

  # Secrets: metadata only — never write Secret bodies into the audit log
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]
      - group: "authentication.k8s.io"
        resources: ["tokenreviews"]

  # Privilege changes: full request AND response
  - level: RequestResponse
    verbs: ["create", "update", "patch", "delete"]
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["clusterroles", "clusterrolebindings", "roles", "rolebindings"]
      - group: ""
        resources: ["serviceaccounts"]

  # Node-level access: exec/attach/portforward are lateral-movement primitives
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach", "pods/portforward", "nodes/proxy"]

  # Workload mutations: request body, so we see hostNetwork/privileged/hostPath
  - level: Request
    verbs: ["create", "update", "patch", "delete"]
    resources:
      - group: ""
        resources: ["pods"]
      - group: "apps"
        resources: ["deployments", "daemonsets", "statefulsets"]

  # Everything else
  - level: Metadata
```

En clusters administrados habilitas el equivalente a través del proveedor:

```console
$ aws eks update-cluster-config --name prod-euw1 \
    --logging '{"clusterLogging":[{"types":["api","audit","authenticator","controllerManager","scheduler"],"enabled":true}]}'
```

`authenticator` es el específico de EKS que registra el mapeo de identidad de IAM a Kubernetes — el registro que necesitas cuando investigas "¿cómo este principal de IAM se convirtió en `system:masters`?".

---

## 9. Verificación y diagnóstico de fallas

### 9.1 Escaneo base con kube-bench

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: kube-bench-node
  namespace: security
spec:
  backoffLimit: 0
  template:
    metadata:
      labels:
        app: kube-bench
    spec:
      hostPID: true
      restartPolicy: Never
      tolerations:
        - operator: Exists
      containers:
        - name: kube-bench
          image: docker.io/aquasec/kube-bench:v0.9.3
          args: ["node", "--benchmark", "eks-1.5.0", "--json"]
          securityContext:
            privileged: false
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: var-lib-kubelet
              mountPath: /var/lib/kubelet
              readOnly: true
            - name: etc-systemd
              mountPath: /etc/systemd
              readOnly: true
            - name: etc-kubernetes
              mountPath: /etc/kubernetes
              readOnly: true
      volumes:
        - name: var-lib-kubelet
          hostPath:
            path: /var/lib/kubelet
        - name: etc-systemd
          hostPath:
            path: /etc/systemd
        - name: etc-kubernetes
          hostPath:
            path: /etc/kubernetes
```

```console
$ kubectl -n security logs job/kube-bench-node | sed -n '1,24p'
[INFO] 3 Worker Node Security Configuration
[INFO] 3.1 Worker Node Configuration Files
[PASS] 3.1.1 Ensure that the kubeconfig file permissions are set to 644 or more restrictive
[PASS] 3.1.2 Ensure that the kubelet kubeconfig file ownership is set to root:root
[PASS] 3.1.3 Ensure that the kubelet configuration file has permissions set to 644
[PASS] 3.1.4 Ensure that the kubelet configuration file ownership is set to root:root
[INFO] 3.2 Kubelet
[PASS] 3.2.1 Ensure that the Anonymous Auth is Not Enabled
[PASS] 3.2.2 Ensure that the --authorization-mode argument is not set to AlwaysAllow
[PASS] 3.2.3 Ensure that a Client CA File is Configured
[PASS] 3.2.4 Ensure that the --read-only-port is disabled
[PASS] 3.2.5 Ensure that the --streaming-connection-idle-timeout is not set to 0
[PASS] 3.2.6 Ensure that the --make-iptables-util-chains argument is set to true
[WARN] 3.2.7 Ensure that the --hostname-override argument is not set
[PASS] 3.2.8 Ensure that the eventRecordQPS argument is set to a level which ensures appropriate event capture
[PASS] 3.2.9 Ensure that the --rotate-certificates argument is not present or is set to true
[PASS] 3.2.10 Ensure that the RotateKubeletServerCertificate argument is set to true

== Summary node ==
16 checks PASS
0 checks FAIL
1 checks WARN
0 checks INFO
```

`kube-bench` lee archivos de configuración y argumentos de procesos. En control planes administrados, las comprobaciones de `master` no son aplicables — ejecuta `node`, `policies` y `managedservices` y trata los elementos del control plane como atestados por el proveedor.

### 9.2 Una lista de verificación que puedes ejecutar en diez minutos

```console
# 1. Is IMDS reachable from a normal pod?  (expect timeout/403)
$ kubectl run imds --rm -it --restart=Never --image=curlimages/curl:8.8.0 -- \
    sh -c 'curl -s -m 4 -o /dev/null -w "%{http_code}\n" \
      http://169.254.169.254/latest/meta-data/ || echo BLOCKED'
BLOCKED

# 2. Is the kubelet read-only port open?  (expect connection refused)
$ kubectl debug node/ip-10-40-12-31.eu-west-1.compute.internal -it \
    --image=busybox:1.36 -- sh -c 'wget -q -T 3 -O- http://localhost:10255/pods'
wget: can't connect to remote host (127.0.0.1): Connection refused

# 3. Can an anonymous caller do anything?  (expect 403 / no)
$ kubectl auth can-i --list --as=system:anonymous 2>/dev/null | wc -l
5      # only selfsubject* and the health endpoints

# 4. Are Secrets encrypted at rest?
$ kubectl get --raw='/healthz/kms-provider-0'
ok

# 5. Which ServiceAccounts still automount tokens they do not need?
$ kubectl get sa -A -o json | jq -r '
    .items[] | select(.automountServiceAccountToken != false)
    | "\(.metadata.namespace)/\(.metadata.name)"' | head
default/default
kube-system/coredns
payments/ledger

# 6. Which pods run with hostNetwork (i.e. can still reach IMDS)?
$ kubectl get pods -A -o json | jq -r '
    .items[] | select(.spec.hostNetwork == true)
    | "\(.metadata.namespace)/\(.metadata.name)"'
kube-system/aws-node-4f8kq
kube-system/aws-node-9x2mv
kube-system/kube-proxy-b7n3l
kube-system/kube-proxy-c1q8w

# 7. Which pods mount the container runtime socket (full node takeover)?
$ kubectl get pods -A -o json | jq -r '
    .items[] as $p | $p.spec.volumes[]? | select(.hostPath.path
      | tostring | test("docker.sock|containerd.sock|crio.sock"))
    | "\($p.metadata.namespace)/\($p.metadata.name) -> \(.hostPath.path)"'
observability/node-agent-7k2pq -> /run/containerd/containerd.sock
```

El elemento 7 merece énfasis: un pod con el socket de containerd montado puede iniciar un contenedor privilegiado con el sistema de archivos root del host montado, y es por lo tanto **equivalente a root en el nodo** independientemente de su propio `securityContext`.

### 9.3 Tabla de diagnóstico de fallas

| Síntoma | Causa probable en infraestructura | Comando de diagnóstico | Solución |
|---|---|---|---|
| `Unable to locate credentials` en un pod usando IRSA | Anotación `eks.amazonaws.com/role-arn` faltante o con error tipográfico, o `automountServiceAccountToken: false` | `kubectl get sa ledger -n payments -o yaml`; verificar `AWS_WEB_IDENTITY_TOKEN_FILE` en el env del pod | Corregir la anotación, luego **eliminar el pod** — el webhook solo muta durante la creación |
| `AccessDenied ... not authorized to perform: sts:AssumeRoleWithWebIdentity` | El `sub` de la política de confianza no coincide con `system:serviceaccount:<ns>:<sa>` | `aws iam get-role --role-name ... --query 'Role.AssumeRolePolicyDocument'` | Corregir las condiciones `sub`/`aud`; verificar la huella del proveedor OIDC |
| El pod funcionaba antes, ahora `credential not found` tras reemplazar el nodo | La aplicación usaba silenciosamente el **rol del nodo** vía IMDS; el hop limit ahora es 1 | Comparar `aws sts get-caller-identity` antes/después | Configurar la identidad de carga de trabajo adecuada — no reviertas el hop limit |
| `Unable to connect to the server: dial tcp ... i/o timeout` desde CI | Endpoint privado, o la IP de salida del runner fue eliminada de la lista de redes autorizadas | `aws eks describe-cluster --query 'cluster.resourcesVpcConfig'` | Ejecutar el CI dentro de la VPC, o agregar la EIP del gateway NAT a la lista de permitidos |
| El servidor de API devuelve `500` al leer Secrets tras un cambio de KMS | Plugin de KMS no saludable, clave deshabilitada o IAM perdió `kms:Decrypt` | `kubectl get --raw='/healthz/kms-provider-0'`; registros del servidor de API buscando `failed to decrypt` | Volver a habilitar la clave / restaurar el permiso; **nunca** elimines la clave |
| Los Secrets siguen en texto plano en etcd tras habilitar el cifrado | Los objetos existentes nunca fueron reescritos | `etcdctl get /registry/secrets/... \| hexdump -C` | `kubectl get secrets -A -o json \| kubectl replace -f -` |
| `kubectl logs` / `top` fallan con `x509: cannot validate certificate` | `serverTLSBootstrap: true` con CSRs de kubelet-serving no aprobadas | `kubectl get csr` | Aprobar mediante un controlador CSR-approver con una lista de permitidos por nombre de host |
| Kubelet se niega a iniciar tras cambio de configuración | `protectKernelDefaults: true` y los sysctls del nodo no coinciden | `journalctl -u kubelet -n 50` | Establecer los sysctls en la imagen del nodo/user-data, no relajando la flag |
| Nodos atascados en `NotReady`, `NetworkUnavailable` | El pod del CNI no puede alcanzar IMDS/API de la nube tras ajustar la salida | `kubectl -n kube-system logs ds/aws-node` | CNI ejecuta `hostNetwork` — re-verifica las reglas del firewall a nivel de host, no la NetworkPolicy |
| Un pod en el namespace A lee Secrets pertenecientes al namespace B | Autorizador de nodo deshabilitado (solo `--authorization-mode=RBAC`) | Verificar flags del servidor de API / configuración del proveedor | Habilitar `Node,RBAC` y `NodeRestriction` |

---

## 10. Resumen centrado en el examen

- La **capa cloud es la base de las 4Cs**; un compromiso allí invalida cualquier control superior.
- La **responsabilidad compartida cambia según el modelo de consumo.** Control plane administrado ⇒ el proveedor es dueño de etcd y las flags del servidor de API; tú sigues siendo dueño de la configuración del kubelet, el OS del nodo, RBAC y la identidad de carga de trabajo.
- **`169.254.169.254` es la ruta de escalación canónica.** Mitigaciones: IMDSv2 (`http_tokens=required`) + `http_put_response_hop_limit=1` en AWS; ocultamiento de metadatos con Workload Identity en GKE; los encabezados obligatorios `Metadata:`/`Metadata-Flavor:` en Azure/GCP.
- La **identidad de carga de trabajo reemplaza los roles de nodo.** IRSA, EKS Pod Identity, GKE Workload Identity y Azure Workload Identity son todas federaciones OIDC de un token proyectado de ServiceAccount. Fija siempre la política de confianza a un `system:serviceaccount:<ns>:<sa>` totalmente calificado y a la audiencia correcta.
- **Puertos:** 6443 API, 2379/2380 etcd, 10250 kubelet, **10255 debe ser 0**, 10257/10259 controller-manager/scheduler, 30000–32767 NodePort.
- Los **endpoints privados y las redes autorizadas** reducen la superficie de ataque alcanzable; la autenticación por sí sola no es un control de red.
- **etcd está en texto plano por defecto.** `EncryptionConfiguration` con un proveedor **KMS v2** (GA en v1.29) es la solución de producción; el primer proveedor cifra, `identity` va al final, y los objetos existentes requieren una reescritura explícita.
- La **elección del OS del nodo es un control de seguridad.** Imágenes mínimas, inmutables y sin shell (Bottlerocket, COS) eliminan la mayoría de las herramientas posteriores a la explotación. Secure Boot + vTPM + monitoreo de integridad debe ser la opción por defecto; computación confidencial cuando el propio host no es de confianza.
- **Autorizador de nodo + NodeRestriction** confinan un kubelet comprometido a los objetos de su propio nodo y bloquean el auto-etiquetado bajo `node-restriction.kubernetes.io/`.
- **Audita ambos planos.** Registros de auditoría de Kubernetes más registros de auditoría de la nube, enviados a un destino que las propias identidades del cluster no puedan modificar.

---

## Referencias

**CNCF / exam**
- KCSA Curriculum (CNCF): https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
- CNCF curriculum repository: https://github.com/cncf/curriculum
- KCSA certification page: https://training.linuxfoundation.org/certification/kubernetes-and-cloud-native-security-associate-kcsa/

**Kubernetes upstream**
- Cloud Native Security overview (4Cs): https://kubernetes.io/docs/concepts/security/cloud-native-security/
- Securing a cluster: https://kubernetes.io/docs/tasks/administer-cluster/securing-a-cluster/
- Encrypting confidential data at rest: https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
- Using a KMS provider for data encryption: https://kubernetes.io/docs/tasks/administer-cluster/kms-provider/
- Ports and protocols: https://kubernetes.io/docs/reference/networking/ports-and-protocols/
- Using Node Authorization: https://kubernetes.io/docs/reference/access-authn-authz/node/
- Admission controllers (NodeRestriction): https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#noderestriction
- Kubelet configuration (v1beta1) reference: https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
- Kubelet authentication/authorization: https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/
- TLS bootstrapping: https://kubernetes.io/docs/reference/access-authn-authz/kubelet-tls-bootstrapping/
- Auditing: https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- Service account token volume projection: https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/#serviceaccount-token-volume-projection
- Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/

**AWS**
- Configuring the instance metadata service (IMDSv2): https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html
- IAM roles for service accounts (IRSA): https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html
- EKS Pod Identity: https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html
- EKS cluster endpoint access control: https://docs.aws.amazon.com/eks/latest/userguide/cluster-endpoint.html
- EKS envelope encryption of Secrets: https://docs.aws.amazon.com/eks/latest/userguide/enable-kms.html
- EKS Best Practices Guide — Security: https://aws.github.io/aws-eks-best-practices/security/docs/
- Bottlerocket OS: https://bottlerocket.dev/en/os/

**Google Cloud**
- GKE Workload Identity Federation: https://cloud.google.com/kubernetes-engine/docs/concepts/workload-identity
- Protecting cluster metadata: https://cloud.google.com/kubernetes-engine/docs/how-to/protecting-cluster-metadata
- Private clusters: https://cloud.google.com/kubernetes-engine/docs/concepts/private-cluster-concept
- Shielded GKE Nodes: https://cloud.google.com/kubernetes-engine/docs/how-to/shielded-gke-nodes
- Confidential GKE Nodes: https://cloud.google.com/kubernetes-engine/docs/how-to/confidential-gke-nodes
- GKE hardening guide: https://cloud.google.com/kubernetes-engine/docs/how-to/hardening-your-cluster

**Microsoft Azure**
- Azure Instance Metadata Service: https://learn.microsoft.com/en-us/azure/virtual-machines/instance-metadata-service
- Azure Workload Identity for AKS: https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview
- AKS private clusters: https://learn.microsoft.com/en-us/azure/aks/private-clusters
- AKS security concepts: https://learn.microsoft.com/en-us/azure/aks/concepts-security
- KMS etcd encryption on AKS: https://learn.microsoft.com/en-us/azure/aks/use-kms-etcd-encryption

**Benchmarks and tooling**
- CIS Kubernetes Benchmark: https://www.cisecurity.org/benchmark/kubernetes
- kube-bench: https://github.com/aquasecurity/kube-bench
- kubelet-csr-approver: https://github.com/postfinance/kubelet-csr-approver
- NSA/CISA Kubernetes Hardening Guide: https://media.defense.gov/2022/Aug/29/2003066362/-1/-1/0/CTR_KUBERNETES_HARDENING_GUIDANCE_1.2_20220829.PDF
- MITRE ATT&CK for Containers: https://attack.mitre.org/matrices/enterprise/containers/