# Ejercicios guiados — 1.3 Properly set up Ingress objects with TLS

> Fuente de referencia: [CKS Curriculum v1.34 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf)

## Ejercicio 1: Desplegar la aplicación backend

1. Creá un namespace de trabajo:
   ```bash
   kubectl create namespace ckstls
   ```
2. Desplegá una aplicación backend simple:
   ```bash
   kubectl create deployment web --image=nginx:1.25 --replicas=2 -n ckstls
   ```
3. Expon el Deployment como Service `ClusterIP`:
   ```bash
   kubectl expose deployment web --port=80 --target-port=80 -n ckstls
   ```
4. Verificá que el Service tenga Endpoints activos:
   ```bash
   kubectl get pods,svc,endpoints -n ckstls
   ```

**Preguntas de comprensión**
1. ¿Por qué el Service que usa un Ingress como backend suele ser `ClusterIP` y no `NodePort` o `LoadBalancer`?
2. ¿Qué dos campos del Service necesita conocer el objeto Ingress para poder enrutar tráfico hacia los Pods correctos?

---

## Ejercicio 2: Verificar el Ingress Controller

1. Comprobá si ya existe un Ingress Controller corriendo en el clúster:
   ```bash
   kubectl get pods -n ingress-nginx
   ```
2. Si no existe, instalá `ingress-nginx`:
   ```bash
   kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.2/deploy/static/provider/cloud/deploy.yaml
   ```
3. Esperá a que el controller esté listo:
   ```bash
   kubectl wait --namespace ingress-nginx \
     --for=condition=ready pod \
     --selector=app.kubernetes.io/component=controller \
     --timeout=120s
   ```
4. Listá las `IngressClass` disponibles:
   ```bash
   kubectl get ingressclass
   ```

**Preguntas de comprensión**
1. ¿Qué diferencia hay entre el recurso `IngressClass` y el objeto `Ingress`?
2. Si el clúster tiene más de un Ingress Controller instalado, ¿cómo se indica en el manifiesto cuál debe procesar un `Ingress` en particular?

---

## Ejercicio 3: Generar el certificado TLS y el Secret

1. Generá un certificado autofirmado con `openssl` (clave + certificado en un solo paso):
   ```bash
   openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
     -keyout tls.key -out tls.crt \
     -subj "/CN=web.cks.local/O=web.cks.local"
   ```
2. Creá el Secret de tipo TLS a partir de esos archivos:
   ```bash
   kubectl create secret tls web-tls \
     --cert=tls.crt --key=tls.key -n ckstls
   ```
3. Verificá el tipo y las claves del Secret:
   ```bash
   kubectl get secret web-tls -n ckstls -o yaml
   ```
4. Confirmá qué identidades pueden leer ese Secret:
   ```bash
   kubectl auth can-i get secret/web-tls -n ckstls --as=system:serviceaccount:ckstls:default
   ```

**Preguntas de comprensión**
1. ¿Por qué el Secret debe ser del tipo `kubernetes.io/tls` y no `Opaque`?
2. ¿Qué riesgo de seguridad existe si cualquier ServiceAccount del namespace puede hacer `get` sobre este Secret?

---

## Ejercicio 4: Crear el Ingress con TLS

1. Creá el archivo `web-ingress.yaml`:
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     name: web-ingress
     namespace: ckstls
     annotations:
       nginx.ingress.kubernetes.io/ssl-redirect: "true"
   spec:
     ingressClassName: nginx
     tls:
     - hosts:
       - web.cks.local
       secretName: web-tls
     rules:
     - host: web.cks.local
       http:
         paths:
         - path: /
           pathType: Prefix
           backend:
             service:
               name: web
               port:
                 number: 80
   ```
2. Aplicá el manifiesto:
   ```bash
   kubectl apply -f web-ingress.yaml
   ```
3. Verificá el objeto creado y su sección TLS:
   ```bash
   kubectl describe ingress web-ingress -n ckstls
   ```

**Preguntas de comprensión**
1. ¿Qué ocurre si el valor de `tls.hosts` no coincide con el `host` definido en `spec.rules`?
2. ¿La anotación `ssl-redirect` forma parte de la especificación "core" de `networking.k8s.io/v1.Ingress` o es una extensión propia del controller?

---

## Ejercicio 5: Verificar el acceso HTTPS

1. Obtené la IP o el puerto expuesto por el Ingress Controller:
   ```bash
   kubectl get svc -n ingress-nginx
   ```
2. Probá el acceso HTTPS confiando explícitamente en el certificado generado (en vez de ignorar la validación):
   ```bash
   curl -v --resolve web.cks.local:443:<IP> \
     --cacert tls.crt https://web.cks.local/
   ```
3. Probá el acceso por HTTP y confirmá el redirect:
   ```bash
   curl -v --resolve web.cks.local:80:<IP> http://web.cks.local/
   ```
4. Inspeccioná el sujeto del certificado presentado:
   ```bash
   curl -v --resolve web.cks.local:443:<IP> https://web.cks.local/ --cacert tls.crt 2>&1 | grep "subject:"
   ```

**Preguntas de comprensión**
1. ¿Por qué usar `--cacert tls.crt` es más seguro que usar `-k/--insecure` al probar un certificado autofirmado?
2. ¿Qué código de estado HTTP evidencia que el redirect HTTP→HTTPS está activo?

---

## Ejercicio 6: Hardening

1. Revisá si existe una `IngressClass` marcada como default en el clúster:
   ```bash
   kubectl get ingressclass -o yaml | grep -A2 annotations
   ```
2. Confirmá que ningún `Ingress` del clúster carezca de sección `tls`:
   ```bash
   kubectl get ingress -A -o json | jq '.items[] | select(.spec.tls == null) | .metadata.name'
   ```
3. Restringí protocolos y cifrados TLS admitidos a nivel del controller (ConfigMap de `ingress-nginx`):
   ```bash
   kubectl -n ingress-nginx edit configmap ingress-nginx-controller
   # agregar: ssl-protocols: "TLSv1.3 TLSv1.2"
   ```
4. Rotá el certificado sin downtime, reemplazando el contenido del Secret existente:
   ```bash
   kubectl create secret tls web-tls \
     --cert=tls-new.crt --key=tls-new.key \
     -n ckstls --dry-run=client -o yaml | kubectl apply -f -
   ```

**Preguntas de comprensión**
1. ¿Por qué depender de una `IngressClass` "default" implícita puede ser un problema de seguridad en un clúster multi-tenant?
2. Al rotar el certificado, ¿por qué conviene usar `--dry-run=client -o yaml | kubectl apply -f -` en lugar de borrar y volver a crear el Secret?

---

<details>
<summary><strong>Ver respuestas</strong></summary>

### Ejercicio 1
1. Porque el tráfico externo no debe llegar directamente al Pod/Service: el Ingress Controller es el único punto de entrada expuesto (vía su propio Service, típicamente `LoadBalancer` o `NodePort`), y desde ahí reenvía internamente al Service del backend. Exponer el backend además como `NodePort`/`LoadBalancer` amplía innecesariamente la superficie de ataque.
2. El **nombre del Service** (`service.name`) y el **puerto** (`service.port.number` o `service.port.name`), definidos en `spec.rules[].http.paths[].backend.service`.

### Ejercicio 2
1. `IngressClass` es un recurso cluster-scoped que identifica e configura una implementación de Ingress Controller (por ejemplo, `spec.controller: k8s.io/ingress-nginx`); el `Ingress` es el objeto namespaced que describe las reglas de enrutamiento concretas y referencia una `IngressClass` mediante `spec.ingressClassName`.
2. Con el campo `spec.ingressClassName` del manifiesto `Ingress`, apuntando al `metadata.name` de la `IngressClass` deseada.

### Ejercicio 3
1. Porque `kubernetes.io/tls` valida en el momento de creación que el Secret contenga exactamente las claves `tls.crt` y `tls.key` con contenido bien formado, y es el tipo que el Ingress Controller espera para poder cargarlo como certificado de servidor durante el TLS handshake. Un `Opaque` no tiene esa validación ni esa semántica reconocida por los controllers.
2. Cualquier identidad con `get` sobre el Secret puede extraer la clave privada del certificado y suplantar el servicio (person-in-the-middle) o descifrar tráfico capturado, incluso si no tiene acceso directo a los Pods.

### Ejercicio 4
1. El controller no podrá seleccionar ese certificado por SNI durante el handshake TLS (la selección de certificado ocurre antes de leer el header `Host` HTTP); el cliente recibirá el certificado "fake"/default del controller y verá una advertencia de certificado no confiable, aunque el enrutamiento por `rules.host` a nivel HTTP siga funcionando una vez establecida la conexión.
2. Es una extensión propia del controller (en este caso, `nginx.ingress.kubernetes.io/ssl-redirect`, específica de ingress-nginx). El recurso core `networking.k8s.io/v1.Ingress` no define comportamiento de redirect; cada controller expone sus propias anotaciones para funcionalidades no cubiertas por la spec estándar.

### Ejercicio 5
1. `--cacert` valida la cadena de confianza contra el certificado real que se generó, detectando errores como hostname incorrecto, certificado expirado o un certificado distinto al esperado (ej. un ataque de sustitución). `-k/--insecure` desactiva toda validación, por lo que oculta esos mismos errores que en producción indicarían un problema real.
2. `308 Permanent Redirect` (comportamiento por defecto de ingress-nginx cuando `ssl-redirect` está activo).

### Ejercicio 6
1. Si un tenant no especifica `ingressClassName` (o lo omite por descuido), su tráfico puede terminar siendo procesado por un Ingress Controller distinto al esperado —potencialmente uno con menos controles o gestionado por otro equipo—, lo que puede exponer rutas o certificados de forma no intencionada. En clústeres multi-tenant conviene evitar una `IngressClass` default y exigir que cada `Ingress` la declare explícitamente.
2. Porque permite generar el nuevo manifiesto YAML del Secret y aplicarlo con `kubectl apply`, que actualiza el objeto existente sin un intervalo en que el Secret no exista (evitando una ventana en la que el Ingress Controller no encuentre el Secret referenciado y falle el TLS handshake).

</details>