# CKS 5.1 — Minimize host OS footprint (reduce attack surface)

**Dominio:** System Hardening — **Peso en el examen:** 2.5%

Referencia: [CKS Curriculum v1.34](https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf)

Reducir el "footprint" del host OS significa achicar la superficie de ataque de los nodos: menos paquetes instalados, menos servicios corriendo, menos puertos escuchando, menos módulos de kernel cargados y menos binarios con privilegios especiales. Cada componente instalado es una vulnerabilidad potencial; en el examen CKS se evalúa que sepas auditar un nodo Linux y aplicar estas reducciones con comandos estándar.

Los ejercicios siguientes asumen acceso SSH (o consola) a un nodo Linux que actúa como worker o control-plane de un cluster (por ejemplo, un nodo de kubeadm en Ubuntu/Debian).

---

## Ejercicio 1: Auditar y detener servicios innecesarios

1. Listá todos los servicios `systemd` activos en el nodo:

```bash
systemctl list-units --type=service --state=running
```

2. Identificá servicios que no son necesarios para que el nodo funcione como parte del cluster (por ejemplo `cups`, `avahi-daemon`, `bluetooth`, `ModemManager`).

3. Detené y deshabilitá uno de esos servicios (ejemplo con `avahi-daemon`):

```bash
sudo systemctl stop avahi-daemon
sudo systemctl disable avahi-daemon
sudo systemctl mask avahi-daemon
```

4. Confirmá que el servicio ya no va a arrancar en el próximo boot:

```bash
systemctl is-enabled avahi-daemon
```

**Preguntas de comprensión:**

1. ¿Por qué `mask` es más estricto que `disable` para un servicio que querés eliminar definitivamente del footprint de ataque?
2. Si un servicio expone un puerto de red innecesario, ¿alcanza con hacer `disable` sin reiniciar el nodo?

---

## Ejercicio 2: Auditar puertos en escucha

1. Listá todos los sockets TCP/UDP en estado LISTEN, junto con el proceso que los abrió:

```bash
sudo ss -tulpn
```

2. Para cada puerto abierto que no corresponda a un componente esperado del cluster (`kubelet`, `kube-apiserver`, `etcd`, `containerd`, etc.), identificá el proceso dueño con `ss` o `lsof -i :<puerto>`.

3. Si el puerto pertenece a un servicio que no necesitás (por ejemplo `rpcbind` en 111/tcp), aplicá el Ejercicio 1 para detenerlo, o bloqueá el puerto a nivel de firewall si no podés eliminar el servicio:

```bash
sudo iptables -A INPUT -p tcp --dport 111 -j DROP
```

4. Volvé a correr `ss -tulpn` y verificá que el puerto ya no aparece en LISTEN (o que el tráfico entrante se descarta).

**Preguntas de comprensión:**

1. ¿Cuál es la diferencia entre "cerrar" un puerto deteniendo el servicio y "bloquearlo" con reglas de firewall? ¿Cuál reduce más la superficie de ataque?
2. ¿Por qué preferir `ss` sobre el viejo `netstat` en un nodo moderno?

---

## Ejercicio 3: Deshabilitar módulos de kernel innecesarios

1. Listá los módulos de kernel actualmente cargados:

```bash
lsmod
```

2. Elegí un módulo que no es necesario para el funcionamiento del cluster ni del hardware presente (por ejemplo, un filesystem legacy como `cramfs` o un protocolo poco usado como `dccp`).

3. Descargalo si no está en uso:

```bash
sudo modprobe -r cramfs
```

4. Evitá que se vuelva a cargar agregando una blacklist persistente:

```bash
echo "install cramfs /bin/true" | sudo tee /etc/modprobe.d/cramfs-blacklist.conf
```

5. Reiniciá el nodo (o simulá con `modprobe cramfs` y verificá que falla) y confirmá que el módulo sigue sin cargarse.

**Preguntas de comprensión:**

1. ¿Por qué `echo "install cramfs /bin/true"` es más confiable que `blacklist cramfs` para evitar que el módulo se cargue automáticamente por una dependencia?
2. ¿Qué riesgo concreto reduce deshabilitar módulos de filesystems poco comunes en un nodo de Kubernetes?

---

## Ejercicio 4: Minimizar paquetes instalados

1. Listá cuántos paquetes están instalados en el nodo (Debian/Ubuntu):

```bash
dpkg -l | wc -l
```

2. Identificá paquetes que no son dependencias del container runtime, del kubelet ni de herramientas de administración imprescindibles (por ejemplo compiladores, clientes de mail, servidores X11).

3. Remové un paquete innecesario junto con su configuración:

```bash
sudo apt-get purge -y postfix
sudo apt-get autoremove -y
```

4. Verificá que no quedaron archivos de configuración huérfanos:

```bash
dpkg -l | grep '^rc'
```

**Preguntas de comprensión:**

1. ¿Por qué `purge` en vez de `remove` importa para el objetivo de "reduce attack surface"?
2. ¿Qué relación tiene minimizar paquetes instalados con usar imágenes base mínimas (distroless/Alpine) en contenedores?

---

## Ejercicio 5: Hardening del acceso remoto (SSH)

1. Abrí la configuración de SSH del nodo:

```bash
sudo vi /etc/ssh/sshd_config
```

2. Aplicá los siguientes cambios para reducir la superficie de ataque del acceso remoto:

```
PermitRootLogin no
PasswordAuthentication no
X11Forwarding no
```

3. Recargá el servicio SSH:

```bash
sudo systemctl reload sshd
```

4. Desde otra sesión (sin cerrar la actual), verificá que un login como `root` es rechazado y que la autenticación por password ya no funciona.

**Preguntas de comprensión:**

1. ¿Por qué es importante verificar el cambio desde una sesión nueva antes de cerrar la sesión actual?
2. Si el nodo se administra únicamente vía claves SSH, ¿qué gana la organización deshabilitando `PasswordAuthentication`?

---

## Ejercicio 6: Auditar binarios con SUID/SGID

1. Buscá en el filesystem todos los binarios con el bit SUID o SGID activado:

```bash
sudo find / -xdev -type f \( -perm -4000 -o -perm -2000 \) -exec ls -la {} \;
```

2. Comparé la lista contra los binarios estrictamente necesarios (por ejemplo `passwd`, `sudo`, `ping`). Identificá al menos uno que podría quitarse (por ejemplo `chsh` o `wall` si no se usan).

3. Quitá el bit SUID de un binario que no lo necesita:

```bash
sudo chmod u-s /usr/bin/wall
```

4. Confirmá el cambio:

```bash
ls -la /usr/bin/wall
```

**Preguntas de comprensión:**

1. ¿Por qué un binario con SUID root es un objetivo atractivo para escalar privilegios si un atacante ya tiene acceso como usuario no privilegiado?
2. ¿Qué precaución hay que tomar antes de quitar el bit SUID de un binario en un nodo de producción?

---

<details>
<summary>Respuestas</summary>

**Ejercicio 1**
1. `mask` crea un symlink a `/dev/null` para la unit, lo que impide que se inicie incluso si otro paquete o unit lo requiere como dependencia; `disable` solo quita el enlace desde los targets de arranque, pero el servicio podría ser reactivado indirectamente (por ejemplo con `systemctl start` manual o como dependencia de otro servicio).
2. No. El servicio sigue corriendo y el puerto sigue abierto hasta que se hace `stop` (o se reinicia el nodo). `disable` solo afecta el arranque futuro.

**Ejercicio 2**
1. Detener el servicio elimina el proceso y libera el puerto (nadie escucha ahí); bloquear con firewall deja el proceso corriendo y escuchando, solo descarta los paquetes entrantes a nivel de red. Detener el servicio reduce más la superficie de ataque porque elimina el código en ejecución, no solo el acceso de red.
2. `ss` lee directamente las estructuras del kernel (netlink) en vez de parsear `/proc/net`, es más rápido y sigue mantenido activamente; `netstat` está deprecado en la mayoría de las distros modernas.

**Ejercicio 3**
1. Con `blacklist`, el módulo puede seguir cargándose si otro módulo lo requiere como dependencia o si se carga explícitamente con `modprobe <módulo>`. Redirigir el comando `install` a `/bin/true` intercepta cualquier intento de carga, incluso por dependencia.
2. Reduce la cantidad de código de kernel expuesto a un atacante que ya tiene acceso a un contenedor y podría intentar explotar una vulnerabilidad en un filesystem driver poco auditado (algunos ataques de escape de contenedor explotan justamente parsers de filesystems poco comunes).

**Ejercicio 4**
1. `remove` deja los archivos de configuración en `/etc`; `purge` los borra también. Archivos de configuración residuales pueden contener credenciales, quedar mal protegidos, o ser reactivados si el paquete se reinstala sin que el admin lo note.
2. Ambas prácticas siguen el mismo principio: cuanto menos software instalado, menos código con vulnerabilidades potenciales y menos superficie para un atacante que logra ejecución dentro del host o del contenedor.

**Ejercicio 5**
1. Si el cambio tiene un error de configuración (por ejemplo un typo) y cerrás la sesión actual antes de confirmar, podés quedar sin ninguna forma de volver a entrar por SSH al nodo.
2. Elimina por completo el vector de ataque de fuerza bruta o diccionario contra contraseñas SSH, ya que solo se acepta autenticación por clave pública.

**Ejercicio 6**
1. Un binario SUID root ejecuta con privilegios de root sin importar qué usuario lo invoque; si tiene una vulnerabilidad (o permite escapar a un shell, como en algunas versiones viejas de utilidades), un usuario sin privilegios puede usarlo para obtener una shell root.
2. Verificar que ningún proceso del sistema ni script de administración depende de ese bit para funcionar correctamente (por ejemplo, `wall` lo usa para escribir en los terminales de otros usuarios); quitarlo sin verificar puede romper funcionalidad legítima.

</details>