# El contenido (catalog.yaml + certs/) va HORNEADO en la imagen: publicar =
# regenerar/commitear contenido -> rebuild -> helm upgrade. Sin estado en el pod.
FROM python:3.12-slim@sha256:a6e34c598f2467ed0e9a8d349809fcd8b5c603269512df273a0bb1784edc11b1

WORKDIR /app
ENV TEACH_ROOT=/app PYTHONUNBUFFERED=1

# README.md is not copied: pyproject.toml declares no readme, so the build
# never needed it, and copying it made every README edit change the image
# while docker.yml did not rebuild for it. What the image contains and what
# triggers a rebuild are now the same list (docker.yml → paths), which is
# also what scripts/check_pr.py reads to label a PR site:image-rebuild.
COPY pyproject.toml ./
COPY teach/ teach/
RUN pip install --no-cache-dir .

# Every root-level data file the API reads, in one line. Listing them
# individually is how three endpoints shipped broken in a row: /api/status
# needed pipeline.yaml (the quality floor it counts with) and scripts/,
# /api/models needed models.yaml, and each was found only in production
# because the container silently lacked what the toolbox had. If a new
# root .yaml becomes API input, this glob already ships it.
COPY *.yaml ./
COPY certs/ certs/
COPY media/ media/
# /api/status imports check_versions.survey() — the same function that renders
# STATUS.md's table, on purpose (one implementation, two projections). The
# cleaner home for it is teach/core; until that refactor, ship the scripts.
COPY scripts/ scripts/

# The app only reads /app and writes where TEACH_BOT_STATS points (a mounted volume the chart
# gives group 10001): no reason to run as root.
RUN useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin app
USER 10001

EXPOSE 8000
# TEACH_SECRET/LITELLM_* llegan por env desde el chart (Secret)
CMD ["uvicorn", "teach.api:app", "--host", "0.0.0.0", "--port", "8000"]
