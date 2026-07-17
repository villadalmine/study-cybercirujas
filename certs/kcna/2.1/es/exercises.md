# Ejercicios guiados: Application Delivery (KCNA — Tema 2.1)

Estos ejercicios asumen un cluster local (`kind`, `minikube` o Docker Desktop) con `kubectl` configurado y, para el último ejercicio, `helm` instalado.

## Ejercicio 1: Rolling Update de un Deployment

La estrategia de despliegue por defecto de un `Deployment` en Kubernetes es **RollingUpdate**: reemplaza Pods viejos por nuevos de forma incremental, sin downtime, creando un nuevo `ReplicaSet` en cada actualización.

1. Creá un Deployment con una imagen inicial:
```
kubectl create deployment web --image=nginx:1.25 --replicas=4
```
2. Confirmá que se creó un `ReplicaSet` asociado:
```
kubectl get replicaset -l app=web
```
3. Dispará una actualización cambiando la imagen:
```
kubectl set image deployment/web nginx=nginx:1.27
```
4. Observá el progreso del rollout en tiempo real:
```
kubectl rollout status deployment/web
```
5. Listá el historial de revisiones:
```
kubectl rollout history deployment/web
```
6. Volvé a la revisión anterior:
```
kubectl rollout undo deployment/web
```

**Preguntas de comprensión:**
1. ¿Por qué `kubectl rollout undo` no elimina el `ReplicaSet` anterior en lugar de reutilizarlo?
2. Si el nuevo Pod nunca pasa su `readinessProbe`, ¿qué le pasa al rollout?

## Ejercicio 2: Controlar `maxSurge` y `maxUnavailable`

Estos dos campos, dentro de `spec.strategy.rollingUpdate`, definen cuántos Pods extra puede crear el rollout y cuántos puede dejar indisponibles durante la transición.

1. Exportá el manifiesto actual del Deployment:
```
kubectl get deployment web -o yaml > web.yaml
```
2. Editá `web.yaml` y agregá dentro de `spec`:
```
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 1
    maxUnavailable: 0
```
3. Aplicá el cambio:
```
kubectl apply -f web.yaml
```
4. Dispará otra actualización de imagen y observá cuántos Pods `Running` hay en simultáneo durante el rollout:
```
kubectl set image deployment/web nginx=nginx:1.25
kubectl get pods -l app=web -w
```

**Preguntas de comprensión:**
1. Con `maxUnavailable: 0` y `maxSurge: 1`, ¿el número total de Pods durante el rollout puede superar el `replicas` configurado? ¿Por qué?
2. ¿Qué combinación de valores acercaría el comportamiento a un Recreate (matar todo antes de crear lo nuevo)?

## Ejercicio 3: Blue-Green y Canary manuales con labels

Kubernetes no tiene un objeto nativo "Blue-Green" ni "Canary": estas estrategias se construyen combinando `Deployments` con labels y el `selector` de un `Service`.

1. Creá la versión "blue" (estable):
```
kubectl create deployment app-blue --image=nginx:1.25 --replicas=3
kubectl label deployment app-blue track=blue
```
2. Exponé un Service que apunta a `track=blue`:
```
kubectl expose deployment app-blue --name=app --port=80 --selector=track=blue
```
3. Creá la versión "green" (nueva) sin tráfico todavía:
```
kubectl create deployment app-green --image=nginx:1.27 --replicas=3
kubectl label deployment app-green track=green
```
4. Cuando valides que "green" funciona, cambiá el `selector` del Service para cortar el tráfico de golpe:
```
kubectl patch service app -p '{"spec":{"selector":{"track":"green"}}}'
```
5. Para simular un **canary**, en lugar de cortar todo el tráfico de una vez, dejá que el Service seleccione un label común (`app=app`) presente en ambos Deployments y ajustá la proporción de réplicas entre "stable" y "canary" (por ejemplo 9 vs 1) para controlar qué porcentaje del tráfico recibe la versión nueva.

**Preguntas de comprensión:**
1. En el paso 4, ¿por qué el corte de tráfico es instantáneo aunque los Pods "blue" sigan corriendo?
2. En el enfoque canary por proporción de réplicas, ¿qué garantiza (o no garantiza) que exactamente el 10% de las requests vaya a la versión nueva?
3. ¿Qué ventaja tiene blue-green sobre canary en términos de velocidad de rollback, y qué desventaja en uso de recursos?

## Ejercicio 4: Empaquetar y versionar con Helm

Helm gestiona aplicaciones como **charts** (paquetes de manifiestos templatizados) y **releases** (instancias instaladas), con su propio historial de revisiones independiente del de un Deployment.

1. Agregá un repositorio de charts y actualizá el índice local:
```
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
```
2. Instalá una release con valores por defecto:
```
helm install mi-nginx bitnami/nginx --version 15.5.0
```
3. Revisá el estado y los valores efectivos usados:
```
helm status mi-nginx
helm get values mi-nginx
```
4. Actualizá la release sobrescribiendo un valor (por ejemplo el número de réplicas):
```
helm upgrade mi-nginx bitnami/nginx --set replicaCount=2
```
5. Listá el historial de revisiones de la release:
```
helm history mi-nginx
```
6. Revertí a la revisión anterior:
```
helm rollback mi-nginx 1
```

**Preguntas de comprensión:**
1. ¿En qué se diferencia el historial de `helm rollback` del historial de `kubectl rollout undo` visto en el Ejercicio 1?
2. Si dos charts distintos crean un `Deployment` con el mismo nombre en el mismo namespace, ¿qué pasa al hacer `helm install` del segundo?
3. ¿Por qué se recomienda fijar `--version` al instalar un chart de un repo de terceros?

<details>
<summary>Ver respuestas</summary>

**Ejercicio 1**
1. Porque Kubernetes conserva los `ReplicaSet` anteriores (hasta el límite de `revisionHistoryLimit`) escalados a 0 réplicas, precisamente para que un rollback solo tenga que reescalarlos en vez de recrear Pods desde cero.
2. El rollout queda "trabado" (`progressing` pero sin completar): los Pods viejos no se terminan de reemplazar porque el controlador espera a que el nuevo Pod esté `Ready` antes de seguir avanzando, según la estrategia configurada.

**Ejercicio 2**
1. No: con `maxSurge: 1` puede haber como máximo `replicas + 1` Pods en total durante el rollout, y con `maxUnavailable: 0` nunca menos que `replicas` Pods disponibles. El total nunca supera `replicas + maxSurge`.
2. `maxSurge: 0` y `maxUnavailable: 100%` (o un valor igual a `replicas`) fuerza a tumbar los Pods viejos antes de crear los nuevos, replicando el comportamiento de `Recreate`.

**Ejercicio 3**
1. Porque el corte lo hace el `Service`, no los Pods: al cambiar el `selector`, el `Endpoints`/`EndpointSlice` se recalcula inmediatamente y deja de enrutar tráfico a los Pods con `track=blue`, aunque esos Pods sigan `Running`.
2. Solo lo garantiza de forma aproximada: `kube-proxy` balancea entre los Pods que matchean el selector del Service sin ponderar por versión, así que la proporción real de tráfico depende de cuántos Pods de cada track existan, no de un porcentaje configurado explícitamente (para control fino de tráfico se necesita un service mesh o ingress controller con soporte de weighted routing).
3. Ventaja: el rollback es instantáneo (solo cambiar el selector de vuelta), sin esperar a que se recreen Pods. Desventaja: requiere mantener el doble de recursos corriendo (ambas versiones a réplica completa) mientras dura la validación.

**Ejercicio 4**
1. `helm rollback` revierte toda la release (todos los recursos que el chart gestiona: Deployments, Services, ConfigMaps, etc. como una unidad versionada), mientras que `kubectl rollout undo` solo revierte un `Deployment` puntual y su `ReplicaSet` asociado.
2. Falla (o genera un conflicto/error), porque Kubernetes no permite dos recursos del mismo tipo con el mismo nombre en el mismo namespace; Helm no resuelve colisiones de nombres entre releases distintas.
3. Porque sin fijar versión, `helm install` toma la última versión publicada en el repo, que puede introducir cambios breaking o de comportamiento no probados, rompiendo la reproducibilidad del despliegue.

</details>

---
Fuente de referencia: [CNCF KCNA Curriculum](https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf)