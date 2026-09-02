# CKS 1.3 — Configurar Correctamente Objetos Ingress con TLS

**Dominio:** Cluster Setup · **Peso del examen de esta tarea:** 3 · **Versión del examen:** CKS v1.34

Estos son ejercicios prácticos guiados. Ejecutá cada paso en un cluster de pruebas (kind, minikube, kubeadm) donde tengas libertad para romper cosas. Cada bloque termina con preguntas de comprensión; todas las respuestas están colapsadas al final.

---

## Prerequisitos del laboratorio

Necesitás:

- Un cluster funcionando y un contexto de `kubectl` (`kubectl get nodes` devuelve `Ready`).
- `openssl` y `curl` en tu estación de trabajo.
- Un ingress controller. Estos ejercicios usan **ingress-nginx**, porque es el controller que más comúnmente está presente en entornos estilo CKS. Los conceptos (Secret TLS, `spec.tls`, SNI, mTLS) son portables; las *annotations* no lo son.

> **Nota sobre el ciclo de vida de ingress-nginx:** el proyecto Kubernetes anunció que ingress-nginx está siendo discontinuado en favor de un proyecto sucesor. Los entornos de examen van por detrás de los anuncios, así que seguí practicando con él, pero verificá la versión del controller que tenés delante (`kubectl -n ingress-nginx get deploy ingress-nginx-controller -o jsonpath='{.spec.template.spec.containers[0].image}'`) antes de asumir que una annotation existe.

---

## Ejercicio 0 — Preparar el entorno

1. Instalá el controller ingress-nginx (salteá este paso si tu cluster ya tiene uno):

   ```bash
   kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml
   ```

2. Esperá hasta que el pod del controller esté listo:

   ```bash
   kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=180s
   kubectl -n ingress-nginx get pods -o wide
   ```

3. Confirmá que se registró un `IngressClass` y anotá si es el default:

   ```bash
   kubectl get ingressclass -o wide
   kubectl get ingressclass nginx -o jsonpath='{.metadata.annotations}' ; echo
   ```

4. Averiguá cómo alcanzar el controller desde tu shell. Registrá la IP del nodo y el node port de HTTPS:

   ```bash
   kubectl -n ingress-nginx get svc ingress-nginx-controller

   export NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
   export HTTPS_PORT=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
     -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')
   export HTTP_PORT=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
     -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}')
   echo "$NODE_IP  http=$HTTP_PORT  https=$HTTPS_PORT"
   ```

   Si el Service es `LoadBalancer` con una IP externa real, usá esa IP con los puertos 80/443 en su lugar.

5. Pegale directamente al controller, sin ningún Ingress definido todavía, e inspeccioná el certificado que presenta:

   ```bash
   curl -kv "https://$NODE_IP:$HTTPS_PORT/" 2>&1 | grep -E "subject|issuer|HTTP/"
   ```

6. Creá el namespace de trabajo:

   ```bash
   kubectl create namespace shop
   ```

### Verificación de comprensión — Bloque 0

- **Q0.1** En el paso 5, antes de que crearas ningún Ingress, el controller igual completó un handshake TLS. ¿Qué certificado sirvió, y qué te dice eso sobre cómo maneja nginx una petición cuyo SNI no coincide con ningún Ingress?
- **Q0.2** ¿Cuál es la diferencia entre `IngressClass` y la annotation heredada `kubernetes.io/ingress.class`, y cuál deberías usar en objetos `networking.k8s.io/v1`?
- **Q0.3** Desde el punto de vista de seguridad, ¿por qué es un problema dejar el certificado falso incorporado del controller para tráfico de producción, aunque técnicamente los clientes puedan ignorar la advertencia?

---

## Ejercicio 1 — Construir una CA privada y un certificado de servidor

Vas a actuar como tu propia CA para poder reutilizarla después para autenticación por certificado de cliente.

1. Creá un directorio de laboratorio y generá la clave de la CA y el certificado autofirmado de la CA:

   ```bash
   mkdir -p ~/cks13 && cd ~/cks13

   openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
     -keyout ca.key -out ca.crt \
     -subj "/CN=cks-lab-ca/O=cks-lab"
   ```

2. Generá la clave del servidor y una CSR para `shop.cks.lab`:

   ```bash
   openssl req -nodes -newkey rsa:2048 \
     -keyout shop.key -out shop.csr \
     -subj "/CN=shop.cks.lab/O=cks-lab"
   ```

3. Firmá la CSR con tu CA, agregando las extensiones que un cliente moderno requiere:

   ```bash
   openssl x509 -req -in shop.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
     -out shop.crt -days 90 \
     -extfile <(printf "subjectAltName=DNS:shop.cks.lab\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n")
   ```

4. Inspeccioná lo que produjiste:

   ```bash
   openssl x509 -in shop.crt -noout -subject -issuer -dates -ext subjectAltName,extendedKeyUsage
   ```

5. Verificá la cadena localmente antes de subirla al cluster:

   ```bash
   openssl verify -CAfile ca.crt shop.crt
   ```

6. Confirmá que la clave y el certificado realmente se corresponden (la causa más común de un Ingress roto):

   ```bash
   openssl x509 -in shop.crt -noout -pubkey | openssl sha256
   openssl pkey -in shop.key -pubout      | openssl sha256
   ```

   Los dos digests deben coincidir.

### Verificación de comprensión — Bloque 1

- **Q1.1** Omitiste `subjectAltName` en un primer intento y `curl` igual rechazó el certificado aunque `CN=shop.cks.lab` era correcto. ¿Por qué?
- **Q1.2** ¿Qué restringe `extendedKeyUsage=serverAuth`, y qué pondrías en su lugar para un certificado que un cliente presenta al Ingress?
- **Q1.3** En el paso 6 comparaste dos digests SHA-256. ¿Qué síntoma verías al momento de la petición si no coincidieran?
- **Q1.4** ¿Por qué `-nodes` (sin DES / clave privada sin cifrar) es aceptable acá pero cuestionable fuera de un laboratorio? ¿Cómo condiciona Kubernetes tu elección?

---

## Ejercicio 2 — Crear el Secret TLS y el Ingress

1. Desplegá un backend trivial al cual enrutar:

   ```bash
   kubectl -n shop create deployment shop --image=nginx:1.27-alpine --replicas=2
   kubectl -n shop expose deployment shop --port=80 --target-port=80
   kubectl -n shop get svc shop
   ```

2. Creá el Secret TLS. Aprendé tanto la forma imperativa (rápida en el examen) como la forma con manifiesto:

   ```bash
   kubectl -n shop create secret tls shop-tls --cert=shop.crt --key=shop.key

   # the same thing as YAML, useful when you must edit before applying
   kubectl -n shop create secret tls shop-tls --cert=shop.crt --key=shop.key \
     --dry-run=client -o yaml > shop-tls-secret.yaml
   ```

3. Inspeccioná el objeto que se creó:

   ```bash
   kubectl -n shop get secret shop-tls -o jsonpath='{.type}{"\n"}'
   kubectl -n shop get secret shop-tls -o jsonpath='{.data}' | tr ',' '\n'
   kubectl -n shop get secret shop-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | \
     openssl x509 -noout -subject -dates
   ```

4. Escribí el Ingress:

   ```yaml
   # shop-ingress.yaml
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     name: shop
     namespace: shop
   spec:
     ingressClassName: nginx
     tls:
     - hosts:
       - shop.cks.lab
       secretName: shop-tls
     rules:
     - host: shop.cks.lab
       http:
         paths:
         - path: /
           pathType: Prefix
           backend:
             service:
               name: shop
               port:
                 number: 80
   ```

   ```bash
   kubectl apply -f shop-ingress.yaml
   kubectl -n shop describe ingress shop
   ```

5. Probá la terminación TLS. `--resolve` falsea el DNS para que el SNI y el header Host sean correctos sin editar `/etc/hosts`:

   ```bash
   curl -v --cacert ca.crt \
        --resolve "shop.cks.lab:$HTTPS_PORT:$NODE_IP" \
        "https://shop.cks.lab:$HTTPS_PORT/"
   ```

   Deberías ver `SSL certificate verify ok`, `subject: CN=shop.cks.lab`, y `HTTP/2 200`.

6. Ahora pedí la misma IP con un hostname *distinto* y observá el fallback:

   ```bash
   curl -kv --resolve "other.cks.lab:$HTTPS_PORT:$NODE_IP" \
        "https://other.cks.lab:$HTTPS_PORT/" 2>&1 | grep -E "subject:|issuer:|HTTP/"
   ```

7. Rompelo deliberadamente, y después arreglalo. Copiá el Secret al namespace equivocado y apuntá el Ingress hacia él:

   ```bash
   kubectl create namespace shop-certs
   kubectl -n shop get secret shop-tls -o yaml \
     | sed 's/namespace: shop/namespace: shop-certs/' \
     | kubectl apply -f -

   kubectl -n shop patch ingress shop --type=json \
     -p='[{"op":"replace","path":"/spec/tls/0/secretName","value":"shop-certs/shop-tls"}]'

   curl -kv --resolve "shop.cks.lab:$HTTPS_PORT:$NODE_IP" \
        "https://shop.cks.lab:$HTTPS_PORT/" 2>&1 | grep -E "subject:|issuer:"

   kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=30 | grep -i secret
   ```

   Restaurá el valor correcto:

   ```bash
   kubectl -n shop patch ingress shop --type=json \
     -p='[{"op":"replace","path":"/spec/tls/0/secretName","value":"shop-tls"}]'
   ```

### Verificación de comprensión — Bloque 2

- **Q2.1** ¿Qué hace exactamente `kubectl create secret tls` que `kubectl create secret generic` no hace? Nombrá el `type` resultante y las dos claves obligatorias.
- **Q2.2** En el paso 6, una petición a `other.cks.lab` igual fue respondida sobre TLS. ¿Qué certificado se sirvió, y por qué este comportamiento es una preocupación de fingerprinting/enumeración?
- **Q2.3** El paso 7 falló aunque el Secret existía y contenía un certificado válido. Enunciá la regla sobre la ubicación del Secret respecto del objeto Ingress.
- **Q2.4** `spec.tls[].hosts` y `spec.rules[].host` son campos separados. ¿Qué se rompe si listás un host bajo `rules` pero te olvidás de ponerlo bajo `tls`?
- **Q2.5** `kubectl get secret shop-tls -o yaml` muestra la clave privada codificada en base64. ¿Eso es cifrado? ¿Qué control a nivel de cluster la protege realmente en reposo, y qué la protege de otros usuarios?

---

## Ejercicio 3 — Forzar HTTPS y eliminar el camino en texto plano

1. Confirmá que HTTP plano actualmente funciona o redirige. Observá el comportamiento por defecto:

   ```bash
   curl -v --resolve "shop.cks.lab:$HTTP_PORT:$NODE_IP" \
        "http://shop.cks.lab:$HTTP_PORT/" 2>&1 | grep -E "^< HTTP|^< Location"
   ```

2. Desactivá la redirección explícitamente para ver el estado inseguro, y después restaurala:

   ```bash
   kubectl -n shop annotate ingress shop \
     nginx.ingress.kubernetes.io/ssl-redirect="false" --overwrite

   curl -s --resolve "shop.cks.lab:$HTTP_PORT:$NODE_IP" \
        -o /dev/null -w "%{http_code}\n" "http://shop.cks.lab:$HTTP_PORT/"
   ```

3. Volvé a activar la redirección y hacela incondicional:

   ```bash
   kubectl -n shop annotate ingress shop \
     nginx.ingress.kubernetes.io/ssl-redirect="true" \
     nginx.ingress.kubernetes.io/force-ssl-redirect="true" --overwrite

   curl -v --resolve "shop.cks.lab:$HTTP_PORT:$NODE_IP" \
        "http://shop.cks.lab:$HTTP_PORT/" 2>&1 | grep -E "^< HTTP|^< Location"
   ```

4. Agregá HSTS para que los navegadores rechacen el texto plano por su cuenta, a nivel de todo el cluster:

   ```bash
   kubectl -n ingress-nginx patch configmap ingress-nginx-controller --type=merge -p '{
     "data": {
       "hsts": "true",
       "hsts-max-age": "31536000",
       "hsts-include-subdomains": "true"
     }
   }'
   kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller
   ```

5. Verificá que el header esté presente en la respuesta HTTPS:

   ```bash
   curl -sI --cacert ca.crt --resolve "shop.cks.lab:$HTTPS_PORT:$NODE_IP" \
        "https://shop.cks.lab:$HTTPS_PORT/" | grep -i strict-transport
   ```

### Verificación de comprensión — Bloque 3

- **Q3.1** ¿Cuál es la diferencia práctica entre `ssl-redirect` y `force-ssl-redirect`? ¿Cuándo el `ssl-redirect` simple no hace nada silenciosamente?
- **Q3.2** Una redirección 308 igual significa que la primera petición viajó en texto claro. ¿Qué aprende el atacante de eso, y qué mecanismo cierra esa ventana de la primera petición en visitas *posteriores*?
- **Q3.3** ¿Por qué HSTS con `includeSubDomains` y un max-age de un año es peligroso de habilitar a la ligera en un dominio compartido?
- **Q3.4** Configuraste `hsts` en un ConfigMap en lugar de una annotation. ¿Qué alcance afecta cada cambio, y por qué la vía del ConfigMap requiere verificar la recarga del controller?

---

## Ejercicio 4 — Múltiples hosts, SNI y un certificado por defecto

1. Generá un segundo certificado, esta vez un wildcard para `*.api.cks.lab`:

   ```bash
   cd ~/cks13
   openssl req -nodes -newkey rsa:2048 -keyout api.key -out api.csr \
     -subj "/CN=*.api.cks.lab/O=cks-lab"

   openssl x509 -req -in api.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
     -out api.crt -days 90 \
     -extfile <(printf "subjectAltName=DNS:*.api.cks.lab,DNS:api.cks.lab\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n")

   kubectl -n shop create secret tls api-tls --cert=api.crt --key=api.key
   ```

2. Agregá un segundo host al Ingress con su propia entrada TLS:

   ```yaml
   # shop-ingress-multi.yaml
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     name: shop
     namespace: shop
     annotations:
       nginx.ingress.kubernetes.io/ssl-redirect: "true"
       nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
   spec:
     ingressClassName: nginx
     tls:
     - hosts:
       - shop.cks.lab
       secretName: shop-tls
     - hosts:
       - v1.api.cks.lab
       secretName: api-tls
     rules:
     - host: shop.cks.lab
       http:
         paths:
         - path: /
           pathType: Prefix
           backend:
             service:
               name: shop
               port:
                 number: 80
     - host: v1.api.cks.lab
       http:
         paths:
         - path: /
           pathType: Prefix
           backend:
             service:
               name: shop
               port:
                 number: 80
   ```

   ```bash
   kubectl apply -f shop-ingress-multi.yaml
   ```

3. Demostrá que el SNI selecciona el certificado, no la IP:

   ```bash
   for H in shop.cks.lab v1.api.cks.lab; do
     echo "--- $H"
     curl -s --cacert ca.crt --resolve "$H:$HTTPS_PORT:$NODE_IP" \
          -o /dev/null -w "%{http_code}\n" "https://$H:$HTTPS_PORT/"
     openssl s_client -connect "$NODE_IP:$HTTPS_PORT" -servername "$H" </dev/null 2>/dev/null \
       | openssl x509 -noout -subject
   done
   ```

4. Ahora repetí sin SNI para ver lo que recibe un cliente viejo o un escáner:

   ```bash
   openssl s_client -connect "$NODE_IP:$HTTPS_PORT" -noservername </dev/null 2>/dev/null \
     | openssl x509 -noout -subject -issuer
   ```

5. Reemplazá el certificado de fallback del controller por uno que vos controlás:

   ```bash
   openssl req -x509 -nodes -newkey rsa:2048 -days 90 \
     -keyout default.key -out default.crt \
     -subj "/CN=invalid.cks.lab/O=cks-lab" \
     -addext "subjectAltName=DNS:invalid.cks.lab"

   kubectl -n ingress-nginx create secret tls default-tls \
     --cert=default.crt --key=default.key

   kubectl -n ingress-nginx patch deploy ingress-nginx-controller --type=json -p='[
     {"op":"add","path":"/spec/template/spec/containers/0/args/-",
      "value":"--default-ssl-certificate=ingress-nginx/default-tls"}
   ]'
   kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller
   ```

6. Verificá que el fallback cambió:

   ```bash
   openssl s_client -connect "$NODE_IP:$HTTPS_PORT" -servername unknown.cks.lab </dev/null 2>/dev/null \
     | openssl x509 -noout -subject -issuer
   ```

### Verificación de comprensión — Bloque 4

- **Q4.1** Dos hosts, una IP, dos certificados distintos. ¿Qué extensión de TLS hace esto posible, y en qué punto del handshake el hostname es visible en el cable?
- **Q4.2** ¿Por qué el wildcard `*.api.cks.lab` cubre `v1.api.cks.lab` pero no `api.cks.lab` ni `a.b.api.cks.lab`?
- **Q4.3** Los certificados wildcard son cómodos. Nombrá dos desventajas de seguridad comparados con certificados por host.
- **Q4.4** ¿Cuál es el radio de impacto de un Secret `--default-ssl-certificate` comprometido versus un Secret por Ingress?
- **Q4.5** Dos objetos Ingress en namespaces distintos declaran ambos `host: shop.cks.lab`. ¿Qué hace el controller, y por qué esto es un problema de aislamiento entre tenants?

---

## Ejercicio 5 — Endurecer los parámetros TLS

1. Tomá una línea base de la negociación actual. Verificá qué versiones de protocolo acepta el controller:

   ```bash
   for P in tls1 tls1_1 tls1_2 tls1_3; do
     printf "%-8s " "$P"
     openssl s_client -connect "$NODE_IP:$HTTPS_PORT" -servername shop.cks.lab \
       "-$P" </dev/null >/dev/null 2>&1 && echo ACCEPTED || echo refused
   done
   ```

2. Restringí protocolos y cifradores globalmente en el ConfigMap del controller:

   ```bash
   kubectl -n ingress-nginx patch configmap ingress-nginx-controller --type=merge -p '{
     "data": {
       "ssl-protocols": "TLSv1.3",
       "ssl-ciphers": "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305",
       "ssl-prefer-server-ciphers": "true",
       "ssl-session-tickets": "false"
     }
   }'
   ```

3. Confirmá que la configuración llegó a nginx en sí, no solo al API server:

   ```bash
   kubectl -n ingress-nginx exec deploy/ingress-nginx-controller -- \
     grep -E "ssl_protocols|ssl_ciphers|ssl_session_tickets" /etc/nginx/nginx.conf
   ```

4. Volvé a correr el barrido de protocolos del paso 1 y confirmá que TLS 1.2 y anteriores son rechazados.

5. Intentá sobrescribir el protocolo en un único Ingress y observá qué pasa:

   ```bash
   kubectl -n shop annotate ingress shop \
     nginx.ingress.kubernetes.io/ssl-ciphers="ECDHE-RSA-AES128-GCM-SHA256" --overwrite

   kubectl -n ingress-nginx exec deploy/ingress-nginx-controller -- \
     grep -n "ssl_ciphers" /etc/nginx/nginx.conf | head -20
   ```

6. Reducí la superficie de ataque de annotations del controller:

   ```bash
   kubectl -n ingress-nginx patch configmap ingress-nginx-controller --type=merge -p '{
     "data": {
       "allow-snippet-annotations": "false",
       "annotations-risk-level": "High"
     }
   }'
   kubectl -n ingress-nginx rollout restart deploy/ingress-nginx-controller
   kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller
   ```

7. Demostrá que la restricción funciona intentando inyectar configuración cruda de nginx desde un Ingress namespaced:

   ```bash
   kubectl -n shop annotate ingress shop \
     'nginx.ingress.kubernetes.io/configuration-snippet=more_set_headers "X-Injected: yes";' --overwrite

   kubectl -n shop describe ingress shop | tail -20
   kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=30 | grep -i -E "snippet|annotation"
   ```

   Limpiá la annotation después:

   ```bash
   kubectl -n shop annotate ingress shop \
     nginx.ingress.kubernetes.io/configuration-snippet- \
     nginx.ingress.kubernetes.io/ssl-ciphers- --overwrite
   ```

### Verificación de comprensión — Bloque 5

- **Q5.1** `ssl-protocols` solo se puede configurar en el ConfigMap, mientras que `ssl-ciphers` también existe como annotation por Ingress. ¿Qué implica esa asimetría sobre qué equipo es dueño de la política de protocolos?
- **Q5.2** ¿Por qué importa `ssl-prefer-server-ciphers`, y por qué es mayormente irrelevante una vez que fijás `ssl-protocols: TLSv1.3`?
- **Q5.3** Desactivaste los session tickets de TLS. ¿Qué propiedad mejora eso, y cuál es el costo en rendimiento?
- **Q5.4** Explicá concretamente cómo `configuration-snippet` en un Ingress namespaced puede convertirse en un compromiso a nivel de todo el cluster. ¿Por qué `allow-snippet-annotations: "false"` es un paso de endurecimiento relevante para CKS y no solo prolijidad?
- **Q5.5** En el paso 3 hiciste exec dentro del pod para leer `nginx.conf`. ¿Por qué verificar la configuración renderizada es más confiable que verificar el ConfigMap?

---

## Ejercicio 6 — Autenticación por certificado de cliente (mTLS) en el Ingress

1. Publicá el certificado de la CA que el Ingress usará para validar clientes. El Secret debe vivir en el namespace del Ingress y llevar la clave `ca.crt`:

   ```bash
   cd ~/cks13
   kubectl -n shop create secret generic shop-client-ca --from-file=ca.crt=ca.crt
   kubectl -n shop get secret shop-client-ca -o jsonpath='{.data}' | tr ',' '\n'
   ```

2. Habilitá mTLS en el Ingress:

   ```bash
   kubectl -n shop annotate ingress shop \
     nginx.ingress.kubernetes.io/auth-tls-secret="shop/shop-client-ca" \
     nginx.ingress.kubernetes.io/auth-tls-verify-client="on" \
     nginx.ingress.kubernetes.io/auth-tls-verify-depth="1" \
     nginx.ingress.kubernetes.io/auth-tls-pass-certificate-to-upstream="true" \
     --overwrite
   ```

3. Confirmá que ahora la petición es rechazada sin un certificado de cliente:

   ```bash
   curl -s --cacert ca.crt --resolve "shop.cks.lab:$HTTPS_PORT:$NODE_IP" \
        -o /dev/null -w "%{http_code}\n" "https://shop.cks.lab:$HTTPS_PORT/"
   ```

4. Emití un certificado de cliente desde la misma CA:

   ```bash
   openssl req -nodes -newkey rsa:2048 -keyout client.key -out client.csr \
     -subj "/CN=alice/O=shop-clients"

   openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
     -out client.crt -days 30 \
     -extfile <(printf "basicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=clientAuth\n")

   openssl x509 -in client.crt -noout -subject -ext extendedKeyUsage
   ```

5. Reintentá con el certificado de cliente adjunto:

   ```bash
   curl -s --cacert ca.crt --cert client.crt --key client.key \
        --resolve "shop.cks.lab:$HTTPS_PORT:$NODE_IP" \
        -o /dev/null -w "%{http_code}\n" "https://shop.cks.lab:$HTTPS_PORT/"
   ```

6. Observá lo que recibe el backend, ya que habilitaste el pass-through del certificado:

   ```bash
   kubectl -n shop exec deploy/shop -- sh -c \
     'sed -i "s|location / {|location / { add_header X-Seen-Client \$http_ssl_client_subject_dn always;|" /etc/nginx/conf.d/default.conf && nginx -s reload' 2>/dev/null

   kubectl -n ingress-nginx exec deploy/ingress-nginx-controller -- \
     grep -n "ssl-client-verify\|ssl_client_s_dn\|proxy_set_header ssl-client" /etc/nginx/nginx.conf | head
   ```

7. Cambiá al modo `optional` y mirá la diferencia en quién decide:

   ```bash
   kubectl -n shop annotate ingress shop \
     nginx.ingress.kubernetes.io/auth-tls-verify-client="optional" --overwrite

   curl -s --cacert ca.crt --resolve "shop.cks.lab:$HTTPS_PORT:$NODE_IP" \
        -o /dev/null -w "%{http_code}\n" "https://shop.cks.lab:$HTTPS_PORT/"
   ```

8. Restaurá `on` antes de continuar:

   ```bash
   kubectl -n shop annotate ingress shop \
     nginx.ingress.kubernetes.io/auth-tls-verify-client="on" --overwrite
   ```

### Verificación de comprensión — Bloque 6

- **Q6.1** ¿Por qué el Secret de la CA de clientes debe usar el nombre de clave `ca.crt` y ser un Secret `Opaque`/generic común en vez de `kubernetes.io/tls`?
- **Q6.2** ¿Qué limita `auth-tls-verify-depth: "1"`, y qué ataque habilita una profundidad grande si una CA intermedia está comprometida?
- **Q6.3** Con `auth-tls-verify-client: optional`, una petición no autenticada llega al backend. ¿Qué header debe entonces verificar el backend, y qué pasa si la aplicación lo ignora?
- **Q6.4** `auth-tls-pass-certificate-to-upstream: "true"` reenvía el certificado del cliente como un header de la petición. ¿Por qué es peligroso si el Service del backend también puede alcanzarse directamente desde dentro del cluster (esquivando el Ingress)?
- **Q6.5** mTLS en el Ingress autentica al *cliente frente al borde*. Nombrá el segmento del camino que **no** protege, y qué ejercicio lo aborda.

---

## Ejercicio 7 — Proteger el tráfico detrás del Ingress

La terminación TLS en el borde significa que el tráfico controller→pod es texto plano por defecto. Arreglalo de dos maneras distintas.

1. Dale al backend su propio certificado y hacé que sirva HTTPS:

   ```bash
   cd ~/cks13
   openssl req -nodes -newkey rsa:2048 -keyout backend.key -out backend.csr \
     -subj "/CN=shop.shop.svc.cluster.local/O=cks-lab"

   openssl x509 -req -in backend.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
     -out backend.crt -days 90 \
     -extfile <(printf "subjectAltName=DNS:shop.shop.svc.cluster.local,DNS:shop.shop.svc\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n")

   kubectl -n shop create secret tls backend-tls --cert=backend.crt --key=backend.key
   ```

2. Reconfigurá el nginx del backend para que escuche en 8443 con TLS:

   ```bash
   kubectl -n shop create configmap backend-nginx --from-literal=default.conf='
   server {
     listen 8443 ssl;
     ssl_certificate     /etc/tls/tls.crt;
     ssl_certificate_key /etc/tls/tls.key;
     ssl_protocols       TLSv1.3;
     location / { return 200 "backend over TLS\n"; }
   }
   '

   kubectl -n shop patch deploy shop --type=strategic -p '{
     "spec":{"template":{"spec":{
       "volumes":[
         {"name":"tls","secret":{"secretName":"backend-tls","defaultMode":256}},
         {"name":"conf","configMap":{"name":"backend-nginx"}}
       ],
       "containers":[{"name":"nginx","volumeMounts":[
         {"name":"tls","mountPath":"/etc/tls","readOnly":true},
         {"name":"conf","mountPath":"/etc/nginx/conf.d","readOnly":true}
       ]}]
     }}}
   }'
   kubectl -n shop rollout status deploy/shop
   ```

3. Reapuntá el Service y decile al controller que hable HTTPS hacia arriba:

   ```bash
   kubectl -n shop patch svc shop --type=merge \
     -p '{"spec":{"ports":[{"name":"https","port":443,"targetPort":8443,"protocol":"TCP"}]}}'

   kubectl -n shop annotate ingress shop \
     nginx.ingress.kubernetes.io/backend-protocol="HTTPS" --overwrite

   kubectl -n shop patch ingress shop --type=json \
     -p='[{"op":"replace","path":"/spec/rules/0/http/paths/0/backend/service/port/number","value":443}]'
   ```

4. Probá de punta a punta y confirmá que el controller alcanza el pod sobre TLS:

   ```bash
   curl -s --cacert ca.crt --cert client.crt --key client.key \
        --resolve "shop.cks.lab:$HTTPS_PORT:$NODE_IP" \
        "https://shop.cks.lab:$HTTPS_PORT/"

   kubectl -n ingress-nginx exec deploy/ingress-nginx-controller -- \
     grep -n "proxy_pass https" /etc/nginx/nginx.conf | head
   ```

5. Agregá verificación del upstream, que `backend-protocol: HTTPS` por sí solo **no** hace:

   ```bash
   kubectl -n shop create secret generic upstream-ca --from-file=ca.crt=ca.crt

   kubectl -n shop annotate ingress shop \
     nginx.ingress.kubernetes.io/proxy-ssl-secret="shop/upstream-ca" \
     nginx.ingress.kubernetes.io/proxy-ssl-verify="on" \
     nginx.ingress.kubernetes.io/proxy-ssl-verify-depth="1" \
     nginx.ingress.kubernetes.io/proxy-ssl-name="shop.shop.svc.cluster.local" \
     --overwrite

   kubectl -n ingress-nginx exec deploy/ingress-nginx-controller -- \
     grep -n "proxy_ssl_verify\|proxy_ssl_name\|proxy_ssl_trusted" /etc/nginx/nginx.conf | head
   ```

6. Contrastá con SSL passthrough, donde el controller no termina la conexión en absoluto. Habilitá el flag y leé la advertencia:

   ```bash
   kubectl -n ingress-nginx patch deploy ingress-nginx-controller --type=json -p='[
     {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--enable-ssl-passthrough"}
   ]'
   kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller
   ```

   ```yaml
   # passthrough example — do NOT combine with the mTLS annotations above
   metadata:
     annotations:
       nginx.ingress.kubernetes.io/ssl-passthrough: "true"
       nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
   ```

### Verificación de comprensión — Bloque 7

- **Q7.1** `backend-protocol: "HTTPS"` hace que el controller use `proxy_pass https://…`. ¿Valida el certificado del backend por defecto? ¿Qué agregó el paso 5, y qué annotation provee la CA de confianza?
- **Q7.2** ¿Por qué el SAN del certificado del backend usa `shop.shop.svc.cluster.local` en lugar de `shop.cks.lab`?
- **Q7.3** Con `ssl-passthrough` habilitado, ¿por qué dejan de funcionar para ese host las reglas basadas en path, los headers HTTP, las reglas de WAF y las annotations de mTLS?
- **Q7.4** `ssl-passthrough` enruta por SNI en capa 4 para todo el controller. ¿Por qué habilitarlo es una decisión global con un costo de rendimiento y de observabilidad?
- **Q7.5** Montaste el Secret TLS del backend con `defaultMode: 256`. ¿Cuánto es eso en octal, y por qué importa para una clave privada?

---

## Ejercicio 8 — Asegurar el propio plano de control del Ingress

El Ingress controller es un objetivo de alto valor: guarda cada clave privada TLS que sirve y termina todo el tráfico externo.

1. Inspeccioná qué está realmente autorizado a leer el controller:

   ```bash
   kubectl -n ingress-nginx get sa
   kubectl get clusterrole ingress-nginx -o yaml | grep -A8 "secrets"
   kubectl auth can-i get secrets --all-namespaces \
     --as=system:serviceaccount:ingress-nginx:ingress-nginx
   ```

2. Enumerá cada Secret TLS que el controller podría alcanzar — este es el radio de impacto de un pod comprometido:

   ```bash
   kubectl get secrets --all-namespaces --field-selector type=kubernetes.io/tls
   ```

3. Reducí el alcance con `--watch-namespace` (controllers de un solo tenant) o verificá si tu despliegue ya lo limita:

   ```bash
   kubectl -n ingress-nginx get deploy ingress-nginx-controller \
     -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n'
   ```

4. Revisá el admission webhook. Es el componente detrás de CVE-2025-1974 ("IngressNightmare"), donde objetos Ingress manipulados podían llevar a ejecución remota de código en el controller:

   ```bash
   kubectl get validatingwebhookconfiguration ingress-nginx-admission -o yaml \
     | grep -E "name:|clientConfig:|service:|port:|failurePolicy:"

   kubectl -n ingress-nginx get svc ingress-nginx-controller-admission
   ```

   Mitigaciones que deberías saber nombrar: correr una versión parcheada del controller; asegurar que el Service de admission no sea alcanzable desde pods arbitrarios; y si no usás el webhook, eliminar el `ValidatingWebhookConfiguration` y los args `--validating-webhook`.

5. Restringí quién puede alcanzar el endpoint de admission con una NetworkPolicy:

   ```yaml
   # ingress-admission-netpol.yaml
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: admission-webhook-lockdown
     namespace: ingress-nginx
   spec:
     podSelector:
       matchLabels:
         app.kubernetes.io/component: controller
     policyTypes: ["Ingress"]
     ingress:
     - ports:
       - protocol: TCP
         port: 80
       - protocol: TCP
         port: 443
   ```

   ```bash
   kubectl apply -f ingress-admission-netpol.yaml
   ```

   Notá que el puerto 8443 (admission) está deliberadamente ausente, así que solo el camino del API server que permitas explícitamente — o ninguno, si eliminaste el webhook — puede alcanzarlo.

6. Verificá la postura de ejecución del propio controller:

   ```bash
   kubectl -n ingress-nginx get deploy ingress-nginx-controller \
     -o jsonpath='{.spec.template.spec.containers[0].securityContext}' | python3 -m json.tool
   ```

7. Confirmá qué usuarios pueden crear objetos Ingress en absoluto, ya que un Ingress es una concesión de autoridad de enrutamiento:

   ```bash
   kubectl auth can-i create ingresses -n shop --as=system:serviceaccount:shop:default
   kubectl get clusterrolebindings -o json \
     | grep -B5 -A5 "edit" | head -40
   ```

### Verificación de comprensión — Bloque 8

- **Q8.1** El ClusterRole por defecto de ingress-nginx puede leer Secrets en todo el cluster. Explicá el camino exacto de escalada desde "el atacante obtiene RCE en el pod del controller" hasta "el atacante suplanta a cada sitio HTTPS detrás de este controller".
- **Q8.2** ¿Qué dos cambios de configuración reducen más directamente ese radio de impacto, y qué funcionalidad resignás con cada uno?
- **Q8.3** ¿Por qué está `NET_BIND_SERVICE` en la lista de capabilities del controller, y por qué es aceptable mientras que `allowPrivilegeEscalation: true` no lo sería?
- **Q8.4** Un desarrollador con `edit` en el namespace `shop` crea un Ingress que reclama `host: payments.cks.lab`, un hostname propiedad de otro equipo. ¿Qué pasó efectivamente, y qué control en tiempo de admisión (nombrá uno) lo previene?
- **Q8.5** ¿Por qué eliminar un `ValidatingWebhookConfiguration` sin uso cuenta como reducción de superficie de ataque y no como un parche?

---

## Ejercicio 9 — Práctica de troubleshooting

Trabajá estos tres escenarios rotos de punta a punta. Rompé, diagnosticá a partir de la evidencia, y después arreglá.

1. **Escenario A — par de claves equivocado.** Poné una clave que no corresponde y observá:

   ```bash
   cd ~/cks13
   openssl genrsa -out wrong.key 2048
   kubectl -n shop create secret tls shop-tls --cert=shop.crt --key=wrong.key \
     --dry-run=client -o yaml | kubectl apply -f -

   kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=40 | grep -i -E "error|certificate|key"
   openssl s_client -connect "$NODE_IP:$HTTPS_PORT" -servername shop.cks.lab </dev/null 2>/dev/null \
     | openssl x509 -noout -subject
   ```

   Arreglo:

   ```bash
   kubectl -n shop create secret tls shop-tls --cert=shop.crt --key=shop.key \
     --dry-run=client -o yaml | kubectl apply -f -
   ```

2. **Escenario B — certificado expirado.** Emití un certificado que ya está expirado y observá cómo difiere la falla respecto del Escenario A:

   ```bash
   openssl x509 -req -in shop.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
     -out expired.crt -days -1 \
     -extfile <(printf "subjectAltName=DNS:shop.cks.lab\nbasicConstraints=CA:FALSE\n")

   kubectl -n shop create secret tls shop-tls --cert=expired.crt --key=shop.key \
     --dry-run=client -o yaml | kubectl apply -f -

   curl -sv --cacert ca.crt --cert client.crt --key client.key \
        --resolve "shop.cks.lab:$HTTPS_PORT:$NODE_IP" \
        "https://shop.cks.lab:$HTTPS_PORT/" 2>&1 | grep -iE "expire|certificate|SSL"

   # audit every TLS secret's expiry
   kubectl get secrets -A --field-selector type=kubernetes.io/tls \
     -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{.data.tls\.crt}{"\n"}{end}' \
   | while IFS=$'\t' read -r NAME CRT; do
       END=$(echo "$CRT" | base64 -d | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
       printf "%-40s %s\n" "$NAME" "$END"
     done
   ```

   Arreglalo restaurando el certificado válido.

3. **Escenario C — IngressClass equivocada o ausente.** Quitá la clase y diagnosticá la falla silenciosa:

   ```bash
   kubectl -n shop patch ingress shop --type=json \
     -p='[{"op":"remove","path":"/spec/ingressClassName"}]'

   kubectl -n shop get ingress shop
   kubectl -n shop describe ingress shop | grep -A5 Events
   kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=20
   ```

   Arreglo:

   ```bash
   kubectl -n shop patch ingress shop --type=merge \
     -p '{"spec":{"ingressClassName":"nginx"}}'
   kubectl -n shop get ingress shop -o wide
   ```

4. **Rotación sin caída de servicio.** Confirmá que el controller toma un certificado nuevo solo con actualizar el Secret:

   ```bash
   openssl req -nodes -newkey rsa:2048 -keyout shop2.key -out shop2.csr \
     -subj "/CN=shop.cks.lab/O=cks-lab-rotated"
   openssl x509 -req -in shop2.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
     -out shop2.crt -days 90 \
     -extfile <(printf "subjectAltName=DNS:shop.cks.lab\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n")

   kubectl -n shop create secret tls shop-tls --cert=shop2.crt --key=shop2.key \
     --dry-run=client -o yaml | kubectl apply -f -

   sleep 5
   openssl s_client -connect "$NODE_IP:$HTTPS_PORT" -servername shop.cks.lab </dev/null 2>/dev/null \
     | openssl x509 -noout -subject -serial
   ```

### Verificación de comprensión — Bloque 9

- **Q9.1** En el Escenario A el endpoint siguió respondiendo TLS. ¿Qué certificado se sirvió, y por qué "el sitio sigue funcionando sobre HTTPS" es una señal de salud engañosa?
- **Q9.2** El Escenario B falla en el cliente, no en el controller. ¿Por qué el controller carga sin problema un certificado expirado, y qué te dice eso sobre dónde debe vivir el monitoreo de expiración?
- **Q9.3** En el Escenario C el objeto Ingress existía y fue aceptado por el API server, y sin embargo nada enrutaba. ¿Qué significa una columna `ADDRESS` vacía, y por qué normalmente no hay ningún evento de error?
- **Q9.4** El paso 4 rotó el certificado sin reiniciar ningún pod. ¿Qué comportamiento del controller lo hace posible, y qué implicancia tiene para un controller corriendo con `--watch-namespace`?
- **Q9.5** Escribí el one-liner que correrías en el examen para listar cada Secret `kubernetes.io/tls` del cluster junto con su subject y su expiración.

---

## Limpieza

```bash
kubectl delete namespace shop shop-certs --ignore-not-found
kubectl -n ingress-nginx delete secret default-tls --ignore-not-found
kubectl delete -f ingress-admission-netpol.yaml --ignore-not-found
rm -rf ~/cks13
```

---

<details>
<summary><strong>Respuestas</strong></summary>

### Bloque 0

**A0.1** Sirvió el certificado *falso* autofirmado incorporado de ingress-nginx (issuer/subject típicamente `Kubernetes Ingress Controller Fake Certificate`). nginx debe completar el handshake TLS antes de poder leer el header HTTP `Host`, así que siempre necesita *algún* certificado. Cuando el SNI no coincide con ningún server block configurado, cae al certificado por defecto y luego generalmente devuelve `404`. La lección: un handshake exitoso no prueba nada sobre si tu Ingress está bien conectado.

**A0.2** `IngressClass` es un objeto real de la API, de alcance de cluster, referenciado por `spec.ingressClassName`; nombra un controller (`spec.controller: k8s.io/ingress-nginx`) y puede llevar parámetros. La annotation `kubernetes.io/ingress.class` es el mecanismo previo a 1.18, deprecado y honrado solo por algunos controllers por compatibilidad hacia atrás. En `networking.k8s.io/v1` usá siempre `spec.ingressClassName`. Un `IngressClass` anotado con `ingressclass.kubernetes.io/is-default-class: "true"` se aplica a los Ingress que omiten el campo — cómodo, pero también significa que un nombre de clase mal tipeado se comporta muy distinto de uno ausente.

**A0.3** Los clientes no pueden distinguir el certificado falso del controller del certificado autofirmado de un atacante, así que los usuarios se acostumbran a hacer clic para pasar por encima de las advertencias, y cualquier herramienta que configure `--insecure`/`InsecureSkipVerify` para lidiar con eso pierde la protección contra MITM de forma permanente. Además filtra que el endpoint es un ingress-nginx sin configurar, lo cual es reconocimiento útil.

### Bloque 1

**A1.1** Desde aproximadamente 2017 todos los clientes TLS principales (y crypto/tls de Go, que usa la mayoría del tooling de Kubernetes) ignoran por completo el `CN` para la verificación de hostname y requieren una entrada DNS coincidente en `subjectAltName` (RFC 6125 / CA-Browser Forum). Un certificado que solo tiene CN se trata como si no tuviera nombres válidos.

**A1.2** `extendedKeyUsage=serverAuth` marca el certificado como válido para autenticar a un *servidor* durante TLS. Un verificador que aplique EKU lo rechazará si se presenta como credencial de cliente. Para un certificado de cliente ponés `extendedKeyUsage=clientAuth` (como se hace en el Ejercicio 6, paso 4). Restringir el EKU evita que un único par de claves filtrado sea utilizable en ambas direcciones.

**A1.3** nginx no lograría cargar el par de claves. Según la versión y el momento, o bien ves que el controller registra un error y mantiene el certificado previo/de fallback, o bien el server block nunca se materializa — desde afuera parece "se está sirviendo el certificado equivocado" o una falla de handshake, no un error de configuración obvio. Eso es exactamente el Escenario A del Ejercicio 9.

**A1.4** `-nodes` escribe la clave privada sin cifrar. Fuera de un laboratorio, normalmente protegerías una clave en reposo con una passphrase o un HSM/KMS. Kubernetes te fuerza la mano: el kubelet debe poder montar la clave y nginx debe leerla de forma no interactiva, así que un Secret `kubernetes.io/tls` **debe** contener una clave PEM sin cifrar. La protección, por lo tanto, tiene que venir de otro lado — cifrado de etcd en reposo, RBAC sobre el Secret, y una vida corta del certificado.

### Bloque 2

**A2.1** `kubectl create secret tls` crea un Secret de tipo `kubernetes.io/tls` y exige la presencia exacta de las claves `tls.crt` y `tls.key`; el API server valida que ambas estén presentes para ese tipo. Un Secret generic tiene tipo `Opaque` y ninguna restricción de claves, así que un Ingress que lo referencie no encontrará los datos esperados.

**A2.2** El certificado por defecto del controller (el falso, o `default-tls` después del Ejercicio 4). Como *todo* SNI sin coincidencia recibe el mismo fallback, un escáner puede recorrer una lista de hostnames contra una sola IP y distinguir los hosts configurados de los no configurados puramente por qué certificado vuelve — un oráculo de enumeración gratuito para tus hostnames internos.

**A2.3** `spec.tls[].secretName` se resuelve **en el namespace propio del Ingress**. Un string `namespace/name` no es válido ahí (a diferencia de algunas annotations como `auth-tls-secret`, que *sí* toman `namespace/name`). El Secret debe copiarse a, o crearse en, el mismo namespace que el Ingress. Esto es aislamiento deliberado: impide que el namespace A monte por referencia la clave privada del namespace B.

**A2.4** El enrutamiento sigue funcionando, pero ese host no obtiene certificado propio — nginx le sirve el certificado por defecto/de fallback, así que los clientes ven un error de nombre no coincidente. `rules` controla el *enrutamiento*; `tls` controla *qué certificado se presenta para qué SNI*. Son independientes y ambos son necesarios.

**A2.5** Base64 es codificación, no cifrado — es trivialmente reversible y ofrece cero confidencialidad. En reposo, la protección viene de los **proveedores de cifrado de etcd** (`EncryptionConfiguration` con, por ejemplo, `aescbc`/`kms`, referenciado por `--encryption-provider-config` en el API server); sin eso la clave queda en texto plano en etcd. Frente a otros usuarios, la protección viene de **RBAC**: cualquiera con `get` sobre Secrets en ese namespace — incluyendo cualquier ServiceAccount con `edit`/`admin`, y cualquier pod que pueda montar el Secret — lee la clave privada.

### Bloque 3

**A3.1** `ssl-redirect` (por defecto `true`) redirige HTTP→HTTPS **solo cuando el host tiene un certificado TLS configurado** para él. Si falta `spec.tls` o el Secret no se pudo cargar, silenciosamente no hace nada y se sirve texto plano. `force-ssl-redirect` redirige incondicionalmente, sin importar si hay TLS configurado para ese host — por eso es la opción más segura cuando querés una garantía dura.

**A3.2** La primera petición expone la URL completa, el header `Host`, las cookies enviadas por HTTP plano, y la intención del cliente — y un MITM activo puede simplemente responderla en lugar de redirigir (SSL stripping), sin dejar nunca que el cliente llegue a HTTPS. **HSTS** cierra la ventana para las visitas *posteriores* instruyendo al navegador a convertir `http://` en `https://` localmente antes de que salga ningún paquete. El preload de HSTS cierra incluso la primerísima visita.

**A3.3** La directiva se aplica a todo el dominio registrable y a todo lo que cuelga de él, cacheada por los navegadores durante la duración declarada y no fácilmente revocable — limpiarla requiere visitar cada host afectado y enviar una política `max-age=0`, lo cual es imposible si un subdominio no tiene HTTPS funcionando en absoluto. En un dominio compartido podés tirar abajo el servicio HTTP plano de un equipo hermano sin ningún rollback rápido.

**A3.4** El ConfigMap (`ingress-nginx-controller` en el namespace del controller) se aplica a **todos** los Ingress servidos por ese controller; las annotations se aplican a un **único** Ingress. Los cambios del ConfigMap son tomados por el controller y disparan una recarga de configuración — pero un valor mal formado puede hacer que la recarga falle, dejando corriendo la configuración vieja, así que tenés que confirmar que el cambio realmente aterrizó (`rollout status`, logs del controller, o grepeando el `nginx.conf` renderizado) en lugar de asumirlo.

### Bloque 4

**A4.1** **SNI** (Server Name Indication, RFC 6066). El cliente envía el hostname de destino en el **ClientHello**, es decir, en *texto claro*, antes de que se negocie cualquier cifrado. Eso es lo que le permite a nginx elegir el certificado correcto — y también lo que le permite a un observador de red ver qué sitio estás visitando incluso sobre TLS (el problema que Encrypted Client Hello busca resolver).

**A4.2** Un wildcard coincide con exactamente **una** etiqueta, y solo en la posición más a la izquierda. `v1` es una etiqueta bajo `api.cks.lab` → coincide. `api.cks.lab` es el dominio pelado sin etiqueta izquierda que sustituir → no coincide (por eso la lista de SAN también lo incluye explícitamente). `a.b.api.cks.lab` necesita dos etiquetas → no coincide.

**A4.3** (1) **Radio de impacto**: una clave filtrada compromete todos los hosts actuales y futuros bajo ese dominio, y la revocación los tira abajo a todos de una vez. (2) **Exposición del eslabón más débil**: la clave debe distribuirse a cada host/controller que sirva cualquier subdominio, así que el consumidor menos endurecido fija el nivel de seguridad para todos ellos — y cualquier toma de control de un subdominio obtiene instantáneamente un certificado válido. (Además: los wildcards no pueden emitirse con nivel de Extended Validation y no ofrecen granularidad de revocación por host.)

**A4.4** El certificado por defecto se usa para todo SNI sin coincidencia en todo el controller y típicamente vive en el namespace del controller, así que comprometerlo afecta a todos los hosts que caen al fallback — además señala que el atacante ya tiene acceso de lectura en el namespace del ingress-controller, que es donde están también todas las demás claves. Un Secret por Ingress compromete exactamente un hostname y requiere acceso a ese único namespace.

**A4.5** ingress-nginx fusiona las configuraciones y, por defecto, gana el server block en conflicto el Ingress **más viejo** (por timestamp de creación); las reglas del otro pueden ser ignoradas parcial o totalmente, y el certificado servido puede venir del Secret del ganador. Esto es un problema de aislamiento entre tenants porque nada en Kubernetes vanilla impide que el namespace B reclame el hostname del namespace A — la propiedad de un hostname no es un recurso controlado por RBAC. Mitigaciones: controllers separados por tenant, `--watch-namespace`, o una política de admisión (ValidatingAdmissionPolicy / Kyverno / Gatekeeper) que ate sufijos de hostname a namespaces.

### Bloque 5

**A5.1** La versión del protocolo es una política **global y no delegable**: se compila dentro del bloque compartido `http {}` de `nginx.conf`, así que un tenant de un solo namespace no puede debilitarla. Los cifradores se pueden configurar por Ingress, lo que significa que un tenant *sí puede* debilitar el conjunto de cifradores para su propio host. La implicancia: el equipo de plataforma/seguridad es dueño del piso de protocolo vía el ConfigMap, y si la política de cifradores te importa, además tenés que bloquear o restringir la annotation `ssl-ciphers` (vía `annotations-risk-level` o una política de admisión) en lugar de confiar en los tenants.

**A5.2** En TLS 1.2 y anteriores, `ssl_prefer_server_ciphers on` hace que el orden de cifradores del *servidor* sea el autoritativo en lugar del del cliente, evitando que un cliente (o un atacante que fuerce un downgrade) dirija la conexión hacia una suite débil. TLS 1.3 eliminó el problema de los cifradores débiles negociables — sus cinco suites AEAD son todas fuertes y el handshake fue rediseñado — así que la directiva no tiene efecto significativo una vez que fijás `TLSv1.3`.

**A5.3** Mejora la **forward secrecy**. Los session tickets cifran el estado de reanudación con una clave que guarda el servidor; si esa clave no se rota con frecuencia (nginx por defecto no la rota durante la vida del proceso) un atacante que la obtenga después puede descifrar sesiones grabadas, deshaciendo la forward secrecy que provee ECDHE. El costo es que la reanudación cae al caché de sesión del lado del servidor o se pierde por completo, así que más conexiones pagan un handshake completo — CPU extra y un round trip adicional.

**A5.4** `configuration-snippet` inyecta directivas crudas de nginx en el `nginx.conf` renderizado del controller **compartido**. Cualquiera que pueda crear o editar un Ingress en *cualquier* namespace observado puede, por lo tanto, inyectar directivas que afectan a otros tenants: leer archivos arbitrarios del filesystem del controller (incluido el token de ServiceAccount montado en `/var/run/secrets/kubernetes.io/serviceaccount/token`), hacer proxy hacia endpoints internos, registrar el tráfico de otros hosts, o con bloques `lua` ejecutar código. Dado que la ServiceAccount del controller típicamente puede leer Secrets en todo el cluster, ese es un camino directo desde `edit` a nivel de namespace hasta la divulgación de secretos en todo el cluster. `allow-snippet-annotations: "false"` (el valor por defecto desde ingress-nginx v1.12) elimina la primitiva por completo; `annotations-risk-level` además rechaza annotations por encima del nivel de riesgo configurado.

**A5.5** El ConfigMap registra tu *intención*; `nginx.conf` registra lo que nginx está aplicando realmente. Entre los dos hay renderizado de plantillas, validación de valores, y una recarga que puede fallar — una clave mal tipeada se ignora silenciosamente, un valor inválido puede abortar la recarga y dejar la configuración anterior sirviendo tráfico. Solo el archivo renderizado (o una sonda externa de handshake) es evidencia.

### Bloque 6

**A6.1** ingress-nginx busca la clave fija `ca.crt` en el Secret referenciado y la escribe como el almacén de confianza `ssl_client_certificate`; cualquier otro nombre de clave produce "secret does not contain 'ca.crt'" en el log del controller. No puede ser `kubernetes.io/tls`, porque ese tipo requiere `tls.crt`/`tls.key` — y deliberadamente no querés la *clave privada* de la CA en ningún lugar cerca del cluster. (El mismo Secret puede llevar opcionalmente `ca.crl` para revocación.)

**A6.2** Limita el largo de la cadena de certificados que nginx va a seguir al validar un certificado de cliente. Profundidad `1` significa que el certificado de cliente debe estar firmado directamente por una CA de tu almacén de confianza. Una profundidad grande significa que cualquier intermedia en cualquier parte de la cadena — incluida una que no pretendías confiar — puede acuñar certificados de cliente que validen, así que una única intermedia comprometida o demasiado permisiva se convierte silenciosamente en un bypass de autenticación para todo tu Ingress.

**A6.3** `ssl-client-verify` (reenviado por ingress-nginx como header de la petición, junto con `ssl-client-subject-dn`, `ssl-client-issuer-dn`, y el certificado mismo cuando el pass-through está activado). Su valor es `SUCCESS`, `FAILED:<reason>`, o `NONE`. Si la aplicación lo ignora, `optional` es funcionalmente equivalente a no tener autenticación en absoluto: las peticiones no autenticadas llegan al backend y son servidas. `optional` mueve la decisión de autorización del borde a la app — lo cual solo es seguro si la app efectivamente la toma.

**A6.4** Porque el certificado llega como un header HTTP común, cualquier cliente que pueda alcanzar directamente el Service o la IP del Pod del backend puede **falsificar ese header** y suplantar a un usuario autenticado — el backend no tiene forma de distinguir un header puesto por el Ingress confiable de uno puesto por un pod atacante. Pasar certificados hacia arriba solo es seguro cuando una NetworkPolicy restringe al backend a aceptar tráfico exclusivamente de los pods del ingress-controller (o una capa de mesh/mTLS autentica ese salto).

**A6.5** No protege el salto **controller → Pod del backend**, que es HTTP en texto plano por defecto incluso cuando la conexión externa es TLS 1.3 con autenticación mutua. El Ejercicio 7 lo aborda, con `backend-protocol: HTTPS` más `proxy-ssl-verify`, o con `ssl-passthrough`, o colocando un sidecar de service mesh en ese salto.

### Bloque 7

**A7.1** **No.** `backend-protocol: "HTTPS"` solo cambia el esquema en `proxy_pass`; `proxy_ssl_verify` de nginx por defecto está en `off`, así que el controller acepta *cualquier* certificado del upstream — incluido el de un atacante, lo que significa que el salto está cifrado pero no autenticado y sigue siendo susceptible a MITM dentro del cluster. El paso 5 agregó `proxy-ssl-verify: "on"` con `proxy-ssl-verify-depth` y `proxy-ssl-name`; la CA de confianza viene de `nginx.ingress.kubernetes.io/proxy-ssl-secret` (una referencia `namespace/name` a un Secret que contiene `ca.crt`).

**A7.2** La validación de certificados coincide con el nombre que usó el *cliente de esa conexión* para conectarse. En el salto controller→backend el cliente es nginx y el destino es el nombre DNS del Service dentro del cluster (o el valor fijado vía `proxy-ssl-name`), no el hostname público que usó el navegador. `shop.cks.lab` solo es relevante para el salto externo, que el Ingress ya terminó.

**A7.3** Con passthrough el controller nunca descifra la conexión — inspecciona solo el SNI del ClientHello y después canaliza bytes TCP crudos hacia el backend. Todo lo que está aguas abajo del descifrado queda por lo tanto no disponible: paths, métodos, headers, cookies, inyección de headers, inspección de WAF/ModSecurity, y mTLS en el borde (no hay nada que terminar, así que la verificación del certificado de cliente debe moverse al backend). El backend pasa a ser el único responsable de TLS y de la autenticación.

**A7.4** `--enable-ssl-passthrough` es un flag a nivel de controller: habilitarlo inserta un listener proxy TCP que lee SNI por delante de los listeners HTTP normales, así que **todo** el tráfico a través de ese controller da un salto extra, incluso los hosts que no usan passthrough. Costos: latencia y CPU añadidas para cada conexión, pérdida de logs de acceso y métricas de L7 para los hosts con passthrough (no podés registrar lo que no podés leer), y la pérdida de WAF/rate-limiting en el borde para ellos. Preferí una instancia de controller separada para las cargas con passthrough.

**A7.5** `256` decimal es `0400` octal — solo lectura para el propietario, sin acceso para grupo ni otros. El `defaultMode` de Kubernetes toma un entero decimal en JSON (en YAML, `0400` es octal solo si no está entre comillas y se interpreta así, un footgun clásico). Importa porque una clave privada legible por grupo/otros es legible por cualquier proceso o sidecar del pod, y muchas librerías y herramientas TLS advierten o directamente rechazan claves legibles por todo el mundo.

### Bloque 8

**A8.1** El ClusterRole por defecto `ingress-nginx` concede `get`/`list`/`watch` sobre `secrets` en todo el cluster (debe hacerlo, para cargar Secrets TLS de namespaces arbitrarios). Un atacante con ejecución de código en el pod del controller lee el token de ServiceAccount montado en `/var/run/secrets/kubernetes.io/serviceaccount/token`, lo usa contra el API server, y lista cada Secret `kubernetes.io/tls` del cluster — obteniendo las **claves privadas** de cada host que el controller expone. Con esas claves puede descifrar tráfico capturado donde no hay forward secrecy, y suplantar cualquiera de esos sitios con un certificado que valida contra la CA pública real. El mismo token típicamente también concede lectura sobre ConfigMaps y Endpoints, extendiendo el reconocimiento.

**A8.2** (1) **`--watch-namespace=<ns>`** más un Role namespaced en lugar de un ClusterRole: el controller solo puede leer Secrets de un namespace. Resignás servir múltiples namespaces desde un solo controller, así que tenés que correr un controller por tenant (más IPs, más costo de recursos). (2) **Eliminar/blindar el admission webhook** y poner `allow-snippet-annotations: "false"` con un `annotations-risk-level` restrictivo: perdés la validación previa a la admisión de los objetos Ingress (las configuraciones malas fallan en la recarga en vez de en el `kubectl apply`) y perdés la personalización basada en snippets. Ambos reducen significativamente el camino desde "el tenant puede crear un Ingress" hasta "el tenant lee todas las claves".

**A8.3** `NET_BIND_SERVICE` permite hacer bind a puertos privilegiados (<1024) para que nginx pueda escuchar en 80/443 mientras corre con un UID no root. Es una capability estrecha, de propósito único, que no concede ninguna capacidad de leer la memoria de otros procesos, cargar módulos, ni escapar del contenedor. `allowPrivilegeEscalation: true` es categóricamente distinto: permite que un proceso gane capabilities que su padre no tenía (vía binarios setuid o file capabilities), lo que convierte cualquier ejecución de código dentro del contenedor en un compromiso mucho más amplio y socava toda la postura de no-root.

**A8.4** Secuestraron el enrutamiento de un hostname que no les pertenece — cada petición a `payments.cks.lab` que llegue a este controller puede ahora enviarse a su backend, permitiéndoles hacer phishing de credenciales o capturar cookies de sesión con un certificado que el controller sirve alegremente desde el Secret de *su* namespace. RBAC de Kubernetes no tiene ningún concepto de propiedad de hostnames. La prevención requiere política en tiempo de admisión: una **ValidatingAdmissionPolicy** (CEL, incorporada desde 1.30) o una regla de Kyverno/Gatekeeper que exija que `spec.rules[*].host` coincida con un sufijo permitido para el namespace del objeto — o separar físicamente a los tenants en sus propios controllers con `--watch-namespace`.

**A8.5** Un parche arregla el bug *conocido* en un componente que seguís ejecutando; eliminar el webhook borra por completo la exposición del componente, así que también queda inmune al próximo bug desconocido en ese mismo camino de código. CVE-2025-1974 era alcanzable porque el endpoint de admission aceptaba conexiones y procesaba contenido de Ingress influido por el atacante; un cluster sin `ValidatingWebhookConfiguration` y sin listener de admission no tenía nada que alcanzar. La defensa en profundidad pone "el código no está corriendo" por encima de "el código está corriendo, parcheado".

### Bloque 9

**A9.1** El controller no pudo cargar el par no coincidente y cayó al certificado por defecto (el falso o `default-tls`) para ese server block, así que el handshake igual tuvo éxito — con la identidad *equivocada*. "HTTPS responde" solo prueba que se presentó un certificado, no que fuera *tu* certificado para *ese* host. El monitoreo debe verificar el subject/SAN y el issuer del certificado servido, no solo que el puerto 443 responda.

**A9.2** nginx valida la *estructura* de un certificado (PEM parseable, coincidencia de clave) al momento de cargarlo, no su ventana de validez — la expiración es una decisión de la **parte confiante** que toma el cliente en el handshake (`certificate has expired`, curl con código de salida 60). Así que el controller se reporta sano y la recarga de configuración tiene éxito. El monitoreo de expiración, por lo tanto, no puede vivir en el controller: le corresponde a un chequeo externo que decodifique cada Secret `kubernetes.io/tls` y alerte sobre `notAfter`, o a la emisión automatizada (cert-manager) que renueve bastante antes del vencimiento.

**A9.3** Un `ADDRESS` vacío significa que **ningún controller reclamó el objeto** — nada escribió `status.loadBalancer.ingress`. No hay evento de error porque, desde la perspectiva del API server, el objeto es perfectamente válido; la spec de Ingress simplemente no requiere que exista ningún controller. Los controllers solo emiten eventos para los Ingress que poseen, y este no posee ninguno, así que tanto los eventos del objeto como el log del controller están en silencio. La ausencia de dirección es la señal diagnóstica. (La misma falla silenciosa ocurre con un nombre de clase que no coincide con ningún `IngressClass`.)

**A9.4** El controller **observa** (watch) los objetos Secret a través del API server y re-renderiza/recarga nginx ante un cambio — el material TLS no está horneado dentro del pod, así que la rotación es una actualización del plano de datos sin reinicio y sin conexiones caídas. Para un controller corriendo con `--watch-namespace`, el watch está acotado a ese namespace: un Secret actualizado fuera de él nunca es observado, así que la rotación de certificados de un host debe ocurrir en un namespace que el controller realmente observe, y la distribución de certificados entre namespaces (por ejemplo, cert-manager emitiendo dentro de cada namespace de tenant) pasa a ser obligatoria en vez de opcional.

**A9.5**

```bash
kubectl get secrets -A --field-selector type=kubernetes.io/tls \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{.data.tls\.crt}{"\n"}{end}' \
| while IFS=$'\t' read -r N C; do
    echo "$N  $(echo "$C" | base64 -d | openssl x509 -noout -subject -enddate | tr '\n' ' ')"
  done
```

</details>

---

## Fuentes de referencia

- CNCF, *Certified Kubernetes Security Specialist (CKS) Curriculum v1.34* — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Documentación de Kubernetes, *Ingress* — https://kubernetes.io/docs/concepts/services-networking/ingress/
- Documentación de Kubernetes, *Ingress Controllers* — https://kubernetes.io/docs/concepts/services-networking/ingress-controllers/
- Documentación de Kubernetes, *Secrets — TLS Secrets* — https://kubernetes.io/docs/concepts/configuration/secret/#tls-secrets
- Documentación de Kubernetes, *Encrypting Confidential Data at Rest* — https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
- Documentación de Kubernetes, *Validating Admission Policy* — https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- ingress-nginx, *TLS/HTTPS user guide* — https://kubernetes.github.io/ingress-nginx/user-guide/tls/
- ingress-nginx, *Annotations reference* — https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/
- ingress-nginx, *ConfigMap reference* — https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/configmap/
- ingress-nginx, *Command line arguments* — https://kubernetes.github.io/ingress-nginx/user-guide/cli-arguments/
- ingress-nginx, *Hardening guide* — https://kubernetes.github.io/ingress-nginx/deploy/hardening-guide/
- Aviso de seguridad de Kubernetes, *CVE-2025-1974 (ingress-nginx)* — https://github.com/kubernetes/kubernetes/issues/131009
- IETF RFC 8446, *The Transport Layer Security (TLS) Protocol Version 1.3* — https://www.rfc-editor.org/rfc/rfc8446
- IETF RFC 6066, *TLS Extensions: Server Name Indication* — https://www.rfc-editor.org/rfc/rfc6066
- IETF RFC 6125, *Representation and Verification of Domain-Based Application Service Identity* — https://www.rfc-editor.org/rfc/rfc6125
- IETF RFC 6797, *HTTP Strict Transport Security (HSTS)* — https://www.rfc-editor.org/rfc/rfc6797
- Documentación de cert-manager, *Securing Ingress Resources* — https://cert-manager.io/docs/usage/ingress/