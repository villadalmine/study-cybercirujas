# 4.1 Cloud Native Ecosystem and Principles

## ¿Qué significa "Cloud Native"?

Cloud Native describe un enfoque para diseñar, construir y operar aplicaciones que aprovechan al máximo el modelo de cloud computing: escalabilidad elástica, resiliencia ante fallos, despliegues frecuentes y automatización extensiva. No es una tecnología puntual sino una filosofía de arquitectura y de operaciones.

La CNCF (Cloud Native Computing Foundation) define las aplicaciones cloud native como aquellas que son:

- **Containerized (empaquetadas en contenedores):** cada componente corre aislado con sus dependencias, garantizando portabilidad entre entornos (laptop, on-prem, cualquier cloud).
- **Dynamically orchestrated (orquestadas dinámicamente):** un sistema de orquestación (típicamente Kubernetes) decide dónde y cuándo correr cada contenedor, optimizando el uso de recursos.
- **Microservices-oriented:** las aplicaciones se descomponen en servicios pequeños, independientes y débilmente acoplados, en vez de un monolito único.

El objetivo de este enfoque es permitir sistemas **resilientes, manejables y observables**, combinados con automatización robusta que permita a los equipos hacer cambios de alto impacto de forma frecuente y predecible, con el mínimo esfuerzo manual.

## Principios fundamentales

### Microservices

Cada servicio tiene una responsabilidad acotada, su propio ciclo de vida de despliegue y, frecuentemente, su propia base de datos. Se comunican vía APIs (REST, gRPC, mensajería asíncrona). Esto permite escalar y desplegar cada componente de forma independiente, pero introduce complejidad de red, descubrimiento de servicios y observabilidad distribuida (temas de los dominios 4.2 y 4.5 de este curso).

### Containers

Los contenedores empaquetan una aplicación junto con sus dependencias en una unidad inmutable y portable. Estandarizados por la **OCI (Open Container Initiative)**, garantizan que "funciona en mi máquina" se traduzca en "funciona en cualquier máquina compatible con OCI".

```bash
$ docker run -d --name web nginx:1.25
$ docker exec web cat /etc/os-release
```

La misma imagen `nginx:1.25` corre igual en un laptop, en un clúster on-prem o en un cloud público.

### Dynamic orchestration

Un orquestador (Kubernetes es el estándar de facto) automatiza el ciclo de vida de los contenedores: scheduling, self-healing, scaling y rolling updates, sin intervención manual constante.

### Declarative APIs

En lugar de emitir comandos imperativos paso a paso, se declara el **estado deseado** y un controlador se encarga de reconciliar la realidad con esa declaración (control loop / reconciliation loop).

```yaml
# deployment.yaml — estado deseado: 3 réplicas de nginx
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: nginx
        image: nginx:1.25
```

```bash
$ kubectl apply -f deployment.yaml
deployment.apps/web created
```

Comparar con el enfoque imperativo (`kubectl run`, `kubectl scale`), que no queda registrado como fuente de verdad versionable. El modelo declarativo es la base de prácticas como **GitOps**.

### Immutable infrastructure

En vez de parchear un servidor o contenedor en ejecución, se reemplaza por una nueva instancia construida desde una imagen actualizada. Esto elimina el "configuration drift" y hace los rollbacks triviales: basta con volver a desplegar la versión anterior de la imagen.

```bash
# En vez de entrar al contenedor y modificarlo:
$ docker exec -it web sh -c "apt-get update && apt-get upgrade"   # ❌ anti-patrón

# Se construye y despliega una nueva imagen inmutable:
$ docker build -t myapp:1.2.1 .
$ kubectl set image deployment/web nginx=myapp:1.2.1   # ✅ reemplazo, no mutación
```

## CNCF: Cloud Native Computing Foundation

La **CNCF** es una fundación sin fines de lucro creada en 2015 bajo el paraguas de la **Linux Foundation**. Su misión es fomentar la adopción de cloud computing "vendor-neutral" sosteniendo un ecosistema de proyectos open source. Kubernetes fue su proyecto fundacional, donado por Google.

### Estructura de gobernanza

- **Governing Board:** supervisión estratégica y presupuestaria, con representación de las empresas miembro.
- **Technical Oversight Committee (TOC):** define la visión técnica y aprueba el ingreso/graduación de proyectos.
- **TAGs (Technical Advisory Groups):** grupos temáticos (ej. TAG App Delivery, TAG Observability, TAG Security) que asesoran sobre áreas específicas del ecosistema.

### Niveles de madurez de los proyectos

Todo proyecto donado a la CNCF pasa por etapas:

| Nivel | Descripción | Ejemplos |
|---|---|---|
| **Sandbox** | Etapa inicial, experimental, bajo nivel de adopción exigido | proyectos emergentes |
| **Incubating** | Adopción demostrada en producción por múltiples organizaciones | Argo, Cilium, KEDA |
| **Graduated** | Máxima madurez: gobernanza, seguridad y adopción a gran escala verificadas | Kubernetes, Prometheus, Envoy, containerd, CoreDNS, etcd, Fluentd, Helm, Jaeger, Vitess, TiKV |

Este esquema le da a las organizaciones una señal de riesgo/madurez antes de adoptar un proyecto en producción.

## CNCF Cloud Native Landscape

El **CNCF Landscape** (landscape.cncf.io) es un mapa visual e interactivo de miles de proyectos y productos del ecosistema, organizados por categoría:

- **Provisioning** (IaC, gestión de contenedores, seguridad)
- **Runtime** (container runtime, storage, networking)
- **Orchestration & Management** (scheduling, service mesh, API gateway)
- **App Definition and Development** (CI/CD, bases de datos, streaming/messaging)
- **Observability and Analysis** (monitoring, logging, tracing)
- **Platform** (plataformas cloud native, PaaS)
- **Serverless**

El landscape ayuda a ubicar cada herramienta (ej. Prometheus en Observability, Istio en Orchestration & Management) dentro del panorama general y a entender que "cloud native" es un ecosistema de piezas intercambiables, no una única pila cerrada.

## Modelos de servicio en la nube

Como contexto del ecosistema, conviene distinguir los modelos de responsabilidad compartida:

- **IaaS (Infrastructure as a Service):** el proveedor da cómputo/red/storage crudos (ej. EC2). El usuario gestiona el SO y todo lo superior.
- **PaaS (Platform as a Service):** el proveedor gestiona el runtime y la plataforma; el usuario solo despliega su código.
- **SaaS (Software as a Service):** aplicación completa entregada como servicio.
- **FaaS (Function as a Service):** modelo serverless donde se ejecuta código en respuesta a eventos, sin gestionar servidores (ej. AWS Lambda, Knative).

Kubernetes se ubica típicamente como una capa de orquestación sobre IaaS, y a la vez habilita experiencias tipo PaaS/FaaS mediante proyectos del ecosistema (ej. Knative para serverless).

## Open source y comunidad

El ecosistema cloud native se apoya fuertemente en desarrollo abierto: código público, gobernanza transparente y contribución multi-vendor evitan el "vendor lock-in". La CNCF exige a sus proyectos graduados criterios de gobernanza abierta (ej. al menos dos organizaciones distintas contribuyendo activamente), lo que reduce el riesgo de que un solo actor controle unilateralmente el rumbo técnico.

## Referencias

- CNCF Cloud Native Definition v1.0 — https://github.com/cncf/toc/blob/main/DEFINITION.md
- CNCF Curriculum (KCNA) — https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf
- CNCF Cloud Native Landscape — https://landscape.cncf.io/
- CNCF Charter — https://github.com/cncf/foundation/blob/main/charter.md
- CNCF Project Maturity Levels — https://github.com/cncf/toc/blob/main/process/graduation_criteria.md
- Open Container Initiative — https://opencontainers.org/
- Kubernetes Documentation — https://kubernetes.io/docs/concepts/overview/
- The Twelve-Factor App — https://12factor.net/