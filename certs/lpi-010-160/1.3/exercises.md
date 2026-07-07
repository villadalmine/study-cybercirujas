# Ejercicios guiados — Tema 1.3: Open Source Software and Licensing

**Certificación:** LPI Linux Essentials (010-160, versión 1.6) · **Peso:** 1
**Fuente de referencia:** [LPI Learning Materials, Lesson 1.3](https://learning.lpi.org/en/learning-materials/010-160/1/1.3/)

> **Requisitos:** una terminal en cualquier distribución Linux (sirve una máquina virtual o WSL). Algunos pasos ofrecen variantes para sistemas basados en Debian/Ubuntu y para sistemas basados en RPM (Fedora, Rocky, openSUSE).

---

## Ejercicio 1 — Encontrar los textos de licencias en tu propio sistema

Las distribuciones instalan copias de las licencias más comunes. Vas a localizarlas y ver cuáles conviven en un mismo sistema.

1. Buscá el directorio de licencias comunes. En Debian/Ubuntu:
   ```bash
   ls /usr/share/common-licenses/
   ```
   En Fedora/Rocky y derivados:
   ```bash
   ls /usr/share/licenses/ | head -20
   ```
2. Contá cuántas versiones de la **GPL** hay disponibles:
   ```bash
   ls /usr/share/common-licenses/ | grep -i gpl        # Debian/Ubuntu
   ls /usr/share/licenses/ | grep -i gpl               # RPM
   ```
3. Mirá el encabezado de la GPLv3 (ajustá la ruta según tu distro):
   ```bash
   head -15 /usr/share/common-licenses/GPL-3
   ```
4. Medí la longitud de la GPLv3 en líneas:
   ```bash
   wc -l /usr/share/common-licenses/GPL-3
   ```

**Preguntas:**

- **1.a)** ¿Por qué una distribución guarda copias locales de las licencias en lugar de solo enlazar a un sitio web?
- **1.b)** En el listado del paso 2 aparecen GPL-2 y GPL-3 como archivos separados. ¿Puede un programa seguir usando GPLv2 aunque exista la versión 3? ¿Qué significa la cláusula "or later" (`GPL-2.0-or-later`)?

---

## Ejercicio 2 — Copyleft en el texto de la licencia

El concepto central de la GPL es el **copyleft**: quien redistribuye el software (modificado o no) debe hacerlo bajo la misma licencia y ofrecer el **source code**. Vas a verificarlo en el texto real.

1. Buscá dónde la GPLv3 exige entregar el código fuente:
   ```bash
   grep -n "Corresponding Source" /usr/share/common-licenses/GPL-3 | head -5
   ```
2. Buscá la sección que impide agregar restricciones adicionales:
   ```bash
   grep -n "further restrictions" /usr/share/common-licenses/GPL-3
   ```
3. Ahora compará con una licencia **permisiva**. Descargá la licencia MIT y contá sus líneas:
   ```bash
   curl -s https://raw.githubusercontent.com/licenses/license-templates/master/templates/mit.txt | wc -l
   ```
   (Si no tenés red, alcanza con saber que el texto completo de la MIT ocupa ~20 líneas.)
4. Compará ese número con el resultado del paso 4 del Ejercicio 1.

**Preguntas:**

- **2.a)** Definí **copyleft** con tus palabras. ¿Qué obligación impone al redistribuir un programa GPL modificado?
- **2.b)** Una empresa toma código con licencia **MIT**, lo modifica y lo vende como producto cerrado sin publicar sus cambios. ¿Es legal? ¿Y si el código fuera **GPLv3**?
- **2.c)** ¿A qué categoría pertenece cada una: GPL, MIT, BSD, Apache 2.0? (copyleft fuerte vs. permisiva)

---

## Ejercicio 3 — Averiguar la licencia de los paquetes instalados

Cada paquete de tu sistema declara su licencia en sus metadatos. Vas a consultarlos con el gestor de paquetes.

1. Consultá la licencia de `bash`. En sistemas RPM:
   ```bash
   rpm -qi bash | grep -i license
   ```
   En Debian/Ubuntu no hay campo `License` en los metadatos; se consulta el archivo copyright:
   ```bash
   head -30 /usr/share/doc/bash/copyright
   ```
2. Muchos programas GNU muestran su licencia al pedir la versión:
   ```bash
   bash --version
   ```
   Leé la salida completa: fijate la mención a la GPL y las frases sobre garantía.
3. Repetí con otro programa:
   ```bash
   gcc --version 2>/dev/null || python3 --version
   ```
4. (Solo RPM) Listá las licencias de varios paquetes de una sola vez:
   ```bash
   rpm -qa --qf '%{NAME}: %{LICENSE}\n' | sort | head -20
   ```

**Preguntas:**

- **3.a)** La salida de `bash --version` dice que es "free software" y que se distribuye "without warranty". ¿Free software significa que no se puede cobrar por él?
- **3.b)** En el paso 4 vas a ver licencias distintas (GPLv2, GPLv3+, MIT, BSD, Apache…) conviviendo en el mismo sistema. ¿Quién revisa que todas esas licencias califiquen como "open source"? Nombrá la organización y el documento que usa como criterio.

---

## Ejercicio 4 — Las cuatro libertades del Free Software

La **Free Software Foundation (FSF)**, fundada por Richard Stallman, define el free software mediante cuatro libertades numeradas del 0 al 3.

1. Abrí la definición oficial (en un navegador o con `curl`):
   ```bash
   curl -s https://www.gnu.org/philosophy/free-sw.html | grep -o 'freedom [0-3]' | sort -u
   ```
   URL de referencia: https://www.gnu.org/philosophy/free-sw.html
2. Anotá en un archivo las cuatro libertades con tus palabras:
   ```bash
   nano ~/cuatro-libertades.txt
   ```
   Escribí una línea por libertad (0, 1, 2 y 3) y guardá el archivo.
3. Verificá tu archivo:
   ```bash
   cat ~/cuatro-libertades.txt
   ```

**Preguntas:**

- **4.a)** ¿Cuáles son las cuatro libertades? (Numeralas 0–3.)
- **4.b)** ¿Cuál de las cuatro libertades es imposible de ejercer si el proveedor no entrega el **source code**?
- **4.c)** "Free software" y "open source" describen en la práctica casi el mismo conjunto de programas, pero los términos vienen de organizaciones distintas con énfasis distintos. Explicá la diferencia de enfoque entre la **FSF** y la **OSI (Open Source Initiative)**.
- **4.d)** Un programa **freeware** se descarga gratis pero no publica su código. ¿Es free software? ¿Por qué?

---

## Ejercicio 5 — Modelos de negocio con open source

Que el software sea libre no impide ganar dinero con él. Vas a identificar el modelo de negocio detrás de tu propia distribución.

1. Identificá tu distribución:
   ```bash
   cat /etc/os-release
   ```
2. Mirá los campos `NAME`, `HOME_URL` y, si existe, `SUPPORT_URL`. Visitá el `HOME_URL` y buscá qué ofrece la organización a cambio de dinero (soporte, suscripciones, hardware, cloud, capacitación, certificación).
3. Investigá un caso concreto: Red Hat publica el código de sus productos pero vende **subscriptions** de soporte para **Red Hat Enterprise Linux (RHEL)**, mientras que proyectos comunitarios como Fedora o Debian se financian de otra forma. Anotá dos diferencias que encuentres.
4. Pensá en un ejemplo de **dual licensing**: un mismo producto ofrecido bajo GPL para la comunidad y bajo una licencia comercial para empresas que no quieren las obligaciones del copyleft (caso clásico: MySQL / MariaDB, Qt).

**Preguntas:**

- **5.a)** Nombrá al menos tres modelos de negocio viables alrededor del open source.
- **5.b)** Si cualquiera puede descargar RHEL-como-código y recompilarlo (como hacen Rocky Linux o AlmaLinux), ¿qué está comprando realmente el cliente de Red Hat?
- **5.c)** ¿Por qué el modelo **SaaS** (software as a service) permite usar software GPL sin publicar modificaciones, y qué licencia se creó para cerrar ese hueco?

---

## Ejercicio 6 — Creative Commons: licencias para contenido, no para código

Las licencias **Creative Commons (CC)** se usan para obras creativas y documentación, no para software. Vas a decodificar sus módulos.

1. Abrí https://creativecommons.org/licenses/ y ubicá los cuatro módulos combinables: **BY**, **SA**, **NC**, **ND**.
2. Buscá contenido CC en tu sistema: mucha documentación se publica bajo CC. Por ejemplo:
   ```bash
   grep -ril "creative commons" /usr/share/doc/ 2>/dev/null | head -5
   ```
3. Escribí en un archivo qué permite y qué prohíbe la licencia **CC BY-NC-ND** y compará con **CC BY-SA**:
   ```bash
   nano ~/cc-comparacion.txt
   ```
4. Dato para el examen: los propios materiales de aprendizaje de LPI se publican bajo **CC BY-NC-ND 4.0**. Verificalo al pie de https://learning.lpi.org/en/learning-materials/010-160/1/1.3/

**Preguntas:**

- **6.a)** ¿Qué significa cada módulo: BY, SA, NC, ND?
- **6.b)** ¿Cuál de los módulos de CC es el análogo del copyleft de la GPL?
- **6.c)** ¿Qué variante, **CC0**, no es estrictamente una licencia? ¿Qué hace?
- **6.d)** ¿Por qué una licencia CC con módulo **ND** no calificaría como open source si se aplicara a software?

---

<details>
<summary><strong>✅ Respuestas</strong></summary>

### Ejercicio 1

- **1.a)** Por cumplimiento legal y autonomía: la licencia es parte de las condiciones de distribución del software, así que debe acompañar a los binarios instalados, disponible incluso sin conexión y sin depender de que un sitio externo siga existiendo o cambie su contenido. Además, cientos de paquetes pueden apuntar a una única copia local en lugar de duplicar el texto.
- **1.b)** Sí. Cada versión de la GPL es una licencia independiente; un proyecto puede quedarse en GPLv2 para siempre (el kernel Linux es el ejemplo clásico: es GPLv2 *only*). La cláusula "or later" (`GPL-2.0-or-later`) significa que el receptor puede elegir cumplir esa versión **o cualquier versión posterior** publicada por la FSF, lo que facilita la compatibilidad futura entre proyectos.

### Ejercicio 2

- **2.a)** Copyleft: mecanismo por el cual la licencia exige que toda redistribución de la obra —modificada o no— se haga **bajo la misma licencia**, conservando las libertades para los siguientes receptores. Al redistribuir un programa GPL modificado hay que ofrecer el source code completo correspondiente y no se pueden añadir restricciones adicionales.
- **2.b)** Con MIT es totalmente legal: las licencias permisivas solo exigen, en esencia, conservar el aviso de copyright y la renuncia de garantía; permiten crear derivados cerrados (proprietary). Con GPLv3 no: al **distribuir** el producto derivado estarían obligados a licenciarlo bajo GPLv3 y entregar el código fuente; venderlo cerrado violaría la licencia.
- **2.c)** GPL → **copyleft fuerte**. MIT, BSD y Apache 2.0 → **permisivas** (Apache 2.0 añade una concesión explícita de patentes, pero sigue siendo permisiva). Mención útil: la **LGPL** es un copyleft débil pensado para bibliotecas.

### Ejercicio 3

- **3.a)** No. "Free" refiere a **libertad**, no a precio ("free as in freedom, not as in free beer"). Es perfectamente legal vender free software o cobrar por distribuirlo; lo que no se puede es impedir que el receptor lo use, estudie, modifique y redistribuya.
- **3.b)** La **Open Source Initiative (OSI)**, que aprueba licencias contrastándolas con la **Open Source Definition (OSD)**, un documento de 10 criterios (distribución libre, código fuente disponible, permitir derivados, no discriminar personas ni campos de uso, etc.). Referencia: https://opensource.org/osd

### Ejercicio 4

- **4.a)**
  - **Libertad 0:** ejecutar el programa como quieras, para cualquier propósito.
  - **Libertad 1:** estudiar cómo funciona y modificarlo (requiere acceso al source code).
  - **Libertad 2:** redistribuir copias para ayudar a otros.
  - **Libertad 3:** distribuir copias de tus versiones modificadas (también requiere el source code).
- **4.b)** Las libertades **1 y 3**: sin código fuente no se puede estudiar, modificar ni redistribuir versiones modificadas de forma práctica. Si en el examen piden una sola, la respuesta canónica es la **libertad 1**.
- **4.c)** La **FSF** (Stallman, 1985) plantea el tema como una cuestión **ética y social**: la libertad del usuario es un fin en sí mismo. La **OSI** (1998, a partir del término acuñado por el movimiento open source) enfatiza las ventajas **prácticas y de desarrollo**: calidad, transparencia, colaboración, atractivo para empresas. El conjunto de software que califican es casi idéntico; por eso se usa el término paraguas **FOSS/FLOSS** (Free/Libre and Open Source Software).
- **4.d)** No. Freeware es gratis en precio pero **proprietary** en licencia: no otorga acceso al código ni las libertades 1–3. Gratis ≠ libre.

### Ejercicio 5

- **5.a)** Entre otros: venta de **soporte y subscriptions** (Red Hat, SUSE, Canonical); **dual licensing** (Qt, MySQL); **open core** (versión base libre + funciones enterprise cerradas); **SaaS/hosting** del software libre (GitLab.com, WordPress.com); **capacitación y certificación**; **donaciones y fundaciones** (Debian, Apache Software Foundation); venta de **hardware** que integra software libre.
- **5.b)** No compra el código: compra la **subscription** — soporte con SLA, actualizaciones y parches de seguridad certificados, garantías legales/indemnización, certificaciones de hardware y software de terceros, y acceso a ingeniería del fabricante. El valor está en el servicio y la confianza, no en los bits.
- **5.c)** Porque la GPL clásica impone obligaciones al **distribuir** el software, y ofrecerlo como servicio por red no constituye distribución: el binario nunca sale del servidor del proveedor (el llamado "ASP/SaaS loophole"). Para cerrarlo se creó la **AGPL (GNU Affero GPL)**, que extiende el copyleft a la interacción por red: quien ofrece un servicio con software AGPL modificado debe ofrecer el código fuente a sus usuarios remotos.

### Ejercicio 6

- **6.a)**
  - **BY (Attribution):** hay que dar crédito al autor original. Presente en todas las licencias CC salvo CC0.
  - **SA (ShareAlike):** las obras derivadas deben compartirse bajo la misma licencia.
  - **NC (NonCommercial):** prohíbe usos comerciales.
  - **ND (NoDerivatives):** prohíbe distribuir obras modificadas/derivadas.
- **6.b)** **SA (ShareAlike)**: igual que el copyleft, obliga a que los derivados hereden la misma licencia.
- **6.c)** **CC0** es una **dedicación al dominio público** (public domain dedication): el autor renuncia a todos los derechos en la medida que la ley lo permita, sin exigir siquiera atribución. No impone condiciones, por eso no funciona como licencia condicional.
- **6.d)** Porque prohibir obras derivadas contradice tanto la libertad 3 de la FSF como el criterio de la Open Source Definition que exige permitir modificaciones y trabajos derivados. Por la misma razón, el módulo **NC** también sería incompatible (la OSD prohíbe discriminar campos de actividad, incluido el comercial).

</details>

---

*Material original elaborado con fines de estudio. Referencias consultadas: [LPI Learning Materials 010-160, Lesson 1.3](https://learning.lpi.org/en/learning-materials/010-160/1/1.3/) · [GNU — Free Software Definition](https://www.gnu.org/philosophy/free-sw.html) · [Open Source Definition (OSI)](https://opensource.org/osd) · [Creative Commons Licenses](https://creativecommons.org/licenses/).*