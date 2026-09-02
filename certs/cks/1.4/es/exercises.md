# Ejercicios Guiados — Proteger los Metadatos y Endpoints del Nodo (CKS 1.34, Tema 1.4)

Estos ejercicios prácticos te guían a través del descubrimiento, prueba y endurecimiento de los endpoints de red expuestos por los nodos de Kubernetes, y del bloqueo del acceso de los Pods al servicio de metadatos del proveedor cloud. Ejecutá cada bloque en orden, después respondé las preguntas de verificación antes de continuar. Las respuestas consolidadas están en la sección plegable al final.

> **Entorno de laboratorio.** Necesitás un clúster donde tengas `sudo` en los nodos (kubeadm, `kind`, o un clúster cloud con acceso SSH). Los comandos asumen un nodo de control-plane más al menos un worker. Cuando un paso toque la configuración del kubelet, hacé primero un backup — una configuración malformada detendrá el kubelet. Nada de esto necesita ejecutarse contra producción.

**Fuentes de referencia**
- CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Ports and Protocols — https://kubernetes.io/docs/reference/networking/ports-and-protocols/
- Kubelet authentication/authorization — https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/
- Kubelet config (v1beta1) — https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
- Securing a cluster / restricting cloud metadata API — https://kubernetes.io/docs/tasks/administer-cluster/securing-a-cluster/
- Network Policies — https://kubernetes.io/docs/concepts/services-networking/network-policies/

---

## Ejercicio 1 — Mapear los endpoints que expone un nodo

Antes de poder proteger endpoints, tenés que saber cuáles escuchan y si autentican a quienes los llaman.

1. Conectate por SSH a un nodo **worker** y listá todos los sockets TCP en escucha con el proceso propietario:

   ```bash
   sudo ss -tlnp
   ```

2. Identificá en la salida los puertos conocidos del control-plane y del nodo. En un worker deberías ver al menos el kubelet. Contrastá con los valores por defecto documentados:

   ```bash
   # Kubelet API (HTTPS, authenticated)       -> 10250
   # Kubelet read-only port (HTTP, NO auth)   -> 10255  (should be absent/disabled)
   # Kubelet healthz (localhost only)          -> 10248
   # kube-proxy health/metrics                 -> 10256 / 10249
   ```

3. Sondeá el puerto read-only del kubelet desde el nodo. Si está deshabilitado vas a obtener un connection refused:

   ```bash
   curl -s http://localhost:10255/pods | head -c 200 ; echo
   ```

4. Ahora sondeá la API autenticada del kubelet de forma **anónima** (sin certificado de cliente, sin token):

   ```bash
   curl -sk https://localhost:10250/pods/ | head -c 200 ; echo
   ```

5. En el nodo de **control-plane**, verificá si el puerto de cliente de etcd es alcanzable y cómo está protegido:

   ```bash
   sudo ss -tlnp | grep -E '2379|2380'
   sudo grep -E 'client-cert-auth|listen-client-urls' /etc/kubernetes/manifests/etcd.yaml
   ```

**Preguntas de verificación**

1. ¿Cuál es la diferencia de propósito y de autenticación entre los puertos del kubelet `10250` y `10255`?
2. En el paso 4, un kubelet endurecido devuelve `401 Unauthorized`. ¿Qué te dice, en cambio, un `200` con una lista JSON de pods sobre la configuración del nodo?
3. ¿Por qué exponer el `2379` de etcd sin `client-cert-auth` es catastrófico incluso si el API server está por lo demás asegurado?

---

## Ejercicio 2 — Endurecer el endpoint del kubelet

Ahora cerrá los agujeros de acceso anónimo en el kubelet que acabás de sondear.

1. Hacé un backup y abrí la configuración del kubelet en el nodo worker:

   ```bash
   sudo cp /var/lib/kubelet/config.yaml /var/lib/kubelet/config.yaml.bak
   sudo vi /var/lib/kubelet/config.yaml
   ```

2. Asegurate de que las secciones `authentication`, `authorization` y `readOnlyPort` coincidan con la línea base endurecida:

   ```yaml
   authentication:
     anonymous:
       enabled: false      # reject unauthenticated callers
     webhook:
       enabled: true       # let the API server issue TokenReviews
     x509:
       clientCAFile: /etc/kubernetes/pki/ca.crt
   authorization:
     mode: Webhook         # delegate authz to the API server (not AlwaysAllow)
   readOnlyPort: 0         # disable the unauthenticated 10255 port
   ```

3. Reiniciá el kubelet y confirmá que vuelve sano:

   ```bash
   sudo systemctl restart kubelet
   sudo systemctl status kubelet --no-pager | head -n 5
   ```

4. Volvé a ejecutar los sondeos anónimos del Ejercicio 1 y confirmá que el comportamiento cambió:

   ```bash
   curl -s http://localhost:10255/pods ; echo        # expect: connection refused
   curl -sk https://localhost:10250/pods/ ; echo      # expect: 401 Unauthorized
   ```

5. Demostrá que un llamador **autorizado** sigue funcionando, usando las propias credenciales del nodo como comprobación:

   ```bash
   sudo curl -s --cacert /etc/kubernetes/pki/ca.crt \
     --cert /var/lib/kubelet/pki/kubelet-client-current.pem \
     --key  /var/lib/kubelet/pki/kubelet-client-current.pem \
     https://localhost:10250/pods/ | head -c 120 ; echo
   ```

**Preguntas de verificación**

4. ¿Por qué se requiere `authorization.mode: Webhook` además de `anonymous.enabled: false`? ¿Qué ataque queda abierto si `mode` se dejara como `AlwaysAllow` incluso con la autenticación anónima deshabilitada?
5. Poner `readOnlyPort: 0` elimina el puerto 10255. Nombrá una pieza de información que un atacante podría extraer de `10255` antes de que fuera deshabilitado.
6. Después del cambio, `kubectl logs` y `kubectl exec` siguen funcionando. ¿Qué componente se autentica ante el kubelet en tu nombre cuando ejecutás esos comandos?

---

## Ejercicio 3 — Alcanzar el servicio de metadatos cloud desde un Pod

La dirección link-local `169.254.169.254` es el Instance Metadata Service (IMDS) del proveedor cloud. Por defecto un Pod hereda la ruta de red del nodo hacia él y puede robar la identidad cloud del nodo.

1. Lanzá un Pod descartable con herramientas de red:

   ```bash
   kubectl run meta-test --image=nicolaka/netshoot --restart=Never -- sleep 3600
   kubectl wait --for=condition=Ready pod/meta-test
   ```

2. Desde dentro del Pod, intentá alcanzar la raíz de metadatos (esto funciona en AWS IMDSv1, y es análogo en otras nubes):

   ```bash
   kubectl exec meta-test -- curl -s --max-time 3 http://169.254.169.254/latest/meta-data/ ; echo
   ```

3. Si estás en AWS con IMDSv1 alcanzable, intentá enumerar el rol IAM del nodo y obtener sus credenciales temporales (este es el ataque real contra el que te estás defendiendo):

   ```bash
   kubectl exec meta-test -- sh -c \
     'R=$(curl -s --max-time 3 http://169.254.169.254/latest/meta-data/iam/security-credentials/); \
      echo "role: $R"; \
      curl -s --max-time 3 http://169.254.169.254/latest/meta-data/iam/security-credentials/$R'
   ```

   > En GCP el equivalente es `curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token`; en Azure, `curl -H Metadata:true "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://management.azure.com/"`. En `kind`/bare-metal no hay IMDS, así que la petición simplemente expira por timeout — ese es el resultado esperado de "no hay nada que robar".

**Preguntas de verificación**

7. ¿Por qué que un Pod pueda leer `169.254.169.254` es un riesgo de escalada de privilegios y no solo una fuga de información?
8. IMDSv2 (AWS) requiere un `PUT` para obtener un token de sesión e impone un límite bajo de saltos IP. ¿Cómo frustra específicamente ese límite de saltos el ataque basado en Pod del paso 3?

---

## Ejercicio 4 — Bloquear el acceso a metadatos con una NetworkPolicy

Tu CNI debe hacer cumplir NetworkPolicy (Calico, Cilium, etc.) para que esto surta efecto. Este es el control principal dentro del clúster que CKS espera que apliques.

1. Escribí una política que permita el egress normal pero que recorte la IP de metadatos como excepción:

   ```yaml
   # deny-metadata.yaml
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
   ```

2. Aplicala y confirmá que existe:

   ```bash
   kubectl apply -f deny-metadata.yaml
   kubectl get networkpolicy deny-cloud-metadata
   ```

3. Volvé a ejecutar el sondeo de metadatos del Ejercicio 3 — ahora debería expirar por timeout o ser rechazado:

   ```bash
   kubectl exec meta-test -- curl -s --max-time 3 http://169.254.169.254/latest/meta-data/ ; echo "exit=$?"
   ```

4. Confirmá que el egress ordinario y el DNS siguen funcionando, para saber que la excepción es quirúrgica y no un deny generalizado:

   ```bash
   kubectl exec meta-test -- nslookup kubernetes.default
   kubectl exec meta-test -- curl -s --max-time 3 -o /dev/null -w '%{http_code}\n' https://kubernetes.io
   ```

5. Limpiá:

   ```bash
   kubectl delete pod meta-test
   ```

**Preguntas de verificación**

9. Esta política usa `ipBlock: 0.0.0.0/0` con un `except`. ¿Por qué es necesario ese patrón acá en lugar de simplemente listar la IP de metadatos bajo una regla de "deny"?
10. Un compañero de equipo aplica el mismo manifiesto pero los Pods siguen alcanzando `169.254.169.254`. Dá dos razones distintas por las que la política podría no estar siendo aplicada.
11. La política apunta a `podSelector: {}` en un namespace. ¿Cuál es la brecha si el clúster tiene 12 namespaces, y cómo la cerrarías a nivel de todo el clúster?
12. Bloquear `169.254.169.254` en la capa de NetworkPolicy es defensa en profundidad. ¿Qué control complementario en la capa *cloud* elimina el riesgo de robo de credenciales incluso si falta la NetworkPolicy?

---

<details>
<summary><strong>Respuestas — clic para expandir</strong></summary>

**Ejercicio 1**

1. **10250** es la API HTTPS completa del kubelet (`/pods`, `/exec`, `/logs`, `/metrics`); está pensada para estar autenticada (certificado de cliente x509 o bearer token) y autorizada. **10255** es el puerto HTTP **read-only** heredado que sirve datos de pods/spec/métricas **sin autenticación** — cualquiera que pueda alcanzarlo lee el estado del clúster. Debería estar deshabilitado (`readOnlyPort: 0`).
2. Un `200` con una lista real de pods significa que el kubelet acepta peticiones **anónimas** y que su modo de autorización efectivamente concede acceso (p. ej. `anonymous.enabled: true` y/o `authorization.mode: AlwaysAllow`). Eso permite que un par de red no autenticado lea pods y potencialmente haga `exec` dentro de contenedores.
3. etcd guarda el estado completo del clúster en texto plano, incluyendo todos los Secrets. El acceso directo de cliente al `2379` sin `client-cert-auth` evita por completo el API server, RBAC, el control de admisión y el registro de auditoría — un atacante puede leer o sobrescribir cualquier objeto, así que es un compromiso total del clúster.

**Ejercicio 2**

4. `anonymous.enabled: false` solo obliga a los llamadores a *presentar una identidad*; no decide qué puede hacer esa identidad. Con `mode: AlwaysAllow`, cualquier identidad autenticada — incluido un token de bajo valor — queda autorizada para toda operación del kubelet. `mode: Webhook` delega la decisión de autorización al API server (SubjectAccessReview), de modo que solo los principals con el RBAC correcto sobre los subrecursos `nodes/*` tienen éxito. Sin eso, la autenticación es irrelevante para la autorización.
5. Cualquiera de estas: la lista completa de pods y sus specs/namespaces en el nodo, el entorno/montajes de los contenedores, las métricas de recursos del nodo y de los pods, o los nombres/imágenes de los contenedores en ejecución — todo útil para reconocimiento y para localizar cargas de trabajo que manejan Secrets.
6. El **kube-apiserver** se autentica ante el kubelet en tu nombre, usando su certificado de cliente de kubelet (`--kubelet-client-certificate`/`--kubelet-client-key`), cuando hace de proxy de las peticiones `logs`/`exec`/`attach`/`port-forward`.

**Ejercicio 3**

7. IMDS devuelve las **credenciales de identidad cloud del nodo** (claves temporales del rol IAM en AWS, el token OAuth de la service account por defecto en GCP, un token de managed identity en Azure). Un Pod que las lea puede llamar a las APIs cloud *como el nodo* — creando recursos, leyendo buckets de almacenamiento, o escalando dentro de la cuenta cloud. Eso es escalada de privilegios fuera del clúster, no solo divulgación.
8. IMDSv2 marca la respuesta del token de sesión con un TTL/límite de saltos IP de 1 por defecto. El tráfico de un Pod hacia `169.254.169.254` se enruta/NATea a través del namespace de red del nodo, agregando un salto, así que la respuesta se descarta antes de llegar al Pod — el contenedor no puede obtener el token de sesión necesario para las lecturas de metadatos posteriores.

**Ejercicio 4**

9. NetworkPolicy no tiene reglas explícitas de "deny" — está basada en listas de permitidos, y el efecto de una política de `Egress` es "denegar todo excepto lo que esté listado". Para mantener funcionando el egress normal mientras se bloquea una dirección, tenés que **permitir un rango amplio y restar la IP de metadatos** vía `ipBlock.except`. Listar la IP como una regla positiva la *permitiría*; no existe un tipo de regla negativa.
10. Dos de estas: (a) el plugin CNI no hace cumplir NetworkPolicy (p. ej. Flannel sin un add-on); (b) la política se creó en el namespace equivocado o los Pods no coinciden con el selector; (c) el tráfico de metadatos recibe SNAT a la IP del nodo antes de la evaluación de la política, o el nodo alcanza IMDS vía host networking que el Pod hereda (los Pods con `hostNetwork: true` eluden la NetworkPolicy de Pod); (d) otra política más permisiva también selecciona a los Pods (las políticas son aditivas/OR, así que otra regla de egress puede volver a permitir la IP).
11. La política solo protege el namespace **`default`**; los Pods de los otros 11 namespaces siguen alcanzando el IMDS. Cerralo aplicando la misma política en **todos los namespaces** (un default por namespace gestionado con GitOps/Kyverno), o usá un control de alcance de clúster como una `GlobalNetworkPolicy` de Calico / `CiliumClusterwideNetworkPolicy` de Cilium que bloquee `169.254.169.254/32` en todos los namespaces.
12. En la capa cloud: imponé **IMDSv2 con un límite de saltos de 1** (AWS) para que los contenedores no puedan alcanzar el endpoint del token, y/o usá identidad cloud por carga de trabajo (IRSA / GKE Workload Identity / Azure Workload Identity) para que el rol del nodo no lleve permisos significativos. Entonces, incluso una llamada de metadatos no bloqueada no rinde nada que valga la pena robar.

</details>