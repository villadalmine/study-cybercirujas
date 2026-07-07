# Ejercicios guiados — Tema 1.4: ICT Skills and Working in Linux

**Certificación:** LPI Linux Essentials (010-160, versión 1.6) · **Peso:** 2
**Referencia:** [LPI Learning Materials 1.4](https://learning.lpi.org/en/learning-materials/010-160/1/1.4/)

> **Requisitos:** una instalación de Linux con entorno de escritorio (física o máquina virtual) y un navegador web. No necesitás permisos de administrador salvo donde se indique.

---

## Ejercicio 1 — Encontrar la terminal desde el escritorio

Gran parte del trabajo en Linux ocurre en la **command line**. El primer paso es saber llegar a ella desde el entorno gráfico.

1. Iniciá sesión en tu entorno de escritorio (GNOME, KDE Plasma, Xfce u otro).
2. Abrí el lanzador de aplicaciones y buscá la palabra **terminal**. Según el entorno, la aplicación puede llamarse *GNOME Terminal*, *Konsole*, *Xfce Terminal*, etc.
3. Abrí la aplicación. Vas a ver un **prompt** parecido a:
   ```
   usuario@equipo:~$
   ```
4. Escribí el siguiente comando y presioná Enter:
   ```
   echo "Hola desde la shell"
   ```
5. Ahora identificá qué **shell** estás usando:
   ```
   echo $SHELL
   ```
6. Cerrá la terminal escribiendo:
   ```
   exit
   ```

**Preguntas:**

- **1.a** ¿Qué diferencia hay entre *terminal emulator* y *shell*?
- **1.b** ¿Qué indica normalmente el símbolo `$` al final del prompt? ¿Y el símbolo `#`?
- **1.c** ¿Cuál es la shell más común en las distribuciones Linux?

---

## Ejercicio 2 — Consolas virtuales (virtual consoles)

Linux ofrece varias **virtual consoles** de texto independientes del entorno gráfico. Son útiles cuando la interfaz gráfica falla o en servidores sin escritorio.

> ⚠️ Si trabajás en una máquina virtual, el atajo de teclado puede ser capturado por el sistema anfitrión. En VirtualBox, por ejemplo, usá la tecla *Host* en lugar de `Ctrl+Alt`.

1. Desde tu sesión gráfica, presioná `Ctrl+Alt+F3`. Deberías ver una pantalla de texto con un mensaje de login similar a:
   ```
   equipo login:
   ```
2. Ingresá tu nombre de usuario y tu contraseña. Notá que **la contraseña no se muestra mientras la escribís**: es el comportamiento normal.
3. Ejecutá un comando cualquiera para verificar que la sesión funciona:
   ```
   who
   ```
   Observá que aparece tu sesión en una `tty`.
4. Cerrá la sesión de la consola:
   ```
   exit
   ```
5. Volvé al entorno gráfico probando `Ctrl+Alt+F1` o `Ctrl+Alt+F2` (la consola exacta donde corre la sesión gráfica varía según la distribución).

**Preguntas:**

- **2.a** ¿En qué situación real te conviene usar una virtual console en lugar del terminal emulator del escritorio?
- **2.b** ¿Qué muestra el comando `who` y para qué sirve?
- **2.c** ¿Por qué la contraseña no aparece en pantalla al escribirla en la consola?

---

## Ejercicio 3 — Contraseñas seguras

La contraseña es la primera línea de defensa de tu cuenta. En este ejercicio vas a cambiarla y a razonar sobre qué la hace fuerte o débil.

1. Abrí una terminal.
2. Ejecutá el comando para cambiar tu contraseña:
   ```
   passwd
   ```
3. Ingresá tu contraseña actual cuando se solicite.
4. Ingresá una contraseña nueva que cumpla estas condiciones: al menos 12 caracteres, mezcla de mayúsculas, minúsculas, números y símbolos, y que **no** sea una palabra de diccionario ni un dato personal (fecha de nacimiento, nombre de mascota).
5. Probá deliberadamente ingresar una contraseña muy corta (por ejemplo `abc`) y observá el mensaje de rechazo del sistema.
6. Repetí el proceso con la contraseña fuerte y confirmala escribiéndola dos veces.

**Preguntas:**

- **3.a** Mencioná tres características de una contraseña fuerte.
- **3.b** ¿Por qué es una mala práctica reutilizar la misma contraseña en varios servicios?
- **3.c** ¿Qué herramienta de software te ayuda a manejar muchas contraseñas distintas sin memorizarlas todas?

---

## Ejercicio 4 — Privacidad en el navegador web

El navegador guarda **cookies**, historial y archivos en caché que pueden revelar tus hábitos de navegación. Vas a inspeccionar y limpiar esos datos.

1. Abrí **Firefox** (o el navegador instalado en tu sistema).
2. Visitá dos o tres sitios web cualesquiera.
3. Abrí el historial de navegación (en Firefox: menú ☰ → *History*). Verificá que los sitios visitados quedaron registrados.
4. Entrá en la configuración de privacidad (en Firefox: menú ☰ → *Settings* → *Privacy & Security*).
5. Localizá la sección de **cookies and site data** y mirá cuánto espacio ocupan los datos almacenados.
6. Borrá el historial reciente y las cookies (en Firefox: *Clear Data* / *Clear History*).
7. Abrí ahora una ventana de **navegación privada** (`Ctrl+Shift+P` en Firefox), visitá un sitio, cerrá la ventana y verificá en el historial que esa visita **no** quedó registrada.

**Preguntas:**

- **4.a** ¿Qué es una cookie y para qué la usan los sitios web?
- **4.b** El modo de navegación privada, ¿te hace anónimo frente al sitio web que visitás y frente a tu proveedor de internet? Justificá.
- **4.c** ¿Qué diferencia hay entre cookies de origen (*first-party*) y cookies de terceros (*third-party*) en términos de privacidad?

---

## Ejercicio 5 — Bloqueo de pantalla y cifrado

Proteger la sesión y los datos locales también es parte de las buenas prácticas de seguridad.

1. Con tu sesión gráfica abierta, bloqueá la pantalla con el atajo de tu entorno (en GNOME: `Super+L`).
2. Verificá que para volver a entrar el sistema te pide la contraseña.
3. Abrí una terminal y comprobá si tu sistema tiene herramientas de cifrado disponibles:
   ```
   which gpg
   ```
4. Creá un archivo de prueba y cifralo simétricamente con **GnuPG**:
   ```
   echo "dato confidencial" > secreto.txt
   gpg -c secreto.txt
   ```
   Ingresá una frase de paso (*passphrase*) cuando se solicite.
5. Listá los archivos y verificá que se creó `secreto.txt.gpg`:
   ```
   ls -l secreto*
   ```
6. Borrá el original y descifrá la copia protegida para recuperar el contenido:
   ```
   rm secreto.txt
   gpg -d secreto.txt.gpg
   ```
7. Limpiá los archivos de prueba:
   ```
   rm secreto.txt.gpg
   ```

**Preguntas:**

- **5.a** ¿Por qué es importante bloquear la pantalla aunque te alejes del equipo "solo un minuto"?
- **5.b** ¿Qué diferencia conceptual hay entre cifrar un archivo y protegerlo solo con permisos de usuario?
- **5.c** Además del cifrado de archivos, ¿qué otra forma de cifrado protege los datos si te roban la notebook apagada?

---

## Ejercicio 6 — Aplicaciones open source para el trabajo diario

Linux ofrece aplicaciones de código abierto equivalentes a las herramientas propietarias más usadas. Vas a identificarlas y usar una de ellas.

1. Abrí el lanzador de aplicaciones y anotá qué programas tenés instalados para cada tarea:
   - Navegación web
   - Documentos de texto
   - Hojas de cálculo
   - Presentaciones
   - Edición de imágenes
2. Abrí **LibreOffice Impress** (o instalalo desde el gestor de software de tu distribución si no está).
3. Creá una presentación nueva con una sola diapositiva titulada *"Linux en la industria"*.
4. Agregá una lista con tres ámbitos donde Linux domina: **servidores y cloud computing**, **supercomputadoras** y **dispositivos embebidos / Android**.
5. Guardá el archivo en el formato nativo (`.odp`) y después exportalo también como **PDF** (*File → Export As → Export as PDF*).
6. Verificá desde la terminal que ambos archivos existen:
   ```
   ls -l ~/*.odp ~/*.pdf
   ```

**Preguntas:**

- **6.a** Completá la tabla de equivalencias:

  | Tarea | Aplicación propietaria común | Alternativa open source |
  |---|---|---|
  | Hoja de cálculo | Microsoft Excel | ? |
  | Edición de imágenes | Adobe Photoshop | ? |
  | Presentaciones | Microsoft PowerPoint | ? |

- **6.b** ¿Qué formato de archivo usa nativamente LibreOffice y qué ventaja tiene que sea un estándar abierto?
- **6.c** ¿Por qué conviene exportar a PDF una presentación que vas a compartir con personas que usan otros sistemas operativos?

---

## Ejercicio 7 — Linux en la nube y la virtualización (exploración conceptual)

Este ejercicio es de investigación guiada: no requiere instalar nada.

1. Desde la terminal, verificá si tu sistema está corriendo en una máquina virtual:
   ```
   systemd-detect-virt
   ```
   Si devuelve `none`, estás en hardware físico; si devuelve `kvm`, `oracle`, `vmware`, etc., estás en una VM.
2. Investigá en la web (5–10 minutos) qué sistema operativo usan mayoritariamente los servidores de los grandes proveedores de nube (AWS, Google Cloud, Azure).
3. Buscá qué kernel usa el sistema operativo **Android**.
4. Anotá en un archivo de texto tres ejemplos de dispositivos o servicios que usás a diario y que corren Linux sin que sea evidente:
   ```
   nano linux-oculto.txt
   ```
   (guardá con `Ctrl+O`, salí con `Ctrl+X`).

**Preguntas:**

- **7.a** ¿Qué es una máquina virtual y qué ventaja ofrece frente a instalar cada sistema en hardware dedicado?
- **7.b** ¿Qué relación hay entre Linux y el *cloud computing*?
- **7.c** Nombrá tres tipos de dispositivos embebidos donde es habitual encontrar Linux.

---

<details>
<summary><strong>✅ Respuestas</strong></summary>

### Ejercicio 1

- **1.a** El *terminal emulator* es la aplicación gráfica que muestra la ventana donde escribís (GNOME Terminal, Konsole…). La *shell* es el programa que corre dentro de esa ventana, interpreta los comandos que escribís y devuelve los resultados (por ejemplo Bash). La terminal es la "ventana"; la shell es el "intérprete".
- **1.b** El `$` indica que la sesión pertenece a un usuario común (sin privilegios). El `#` indica que la sesión pertenece al usuario **root** (administrador), por lo que hay que operar con más cuidado.
- **1.c** **Bash** (Bourne Again Shell) es la shell por defecto en la mayoría de las distribuciones.

### Ejercicio 2

- **2.a** Cuando el entorno gráfico se congela o no arranca, o cuando administrás un servidor sin interfaz gráfica. Las virtual consoles funcionan de forma independiente de la sesión gráfica.
- **2.b** `who` muestra los usuarios con sesión abierta en el sistema, indicando la terminal (`tty`) desde la que se conectaron y la hora de inicio. Sirve para auditar quién está usando el equipo.
- **2.c** Es una medida de seguridad: evita que alguien que mire la pantalla (*shoulder surfing*) vea la contraseña o incluso su longitud.

### Ejercicio 3

- **3.a** Longitud suficiente (12+ caracteres), combinación de tipos de caracteres (mayúsculas, minúsculas, números, símbolos), y que no sea predecible: nada de palabras de diccionario, datos personales ni patrones de teclado. Además, debe ser única para cada servicio.
- **3.b** Si un servicio sufre una filtración, los atacantes prueban esa misma combinación de usuario/contraseña en otros servicios (*credential stuffing*). Una sola filtración comprometería todas tus cuentas.
- **3.c** Un **password manager** (gestor de contraseñas), como KeePassXC o Bitwarden: genera y almacena contraseñas únicas y fuertes, y vos solo memorizás una contraseña maestra.

### Ejercicio 4

- **4.a** Una cookie es un pequeño dato que el sitio web guarda en tu navegador. Se usa legítimamente para mantener sesiones iniciadas y preferencias, pero también para rastrear tu actividad con fines publicitarios.
- **4.b** No. El modo privado solo evita que el navegador guarde localmente historial, cookies y datos de formularios. El sitio web sigue viendo tu dirección IP y tu proveedor de internet sigue viendo qué sitios visitás.
- **4.c** Las *first-party cookies* las crea el sitio que estás visitando y suelen ser funcionales. Las *third-party cookies* las crean otros dominios embebidos en la página (redes publicitarias, botones sociales) y permiten rastrear tu navegación a través de múltiples sitios, por eso son las más problemáticas para la privacidad.

### Ejercicio 5

- **5.a** Porque cualquiera con acceso físico momentáneo puede leer tus datos, enviar mensajes en tu nombre o instalar software malicioso. El bloqueo de pantalla exige la contraseña para retomar la sesión.
- **5.b** Los permisos de usuario los hace cumplir el sistema operativo: si alguien extrae el disco y lo lee desde otro sistema (o arranca con un live USB), los permisos no lo detienen. El cifrado protege el contenido matemáticamente: sin la clave o passphrase, los datos son ilegibles aunque se acceda al disco directamente.
- **5.c** El **cifrado de disco completo** (*full disk encryption*, por ejemplo con LUKS), que suele configurarse durante la instalación de la distribución. Sin la passphrase, el contenido del disco es inaccesible.

### Ejercicio 6

- **6.a**

  | Tarea | Aplicación propietaria común | Alternativa open source |
  |---|---|---|
  | Hoja de cálculo | Microsoft Excel | **LibreOffice Calc** |
  | Edición de imágenes | Adobe Photoshop | **GIMP** |
  | Presentaciones | Microsoft PowerPoint | **LibreOffice Impress** |

- **6.b** El formato **OpenDocument Format (ODF)**: `.odt` para textos, `.ods` para hojas de cálculo, `.odp` para presentaciones. Al ser un estándar abierto, cualquier software puede implementarlo, lo que garantiza que tus documentos sigan siendo legibles en el futuro sin depender de un único proveedor.
- **6.c** El PDF conserva el diseño exacto (tipografías, disposición) en cualquier sistema operativo y se puede abrir con visores gratuitos en todas las plataformas, sin requerir que el destinatario tenga LibreOffice ni PowerPoint instalados.

### Ejercicio 7

- **7.a** Una máquina virtual es un equipo simulado por software que corre dentro de un equipo físico, con su propio sistema operativo. Ventajas: varios sistemas conviven en un mismo hardware, se aprovechan mejor los recursos, y las VMs se crean, clonan y destruyen en minutos.
- **7.b** Linux es el sistema operativo dominante en el cloud computing: la mayoría de las instancias de servidores en AWS, Google Cloud y Azure corren Linux, y gran parte de la infraestructura de virtualización y contenedores de la nube (KVM, Docker, Kubernetes) está construida sobre Linux.
- **7.c** Routers y equipos de red, smart TVs, y teléfonos con **Android** (cuyo kernel es Linux). También son válidos: sistemas de entretenimiento de autos, cámaras, dispositivos IoT, e-readers.

</details>

---

*Material original elaborado con base en los objetivos del examen. Referencia consultada: [https://learning.lpi.org/en/learning-materials/010-160/1/1.4/](https://learning.lpi.org/en/learning-materials/010-160/1/1.4/)*