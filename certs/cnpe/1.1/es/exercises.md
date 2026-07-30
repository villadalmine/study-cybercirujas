# Ejercicios Guiados — 1.1 Applying Platform Architecture Best Practices for Networking, Storage, and Compute

> Referencia: [CNCF CNPE Curriculum](https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf)

Requisitos previos: Acceso a un clúster Kubernetes funcional con `kubectl`.

---

## Ejercicio 1 — Inspección de StorageClasses y VolumeBindingMode

1. Inspeccionar las StorageClasses configuradas en el clúster:
   ```bash
   kubectl get storageclass
   ```
2. Verificar el campo `volumeBindingMode` de la StorageClass default:
   ```bash
   kubectl get sc -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.volumeBindingMode}{"\n"}{end}'
   ```

**Preguntas de comprensión:**
- ¿Por qué es crítico usar `WaitForFirstConsumer` en clústeres multi-AZ?

---

## Ejercicio 2 — Configuración de Topology Spread Constraints

1. Crear un namespace para la prueba de cómputo:
   ```bash
   kubectl create namespace topology-demo
   ```
2. Desplegar una aplicación configurada para distribuirse equitativamente entre zonas:
   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: zone-aware-app
     namespace: topology-demo
   spec:
     replicas: 3
     selector:
       matchLabels:
         app: zone-app
     template:
       metadata:
         labels:
           app: zone-app
       spec:
         topologySpreadConstraints:
         - maxSkew: 1
           topologyKey: kubernetes.io/hostname
           whenUnsatisfiable: ScheduleAnyway
           labelSelector:
             matchLabels:
               app: zone-app
         containers:
         - name: web
           image: nginx:alpine
   ```
   ```bash
   kubectl apply -f zone-app.yaml
   ```
3. Verificar la distribución de los Pods entre los nodos:
   ```bash
   kubectl get pods -n topology-demo -o wide
   ```

---

## Ejercicio 3 — Verificación de Network Policies en la Plataforma

1. Validar si el CNI del clúster soporta aislamiento por NetworkPolicy:
   ```bash
   kubectl get netpol -A
   ```

---

<details>
<summary>Ver Respuestas</summary>

1. `WaitForFirstConsumer` evita que el aprovisionador de almacenamiento cree el PVC/PV en una Zona de Disponibilidad (AZ) diferente a aquella donde el Scheduler asignará finalmente el Pod.
2. `maxSkew: 1` limita la diferencia de cantidad de Pods entre topologías (nodos/AZs) a un máximo de 1 Pod.

</details>