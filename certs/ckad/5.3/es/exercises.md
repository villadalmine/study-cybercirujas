# Ejercicios guiados — Tema 5.3: Use Ingress rules to expose applications (CKAD v1.35, peso 5%)

Fuente de referencia: [CNCF CKAD Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf)

Requisito previo: un cluster con un Ingress controller instalado (por ejemplo `ingress-nginx`). Si usás `minikube`, habilitalo con `minikube addons enable ingress`.

## Ejercicio 1 — Verificar el Ingress controller y las IngressClass disponibles

1. Listá los Pods del namespace donde corre el Ingress controller:
   ```bash
   kubectl get pods -n ingress-nginx
   ```
2. Confirmá que existe al menos un objeto `IngressClass`:
   ```bash
   kubectl get ingressclass
   ```
3. Inspeccioná el `IngressClass` por defecto (buscá la annotation `ingressclass.kubernetes.io/is-default-class`):
   ```bash
   kubectl get ingressclass -o yaml
   ```

**Preguntas de verificación:**
- ¿Qué diferencia hay entre el recurso `Ingress` y el Ingress controller?
- ¿Qué pasa si creás un `Ingress` sin especificar `ingressClassName` y no hay ninguna `IngressClass` marcada como default?

---

## Ejercicio 2 — Desplegar la aplicación y exponerla con un Service

1. Creá un Deployment simple:
   ```bash
   kubectl create deployment web --image=nginx --replicas=2
   ```
2. Exponelo como Service de tipo `ClusterIP`:
   ```bash
   kubectl expose deployment web --port=80 --target-port=80
   ```
3. Verificá que el Service tiene Endpoints:
   ```bash
   kubectl get endpoints web
   ```

**Preguntas de verificación:**
- ¿Por qué un `Ingress` necesita un `Service` como backend en lugar de apuntar directamente a los Pods?
- ¿Qué significaría que `kubectl get endpoints web` devuelva `<none>`?

---

## Ejercicio 3 — Crear un Ingress básico con una regla de path

1. Creá el archivo `ingress-web.yaml`:
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     name: web-ingress
   spec:
     ingressClassName: nginx
     rules:
     - host: web.local
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
2. Aplicalo:
   ```bash
   kubectl apply -f ingress-web.yaml
   ```
3. Obtené la IP o el hostname asignado:
   ```bash
   kubectl get ingress web-ingress
   ```
4. Probá el acceso simulando el header `Host` (reemplazá `<IP>` por la IP del Ingress controller):
   ```bash
   curl -H "Host: web.local" http://<IP>/
   ```

**Preguntas de verificación:**
- ¿Qué diferencia hay entre `pathType: Prefix` y `pathType: Exact`?
- ¿Por qué hace falta pasar el header `Host` en el `curl` para que la request llegue a la regla correcta?

---

## Ejercicio 4 — Fan-out: rutear múltiples paths a distintos Services

1. Desplegá una segunda app y exponela:
   ```bash
   kubectl create deployment api --image=hashicorp/http-echo -- -text="api response"
   kubectl expose deployment api --port=5678 --target-port=5678
   ```
2. Editá `ingress-web.yaml` agregando un segundo path bajo el mismo host:
   ```yaml
       - path: /api
         pathType: Prefix
         backend:
           service:
             name: api
             port:
               number: 5678
   ```
3. Reaplicá y probá ambos paths:
   ```bash
   kubectl apply -f ingress-web.yaml
   curl -H "Host: web.local" http://<IP>/
   curl -H "Host: web.local" http://<IP>/api
   ```

**Preguntas de verificación:**
- Si dos paths se superponen (por ejemplo `/` y `/api`), ¿qué regla determina cuál gana?
- ¿Qué pasaría si el path `/api` tuviera `pathType: Exact` en vez de `Prefix`?

---

## Ejercicio 5 — Name-based virtual hosting (múltiples hosts)

1. Agregá una segunda regla de host en el mismo `Ingress`, apuntando `api.local` al Service `api`:
   ```yaml
     - host: api.local
       http:
         paths:
         - path: /
           pathType: Prefix
           backend:
             service:
               name: api
               port:
                 number: 5678
   ```
2. Reaplicá el manifiesto y probá con ambos hosts:
   ```bash
   kubectl apply -f ingress-web.yaml
   curl -H "Host: web.local" http://<IP>/
   curl -H "Host: api.local" http://<IP>/
   ```

**Preguntas de verificación:**
- ¿Cuál es la diferencia conceptual entre ruteo por path (fan-out) y ruteo por host (virtual hosting)?
- ¿Qué pasa si hacés la request sin header `Host` o con un host que no coincide con ninguna regla?

---

## Ejercicio 6 — Terminar TLS en el Ingress

1. Generá un certificado autofirmado y un Secret de tipo `kubernetes.io/tls`:
   ```bash
   openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
     -keyout tls.key -out tls.crt -subj "/CN=web.local/O=web.local"
   kubectl create secret tls web-tls --key tls.key --cert tls.crt
   ```
2. Agregá la sección `tls` al `Ingress`:
   ```yaml
   spec:
     tls:
     - hosts:
       - web.local
       secretName: web-tls
   ```
3. Reaplicá y probá HTTPS ignorando la validación del certificado:
   ```bash
   kubectl apply -f ingress-web.yaml
   curl -k -H "Host: web.local" https://<IP>/
   ```

**Preguntas de verificación:**
- ¿En qué componente ocurre la terminación TLS: en el Pod de la app o en el Ingress controller?
- ¿Qué campos son obligatorios dentro de un Secret `kubernetes.io/tls`?

---

## Ejercicio 7 — Troubleshooting de un Ingress

1. Provocá un error intencional: cambiá el `name` del Service en un path a uno inexistente (`web-typo`) y reaplicá.
2. Describí el Ingress para ver los eventos:
   ```bash
   kubectl describe ingress web-ingress
   ```
3. Corregí el nombre del Service y confirmá que el error desaparece.

**Preguntas de verificación:**
- ¿Qué mensaje esperás ver en los eventos de `kubectl describe ingress` cuando el backend Service no existe?
- Si el `Ingress` está bien configurado pero seguís recibiendo 404, ¿qué dos componentes deberías revisar además del recurso `Ingress` en sí?

---

<details>
<summary>Ver respuestas</summary>

**Ejercicio 1**
- El recurso `Ingress` es solo la declaración de reglas de ruteo (API object); el Ingress controller es el software (por ejemplo `ingress-nginx`, corriendo como Pods) que observa esos recursos y configura un proxy/load balancer real para cumplirlas. Sin un controller corriendo, crear un `Ingress` no tiene ningún efecto.
- Si no se especifica `ingressClassName` y no hay ninguna `IngressClass` marcada como default, ningún controller "adopta" ese `Ingress` (salvo que esté configurado para observar recursos sin clase), por lo que las reglas quedan sin efecto.

**Ejercicio 2**
- El `Ingress` necesita un `Service` porque el controller resuelve el backend a través del `Service` (y sus Endpoints), lo que da balanceo de carga y desacopla el ciclo de vida de los Pods (que cambian de IP) del ruteo. `Ingress` no admite apuntar directamente a un Pod.
- Endpoints vacíos indican que el selector del Service no coincide con ningún Pod en estado `Ready`, así que cualquier request ruteada a ese Service fallaría con error de gateway (502/503).

**Ejercicio 3**
- `Prefix` matchea por segmentos de path: `/` matchea todo, `/api` matchea `/api`, `/api/`, `/api/v1`, etc. `Exact` requiere coincidencia exacta y sensible a mayúsculas del path completo, sin matchear subpaths.
- El Ingress controller rutea usando reglas de virtual host basadas en el header `Host` de la request HTTP; sin ese header (o con uno que no matchea `spec.rules[].host`), la request cae en el backend por defecto (si existe) o devuelve 404.

**Ejercicio 4**
- Gana el path más específico (el de mayor longitud de coincidencia), no el orden en que aparece en el YAML. Es un comportamiento definido por el controller (ingress-nginx ordena por longitud del path), aunque la especificación de la API no lo fuerza estrictamente para todos los controllers.
- Con `pathType: Exact` en `/api`, solo matchearía la request a `/api` exactamente; algo como `/api/status` no matchearía esa regla y caería en otra (por ejemplo `/`) o en 404 si no hay otra regla aplicable.

**Ejercicio 5**
- El fan-out rutea distintos paths bajo el mismo host hacia distintos Services (una sola URL pública, múltiples "carpetas"); el virtual hosting rutea según el header `Host`, permitiendo servir múltiples dominios/hostnames distintos desde la misma IP del Ingress controller.
- Sin header `Host`, o con uno que no coincide con ningún `rules[].host`, el controller usa el backend por defecto si está configurado (`spec.defaultBackend`) o responde 404.

**Ejercicio 6**
- La terminación TLS ocurre en el Ingress controller (el proxy), no en el Pod de la aplicación: el tráfico entre cliente y controller va cifrado, y de controller a Service/Pod normalmente va en texto plano (HTTP) salvo que se configure TLS end-to-end explícitamente.
- El Secret `kubernetes.io/tls` requiere las claves `tls.crt` (certificado) y `tls.key` (clave privada) en su `data`.

**Ejercicio 7**
- Un evento tipo `Warning` indicando que el backend referenciado no existe (algo como `service "web-typo" not found`).
- Además del `Ingress`, conviene revisar el `Service` (¿existe, con el puerto correcto?) y sus `Endpoints`/Pods (¿están `Ready` y con las labels que matchean el selector?).

</details>