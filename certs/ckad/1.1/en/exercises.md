# CKAD v1.35 — Domain 1.1: Define, Build and Modify Container Images

*Reference: CNCF CKAD Curriculum v1.35 — https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf*

These exercises assume a shell with `docker` (or a compatible CLI like `podman`/`nerdctl` — commands are interchangeable unless noted) and a working directory you can write files into.

---

## Exercise 1 — Write and build a minimal Dockerfile

1. Create a working directory and move into it:
   ```bash
   mkdir ckad-image-lab && cd ckad-image-lab
   ```
2. Create a file named `app.py` with the following content:
   ```python
   import http.server
   import socketserver

   PORT = 8080

   class Handler(http.server.SimpleHTTPRequestHandler):
       def do_GET(self):
           self.send_response(200)
           self.end_headers()
           self.wfile.write(b"Hello from CKAD lab\n")

   with socketserver.TCPServer(("", PORT), Handler) as httpd:
       httpd.serve_forever()
   ```
3. Create a file named `Dockerfile` (no extension) with:
   ```dockerfile
   FROM python:3.12-slim
   WORKDIR /app
   COPY app.py .
   EXPOSE 8080
   CMD ["python", "app.py"]
   ```
4. Build the image, tagging it `ckad-lab:v1`:
   ```bash
   docker build -t ckad-lab:v1 .
   ```
5. Confirm the image exists locally:
   ```bash
   docker images | grep ckad-lab
   ```
6. Run a container from it and test it:
   ```bash
   docker run -d --name lab1 -p 8080:8080 ckad-lab:v1
   curl localhost:8080
   ```

**Check your understanding**
- What is the purpose of `WORKDIR` in a Dockerfile, and what happens if you omit it?
- Why does the build fail if `app.py` is not in the same directory as the `Dockerfile` (the *build context*)?

---

## Exercise 2 — Image layers and build cache

1. Add a `requirements.txt` file (empty is fine for now, but simulate a real dependency):
   ```bash
   echo "requests==2.32.3" > requirements.txt
   ```
2. Rewrite the `Dockerfile` to install dependencies **before** copying application code:
   ```dockerfile
   FROM python:3.12-slim
   WORKDIR /app
   COPY requirements.txt .
   RUN pip install --no-cache-dir -r requirements.txt
   COPY app.py .
   EXPOSE 8080
   CMD ["python", "app.py"]
   ```
3. Build it and note the timing:
   ```bash
   time docker build -t ckad-lab:v2 .
   ```
4. Modify only `app.py` (e.g., change the response text to `b"Hello v2\n"`), then rebuild:
   ```bash
   time docker build -t ckad-lab:v2 .
   ```
5. Inspect how many layers the image has and where they came from:
   ```bash
   docker history ckad-lab:v2
   ```

**Check your understanding**
- Why was the second build in step 4 significantly faster than the first?
- If you had instead written `COPY . .` followed by `RUN pip install -r requirements.txt`, what would happen to build speed every time you changed `app.py`, and why?

---

## Exercise 3 — CMD vs ENTRYPOINT, and overriding at runtime

1. Modify the `Dockerfile` to use `ENTRYPOINT` with `CMD` supplying default arguments:
   ```dockerfile
   FROM python:3.12-slim
   WORKDIR /app
   COPY requirements.txt .
   RUN pip install --no-cache-dir -r requirements.txt
   COPY app.py .
   EXPOSE 8080
   ENTRYPOINT ["python"]
   CMD ["app.py"]
   ```
2. Build it as `ckad-lab:v3`:
   ```bash
   docker build -t ckad-lab:v3 .
   ```
3. Run it normally (uses the default `CMD`):
   ```bash
   docker run --rm -d --name lab3 -p 8081:8080 ckad-lab:v3
   curl localhost:8081
   docker stop lab3
   ```
4. Now override just the `CMD` portion at the command line, launching a Python REPL instead:
   ```bash
   docker run --rm -it ckad-lab:v3 -c "print('overridden cmd')"
   ```
5. Try to override the `ENTRYPOINT` itself:
   ```bash
   docker run --rm -it --entrypoint python3 ckad-lab:v3 --version
   ```

**Check your understanding**
- What is the difference between how `docker run <image> <args>` interacts with `CMD` versus `ENTRYPOINT`?
- In a Kubernetes Pod spec, which Dockerfile instruction does `command:` override, and which does `args:` override?

---

## Exercise 4 — Modifying an existing image

1. Start a container from the base image with an interactive shell:
   ```bash
   docker run -it --name modify-me python:3.12-slim bash
   ```
2. Inside the container, install a package and create a marker file, then exit:
   ```bash
   pip install requests
   touch /tmp/modified-marker
   exit
   ```
3. Commit the stopped container's filesystem as a new image (imperative modification):
   ```bash
   docker commit modify-me ckad-lab:committed
   ```
4. Now do the same modification the declarative, reproducible way — extend the base image via a Dockerfile:
   ```dockerfile
   FROM python:3.12-slim
   RUN pip install --no-cache-dir requests \
       && touch /tmp/modified-marker
   ```
5. Build it:
   ```bash
   docker build -t ckad-lab:declarative .
   ```
6. Compare both images' history:
   ```bash
   docker history ckad-lab:committed
   docker history ckad-lab:declarative
   ```

**Check your understanding**
- Why is `docker commit` generally discouraged for producing images used in CI/CD or Kubernetes deployments compared to a Dockerfile build?
- What information does `docker commit` fail to capture that a Dockerfile preserves (hint: think about reproducibility and auditability)?

---

## Exercise 5 — Multi-stage builds

1. Create a Go source file `main.go` (or reuse any compiled-language example) — if Go isn't relevant to you, follow along conceptually:
   ```go
   package main

   import "fmt"

   func main() {
       fmt.Println("Hello from a multi-stage build")
   }
   ```
2. Write a multi-stage `Dockerfile.multistage`:
   ```dockerfile
   FROM golang:1.22 AS builder
   WORKDIR /src
   COPY main.go .
   RUN CGO_ENABLED=0 go build -o app .

   FROM gcr.io/distroless/static-debian12
   COPY --from=builder /src/app /app
   ENTRYPOINT ["/app"]
   ```
3. Build it, naming only the final stage's output:
   ```bash
   docker build -f Dockerfile.multistage -t ckad-lab:multistage .
   ```
4. Compare the final image size against the intermediate builder stage:
   ```bash
   docker images | grep ckad-lab
   docker build -f Dockerfile.multistage --target builder -t ckad-lab:builder-only .
   docker images | grep ckad-lab
   ```
5. Run the final image and confirm it works despite having no shell or package manager:
   ```bash
   docker run --rm ckad-lab:multistage
   ```

**Check your understanding**
- Why is the final image so much smaller than the `builder` stage, given both were built from the same source?
- What CKAD-relevant benefit does a smaller, dependency-free final image give you at deploy time (think image pull time and attack surface)?

---

## Exercise 6 — Metadata, tagging, and pushing to a registry

1. Add labels and environment metadata to your original `Dockerfile`:
   ```dockerfile
   FROM python:3.12-slim
   LABEL maintainer="you@example.com" \
         org.opencontainers.image.source="https://example.com/ckad-lab"
   ENV APP_ENV=production
   WORKDIR /app
   COPY requirements.txt .
   RUN pip install --no-cache-dir -r requirements.txt
   COPY app.py .
   EXPOSE 8080
   CMD ["python", "app.py"]
   ```
2. Build and inspect the labels:
   ```bash
   docker build -t ckad-lab:v4 .
   docker inspect ckad-lab:v4 --format '{{json .Config.Labels}}'
   ```
3. Tag the image for a registry namespace (use a local registry for practice):
   ```bash
   docker run -d -p 5000:5000 --name registry registry:2
   docker tag ckad-lab:v4 localhost:5000/ckad-lab:v4
   ```
4. Push the tagged image:
   ```bash
   docker push localhost:5000/ckad-lab:v4
   ```
5. Remove the local copy and pull it back from the registry to confirm it round-trips:
   ```bash
   docker rmi localhost:5000/ckad-lab:v4
   docker pull localhost:5000/ckad-lab:v4
   ```

**Check your understanding**
- Why must an image be *tagged* with a registry hostname/port before `docker push` will send it anywhere other than the default registry?
- If a Kubernetes Pod references `localhost:5000/ckad-lab:v4` as its image, what must be true about where the kubelet runs relative to that registry for the pull to succeed?

---

<details>
<summary><strong>Answers</strong></summary>

**Exercise 1**
- `WORKDIR` sets (and creates, if needed) the working directory for all subsequent instructions (`COPY`, `RUN`, `CMD`, etc.) and for the container's runtime shell. If omitted, instructions run relative to `/` (or whatever the base image's default working directory is), which makes paths harder to reason about and risks collisions with system directories.
- `COPY` (and `ADD`) can only reference files inside the **build context** (the directory/path passed to `docker build`, here `.`). Docker cannot read files outside that context for security and reproducibility reasons, so a missing `app.py` in the context directory causes a "file not found" build error even if the file exists elsewhere on disk.

**Exercise 2**
- Docker caches each layer keyed by the instruction and its inputs. Since `requirements.txt` didn't change, the `COPY requirements.txt .` and `RUN pip install ...` layers were reused from cache; only the `COPY app.py .` layer (and anything after it) had to be rebuilt, which is fast because it's just a file copy.
- With `COPY . .` before `RUN pip install`, any change to *any* file in the context (including `app.py`) invalidates the `COPY` layer, which cascades and invalidates the `RUN pip install` layer too — forcing a full dependency reinstall on every code change, even though dependencies didn't change.

**Exercise 3**
- `ENTRYPOINT` defines the fixed executable that always runs; `CMD` supplies default *arguments* to that executable. Passing arguments to `docker run <image> <args>` replaces `CMD` entirely but leaves `ENTRYPOINT` untouched — so `docker run ckad-lab:v3 -c "..."` runs `python -c "..."` instead of `python app.py`. To replace the entrypoint itself, you must pass `--entrypoint`.
- In a Pod spec, `command:` overrides the Dockerfile's `ENTRYPOINT`, and `args:` overrides `CMD`. If `command:` is omitted, the image's `ENTRYPOINT` is used with `args:` (or the image's `CMD` if `args:` is also omitted) appended.

**Exercise 4**
- `docker commit` captures only the resulting filesystem state and current metadata as an opaque snapshot — there's no record of *how* that state was produced. This breaks reproducibility (you can't rebuild the same image from source), makes code review of changes impossible, and typically isn't tied to version control, so it's unsuitable for CI/CD pipelines that need auditable, repeatable builds.
- A Dockerfile preserves the exact sequence of build instructions (a build "recipe") that is versionable in git, diffable, and rerunnable to produce a byte-for-byte reproducible result (given pinned base images/dependencies). `docker commit` loses this build history — `docker history` on a committed image typically just shows a single opaque "commit" layer instead of discrete, meaningful steps.

**Exercise 5**
- Multi-stage builds let the `builder` stage carry the full Go toolchain, source code, and build caches, while only the `COPY --from=builder` instruction pulls the single compiled, statically-linked binary into the final stage. The final stage's base (`distroless/static-debian12`) has no compiler, package manager, or shell, so the resulting image contains only the binary plus a minimal OS layer.
- Smaller images pull faster (less network/storage I/O), which speeds up Pod scheduling and scale-up events in Kubernetes. They also carry a smaller attack surface — no shell, package manager, or build tools an attacker could use if the container were compromised, which aligns with CKAD's implicit security-minded image-building expectations.

**Exercise 6**
- Docker's default registry is Docker Hub, and it determines the target registry from the tag's prefix. A bare tag like `ckad-lab:v4` is assumed to belong to Docker Hub (or the configured default registry); prefixing it with a hostname\[:port\] (`localhost:5000/ckad-lab:v4`) tells Docker to push to that specific registry endpoint instead.
- The kubelet on each node that runs the Pod must be able to resolve and reach that registry address over the network. A `localhost:5000` reference only works if the registry is reachable as `localhost` *from the node's perspective* (e.g., running on every node, or via a node-local mirror) — in a real multi-node cluster this typically fails unless you use a properly addressable/exposed registry hostname instead of `localhost`.

</details>