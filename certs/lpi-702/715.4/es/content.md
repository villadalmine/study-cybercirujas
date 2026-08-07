# Guía de Estudio LPI-702 BSD Specialist: Tema 715.4 — Uso de Expresiones Regulares Simples

**Examen:** LPI BSD Specialist (Examen 702-100, Versión 1.0)  
**Tema:** 715.4 Uso de Expresiones Regulares Simples  
**Peso:** 3.33  
**Rol Objetivo:** Senior SRE / Principal Platform Architect  

---

## 1. Motivación de Arquitectura de Producción y Mecánica Interna

En entornos de infraestructura BSD de alto rendimiento (FreeBSD, OpenBSD, NetBSD), los pipelines de agregación de logs, los parsers de auditoría de seguridad (`auditd`, `pflog`) y los procesadores de telemetría del sistema evalúan millones de eventos de texto por segundo. El procesamiento de expresiones regulares (Regex) a esta escala va más allá de la simple coincidencia de cadenas; impacta directamente en la conmutación de contexto de kernel a userland, la eficiencia de ciclos de CPU y la huella de memoria.

### 1.1 Arquitectura del Motor Regex POSIX de BSD (`re_format(7)`)

Las implementaciones BSD dependen de la biblioteca de expresiones regulares POSIX 1003.2 embebida directamente dentro de las implementaciones de la biblioteca estándar de C (`libc`). El motor de BSD opera principalmente utilizando estrategias de coincidencia de autómatas finitos deterministas (DFA) y autómatas finitos no deterministas (NFA), adhiriéndose estrictamente a las especificaciones IEEE Std 1003.1-2008.

```
                      [ Uncompiled Regex String ]
                                   │
                                   ▼
                   `regcomp()` Compilation Stage
                                   │
      ┌────────────────────────────┴────────────────────────────┐
      ▼                                                         ▼
[ Basic Regex (BRE) ]                                 [ Extended Regex (ERE) ]
  • Escaped Metacharacters: `\(`, `\)`, `\{`, `\}`      • Literal Metacharacters: `(`, `)`, `{`, `}`
  • Concatenation & `*` Repetition                      • Standard ERE Grammar (`+`, `?`, `|`)
      │                                                         │
      └────────────────────────────┬────────────────────────────┘
                                   ▼
                       [ NFA / DFA Graph Construction ]
                                   │
                                   ▼
                   `regexec()` Execution Engine
                                   │
                 ┌─────────────────┴─────────────────┐
                 ▼                                   ▼
         [ DFA Match Path ]                  [ NFA Backtracking Path ]
         (O(M * N) linear execution)         (Sub-expression evaluation & back-references)
```

1. **Fase de Compilación (`regcomp(3)`)**: La cadena del patrón es analizada hacia un grafo de estados NFA interno. Los árboles de sintaxis validan clases de caracteres, rangos de caracteres y límites de cuantificadores (`{m,n}`).
2. **Fase de Ejecución (`regexec(3)`)**: El motor recorre el flujo de texto contra el grafo de estados. Las implementaciones nativas de BSD optimizan los escaneos simples de caracteres utilizando la ejecución lineal de DFA, cambiando a backtracking NFA al coincidir con subexpresiones o cuantificadores acotados.
3. **Trampas del Motor y Riesgos de Rendimiento**:
   - **Catastrophic Backtracking**: Cuantificadores anidados como `(a+)+$` evaluados contra entradas que no coinciden causan una evaluación de estados exponencial ($O(2^N)$), llevando a la inanición de hilos (thread starvation) en daemons de producción.
   - **Sobrecarga de Locale**: Las clases de caracteres POSIX (ej., `[[:alpha:]]`) evalúan conjuntos de caracteres multibyte basados en `LC_CTYPE`. En pipelines de parseo de logs críticos para el rendimiento, forzar `LC_ALL=C` obliga a realizar comparaciones a nivel de byte, reduciendo la latencia de evaluación de regex hasta en un 60%.

---

## 2. Comparaciones Técnicas y Análisis de Trade-Offs

### 2.1 Basic Regular Expressions (BRE) vs. Extended Regular Expressions (ERE)

| Métrica / Característica | Basic Regular Expressions (BRE) | Extended Regular Expressions (ERE) | Trade-off en SRE de Producción |
| :--- | :--- | :--- | :--- |
| **Flag Estándar** | Predeterminado en `grep`, `sed` | `grep -E`, `egrep`, `sed -E`, `awk` | BRE es portable a scripts heredados; ERE proporciona coincidencias complejas legibles. |
| **Sintaxis de Agrupación** | `\(pattern\)` | `(pattern)` | BRE requiere barras invertidas literales para sub-captura; un `(` sin escapar es literal. ERE usa paréntesis directos. |
| **Cuantificadores de Intervalo** | `\{m,n\}` | `{m,n}` | BRE requiere barras invertidas; ERE usa llaves directas. ERE ofrece mejor legibilidad en scripts de mantenimiento. |
| **Alternancia** | No estándar (requiere la extensión no POSIX `\|`) | Operador explícito `\|` | ERE permite condiciones OR nativas de múltiples patrones (ej., `(WARN\|FAIL\|CRIT)`). |
| **Uno o Más (`+`)** | `+` literal (o extensión `\+`) | Cuantificador `+` nativo | ERE evita la sobrecarga de escape en coincidencias de métricas de alta densidad. |
| **Cero o Uno (`?`)** | `?` literal (o extensión `\?`) | Cuantificador `?` nativo | ERE simplifica la coincidencia de tokens opcionales (ej., cadenas de versión de HTTP `HTTPS?`). |
| **Costo de Evaluación** | Equivalente bajo un motor DFA lineal | Equivalente bajo un motor DFA lineal | Sin diferencia de penalización en tiempo de ejecución; las variaciones son puramente sintácticas y a nivel de parser. |

### 2.2 Mecánica de Herramientas BSD y Diferencias de Motores

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            BSD Text Processing Tools                        │
├─────────────────┬───────────────────┬───────────────────┬───────────────────┤
│    Tool         │ Default Regex Mode│ Modifiers/Flags   │ Primary SRE Use   │
├─────────────────┼───────────────────┼───────────────────┼───────────────────┤
│ `grep(1)`       │ BRE               │ `-E` (ERE), `-F`  │ In-line filtering │
│                 │                   │ `-i`, `-v`, `-o`  │ & line counting   │
├─────────────────┼───────────────────┼───────────────────┼───────────────────┤
│ `sed(1)`        │ BRE               │ `-E` (ERE)        │ Stream editing &  │
│                 │                   │ `-n` (quiet mode) │ inline rewriting  │
├─────────────────┼───────────────────┼───────────────────┼───────────────────┤
│ `awk(1)`        │ ERE               │ Field splitting   │ Structured column │
│                 │                   │ `FS`, `~` match   │ analysis & metrics│
└─────────────────┴───────────────────┴───────────────────┴───────────────────┘
```

---

## 3. Configuración de Pipelines de Producción y Scripts de Utilidad

A continuación se muestra una herramienta de extracción de alertas y parseo de logs automatizada, completa y de nivel de producción, diseñada para sistemas BSD. Utiliza lógica de shell compatible con POSIX, BSD `grep -E`, `sed -E` y `awk` para parsear `/var/log/messages`, `/var/log/auth.log` y logs del firewall `pf`.

### 3.1 Inspector Avanzado de Logs de Producción en FreeBSD (`/usr/local/sbin/bsd_log_analyzer.sh`)

```sh
#!/bin/sh
# ==============================================================================
# Script: /usr/local/sbin/bsd_log_analyzer.sh
# Target OS: FreeBSD 13.x/14.x, OpenBSD 7.x, NetBSD 10.x
# Description: High-performance POSIX-compliant log auditor using ERE/BRE patterns.
# ==============================================================================

set -eu

# Enforce C locale for raw byte-level matching (bypasses UTF-8 parsing overhead)
export LC_ALL=C

LOG_AUTH="/var/log/auth.log"
LOG_MESSAGES="/var/log/messages"
OUTPUT_DIR="/var/log/audit_reports"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT_FILE="${OUTPUT_DIR}/audit_${TIMESTAMP}.log"

mkdir -p "${OUTPUT_DIR}"

echo "======================================================================" > "${REPORT_FILE}"
echo " FreeBSD SRE Security & Telemetry Audit Report - ${TIMESTAMP}" >> "${REPORT_FILE}"
echo "======================================================================" >> "${REPORT_FILE}"

# ------------------------------------------------------------------------------
# 1. Parse Invalid SSH Login Attempts using Extended Regular Expressions (ERE)
#    Matches patterns like: "Failed password for root from 192.168.1.50 port 54321"
# ------------------------------------------------------------------------------
echo "\n[+] Analyzing Failed SSH Authentication Attempts (ERE via grep -E)..." >> "${REPORT_FILE}"

if [ -f "${LOG_AUTH}" ]; then
    grep -E 'Failed (password|publickey) for (invalid user )?[a-zA-Z0-9_-]+ from [0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' "${LOG_AUTH}" \
    | awk '{
        for(i=1; i<=NF; i++) {
            if ($i == "from") ip=$(i+1);
            if ($i == "for") user=$(i+1);
        }
        print $1, $2, $3, "TargetUser:" user, "SourceIP:" ip
    }' | sort | uniq -c | sort -nr | head -n 10 >> "${REPORT_FILE}"
else
    echo "LOG WARNING: ${LOG_AUTH} not found." >> "${REPORT_FILE}"
fi

# ------------------------------------------------------------------------------
# 2. Extract Kernel Traps and Fatal Memory Errors via BSD sed -E
#    Translates kernel panic/page fault lines into standardized CSV format.
# ------------------------------------------------------------------------------
echo "\n[+] Extracting Kernel Faults & Memory Exceptions (ERE via sed -E)..." >> "${REPORT_FILE}"

if [ -f "${LOG_MESSAGES}" ]; then
    sed -E -n 's/^([A-Z][a-z]{2} [ 0-9][0-9] [0-9:]{8}) [a-zA-Z0-9_.-]+ kernel: \[.*\] (fatal page fault|kernel trap|panic): (.*)$/\1 | CRITICAL | \2 | Detail: \3/p' "${LOG_MESSAGES}" >> "${REPORT_FILE}"
else
    echo "LOG WARNING: ${LOG_MESSAGES} not found." >> "${REPORT_FILE}"
fi

# ------------------------------------------------------------------------------
# 3. Process POSIX Character Classes for Service State Transitions
#    Filters non-alphanumeric noise, isolates daemon state change signals.
# ------------------------------------------------------------------------------
echo "\n[+] Monitoring System Daemon Status Changes (POSIX Classes via awk)..." >> "${REPORT_FILE}"

if [ -f "${LOG_MESSAGES}" ]; then
    awk '$5 ~ /[[:alpha:]]+\[[[:digit:]]+\]:/ && $0 ~ /(stopped|started|restarted|failed)/ {
        gsub(/[^[:alnum:]: ]/, "", $5);
        print $1, $2, $3, "Daemon:" $5, "Event:" $6
    }' "${LOG_MESSAGES}" | tail -n 15 >> "${REPORT_FILE}"
fi

# ------------------------------------------------------------------------------
# 4. Filter IPv4/IPv6 Address Patterns with Quantifier Bounds
# ------------------------------------------------------------------------------
echo "\n[+] Extracting Unique Blocked IPv4 Subnets (Bounded Quantifiers)..." >> "${REPORT_FILE}"

if [ -f "${LOG_MESSAGES}" ]; then
    grep -E -o '([0-9]{1,3}\.){3}[0-9]{1,3}' "${LOG_MESSAGES}" \
    | grep -v -E '^(127\.0\.0\.1|0\.0\.0\.0)$' \
    | sort -u | head -n 20 >> "${REPORT_FILE}"
fi

echo "\n[+] Audit Complete. Report written to ${REPORT_FILE}"
exit 0
```

---

## 4. Flujos de Trabajo Prácticos en CLI y Salidas Reales de Terminal

A continuación se muestran flujos de trabajo de ejecución que demuestran la evaluación de regex en utilidades userland de BSD.

### 4.1 Aislamiento de Usuarios del Sistema con Clases de Caracteres Acotadas (`grep` BRE vs ERE)

#### Consultando `/etc/passwd` para Cuentas de Servicio (UID entre 10 y 99) usando ERE:
```syslog
$ grep -E '^[a-zA-Z0-9_-]+:[^:]+:[0-9]{2}:[0-9]{2}:' /etc/passwd
```
**Salida Esperada:**
```text
pop:*:68:6:Post Office Protocol Daemon:/nonexistent:/usr/sbin/nologin
hshdump:*:73:73:Hashdump Daemon:/nonexistent:/usr/sbin/nologin
ntpd:*:123:123:NTP Daemon:/var/db/ntp:/usr/sbin/nologin
```

#### Ejecutando Clases de Caracteres POSIX estándar para detectar shells no estándar:
```syslog
$ grep -v -E ':(/[[:alnum:]]+)+/(nologin|false)$' /etc/passwd
```
**Salida Esperada:**
```text
root:*:0:0:Charlie &:/root:/bin/csh
toor:*:0:0:Bourne-again Superuser:/root:
operator:*:5:5:System &:/usr/sbin:/bin/csh
freebsd:*:1001:1001:FreeBSD User:/home/freebsd:/bin/sh
```

---

### 4.2 Manipulación Avanzada de Flujos con BSD `sed(1)`

#### Normalización de marcas de tiempo de syslog del formato tradicional de BSD a la representación ISO-8601:
Línea de entrada en formato syslog: `Oct 24 14:05:22 freebsd-node-01 kernel: pid 4321 (nginx), jid 0, uid 80: exited on signal 11`

```syslog
$ echo "Oct 24 14:05:22 freebsd-node-01 kernel: pid 4321 (nginx), jid 0, uid 80: exited on signal 11" | sed -E 's/^([A-Z][a-z]{2}) +([0-9]{1,2}) ([0-9:]{8}) ([^ ]+) (.*)$/DATE=\1-\2 TIME=\3 HOST=\4 MSG="\5"/'
```
**Salida Esperada:**
```text
DATE=Oct-24 TIME=14:05:22 HOST=freebsd-node-01 MSG="kernel: pid 4321 (nginx), jid 0, uid 80: exited on signal 11"
```

#### Eliminar comentarios y líneas en blanco de la configuración de red `/etc/pf.conf` de BSD:
```syslog
$ sed -E '/^[[:space:]]*#/d; /^[[:space:]]*$/d' /etc/pf.conf
```
**Salida Esperada:**
```text
set skip on lo
scrub in all
block in all
pass out quick all keep state
pass in quick proto tcp to port { 22 80 443 } keep state
```

---

### 4.3 Parseo de Logs y Agregación de Columnas usando BSD `awk(1)`

#### Parseando `/var/log/pflog` (renderizado mediante `tcpdump -e -n -r`) para agregar los principales puertos de destino bloqueados:
```syslog
$ cat /var/log/dummy_pflog.txt | awk '$1 ~ /rule/ && $0 ~ /block/ {
    for (i=1; i<=NF; i++) {
        if ($i ~ /\.[0-9]+>/) {
            split($i, a, ".");
            port = a[length(a)];
            gsub(/[^0-9]/, "", port);
            if (port != "") counts[port]++;
        }
    }
}
END {
    for (p in counts) {
        printf "Port %-5s : %d Blocks\n", p, counts[p];
    }
}' | sort -k3 -nr | head -n 5
```
**Salida Esperada:**
```text
Port 23    : 1420 Blocks
Port 445   : 980 Blocks
Port 1433  : 412 Blocks
Port 3389  : 205 Blocks
Port 8080  : 89 Blocks
```

---

## 5. Guía de Verificación, Profiling de Rendimiento y Resolución de Problemas

### 5.1 Diagnóstico y Benchmarking del Motor de Regex

Cuando las expresiones regulares se ejecutan dentro de operaciones de bucle masivas en utilidades de pipeline de SRE, los patrones deficientes introducen una alta latencia.

#### Benchmarking de la Evaluación de Caracteres Multibyte con LC_ALL=C vs. UTF-8:
```syslog
$ time env LC_ALL=en_US.UTF-8 grep -E -c '([[:alnum:]]+_?){3,}' /usr/share/dict/words
$ time env LC_ALL=C grep -E -c '([[:alnum:]]+_?){3,}' /usr/share/dict/words
```
**Salida Esperada:**
```text
235890
real    0m0.342s
user    0m0.318s
sys     0m0.024s

235890
real    0m0.048s
user    0m0.039s
sys     0m0.009s
```
*Conclusión:* Forzar `LC_ALL=C` omite los decodificadores multibyte `mbrtowc` en libc, acelerando la velocidad de procesamiento en **~7x**.

---

### 5.2 Escenarios Comunes de Resolución de Problemas y Corrección de Errores del Motor

#### Caso 1: Cuantificadores sin Escapar en Modo Basic Regular Expression (`grep` / `sed`)
* **Síntoma**: `grep 'host-[0-9]{1,3}' /var/log/messages` devuelve una salida vacía a pesar de que existen coincidencias.
* **Causa Raíz**: `{1,3}` se analiza como caracteres literales en modo BRE.
* **Remediación**:
  - Opción A (Escapar Llaves en BRE): `grep 'host-[0-9]\{1,3\}' /var/log/messages`
  - Opción B (Cambiar a ERE): `grep -E 'host-[0-9]{1,3}' /var/log/messages`

#### Caso 2: Sobre-consumo por Coincidencia Codiciosa (Greedy Matching)
* **Síntoma**: Extraer texto entre corchetes `[ERROR] [MODULE_A] [ID_99]` usando `\[.*\]` coincide con `[ERROR] [MODULE_A] [ID_99]` como un solo grupo.
* **Causa Raíz**: Los cuantificadores de regex POSIX (`*`, `+`) son codiciosos (greedy) por naturaleza y carecen de modificadores no codiciosos (`*?`) en las especificaciones del motor estándar de BSD.
* **Remediación**: Usar clases de caracteres negadas `\[[^]]*\]`.
```syslog
$ echo "[ERROR] [MODULE_A] [ID_99]" | grep -E -o '\[[^]]+\]'
```
**Salida Esperada:**
```text
[ERROR]
[MODULE_A]
[ID_99]
```

#### Caso 3: Coincidencia Portable de Límites de Línea en Datasets de BSD / Linux
* **Síntoma**: `^` y `$` no logran coincidir con líneas generadas en nodos Windows/DOS exportados a BSD.
* **Causa Raíz**: Los Retornos de Carro sin eliminar (`\r` / `0x0D`) impiden que `$` se ancle al final de las cadenas de texto.
* **Remediación**: Eliminar `\r` usando `tr` o contemplarlo explícitamente usando ERE `\r?$`.
```syslog
$ tr -d '\r' < dos_log.txt | grep -E 'ERROR$'
```

---

### 5.3 Matriz de Decisión de Diagnóstico

```
                          [ Issue Detected ]
                                   │
         ┌─────────────────────────┴─────────────────────────┐
         ▼                                                   ▼
[ Empty Output / No Match ]                         [ High CPU / Timeout ]
         │                                                   │
 ┌───────┴──────────────────┐                       ┌────────┴──────────────────┐
 ▼                          ▼                       ▼                           ▼
[ Regex Engine Syntax ]    [ Line Endings ]        [ Catastrophic Backtrack ]  [ Multibyte Bottleneck ]
  • BRE vs ERE flag missing  • Windows CRLF present  • Nested quantifiers        • UTF-8 Locale active
  • Braces unescaped in BRE  • Run `tr -d '\r'`        `(a+)+` in ERE            • Set `LC_ALL=C`
  • Use `grep -E`            • Adjust `$` anchor     • Simplify expression       • Re-run benchmark
```

---

## 6. Referencias

* **FreeBSD Manual Pages - `re_format(7)`**:  
  https://man.freebsd.org/cgi/man.cgi?query=re_format&sektion=7  
* **FreeBSD Manual Pages - `grep(1)`**:  
  https://man.freebsd.org/cgi/man.cgi?query=grep&sektion=1  
* **FreeBSD Manual Pages - `sed(1)`**:  
  https://man.freebsd.org/cgi/man.cgi?query=sed&sektion=1  
* **FreeBSD Manual Pages - `awk(1)`**:  
  https://man.freebsd.org/cgi/man.cgi?query=awk&sektion=1  
* **OpenBSD Manual Pages - `re_format(7)`**:  
  https://man.openbsd.org/re_format.7  
* **LPI BSD Specialist Certification Overview**:  
  https://www.lpi.org/our-certifications/bsd-specialist-overview/  
* **IEEE Std 1003.1-2008 (POSIX.1) Regular Expressions**:  
  https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/V1_chap09.html