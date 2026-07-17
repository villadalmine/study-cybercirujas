# CKA 5.5 — Ingress Controllers and Ingress Resources

**Peso en el examen:** 3.34%
**Fuente:** CNCF CKA Curriculum v1.35 — https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf

## Requisitos previos

- Clúster con `kubectl` configurado y permisos de administrador.
- Al menos un nodo con acceso a Internet para descargar imágenes de contenedor.

---

## Ejercicio 1: Verificar o instalar un Ingress Controller

Un `Ingress` resource por sí solo no hace nada: necesita un Ingress Controller corriendo en el clúster que observe esos objetos y programe el proxy real (nginx, haproxy, traefik, etc.).

1. Comprobá si ya existe un controller instalado:
   ```bash
   kubectl get pods --all-namespaces -l app.kubernetes.io/name=ingress-nginx
   kubectl get ingressclass
   ```
2. Si no aparece ninguno y estás en `minikube`, activá el addon oficial:
   ```bash
   minikube addons enable ingress
   ```
   Si estás en `kind` o un clúster propio, instalá el controller de referencia `ingress-nginx`:
   ```bash
   kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml
   ```
3. Esperá a que el pod del controller quede `Running`:
   ```bash
   kubectl get pods -n ingress-nginx --watch
   ```
4. Confirmá que se creó una `IngressClass`:
   ```bash
   kubectl get ingressclass -o wide
   ```

**Preguntas de verificación**
1. ¿Qué diferencia hay entre un `Ingress` resource y un Ingress Controller?
2. Si creás un `Ingress` sin tener ningún controller corriendo en el clúster, ¿qué pasa con el tráfico?
3. ¿Qué campo del objeto `IngressClass` indica qué controller lo implementa?

---

## Ejercicio 2: Desplegar backends de prueba

1. Creá un namespace dedicado:
   ```bash
   kubectl create namespace ingress-demo
   ```
2. Desplegá dos aplicaciones distintas con `kubectl create deployment`:
   ```bash
   kubectl create deployment app-blue --image=hashicorp/http-echo -n ingress-demo -- -text="blue"
   kubectl create deployment app-green --image=hashicorp/http-echo -n ingress-demo -- -text="green"
   ```
3. Exponé cada Deployment como Service en el puerto 5678 (puerto por defecto de `http-echo`):
   ```bash
   kubectl expose deployment app-blue -n ingress-demo --port=80 --target-port=5678
   kubectl expose deployment app-green -n ingress-demo --port=80 --target-port=5678
   ```
4. Verificá que los Services resuelven a los Pods correctos:
   ```bash
   kubectl get endpoints -n ingress-demo
   ```

**Preguntas de verificación**
1. ¿Por qué un `Ingress` necesita apuntar a un `Service` y no directamente a Pods?
2. Si `kubectl get endpoints` muestra `<none>` para `app-blue`, ¿cuáles son las dos causas más comunes?

---

## Ejercicio 3: Ingress básico con un solo backend

1. Creá un `Ingress` imperativamente apuntando todo el tráfico a `app-blue`:
   ```bash
   kubectl create ingress demo-basic -n ingress-demo \
     --class=nginx \
     --rule="demo.local/*=app-blue:80"
   ```
2. Revisá el YAML generado:
   ```bash
   kubectl get ingress demo-basic -n ingress-demo -o yaml
   ```
3. Obtené la IP o el hostname donde escucha el controller:
   ```bash
   kubectl get svc -n ingress-nginx
   ```
4. Probá el acceso simulando el header `Host` (reemplazá `<IP>` por la IP externa o `ClusterIP`/`NodePort` del Service del controller):
   ```bash
   curl -H "Host: demo.local" http://<IP>/
   ```

**Preguntas de verificación**
1. ¿Qué campo del `spec` del Ingress indica qué Ingress Controller debe procesarlo?
2. ¿Qué `pathType` usa por defecto `kubectl create ingress` cuando el path termina en `/*`?
3. ¿Por qué hace falta pasar el header `Host` con `curl` en lugar de solo pegarle a la IP?

---

## Ejercicio 4: Routing por path (`Prefix` vs `Exact`)

1. Editá o recreá el Ingress para enrutar por path hacia los dos backends:
   ```bash
   cat <<EOF | kubectl apply -f -
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     name: demo-paths
     namespace: ingress-demo
   spec:
     ingressClassName: nginx
     rules:
     - host: demo.local
       http:
         paths:
         - path: /blue
           pathType: Prefix
           backend:
             service:
               name: app-blue
               port:
                 number: 80
         - path: /green
           pathType: Prefix
           backend:
             service:
               name: app-green
               port:
                 number: 80
   EOF
   ```
2. Probá ambas rutas:
   ```bash
   curl -H "Host: demo.local" http://<IP>/blue
   curl -H "Host: demo.local" http://<IP>/green
   ```
3. Cambiá el `pathType` de `/blue` a `Exact` y probá con `curl -H "Host: demo.local" http://<IP>/blue/extra`.

**Preguntas de verificación**
1. ¿Qué diferencia de comportamiento hay entre `pathType: Prefix` y `pathType: Exact`?
2. Si dos reglas del mismo host tuvieran el mismo `path`, ¿qué determina cuál gana?

---

## Ejercicio 5: Routing por host (name-based virtual hosting)

1. Aplicá un Ingress con dos hosts distintos, cada uno hacia su propio backend:
   ```bash
   cat <<EOF | kubectl apply -f -
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     name: demo-hosts
     namespace: ingress-demo
   spec:
     ingressClassName: nginx
     rules:
     - host: blue.demo.local
       http:
         paths:
         - path: /
           pathType: Prefix
           backend:
             service:
               name: app-blue
               port:
                 number: 80
     - host: green.demo.local
       http:
         paths:
         - path: /
           pathType: Prefix
           backend:
             service:
               name: app-green
               port:
                 number: 80
   EOF
   ```
2. Probá cada host contra la misma IP del controller:
   ```bash
   curl -H "Host: blue.demo.local" http://<IP>/
   curl -H "Host: green.demo.local" http://<IP>/
   ```

**Preguntas de verificación**
1. ¿Cómo distingue el Ingress Controller a qué backend enviar dos requests que llegan a la misma IP y puerto?
2. ¿Qué pasaría si mandás un request sin header `Host` o con un host que no coincide con ninguna regla?

---

## Ejercicio 6: TLS termination

1. Generá un certificado autofirmado para `secure.demo.local`:
   ```bash
   openssl req -x509 -nodes -days 365 \
     -newkey rsa:2048 \
     -keyout tls.key -out tls.crt \
     -subj "/CN=secure.demo.local/O=secure.demo.local"
   ```
2. Creá el Secret de tipo TLS en el namespace:
   ```bash
   kubectl create secret tls demo-tls -n ingress-demo \
     --cert=tls.crt --key=tls.key
   ```
3. Agregá el bloque `tls` al Ingress:
   ```bash
   cat <<EOF | kubectl apply -f -
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     name: demo-tls
     namespace: ingress-demo
   spec:
     ingressClassName: nginx
     tls:
     - hosts:
       - secure.demo.local
       secretName: demo-tls
     rules:
     - host: secure.demo.local
       http:
         paths:
         - path: /
           pathType: Prefix
           backend:
             service:
               name: app-blue
               port:
                 number: 80
   EOF
   ```
4. Probá el acceso HTTPS ignorando la validación del certificado (es autofirmado):
   ```bash
   curl -k -H "Host: secure.demo.local" https://<IP>/
   ```

**Preguntas de verificación**
1. ¿Qué dos claves obligatorias debe tener un Secret de tipo `kubernetes.io/tls`?
2. ¿Quién termina la conexión TLS: el Pod de `app-blue` o el Ingress Controller?
3. Si `spec.tls[].hosts` no incluye el host de la regla `http`, ¿qué certificado se sirve?

---

## Ejercicio 7: IngressClass y clase por defecto

1. Listá las `IngressClass` disponibles y su controller:
   ```bash
   kubectl get ingressclass -o yaml
   ```
2. Marcá una clase como default agregando la annotation correspondiente:
   ```bash
   kubectl annotate ingressclass nginx ingressclass.kubernetes.io/is-default-class=true --overwrite
   ```
3. Creá un Ingress **sin** especificar `ingressClassName` y confirmá que toma la clase default:
   ```bash
   kubectl create ingress demo-default -n ingress-demo --rule="default.demo.local/*=app-blue:80"
   kubectl get ingress demo-default -n ingress-demo -o jsonpath='{.spec.ingressClassName}{"\n"}'
   ```

**Preguntas de verificación**
1. ¿Qué pasa si hay dos `IngressClass` marcadas como default al mismo tiempo?
2. ¿Qué diferencia hay entre el campo legacy `kubernetes.io/ingress.class` (annotation) y `spec.ingressClassName`?

---

## Ejercicio 8: Troubleshooting

1. Provocá un error apuntando un Ingress a un Service inexistente:
   ```bash
   kubectl create ingress demo-broken -n ingress-demo --rule="broken.demo.local/*=no-existe:80"
   ```
2. Inspeccioná los eventos del objeto:
   ```bash
   kubectl describe ingress demo-broken -n ingress-demo
   ```
3. Revisá los logs del controller para ver cómo reporta el problema:
   ```bash
   kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller --tail=50
   ```
4. Corregí el Ingress apuntándolo a `app-green` y confirmá que el error desaparece:
   ```bash
   kubectl edit ingress demo-broken -n ingress-demo
   ```

**Preguntas de verificación**
1. ¿Dónde vas a encontrar primero el error de un backend inexistente: en `kubectl describe ingress` o en los logs del controller?
2. Nombrá dos causas típicas de un Ingress que "no responde" que no tienen que ver con el YAML del Ingress en sí.

---

<details>
<summary><strong>Ver respuestas</strong></summary>

**Ejercicio 1**
1. El `Ingress` es un objeto de la API de Kubernetes que declara reglas de enrutamiento HTTP/HTTPS; el Ingress Controller es el software (ej. nginx, haproxy) que lee esos objetos y configura un proxy real para cumplirlos. Sin controller, el Ingress es solo metadata inerte.
2. El `Ingress` queda creado en la API pero nunca se programa ningún proxy: no hay tráfico posible a través de él porque nadie lo está implementando.
3. `spec.controller` (ej. `k8s.io/ingress-nginx`).

**Ejercicio 2**
1. Los Pods son efímeros y cambian de IP; el `Service` da una identidad estable (ClusterIP + Endpoints) que el Ingress Controller puede resolver de forma consistente vía kube-proxy o el propio balanceo del controller.
2. Que el `selector` del Service no coincide con las labels del Pod, o que los Pods del Deployment todavía no están `Ready` (falla el readiness probe o siguen en `Pending`/`ContainerCreating`).

**Ejercicio 3**
1. `spec.ingressClassName`.
2. `Prefix` (path que termina en `/*` se traduce a `pathType: Prefix` con el path base).
3. Porque el Ingress Controller enruta por el header `Host` de la request HTTP, no por la IP de destino; sin el header correcto no matchea ninguna regla basada en host (o cae en el default backend si existe).

**Ejercicio 4**
1. `Prefix` matchea el path y todo lo que empiece con él (separado por `/`); `Exact` matchea el path completo carácter por carácter, sin subrutas.
2. Gana la regla más específica: Kubernetes ordena por longitud de coincidencia del path, y ante empate, el comportamiento de desempate depende de la implementación del controller (para nginx, `Exact` gana sobre `Prefix` en el mismo path).

**Ejercicio 5**
1. Por el header `Host` de la request HTTP (name-based virtual hosting): el Ingress Controller inspecciona ese header y lo compara contra `spec.rules[].host`.
2. Si no matchea ningún host, la request cae al `defaultBackend` del Ingress si está definido, o al backend por defecto del controller (normalmente un 404) si no hay ninguno configurado.

**Ejercicio 6**
1. `tls.crt` (certificado) y `tls.key` (clave privada).
2. El Ingress Controller: TLS se termina en el proxy (nginx), y el tráfico hacia el Pod backend normalmente sigue en HTTP plano dentro del clúster, salvo que se configure backend TLS explícitamente.
3. Se sirve el certificado default del controller (autogenerado o "fake certificate"), no el de `demo-tls`, porque nginx no sabe asociar ese Secret al SNI de ese host.

**Ejercicio 7**
1. Comportamiento no determinístico/ambiguo: el controller normalmente toma la primera que encuentra o ninguna, y Kubernetes no impide tener más de una marcada como default (es responsabilidad del operador evitarlo).
2. La annotation `kubernetes.io/ingress.class` es el mecanismo legacy (pre-1.18, deprecado) para asociar un Ingress a un controller por nombre de string; `spec.ingressClassName` es el campo GA que referencia un objeto `IngressClass` real, permitiendo múltiples controllers coexistiendo de forma más explícita.

**Ejercicio 8**
1. En los logs del controller primero — nginx suele loguear "service X does not have any active endpoints" o similar apenas recarga la config. `kubectl describe ingress` puede no mostrar nada anómalo porque el Ingress en sí es sintácticamente válido; el error es de resolución en tiempo de reconciliación del controller.
2. (a) El Service backend no tiene Endpoints porque los Pods no pasan el readiness probe; (b) el Service del propio Ingress Controller no está expuesto correctamente hacia afuera del clúster (tipo `ClusterIP` sin `NodePort`/`LoadBalancer`, o falta de `hostNetwork`/port-forward en clústeres locales como kind/minikube).

</details>