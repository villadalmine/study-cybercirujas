# CKS 1.4 — Protect Node Metadata and Endpoints

**Peso en el examen:** 3

**Referencias:**
- CKS Curriculum v1.34: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubelet authentication/authorization: https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/
- Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- AWS EC2 Instance Metadata Service (IMDS): https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-metadata.html
- GCP metadata server: https://cloud.google.com/compute/docs/metadata/overview

Contexto: en este dominio se asume un clúster kubeadm con un control-plane (`controlplane`) y al menos un worker (`node01`), con acceso `kubectl` desde el control-plane y acceso `ssh` a los nodos. Ajustá `<NODE_IP>` a la IP interna real de tu worker.

---

## Ejercicio 1: Explorar el kubelet API sin autenticación

1. Obtené la IP interna del nodo worker:
   ```bash
   kubectl get nodes -o wide
   ```
2. Desde el control-plane (o cualquier host con ruta de red hacia el nodo), consultá el endpoint `/pods` del kubelet API en el puerto `10250`:
   ```bash
   curl -sk https://<NODE_IP>:10250/pods
   ```
3. Observá la respuesta. Repetí la consulta contra `/stats/summary`:
   ```bash
   curl -sk https://<NODE_IP>:10250/stats/summary
   ```

**Pregunta 1.1:** Si el comando del paso 2 devuelve el listado completo de Pods del nodo (specs, env vars, volumes) sin haber presentado ninguna credencial, ¿qué configuración del kubelet lo permite?

**Pregunta 1.2:** ¿Qué información sensible podría filtrarse a través de `/pods` y `/stats/summary` si un atacante alcanza este puerto desde la red?

---

## Ejercicio 2: Inspeccionar y endurecer la configuración del kubelet

1. Conectate por `ssh` a `node01`.
2. Revisá el archivo de configuración del kubelet:
   ```bash
   sudo cat /var/lib/kubelet/config.yaml
   ```
3. Localizá las secciones `authentication` y `authorization`, prestando atención a `anonymous.enabled` y `mode`.
4. Hacé un backup del archivo antes de modificarlo:
   ```bash
   sudo cp /var/lib/kubelet/config.yaml /var/lib/kubelet/config.yaml.bak
   ```
5. Editá el archivo para dejarlo así:
   ```yaml
   authentication:
     anonymous:
       enabled: false
     webhook:
       enabled: true
     x509:
       clientCAFile: /etc/kubernetes/pki/ca.crt
   authorization:
     mode: Webhook
   ```
6. Reiniciá el kubelet y verificá que el nodo siga `Ready`:
   ```bash
   sudo systemctl restart kubelet
   sudo systemctl status kubelet
   kubectl get nodes
   ```
7. Volvé a ejecutar el `curl` del Ejercicio 1 contra `/pods`.

**Pregunta 2.1:** ¿Qué código de respuesta HTTP esperás ahora en el paso 7, y por qué?

**Pregunta 2.2:** ¿Qué riesgo concreto existe si `authorization.mode` queda en `AlwaysAllow` mientras `anonymous.enabled` es `true`?

---

## Ejercicio 3: Acceder al kubelet de forma segura vía el apiserver

1. En vez de golpear el puerto `10250` directamente, usá el proxy del apiserver:
   ```bash
   kubectl get --raw /api/v1/nodes/node01/proxy/pods
   ```
2. Creá un `ServiceAccount` sin permisos y probá el mismo comando impersonándolo:
   ```bash
   kubectl create serviceaccount sin-permisos
   kubectl auth can-i get nodes/proxy --as=system:serviceaccount:default:sin-permisos
   ```
3. Otorgá el permiso mínimo necesario con un `ClusterRole`/`ClusterRoleBinding` y repetí la verificación:
   ```bash
   kubectl create clusterrole nodes-proxy-reader --verb=get --resource=nodes/proxy
   kubectl create clusterrolebinding sin-permisos-proxy --clusterrole=nodes-proxy-reader --serviceaccount=default:sin-permisos
   kubectl auth can-i get nodes/proxy --as=system:serviceaccount:default:sin-permisos
   ```

**Pregunta 3.1:** ¿Por qué el camino `kubectl get --raw .../proxy/...` es más seguro que exponer el puerto `10250` directamente a la red?

**Pregunta 3.2:** ¿Qué subresource de RBAC controla quién puede usar este proxy hacia el kubelet?

---

## Ejercicio 4: Verificar que el read-only port está deshabilitado

1. Intentá consultar el puerto legado de solo lectura del kubelet (sin TLS, sin auth):
   ```bash
   curl -s http://<NODE_IP>:10255/pods
   ```
2. En `node01`, revisá si `readOnlyPort` aparece en `/var/lib/kubelet/config.yaml` y qué valor tiene.
3. Si el valor es distinto de `0`, corregilo:
   ```yaml
   readOnlyPort: 0
   ```
4. Reiniciá el kubelet y repetí el paso 1.

**Pregunta 4.1:** ¿Qué debería devolver el paso 1 en un clúster correctamente configurado, y qué valor de `readOnlyPort` lo garantiza?

**Pregunta 4.2:** ¿Por qué este puerto se considera un endpoint especialmente peligroso para dejar habilitado?

---

## Ejercicio 5: Exponer el riesgo del cloud Instance Metadata Service desde un Pod

1. Lanzá un Pod interactivo dentro del clúster:
   ```bash
   kubectl run attacker --image=busybox --restart=Never -it --rm -- sh
   ```
2. Dentro del Pod, intentá alcanzar el metadata endpoint del cloud provider. Ejemplo en AWS:
   ```bash
   wget -qO- --timeout=2 http://169.254.169.254/latest/meta-data/iam/security-credentials/
   ```
   Ejemplo en GCP:
   ```bash
   wget -qO- --header="Metadata-Flavor: Google" http://169.254.169.254/computeMetadata/v1/instance/
   ```
3. Si el nodo tiene un IAM role / service account de infraestructura asociado, intentá listar credenciales temporales:
   ```bash
   wget -qO- http://169.254.169.254/latest/meta-data/iam/security-credentials/<ROLE_NAME>
   ```
4. Salí del Pod (`exit`).

**Pregunta 5.1:** ¿Qué podría hacer un atacante que compromete un Pod y logra leer las credenciales del paso 3?

**Pregunta 5.2:** ¿Por qué `169.254.169.254` es alcanzable por defecto desde cualquier Pod, sin mediar ninguna configuración de Kubernetes?

---

## Ejercicio 6: Mitigar el acceso al metadata endpoint con NetworkPolicy

1. Creá el archivo `deny-cloud-metadata.yaml`:
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
2. Aplicá la política:
   ```bash
   kubectl apply -f deny-cloud-metadata.yaml
   ```
3. Repetí el Ejercicio 5 (pasos 1-2) y confirmá que la conexión ahora falla o expira.
4. Inspeccioná la política aplicada:
   ```bash
   kubectl describe networkpolicy deny-cloud-metadata
   ```

**Pregunta 6.1:** ¿Qué requisito de infraestructura debe cumplirse para que esta `NetworkPolicy` tenga efecto real?

**Pregunta 6.2:** Un Pod definido con `hostNetwork: true` en su spec, ¿queda protegido por esta `NetworkPolicy`? Justificá.

---

<details>
<summary><strong>Respuestas</strong></summary>

**1.1:** El kubelet tiene `authentication.anonymous.enabled: true` (junto con `authorization.mode: AlwaysAllow`), lo que permite que cualquier request sin credenciales se trate como el usuario anónimo y sea autorizado sin restricciones.

**1.2:** Pueden filtrarse variables de entorno con secretos montados como env vars, nombres e imágenes de todos los workloads del nodo, volúmenes montados, y en `/stats/summary` métricas de uso de recursos que revelan qué cargas corren en el nodo — información útil para reconocimiento previo a un ataque.

**2.1:** `401 Unauthorized`, porque ya no se acepta autenticación anónima (`anonymous.enabled: false`) y el cliente `curl` no presenta ningún certificado ni token válido.

**2.2:** Con `AlwaysAllow` cualquier request autenticado (incluido el anónimo) se autoriza sin chequear permisos, es decir que anonymous-auth + AlwaysAllow equivale a un kubelet API totalmente abierto — cualquiera con acceso de red al puerto puede leer y potencialmente ejecutar comandos (`exec`, `attach`, `portforward`) en los Pods del nodo.

**3.1:** Porque pasa por la autenticación y el RBAC normal del apiserver (certificados, tokens de ServiceAccount, políticas `Role`/`ClusterRole`) en lugar de depender únicamente de la configuración local del kubelet, que suele estar expuesta a nivel de red del nodo y es más fácil de alcanzar directamente si no hay segmentación de red.

**3.2:** El subresource `nodes/proxy`. El RBAC del apiserver evalúa `get`/`create` sobre `nodes/proxy` para decidir si un usuario o ServiceAccount puede llegar al kubelet a través de este camino.

**4.1:** Debería devolver `Connection refused` (o timeout), porque `readOnlyPort: 0` deshabilita completamente el listener HTTP sin autenticación en el puerto `10255`.

**4.2:** Porque es un puerto HTTP plano (sin TLS) que no requiere ninguna autenticación ni autorización — cualquiera con acceso de red al nodo podía leer el estado completo de los Pods, por eso quedó deprecado y el valor por defecto moderno es `0`.

**5.1:** Podría usar las credenciales temporales del IAM role/service account del nodo para llamar a la API del cloud provider (por ejemplo, leer buckets S3, describir instancias, o incluso escalar privilegios si el role tiene permisos amplios) — esto es un vector clásico de movimiento lateral desde un Pod comprometido hacia la cuenta cloud completa.

**5.2:** Porque `169.254.169.254` es una IP link-local que el propio Linux del nodo enruta directamente hacia el metadata server del hypervisor/cloud; Kubernetes no intermedia ni filtra ese tráfico por defecto, así que cualquier Pod hereda la misma visibilidad de red que el nodo host (salvo que exista una `NetworkPolicy` u otro control que lo bloquee).

**6.1:** El CNI plugin del clúster debe soportar (implementar) el enforcement de `NetworkPolicy` (por ejemplo Calico, Cilium, o Weave Net con NetworkPolicy habilitado). Si el CNI no lo soporta (por ejemplo Flannel sin extensiones), el recurso `NetworkPolicy` se acepta en la API pero no tiene ningún efecto real sobre el tráfico.

**6.2:** No queda protegido. Con `hostNetwork: true` el Pod usa directamente el namespace de red del nodo, saltándose por completo la interfaz de red virtual del CNI sobre la que actúan las `NetworkPolicy`. Por eso además de esta política es necesario restringir quién puede crear Pods con `hostNetwork: true` (por ejemplo vía Pod Security Admission/`restricted` profile).

</details>