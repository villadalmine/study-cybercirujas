# Ejercicios guiados — Tema 1.1: Define, build and modify container images

**Certificación:** CKAD (examen CKAD, versión 1.35) · **Peso:** 5
**Fuente de referencia:** [CKAD Curriculum v1.35 (CNCF)](https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf)

> Necesitás un motor de contenedores instalado (`docker` o `podman`; los comandos son intercambiables). Los ejemplos usan `docker`, pero si tenés `podman` podés reemplazar el nombre del comando sin cambiar nada más.

---

## Ejercicio 1 — Escribir un Dockerfile desde cero

Un `Dockerfile` es la receta declarativa que describe cómo construir una imagen: desde qué base parte, qué archivos copia, qué dependencias instala y qué proceso arranca por defecto.

1. Creá un directorio de trabajo y entrá en él:

   ```bash
   mkdir ~/ckad-1.1 && cd ~/ckad-1.1
   ```

2. Creá una app mínima en Python:

   ```bash
   cat > app.py <<'EOF'
   from http.server import BaseHTTPRequestHandler, HTTPServer

   class Handler(BaseHTTPRequestHandler):
       def do_GET(self):
           self.send_response(200)
           self.end_headers()
           self.wfile.write(b"hola desde el contenedor\n")

   HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
   EOF
   ```

3. Escribí el `Dockerfile`:

   ```dockerfile
   FROM python:3.12-slim
   WORKDIR /app
   COPY app.py .
   EXPOSE 8080
   CMD ["python", "app.py"]
   ```

4. Guardalo como `Dockerfile` en el mismo directorio.

**Preguntas de verificación**

- **1.a)** ¿Qué diferencia hay entre la instrucción `FROM` y `WORKDIR`? ¿Qué pasa si omitís `WORKDIR`?
- **1.b)** `CMD` recibe una lista (`["python", "app.py"]`) en vez de una cadena de texto simple. ¿Qué forma es esa y por qué se prefiere sobre `CMD python app.py`?
- **1.c)** `EXPOSE 8080` ¿abre efectivamente el puerto hacia el host? Justificá.

---

## Ejercicio 2 — Construir la imagen y examinar sus capas

Cada instrucción del Dockerfile genera una **capa** (*layer*), y Docker las cachea para acelerar builds sucesivos.

1. Construí la imagen con un tag:

   ```bash
   docker build -t hola-app:v1 .
   ```

2. Listá las imágenes locales y confirmá que aparece:

   ```bash
   docker images hola-app
   ```

3. Inspeccioná el historial de capas:

   ```bash
   docker history hola-app:v1
   ```

4. Mirá los metadatos completos de la imagen (arquitectura, `Cmd`, variables de entorno, capas):

   ```bash
   docker inspect hola-app:v1
   ```

**Preguntas de verificación**

- **2.a)** ¿Qué es el *image ID* (el hash que empieza con `sha256:`) y en qué se diferencia del *tag* `v1`?
- **2.b)** En la salida de `docker history`, ¿qué capa es la más pesada y por qué?
- **2.c)** Si volvés a correr `docker build -t hola-app:v1 .` sin cambiar nada, ¿todas las capas se reconstruyen o Docker reutiliza algo? ¿Cómo lo comprobás en la salida del build?

---

## Ejercicio 3 — Modificar la imagen: orden de capas, ENV y ENTRYPOINT vs CMD

Modificar una imagen no es solo cambiar código: también implica decidir qué capas invalidás y cómo parametrizás el proceso principal.

1. Editá el `Dockerfile` para separar dependencias del código de la app y agregar una variable de entorno configurable:

   ```dockerfile
   FROM python:3.12-slim
   WORKDIR /app
   ENV GREETING="hola desde el contenedor"
   COPY app.py .
   EXPOSE 8080
   ENTRYPOINT ["python", "app.py"]
   ```

2. Reconstruí la imagen con un nuevo tag:

   ```bash
   docker build -t hola-app:v2 .
   ```

3. Corré el contenedor y verificá que responde:

   ```bash
   docker run -d --name hola --rm -p 8080:8080 hola-app:v2
   curl http://localhost:8080
   docker stop hola
   ```

4. Probá sobreescribir el `ENTRYPOINT` para depurar en vez de arrancar el servidor:

   ```bash
   docker run --rm -it --entrypoint /bin/bash hola-app:v2
   ```

   Dentro del contenedor, corré `echo $GREETING` y salí con `exit`.

**Preguntas de verificación**

- **3.a)** ¿Qué diferencia práctica hay entre `ENTRYPOINT` y `CMD`? ¿Qué pasa si un Dockerfile define ambos a la vez?
- **3.b)** ¿Por qué cambiar el valor de `ENV GREETING` no obliga a reconstruir la capa de `COPY app.py .`? ¿Qué determina si una capa se invalida?
- **3.c)** `docker run --entrypoint /bin/bash ...` ¿modifica la imagen `hola-app:v2` en el registro/disco, o solo afecta al contenedor de esa ejecución?

---

## Ejercicio 4 — Multi-stage build para reducir el tamaño de la imagen

Las imágenes de producción no deberían cargar compiladores ni herramientas de build. El *multi-stage build* permite compilar en una etapa y copiar solo el artefacto final a una imagen liviana.

1. Creá un programa mínimo en Go:

   ```bash
   cat > main.go <<'EOF'
   package main

   import "fmt"

   func main() {
       fmt.Println("hola desde un binario compilado")
   }
   EOF
   ```

2. Escribí un `Dockerfile.multistage` con dos etapas:

   ```dockerfile
   FROM golang:1.23 AS builder
   WORKDIR /src
   COPY main.go .
   RUN CGO_ENABLED=0 go build -o hola main.go

   FROM gcr.io/distroless/static-debian12
   COPY --from=builder /src/hola /hola
   ENTRYPOINT ["/hola"]
   ```

3. Construí ambas variantes y compará tamaños:

   ```bash
   docker build -f Dockerfile.multistage -t hola-multistage:v1 .
   docker build -f Dockerfile.multistage --target builder -t hola-builder:v1 .
   docker images | grep hola-
   ```

4. Corré la imagen final y confirmá que funciona sin tener Go instalado dentro:

   ```bash
   docker run --rm hola-multistage:v1
   ```

**Preguntas de verificación**

- **4.a)** ¿Por qué la imagen `hola-multistage:v1` es drásticamente más chica que `hola-builder:v1`?
- **4.b)** ¿Qué hace exactamente `COPY --from=builder` y qué requisito tiene el binario copiado (pista: `CGO_ENABLED=0`) para poder correr en una imagen `distroless` sin librerías dinámicas?
- **4.c)** Además del tamaño, ¿qué ventaja de seguridad tiene no incluir el toolchain de compilación (Go, compiladores, gestores de paquetes) en la imagen final?

---

## Ejercicio 5 — Usuario no root y publicación en un registro

Una imagen "definida" correctamente para Kubernetes también contempla quién la ejecuta y cómo se distribuye.

1. Agregá un usuario sin privilegios al `Dockerfile` original (v2) y usalo como usuario por defecto:

   ```dockerfile
   FROM python:3.12-slim
   WORKDIR /app
   RUN useradd --uid 1000 --create-home appuser
   COPY app.py .
   EXPOSE 8080
   USER appuser
   ENTRYPOINT ["python", "app.py"]
   ```

2. Reconstruí con un nuevo tag y verificá el usuario efectivo dentro del contenedor:

   ```bash
   docker build -t hola-app:v3 .
   docker run --rm hola-app:v3 id
   ```

3. Levantá un registro local descartable para practicar el push:

   ```bash
   docker run -d --name registry -p 5000:5000 registry:2
   ```

4. Etiquetá la imagen apuntando al registro local y publicala:

   ```bash
   docker tag hola-app:v3 localhost:5000/hola-app:v3
   docker push localhost:5000/hola-app:v3
   ```

5. Confirmá el roundtrip: borrá la imagen local y volvé a traerla desde el registro:

   ```bash
   docker rmi hola-app:v3 localhost:5000/hola-app:v3
   docker pull localhost:5000/hola-app:v3
   ```

**Preguntas de verificación**

- **5.a)** ¿Por qué correr un contenedor como root dentro de la imagen es un riesgo, aunque el contenedor esté "aislado"?
- **5.b)** En el nombre `localhost:5000/hola-app:v3`, identificá cada parte: ¿cuál es el host del registro, cuál el repositorio y cuál el tag?
- **5.c)** Si no hubieras hecho `docker tag` antes del `push`, ¿hacia dónde intentaría publicar la imagen `docker push hola-app:v3`?

---

<details>
<summary><strong>✅ Respuestas</strong></summary>

### Ejercicio 1

- **1.a)** `FROM` define la imagen base sobre la que se construyen todas las capas siguientes; `WORKDIR` fija el directorio de trabajo dentro de la imagen para las instrucciones posteriores (`COPY`, `RUN`, `CMD`). Si se omite `WORKDIR`, los comandos se ejecutan relativos a `/` (o al `WORKDIR` heredado de la imagen base), lo que suele ser menos prolijo y más propenso a errores de rutas.
- **1.b)** Es la **forma exec** (*exec form*, una lista JSON), donde el proceso se ejecuta directamente sin invocar una shell intermedia. Se prefiere sobre la **forma shell** (`CMD python app.py`) porque el proceso resultante es el PID 1 del contenedor y recibe señales (como `SIGTERM`) directamente, permitiendo un apagado (*graceful shutdown*) correcto; con la forma shell, la señal la recibe `/bin/sh -c`, no la aplicación.
- **1.c)** No. `EXPOSE` es únicamente **documentación** dentro de la imagen: indica en qué puerto escucha la aplicación. La publicación real del puerto hacia el host la hace el flag `-p`/`--publish` en `docker run` (o el `Service` de Kubernetes en producción).

### Ejercicio 2

- **2.a)** El *image ID* es el hash de contenido (SHA-256) que identifica de forma única e inmutable esa imagen concreta; el *tag* (`v1`) es solo una etiqueta legible y mutable que apunta a un *image ID*. Un mismo tag puede reapuntar a distintos IDs a lo largo del tiempo (por eso `latest` es poco confiable en producción).
- **2.b)** La capa correspondiente a `FROM python:3.12-slim` (la imagen base), porque incluye el intérprete de Python y las librerías del sistema; las capas propias (`COPY`, `EXPOSE`, `CMD`) son órdenes de magnitud más livianas.
- **2.c)** Docker reutiliza todas las capas: al no haber cambios en el Dockerfile ni en los archivos copiados, cada instrucción resuelve al mismo hash de capa cacheado. En la salida del build esto se ve como `CACHED` junto a cada paso.

### Ejercicio 3

- **3.a)** `ENTRYPOINT` define el proceso fijo que siempre se ejecuta; `CMD` define argumentos por defecto que pueden sobreescribirse fácilmente al correr `docker run <imagen> <otros-args>`. Cuando ambos están presentes, los argumentos de `CMD` se pasan como argumentos al `ENTRYPOINT` (siempre que ambos usen la forma exec).
- **3.b)** Docker invalida una capa cuando cambia la instrucción que la genera o los archivos que copia; `ENV GREETING=...` y `COPY app.py .` son instrucciones independientes en capas distintas, así que modificar una no afecta el hash de la otra. La invalidación de una capa sí obliga a reconstruir **todas las capas siguientes** en el Dockerfile.
- **3.c)** Solo afecta a esa ejecución puntual del contenedor. `--entrypoint` sobreescribe el proceso de arranque en tiempo de ejecución (*runtime*), pero no modifica ni reconstruye la imagen `hola-app:v2` almacenada en disco.

### Ejercicio 4

- **4.a)** Porque `hola-multistage:v1` solo contiene el binario compilado (unos pocos MB) copiado sobre una imagen `distroless` sin shell, gestor de paquetes ni librerías innecesarias; `hola-builder:v1` incluye todo el toolchain de Go (cientos de MB: compilador, caché de módulos, herramientas de build).
- **4.b)** `COPY --from=builder /src/hola /hola` copia un archivo específico desde el sistema de archivos de una etapa previa (identificada por su alias `AS builder`) hacia la imagen final, sin arrastrar el resto de esa etapa. El binario debe estar **compilado estáticamente** (`CGO_ENABLED=0` desactiva los enlaces dinámicos a `glibc` vía cgo) porque la imagen `distroless` no tiene librerías C dinámicas para resolver esos enlaces en tiempo de ejecución.
- **4.c)** Reduce la **superficie de ataque** (*attack surface*): sin compilador, shell ni gestor de paquetes, un atacante que comprometa el contenedor no tiene herramientas para escalar, instalar malware o moverse lateralmente, y hay menos CVEs potenciales que auditar en la imagen.

### Ejercicio 5

- **5.a)** Aunque el contenedor esté aislado por *namespaces* y *cgroups*, correr como root dentro del contenedor sigue siendo root respecto al sistema de archivos montado y, en caso de una fuga de contenedor (*container escape*, por una vulnerabilidad del runtime o del kernel), ese proceso tendría privilegios de root también en el host. Ejecutar como usuario sin privilegios reduce drásticamente el daño posible ante ese escenario.
- **5.b)** `localhost:5000` es el **host y puerto del registro**; `hola-app` es el **nombre del repositorio** (repository); `v3` es el **tag** que identifica esa versión concreta dentro del repositorio.
- **5.c)** Sin el `docker tag`, `docker push hola-app:v3` intentaría publicar hacia **Docker Hub** (el registro por defecto cuando no se especifica un host), buscando el repositorio `docker.io/library/hola-app` o `docker.io/<tu-usuario>/hola-app`, lo cual normalmente fallaría por falta de autenticación o permisos.

</details>

---

**Fuentes consultadas:**
- CKAD Curriculum v1.35 (CNCF): [https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf](https://github.com/cncf/curriculum/raw/master/CKAD_Curriculum_v1.35.pdf)
- Dockerfile reference: [https://docs.docker.com/reference/dockerfile/](https://docs.docker.com/reference/dockerfile/)
- Multi-stage builds: [https://docs.docker.com/build/building/multi-stage/](https://docs.docker.com/build/building/multi-stage/)