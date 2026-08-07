# LPI 702-100 (v1.0) Guía de Estudio: Tema 715.4 - Uso de Expresiones Regulares Simples

**Certificación:** LPI BSD Specialist (Examen 702-100, Versión 1.0)  
**Tema:** 715.4 Uso de Expresiones Regulares Simples  
**Peso:** 3.33  
**Referencia Oficial:** [LPI BSD Specialist Overview](https://www.lpi.org/our-certifications/bsd-specialist-overview/)

---

## Análisis Técnico Profundo y Arquitectura

### 1. Mecánica del Motor Regex en BSD Unix
Los sistemas operativos BSD modernos (FreeBSD, OpenBSD, NetBSD) procesan expresiones regulares usando motores de compilación y ejecución basados en especificaciones POSIX (interfaz de biblioteca C estándar `regex(3)`). Los motores de expresiones regulares se categorizan en dos modelos arquitectónicos primarios:

1. **Autómatas Finitos Deterministas (DFA):**
   - Traduce expresiones regulares en tablas de transición de estados.
   - Garantiza tiempo de ejecución $O(N)$ relativo a la longitud de la cadena de entrada $N$.
   - No admite backreferences (`\1`, `\2`) ni aserciones lookaround.
   - El `grep` BSD estándar utiliza un motor de búsqueda rápida primario DFA para escanear archivos de registro rápidamente.

2. **Autómatas Finitos No Deterministas (NFA):**
   - Evalúa rutas de estado dinámicamente y utiliza **backtracking** cuando una rama no logra coincidir.
   - La complejidad temporal en el peor de los casos puede escalarse a exponencial $O(2^N)$ (catastrophic backtracking) con cuantificadores mal delimitados.
   - Evalúa Expresiones Regulares Básicas (BRE) y Expresiones Regulares Extendidas (ERE) POSIX estándar cuando se invocan características avanzadas (como agrupación de subexpresiones y backreferencing).

```
                     +---------------------------------------+
                     |         Input Text Stream             |
                     +---------------------------------------+
                                         |
                                         v
                     +---------------------------------------+
                     |       POSIX regex(3) Compiler         |
                     |  (Parse Pattern -> AST -> Automata)   |
                     +---------------------------------------+
                                         |
                       +-----------------+-----------------+
                       |                                   |
                       v                                   v
         +---------------------------+       +---------------------------+
         |     DFA Fast Engine       |       |   NFA Backtracking Engine |
         |   (Literal / Fixed Set)   |       |  (Subexpressions / BRE)   |
         |   Linear Time: O(N)       |       |   Supports Backreferences |
         +---------------------------+       +---------------------------+
                       |                                   |
                       +-----------------+-----------------+
                                         |
                                         v
                     +---------------------------------------+
                     |      Matched Line / Output Buffer     |
                     +---------------------------------------+
```

### 2. Estándares POSIX: Metacaracteres Básicos (BRE) vs. Extendidos (ERE)

POSIX estandariza dos dialectos de regex en las utilidades base de BSD (`grep`, `sed`, `awk`):

| Característica / Metacarácter | Basic Regular Expression (BRE) | Extended Regular Expression (ERE) |
| :--- | :--- | :--- |
| **Caracteres Literales** | `a-z`, `A-Z`, `0-9`, `_` | `a-z`, `A-Z`, `0-9`, `_` |
| **Cualquier Carácter Individual** | `.` | `.` |
| **Cero o Más Repeticiones**| `*` | `*` |
| **Una o Más Repeticiones** | `\+` (extensión BSD) | `+` |
| **Cero o Una Repetición** | `\?` (extensión BSD) | `?` |
| **Cuantificador de Intervalo** | `\{m,n\}` | `{m,n}` |
| **Grupo / Subexpresión** | `\(` ... `\)` | `(` ... `)` |
| **Alternancia (OR)** | `\|` (extensión BSD) | `\|` |
| **Ancla de Inicio de Línea** | `^` | `^` |
| **Ancla de Fin de Línea** | `$` | `$` |
| **Ancla de Límite de Palabra** | `\<`, `\>` o `[[:<:]]`, `[[:>:]]` | `\<`, `\>` o `[[:<:]]`, `[[:>:]]` |

> [!IMPORTANT]
> En **BRE** (usado por defecto en `grep` y `sed` estándar de BSD), los paréntesis de agrupación `(` `)` y los límites de intervalo `{` `}` se tratan como caracteres literales a menos que se escapen con una barra invertida (`\(` `\)`, `\{m,n\}`). En **ERE** (invocado con `grep -E` o `egrep`), estos caracteres son metacaracteres por defecto, y las barras invertidas eliminan su significado especial.

### 3. Expresiones entre Corchetes POSIX y Clases de Caracteres
El uso de rangos como `[a-z]` o `[0-9]` puede introducir errores sutiles cuando las configuraciones de locale (`LC_COLLATE`) difieren del orden ASCII estándar. Las clases de caracteres POSIX garantizan una evaluación predecible e independiente del locale:

- `[[:alnum:]]`: Caracteres alfanuméricos (`[A-Za-z0-9]`)
- `[[:alpha:]]`: Caracteres alfabéticos (`[A-Za-z]`)
- `[[:digit:]]`: Caracteres numéricos (`[0-9]`)
- `[[:space:]]`: Caracteres de espacio en blanco (espacio, tabulación, salto de línea, tabulación vertical, avance de página)
- `[[:xdigit:]]`: Dígitos hexadecimales (`[0-9a-fA-F]`)
- `[[:punct:]]`: Caracteres de puntuación (`!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~`)

La negación dentro de los conjuntos de caracteres se declara utilizando un acento circunflejo inmediatamente después del corchete de apertura:
- `[^0-9]`: Cualquier carácter que **no** sea un dígito.
- `[^[:space:]]`: Cualquier carácter que no sea espacio en blanco.

### 4. Shell Globbing vs. Expresiones Regulares

Un modo de fallo fundamental en las operaciones de SRE proviene de confundir **Shell Globbing** (expansión de nombres de ruta ejecutada por shells BSD estándar como `/bin/sh`, `/bin/csh` o `/bin/zsh`) con **Expresiones Regulares** (análisis del contenido de cadenas ejecutado por `grep`, `sed` o `awk`).

```
                    +------------------------------------------+
                    |   User Shell Command Execution Path      |
                    +------------------------------------------+
                                         |
                                         v
                    +------------------------------------------+
                    |           Phase 1: Shell Expansion       |
                    | Parses unquoted globs (*, ?, [...])      |
                    | against the local filesystem directory.  |
                    +------------------------------------------+
                                         |
                                         v
                    +------------------------------------------+
                    |      Phase 2: Process Invocation         |
                    | Passes expanded ARGV array to `grep`.   |
                    +------------------------------------------+
                                         |
                                         v
                    +------------------------------------------+
                    |            Phase 3: Regex Match          |
                    | `grep` compiles string argument into NFA |
                    | engine and reads file stream contents.   |
                    +------------------------------------------+
```

Diferencias operativas clave:

1. **Tiempo de Evaluación:** Los globs son evaluados por la shell *antes* de que se ejecute el comando. Las expresiones regulares son evaluadas línea por línea por el proceso objetivo *durante* la lectura del archivo.
2. **Significado del Cuantificador `*`:**
   - Shell Globbing: `*` coincide con **cero o más caracteres arbitrarios** en nombres de archivos (por ejemplo, `*.log`).
   - Expresiones Regulares: `*` modifica el token precedente para coincidir con **cero o más ocurrencias** de ese elemento específico (por ejemplo, `a*` coincide con `""`, `"a"`, `"aa"`).
3. **Significado del Carácter `?`:**
   - Shell Globbing: `?` coincide con **exactamente un carácter** (por ejemplo, `file?.txt`).
   - Expresiones Regulares (ERE): `?` denota **cero o una ocurrencia** del átomo precedente.

---

## Ejercicios Guiados de Producción

### Inicialización del Entorno
Ejecutá el siguiente bloque en un host BSD o terminal POSIX estándar para generar el archivo de registro de auditoría empresarial multitenant realista requerido para estos ejercicios:

```bash
cat << 'EOF' > /tmp/sre_audit.log
2026-08-06T14:00:01Z host-01 pf: [PASS] src=192.168.1.50 dst=10.0.0.1 proto=tcp port=443 flags=SYN
2026-08-06T14:00:02Z host-02 sysctl: kern.securelevel changed from 1 to 2
2026-08-06T14:00:05Z host-01 pf: [BLOCK] src=45.33.32.156 dst=10.0.0.1 proto=tcp port=22 flags=SYN
2026-08-06T14:00:12Z host-03 sshd[4821]: Failed password for root from 192.168.1.120 port 54112 ssh2
2026-08-06T14:00:15Z host-03 sshd[4825]: Accepted publickey for admin from 192.168.1.50 port 54118 ssh2
2026-08-06T14:00:22Z host-01 pf: [BLOCK] src=192.168.1.188 dst=10.0.0.1 proto=udp port=53
2026-08-06T14:01:00Z host-02 pkg: upgraded nginx-1.24.0,1 to nginx-1.26.1,1
2026-08-06T14:01:30Z host-01 pf: [BLOCK] src=10.0.0.50 dst=10.0.0.1 proto=icmp type=8
2026-08-06T14:02:00Z host-04 kernel: arprequest: cannot find matching subnet for 172.16.0.5
2026-08-06T14:02:05Z host-03 sshd[4910]: Invalid user deploy from 192.168.1.200 port 61200
EOF
```

---

### Ejercicio 1: Coincidencia Básica, Anclaje y Selección de Líneas (BRE)

#### Objetivo
Dominar los operadores de ancla (`^`, `$`) y los flags de filtrado de líneas (`-v`, `-n`, `-c`) utilizando Expresiones Regulares Básicas para extraer datos de telemetría de manera precisa.

#### Pasos a Ejecutar

1. **Coincidir con líneas que comienzan con una hora de marca de tiempo específica:**
   Extraer todas las entradas de registro que ocurren durante el minuto `14:01` utilizando el ancla de inicio de línea (`^`).

   ```bash
   grep '^2026-08-06T14:01' /tmp/sre_audit.log
   ```

   **Expected Output:**
   ```text
   2026-08-06T14:01:00Z host-02 pkg: upgraded nginx-1.24.0,1 to nginx-1.26.1,1
   2026-08-06T14:01:30Z host-01 pf: [BLOCK] src=10.0.0.50 dst=10.0.0.1 proto=icmp type=8
   ```

2. **Coincidir con líneas que terminan con una palabra específica:**
   Filtrar todas las entradas que terminan con `ssh2` usando el ancla de fin de línea (`$`).

   ```bash
   grep 'ssh2$' /tmp/sre_audit.log
   ```

   **Expected Output:**
   ```text
   2026-08-06T14:00:12Z host-03 sshd[4821]: Failed password for root from 192.168.1.120 port 54112 ssh2
   2026-08-06T14:00:15Z host-03 sshd[4825]: Accepted publickey for admin from 192.168.1.50 port 54118 ssh2
   ```

3. **Invertir la coincidencia para aislar eventos que no son de firewall con números de línea:**
   Usar `-v` para excluir las entradas del filtro de paquetes (`pf:`) y `-n` para mostrar los números de línea para el seguimiento de auditoría.

   ```bash
   grep -v -n 'pf:' /tmp/sre_audit.log
   ```

   **Expected Output:**
   ```text
   2:2026-08-06T14:02Z host-02 sysctl: kern.securelevel changed from 1 to 2
   4:2026-08-06T14:00:12Z host-03 sshd[4821]: Failed password for root from 192.168.1.120 port 54112 ssh2
   5:2026-08-06T14:00:15Z host-03 sshd[4825]: Accepted publickey for admin from 192.168.1.50 port 54118 ssh2
   7:2026-08-06T14:01:00Z host-02 pkg: upgraded nginx-1.24.0,1 to nginx-1.26.1,1
   9:2026-08-06T14:02:00Z host-04 kernel: arprequest: cannot find matching subnet for 172.16.0.5
   10:2026-08-06T14:02:05Z host-03 sshd[4910]: Invalid user deploy from 192.168.1.200 port 61200
   ```

4. **Contar el total de eventos de bloqueo del firewall:**
   Contar las líneas que coinciden con el patrón literal `[BLOCK]`. Tened en cuenta que los corchetes deben escaparse en BRE o incluirse en una clase de caracteres para evitar tratarlos como delimitadores de conjunto.

   ```bash
   grep -c '\[BLOCK\]' /tmp/sre_audit.log
   ```

   **Expected Output:**
   ```text
   3
   ```

---

#### Preguntas de Verificación - Ejercicio 1

1. Si ejecutás el comando `grep '^' /tmp/sre_audit.log`, ¿qué se devolverá y por qué?
2. ¿Cuál es la diferencia técnica entre ejecutar `grep 'SYN' /tmp/sre_audit.log` frente a `grep 'SYN$' /tmp/sre_audit.log`?
3. ¿Qué ocurre si un usuario ejecuta `grep [BLOCK] /tmp/sre_audit.log` sin comillas simples ni barras invertidas en un directorio que contiene un archivo llamado `B`?

---

### Ejercicio 2: Conjuntos de Caracteres, Negación y Clases POSIX

#### Objetivo
Utilizar rangos de caracteres personalizados (`[...]`), conjuntos negados (`[^...]`) y corchetes POSIX (`[[:digit:]]`, `[[:alpha:]]`) para extraer indicadores de compromiso (IOC) estructurados.

#### Pasos a Ejecutar

1. **Extraer líneas de registro originadas en instancias de host específicas:**
   Filtrar para `host-01` y `host-03` usando un conjunto de caracteres.

   ```bash
   grep 'host-0[13]' /tmp/sre_audit.log
   ```

   **Expected Output:**
   ```text
   2026-08-06T14:00:01Z host-01 pf: [PASS] src=192.168.1.50 dst=10.0.0.1 proto=tcp port=443 flags=SYN
   2026-08-06T14:00:05Z host-01 pf: [BLOCK] src=45.33.32.156 dst=10.0.0.1 proto=tcp port=22 flags=SYN
   2026-08-06T14:00:12Z host-03 sshd[4821]: Failed password for root from 192.168.1.120 port 54112 ssh2
   2026-08-06T14:00:15Z host-03 sshd[4825]: Accepted publickey for admin from 192.168.1.50 port 54118 ssh2
   2026-08-06T14:00:22Z host-01 pf: [BLOCK] src=192.168.1.188 dst=10.0.0.1 proto=udp port=53
   2026-08-06T14:01:30Z host-01 pf: [BLOCK] src=10.0.0.50 dst=10.0.0.1 proto=icmp type=8
   2026-08-06T14:02:05Z host-03 sshd[4825]: Accepted publickey for admin... -> host-03 lines
   ```

2. **Coincidir con tráfico de red de IP de origen no interna:**
   Encontrar entradas de registro del firewall donde la dirección IP externa **no** comience con `192.` ni `10.`. Usar una clase de caracteres negada.

   ```bash
   grep 'src=[^1]' /tmp/sre_audit.log
   ```

   **Expected Output:**
   ```text
   2026-08-06T14:00:05Z host-01 pf: [BLOCK] src=45.33.32.156 dst=10.0.0.1 proto=tcp port=22 flags=SYN
   ```

3. **Aislar identificadores de procesos utilizando clases de caracteres POSIX:**
   Localizar todas las líneas que contienen `sshd` con su ID de proceso asociado entre corchetes usando `[[:digit:]]`.

   ```bash
   grep 'sshd\[[[:digit:]][[:digit:]][[:digit:]][[:digit:]]\]' /tmp/sre_audit.log
   ```

   **Expected Output:**
   ```text
   2026-08-06T14:00:12Z host-03 sshd[4821]: Failed password for root from 192.168.1.120 port 54112 ssh2
   2026-08-06T14:00:15Z host-03 sshd[4825]: Accepted publickey for admin from 192.168.1.50 port 54118 ssh2
   2026-08-06T14:02:05Z host-03 sshd[4910]: Invalid user deploy from 192.168.1.200 port 61200
   ```

---

#### Preguntas de Verificación - Ejercicio 2

1. ¿En qué se diferencia fundamentalmente la regex `[^0-9]` de `^0-9` cuando se evalúa dentro de un motor de patrones BRE?
2. ¿Cuál es el resultado de usar la expresión `[a-z]` bajo un locale distinto de C (por ejemplo, `en_US.UTF-8`) en comparación con el uso de `[[:lower:]]`?
3. Escribí una expresión regular utilizando clases de caracteres POSIX para coincidir con cualquier línea de registro que contenga un identificador de protocolo de 3 caracteres (por ejemplo, `tcp`, `udp`).

---

### Ejercicio 3: Expresiones Regulares Extendidas (ERE), Repetición Acotada y Límites de Palabra

#### Objetivo
Aprovechar ERE (`grep -E`), límites explícitos (`{m,n}`), alternancia (`|`) y anclas de palabra (`\<`, `\>`) para analizar patrones de seguridad complejos.

#### Pasos a Ejecutar

1. **Filtrar múltiples tipos de protocolos usando Alternancia ERE:**
   Extraer líneas de registro que detallen eventos `udp` o `icmp` usando `grep -E`.

   ```bash
   grep -E 'proto=(udp|icmp)' /tmp/sre_audit.log
   ```

   **Expected Output:**
   ```text
   2026-08-06T14:00:22Z host-01 pf: [BLOCK] src=192.168.1.188 dst=10.0.0.1 proto=udp port=53
   2026-08-06T14:01:30Z host-01 pf: [BLOCK] src=10.0.0.50 dst=10.0.0.1 proto=icmp type=8
   ```

2. **Coincidir con límites exactos de octetos IPv4 con cuantificadores de intervalo:**
   Coincidir con direcciones IP que comiencen con `192.168.` seguidas de una dirección de host de 1 a 3 dígitos.

   ```bash
   grep -E '192\.168\.1\.[0-9]{1,3}' /tmp/sre_audit.log
   ```

   **Expected Output:**
   ```text
   2026-08-06T14:00:01Z host-01 pf: [PASS] src=192.168.1.50 dst=10.0.0.1 proto=tcp port=443 flags=SYN
   2026-08-06T14:00:12Z host-03 sshd[4821]: Failed password for root from 192.168.1.120 port 54112 ssh2
   2026-08-06T14:00:15Z host-03 sshd[4825]: Accepted publickey for admin from 192.168.1.50 port 54118 ssh2
   2026-08-06T14:00:22Z host-01 pf: [BLOCK] src=192.168.1.188 dst=10.0.0.1 proto=udp port=53
   2026-08-06T14:02:05Z host-03 sshd[4910]: Invalid user deploy from 192.168.1.200 port 61200
   ```

3. **Forzar la coincidencia exacta de límites de palabra:**
   Demostrar la diferencia entre coincidir con la subcadena `port` y la palabra exacta `port` delimitada por anclas de palabra BSD (`\<` y `\>`).

   ```bash
   grep -E '\<port\>' /tmp/sre_audit.log
   ```

   **Expected Output:**
   ```text
   2026-08-06T14:00:01Z host-01 pf: [PASS] src=192.168.1.50 dst=10.0.0.1 proto=tcp port=443 flags=SYN
   2026-08-06T14:00:05Z host-01 pf: [BLOCK] src=45.33.32.156 dst=10.0.0.1 proto=tcp port=22 flags=SYN
   2026-08-06T14:00:12Z host-03 sshd[4821]: Failed password for root from 192.168.1.120 port 54112 ssh2
   2026-08-06T14:00:15Z host-03 sshd[4825]: Accepted publickey for admin from 192.168.1.50 port 54118 ssh2
   2026-08-06T14:00:22Z host-01 pf: [BLOCK] src=192.168.1.188 dst=10.0.0.1 proto=udp port=53
   2026-08-06T14:02:05Z host-03 sshd[4910]: Invalid user deploy from 192.168.1.200 port 61200
   ```

---

#### Preguntas de Verificación - Ejercicio 3

1. ¿Por qué el comando `grep 'proto=(udp|icmp)' /tmp/sre_audit.log` (sin `-E`) no logra devolver coincidencias en un sistema BSD estándar?
2. ¿Qué sintaxis de límite de palabra POSIX en BSD es equivalente a `\<` y `\>`?
3. Explicá la diferencia en la ejecución entre `grep -E 'go*d'` y `grep -E 'go+d'` al analizar cadenas como `"gd"`, `"god"` y `"good"`.

---

### Ejercicio 4: Transformación de Flujos y Análisis a Través de `sed` y `awk`

#### Objetivo
Aplicar expresiones regulares dentro de tuberías de flujo no interactivo (`sed`) y escáner de patrones tabulares (`awk`).

#### Pasos a Ejecutar

1. **Extraer y reformatear direcciones IP usando grupos de captura de `sed` (BRE):**
   Analizar entradas de registro de `sshd` y extraer solo la dirección IP de origen utilizando grupos de captura de subexpresiones (`\(` ... `\)`).

   ```bash
   sed -n 's/.*from \([0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\).*/SRC_IP: \1/p' /tmp/sre_audit.log
   ```

   **Expected Output:**
   ```text
   SRC_IP: 192.168.1.120
   SRC_IP: 192.168.1.50
   SRC_IP: 192.168.1.200
   ```

2. **Filtrar e imprimir campos específicos usando coincidencia condicional regex de `awk`:**
   Usar `awk` para coincidir con líneas que contienen `[BLOCK]` e imprimir la marca de tiempo (campo 1) y el nombre de host (campo 2).

   ```bash
   awk '/\[BLOCK\]/ {print $1, $2, $5}' /tmp/sre_audit.log
   ```

   **Expected Output:**
   ```text
   2026-08-06T14:00:05Z host-01 src=45.33.32.156
   2026-08-06T14:00:22Z host-01 src=192.168.1.188
   2026-08-06T14:01:30Z host-01 src=10.0.0.50
   ```

---

#### Preguntas de Verificación - Ejercicio 4

1. En el comando de sustitución de `sed` `s/pattern/replacement/p`, ¿cuál es la función del flag final `/p` cuando se combina con la opción `-n`?
2. ¿Cómo maneja `awk` la evaluación de expresiones regulares al usar el operador `~` (por ejemplo, `$5 ~ /src=192/`) frente a la coincidencia de patrones simples `/src=192/`?

---

## Diagnóstico en Producción y Optimización de Rendimiento

### 1. Búsqueda de Registros de Alto Rendimiento mediante Optimización de Locale (`LC_ALL=C`)
En tuberías de análisis de registros de producción de varios gigabytes en hosts BSD, las configuraciones de locale UTF-8 predeterminadas obligan a `grep` a inspeccionar secuencias de bytes de caracteres para determinar los límites de Unicode multibyte.

Para optimizar el rendimiento de los archivos de registro ASCII estándar, anula explícitamente el locale al locale binario `C` (POSIX):

```bash
# Standard UTF-8 processing (slower, multibyte lookup overhead)
time grep -E 'src=192\.168\.[0-9]{1,3}\.[0-9]{1,3}' /var/log/security.log

# Production SRE High-Speed Execution (up to 10x - 100x performance gain)
time LC_ALL=C grep -E 'src=192\.168\.[0-9]{1,3}\.[0-9]{1,3}' /var/log/security.log
```

**Razón Técnica:** `LC_ALL=C` omite las complejas tablas de traducción multibyte `mbrtowc`, lo que permite a `grep` de BSD realizar escaneos directos de memoria de un solo byte utilizando primitivas de instrucciones de cadenas y `memchr` puras.

### 2. Diferencias de Flags entre BSD `grep` y GNU `grep`
Los administradores de sistemas que migran entre entornos Linux y BSD deben reconocer las restricciones de sintaxis:

- BSD `grep` utiliza `[[:<:]]` y `[[:>:]]` o `\<` y `\>` para los límites de palabra.
- Las extensiones GNU como `\s` (espacio en blanco) o `\d` (dígito) no son estándar en POSIX BRE/ERE. Los scripts de producción diseñados para ser portables entre FreeBSD, OpenBSD y Linux deben usar clases de caracteres POSIX (`[[:space:]]`, `[[:digit:]]`) en lugar de adaptadores compatibles con Perl (`\s`, `\d`).

---

## Clave de Respuestas de Verificación

<details>
<summary>Click para desplegar la Clave de Respuestas</summary>

### Respuestas del Ejercicio 1

1. **Pregunta:** Si ejecutás `grep '^' /tmp/sre_audit.log`, ¿qué se devolverá y por qué?  
   **Respuesta:** Se devolverá cada línea del archivo. El acento circunflejo `^` ancla la búsqueda al inicio de la línea. Dado que cada línea tiene una posición inicial (incluso una línea vacía), cada línea coincide.

2. **Pregunta:** ¿Cuál es la diferencia técnica entre `grep 'SYN' /tmp/sre_audit.log` frente a `grep 'SYN$' /tmp/sre_audit.log`?  
   **Respuesta:** `grep 'SYN'` coincide con la secuencia de caracteres literal "SYN" en cualquier lugar dentro de una línea (por ejemplo, `SYN_SENT`, `SYN-ACK`, o al final de una línea). `grep 'SYN$'` coincide strictly con las líneas donde "SYN" ocurre como los tres caracteres finales antes del salto de línea.

3. **Pregunta:** ¿Qué ocurre si un usuario ejecuta `grep [BLOCK] /tmp/sre_audit.log` sin comillas simples ni barras invertidas en un directorio que contiene un archivo llamado `B`?  
   **Respuesta:** La shell de BSD realiza la expansión de globbing en `[BLOCK]` sin comillas *antes* de ejecutar `grep`. Si existe un archivo llamado `B` en el directorio de trabajo actual, la shell expande `[BLOCK]` (que coincide con un carácter entre B, L, O, C, K) a `B`. Luego `grep` se ejecuta como `grep B /tmp/sre_audit.log`, buscando líneas que contengan la letra 'B' en lugar de buscar la cadena literal "[BLOCK]".

---

### Respuestas del Ejercicio 2

1. **Pregunta:** ¿En qué se diferencia fundamentalmente `[^0-9]` de `^0-9` dentro de un motor de patrones BRE?  
   **Respuesta:** `[^0-9]` usa `^` como el primer carácter dentro de los corchetes para denotar la **negación** del conjunto, coincidiendo con cualquier carácter individual que *no* sea un dígito. `^0-9` usa `^` fuera de los corchetes como un **ancla de inicio de línea**, intentando coincidir con una línea que comience literalmente con "0-9".

2. **Pregunta:** ¿Cuál es el resultado de usar `[a-z]` bajo un locale distinto de C (por ejemplo, `en_US.UTF-8`) frente a `[[:lower:]]`?  
   **Respuesta:** Bajo reglas de intercalación (collation) distintas de C, `[a-z]` puede coincidir con caracteres en mayúscula según el orden de clasificación del diccionario (por ejemplo, `a, A, b, B... z`). `[[:lower:]]` fuerza explícitamente al motor de regex POSIX a referenciar la propiedad del conjunto de caracteres en minúscula del locale, garantizando el aislamiento de los caracteres alfabéticos en minúscula.

3. **Pregunta:** Escribí una expresión regular utilizando clases de caracteres POSIX para coincidir con cualquier línea de registro que contenga un identificador de protocolo de 3 caracteres (por ejemplo, `tcp`, `udp`).  
   **Respuesta:** `proto=[[:alpha:]]{3}` (cuando se evalúa con ERE) o `proto=[[:alpha:]]\{3\}` (cuando se evalúa con BRE). Alternativamente: `proto=[[:lower:]][[:lower:]][[:lower:]]`.

---

### Respuestas del Ejercicio 3

1. **Pregunta:** ¿Por qué `grep 'proto=(udp|icmp)' /tmp/sre_audit.log` (sin `-E`) no logra devolver coincidencias en un sistema BSD estándar?  
   **Respuesta:** El `grep` estándar utiliza por defecto Expresiones Regulares Básicas (BRE). En BRE, `(` `)` y `|` sin escapar se tratan como caracteres literales. Para tratarlos como metacaracteres para agrupación y alternancia en BRE, se deben escapar (`\(` `\)`, `\|`), o el comando debe habilitar Expresiones Regulares Extendidas usando `grep -E`.

2. **Pregunta:** ¿Qué sintaxis de límite de palabra POSIX en BSD es equivalente a `\<` y `\>`?  
   **Respuesta:** `[[:<:]]` (inicio de palabra) y `[[:>:]]` (fin de palabra).

3. **Pregunta:** Explicá la diferencia en la ejecución entre `grep -E 'go*d'` y `grep -E 'go+d'`.  
   **Respuesta:** El cuantificador `*` coincide con **cero o más** ocurrencias de 'o'. Por lo tanto, `go*d` coincide con `"gd"`, `"god"` y `"good"`. El cuantificador `+` coincide con **una o más** ocurrencias de 'o'. Por lo tanto, `go+d` coincide con `"god"` y `"good"`, pero no logra coincidir con `"gd"`.

---

### Respuestas del Ejercicio 4

1. **Pregunta:** En `sed -n 's/pattern/replacement/p'`, ¿cuál es la función de `/p` cuando se combina con `-n`?  
   **Respuesta:** El flag `-n` suprime el comportamiento predeterminado de `sed` de imprimir cada línea del búfer de entrada en stdout. El flag final `/p` instruye a `sed` a imprimir *solo* las líneas donde ocurrió una sustitución de regex exitosa.

2. **Pregunta:** ¿Cómo maneja `awk` la evaluación al usar `$5 ~ /src=192/` frente a `/src=192/`?  
   **Respuesta:** `/src=192/` evalúa la regex contra el **registro completo** (`$0`, la línea completa). `$5 ~ /src=192/` restringe la evaluación de la regex específicamente al contenido del **campo 5**, devolviendo verdadero solo si el campo 5 coincide con el patrón.

</details>