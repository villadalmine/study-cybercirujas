# Ejercicios Pr\u00e1cticos: 2.2 Interfaces and Desktops

Estos ejercicios simulan escenarios comunes en integraci\u00f3n continua (CI) o diagn\u00f3stico remoto, donde los SREs interact\u00faan con componentes del sistema gr\u00e1fico de Linux sin utilizar un entorno de escritorio completo.

## Ejercicio 1: Diagn\u00f3stico de X11 Forwarding por SSH

Un desarrollador te pide ayuda porque no puede ejecutar una herramienta de profiling de memoria (como Eclipse MAT o JConsole) hospedada en un servidor remoto mediante SSH.

### Pasos

1. Imagina que vas a conectarte por SSH a un servidor remoto, habilitando el *forwarding* gr\u00e1fico seguro. El comando que ejecutar\u00edas (no lo ejecutes si no tienes un servidor a mano) es:
   ```bash
   ssh -X usuario@servidor.remoto
   ```
2. Una vez "conectado", el primer paso de *troubleshooting* es validar si el demonio SSH remoto prepar\u00f3 el entorno gr\u00e1fico correctamente asignando un Display temporal. Verifica la variable:
   ```bash
   echo $DISPLAY
   ```
3. Si la variable est\u00e1 vac\u00eda, el servidor rechaz\u00f3 el *forwarding*. Deber\u00edas revisar la configuraci\u00f3n del daemon de SSH. Comando para verificarlo:
   ```bash
   sudo grep X11Forwarding /etc/ssh/sshd_config
   ```

### Verificaci\u00f3n de Comprensi\u00f3n

**Pregunta 1.1:** Si ejecutas `echo $DISPLAY` en el servidor remoto tras conectarte con `ssh -X` y obtienes como salida `localhost:10.0`, \u00bfqu\u00e9 significa ese "10.0"? \u00bfSignifica que la aplicaci\u00f3n se dibujar\u00e1 en la pantalla del servidor f\u00edsico (monitor conectado al servidor)?

---

## Ejercicio 2: Ejecuci\u00f3n de Testing Headless con Xvfb

Tu pipeline de GitHub Actions falla porque los tests End-to-End intentan lanzar Firefox, pero el contenedor Ubuntu no tiene monitor f\u00edsico. Vas a usar un Framebuffer Virtual (`Xvfb`).

### Pasos

1. Aseg\u00farate de tener instalado `xvfb` en tu entorno (en un sistema Debian/Ubuntu):
   ```bash
   sudo apt-get update && sudo apt-get install -y xvfb x11-apps
   ```
2. Si ejecutaras el comando `xclock` sin un display v\u00e1lido, fallar\u00eda con `Error: Can't open display:`. Utiliza el *wrapper* oficial de Xvfb para ejecutarlo confinado a un servidor X virtual en segundo plano (el test correr\u00e1 y se cerrar\u00e1 de inmediato para no colgar tu terminal, aunque `xclock` en la vida real se queda abierto):
   ```bash
   xvfb-run -a xclock
   ```
   *(Nota: Puedes presionar Ctrl+C si el comando no retorna de inmediato).*
3. Explora la ayuda del wrapper para entender c\u00f3mo los runners de CI especifican resoluciones (\u00fatil para tests responsivos):
   ```bash
   xvfb-run --help | grep -i screen
   ```

### Verificaci\u00f3n de Comprensi\u00f3n

**Pregunta 2.1:** \u00bfPor qu\u00e9 la herramienta `xvfb-run` es preferida en los scripts de CI/CD por encima de levantar manualmente el proceso `Xvfb &` (en background) antes de lanzar los tests?

---

## Ejercicio 3: Control de Acceso Local a X11 (Troubleshooting de xauth/xhost)

Ocasionalmente, puedes necesitar ejecutar una aplicaci\u00f3n gr\u00e1fica como un usuario distinto (usando `sudo` o `su`), y ver\u00e1s que la aplicaci\u00f3n falla con "Authorization required".

### Pasos

1. Trata de listar los permisos actuales de tu servidor X usando `xhost`:
   ```bash
   xhost
   ```
2. Lista las *cookies* m\u00e1gicas criptogr\u00e1ficas generadas por `xauth`, las cuales son la base de seguridad moderna en vez del obsoleto `xhost`:
   ```bash
   xauth list
   ```
3. *(Mental)* Si recibieras el error "No protocol specified, Can't open display", una forma **totalmente insegura** pero r\u00e1pida de descartar problemas de red/display temporalmente (solo en un entorno aislado de dev local, NUNCA en producci\u00f3n) ser\u00eda deshabilitar el control de acceso:
   ```bash
   xhost +
   ```

### Verificaci\u00f3n de Comprensi\u00f3n

**Pregunta 3.1:** \u00bfCu\u00e1l es la diferencia fundamental en el modelo de seguridad entre utilizar el comando `xhost` versus usar el comando `xauth`?

---

<details>
<summary><b>Respuestas a la Verificaci\u00f3n de Comprensi\u00f3n</b></summary>

**Respuesta 1.1:** No, la aplicaci\u00f3n NO se dibujar\u00e1 en la pantalla del servidor remoto. El servidor SSH intercepta la solicitud y crea un Display "falso" o *proxy* local en el servidor (t\u00edpicamente empezando desde el display n\u00famero `10`). Cuando la aplicaci\u00f3n intenta dibujar en el display 10, SSH captura esas primitivas gr\u00e1ficas, las cifra, las env\u00eda por el t\u00fanel de red a tu m\u00e1quina local (cliente), y se las pasa a tu servidor X o Wayland local para que se dibujen en tu propio monitor.

**Respuesta 2.1:** `xvfb-run` es un *wrapper* (envoltorio) en Bash que se encarga del ciclo de vida completo del Display Virtual. No solo arranca `Xvfb` de fondo, sino que asigna un n\u00famero de display que est\u00e9 libre autom\u00e1ticamente (con el flag `-a`), ejecuta el comando que le pases y, crucialmente, destruye el proceso `Xvfb` limpiamente (cleanup) cuando el test termina, liberando la memoria. Levantar `Xvfb &` manualmente suele dejar procesos zombies y puertos bloqueados si el pipeline falla a la mitad.

**Respuesta 3.1:** El comando `xhost` autoriza la conexi\u00f3n al Display bas\u00e1ndose en direcciones IP de *hosts* de red enteros (ej. permitir que cualquiera desde la IP 192.168.1.100 dibuje en mi pantalla). Esto es altamente inseguro porque cualquier usuario de esa m\u00e1quina remota puede interactuar con el Display. En contraste, `xauth` se basa en credenciales (cookies criptogr\u00e1ficas). Solo el usuario o proceso que pueda leer la cookie espec\u00edfica (guardada en el archivo `~/.Xauthority`) podr\u00e1 conectarse, proporcionando aislamiento incluso si m\u00faltiples usuarios comparten la misma m\u00e1quina local o remota.

</details>