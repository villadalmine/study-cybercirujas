# Guía de Estudio y Laboratorio Práctico: Tema 5.1 – Modelos de Desarrollo de Software

**Certificación Objetivo:** LPI Open Source Essentials (Examen 050-100)  
**Tema:** 5.1 Modelos de Desarrollo de Software  
**Peso del Examen:** 7.5  
**Nivel:** SRE Avanzado / Arquitecto de Plataformas de Producción  

---

## 1. Visión General Arquitectónica y Mecánica Técnica

Los modelos de desarrollo de software definen los marcos operacionales, organizacionales y tecnológicos utilizados para planificar, construir, probar, lanzar y mantener el software. En entornos de código abierto y cloud-native modernos, comprender estos modelos es crucial para diseñar pipelines de entrega continua resilientes, gestionar el riesgo de lanzamiento y alinear la gobernanza del software de código abierto (OSS) con los objetivos de confiabilidad de SRE.

```
       +-------------------------------------------------------------------------+
       |                     SOFTWARE DEVELOPMENT SPECTRUM                       |
       +-------------------------------------------------------------------------+
       |                                                                         |
       |  [ Cathedral Model ] -------------> [ Agile / Scrum ] ----------> [ SRE / DevOps ]
       |  (Predictable, isolated,               (Iterative, sprint-            (Continuous, automated,
       |   centralized control)                 based delivery)                 GitOps, error budgets)
       |                                                                         |
       |  [ Waterfall Model ] -------------> [ Bazaar Model ] -----------> [ GitOps / CI/CD ]
       |  (Sequential phases,                   (Distributed, rapid             (Declarative state, automated
       |   rigid boundaries)                    peer review, open)              reconciliation loops)
       |                                                                         |
       +-------------------------------------------------------------------------+
```

### 1.1 El Espectro del Paradigma Clásico y de Código Abierto

#### 1. Catedral vs. Bazar (Eric S. Raymond)
* **El Modelo Catedral:** El software se desarrolla aisladamente por un grupo restringido de desarrolladores entre lanzamientos públicos oficiales. El código fuente se guarda hasta los lanzamientos principales, los bucles de revisión están centralizados y el control arquitectónico es estrictamente descendente (top-down).
* **El Modelo Bazar:** El software se desarrolla en público ("lanzar temprano, lanzar a menudo" / "release early, release often"). Miles de desarrolladores independientes prueban, parchan y extienden la base de código simultáneamente. *Ley de Linus:* "Dado un número suficiente de ojos, todos los errores son superficiales."

#### 2. Secuencial (Waterfall) vs. Iterativo (Agile / Scrum / Kanban)
* **Waterfall:** Un ciclo de vida secuencial por etapas (Requisitos $\to$ Diseño $\to$ Implementación $\to$ Verificación $\to$ Mantenimiento). Alto costo de cambio, validación tardía, propenso al infierno de la integración (integration hell).
* **Agile/Scrum:** Iteraciones con tiempo delimitado (sprints) que producen incrementos de software funcional. Enfatiza historias de usuario, velocidad, retrospectivas y equipos multidisciplinarios.
* **Kanban:** Modelo de flujo continuo impulsado por límites explícitos de Trabajo en Progreso (Work-In-Progress - WIP). Optimiza el lead time y el rendimiento (throughput) sin límites de sprint fijos.

#### 3. Integración Continua SRE & DevOps
Los modelos modernos de desarrollo de software integran primitivas de Site Reliability Engineering (SRE) en el ciclo de vida:
* **Integración Continua (CI):** Los desarrolladores fusionan (merge) código a main continuamente; las compilaciones y pruebas automatizadas se ejecutan por cada commit.
* **Entrega/Despliegue Continuo (CD):** Despliegue automatizado a staging/producción sujeto a puertas de calidad (quality gates) o reconciliación de estado en GitOps.
* **Seguridad y Pruebas Shift-Left:** Pruebas Estáticas de Seguridad de Aplicaciones (SAST), escaneo de Lista de Materiales de Software (SBOM) y pruebas unitarias se ejecutan automáticamente antes de la fusión (merge).

---

## 2. Matriz de Compensaciones en Producción

| Modelo | Flexibilidad al Cambio | Latencia del Bucle de Retroalimentación | Riesgo de Lanzamiento en Producción | Sobrecarga Operacional | Caso de Uso Típico |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Waterfall** | Muy Baja | Meses / Años | Alto (Big Bang) | Baja inicial, alta post-lanzamiento | Sistemas embebidos, hardware crítico para la seguridad |
| **Catedral (OSS)** | Baja-Media | Meses | Medio | Alta carga de triaje del gatekeeper | Subcomponentes centrales del kernel, OS central del proveedor |
| **Bazar (OSS)** | Alta | Horas / Días | Variable (Requiere filtrado de CI) | Alto costo de infraestructura de CI | Kubernetes, Kernel de Linux, ecosistema CNCF |
| **Agile / Scrum** | Alta | 1–3 Semanas | Medio (Despliegues al final del sprint) | Media (Ceremonias de Scrum) | SaaS empresarial, microservicios de aplicaciones |
| **Continuous DevOps / SRE** | Muy Alta | Minutos / Horas | Bajo (Canary / Feature Flags) | Alta (Esfuerzo de ingeniería de plataforma) | Plataformas cloud-native, plataformas web a gran escala |

---

## 3. Ejercicios Guiados Prácticos

---

### Ejercicio 1: Simulando Flujos de Trabajo de Lanzamiento Git Catedral vs. Bazar

En este ejercicio, construirás dos estrategias distintas de flujo de trabajo Git en un repositorio: un **flujo de lanzamiento Catedral** (ramas de lanzamiento estrictas, control de acceso/gatekeeping) y un **flujo de contribución continua Bazar** (fork-and-pull, validación automatizada rápida).

#### Paso 1.1: Inicializar el Entorno de Laboratorio y la Estructura del Repositorio Catedral
Ejecutá los siguientes comandos en tu shell para simular un flujo de lanzamiento centralizado Catedral.

```bash
mkdir -p ~/dev-models-lab/cathedral-repo
cd ~/dev-models-lab/cathedral-repo
git init -b main
git config user.name "Cathedral Maintainer"
git config user.email "maintainer@cathedral.org"

# Create core application code
cat << 'EOF' > app.py
VERSION = "1.0.0-cathedral"

def core_function():
    return "Stable core functionality validated by release committee."

if __name__ == "__main__":
    print(f"App Version: {VERSION}")
    print(core_function())
EOF

git add app.py
git commit -m "feat: initial cathedral core release 1.0.0"
git tag -a v1.0.0 -m "Official Cathedral Release 1.0.0"
```

Expected Output:
```text
[main (root-commit) a1b2c3d] feat: initial cathedral core release 1.0.0
 1 file changed, 8 insertions(+)
 create mode 100644 app.py
```

#### Paso 1.2: Simular el Ramificado de Desarrollo Aislado de Catedral
En el modelo Catedral, las adiciones de características se mantienen aisladas en ramas de preparación (staging) privadas durante largos ciclos antes de fusionarse a `main`.

```bash
# Create long-lived release staging branch
git checkout -b release/2.0.0-staging

cat << 'EOF' > app.py
VERSION = "2.0.0-cathedral"

def core_function():
    return "Stable core functionality validated by release committee."

def new_isolated_feature():
    return "Feature developed internally after 12 months of planning."

if __name__ == "__main__":
    print(f"App Version: {VERSION}")
    print(core_function())
    print(new_isolated_feature())
EOF

git commit -am "feat: internal development for release 2.0.0"
```

#### Paso 1.3: Inicializar el Modelo de Pipeline Continuo Bazar
Ahora, creá un repositorio separado que represente el modelo Bazar: commits continuos entre pares, alternancia de funciones (feature toggling) y versionado semántico automatizado.

```bash
mkdir -p ~/dev-models-lab/bazaar-repo
cd ~/dev-models-lab/bazaar-repo
git init -b main
git config user.name "Bazaar Developer"
git config user.email "dev@bazaar.community"

cat << 'EOF' > app.py
import os

VERSION = "1.1.0-bazaar"

def get_feature_flags():
    return os.getenv("ENABLE_EXPERIMENTAL_BAZAAR", "false").lower() == "true"

def core_function():
    status = "Core functionality"
    if get_feature_flags():
        status += " [EXPERIMENTAL BAZAAR PATCH ENABLED]"
    return status

if __name__ == "__main__":
    print(f"Bazaar Build Version: {VERSION}")
    print(core_function())
EOF

git add app.py
git commit -m "feat(core): initial bazaar deployment with feature flags"
```

Expected Output:
```text
[main (root-commit) e5f6g7h] feat(core): initial bazaar deployment with feature flags
 1 file changed, 16 insertions(+)
 create mode 100644 app.py
```

#### Paso 1.4: Ejecutar la Alternancia Automatizada de Funciones de Bazar
Verificá cómo el software al estilo Bazar se apoya en la configuración en tiempo de ejecución para alternar funciones en lugar de utilizar un aislamiento prolongado de ramas para probar nuevo código en producción de forma segura.

```bash
python3 app.py
ENABLE_EXPERIMENTAL_BAZAAR=true python3 app.py
```

Expected Output:
```text
Bazaar Build Version: 1.1.0-bazaar
Core functionality
Bazaar Build Version: 1.1.0-bazaar
Core functionality [EXPERIMENTAL BAZAAR PATCH ENABLED]
```

---

#### Preguntas de Verificación – Ejercicio 1

1. **Pregunta 1.1:** ¿Qué riesgo principal del modelo de desarrollo Catedral aborda directamente el modelo Bazar al introducir lanzamientos frecuentes y una amplia revisión por pares pública?
   * A) Altos costos de infraestructura durante la ejecución de CI/CD.
   * B) El "Infierno de Integración" (Integration Hell) causado por ramas de desarrollo aisladas de larga duración que rompen la compatibilidad al fusionarse.
   * C) La incapacidad de hacer cumplir un cumplimiento estricto de derechos de autor y licencias de código abierto.
   * D) La dependencia excesiva de feature flags en tiempo de ejecución causando deuda técnica.

2. **Pregunta 1.2:** En el modelo Bazar, ¿cómo preserva la confiabilidad del sitio la implementación de feature flags al tiempo que permite el despliegue continuo ("lanzar temprano, lanzar a menudo")?
   * A) Reemplaza las pruebas unitarias al capturar excepciones en tiempo de ejecución.
   * B) Desacopla el despliegue de código de la activación de características, permitiendo un rollback instantáneo sin volver a desplegar artefactos.
   * C) Obliga al código a compilarse en binarios separados para los lanzamientos Catedral y Bazar.
   * D) Convierte automáticamente la documentación de Waterfall en historias de usuario de Agile.

---

### Ejercicio 2: Implementando Puertas de Calidad CI/CD y Automatización de Lanzamientos para Modelos Agile/SRE

Los modelos de desarrollo de software modernos imponen el cumplimiento, la seguridad y las puertas de calidad dinámicamente mediante pipelines de integración continua. En este ejercicio, definirás un manifiesto de flujo de trabajo de GitHub Actions sintácticamente válido que automatiza las comprobaciones de versión semántica, las pruebas unitarias y las condiciones de despliegue automatizado.

#### Paso 2.1: Definir el Manifiesto del Pipeline Declarativo de CI
Creá la estructura de directorios y el archivo de workflow dentro de `~/dev-models-lab/bazaar-repo/.github/workflows/ci.yml`.

```bash
mkdir -p ~/dev-models-lab/bazaar-repo/.github/workflows
cd ~/dev-models-lab/bazaar-repo

cat << 'EOF' > .github/workflows/ci.yml
name: Bazaar Software Model CI/CD Pipeline

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

jobs:
  quality-gate:
    name: Code Verification & SAST Gate
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Set up Python Environment
        uses: actions/setup-python@v5
        with:
          python-version: '3.10'

      - name: Run Syntax and Style Verification
        run: |
          python -m py_compile app.py
          echo "Syntax verification passed."

      - name: Execute Automated Unit Tests
        run: |
          python -c "import app; assert 'Core functionality' in app.core_function()"
          echo "Unit tests passed successfully."

  cd-release:
    name: Continuous Deployment Gate
    needs: quality-gate
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    steps:
      - name: Simulate Production Artifact Bundle
        run: |
          echo "Packaging application for automated production release..."
          tar -czf release-artifact.tar.gz app.py
          sha256sum release-artifact.tar.gz > release-artifact.tar.gz.sha256
          echo "Artifact created successfully:"
          cat release-artifact.tar.gz.sha256
EOF
```

#### Paso 2.2: Validar y Probar la Lógica del Pipeline Localmente
Simulá los pasos de ejecución del pipeline utilizando herramientas de Python locales.

```bash
python3 -m py_compile app.py
python3 -c "import app; assert 'Core functionality' in app.core_function()"
tar -czf release-artifact.tar.gz app.py
sha256sum release-artifact.tar.gz
```

Expected Output:
```text
<hash-value>  release-artifact.tar.gz
```

---

#### Preguntas de Verificación – Ejercicio 2

1. **Pregunta 2.1:** En un pipeline de integración continua impulsado por SRE, ¿cuál es el rol de la directiva `needs: quality-gate` en la definición del trabajo de despliegue?
   * A) Permite que el trabajo de despliegue se ejecute de forma concurrente con la puerta de calidad para mejorar la velocidad.
   * B) Actúa como una dependencia dura del pipeline, asegurando que no se construya ni despliegue ningún artefacto si fallan las pruebas de verificación.
   * C) Exige la aprobación humana manual antes de que se ejecute el trabajo.
   * D) Convierte los backlogs de sprint de Agile en límites WIP de Kanban.

2. **Pregunta 2.2:** ¿Cómo altera la filosofía de pruebas shift-left en los pipelines modernos de CI el costo de remediación de errores en comparación con las pruebas tradicionales de Waterfall?
   * A) Aumenta el costo de remediación al requerir una infraestructura de pipeline compleja.
   * B) Mantiene los costos constantes independientemente de cuándo se descubra el error.
   * C) Reduce drásticamente el costo de remediación al detectar defectos durante la integración temprana en lugar de interrupciones de producción post-lanzamiento.
   * D) Elimina la necesidad de observabilidad y monitoreo post-producción.

---

### Ejercicio 3: Simulando la Velocidad en Agile y los Cuellos de Botella en el Flujo de Kanban

En SRE e Ingeniería de Plataforma, las métricas de entrega de modelos de desarrollo de software (métricas DORA) se utilizan para medir la eficiencia de los modelos de desarrollo. Las cuatro métricas centrales son:
1. **Frecuencia de Despliegue (Deployment Frequency - DF)**
2. **Tiempo de Lead para Cambios (Lead Time for Changes - LTC)**
3. **Tasa de Fallos en Cambios (Change Failure Rate - CFR)**
4. **Tiempo para Restaurar el Servicio (Time to Restore Service - TTRS)**

En este ejercicio, ejecutarás un script de diagnóstico que analiza los registros de commits de Git para calcular las métricas de lead time y frecuencia de despliegue.

#### Paso 3.1: Crear un Script de Simulación para el Cálculo de Métricas DORA
Creá un script de Python que analice las marcas de tiempo de los commits para calcular el **Lead Time for Changes** a lo largo de los lanzamientos.

```bash
cd ~/dev-models-lab

cat << 'EOF' > dora_metrics.py
import json
import subprocess
from datetime import datetime

def parse_git_commits():
    # Fetch commit hashes and commit timestamps
    cmd = ["git", "log", "--format=%H|%at|%s"]
    result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    lines = result.stdout.strip().split("\n")
    
    commits = []
    for line in lines:
        if not line:
            continue
        h, ts, msg = line.split("|", 2)
        commits.append({
            "hash": h[:7],
            "timestamp": int(ts),
            "date": datetime.fromtimestamp(int(ts)).strftime('%Y-%m-%d %H:%M:%S'),
            "message": msg
        })
    return commits

def calculate_lead_time(commits):
    if len(commits) < 2:
        return 0.0
    # Lead time between oldest commit in window and newest commit
    newest = commits[0]["timestamp"]
    oldest = commits[-1]["timestamp"]
    return (newest - oldest) / 3600.0  # Hours

if __name__ == "__main__":
    import os
    os.chdir(os.path.expanduser("~/dev-models-lab/bazaar-repo"))
    commits = parse_git_commits()
    lt_hours = calculate_lead_time(commits)
    
    metrics = {
        "total_commits": len(commits),
        "lead_time_hours": round(lt_hours, 4),
        "deployment_frequency_rating": "Elite" if len(commits) > 0 else "Low",
        "recent_commits": commits
    }
    
    print(json.dumps(metrics, indent=2))
EOF
```

#### Paso 3.2: Ejecutar la Extracción de Métricas de Diagnóstico DORA
Ejecutá el script para analizar el historial de `bazaar-repo`.

```bash
python3 dora_metrics.py
```

Expected Output:
```json
{
  "total_commits": 1,
  "lead_time_hours": 0.0,
  "deployment_frequency_rating": "Elite",
  "recent_commits": [
    {
      "hash": "...",
      "timestamp": 1700000000,
      "date": "...",
      "message": "feat(core): initial bazaar deployment with feature flags"
    }
  ]
}
```

---

#### Preguntas de Verificación – Ejercicio 3

1. **Pregunta 3.1:** ¿Qué métrica DORA mide directamente la velocidad del pipeline de un equipo de desarrollo desde el commit de código hasta su ejecución en producción?
   * A) Tiempo para Restaurar el Servicio (Time to Restore Service - TTRS)
   * B) Tasa de Fallos en Cambios (Change Failure Rate - CFR)
   * C) Tiempo de Lead para Cambios (Lead Time for Changes - LTC)
   * D) Límite de Trabajo en Progreso (Work In Progress - WIP Limit)

2. **Pregunta 3.2:** Si un equipo que se traslada de Waterfall a DevOps experimenta una alta Tasa de Fallos en Cambios (CFR > 40%) a pesar de una alta Frecuencia de Despliegue, ¿cuál es la deficiencia arquitectónica principal en su pipeline?
   * A) Insuficientes reuniones de retrospectiva de sprint.
   * B) Falta de pruebas automatizadas, validación en canary y puertas de calidad en producción.
   * C) Uso excesivo de modelos de gobernanza Bazar de código abierto.
   * D) Uso de ramas Git en lugar de repositorios Subversion.

---

## 4. Referencias y Fuentes Oficiales

* **Objetivos del Examen LPI Open Source Essentials:**  
  [https://www.lpi.org/our-certifications/open-source-essentials-overview/](https://www.lpi.org/our-certifications/open-source-essentials-overview/)
* **La Catedral y el Bazar (Eric S. Raymond):**  
  [https://www.catb.org/~esr/writings/cathedral-bazaar/cathedral-bazaar/](https://www.catb.org/~esr/writings/cathedral-bazaar/cathedral-bazaar/)
* **Métricas DORA (DevOps Research and Assessment):**  
  [https://dora.dev/quickss/](https://dora.dev/quickss/)
* **Panorama y Buenas Prácticas de Entrega Continua de CNCF:**  
  [https://www.cncf.io/reports/continuous-delivery-landscape/](https://www.cncf.io/reports/continuous-delivery-landscape/)

---

## 5. Respuestas de Verificación y Explicaciones Técnicas Detalladas

<details>
<summary>Hacé clic aquí para desplegar las Soluciones y Explicaciones Detalladas</summary>

### Soluciones del Ejercicio 1

* **Pregunta 1.1: Respuesta Correcta: B**
  * **Justificación Técnica:** En el modelo Catedral, el código permanece en ramas de desarrollo aisladas de larga duración durante largos períodos. Fusionar estos diffs masivos de nuevo en `main` causa una severa desviación del código (code drift) y el "Infierno de Integración" (Integration Hell). El modelo Bazar resuelve esto lanzando temprano y a menudo, fusionando pequeños incrementos continuamente para resolver conflictos inmediatamente.
  * **Análisis de Opciones Incorrectas:**
    * A es incorrecta porque los modelos Bazar a menudo aumentan las ejecuciones de CI debido a los commits frecuentes.
    * C es incorrecta porque la conformidad de licencias de código abierto requiere escáneres explícitos (por ejemplo, FOSSology), independientemente del modelo de ramificado.
    * D es incorrecta porque las feature flags son una técnica de despliegue operacional, no un defecto inherente del modelo Bazar.

* **Pregunta 1.2: Respuesta Correcta: B**
  * **Justificación Técnica:** Las feature flags separan la acción de *desplegar código* de la de *liberar funcionalidad* a los usuarios. El código se puede enviar a producción continuamente en un estado desactivado. Si ocurre una anomalía, los SREs pueden cambiar la flag a desactivado al instante mediante configuración sin desencadenar una compilación de contenedor de varios minutos ni un pipeline de despliegue.
  * **Análisis de Opciones Incorrectas:**
    * A es incorrecta porque las feature flags no reemplazan las pruebas unitarias automatizadas.
    * C es incorrecta porque las feature flags alteran dinámicamente las rutas de ejecución en tiempo de ejecución dentro del mismo artefacto compilado.
    * D es incorrecta porque las feature flags no interactúan con la transformación de la documentación.

---

### Soluciones del Ejercicio 2

* **Pregunta 2.1: Respuesta Correcta: B**
  * **Justificación Técnica:** En GitHub Actions y en los motores DAG de CI/CD estándar, el atributo `needs:` define un nodo de dependencia. El trabajo `cd-release` permanecerá bloqueado hasta que el trabajo `quality-gate` se complete con un código de salida `0` (éxito). Si fallan las pruebas unitarias o los escáneres SAST, el trabajo de lanzamiento se omite automáticamente.
  * **Análisis de Opciones Incorrectas:**
    * A es incorrecta porque `needs:` fuerza la ejecución secuencial, no la concurrencia.
    * C es incorrecta porque la aprobación manual en GitHub Actions se rige por reglas de protección de entornos (`environment:`), no por `needs:`.
    * D es incorrecta porque la sintaxis de trabajos de CI no manipula las metodologías de gestión de proyectos.

* **Pregunta 2.2: Respuesta Correcta: C**
  * **Justificación Técnica:** El paradigma "Shift-Left" desplaza las verificaciones de seguridad, la validación de sintaxis y las pruebas unitarias a las etapas iniciales del ciclo de vida del software (estaciones de trabajo de desarrolladores y comprobaciones de PR). Corregir un error durante la creación de una PR cuesta un tiempo de desarrollo mínimo; descubrir el mismo error durante una interrupción de producción involucra equipos de respuesta a incidentes, impacto en el cliente y sobrecarga de parches de emergencia (hotfix).
  * **Análisis de Opciones Incorrectas:**
    * A es incorrecta porque las pruebas automatizadas reducen drásticamente el costo total de ingeniería en comparación con las pruebas de QA manuales y la gestión de incidentes.
    * B es incorrecta porque el costo de los defectos aumenta exponencialmente a medida que el código se acerca a producción.
    * D es incorrecta porque las pruebas shift-left complementan, pero no reemplazan, la observabilidad en producción.

---

### Soluciones del Ejercicio 3

* **Pregunta 3.1: Respuesta Correcta: C**
  * **Justificación Técnica:** El Tiempo de Lead para Cambios (Lead Time for Changes - LTC) mide la duración precisa transcurrida desde el momento en que se realiza un commit en el repositorio de control de versiones hasta que ese código se ejecuta en un entorno de producción.
  * **Análisis de Opciones Incorrectas:**
    * A (TTRS) mide el tiempo de recuperación después de que ocurre una interrupción.
    * B (CFR) mide el porcentaje de despliegues que causan fallas en producción.
    * D (WIP) es una métrica de restricción de flujo en Kanban, no una métrica de velocidad DORA.

* **Pregunta 3.2: Respuesta Correcta: B**
  * **Justificación Técnica:** Desplegar rápidamente sin las puertas de calidad adecuadas (pruebas de regresión automatizadas, escaneo SAST, estrategias de lanzamiento en canary, rollbacks automatizados basados en controles de salud) conduce a frecuentes fallas en producción, lo que se refleja directamente como una alta Tasa de Fallos en Cambios. Una alta Frecuencia de Despliegue debe equilibrarse con puertas de verificación automatizadas para mantener los presupuestos de error de SRE.
  * **Análisis de Opciones Incorrectas:**
    * A es incorrecta porque las retrospectivas de sprint no interceptan mecánicamente los artefactos de despliegue defectuosos.
    * C es incorrecta porque los modelos de gobernanza Bazar pueden lograr una alta confiabilidad cuando se combinan con pipelines de CI automatizados.
    * D es incorrecta porque la selección de la herramienta de control de versiones (Git vs SVN) no soluciona de por sí la lógica de aplicación defectuosa.

</details>