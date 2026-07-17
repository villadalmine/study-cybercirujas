# 5.1 — NetworkPolicies: fundamentos

## ¿Qué es una NetworkPolicy?

Una **NetworkPolicy** es un recurso de Kubernetes que controla el tráfico de red hacia y desde los **Pods** a nivel de capa 3/4 (IP y puerto). Funciona como un firewall declarativo dentro del cluster: definís *qué Pods pueden hablar con qué Pods* (y con qué destinos externos), en lugar de configurar reglas de red a mano.

Dos ideas centrales que tenés que dominar para el examen:

1. **Por defecto, todo está permitido.** Si ningún objeto NetworkPolicy selecciona a un Pod, ese Pod es *non-isolated*: acepta todo el tráfico entrante y puede iniciar cualquier conexión saliente.
2. **Las políticas son aditivas (allow-list).** En cuanto una NetworkPolicy selecciona a un Pod, ese Pod queda *isolated* para la dirección de tráfico que la política declara (`Ingress`, `Egress` o ambas), y **solo** se permite lo que alguna política permita explícitamente. No existen reglas de "deny": denegás dejando algo fuera de la allow-list.

> **Requisito previo:** las NetworkPolicies las implementa el plugin de red (**CNI**) del cluster — por ejemplo Calico o Cilium. Si el CNI no las soporta, el objeto se crea igual pero **no tiene ningún efecto**. En el examen los clusters ya vienen con un CNI compatible, pero conviene saberlo para no perder tiempo depurando.

---

## Anatomía del recurso

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ejemplo
  namespace: app
spec:
  podSelector:          # A QUIÉN aplica la política (Pods del mismo namespace)
    matchLabels:
      app: api
  policyTypes:          # QUÉ direcciones regula: Ingress, Egress o ambas
    - Ingress
    - Egress
  ingress:              # reglas de tráfico ENTRANTE permitido
    - from: [...]
      ports: [...]
  egress:               # reglas de tráfico SALIENTE permitido
    - to: [...]
      ports: [...]
```

Campos clave:

| Campo | Significado |
|---|---|
| `spec.podSelector` | Selecciona los Pods **a los que aplica** la política, dentro del namespace de la política. `podSelector: {}` selecciona **todos** los Pods del namespace. |
| `spec.policyTypes` | Lista con `Ingress`, `Egress` o ambos. Define qué dirección de tráfico queda aislada. Si lo omitís, se infiere de las secciones presentes — pero escribirlo explícito evita sorpresas. |
| `ingress[].from` / `egress[].to` | Los *peers* permitidos: `podSelector`, `namespaceSelector`, `ipBlock`, o combinaciones. |
| `ports` | Puertos/protocolos permitidos (`TCP` por defecto; también `UDP` y `SCTP`; `endPort` permite rangos). |

**Importante:** no hay comando imperativo tipo `kubectl create networkpolicy`. En el examen, partí siempre de un YAML (copiá el ejemplo de la documentación oficial y adaptalo).

---

## Ejemplo 1: permitir ingreso solo desde un frontend

Escenario: los Pods `app=db` solo deben aceptar conexiones en el puerto 5432 desde Pods `app=api` del mismo namespace.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: db-allow-api
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
              app: api
      ports:
        - protocol: TCP
          port: 5432
```

Aplicar y verificar:

```bash
$ kubectl apply -f db-allow-api.yaml
networkpolicy.networking.k8s.io/db-allow-api created

$ kubectl get networkpolicy -n prod
NAME           POD-SELECTOR   AGE
db-allow-api   app=db         10s

$ kubectl describe networkpolicy db-allow-api -n prod
Name:         db-allow-api
Namespace:    prod
Spec:
  PodSelector:     app=db
  Allowing ingress traffic:
    To Port: 5432/TCP
    From:
      PodSelector: app=api
  Not affecting egress traffic
  Policy Types: Ingress
```

Efecto: los Pods `app=db` quedan aislados para ingreso. Solo entra tráfico de Pods `app=api`, y solo al 5432/TCP. Su tráfico **saliente** no se toca, porque la política no declara `Egress`.

---

## Ejemplo 2: default deny (patrón de examen clásico)

Denegar **todo el ingreso** a todos los Pods de un namespace:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: prod
spec:
  podSelector: {}        # todos los Pods del namespace
  policyTypes:
    - Ingress            # sin sección ingress => nada permitido
```

Variantes que conviene memorizar:

```yaml
# Denegar todo egress
spec:
  podSelector: {}
  policyTypes: [Egress]
---
# Denegar todo (ingress + egress)
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
---
# Permitir todo el ingress (útil para "desaislar" tras un default-deny)
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress:
    - {}                 # regla vacía = permite desde cualquier origen
```

El patrón habitual en producción (y en el examen): aplicás un `default-deny` en el namespace y después agregás políticas puntuales que abren solo lo necesario. Como las políticas son aditivas, la combinación funciona sin conflictos.

---

## Selectores en `from` / `to`: la trampa AND vs OR

Este es **el** detalle que más se evalúa. Comparemos:

**Caso A — dos elementos en la lista (OR):**

```yaml
ingress:
  - from:
      - namespaceSelector:
          matchLabels:
            team: platform
      - podSelector:
          matchLabels:
            app: api
```

Permite tráfico desde: cualquier Pod de namespaces con label `team=platform`, **O** Pods `app=api` del namespace propio. Son dos peers independientes (guiones separados).

**Caso B — un elemento con dos campos (AND):**

```yaml
ingress:
  - from:
      - namespaceSelector:
          matchLabels:
            team: platform
        podSelector:
          matchLabels:
            app: api
```

Permite tráfico **solo** desde Pods `app=api` que además estén en namespaces `team=platform`. Es un único peer con dos condiciones (un solo guion).

La diferencia es un `-` en el YAML. Leé con cuidado el enunciado: "desde el namespace X **o** desde pods Y" vs "desde pods Y **del** namespace X".

> Para seleccionar un namespace por nombre, usá el label automático `kubernetes.io/metadata.name`, que todo namespace tiene:
> ```yaml
> namespaceSelector:
>   matchLabels:
>     kubernetes.io/metadata.name: prod
> ```

---

## `ipBlock`: tráfico externo por CIDR

Para orígenes/destinos fuera del cluster (o rangos de IP concretos):

```yaml
egress:
  - to:
      - ipBlock:
          cidr: 10.0.0.0/16
          except:
            - 10.0.5.0/24
    ports:
      - protocol: TCP
        port: 443
```

Permite egress HTTPS hacia `10.0.0.0/16` excepto la subred `10.0.5.0/24`. Ojo: las IPs de Pods son efímeras — `ipBlock` es para rangos externos, no para apuntar a Pods.

---

## Ejemplo 3: egress con DNS (el error típico)

Si aislás egress, los Pods pierden también la resolución DNS y casi todo deja de funcionar aunque hayas permitido el destino correcto. Siempre que restrinjas egress, permití DNS:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-egress
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app: api
  policyTypes:
    - Egress
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: db
      ports:
        - protocol: TCP
          port: 5432
    - to: []               # DNS hacia cualquier destino
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

---

## Probar una política

La forma rápida de verificar conectividad es un Pod temporal:

```bash
# ¿Puede un pod cualquiera llegar al servicio db?
$ kubectl run test --rm -it --image=busybox -n prod --restart=Never \
    -- wget -qO- --timeout=2 http://db:5432
wget: download timed out          # bloqueado por la política ✔

# El mismo test desde un pod con el label permitido
$ kubectl run test --rm -it --image=busybox -n prod --restart=Never \
    --labels="app=api" -- nc -zv db 5432
db (10.96.14.3:5432) open         # permitido ✔
```

Notá el uso de `--labels` en `kubectl run`: es la manera más rápida de simular "un Pod que sí matchea el selector".

---

## Puntos clave para el examen

- Sin política que lo seleccione, un Pod acepta y emite **todo**.
- `podSelector: {}` + `policyTypes` sin reglas = **default deny** para esa dirección.
- Las políticas solo **permiten**; se combinan por unión (aditivas), nunca entran en conflicto.
- Una política solo afecta la dirección listada en `policyTypes`: una política solo-Ingress no restringe el egress.
- La diferencia AND/OR entre `namespaceSelector` y `podSelector` depende de si van en el **mismo elemento** de la lista o en elementos separados.
- Al restringir egress, acordate de **permitir DNS (53/UDP y 53/TCP)**.
- NetworkPolicy es un recurso **namespaced**; `podSelector` solo matchea Pods de su propio namespace (para cruzar namespaces usás `namespaceSelector`).
- No hay generador imperativo: trabajá desde YAML (la página de la documentación oficial tiene ejemplos listos para copiar durante el examen).

---

## Referencias

- Documentación oficial — Network Policies: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Referencia de API — NetworkPolicy v1 (networking.k8s.io): https://kubernetes.io/docs/reference/kubernetes-api/policy-resources/network-policy-v1/
- Tutorial oficial — Declare Network Policy: https://kubernetes.io/docs/tasks/administer-cluster/declare-network-policy/
- Labels automáticos de namespace (`kubernetes.io/metadata.name`): https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/
- Curriculum CKAD v1.35: https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf