# El contenido (catalog.yaml + certs/) va HORNEADO en la imagen: publicar =
# regenerar/commitear contenido -> rebuild -> helm upgrade. Sin estado en el pod.
FROM python:3.12-slim

WORKDIR /app
ENV TEACH_ROOT=/app PYTHONUNBUFFERED=1

COPY pyproject.toml README.md ./
COPY teach/ teach/
RUN pip install --no-cache-dir .

COPY catalog.yaml ./
COPY certs/ certs/

EXPOSE 8000
# TEACH_SECRET/LITELLM_* llegan por env desde el chart (Secret)
CMD ["uvicorn", "teach.api:app", "--host", "0.0.0.0", "--port", "8000"]
