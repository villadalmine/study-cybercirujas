# Ejercicios guiados — 4.1 Cloud Native Ecosystem and Principles

*Fuente de referencia: [KCNA Curriculum (CNCF)](https://github.com/cncf/curriculum/raw/master/KCNA_Curriculum.pdf)*

---

## Ejercicio 1 — La definición de Cloud Native y sus pilares

1. Escribí en una hoja (o editor de texto) tu propia definición de "cloud native" antes de leer nada más, en una sola oración.
2. Ahora identificá, dentro de esa definición, si mencionaste alguno de estos cuatro elementos: **contenedores**, **microservicios**, **infraestructura inmutable**, **APIs declarativas**. Marcá cuáles incluiste y cuáles no.
3. Tomá una aplicación que conozcas (por ejemplo, un monolito tradicional desplegado en una VM) y listá, punto por punto, qué cambiaría en su arquitectura, su proceso de deploy y su forma de escalar si la migraras a un enfoque cloud native.
4. Compará tu lista del paso 3 contra los cuatro pilares del paso 2. Marcá qué pilar resuelve cada cambio que identificaste.

> **Pregunta 1.1:** Según el enfoque de la CNCF, ¿por qué "usar contenedores" por sí solo no alcanza para decir que un sistema es "cloud native"?
>
> **Pregunta 1.2:** Dado un sistema que guarda configuración de red hardcodeada dentro de la imagen del contenedor y requiere SSH manual para aplicar cambios, ¿qué pilar de cloud native está violando y por qué?

---

## Ejercicio 2 — Explorando el CNCF Landscape

1. Andá a [landscape.cncf.io](https://landscape.cncf.io) (podés hacerlo desde cualquier navegador; no requiere cuenta).
2. Ubicá la categoría **"Orchestration & Management"** y dentro de ella la subcategoría **"Scheduling & Orchestration"**. Anotá tres proyectos que aparezcan ahí además de Kubernetes.
3. Cambiá a la categoría **"App Definition and Development"** y anotá un proyecto de la subcategoría **"Database"** y uno de **"Streaming & Messaging"**.
4. Activá el filtro que distingue proyectos **CNCF hosted** de proyectos que solo aparecen listados como parte del landscape sin ser hosted por la CNCF (fijate en el ícono/borde distintivo que usa el sitio). Anotá un ejemplo de cada tipo.
5. Contá, a grandes rasgos, cuántas categorías principales tiene el landscape completo (sin entrar en subcategorías).

> **Pregunta 2.1:** ¿Cuál es la diferencia entre un proyecto que la CNCF "hostea" (CNCF hosted project) y uno que simplemente aparece listado en el landscape?
>
> **Pregunta 2.2:** ¿Para qué le sirve el landscape a una organización que está evaluando qué herramientas adoptar, más allá de ser un simple catálogo?

---

## Ejercicio 3 — Niveles de madurez de un proyecto CNCF

1. Elegí tres proyectos CNCF que conozcas o que hayas visto en el Ejercicio 2 (por ejemplo: Kubernetes, Envoy, algo que hayas anotado como "recién agregado" o menos conocido).
2. Para cada uno, buscá en el propio landscape o en la [lista oficial de proyectos CNCF](https://www.cncf.io/projects/) su estado: **Sandbox**, **Incubating** o **Graduated**.
3. Anotá, para cada proyecto, un indicio que justifique ese nivel: cantidad de adopters conocidos, tiempo desde que ingresó a la CNCF, si tiene un proceso de seguridad auditado (relevante sobre todo para Graduated).
4. Ordená los tres proyectos de menor a mayor madurez según lo que encontraste.

> **Pregunta 3.1:** ¿Qué cuerpo de gobierno de la CNCF es responsable de aprobar el paso de un proyecto de un nivel de madurez a otro?
>
> **Pregunta 3.2:** Un equipo de infraestructura te pregunta si puede llevar a producción crítica un proyecto que está en estado **Sandbox**. ¿Qué le respondés y por qué, en términos de riesgo y expectativas de esa etapa?
>
> **Pregunta 3.3:** ¿Qué diferencia clave separa a un proyecto **Incubating** de uno **Graduated** en cuanto a expectativas de estabilidad y adopción?

---

## Ejercicio 4 — Recorriendo el Cloud Native Trail Map

1. Buscá el diagrama del **Cloud Native Trail Map**, publicado por la CNCF, que propone una secuencia de pasos recomendados para adoptar prácticas cloud native.
2. Listá, en orden, los primeros cuatro pasos del Trail Map (típicamente: containerization, CI/CD, orchestration & application definition, observability & analysis).
3. Para cada uno de esos cuatro pasos, escribí un ejemplo concreto de herramienta o proyecto CNCF que lo cubra (por ejemplo: contenerización → un runtime de contenedores).
4. Imaginá que tu equipo todavía despliega binarios directamente en VMs sin contenedores ni pipeline automatizado. Señalá cuál sería el primer paso del Trail Map que deberían encarar y justificá por qué ese y no otro más adelante en el mapa.

> **Pregunta 4.1:** ¿Por qué el Trail Map ubica la observabilidad (logging, monitoring, tracing) como un paso posterior a la orquestación y no como el primero?
>
> **Pregunta 4.2:** ¿Qué problema práctico busca evitar el Trail Map al proponer un orden sugerido de adopción en lugar de dejar que cada organización empiece por donde quiera?

---

## Ejercicio 5 — Gobernanza y roles en la comunidad CNCF

1. Identificá qué organización paraguas aloja a la CNCF (pista: es una fundación sin fines de lucro dedicada a sostener proyectos de código abierto).
2. Listá tres roles distintos que puede tener una persona o empresa dentro del ecosistema de un proyecto CNCF: **end user**, **contributor**, **maintainer**.
3. Buscá qué es el **Technical Oversight Committee (TOC)** de la CNCF y anotá, en una oración, su función principal.
4. Buscá qué es un **Special Interest Group (SIG)** dentro de la comunidad de Kubernetes y anotá un ejemplo de SIG (por ejemplo, SIG-Networking, SIG-Storage).
5. Repasá qué es el **CNCF End User Community** y por qué existe como grupo separado de los mantenedores de proyectos.

> **Pregunta 5.1:** ¿Qué diferencia hay entre ser *contributor* y ser *maintainer* de un proyecto open source dentro de la CNCF?
>
> **Pregunta 5.2:** ¿Por qué le conviene a la CNCF mantener un canal formal (el End User Community) separado, en lugar de escuchar solo a las empresas que desarrollan los proyectos?
>
> **Pregunta 5.3:** ¿Qué tipo de decisiones caen bajo la órbita del TOC y no de un SIG individual?

---

## Ejercicio 6 — Principios arquitectónicos aplicados a un caso

1. Tomá el siguiente escenario: una empresa tiene una aplicación monolítica que se actualiza editando archivos directamente en el servidor de producción, sin versionado de infraestructura ni pipeline de despliegue.
2. Reescribí el escenario aplicando el principio de **infraestructura inmutable**: ¿cómo cambiaría el proceso de actualización?
3. Reescribí el escenario aplicando el principio de **APIs declarativas**: en vez de ejecutar comandos paso a paso para configurar el sistema, ¿cómo se expresaría el estado deseado?
4. Proponé cómo dividir el monolito en al menos dos **microservicios**, identificando un límite de responsabilidad razonable entre ellos.
5. Sumá un **service mesh** al diseño resultante y explicá qué problema nuevo (no relacionado a la lógica de negocio) resuelve al tener múltiples microservicios comunicándose entre sí.

> **Pregunta 6.1:** ¿Por qué "editar un archivo de configuración directamente en el servidor en producción" es lo opuesto al principio de infraestructura inmutable?
>
> **Pregunta 6.2:** ¿Qué ventaja concreta aporta describir el estado deseado (declarativo) frente a describir la secuencia de comandos para llegar a él (imperativo), especialmente cuando falla un paso a mitad de camino?
>
> **Pregunta 6.3:** Si dos microservicios necesitan comunicarse de forma segura y con reintentos automáticos ante fallas de red, ¿qué componente de la arquitectura cloud native se encarga típicamente de eso sin que cada microservicio tenga que implementarlo por su cuenta?

---

<details>
<summary><strong>Ver respuestas</strong></summary>

**1.1** — Porque "cloud native" no es una tecnología puntual sino un enfoque arquitectónico completo. Un sistema puede estar containerizado y seguir siendo frágil, difícil de escalar o de operar si no adopta también microservicios (para desacoplar componentes), infraestructura inmutable (para despliegues predecibles) y APIs declarativas (para gestionar el estado de forma reproducible). Los contenedores son un habilitador, no el objetivo en sí.

**1.2** — Viola el principio de **infraestructura inmutable**. Ese principio propone que, ante un cambio, se reemplaza el artefacto completo (una nueva imagen, un nuevo despliegue) en lugar de modificar un componente en ejecución. Hacer SSH manual para tocar configuración introduce drift entre instancias, hace el cambio no reproducible y rompe la trazabilidad de qué versión está corriendo realmente.

**2.1** — Un proyecto **CNCF hosted** fue donado formalmente a la fundación, sigue su gobernanza (TOC, niveles de madurez, políticas de IP y trademark) y recibe soporte de la CNCF (infraestructura de CI, marketing, eventos). Un proyecto que solo aparece **listado** en el landscape es simplemente parte del ecosistema cloud native reconocido por la CNCF como relevante, pero mantiene su propia gobernanza independiente y no pasa por el proceso de sandbox/incubating/graduated.

**2.2** — Más allá de catalogar, el landscape ayuda a una organización a comparar alternativas dentro de una misma categoría (por ejemplo, distintas opciones de service mesh), entender qué tan maduro y adoptado está un proyecto antes de apostar por él, y visualizar cómo encajan las piezas entre sí dentro de una arquitectura cloud native completa.

**3.1** — El **Technical Oversight Committee (TOC)**.

**3.2** — Se le explica que **Sandbox** es la etapa de entrada: son proyectos experimentales, de alcance y calidad muy variable, sin garantías de continuidad ni de haber pasado revisiones de seguridad o gobernanza formal. No es una etapa pensada para producción crítica; conviene reservarla para pruebas de concepto o evaluación, y esperar a que el proyecto avance a Incubating (o mejor, Graduated) antes de depender de él en un entorno productivo sensible.

**3.3** — **Incubating** indica que el proyecto ya demostró adopción real por parte de múltiples usuarios en producción y cierto nivel de gobernanza, pero todavía no cumple todos los criterios más exigentes de sostenibilidad, diversidad de contribuyentes y procesos de seguridad. **Graduated** implica que superó una auditoría de seguridad independiente, tiene gobernanza y comunidad de contribuyentes bien establecidas (no dependiente de una sola empresa) y una adopción amplia y comprobada — es el nivel de mayor confianza dentro de la CNCF.

**4.1** — Porque para poder observar (loggear, monitorear, tracear) de forma efectiva un sistema distribuido, primero necesitás que ese sistema esté containerizado y orquestado de manera consistente: la orquestación te da un punto uniforme desde donde recolectar métricas y logs de todos los componentes. Instrumentar observabilidad antes de tener esa base ordenada produce datos fragmentados y difíciles de correlacionar.

**4.2** — Busca evitar que las organizaciones salten directamente a herramientas avanzadas (por ejemplo, service mesh o políticas de seguridad complejas) sin haber resuelto primero los fundamentos (contenerización, CI/CD, orquestación básica). Saltear pasos suele generar sistemas frágiles, difíciles de depurar y con curva de adopción mucho más alta de la necesaria.

**5.1** — La **Linux Foundation**.

**5.2** — Un **contributor** es cualquier persona que aporta código, documentación o cualquier otro trabajo al proyecto de forma puntual o recurrente. Un **maintainer** tiene, además, responsabilidad de revisión y aprobación de cambios, define la dirección técnica del proyecto y suele tener permisos elevados sobre el repositorio — es un rol de confianza que normalmente se gana con contribuciones sostenidas en el tiempo.

**5.3** — Porque las empresas que desarrollan un proyecto tienen incentivos distintos a los de quienes lo operan día a día en producción. El End User Community le da a la CNCF una fuente directa de feedback sobre problemas reales de adopción, casos de uso y prioridades, sin ese feedback filtrado por los intereses comerciales de los vendors.

**5.4 (Pregunta 5.3)** — El TOC define políticas transversales de la fundación: gobernanza general, criterios y proceso de avance entre niveles de madurez (Sandbox → Incubating → Graduated), aceptación de nuevos proyectos y resolución de conflictos entre proyectos que se superponen. Un SIG, en cambio, se ocupa de decisiones técnicas dentro de un área específica de un proyecto puntual (por ejemplo, el diseño de la capa de storage en Kubernetes).

**6.1** — Porque infraestructura inmutable implica que, una vez desplegado un artefacto (imagen, VM, configuración), no se modifica en el lugar: cualquier cambio se hace creando una nueva versión del artefacto y reemplazando la anterior. Editar un archivo directamente en el servidor en producción crea una instancia que ya no coincide con ningún artefacto versionado, generando drift y pérdida de reproducibilidad.

**6.2** — El enfoque declarativo le dice al sistema "este es el estado que quiero", y es el propio sistema (el controlador u orquestador) el que reconcilia continuamente la realidad contra ese estado deseado, reintentando automáticamente ante fallas parciales. El enfoque imperativo, en cambio, si falla a mitad de una secuencia de comandos, puede dejar el sistema en un estado intermedio inconsistente que hay que diagnosticar y corregir manualmente.

**6.3** — Un **service mesh**. Se encarga de aspectos transversales de la comunicación entre servicios (mTLS, reintentos, balanceo de carga, circuit breaking, observabilidad del tráfico) mediante un proxy sidecar, sin que cada microservicio tenga que implementar esa lógica en su propio código.

</details>