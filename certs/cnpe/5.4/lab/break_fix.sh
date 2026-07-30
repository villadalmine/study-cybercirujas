# 5.4 Using Automation Frameworks for Self-Service Provisioning

## Motivación e Internal Developer Portals (Backstage)

Portales de desarrollador como **Spotify Backstage** (CNCF Incubating) ofrecen un catálogo unificado de servicios y plantillas de desarrollo (*Software Templates*).

---

## 1. Backstage Software Template

```yaml
apiVersion: backstage.io/v1alpha1
kind: Template
metadata:
  name: create-microservice-template
  title: Microservicio Cloud Native Go
spec:
  owner: platform-team
  type: service
  steps:
  - id: fetch-base
    name: Descargar Plantilla Base
    action: fetch:template
    input:
      url: ./skeleton
  - id: publish-repo
    name: Crear Repositorio Git
    action: publish:github
    input:
      allowedOwners: ['my-org']
      repoUrl: github.com?repo=${{ parameters.repoName }}&owner=my-org
```

---

## Referencias

- CNCF CNPE Curriculum — https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf
- Spotify Backstage — https://backstage.io/