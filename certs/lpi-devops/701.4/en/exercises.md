# 701.4 — Continuous Integration and Continuous Delivery — Guided Exercises

> **Exam context:** LPI DevOps Tools Engineer, exam 701-100, objective 701.4 (weight 5).
> Official objectives: <https://www.lpi.org/our-certifications/exam-701-objectives/>

These exercises build a real delivery pipeline from the bottom up, on one machine: first the manual build, then the pipeline as code, then a server-side gate, then Jenkins, then an artifact registry, then the declarative GitLab CI equivalent, and finally the deployment strategies that turn a built artifact into a release. Nothing is simulated — every command runs.

**Prerequisites**

- Linux with `bash`, `git` ≥ 2.35, `make`, `tar`, `curl`, `python3` ≥ 3.11 (`python3-venv` installed)
- Docker ≥ 24 with a non-root user in the `docker` group, and free ports **8080** (Jenkins), **8088** (nginx), **5000** (registry)
- A `java` runtime (JRE 17+) only for the optional Jenkins CLI steps
- Roughly 3 GB of disk and outbound network for image and package pulls

**Lab layout** — everything lives under `~/cicd-lab`:

```
~/cicd-lab/
├── hello-ci/      working copy (the application)
├── app.git/       bare repo acting as the "central" server
└── nginx/         reverse-proxy configs for the release strategies
```

---

## Exercise 0 — The application under test

**Why this matters.** A pipeline is only as honest as the thing it builds. Before automating anything, you need a repository where the code, its tests, its lint configuration and its build recipe are versioned *together*, so that one commit describes one complete, reproducible state.

1. Create the workspace and initialise the repository:

```bash
mkdir -p ~/cicd-lab/hello-ci && cd ~/cicd-lab/hello-ci
git init -b main
git config user.name  "CI Student"
git config user.email "student@example.com"
```

2. Write the library that the pipeline will build — `greeter.py`:

```python
"""Greeting library - the unit under test."""

DEFAULT_GREETING = "Hello"


def greet(name, greeting=DEFAULT_GREETING):
    """Return a greeting for name."""
    if not name:
        raise ValueError("name must not be empty")
    return f"{greeting}, {name}!"
```

3. Write the entry point — `cli.py`:

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

4. Write the unit tests — `test_greeter.py`:

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

5. Pin the tooling in `requirements-dev.txt` — exact versions, not ranges:

```
pytest==8.3.5
ruff==0.8.4
```

6. Put the static-analysis configuration **in the repository**, not in your shell history — `pyproject.toml`:

```toml
[tool.ruff]
line-length = 100
target-version = "py312"

[tool.ruff.lint]
select = ["E", "F", "W", "I", "B", "UP", "S"]
# S104: the lab server deliberately binds 0.0.0.0 inside a container.
ignore = ["S104"]
```

7. Exclude build output from version control — `.gitignore`:

```
.venv/
dist/
reports/
.pytest_cache/
__pycache__/
*.pyc
```

8. Build the environment by hand once, so you know what the pipeline will be automating:

```bash
python3 -m venv .venv
.venv/bin/pip install --quiet --requirement requirements-dev.txt
.venv/bin/ruff check --output-format=concise .
.venv/bin/pytest -q
```

Expected:

```
All checks passed!
...                                                                      [100%]
3 passed in 0.03s
```

9. Commit the baseline:

```bash
git add -A
git commit -m "feat: greeter library, CLI and unit tests"
git tag -a v1.0.0 -m "first release"
```

**Questions**

- **Q0.1** `requirements-dev.txt` pins `pytest==8.3.5` instead of `pytest>=8`. What class of pipeline failure does the exact pin prevent, and what new maintenance duty does it create?
- **Q0.2** The lint rules live in `pyproject.toml` inside the repo. What breaks if each developer configures `ruff` locally instead, and the CI server has its own defaults?
- **Q0.3** `.venv/` and `dist/` are in `.gitignore`. State the general rule this follows about what belongs in source control versus what belongs in an artifact repository.

---

## Exercise 1 — What "integration" actually means

**Why this matters.** Continuous *Integration* is not "a server that runs tests". It is the practice of merging every developer's work into the shared trunk continuously, precisely because merging is where independently-correct changes become collectively wrong. Git can only resolve *textual* conflicts. This exercise produces a conflict git cannot see.

1. Developer A adds multi-language support, changing the public signature of `greet()`:

```bash
git switch -c feature/greeting-lang
```

Replace `greeter.py` with:

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

Update `test_greeter.py` to match the new signature:

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

2. Verify the branch is green **in isolation** and commit:

```bash
.venv/bin/pytest -q
git commit -am "feat(greeter): select the greeting by language"
```

Expected: `3 passed`.

3. Developer B, meanwhile, branches from the *same* baseline and improves the CLI — a different file:

```bash
git switch main
git switch -c feature/cli-default
```

Append to `cli.py`, inside `main()`, right after `args = parser.parse_args(argv)`:

```python
    if args.name.islower():
        args.name = args.name.capitalize()
```

3 (cont.). Verify and commit:

```bash
.venv/bin/pytest -q
python3 cli.py ada
git commit -am "feat(cli): capitalise a lower-case name"
```

Expected: `3 passed`, then `Hello, Ada!`.

4. Integrate both branches into the trunk and observe the merge result:

```bash
git switch main
git merge --no-edit feature/greeting-lang
git merge --no-edit feature/cli-default
git log --oneline --graph -5
```

**Q1.1** — answer before continuing.

5. Now run the application, and then the test suite:

```bash
python3 cli.py ada
.venv/bin/pytest -q
```

Expected:

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

and:

```
...                                                                      [100%]
3 passed in 0.03s
```

**Questions**

- **Q1.1** `git merge` reported no conflict for either branch, and both branches were green before the merge. Explain in one sentence why the merged trunk is broken anyway, and name this failure class.
- **Q1.2** The test suite passes on the broken trunk. Which *kind* of test was missing — unit, integration or acceptance — and why could no amount of extra unit tests on `greet()` have caught it?
- **Q1.3** Both branches lived for minutes. Argue what would have happened if each had lived three weeks, and connect that to why CI prescribes merging to trunk at least daily.

6. Fix it the way a pipeline teaches you to: **reproduce first**. Add the test that fails, as `test_cli.py`:

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

Expected: `1 failed, 3 passed` — the suite now sees the defect.

7. Make it green by restoring backward compatibility in `greeter.py`:

```python
def greet(name, lang="en"):
```

```bash
.venv/bin/pytest -q
git add -A
git commit -m "fix(greeter): keep greet() callable with one argument"
```

Expected: `4 passed`.

**Questions**

- **Q1.4** You fixed the break with a default argument rather than by editing every caller. State the API-compatibility principle at work, and one case where the default-argument fix would have been the wrong choice.
- **Q1.5** Define Continuous Integration, Continuous Delivery and Continuous Deployment so that the three definitions differ only in *where the human decision sits*.

---

## Exercise 2 — The pipeline as code you can run locally

**Why this matters.** A pipeline that only exists inside a CI server's UI cannot be reviewed, cannot be bisected, and cannot be reproduced on a laptop at 02:00. The build must be a script in the repository; the CI system's only job is to call it on a clean machine.

1. Create the `Makefile`. **The recipe lines must begin with a TAB, not spaces:**

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

2. Run the whole pipeline and inspect the artifact:

```bash
make clean && make ci
ls -l dist/
cat dist/*.sha256
```

Expected (the version string depends on your tags and commits):

```
-rw-r--r--. 1 you you 2381 Sep 18 11:04 hello-ci-v1.0.0-2-g9c1f4ab.tar.gz
-rw-r--r--. 1 you you   99 Sep 18 11:04 hello-ci-v1.0.0-2-g9c1f4ab.tar.gz.sha256
9f0c...e31  hello-ci-v1.0.0-2-g9c1f4ab.tar.gz
```

3. Prove the pipeline fails loudly. Add a dead import at the top of `cli.py`:

```python
import os
```

```bash
make lint ; echo "exit status: $?"
```

Expected:

```
.venv/bin/ruff check --output-format=concise .
cli.py:3:8: F401 [*] `os` imported but unused
Found 1 error.
[*] 1 fixable with the `--fix` option.
make: *** [Makefile:20: lint] Error 1
exit status: 2
```

4. Now make the classic mistake — capture the log with a pipe:

```bash
make ci | tee build.log ; echo "exit status: $?"
```

Expected:

```
...
make: *** [Makefile:20: lint] Error 1
exit status: 0
```

5. Fix the invocation two different ways and compare:

```bash
set -o pipefail; make ci | tee build.log ; echo "pipefail: $?"; set +o pipefail
make ci 2>&1 | tee build.log ; echo "PIPESTATUS[0]: ${PIPESTATUS[0]}"
```

Expected: `pipefail: 2` and `PIPESTATUS[0]: 2`.

6. Remove the dead import, confirm green, and commit the pipeline:

```bash
sed -i '/^import os$/d' cli.py
make ci
git add -A
git commit -m "build: pipeline as a Makefile with lint, test and package stages"
```

**Questions**

- **Q2.1** Explain each flag in `.SHELLFLAGS := -eu -o pipefail -c`, and state what `make` does by default with each recipe line that makes `-e` necessary here.
- **Q2.2** In step 4 the build failed but the shell reported `0`. Explain exactly whose exit status you saw, and why a CI job written that way reports green forever.
- **Q2.3** `ci: lint test package` fixes the order lint → test → package. Justify that order using two independent arguments: cost and meaning.
- **Q2.4** `VERSION` comes from `git describe --tags --always --dirty`. What does the `-dirty` suffix tell a person who finds this tarball in production six months later, and why is a plain incrementing build number insufficient on its own?

---

## Exercise 3 — A minimal CI server: the pre-receive gate

**Why this matters.** Before you can evaluate Jenkins or GitLab CI, you should know what they are automating. A CI server is, at its core, a machine that receives a proposed change, materialises it in a clean directory, runs the build, and reports a verdict. Twenty lines of shell do that — the products add scheduling, isolation, history and reporting.

1. Create the "central" bare repository and push to it:

```bash
git init --bare ~/cicd-lab/app.git
cd ~/cicd-lab/hello-ci
git remote add origin ~/cicd-lab/app.git
git push -u origin main
```

2. Install the gate as `~/cicd-lab/app.git/hooks/pre-receive`:

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

3. Push a change that should be rejected:

```bash
cd ~/cicd-lab/hello-ci
sed -i '2i import os' cli.py
git commit -am "chore: add an unused import"
git push origin main
```

Expected (abridged):

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

4. Confirm the trunk was never touched, then repair and push again:

```bash
git --git-dir=$HOME/cicd-lab/app.git log --oneline -1
sed -i '/^import os$/d' cli.py
git commit -am "chore: drop the unused import"
git push origin main
```

Expected: the bare repo still points at the previous commit in the first command, and the second push prints `remote CI: PASSED`.

**Questions**

- **Q3.1** Compare `pre-receive`, `update` and `post-receive`. Which of the three can *refuse* a push, which runs once per pushed ref, and which one would you use to notify a chat channel?
- **Q3.2** The hook runs `make` through `env -u GIT_DIR …`. What concretely goes wrong if `GIT_DIR` stays exported into the build?
- **Q3.3** This gate is server-side. A `pre-commit` hook in each developer's clone would run the same checks earlier. Give the decisive reason the server-side check is the one that defines the quality bar.
- **Q3.4** The push blocks until the build finishes. Name two ways this breaks down with 60 engineers and a 20-minute build, and name the mechanism real platforms use instead (GitLab and GitHub each have a name for it).

---

## Exercise 4 — Jenkins: a declarative pipeline

**Why this matters.** Jenkins is the reference CI system in the 701 objectives. The concepts you must be able to name — job, build number, workspace, agent, stage, artifact, plugin, pipeline-as-code — all appear in a single declarative `Jenkinsfile`.

1. Start Jenkins and read the unlock secret:

```bash
docker volume create jenkins_home
docker run -d --name jenkins \
  -p 8080:8080 -p 50000:50000 \
  -v jenkins_home:/var/jenkins_home \
  -v "$HOME/cicd-lab/app.git:/srv/app.git:ro" \
  jenkins/jenkins:lts-jdk21

docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
```

2. Open <http://localhost:8080>, paste the secret, choose **Install suggested plugins** (this installs Pipeline, Git, JUnit and Timestamper), and create the admin user.

3. The controller image has no Python. Install the build's runtime *once*, then note why this is a smell:

```bash
docker exec -u root jenkins bash -c \
  'apt-get update -qq && apt-get install -y -qq python3 python3-venv make >/dev/null && echo ok'
docker exec -u root jenkins git config --system --add safe.directory /srv/app.git
```

**Q4.1** — answer before continuing.

4. Add the `Jenkinsfile` to the repository root:

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

5. Create the job: **New Item** → name `hello-ci` → **Pipeline** → OK. In the configuration:
   - **Build Triggers** → tick *Trigger builds remotely (e.g., from scripts)* → Authentication Token: `lab-token`
   - **Pipeline** → Definition: *Pipeline script from SCM* → SCM: *Git* → Repository URL: `file:///srv/app.git` → Branch Specifier: `*/main` → Script Path: `Jenkinsfile`
   - Save, then **Build Now**.

6. Watch the run: the **Stage View** shows one column per `stage`, **Console Output** shows each `sh` step prefixed with a timestamp, and the build page shows **Last Successful Artifacts** plus **Test Result: 4 tests (±0)**.

7. Inspect the workspace and the archive from the command line:

```bash
docker exec jenkins ls /var/jenkins_home/workspace/hello-ci
docker exec jenkins ls /var/jenkins_home/jobs/hello-ci/builds/1/archive/dist
```

Expected: the workspace is empty (`post { cleanup { deleteDir() } }` removed it) while the archive still holds `hello-ci-1-9c1f4ab.tar.gz` and its `.sha256`.

**Q4.2, Q4.3** — answer before continuing.

8. Close the loop: make the push trigger the build. Create an API token (your user → **Security** → **API Token** → *Add new Token*), export it, and test:

```bash
export JENKINS_TOKEN='paste-the-api-token'
curl -sS -o /dev/null -w '%{http_code}\n' -X POST \
  -u "admin:${JENKINS_TOKEN}" \
  'http://localhost:8080/job/hello-ci/build?token=lab-token'
```

Expected: `201`.

9. Append the trigger to the bare repo's **`post-receive`** hook — the notification belongs *after* the change is accepted, not before:

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

10. Push a trivial change and confirm a new build number appears:

```bash
cd ~/cicd-lab/hello-ci
git commit --allow-empty -m "chore: trigger the pipeline"
git push origin main
curl -sS -u "admin:${JENKINS_TOKEN}" \
  'http://localhost:8080/job/hello-ci/lastBuild/api/json?tree=number,result' 
```

Expected:

```
remote: remote CI: PASSED for 1d3f77a2
remote: Jenkins build queued
{"_class":"org.jenkinsci.plugins.workflow.job.WorkflowRun","number":2,"result":"SUCCESS"}
```

**Questions**

- **Q4.1** You installed Python into the Jenkins controller so builds would work. Name two concrete problems this creates in a real installation, and name the two mechanisms Jenkins offers instead.
- **Q4.2** The `junit` step is inside `post { always { … } }` rather than in `steps`. Explain what would be lost if it ran only on success.
- **Q4.3** `archiveArtifacts` uses `fingerprint: true`. What question does a fingerprint let you answer later that a plain archived file cannot?
- **Q4.4** A common shortcut is `-v /var/run/docker.sock:/var/run/docker.sock` so pipelines can build images. State precisely what privilege that grants to anyone who can modify a `Jenkinsfile`.
- **Q4.5** Step 8 authenticates with an API token instead of the account password, and sends `POST` without fetching a CSRF crumb. Explain why both of those are correct.
- **Q4.6** `buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '5'))` keeps 20 build records but only 5 sets of artifacts. Why are those two numbers different?

---

## Exercise 5 — Build once, promote many: artifacts and the registry

**Why this matters.** The single most important rule in continuous delivery is that the artifact tested in staging must be *bit-for-bit* the artifact released to production. Rebuilding per environment silently re-rolls the dice on every dependency.

1. Add the HTTP service the later exercises will deploy — `serve.py`:

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

2. Add the `Dockerfile`:

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

3. Start a local registry — the artifact repository for images:

```bash
docker run -d --name registry -p 5000:5000 registry:2
curl -s http://localhost:5000/v2/_catalog
```

Expected: `{"repositories":[]}`

4. Build the image **once**, tagged with the immutable commit identity, and push it:

```bash
cd ~/cicd-lab/hello-ci
SHA=$(git rev-parse --short HEAD)
docker build --build-arg "APP_VERSION=1.0.0-${SHA}" -t "localhost:5000/hello-ci:${SHA}" .
docker push "localhost:5000/hello-ci:${SHA}"
```

5. Record the digest — the only truly immutable reference:

```bash
DIGEST=$(docker image inspect --format '{{index .RepoDigests 0}}' "localhost:5000/hello-ci:${SHA}" | cut -d@ -f2)
echo "$DIGEST"
```

Expected:

```
sha256:7d4c0c0a5f3d3b1a8c2e4f6b9a0d1e2c3f4a5b6c7d8e9f0a1b2c3d4e5f60718
```

6. Promote the *same bytes* through the environments by tagging, never rebuilding:

```bash
docker tag "localhost:5000/hello-ci:${SHA}" localhost:5000/hello-ci:staging
docker push localhost:5000/hello-ci:staging
docker tag "localhost:5000/hello-ci:${SHA}" localhost:5000/hello-ci:1.0.0
docker push localhost:5000/hello-ci:1.0.0
curl -s http://localhost:5000/v2/hello-ci/tags/list
```

Expected:

```
{"name":"hello-ci","tags":["1.0.0","9c1f4ab","staging"]}
```

7. Prove the promotion moved no bytes — all three tags resolve to one digest:

```bash
for tag in "$SHA" staging 1.0.0; do
  printf '%-10s ' "$tag"
  curl -sI -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
       "http://localhost:5000/v2/hello-ci/manifests/${tag}" \
    | awk '/[Dd]ocker-[Cc]ontent-[Dd]igest/ {print $2}'
done
```

Expected: the same `sha256:…` printed three times.

8. Deploy by digest and confirm the running version:

```bash
docker run -d --name hello-probe -p 8001:8000 "localhost:5000/hello-ci@${DIGEST}"
curl -s http://localhost:8001/
curl -s "http://localhost:8001/greet?name=ada"
docker rm -f hello-probe
```

Expected:

```
1.0.0-9c1f4ab
Hello, ada!
```

**Questions**

- **Q5.1** `:staging` and `sha256:7d4c…` both identify an image today. Which one can change meaning tomorrow without anyone editing a deployment manifest, and what is the operational consequence?
- **Q5.2** A colleague proposes running `docker build` again in the production deploy job "so production gets a fresh image". Give two independent reasons this defeats continuous delivery.
- **Q5.3** Why is `image: myapp:latest` in a production manifest an anti-pattern, even when the image is correct at the moment you deploy it?
- **Q5.4** Besides the image or tarball itself, name three things a mature artifact repository stores alongside it, and what each one is for.
- **Q5.5** Build #412 tested in staging is promoted to production two weeks later, but the registry's retention policy deletes untagged manifests after 7 days. What can go wrong, and what is the fix?

---

## Exercise 6 — The same pipeline as declarative YAML (GitLab CI)

**Why this matters.** Jenkins expresses a pipeline as a Groovy program; GitLab CI, GitHub Actions and Travis CI express it as declarative YAML consumed by a *runner*. The objectives require you to read both. This exercise also drills the YAML traps that silently produce a job doing something other than what you wrote.

1. Create `.gitlab-ci.yml` in the repository root:

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

2. Validate that the file is well-formed YAML before you ever push it:

```bash
.venv/bin/python3 -c "import yaml,sys;d=yaml.safe_load(open('.gitlab-ci.yml'));print(sorted(d))" \
  2>/dev/null || python3 -c "import json;print('install pyyaml: .venv/bin/pip install pyyaml')"
```

Expected:

```
['build-image', 'cache', 'default', 'deploy-production', 'deploy-staging', 'stages', 'static-analysis', 'unit-tests', 'variables']
```

3. Now reproduce the trap the quoting in step 1 avoids. Create a scratch file `/tmp/trap.yml`:

```yaml
script:
  - echo "Building: $IMAGE_TAG"
```

```bash
python3 -c "import yaml,pprint;pprint.pprint(yaml.safe_load(open('/tmp/trap.yml')))"
```

Expected:

```
{'script': [{'echo "Building': '$IMAGE_TAG"'}]}
```

**Q6.1** — answer before continuing.

4. Inspect what the pipeline *shape* is, independent of GitLab, by listing each job's stage and dependencies:

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

Expected:

```
static-analysis      stage=lint   needs=-
unit-tests           stage=test   needs=-
build-image          stage=build  needs=['static-analysis', 'unit-tests']
deploy-staging       stage=deploy needs=['build-image']
deploy-production    stage=deploy needs=['deploy-staging']
```

5. Commit it:

```bash
git add .gitlab-ci.yml
git commit -m "ci: GitLab CI equivalent of the Jenkins pipeline"
git push origin main
```

**Questions**

- **Q6.1** Explain what YAML did to `- echo "Building: $IMAGE_TAG"` and why. State the rule in one sentence, and give the two safe ways to write that line.
- **Q6.2** `cache:` holds `.cache/pip`; `artifacts:` holds `reports/junit.xml`. Define the difference in purpose and in lifetime, and say what happens to a pipeline that is *correct only because* the cache was warm.
- **Q6.3** `build-image` declares both `stage: build` and `needs:`. What does `needs:` change about when the job starts, and what is the risk of over-using it?
- **Q6.4** `deploy-production` carries `when: manual` and `allow_failure: false`. Which of the three practices (CI / continuous delivery / continuous deployment) does this configuration implement, and what single edit would convert it to the third one?
- **Q6.5** `$CI_REGISTRY_PASSWORD` never appears in the repository. Where does the runner get it, what does the platform do to it in job logs, and why is `echo "$CI_REGISTRY_PASSWORD" | base64` still a leak?
- **Q6.6** `build-image` overrides `before_script: []`. What would happen without that line, given the `default:` block?

---

## Exercise 7 — Deployment strategies: rolling, blue/green, canary, and the flag

**Why this matters.** Delivery ends where release begins. The artifact is immutable; the *strategy* decides how much of your traffic meets a new version, how fast, and how quickly you can take it back.

1. Build and publish a second version so there is something to release:

```bash
cd ~/cicd-lab/hello-ci
docker build --build-arg APP_VERSION=1.0.0 -t localhost:5000/hello-ci:1.0.0 .
docker build --build-arg APP_VERSION=2.0.0 -t localhost:5000/hello-ci:2.0.0 .
docker push localhost:5000/hello-ci:1.0.0
docker push localhost:5000/hello-ci:2.0.0
```

2. Create a network and start **blue** (the incumbent) and **green** (the candidate):

```bash
docker network create release-lab
docker run -d --name hello-blue  --network release-lab localhost:5000/hello-ci:1.0.0
docker run -d --name hello-green --network release-lab \
  -e FEATURE_SHOUT=0 localhost:5000/hello-ci:2.0.0
```

3. Write the router configuration. `~/cicd-lab/nginx/blue.conf`:

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

`~/cicd-lab/nginx/green.conf` — identical, with `hello-green:8000` as the single `server`.

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

4. Start the router on blue and measure the baseline:

```bash
mkdir -p ~/cicd-lab/nginx/active
cp ~/cicd-lab/nginx/blue.conf ~/cicd-lab/nginx/active/default.conf
docker run -d --name router --network release-lab -p 8088:8000 \
  -v "$HOME/cicd-lab/nginx/active:/etc/nginx/conf.d:ro" nginx:1.27-alpine

for i in $(seq 1 100); do curl -s http://localhost:8088/; done | sort | uniq -c
```

Expected:

```
    100 1.0.0
```

5. **Canary.** Shift 10 % of traffic to the candidate and measure:

```bash
cp ~/cicd-lab/nginx/canary.conf ~/cicd-lab/nginx/active/default.conf
docker exec router nginx -s reload
for i in $(seq 1 100); do curl -s http://localhost:8088/; done | sort | uniq -c
```

Expected:

```
     90 1.0.0
     10 2.0.0
```

**Q7.1** — answer before continuing.

6. **Blue/green.** Cut over entirely, verify, then roll back and verify again — timing both:

```bash
cp ~/cicd-lab/nginx/green.conf ~/cicd-lab/nginx/active/default.conf
time docker exec router nginx -s reload
for i in $(seq 1 20); do curl -s http://localhost:8088/; done | sort | uniq -c

cp ~/cicd-lab/nginx/blue.conf ~/cicd-lab/nginx/active/default.conf
time docker exec router nginx -s reload
for i in $(seq 1 20); do curl -s http://localhost:8088/; done | sort | uniq -c
```

Expected: `20 2.0.0`, then `20 1.0.0`, each reload well under a second.

7. **The failure the router absorbs.** Return to canary, kill the candidate, and observe:

```bash
cp ~/cicd-lab/nginx/canary.conf ~/cicd-lab/nginx/active/default.conf
docker exec router nginx -s reload
docker stop hello-green
for i in $(seq 1 100); do curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8088/; done \
  | sort | uniq -c
docker start hello-green
```

Expected:

```
    100 200
```

**Q7.2** — answer before continuing.

8. **Decouple deploy from release.** The candidate is already deployed; turn its behaviour on without deploying anything:

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

Expected:

```
Hello, ada!
HELLO, ADA!
```

**Questions**

- **Q7.1** The canary served 10 % of requests. What makes a canary release *useful* rather than merely "a slower outage", and what must exist before you start one?
- **Q7.2** With `hello-green` stopped, every request still returned 200. Name the two nginx directives responsible, and explain why relying on them alone is not a health-checking strategy.
- **Q7.3** Blue/green gave you a sub-second rollback. Name its two standing costs, and describe the specific problem that appears when version 2.0.0 requires a database schema change — including the pattern that solves it.
- **Q7.4** A Kubernetes `Deployment` with `strategy.rollingUpdate.maxSurge: 1` and `maxUnavailable: 0` replaces pods gradually. Compare its rollback latency with blue/green's, and say which property makes it the default for stateless services.
- **Q7.5** In step 8 the binary never changed; only an environment variable did. Explain what "deploy is not release" means operationally, and name one serious long-term cost of feature flags.
- **Q7.6** Order rolling, blue/green and canary from cheapest to most expensive in infrastructure, and separately from fastest to slowest in rollback. Explain why the two orderings differ.

---

## Cleanup

```bash
docker rm -f router hello-blue hello-green registry jenkins 2>/dev/null
docker network rm release-lab 2>/dev/null
docker volume rm jenkins_home 2>/dev/null
rm -rf ~/cicd-lab
```

---

## Sources

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
<summary><strong>Answers</strong> — open only after attempting every question</summary>

### Exercise 0

**A0.1** An exact pin makes the build *deterministic*: the same commit produces the same lint verdict and the same test results today and in a year. Without it, a new `ruff` release that adds a rule turns a previously green commit red with no change to your code — the pipeline stops being a statement about your software and becomes a statement about the internet that morning. The duty it creates is deliberate, scheduled upgrades (Renovate/Dependabot, or a manual bump), which is a feature: the upgrade lands as its own reviewable commit with its own pipeline run, instead of ambushing an unrelated change.

**A0.2** The definition of "correct" would live outside version control. Three consequences: developers get different results from the CI server, so "works on my machine" becomes structurally true; a change to the rules is invisible to code review and cannot be bisected; and a rule change on the CI server retroactively invalidates every past build. Configuration that decides pass/fail is part of the source.

**A0.3** Version control holds *sources* — everything a human authors, from which the build is derived. Artifact repositories hold *derivations* — everything the build produces, addressed by an identity (version, commit, digest) that ties it back to the sources. Committing `dist/` bloats history, invites merge conflicts on binaries, and creates two sources of truth for what "the build" is.

### Exercise 1

**A1.1** Git merges *text*: the two branches edited different files, so there was no textual overlap and nothing to conflict on. The incompatibility is *semantic* — one branch changed a function's contract while the other added a caller relying on the old contract. This is a **semantic conflict** (or *logical conflict*), and it is exactly the failure class continuous integration exists to detect, because only building and testing the merged state can reveal it.

**A1.2** An **integration test** — one that exercises the CLI through its real entry point, so that the binding between `cli.py` and `greeter.py` is part of what is asserted. No unit test of `greet()` could catch it: unit tests verify a component against its *current* contract, and `greet(name, lang)` satisfies its own tests perfectly. The defect lives in the seam between components, which is by definition outside any single unit's scope.

**A1.3** Three weeks of divergence multiplies both the probability and the cost. Probability: every additional commit on either side is another chance to change a shared contract. Cost: when the break finally surfaces, you must reason about hundreds of changes at once, the authors have paged the context out, and the failing merge blocks everyone else too. This is why CI prescribes integrating to trunk at least daily (trunk-based development): not because merging daily is pleasant, but because it keeps each merge small enough that the failing change is obvious and the fix is cheap. Long-lived branches don't avoid integration pain — they postpone and compound it.

**A1.4** The principle is **backward compatibility at the API boundary**: when you extend a contract, extend it additively so existing callers keep working — new parameters get defaults, new behaviour is opt-in. It would be the wrong choice when the default is a *silent wrong answer* rather than a safe one: if `lang` genuinely has no sensible default for your users, defaulting to `"en"` ships incorrect output instead of an error. Then the right move is the explicit migration — change all callers in the same commit, or version the API and deprecate on a schedule.

**A1.5** All three share the same pipeline; they differ in where a human is required to act.

- **Continuous Integration** — every change is merged to the shared trunk frequently and automatically built and tested. The human decision is *what to merge*; everything after the merge is automatic up to a verified build.
- **Continuous Delivery** — the pipeline extends through to a deployable, environment-promoted artifact, and every build that passes is *releasable at any moment*. A human presses the button to release to production; the pipeline guarantees the button always works.
- **Continuous Deployment** — the same pipeline with the button removed: every change that passes every gate goes to production automatically. The human decision has moved entirely upstream, into the gates themselves.

### Exercise 2

**A2.1** `-e` aborts the recipe line on the first failing command; `-u` makes an unset variable an error instead of an empty string; `-o pipefail` makes a pipeline return the status of the *rightmost failing* command instead of only the last; `-c` tells the shell the following argument is the command to run (Make requires it). `-e` matters here because Make invokes a *fresh shell per recipe line*, and by default a multi-command line like `cd dist && cmd1; cmd2` would carry on past `cmd1` failing and report success from `cmd2`.

**A2.2** `$?` after a pipeline is the exit status of the **last** command in it — `tee`, which succeeded at writing the log. `make`'s failure was discarded. A CI job whose script is `make ci | tee build.log`, or `./build.sh | grep -v DEBUG`, therefore reports green no matter what the build did; the job "passes" and broken artifacts get promoted. Fixes: `set -o pipefail` before the pipeline, or check `${PIPESTATUS[0]}` explicitly, or don't pipe at all and let the CI system capture the log (which it already does).

**A2.3** *Cost:* lint takes milliseconds, tests take seconds, packaging takes the longest and needs the most I/O. Running cheapest first means the most common failures are reported fastest and the expensive stages never run for code that was never going to ship — this is **fail fast**. *Meaning:* each stage's output is only trustworthy if the previous one passed. Packaging code that fails its tests produces an artifact that is guaranteed broken; the only thing worse than no artifact is a plausible-looking bad one sitting in the registry.

**A2.4** `-dirty` means the tarball was built from a working tree with **uncommitted changes** — the source it contains does not exist in any commit, so it cannot be reproduced, reviewed or bisected. Finding that suffix on a production artifact means someone built from a laptop, and you have lost traceability. A build number alone is insufficient because it is a counter local to one CI server: it survives no migration, collides after a server rebuild, and answers "which build?" but never "which *source*?" — the commit SHA is the only identifier that ties the artifact back to a reviewable, reproducible state. In practice you want both: the SHA for identity, the build number for ordering.

### Exercise 3

**A3.1** `pre-receive` runs **once per push**, receives all ref updates on stdin, and a non-zero exit **rejects the entire push atomically**. `update` runs **once per ref** and can reject that ref individually (the others still land). `post-receive` runs once per push **after** the refs have been updated; its exit status is ignored, so it cannot refuse anything — it is the correct place for notifications: chat messages, CI triggers, ticket updates, mirror pushes.

**A3.2** Git hooks run with `GIT_DIR` pointing at the bare repository. Any `git` command inside the build — `git describe` in the Makefile's `VERSION`, a test that shells out to git, a tool detecting the project root — would then operate on the *bare* repo rather than on the exported working tree in `$work`. Concretely, `git describe --dirty` would report the bare repo's state, and the tarball would be stamped with the wrong version. `GIT_INDEX_FILE` and the quarantine variables cause equally confusing failures. The general rule: scrub git's environment before handing control to anything that isn't the hook itself.

**A3.3** Client-side hooks are **advisory**: they live in `.git/hooks`, are not cloned with the repository, and are trivially bypassed with `git commit --no-verify`. A developer who never installs them is invisible. The server-side check is the only one that is **unbypassable and uniform**, so it — not the local hook — is what actually defines the quality bar. Client-side hooks remain valuable as a fast feedback loop, but as an optimisation, never as the gate.

**A3.4** (1) **Serialisation and latency:** the pusher's terminal blocks for 20 minutes, and concurrent pushes either queue behind each other or run in parallel and exhaust the git server's CPU — a git server is not a build farm. (2) **Wrong unit of review:** the check runs on code that has already been written and pushed, with no place to discuss it, no artifact to keep, and no history of the result; a failure just prints to a terminal and vanishes. Real platforms gate at the *proposed merge* instead, asynchronously: GitLab calls it **merge trains** (with merge request pipelines and "pipelines must succeed"), GitHub calls it **required status checks** on a protected branch (with merge queues). The change is tested against the trunk it will become part of, results are recorded, and nobody's terminal is held hostage.

**A3.5** When `git receive-pack` accepts a push it writes the incoming objects into a temporary **quarantine** directory rather than directly into the object store, and exposes it to the `pre-receive` hook (via `GIT_QUARANTINE_PATH`) so the hook can read the proposed objects — which is why `git archive "$newrev"` works. If the hook rejects the push, the quarantine directory is simply discarded and the repository is never polluted with objects from a refused change.

### Exercise 4

**A4.1** Problems: (1) **The controller is now stateful and unreproducible** — the change lives only in a volume, will be lost on the next image upgrade, and is invisible to anyone reading your configuration; a second controller will not behave the same. (2) **Builds run as the controller's own process, on the controller's filesystem**, so any `Jenkinsfile` can read credentials, `config.xml`, other jobs' workspaces and the Jenkins secret key — a build is not a sandbox, and on a shared controller that is a full compromise. It also couples every job to one machine's tool versions, so two projects cannot use different Python versions. Jenkins offers instead: **agents** (`agent { label 'python' }`) — separate machines or containers that run builds while the controller only schedules; and **containerised build environments** (`agent { docker { image 'python:3.12-slim' } }` or the Kubernetes plugin) where each build gets a fresh, declared, disposable environment.

**A4.2** Test results are most valuable precisely when the build fails — that is the run you need the report for. `sh 'make test'` returns non-zero on a test failure, which aborts the stage; if `junit` were a subsequent `steps` entry, or lived in `post { success }`, it would never execute on exactly those runs, and the build page would show "no test results" for every failure. `post { always }` guarantees the report is collected regardless of outcome, which is also how Jenkins can mark the build `UNSTABLE` (yellow) for a test failure versus `FAILURE` (red) for an infrastructure error.

**A4.3** A fingerprint is the MD5 of the archived file, recorded against the build that produced it. It lets you answer **"where else did this exact file go?"** — Jenkins can then show which other jobs consumed it and which builds used it, so given a bad artifact found in production you can trace it back to its producing build and forward to every downstream consumer. A plain archived file has no such index: you know a build produced *a* file with that name, not whether the bytes in production are the same bytes.

**A4.4** It grants **unrestricted root on the Docker host**. The Docker API has no meaningful privilege separation: anyone who can talk to the socket can run `docker run -v /:/host --privileged`, read every file on the host including Jenkins' own credential store and the host's SSH keys, and start containers as root. Since a `Jenkinsfile` is just a file in a repository, this means **anyone who can open a pull request that triggers a build can become root on your CI host**. The mitigations are rootless build tools that do not need the daemon (Kaniko, Buildah, BuildKit in rootless mode), a separate build node whose compromise is contained, or a remote BuildKit builder with an authenticated endpoint.

**A4.5** Using an **API token** means the account password is never sent, never stored in the hook script, and can be revoked individually without changing the password or breaking other integrations — and it is scoped to the user, so its use is attributable. The **CSRF crumb** is not needed because CSRF protection defends against a browser being tricked into sending an authenticated request using its ambient session cookie; a request authenticated by an API token carries no ambient credential and cannot be forged that way, so Jenkins exempts API-token requests from the crumb requirement. Interactive session-cookie POSTs still need the crumb.

**A4.6** Build records are small (a `config.xml`, a log, test results) and are the *history* — you want many of them to see trends, find when a test started failing, and correlate with commits. Artifacts are large (tarballs, images, coverage bundles) and consume disk linearly; keeping 20 sets would cost four times the space for almost no benefit, because an old artifact is rarely re-deployed and, if it were, it belongs in an artifact repository with proper retention rather than on the CI controller. Separating the two numbers keeps long history cheap.

### Exercise 5

**A5.1** `:staging` is a **mutable pointer** — the next push to that tag silently repoints it, so a manifest saying `image: hello-ci:staging` deploys different bytes tomorrow with no change in git and no audit trail. `sha256:7d4c…` is **content-addressed**: it *is* the hash of the manifest, so it cannot refer to different content, ever. The operational consequence of the mutable form: a pod restart, an autoscaling event or a node replacement can pull a different image than its siblings are running, giving you a cluster that is simultaneously on two versions with no deploy recorded — and a "rollback" that restores the manifest restores nothing.

**A5.2** (1) **It is no longer the tested artifact.** Base images move, package mirrors update, transitive dependencies resolve differently; the production image contains code nobody tested. Every gate you passed was about a different binary. (2) **It destroys traceability and rollback.** With one build there is one digest linking commit → artifact → environment; with per-environment builds there are three digests for one commit and no way to say what production actually ran. The rule is **build once, promote many**: the pipeline produces exactly one artifact, and promotion moves a *reference*, not bytes.

**A5.3** Because the manifest does not record *what* it deployed, only an intention. Any later pull — a rescheduled pod, a scaled-up replica, a node reboot, `imagePullPolicy: Always` — resolves `latest` to whatever it means at that moment, which may be a newer, untested image. You get releases that nobody performed, versions you cannot name during an incident, and a rollback that is a no-op because the manifest is unchanged. A digest (or at minimum an immutable, never-reused version tag) makes the deployed version a fact rather than a guess.

**A5.4** Any three of: **checksums** (`.sha256`) so a consumer can detect corruption or substitution; **cryptographic signatures** (cosign/Sigstore, GPG) so a consumer can verify *who* produced it and reject anything unsigned; an **SBOM** listing every component and version, so that when a CVE lands you can query which artifacts contain the vulnerable library instead of rebuilding to find out; **build provenance/attestations** (SLSA) recording the commit, builder and parameters; and **metadata/labels** — commit SHA, build URL, build timestamp — that let anyone holding the artifact walk back to its pipeline run.

**A5.5** Promotion by re-tagging leaves the *original* manifest reachable only through the digest; if a cleanup policy deletes untagged manifests, the artifact you validated is garbage-collected and the promotion fails — or worse, someone "fixes" it by rebuilding from the same commit, which produces different bytes and quietly voids the staging validation. The fixes: keep an immutable, never-deleted tag per build (`:1.0.0-9c1f4ab`) so the manifest is always referenced; set retention to protect anything referenced by a deployed environment; and make retention windows longer than your longest realistic promotion lag.

### Exercise 7

*(Exercise 6 answers follow below — they are grouped after these for readability.)*

### Exercise 6

**A6.1** YAML saw `: ` (colon **followed by a space**) inside an unquoted plain scalar and read the line as a **mapping**, producing `{'echo "Building': '$IMAGE_TAG"'}` instead of the string you meant. The runner then receives a dict where it expects a command — either a hard validation error or, in the worst case, a job that executes something you did not write. The rule: **in a plain (unquoted) YAML scalar, `: ` starts a mapping, so any value containing a colon-space must be quoted.** The two safe forms: wrap the whole item in single quotes — `- 'echo "Building: $IMAGE_TAG"'` — or use a block scalar:

```yaml
script:
  - |
    echo "Building: $IMAGE_TAG"
```

(The same family of traps: a value starting with `*` is read as an alias and must be quoted — `- "*.example.com"` — and a key must be followed by a space: `secret: value`, never `secret:value`.)

**A6.2** **Artifacts** are *outputs*: files a job produces that must survive it — test reports, packages, coverage. They are uploaded to the server, passed to later jobs, shown in the UI, and expire on a policy (`expire_in`). Deleting them loses evidence but never changes a result. **Cache** is an *optimisation*: reusable inputs (downloaded wheels, `node_modules`) restored to make the next run faster. It is best-effort and may be absent, cold, or shared across branches. A pipeline that is correct only because the cache was warm is **broken**: it means a dependency is being supplied by the cache rather than declared, so the first run on a fresh runner — or the first run after a cache eviction, typically on a Friday release — fails. The test is simple: a pipeline must pass with an empty cache.

**A6.3** By default a job waits for **every** job in all preceding stages. `needs:` replaces that with an explicit dependency, so `build-image` starts the moment `static-analysis` and `unit-tests` are both done, turning the pipeline from a sequence of barriers into a **DAG** and cutting wall-clock time. The risk of over-use: stages carry an implicit "everything before this has passed" guarantee that documents intent and protects against ordering mistakes; replacing it with hand-written edges means a forgotten edge lets a deploy job start on an unvalidated artifact, and the graph becomes something only its author can reason about. Use `needs:` where the parallelism is worth real minutes, not everywhere.

**A6.4** This is **continuous delivery**: every commit to the default branch is automatically built, tested, published and deployed to staging, so it is *provably releasable*, but production requires a human to press the play button. `allow_failure: false` makes the manual job blocking, so the pipeline is not reported successful until someone decides. Removing `when: manual` (leaving `rules: - if: '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'`) makes production deployment automatic on every green commit — that is **continuous deployment**. Note the single-line difference: the two practices are the same machinery, and choosing between them is a risk decision, not a technical one.

**A6.5** `$CI_REGISTRY_PASSWORD` is a **predefined CI/CD variable** injected into the job's environment by the platform (project/group CI/CD settings supply user-defined ones; production systems fetch them from a secret manager such as Vault or the cloud provider's, through an OIDC-federated identity, so nothing long-lived is stored at all). The platform **masks** values in job logs, replacing them with `[MASKED]`. That masking is a **literal string match on the output**, so any transformation defeats it: `base64`, a partial echo, `set -x` printing a constructed URL, `env` dumping the environment, or the secret ending up inside an artifact or an error message from a tool. Masking is a safety net against accidental `echo`, not a security boundary — the boundary is short-lived, least-privilege credentials that are useless to whoever reads the log.

**A6.6** `default: before_script:` applies to every job that does not override it, so without `before_script: []` the `build-image` job would run `python3 -m venv .venv` inside `docker:27-cli` — an Alpine image with no Python — and fail at setup with `python3: not found`, before the build ever started. Setting it to an empty list explicitly opts the job out of the inherited default. This is the general hazard of `default:` blocks: they are invisible at the point of use, so a job that changes `image:` must also review everything it silently inherits.

### Exercise 7 (answers)

**A7.1** A canary is useful only if you are **measuring the canary separately and can act on the measurement automatically**. Serving 10 % of traffic to a new version tells you nothing unless error rate, latency percentiles, saturation and key business metrics are broken out *per version*, compared against the baseline, and wired to an automatic abort. Prerequisites: per-version labelling in metrics and logs; a defined success criterion and observation window agreed **before** the release (e.g. "5xx rate ≤ baseline + 0.1 % over 15 minutes"); enough traffic for the sample to be statistically meaningful; and a rollback that is one action. Without those, a canary is just an outage affecting 10 % of users, discovered at the same speed as any other — and often slower, because the aggregate dashboards still look fine.

**A7.2** `max_fails=3 fail_timeout=10s` mark an upstream as unavailable after 3 failed attempts within 10 s, and `proxy_next_upstream error timeout http_502 http_503` retries the request on the other upstream. Together they turned a dead backend into 200s. This is **passive** health checking: it discovers failure only by sacrificing real user requests, cannot detect a backend that returns 200 while being broken (a dependency down, a cache poisoned, a queue stalled), and never marks a recovered backend healthy except by trying again. A real strategy adds **active** health checks against a meaningful `/healthz` — and distinguishes *liveness* (should I be restarted?) from *readiness* (should I receive traffic?), so a starting or degraded instance is removed from the pool before users find it.

**A7.3** Standing costs: (1) **double the infrastructure** for the service and everything it depends on, permanently, since the idle colour must be able to take 100 % of traffic instantly; (2) **double the operational surface** — two environments to patch, configure, monitor and keep identical, and drift between them is the classic blue/green incident. With a schema change the problem is that **both colours share one database**, so the schema must satisfy the old and new code simultaneously — and an instant rollback of the code does not roll back a migration that has already run. The pattern is **expand/contract** (parallel change): *expand* — deploy a backward-compatible migration that only adds (new nullable column, new table, dual writes); *migrate* — release code that writes both and reads the new; *contract* — only once the old version can never be rolled back to, remove the old column in a later, separate release. Each step is independently reversible, which is what makes the fast rollback real rather than theoretical.

**A7.4** A rolling update's rollback is itself a rolling update: Kubernetes must schedule, pull, start and pass readiness on replacement pods, so recovery takes as long as the deploy — minutes, and the cluster is in a mixed-version state throughout. Blue/green's rollback is a **routing change**: the old version is already running and warm, so recovery is seconds and atomic. What makes rolling the default for stateless services is that it needs **no duplicate capacity** (`maxSurge: 1` adds exactly one extra pod) while keeping availability at 100 % (`maxUnavailable: 0`), and it is a first-class built-in with no external router to orchestrate. You pay in rollback latency and in having to tolerate two versions serving simultaneously — which is precisely why API compatibility (A1.4) is a hard requirement for rolling updates.

**A7.5** **Deploy** is placing an artifact on infrastructure; **release** is exposing its behaviour to users. Separating them means you can deploy at any time, in daylight, with the change dark — verifying that it starts, connects, and passes health checks under real load — and then decide independently, per user segment, when the behaviour turns on, with an off switch that takes effect in seconds without a deployment. It also gives you rollback that does not require redeploying anything. The long-term cost: **flags are branches in production**. Each one doubles the paths through the code and the combinations you must test; they accumulate because removing them is nobody's priority; stale flags become permanent, untested dead code and a real source of outages. Flags need the same discipline as branches — an owner, an expiry date, and a cleanup task in the same backlog as the feature.

**A7.6** Infrastructure cost, cheapest first: **rolling** (a small surge, e.g. +1 pod) → **canary** (the canary subset plus a traffic-splitting router and per-version observability) → **blue/green** (a full duplicate of the environment). Rollback speed, fastest first: **blue/green** (seconds — flip the router to an already-warm environment) → **canary** (seconds to stop the bleeding by re-weighting to 0 %, but the full rollout still has to be undone) → **rolling** (minutes — the reverse rollout must be scheduled and pass readiness). The orderings differ because **rollback speed is bought with idle capacity**: blue/green is fast precisely *because* it pays to keep a complete second environment warm, while rolling is cheap precisely *because* it has nothing warm to fall back to and must rebuild the old state. Canary sits between the two on both axes, and adds a third cost the others don't have — the observability and automation required to make the partial exposure mean anything (A7.1).

</details>