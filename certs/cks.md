---
cert: cks
exam: CKS
snapshot_date: '2026-07-17'
sources:
- https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
topics:
- id: '1.1'
  sources:
  - https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
  status: generated
  title: Use Network security policies to restrict cluster level access
  topic: 1 - Cluster Setup
  weight: 3
- id: '1.2'
  sources:
  - https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
  status: generated
  title: Use CIS benchmark to review the security configuration of Kubernetes components
    (etcd, kubelet, kubedns, kubeapi)
  topic: 1 - Cluster Setup
  weight: 3
- id: '1.3'
  sources:
  - https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
  status: generated
  title: Properly set up Ingress objects with TLS
  topic: 1 - Cluster Setup
  weight: 3
- id: '1.4'
  sources:
  - https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
  status: generated
  title: Protect node metadata and endpoints
  topic: 1 - Cluster Setup
  weight: 3
- id: '1.5'
  sources:
  - https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
  status: generated
  title: Verify platform binaries before deploying
  topic: 1 - Cluster Setup
  weight: 3
- id: '2.1'
  sources:
  - https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
  status: pending
  title: Use appropriate pod security standards
  topic: 2 - Minimize Microservice Vulnerabilities
  weight: 5
- id: '2.2'
  sources:
  - https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
  status: pending
  title: Manage kubernetes secrets
  topic: 2 - Minimize Microservice Vulnerabilities
  weight: 5
- id: '2.3'
  sources:
  - https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
  status: pending
  title: Understand and implement isolation techniques (multi-tenancy, sandboxed containers,
    etc.)
  topic: 2 - Minimize Microservice Vulnerabilities
  weight: 5
- id: '2.4'
  sources:
  - https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
  status: pending
  title: Implement Pod-to-Pod encryption (Cilium, Istio)
  topic: 2 - Minimize Microservice Vulnerabilities
  weight: 5
- id: '3.1'
  sources:
  - https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
  status: pending
  title: Use Role Based Access Controls to minimize exposure
  topic: 3 - Cluster Hardening
  weight: 3.75
- id: '3.2'
  sources:
  - https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
  status: pending
  title: Exercise caution in using service accounts e.g. disable defaults, minimize
    permissions on newly created ones
  topic: 3 - Cluster Hardening
  weight: 3.75
- id: '3.3'
  sources:
  - https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
  status: pending
  title: Restrict access to Kubernetes API
  topic: 3 - Cluster Hardening
  weight: 3.75
- id: '3.4'
  sources:
  - https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
  status: pending
  title: Upgrade Kubernetes to avoid vulnerabilities
  topic: 3 - Cluster Hardening
  weight: 3.75
- id: '4.1'
  sources:
  - https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
  status: pending
  title: Minimize base image footprint
  topic: 4 - Supply Chain Security
  weight: 5
- id: '4.2'
  sources:
  - https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
  status: pending
  title: Understand your supply chain (e.g. SBOM, CI/CD, artifact repositories)
  topic: 4 - Supply Chain Security
  weight: 5
- id: '4.3'
  sources:
  - https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
  status: pending
  title: Secure your supply chain (permitted registries, sign and validate artifacts,
    etc.)
  topic: 4 - Supply Chain Security
  weight: 5
- id: '4.4'
  sources:
  - https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
  status: pending
  title: Perform static analysis of user workloads and container images (e.g. Kubesec,
    KubeLinter)
  topic: 4 - Supply Chain Security
  weight: 5
- id: '5.1'
  sources:
  - https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
  status: pending
  title: Minimize host OS footprint (reduce attack surface)
  topic: 5 - System Hardening
  weight: 2.5
- id: '5.2'
  sources:
  - https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
  status: pending
  title: Using least-privilege identity and access management
  topic: 5 - System Hardening
  weight: 2.5
- id: '5.3'
  sources:
  - https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
  status: pending
  title: Minimize external access to the network
  topic: 5 - System Hardening
  weight: 2.5
- id: '5.4'
  sources:
  - https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
  status: pending
  title: Appropriately use kernel hardening tools such as AppArmor, seccomp
  topic: 5 - System Hardening
  weight: 2.5
- id: '6.1'
  sources:
  - https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
  status: pending
  title: Perform behavioral analytics to detect malicious activities
  topic: 6 - Monitoring, Logging and Runtime Security
  weight: 4
- id: '6.2'
  sources:
  - https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
  status: pending
  title: Detect threats within physical infrastructure, apps, networks, data, users
    and workloads
  topic: 6 - Monitoring, Logging and Runtime Security
  weight: 4
- id: '6.3'
  sources:
  - https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
  status: pending
  title: Investigate and identify phases of attack and bad actors within the environment
  topic: 6 - Monitoring, Logging and Runtime Security
  weight: 4
- id: '6.4'
  sources:
  - https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
  status: pending
  title: Ensure immutability of containers at runtime
  topic: 6 - Monitoring, Logging and Runtime Security
  weight: 4
- id: '6.5'
  sources:
  - https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
  status: pending
  title: Use Kubernetes audit logs to monitor access
  topic: 6 - Monitoring, Logging and Runtime Security
  weight: 4
version: '1.34'
---

# Certified Kubernetes Security Specialist (CKS)

Snapshot del temario. Completar `topics` con id, title, weight, status y sources
(ver certs/lpi-010-160.md como referencia) y correr `teach cert generate cks`.
