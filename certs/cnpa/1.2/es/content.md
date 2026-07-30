# 1.2 DevOps Practices and Culture in Platform Engineering

> Referencia: [CNCF CNPA Curriculum](https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf)

La **Ingeniería de Plataformas (Platform Engineering)** evoluciona las prácticas de **DevOps** tradicionales ofreciendo herramientas y servicios como un producto (*Platform as a Product*) para reducir la carga cognitiva de los desarrolladores (*Developer Cognitive Load*) y acelerar la entrega de valor sin comprometer la gobernanza.

---

## 1. El Paradigma "Platform as a Product"

En lugar de que cada equipo de desarrollo gestione su propia infraestructura de forma aislada, los ingenieros de plataforma tratan su plataforma interna (Internal Developer Platform - IDP) como un producto orientado a sus clientes internos (desarrolladores).

- **Thinnest Viable Platform (TVP)**: Plataforma mínima viable enfocada en resolver las necesidades reales sin sobre-diseñar componentes.
- **Paved Paths / Guardrails**: Rutas doradas pre-aprobadas que automatizan la seguridad, CI/CD y observabilidad de forma nativa.

---

## 2. Reducción de la Carga Cognitiva

Las topologías de equipo (Team Topologies) clasifican a los equipos en cuatro categorías:
1. **Stream-aligned Teams**: Enfocados en la entrega de valor al negocio.
2. **Platform Teams**: Desarrollan la plataforma autoservicio.
3. **Enabling Teams**: Ayudan a otros equipos a adoptar nuevas tecnologías.
4. **Complicated Subsystem Teams**: Especialistas en componentes matemáticos o de infraestructura profunda.

---

## Referencias

- CNCF CNPA Curriculum — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- Team Topologies Framework — https://teamtopologies.com/
- CNCF Platform Engineering Maturity Model — https://tag-app-delivery.cncf.io/wgs/platform/maturity-model/