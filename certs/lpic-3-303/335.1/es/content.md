# 335.1 Vulnerabilidades y amenazas de seguridad comunes

**LPIC-3 Security — Examen 303-300, v3.0.0 · Tema 335 (Amenazas y evaluación de vulnerabilidades) · Peso 3.33**

---

## 0. Mapa de alcance: objetivo → sección

| Área de conocimiento clave del examen | Cubierta en |
|---|---|
| Términos: amenaza, vulnerabilidad, exploit, riesgo, superficie de ataque | §2 |
| CVE, CWE, CVSS, NVD (+ KEV/EPSS/VEX modernos) | §3 |
| Buffer overflow (stack/heap), integer overflow, over-read | §4 |
| Condiciones de carrera, TOCTOU | §5 |
| Escalada de privilegios | §6 |
| Sniffing, ARP/DNS spoofing, MITM | §7 |
| DoS, DDoS, amplificación, agotamiento de recursos | §8 |
| SQL injection, XSS, CSRF y clases web | §9 |
| Virus, gusanos, troyanos, rootkits, ransomware | §10 |
| Ataques a contraseñas, phishing, ingeniería social | §11 |
| Ataques de canal lateral (Meltdown, Spectre, Rowhammer) | §12 |
| Compromiso de la cadena de suministro (agregado moderno) | §13 |
| Operacionalización, verificación, diagnóstico | §14–§15 |

---

## 1. El problema en producción

Una vulnerabilidad no es un evento. Es un **problema de latencia**.

Considerá una flota realista: 400 hosts Linux (mezcla de RHEL 9 / Debian 12), 60 imágenes de contenedor, 9 000 tuplas paquete-versión distintas. Un martes cualquiera, la NVD publica del orden de 100–150 CVEs nuevos. De esos, quizá 3 afectan tu flota. De esos 3, quizá 1 es alcanzable desde una red no confiable, y quizá 1 de cada 40 días laborables es *a la vez* alcanzable y tiene código de exploit público dentro de las 24 horas.

La arquitectura ingenua — "suscribirse a una lista de correo, parchear cuando alguien lo note" — falla en tres ejes independientes:

1. **Relación señal-ruido.** Una política basada solo en CVSS ("parchear todo ≥ 7.0 en 7 días") genera miles de tickets por trimestre, de los cuales la abrumadora mayoría son inexplotables en tu configuración. Los equipos entonces se pierden el que importa *porque* están ahogados en los que no.
2. **Latencia de descubrimiento.** No podés parchear lo que no podés enumerar. Sin un inventario autoritativo (base de datos de paquetes + SBOM + mapa de procesos en ejecución), "¿nos afecta CVE-2024-3094?" se responde con arqueología de Slack, no con una consulta.
3. **Latencia de verificación.** Instalar un paquete **no** remedia una vulnerabilidad si el código vulnerable sigue mapeado en un proceso de larga duración. `openssl` actualizado, `nginx` no reiniciado = sigue explotable, con un dashboard en verde.

La respuesta arquitectónica es tratar la gestión de vulnerabilidades como un **bucle de control de SRE** con un presupuesto de error explícito:

```
inventory ──▶ match(CVE feed) ──▶ triage(reachability, KEV, EPSS) ──▶ remediate ──▶ VERIFY ──▶ inventory
    ▲                                                                                    │
    └────────────────────────────── drift detection ─────────────────────────────────────┘
```

Cada etapa de ese bucle debe ser un comando que devuelve un código de salida, no un juicio humano. Este tema te da la taxonomía sobre la que opera el bucle: **no podés escribir una regla de triaje para una clase de vulnerabilidad que no sabés nombrar.**

El resto del material está organizado por *clase* en lugar de por *CVE*, porque el CVE individual es efímero y la clase no. Los stack overflows se explotan desde 1988 (gusano Morris, `fingerd`) y todavía se enviaban en 2021 (`sudo` Baron Samedit). La clase es el conocimiento duradero; el CVE es la instancia.

---

## 2. Vocabulario que el examen califica y del que depende producción

Estos términos se confunden con frecuencia, y el examen evalúa la distinción de forma directa.

| Término | Definición | Ejemplo concreto |
|---|---|---|
| **Activo** | Cualquier cosa con valor para la organización | Base de datos de clientes, clave de firma, `/etc/shadow` |
| **Amenaza** | Una causa potencial de un incidente no deseado | "Un atacante remoto ejecuta código como root" |
| **Actor de amenaza** | La entidad detrás de una amenaza | Script kiddie, grupo criminal, insider, actor estatal |
| **Vulnerabilidad** | Una debilidad que una amenaza puede explotar | `sudo` 1.9.5p1 sin parchear (CVE-2021-3156) |
| **Exploit** | Código/técnica que convierte una vulnerabilidad en un efecto | La PoC de heap overflow para ese CVE |
| **Vector de ataque** | El camino usado para alcanzar la vulnerabilidad | Shell local, socket de red, archivo malicioso |
| **Superficie de ataque** | Suma de todos los puntos de entrada alcanzables | Puertos abiertos + binarios SUID + parsers |
| **Riesgo** | Probabilidad × Impacto, sobre un activo dado | "Alto: expuesto a internet, RCE, contiene PII" |
| **Control** | Una medida que reduce el riesgo | Parche, regla de firewall, política SELinux, MFA |
| **Riesgo residual** | Riesgo que queda después de los controles | Aceptado y firmado, o no aceptado |
| **0-day** | Vulnerabilidad sin arreglo disponible del proveedor | Log4Shell el 2021-12-09 |
| **n-day** | Vulnerabilidad con arreglo disponible pero no aplicado | Log4Shell el 2022-06-01 — el verdadero asesino |
| **Radio de impacto** | Alcance del daño si el control falla | Un contenedor vs. el nodo entero vs. el clúster |

**La relación crítica**: `Riesgo = Amenaza × Vulnerabilidad × Impacto`. Eliminar *cualquier* factor elimina el riesgo. Por eso "el servicio vulnerable no está escuchando en ninguna interfaz" es una remediación legítima, y por eso los controles compensatorios (segmentación de red, confinamiento SELinux, montajes `noexec`) reducen el riesgo sin parchear un solo byte.

### 2.1 Tríada CIA — y qué significa operativamente

| Propiedad | Pregunta que responde | Se rompe con | Control típico |
|---|---|---|---|
| **Confidencialidad** | ¿Quién puede leerlo? | Sniffing, canal lateral, IDOR, fuga de datos | TLS, LUKS, DAC/MAC, mínimo privilegio |
| **Integridad** | ¿Puedo probar que no fue alterado? | MITM, rootkit, cadena de suministro, UPDATE por SQLi | Firmas, AIDE, dm-verity, IMA |
| **Disponibilidad** | ¿Está ahí cuando se necesita? | DoS/DDoS, ransomware, fork bomb | Límites de tasa, cuotas, réplicas, backups |

Extendida en la práctica con **Autenticidad**, **No repudio** (registros de auditoría, commits firmados) y **Responsabilidad** (AAA: Authentication, Authorization, Accounting).

Notá el **trade-off que vas a enfrentar realmente**: endurecer contra ataques a la confidencialidad/integridad suele costar disponibilidad. `fail2ban` con un umbral agresivo convierte un password-spray en un DoS autoinfligido cuando un cliente mal configurado entra en bucle. Las mitigaciones completas de Spectre cuestan throughput medible. La ingeniería de seguridad es la disciplina de elegir *qué* pata de la tríada gastar.

---

## 3. La pila de identificadores: CWE, CVE, CVSS, NVD, KEV, EPSS

Son cuatro cosas ortogonales. El examen espera que sepas cuál es cuál.

| Identificador | Responde | Alcance | Ejemplo |
|---|---|---|---|
| **CWE** | *¿Qué tipo de bug es?* | Clase / taxonomía | CWE-121: Stack-based Buffer Overflow |
| **CVE** | *¿Qué instancia de producto?* | Una vuln en un producto | CVE-2021-3156 (sudo) |
| **CVSS** | *¿Qué tan grave, técnicamente?* | Severidad 0.0–10.0 | 7.8 HIGH |
| **EPSS** | *¿Qué probabilidad hay de que se explote?* | Probabilidad 0–1, 30 días | 0.94 (94 %) |
| **KEV** | *¿Se está explotando ahora mismo?* | Booleano, observado en el mundo real | Sí / No |

**NVD** (National Vulnerability Database, NIST) es la capa de enriquecimiento sobre la lista de CVE: agrega puntajes CVSS, mapeo CWE y declaraciones de aplicabilidad CPE (Common Platform Enumeration). **MITRE** asigna el ID de CVE; las **CNAs** (CVE Numbering Authorities — Red Hat, Canonical, Google, GitHub…) asignan IDs dentro de su ámbito. Las distribuciones publican sus *propios* avisos, que son los autoritativos para vos: **RHSA** (Red Hat), **DSA/DLA** (Debian), **USN** (Ubuntu), **SUSE-SU**, **openSUSE-SU**.

> **Trampa del backporting.** El `openssl 3.0.11-1~deb12u2` de Debian puede ser inmune a un CVE que "afecta a OpenSSL < 3.0.14". Las distribuciones hacen backport de arreglos de seguridad sin subir la versión upstream. Los escáneres basados en cadenas de versión producen falsos positivos en distros estables; siempre contrastá con los datos OVAL/security tracker de la distribución.

### 3.1 Leer un vector CVSS v3.1

```
CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:C/C:H/I:H/A:H   →  10.0 CRITICAL   (CVE-2021-44228, Log4Shell)
CVSS:3.1/AV:L/AC:L/PR:L/UI:N/S:U/C:H/I:H/A:H   →   7.8 HIGH       (CVE-2021-4034, PwnKit)
```

| Métrica | Valores | Significado |
|---|---|---|
| **AV** Attack Vector | N / A / L / P | Network, Adjacent, Local, Physical |
| **AC** Attack Complexity | L / H | Low, High (requiere condiciones especiales) |
| **PR** Privileges Required | N / L / H | None, Low, High |
| **UI** User Interaction | N / R | None, Required |
| **S** Scope | U / C | Unchanged, **Changed** (escapa de su autoridad de seguridad — escape de VM, escape de contenedor) |
| **C/I/A** | N / L / H | Impacto en Confidencialidad / Integridad / Disponibilidad |

Rangos del puntaje base: 0.1–3.9 LOW, 4.0–6.9 MEDIUM, 7.0–8.9 HIGH, 9.0–10.0 CRITICAL.

Existen dos grupos derivados que casi siempre se ignoran, a costa de todos:
- **Temporal** (v3.1): Exploit Code Maturity, Remediation Level, Report Confidence.
- **Environmental** (v3.1): te permite a *vos* re-puntuar para *tu* despliegue — p. ej. `CR:H/MAV:A` para un host alcanzable solo desde una VLAN de gestión.

**CVSS v4.0** (publicado 2023-11) reestructura esto en **CVSS-B / -BT / -BE / -BTE**, divide el impacto en *Vulnerable System* y *Subsequent System* (reemplazando a Scope), agrega **AT** (Attack Requirements) y expande UI a N/P/A (None, Passive, Active). Esperá un examen centrado en v3.1, pero reconocé vectores v4.0 en el mundo real.

### 3.2 Comparación de entradas de triaje

| Entrada | Fortaleza | Debilidad | Usala para |
|---|---|---|---|
| CVSS base | Universal, agnóstico del proveedor, offline | No dice nada sobre *tu* exposición ni sobre la explotación; ~58 % de los CVEs de NVD son ≥7.0 | Solo filtro de piso |
| CVSS environmental | Refleja tu topología | Requiere trabajo manual por CVE | Activos joya de la corona |
| **EPSS** (FIRST) | Probabilidad de explotación basada en datos, actualizada a diario | Probabilística, no es una garantía; pobre en CVEs recién salidos | Ordenar la cola |
| **CISA KEV** | Verdad de campo: *sí* está siendo explotado | Rezagado, centrado en el gobierno de EE. UU., escaso | Disparador de "soltá todo" |
| Alcanzabilidad / VEX | Elimina la mayoría de los falsos positivos (rutas de código inalcanzables) | Necesita SBOM + declaraciones VEX del proveedor | Suprimir ruido honestamente |

Una política de producción defendible los combina:

```
if in_KEV:                      SLO = 24 h    (emergency change)
elif EPSS >= 0.10 and CVSS>=7:  SLO = 7 d
elif CVSS >= 9.0:               SLO = 14 d
elif CVSS >= 7.0:               SLO = 30 d
else:                           SLO = next monthly patch window
```

### 3.3 Consultar los feeds desde la CLI

```bash
$ curl -s "https://services.nvd.nist.gov/rest/json/cves/2.0?cveId=CVE-2021-4034" \
  | jq -r '.vulnerabilities[0].cve
      | "\(.id)  \(.metrics.cvssMetricV31[0].cvssData.baseScore) \
\(.metrics.cvssMetricV31[0].cvssData.baseSeverity)\n\(.descriptions[0].value)"'
CVE-2021-4034  7.8 HIGH
A local privilege escalation vulnerability was found on polkit's pkexec utility. The
pkexec application is a setuid tool designed to allow unprivileged users to run
commands as privileged users according predefined policies.
```

```bash
$ curl -s https://api.first.org/data/v1/epss?cve=CVE-2021-4034 \
  | jq -r '.data[] | "EPSS \(.epss)  percentile \(.percentile)"'
EPSS 0.94129  percentile 0.99912
```

El matching nativo de la distribución es más rápido y no tiene falsos positivos por backporting:

```bash
# RHEL / Fedora
$ dnf updateinfo list --security
Last metadata expiration check: 0:12:44 ago on Tue 25 Aug 2026 09:02:11 -03.
RHSA-2026:4471 Important/Sec. kernel-5.14.0-427.42.1.el9_4.x86_64
RHSA-2026:4488 Moderate/Sec.  openssl-1:3.0.7-27.el9_4.x86_64
$ dnf updateinfo info --cve CVE-2026-21432 | head -12

# Debian / Ubuntu
$ debsecan --suite bookworm --format detail --only-fixed
CVE-2026-2153 openssl (remotely exploitable, high urgency)
  fixed in 3.0.16-1~deb12u1
$ apt list --upgradable 2>/dev/null | grep -i security | head -5
libssl3/stable-security 3.0.16-1~deb12u1 amd64 [upgradable from: 3.0.15-1~deb12u1]
```

---

## 4. Vulnerabilidades de seguridad de memoria

Aproximadamente el 60–70 % de los CVEs críticos en bases de código C/C++ (las cifras publicadas de forma independiente por Microsoft y por Google caen ambas en esa banda) son problemas de seguridad de memoria. Esta es la familia de vulnerabilidades más importante en software de sistemas.

### 4.1 Stack-based buffer overflow (CWE-121)

El mecanismo: un buffer de tamaño fijo vive en el stack frame de la función. En x86-64 el frame crece *hacia abajo* pero las escrituras van *hacia arriba*, así que desbordar un buffer local sobrescribe — en orden — otras variables locales, el frame pointer guardado y la **dirección de retorno guardada**. Controlá la dirección de retorno, controlás `RIP`.

```c
/* vuln.c — deliberately unsafe; for study only */
#include <stdio.h>
#include <string.h>

void handle(const char *input) {
    char name[16];
    strcpy(name, input);          /* CWE-120: no bounds check */
    printf("Hello, %s\n", name);
}

int main(int argc, char **argv) {
    if (argc > 1) handle(argv[1]);
    return 0;
}
```

Compilado con todas las protecciones modernas deshabilitadas deliberadamente, para que el fallo sea visible:

```bash
$ gcc -fno-stack-protector -z execstack -no-pie -O0 -o vuln vuln.c
$ ./vuln AAAA
Hello, AAAA
$ ./vuln $(python3 -c 'print("A"*80)')
Hello, AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
Segmentation fault (core dumped)
```

```bash
$ gdb -q ./vuln
Reading symbols from ./vuln...
(gdb) run $(python3 -c 'print("A"*80)')
Program received signal SIGSEGV, Segmentation fault.
0x0000000000401156 in handle ()
(gdb) x/1gx $rsp
0x7fffffffe3a8: 0x4141414141414141
(gdb) info frame
Stack level 0, frame at 0x7fffffffe3b0:
 rip = 0x401156 in handle; saved rip = 0x4141414141414141
```

`saved rip = 0x4141414141414141` es la firma definitiva: la dirección de retorno ahora está controlada por el atacante, ASCII `AAAAAAAA`.

Ahora recompilá con el endurecimiento por defecto de la distribución:

```bash
$ gcc -O2 -fstack-protector-strong -D_FORTIFY_SOURCE=3 -fPIE -pie -Wl,-z,relro,-z,now -o safe vuln.c
$ ./safe $(python3 -c 'print("A"*80)')
*** buffer overflow detected ***: terminated
Aborted (core dumped)
$ dmesg | tail -2
[  914.223118] traps: safe[5312] general protection fault ip:7f3a2c0a1e2b sp:7ffd...
```

`_FORTIFY_SOURCE` convirtió una corrupción de memoria explotable en un `abort()` limpio — disponibilidad perdida, confidencialidad e integridad preservadas. Ese intercambio casi siempre es correcto.

### 4.2 Heap overflow, use-after-free, double free (CWE-122, CWE-416, CWE-415)

Los metadatos del heap (`tcache`, `fastbins`, cabeceras de chunk de glibc) están en línea con los datos de usuario. Desbordar un buffer obtenido con `malloc` corrompe la cabecera del chunk siguiente; el allocator de glibc entonces escribe punteros influenciados por el atacante durante `free()`/`malloc()`. El **use-after-free** reutiliza un puntero colgante después de que su chunk fue reciclado en un objeto distinto — la ruta clásica hacia la confusión de tipos. glibc tiene chequeos de endurecimiento que se manifiestan como aborts distintivos:

```bash
$ ./heapdemo
free(): invalid next size (fast)
Aborted (core dumped)

$ ./uaf
free(): double free detected in tcache 2
Aborted (core dumped)

$ GLIBC_TUNABLES=glibc.malloc.check=3 ./heapdemo
malloc: invalid size (unsorted)
Aborted (core dumped)
```

Ejemplo del mundo real: **CVE-2021-3156 "Baron Samedit"** — `sudoedit -s '\'` hacía que `sudo` leyera más allá de un argumento de línea de comandos y escribiera un heap overflow, alcanzable por *cualquier* usuario local, sin necesidad de una entrada en `sudoers`, presente desde 2011.

### 4.3 Integer overflow / underflow (CWE-190/191)

Rara vez peligroso por sí solo; letal cuando alimenta un cálculo de tamaño.

```c
size_t n = user_count;             /* attacker: 0x40000001 */
char *buf = malloc(n * 4);         /* 0x100000004 truncated to 4 on 32-bit → malloc(4) */
for (size_t i = 0; i < n; i++)     /* writes 1 GiB into a 4-byte buffer */
    buf[i*4] = data[i];
```

El overflow con signo en C es *comportamiento indefinido*, así que el compilador puede eliminar tu "chequeo": `if (a + b < a)` se optimiza y desaparece. Los patrones correctos son `__builtin_mul_overflow()`, `reallocarray(3)`, o chequeos explícitos de división. Compilá con `-ftrapv` / `-fsanitize=signed-integer-overflow` en CI.

### 4.4 Buffer over-read (CWE-125) — la forma Heartbleed

**CVE-2014-0160**: el heartbeat TLS de OpenSSL confiaba en un campo de longitud provisto por el atacante y hacía `memcpy` de hasta 64 KiB del heap del proceso de vuelta al cliente. Sin caída, sin entrada de log, sin *escritura* de memoria — pura pérdida de confidencialidad, repetible, y filtró claves privadas y cookies de sesión. Por esto "no crasheó" no es evidencia de seguridad, y por esto el registro pasivo de red no puede detectar todos los ataques.

### 4.5 Matriz de mitigación de exploits

| Mitigación | Detiene | Bypass típico | Costo | Verificalo |
|---|---|---|---|---|
| **NX / DEP** (`W^X`) | Ejecutar shellcode inyectado en stack/heap | ROP / ret2libc | ~0 % | `checksec`, `readelf -lW \| grep GNU_STACK` |
| **ASLR** (`randomize_va_space=2`) | Direcciones hardcodeadas | Fuga de información, fuerza bruta en 32 bits, binarios no PIE | ~0–1 % | `sysctl kernel.randomize_va_space` |
| **PIE** | Base de binario fija (necesario para que ASLR cubra el ejecutable) | Fuga de cualquier dirección de código | ~1–3 % en x86-64 | `checksec` → `PIE enabled` |
| **Stack canary** (`-fstack-protector-strong`) | Aplastamientos secuenciales del stack sobre la dirección de retorno | Escrituras directas/indexadas, fuga del canary, fuerza bruta con fork-server | ~1–2 % | `checksec` → `Canary found` |
| **Full RELRO** (`-z relro -z now`) | Sobrescritura de la GOT | Otros punteros a función escribibles | Arranque más lento | `checksec` → `Full RELRO` |
| **FORTIFY_SOURCE=2/3** | Overflows en llamadas `str*`/`mem*` de tamaño conocido | Bucles de copia propios sin fortificar | ~0–1 % | `hardening-check`, `checksec --fortify-file` |
| **CET IBT + Shadow Stack** | ROP/JOP (retornos y saltos indirectos) | Requiere soporte de hardware + glibc + kernel | ~1–2 % | `grep -o 'ibt\|shstk' /proc/cpuinfo` |
| **CFI / kCFI** | Secuestro de llamadas indirectas | Reutilización de destinos con la misma firma | 1–5 % | Kernel `CONFIG_CFI_CLANG` |
| **Lenguaje memory-safe** | La clase entera | Bloques unsafe, fronteras FFI | Costo de reescritura | — |

```bash
$ checksec --file=/usr/sbin/sshd
RELRO        STACK CANARY  NX          PIE       RPATH     RUNPATH   Symbols  FORTIFY  Fortified  FILE
Full RELRO   Canary found  NX enabled  PIE enab  No RPATH  No RUNPATH  No Symb   Yes      27       /usr/sbin/sshd

$ sysctl kernel.randomize_va_space
kernel.randomize_va_space = 2

$ for i in 1 2 3; do setarch --addr-no-randomize true; ldd /bin/ls | grep libc; done   # ASLR off → identical
        libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007ffff7c00000)
$ for i in 1 2 3; do ldd /bin/ls | grep libc; done                                    # ASLR on  → varies
        libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f2ad9a00000)
        libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f8c14200000)
        libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007fbb31000000)
```

Auditoría de binarios sin endurecer en toda la flota:

```bash
$ find /usr/bin /usr/sbin -type f -executable -print0 \
  | xargs -0 -P4 -n1 checksec --output=json --file 2>/dev/null \
  | jq -r 'to_entries[] | select(.value.canary=="no" or .value.nx=="no")
           | "\(.key)  canary=\(.value.canary) nx=\(.value.nx) relro=\(.value.relro)"'
/usr/bin/legacy-agent  canary=no nx=yes relro=partial
```

---

## 5. Condiciones de carrera y TOCTOU (CWE-362, CWE-367)

Existe una **condición de carrera** cuando la corrección de una operación depende del tiempo relativo de actores concurrentes. **TOCTOU** (Time-of-Check to Time-of-Use) es el caso especial relevante para la seguridad: el estado validado en el momento del chequeo ya no es cierto en el momento del uso.

### 5.1 El TOCTOU canónico de sistema de archivos

```c
/* WRONG: check and use are two syscalls with a window between them */
if (access("/tmp/report.tmp", W_OK) == 0) {      /* CHECK  (as root, tests real UID) */
    fd = open("/tmp/report.tmp", O_WRONLY);      /* USE    — attacker swapped it for
                                                    a symlink to /etc/shadow in between */
    write(fd, buf, len);
}
```

Dos bugs independientes: `access(2)` *nunca* es el chequeo correcto para un proceso privilegiado (prueba el UID real, no el efectivo — que es precisamente lo que advierte la página de manual), y la ruta se vuelve a resolver en `open()`.

**Patrones correctos:**

| Antipatrón | Reemplazo correcto |
|---|---|
| `access()` y luego `open()` | `open()` y después chequear con `fstat()` sobre el **fd** |
| `mktemp()` / `/tmp/foo.$$` predecible | `mkstemp()` / `mkdtemp()` / `PrivateTmp=yes` de `systemd` |
| `open(path, O_CREAT)` en un directorio compartido | `open(path, O_CREAT\|O_EXCL\|O_NOFOLLOW, 0600)` |
| `stat()` y luego `chown()` | `fchown()` sobre el fd ya abierto |
| Traversal de rutas a través de directorios no confiables | `openat2(2)` con `RESOLVE_NO_SYMLINKS\|RESOLVE_BENEATH` |

Mitigaciones a nivel de kernel para la clase de symlinks en directorios sticky:

```bash
$ sysctl fs.protected_symlinks fs.protected_hardlinks fs.protected_fifos fs.protected_regular
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
fs.protected_fifos = 1
fs.protected_regular = 2
```

`fs.protected_symlinks=1` hace que el kernel se niegue a seguir un symlink en un directorio sticky escribible por todos cuando el dueño del symlink ≠ el dueño del directorio ≠ el UID del proceso que lo sigue — elimina de raíz una fracción grande de las carreras históricas de `/tmp`.

### 5.2 Carreras en manejadores de señales — CVE-2024-6387 ("regreSSHion")

El RCE pre-autenticación de OpenSSH de 2024 es el ejemplo moderno de nivel de examen. El manejador de `SIGALRM` de `sshd` (timeout de gracia de login) llamaba a `syslog()`, que **no es async-signal-safe**. Si la alarma se disparaba mientras el hilo principal estaba dentro de `malloc()`/`free()`, el manejador reentraba al allocator y corrompía el heap — alcanzable por un cliente remoto no autenticado que simplemente demora el handshake. Afectó a Linux basado en glibc con OpenSSH 8.5p1–9.7p1; puntuado CVSS 8.1 (`AV:N/AC:H/PR:N/UI:N/S:U/C:H/I:H/A:H` — notá `AC:H`, porque ganar la carrera lleva miles de intentos).

Mitigación sin parchear, y el diagnóstico:

```bash
$ ssh -V
OpenSSH_9.6p1 Ubuntu-3ubuntu13.4, OpenSSL 3.0.13 30 Jan 2024
$ grep -E '^LoginGraceTime' /etc/ssh/sshd_config
LoginGraceTime 0            # disables the alarm → removes the trigger, at the cost of
                            # unbounded half-open sessions (pair with MaxStartups)
$ sudo sshd -T | grep -E 'logingracetime|maxstartups'
logingracetime 0
maxstartups 10:30:60
```

### 5.3 Otras familias de carreras

- **Dirty COW (CVE-2016-5195)** — carrera entre `madvise(MADV_DONTNEED)` y el manejador de fallos COW, que permite a un usuario local escribir en mapeos de archivo de solo lectura, p. ej. `/usr/bin/passwd`. LPE universal de Linux, 2007–2016.
- **Dirty Pipe (CVE-2022-0847)** — `pipe_buffer.flags` sin inicializar permitía sobrescribir páginas de la page cache de archivos *de solo lectura* (kernel 5.8 → 5.16.11/5.15.25/5.10.102). Trivialmente convertible en arma para editar `/etc/passwd`.
- **Secuestro de TTY de `sudo`/`su`**, bugs de double-fetch en manejadores de ioctl (`copy_from_user` dos veces), y TOCTOU en runtimes de contenedores (**CVE-2019-5736**, sobrescritura de `/proc/self/exe` en `runc` → escape al host).

---

## 6. Escalada de privilegios

La escalada es **vertical** (usuario → root) u **horizontal** (usuario A → usuario B). La lista de verificación del atacante es la lista de auditoría del defensor.

### 6.1 Inventario SUID/SGID

```bash
$ find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -printf '%M %u %g %p\n' 2>/dev/null | sort -k4
-rwsr-xr-x root root /usr/bin/chfn
-rwsr-xr-x root root /usr/bin/chsh
-rwsr-xr-x root root /usr/bin/gpasswd
-rwsr-xr-x root root /usr/bin/mount
-rwsr-xr-x root root /usr/bin/newgrp
-rwsr-xr-x root root /usr/bin/passwd
-rwsr-xr-x root root /usr/bin/su
-rwsr-xr-x root root /usr/bin/sudo
-rwsr-xr-x root root /usr/bin/umount
-rwsr-xr-x root root /usr/libexec/openssh/ssh-keysign
-rwxr-sr-x root shadow /usr/sbin/unix_chkpwd
-rwsr-xr-x root root /opt/vendor/bin/collector        <-- NOT from a package: investigate
```

Cualquier binario SUID fuera del conjunto propio de la distribución es un hallazgo. Verificá la propiedad:

```bash
$ rpm -qf /opt/vendor/bin/collector
file /opt/vendor/bin/collector is not owned by any package
$ dpkg -S /opt/vendor/bin/collector
dpkg-query: no path found matching pattern /opt/vendor/bin/collector
```

La clase de ataque está documentada públicamente como **GTFOBins**: binarios SUID legítimos con una funcionalidad que lanza una shell o lee archivos arbitrarios (`find -exec`, `vim :!sh`, `awk 'BEGIN{system()}'`, `less !sh`, `env`, `nmap --interactive` históricamente).

### 6.2 Capabilities de archivo — la variante moderna y más silenciosa

```bash
$ getcap -r /usr /opt 2>/dev/null
/usr/bin/ping cap_net_raw=ep
/usr/bin/newgidmap cap_setgid=ep
/usr/bin/newuidmap cap_setuid=ep
/opt/telemetry/bin/agent cap_dac_read_search,cap_sys_ptrace=ep     <-- root-equivalent
```

`CAP_DAC_READ_SEARCH` lee todos los archivos de la máquina (incluidos `/etc/shadow` y las claves de host de SSH). `CAP_SYS_PTRACE` se adjunta a cualquier proceso. `CAP_SYS_ADMIN`, `CAP_SYS_MODULE`, `CAP_DAC_OVERRIDE`, `CAP_SETUID`, `CAP_BPF`, `CAP_SYS_RAWIO` son todas efectivamente equivalentes a root. Un inventario de capabilities **no** es menos peligroso que un inventario SUID — es el mismo inventario, menos visible para `ls -l`.

### 6.3 Mala configuración de `sudo`

```bash
$ sudo -l
Matching Defaults entries for jdoe on app01:
    env_reset, mail_badpass, secure_path=/usr/sbin:/usr/bin:/sbin:/bin

User jdoe may run the following commands on app01:
    (root) NOPASSWD: /usr/bin/systemctl restart app*      <-- wildcard: "app../../../bin/sh"
    (root) /usr/bin/vi /etc/app/config.yaml               <-- vi → :!/bin/bash
    (root) SETENV: /opt/app/deploy.sh                     <-- SETENV lets LD_PRELOAD through
```

Cada línea de arriba es una escalada. Reglas: sin comodines en las rutas, sin editores (usá `sudoedit`, que baja privilegios para editar), sin `SETENV`, sin intérpretes, sin negaciones al estilo `sudo ALL, !/bin/su` (bypasseables trivialmente copiando el binario).

### 6.4 Secuestro de entorno y de bibliotecas

- **Inyección de `PATH`** contra un script que llama a `tar` en lugar de `/usr/bin/tar` — mitigado con `Defaults secure_path`.
- **`LD_PRELOAD` / `LD_LIBRARY_PATH` / `LD_AUDIT`** — el enlazador dinámico ignora estas variables en *modo de ejecución segura* (binarios SUID/SGID/con capabilities), que es exactamente por lo que nunca deben rehabilitarse vía `sudo SETENV`. Bypass histórico: **CVE-2010-3856** (`LD_AUDIT` en binarios SUID), y **CVE-2023-4911 "Looney Tunables"** (buffer overflow al parsear `GLIBC_TUNABLES` en `ld.so`, root local en glibc ≥ 2.34).
- **Directorios `$ORIGIN`/RPATH escribibles**: `readelf -d bin | grep -E 'RPATH|RUNPATH'`.

### 6.5 LPE de kernel — la clase que ignora todo tu endurecimiento de userspace

| CVE | Nombre | Mecanismo | Arreglado en |
|---|---|---|---|
| CVE-2016-5195 | Dirty COW | Carrera COW/madvise | 4.8.3 y backports |
| CVE-2021-4034 | PwnKit | `pkexec` argv[0]==NULL → reinyección de entorno | polkit 0.120-x |
| CVE-2021-22555 | — | Escritura OOB en el heap de Netfilter `xt_compat` | 5.12 |
| CVE-2022-0847 | Dirty Pipe | `pipe_buffer.flags` sin inicializar | 5.16.11 / 5.15.25 / 5.10.102 |
| CVE-2022-0185 | — | Underflow de entero en `fs_context` legacy, vía user ns | 5.16.2 |
| CVE-2023-0386 | — | Copy-up SUID de OverlayFS | 6.2 |
| CVE-2023-32233 | — | UAF de nf_tables en conjuntos anónimos | 6.4-rc |

El habilitador recurrente son los **user namespaces sin privilegios**, que exponen miles de líneas de superficie de ataque del kernel (netfilter, overlayfs, fs_context) a cualquier usuario local. Restringilos cuando tu carga de trabajo no los necesite:

```bash
# Debian/Ubuntu
$ sudo sysctl -w kernel.unprivileged_userns_clone=0
# Upstream / RHEL
$ sudo sysctl -w user.max_user_namespaces=0
# Ubuntu 24.04+ AppArmor-based restriction
$ sysctl kernel.apparmor_restrict_unprivileged_userns
kernel.apparmor_restrict_unprivileged_userns = 1
```

> **Trade-off**: esto rompe Podman rootless, Flatpak basado en `bwrap`, y los contenedores sin privilegios. Decidí por rol de host, no por reflejo en toda la flota.

### 6.6 Palancas de endurecimiento con sus costos

| Palanca | Bloquea | Rompe |
|---|---|---|
| `nosuid,nodev,noexec` en `/tmp`, `/var/tmp`, `/home`, `/dev/shm` | Drops SUID, payloads depositados | Scripts de post-instalación de paquetes que usan `/tmp`, algunas herramientas de compilación |
| `kernel.yama.ptrace_scope=1` (o 2/3) | Extracción de memoria de procesos entre pares | `gdb -p`, `strace -p` sin root |
| `kernel.kptr_restrict=2`, `kernel.dmesg_restrict=1` | Fugas de direcciones del kernel útiles para la fiabilidad del exploit | Herramientas de perf, algo del triaje de crashes |
| **Lockdown** del kernel (`integrity`/`confidentiality`) | `/dev/mem`, módulos sin firmar, kexec | Drivers DKMS, hibernación |
| Aplicación de firmas de módulos | Rootkits de kernel | Drivers fuera del árbol |
| SELinux `enforcing` / AppArmor | Movimiento lateral post-explotación | Cualquier cosa con una etiqueta equivocada |
| Sandboxing de unidades `systemd` | Escalada desde un servicio comprometido | Servicios que necesitan acceso amplio |

```bash
$ systemd-analyze security nginx.service | tail -20
  NAME                                                     DESCRIPTION                    EXPOSURE
✗ PrivateNetwork=                                          Service has access to the host…      0.5
✗ User=/DynamicUser=                                       Service runs as root                 0.4
✓ CapabilityBoundingSet=~CAP_SYS_ADMIN                     Service has no administrator…
✗ RestrictAddressFamilies=~AF_PACKET                       Service may allocate packet…         0.1
✗ ProtectSystem=                                           Service has full access to the…      0.2
→ Overall exposure level for nginx.service: 8.4 EXPOSED 🙁

$ systemd-analyze security nginx.service | tail -3     # after applying the drop-in below
→ Overall exposure level for nginx.service: 2.1 OK 🙂
```

```ini
# /etc/systemd/system/nginx.service.d/10-hardening.conf
[Service]
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
ProtectProc=invisible
RestrictSUIDSGID=yes
RestrictRealtime=yes
RestrictNamespaces=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources @obsolete
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
ReadWritePaths=/var/log/nginx /var/lib/nginx /run
```

`MemoryDenyWriteExecute=yes` es el que hay que probar con cuidado: rompe cualquier runtime que haga JIT (Java, Node, LuaJIT, PHP con JIT habilitado).

---

## 7. Amenazas a nivel de red

### 7.1 Sniffing (interceptación pasiva)

En un hub o en una red inalámbrica en modo monitor, todo el tráfico es visible. En un switch, el atacante debe estar en un puerto espejo, ser el gateway, o forzar al switch a comportarse como un hub — el **MAC flooding** (`macof`) desborda la tabla CAM hasta que el switch falla en abierto e inunda todas las tramas.

```bash
$ sudo tcpdump -ni eth0 -c 5 'tcp port 23 or tcp port 21 or port 161'
tcpdump: verbose output suppressed, use -v[v]... for full protocol decode
listening on eth0, link-type EN10MB (Ethernet), snapshot length 262144 bytes
10:14:02.113455 IP 10.10.5.31.51422 > 10.10.5.9.23: Flags [P.], seq 1:9, ack 1, length 8
10:14:02.115901 IP 10.10.5.31.51422 > 10.10.5.9.23: Flags [P.], seq 9:10, ack 1, length 1
5 packets captured
```

Detección de un sniffer local: una interfaz en modo promiscuo.

```bash
$ ip -d link show eth0 | head -2
2: eth0: <BROADCAST,MULTICAST,PROMISC,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP mode DEFAULT
$ dmesg | grep -i promisc
[ 8291.4471] device eth0 entered promiscuous mode
```

**La única mitigación duradera es el cifrado en tránsito.** Port security, DAI y 802.1X suben la vara; TLS/IPsec/WireGuard eliminan el valor de la captura.

### 7.2 ARP spoofing → MITM (CWE-290)

ARP no tiene autenticación: cualquier host puede anunciar gratuitamente que es dueño de una IP. El atacante envenena las cachés de la víctima y del gateway, convirtiéndose en un relay transparente.

```bash
# Victim's view during an attack — gateway and attacker share a MAC
$ ip neigh show
10.10.5.1 dev eth0 lladdr 52:54:00:aa:bb:cc REACHABLE     <-- gateway
10.10.5.66 dev eth0 lladdr 52:54:00:aa:bb:cc REACHABLE    <-- attacker, SAME MAC
$ arpwatch -d -i eth0
From: arpwatch (Arpwatch)
Subject: changed ethernet address (gateway)
          hostname: gw.corp.example
        ip address: 10.10.5.1
  ethernet address: 52:54:00:aa:bb:cc
   ethernet vendor: QEMU
 old ethernet addr: 52:54:00:11:22:33
```

| Mitigación | Capa | Costo |
|---|---|---|
| Entradas ARP estáticas (`ip neigh add ... nud permanent`) | Host | Inmanejable a escala |
| Dynamic ARP Inspection + DHCP snooping | Switch | Requiere switches gestionados, solo DHCP |
| Autenticación de puerto 802.1X | Switch | Infraestructura de PKI + RADIUS |
| `arpwatch` / `arpon` | Detección en el host | Solo alertas, no previene |
| Transporte autenticado (TLS con pinning, IPsec, WireGuard) | Aplicación/red | **Elimina el impacto de todos modos** |

### 7.3 DNS spoofing y envenenamiento de caché

El envenenamiento off-path debe adivinar el ID de transacción de 16 bits *y* el puerto de origen. El **ataque Kaminsky (2008)** lo hizo práctico al disparar intentos ilimitados contra subdominios inexistentes e inyectar un registro de autoridad envenenado. La respuesta fue la **aleatorización del puerto de origen** (elevando la entropía a ~32 bits), luego las **DNS cookies (RFC 7873)** y la codificación 0x20. El arreglo estructural es **DNSSEC**: autenticación de origen e integridad del conjunto de registros (no confidencialidad — eso es **DoT/DoH/DoQ**).

```bash
$ dig +dnssec +multiline example.com A | grep -E 'flags|RRSIG' | head -3
;; flags: qr rd ra ad; QUERY: 1, ANSWER: 2, AUTHORITY: 0, ADDITIONAL: 1
example.com.  3600 IN RRSIG A 13 2 3600 (

$ delv example.com A
; fully validated
example.com.            3600    IN      A       93.184.215.14
example.com.            3600    IN      RRSIG   A 13 2 3600 20260910000000 ...
```

La bandera `ad` (Authenticated Data) y el `; fully validated` de `delv` son las dos cosas que hay que revisar. Si falta `ad`, o bien la zona no está firmada o tu resolver no está validando.

### 7.4 Man-in-the-Middle contra TLS

| Técnica | Mecanismo | Defensa |
|---|---|---|
| **SSL stripping** | Reescribe los enlaces `https://` a `http://` en una landing page en texto plano | HSTS + lista de preload, redirecciones solo-HTTPS |
| **Downgrade** (POODLE, FREAK, Logjam, DROWN) | Fuerza protocolo/cifrado/tamaño de clave obsoleto | Deshabilitar SSLv3/TLS1.0/1.1, cifrados de exportación; `TLS_FALLBACK_SCSV` |
| **Certificado falso o mal emitido** | CA controlada por el atacante o comprometida | Certificate Transparency, registros CAA, pinning, certificados de vida corta |
| **Interceptación TLS corporativa** | CA raíz empresarial instalada en los endpoints | Reconocerla; pinning en flujos críticos; política |

```bash
$ openssl s_client -connect target.example:443 -tls1_1 </dev/null 2>&1 | head -3
80B7...:error:0A0000102:SSL routines:ssl_choose_client_version:unsupported protocol
   # correct: legacy protocol refused

$ nmap --script ssl-enum-ciphers -p 443 target.example
PORT    STATE SERVICE
443/tcp open  https
| ssl-enum-ciphers:
|   TLSv1.2:
|     ciphers:
|       TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384 (secp256r1) - A
|   TLSv1.3:
|     ciphers:
|       TLS_AKE_WITH_AES_256_GCM_SHA384 - A
|_  least strength: A
```

### 7.5 Otros abusos de L2/L3

Servidores DHCP rogue (mitigación: DHCP snooping), inundación de Router Advertisement de IPv6 y RAs rogue (**RA-Guard**; notá que una política de firewall solo-IPv4 que ignora IPv6 queda completamente bypasseada por un RA provisto por el atacante), toma del root bridge de STP (BPDU Guard), VLAN hopping vía DTP/doble etiquetado (deshabilitar DTP, nunca usar la VLAN 1 como nativa), e **inyección off-path de RST/datos TCP** (mitigada con aleatorización de números de secuencia y cifrando/autenticando la sesión — la razón por la que existen `tcp_md5sig`/TCP-AO para BGP).

---

## 8. Denegación de servicio

| Categoría | Costo para el atacante | Mecanismo | Ejemplo |
|---|---|---|---|
| **Volumétrico** | Alto ancho de banda, o amplificación | Saturar el enlace | Flood UDP, amplificación DNS/NTP/memcached |
| **Protocolo / agotamiento de estado** | Bajo | Agotar una tabla finita del kernel/app | SYN flood, llenado de la tabla conntrack, renegociación TLS |
| **Capa de aplicación** | Muy bajo | Agotar un recurso caro por petición | Slowloris, HTTP/2 Rapid Reset, ReDoS, zip bombs, búsquedas costosas |
| **Agotamiento de recursos locales** | Trivial | Consumir fds, PIDs, inodos, memoria | Fork bomb, agotamiento de inodos en `/tmp` |

### 8.1 Mecánica del SYN flood

El handshake de tres vías obliga al servidor a asignar estado con el `SYN` y mantenerlo hasta el `ACK` o el timeout. Direcciones de origen falsificadas significan que el `ACK` nunca llega; la cola de SYN se llena; las conexiones legítimas son rechazadas.

```bash
$ ss -s
Total: 2841
TCP:   9482 (estab 112, closed 84, orphaned 0, timewait 84)
                   ^^^^ SYN-RECV dominating

$ ss -tn state syn-recv | wc -l
8129

$ nstat -az | grep -E 'TcpExtTCPReqQFullDoCookies|TcpExtListenDrops|TcpExtListenOverflows|TcpExtSyncookies'
TcpExtSyncookiesSent            84213   0.0
TcpExtSyncookiesRecv               12   0.0
TcpExtListenOverflows            1874   0.0
TcpExtListenDrops                1874   0.0
TcpExtTCPReqQFullDoCookies      84213   0.0

$ dmesg -T | tail -1
[Tue Aug 25 10:41:12 2026] TCP: request_sock_TCP: Possible SYN flooding on port 443. Sending cookies.
```

Las **SYN cookies** codifican el estado de la conexión dentro del número de secuencia inicial, así que no se asigna memoria hasta que vuelve el `ACK` final. El trade-off es real y evaluable: las cookies **no pueden transportar opciones TCP** que no entren en la codificación, así que con cookies activas perdés la negociación confiable de SACK/window scaling/timestamps para las conexiones aceptadas por cookie. Por eso `tcp_syncookies=1` (solo bajo presión) es lo correcto y `=2` (siempre) es una decisión de rendimiento, no de seguridad.

Archivo de tuning completo y desplegable:

```ini
# /etc/sysctl.d/60-network-dos.conf — SYN flood and spoofing resistance
# Verify with: sudo sysctl --system && sysctl -a --pattern 'tcp_(syncookies|max_syn)'

net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 3
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384

# Reverse-path filtering: drop packets whose source is not routable back
# out of the arrival interface. Use 2 (loose) on multihomed/asymmetric hosts.
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignore ICMP broadcast (Smurf) and stop being a reflector
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.icmp_ratelimit = 100

# No redirects: neither accept nor send (routing hijack primitive)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# IPv6 RA: reject unless this host is a client that needs SLAAC
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0

# Log martians for forensics
net.ipv4.conf.all.log_martians = 1

# Conntrack sizing (state-exhaustion resistance on a firewall)
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 30
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
```

```bash
$ sudo sysctl --system
* Applying /etc/sysctl.d/60-network-dos.conf ...
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 8192
...
$ sysctl net.ipv4.tcp_syncookies net.ipv4.conf.all.rp_filter
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
```

### 8.2 Reflexión y amplificación

El atacante falsifica la dirección de origen de la víctima hacia un servicio que responde con algo mucho más grande. El **factor de amplificación de ancho de banda (BAF)** es el multiplicador.

| Protocolo / puerto | BAF (aprox.) | Arreglo |
|---|---|---|
| memcached UDP/11211 | 10 000–51 000× | `-U 0`; nunca exponer UDP; firewall |
| NTP `monlist` UDP/123 | ~557× | ntpd ≥ 4.2.7p26, `disable monitor` |
| CharGen UDP/19 | ~359× | Deshabilitar; no tiene uso moderno |
| QOTD UDP/17 | ~140× | Deshabilitar |
| RIPv1 UDP/520 | ~131× | RIPv2 con autenticación, o un IGP de verdad |
| CLDAP UDP/389 | ~56–70× | No exponer LDAP a internet |
| DNS UDP/53 (resolver abierto) | ~28–54× | Sin recursión abierta; RRL; ACLs |
| SSDP UDP/1900 | ~31× | Bloquear en el borde |
| SNMPv2 UDP/161 | ~6× | SNMPv3, ACLs |
| NetBIOS UDP/137 | ~4× | Bloquear en el borde |

El arreglo upstream para toda la clase es el **filtrado de ingreso BCP 38 / RFC 2827** — redes que se niegan a reenviar paquetes con direcciones de origen que no les pertenecen. `rp_filter` es BCP 38 en el host.

¿Sos un reflector? Probalo desde *fuera* de tu propia red:

```bash
$ dig @203.0.113.10 . NS +short          # your resolver, queried from the internet
;; connection timed out; no servers could be reached      # correct — recursion is closed

$ nmap -sU -p 11211,123,1900,161,19 --script memcached-info,ntp-monlist 203.0.113.10
PORT      STATE  SERVICE
19/udp    closed chargen
123/udp   open   ntp
161/udp   closed snmp
1900/udp  closed upnp
11211/udp closed memcache
| ntp-monlist: (no response — monitor disabled)
```

### 8.3 DoS de capa de aplicación

**Slowloris** abre muchas conexiones y envía una cabecera HTTP parcial cada pocos segundos, reteniendo slots de worker con casi cero ancho de banda. **R.U.D.Y.** hace lo mismo con un cuerpo POST lento. **HTTP/2 Rapid Reset (CVE-2023-44487)** explota la multiplexación de streams: abrir un stream, inmediatamente `RST_STREAM`, repetir — el servidor hace el trabajo, el cliente paga casi nada.

```nginx
# /etc/nginx/conf.d/00-dos-limits.conf
limit_req_zone  $binary_remote_addr zone=perip:20m  rate=20r/s;
limit_conn_zone $binary_remote_addr zone=connperip:20m;

server {
    listen 443 ssl http2;

    client_body_timeout   10s;   # kills R.U.D.Y.
    client_header_timeout 10s;   # kills Slowloris
    send_timeout          10s;
    keepalive_timeout     30s;
    client_max_body_size  8m;
    large_client_header_buffers 4 8k;

    http2_max_concurrent_streams 128;   # bounds Rapid Reset per connection

    limit_req      zone=perip burst=40 nodelay;
    limit_conn     connperip 20;
    limit_req_status 429;
    limit_conn_status 429;
}
```

Limitación de tasa a nivel de kernel con nftables (ruleset completo y cargable):

```
#!/usr/sbin/nft -f
# /etc/nftables.d/dos-protect.nft  —  nft -c -f this file to syntax-check
flush ruleset

table inet filter {
    set blackhole {
        type ipv4_addr
        flags dynamic, timeout
        timeout 1h
        size 65535
    }

    chain input {
        type filter hook input priority filter; policy drop;

        iif lo accept
        ct state established,related accept
        ct state invalid drop

        ip saddr @blackhole drop

        # ICMP: allow, but bounded
        ip protocol icmp icmp type echo-request limit rate 10/second burst 20 packets accept
        ip protocol icmp icmp type echo-request drop
        ip6 nexthdr icmpv6 icmpv6 type { echo-request, nd-neighbor-solicit,
             nd-neighbor-advert, nd-router-advert } limit rate 20/second accept

        # SYN rate limiting per source, then blackhole repeat offenders
        tcp flags syn tcp dport { 80, 443 } \
            meter syn_meter { ip saddr limit rate over 25/second burst 50 packets } \
            add @blackhole { ip saddr } \
            log prefix "nft-synflood: " level warn counter drop

        # Concurrent connection cap per source
        tcp dport { 80, 443 } ct count over 60 \
            log prefix "nft-connlimit: " counter drop

        # SSH: slow brute force to a crawl
        tcp dport 22 ct state new \
            meter ssh_meter { ip saddr limit rate over 6/minute burst 6 packets } \
            counter drop
        tcp dport 22 accept

        tcp dport { 80, 443 } accept
        counter comment "policy drop counter"
    }

    chain forward { type filter hook forward priority filter; policy drop; }
    chain output  { type filter hook output  priority filter; policy accept; }
}
```

```bash
$ sudo nft -c -f /etc/nftables.d/dos-protect.nft && echo "syntax OK"
syntax OK
$ sudo nft -f /etc/nftables.d/dos-protect.nft
$ sudo nft list set inet filter blackhole
table inet filter {
        set blackhole {
                type ipv4_addr
                size 65535
                flags dynamic,timeout
                timeout 1h
                elements = { 198.51.100.77 expires 58m12s344ms }
        }
}
$ sudo nft list chain inet filter input | grep -A1 synflood
                tcp flags syn tcp dport { 80, 443 } meter syn_meter ...
                log prefix "nft-synflood: " level warn counter packets 41822 bytes 2508 drop
```

> **El límite honesto:** toda técnica de arriba defiende contra el agotamiento de *estado*. Un DDoS verdaderamente volumétrico que satura tu enlace de tránsito no se puede filtrar en el host — para cuando el paquete llega a tu NIC, el ancho de banda ya se gastó. Eso requiere scrubbing upstream, anycast, o un filtro a nivel de proveedor. Decilo en tus documentos de diseño.

---

## 9. Clases de vulnerabilidades en aplicaciones web

Incluso en un rol de infraestructura, estas son material de examen y el vector de acceso inicial más común.

| Clase | CWE | Mecanismo en una línea | Arreglo principal |
|---|---|---|---|
| SQL injection | CWE-89 | Datos no confiables se convierten en sintaxis SQL | Consultas parametrizadas / prepared statements |
| Command injection | CWE-78 | Datos no confiables se convierten en sintaxis de shell | `execve()` con un array argv; nunca una cadena de shell |
| XSS (stored/reflected/DOM) | CWE-79 | Datos no confiables se convierten en HTML/JS en el navegador de otro usuario | Codificación de salida contextual + CSP |
| CSRF | CWE-352 | Se engaña al navegador de la víctima para hacer una petición autenticada | `SameSite=Lax/Strict` + token anti-CSRF |
| SSRF | CWE-918 | El servidor descarga una URL elegida por el atacante | Allowlist, bloquear link-local `169.254.169.254`, IMDSv2 |
| Path traversal | CWE-22 | `../../etc/passwd` escapa del document root | Canonicalizar y luego verificar el prefijo; `openat2 RESOLVE_BENEATH` |
| Deserialización insegura | CWE-502 | La construcción del grafo de objetos es ejecución de código | Formatos solo-datos; payloads firmados |
| XXE | CWE-611 | Las entidades externas XML leen archivos / alcanzan hosts internos | Deshabilitar DTD/entidades externas |
| Control de acceso roto / IDOR | CWE-639/862 | Se confía en el ID de objeto que viene del cliente | Autorización del lado del servidor en cada objeto |
| SSTI / inyección de expresiones | CWE-1336 | El motor de plantillas evalúa la entrada del usuario | Nunca construir plantillas a partir de entrada del usuario |

**SQL injection — el mecanismo y el único arreglo real:**

```python
# Vulnerable: input becomes syntax
cur.execute("SELECT id,email FROM users WHERE name = '%s'" % name)
#   name = "x' UNION SELECT 1,password_hash FROM users -- "

# Correct: input can only ever be a value
cur.execute("SELECT id,email FROM users WHERE name = %s", (name,))
```

El escapado y las reglas de WAF son controles compensatorios. La parametrización es el arreglo, porque mueve la frontera de confianza del contenido de la cadena a la estructura del protocolo. Agregá defensa en profundidad: cuentas de base de datos con mínimo privilegio (el usuario web no necesita `DROP`, ni `FILE`, ni `outfile`), y aislamiento de red de la base de datos.

**Log4Shell (CVE-2021-44228)** merece una mención como híbrido: una biblioteca de *logging* realizaba búsquedas JNDI sobre subcadenas `${jndi:ldap://…}` dentro de los datos registrados, convirtiendo "loguear la cabecera User-Agent" en carga remota de clases y RCE. CVSS 10.0. La lección arquitectónica es que **cualquier componente que interpreta datos como instrucciones es una superficie de inyección**, incluidos los que no considerás parsers.

---

## 10. Código malicioso

| Tipo | Propiedad definitoria | Propagación | Relevancia en Linux |
|---|---|---|---|
| **Virus** | Se adhiere a un archivo/programa anfitrión | Requiere que el usuario ejecute el anfitrión | Históricamente baja; existen infectores de ELF |
| **Gusano** | Autopropagante, no necesita anfitrión | Red, de forma autónoma | Morris (1988), Slammer, WannaCry, Mirai |
| **Troyano** | Se hace pasar por software legítimo | El usuario lo instala voluntariamente | Paquetes maliciosos, tarballs con backdoor |
| **Backdoor** | Canal de acceso encubierto | Plantado después o durante el compromiso | Clave SSH en `authorized_keys`, `xz` |
| **Rootkit** | Oculta el compromiso mismo | Instalado post-explotación | LD_PRELOAD, LKM, eBPF |
| **Ransomware** | Cifra datos, extorsiona un pago | Phishing → movimiento lateral | Variantes para ESXi/NAS/Linux ya comunes |
| **Agente de botnet** | Nodo controlado remotamente | Gusano o troyano | Mirai (IoT), DDoS por encargo |
| **Cryptominer** | Roba CPU/GPU | APIs expuestas, SSH débil, K8s | El payload más común en Linux hoy |
| **Bomba lógica** | Se dispara ante una condición | Insider | Rara, alto impacto |

### 10.1 Estratos de rootkit — y qué detecta cada uno

| Estrato | Técnica | Detección |
|---|---|---|
| **Userland** | `ls`, `ps`, `netstat` troyanizados; `/etc/ld.so.preload` | Verificación de paquetes (`rpm -Va`, `debsums`), AIDE, binarios estáticos |
| **Biblioteca** | `LD_PRELOAD` enganchando `readdir`, `open` | `cat /etc/ld.so.preload`, comparar `ls` con `getdents` crudo |
| **Módulo de kernel (LKM)** | Hooks de la tabla de syscalls / ftrace, PIDs ocultos | `lsmod` vs `/proc/modules` vs `/sys/module`, firma de módulos, lockdown |
| **eBPF** | Hooks sin módulo | `bpftool prog list`, restricción de `CAP_BPF`, `kernel.unprivileged_bpf_disabled=1` |
| **Bootkit / firmware** | Pre-kernel | Secure Boot, arranque medido con TPM, IMA/EVM |

```bash
$ rpm -Va --nomtime --nordev 2>/dev/null | grep -E '^..5|missing' | head
S.5....T.  /usr/bin/ps                       <-- content hash changed: INVESTIGATE
$ debsums -c 2>/dev/null
/usr/bin/netstat

$ cat /etc/ld.so.preload 2>/dev/null
/lib/libmemcached.so.6                       <-- not owned by any package: INVESTIGATE

$ sudo aide --check
AIDE found differences between database and filesystem!!
Start timestamp: 2026-08-25 10:52:03 -0300 (AIDE 0.18.6)

Summary:
  Total number of entries:      212944
  Added entries:                1
  Removed entries:              0
  Changed entries:              3

---------------------------------------------------
Added entries:
---------------------------------------------------
f++++++++++++++++: /usr/lib64/libhealth.so

---------------------------------------------------
Changed entries:
---------------------------------------------------
f   ...    .C... : /usr/bin/ps
f   ...    .C... : /etc/ld.so.preload
f   ...    .C... : /root/.ssh/authorized_keys

$ sudo bpftool prog list | tail -6
418: kprobe  name sys_getdents_hook  tag 9c2f1a3b4d5e6f70  gpl
     loaded_at 2026-08-25T09:11:44-0300  uid 0
     xlated 1288B  jited 736B  memlock 4096B  map_ids 91,92
```

Configuración mínima de AIDE que sí sirve (la base de datos debe vivir fuera del host o en medios de solo lectura, o el atacante también la actualiza):

```
# /etc/aide.conf (excerpt)
database_in  = file:/var/lib/aide/aide.db.gz
database_out = file:/var/lib/aide/aide.db.new.gz
database_attrs = sha512
report_url = file:/var/log/aide/aide.log
report_url = stdout

# rule definitions
NORMAL   = p+i+n+u+g+s+m+c+acl+selinux+xattrs+sha512
LOGS     = p+u+g+n+S+acl+selinux+xattrs
CONFIG   = p+i+n+u+g+s+m+c+sha512

/boot      NORMAL
/bin       NORMAL
/sbin      NORMAL
/usr/bin   NORMAL
/usr/sbin  NORMAL
/usr/lib   NORMAL
/lib       NORMAL
/etc       CONFIG
/root/.ssh NORMAL
/var/log   LOGS
!/var/log/journal
!/etc/mtab
!/etc/adjtime
```

```bash
$ sudo aide --init && sudo mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
$ sudo sha256sum /var/lib/aide/aide.db.gz | tee /media/wormdrive/aide.db.sha256
2f9a...c81  /var/lib/aide/aide.db.gz
```

`rkhunter` y `chkrootkit` complementan esto con chequeos de firmas/heurísticos:

```bash
$ sudo rkhunter --check --sk --rwo
Warning: The file properties have changed:
         File: /usr/bin/ps
         Current hash: 4d8a...  Stored hash: 91be...
Warning: Hidden directory found: /dev/.udev
Warning: Suspicious file types found in /dev: /dev/shm/.x
```

### 10.2 Ransomware — un problema de disponibilidad *y* de integridad

La primitiva técnica es trivial (cifrar archivos, borrar el texto plano). La defensa es enteramente arquitectónica: **backups inmutables, offline o de una sola escritura**, restauraciones probadas, segmentación de credenciales para que un administrador comprometido no alcance el servidor de backups, y monitoreo de patrones de renombrado/escritura masivos. Los backups accesibles con las mismas credenciales que producción no son backups.

---

## 11. Ataques a credenciales, phishing, ingeniería social

| Ataque | Mecanismo | Contramedida |
|---|---|---|
| **Fuerza bruta** | Probar todos los candidatos | Hashes lentos, límite de tasa, bloqueo, autenticación solo por clave |
| **Diccionario** | Probar candidatos probables | Política de calidad de contraseñas (`pam_pwquality`), rechazo por listas de filtraciones |
| **Rainbow tables** | Cadenas hash→texto plano precomputadas | **Sal por contraseña** (derrota la precomputación por completo) |
| **Credential stuffing** | Reusar pares filtrados en otros sitios | MFA, monitoreo de filtraciones, política de contraseñas únicas |
| **Password spraying** | Una contraseña común contra muchas cuentas | Bloqueo por *cuenta* Y por *origen*, detección de anomalías |
| **Pass-the-hash** | Reusar el hash almacenado, sin crackearlo nunca | Kerberos, sin hashes de admin local compartidos |
| **Keylogger / shoulder surfing** | Captura en la entrada | Endurecimiento del endpoint, tokens de hardware |
| **Phishing / spear-phishing / whaling** | Mensaje engañoso | DMARC/DKIM/SPF, capacitación, **MFA resistente a phishing (FIDO2)** |
| **Vishing / smishing / BEC** | Voz / SMS / compromiso del correo empresarial | Verificación fuera de banda de cambios de pago |
| **Fatiga de MFA / push bombing** | Spamear aprobaciones hasta que una sea aceptada | Number matching, FIDO2 |
| **Pretexting / tailgating / baiting / quid pro quo** | Explotación de la confianza humana | Política, disciplina de credenciales, cultura |

### 11.1 Por qué el salting es la respuesta a las rainbow tables

Una rainbow table amortiza el costo de crackear entre *todos* los objetivos. Una sal aleatoria única por contraseña significa que el atacante debe reconstruir la tabla para cada hash individual — la amortización se derrumba. Los formatos modernos de `crypt(3)` incorporan algoritmo, costo y sal:

| Prefijo | Algoritmo | Notas |
|---|---|---|
| `$1$` | MD5-crypt | **Obsoleto** |
| `$5$` | SHA-256-crypt | Rondas configurables |
| `$6$` | SHA-512-crypt | Predeterminado de Linux durante mucho tiempo |
| `$2b$` | bcrypt | Ligero en memoria, algo resistente a GPU |
| `$7$` | scrypt | Memory-hard |
| `$y$` | **yescrypt** | Memory-hard; predeterminado en Debian 11+, Fedora 35+ |
| `$argon2id$` | Argon2id | Recomendación actual para aplicaciones nuevas |

```bash
$ sudo getent shadow alice | cut -c1-70
alice:$y$j9T$Yg2Vw9xQ1rZ8kP4nL0cJs.$3nQ0v8sD2wF...:20320:0:99999:7:::
        ^^^ yescrypt
$ grep -E '^ENCRYPT_METHOD|^SHA_CRYPT' /etc/login.defs
ENCRYPT_METHOD YESCRYPT
$ authselect current 2>/dev/null || grep -l pam_unix /etc/pam.d/* | head -3
```

Las cuentas sin contraseña, o con un campo bloqueado pero usable, son un hallazgo permanente:

```bash
$ sudo awk -F: '($2 == "") {print $1 " HAS EMPTY PASSWORD"}' /etc/shadow
$ sudo awk -F: '($3 == 0) {print $1 " HAS UID 0"}' /etc/passwd
root
backupadmin        <-- second UID-0 account: INVESTIGATE
$ sudo passwd -S -a | awk '$2=="NP"'
svc_legacy NP 2026-01-14 0 99999 7 -1
```

Bloqueo con `pam_faillock` (RHEL 9 / Debian moderno) — notá el trade-off de disponibilidad:

```
# /etc/security/faillock.conf
deny = 5
unlock_time = 900
fail_interval = 900
even_deny_root
audit
silent
```

```bash
$ faillock --user alice
alice:
When                Type  Source                                           Valid
2026-08-25 10:58:11 RHOST 198.51.100.77                                        V
2026-08-25 10:58:13 RHOST 198.51.100.77                                        V
$ sudo faillock --user alice --reset
```

Y limitación a nivel de red con `fail2ban`:

```ini
# /etc/fail2ban/jail.d/sshd.local
[sshd]
enabled  = true
backend  = systemd
port     = ssh
maxretry = 5
findtime = 10m
bantime  = 1h
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 48h
ignoreip = 127.0.0.1/8 ::1 10.10.0.0/16
action   = nftables[type=allports]
```

```bash
$ sudo fail2ban-client status sshd
Status for the jail: sshd
|- Filter
|  |- Currently failed: 3
|  |- Total failed:     4128
|  `- Journal matches:  _SYSTEMD_UNIT=sshd.service + _COMM=sshd
`- Actions
   |- Currently banned: 27
   |- Total banned:     912
   `- Banned IP list:   198.51.100.77 203.0.113.9 ...
```

> El arreglo estructural para SSH no es la limitación de tasa — es `PasswordAuthentication no` con autenticación por certificado o por clave. La limitación es lo que desplegás para los servicios que todavía no pueden hacer eso.

---

## 12. Ataques de canal lateral y microarquitectónicos

Un canal lateral filtra información a través del *comportamiento físico o temporal* de un sistema en lugar de a través de su interfaz lógica. El algoritmo puede ser matemáticamente perfecto y aun así filtrar.

| Canal | Qué se observa | Objetivo clásico |
|---|---|---|
| **Timing** | Duración de la ejecución | `memcmp` no de tiempo constante sobre MACs; RSA/ECDSA |
| **Caché** (Flush+Reload, Prime+Probe, Evict+Time) | Qué líneas de caché se tocaron | T-tables de AES, square-and-multiply de RSA |
| **Potencia / EM / acústico** | Emisiones físicas | Tarjetas inteligentes, HSMs, dispositivos aislados |
| **Predictor de saltos / TLB** | Estado del predictor y del TLB | Variantes de Spectre, des-aleatorización de ASLR |
| **Inyección de fallos** | Errores inducidos | Rowhammer, glitching de voltaje/reloj, Plundervolt |
| **Throttling de frecuencia/potencia** | Timing inducido por DVFS | Hertzbleed (2022) |

### 12.1 Ataques de ejecución transitoria

La CPU especula más allá de una frontera, realiza la carga y después revierte arquitectónicamente — pero los **efectos secundarios microarquitectónicos (estado de la caché) sobreviven**, y pueden extraerse con un canal temporal de caché.

| Familia | CVE / nombre | Frontera cruzada |
|---|---|---|
| **Meltdown** (v3) | CVE-2017-5754 | Usuario lee memoria del kernel (carga fuera de orden más allá de un chequeo de permisos) |
| **Spectre v1** | CVE-2017-5753 | Bypass de chequeo de límites — especulación más allá de `if (x < len)` |
| **Spectre v2** | CVE-2017-5715 | Inyección de destino de salto — salto indirecto mal entrenado |
| **Spectre v4 / SSB** | CVE-2018-3639 | Bypass especulativo de almacenamiento |
| **L1TF / Foreshadow** | CVE-2018-3615/6/20 | Fallo terminal de L1 — SGX, VM→host |
| **MDS** (RIDL/Fallout/ZombieLoad) | CVE-2018-12126/7/30, 2019-11091 | Fuga desde buffers internos (puertos de store/fill/load) |
| **TAA** | CVE-2019-11135 | Aborto asíncrono de TSX |
| **SRBDS** | CVE-2020-0543 | Muestreo de datos del buffer de registros especiales (`RDRAND`) |
| **Retbleed** | CVE-2022-29900/1 | Instrucciones de retorno especuladas (derrota las suposiciones de retpoline) |
| **Downfall / GDS** | CVE-2022-40982 | Muestreo de datos de `AVX GATHER` (Intel) |
| **Inception / SRSO** | CVE-2023-20569 | Desbordamiento especulativo de la pila de retornos (AMD) |
| **Zenbleed** | CVE-2023-20593 | Fuga de registro en `vzeroupper` (AMD Zen 2) |
| **RFDS** | CVE-2023-28746 | Muestreo de datos del banco de registros (Intel Atom) |

El único comando que responde "¿estoy mitigado?":

```bash
$ grep . /sys/devices/system/cpu/vulnerabilities/*
/sys/devices/system/cpu/vulnerabilities/gather_data_sampling:Mitigation: Microcode
/sys/devices/system/cpu/vulnerabilities/itlb_multihit:KVM: Mitigation: Split huge pages
/sys/devices/system/cpu/vulnerabilities/l1tf:Mitigation: PTE Inversion; VMX: conditional cache flushes, SMT vulnerable
/sys/devices/system/cpu/vulnerabilities/mds:Mitigation: Clear CPU buffers; SMT vulnerable
/sys/devices/system/cpu/vulnerabilities/meltdown:Mitigation: PTI
/sys/devices/system/cpu/vulnerabilities/mmio_stale_data:Mitigation: Clear CPU buffers; SMT vulnerable
/sys/devices/system/cpu/vulnerabilities/retbleed:Mitigation: Enhanced IBRS
/sys/devices/system/cpu/vulnerabilities/spec_rstack_overflow:Not affected
/sys/devices/system/cpu/vulnerabilities/spec_store_bypass:Mitigation: Speculative Store Bypass disabled via prctl
/sys/devices/system/cpu/vulnerabilities/spectre_v1:Mitigation: usercopy/swapgs barriers and __user pointer sanitization
/sys/devices/system/cpu/vulnerabilities/spectre_v2:Mitigation: Enhanced IBRS, IBPB: conditional, RSB filling, PBRSB-eIBRS: SW sequence
/sys/devices/system/cpu/vulnerabilities/srbds:Mitigation: Microcode
/sys/devices/system/cpu/vulnerabilities/tsx_async_abort:Not affected
```

Leé `SMT vulnerable` literalmente: **el hyper-threading es un canal de microarquitectura compartida entre hermanos.** En un hipervisor multi-tenant eso es una fuga real entre inquilinos; en un servidor de aplicaciones de un solo inquilino normalmente no compensa la pérdida de ~15–30 % de throughput que implica deshabilitar SMT.

### 12.2 Trade-offs de mitigación

| Mitigación | Perilla del kernel | Protege | Costo típico medido |
|---|---|---|---|
| **KPTI** (Meltdown) | `pti=on` | Lectura de memoria de kernel desde usuario | Intensivo en syscalls: 5–30 %; limitado por cómputo: ~0 % |
| **Retpoline / IBRS / eIBRS** | `spectre_v2=` | Inyección de destino de salto | 1–10 %, depende de la carga |
| **SSBD** | `spec_store_bypass_disable=` | Fugas por bypass de almacenamiento | 2–8 % en algunas cargas |
| **Limpieza de buffers MDS (`VERW`)** | automático con microcódigo | Muestreo de buffers | 1–5 %, peor con muchos cambios de contexto |
| **`nosmt`** | `mitigations=auto,nosmt` | Fugas entre hermanos | 15–30 % de pérdida de throughput |
| **`mitigations=off`** | — | *nada* | Recupera todo lo anterior |

> Tratá estos rangos como órdenes de magnitud, no como constantes — siempre medí tu carga de trabajo. La regla de decisión que sobrevive a la revisión: **multi-tenant o código local no confiable → mitigaciones completas más `nosmt`; appliance dedicado de un solo inquilino sin ejecución de código no confiable y sin navegador → `mitigations=off` puede ser una aceptación de riesgo defendible, documentada y firmada.** Nunca debe ser un valor por defecto sin documentar.

```bash
$ cat /proc/cmdline
BOOT_IMAGE=/vmlinuz-6.6.0 root=/dev/mapper/vg0-root ro mitigations=auto,nosmt
$ lscpu | grep -E '^Thread|^Vulnerability Meltdown|^Vulnerability Spectre v2'
Thread(s) per core:  1
Vulnerability Meltdown: Mitigation; PTI
Vulnerability Spectre v2: Mitigation; Enhanced IBRS, IBPB: conditional, RSB filling
```

### 12.3 Rowhammer — un ataque de inyección de fallos, no un bug de software

Activar repetidamente una fila de DRAM induce fuga de carga en filas físicamente adyacentes, volteando bits **sin acceder nunca a ellos**. Un bit volteado en una entrada de tabla de páginas da acceso arbitrario a memoria física; un bit volteado en una clave pública RSA puede habilitar su factorización. Demostrado desde JavaScript (Rowhammer.js) y por red (Throwhammer).

Mitigaciones, en orden creciente de efectividad: aumento de la tasa de refresco (2× tREFI), Target Row Refresh (**TRR** — bypasseado repetidamente, p. ej. por TRRespass y Blacksmith), **memoria ECC** (sube la vara sustancialmente pero no es una prueba — ECCploit), y el **Refresh Management** on-die de DDR5. Esto es una decisión de compra de hardware, no un `sysctl`. Para servidores que guardan secretos, **la RAM ECC es un requisito de seguridad, no un lujo de fiabilidad.**

```bash
$ sudo dmidecode -t memory | grep -E 'Type:|Total Width|Data Width' | head -6
        Total Width: 72 bits            <-- 72 vs 64 = ECC present
        Data Width: 64 bits
        Type: DDR4
$ sudo edac-util -v
mc0: 0 Uncorrected Errors with no DIMM info
mc0: 0 Corrected Errors with no DIMM info
mc0: csrow0: 0 Uncorrected Errors
mc0: csrow0: CPU_SrcID#0_MC#0_Chan#0_DIMM#0: 0 Corrected Errors
```

### 12.4 El tiempo constante como disciplina

Todo código que maneja secretos debe tener tiempo de ejecución y patrones de acceso a memoria independientes del secreto. En la práctica: usá `CRYPTO_memcmp()` / `crypto_verify_32()` en lugar de `memcmp()` para comparar MACs; usá primitivas de biblioteca (OpenSSL, libsodium) en vez de exponenciación modular hecha a mano; nunca ramifiques según datos secretos. Una implementación "correcta" de AES con búsquedas en tablas dependientes de los datos filtra su clave por el canal de caché.

---

## 13. Compromiso de la cadena de suministro

La versión moderna de "trusting trust". Tu superficie de ataque es la unión de la superficie de ataque de cada dependencia, más cada sistema de compilación que toca tu artefacto.

| Vector | Ejemplo | Control |
|---|---|---|
| Código fuente upstream con backdoor | **CVE-2024-3094** (`xz`/liblzma, 2024) | Builds reproducibles, diff build-vs-fuente, diversidad de mantenedores |
| Cuenta de mantenedor comprometida | `event-stream` (npm, 2018) | 2FA en los registries, releases firmadas |
| **Typosquatting** | `python-dateutil` → `python3-dateutil` | Vendoring, allowlists, registry proxy interno |
| **Confusión de dependencias** | Un nombre interno se resuelve desde el registry público | Nombres con scope, fijar el índice, sin resolución de respaldo |
| Sistema de compilación comprometido | SolarWinds (2020) | Builds herméticos, niveles SLSA, atestación de procedencia |
| Imagen base de contenedor maliciosa | Cryptominers en imágenes públicas | Imágenes firmadas, fijado por digest, política de admisión |
| Canal de actualización comprometido | Repos sin firmar/por HTTP | Repos firmados con GPG, TLS, `gpgcheck=1` |

**CVE-2024-3094** es el caso de estudio: una operación de ingeniería social de varios años plantó un backdoor ofuscado en los *tarballs* de release de `xz-utils` (no en el árbol git), entregado a través de fixtures de test, que enganchaba `RSA_public_decrypt` vía resolución IFUNC en `sshd` (a través de la dependencia `liblzma` de `libsystemd`) para otorgar bypass de autenticación al poseedor de una clave específica. CVSS 10.0. Se descubrió por una investigación de rendimiento — un retraso de ~500 ms en los logins SSH — no por ningún escáner. **Todos los chequeos automatizados de la §14 habrían pasado.**

```bash
$ rpm -K /var/cache/dnf/updates/packages/openssl-3.2.2-6.el9.x86_64.rpm
openssl-3.2.2-6.el9.x86_64.rpm: digests signatures OK
$ apt-key list 2>/dev/null; ls -l /etc/apt/trusted.gpg.d/ /etc/apt/keyrings/
$ grep -rE '^gpgcheck|^repo_gpgcheck' /etc/yum.repos.d/*.repo | grep -v '=1'
/etc/yum.repos.d/vendor.repo:gpgcheck=0        <-- FINDING

$ syft dir:/opt/app -o cyclonedx-json > sbom.json
 ✔ Indexed file system  /opt/app
 ✔ Cataloged contents   sha256:9f2c…
   ├── 412 packages
$ grype sbom:sbom.json --fail-on high
NAME          INSTALLED   FIXED-IN   TYPE   VULNERABILITY   SEVERITY
log4j-core    2.14.1      2.17.1     java-archive  CVE-2021-44228  Critical
netty-codec   4.1.68      4.1.77     java-archive  CVE-2022-24823  High
$ echo $?
1
```

---

## 14. Operacionalizarlo: el pipeline de remediación como infraestructura

### 14.1 SLOs de remediación

| Clase | Disparador | SLO de remediación | Proceso de cambio |
|---|---|---|---|
| **P0** | En CISA KEV **y** alcanzable desde internet | 24 h | Cambio de emergencia, avisar a la guardia |
| **P1** | CVSS ≥ 9.0, o EPSS ≥ 0.10 con CVSS ≥ 7.0 | 7 días | Cambio acelerado |
| **P2** | CVSS 7.0–8.9 | 30 días | Ventana normal de parcheo |
| **P3** | CVSS < 7.0 | Próxima ventana trimestral | Agrupado |
| **Suprimido** | VEX `not_affected` con una justificación declarada | n/a | Documentado, expira en 90 días |

Toda supresión debe llevar una razón legible por máquina y una fecha de expiración. Una supresión sin expiración es un punto ciego permanente.

### 14.2 Compuerta de escaneo en CI (GitLab CI, completa)

```yaml
# .gitlab-ci.yml — vulnerability gate for container images
stages: [build, sbom, scan, gate]

variables:
  IMAGE: "$CI_REGISTRY_IMAGE:$CI_COMMIT_SHORT_SHA"
  TRIVY_CACHE_DIR: ".trivycache"
  TRIVY_NO_PROGRESS: "true"

build:
  stage: build
  image: quay.io/buildah/stable:v1.35
  script:
    - buildah bud --format docker -t "$IMAGE" .
    - buildah push "$IMAGE"

sbom:
  stage: sbom
  image: anchore/syft:v1.4.1
  script:
    - syft "$IMAGE" -o cyclonedx-json=sbom.cdx.json -o spdx-json=sbom.spdx.json
  artifacts:
    paths: [sbom.cdx.json, sbom.spdx.json]
    expire_in: 1 year
    reports:
      cyclonedx: sbom.cdx.json

scan:
  stage: scan
  image: aquasec/trivy:0.52.2
  cache:
    key: trivy-db
    paths: [".trivycache"]
  script:
    # Report everything, never fail here — the gate job decides
    - trivy image --exit-code 0 --format json --output trivy.json "$IMAGE"
    - trivy image --exit-code 0 --format table --severity HIGH,CRITICAL "$IMAGE"
    - trivy config --exit-code 0 --format json --output trivy-iac.json .
    - trivy fs --scanners secret --exit-code 1 --format table .
  artifacts:
    paths: [trivy.json, trivy-iac.json]
    when: always

gate:
  stage: gate
  image: aquasec/trivy:0.52.2
  script:
    # Hard gate: any CRITICAL with a known fix blocks the pipeline.
    - trivy image --severity CRITICAL --ignore-unfixed --exit-code 1
        --ignorefile .trivyignore.yaml --vex vex.cdx.json "$IMAGE"
    # Soft gate: HIGH with a fix is reported and tracked, not blocking.
    - trivy image --severity HIGH --ignore-unfixed --exit-code 0
        --ignorefile .trivyignore.yaml --vex vex.cdx.json "$IMAGE"
  allow_failure: false
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
```

```yaml
# .trivyignore.yaml — every suppression is justified AND expires
vulnerabilities:
  - id: CVE-2024-28085
    paths: ["usr/bin/wall"]
    statement: "util-linux wall(1) escape injection; no interactive local users on this image."
    expired_at: 2026-11-01
  - id: CVE-2023-45853
    statement: "zlib minizip; the image never processes untrusted ZIP archives."
    expired_at: 2026-10-15
```

```bash
$ trivy image --severity CRITICAL --ignore-unfixed --exit-code 1 registry.example/app:9f2c1ab
2026-08-25T11:04:18-03:00  INFO  Vulnerability scanning is enabled
registry.example/app:9f2c1ab (debian 12.6)
Total: 2 (CRITICAL: 2)

┌──────────────┬────────────────┬──────────┬────────┬───────────────────┬───────────────┐
│   Library    │ Vulnerability  │ Severity │ Status │ Installed Version │ Fixed Version │
├──────────────┼────────────────┼──────────┼────────┼───────────────────┼───────────────┤
│ libssl3      │ CVE-2026-2153  │ CRITICAL │ fixed  │ 3.0.13-1~deb12u1  │ 3.0.16-1~...  │
│ libtasn1-6   │ CVE-2026-1877  │ CRITICAL │ fixed  │ 4.19.0-2          │ 4.19.0-2+deb..│
└──────────────┴────────────────┴──────────┴────────┴───────────────────┴───────────────┘
$ echo $?
1
```

### 14.3 Parcheo de la flota en anillos (Ansible, completo)

```yaml
# patch-rings.yml — ring-based security patching with verification
# Usage: ansible-playbook -i inventory patch-rings.yml -e ring=canary
---
- name: Security patch ring
  hosts: "{{ ring | default('canary') }}"
  become: true
  serial: "{{ batch | default('20%') }}"
  max_fail_percentage: 0
  gather_facts: true

  vars:
    reboot_if_required: true
    reboot_timeout: 900

  pre_tasks:
    - name: Record pre-patch package state
      ansible.builtin.shell: |
        set -o pipefail
        if command -v rpm >/dev/null; then rpm -qa | sort; else dpkg -l | sort; fi
      args: {executable: /bin/bash}
      register: pkgs_before
      changed_when: false

    - name: Drain from load balancer
      ansible.builtin.uri:
        url: "https://lb.example/api/v1/backends/{{ inventory_hostname }}/drain"
        method: POST
        status_code: [200, 204]
      delegate_to: localhost
      become: false
      when: "'web' in group_names"

  tasks:
    - name: Apply security updates (RHEL family)
      ansible.builtin.dnf:
        name: "*"
        security: true
        bugfix: false
        state: latest
        update_cache: true
      when: ansible_os_family == "RedHat"
      register: dnf_patch

    - name: Apply security updates (Debian family)
      ansible.builtin.apt:
        upgrade: dist
        update_cache: true
        cache_valid_time: 3600
        only_upgrade: true
      environment:
        DEBIAN_FRONTEND: noninteractive
      when: ansible_os_family == "Debian"
      register: apt_patch

    - name: Detect processes still using deleted (pre-patch) libraries
      ansible.builtin.shell: |
        set -o pipefail
        if command -v needs-restarting >/dev/null; then
          needs-restarting -s 2>/dev/null || true
        else
          checkrestart -v 2>/dev/null || true
        fi
      args: {executable: /bin/bash}
      register: stale_procs
      changed_when: false

    - name: Fail loudly if remediation is incomplete without a reboot
      ansible.builtin.assert:
        that: stale_procs.stdout | length == 0 or reboot_if_required
        fail_msg: >-
          Packages upgraded but {{ stale_procs.stdout_lines | length }} services still
          map the OLD library. The host is NOT remediated.

    - name: Check whether a reboot is required
      ansible.builtin.stat:
        path: /var/run/reboot-required
      register: deb_reboot

    - name: Check kernel currency (RHEL)
      ansible.builtin.command: needs-restarting -r
      register: rhel_reboot
      failed_when: false
      changed_when: false
      when: ansible_os_family == "RedHat"

    - name: Reboot when required
      ansible.builtin.reboot:
        reboot_timeout: "{{ reboot_timeout }}"
        post_reboot_delay: 30
        test_command: systemctl is-system-running --wait
      when:
        - reboot_if_required
        - deb_reboot.stat.exists | default(false) or (rhel_reboot.rc | default(0)) == 1

  post_tasks:
    - name: Re-scan for remaining security errata
      ansible.builtin.shell: |
        set -o pipefail
        if command -v dnf >/dev/null; then
          dnf -q updateinfo list --security | wc -l
        else
          apt-get -s -o Dir::Etc::SourceList=/etc/apt/sources.list.d/security.list \
            dist-upgrade | grep -c '^Inst' || true
        fi
      args: {executable: /bin/bash}
      register: remaining
      changed_when: false

    - name: Assert zero outstanding security errata
      ansible.builtin.assert:
        that: remaining.stdout | int == 0
        fail_msg: "{{ remaining.stdout }} security errata still outstanding after patching."

    - name: Return to load balancer
      ansible.builtin.uri:
        url: "https://lb.example/api/v1/backends/{{ inventory_hostname }}/enable"
        method: POST
        status_code: [200, 204]
      delegate_to: localhost
      become: false
      when: "'web' in group_names"
```

```bash
$ ansible-playbook -i inventory patch-rings.yml -e ring=canary -e batch=1
PLAY [Security patch ring] *****************************************************
TASK [Apply security updates (Debian family)] **********************************
changed: [web-canary-01]
TASK [Detect processes still using deleted (pre-patch) libraries] **************
ok: [web-canary-01]
TASK [Reboot when required] ****************************************************
changed: [web-canary-01]
TASK [Assert zero outstanding security errata] *********************************
ok: [web-canary-01]
PLAY RECAP *********************************************************************
web-canary-01              : ok=11   changed=3    unreachable=0    failed=0
```

### 14.4 Actualizaciones de seguridad desatendidas (el control aburrido que funciona)

```ini
# Debian: /etc/apt/apt.conf.d/50unattended-upgrades (excerpt)
Unattended-Upgrade::Origins-Pattern {
      "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::MailReport "on-change";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
```

```ini
# RHEL: /etc/dnf/automatic.conf (excerpt)
[commands]
upgrade_type = security
apply_updates = yes
reboot = when-needed
```

```bash
$ sudo systemctl enable --now dnf-automatic.timer
$ systemctl list-timers dnf-automatic.timer
NEXT                        LEFT     LAST                        PASSED   UNIT
Wed 2026-08-26 06:31:44 -03 19h left Tue 2026-08-25 06:29:12 -03 4h 36min dnf-automatic.timer
$ sudo unattended-upgrade --dry-run -d 2>&1 | tail -3
Packages that will be upgraded: libssl3 openssl
Writing dpkg log to /var/log/unattended-upgrades/unattended-upgrades-dpkg.log
```

---

## 15. Verificación y diagnóstico de fallos

### 15.1 La escalera de verificación — sabé sobre qué peldaño se apoya una afirmación

| Afirmación | Evidencia que realmente la respalda | Sustituto falso común |
|---|---|---|
| "El paquete está parcheado" | `rpm -q --changelog pkg \| grep CVE`; el tracker de la distro dice arreglado | "Corrimos `apt upgrade` la semana pasada" |
| "El **host** está remediado" | Ningún proceso mapea la biblioteca vieja: `needs-restarting -s` / `lsof +c0 \| grep DEL` | Solo la versión del paquete |
| "La **flota** está remediada" | Consulta de inventario sobre el 100 % de los activos, con el denominador declarado | Un escaneo de los hosts que el escáner pudo alcanzar |
| "No es explotable" | Análisis de alcanzabilidad o declaración VEX con justificación | "Probablemente no sea alcanzable" |
| "La mitigación está activa" | `/sys/devices/system/cpu/vulnerabilities/*`, `checksec`, lectura de vuelta con `sysctl` | El archivo de configuración contiene el ajuste |
| "La configuración está aplicada" | Lectura de vuelta en tiempo de ejecución (`sshd -T`, `nft list ruleset`, `sysctl -a`) | El archivo en disco |
| "Lo detectaríamos" | Un ejercicio de mesa o de purple team que disparó la alerta | Un agente instalado |

### 15.2 Tabla síntoma → diagnóstico

| Síntoma | Causa probable | Comando |
|---|---|---|
| El ajuste está en `/etc/sysctl.d/` pero no tiene efecto | Un archivo posterior lo sobrescribe; unidad no aplicada; namespace | `sysctl -a --pattern X`; `sysctl --system`; revisar el orden de `/usr/lib/sysctl.d` |
| `sshd_config` editado, comportamiento sin cambios | Bloque `Match`, orden de `Include`, o servicio no recargado | `sshd -T \| grep X`; `sshd -T -C user=x,host=y,addr=z` |
| Regla de firewall presente, el tráfico igual pasa | Regla después de un `accept`; hook/prioridad equivocados; cortocircuito de conntrack `established` | `nft list ruleset -a`; `nft monitor trace` |
| Paquete actualizado, el escáner lo sigue marcando | Un proceso de larga duración retiene el mapeo viejo | `lsof +c0 2>/dev/null \| grep -E 'DEL\|(deleted)'` |
| El escáner reporta un CVE que la distro dice arreglado | Backport: desajuste de la cadena de versión | Datos OVAL de la distro; `rpm -q --changelog` |
| CVSS 9.8 pero nadie puede explotarlo | Precondición ausente en tu configuración | Revisar EPSS/KEV, leer los prerrequisitos del aviso |
| El binario crashea con `*** stack smashing detected ***` | Overflow real, capturado por el canary | Core dump + `gdb bt`, y después reportar el bug — no deshabilitar el canary |
| Los logins SSH de golpe ~500 ms más lentos | Podría ser DNS/GSSAPI — o una biblioteca comprometida | `ssh -vvv`; `perf trace`; `rpm -Va`; comparar `sha256sum` con el de la distro |
| La mitigación muestra `Vulnerable: … SMT vulnerable` | Microcódigo presente pero SMT habilitado | `lscpu`; `mitigations=auto,nosmt`; actualización de firmware |
| El servicio funciona en staging, el sandbox de `systemd` lo mata en producción | `SystemCallFilter`/`ProtectSystem` demasiado estrictos | `journalctl -u X`; `SystemCallLog=@all` para observar primero |
| `fail2ban` banea usuarios legítimos | Salida NAT compartida; bucle de reintentos en un cliente | `fail2ban-client status`; ampliar `ignoreip`, bloqueo por cuenta en su lugar |
| AIDE reporta miles de cambios | Base de datos no actualizada tras una tanda legítima de parches | Reinicializar tras cada ciclo de parcheo; guardar la BD fuera del host |

### 15.3 Comandos de diagnóstico que vale la pena memorizar

```bash
# What is actually listening, and which binary owns it
$ sudo ss -tulpnH | awk '{print $1,$5,$7}' | sort -u
tcp 0.0.0.0:22   users:(("sshd",pid=1121,fd=3))
tcp 127.0.0.1:5432 users:(("postgres",pid=1443,fd=7))
udp 0.0.0.0:123  users:(("chronyd",pid=980,fd=5))

# Processes still mapping deleted (pre-upgrade) libraries — the #1 false "patched"
$ sudo lsof +c0 2>/dev/null | awk '/DEL|\(deleted\)/ {print $1,$2,$NF}' | sort -u
nginx     2211 /usr/lib/x86_64-linux-gnu/libssl.so.3
postgres  1443 /usr/lib/x86_64-linux-gnu/libcrypto.so.3
$ sudo needs-restarting -s
systemd-journald.service
nginx.service

# Reboot required?
$ needs-restarting -r
Core libraries or services have been updated since boot-up:
  * kernel
Reboot is required to fully utilize these updates.
$ echo $?
1

# Runtime config readback — never trust the file
$ sudo sshd -T | grep -E '^(permitrootlogin|passwordauthentication|kbdinteractive)'
permitrootlogin no
passwordauthentication no
kbdinteractiveauthentication no
$ sudo nft list ruleset | head -5
$ sudo sysctl -a --pattern 'randomize|protected_|rp_filter|syncookies'

# Broad posture baseline
$ sudo lynis audit system --quick 2>&1 | tail -8
  Hardening index : 74 [############        ]
  Tests performed : 268
  Suggestions     : 31
$ sudo oscap xccdf eval --profile xccdf_org.ssgproject.content_profile_cis_server_l1 \
    --results-arf arf.xml --report report.html \
    /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml
Title   Ensure sudo is installed
Rule    xccdf_org.ssgproject.content_rule_package_sudo_installed
Result  pass
...
$ oscap info arf.xml | grep -A2 'Score'
```

### 15.4 Modos de fallo del proceso mismo

1. **Fraude del denominador.** "98 % parcheado" sobre los activos que el escáner pudo alcanzar. El 2 % que no puede alcanzar es donde empieza la brecha. Reconciliá el inventario del escáner contra la CMDB/DHCP/tablas MAC de los switches y reportá la *brecha*, no el ratio.
2. **Amnesia de reinicio.** La razón más común por la que una flota parcheada sigue siendo explotable. Automatizá el chequeo de `needs-restarting` como compuerta, no como reporte.
3. **Podredumbre de supresiones.** Un `.trivyignore` sin fechas de expiración se convierte en una aceptación de riesgo permanente e invisible.
4. **Escanear solo lo que construís.** Las imágenes base, los sidecars, los init containers, los appliances de proveedores, el firmware y los propios runners de CI también cargan CVEs.
5. **Creer que "sin hallazgos" significa "sin vulnerabilidades".** Ningún escáner detectó `xz`. La cobertura de detección es una *propiedad que debés medir*, no una que puedas asumir.
6. **Confundir cumplimiento con seguridad.** Un benchmark CIS aprobado es un piso. No dice nada sobre la inyección SQL de tu aplicación.

---

## 16. Hechos destilados para el día del examen

- **CWE = clase, CVE = instancia, CVSS = severidad, EPSS = probabilidad, KEV = observado.**
- Rangos CVSS: 0.1–3.9 bajo · 4.0–6.9 medio · 7.0–8.9 alto · 9.0–10.0 crítico.
- `Riesgo = Amenaza × Vulnerabilidad × Impacto`; eliminá cualquier factor y el riesgo desaparece.
- **La sal derrota las rainbow tables**, no la fuerza bruta. Los hashes lentos/memory-hard (yescrypt, bcrypt, Argon2) derrotan la fuerza bruta.
- El **stack canary** protege la dirección de retorno guardada; **NX** detiene la ejecución de shellcode; **ASLR/PIE** aleatoriza direcciones; **RELRO** protege la GOT. Los cuatro son necesarios — cada uno tiene un bypass.
- **TOCTOU** = el chequeo y el uso son operaciones separadas; se arregla operando sobre un descriptor de archivo, no sobre una ruta.
- Las **SYN cookies** evitan asignar estado hasta que el handshake se completa, a costa de las opciones TCP.
- La **amplificación** requiere falsificación de la dirección de origen; el arreglo estructural es el **filtrado de ingreso BCP 38**.
- **Meltdown → KPTI. Spectre v2 → retpoline/IBRS. SMT es un canal lateral.** Revisá `/sys/devices/system/cpu/vulnerabilities/`.
- **Rowhammer** es un ataque de inyección de fallos en hardware; ECC sube la vara pero no elimina el riesgo.
- **DNSSEC provee integridad/autenticidad, no confidencialidad**; DoT/DoH proveen confidencialidad, no integridad de los datos de la zona.
- **El gusano se autopropaga; el virus necesita un anfitrión; el troyano necesita un usuario dispuesto; el rootkit oculta al resto.**
- Los rootkits viven a nivel de userland, biblioteca (`/etc/ld.so.preload`), módulo de kernel, eBPF o firmware — cada uno necesita un detector distinto.
- Un **0-day** no tiene arreglo; un **n-day** tiene un arreglo que no aplicaste. La mayoría de las brechas son n-days.

---

## Referencias

- LPI — Exam 303-300 Objectives (LPIC-3 Security v3.0): https://www.lpi.org/our-certifications/exam-303-objectives/
- MITRE — CVE Program: https://www.cve.org/
- MITRE — CWE, Common Weakness Enumeration: https://cwe.mitre.org/
- MITRE — CWE Top 25 Most Dangerous Software Weaknesses: https://cwe.mitre.org/top25/
- FIRST — CVSS v3.1 Specification Document: https://www.first.org/cvss/v3-1/specification-document
- FIRST — CVSS v4.0 Specification Document: https://www.first.org/cvss/v4-0/specification-document
- FIRST — EPSS, Exploit Prediction Scoring System: https://www.first.org/epss/
- NIST — National Vulnerability Database: https://nvd.nist.gov/
- NIST — NVD API 2.0 documentation: https://nvd.nist.gov/developers/vulnerabilities
- CISA — Known Exploited Vulnerabilities Catalog: https://www.cisa.gov/known-exploited-vulnerabilities-catalog
- CISA — Alert TA14-013A, UDP-Based Amplification Attacks: https://www.cisa.gov/news-events/alerts/2014/01/17/udp-based-amplification-attacks
- OWASP — Top 10: https://owasp.org/www-project-top-ten/
- OWASP — Cheat Sheet Series: https://cheatsheetseries.owasp.org/
- OWASP — SQL Injection Prevention Cheat Sheet: https://cheatsheetseries.owasp.org/cheatsheets/SQL_Injection_Prevention_Cheat_Sheet.html
- Linux kernel — Hardware vulnerabilities documentation: https://www.kernel.org/doc/html/latest/admin-guide/hw-vuln/index.html
- Linux kernel — Kernel parameters (`mitigations=`, `pti=`, `spectre_v2=`): https://www.kernel.org/doc/html/latest/admin-guide/kernel-parameters.html
- Linux kernel — sysctl/fs documentation (`protected_symlinks`, `protected_hardlinks`): https://www.kernel.org/doc/html/latest/admin-guide/sysctl/fs.html
- Linux kernel — sysctl/kernel documentation (`randomize_va_space`, `kptr_restrict`, Yama): https://www.kernel.org/doc/html/latest/admin-guide/sysctl/kernel.html
- Linux kernel — Yama LSM (`ptrace_scope`): https://www.kernel.org/doc/html/latest/admin-guide/LSM/Yama.html
- Meltdown and Spectre — official disclosure site: https://meltdownattack.com/
- Intel — Transient Execution Attacks & Related Security Issues: https://www.intel.com/content/www/us/en/developer/topic-technology/software-security-guidance/overview.html
- AMD — Security Bulletins: https://www.amd.com/en/resources/product-security.html
- Google Project Zero — "Exploiting the DRAM rowhammer bug to gain kernel privileges": https://googleprojectzero.blogspot.com/2015/03/exploiting-dram-rowhammer-bug-to-gain.html
- CVE-2024-3094 — Red Hat advisory on the `xz`/liblzma backdoor: https://access.redhat.com/security/cve/CVE-2024-3094
- CVE-2024-6387 — Qualys advisory, "regreSSHion" OpenSSH signal-handler race: https://www.qualys.com/2024/07/01/cve-2024-6387/regresshion.txt
- CVE-2021-4034 — Qualys advisory, PwnKit polkit local privilege escalation: https://www.qualys.com/2022/01/25/cve-2021-4034/pwnkit.txt
- CVE-2021-3156 — Qualys advisory, sudo "Baron Samedit" heap overflow: https://www.qualys.com/2021/01/26/cve-2021-3156/baron-samedit-heap-based-overflow-sudo.txt
- Dirty Pipe (CVE-2022-0847) — original disclosure: https://dirtypipe.cm4all.com/
- Apache Log4j Security Vulnerabilities (CVE-2021-44228): https://logging.apache.org/log4j/2.x/security.html
- Red Hat — Security Data and OVAL feeds: https://access.redhat.com/security/data/
- Debian — Security Bug Tracker: https://security-tracker.debian.org/tracker/
- Ubuntu — Security Notices: https://ubuntu.com/security/notices
- SUSE — Security Advisories: https://www.suse.com/support/security/
- systemd — `systemd.exec(5)` sandboxing directives: https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
- systemd — `systemd-analyze(1)` (`security` verb): https://www.freedesktop.org/software/systemd/man/latest/systemd-analyze.html
- nftables wiki — Meters, sets and rate limiting: https://wiki.nftables.org/wiki-nftables/index.php/Main_Page
- AIDE — Advanced Intrusion Detection Environment: https://aide.github.io/
- Fail2ban — official documentation: https://github.com/fail2ban/fail2ban
- OpenSCAP / SCAP Security Guide: https://www.open-scap.org/ · https://complianceascode.readthedocs.io/
- Lynis — security auditing tool: https://cisofy.com/lynis/
- Aqua Trivy — documentation: https://aquasecurity.github.io/trivy/
- Anchore Syft / Grype: https://github.com/anchore/syft · https://github.com/anchore/grype
- CycloneDX — SBOM and VEX specification: https://cyclonedx.org/specification/overview/
- SPDX — Software Package Data Exchange: https://spdx.dev/
- SLSA — Supply-chain Levels for Software Artifacts: https://slsa.dev/
- IETF — RFC 2827 (BCP 38), Network Ingress Filtering: https://www.rfc-editor.org/rfc/rfc2827
- IETF — RFC 4033/4034/4035, DNS Security Introduction and Requirements: https://www.rfc-editor.org/rfc/rfc4033
- IETF — RFC 7873, Domain Name System (DNS) Cookies: https://www.rfc-editor.org/rfc/rfc7873
- IETF — RFC 4987, TCP SYN Flooding Attacks and Common Mitigations: https://www.rfc-editor.org/rfc/rfc4987
- Debian Wiki — Hardening (compiler and toolchain flags): https://wiki.debian.org/Hardening
- GNU C Library manual — Dynamic linker and secure-execution mode (`ld.so(8)`): https://man7.org/linux/man-pages/man8/ld.so.8.html
- `capabilities(7)` — Linux capability model: https://man7.org/linux/man-pages/man7/capabilities.7.html
- `openat2(2)` — path resolution with `RESOLVE_*` flags: https://man7.org/linux/man-pages/man2/openat2.2.html
- `signal-safety(7)` — async-signal-safe functions: https://man7.org/linux/man-pages/man7/signal-safety.7.html
- `crypt(5)` — password hashing methods and prefixes: https://man7.org/linux/man-pages/man5/crypt.5.html