# El contenido (catalog.yaml + certs/) va HORNEADO en la imagen: publicar =
# regenerar/commitear contenido -> rebuild -> helm upgrade. Sin estado en el pod.
FROM python:3.12-slim

WORKDIR /app
ENV TEACH_ROOT=/app PYTHONUNBUFFERED=1

COPY pyproject.toml README.md ./
COPY teach/ teach/
RUN pip install --no-cache-dir .

COPY catalog.yaml ./
# quality.check_file reads the floor thresholds from here; /api/status counts
# a language only when its material passes that floor.
COPY pipeline.yaml ./
COPY certs/ certs/
COPY media/ media/
# /api/status imports check_versions.survey() — the same function that renders
# STATUS.md's table, on purpose (one implementation, two projections). The
# cleaner home for it is teach/core; until that refactor, ship the scripts.
COPY scripts/ scripts/

EXPOSE 8000
# TEACH_SECRET/LITELLM_* llegan por env desde el chart (Secret)
CMD ["uvicorn", "teach.api:app", "--host", "0.0.0.0", "--port", "8000"]
