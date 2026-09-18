# 701.4 — Integración Continua y Entrega Continua — Ejercicios Guiados

> **Contexto del examen:** LPI DevOps Tools Engineer, examen 701-100, objetivo 701.4 (peso 5).
> Objetivos oficiales: <https://www.lpi.org/our-certifications/exam-701-objectives/>

Estos ejercicios construyen un pipeline de entrega real desde abajo, en una sola máquina: primero el build manual, después el pipeline como código, después una compuerta del lado del servidor, después Jenkins, después un registry de artefactos, después el equivalente declarativo en GitLab CI, y finalmente las estrategias de despliegue que convierten un artefacto construido en un release. Nada está simulado: cada comando se ejecuta de verdad.

**Prerrequisitos**

- Linux con `bash`, `git` ≥ 2.35, `make`, `tar`, `curl`, `python3` ≥ 3.11 (con `python3-venv` instalado)
- Docker ≥ 24 con un usuario no root en el grupo `docker`, y los puertos **8080** (Jenkins), **8088** (nginx) y **5000** (registry) libres
- Un runtime de `java` (JRE 17+) solo para los pasos opcionales del CLI de Jenkins
- Aproximadamente 3 GB de disco y red de salida para descargar imágenes y paquetes

**Disposición del laboratorio** — todo vive bajo `~/cicd-lab`:

```
~/cicd-lab/
├── hello-ci/      working copy (the application)
├── app.git/       bare repo acting as the "central" server
└── nginx/         reverse-proxy configs for the release strategies
```

---

## Ejercicio 0 — La aplicación bajo prueba

**Por qué importa.** Un pipeline es tan honesto como aquello que construye. Antes de automatizar nada, necesitás un repositorio donde el código, sus tests, su configuración de lint y su receta de build estén versionados *juntos*, de modo que un commit describa un estado completo y reproducible.

1. Creá el espacio de trabajo e inicializá el repositorio:

```bash
mkdir -p ~/cicd-lab/hello-ci && cd ~/cicd-lab/hello-ci
git init -b main
git config user.name  "CI Student"
git config user.email "student@example.com"
```

2. Escribí la biblioteca que el pipeline va a construir — `greeter.py`:

```python
"""Greeting library - the unit under test."""

DEFAULT_GREETING = "Hello"


def greet(name, greeting=DEFAULT_GREETING):
    """Return a greeting for name."""
    if not name:
        raise ValueError("name must not be empty")
    return f"{greeting}, {name}!"
```

3. Escribí el punto de entrada — `cli.py`:

```python
"""Command line front end for the greeter library."""

import argparse

from greeter import greet


def main(argv=None):
    parser = argparse.ArgumentParser(prog="hello-ci")
    parser.add_argument("name")
    args = parser.parse_args(argv)
    print(greet(args.name))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

4. Escribí los tests unitarios — `test_greeter.py`:

```python
import pytest

from greeter import greet


def test_greet_uses_the_default_greeting():
    assert greet("Ada") == "Hello, Ada!"


def test_greet_honours_an_explicit_greeting():
    assert greet("Ada", "Hi") == "Hi, Ada!"


def test_greet_rejects_an_empty_name():
    with pytest.raises(ValueError):
        greet("")
```

5. Fijá el herramental en `requirements-dev.txt` — versiones exactas, no rangos:

```
pytest==8.3.5
ruff==0.8.4
```

6. Poné la configuración del análisis estático **en el repositorio**, no en el historial de tu shell — `pyproject.toml`:

```toml
[tool.ruff]
line-length = 100
target-version = "py312"

[tool.ruff.lint]
select = ["E", "F", "W", "I", "B", "UP", "S"]
# S104: the lab server deliberately binds 0.0.0.0 inside a container.
ignore = ["S104"]
```

7. Excluí la salida del build del control de versiones — `.gitignore`:

```
.venv/
dist/
reports/
.pytest_cache/
__pycache__/
*.pyc
```

8. Construí el entorno a mano una vez, para saber qué va a estar automatizando el pipeline:

```bash
python3 -m venv .venv
.venv/bin/pip install --quiet --requirement requirements-dev.txt
.venv/bin/ruff check --output-format=concise .
.venv/bin/pytest -q
```

Esperado:

```
All checks passed!
...                                                                      [100%]
3 passed in 0.03s
```

9. Commiteá la línea base:

```bash
git add -A
git commit -m "feat: greeter library, CLI and unit tests"
git tag -a v1.0.0 -m "first release"
```

**Preguntas**

- **Q0.1** `requirements-dev.txt` fija `pytest==8.3.5` en lugar de `pytest>=8`. ¿Qué clase de falla de pipeline previene el pin exacto, y qué nueva obligación de mantenimiento crea?
- **Q0.2** Las reglas de lint viven en `pyproject.toml` dentro del repo. ¿Qué se rompe si cada desarrollador configura `ruff` localmente y el servidor de CI tiene sus propios valores por defecto?
- **Q0.3** `.venv/` y `dist/` están en `.gitignore`. Enunciá la regla general que esto sigue sobre qué pertenece al control de versiones y qué pertenece a un repositorio de artefactos.

---

## Ejercicio 1 — Qué significa realmente "integración"

**Por qué importa.** La *Integración* Continua no es "un servidor que corre tests". Es la práctica de fusionar el trabajo de cada desarrollador en el tronco compartido de manera continua, precisamente porque la fusión es donde cambios individualmente correctos se vuelven colectivamente incorrectos. Git solo puede resolver conflictos *textuales*. Este ejercicio produce un conflicto que git no puede ver.

1. El desarrollador A agrega soporte multilenguaje, cambiando la firma pública de `greet()`:

```bash
git switch -c feature/greeting-lang
```

Reemplazá `greeter.py` por:

```python
"""Greeting library - the unit under test."""

GREETINGS = {
    "en": "Hello",
    "es": "Hola",
    "de": "Hallo",
}


def greet(name, lang):
    """Return a greeting for name in lang."""
    if not name:
        raise ValueError("name must not be empty")
    try:
        greeting = GREETINGS[lang]
    except KeyError:
        raise ValueError(f"unsupported language: {lang}") from None
    return f"{greeting}, {name}!"
```

Actualizá `test_greeter.py` para que coincida con la nueva firma:

```python
import pytest

from greeter import greet


def test_greet_in_english():
    assert greet("Ada", "en") == "Hello, Ada!"


def test_greet_in_spanish():
    assert greet("Ada", "es") == "Hola, Ada!"


def test_greet_rejects_an_unknown_language():
    with pytest.raises(ValueError):
        greet("Ada", "cy")
```

2. Verificá que la rama esté en verde **de forma aislada** y commiteá:

```bash
.venv/bin/pytest -q
git commit -am "feat(greeter): select the greeting by language"
```

Esperado: `3 passed`.

3. Mientras tanto, el desarrollador B se ramifica desde la *misma* línea base y mejora el CLI — un archivo distinto:

```bash
git switch main
git switch -c feature/cli-default
```

Agregá a `cli.py`, dentro de `main()`, justo después de `args = parser.parse_args(argv)`:

```python
    if args.name.islower():
        args.name = args.name.capitalize()
```

3 (cont.). Verificá y commiteá:

```bash
.venv/bin/pytest -q
python3 cli.py ada
git commit -am "feat(cli): capitalise a lower-case name"
```

Esperado: `3 passed`, y después `Hello, Ada!`.

4. Integrá ambas ramas en el tronco y observá el resultado de la fusión:

```bash
git switch main
git merge --no-edit feature/greeting-lang
git merge --no-edit feature/cli-default
git log --oneline --graph -5
```

**Q1.1** — respondé antes de continuar.

5. Ahora ejecutá la aplicación, y después la suite de tests:

```bash
python3 cli.py ada
.venv/bin/pytest -q
```

Esperado:

```
Traceback (most recent call last):
  File "/home/you/cicd-lab/hello-ci/cli.py", line 19, in <module>
    raise SystemExit(main())
                     ~~~~^^
  File "/home/you/cicd-lab/hello-ci/cli.py", line 15, in main
    print(greet(args.name))
          ~~~~~^^^^^^^^^^^
TypeError: greet() missing 1 required positional argument: 'lang'
```

y:

```
...                                                                      [100%]
3 passed in 0.03s
```

**Preguntas**

- **Q1.1** `git merge` no reportó ningún conflicto para ninguna de las dos ramas, y ambas estaban en verde antes de la fusión. Explicá en una oración por qué el tronco fusionado está roto igual, y nombrá esta clase de falla.
- **Q1.2** La suite de tests pasa sobre el tronco roto. ¿Qué *tipo* de test faltaba — unitario, de integración o de aceptación — y por qué ninguna cantidad de tests unitarios adicionales sobre `greet()` podría haberlo detectado?
- **Q1.3** Ambas ramas vivieron minutos. Argumentá qué habría pasado si cada una hubiera vivido tres semanas, y conectá eso con por qué CI prescribe fusionar al tronco al menos una vez por día.

6. Arreglalo como te enseña un pipeline: **reproducí primero**. Agregá el test que falla, como `test_cli.py`:

```python
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent


def test_cli_greets_in_english_by_default():
    result = subprocess.run(
        [sys.executable, "cli.py", "ada"],
        cwd=REPO,
        capture_output=True,
        text=True,
        check=True,
    )
    assert result.stdout.strip() == "Hello, Ada!"
```

```bash
.venv/bin/pytest -q
```

Esperado: `1 failed, 3 passed` — la suite ahora ve el defecto.

7. Ponelo en verde restaurando la compatibilidad hacia atrás en `greeter.py`:

```python
def greet(name, lang="en"):
```

```bash
.venv/bin/pytest -q
git add -A
git commit -m "fix(greeter): keep greet() callable with one argument"
```

Esperado: `4 passed`.

**Preguntas**

- **Q1.4** Arreglaste la rotura con un argumento por defecto en lugar de editar cada llamador. Enunciá el principio de compatibilidad de API que opera acá, y un caso en el que el arreglo con argumento por defecto habría sido la elección equivocada.
- **Q1.5** Definí Integración Continua, Entrega Continua y Despliegue Continuo de modo que las tres definiciones difieran únicamente en *dónde se ubica la decisión humana*.

---

## Ejercicio 2 — El pipeline como código que podés correr localmente

**Por qué importa.** Un pipeline que solo existe dentro de la UI de un servidor de CI no se puede revisar, no se puede bisectar y no se puede reproducir en una laptop a las 02:00. El build tiene que ser un script en el repositorio; el único trabajo del sistema de CI es invocarlo en una máquina limpia.

1. Creá el `Makefile`. **Las líneas de receta deben empezar con un TAB, no con espacios:**

```make
SHELL       := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := ci

VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
VENV    := .venv

.PHONY: ci lint test package clean

ci: lint test package

$(VENV)/.stamp: requirements-dev.txt
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install --quiet --requirement requirements-dev.txt
	touch $@

lint: $(VENV)/.stamp
	$(VENV)/bin/ruff check --output-format=concise .

test: $(VENV)/.stamp
	mkdir -p reports
	$(VENV)/bin/pytest -q --junitxml=reports/junit.xml

package:
	mkdir -p dist
	tar --exclude=./dist --exclude=./$(VENV) --exclude=./.git --exclude=./reports \
	    --exclude-vcs-ignores -czf dist/hello-ci-$(VERSION).tar.gz .
	cd dist && sha256sum hello-ci-$(VERSION).tar.gz > hello-ci-$(VERSION).tar.gz.sha256

clean:
	rm -rf $(VENV) dist reports .pytest_cache
```

2. Ejecutá el pipeline completo e inspeccioná el artefacto:

```bash
make clean && make ci
ls -l dist/
cat dist/*.sha256
```

Esperado (la cadena de versión depende de tus tags y commits):

```
-rw-r--r--. 1 you you 2381 Sep 18 11:04 hello-ci-v1.0.0-2-g9c1f4ab.tar.gz
-rw-r--r--. 1 you you   99 Sep 18 11:04 hello-ci-v1.0.0-2-g9c1f4ab.tar.gz.sha256
9f0c...e31  hello-ci-v1.0.0-2-g9c1f4ab.tar.gz
```

3. Demostrá que el pipeline falla ruidosamente. Agregá un import muerto al principio de `cli.py`:

```python
import os
```

```bash
make lint ; echo "exit status: $?"
```

Esperado:

```
.venv/bin/ruff check --output-format=concise .
cli.py:3:8: F401 [*] `os` imported but unused
Found 1 error.
[*] 1 fixable with the `--fix` option.
make: *** [Makefile:20: lint] Error 1
exit status: 2
```

4. Ahora cometé el error clásico — capturar el log con un pipe:

```bash
make ci | tee build.log ; echo "exit status: $?"
```

Esperado:

```
...
make: *** [Makefile:20: lint] Error 1
exit status: 0
```

5. Corregí la invocación de dos maneras distintas y compará:

```bash
set -o pipefail; make ci | tee build.log ; echo "pipefail: $?"; set +o pipefail
make ci 2>&1 | tee build.log ; echo "PIPESTATUS[0]: ${PIPESTATUS[0]}"
```

Esperado: `pipefail: 2` y `PIPESTATUS[0]: 2`.

6. Quitá el import muerto, confirmá el verde y commiteá el pipeline:

```bash
sed -i '/^import os$/d' cli.py
make ci
git add -A
git commit -m "build: pipeline as a Makefile with lint, test and package stages"
```

**Preguntas**

- **Q2.1** Explicá cada flag en `.SHELLFLAGS := -eu -o pipefail -c`, y decí qué hace `make` por defecto con cada línea de receta que hace necesario `-e` acá.
- **Q2.2** En el paso 4 el build falló pero la shell reportó `0`. Explicá exactamente de quién era el exit status que viste, y por qué un job de CI escrito así reporta verde para siempre.
- **Q2.3** `ci: lint test package` fija el orden lint → test → package. Justificá ese orden con dos argumentos independientes: costo y significado.
- **Q2.4** `VERSION` sale de `git describe --tags --always --dirty`. ¿Qué le dice el sufijo `-dirty` a una persona que encuentre este tarball en producción seis meses después, y por qué un simple número de build incremental no alcanza por sí solo?

---

## Ejercicio 3 — Un servidor de CI mínimo: la compuerta pre-receive

**Por qué importa.** Antes de poder evaluar Jenkins o GitLab CI, conviene saber qué están automatizando. Un servidor de CI es, en su núcleo, una máquina que recibe un cambio propuesto, lo materializa en un directorio limpio, corre el build e informa un veredicto. Veinte líneas de shell hacen eso — los productos agregan planificación, aislamiento, historial y reportes.

1. Creá el repositorio bare "central" y empujá hacia él:

```bash
git init --bare ~/cicd-lab/app.git
cd ~/cicd-lab/hello-ci
git remote add origin ~/cicd-lab/app.git
git push -u origin main
```

2. Instalá la compuerta como `~/cicd-lab/app.git/hooks/pre-receive`:

```bash
#!/usr/bin/env bash
# Reject any push to main whose tree does not pass the repository's own pipeline.
set -euo pipefail

ZERO='0000000000000000000000000000000000000000'

while read -r _oldrev newrev refname; do
    [ "$refname" = 'refs/heads/main' ] || continue
    [ "$newrev" = "$ZERO" ] && continue

    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT

    # The pushed objects are visible here through the quarantine directory.
    git archive "$newrev" | tar -x -C "$work"

    echo "remote CI: building ${newrev:0:8} in $work"
    if ! env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
             -u GIT_QUARANTINE_PATH -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
             make -C "$work" ci >"$work/ci.log" 2>&1; then
        echo "remote CI: FAILED for ${newrev:0:8}" >&2
        sed 's/^/remote CI |  /' "$work/ci.log" >&2
        exit 1
    fi
    echo "remote CI: PASSED for ${newrev:0:8}"
done
```

```bash
chmod +x ~/cicd-lab/app.git/hooks/pre-receive
```

3. Empujá un cambio que debería ser rechazado:

```bash
cd ~/cicd-lab/hello-ci
sed -i '2i import os' cli.py
git commit -am "chore: add an unused import"
git push origin main
```

Esperado (abreviado):

```
remote: remote CI: building 4b7d90ac in /tmp/tmp.q0Xk2n
remote: remote CI: FAILED for 4b7d90ac
remote: remote CI |  cli.py:2:8: F401 [*] `os` imported but unused
remote: remote CI |  Found 1 error.
remote: remote CI |  make: *** [Makefile:20: lint] Error 1
To /home/you/cicd-lab/app.git
 ! [remote rejected] main -> main (pre-receive hook declined)
error: failed to push some refs to '/home/you/cicd-lab/app.git'
```

4. Confirmá que el tronco nunca fue tocado, después reparalo y empujá de nuevo:

```bash
git --git-dir=$HOME/cicd-lab/app.git log --oneline -1
sed -i '/^import os$/d' cli.py
git commit -am "chore: drop the unused import"
git push origin main
```

Esperado: el repo bare sigue apuntando al commit anterior en el primer comando, y el segundo push imprime `remote CI: PASSED`.

**Preguntas**

- **Q3.1** Compará `pre-receive`, `update` y `post-receive`. ¿Cuál de los tres puede *rechazar* un push, cuál corre una vez por ref empujada, y cuál usarías para notificar a un canal de chat?
- **Q3.2** El hook ejecuta `make` a través de `env -u GIT_DIR …`. ¿Qué sale mal concretamente si `GIT_DIR` queda exportado dentro del build?
- **Q3.3** Esta compuerta es del lado del servidor. Un hook `pre-commit` en el clon de cada desarrollador correría los mismos chequeos antes. Dá la razón decisiva por la cual el chequeo del lado del servidor es el que define el nivel de calidad.
- **Q3.4** El push bloquea hasta que termina el build. Nombrá dos formas en que esto se rompe con 60 ingenieros y un build de 20 minutos, y nombrá el mecanismo que usan en su lugar las plataformas reales (GitLab y GitHub tienen cada uno un nombre para él).

---

## Ejercicio 4 — Jenkins: un pipeline declarativo

**Por qué importa.** Jenkins es el sistema de CI de referencia en los objetivos de 701. Los conceptos que tenés que poder nombrar — job, número de build, workspace, agente, stage, artefacto, plugin, pipeline-as-code — aparecen todos en un único `Jenkinsfile` declarativo.

1. Arrancá Jenkins y leé el secreto de desbloqueo:

```bash
docker volume create jenkins_home
docker run -d --name jenkins \
  -p 8080:8080 -p 50000:50000 \
  -v jenkins_home:/var/jenkins_home \
  -v "$HOME/cicd-lab/app.git:/srv/app.git:ro" \
  jenkins/jenkins:lts-jdk21

docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
```

2. Abrí <http://localhost:8080>, pegá el secreto, elegí **Install suggested plugins** (esto instala Pipeline, Git, JUnit y Timestamper), y creá el usuario administrador.

3. La imagen del controlador no tiene Python. Instalá el runtime del build *una vez*, y después fijate por qué esto es un olor a problema:

```bash
docker exec -u root jenkins bash -c \
  'apt-get update -qq && apt-get install -y -qq python3 python3-venv make >/dev/null && echo ok'
docker exec -u root jenkins git config --system --add safe.directory /srv/app.git
```

**Q4.1** — respondé antes de continuar.

4. Agregá el `Jenkinsfile` a la raíz del repositorio:

```groovy
pipeline {
    agent any

    options {
        timestamps()
        timeout(time: 15, unit: 'MINUTES')
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '5'))
    }

    environment {
        PIP_DISABLE_PIP_VERSION_CHECK = '1'
    }

    stages {
        stage('Identify') {
            steps {
                script {
                    env.SHORT_SHA = sh(
                        script: 'git rev-parse --short HEAD',
                        returnStdout: true
                    ).trim()
                    env.APP_VERSION = "${env.BUILD_NUMBER}-${env.SHORT_SHA}"
                    currentBuild.displayName = "#${env.BUILD_NUMBER} ${env.SHORT_SHA}"
                }
                sh 'git --no-pager log -1 --oneline'
            }
        }

        stage('Static analysis') {
            steps {
                sh 'make lint'
            }
        }

        stage('Unit tests') {
            steps {
                sh 'make test'
            }
            post {
                always {
                    junit testResults: 'reports/junit.xml', allowEmptyResults: false
                }
            }
        }

        stage('Package') {
            steps {
                sh 'make package VERSION=${APP_VERSION}'
                archiveArtifacts artifacts: 'dist/*', fingerprint: true
            }
        }
    }

    post {
        failure {
            echo "Build ${env.BUILD_NUMBER} failed - console at ${env.BUILD_URL}console"
        }
        cleanup {
            deleteDir()
        }
    }
}
```

```bash
git add Jenkinsfile
git commit -m "ci: declarative Jenkins pipeline"
git push origin main
```

5. Creá el job: **New Item** → nombre `hello-ci` → **Pipeline** → OK. En la configuración:
   - **Build Triggers** → tildá *Trigger builds remotely (e.g., from scripts)* → Authentication Token: `lab-token`
   - **Pipeline** → Definition: *Pipeline script from SCM* → SCM: *Git* → Repository URL: `file:///srv/app.git` → Branch Specifier: `*/main` → Script Path: `Jenkinsfile`
   - Guardá, y después **Build Now**.

6. Observá la ejecución: la **Stage View** muestra una columna por `stage`, **Console Output** muestra cada paso `sh` con un timestamp como prefijo, y la página del build muestra **Last Successful Artifacts** más **Test Result: 4 tests (±0)**.

7. Inspeccioná el workspace y el archivo desde la línea de comandos:

```bash
docker exec jenkins ls /var/jenkins_home/workspace/hello-ci
docker exec jenkins ls /var/jenkins_home/jobs/hello-ci/builds/1/archive/dist
```

Esperado: el workspace está vacío (`post { cleanup { deleteDir() } }` lo borró) mientras que el archivo todavía contiene `hello-ci-1-9c1f4ab.tar.gz` y su `.sha256`.

**Q4.2, Q4.3** — respondé antes de continuar.

8. Cerrá el ciclo: hacé que el push dispare el build. Creá un token de API (tu usuario → **Security** → **API Token** → *Add new Token*), exportalo y probá:

```bash
export JENKINS_TOKEN='paste-the-api-token'
curl -sS -o /dev/null -w '%{http_code}\n' -X POST \
  -u "admin:${JENKINS_TOKEN}" \
  'http://localhost:8080/job/hello-ci/build?token=lab-token'
```

Esperado: `201`.

9. Agregá el disparador al hook **`post-receive`** del repo bare — la notificación va *después* de que el cambio fue aceptado, no antes:

```bash
cat > ~/cicd-lab/app.git/hooks/post-receive <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
curl -fsS -o /dev/null -X POST \
    -u "admin:${JENKINS_TOKEN:?JENKINS_TOKEN is not set}" \
    'http://localhost:8080/job/hello-ci/build?token=lab-token' \
  && echo "remote: Jenkins build queued"
EOF
chmod +x ~/cicd-lab/app.git/hooks/post-receive
```

10. Empujá un cambio trivial y confirmá que aparece un nuevo número de build:

```bash
cd ~/cicd-lab/hello-ci
git commit --allow-empty -m "chore: trigger the pipeline"
git push origin main
curl -sS -u "admin:${JENKINS_TOKEN}" \
  'http://localhost:8080/job/hello-ci/lastBuild/api/json?tree=number,result' 
```

Esperado:

```
remote: remote CI: PASSED for 1d3f77a2
remote: Jenkins build queued
{"_class":"org.jenkinsci.plugins.workflow.job.WorkflowRun","number":2,"result":"SUCCESS"}
```

**Preguntas**

- **Q4.1** Instalaste Python en el controlador de Jenkins para que los builds funcionaran. Nombrá dos problemas concretos que esto crea en una instalación real, y nombrá los dos mecanismos que Jenkins ofrece en su lugar.
- **Q4.2** El paso `junit` está dentro de `post { always { … } }` en vez de en `steps`. Explicá qué se perdería si solo corriera en caso de éxito.
- **Q4.3** `archiveArtifacts` usa `fingerprint: true`. ¿Qué pregunta te permite responder después un fingerprint que un archivo simplemente archivado no puede?
- **Q4.4** Un atajo común es `-v /var/run/docker.sock:/var/run/docker.sock` para que los pipelines puedan construir imágenes. Decí con precisión qué privilegio le otorga eso a cualquiera que pueda modificar un `Jenkinsfile`.
- **Q4.5** El paso 8 se autentica con un token de API en lugar de la contraseña de la cuenta, y envía `POST` sin obtener un crumb CSRF. Explicá por qué ambas cosas son correctas.
- **Q4.6** `buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '5'))` conserva 20 registros de build pero solo 5 conjuntos de artefactos. ¿Por qué esos dos números son distintos?

---

## Ejercicio 5 — Construir una vez, promover muchas: artefactos y el registry

**Por qué importa.** La regla más importante de la entrega continua es que el artefacto probado en staging debe ser *bit por bit* el artefacto liberado a producción. Reconstruir por entorno vuelve a tirar los dados en silencio sobre cada dependencia.

1. Agregá el servicio HTTP que desplegarán los ejercicios posteriores — `serve.py`:

```python
"""Minimal HTTP service: reports its own version and greets."""

import os
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

from greeter import greet

VERSION = os.environ.get("APP_VERSION", "dev")
SHOUT = os.environ.get("FEATURE_SHOUT", "0") == "1"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/healthz":
            body = b"ok\n"
        elif url.path == "/greet":
            name = parse_qs(url.query).get("name", ["world"])[0]
            text = greet(name)
            body = f"{text.upper() if SHOUT else text}\n".encode()
        else:
            body = f"{VERSION}\n".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        return


if __name__ == "__main__":
    HTTPServer(("", 8000), Handler).serve_forever()
```

2. Agregá el `Dockerfile`:

```dockerfile
FROM python:3.12-slim

ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION} \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY greeter.py cli.py serve.py ./

USER 65534:65534
EXPOSE 8000
HEALTHCHECK --interval=5s --timeout=2s --retries=3 \
  CMD python3 -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8000/healthz')"
CMD ["python3", "serve.py"]
```

```bash
make ci
git add -A && git commit -m "feat: HTTP service and container image" && git push origin main
```

3. Arrancá un registry local — el repositorio de artefactos para imágenes:

```bash
docker run -d --name registry -p 5000:5000 registry:2
curl -s http://localhost:5000/v2/_catalog
```

Esperado: `{"repositories":[]}`

4. Construí la imagen **una sola vez**, etiquetada con la identidad inmutable del commit, y empujala:

```bash
cd ~/cicd-lab/hello-ci
SHA=$(git rev-parse --short HEAD)
docker build --build-arg "APP_VERSION=1.0.0-${SHA}" -t "localhost:5000/hello-ci:${SHA}" .
docker push "localhost:5000/hello-ci:${SHA}"
```

5. Registrá el digest — la única referencia verdaderamente inmutable:

```bash
DIGEST=$(docker image inspect --format '{{index .RepoDigests 0}}' "localhost:5000/hello-ci:${SHA}" | cut -d@ -f2)
echo "$DIGEST"
```

Esperado:

```
sha256:7d4c0c0a5f3d3b1a8c2e4f6b9a0d1e2c3f4a5b6c7d8e9f0a1b2c3d4e5f60718
```

6. Promoví los *mismos bytes* a través de los entornos etiquetando, nunca reconstruyendo:

```bash
docker tag "localhost:5000/hello-ci:${SHA}" localhost:5000/hello-ci:staging
docker push localhost:5000/hello-ci:staging
docker tag "localhost:5000/hello-ci:${SHA}" localhost:5000/hello-ci:1.0.0
docker push localhost:5000/hello-ci:1.0.0
curl -s http://localhost:5000/v2/hello-ci/tags/list
```

Esperado:

```
{"name":"hello-ci","tags":["1.0.0","9c1f4ab","staging"]}
```

7. Demostrá que la promoción no movió bytes — los tres tags resuelven a un único digest:

```bash
for tag in "$SHA" staging 1.0.0; do
  printf '%-10s ' "$tag"
  curl -sI -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
       "http://localhost:5000/v2/hello-ci/manifests/${tag}" \
    | awk '/[Dd]ocker-[Cc]ontent-[Dd]igest/ {print $2}'
done
```

Esperado: el mismo `sha256:…` impreso tres veces.

8. Desplegá por digest y confirmá la versión en ejecución:

```bash
docker run -d --name hello-probe -p 8001:8000 "localhost:5000/hello-ci@${DIGEST}"
curl -s http://localhost:8001/
curl -s "http://localhost:8001/greet?name=ada"
docker rm -f hello-probe
```

Esperado:

```
1.0.0-9c1f4ab
Hello, ada!
```

**Preguntas**

- **Q5.1** `:staging` y `sha256:7d4c…` identifican ambos una imagen hoy. ¿Cuál puede cambiar de significado mañana sin que nadie edite un manifiesto de despliegue, y cuál es la consecuencia operativa?
- **Q5.2** Un colega propone correr `docker build` de nuevo en el job de despliegue a producción "para que producción reciba una imagen fresca". Dá dos razones independientes por las que esto derrota la entrega continua.
- **Q5.3** ¿Por qué `image: myapp:latest` en un manifiesto de producción es un antipatrón, incluso cuando la imagen es la correcta en el momento en que desplegás?
- **Q5.4** Además de la imagen o el tarball en sí, nombrá tres cosas que un repositorio de artefactos maduro guarda junto a ellos, y para qué sirve cada una.
- **Q5.5** El build #412 probado en staging se promueve a producción dos semanas después, pero la política de retención del registry borra los manifiestos sin tag después de 7 días. ¿Qué puede salir mal, y cuál es el arreglo?

---

## Ejercicio 6 — El mismo pipeline como YAML declarativo (GitLab CI)

**Por qué importa.** Jenkins expresa un pipeline como un programa Groovy; GitLab CI, GitHub Actions y Travis CI lo expresan como YAML declarativo consumido por un *runner*. Los objetivos exigen que sepas leer ambos. Este ejercicio también ejercita las trampas de YAML que producen silenciosamente un job que hace algo distinto de lo que escribiste.

1. Creá `.gitlab-ci.yml` en la raíz del repositorio:

```yaml
stages:
  - lint
  - test
  - build
  - deploy

default:
  image: python:3.12-slim
  before_script:
    - python3 -m venv .venv
    - .venv/bin/pip install --quiet --requirement requirements-dev.txt

variables:
  PIP_CACHE_DIR: "$CI_PROJECT_DIR/.cache/pip"
  IMAGE_TAG: "$CI_REGISTRY_IMAGE:$CI_COMMIT_SHORT_SHA"

cache:
  key:
    files:
      - requirements-dev.txt
  paths:
    - .cache/pip

static-analysis:
  stage: lint
  script:
    - .venv/bin/ruff check --output-format=concise .

unit-tests:
  stage: test
  script:
    - mkdir -p reports
    - .venv/bin/pytest -q --junitxml=reports/junit.xml
  artifacts:
    when: always
    expire_in: 1 week
    reports:
      junit: reports/junit.xml

build-image:
  stage: build
  image: docker:27-cli
  services:
    - docker:27-dind
  before_script: []
  needs:
    - static-analysis
    - unit-tests
  script:
    - 'echo "Building: $IMAGE_TAG"'
    - docker login -u "$CI_REGISTRY_USER" -p "$CI_REGISTRY_PASSWORD" "$CI_REGISTRY"
    - docker build --build-arg "APP_VERSION=$CI_COMMIT_SHORT_SHA" -t "$IMAGE_TAG" .
    - docker push "$IMAGE_TAG"

deploy-staging:
  stage: deploy
  image: docker:27-cli
  before_script: []
  needs:
    - build-image
  environment:
    name: staging
    url: "https://staging.example.com"
  rules:
    - if: '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'
  script:
    - ./deploy.sh staging "$IMAGE_TAG"

deploy-production:
  stage: deploy
  image: docker:27-cli
  before_script: []
  needs:
    - deploy-staging
  environment:
    name: production
    url: "https://app.example.com"
  rules:
    - if: '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'
      when: manual
      allow_failure: false
  script:
    - ./deploy.sh production "$IMAGE_TAG"
```

2. Validá que el archivo sea YAML bien formado antes de empujarlo siquiera:

```bash
.venv/bin/python3 -c "import yaml,sys;d=yaml.safe_load(open('.gitlab-ci.yml'));print(sorted(d))" \
  2>/dev/null || python3 -c "import json;print('install pyyaml: .venv/bin/pip install pyyaml')"
```

Esperado:

```
['build-image', 'cache', 'default', 'deploy-production', 'deploy-staging', 'stages', 'static-analysis', 'unit-tests', 'variables']
```

3. Ahora reproducí la trampa que evita el entrecomillado del paso 1. Creá un archivo de borrador `/tmp/trap.yml`:

```yaml
script:
  - echo "Building: $IMAGE_TAG"
```

```bash
python3 -c "import yaml,pprint;pprint.pprint(yaml.safe_load(open('/tmp/trap.yml')))"
```

Esperado:

```
{'script': [{'echo "Building': '$IMAGE_TAG"'}]}
```

**Q6.1** — respondé antes de continuar.

4. Inspeccioná cuál es la *forma* del pipeline, independientemente de GitLab, listando el stage y las dependencias de cada job:

```bash
python3 - <<'PY'
import yaml
doc = yaml.safe_load(open('.gitlab-ci.yml'))
skip = {'stages', 'default', 'variables', 'cache'}
for name, job in doc.items():
    if name in skip:
        continue
    print(f"{name:20} stage={job['stage']:6} needs={job.get('needs', '-')}")
PY
```

Esperado:

```
static-analysis      stage=lint   needs=-
unit-tests           stage=test   needs=-
build-image          stage=build  needs=['static-analysis', 'unit-tests']
deploy-staging       stage=deploy needs=['build-image']
deploy-production    stage=deploy needs=['deploy-staging']
```

5. Commiteálo:

```bash
git add .gitlab-ci.yml
git commit -m "ci: GitLab CI equivalent of the Jenkins pipeline"
git push origin main
```

**Preguntas**

- **Q6.1** Explicá qué le hizo YAML a `- echo "Building: $IMAGE_TAG"` y por qué. Enunciá la regla en una oración, y dá las dos formas seguras de escribir esa línea.
- **Q6.2** `cache:` contiene `.cache/pip`; `artifacts:` contiene `reports/junit.xml`. Definí la diferencia en propósito y en tiempo de vida, y decí qué le pasa a un pipeline que es *correcto solo porque* la caché estaba caliente.
- **Q6.3** `build-image` declara tanto `stage: build` como `needs:`. ¿Qué cambia `needs:` respecto de cuándo arranca el job, y cuál es el riesgo de abusar de él?
- **Q6.4** `deploy-production` lleva `when: manual` y `allow_failure: false`. ¿Cuál de las tres prácticas (CI / entrega continua / despliegue continuo) implementa esta configuración, y qué única edición la convertiría en la tercera?
- **Q6.5** `$CI_REGISTRY_PASSWORD` nunca aparece en el repositorio. ¿De dónde lo obtiene el runner, qué le hace la plataforma en los logs del job, y por qué `echo "$CI_REGISTRY_PASSWORD" | base64` sigue siendo una fuga?
- **Q6.6** `build-image` sobrescribe `before_script: []`. ¿Qué pasaría sin esa línea, dado el bloque `default:`?

---

## Ejercicio 7 — Estrategias de despliegue: rolling, blue/green, canary y el flag

**Por qué importa.** La entrega termina donde empieza el release. El artefacto es inmutable; la *estrategia* decide cuánto de tu tráfico se encuentra con una nueva versión, a qué velocidad, y con qué rapidez podés dar marcha atrás.

1. Construí y publicá una segunda versión para tener algo que liberar:

```bash
cd ~/cicd-lab/hello-ci
docker build --build-arg APP_VERSION=1.0.0 -t localhost:5000/hello-ci:1.0.0 .
docker build --build-arg APP_VERSION=2.0.0 -t localhost:5000/hello-ci:2.0.0 .
docker push localhost:5000/hello-ci:1.0.0
docker push localhost:5000/hello-ci:2.0.0
```

2. Creá una red y arrancá **blue** (la versión en curso) y **green** (la candidata):

```bash
docker network create release-lab
docker run -d --name hello-blue  --network release-lab localhost:5000/hello-ci:1.0.0
docker run -d --name hello-green --network release-lab \
  -e FEATURE_SHOUT=0 localhost:5000/hello-ci:2.0.0
```

3. Escribí la configuración del router. `~/cicd-lab/nginx/blue.conf`:

```nginx
upstream app {
    server hello-blue:8000 max_fails=3 fail_timeout=10s;
}

server {
    listen 8000;

    location / {
        proxy_pass http://app;
        proxy_set_header Host $host;
        proxy_next_upstream error timeout http_502 http_503;
    }
}
```

`~/cicd-lab/nginx/green.conf` — idéntico, con `hello-green:8000` como único `server`.

`~/cicd-lab/nginx/canary.conf`:

```nginx
upstream app {
    server hello-blue:8000  weight=9 max_fails=3 fail_timeout=10s;
    server hello-green:8000 weight=1 max_fails=3 fail_timeout=10s;
}

server {
    listen 8000;

    location / {
        proxy_pass http://app;
        proxy_set_header Host $host;
        proxy_next_upstream error timeout http_502 http_503;
    }
}
```

4. Arrancá el router sobre blue y medí la línea base:

```bash
mkdir -p ~/cicd-lab/nginx/active
cp ~/cicd-lab/nginx/blue.conf ~/cicd-lab/nginx/active/default.conf
docker run -d --name router --network release-lab -p 8088:8000 \
  -v "$HOME/cicd-lab/nginx/active:/etc/nginx/conf.d:ro" nginx:1.27-alpine

for i in $(seq 1 100); do curl -s http://localhost:8088/; done | sort | uniq -c
```

Esperado:

```
    100 1.0.0
```

5. **Canary.** Desviá el 10 % del tráfico a la candidata y medí:

```bash
cp ~/cicd-lab/nginx/canary.conf ~/cicd-lab/nginx/active/default.conf
docker exec router nginx -s reload
for i in $(seq 1 100); do curl -s http://localhost:8088/; done | sort | uniq -c
```

Esperado:

```
     90 1.0.0
     10 2.0.0
```

**Q7.1** — respondé antes de continuar.

6. **Blue/green.** Cambiá por completo, verificá, después revertí y verificá de nuevo — midiendo el tiempo de ambos:

```bash
cp ~/cicd-lab/nginx/green.conf ~/cicd-lab/nginx/active/default.conf
time docker exec router nginx -s reload
for i in $(seq 1 20); do curl -s http://localhost:8088/; done | sort | uniq -c

cp ~/cicd-lab/nginx/blue.conf ~/cicd-lab/nginx/active/default.conf
time docker exec router nginx -s reload
for i in $(seq 1 20); do curl -s http://localhost:8088/; done | sort | uniq -c
```

Esperado: `20 2.0.0`, después `20 1.0.0`, cada recarga bastante por debajo de un segundo.

7. **La falla que el router absorbe.** Volvé a canary, matá la candidata y observá:

```bash
cp ~/cicd-lab/nginx/canary.conf ~/cicd-lab/nginx/active/default.conf
docker exec router nginx -s reload
docker stop hello-green
for i in $(seq 1 100); do curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8088/; done \
  | sort | uniq -c
docker start hello-green
```

Esperado:

```
    100 200
```

**Q7.2** — respondé antes de continuar.

8. **Desacoplar deploy de release.** La candidata ya está desplegada; activá su comportamiento sin desplegar nada:

```bash
cp ~/cicd-lab/nginx/green.conf ~/cicd-lab/nginx/active/default.conf
docker exec router nginx -s reload
curl -s "http://localhost:8088/greet?name=ada"

docker rm -f hello-green
docker run -d --name hello-green --network release-lab \
  -e FEATURE_SHOUT=1 localhost:5000/hello-ci:2.0.0
sleep 1
curl -s "http://localhost:8088/greet?name=ada"
```

Esperado:

```
Hello, ada!
HELLO, ADA!
```

**Preguntas**

- **Q7.1** El canary sirvió el 10 % de las peticiones. ¿Qué hace que un canary release sea *útil* en lugar de simplemente "una caída más lenta", y qué debe existir antes de iniciar uno?
- **Q7.2** Con `hello-green` detenido, cada petición siguió devolviendo 200. Nombrá las dos directivas de nginx responsables, y explicá por qué apoyarse solo en ellas no es una estrategia de health checking.
- **Q7.3** Blue/green te dio un rollback de menos de un segundo. Nombrá sus dos costos permanentes, y describí el problema específico que aparece cuando la versión 2.0.0 requiere un cambio de esquema de base de datos — incluyendo el patrón que lo resuelve.
- **Q7.4** Un `Deployment` de Kubernetes con `strategy.rollingUpdate.maxSurge: 1` y `maxUnavailable: 0` reemplaza pods gradualmente. Compará su latencia de rollback con la de blue/green, y decí qué propiedad lo convierte en el valor por defecto para servicios sin estado.
- **Q7.5** En el paso 8 el binario nunca cambió; solo cambió una variable de entorno. Explicá qué significa operativamente "deploy no es release", y nombrá un costo serio a largo plazo de los feature flags.
- **Q7.6** Ordená rolling, blue/green y canary de más barato a más caro en infraestructura, y por separado de más rápido a más lento en rollback. Explicá por qué los dos ordenamientos difieren.

---

## Limpieza

```bash
docker rm -f router hello-blue hello-green registry jenkins 2>/dev/null
docker network rm release-lab 2>/dev/null
docker volume rm jenkins_home 2>/dev/null
rm -rf ~/cicd-lab
```

---

## Fuentes

- LPI, *Exam 701 Objectives (DevOps Tools Engineer, version 2.0)* — <https://www.lpi.org/our-certifications/exam-701-objectives/>
- Jenkins, *Pipeline Syntax* — <https://www.jenkins.io/doc/book/pipeline/syntax/>
- Jenkins, *Installing Jenkins with Docker* — <https://www.jenkins.io/doc/book/installing/docker/>
- Jenkins, *Remote access API and CSRF protection* — <https://www.jenkins.io/doc/book/security/csrf-protection/>
- GitLab, *CI/CD YAML syntax reference* — <https://docs.gitlab.com/ee/ci/yaml/>
- GitLab, *Environments and deployments* — <https://docs.gitlab.com/ee/ci/environments/>
- GitLab, *Caching in CI/CD* — <https://docs.gitlab.com/ee/ci/caching/>
- Git, *githooks(5)* — <https://git-scm.com/docs/githooks>
- Git, *git-receive-pack, quarantine environment* — <https://git-scm.com/docs/git-receive-pack>
- Docker, *Dockerfile reference* — <https://docs.docker.com/reference/dockerfile/>
- CNCF Distribution, *Registry HTTP API V2* — <https://distribution.github.io/distribution/spec/api/>
- nginx, *ngx_http_upstream_module* — <https://nginx.org/en/docs/http/ngx_http_upstream_module.html>
- Kubernetes, *Performing a rolling update* — <https://kubernetes.io/docs/concepts/workloads/controllers/deployment/>
- pytest, *Creating JUnit XML files* — <https://docs.pytest.org/en/stable/how-to/output.html>
- GNU Make, *Choosing the shell* — <https://www.gnu.org/software/make/manual/make.html#Choosing-the-Shell>

---

<details>
<summary><strong>Respuestas</strong> — abrir solo después de intentar todas las preguntas</summary>

### Ejercicio 0

**A0.1** Un pin exacto hace que el build sea *determinista*: el mismo commit produce el mismo veredicto de lint y los mismos resultados de tests hoy y dentro de un año. Sin él, una nueva versión de `ruff` que agrega una regla pone en rojo un commit antes verde sin ningún cambio en tu código — el pipeline deja de ser una afirmación sobre tu software y pasa a ser una afirmación sobre internet esa mañana. La obligación que crea es la de hacer actualizaciones deliberadas y planificadas (Renovate/Dependabot, o un bump manual), lo cual es una ventaja: la actualización llega como su propio commit revisable con su propia ejecución de pipeline, en vez de emboscar a un cambio no relacionado.

**A0.2** La definición de "correcto" viviría fuera del control de versiones. Tres consecuencias: los desarrolladores obtienen resultados distintos a los del servidor de CI, con lo cual "funciona en mi máquina" se vuelve estructuralmente cierto; un cambio en las reglas es invisible para la revisión de código y no se puede bisectar; y un cambio de reglas en el servidor de CI invalida retroactivamente todos los builds pasados. La configuración que decide pasa/falla es parte del código fuente.

**A0.3** El control de versiones guarda *fuentes* — todo lo que escribe una persona, de lo cual se deriva el build. Los repositorios de artefactos guardan *derivaciones* — todo lo que produce el build, direccionado por una identidad (versión, commit, digest) que lo vincula de vuelta con las fuentes. Commitear `dist/` infla el historial, invita conflictos de merge sobre binarios y crea dos fuentes de verdad sobre qué es "el build".

### Ejercicio 1

**A1.1** Git fusiona *texto*: las dos ramas editaron archivos distintos, así que no hubo solapamiento textual ni nada sobre lo que entrar en conflicto. La incompatibilidad es *semántica* — una rama cambió el contrato de una función mientras la otra agregaba un llamador que dependía del contrato viejo. Esto es un **conflicto semántico** (o *conflicto lógico*), y es exactamente la clase de falla para cuya detección existe la integración continua, porque solo construir y probar el estado fusionado puede revelarlo.

**A1.2** Un **test de integración** — uno que ejercite el CLI a través de su punto de entrada real, de modo que el acoplamiento entre `cli.py` y `greeter.py` forme parte de lo que se afirma. Ningún test unitario de `greet()` podría haberlo detectado: los tests unitarios verifican un componente contra su contrato *actual*, y `greet(name, lang)` satisface sus propios tests a la perfección. El defecto vive en la costura entre componentes, que por definición queda fuera del alcance de cualquier unidad individual.

**A1.3** Tres semanas de divergencia multiplican tanto la probabilidad como el costo. Probabilidad: cada commit adicional de cualquiera de los dos lados es otra oportunidad de cambiar un contrato compartido. Costo: cuando la rotura finalmente aparece, hay que razonar sobre cientos de cambios a la vez, los autores ya perdieron el contexto, y la fusión fallida bloquea también a todos los demás. Por eso CI prescribe integrar al tronco al menos una vez por día (desarrollo basado en tronco): no porque fusionar a diario sea agradable, sino porque mantiene cada fusión lo bastante pequeña como para que el cambio culpable sea obvio y el arreglo barato. Las ramas de vida larga no evitan el dolor de la integración — lo posponen y lo componen.

**A1.4** El principio es la **compatibilidad hacia atrás en el límite de la API**: cuando extendés un contrato, extendelo de forma aditiva para que los llamadores existentes sigan funcionando — los parámetros nuevos llevan valores por defecto, el comportamiento nuevo es opcional. Sería la elección equivocada cuando el valor por defecto es una *respuesta silenciosamente incorrecta* en vez de una segura: si `lang` genuinamente no tiene un valor por defecto sensato para tus usuarios, poner `"en"` por defecto entrega una salida incorrecta en lugar de un error. Ahí lo correcto es la migración explícita: cambiar todos los llamadores en el mismo commit, o versionar la API y deprecar según un cronograma.

**A1.5** Las tres comparten el mismo pipeline; difieren en dónde se requiere la acción de una persona.

- **Integración Continua** — cada cambio se fusiona al tronco compartido con frecuencia y se construye y prueba automáticamente. La decisión humana es *qué fusionar*; todo lo posterior a la fusión es automático hasta llegar a un build verificado.
- **Entrega Continua** — el pipeline se extiende hasta un artefacto desplegable y promovido entre entornos, y cada build que pasa es *liberable en cualquier momento*. Una persona aprieta el botón para liberar a producción; el pipeline garantiza que el botón siempre funcione.
- **Despliegue Continuo** — el mismo pipeline sin el botón: cada cambio que pasa todas las compuertas va a producción automáticamente. La decisión humana se movió enteramente aguas arriba, a las compuertas mismas.

### Ejercicio 2

**A2.1** `-e` aborta la línea de receta ante el primer comando que falla; `-u` convierte una variable no definida en un error en vez de una cadena vacía; `-o pipefail` hace que un pipeline devuelva el estado del comando *que falla más a la derecha* en lugar de solo el último; `-c` le dice a la shell que el argumento siguiente es el comando a ejecutar (Make lo requiere). `-e` importa acá porque Make invoca una *shell nueva por cada línea de receta*, y por defecto una línea con varios comandos como `cd dist && cmd1; cmd2` seguiría adelante tras el fallo de `cmd1` y reportaría el éxito de `cmd2`.

**A2.2** `$?` después de un pipeline es el exit status del **último** comando del mismo — `tee`, que escribió el log con éxito. El fallo de `make` se descartó. Un job de CI cuyo script sea `make ci | tee build.log`, o `./build.sh | grep -v DEBUG`, reporta verde sin importar lo que haya hecho el build; el job "pasa" y se promueven artefactos rotos. Arreglos: `set -o pipefail` antes del pipeline, o chequear `${PIPESTATUS[0]}` explícitamente, o no usar un pipe en absoluto y dejar que el sistema de CI capture el log (cosa que ya hace).

**A2.3** *Costo:* el lint tarda milisegundos, los tests tardan segundos, el empaquetado es lo que más tarda y más E/S necesita. Ejecutar primero lo más barato significa que los fallos más comunes se reportan más rápido y que las etapas caras nunca corren para código que nunca iba a llegar a producción — esto es **fail fast**. *Significado:* la salida de cada etapa solo es confiable si la anterior pasó. Empaquetar código que falla sus tests produce un artefacto garantizadamente roto; lo único peor que no tener artefacto es tener uno malo pero de aspecto plausible sentado en el registry.

**A2.4** `-dirty` significa que el tarball se construyó desde un árbol de trabajo con **cambios sin commitear** — el código que contiene no existe en ningún commit, así que no puede reproducirse, revisarse ni bisectarse. Encontrar ese sufijo en un artefacto de producción significa que alguien construyó desde una laptop, y perdiste la trazabilidad. Un número de build por sí solo no alcanza porque es un contador local de un servidor de CI: no sobrevive a ninguna migración, colisiona tras reconstruir el servidor, y responde "¿qué build?" pero nunca "¿qué *fuente*?" — el SHA del commit es el único identificador que ata el artefacto de vuelta a un estado revisable y reproducible. En la práctica querés ambos: el SHA para la identidad, el número de build para el orden.

### Ejercicio 3

**A3.1** `pre-receive` corre **una vez por push**, recibe todas las actualizaciones de refs por stdin, y una salida distinta de cero **rechaza el push entero de forma atómica**. `update` corre **una vez por ref** y puede rechazar esa ref individualmente (las otras igual entran). `post-receive` corre una vez por push **después** de que las refs fueron actualizadas; su exit status se ignora, así que no puede rechazar nada — es el lugar correcto para notificaciones: mensajes de chat, disparos de CI, actualizaciones de tickets, pushes a mirrors.

**A3.2** Los hooks de git corren con `GIT_DIR` apuntando al repositorio bare. Cualquier comando `git` dentro del build — el `git describe` de `VERSION` en el Makefile, un test que invoque git, una herramienta que detecte la raíz del proyecto — operaría entonces sobre el repo *bare* en vez de sobre el árbol de trabajo exportado en `$work`. Concretamente, `git describe --dirty` reportaría el estado del repo bare, y el tarball quedaría estampado con la versión equivocada. `GIT_INDEX_FILE` y las variables de cuarentena causan fallas igual de confusas. La regla general: limpiá el entorno de git antes de entregar el control a cualquier cosa que no sea el hook en sí.

**A3.3** Los hooks del lado del cliente son **consultivos**: viven en `.git/hooks`, no se clonan con el repositorio y se eluden trivialmente con `git commit --no-verify`. Un desarrollador que nunca los instala es invisible. El chequeo del lado del servidor es el único **ineludible y uniforme**, así que es él — y no el hook local — el que realmente define el nivel de calidad. Los hooks del lado del cliente siguen siendo valiosos como ciclo rápido de retroalimentación, pero como optimización, nunca como compuerta.

**A3.4** (1) **Serialización y latencia:** la terminal de quien empuja queda bloqueada 20 minutos, y los pushes concurrentes o se encolan unos detrás de otros o corren en paralelo y agotan la CPU del servidor git — un servidor git no es una granja de builds. (2) **Unidad de revisión equivocada:** el chequeo corre sobre código ya escrito y ya empujado, sin lugar donde discutirlo, sin artefacto que conservar y sin historial del resultado; un fallo simplemente se imprime en una terminal y desaparece. Las plataformas reales ponen la compuerta en la *fusión propuesta*, de forma asíncrona: GitLab lo llama **merge trains** (con pipelines de merge request y "los pipelines deben tener éxito"), GitHub lo llama **required status checks** sobre una rama protegida (con merge queues). El cambio se prueba contra el tronco del que va a formar parte, los resultados quedan registrados, y la terminal de nadie queda de rehén.

**A3.5** Cuando `git receive-pack` acepta un push, escribe los objetos entrantes en un directorio temporal de **cuarentena** en lugar de directamente en el almacén de objetos, y lo expone al hook `pre-receive` (vía `GIT_QUARANTINE_PATH`) para que el hook pueda leer los objetos propuestos — por eso funciona `git archive "$newrev"`. Si el hook rechaza el push, el directorio de cuarentena simplemente se descarta y el repositorio nunca queda contaminado con objetos de un cambio rechazado.

### Ejercicio 4

**A4.1** Problemas: (1) **El controlador ahora tiene estado y no es reproducible** — el cambio vive solo en un volumen, se perderá en la próxima actualización de imagen y es invisible para cualquiera que lea tu configuración; un segundo controlador no se comportará igual. (2) **Los builds corren como el propio proceso del controlador, sobre el sistema de archivos del controlador**, así que cualquier `Jenkinsfile` puede leer credenciales, `config.xml`, los workspaces de otros jobs y la clave secreta de Jenkins — un build no es un sandbox, y en un controlador compartido eso es un compromiso total. Además acopla cada job a las versiones de herramientas de una sola máquina, así que dos proyectos no pueden usar versiones distintas de Python. Jenkins ofrece en su lugar: **agentes** (`agent { label 'python' }`) — máquinas o contenedores separados que ejecutan los builds mientras el controlador solo planifica; y **entornos de build en contenedores** (`agent { docker { image 'python:3.12-slim' } }` o el plugin de Kubernetes) donde cada build obtiene un entorno fresco, declarado y descartable.

**A4.2** Los resultados de tests son más valiosos precisamente cuando el build falla — esa es la ejecución para la que necesitás el reporte. `sh 'make test'` devuelve distinto de cero ante un test fallido, lo que aborta la etapa; si `junit` fuera una entrada `steps` posterior, o viviera en `post { success }`, nunca se ejecutaría exactamente en esas ejecuciones, y la página del build mostraría "no test results" para cada fallo. `post { always }` garantiza que el reporte se recolecte independientemente del resultado, que es también la forma en que Jenkins puede marcar el build como `UNSTABLE` (amarillo) ante un test fallido frente a `FAILURE` (rojo) ante un error de infraestructura.

**A4.3** Un fingerprint es el MD5 del archivo archivado, registrado contra el build que lo produjo. Permite responder **"¿a qué otros lugares fue este archivo exacto?"** — Jenkins puede mostrar entonces qué otros jobs lo consumieron y qué builds lo usaron, de modo que dado un artefacto malo encontrado en producción podés rastrearlo hacia atrás hasta el build que lo produjo y hacia adelante hasta cada consumidor aguas abajo. Un archivo simplemente archivado no tiene tal índice: sabés que un build produjo *un* archivo con ese nombre, no si los bytes en producción son los mismos bytes.

**A4.4** Otorga **root sin restricciones sobre el host Docker**. La API de Docker no tiene separación de privilegios significativa: cualquiera que pueda hablar con el socket puede correr `docker run -v /:/host --privileged`, leer cada archivo del host incluyendo el almacén de credenciales de Jenkins y las claves SSH del host, y arrancar contenedores como root. Dado que un `Jenkinsfile` no es más que un archivo en un repositorio, esto significa que **cualquiera que pueda abrir un pull request que dispare un build puede volverse root en tu host de CI**. Las mitigaciones son herramientas de build sin root que no necesitan el daemon (Kaniko, Buildah, BuildKit en modo rootless), un nodo de build separado cuyo compromiso quede contenido, o un builder BuildKit remoto con un endpoint autenticado.

**A4.5** Usar un **token de API** significa que la contraseña de la cuenta nunca se envía, nunca se almacena en el script del hook, y puede revocarse individualmente sin cambiar la contraseña ni romper otras integraciones — y está acotado al usuario, así que su uso es atribuible. El **crumb CSRF** no hace falta porque la protección CSRF defiende contra un navegador al que se engaña para enviar una petición autenticada usando su cookie de sesión ambiente; una petición autenticada por un token de API no lleva credencial ambiente y no puede falsificarse de esa manera, así que Jenkins exime a las peticiones con token de API del requisito del crumb. Los POST interactivos con cookie de sesión siguen necesitando el crumb.

**A4.6** Los registros de build son pequeños (un `config.xml`, un log, resultados de tests) y son la *historia* — querés muchos para ver tendencias, encontrar cuándo empezó a fallar un test y correlacionar con commits. Los artefactos son grandes (tarballs, imágenes, paquetes de cobertura) y consumen disco linealmente; conservar 20 conjuntos costaría cuatro veces el espacio con casi ningún beneficio, porque un artefacto viejo rara vez se vuelve a desplegar y, si se hiciera, pertenece a un repositorio de artefactos con retención adecuada en vez de al controlador de CI. Separar los dos números mantiene barato el historial largo.

### Ejercicio 5

**A5.1** `:staging` es un **puntero mutable** — el siguiente push a ese tag lo reapunta en silencio, así que un manifiesto que diga `image: hello-ci:staging` despliega bytes distintos mañana sin ningún cambio en git y sin rastro de auditoría. `sha256:7d4c…` está **direccionado por contenido**: *es* el hash del manifiesto, así que no puede referirse a contenido distinto, nunca. La consecuencia operativa de la forma mutable: un reinicio de pod, un evento de autoescalado o el reemplazo de un nodo pueden descargar una imagen distinta de la que están corriendo sus pares, dándote un clúster que está simultáneamente en dos versiones sin ningún despliegue registrado — y un "rollback" que restaura el manifiesto no restaura nada.

**A5.2** (1) **Ya no es el artefacto probado.** Las imágenes base se mueven, los mirrors de paquetes se actualizan, las dependencias transitivas resuelven distinto; la imagen de producción contiene código que nadie probó. Cada compuerta que pasaste era sobre un binario diferente. (2) **Destruye la trazabilidad y el rollback.** Con un solo build hay un único digest que enlaza commit → artefacto → entorno; con builds por entorno hay tres digests para un commit y ninguna forma de decir qué corrió realmente producción. La regla es **construir una vez, promover muchas**: el pipeline produce exactamente un artefacto, y la promoción mueve una *referencia*, no bytes.

**A5.3** Porque el manifiesto no registra *qué* desplegó, solo una intención. Cualquier descarga posterior — un pod reprogramado, una réplica escalada, el reinicio de un nodo, `imagePullPolicy: Always` — resuelve `latest` a lo que sea que signifique en ese momento, que puede ser una imagen más nueva y no probada. Obtenés releases que nadie realizó, versiones que no podés nombrar durante un incidente, y un rollback que no hace nada porque el manifiesto no cambió. Un digest (o como mínimo un tag de versión inmutable y nunca reutilizado) convierte la versión desplegada en un hecho y no en una suposición.

**A5.4** Tres cualesquiera de: **checksums** (`.sha256`) para que un consumidor pueda detectar corrupción o sustitución; **firmas criptográficas** (cosign/Sigstore, GPG) para que un consumidor pueda verificar *quién* lo produjo y rechazar lo que no esté firmado; un **SBOM** que liste cada componente y versión, de modo que cuando aparece un CVE podés consultar qué artefactos contienen la biblioteca vulnerable en vez de reconstruir para averiguarlo; **procedencia/atestaciones del build** (SLSA) que registren el commit, el constructor y los parámetros; y **metadatos/etiquetas** — SHA del commit, URL del build, timestamp del build — que permiten a quien tenga el artefacto volver caminando hasta su ejecución de pipeline.

**A5.5** La promoción por re-etiquetado deja el manifiesto *original* alcanzable solo a través del digest; si una política de limpieza borra los manifiestos sin tag, el artefacto que validaste se recolecta como basura y la promoción falla — o peor, alguien lo "arregla" reconstruyendo desde el mismo commit, lo que produce bytes distintos y anula silenciosamente la validación de staging. Los arreglos: mantener un tag inmutable y nunca borrado por build (`:1.0.0-9c1f4ab`) para que el manifiesto esté siempre referenciado; configurar la retención para proteger cualquier cosa referenciada por un entorno desplegado; y hacer que las ventanas de retención sean más largas que tu mayor demora realista de promoción.

### Ejercicio 7

*(Las respuestas del Ejercicio 6 siguen más abajo — están agrupadas después de estas por legibilidad.)*

### Ejercicio 6

**A6.1** YAML vio `: ` (dos puntos **seguidos de un espacio**) dentro de un escalar plano sin comillas y leyó la línea como un **mapeo**, produciendo `{'echo "Building': '$IMAGE_TAG"'}` en lugar de la cadena que querías. El runner recibe entonces un diccionario donde espera un comando — o bien un error duro de validación o, en el peor caso, un job que ejecuta algo que no escribiste. La regla: **en un escalar YAML plano (sin comillas), `: ` inicia un mapeo, así que todo valor que contenga dos-puntos-espacio debe ir entrecomillado.** Las dos formas seguras: envolver el ítem entero en comillas simples — `- 'echo "Building: $IMAGE_TAG"'` — o usar un escalar de bloque:

```yaml
script:
  - |
    echo "Building: $IMAGE_TAG"
```

(La misma familia de trampas: un valor que empieza con `*` se lee como un alias y debe entrecomillarse — `- "*.example.com"` — y una clave debe ir seguida de un espacio: `secret: value`, nunca `secret:value`.)

**A6.2** Los **artifacts** son *salidas*: archivos que produce un job y que deben sobrevivirlo — reportes de tests, paquetes, cobertura. Se suben al servidor, se pasan a jobs posteriores, se muestran en la UI y expiran según una política (`expire_in`). Borrarlos pierde evidencia pero nunca cambia un resultado. La **cache** es una *optimización*: entradas reutilizables (wheels descargadas, `node_modules`) restauradas para que la siguiente ejecución sea más rápida. Es de mejor esfuerzo y puede estar ausente, fría o compartida entre ramas. Un pipeline que es correcto solo porque la caché estaba caliente está **roto**: significa que una dependencia la provee la caché en vez de estar declarada, así que la primera ejecución en un runner nuevo — o la primera tras una expulsión de caché, típicamente un viernes de release — falla. La prueba es simple: un pipeline debe pasar con la caché vacía.

**A6.3** Por defecto un job espera a **todos** los jobs de todas las etapas precedentes. `needs:` reemplaza eso con una dependencia explícita, así que `build-image` arranca en cuanto `static-analysis` y `unit-tests` están ambos terminados, convirtiendo el pipeline de una secuencia de barreras en un **DAG** y recortando tiempo de reloj. El riesgo de abusar: las etapas llevan una garantía implícita de "todo lo anterior a esto pasó" que documenta la intención y protege contra errores de orden; reemplazarla con aristas escritas a mano significa que una arista olvidada permite que un job de despliegue arranque sobre un artefacto no validado, y el grafo se vuelve algo sobre lo que solo su autor puede razonar. Usá `needs:` donde el paralelismo valga minutos reales, no en todos lados.

**A6.4** Esto es **entrega continua**: cada commit a la rama por defecto se construye, prueba, publica y despliega a staging automáticamente, de modo que es *demostrablemente liberable*, pero producción requiere que una persona apriete el botón de play. `allow_failure: false` hace que el job manual sea bloqueante, así que el pipeline no se reporta exitoso hasta que alguien decide. Quitar `when: manual` (dejando `rules: - if: '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'`) hace automático el despliegue a producción en cada commit verde — eso es **despliegue continuo**. Notá la diferencia de una sola línea: las dos prácticas son la misma maquinaria, y elegir entre ellas es una decisión de riesgo, no técnica.

**A6.5** `$CI_REGISTRY_PASSWORD` es una **variable predefinida de CI/CD** inyectada en el entorno del job por la plataforma (la configuración de CI/CD del proyecto o grupo provee las definidas por el usuario; los sistemas de producción las obtienen de un gestor de secretos como Vault o el del proveedor cloud, a través de una identidad federada por OIDC, de modo que no se almacena nada de larga duración). La plataforma **enmascara** los valores en los logs del job, reemplazándolos por `[MASKED]`. Ese enmascarado es una **coincidencia literal de cadena sobre la salida**, así que cualquier transformación lo derrota: `base64`, un echo parcial, `set -x` imprimiendo una URL construida, `env` volcando el entorno, o el secreto terminando dentro de un artefacto o en un mensaje de error de una herramienta. El enmascarado es una red de seguridad contra un `echo` accidental, no un límite de seguridad — el límite son credenciales de vida corta y de mínimo privilegio que resultan inútiles para quien lea el log.

**A6.6** `default: before_script:` aplica a todo job que no lo sobrescriba, así que sin `before_script: []` el job `build-image` correría `python3 -m venv .venv` dentro de `docker:27-cli` — una imagen Alpine sin Python — y fallaría en la preparación con `python3: not found`, antes de que el build siquiera empezara. Ponerlo en lista vacía hace que el job se excluya explícitamente del valor por defecto heredado. Este es el peligro general de los bloques `default:`: son invisibles en el punto de uso, así que un job que cambia `image:` también debe revisar todo lo que hereda en silencio.

### Ejercicio 7 (respuestas)

**A7.1** Un canary solo es útil si estás **midiendo el canary por separado y podés actuar sobre la medición automáticamente**. Servir el 10 % del tráfico a una versión nueva no te dice nada a menos que la tasa de errores, los percentiles de latencia, la saturación y las métricas de negocio clave estén desglosadas *por versión*, comparadas contra la línea base y conectadas a un aborto automático. Prerrequisitos: etiquetado por versión en métricas y logs; un criterio de éxito definido y una ventana de observación acordados **antes** del release (p. ej., "tasa de 5xx ≤ línea base + 0,1 % durante 15 minutos"); suficiente tráfico para que la muestra sea estadísticamente significativa; y un rollback que sea una sola acción. Sin eso, un canary es simplemente una caída que afecta al 10 % de los usuarios, descubierta a la misma velocidad que cualquier otra — y a menudo más lento, porque los tableros agregados siguen viéndose bien.

**A7.2** `max_fails=3 fail_timeout=10s` marcan un upstream como no disponible tras 3 intentos fallidos dentro de 10 s, y `proxy_next_upstream error timeout http_502 http_503` reintenta la petición en el otro upstream. Juntos convirtieron un backend muerto en respuestas 200. Esto es health checking **pasivo**: descubre la falla solo sacrificando peticiones de usuarios reales, no puede detectar un backend que devuelve 200 estando roto (una dependencia caída, una caché envenenada, una cola atascada), y nunca marca un backend recuperado como sano salvo intentando de nuevo. Una estrategia real agrega chequeos de salud **activos** contra un `/healthz` significativo — y distingue *liveness* (¿debería ser reiniciado?) de *readiness* (¿debería recibir tráfico?), para que una instancia que está arrancando o degradada se saque del pool antes de que los usuarios la encuentren.

**A7.3** Costos permanentes: (1) **el doble de infraestructura** para el servicio y todo aquello de lo que depende, de forma permanente, dado que el color inactivo debe poder tomar el 100 % del tráfico al instante; (2) **el doble de superficie operativa** — dos entornos que parchear, configurar, monitorear y mantener idénticos, y la deriva entre ellos es el incidente clásico de blue/green. Con un cambio de esquema el problema es que **ambos colores comparten una sola base de datos**, así que el esquema debe satisfacer simultáneamente al código viejo y al nuevo — y un rollback instantáneo del código no revierte una migración que ya corrió. El patrón es **expand/contract** (cambio paralelo): *expand* — desplegar una migración compatible hacia atrás que solo agrega (columna nueva anulable, tabla nueva, escrituras duales); *migrate* — liberar código que escribe en ambos y lee del nuevo; *contract* — solo una vez que ya nunca se pueda volver a la versión vieja, eliminar la columna vieja en un release posterior y separado. Cada paso es reversible de forma independiente, que es lo que hace que el rollback rápido sea real y no teórico.

**A7.4** El rollback de una actualización rolling es en sí mismo una actualización rolling: Kubernetes debe planificar, descargar, arrancar y pasar readiness en pods de reemplazo, así que la recuperación tarda lo mismo que el despliegue — minutos, y el clúster queda en estado de versiones mezcladas todo ese tiempo. El rollback de blue/green es un **cambio de ruteo**: la versión vieja ya está corriendo y caliente, así que la recuperación es de segundos y atómica. Lo que hace que rolling sea el valor por defecto para servicios sin estado es que no necesita **capacidad duplicada** (`maxSurge: 1` agrega exactamente un pod extra) manteniendo la disponibilidad en 100 % (`maxUnavailable: 0`), y es una función incorporada de primera clase sin ningún router externo que orquestar. Lo pagás en latencia de rollback y en tener que tolerar dos versiones sirviendo simultáneamente — que es precisamente por qué la compatibilidad de API (A1.4) es un requisito duro para las actualizaciones rolling.

**A7.5** **Deploy** es colocar un artefacto sobre infraestructura; **release** es exponer su comportamiento a los usuarios. Separarlos significa que podés desplegar en cualquier momento, a la luz del día, con el cambio apagado — verificando que arranca, conecta y pasa los chequeos de salud bajo carga real — y después decidir de forma independiente, por segmento de usuarios, cuándo se enciende el comportamiento, con un interruptor de apagado que surte efecto en segundos sin un despliegue. También te da un rollback que no requiere volver a desplegar nada. El costo a largo plazo: **los flags son ramas en producción**. Cada uno duplica los caminos por el código y las combinaciones que hay que probar; se acumulan porque eliminarlos no es prioridad de nadie; los flags obsoletos se vuelven código muerto permanente y sin pruebas, y una fuente real de caídas. Los flags necesitan la misma disciplina que las ramas — un responsable, una fecha de vencimiento y una tarea de limpieza en el mismo backlog que la funcionalidad.

**A7.6** Costo de infraestructura, del más barato primero: **rolling** (un pequeño excedente, p. ej. +1 pod) → **canary** (el subconjunto canary más un router que reparte tráfico y observabilidad por versión) → **blue/green** (un duplicado completo del entorno). Velocidad de rollback, del más rápido primero: **blue/green** (segundos — girar el router hacia un entorno ya caliente) → **canary** (segundos para frenar la hemorragia re-pesando a 0 %, pero el rollout completo igual hay que deshacerlo) → **rolling** (minutos — el rollout inverso debe planificarse y pasar readiness). Los ordenamientos difieren porque **la velocidad de rollback se compra con capacidad ociosa**: blue/green es rápido precisamente *porque* paga por mantener caliente un segundo entorno completo, mientras que rolling es barato precisamente *porque* no tiene nada caliente a lo que recurrir y debe reconstruir el estado viejo. Canary queda entre los dos en ambos ejes, y agrega un tercer costo que los otros no tienen — la observabilidad y la automatización requeridas para que la exposición parcial signifique algo (A7.1).

</details>