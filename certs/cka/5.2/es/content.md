# 5.2 Define and enforce Network Policies

**Peso en el examen: 3.33%**

## Introducción

Por defecto, en un clúster de Kubernetes **todos los Pods pueden comunicarse con todos los demás Pods**, sin restricciones de red, independientemente del Namespace en el que estén. Esto es así porque el modelo de red de Kubernetes asume una red plana (*flat network*) donde cada Pod obtiene su propia IP y puede alcanzar a cualquier otro Pod directamente.

Un **NetworkPolicy** es un recurso de la API (`networking.k8s.io/v1`) que permite definir reglas a nivel de **Capa 3 (IP) y Capa 4 (TCP/UDP/SCTP)** para controlar qué tráfico de entrada (`ingress`) y salida (`egress`) está permitido hacia/desde un conjunto de Pods. No opera a nivel de aplicación (Capa 7): no filtra por HTTP path, headers, etc. Para eso se necesitan otras herramientas (service mesh, CNI con extensiones propias).

### Requisito clave: el CNI debe soportar NetworkPolicy

Este es uno de los puntos más importantes y más preguntados del examen: **el objeto `NetworkPolicy` es solo una especificación**. Kubernetes no trae un motor de enforcement propio; quien aplica (o ignora) las reglas es el **plugin CNI** instalado en el clúster.

- Si el CNI **no soporta** NetworkPolicy (ejemplo clásico: Flannel en su configuración básica), los objetos `NetworkPolicy` se pueden crear sin error, pero **no tienen ningún efecto real**. Esto es una trampa típica de examen.
- CNIs que sí implementan NetworkPolicy: **Calico**, **Cilium**, **Weave Net**, **Antrea**, entre otros.

En el examen CKA, el clúster ya viene con un CNI compatible (normalmente Calico), así que no hace falta instalarlo, pero sí hay que saber diagnosticar el problema si las políticas "no funcionan".

## Comportamiento por defecto

- Si un Pod **no está seleccionado por ningún NetworkPolicy**, todo el tráfico de entrada y salida hacia/desde ese Pod está **permitido** (comportamiento por defecto de Kubernetes).
- En cuanto **al menos un** NetworkPolicy selecciona a un Pod (vía `podSelector`) para un tipo de tráfico dado (`Ingress` o `Egress`), ese Pod pasa a modo **"default deny"** para ese tipo de tráfico, y solo se permite lo explícitamente listado en las reglas.
- **Las políticas son aditivas (unión), no de "primer match"**: si varios NetworkPolicy seleccionan al mismo Pod, el tráfico permitido es la **unión** de todas las reglas `allow`. No existen reglas `deny` explícitas en la API estándar de NetworkPolicy — todo lo que no está permitido, queda denegado implícitamente.

## Estructura de un NetworkPolicy

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ejemplo
  namespace: produccion
spec:
  podSelector:        # a qué Pods aplica esta política
    matchLabels:
      app: backend
  policyTypes:         # Ingress, Egress, o ambos
  - Ingress
  - Egress
  ingress:              # reglas de entrada (lista de reglas "allow")
  - from:
    - podSelector:
        matchLabels:
          app: frontend
    ports:
    - protocol: TCP
      port: 8080
  egress:                # reglas de salida
  - to:
    - podSelector:
        matchLabels:
          app: database
    ports:
    - protocol: TCP
      port: 5432
```

Campos clave:

- **`podSelector`** (a nivel de `spec`): selecciona el conjunto de Pods del mismo Namespace al que se aplica la política. Un `podSelector: {}` vacío selecciona **todos los Pods del Namespace**.
- **`policyTypes`**: indica si la política define reglas de `Ingress`, `Egress` o ambas. Si se omite, se infiere: si hay bloque `ingress` se asume `Ingress`; si hay `egress` se asume `Egress`. **Buena práctica de examen**: declararlo explícitamente, sobre todo para egress-only o para "deny all" (donde no hay reglas y hay que forzar el tipo).
- **`ingress[].from`** / **`egress[].to`**: lista de *peers* permitidos. Puede contener:
  - `podSelector`: Pods dentro del mismo Namespace (o del Namespace indicado por `namespaceSelector` si se combinan).
  - `namespaceSelector`: todos los Pods de los Namespaces que matcheen las labels.
  - `ipBlock`: rango CIDR (para tráfico externo al clúster), con posibilidad de excluir subrangos vía `except`.
- **`ports`**: lista de puertos/protocolos permitidos. Si se omite, se permiten **todos los puertos**.

### AND vs OR entre selectores

Un punto muy consultado en el examen:

```yaml
  ingress:
  - from:
    - podSelector:
        matchLabels:
          role: frontend
      namespaceSelector:
        matchLabels:
          env: prod
```

Cuando `podSelector` y `namespaceSelector` están **dentro del mismo elemento** de la lista `from` (mismo `-`), se combinan con **AND**: solo Pods con label `role: frontend` **que además** estén en un Namespace con label `env: prod`.

```yaml
  ingress:
  - from:
    - podSelector:
        matchLabels:
          role: frontend
    - namespaceSelector:
        matchLabels:
          env: prod
```

Cuando están en **elementos distintos** de la lista (dos `-` separados), se combinan con **OR**: Pods con `role: frontend` (en cualquier Namespace) **o** cualquier Pod de un Namespace con `env: prod`.

> Desde Kubernetes 1.21+, todo Namespace tiene automáticamente la label `kubernetes.io/metadata.name: <nombre-del-namespace>`, lo que permite escribir `namespaceSelector` apuntando a un Namespace específico por nombre sin tener que etiquetarlo manualmente.

## Patrones comunes

### 1. Deny all ingress (default deny) en un Namespace

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: produccion
spec:
  podSelector: {}
  policyTypes:
  - Ingress
```

Selecciona todos los Pods del Namespace y no define ninguna regla `ingress` → todo el tráfico entrante queda bloqueado.

### 2. Deny all egress

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  namespace: produccion
spec:
  podSelector: {}
  policyTypes:
  - Egress
```

### 3. Allow all (útil para "abrir" excepciones dentro de un Namespace en default-deny)

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-all-ingress
  namespace: produccion
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  ingress:
  - {}
```

Un `ingress: - {}` (regla vacía) permite tráfico desde **cualquier origen**, sin restricción de peer ni de puerto.

### 4. Permitir tráfico solo desde un Pod/label específico, en un puerto determinado

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-backend
  namespace: produccion
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: frontend
    ports:
    - protocol: TCP
      port: 8080
```

### 5. Permitir egress hacia DNS (imprescindible en clústeres con default-deny egress)

Si se aplica un `default-deny-egress`, hay que recordar explícitamente permitir la resolución DNS hacia CoreDNS (namespace `kube-system`, puerto 53 UDP/TCP), porque de lo contrario las aplicaciones dejan de poder resolver nombres:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: produccion
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
```

### 6. Restringir por rango de IP (ipBlock), útil para tráfico externo

```yaml
  ingress:
  - from:
    - ipBlock:
        cidr: 172.17.0.0/16
        except:
        - 172.17.1.0/24
```

## Flujo de trabajo típico en el examen

1. Identificar los Pods involucrados (por labels) y el Namespace.
2. Crear/editar el YAML del NetworkPolicy.
3. Aplicarlo:

```bash
kubectl apply -f netpol-backend.yaml
```

4. Verificar que existe y su contenido:

```bash
kubectl get networkpolicy -n produccion
```

```
NAME                       POD-SELECTOR   AGE
allow-frontend-to-backend  app=backend    12s
```

```bash
kubectl describe networkpolicy allow-frontend-to-backend -n produccion
```

```
Name:         allow-frontend-to-backend
Namespace:    produccion
Spec:
  PodSelector:     app=backend
  Allowing ingress traffic:
    To Port: 8080/TCP
    From:
      PodSelector: app=frontend
  Not affecting egress traffic
  Policy Types: Ingress
```

5. **Probar la conectividad** con un Pod temporal, algo que se pide con frecuencia en el examen:

```bash
kubectl run test-pod --image=busybox:1.36 --rm -it --restart=Never \
  --labels="app=frontend" -n produccion -- wget -qO- --timeout=2 http://backend-svc:8080
```

Si el `podSelector` de la política no matchea las labels del Pod de prueba (`app=frontend`), la conexión debería colgarse o dar timeout, confirmando que la política bloquea correctamente.

También es común usar `kubectl exec` en un Pod ya existente:

```bash
kubectl exec -n produccion frontend-abc123 -- curl -s --max-time 2 http://backend-svc:8080
```

## Troubleshooting típico

| Síntoma | Causa probable |
|---|---|
| El NetworkPolicy no bloquea nada, aunque está bien escrito | El CNI del clúster no soporta NetworkPolicy (ej. Flannel puro) |
| Se bloqueó tráfico que no debería estar bloqueado | Namespace de destino sin la label esperada en `namespaceSelector`, o falta permitir DNS tras aplicar `default-deny-egress` |
| La política "no aplica" a ningún Pod | `podSelector` con labels que no coinciden con ningún Pod real — revisar con `kubectl get pods --show-labels` |
| Tráfico entre Namespaces sigue funcionando pese a la política | Falta `policyTypes` explícito, o la política se creó en el Namespace equivocado (NetworkPolicy es un recurso namespaced y su `podSelector` solo mira Pods del mismo Namespace donde vive el objeto) |
| El Service sigue "funcionando" desde curl externo | NetworkPolicy filtra a nivel de Pod IP, no de Service — si el peer bloqueado igual pasa, verificar si el tráfico está siendo enrutado por otro Pod permitido, o si el kube-proxy hace SNAT que enmascara el origen real |

Comandos útiles de diagnóstico:

```bash
kubectl get pods -n produccion --show-labels
kubectl get ns --show-labels
kubectl get networkpolicy -A
```

## Referencias

- Network Policies — documentación oficial: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Declare Network Policy (task guide): https://kubernetes.io/docs/tasks/administer-cluster/declare-network-policy/
- NetworkPolicy API reference: https://kubernetes.io/docs/reference/kubernetes-api/policy-resources/network-policy-v1/
- CKA Curriculum v1.35 (CNCF): https://github.com/cncf/curriculum/raw/master/CKA_Curriculum_v1.35.pdf
