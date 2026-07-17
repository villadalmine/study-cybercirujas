# 1.3 Properly set up Ingress objects with TLS

## Ingress: qué es y por qué importa para seguridad

Un objeto `Ingress` en Kubernetes define reglas de enrutamiento HTTP/HTTPS hacia Services internos, permitiendo exponer múltiples aplicaciones a través de una única IP/LoadBalancer externo. El `Ingress` por sí solo es solo la especificación de reglas: necesita un **Ingress Controller** (NGINX Ingress Controller, Traefik, HAProxy, etc.) corriendo en el cluster que efectivamente implemente esas reglas como configuración de proxy.

Desde la óptica de CKS, este tema no es solo "cómo exponer una app", sino **cómo proteger el tráfico en tránsito** y **cómo evitar que el punto de entrada del cluster (el Ingress Controller) se convierta en superficie de ataque**. El Ingress Controller suele:

- Correr con `hostNetwork: true` o exponer puertos privilegiados (80/443).
- Tener permisos RBAC amplios (lee `Secrets` en el namespace para los certificados TLS).
- Ser el único componente accesible desde fuera del cluster.

Por eso, configurar TLS correctamente en el Ingress es una medida de *defense in depth*, no un detalle cosmético.

## Terminación TLS: dónde ocurre

El patrón estándar es **TLS termination en el Ingress Controller**: el cliente negocia TLS con el controller, que descifra el tráfico y lo reenvía en texto plano (o re-cifrado, según configuración) hacia el `Service`/`Pod` backend dentro del cluster.

```
cliente --TLS(443)--> Ingress Controller --HTTP(80)--> Service --> Pod
```

Alternativa: **SSL passthrough**, donde el Ingress Controller no descifra sino que reenvía el stream TLS crudo hasta el Pod (útil cuando el backend maneja su propio certificado, p. ej. mTLS interno). En NGINX Ingress se habilita con la annotation `nginx.ingress.kubernetes.io/ssl-passthrough: "true"` y requiere que el controller arranque con la flag `--enable-ssl-passthrough`.

## Paso 1: generar el certificado (o usar uno emitido por una CA)

Para laboratorio/examen, se genera un certificado autofirmado con `openssl`:

```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tls.key -out tls.crt \
  -subj "/CN=app.example.com/O=app.example.com"
```

En producción el certificado vendría de una CA real o de un emisor automatizado (p. ej. `cert-manager` con Let's Encrypt), pero esa automatización queda fuera del alcance de este tema del curriculum — acá lo relevante es saber **consumir** un par cert/key en un objeto Kubernetes.

## Paso 2: crear el Secret de tipo `kubernetes.io/tls`

```bash
kubectl create secret tls app-tls-secret \
  --cert=tls.crt --key=tls.key \
  -n default
```

Salida esperada:

```
secret/app-tls-secret created
```

Verificación del tipo y las claves del Secret:

```bash
kubectl get secret app-tls-secret -o yaml
```

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: app-tls-secret
  namespace: default
type: kubernetes.io/tls
data:
  tls.crt: LS0tLS1CRUdJTi...
  tls.key: LS0tLS1CRUdJTi...
```

El `type: kubernetes.io/tls` es obligatorio: si se crea con `kubectl create secret generic` en vez de `tls`, el Ingress Controller no lo reconocerá como material TLS válido aunque contenga las mismas claves `tls.crt`/`tls.key`.

**Punto de seguridad clave:** el Secret debe existir en el **mismo namespace** que el objeto `Ingress` que lo referencia. La API de `Ingress` no soporta referencias cross-namespace a Secrets (a diferencia de Gateway API con `ReferenceGrant`), así que si una app en `ns-a` necesita el mismo certificado que otra en `ns-b`, hay que duplicar el Secret en ambos namespaces — lo cual también implica duplicar el control de acceso RBAC sobre ese Secret en cada namespace.

## Paso 3: definir el Ingress con el bloque `tls`

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-ingress
  namespace: default
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - app.example.com
      secretName: app-tls-secret
  rules:
    - host: app.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: app-service
                port:
                  number: 80
```

Elementos clave:

- **`spec.ingressClassName`**: reemplaza a la antigua annotation `kubernetes.io/ingress.class`. Le dice al cluster qué Ingress Controller debe procesar este objeto (útil cuando hay más de uno, p. ej. uno interno y otro expuesto públicamente — separación que también es una decisión de seguridad).
- **`spec.tls[].hosts`**: debe coincidir con el/los `Common Name`/`Subject Alternative Names` del certificado y con `spec.rules[].host`. Si no coinciden, el navegador/cliente rechazará el certificado por *hostname mismatch*.
- **`spec.tls[].secretName`**: el Secret `kubernetes.io/tls` creado en el paso anterior.
- **Annotations `ssl-redirect`/`force-ssl-redirect`**: fuerzan que todo tráfico HTTP (puerto 80) sea redirigido a HTTPS (301), evitando que quede una vía de acceso sin cifrar al mismo backend.

Aplicar y verificar:

```bash
kubectl apply -f app-ingress.yaml
kubectl get ingress app-ingress
```

```
NAME          CLASS   HOSTS              ADDRESS         PORTS     AGE
app-ingress   nginx   app.example.com    203.0.113.10    80, 443   12s
```

```bash
kubectl describe ingress app-ingress
```

```
...
TLS:
  app-tls-secret terminates app.example.com
Rules:
  Host              Path  Backends
  ----              ----  --------
  app.example.com   /     app-service:80 (10.244.0.15:80)
...
```

## Verificación del handshake TLS

```bash
curl -kv https://app.example.com/ 2>&1 | grep -E "subject|issuer|SSL connection"
```

```
* subject: CN=app.example.com; O=app.example.com
* issuer: CN=app.example.com; O=app.example.com
* SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384
```

O con `openssl s_client`, útil para inspeccionar la cadena completa y el protocolo negociado:

```bash
openssl s_client -connect app.example.com:443 -servername app.example.com </dev/null 2>/dev/null | openssl x509 -noout -dates -subject
```

```
notBefore=Jul 17 00:00:00 2026 GMT
notAfter=Jul 17 00:00:00 2027 GMT
subject=CN=app.example.com, O=app.example.com
```

El flag `-servername` es indispensable: la mayoría de Ingress Controllers usan **SNI** para servir el certificado correcto cuando hay múltiples hosts/TLS blocks en el mismo Ingress o en distintos Ingress objects compartiendo el mismo controller. Sin SNI, el controller devuelve un certificado *default* (a menudo autofirmado, generado por el propio controller al arrancar) y el hostname no coincidirá.

## Múltiples hosts y certificados en un mismo Ingress

```yaml
spec:
  tls:
    - hosts: ["app.example.com"]
      secretName: app-tls-secret
    - hosts: ["api.example.com"]
      secretName: api-tls-secret
  rules:
    - host: app.example.com
      http: { paths: [...] }
    - host: api.example.com
      http: { paths: [...] }
```

Cada entrada de `tls` es independiente: el controller sirve el `secretName` correspondiente según el SNI recibido. Esto es preferible a usar un certificado wildcard único para todo, en la medida en que limita el *blast radius* si una clave privada se compromete.

## Consideraciones de seguridad específicas de CKS

1. **No dejar rutas sin TLS.** Verificar siempre que las annotations de redirect estén activas; sin ellas, el mismo backend queda accesible por HTTP plano en paralelo a HTTPS.
2. **Restringir quién puede crear/editar `Ingress`.** Cualquier usuario con permiso de crear objetos `Ingress` en un namespace donde corre un NGINX Ingress Controller compartido puede, vía annotations como `nginx.ingress.kubernetes.io/configuration-snippet` o `nginx.ingress.kubernetes.io/server-snippet`, inyectar directivas NGINX arbitrarias — un vector de escalamiento de privilegios/RCE documentado (CVE-2021-25742, entre otros). Mitigación: deshabilitar snippets a nivel del controller (`allow-snippet-annotations: "false"` en el ConfigMap del controller) o restringir su uso con un admission controller (Gatekeeper/Kyverno) que bloquee esas annotations para usuarios no confiables.
3. **RBAC sobre los Secrets TLS.** El Ingress Controller necesita `get`/`list`/`watch` sobre `secrets` en los namespaces que vigila. Auditar con:
   ```bash
   kubectl auth can-i get secrets --as=system:serviceaccount:ingress-nginx:ingress-nginx -n default
   ```
   Evitar otorgar ese ServiceAccount acceso cluster-wide a Secrets si solo necesita un namespace puntual.
4. **Hardening de versión/cifrado TLS.** El ConfigMap del NGINX Ingress Controller permite fijar mínimos de protocolo y cipher suites:
   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: ingress-nginx-controller
     namespace: ingress-nginx
   data:
     ssl-protocols: "TLSv1.2 TLSv1.3"
     ssl-ciphers: "HIGH:!aNULL:!MD5"
   ```
   Esto evita degradar la conexión a protocolos obsoletos (SSLv3, TLSv1.0/1.1) que un cliente malicioso podría forzar.
5. **Exposición del propio Ingress Controller.** Revisar el `Deployment`/`DaemonSet` del controller: `hostNetwork`, capacidades Linux (`NET_BIND_SERVICE` en vez de correr como root completo), `runAsNonRoot` donde la imagen lo soporte, y `NetworkPolicy` que limite qué puede alcanzar al Pod del controller además del tráfico entrante esperado.
6. **Certificados vencidos o self-signed en producción.** El examen puede pedir simplemente verificar `notAfter` de un certificado ya desplegado; en un entorno real esto se automatiza con `cert-manager`, pero el objetivo del curriculum es que sepas hacerlo manualmente sin depender de esa herramienta.

## Troubleshooting rápido

| Síntoma | Causa probable | Chequeo |
|---|---|---|
| `curl` devuelve certificado default/autofirmado del controller | `host` en `tls.hosts` no coincide con `Host` del request, o falta SNI | `curl -kv --resolve host:443:IP https://host` |
| `Ingress` sin `ADDRESS` | Ingress Controller no está corriendo o `ingressClassName` no coincide con ninguno instalado | `kubectl get ingressclass`, `kubectl get pods -n ingress-nginx` |
| `502/503` tras terminar TLS correctamente | Backend Service/Pod no responde en el puerto declarado | `kubectl get endpoints app-service` |
| Secret rechazado por el controller | `type` del Secret no es `kubernetes.io/tls`, o claves mal nombradas (`tls.crt`/`tls.key`) | `kubectl get secret app-tls-secret -o jsonpath='{.type}'` |

## Referencias

- CKS Curriculum v1.34 — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Kubernetes docs — Ingress: https://kubernetes.io/docs/concepts/services-networking/ingress/
- Kubernetes docs — Ingress TLS section: https://kubernetes.io/docs/concepts/services-networking/ingress/#tls
- Kubernetes docs — Secrets (tipo `kubernetes.io/tls`): https://kubernetes.io/docs/concepts/configuration/secret/#secret-types
- NGINX Ingress Controller — TLS: https://kubernetes.github.io/ingress-nginx/user-guide/tls/
- NGINX Ingress Controller — Annotations reference: https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/
- NGINX Ingress Controller — Configuration snippets (riesgos de seguridad): https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/#configuration-snippet