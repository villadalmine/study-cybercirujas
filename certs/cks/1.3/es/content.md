# 1.3 Configurar correctamente objetos Ingress con TLS

**Dominio:** Cluster Setup · **Peso en el examen:** 3

---

## 1. Por qué esto importa para la seguridad

Un `Ingress` es la puerta de entrada del clúster: es el único objeto que expone deliberadamente Services internos a tráfico originado fuera del clúster. Todo lo que aprendiste sobre NetworkPolicies y endurecimiento de nodos es irrelevante si el punto de entrada termina HTTP en texto plano, presenta un certificado vencido o acepta SSLv3.

Desde el punto de vista de CKS hay tres objetivos de seguridad distintos:

| Objetivo | Mecanismo |
|---|---|
| Confidencialidad/integridad del tráfico del cliente | Terminación TLS en el Ingress con un certificado válido |
| Ninguna ruta accidental en texto plano | Redirección HTTP → HTTPS, HSTS |
| Prueba de quién está hablando | Certificado de servidor (siempre) + certificado de cliente opcional (mTLS) |

Un cuarto objetivo, frecuentemente pasado por alto, es proteger el **Ingress controller en sí**, que corre con privilegios altos y tiene un historial de CVEs serios. La sección 10 cubre eso.

---

## 2. Las piezas móviles

TLS en un Ingress requiere que cuatro cosas coincidan entre sí. Si alguna de ellas no coincide, obtenés el certificado autofirmado de respaldo del controller en lugar del tuyo — y *ningún error*, que es la razón por la cual este tema produce tanto tiempo de troubleshooting en el examen.

```
                     must match
   ┌──────────────────────────────────────────────┐
   │                                              │
Client SNI ──► spec.tls[].hosts ──► Secret (tls.crt SAN) 
   │                                              
   └────────► spec.rules[].host ──► backend Service
```

1. **Un Ingress controller** debe estar corriendo y observando el `IngressClass` correcto. El objeto `Ingress` es dato inerte; sin un controller no pasa nada.
2. **Un Secret de tipo `kubernetes.io/tls`** que contenga `tls.crt` (leaf + cualquier intermedio) y `tls.key`, viviendo **en el mismo namespace que el Ingress**.
3. **El objeto `Ingress`** referenciando ese Secret bajo `spec.tls`.
4. **Un certificado cuyo SAN cubra el hostname** que el cliente solicita vía SNI.

---

## 3. Prerrequisito: un Ingress controller

El entorno del examen normalmente tiene `ingress-nginx` preinstalado. Confirmalo antes de hacer cualquier cosa:

```bash
kubectl get pods -n ingress-nginx
kubectl get ingressclass
```

```
NAME                                        READY   STATUS    RESTARTS   AGE
ingress-nginx-controller-7d4c8f96b4-x2vlq   1/1     Running   0          3d

NAME    CONTROLLER                      PARAMETERS   AGE
nginx   k8s.io/ingress-nginx            <none>       3d
```

Si tenés que instalarlo vos mismo:

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.1/deploy/static/provider/baremetal/deploy.yaml
kubectl wait --namespace ingress-nginx \
  --for=condition=Ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s
```

> **Nota sobre ingress-nginx.** El proyecto upstream `ingress-nginx` fue puesto en modo mantenimiento con un retiro planificado, y se está desarrollando *InGate* como su sucesor. Los entornos de examen y la mayoría de los clústeres en el campo todavía traen `ingress-nginx`, así que sigue siendo la implementación de referencia para este objetivo — pero verificá qué controller corre realmente tu clúster antes de copiar annotations, ya que **las annotations son específicas de cada controller y no son parte de la API de Ingress**. El bloque `spec.tls`, en cambio, es portable a través de todos los controllers.

---

## 4. Paso 1 — obtener un certificado

Para propósitos de laboratorio y examen, generá un certificado autofirmado con `openssl`. La parte crítica es el **subjectAltName**: los clientes modernos ignoran el CN por completo, así que un certificado sin un SAN coincidente fallará la verificación incluso si el CN se ve correcto.

```bash
openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
  -keyout shop.key -out shop.crt \
  -subj "/CN=shop.example.com/O=teach-plat" \
  -addext "subjectAltName=DNS:shop.example.com"
```

```
..+.....+.......+..+.......+...+..+....+......+..+...+....+..+......+..
-----
```

Inspeccioná lo que produjiste — hacé esto de manera refleja, atrapa la mayoría de los errores:

```bash
openssl x509 -in shop.crt -noout -subject -issuer -dates -ext subjectAltName
```

```
subject=CN = shop.example.com, O = teach-plat
issuer=CN = shop.example.com, O = teach-plat
notBefore=Jul 29 09:14:02 2026 GMT
notAfter=Jul 29 09:14:02 2027 GMT
X509v3 Subject Alternative Name:
    DNS:shop.example.com
```

---

## 5. Paso 2 — crear el Secret TLS

La forma imperativa es la que hay que memorizar; es más rápida y no puede equivocarse con los nombres de las claves:

```bash
kubectl create secret tls shop-tls \
  --cert=shop.crt --key=shop.key \
  -n webshop
```

```
secret/shop-tls created
```

Verificá el **type** y las **dos claves requeridas**. Un Secret de tipo `Opaque`, o uno cuyas claves se llamen `cert.pem`/`key.pem`, será ignorado silenciosamente por el controller:

```bash
kubectl get secret shop-tls -n webshop -o jsonpath='{.type}{"\n"}{range .data}{"\n"}{end}'
kubectl describe secret shop-tls -n webshop
```

```
kubernetes.io/tls

Name:         shop-tls
Namespace:    webshop
Type:         kubernetes.io/tls

Data
====
tls.crt:  1298 bytes
tls.key:  1704 bytes
```

El equivalente declarativo, si te piden producir un manifiesto:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: shop-tls
  namespace: webshop
type: kubernetes.io/tls
data:
  tls.crt: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t...   # base64 of the full chain
  tls.key: LS0tLS1CRUdJTiBQUklWQVRFIEtFWS0tLS0t...   # base64 of the private key
```

Generá el base64 sin salto de línea — el base64 con wrapping es una fuente clásica de errores de "invalid certificate":

```bash
kubectl create secret tls shop-tls --cert=shop.crt --key=shop.key \
  --dry-run=client -o yaml > shop-tls.yaml
```

**El orden de la cadena importa.** `tls.crt` debe contener el certificado leaf *primero*, seguido de cualquier intermedio, y normalmente *no* el root. Un intermedio faltante produce un certificado que funciona en un navegador con una cadena cacheada y falla en `curl` — probá con `openssl s_client`, no con tu navegador.

---

## 6. Paso 3 — el objeto Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: shop
  namespace: webshop
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - shop.example.com
      secretName: shop-tls
  rules:
    - host: shop.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: shop-svc
                port:
                  number: 8080
```

```bash
kubectl apply -f shop-ingress.yaml
kubectl get ingress -n webshop
```

```
NAME   CLASS   HOSTS              ADDRESS        PORTS     AGE
shop   nginx   shop.example.com   10.98.144.27   80, 443   12s
```

La columna `PORTS` mostrando `80, 443` es la confirmación más rápida de que el bloque `tls` fue aceptado. Si muestra solo `80`, tu `spec.tls` falta o está malformado.

El atajo imperativo crea las reglas pero **no** el bloque TLS — igual tenés que editarlo o parchearlo:

```bash
kubectl create ingress shop -n webshop \
  --class=nginx \
  --rule="shop.example.com/*=shop-svc:8080,tls=shop-tls"
```

El sufijo `,tls=<secret>` en `--rule` *sí* completa `spec.tls`, y vale la pena memorizarlo por velocidad.

---

## 7. Cómo el controller elige un certificado (SNI)

El controller construye un bloque `server` de nginx por host. Al momento del handshake selecciona el certificado usando el valor **SNI** enviado por el cliente, no el header HTTP `Host` — el certificado se elige antes de que se parsee cualquier HTTP.

Consecuencias que tenés que internalizar:

- Si el cliente no envía SNI (acceso por IP cruda, herramientas viejas), el controller sirve el **certificado por defecto**.
- Si el host del SNI no tiene una entrada coincidente en `spec.tls[].hosts`, obtenés el certificado por defecto.
- El certificado por defecto, salvo que se configure, es uno autofirmado que se identifica como `Kubernetes Ingress Controller Fake Certificate`. **Ver esa cadena es el síntoma canónico de un cableado TLS roto** — el Ingress está funcionando, pero tu Secret no coincidió.

Diagnosticá exactamente eso:

```bash
openssl s_client -connect 10.98.144.27:443 -servername shop.example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
```

Roto:
```
subject=O = Acme Co, CN = Kubernetes Ingress Controller Fake Certificate
issuer=O = Acme Co, CN = Kubernetes Ingress Controller Fake Certificate
```

Correcto:
```
subject=CN = shop.example.com, O = teach-plat
issuer=CN = shop.example.com, O = teach-plat
notBefore=Jul 29 09:14:02 2026 GMT
notAfter=Jul 29 09:14:02 2027 GMT
```

Para configurar un certificado por defecto a nivel de clúster en lugar del falso, pasale un flag al Deployment del controller:

```yaml
        args:
          - /nginx-ingress-controller
          - --default-ssl-certificate=ingress-nginx/default-tls
```

---

## 8. Forzar HTTPS

Por defecto `ingress-nginx` ya emite una redirección `308` de HTTP a HTTPS **para los hosts que tienen TLS configurado**. Dos annotations controlan el comportamiento:

```yaml
metadata:
  annotations:
    # redirect HTTP→HTTPS (default true when spec.tls covers the host)
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    # redirect even when TLS is terminated upstream (LB/proxy) and the
    # controller receives plain HTTP with X-Forwarded-Proto
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
```

Verificá:

```bash
curl -sI --resolve shop.example.com:80:10.98.144.27 http://shop.example.com/
```

```
HTTP/1.1 308 Permanent Redirect
Date: Wed, 29 Jul 2026 09:31:44 GMT
Content-Type: text/html
Location: https://shop.example.com
```

Agregá **HSTS** para que los navegadores rechacen texto plano en visitas posteriores. HSTS está habilitado por defecto en `ingress-nginx`, pero vale la pena configurar explícitamente el max-age y los flags de subdominios en el ConfigMap del controller:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: ingress-nginx-controller
  namespace: ingress-nginx
data:
  hsts: "true"
  hsts-max-age: "31536000"          # 1 year
  hsts-include-subdomains: "true"
```

Habilitá `hsts-include-subdomains` solamente cuando realmente servís cada subdominio sobre TLS — es efectivamente irreversible durante la duración del max-age.

---

## 9. Endurecer la configuración TLS

La selección de protocolo y ciphers es una configuración **a nivel de controller**, no por Ingress. Editá el ConfigMap del controller:

```bash
kubectl edit configmap ingress-nginx-controller -n ingress-nginx
```

```yaml
data:
  ssl-protocols: "TLSv1.2 TLSv1.3"
  ssl-ciphers: "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305"
  ssl-prefer-server-ciphers: "true"
  ssl-session-tickets: "false"       # avoid weakening forward secrecy
```

Notas:

- `ssl-protocols` es el control que elimina TLS 1.0/1.1. Descartarlos es el ítem de endurecimiento de mayor valor acá.
- `ssl-ciphers` aplica a **TLS 1.2 y anteriores**; las suites de cifrado de TLS 1.3 están fijadas por el protocolo y todas se consideran seguras.
- Los cambios son tomados por el reload de nginx; no hace falta reiniciar el pod, pero confirmá que ocurrió:

```bash
kubectl logs -n ingress-nginx deploy/ingress-nginx-controller | tail -3
```

```
I0729 09:40:12.114  7 controller.go:213] "Configuration changes detected, backend reload required"
I0729 09:40:12.398  7 controller.go:230] "Backend successfully reloaded"
```

Confirmá desde afuera que un protocolo débil es efectivamente rechazado:

```bash
openssl s_client -connect 10.98.144.27:443 -servername shop.example.com -tls1_1 </dev/null
```

```
140234...:SSL alert number 70
no peer certificate available
```

---

## 10. Reencriptar hacia el backend

Por defecto, `ingress-nginx` termina TLS y reenvía **HTTP en texto plano** dentro del clúster. Para cargas de trabajo con requisitos reales de confidencialidad — o cuando el pod en sí sirve HTTPS — reencriptá:

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
    nginx.ingress.kubernetes.io/proxy-ssl-verify: "on"
    nginx.ingress.kubernetes.io/proxy-ssl-secret: "webshop/backend-ca"
    nginx.ingress.kubernetes.io/proxy-ssl-name: "shop-svc.webshop.svc"
```

Sin `proxy-ssl-verify: "on"` el controller encripta pero **no** valida el certificado del backend — eso es encriptación sin autenticación, y es el comportamiento por defecto. Esperá que esta distinción sea evaluada.

---

## 11. Autenticación con certificado de cliente (mTLS)

Exigir que los clientes presenten un certificado convierte al Ingress en un límite de autenticación. Creá un Secret que contenga la CA que firmó los certificados de cliente:

```bash
kubectl create secret generic client-ca -n webshop --from-file=ca.crt=client-ca.crt
```

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/auth-tls-verify-client: "on"
    nginx.ingress.kubernetes.io/auth-tls-secret: "webshop/client-ca"
    nginx.ingress.kubernetes.io/auth-tls-verify-depth: "1"
    nginx.ingress.kubernetes.io/auth-tls-pass-certificate-to-upstream: "true"
```

Valores para `auth-tls-verify-client`: `on` (requerido), `optional` (solicita, permite ambos, el backend decide), `optional_no_ca` (solicita, no valida — útil solo cuando el backend hace la validación), `off`.

Probá:

```bash
# no client cert
curl -s -o /dev/null -w '%{http_code}\n' --cacert shop.crt \
  --resolve shop.example.com:443:10.98.144.27 https://shop.example.com/
```
```
400
```

```bash
# with client cert
curl -s -o /dev/null -w '%{http_code}\n' --cacert shop.crt \
  --cert client.crt --key client.key \
  --resolve shop.example.com:443:10.98.144.27 https://shop.example.com/
```
```
200
```

La clave del Secret **debe** llamarse `ca.crt`. Debe vivir en el namespace nombrado en la annotation.

---

## 12. Automatizar certificados con cert-manager

Los certificados autofirmados están bien para el examen, pero la higiene en producción implica certificados de vida corta y renovados automáticamente. `cert-manager` observa objetos Ingress y crea el Secret TLS por vos:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: shop
  namespace: webshop
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  ingressClassName: nginx
  tls:
    - hosts: ["shop.example.com"]
      secretName: shop-tls        # created and renewed by cert-manager
  rules:
    - host: shop.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: { name: shop-svc, port: { number: 8080 } }
```

Beneficio de seguridad que vale la pena declarar explícitamente: nadie manipula la clave privada, y un certificado de 90 días limita el radio de impacto del compromiso de una clave.

---

## 13. Asegurar el propio Ingress controller

Esta es la parte que los candidatos saltean y que a los examinadores les gusta. El controller es un componente privilegiado y expuesto a internet.

**Deshabilitá los snippets de configuración.** Las annotations de snippet le permiten a cualquiera que pueda crear un Ingress inyectar configuración arbitraria de nginx — incluyendo leer archivos del pod del controller. Las versiones modernas dejan `allow-snippet-annotations` en `false` por defecto; hacelo explícito:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: ingress-nginx-controller
  namespace: ingress-nginx
data:
  allow-snippet-annotations: "false"
  annotation-value-word-blocklist: "load_module,lua_package,_by_lua,root,serviceaccount,{,},',\""
```

**Parchá las CVEs conocidas.** El conjunto de vulnerabilidades *IngressNightmare* (CVE-2025-1974 más CVE-2025-1097, CVE-2025-1098, CVE-2025-24513, CVE-2025-24514) permitía RCE sin autenticar contra el **admission webhook** de `ingress-nginx`, llevando a la divulgación completa de los secrets del clúster. Corregido en 1.11.5 y 1.12.1. Verificá tu versión:

```bash
kubectl exec -n ingress-nginx deploy/ingress-nginx-controller -- \
  /nginx-ingress-controller --version
```

```
NGINX Ingress controller
  Release:       v1.12.1
  Build:         ...
  Repository:    https://github.com/kubernetes/ingress-nginx
```

Mitigaciones cuando parchear no es inmediatamente posible: restringir el acceso de red al puerto del admission webhook (`8443`) con una NetworkPolicy para que solo el API server pueda alcanzarlo, o deshabilitar el admission controller.

**Limitá quién puede crear Ingresses.** La creación de un `Ingress` es efectivamente el poder de enrutar tráfico externo hacia cualquier Service del namespace y — vía annotations del estilo `auth-tls-secret` / `proxy-ssl-secret` — de referenciar Secrets. Acotá el RBAC en consecuencia, y restringí los permisos de `get` sobre Secrets para que una carga de trabajo comprometida no pueda leer `tls.key`.

**Restringí el propio Secret.** La clave privada está en etcd como base64. Habilitá el cifrado en reposo para Secrets (cubierto en el dominio Cluster Hardening) y auditá `get`/`list` sobre Secrets en los namespaces de ingress.

---

## 14. Checklist de troubleshooting

Recorré esto en orden; resuelve casi todas las fallas.

```bash
# 1. Is the Ingress admitted and does it show 443?
kubectl get ingress -n webshop -o wide

# 2. Any events? (wrong secret name shows up here)
kubectl describe ingress shop -n webshop

# 3. Does the Secret exist, in the right namespace, with the right type?
kubectl get secret -n webshop shop-tls -o jsonpath='{.type}'

# 4. Did the controller load it?
kubectl logs -n ingress-nginx deploy/ingress-nginx-controller | grep -i ssl

# 5. What is actually served on the wire?
openssl s_client -connect <ADDRESS>:443 -servername shop.example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -dates

# 6. End-to-end with verification enabled
curl -v --cacert shop.crt --resolve shop.example.com:443:<ADDRESS> https://shop.example.com/
```

Salida típica de `describe` cuando falta el Secret:

```
Events:
  Type     Reason  Age   From                      Message
  ----     ------  ----  ----                      -------
  Warning  Sync    10s   nginx-ingress-controller  Error obtaining X.509 certificate:
                                                   secret webshop/shop-tls was not found
```

Handshake exitoso de `curl`:

```
* Server certificate:
*  subject: CN=shop.example.com; O=teach-plat
*  start date: Jul 29 09:14:02 2026 GMT
*  expire date: Jul 29 09:14:02 2027 GMT
*  SSL certificate verify ok.
> GET / HTTP/2
< HTTP/2 200
< strict-transport-security: max-age=31536000; includeSubDomains
```

---

## 15. Errores comunes en el examen

| Síntoma | Causa |
|---|---|
| Se sirve el Fake Certificate | El host del SNI no está presente en `spec.tls[].hosts`, o el Secret está en el namespace equivocado |
| `PORTS` muestra solo `80` | `spec.tls` falta o el bloque entero está indentado bajo la clave equivocada |
| El Secret es ignorado | El type es `Opaque` en lugar de `kubernetes.io/tls`, o las claves no se llaman `tls.crt`/`tls.key` |
| Funciona en el navegador, falla en `curl` | Falta el certificado intermedio en `tls.crt` |
| No pasa absolutamente nada | `spec.ingressClassName` omitido o mal escrito; ningún controller reclama el objeto |
| `curl` se queja del nombre | El certificado tiene un CN pero ningún SAN coincidente |
| El cambio de cipher/protocolo no tiene efecto | Se editaron las annotations del Ingress en lugar del ConfigMap del controller |
| mTLS rechaza a todo el mundo | La clave del Secret de la CA no se llama `ca.crt`, o a `auth-tls-secret` le falta el prefijo `namespace/` |

**Consejos de velocidad:** el Secret debe estar en el namespace del *workload*, no en `ingress-nginx`. Usá `kubectl create ingress ... --rule="host/path=svc:port,tls=secret"` para generar un esqueleto correcto, y después `kubectl explain ingress.spec.tls` si te olvidás el nombre de un campo — `explain` está disponible en el examen y es más rápido que el sitio de documentación.

---

## Referencias

- Kubernetes — Ingress: https://kubernetes.io/docs/concepts/services-networking/ingress/#tls
- Kubernetes — Ingress Controllers: https://kubernetes.io/docs/concepts/services-networking/ingress-controllers/
- Kubernetes — TLS Secrets: https://kubernetes.io/docs/concepts/configuration/secret/#tls-secrets
- Kubernetes — `kubectl create ingress`: https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#-em-ingress-em-
- ingress-nginx — TLS/HTTPS user guide: https://kubernetes.github.io/ingress-nginx/user-guide/tls/
- ingress-nginx — Annotations reference: https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/
- ingress-nginx — ConfigMap reference: https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/configmap/
- ingress-nginx — Hardening guide: https://kubernetes.github.io/ingress-nginx/deploy/hardening-guide/
- ingress-nginx — Client certificate authentication: https://kubernetes.github.io/ingress-nginx/examples/auth/client-certs/
- Kubernetes blog — "Ingress-nginx CVE-2025-1974: What You Need to Know": https://kubernetes.io/blog/2025/03/24/ingress-nginx-cve-2025-1974/
- cert-manager — Securing Ingress resources: https://cert-manager.io/docs/usage/ingress/
- CNCF — CKS Curriculum v1.34: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf