# Guía de estudio CNCF KCSA: Tema 5.5 - Public Key Infrastructure (PKI)

**Dominio del examen:** Kubernetes and Cloud Native Security Associate (KCSA)  
**Tema:** 5.5 Public Key Infrastructure (PKI)  
**Peso:** 2.29%  

---

## Fuentes de referencia oficiales

- [CNCF KCSA Curriculum (PDF)](https://github.com/cncf/curriculum/raw/master/KCSA%20Curriculum.pdf)
- [Kubernetes Documentation: PKI Certificates and Requirements](https://kubernetes.io/docs/setup/best-practices/certificates/)
- [Kubernetes Documentation: Certificate Signing Requests (CSR)](https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/)
- [Kubernetes Documentation: Managing TLS Certificates in a Cluster](https://kubernetes.io/docs/tasks/tls/managing-tls-in-a-cluster/)
- [cert-manager Architecture & Concepts](https://cert-manager.io/docs/concepts/)

---

## Arquitectura técnica profunda y mecánica

Kubernetes depende en gran medida de X.509 Public Key Infrastructure (PKI) para la autenticación Mutual TLS (mTLS) a través de todos los componentes del control plane, worker nodes, clientes de usuario y extension API servers.

```
                         +-----------------------------------+
                         |    Kubernetes Root CA             |
                         |    (/etc/kubernetes/pki/ca.crt)   |
                         +-----------------+-----------------+
                                           |
       +-----------------------+-----------+-----------+-----------------------+
       |                       |                       |                       |
+------v------+         +------v------+         +------v------+         +------v------+
| kube-apiserver|       | kubelet     |         | admin.conf  |         | controller  |
| Server Cert |         | Client Cert |         | Client Cert |         | manager Cert|
+-------------+         +-------------+         +-------------+         +-------------+

                         +-----------------------------------+
                         |    etcd Root CA                   |
                         |    (/etc/kubernetes/pki/etcd/ca)|
                         +-----------------+-----------------+
                                           |
                       +-------------------+-------------------+
                       |                                       |
                +------v------+                         +------v------+
                | etcd Server |                         | apiserver   |
                | Peer Certs  |                         | etcd-client |
                +-------------+                         +-------------+

                         +-----------------------------------+
                         |    Front-Proxy Root CA            |
                         |    (/etc/kubernetes/pki/front-proxy)|
                         +-----------------+-----------------+
                                           |
                                    +------v------+
                                    | Front Proxy |
                                    | Client Cert |
                                    +-------------+
```

### 1. Límites de Certificate Authority (CA) distintos
Un cluster de Kubernetes en producción seguro aisla los dominios de confianza de CA para evitar la suplantación entre componentes:
* **Kubernetes Root CA (`ca.crt` / `ca.key`)**: Firma certificados para `kube-apiserver`, clientes/servidores de `kubelet`, `kube-controller-manager`, `kube-scheduler` y acceso de usuario administrativo.
* **etcd Root CA (`etcd/ca.crt` / `etcd/ca.key`)**: Aisla las comunicaciones mTLS del cluster etcd (peer-to-peer y client-to-server). Evita que componentes del control plane comprometidos consulten directamente el almacenamiento a menos que presenten un certificado cliente de etcd firmado explícitamente.
* **Front-Proxy Root CA (`front-proxy-ca.crt` / `front-proxy-ca.key`)**: Autentica peticiones proxy cuando se utiliza API Aggregation (`extension-apiserver-authentication`), como Metrics Server o Custom Resource Aggregators.
* **Service Account Key Pair (`sa.pub` / `sa.key`)**: No es una CA X.509, sino un par de claves RSA/ECDSA utilizado estrictamente para firmar y verificar JSON Web Tokens (JWTs) de Service Account mediante los flags `--service-account-issuer` y `--service-account-key-file`.

### 2. Mapeo de campos X.509 en la autenticación de Kubernetes
* **Common Name (`CN`)**: Interpretado por `kube-apiserver` como la **identidad del usuario** (ej., `CN=system:node:worker-01` o `CN=jane-admin`).
* **Organization (`O`)**: Interpretado como la **pertenencia a grupos** (ej., `O=system:nodes` o `O=system:masters`).
  > **ADVERTENCIA DE SEGURIDAD:** El grupo `system:masters` está hardcodeado en el código fuente de `kube-apiserver` para omitir la evaluación de RBAC por completo (equivalencia a `cluster-admin`). Cualquier certificado con `O=system:masters` otorga poder absoluto de superusuario independientemente de los `ClusterRoleBindings` de RBAC activos.
* **Subject Alternative Names (SANs)**: Define las direcciones IP y nombres de dominio DNS válidos para certificados de servidor. Si una petición API se conecta a una IP o hostname que no está presente en la extensión SAN del certificado, la negociación TLS falla con `x509: certificate relies on legacy CommonName field` o `x509: certificate is valid for X, not Y`.

---

## Ejercicios prácticos guiados

---

### Ejercicio 1: Inspección profunda y auditoría de seguridad de PKI del Control Plane

#### Objetivo
Auditar el paquete de certificados activo en un nodo de control plane utilizando utilidades estándar de OpenSSL y `kubeadm`. Identificar riesgos de seguridad relacionados con la expiración de certificados, cobertura SAN y vectores de escalada de privilegios en los campos Subject de X.509.

#### Pasos de ejecución

1. Ejecutar `kubeadm` para inspeccionar el estado de expiración de todos los certificados del control plane administrados:
   ```bash
   sudo kubeadm certs check-expiration
   ```
   *Expected Output:*
   ```text
   CERTIFICATE                EXPIRES                  RESIDUAL TIME   CERTIFICATE AUTHORITY   EXTERNALLY MANAGED
   admin.conf                 Aug 07, 2027 18:30 UTC   364d            ca                      no
   apiserver                  Aug 07, 2027 18:30 UTC   364d            ca                      no
   apiserver-etcd-client      Aug 07, 2027 18:30 UTC   364d            etcd-ca                 no
   apiserver-kubelet-client   Aug 07, 2027 18:30 UTC   364d            ca                      no
   front-proxy-client         Aug 07, 2027 18:30 UTC   364d            front-proxy-ca          no
   healthcheck-etcd-client    Aug 07, 2027 18:30 UTC   364d            etcd-ca                 no
   apiserver-etcd-client      Aug 07, 2027 18:30 UTC   364d            etcd-ca                 no
   
   CERTIFICATE AUTHORITY   EXPIRES                  RESIDUAL TIME   EXTERNALLY MANAGED
   ca                      Aug 05, 2036 18:30 UTC   9y              no
   etcd-ca                 Aug 05, 2036 18:30 UTC   9y              no
   front-proxy-ca          Aug 05, 2036 18:30 UTC   9y              no
   ```

2. Inspeccionar los campos Subject y las extensiones SAN X.509 del certificado principal del API Server (`apiserver.crt`):
   ```bash
   sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -text -noout | grep -A 2 "Subject:"
   sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -text -noout | grep -A 1 "Subject Alternative Name"
   ```
   *Expected Output:*
   ```text
        Subject: CN = kube-apiserver
   --
            X509v3 Subject Alternative Name: 
                DNS:control-plane-01, DNS:kubernetes, DNS:kubernetes.default, DNS:kubernetes.default.svc, DNS:kubernetes.default.svc.cluster.local, IP Address:10.96.0.1, IP Address:192.168.1.50
   ```

3. Extraer la línea Subject del certificado cliente `admin.conf` para detectar vinculaciones a grupos de superusuario:
   ```bash
   kubectl config view --raw --minify -o jsonpath='{.users[0].user.client-certificate-data}' | base64 -d | openssl x509 -text -noout | grep "Subject:"
   ```
   *Expected Output:*
   ```text
        Subject: O = system:masters, CN = kubernetes-admin
   ```

#### Preguntas de verificación (Ejercicio 1)
1. **Pregunta 1.1:** ¿Por qué el certificado `apiserver.crt` incluye explícitamente tanto `IP Address:10.96.0.1` como `DNS:kubernetes.default.svc.cluster.local` en sus Subject Alternative Names (SANs)?
2. **Pregunta 1.2:** Si un atacante extrae `/etc/kubernetes/pki/ca.key`, ¿cómo puede eludir todas las políticas de RBAC configuradas en el cluster?

---

### Ejercicio 2: Ciclo de vida manual de CertificateSigningRequest (CSR) y vulnerabilidad de escalada de privilegios en RBAC

#### Objetivo
Generar manualmente una clave privada y un Certificate Signing Request PKCS#10, enviarlo a la API `certificates.k8s.io` de Kubernetes, evaluar las políticas de validación del firmante y ejecutar flujos de trabajo de aprobación a través de `kubectl`.

#### Pasos de ejecución

1. Crear un directorio dedicado y generar una clave privada RSA de 2048 bits y un CSR solicitando la pertenencia al grupo de desarrolladores:
   ```bash
   mkdir -p /tmp/pki-lab && cd /tmp/pki-lab
   openssl req -new -newkey rsa:2048 -nodes \
     -keyout dev-user.key \
     -out dev-user.csr \
     -subj "/CN=security-auditor/O=dev-team"
   ```

2. Codificar en Base64 el contenido del CSR sin saltos de línea:
   ```bash
   CSR_BASE64=$(cat dev-user.csr | base64 | tr -d '\n')
   ```

3. Aplicar el manifiesto `CertificateSigningRequest` de Kubernetes completo y sintácticamente válido:
   ```bash
   cat <<EOF | kubectl apply -f -
   apiVersion: certificates.k8s.io/v1
   kind: CertificateSigningRequest
   metadata:
     name: security-auditor-csr
   spec:
     request: ${CSR_BASE64}
     signerName: kubernetes.io/kube-apiserver-client
     expirationSeconds: 86400
     usages:
     - client auth
     - digital signature
     - key encipherment
   EOF
   ```
   *Expected Output:*
   ```text
   certificatesigningrequest.certificates.k8s.io/security-auditor-csr created
   ```

4. Listar e inspeccionar el estado del CSR recién creado:
   ```bash
   kubectl get csr security-auditor-csr
   ```
   *Expected Output:*
   ```text
   NAME                   AGE   SIGNERNAME                            REQUESTOR          REQUESTEDDURATION   CONDITION
   security-auditor-csr   5s    kubernetes.io/kube-apiserver-client   kubernetes-admin   24h                 Pending
   ```

5. Aprobar el Certificate Signing Request utilizando credenciales administrativas:
   ```bash
   kubectl certificate approve security-auditor-csr
   ```
   *Expected Output:*
   ```text
   certificatesigningrequest.certificates.k8s.io/security-auditor-csr approved
   ```

6. Obtener el certificado X.509 emitido desde el campo status del objeto CSR y verificar sus atributos de Subject:
   ```bash
   kubectl get csr security-auditor-csr -o jsonpath='{.status.certificate}' | base64 -d | openssl x509 -text -noout | grep -E "Subject:|Issuer:"
   ```
   *Expected Output:*
   ```text
        Issuer: CN = kubernetes
        Subject: CN = security-auditor, O = dev-team
   ```

#### Preguntas de verificación (Ejercicio 2)
1. **Pregunta 2.1:** ¿Qué sucede si un usuario envía un CSR con `signerName: kubernetes.io/kube-apiserver-client` donde el Subject contiene `O=system:masters`? ¿Bloquea Kubernetes este CSR automáticamente?
2. **Pregunta 2.2:** ¿Qué permisos de API se requieren en RBAC para aprobar un CSR, y por qué otorgar `update` en `certificatesigningrequests/approval` es equivalente al acceso completo de administrador del cluster?

---

### Ejercicio 3: PKI automatizada de Ingress y Workloads utilizando cert-manager y CAs internas

#### Objetivo
Configurar `cert-manager` utilizando Custom Resource Definitions (CRDs) personalizadas, establecer un `ClusterIssuer` dentro del cluster respaldado por un `Secret` de CA, y emitir certificados mTLS automatizados y autorrenovables para workloads de aplicaciones en producción.

```
 +-------------------------------------------------------------------------+
 | cert-manager Namespace                                                  |
 |                                                                         |
 |  +--------------------+      +--------------------+                     |
 |  | secret/ca-key-pair | ---> | ClusterIssuer/ca-  |                     |
 |  | (tls.crt, tls.key) |      | issuer             |                     |
 |  +--------------------+      +---------+----------+                     |
 +----------------------------------------|--------------------------------+
                                          | Watches & Issues
 +----------------------------------------v--------------------------------+
 | Production Namespace (default)                                          |
 |                                                                         |
 |  +------------------------+      +------------------------------------+ |
 |  | Certificate/app-mtls-  | ---> | secret/app-mtls-tls                | |
 |  | cert                   |      | (tls.crt, tls.key, ca.crt)         | |
 |  +------------------------+      +------------------------------------+ |
 +-------------------------------------------------------------------------+
```

#### Pasos de ejecución

1. Crear un par de claves de CA dedicado dentro del cluster para que funcione como emisor interno para mTLS de aplicaciones:
   ```bash
   openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes \
     -keyout internal-ca.key \
     -out internal-ca.crt \
     -subj "/CN=Internal Workload CA/O=Enterprise Security"

   kubectl create secret tls internal-ca-secret \
     --cert=internal-ca.crt \
     --key=internal-ca.key \
     -n cert-manager
   ```
   *Expected Output:*
   ```text
   secret/internal-ca-secret created
   ```

2. Aplicar el manifiesto `ClusterIssuer` de producción haciendo referencia al secret recién creado:
   ```bash
   cat <<EOF | kubectl apply -f -
   apiVersion: cert-manager.io/v1
   kind: ClusterIssuer
   metadata:
     name: internal-app-issuer
   spec:
     ca:
       secretName: internal-ca-secret
   EOF
   ```
   *Expected Output:*
   ```text
   clusterissuer.cert-manager.io/internal-app-issuer created
   ```

3. Declarar un recurso `Certificate` de producción para automatizar el aprovisionamiento de certificados con activadores de renovación agresivos:
   ```bash
   cat <<EOF | kubectl apply -f -
   apiVersion: cert-manager.io/v1
   kind: Certificate
   metadata:
     name: payment-service-tls
     namespace: default
   spec:
     secretName: payment-service-tls-ingress
     duration: 2160h # 90 days
     renewBefore: 360h # 15 days before expiration
     subject:
       organizations:
         - Financial-Services
     commonName: payment-service.default.svc
     dnsNames:
       - payment-service
       - payment-service.default
       - payment-service.default.svc
       - payment-service.default.svc.cluster.local
     isCA: false
     privateKey:
       algorithm: ECDSA
       size: 256
     issuerRef:
       name: internal-app-issuer
       kind: ClusterIssuer
       group: cert-manager.io
   EOF
   ```
   *Expected Output:*
   ```text
   certificate.cert-manager.io/payment-service-tls created
   ```

4. Verificar que cert-manager resolvió la solicitud y pobló el secret TLS de destino:
   ```bash
   kubectl get certificate payment-service-tls
   kubectl get secret payment-service-tls-ingress -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout | grep -A 1 "Signature Algorithm"
   ```
   *Expected Output:*
   ```text
   NAME                  READY   AGE
   payment-service-tls   True    10s

       Signature Algorithm: ecdsa-with-SHA256
           Public Key Algorithm: id-ecPublicKey
   ```

#### Preguntas de verificación (Ejercicio 3)
1. **Pregunta 3.1:** ¿Cuál es la diferencia técnica entre un `Issuer` y un `ClusterIssuer` en la arquitectura de cert-manager?
2. **Pregunta 3.2:** ¿Por qué se prefiere el uso de ECDSA (ej., `P-256`) sobre el RSA 2048/4096 tradicional en entornos mTLS de microservicios internos de alto rendimiento?

---

### Ejercicio 4: Diagnóstico avanzado de fallas de certificados y discordancias de SAN

#### Objetivo
Simular, diagnosticar y resolver un escenario común de interrupción en producción: un servicio que falla en la autenticación mTLS debido a extensiones SAN faltantes y configuraciones de confianza de CA cliente inválidas.

#### Pasos de ejecución

1. Inspeccionar un handshake TLS fallido utilizando `openssl s_client` contra un endpoint de servicio del cluster habilitado con TLS (o wrapper mock local):
   ```bash
   openssl s_client -connect 10.96.0.1:443 -servername unknown-host.default.svc /dev/null 2>&1 | grep -i -E "verify return|certificate verify failed|CN ="
   ```
   *Expected Output:*
   ```text
   depth=0 CN = kube-apiserver
   verify error:num=20:unable to get local issuer certificate
   verify return:1
   ```

2. Probar la verificación explícitamente pasando la CA raíz del cluster:
   ```bash
   openssl s_client -connect 10.96.0.1:443 -CAfile /etc/kubernetes/pki/ca.crt -servername kubernetes.default.svc < /dev/null | grep -E "Verify return code"
   ```
   *Expected Output:*
   ```text
       Verify return code: 0 (ok)
   ```

3. Consultar intencionalmente utilizando una IP o hostname ausente en la lista SAN para activar un error de discordancia de SAN:
   ```bash
   openssl s_client -connect 10.96.0.1:443 -CAfile /etc/kubernetes/pki/ca.crt -servername invalid-apiserver-name.domain.com < /dev/null 2>&1 | grep -i "hostname"
   ```
   *Expected Output (or validation tool failure):*
   ```text
   curl: (60) SSL: certificate subject name 'kube-apiserver' does not match target host name 'invalid-apiserver-name.domain.com'
   ```

#### Preguntas de verificación (Ejercicio 4)
1. **Pregunta 4.1:** ¿Cómo actualizas los flags de `kube-apiserver` para agregar un nuevo SAN (ej., un nombre DNS de load balancer) al certificado del API Server en un control plane administrado por `kubeadm`?
2. **Pregunta 4.2:** En un escenario donde la comunicación pod-a-pod falla con `x509: certificate signed by unknown authority`, ¿cuáles son las dos causas raíz principales?

---

## Soluciones y explicaciones arquitectónicas

<details>
<summary>Hacé clic para desplegar Soluciones y Respuestas Detalladas</summary>

### Soluciones del Ejercicio 1

* **Respuesta a la Pregunta 1.1:**  
  Se puede acceder al Kubernetes API server internamente a través del servicio ClusterIP (`10.96.0.1`), mediante resolución de DNS interna (`kubernetes`, `kubernetes.default`, `kubernetes.default.svc.cluster.local`) y directamente mediante la dirección IP física/virtual del nodo del control plane (`192.168.1.50`). Los clientes TLS X.509 validan estrictamente que la dirección del host utilizada en la cadena de conexión coincida al menos con una entrada en la extensión Subject Alternative Name (SAN). Si cualquiera de estos nombres DNS o direcciones IP faltara en la extensión SAN, `kubectl` o los componentes internos del cluster que se conecten a través de esa dirección abortarían el handshake TLS con un error de verificación de certificado.

* **Respuesta a la Pregunta 1.2:**  
  El archivo `ca.key` es la clave privada de la Certificate Authority Raíz de Kubernetes. Cualquiera que posea esta clave puede falsificar certificados cliente X.509 arbitrarios. Al configurar el campo Subject de un certificado falsificado como `O=system:masters, CN=attacker`, el portador puede presentar este certificado al API server durante un handshake mTLS. Dado que `kube-apiserver` confía en `ca.crt` y tiene hardcodeado `system:masters` para omitir todas las comprobaciones de RBAC, el atacante obtiene acceso administrativo inmediato e irrevocable sobre todo el cluster. (Nota: los certificados cliente X.509 no se pueden revocar fácilmente en Kubernetes porque `kube-apiserver` no verifica de forma nativa listas CRL ni endpoints OCSP).

---

### Soluciones del Ejercicio 2

* **Respuesta a la Pregunta 2.1:**  
  Kubernetes **no** bloquea automáticamente las CSR que contienen `O=system:masters` a nivel de esquema de API. Sin embargo, el firmante integrado predeterminado `kubernetes.io/kube-apiserver-client` implementado en `kube-controller-manager` aplica reglas de validación estrictas. Si se aprueba una CSR que contiene `O=system:masters`, el controlador integrado se negará a firmarla y emitirá un evento indicando que la firma de solicitudes para `system:masters` está prohibida para evitar la escalada de privilegios de autoservicio.

* **Respuesta a la Pregunta 2.2:**  
  Para aprobar una CSR, un usuario o ServiceAccount debe tener permisos de RBAC para realizar el verbo `update` en el subrecurso `certificatesigningrequests/approval` para el `signerName` específico (ej., reglas de `authorization.k8s.io/synthetic-authorization-reason` para `certificatesigningrequests/approval`).  
  Otorgar `update` en `certificatesigningrequests/approval` es funcionalmente equivalente a `cluster-admin` completo porque un atacante con este permiso puede aprobar una CSR personalizada que solicite identidades arbitrarias (como identidades de nodos o grupos personalizados con altos privilegios), obtener un certificado cliente firmado por el API server y escalar privilegios.

---

### Soluciones del Ejercicio 3

* **Respuesta a la Pregunta 3.1:**  
  * **`Issuer`**: Un Custom Resource con ámbito de namespace. Solo puede emitir certificados X.509 a recursos `Certificate` ubicados dentro del mismo namespace de Kubernetes.  
  * **`ClusterIssuer`**: Un Custom Resource con ámbito de cluster. Puede emitir certificados a recursos `Certificate` en **todos** los namespaces del cluster. Se utiliza habitualmente para controladores Ingress compartidos, CAs internas a nivel de cluster o configuraciones globales de ACME/Let's Encrypt.

* **Respuesta a la Pregunta 3.2:**  
  Las claves ECDSA (Elliptic Curve Digital Signature Algorithm) (como `P-256` o `P-384`) ofrecen una seguridad criptográfica equivalente o superior en comparación con RSA 2048/4096 al tiempo que utilizan tamaños de clave significativamente menores. Esto da como resultado:
  1. **Menor consumo de CPU**: Handshakes TLS más rápidos durante conexiones mTLS de alta frecuencia entre microservicios.
  2. **Sobrecarga de red reducida**: Menor tamaño del payload del certificado X.509 transferido durante las negociaciones del handshake.
  3. **Menor huella de memoria**: Menor uso de memoria por contexto de conexión TLS activa en proxies como Envoy, Linkerd o NGINX.

---

### Soluciones del Ejercicio 4

* **Respuesta a la Pregunta 4.1:**  
  Para agregar un nuevo SAN a un certificado de API server del control plane de `kubeadm`:
  1. Modificar `/etc/kubernetes/kubeadm-config.yaml` (o crear una configuración de parche) para añadir la IP/DNS a `apiServer.certSANs`:
     ```yaml
     apiServer:
       certSANs:
         - "10.96.0.1"
         - "lb.internal.example.com"
         - "192.168.1.100"
     ```
  2. Realizar un respaldo de los certificados existentes:
     ```bash
     sudo mv /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/apiserver.crt.bak
     sudo mv /etc/kubernetes/pki/apiserver.key /etc/kubernetes/pki/apiserver.key.bak
     ```
  3. Regenerar el certificado del API server:
     ```bash
     sudo kubeadm certs generate-id --config /etc/kubernetes/kubeadm-config.yaml
     # Or: sudo kubeadm init phase certs apiserver --config /etc/kubernetes/kubeadm-config.yaml
     ```
  4. Reiniciar el contenedor del Pod estático `kube-apiserver`:
     ```bash
     sudo crictl stop $(sudo crictl ps --name kube-apiserver -q)
     ```

* **Respuesta a la Pregunta 4.2:**  
  1. **CA Bundle faltante o no coincidente**: El Pod cliente no monta ni confía en la CA Raíz/Intermedia específica que firmó el certificado del servidor (ej., la imagen del contenedor de la aplicación carece del paquete de confianza CA del sistema o `ca.crt` no se montó mediante un ConfigMap/Secret).
  2. **Emisor personalizado / autofirmado no confiable**: El Pod servidor presenta un certificado firmado por un emisor personalizado interno (como un `Issuer` interno de cert-manager), pero el Pod cliente realiza la validación contra la CA predeterminada del cluster de Kubernetes (`/var/run/secrets/kubernetes.io/serviceaccount/ca.crt`) en lugar del paquete CA personalizado de la aplicación.

</details>