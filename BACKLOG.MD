# Backlog

Lo que falta, sin comprometerse a orden estricto salvo donde se indica. Lo ya
resuelto va a [CHANGELOG.MD](CHANGELOG.MD); el diseño de fondo a [PLAN.MD](PLAN.MD).

## En curso / próximo (orden)

Lo resuelto el 2026-07-16 (contenido corrupto, CKA, video de `kubernetes`,
bug del fence envolvente, gaps de archivos faltantes, tagging de deploy) ya
está en [CHANGELOG.MD](CHANGELOG.MD) con el detalle completo — no se repite
acá. Próximo, sin orden estricto:

1. **SDD de labs** (ver sección "Labs — modos de ejecución" más abajo, y
   PLAN.MD sección SDD) — evaluación hecha, nada implementado todavía.
   Empezar por Docker local (provider `local` de `labs.py`, hoy sin
   implementar) porque el resto del roadmap de labs depende de tener un
   container "toolbox" reusable.
2. Traducir CKAD y CKA a los otros 6 idiomas.
3. Video para los paths restantes sin video (ver "Contenido" más abajo).

## Contenido

- Traducir CKAD y CKA a los otros 6 idiomas — hoy solo existen en español.
- Revisar si otras certs CNCF ya snapshoteadas (KCNA, KCSA, CKS, etc.) tienen
  el mismo problema de peso-por-dominio antes de generar contenido sobre ellas.
- Video para los paths restantes sin video: `linux-devops`, `kubernetes-security`,
  `gitops-platform`, `kubestronaut`, `golden-kubestronaut`, `care`.

## Video — deuda técnica

- No hay voz Piper configurada para de/zh/ja (`VOICES` en `core/video.py` solo
  tiene es/en) — bloquea narración de video en esos idiomas.
- No hay fuente CJK instalada — bloquea que las slides Pillow rendericen texto
  zh/ja correctamente (hoy solo Liberation Sans).

## Labs — modos de ejecución (ver PLAN.MD, sección SDD)

Evaluación hecha (spec-driven, PLAN.MD), nada de esto implementado todavía.
Punto de partida ya existente: `lab.yaml` (spec declarativo por tema) y
`break_fix.sh` (script real, generado y revisado) por tema; `labs.py` solo
implementa el provider `terraform` — el provider `local` está declarado pero
sin código detrás. Orden sugerido (cada etapa reusa la anterior):

1. **Docker local (free, primero).** Generar desde `lab.yaml` un
   `Dockerfile`/`docker-compose.yml` determinístico; el estudiante lo corre
   en su propia máquina. Llena el hueco del provider `local` en `labs.py`.
   Costo/riesgo para la plataforma: cero. El mismo container "toolbox" que
   esto produce es el que se reusa en el paso siguiente.
2. **Video del ejercicio — captura real, no mock.** Mismo principio que el
   video de marketing de paths (la parte fáctica nunca la escribe la AI, ver
   el path scene determinístico en `core/video.py`): levantar el container
   real del paso 1, correr `break_fix.sh` de verdad, y grabar la sesión con
   **asciinema** (`.cast`, texto, KB no MB, reproducible/escalable, player
   self-hosteable) en vez de mockear la terminal con AI o renderizar mp4. La
   AI solo escribe la narración que se superpone (Piper TTS, como ya se hace
   para los videos de path).
3. **Pago A — BYO-cloud + terraform, self-service primero.** Extiende el
   contrato que ya está en `labs.py` (`up`/`down` sobre `lab/terraform/`):
   generar el módulo terraform por tema, v1 con el estudiante corriendo
   `terraform apply` con sus propias credenciales — la plataforma nunca las
   toca. Un modo "un click" donde la plataforma ejecuta terraform con
   credenciales pegadas por el estudiante es más cómodo pero la convierte en
   custodio de credenciales cloud ajenas — dejar para cuando haya demanda
   comprobada, no construirlo de entrada.
4. **Pago B — hosteado por mí, botón "Conectar" → destrucción automática
   (al final, solo con ingresos que justifiquen la inversión en seguridad).**
   Riesgo principal: la plataforma corre en el cluster de casa, expuesto
   públicamente — **no correr labs de terceros ahí**, blast radius directo a
   la red doméstica (escape de lab, minado, pivot a la LAN). Alternativa:
   VM efímera por sesión en un proveedor cloud aparte y barato (Hetzner/DO,
   billing por minuto), desde la misma imagen "toolbox" del paso 1, timeout
   duro (30-60 min), límite de sesiones concurrentes, terminal web vía
   xterm.js+websocket, `terraform destroy` al cerrar la sesión. Evaluar
   también sandboxes efímeros ya hechos (E2B, Coder, Gitpod) antes de
   construir el hardening de aislamiento a mano.

## Deploy — deuda técnica

- ~~**`make image-cluster` usaba un `TAG` fijo que podía divergir del release
  de Helm en producción sin error visible.**~~ **Resuelto (2026-07-16)**:
  `TAG` default ahora es `$(shell date +%Y%m%d%H%M%S)` en el Makefile — un
  timestamp fresco por invocación, no un número que haya que sincronizar a
  mano. Ojo: sigue siendo responsabilidad de quien despliega pasar el MISMO
  `TAG=...` explícito a `make image-cluster` y `make deploy-local` en la
  misma tanda (dos invocaciones de `make` sin `TAG=` explícito generan dos
  timestamps distintos y rompen el emparejamiento build↔deploy).

## Plataforma (roadmap largo, ver PLAN.MD)

- Multi-provider de labs, usuarios reales (hoy admin/admin stub), lab-runner
  en Go contra el contrato `lab.yaml`/`terraform/`/`status.yaml`.
- Mejorar el render de la web: hoy el contenido se muestra sin formato
  Markdown real (no es prioridad — el core es el contenido en sí).
