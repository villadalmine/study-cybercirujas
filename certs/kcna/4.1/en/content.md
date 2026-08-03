# 4.1 Cloud Native Ecosystem and Principles

## What Does "Cloud Native" Mean?

Cloud Native describes an approach for designing, building, and operating applications that fully leverage the cloud computing model: elastic scalability, fault resilience, frequent deployments, and extensive automation. It is not a single technology but a philosophy of architecture and operations.

The CNCF (Cloud Native Computing Foundation) defines cloud native applications as those that are:

- **Containerized:** each component runs in isolation with its dependencies, guaranteeing portability across environments (laptop, on-prem, any cloud).
- **Dynamically orchestrated:** an orchestration system (typically Kubernetes) decides where and when to run each container, optimizing resource usage.
- **Microservices-oriented:** applications are decomposed into small, independent, loosely coupled services instead of a single monolith.

The goal of this approach is to enable **resilient, manageable, and observable** systems, combined with robust automation that allows teams to make high-impact changes frequently and predictably with minimal manual effort.

## Foundational Principles

### Microservices

Each service has a bounded responsibility, its own deployment lifecycle, and often its own database. They communicate via APIs (REST, gRPC, asynchronous messaging). This allows independent scaling and deployment of each component but introduces network complexity, service discovery, and distributed observability (topics covered in domains 4.2 and 4.5 of this course).

### Containers

Containers package an application together with its dependencies into an immutable and portable unit. Standardized by the **OCI (Open Container Initiative)**, they guarantee that "it works on my machine" translates to "it works on any OCI-compatible machine."

```bash
$ docker run -d --name web nginx:1.25
$ docker exec web cat /etc/os-release
```

The same image `nginx:1.25` runs identically on a laptop, an on-prem cluster, or a public cloud.

### Dynamic Orchestration

An orchestrator (Kubernetes is the de facto standard) automates the container lifecycle: scheduling, self-healing, scaling, and rolling updates, without constant manual intervention.

### Declarative APIs

Instead of issuing imperative commands step by step, the **desired state** is declared, and a controller reconciles reality with that declaration (control loop / reconciliation loop).

```yaml
# deployment.yaml — desired state: 3 replicas of nginx
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

Compare this with the imperative approach (`kubectl run`, `kubectl scale`), which is not recorded as a versionable source of truth. The declarative model is the foundation of practices such as **GitOps**.

### Immutable Infrastructure

Instead of patching a running server or container, replace it with a new instance built from an updated image. This eliminates "configuration drift" and makes rollbacks trivial: simply redeploy the previous image version.

```bash
# Instead of entering the container and modifying it:
$ docker exec -it web sh -c "apt-get update && apt-get upgrade"   # ❌ anti-pattern

# Build and deploy a new immutable image:
$ docker build -t myapp:1.2.1 .
$ kubectl set image deployment/web nginx=myapp:1.2.1   # ✅ replacement, not mutation
```

## CNCF: Cloud Native Computing Foundation

The **CNCF** is a non-profit foundation created in 2015 under the umbrella of the **Linux Foundation**. Its mission is to foster the adoption of "vendor-neutral" cloud computing by sustaining an ecosystem of open source projects. Kubernetes was its founding project, donated by Google.

### Governance Structure

- **Governing Board:** strategic and budgetary oversight, with representation from member companies.
- **Technical Oversight Committee (TOC):** defines the technical vision and approves project admission/graduation.
- **TAGs (Technical Advisory Groups):** topic-focused groups (e.g., TAG App Delivery, TAG Observability, TAG Security) that advise on specific areas of the ecosystem.

### Project Maturity Levels

Every project donated to the CNCF goes through stages:

| Level | Description | Examples |
|---|---|---|
| **Sandbox** | Initial, experimental stage; low adoption required | emerging projects |
| **Incubating** | Demonstrated production adoption by multiple organizations | Argo, Cilium, KEDA |
| **Graduated** | Highest maturity: governance, security, and large-scale adoption verified | Kubernetes, Prometheus, Envoy, containerd, CoreDNS, etcd, Fluentd, Helm, Jaeger, Vitess, TiKV |

This scheme provides organizations with a risk/maturity signal before adopting a project in production.

## CNCF Cloud Native Landscape

The **CNCF Landscape** (landscape.cncf.io) is a visual and interactive map of thousands of projects and products in the ecosystem, organized by category:

- **Provisioning** (IaC, container management, security)
- **Runtime** (container runtime, storage, networking)
- **Orchestration & Management** (scheduling, service mesh, API gateway)
- **App Definition and Development** (CI/CD, databases, streaming/messaging)
- **Observability and Analysis** (monitoring, logging, tracing)
- **Platform** (cloud native platforms, PaaS)
- **Serverless**

The landscape helps place each tool (e.g., Prometheus in Observability, Istio in Orchestration & Management) within the overall picture and understand that "cloud native" is an ecosystem of interchangeable pieces, not a single closed stack.

## Cloud Service Models

As context for the ecosystem, it is useful to distinguish the shared responsibility models:

- **IaaS (Infrastructure as a Service):** the provider supplies raw compute/network/storage (e.g., EC2). The user manages the OS and everything above.
- **PaaS (Platform as a Service):** the provider manages the runtime and platform; the user only deploys their code.
- **SaaS (Software as a Service):** a complete application delivered as a service.
- **FaaS (Function as a Service):** a serverless model where code is executed in response to events, without managing servers (e.g., AWS Lambda, Knative).

Kubernetes is typically positioned as an orchestration layer over IaaS, while also enabling PaaS/FaaS experiences through ecosystem projects (e.g., Knative for serverless).

## Open Source and Community

The cloud native ecosystem is heavily based on open development: public code, transparent governance, and multi-vendor contribution avoid "vendor lock-in." The CNCF requires its graduated projects to meet open governance criteria (e.g., at least two different organizations actively contributing), which reduces the risk of a single actor unilaterally controlling the technical direction.

## References

- CNCF Cloud Native Definition v1.0 — https://github.com/cncf/toc/blob/main/DEFINITION.md
- CNCF Curriculum (KCNA) — https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf
- CNCF Cloud Native Landscape — https://landscape.cncf.io/
- CNCF Charter — https://github.com/cncf/foundation/blob/main/charter.md
- CNCF Project Maturity Levels — https://github.com/cncf/toc/blob/main/process/graduation_criteria.md
- Open Container Initiative — https://opencontainers.org/
- Kubernetes Documentation — https://kubernetes.io/docs/concepts/overview/
- The Twelve-Factor App — https://12factor.net/