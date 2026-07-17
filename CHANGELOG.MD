# Changelog

Registro de lo que se fue entregando. Formato libre, orden cronológico
inverso (más reciente arriba). El detalle de diseño vive en [PLAN.MD](PLAN.MD);
lo pendiente vive en [BACKLOG.MD](BACKLOG.MD).

## 2026-07-17

- **Video por certificación escalado a las 5 certs con contenido** (cka,
  ckad, cks, kcna, lpi-010-160), en español. Dos bugs reales encontrados y
  arreglados en el camino:
  - **YAML del guion roto por `:` sin comillas dentro de una frase**
    (reproducido con `cks`: `"No es teoría: es defender..."` — el `: ` en
    medio de un plain scalar es ambiguo para el parser YAML y lo rompe).
    No es un error de contenido ni de backend, es de formato; `_ask_scenes`
    ahora reintenta hasta 3 veces (pidiéndole al modelo explícitamente que
    entrecomille cualquier frase con `:`) antes de fallar.
  - **`lpi-010-160` pesa sus dominios en puntos que suman 40, no en % que
    suman 100** (a diferencia de todos los temarios CNCF snapshoteados,
    que sí usan %) — sin normalizar, la escena de dominios del video hubiera
    mostrado "7%" para un dominio que en realidad es "7 de 40 puntos", un
    dato incorrecto. `_cert_domains()` ahora normaliza siempre a porcentaje
    del total antes de mostrarlo.
- **CKS agregado al catálogo**: snapshot del temario oficial (PDF
  `CKS_Curriculum v1.34`, 26 topics, pesos correctos por dominio desde el
  primer intento) + contenido/ejercicios/lab en español, 26/26 limpio.
  Sobrevivió a un `kill` externo del proceso (a las 14/26) y a dos cortes
  reales de cuota de Claude (a los 19/26 y 24/26) — se retomó cada vez sin
  perder progreso porque `teach cert generate` saltea topics ya generados.
  Quedaron 2 labs a medio generar por los cortes; `fix_corrupted_content.py`
  los detectó (ahora chequea también labs faltantes, no solo corruptos) y
  los completó solo.
- **KCNA agregado al catálogo**: mismo bug de peso-por-dominio que CKAD
  encontrado al revisar `STATUS.MD` (pesos sumaban 360 en vez de 100, cada
  sub-tema con el peso completo del dominio copiado) — re-snapshoteado con
  `tracker.py` ya arreglado, ahora suma 100 limpio (44/16/28/12). Contenido
  generado, 13/13 en español. **Con esto el temario del path `kubernetes`
  (KCNA → CKA/CKAD → CKS) queda completo en sus 4 certs.**
- **Video en más idiomas**: Piper sí tiene voces para alemán y chino
  (`de_DE-thorsten-high`, `zh_CN-huayan-medium` — verificado contra la
  lista real de idiomas soportados del repo `rhasspy/piper-voices`; japonés
  NO tiene ninguna voz Piper, ese sigue bloqueado). Videos de `linux-admin`
  y `kubernetes` generados en inglés y alemán. `core/video.py` ahora elige
  fuente por idioma (Noto Sans CJK para zh/ja si está instalada, si no cae
  a Liberation Sans sin romper) para que las slides en chino no muestren
  tofu/cuadraditos.
- **STATUS.MD (nuevo)** + `scripts/status_matrix.py`: matriz de qué
  cert/idioma/lab/video está terminado, generada siempre desde conteo real
  de archivos (nunca a mano) — correr el script después de cualquier
  generación. Ya sirvió para encontrar el bug de KCNA de arriba.
- **Nueva feature: video por certificación puntual** (no solo por path de
  carrera). Mismo pipeline (Piper + Pillow + ffmpeg) que los videos de path,
  con una escena nueva y determinística "dominios del examen" (barras con
  el peso real de cada dominio, sumado de los topics del cert.md — nunca
  inventado por la AI, mismo principio que la escena "path" existente) en
  vez del mapa de certificaciones. `teach cert video-script`/`teach cert
  video` (nuevos), `/api/certs/{id}/video` (nuevo, mismo fallback de idioma
  que el de paths), video visible en la página de cada cert en la web.
  Pilotado en `cka` (52s, 4 escenas) antes de decidir si escalar al resto.
- `cks` agregado a `TARGETS` en `scripts/fix_corrupted_content.py` y
  `scripts/resume-generation.sh` (mismo chequeo de fence envolvente y
  archivos faltantes que ya corría para lpi-010-160/ckad/cka).

## 2026-07-16

- **Bug encontrado y arreglado en `scripts/fix_corrupted_content.py`: solo
  detectaba archivos corruptos, no faltantes.** El script auditaba
  `cert_dir.glob(".../content.md")` — si el archivo no existía, el glob
  simplemente no lo encontraba, así que un topic a medio generar (proceso
  matado entre los dos completions, ej. de una sesión de meses atrás) no
  se detectaba nunca aunque el resto pareciera "0 combos corruptos". Se
  encontraron así 3 huecos reales que habían sobrevivido a todas las
  auditorías previas: `ckad/5.3/es/exercises.md` (y su lab entero) y los
  labs de `ckad/2.3` y `ckad/3.4` faltaban directamente. El chequeo de
  lpi-010-160/ckad "19/19"/"24/24" de entradas anteriores solo contaba
  `content.md` — nunca verificó `exercises.md`/`break_fix.sh` uno por uno.
  Fix: el script ahora itera por directorio de idioma (detecta
  `content.md`/`exercises.md` faltantes) y por la lista de topics del
  temario — no del disco — para los labs (detecta `break_fix.sh`
  faltante). Regenerados los 3 huecos; auditoría fresca confirma 0 combos
  en los tres certs, con conteo por archivo (no solo por topic) verificado
  a mano: lpi-010-160 19/19 content+exercises+lab en los 7 idiomas, ckad
  24/24, cka 27/27. Redesplegado con esta corrección.
- **CKA agregado al catálogo**: snapshot del temario oficial (PDF
  `CKA_Curriculum_v1.35.pdf`, 27 topics) + contenido/ejercicios/lab en
  español, 27/27 limpio. El bug de peso-por-dominio (visto antes en CKAD) se
  arregló ahora a nivel de código en `teach/core/tracker.py::snapshot_topics`:
  prompt explícito pidiendo repartir el peso del dominio entre sub-temas, más
  una validación dura que rechaza el snapshot (`TrackerError`, no se
  persiste) si los weight de todos los topics no suman ~100. Salió correcto
  al primer intento.
- **Video del path `kubernetes`** (Ingeniero Kubernetes, es, 111s/7 escenas).
  De paso se encontró y arregló un bug de PATH: `piper` (TTS) vive en
  `.venv/bin`, no en el PATH del sistema, y fallaba silenciosamente en
  contextos sin el venv activado (mismo patrón que ya había mordido antes con
  el binario `teach`). `teach/core/video.py` ahora lo resuelve vía
  `sys.executable` en vez de confiar en el PATH.
- **Bug nuevo encontrado y arreglado: fence de código Markdown envolvente.**
  El backend `claude` a veces devuelve todo el contenido envuelto en un fence
  (` ```markdown ` al inicio, ` ``` ` al final) a pesar de que el prompt pide
  texto plano — no es corrupción (el contenido es real), pero rompe el
  render en la web. Visto por primera vez en CKA (18 de 81 archivos, 0 casos
  en lpi-010-160/CKAD). Fix en `teach/core/generator.py::_strip_fence`
  (aplicado antes de guardar y antes de la validación anti-recap);
  `scripts/fix_corrupted_content.py` gana un paso previo que arregla in-place
  los archivos ya afectados sin gastar cuota de AI.
- **Confirmada la limpieza de contenido corrupto** (ver entrada 2026-07-11/12
  de más abajo): `scripts/fix_corrupted_content.py` corrió repetidamente vía
  el timer de systemd (que quedó activo de nuevo tras un reboot — ver
  BACKLOG.MD) y converge a **0 combos corruptos**. Verificación manual
  adicional: lpi-010-160 completo 19/19 en los 7 idiomas, ckad 24/24 en es,
  sin archivos por debajo de 1500 bytes, contenido real (no recap)
  confirmado por lectura directa en muestras de ja/zh y en
  `ckad/4.7/lab/break_fix.sh`. lpi-010-160 y CKAD quedan habilitados para
  deploy.

## 2026-07-11/12

- **Bug crítico encontrado y arreglado: el generador guardaba resúmenes de
  proceso en vez de contenido real.** `teach cert generate --backend claude`
  corre `claude -p` sin restricción de herramientas y con cwd en el repo — el
  modelo a veces actúa como agente de código (explora el repo, intenta
  escribir el archivo él mismo vía su propio Write tool) y lo que devuelve por
  stdout es un resumen de esa acción ("ja/content.md に完全な学習コンテンツを
  書きました...", referenciando el tamaño real del stub viejo) en vez del
  contenido pedido — que el pipeline guardaba tal cual. Reproducido de forma
  determinística. Una auditoría encontró **~170 archivos corruptos** (73% de
  lo revisado) entre las traducciones de lpi-010-160 (pt/fr/de/zh/ja) y CKAD.
  **Fix en `teach/core/generator.py`**: (1) `claude -p --disallowedTools
  "Write,Edit,Bash,Read,Glob,Grep,NotebookEdit,WebFetch,WebSearch,Task" --`
  fuerza al modelo a responder en texto plano, sin alternativa de herramienta;
  (2) `_reject_if_recap()` valida cada respuesta antes de guardarla y rechaza
  cualquier cosa con la firma de este bug, en vez de guardarla en silencio.
  **`scripts/fix_corrupted_content.py`** audita y regenera (con `--force`) todo
  lo que siga corrupto — idempotente, integrado al timer de systemd para que
  siga solo. **Esto invalida el ítem de abajo** ("multi-idioma completo") — la
  cuenta de archivos (19/19) nunca midió calidad, solo existencia. No
  desplegado a producción hasta confirmar una pasada limpia de la auditoría.
- ~~**lpi-010-160 multi-idioma completo**: contenido + ejercicios generados en
  los 7 idiomas soportados (es, en, pt, fr, de, zh, ja), 19/19 temas cada uno.~~
  Ver el ítem de arriba — el conteo de archivos no garantizaba contenido real.
- **Video de paths (nueva feature)**: pipeline propio sin APIs externas —
  guion escrito por AI y congelado en `script.yaml` (con la parte fáctica, el
  gráfico de certificaciones, siempre determinística desde `catalog.yaml`,
  nunca generada por AI), narración con Piper TTS (voz neural offline), slides
  con Pillow (paleta del sitio), render con ffmpeg (`libopenh264`, esta build
  no trae `libx264` software). Primer video: path `linux-admin` en español.
  Servido vía `/media` (StaticFiles) + `/api/paths/{slug}/video`, horneado en
  la imagen Docker igual que `certs/`. Módulo: `teach/core/video.py`.
- **CKAD agregado al catálogo**: snapshot del temario oficial (PDF de
  `cncf/curriculum`, 24 temas) + contenido/ejercicios/lab por tema en español.
  Bug encontrado y corregido en el snapshot: el PDF de CNCF solo da peso por
  **dominio** (20/20/15/25/20 = 100%), no por sub-tema; el snapshot copiaba el
  peso del dominio entero a cada uno de sus sub-temas. Se corrigió repartiendo
  el peso de cada dominio entre sus temas (suma verificada = 100). Vale la
  pena revisar el mismo patrón en otras certs CNCF snapshot-eadas por AI desde
  un PDF con pesos solo a nivel de dominio.

## b7a8edb — web abierta

Contenido de estudio sin login (antes exigía sesión + plan pago) + inglés
completo (19/19) en lpi-010-160.

## 32b929f — landing

Remarca la organización (LPI vs Linux Foundation) dentro de la categoría Linux.

## deca856 — deploy local

`study.cluster.home` servido desde el cluster (k3s casero).

## 12e01a6 — paths + Linux Foundation

Paths i18n + track Linux Foundation (LFCA/LFCS) separado del track LPI. Build
sin workflow de CI.

## 1d4bd14 — multi-idioma + deploy

Primera versión multi-idioma + estilo + Helm chart para el cluster.
