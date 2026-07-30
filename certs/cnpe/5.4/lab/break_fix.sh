# 5.4 Using Automation Frameworks for Self-Service Provisioning

> Referencia: [CNCF CNPE Curriculum](https://github.com/cncf/curriculum/raw/master/CNPE_Curriculum.pdf)

Los frameworks de automatización para portales de autoservicio (Internal Developer Portals - IDP) como **Spotify Backstage** integran catalogación de servicios, plantillas de desarrollo (*Software Templates*) y APIs para habilitar la experiencia del desarrollador (Developer Experience - DevEx).

---

## 1. Internal Developer Portals (IDPs) con Backstage

**Backstage** (CNCF Incubating) expone un catálogo centralizado donde los desarrolladores pueden crear proyectos pre-configurados que incluyen CI/CD, IaC, monitoreo y políticas de seguridad automáticamente.

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
- Spotify Backstage Documentation — https://backstage.io/docs/overview/what-is-backstage