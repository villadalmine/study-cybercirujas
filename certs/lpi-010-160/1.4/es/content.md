# 1.4 ICT Skills and Working in Linux

**Peso en el examen: 2** — Este tema evalúa habilidades prácticas de trabajo cotidiano en Linux: uso del escritorio, acceso a la línea de comandos, navegación web segura, gestión de contraseñas, privacidad, y el rol de Linux en la industria (cloud computing y virtualización).

---

## 1. Habilidades de escritorio (Desktop Skills)

Linux ofrece múltiples **desktop environments** (entornos de escritorio). A diferencia de Windows o macOS, donde la interfaz gráfica es única y fija, en Linux podés elegir e incluso cambiar de entorno sin reinstalar el sistema.

Los más comunes:

| Entorno | Características | Distribuciones que lo usan por defecto |
|---|---|---|
| **GNOME** | Moderno, minimalista, orientado a productividad | Ubuntu, Fedora, Debian |
| **KDE Plasma** | Altamente configurable, aspecto similar a Windows | Kubuntu, openSUSE |
| **Xfce** | Liviano, ideal para hardware antiguo | Xubuntu, MX Linux |
| **LXDE / LXQt** | Muy liviano, mínimo consumo de recursos | Lubuntu |
| **Cinnamon** | Tradicional, amigable para principiantes | Linux Mint |

Conceptos clave:

- Todos los entornos comparten elementos comunes: un **panel** o barra de tareas, un **application launcher** (lanzador de aplicaciones), un **file manager** (gestor de archivos como Nautilus, Dolphin o Thunar) y áreas de notificación.
- El sistema gráfico subyacente es el **X Window System (X11)** o, más recientemente, **Wayland**. El entorno de escritorio se ejecuta "encima" de este sistema.
- El **display manager** (como GDM, SDDM o LightDM) es la pantalla de inicio de sesión gráfica; allí generalmente podés elegir qué entorno de escritorio usar antes de iniciar sesión.

---

## 2. Acceso a la línea de comandos (Getting to the Command Line)

Aunque el escritorio gráfico es cómodo, la **command line** es la herramienta más poderosa y universal en Linux. Hay varias formas de acceder a ella:

### 2.1 Terminal emulator (emulador de terminal)

Es una aplicación gráfica que ejecuta una **shell** dentro del escritorio. Ejemplos: `gnome-terminal`, `konsole`, `xterm`, `xfce4-terminal`.

Se abre desde el menú de aplicaciones (generalmente bajo "Terminal") o con el atajo `Ctrl+Alt+T` en muchas distribuciones.

Al abrirla, ves el **prompt**:

```
user@localhost:~$
```

- `user`: nombre del usuario actual
- `localhost`: nombre del equipo (hostname)
- `~`: directorio actual (la tilde representa el home del usuario)
- `$`: indica usuario regular (un `#` indica usuario **root**)

### 2.2 Virtual consoles (consolas virtuales)

Linux provee varias consolas de texto puro, independientes del entorno gráfico. Se accede con:

```
Ctrl + Alt + F1 … F6
```

Cada combinación abre una consola distinta (TTY1 a TTY6). En la mayoría de las distribuciones modernas, la sesión gráfica corre en TTY1 o TTY7, y con `Ctrl+Alt+F2` accedés a una consola de texto donde podés iniciar sesión de forma independiente. Esto es muy útil cuando el entorno gráfico falla.

Podés verificar en qué terminal estás con:

```
$ tty
/dev/pts/0
```

Una salida `/dev/pts/N` indica un emulador de terminal (pseudo-terminal); `/dev/tty2` indicaría una consola virtual.

### 2.3 Acceso remoto con SSH

**SSH (Secure Shell)** permite abrir una sesión de línea de comandos en una máquina remota, con todo el tráfico cifrado:

```
$ ssh usuario@servidor.ejemplo.com
usuario@servidor.ejemplo.com's password:
Last login: Mon Jul  6 10:23:41 2026 from 192.168.1.50
usuario@servidor:~$
```

SSH reemplazó a herramientas antiguas e inseguras como `telnet` y `rsh`, que transmitían las contraseñas en texto plano. Es la forma estándar de administrar servidores Linux, que en su mayoría no tienen entorno gráfico instalado.

---

## 3. Linux en la industria, cloud computing y virtualización

### 3.1 Usos de Linux en la industria

Linux domina muchos sectores de IT:

- **Servidores web**: la mayoría de los sitios de Internet corren sobre Linux (con servidores como Apache o NGINX).
- **Supercomputadoras**: el 100% del TOP500 de supercomputadoras usa Linux.
- **Dispositivos móviles y embebidos**: Android está basado en el kernel Linux; también routers, smart TVs y sistemas IoT.
- **Cloud computing**: la enorme mayoría de las instancias en la nube (AWS, Google Cloud, Azure) son Linux.
- **DevOps y contenedores**: tecnologías como Docker y Kubernetes nacieron sobre Linux.

### 3.2 Virtualización

La **virtualization** permite ejecutar múltiples sistemas operativos ("guests" o máquinas virtuales) sobre un mismo hardware físico ("host"), administrados por un **hypervisor**.

Conceptos clave:

- **Virtual machine (VM)**: una computadora simulada por software, con su propio sistema operativo, CPU virtual, memoria y disco.
- **Hypervisors** comunes en Linux: **KVM** (Kernel-based Virtual Machine, integrado al kernel), **VirtualBox**, **Xen**, **VMware**.
- Ventajas: mejor aprovechamiento del hardware, aislamiento entre sistemas, facilidad para crear/destruir entornos de prueba, snapshots.

### 3.3 Cloud computing

El **cloud computing** ofrece recursos de cómputo (servidores, almacenamiento, redes) como servicio, bajo demanda y pagando por uso. Se apoya fuertemente en virtualización y en Linux. Modelos principales:

- **IaaS (Infrastructure as a Service)**: alquilás máquinas virtuales y redes (ej.: Amazon EC2). Vos administrás el sistema operativo.
- **PaaS (Platform as a Service)**: la plataforma de ejecución ya está lista; solo desplegás tu aplicación (ej.: Heroku, Google App Engine).
- **SaaS (Software as a Service)**: usás la aplicación final directamente desde el navegador (ej.: Gmail, Nextcloud alojado).

Relacionado con la nube, los **containers** (contenedores, como Docker) son una forma de virtualización liviana: en lugar de virtualizar hardware completo, comparten el kernel del host y aíslan solo los procesos y sus dependencias.

---

## 4. Navegación web: privacidad y configuración

El navegador es la aplicación más usada del escritorio y también un punto crítico de privacidad. **Mozilla Firefox** es el navegador open source de referencia en Linux; también existen Chromium, Brave y otros.

### 4.1 Cookies y rastreo

- Las **cookies** son pequeños archivos que los sitios guardan en el navegador para recordar sesiones y preferencias.
- Las **third-party cookies** (cookies de terceros) provienen de dominios distintos al sitio visitado (por ejemplo, redes publicitarias) y permiten rastrear tu navegación entre múltiples sitios. Los navegadores modernos permiten bloquearlas en su configuración de privacidad.
- El **tracking** (rastreo) también se realiza mediante fingerprinting y scripts de terceros; Firefox incluye **Enhanced Tracking Protection** para mitigarlo.

### 4.2 Private browsing (navegación privada)

El modo **private browsing** (o "incognito") hace que el navegador no guarde historial, cookies ni datos de formularios al cerrar la ventana. Importante: **no te hace anónimo en Internet** — tu proveedor de Internet, tu empleador y los sitios que visitás siguen pudiendo ver tu actividad. Solo evita dejar rastros locales en la máquina.

### 4.3 TLS y HTTPS

- **TLS (Transport Layer Security)** es el protocolo que cifra la comunicación entre el navegador y el servidor. Es el sucesor de **SSL**.
- Cuando la URL comienza con `https://` y aparece el candado en la barra de direcciones, la conexión está cifrada con TLS.
- Nunca ingreses contraseñas o datos sensibles en sitios que usen `http://` sin cifrar.

### 4.4 Guardar contenido y buscar en la web

- Los navegadores permiten guardar páginas completas (`Ctrl+S`), imprimir a PDF y administrar **bookmarks** (marcadores).
- Los **search engines** (motores de búsqueda) como DuckDuckGo o Startpage son alternativas orientadas a privacidad frente a Google, ya que no perfilan al usuario.

---

## 5. Contraseñas y autenticación

### 5.1 Buenas prácticas con contraseñas

- Usar contraseñas **largas** (la longitud importa más que la complejidad artificial): una frase de varias palabras es mejor que `P4ssw0rd!`.
- **Nunca reutilizar** la misma contraseña en distintos servicios: si un sitio es comprometido, esa contraseña se prueba automáticamente en otros (credential stuffing).
- No compartir contraseñas ni anotarlas en lugares visibles.
- Cambiar la contraseña inmediatamente si se sospecha un compromiso.

En Linux, tu contraseña local se cambia con:

```
$ passwd
Changing password for user.
Current password:
New password:
Retype new password:
passwd: all authentication tokens updated successfully.
```

Las contraseñas no se guardan en texto plano: se almacenan como **hashes** en el archivo `/etc/shadow`, legible solo por root.

### 5.2 Password managers

Un **password manager** (gestor de contraseñas) genera y almacena contraseñas únicas y fuertes para cada servicio, cifradas bajo una única **master password**. Opciones open source populares:

- **KeePassXC**: local, almacena la base de datos cifrada en un archivo.
- **Bitwarden**: sincronizado en la nube, con opción de self-hosting.

### 5.3 Two-factor authentication (2FA)

La **two-factor authentication** agrega un segundo factor además de la contraseña: algo que *tenés* (un token TOTP en el teléfono, una llave física como YubiKey) o algo que *sos* (biometría). Aun si roban tu contraseña, no pueden acceder sin el segundo factor. Siempre que un servicio lo ofrezca, conviene activarlo.

---

## 6. Cifrado y protección de datos

- **Encryption in transit** (cifrado en tránsito): protege los datos mientras viajan por la red — TLS/HTTPS para la web, SSH para administración remota, VPNs para túneles completos.
- **Encryption at rest** (cifrado en reposo): protege los datos almacenados. En Linux es común el **full disk encryption** con **LUKS** (Linux Unified Key Setup), configurable durante la instalación de la mayoría de las distribuciones. Si te roban la laptop, los datos son ilegibles sin la passphrase.
- **Cifrado de archivos y correo**: **GnuPG (GPG)** permite cifrar y firmar archivos y correos electrónicos con criptografía de clave pública.

Ejemplo simple de cifrado simétrico de un archivo con GPG:

```
$ gpg -c documento.txt
Enter passphrase: ********
$ ls documento*
documento.txt  documento.txt.gpg
```

---

## 7. Aplicaciones open source para el trabajo diario

Para presentaciones, proyectos y colaboración, el ecosistema open source ofrece equivalentes completos a las suites propietarias:

| Necesidad | Aplicación open source | Equivalente propietario |
|---|---|---|
| Procesador de texto | LibreOffice Writer | Microsoft Word |
| Hoja de cálculo | LibreOffice Calc | Microsoft Excel |
| Presentaciones | LibreOffice Impress | Microsoft PowerPoint |
| Edición de imágenes | GIMP | Adobe Photoshop |
| Gráficos vectoriales | Inkscape | Adobe Illustrator |
| Navegador | Firefox | Edge / Safari |
| Correo | Thunderbird | Outlook |
| Colaboración en la nube | Nextcloud | Google Drive / OneDrive |

Consejos prácticos para el examen y el trabajo real:

- LibreOffice puede abrir y guardar formatos de Microsoft Office (`.docx`, `.xlsx`, `.pptx`), aunque su formato nativo es **ODF (Open Document Format)**: `.odt`, `.ods`, `.odp`.
- Para distribuir documentos finales, exportá a **PDF**, que se ve igual en cualquier sistema.

---

## Resumen de puntos clave para el examen

- Conocer los principales **desktop environments** (GNOME, KDE, Xfce) y que son intercambiables.
- Tres vías a la línea de comandos: **terminal emulator**, **virtual consoles** (`Ctrl+Alt+F1-F6`) y **SSH** para acceso remoto seguro.
- Linux domina servidores, supercomputadoras, Android y la nube; entender **IaaS/PaaS/SaaS**, **virtual machines**, **hypervisors** (KVM) y **containers**.
- Privacidad en el navegador: **cookies** (especialmente de terceros), **private browsing** (no es anonimato), **TLS/HTTPS**.
- Contraseñas: largas, únicas por servicio, gestionadas con un **password manager**, reforzadas con **2FA**.
- Cifrado: **TLS** en tránsito, **LUKS** para disco, **GPG** para archivos y correo.
- Aplicaciones open source equivalentes: LibreOffice, GIMP, Firefox, Thunderbird, Nextcloud.

---

## Referencias

- LPI Learning Materials — Topic 1.4: ICT Skills and Working in Linux: https://learning.lpi.org/en/learning-materials/010-160/1.4/
- Objetivos oficiales del examen Linux Essentials 010-160: https://www.lpi.org/our-certifications/exam-010-objectives/
- Documentación de Mozilla Firefox (privacidad y seguridad): https://support.mozilla.org/en-US/products/firefox/privacy-and-security
- Manual de OpenSSH: https://www.openssh.com/manual.html
- Documentación de KVM: https://linux-kvm.org/page/Documents
- Documentación de LibreOffice: https://documentation.libreoffice.org/en/english-documentation/
- GnuPG (GPG): https://gnupg.org/documentation/
- KeePassXC: https://keepassxc.org/docs/