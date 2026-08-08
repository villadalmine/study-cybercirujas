# KCSA Exam Preparation Series: Módulo 5.5 — Public Key Infrastructure (PKI) en Kubernetes

## 1. Motivación arquitectónica de producción y mecánica interna

Public Key Infrastructure (PKI) constituye la capa de confianza fundamental de un cluster de Kubernetes. Cada componente del control plane, agente de nodo worker (`kubelet`), webhook conversion controller y entidad de usuario depende de certificados digitales X.509 y mutual TLS (mTLS) para lograr la autenticación de identidad, el cifrado de la capa de transporte y la propagación del contexto de autorización.

```
                      +------------------------------------------+
                      |         Root Certificate Authority       |
                      |            (Offline / HSM / Vault)       |
                      +--------------------+---------------------+
                                           |
                    +----------------------+----------------------+
                    |                                             |
        +-----------v-----------+                     +-----------v-----------+
        |  Kubernetes Control   |                     |     etcd Cluster      |
        |       Plane CA        |                     |        Peer CA        |
        +-----------+-----------+                     +-----------+-----------+
                    |                                             |
       +------------+------------+                   +------------+------------+
       |                         |                   |                         |
+------v------+           +------v------+     +------v------+           +------v------+
| API Server  |           |   Kubelet   |     | etcd Peer 1 |           | etcd Peer 2 |
| Server Cert |           | Client Cert |     | Client/Svr  |           | Client/Svr  |
+-------------+           +-------------+     +-------------+           +-------------+
```

### 1.1 Límites de confianza del Kubernetes Control Plane
La PKI de Kubernetes no es monolítica; un despliegue de producción robustecido (hardened) impone dominios de confianza distintos gestionados por cadenas de CA independientes:

1. **Kubernetes Core CA**: Firma certificados de servidor para `kube-apiserver` y certificados de cliente para administradores del cluster, `kube-controller-manager`, `kube-scheduler` e interfaces de control de `kubelet`.
2. **etcd Peer & Client CAs**: Cifra el tráfico de replicación Raft de etcd (Peer CA) y autentica el acceso de lectura/escritura de `kube-apiserver` a etcd (Client CA). Aislar la CA de etcd previene que un componente del control plane comprometido forje credenciales de cliente de etcd.
3. **Front-Proxy Aggregation CA**: Firma los certificados de cliente presentados por `kube-apiserver` a los extension API servers (por ejemplo, Metrics Server). Permite los encabezados de impersonación de usuario (`X-Remote-User`, `X-Remote-Group`) de forma segura.
4. **Service Account Key Pair**: Par de claves RSA/ECDSA utilizado estrictamente para firmar y validar tokens JWT presentados por las cargas de trabajo (workloads) de los Pods (no es una cadena de CA X.509).

### 1.2 Mapeo de atributos X.509 y extracción de identidad
Cuando una entidad presenta un certificado de cliente X.509 al `kube-apiserver`, el servidor autentica la conexión contra el `--client-ca-file` configurado y extrae los atributos de identidad directamente del **Subject Distinguished Name (DN)** del certificado:

* **Subject Common Name (`CN`)**: Mapeado a la identidad de **User** de Kubernetes (por ejemplo, `CN=system:node:worker-01` o `CN=jane.doe@company.com`).
* **Subject Organization (`O`)**: Mapeado a los **Groups** de Kubernetes (por ejemplo, `O=system:nodes` o `O=devops-engineering`). Un certificado puede contener múltiples campos `O`, colocando la identidad en múltiples grupos RBAC simultáneamente.
* **Subject Alternative Names (`SAN`)**: Obligatorio para certificados de servidor. Define direcciones IP (`IP:10.96.0.1`) y nombres DNS (`DNS:kubernetes`, `DNS:kubernetes.default.svc.cluster.local`) bajo los cuales el servicio es accesible.

### 1.3 Restricciones de Key Usage (KU) y Extended Key Usage (EKU)
Las extensiones X.509 v3 imponen límites de uso previstos. El `kube-apiserver` verifica estrictamente los EKUs durante los handshakes de TLS:

* `serverAuth` (`id-kp-serverAuth`): Requerido para endpoints que aceptan conexiones TLS entrantes (API Server, endpoint HTTPS de Kubelet, Admission Webhooks).
* `clientAuth` (`id-kp-clientAuth`): Requerido para clientes que establecen conexiones mTLS salientes (cliente Kubelet, cliente Controller Manager, certificados de usuario de kubectl).

### 1.4 Gestión de certificados impulsada por API (`certificates.k8s.io/v1`)
Kubernetes proporciona un motor de emisión de certificados automatizado a través de la API `CertificateSigningRequest` (CSR):
1. **CSR Submission**: Un cliente genera una clave privada local y envía una CSR codificada en PEM al API server.
2. **Authorization & Validation**: El `kube-controller-manager` hace cumplir políticas de RBAC verificando si el solicitante tiene permisos en `certificatesigningrequests/approval` para firmantes (signers) específicos (`kubernetes.io/kube-apiserver-client`, `kubernetes.io/kubelet-serving`, `kubernetes.io/legacy-unknown`).
3. **Approval Engine**: Un administrador o controlador automatizado aprueba la CSR utilizando `kubectl certificate approve`.
4. **Issuance**: El controlador `csrsigning` firma la CSR utilizando el par de claves de la CA almacenado y actualiza `.status.certificate`.

---

## 2. Comparativa técnica y compensaciones de arquitectura (Architecture Trade-offs)

### Tabla 2.1: Algoritmos de claves criptográficas en la PKI de Kubernetes

| Métrica / Dimensión | RSA (3072-bit / 4096-bit) | ECDSA (P-256 / P-384) | Ed25519 |
| :--- | :--- | :--- | :--- |
| **Nivel de seguridad equivalente** | ~128-bit / ~152-bit | 128-bit / 192-bit | ~128-bit |
| **Latencia de handshake y sobrecarga de CPU** | Alto uso de CPU en verificación; generación de claves lenta | Firmas extremadamente rápidas; menor sobrecarga de CPU | Alta velocidad, sobrecarga mínima de CPU |
| **Tamaño de clave (huella de almacenamiento)** | Grande (~2.5 KB a 3.3 KB PEM) | Compacto (~400 Bytes PEM) | Ultra-compacto (~250 Bytes PEM) |
| **Compatibilidad con Kubernetes / Ecosistema** | Universal en todas las herramientas heredadas y stacks TLS | Totalmente soportado en Go TLS y componentes estándar de K8s | Parcial; no soportado por implementaciones TLS más antiguas |
| **Recomendación para producción** | Recomendado para Root/Intermediate CAs (compatibilidad heredada) | **Recomendado para todos los componentes y cargas de trabajo del cluster** | Experimental / Solo microservicios internos |

### Tabla 2.2: Patrones arquitectónicos de emisión de certificados

| Arquitectura | Complejidad operacional | Radio de impacto / Riesgo de seguridad | Automatización del ciclo de vida del certificado | Integración con Vault / HSM externo |
| :--- | :--- | :--- | :--- | :--- |
| **Static File-based CA (por defecto en kubeadm)** | Baja sobrecarga operacional; requiere scripts manuales | Alto: La clave privada de la CA reside en los nodos del control plane | Pobre: Requiere renovación manual o comandos `kubeadm cert renew` | Difícil; requiere herramientas personalizadas |
| **API nativa de CSR de K8s (`certificates.k8s.io`)** | Baja: Construida directamente dentro del API server de Kubernetes | Medio: Limitado al ámbito del cluster de Kubernetes; autorización simple | Alta para certificados de cliente Kubelet; baja para Ingress/webhooks | Indirecta a través de controladores CSR signer personalizados |
| **`cert-manager` + HashiCorp Vault / External Issuer** | Media a alta: Requiere mantener el operador dentro del cluster | Mínimo: La clave de la CA permanece dentro del Vault HSM; auditoría detallada | **Óptimo: Emisión automatizada, renovación y validación ACME** | Nativo empresarial: Integración completa vía AppRole / K8s Auth |

### Tabla 2.3: Estrategias de revocación y certificados de corta duración

| Estrategia | Ejecución mecánica | Sobrecarga de red | Soporte en Kubernetes | Evaluación en producción |
| :--- | :--- | :--- | :--- | :--- |
| **Certificate Revocation Lists (CRL)** | Lista estática de números de serie verificada vía HTTP | Alta: El tamaño de descarga escala con los certificados revocados | **Sin soporte nativo en el mTLS de `kube-apiserver`** | No apto para clusters cloud-native dinámicos |
| **Online Certificate Status Protocol (OCSP)** | Consulta en tiempo real al responder de validación de la CA | Media: Agrega un salto de red durante cada handshake TLS | No soportado por los listeners TLS estándar de Golang | Poco práctico para llamadas al API Server de alto rendimiento |
| **Short-Lived Certificates (TTL <= 24h)** | Los certificados expiran automáticamente antes de la ventana de explotación | Ninguna: Elimina los requerimientos de validación fuera de banda | Nativo a través de autorrotación de `cert-manager` / SPIFFE-SPIRE | **Gold Standard: Paradigma de cumplimiento Zero-Trust** |

---

## 3. Manifests completos de producción e infraestructura de configuración

### 3.1 Kubernetes Native CertificateSigningRequest (`certificates.k8s.io/v1`)
El siguiente manifest envía una CSR para un componente cliente de monitoreo de SRE interno que requiere autenticación de cliente ante el API server:

```yaml
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: sre-monitoring-client-csr
  labels:
    tier: infrastructure
    environment: production
spec:
  request: MIIBvTCCASQCAQAwJDEiMCAGA1UEAwwZc3JlLW1vbml0b3Jpbmctc2VydmljZTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABPZ+8T1vF5bQJ3X8/g1+g0hY6a5W+R1S+4Xv0vF1k+zN7uW7sP0N+Z9y6X1n9W2y8Z3S5v8T0vF1k+zN7uW7sP6gXjBcBgkqhkiG9w0BCQ4headerXDBAMBgNVHSMEIDAAeAAYBokwCwYDVR0PBAQDAgWgMB0GA1UdJQQWMBQGCCsGAQUFBwMCBggrBgEFBQcDADAKBggqhkjOPQQDAgNIADBFAiEA/x+Y8+5K1X9z8+4Xv0vF1k+zN7uW7sP0N+Z9y6X1n9UCICX/f8T1vF5bQJ3X8/g1+g0hY6a5W+R1S+4Xv0vF1k+z
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 86400
  usages:
    - digital signature
    - key encipherment
    - client auth
```

### 3.2 cert-manager Production HashiCorp Vault ClusterIssuer
Este manifest configura una Certificate Authority a nivel de cluster respaldada por HashiCorp Vault utilizando autenticación por token de ServiceAccount de Kubernetes:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: vault-pki-issuer
spec:
  vault:
    server: https://vault.internal.infrastructure.net:8200
    path: pki_k8s/sign/production-intermediate
    caBundle: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSURkekNDQWx1Z0F3SUJBZ0lVTnZZNVZ4c0Z0YXZXOWdCSWdYRW1qS0J2S0x3d0RRWUpLb1pJaHZjTkFRRUwKQlFBd1JERUxNQWtHQTFVRUJoTUNRVlV4RXpBUkJnTlZCQUdNQ3BOdmFXNWtZVEVNTUFvR0ExVUVDd3dEVEVsawpNQjRYRFRJeE1ERXlNVEE1TURRMU1sb1hEVE14TURFeU1EQTVNRFExTWxvdyZERVNNQUdHQTFVRUF3d0ZRVmRPCnQyRnlMVk5ZTWNCWENEVXlNQTRHQTFVREVRd0hRMlY1SUZkNUlFMTVJRkpQVDEwV01CNEdBMVVkRHdXRQpCUUF3SUZvb01BMEdDU3FHU0liM0RRRUJDd1VBQTRJQkFRQzF2NGZkR3ZyT3lCSHJ3UzU5Q1p0L2tTTVkKS0g0eEZwUUpHUTlhMWJ0MDFYMHZZcE45c3Jld3FvTk1ZVkVnVWgxbEFlZEJ1dkp0S1E1NmJHZmlzYjBQCnR6K3Yrd1ZwMkxYZ2p2SktSazhKMWFvNThUcXlGVW5aK0U1ZUtHUlVkMWp6c2RXZnVkRjU2N3UzaExSVApvMm0rcVZtbVdtS3hVUGt4UUpnLzMyeTV4VkpqM0d1dDFiTFVzSzhIdUlycmkyOHlCVi9MZFhhSndlTHQKY0s3RktnTkpYTFhrcmFsY3c3a0k2WjkyU3Boc0s1L0pmTG5iSElhbHpmMSt3cTF4eWZqZ1p2Y29RSmFtdgp4cTF5c2F4N2VpdGpyRndPdkR6ZldHdmRzZnlYOHl1SGpxUGk4aVpMbEZlS1ZqL2sreS9QWmhLSgppc3Nvd3JhUk96T0c0N1BMTnNDS016TGsvSzd6Ci0tLS0tRU5EIENFUlRJRklDQVRFLS0tLS0=
    auth:
      kubernetes:
        mountPath: /v1/auth/kubernetes
        role: cert-manager-pki-signer
        secretRef:
          name: cert-manager-vault-token
          key: token
```

### 3.3 cert-manager Production Certificate Request
Un recurso `Certificate` completo que impone cifrado ECDSA, tiempo de vida estricto de 90 días, autorrenovación de 30 días y definiciones SAN:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: api-gateway-tls
  namespace: ingress-gateways
spec:
  secretName: api-gateway-tls-secret
  duration: 2160h0m0s # 90 Days
  renewBefore: 720h0m0s # 30 Days
  subject:
    organizations:
      - Infrastructure Engineering
    organizationalUnits:
      - Security Operations
  commonName: api.production.domain.net
  dnsNames:
    - api.production.domain.net
    - internal-api.production.domain.net
  ipAddresses:
    - 10.100.50.25
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Always
  usages:
    - digital signature
    - key encipherment
    - server auth
    - client auth
  issuerRef:
    name: vault-pki-issuer
    kind: ClusterIssuer
    group: cert-manager.io
```

### 3.4 Hardened API Server Static Pod PKI Configuration Snippet
Fragmento de `/etc/kubernetes/manifests/kube-apiserver.yaml` que configura una verificación mTLS estricta y CAs dedicadas:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: kube-apiserver
  namespace: kube-system
spec:
  containers:
  - command:
    - kube-apiserver
    - --tls-cert-file=/etc/kubernetes/pki/apiserver.crt
    - --tls-private-key-file=/etc/kubernetes/pki/apiserver.key
    - --client-ca-file=/etc/kubernetes/pki/ca.crt
    - --etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt
    - --etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt
    - --etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key
    - --kubelet-client-certificate=/etc/kubernetes/pki/apiserver-kubelet-client.crt
    - --kubelet-client-key=/etc/kubernetes/pki/apiserver-kubelet-client.key
    - --requestheader-client-ca-file=/etc/kubernetes/pki/front-proxy-ca.crt
    - --requestheader-allowed-names=front-proxy-client
    - --requestheader-extra-headers-prefix=X-Remote-Extra-
    - --requestheader-group-headers=X-Remote-Group
    - --requestheader-username-headers=X-Remote-User
    - --service-account-key-file=/etc/kubernetes/pki/sa.pub
    - --service-account-signing-key-file=/etc/kubernetes/pki/sa.key
    - --service-account-issuer=https://kubernetes.default.svc.cluster.local
```

---

## 4. Comandos reales de CLI y flujo de ejecución de salida de terminal

### 4.1 Paso 1: Generar clave privada y CSR utilizando OpenSSL
Generar una clave privada ECDSA P-256 y una CSR que contenga extensiones Subject y SAN personalizadas:

```bash
$ openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -nodes -keyout cluster-admin-sre.key \
    -out cluster-admin-sre.csr \
    -subj "/CN=sre-admin/O=system:masters" \
    -addext "subjectAltName=DNS:sre-admin.local,email:sre-oncall@company.com"
```

```text
Generating a ECDSA private key
writing new private key to 'cluster-admin-sre.key'
-----
```

### 4.2 Paso 2: Codificar y enviar la CSR al API Server de Kubernetes
Codificar la CSR utilizando base64 y envolverla dentro de un objeto `CertificateSigningRequest`:

```bash
$ CSR_BASE64=$(cat cluster-admin-sre.csr | base64 | tr -d '\n')
$ cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: sre-admin-access
spec:
  request: ${CSR_BASE64}
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 28800
  usages:
  - client auth
  - digital signature
  - key encipherment
EOF
```

```text
certificatesigningrequest.certificates.k8s.io/sre-admin-access created
```

### 4.3 Paso 3: Inspeccionar el estado de la CSR pendiente
Verificar que la CSR exista y esté esperando la aprobación manual del administrador:

```bash
$ kubectl get csr sre-admin-access -o wide
```

```text
NAME               AGE   SIGNERNAME                            REQUESTOR                 REQUESTEDDURATION   CONDITION
sre-admin-access   12s   kubernetes.io/kube-apiserver-client   kubernetes-admin          8h                  Pending
```

### 4.4 Paso 4: Aprobar la CSR y extraer el certificado firmado
Aprobar la solicitud utilizando `kubectl certificate approve` y extraer el certificado X.509 firmado resultante:

```bash
$ kubectl certificate approve sre-admin-access
```

```text
certificatesigningrequest.certificates.k8s.io/sre-admin-access approved
```

```bash
$ kubectl get csr sre-admin-access -o jsonpath='{.status.certificate}' | base64 --decode > cluster-admin-sre.crt
$ ls -lh cluster-admin-sre.crt
```

```text
-rw-r--r-- 1 root root 1.1K Aug 7 20:24 cluster-admin-sre.crt
```

### 4.5 Paso 5: Validar las extensiones del certificado X.509 y los atributos de identidad
Inspeccionar el certificado emitido para verificar que los atributos `CN`, `O`, `SAN` y `EKU` coincidan con las especificaciones deseadas:

```bash
$ openssl x509 -in cluster-admin-sre.crt -text -noout | grep -E "Subject:|Issuer:|Not After|ASN1 OID|DNS:" -A 1
```

```text
        Issuer: CN = kubernetes
        Validity
            Not Before: Aug  7 20:20:00 2026 GMT
            Not After : Aug  8 04:24:00 2026 GMT
        Subject: CN = sre-admin, O = system:masters
        X509v3 Extended Key Usage: 
            TLS Web Client Authentication
        X509v3 Subject Alternative Name: 
            DNS:sre-admin.local, email:sre-oncall@company.com
```

### 4.6 Paso 6: Verificar la cadena de certificados contra la CA del cluster
Confirmar la confianza criptográfica contra el CA bundle del control plane:

```bash
$ openssl verify -CAfile /etc/kubernetes/pki/ca.crt cluster-admin-sre.crt
```

```text
cluster-admin-sre.crt: OK
```

---

## 5. Guía de verificación y resolución de problemas (Troubleshooting)

### 5.1 Matriz de resolución de problemas en producción

```
                        +--------------------------------+
                        |  Kubernetes TLS Failure Event  |
                        +---------------+----------------+
                                        |
                 +----------------------+----------------------+
                 |                                             |
    +------------v------------+                   +------------v------------+
    |   Handshake Error       |                   |  Authorization Failure  |
    |  "unknown authority"    |                   |   "user unauthorized"   |
    +------------+------------+                   +------------+------------+
                 |                                             |
    +------------v------------+                   +------------v------------+
    | Check CA Bundle Match   |                   | Validate CN & O Fields  |
    | & Intermediate Chains   |                   | Against RBAC Bindings   |
    +-------------------------+                   +-------------------------+
```

| Síntoma / Salida de logs | Causa raíz | Flujo de remedación |
| :--- | :--- | :--- |
| `x509: certificate signed by unknown authority` | El cliente confía en un CA bundle que no incluye la CA firmante del certificado del servidor destino. | 1. Extraer el certificado remoto: `openssl s_client -connect <host>:443 -showcerts`<br>2. Comparar el Issuer Hash con `/etc/kubernetes/pki/ca.crt`<br>3. Montar el CA bundle correcto en el pod cliente. |
| `x509: certificate relies on legacy Common Name field` | Go 1.15+ aplica una validación SAN estricta. El certificado carece de la extensión DNS SAN que coincida con el endpoint solicitado. | Reemitir el certificado utilizando OpenSSL/cert-manager con campos `subjectAltName=DNS:<hostname>` explícitos. |
| `tls: failed to verify certificate: x509: certificate has expired or is not yet valid` | Desviación del reloj del sistema (clock drift) o tiempo de vida del certificado superado sin autorrotación. | 1. Verificar la hora del sistema: `chronyc tracking`<br>2. Verificar la validez del certificado: `openssl x509 -enddate -noout -in <cert.crt>`<br>3. Rotar credenciales a través de `kubeadm certs renew` o cert-manager. |
| Certificado de `cert-manager` atascado en `Ready: False` | Fallo del Issuer (Error de autenticación con Vault, desafío ACME fallido o RBAC inválido). | Ejecutar `kubectl describe certificate <name>` seguido de `kubectl describe certificaterequest <name-csr>` y verificar `.status.conditions`. |

### 5.2 Escenarios diagnósticos en profundidad (Deep-Dive)

#### Escenario A: Fallo en llamada de Webhook (`x509: certificate signed by unknown authority`)
**Contexto:** Un admission webhook (`ValidatingWebhookConfiguration`) bloquea el despliegue de Pods debido a un fallo en el handshake TLS entre `kube-apiserver` y el endpoint del webhook.

1. **Consultar logs del API Server:**
```bash
$ kubectl logs -n kube-system kube-apiserver-master-01 --tail=100 | grep -i "webhook"
```
```text
E0807 20:24:20.104512 1 dispatcher.go:205] Failed calling webhook "validate.security.domain": Post "https://webhook-service.monitoring.svc:443/validate": x509: certificate signed by unknown authority (possibly because of "crypto/rsa: verification error" while trying to verify candidate authority certificate "custom-ca")
```

2. **Inspeccionar el campo `caBundle` de la configuración del Webhook:**
```bash
$ kubectl get validatingwebhookconfiguration security-webhook-config -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | base64 --decode | openssl x509 -text -noout | grep -E "Subject:|Issuer:"
```
```text
        Issuer: CN = old-cluster-ca
        Subject: CN = old-cluster-ca
```

3. **Resolución:** Actualizar el `caBundle` en el `ValidatingWebhookConfiguration` con el certificado CA raíz/intermedio activo codificado en Base64 que coincida con el certificado de servidor del webhook service.

#### Escenario B: Emisión de certificado bloqueada en cert-manager
**Contexto:** Un Secret TLS de Ingress crítico no se está actualizando.

1. **Rastrear la jerarquía de recursos de cert-manager:**
```bash
$ kubectl get certificate -n ingress-gateways
```
```text
NAME               READY   SECRET             AGE
api-gateway-tls    False   api-gateway-tls    15m
```

2. **Inspeccionar el CertificateRequest subyacente:**
```bash
$ kubectl get certificaterequest -n ingress-gateways
```
```text
NAME                    APPROVED   DENIED   READY   ISSUER             REQUESTOR                               AGE
api-gateway-tls-12345   True       False    False   vault-pki-issuer   cert-manager-cert-manager-controller   14m
```

3. **Verificar logs detallados de eventos en Order/CertificateRequest:**
```bash
$ kubectl describe certificaterequest api-gateway-tls-12345 -n ingress-gateways
```
```text
Status:
  Conditions:
    Type:   Ready
    Status: False
    Reason: VaultError
    Message: Failed to sign certificate: Vault request failed: Error making API request.
             URL: POST https://vault.internal.infrastructure.net:8200/v1/pki_k8s/sign/production-intermediate
             Code: 403. Errors: * permission denied
```

4. **Resolución:** Corregir la configuración de RBAC de HashiCorp Vault: El rol de ServiceAccount de Kubernetes `cert-manager-pki-signer` carece de políticas de autorización para escribir en `pki_k8s/sign/production-intermediate`. Actualizar la política de ACL de Vault para incluir `capabilities = ["update"]` para esa ruta.

---

## 6. Referencias

* **Documentación de certificados y requisitos de la PKI de Kubernetes**:  
  https://kubernetes.io/docs/setup/best-practices/certificates/
* **Referencia de Certificate Signing Requests (`certificates.k8s.io`) de Kubernetes**:  
  https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/
* **Repositorio del currículo oficial de CNCF KCSA**:  
  https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf
* **Guía de configuración del Issuer de Vault en cert-manager**:  
  https://cert-manager.io/docs/configuration/vault/
* **RFC 5280: Perfil de certificado de Public Key Infrastructure X.509 para Internet**:  
  https://datatracker.ietf.org/doc/html/rfc5280