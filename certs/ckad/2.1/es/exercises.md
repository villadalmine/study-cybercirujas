# Ejercicios guiados — 2.1 Estrategias de deployment con primitivas de Kubernetes (blue/green, canary)

> Fuente de referencia: [CKAD Curriculum v1.35](https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf)

En estos ejercicios vas a implementar tres estrategias de deployment usando únicamente primitivas nativas de Kubernetes (`Deployment`, `Service`, `labels`/`selectors`), sin service mesh ni controladores externos. Trabajá en un cluster de práctica (`kind`, `minikube` o similar) con `kubectl` configurado.

Preparación común para todos los ejercicios:

```bash
kubectl create namespace ckad-2-1
kubectl config set-context --current --namespace=ckad-2-1
```

---

## Ejercicio 1 — Rolling update: la estrategia por defecto de un Deployment

1. Creá un Deployment `web` con 4 réplicas de `nginx:1.25`:

   ```bash
   kubectl create deployment web --image=nginx:1.25 --replicas=4
   kubectl expose deployment web --port=80
   ```

2. Inspeccioná la estrategia por defecto que asignó Kubernetes:

   ```bash
   kubectl get deployment web -o jsonpath='{.spec.strategy}{"\n"}'
   ```

3. En una segunda terminal, lanzá un Pod temporal que consulte el Service en loop y muestre la versión que responde (vía el header `Server` que expone nginx):

   ```bash
   kubectl run curl-test --rm -it --image=curlimages/curl --restart=Never -- \
     sh -c 'while true; do curl -s -I http://web 2>/dev/null | grep -i Server; sleep 0.3; done'
   ```

4. Volvé a la primera terminal y endurecé la estrategia para garantizar cero downtime durante el update:

   ```bash
   kubectl patch deployment web --type='json' \
     -p='[{"op":"replace","path":"/spec/strategy/rollingUpdate","value":{"maxSurge":1,"maxUnavailable":0}}]'
   ```

5. Dispará el rollout cambiando la imagen:

   ```bash
   kubectl set image deployment/web nginx=nginx:1.27
   ```

6. Observá el progreso y confirmá que terminó correctamente:

   ```bash
   kubectl rollout status deployment/web
   kubectl rollout history deployment/web
   ```

7. Mientras el rollout corría, revisá la salida de la terminal del paso 3: todas las respuestas deberían tener `Server: nginx/1.25.x` o `Server: nginx/1.27.x`, nunca un corte o error.

**Preguntas de comprensión**

- ¿Qué diferencia hay entre `maxSurge` y `maxUnavailable`, y por qué `maxUnavailable=0` fue la clave para no perder disponibilidad durante el update?
- Si necesitaras revertir el cambio de imagen, ¿qué comando usarías y qué dato del `rollout history` necesitás para elegir la revisión correcta?

---

## Ejercicio 2 — Blue/Green: corte de tráfico instantáneo con el `selector` del Service

1. Creá el Deployment "blue" (versión actualmente en producción):

   ```bash
   kubectl create deployment web-blue --image=nginx:1.25 --replicas=3
   kubectl label deployment web-blue app=web version=blue
   kubectl patch deployment web-blue -p \
     '{"spec":{"template":{"metadata":{"labels":{"app":"web","version":"blue"}}}}}'
   ```

2. Creá el Service que va a enrutar producción, apuntando solo a `blue`:

   ```yaml
   # svc-web.yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: web
   spec:
     selector:
       app: web
       version: blue
     ports:
       - port: 80
   ```

   ```bash
   kubectl apply -f svc-web.yaml
   ```

3. Confirmá que el Service sirve `blue`:

   ```bash
   kubectl run curl-test --rm -it --image=curlimages/curl --restart=Never -- \
     sh -c 'curl -s -I http://web | grep -i Server'
   ```

4. Desplegá "green" (la nueva versión) con sus propias labels, **sin** tocar el Service todavía:

   ```bash
   kubectl create deployment web-green --image=nginx:1.27 --replicas=3
   kubectl patch deployment web-green -p \
     '{"spec":{"template":{"metadata":{"labels":{"app":"web","version":"green"}}}}}'
   kubectl rollout status deployment/web-green
   ```

5. Probá `green` antes del corte, sin exponer el tráfico real, con un Service temporal de preview:

   ```bash
   kubectl expose deployment web-green --name=web-green-preview --port=80
   kubectl run curl-preview --rm -it --image=curlimages/curl --restart=Never -- \
     sh -c 'curl -s -I http://web-green-preview | grep -i Server'
   ```

6. Una vez validado, hacé el corte de tráfico cambiando el `selector` del Service `web`:

   ```bash
   kubectl patch service web -p '{"spec":{"selector":{"app":"web","version":"green"}}}'
   ```

7. Repetí el curl loop del paso 3 contra `web`: el header debería pasar a `nginx/1.27.x` sin ningún request fallido.

8. Dejá `web-blue` corriendo unos minutos como camino de rollback. Si algo falla, revertí con:

   ```bash
   kubectl patch service web -p '{"spec":{"selector":{"app":"web","version":"blue"}}}'
   ```

9. Una vez confirmado que `green` es estable, limpiá los recursos viejos:

   ```bash
   kubectl delete deployment web-blue
   kubectl delete service web-green-preview
   ```

**Preguntas de comprensión**

- ¿Por qué el corte de tráfico en blue/green es prácticamente instantáneo y sin downtime, a diferencia del rolling update del Ejercicio 1?
- ¿Qué mecanismo garantiza que el Service no envíe tráfico a Pods de `green` que todavía no están `Ready`, aun si el selector ya los incluye?
- ¿Qué ventaja concreta da mantener `web-blue` corriendo un rato después del corte, en lugar de borrarlo inmediatamente?

---

## Ejercicio 3 — Canary release: dos Deployments compartiendo un mismo Service

1. Creá el Deployment estable con la mayoría del tráfico, usando una label `track` que **no** vas a incluir en el selector del Service:

   ```bash
   kubectl create deployment web-stable --image=nginx:1.25 --replicas=9
   kubectl patch deployment web-stable -p \
     '{"spec":{"template":{"metadata":{"labels":{"app":"web","track":"stable"}}}}}'
   ```

2. Creá el Service seleccionando solo por `app=web` (sin `track`), de forma que agrupe automáticamente a cualquier Deployment que comparta esa label:

   ```yaml
   # svc-canary.yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: web
   spec:
     selector:
       app: web
     ports:
       - port: 80
   ```

   ```bash
   kubectl apply -f svc-canary.yaml
   ```

3. Confirmá que el 100% del tráfico va a `stable`:

   ```bash
   kubectl run curl-test --rm -it --image=curlimages/curl --restart=Never -- \
     sh -c 'for i in $(seq 1 20); do curl -s -I http://web | grep -i Server; done | sort | uniq -c'
   ```

4. Desplegá el canary con la nueva versión y **1 sola réplica**, usando la misma label `app=web` para que el Service lo incluya automáticamente:

   ```bash
   kubectl create deployment web-canary --image=nginx:1.27 --replicas=1
   kubectl patch deployment web-canary -p \
     '{"spec":{"template":{"metadata":{"labels":{"app":"web","track":"canary"}}}}}'
   kubectl rollout status deployment/web-canary
   ```

5. Repetí el loop del paso 3: con 9 réplicas `stable` + 1 `canary`, deberías ver aproximadamente 10% de las respuestas en `nginx/1.27.x`.

6. Monitoreá la salud del canary antes de avanzar (logs, tasa de errores):

   ```bash
   kubectl logs -l track=canary --tail=50
   ```

7. Si el canary se ve saludable, promovelo gradualmente ajustando réplicas de ambos Deployments (manteniendo el total similar):

   ```bash
   kubectl scale deployment web-canary --replicas=3
   kubectl scale deployment web-stable --replicas=6
   ```

   Volvé a correr el loop del paso 3 y confirmá que ahora ronda el 30% para `canary`.

8. Promoción completa: escalá `canary` al 100% del tráfico y bajá `stable` a 0:

   ```bash
   kubectl scale deployment web-canary --replicas=9
   kubectl scale deployment web-stable --replicas=0
   ```

9. Escenario de rollback: si en el paso 6 el canary mostrara errores, la corrección es inmediata y no toca el Service ni `stable`:

   ```bash
   kubectl scale deployment web-canary --replicas=0
   ```

**Preguntas de comprensión**

- ¿Por qué el `selector` del Service en este ejercicio usa solo `app=web` y no incluye `track`?
- ¿Cómo se relaciona el porcentaje de tráfico que recibe el canary con la cantidad de réplicas, y qué limitación tiene este método de "canary por réplicas" frente a un service mesh con weighted routing (por ejemplo, no poder segmentar por cabecera o cookie de usuario)?
- Ante una tasa de error alta en el canary, ¿por qué escalar a 0 réplicas es preferible a eliminar el Deployment directamente si todavía estás decidiendo si vas a reintentarlo?

---

## Ejercicio 4 — Recreate: cuando el rolling update no es viable

1. Creá un Deployment que use la estrategia `Recreate` en lugar de `RollingUpdate` (útil cuando la app no soporta múltiples versiones corriendo en simultáneo, por ejemplo por un schema de base de datos incompatible):

   ```yaml
   # worker.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: batch-worker
   spec:
     replicas: 2
     strategy:
       type: Recreate
     selector:
       matchLabels:
         app: batch-worker
     template:
       metadata:
         labels:
           app: batch-worker
       spec:
         containers:
           - name: nginx
             image: nginx:1.25
   ```

   ```bash
   kubectl apply -f worker.yaml
   ```

2. En una terminal aparte, mirá los Pods en tiempo real:

   ```bash
   kubectl get pods -l app=batch-worker -w
   ```

3. Disparás el update:

   ```bash
   kubectl set image deployment/batch-worker nginx=nginx:1.27
   ```

4. Observá en la terminal del paso 2 que **todos** los Pods viejos terminan antes de que arranque cualquier Pod nuevo (a diferencia del rolling update, hay una ventana sin Pods disponibles).

**Preguntas de comprensión**

- ¿En qué escenarios reales conviene usar `Recreate` en vez de `RollingUpdate`, a pesar de aceptar downtime?

---

<details>
<summary><strong>Respuestas</strong></summary>

**Ejercicio 1**

1. `maxSurge` define cuántos Pods **extra** por encima del número de réplicas deseado puede crear el Deployment mientras actualiza (nuevos Pods antes de bajar viejos). `maxUnavailable` define cuántos Pods del total deseado pueden estar **no disponibles** durante el update. Con `maxUnavailable=0` el controlador nunca baja un Pod viejo hasta que el nuevo que lo reemplaza esté `Ready`, garantizando que la capacidad servible nunca caiga por debajo de las 4 réplicas — de ahí el cero downtime.
2. `kubectl rollout undo deployment/web` (o `--to-revision=<N>`). El dato necesario es el número de revisión (`REVISION`) que muestra `kubectl rollout history deployment/web`, para elegir explícitamente a cuál volver si no alcanza con la anterior inmediata.

**Ejercicio 2**

1. Porque el corte no depende de crear/terminar Pods (eso ya sucedió de antemano con `green` corriendo y `Ready`): solo cambia una entrada en `spec.selector` del Service, lo que Kubernetes propaga a los `Endpoints`/`EndpointSlices` casi instantáneamente. No hay ventana de transición como en el rolling update.
2. El Service solo agrega a sus `Endpoints` los Pods que, además de matchear el `selector`, están en estado `Ready` (pasan su `readinessProbe`). Un Pod `NotReady` nunca recibe tráfico aunque sus labels coincidan.
3. Da una ventana de rollback inmediato: si `green` falla bajo tráfico real, alcanza con revertir el `selector` a `blue` sin tener que recrear ningún Pod, porque `blue` sigue corriendo intacto.

**Ejercicio 3**

1. Porque si el selector incluyera `track`, el Service apuntaría exclusivamente a un solo grupo (`stable` o `canary`) y nunca a ambos a la vez; al dejar solo `app=web`, el Service agrupa automáticamente los Pods de cualquier Deployment que comparta esa label, permitiendo que ambas versiones reciban tráfico simultáneamente en proporción a su cantidad de réplicas.
2. El balanceo del Service reparte tráfico de forma aproximadamente uniforme entre todos los Pods en sus `Endpoints`, así que el % de tráfico al canary queda determinado por `réplicas_canary / (réplicas_canary + réplicas_stable)`. La limitación es que solo podés ajustar el split en incrementos discretos (según cuántas réplicas totales tengas) y no podés segmentar tráfico por otros criterios (header, cookie, usuario, geografía) como sí permite un service mesh con weighted routing o traffic splitting explícito.
3. Escalar a 0 mantiene el Deployment (su spec, historial y ReplicaSet) intacto para volver a escalarlo rápidamente si el problema se corrige, mientras seguís investigando; eliminarlo obliga a recrear el Deployment desde cero (y perder el historial de revisiones) para reintentar.

**Ejercicio 4**

1. Cuando distintas versiones de la app **no pueden coexistir** de forma segura al mismo tiempo — por ejemplo, migraciones de esquema de base de datos incompatibles entre v1 y v2, cambios de formato de mensajes en una cola que ambas versiones consumen, o locks/recursos exclusivos que dos versiones no pueden compartir. En esos casos, aceptar una ventana corta de downtime con `Recreate` es más seguro que arriesgar corrupción de datos con versiones mixtas corriendo en simultáneo bajo `RollingUpdate`.

</details>