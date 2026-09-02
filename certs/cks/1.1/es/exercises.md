# CKS 1.1 — Usar Network Security Policies para Restringir el Acceso a Nivel de Clúster

## Ejercicios Guiados

**Dominio del examen:** Cluster Setup (peso de este tema: 3)
**Tiempo estimado de laboratorio:** 90–120 minutos

---

## Antes de Empezar

### Qué necesitás

- Un clúster de Kubernetes **cuyo plugin CNI aplique `NetworkPolicy`**. Esta es la razón más común por la que un laboratorio "no funciona": el API server acepta sin problemas un objeto `NetworkPolicy` incluso cuando nada en el clúster lo hace cumplir.
- `kubectl` v1.34 coincidiendo con la versión del clúster.
- Opcionalmente `jq` para el ejercicio de auditoría.

### El modelo mental que estás construyendo

`NetworkPolicy` es un firewall **de lista de permitidos, con alcance de namespace, en L3/L4** aplicado a **pods**, no a Services:

1. Un pod *no seleccionado* por ninguna policy → todo el tráfico permitido (default-allow).
2. Apenas **cualquier** policy selecciona un pod para una dirección (`Ingress` / `Egress`), esa dirección pasa a ser **default-deny** para ese pod, y solo se permite la unión de todas las reglas coincidentes.
3. Las policies son puramente **aditivas**. No hay acción `deny`, ni prioridad, ni ordenamiento en `networking.k8s.io/v1`.

Mantené esas tres frases en la cabeza para cada ejercicio de abajo.

---

## Ejercicio 0 — Construir un clúster de laboratorio que realmente aplique las policies

### Pasos

1. Escribí una configuración de `kind` que **deshabilite el CNI por defecto**, para poder instalar uno capaz de aplicar policies:

```yaml
# kind-cks-netpol.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
  podSubnet: "192.168.0.0/16"
nodes:
  - role: control-plane
  - role: worker
  - role: worker
```

2. Creá el clúster:

```bash
kind create cluster --name cks-netpol --config kind-cks-netpol.yaml
kubectl get nodes
```

Los nodos van a reportar `NotReady` — es lo esperado, todavía no hay CNI.

3. Instalá Calico. Reemplazá `<version>` con el tag de release actual que aparece en la página de instalación de Calico (por ejemplo `v3.30.0`):

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/<version>/manifests/calico.yaml
kubectl -n kube-system rollout status ds/calico-node --timeout=180s
kubectl get nodes
```

> Alternativa: cualquier CNI que aplique policies funciona — Cilium (`cilium install`), Antrea, Weave, o un clúster gestionado con Calico/Cilium habilitado. Todo el YAML de este laboratorio es upstream `networking.k8s.io/v1` y neutral respecto del proveedor.

4. Creá los namespaces que vas a usar, e inspeccioná las etiquetas que Kubernetes les pone automáticamente:

```bash
kubectl create namespace prod
kubectl create namespace dev
kubectl create namespace monitoring
kubectl get ns --show-labels
```

5. Desplegá la carga de trabajo objetivo en `prod` y una segunda en `dev`:

```bash
kubectl -n prod run web --image=nginx:1.27-alpine --labels="app=web,tier=frontend" --port=80
kubectl -n prod expose pod web --port=80 --name=web

kubectl -n prod run db --image=nginx:1.27-alpine --labels="app=db,tier=backend" --port=80
kubectl -n prod expose pod db --port=80 --name=db

kubectl -n dev run scanner --image=nginx:1.27-alpine --labels="app=scanner" --port=80

kubectl -n prod wait --for=condition=Ready pod --all --timeout=120s
kubectl get pods -A -o wide
```

6. Comprobá que el CNI aplica las policies antes de confiar en cualquier resultado posterior. Aplicá un deny-all descartable y confirmá que el tráfico efectivamente se corta:

```bash
kubectl -n prod apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: smoke-test-deny
  namespace: prod
spec:
  podSelector: {}
  policyTypes:
    - Ingress
EOF

kubectl -n prod run probe --rm -it --restart=Never \
  --image=busybox:1.36 --labels="app=probe" \
  -- wget -q -O- -T 3 http://web
```

7. Borrá la policy de prueba de humo:

```bash
kubectl -n prod delete netpol smoke-test-deny
```

### Preguntas de control

- **Q1.** En el paso 4 nunca aplicaste una etiqueta a los namespaces, y sin embargo `--show-labels` imprimió una en cada uno. ¿Cuál es esa etiqueta, quién la establece, y por qué importa enormemente para `NetworkPolicy`?
- **Q2.** En el paso 6, ¿qué salida te indica que el CNI *sí* está aplicando la policy, y qué salida te diría que *no* lo hace? ¿Por qué "el objeto se creó exitosamente" no es evidencia de aplicación?
- **Q3.** La policy `smoke-test-deny` no tiene ninguna clave `ingress:`. ¿Es un error de sintaxis? ¿Qué tráfico permite?
- **Q4.** Aplicaste la policy en `prod`. ¿Afectó al pod `scanner` en `dev`? Justificá tu respuesta a partir del propio objeto de la API.

---

## Ejercicio 1 — Establecer un mapa base de conectividad

No podés verificar una restricción si nunca mediste el estado "antes".

### Pasos

1. Creá una pequeña función de sonda reutilizable en tu shell:

```bash
probe() {   # usage: probe <client-ns> <client-label> <url>
  kubectl -n "$1" run "probe-$RANDOM" --rm -i --restart=Never \
    --image=busybox:1.36 --labels="$2" \
    -- wget -q -O- -T 3 "$3" >/dev/null 2>&1 \
    && echo "ALLOWED  $1/$2 -> $3" \
    || echo "BLOCKED  $1/$2 -> $3"
}
```

2. Registrá la línea base en cada dirección que te importe:

```bash
probe prod  app=client  http://web
probe prod  app=client  http://db
probe dev   app=scanner http://web.prod.svc.cluster.local
probe dev   app=scanner http://db.prod.svc.cluster.local
```

3. Capturá la IP del pod `web` y sondeala directamente, salteando el Service:

```bash
WEB_IP=$(kubectl -n prod get pod web -o jsonpath='{.status.podIP}')
echo "$WEB_IP"
probe dev app=scanner "http://$WEB_IP"
```

4. Confirmá que la resolución de nombres funciona desde un pod sin restricciones:

```bash
kubectl -n prod run dns --rm -i --restart=Never --image=busybox:1.36 \
  -- nslookup web.prod.svc.cluster.local
```

### Preguntas de control

- **Q5.** Las cuatro sondas del paso 2 devolvieron `ALLOWED`. ¿Cuál es la postura de red por defecto de un namespace nuevo de Kubernetes, y es eso un bug de Kubernetes o una decisión de diseño?
- **Q6.** El paso 3 llegó a la IP del pod directamente y obtuvo el mismo resultado que llegar al nombre del Service. ¿Qué te dice eso sobre la capa en la que opera `NetworkPolicy`? ¿Podés escribir una policy que permita tráfico hacia un **Service** pero lo deniegue hacia la **IP del pod** que está detrás?
- **Q7.** ¿Por qué vale la pena ejecutar el paso 4 *ahora*, antes de escribir cualquier policy de egress?

---

## Ejercicio 2 — Default-deny ingress como línea base del namespace

### Pasos

1. Escribí la policy de línea base:

```yaml
# 01-default-deny-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: prod
spec:
  podSelector: {}
  policyTypes:
    - Ingress
```

```bash
kubectl apply -f 01-default-deny-ingress.yaml
```

2. Confirmá qué pods selecciona la policy — así es exactamente como se depura una policy que "no se aplica":

```bash
kubectl -n prod get pods --show-labels
kubectl -n prod get pods -l ''      # empty selector == every pod
```

3. Volvé a ejecutar las sondas de línea base:

```bash
probe prod app=client  http://web
probe dev  app=scanner http://web.prod.svc.cluster.local
probe prod app=client  http://db
```

4. Verificá que el egress fuera de `prod` sigue completamente abierto:

```bash
kubectl -n prod run egresstest --rm -i --restart=Never \
  --image=busybox:1.36 \
  -- wget -q -O- -T 3 http://scanner.dev.svc.cluster.local >/dev/null 2>&1 \
  && echo "prod -> dev egress ALLOWED" || echo "prod -> dev egress BLOCKED"
```

5. Inspeccioná lo que el API server realmente almacenó, incluidos los campos con valores por defecto:

```bash
kubectl -n prod get netpol default-deny-ingress -o yaml
kubectl -n prod describe netpol default-deny-ingress
```

### Preguntas de control

- **Q8.** El paso 4 muestra que los pods de `prod` todavía pueden *iniciar* conexiones hacia `dev`. Explicá por qué una policy de default-deny **ingress** no detiene la exfiltración de datos, y qué podría seguir haciendo un atacante con RCE en un pod de `prod`.
- **Q9.** Eliminá el campo `policyTypes` por completo de `01-default-deny-ingress.yaml` y volvé a aplicarlo. ¿Qué valor le asigna el API server por defecto, y cambia el comportamiento de la policy? Ahora agregá una regla `egress:` pero seguí omitiendo `policyTypes` — ¿qué valor por defecto se asigna entonces?
- **Q10.** `podSelector: {}` selecciona todos los pods. ¿Qué haría `podSelector:` sin ningún valor (es decir, `null`)? ¿Y `podSelector: {matchLabels: {}}`?
- **Q11.** ¿Esta policy bloquea el tráfico desde el kubelet, por ejemplo un readiness probe HTTP contra `web:80`? Probalo agregando un probe al pod y razoná sobre la IP de origen.

---

## Ejercicio 3 — Abrir exactamente un camino: podSelector más puertos

### Pasos

1. Permití que solo los pods `app=client` dentro de `prod` alcancen `web` en TCP/80:

```yaml
# 02-allow-client-to-web.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-client-to-web
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app: web
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: client
      ports:
        - protocol: TCP
          port: 80
```

```bash
kubectl apply -f 02-allow-client-to-web.yaml
```

2. Probá el camino permitido, un camino con etiqueta incorrecta, y el `db` todavía cerrado:

```bash
probe prod app=client  http://web     # expect ALLOWED
probe prod app=scanner http://web     # expect BLOCKED (label mismatch)
probe prod app=client  http://db      # expect BLOCKED
probe dev  app=scanner http://web.prod.svc.cluster.local   # expect BLOCKED
```

3. Ahora probá la dimensión del puerto. Sumá un segundo puerto de contenedor al panorama apuntando a un puerto que no permitiste:

```bash
kubectl -n prod run web8080 --image=nginx:1.27-alpine --labels="app=web" --port=80 \
  --overrides='{"spec":{"containers":[{"name":"web8080","image":"nginx:1.27-alpine","command":["sh","-c","sed -i s/80/8080/ /etc/nginx/conf.d/default.conf && nginx -g \"daemon off;\""],"ports":[{"containerPort":8080}]}]}}'
kubectl -n prod wait --for=condition=Ready pod/web8080 --timeout=60s

W8=$(kubectl -n prod get pod web8080 -o jsonpath='{.status.podIP}')
probe prod app=client "http://$W8:8080"
```

4. Extendé la policy a un **rango de puertos** usando `endPort`:

```yaml
# 03-allow-client-portrange.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-client-portrange
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app: web
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: client
      ports:
        - protocol: TCP
          port: 8000
          endPort: 8090
```

```bash
kubectl apply -f 03-allow-client-portrange.yaml
probe prod app=client "http://$W8:8080"
```

5. Borrá el pod extra y la policy de rango cuando termines:

```bash
kubectl -n prod delete pod web8080
kubectl -n prod delete netpol allow-client-portrange
```

### Preguntas de control

- **Q12.** Ahora dos policies seleccionan el pod `web`: `default-deny-ingress` y `allow-client-to-web`. ¿Cuál "gana"? Enunciá la regla de combinación con precisión.
- **Q13.** En el paso 3 el pod `web8080` lleva `app=web`, así que `allow-client-to-web` lo selecciona. ¿Por qué el puerto 8080 seguía bloqueado antes del paso 4? ¿Qué campo causó el bloqueo — el `from` o los `ports`?
- **Q14.** En el paso 4 reemplazaste el puerto por un rango. ¿Cuáles son las dos restricciones duras sobre `endPort` (respecto de `port`, y respecto de los puertos con nombre)?
- **Q15.** Un atacante compromete el pod `scanner` en `prod` y puede ejecutar `kubectl`. Tiene `patch` sobre pods. Describí el ataque de un solo comando que derrota a `allow-client-to-web`, y nombrá el verbo de RBAC que tenés que denegar para prevenirlo.
- **Q16.** Si borrás `default-deny-ingress` y conservás solo `allow-client-to-web`, ¿qué cambia para `web`? ¿Qué cambia para `db`?

---

## Ejercicio 4 — Reglas entre namespaces y la trampa AND/OR

Este es el concepto de mayor rendimiento de todo el tema, y el ítem del examen que más frecuentemente se falla.

### Pasos

1. Etiquetá los namespaces que querés referenciar:

```bash
kubectl label namespace monitoring purpose=monitoring
kubectl label namespace dev tier=untrusted
kubectl get ns --show-labels
```

2. Desplegá un scraper en `monitoring`:

```bash
kubectl -n monitoring run scraper --image=busybox:1.36 --labels="app=scraper" \
  --command -- sleep 86400
kubectl -n monitoring wait --for=condition=Ready pod/scraper --timeout=60s
```

3. Aplicá la **Variante A** — un único elemento `from` conteniendo *ambos* selectores:

```yaml
# 04a-and-variant.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-monitoring-scraper
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app: web
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              purpose: monitoring
          podSelector:
            matchLabels:
              app: scraper
      ports:
        - protocol: TCP
          port: 80
```

```bash
kubectl apply -f 04a-and-variant.yaml
```

4. Probá la Variante A desde tres orígenes distintos:

```bash
probe monitoring app=scraper http://web.prod.svc.cluster.local   # expect ALLOWED
probe monitoring app=other   http://web.prod.svc.cluster.local   # expect ?
probe prod       app=scraper http://web                          # expect ?
```

5. Ahora aplicá la **Variante B** — los mismos dos selectores como *dos elementos separados de la lista*. Notá el `-` extra:

```yaml
# 04b-or-variant.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-monitoring-scraper
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app: web
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              purpose: monitoring
        - podSelector:
            matchLabels:
              app: scraper
      ports:
        - protocol: TCP
          port: 80
```

```bash
kubectl apply -f 04b-or-variant.yaml
```

6. Volvé a ejecutar las mismas tres sondas:

```bash
probe monitoring app=scraper http://web.prod.svc.cluster.local
probe monitoring app=other   http://web.prod.svc.cluster.local
probe prod       app=scraper http://web
```

7. Intentá referenciar un namespace sin etiquetas personalizadas, usando solo la automática:

```yaml
# 04c-metadata-name.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dev-namespace
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app: db
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: dev
```

```bash
kubectl apply -f 04c-metadata-name.yaml
probe dev app=scanner http://db.prod.svc.cluster.local
```

8. Restaurá la Variante A (la segura) y limpiá la regla de `dev`:

```bash
kubectl apply -f 04a-and-variant.yaml
kubectl -n prod delete netpol allow-dev-namespace
```

### Preguntas de control

- **Q17.** Escribí, en una oración cada una, exactamente qué permiten la Variante A y la Variante B. ¿Cuál es el único carácter YAML que las diferencia?
- **Q18.** En la Variante B, `podSelector: {matchLabels: {app: scraper}}` aparece sin un `namespaceSelector`. ¿A qué namespace se refiere un `podSelector` solo dentro de un bloque `from`?
- **Q19.** La Variante B es un incidente de seguridad esperando a ocurrir. Describí un camino concreto de escalación que un atacante obtiene con la Variante B y que la Variante A deniega.
- **Q20.** El paso 7 seleccionó el namespace `dev` sin haberlo etiquetado nunca. ¿Por qué funcionó? ¿Depender de `kubernetes.io/metadata.name` es una buena o una mala idea desde el punto de vista de la seguridad, dado que no puede cambiarse a un valor distinto del nombre del namespace?
- **Q21.** ¿Cómo permitirías que **cada pod de cada namespace** alcance `web:80`? Escribí el bloque `from`. Ahora escribí el bloque `from` que permite **solo cada pod del propio namespace de la policy**.

---

## Ejercicio 5 — Default-deny egress, y la trampa del DNS

### Pasos

1. Aplicá un bloqueo de egress para todo el namespace `prod`:

```yaml
# 05-default-deny-egress.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  namespace: prod
spec:
  podSelector: {}
  policyTypes:
    - Egress
```

```bash
kubectl apply -f 05-default-deny-egress.yaml
```

2. Observá cómo se manifiesta la falla. Ejecutá estas dos sondas y compará con atención el texto del error:

```bash
kubectl -n prod run t1 --rm -i --restart=Never --image=busybox:1.36 \
  -- nslookup db.prod.svc.cluster.local

DB_IP=$(kubectl -n prod get pod db -o jsonpath='{.status.podIP}')
kubectl -n prod run t2 --rm -i --restart=Never --image=busybox:1.36 \
  -- wget -q -O- -T 3 "http://$DB_IP"
```

3. Encontrá los pods de CoreDNS y sus etiquetas — los necesitás para una regla precisa:

```bash
kubectl -n kube-system get pods -l k8s-app=kube-dns --show-labels
kubectl -n kube-system get svc kube-dns
```

4. Agregá un permiso de egress para DNS acotado únicamente a CoreDNS:

```yaml
# 06-allow-dns-egress.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: prod
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

```bash
kubectl apply -f 06-allow-dns-egress.yaml

kubectl -n prod run t3 --rm -i --restart=Never --image=busybox:1.36 \
  -- nslookup db.prod.svc.cluster.local
```

5. Confirmá que la resolución de nombres ahora funciona pero la conexión real todavía no:

```bash
kubectl -n prod run t4 --rm -i --restart=Never --image=busybox:1.36 \
  -- wget -q -O- -T 3 http://db
```

6. Permití el camino este-oeste previsto — `app=web` hacia `app=db` en TCP/80 — escribiendo **ambas** mitades del camino:

```yaml
# 07-web-to-db.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: web-egress-to-db
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app: web
  policyTypes:
    - Egress
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: db
      ports:
        - protocol: TCP
          port: 80
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: db-ingress-from-web
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app: db
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: web
      ports:
        - protocol: TCP
          port: 80
```

```bash
kubectl apply -f 07-web-to-db.yaml
kubectl -n prod exec web -- sh -c 'apk add --no-cache curl >/dev/null 2>&1; curl -s -m 3 -o /dev/null -w "%{http_code}\n" http://db'
```

### Preguntas de control

- **Q22.** En el paso 2, `nslookup` falló aunque nunca escribiste una regla sobre DNS. Explicá el mecanismo. ¿Por qué esta es la causa número uno de caídas cuando los equipos despliegan policies de egress?
- **Q23.** ¿Por qué el paso 4 necesitó un `namespaceSelector` *y* un `podSelector` dentro del mismo elemento `from`/`to`, en lugar de solo `podSelector: {k8s-app: kube-dns}`?
- **Q24.** Tu regla permite UDP/53 **y** TCP/53. ¿En qué circunstancias un resolver recurre a TCP, y qué se rompe si permitís solo UDP?
- **Q25.** En el paso 6 escribiste dos policies para una conexión lógica. Explicá por qué una policy no alcanza, e identificá con precisión qué pods selecciona cada una de las dos.
- **Q26.** ¿El tráfico de retorno (la respuesta HTTP de `db` hacia `web`) requiere su propia regla? ¿Qué propiedad del motor de aplicación hace que la respuesta sea la que es?
- **Q27.** Un compañero propone reemplazar la regla de DNS con `- to: - ipBlock: {cidr: 10.96.0.10/32}` más los puertos 53. Nombrá dos formas en las que esto es más frágil que la regla basada en selectores.

---

## Ejercicio 6 — ipBlock, `except`, y bloquear el endpoint de metadata de la nube

Restringir el egress hacia la metadata link-local (`169.254.169.254`) es un escenario clásico de CKS: ese endpoint entrega credenciales IAM del nodo a cualquier cosa que pueda alcanzarlo.

### Pasos

1. Desplegá una carga de trabajo que represente un servicio no confiable expuesto a internet:

```bash
kubectl -n prod run dmz --image=nicolaka/netshoot --labels="app=dmz" \
  --command -- sleep 86400
kubectl -n prod wait --for=condition=Ready pod/dmz --timeout=120s
```

2. Notá que `default-deny-egress` actualmente lo bloquea. Escribí una policy que permita egress amplio pero recorte el endpoint de metadata:

```yaml
# 08-dmz-egress-no-metadata.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: dmz-egress-block-metadata
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app: dmz
  policyTypes:
    - Egress
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 169.254.0.0/16
              - 10.96.0.0/12
              - 192.168.0.0/16
```

```bash
kubectl apply -f 08-dmz-egress-no-metadata.yaml
```

3. Verificá el recorte:

```bash
kubectl -n prod exec dmz -- nc -z -w 2 169.254.169.254 80 \
  && echo "metadata REACHABLE" || echo "metadata BLOCKED"

kubectl -n prod exec dmz -- nc -z -w 2 1.1.1.1 443 \
  && echo "internet REACHABLE" || echo "internet BLOCKED"
```

4. Ahora probá DNS desde el pod `dmz` y observá qué rompió tu `except`:

```bash
kubectl -n prod exec dmz -- dig +short +time=2 +tries=1 kubernetes.default.svc.cluster.local
```

5. Intentá aplicar una entrada `except` que esté *fuera* del `cidr` y leé la respuesta del API server:

```bash
kubectl -n prod apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: bad-except
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app: dmz
  policyTypes:
    - Egress
  egress:
    - to:
        - ipBlock:
            cidr: 10.0.0.0/8
            except:
              - 192.168.5.0/24
EOF
```

6. Intentá mezclar `ipBlock` con un selector en el mismo elemento peer:

```bash
kubectl -n prod apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: bad-mixed-peer
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app: dmz
  policyTypes:
    - Egress
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
          podSelector:
            matchLabels:
              app: db
EOF
```

7. Permití egress hacia el API server de Kubernetes. Encontrá ambas direcciones involucradas:

```bash
kubectl get svc kubernetes -n default -o jsonpath='{.spec.clusterIP}{"\n"}'
kubectl get endpoints kubernetes -n default -o jsonpath='{.subsets[*].addresses[*].ip}{"\n"}'
```

```yaml
# 09-allow-apiserver-egress.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-apiserver-egress
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app: dmz
  policyTypes:
    - Egress
  egress:
    - to:
        - ipBlock:
            cidr: 10.96.0.1/32      # kubernetes Service ClusterIP
        - ipBlock:
            cidr: 172.18.0.0/16     # control-plane node IPs — adjust to your cluster
      ports:
        - protocol: TCP
          port: 443
        - protocol: TCP
          port: 6443
```

```bash
kubectl apply -f 09-allow-apiserver-egress.yaml
kubectl -n prod exec dmz -- curl -sk -m 3 -o /dev/null -w "%{http_code}\n" https://kubernetes.default.svc
```

### Preguntas de control

- **Q28.** El paso 5 y el paso 6 fallaron ambos. Citá la *categoría* de cada falla y enunciá las dos reglas estructurales de `NetworkPolicyPeer` que demuestran.
- **Q29.** En el paso 4, DNS se rompió. ¿Qué entrada de `except` lo causó, y cuáles son dos maneras correctas distintas de arreglar la policy sin dejar de bloquear la metadata?
- **Q30.** ¿Por qué la regla del API server necesitó *tanto* el ClusterIP del Service como el rango de IPs del nodo? ¿Qué componente reescribe la dirección de destino, y en qué momento respecto de la evaluación de la policy ocurre eso?
- **Q31.** `ipBlock` en una regla de **ingress** coincide con la IP de origen del paquete. Explicá por qué un Service `NodePort` puede volver inútil esa regla, y qué campo del Service restaura la IP real del cliente.
- **Q32.** Bloquear `169.254.169.254` con una `NetworkPolicy` es un control *con alcance de namespace*. Nombrá dos brechas que dejan el endpoint de metadata alcanzable a pesar de esta policy, y el pod-spec / control de admisión que usarías para cerrarlas.

---

## Ejercicio 7 — Postura a nivel de clúster: auditoría y despliegue

"Acceso a nivel de clúster" en el objetivo del examen significa que tenés que pensar más allá de un namespace. `NetworkPolicy` no tiene ningún objeto con alcance de clúster, así que una línea base a nivel de clúster son *n* objetos idénticos más un control que los mantenga ahí.

### Pasos

1. Inventariá cada policy del clúster:

```bash
kubectl get networkpolicies --all-namespaces
kubectl get netpol -A -o custom-columns=\
'NS:.metadata.namespace,NAME:.metadata.name,SELECTOR:.spec.podSelector,TYPES:.spec.policyTypes'
```

2. Encontrá los namespaces que carecen de una línea base de default-deny **ingress**:

```bash
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
  count=$(kubectl get netpol -n "$ns" -o json 2>/dev/null | jq '
    [ .items[]
      | select(.spec.podSelector == {})
      | select((.spec.policyTypes // ["Ingress"]) | index("Ingress"))
    ] | length')
  [ "${count:-0}" -eq 0 ] && echo "MISSING default-deny-ingress: $ns"
done
```

3. Repetí para egress intercambiando `"Ingress"` por `"Egress"` en la llamada a `index()`, y notá qué namespaces del sistema aparecen.

4. Determiná qué pods protege realmente una policy dada, usando su propio selector:

```bash
kubectl -n prod get netpol allow-client-to-web -o jsonpath='{.spec.podSelector.matchLabels}{"\n"}'
kubectl -n prod get pods -l app=web -o name
```

5. Encontrá pods que **ninguna** policy selecciona en un namespace que tiene un default-deny — una discrepancia acá significa que un pod está silenciosamente desprotegido porque cambiaron sus etiquetas:

```bash
kubectl -n prod get pods -o custom-columns='POD:.metadata.name,LABELS:.metadata.labels'
```

6. Aplicá la línea base deny-all (ambas direcciones) a un namespace nuevo y verificá que el patrón es reutilizable:

```bash
kubectl create namespace payments
kubectl -n payments apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
EOF
kubectl -n payments get netpol default-deny-all -o yaml
```

7. Confirmá que no dejaste al control plane afuera por accidente. Chequeá que los pods de `kube-system` estén intactos y que el clúster esté sano:

```bash
kubectl get netpol -n kube-system
kubectl -n kube-system get pods
kubectl get --raw='/readyz?verbose' | tail -5
```

### Preguntas de control

- **Q33.** En el paso 6 omitiste `namespace:` de `metadata` y te apoyaste en `-n payments`. ¿Una `NetworkPolicy` tiene alcance de clúster o de namespace? ¿Cuál es la consecuencia para aplicar una línea base *a nivel de clúster*?
- **Q34.** Una desarrolladora crea un namespace completamente nuevo. ¿Queda protegido por tu línea base? Nombrá dos mecanismos que podrían aplicar la línea base automáticamente al crearse el namespace.
- **Q35.** En el paso 5 buscaste pods que ninguna policy selecciona. Describí el modo de falla en el que una policy existe, parece correcta en la revisión, y no protege nada.
- **Q36.** ¿Por qué sería peligroso aplicar `default-deny-all` a `kube-system`? Nombrá dos cosas concretas que se romperían.
- **Q37.** `NetworkPolicy` v1 no tiene acción `deny` ni prioridad. Dado solo v1, ¿cómo expresás "el namespace `dev` nunca debe alcanzar el namespace `prod`, sin importar qué policy escriba el equipo de `prod`"? ¿Es realmente posible?

---

## Ejercicio 8 — (Opcional, más allá del v1 core) Policy con alcance de clúster mediante AdminNetworkPolicy

La API `policy.networking.k8s.io` agrega policies con alcance de clúster, ordenadas y con denegación explícita. **No** forma parte de Kubernetes core: se distribuye como CRDs del proyecto `network-policy-api` de SIG-Network y requiere soporte del CNI (Calico, Cilium, OVN-Kubernetes). Tomá esto como contexto sobre *por qué* v1 por sí solo no puede expresar una barrera de protección a nivel de clúster — no lo esperes como tarea del examen a menos que el clúster claramente lo tenga instalado.

### Pasos

1. Chequeá si la API está presente:

```bash
kubectl api-resources | grep -i adminnetworkpolicy || echo "ANP not installed"
```

2. Si está presente, inspeccioná un ejemplo que el dueño de un namespace no puede sobrescribir:

```yaml
apiVersion: policy.networking.k8s.io/v1alpha1
kind: AdminNetworkPolicy
metadata:
  name: deny-untrusted-to-prod
spec:
  priority: 10
  subject:
    namespaces:
      matchLabels:
        kubernetes.io/metadata.name: prod
  ingress:
    - name: "deny-from-untrusted"
      action: Deny
      from:
        - namespaces:
            matchLabels:
              tier: untrusted
```

3. Contrastá los nombres de los campos contra `networking.k8s.io/v1` y anotá las diferencias: `priority`, `action`, `subject`, y el alcance de clúster.

### Preguntas de control

- **Q38.** ¿Qué tres capacidades ofrece `AdminNetworkPolicy` que `networking.k8s.io/v1` estructuralmente no puede?
- **Q39.** ¿Qué hace la acción `Pass`, y por qué es la clave para "el administrador del clúster fija un piso, los dueños de los namespaces deciden por encima"?
- **Q40.** `kubectl api-resources` no devolvió nada para ANP pero el `kubectl apply` del manifiesto de arriba igual falló con un error. Dado que ANP es un CRD, ¿qué error esperás, y qué te dice eso sobre validar las capacidades de un clúster de examen antes de escribir YAML?

---

## Limpieza

```bash
kubectl delete namespace prod dev monitoring payments
kind delete cluster --name cks-netpol
```

---

## Patrones de referencia que vale la pena memorizar

| Objetivo | Campos clave |
|---|---|
| Denegar todo el ingress en un namespace | `podSelector: {}` + `policyTypes: [Ingress]`, sin `ingress:` |
| Denegar todo el egress en un namespace | `podSelector: {}` + `policyTypes: [Egress]`, sin `egress:` |
| Denegar todo | `podSelector: {}` + `policyTypes: [Ingress, Egress]` |
| Permitir todo el ingress | `ingress: [{}]` |
| Permitir desde un namespace, cualquier pod | `from: [{namespaceSelector: {matchLabels: {...}}}]` |
| Permitir desde un pod en un namespace (**AND**) | un ítem `from` con ambos `namespaceSelector` y `podSelector` |
| Permitir desde cualquier namespace | `from: [{namespaceSelector: {}}]` |
| Permitir DNS | egress hacia `kube-system` / `k8s-app=kube-dns`, UDP **y** TCP 53 |
| Permitir un CIDR menos un agujero | `ipBlock: {cidr: ..., except: [...]}` — `except` debe estar dentro de `cidr` |

---

<details>
<summary><strong>Respuestas</strong></summary>

**Q1.** La etiqueta es `kubernetes.io/metadata.name: <namespace-name>`. El API server la establece automáticamente en cada namespace (la funcionalidad `NamespaceDefaultLabelName`, GA desde Kubernetes 1.21) y el valor es inmutable — siempre es igual al nombre del namespace. Importa porque `namespaceSelector` hace coincidencia **solo sobre etiquetas de namespace**; no hay forma de referenciar un namespace por nombre en el esquema de `NetworkPolicy`. Sin esta etiqueta automática tendrías que etiquetar manualmente cada namespace antes de poder escribir una regla entre namespaces, y una etiqueta olvidada haría que una regla no coincida con nada, silenciosamente.

**Q2.** La aplicación se demuestra con el **fallo** de la sonda: `wget` se cuelga durante el timeout de 3 segundos y el pod sale con código distinto de cero, así que `kubectl run` reporta `pod "probe" deleted` con un error / salida distinta de cero. Si el CNI **no** aplica las policies, la sonda igual devuelve el HTML de bienvenida de nginx al instante. La creación exitosa del objeto prueba únicamente que el API server aceptó un recurso `networking.k8s.io/v1` bien formado — el API server almacena los objetos `NetworkPolicy` incondicionalmente y nunca chequea si algún componente los lee. La aplicación es enteramente tarea del CNI, así que "creado" y "aplicado" son hechos independientes.

**Q3.** No es un error de sintaxis. `ingress` es un campo opcional; omitirlo significa "la lista de reglas de permiso está vacía". Combinado con `policyTypes: [Ingress]` y `podSelector: {}`, selecciona cada pod de `prod` para ingress y no permite nada, es decir, default-deny ingress. Permite **cero** tráfico entrante hacia cualquier pod del namespace. (Notá la diferencia con `ingress: [{}]`, que es una única regla vacía que permite *todo* el tráfico entrante.)

**Q4.** No. `NetworkPolicy` es un recurso con alcance de namespace, y `spec.podSelector` se evalúa **solo dentro del propio namespace de la policy**. `metadata.namespace: prod` por lo tanto acota el objeto entero a `prod`; ningún campo del objeto puede seleccionar pods en otro lado. Nada en `dev` se ve afectado. Esta es la razón estructural por la que un "default deny a nivel de clúster" requiere un objeto por namespace.

**Q5.** Un namespace nuevo está completamente abierto — cualquier pod puede alcanzar cualquier otro pod en cualquier namespace, y cualquier dirección externa. Esto es una decisión de diseño deliberada, no un bug: el modelo de red plana de Kubernetes garantiza que cada pod pueda alcanzar cada pod sin NAT, y `NetworkPolicy` es una restricción opcional superpuesta encima. La consecuencia de seguridad es que el aislamiento debe ser *agregado*; el valor por defecto seguro tiene que ser creado por un operador.

**Q6.** `NetworkPolicy` opera en L3/L4 sobre **IPs de pods** (y CIDRs), no sobre Services. El tráfico hacia un ClusterIP recibe DNAT de kube-proxy (o del reemplazo del CNI) hacia la IP de un pod backend, y la policy se evalúa contra esa IP de pod final. Por lo tanto **no podés** escribir una policy que permita el acceso vía Service pero deniegue el acceso directo a la IP del pod — desde el punto de vista del motor de aplicación son el mismo paquete. Cualquier cosa que dependa de "solo accesible vía el Service" no es un control de seguridad.

**Q7.** Porque una vez que aplicás una policy de default-deny **egress**, DNS se rompe primero y todos los demás síntomas se vuelven ambiguos. Confirmar de antemano que la resolución funciona significa que cuando `nslookup` falle más tarde vas a saber que la causa fue la policy, en lugar de un despliegue de CoreDNS roto o un `resolv.conf` mal configurado. De forma más general: nunca introduzcas una restricción sin una medición "antes" conocida como buena.

**Q8.** La policy establece solo `policyTypes: [Ingress]`, así que la dirección de egress de cada pod de `prod` queda no seleccionada y por lo tanto default-allow. Un atacante con ejecución de código en un pod de `prod` todavía puede abrir conexiones salientes: exfiltrar datos hacia un host C2 externo, descargar herramientas de segunda etapa, escanear y conectarse a pods de otros namespaces (incluido `db`, cuyo *ingress* está denegado solo para lo entrante — pero el propio pod del atacante iniciando una salida hacia `db` es entrante *hacia db*, así que ese salto específico está bloqueado; los saltos hacia cualquier pod en `dev`, `monitoring`, o internet no lo están), y alcanzar el endpoint de metadata de la nube. Las policies solo de ingress contienen el movimiento lateral *hacia* pods protegidos pero no hacen nada respecto de la exfiltración.

**Q9.** Con `ingress` y `egress` ambos ausentes, `policyTypes` toma por defecto `["Ingress"]` — el comportamiento no cambia, sigue siendo default-deny ingress. La regla de asignación por defecto es: `Ingress` siempre se incluye; `Egress` se incluye solo si la policy tiene al menos una regla `egress`. Así que si agregás un bloque `egress:` y seguís omitiendo `policyTypes`, el API server lo establece por defecto en `["Ingress", "Egress"]` — lo que significa que silenciosamente también activaste el default-deny de ingress para esos pods. Por eso el hábito seguro es escribir `policyTypes` explícitamente, siempre.

**Q10.** `podSelector: {}` es un `LabelSelector` vacío, que por convención de Kubernetes coincide con **todos** los pods del namespace. `podSelector:` con valor nulo es inválido acá — `podSelector` es un campo obligatorio de `NetworkPolicySpec`, así que el API server rechaza el objeto. `podSelector: {matchLabels: {}}` es un mapa match-labels vacío dentro del selector, que también evalúa a "coincidir con todo" — semánticamente idéntico a `{}`. (El primo peligroso es un `namespaceSelector: {}` dentro de un bloque `from`, que significa "todos los namespaces" — no "ningún namespace".)

**Q11.** En la práctica el readiness probe sigue funcionando, pero no por nada que esté en la policy: el kubelet sondea el pod desde el namespace de red del **nodo**, y la mayoría de los CNIs (Calico, Cilium) permiten explícitamente el tráfico host-a-pod-local para que los probes y los health checks locales del nodo nunca se rompan por una policy. La IP de origen es la IP del nodo, no una IP de pod, así que ningún `podSelector` podría coincidir jamás con ella; si necesitaras permitirlo explícitamente usarías un `ipBlock` con el CIDR del nodo. La lección: `NetworkPolicy` gobierna el tráfico pod-a-pod y pod-a-externo; el tráfico originado en el host hacia pods locales es un recorte específico del CNI que tenés que verificar en lugar de asumir.

**Q12.** Ninguna "gana" — las policies son estrictamente **aditivas (OR)**. La regla efectiva para un pod es: si cualquier policy lo selecciona para una dirección, esa dirección es deny por defecto, y el conjunto permitido es la *unión* de cada regla coincidente de cada policy. Así que `web` tiene el ingress denegado por defecto (por `default-deny-ingress`) y un agujero abierto en él (por `allow-client-to-web`). No hay precedencia, ni ordenamiento, ni forma de que una policy posterior reste algo de una anterior.

**Q13.** El campo `ports` causó el bloqueo. `allow-client-to-web` sí selecciona a `web8080` (lleva `app=web`), y el origen `app=client` coincidió con la cláusula `from` — pero la regla permite solo `protocol: TCP, port: 80`. La lista `ports` de una regla restringe el puerto de destino en el pod *seleccionado* (objetivo); todo lo no listado queda denegado. Omitir `ports` por completo habría permitido todos los puertos.

**Q14.** (1) `endPort` debe ser **mayor o igual que** `port`, y ambos deben estar dentro de 1–65535; el API server rechaza `endPort < port`. (2) `endPort` solo puede usarse cuando `port` es un valor **numérico** — no podés combinar `endPort` con un puerto con nombre (`port: http`), porque un nombre se resuelve por pod a un único número y un rango no tiene sentido. Notá también que el CNI debe soportar rangos de puertos; el campo es estable en la API desde v1.25 pero un plugin viejo puede ignorarlo.

**Q15.** El atacante ejecuta `kubectl -n prod label pod scanner app=client --overwrite` (o `kubectl patch`), dándole a su pod la etiqueta en la que la policy confía, y gana acceso inmediato a `web`. La identidad en `NetworkPolicy` son las **etiquetas**, y las etiquetas son mutables por la vía normal de actualización de pods. El verbo a denegar es `patch` (y `update`) sobre `pods` — una service account de carga de trabajo no debería poder modificar los metadatos de un pod. Esta es la lección general: una network policy es solo tan fuerte como el RBAC que protege las etiquetas en las que confía.

**Q16.** Para `web`: no cambia nada. `allow-client-to-web` selecciona a `web` para `Ingress`, lo que por sí solo ya deja a `web` en default-deny entrante; el deny-all explícito era redundante *para ese pod*. Para `db`: cambia todo — ninguna policy selecciona ya a `db`, así que vuelve a default-allow y se vuelve alcanzable desde cada pod del clúster. Esto es exactamente por qué importa la línea base `podSelector: {}` a nivel de namespace: las policies dirigidas protegen únicamente lo que seleccionan.

**Q17.** La Variante A permite: *pods etiquetados `app=scraper` **que están en** un namespace etiquetado `purpose=monitoring`*. La Variante B permite: *cualquier pod en cualquier namespace etiquetado `purpose=monitoring`,* **O** *cualquier pod etiquetado `app=scraper` en el propio namespace de la policy (`prod`)*. La diferencia es un `-`: si `podSelector` es una clave del mismo elemento de lista que `namespaceSelector` (AND) o el comienzo de un nuevo elemento de lista (OR).

**Q18.** El namespace **propio** de la policy — acá, `prod`. Un `podSelector` dentro de un elemento `from`/`to` sin un `namespaceSelector` acompañante está implícitamente acotado al namespace donde vive la `NetworkPolicy`. Para seleccionar pods en un namespace distinto tenés que emparejarlo con un `namespaceSelector` en el *mismo* elemento.

**Q19.** Con la Variante B, cualquier pod que logre llevar la etiqueta `app=scraper` en `prod` obtiene acceso a `web` — así que un atacante que pueda crear o reetiquetar un pod dentro de `prod` (o una carga de trabajo legítima pero no relacionada de `prod` que casualmente use esa etiqueta) alcanza `web:80` sin tocar jamás el namespace `monitoring`. Además, *cada* pod en `monitoring` obtiene acceso, no solo el scraper, así que comprometer cualquier sidecar o exporter de monitoreo otorga el mismo alcance. La Variante A requiere ambas condiciones simultáneamente, algo que un atacante confinado a un namespace no puede satisfacer.

**Q20.** Funcionó porque `kubernetes.io/metadata.name` es aplicada automáticamente a cada namespace por el API server, así que `dev` ya la tenía. Desde el punto de vista de la seguridad es **buena**: el valor es forzado por el API server a ser igual al nombre del namespace y no puede falsificarse ni establecerse al nombre de otro namespace, así que es un identificador confiable. Las etiquetas personalizadas como `tier: untrusted` son la opción más débil — cualquiera con `update` sobre namespaces puede agregarlas o quitarlas, así que una regla basada en una etiqueta personalizada es solo tan fuerte como el RBAC de namespaces. Usá `kubernetes.io/metadata.name` cuando te referís a un namespace específico; usá etiquetas personalizadas para semántica de grupo, y controlá estrictamente quién puede establecerlas.

**Q21.** Todos los pods en todos los namespaces:
```yaml
from:
  - namespaceSelector: {}
```
Solo todos los pods del propio namespace de la policy:
```yaml
from:
  - podSelector: {}
```
La trampa es que `namespaceSelector: {}` significa "cada namespace", no "ningún namespace" — un selector vacío siempre coincide con todo.

**Q22.** Aplicar `policyTypes: [Egress]` sin reglas `egress` seleccionó cada pod de `prod` para egress y denegó todo el tráfico saliente — incluidos los paquetes UDP/53 del pod hacia el Service de CoreDNS. Sin DNS, cada búsqueda de nombre de host falla, así que las aplicaciones fallan antes siquiera de abrir una conexión. Es la principal causa de caídas porque la falla es indirecta: la app registra un error de resolución de nombres, no un connection-refused, así que los operadores miran CoreDNS o `resolv.conf` en lugar de la policy que acaban de aplicar. Todo despliegue de default-deny-egress debe salir junto con un permiso de DNS.

**Q23.** Porque un `podSelector` solo dentro de un elemento `to` está acotado al propio namespace de la policy (`prod`), y CoreDNS corre en `kube-system`. `podSelector: {k8s-app: kube-dns}` por sí solo intentaría coincidir con un pod que tenga esa etiqueta *en `prod`*, no encontraría ninguno, y no permitiría nada. Emparejarlo con `namespaceSelector: {kubernetes.io/metadata.name: kube-system}` en el **mismo elemento de lista** aplica un AND a las dos condiciones y apunta correctamente a los pods de CoreDNS.

**Q24.** Un resolver recurre a TCP cuando una respuesta UDP excede el tamaño de buffer anunciado y vuelve truncada (con el bit TC activado) — común con respuestas DNSSEC grandes, registros con muchas respuestas, o consultas tipo `AXFR`. Si permitís solo UDP/53, esas búsquedas se cuelgan o fallan de forma intermitente: la mayoría de los nombres resuelven bien y unos pocos no, lo que produce bugs confusos y dependientes de la carga. Permití siempre ambos.

**Q25.** Egress e ingress se evalúan **independientemente en cada extremo** de una conexión. `web-egress-to-db` selecciona los pods etiquetados `app=web` y gobierna su dirección saliente; `db-ingress-from-web` selecciona los pods etiquetados `app=db` y gobierna su dirección entrante. Como `prod` tiene tanto una línea base de default-deny-egress como una de default-deny-ingress, ambos extremos están cerrados, así que hay que abrir ambos agujeros o el paquete muere en el extremo que siga cerrado. Olvidar una mitad es la razón más común por la que un par de policies "que se ve correcto" igual bloquea el tráfico.

**Q26.** No se necesita una regla aparte. La aplicación de `NetworkPolicy` es **con estado / con seguimiento de conexiones**: una vez que una conexión se permite en una dirección, los paquetes de respuesta de esa conexión establecida se permiten automáticamente. Las reglas describen la *iniciación de la conexión*, no paquetes individuales. (Por eso nunca escribís "permitir de vuelta los puertos efímeros 32768–60999" como harías en una ACL sin estado.)

**Q27.** (1) El ClusterIP de `kube-dns` es específico del clúster y puede diferir entre clústeres o cambiar si el Service se recrea — el manifiesto deja de ser portable y falla silenciosamente. (2) `ipBlock` coincide con la dirección *después* del DNAT de kube-proxy en muchos caminos de datos, así que el paquete que ve el motor puede llevar la IP del **pod** de CoreDNS, no el ClusterIP, y la regla nunca coincide; las IPs de los pods también son efímeras, así que ningún CIDR estático es confiable. La regla basada en selectores sigue a CoreDNS dondequiera que sea reprogramado y funciona sin importar el CIDR del Service.

**Q28.** El paso 5 falla en la **validación**: el API server rechaza el objeto porque cada CIDR en `except` debe ser un subconjunto del `cidr` que lo contiene (`192.168.5.0/24` no está dentro de `10.0.0.0/8`). El paso 6 también falla en la **validación**: un `NetworkPolicyPeer` puede establecer `ipBlock` **o** el par de selectores (`podSelector` / `namespaceSelector`), nunca ambos en el mismo elemento. Las dos reglas estructurales: (1) las entradas de `except` deben estar contenidas dentro de su `cidr`; (2) `ipBlock` es mutuamente excluyente con los selectores dentro de un peer — para permitir ambos, usá dos elementos de lista separados.

**Q29.** `10.96.0.0/12` lo rompió — ese rango contiene el ClusterIP de `kube-dns` (típicamente `10.96.0.10`), así que las consultas DNS a la dirección del Service quedaron excluidas. Dos arreglos correctos: (a) agregar una regla de egress **separada** usando la forma `namespaceSelector` + `podSelector` para CoreDNS en UDP/TCP 53 (las reglas son aditivas, así que la regla basada en selectores reabre DNS sin debilitar el bloqueo de metadata); o (b) reducir el `except` de `169.254.0.0/16` + rangos internos amplios a solamente `169.254.169.254/32` más los rangos internos que genuinamente necesites bloquear, manteniendo el ClusterIP de DNS fuera del conjunto exceptuado. La opción (a) es preferible — mantiene intacta la intención de "bloquear interno + metadata" y expresa DNS por identidad en lugar de por dirección.

**Q30.** Porque kube-proxy (o el reemplazo de kube-proxy del CNI) hace DNAT del ClusterIP de `kubernetes` hacia un endpoint real — la IP del nodo del control plane en el puerto 6443 — y dependiendo del camino de datos, la policy de egress puede evaluarse **después** de esa traducción. Permitir solo el ClusterIP funciona en algunos CNIs y falla en otros; permitir solo la IP del nodo falla donde la policy se evalúa pre-DNAT. Permitir ambas direcciones y ambos puertos (443 para el ClusterIP, 6443 para el endpoint) es la respuesta portable. La lección general: para cualquier regla `ipBlock` dirigida a un Service, determiná si tu CNI ve direcciones pre- o post-DNAT y cubrí ambas.

**Q31.** Cuando el tráfico entra por un `NodePort` (o un `LoadBalancer` con el `externalTrafficPolicy: Cluster` por defecto), kube-proxy puede reenviar el paquete a un pod en un nodo *distinto* y hacerle SNAT, así que la IP de origen que ve el motor de policies es la IP del **nodo**, no la del cliente original. Una regla `ipBlock` de ingress escrita contra CIDRs de clientes reales entonces no coincide con nada — o, peor, un `except` pensado para bloquear a un cliente es eludido porque cada paquete parece venir de un nodo. Establecer `spec.externalTrafficPolicy: Local` en el Service preserva la IP de origen del cliente (a costa de enrutar solo hacia pods del nodo receptor).

**Q32.** Brechas: (1) Los pods que corren con `hostNetwork: true` comparten el namespace de red del nodo, y la mayoría de los CNIs no aplican la `NetworkPolicy` de pod al tráfico de host-network — un pod así alcanza el endpoint de metadata libremente. (2) La policy cubre únicamente los namespaces donde la aplicaste; cualquier namespace nuevo o sin etiquetar, o un pod cuyas etiquetas no coincidan con el `podSelector` de la policy, queda desprotegido. (3) Un pod que puede escalar al nodo (contenedor privilegiado, hostPID, montaje del host escribible) alcanza la metadata desde el host. Cerralas prohibiendo `hostNetwork`, `privileged` y los montajes del host vía Pod Security Admission (`restricted`) o un motor de policies (Kyverno/OPA Gatekeeper), y aplicando la línea base del namespace automáticamente en lugar de a mano. En proveedores de nube, además hacé cumplir IMDSv2 / deshabilitá el endpoint de metadata legacy a nivel de la instancia — un control enteramente fuera de Kubernetes.

**Q33.** Con alcance de namespace. `kubectl -n payments` simplemente completó `metadata.namespace` por vos; el objeto es inerte fuera de ese namespace. La consecuencia es que una "línea base a nivel de clúster" en Kubernetes core no es un objeto — son N objetos idénticos, uno por namespace, más algo que garantice que el namespace N+1 también reciba uno. No existe un kind `NetworkPolicy` con alcance de clúster.

**Q34.** No — un namespace nuevo no tiene policies y está completamente abierto. Dos mecanismos: (1) un controlador de admisión/policies como **Kyverno** con una regla `generate` (o OPA Gatekeeper con un patrón de mutación/expansión) que cree los objetos de default-deny automáticamente cada vez que se crea un `Namespace`; (2) un controlador de GitOps (Argo CD / Flux) reconciliando un repositorio donde cada namespace viene con su policy de línea base, de modo que la deriva o un namespace creado manualmente sea marcado y corregido. Una tercera opción, donde el CNI lo soporte, es una `AdminNetworkPolicy` con alcance de clúster o una `GlobalNetworkPolicy` de Calico, que se aplica sin objetos por namespace.

**Q35.** El `spec.podSelector` de la policy no coincide con ningún pod — porque una etiqueta tenía un error de tipeo, porque las etiquetas del pod template de un Deployment se cambiaron después, o porque la carga de trabajo se movió a un namespace donde la policy no existe. El objeto aparece en `kubectl get netpol`, pasa la revisión del YAML, y no aplica nada. Peor aún, si era la *única* policy que seleccionaba un pod, ese pod vuelve silenciosamente a default-allow. Verificá siempre resolviendo el selector contra pods vivos (`kubectl get pods -l <selector>`) y ejecutando una sonda de conectividad real, nunca leyendo solamente el YAML.

**Q36.** Un deny-all general en `kube-system` rompe la propia plomería del control plane. Dos ejemplos concretos: (1) **CoreDNS** perdería el egress hacia el API server (observa Services y EndpointSlices) y perdería el ingress desde cada namespace, así que el DNS de todo el clúster muere de inmediato; (2) el **metrics-server** no podría hacer scraping de los kubelets y dejaría de servir `kubectl top` y las métricas del HPA — e igualmente, cualquier controlador en `kube-system` que se conecte al API server o a webhooks pierde ese camino. Sumale a eso los admission webhooks y los componentes CNI/CSI que necesitan conectividad con el nodo y con la API. Si tenés que restringir `kube-system`, hacelo con policies dirigidas por carga de trabajo y pruebas exhaustivas, nunca con un deny-all a nivel de namespace.

**Q37.** Con `networking.k8s.io/v1` core solamente, **no** es posible garantizarlo. La API no tiene acción `deny` ni prioridad: las policies solo *agregan* permisos, y cualquier policy que escriba el equipo de `prod` que permita `namespaceSelector: {tier: untrusted}` (o `namespaceSelector: {}`) reabre el camino al instante. Lo más cerca que podés llegar es aplicar un default-deny en `prod` más un default-deny-egress en `dev`, y después hacer cumplir la barrera de protección *administrativamente* — RBAC que impida al equipo de `prod` crear objetos `NetworkPolicy` en absoluto, o una policy de admisión (Kyverno/Gatekeeper) que rechace cualquier `NetworkPolicy` cuyo `from` admitiría `tier: untrusted`. Una garantía real dentro de la red requiere una API con alcance de clúster y con acción de denegación: `AdminNetworkPolicy`, o un equivalente de proveedor como la `GlobalNetworkPolicy` de Calico o la `CiliumClusterwideNetworkPolicy` de Cilium.

**Q38.** (1) **Alcance de clúster** — un objeto que cubre muchos namespaces, incluidos namespaces que todavía no existen, en lugar de N copias por namespace. (2) **`Deny` explícito** — una acción de denegación real, de modo que una barrera de protección no puede ser deshecha por el dueño de un namespace agregando una regla de permiso. (3) **Prioridad / ordenamiento** — un campo numérico `priority` que hace determinista la evaluación de reglas, algo que el modelo de unión puramente aditivo de v1 no puede expresar. (Una cuarta: la acción `Pass`, que no tiene ningún análogo en v1.)

**Q39.** `Pass` detiene la evaluación de las reglas de `AdminNetworkPolicy` para ese tráfico y **delega la decisión a la `NetworkPolicy` a nivel de namespace** (y luego a `BaselineAdminNetworkPolicy` si nada coincide). Eso es lo que hace funcionar el modelo por capas: el administrador del clúster escribe reglas `Deny` de alta prioridad para el tráfico que nunca debe permitirse, reglas `Pass` para el tráfico que se confía a los equipos para que lo gobiernen ellos mismos, y una `BaselineAdminNetworkPolicy` que fija el comportamiento de reserva cuando un namespace no escribió ninguna policy. El administrador fija el piso y el techo; el dueño del namespace decide en el medio.

**Q40.** Obtendrías un error del API server del estilo de `error: resource mapping not found for ... "policy.networking.k8s.io/v1alpha1, Kind=AdminNetworkPolicy": no matches for kind "AdminNetworkPolicy" in version "policy.networking.k8s.io/v1alpha1" — ensure CRDs are installed first`. Dado que ANP se entrega como CustomResourceDefinitions, el kind simplemente no existe hasta que se instalen los CRDs (y un CNI que los reconcilie). La conclusión para el examen: ejecutá `kubectl api-resources` / `kubectl api-versions` *antes* de escribir YAML que dependa de una API opcional, y usá por defecto `networking.k8s.io/v1` core a menos que la tarea o el clúster provean demostrablemente otra cosa.

</details>

---

## Referencias

- CNCF, *Certified Kubernetes Security Specialist (CKS) Curriculum v1.34* — https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- Documentación de Kubernetes, *Network Policies* — https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Referencia de la API de Kubernetes, *NetworkPolicy v1* — https://kubernetes.io/docs/reference/kubernetes-api/policy-resources/network-policy-v1/
- Documentación de Kubernetes, *Declare Network Policy* — https://kubernetes.io/docs/tasks/administer-cluster/declare-network-policy/
- Documentación de Kubernetes, *Automatic labelling of namespaces* — https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/
- Documentación de Kubernetes, *Pod Security Standards* — https://kubernetes.io/docs/concepts/security/pod-security-standards/
- Documentación de Kubernetes, *Service `externalTrafficPolicy` and source IP* — https://kubernetes.io/docs/tutorials/services/source-ip/
- SIG-Network, *Network Policy API (AdminNetworkPolicy)* — https://network-policy-api.sigs.k8s.io/
- kind, *Cluster configuration and CNI* — https://kind.sigs.k8s.io/docs/user/configuration/
- Project Calico, *Install Calico on a kind cluster* — https://docs.tigera.io/calico/latest/getting-started/kubernetes/kind
- Cilium, *Network Policy documentation* — https://docs.cilium.io/en/stable/security/policy/
- Ahmet Alp Balkan, *Kubernetes Network Policy Recipes* — https://github.com/ahmetb/kubernetes-network-policy-recipes