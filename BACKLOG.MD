# Backlog

Lo que falta, sin comprometerse a orden estricto salvo donde se indica. Lo ya
resuelto va a [CHANGELOG.MD](CHANGELOG.MD); el diseño de fondo a [PLAN.MD](PLAN.MD).

## En curso / próximo (orden)

0. ~~**(Bloqueante) Terminar de regenerar contenido corrupto.**~~ **Resuelto
   (2026-07-16)**: `scripts/fix_corrupted_content.py` reporta 0 combos
   corruptos. Verificado además a mano: lpi-010-160 19/19 temas en los 7
   idiomas, ckad 24/24 en es, ningún `content.md`/`exercises.md` por debajo de
   1500 bytes, y spot-check de contenido real (no recap) en ja/zh y en
   `ckad/4.7/lab/break_fix.sh` (el archivo que la memoria de proyecto marcaba
   como historial de regresión a stub — ahora tiene contenido real). Ya no
   bloquea deploy/commit.
1. ~~**CKA**~~ **Hecho (2026-07-16)**: snapshot de `CKA_Curriculum_v1.35.pdf`
   (27 topics) + contenido/ejercicios/lab en español, 27/27 limpio. El bug de
   peso-por-dominio se arregló a nivel de código en
   `teach/core/tracker.py::snapshot_topics` (prompt explícito + validación
   dura: si los weight no suman ~100, `TrackerError` y no se persiste el
   snapshot) — ya no depende de corrección manual. Salió correcto al primer
   intento (Storage 10/Troubleshooting 30/Workloads 15/Cluster Arch 25/
   Networking 20 = 100).
2. ~~**Video de otro path**~~ **Hecho (2026-07-16)**: path `kubernetes`
   (Ingeniero Kubernetes), es, 111s/7 escenas. De paso se encontró y arregló
   otro bug de PATH (`piper` vive en `.venv/bin`, no en el PATH del sistema —
   mismo patrón que ya había mordido con el binario `teach`): ahora
   `teach/core/video.py` lo resuelve vía `sys.executable` en vez de confiar
   en el PATH.
3. **Nuevo bug encontrado y arreglado (2026-07-16): fence de código envolvente.**
   El backend `claude` a veces devuelve todo el contenido envuelto en un fence
   Markdown (` ```markdown ` al inicio, ` ``` ` al final) a pesar de pedir
   texto plano — no es corrupción (el contenido es real), pero rompe el
   render en la web. Visto por primera vez en CKA (18 de 81 archivos). Fix en
   `teach/core/generator.py::_strip_fence` (aplicado antes de guardar,
   también antes de la validación anti-recap) + `scripts/fix_corrupted_content.py`
   ahora tiene un paso previo que arregla in-place los archivos ya afectados
   sin gastar cuota de AI. Vale la pena revisar si lpi-010-160/CKAD tuvieron
   este problema en el pasado y no se detectó (el chequeo viejo de "empieza
   con #" los habría marcado como corruptos igual, así que si hubieran
   existido ya se habrían regenerado).

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

- Docker local (free): generar `docker-compose.yml`/`Dockerfile` desde
  `lab.yaml`, llena el hueco del provider `local` no implementado en `labs.py`.
- Grabación asciinema del ejercicio resuelto (reusa el mismo container).
- Terraform BYO-cloud (pago, self-service primero).
- Lab hosteado efímero (pago, al final — requiere aislar de la red doméstica).

## Deploy — deuda técnica

- **`make image-cluster` usa `TAG ?= 0.1.0` por default, pero el release de
  Helm en producción está fijado a `image.tag: 0.1.3`** (de un `helm upgrade
  --set image.tag=...` manual anterior, nunca reflejado en `values-*.yaml` ni
  en el Makefile). Un rebuild con el TAG default sube una imagen que el
  deployment nunca pulls — el rollout "funciona" pero sirve la imagen vieja
  sin error visible. Pasa desapercibido porque `imagePullPolicy: Always` hace
  que el pod arranque igual. Automatizar el tagging (git sha o timestamp) en
  vez de un número fijo que hay que sincronizar a mano entre Makefile y Helm.

## Plataforma (roadmap largo, ver PLAN.MD)

- Multi-provider de labs, usuarios reales (hoy admin/admin stub), lab-runner
  en Go contra el contrato `lab.yaml`/`terraform/`/`status.yaml`.
- Mejorar el render de la web: hoy el contenido se muestra sin formato
  Markdown real (no es prioridad — el core es el contenido en sí).
