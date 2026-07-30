# 3.6 GitOps Basics, Controllers, and Workflows

## Motivación y Controladores de GitOps

Los controladores in-cluster de GitOps (**Argo CD** y **Flux v2**) garantizan la reconciliación continua entre el estado deseado declarado en repositorios Git e infraestructura en vivo sobre Kubernetes.

---

## 1. Principios de Operación

- Reconciliación continua mediante controladores in-cluster.
- Detección automática de deriva de configuración (*Drift Detection*).
- Auto-remediación (*Self-Healing*).

---

## Referencias

- CNCF CNPA Curriculum — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- OpenGitOps Standard — https://opengitops.dev/