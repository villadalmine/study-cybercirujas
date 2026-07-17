# 5.1 Minimize host OS footprint (reduce attack surface)

## Por qué importa

Cada paquete instalado, cada servicio corriendo y cada puerto abierto en un nodo es una superficie de ataque adicional: código que puede tener vulnerabilidades (CVEs), binarios que un atacante puede usar para escalar privilegios o moverse lateralmente ("living off the land"), y procesos que consumen recursos y credenciales. En un clúster Kubernetes, el host OS (worker nodes y control plane) es la base de confianza sobre la que corre el container runtime, el kubelet y, en última instancia, los pods. Si el host está comprometido, ningún control a nivel de Pod Security Standards, NetworkPolicy o RBAC lo puede compensar completamente.

Minimizar el footprint del host OS significa aplicar el principio de menor privilegio y superficie mínima a nivel de sistema operativo: instalar solo lo estrictamente necesario para correr el kubelet, el container runtime (containerd/CRI-O) y el agente de red, y nada más.

## 1. Usar un sistema operativo minimalista orientado a contenedores

En lugar de una distribución general (Ubuntu Server, RHEL, Debian) con cientos de paquetes, muchos entornos productivos usan distros diseñadas específicamente para correr contenedores:

- **Flatcar Container Linux** (fork mantenido de CoreOS Container Linux): filesystem raíz de solo lectura, sin gestor de paquetes, actualizaciones atómicas tipo A/B.
- **Bottlerocket** (AWS): usado en EKS, root filesystem inmutable, sin shell interactivo ni SSH por defecto (acceso solo vía "admin container" o "control container" opcional).
- **Container-Optimized OS (COS)** (GCP, usado por defecto en GKE): filesystem raíz de solo lectura, verified boot, sin gestor de paquetes tradicional.
- **Talos Linux**: sin SSH, sin shell, sin gestor de paquetes; toda la administración se hace vía API gRPC (`talosctl`).

Características comunes que reducen el ataque de superficie:

- Root filesystem **read-only** (evita persistencia de malware).
- **Sin gestor de paquetes** (no se pueden instalar herramientas ad-hoc tras un compromiso).
- **Sin SSH** o SSH deshabilitado por defecto.
- Actualizaciones **atómicas e inmutables** (rollback simple ante fallos).

```bash
# Bottlerocket no tiene shell tradicional; se accede (si está habilitado)
# al "admin container" vía SSM o SSH, separado del sistema principal
$ ssh -i key.pem ec2-user@<bottlerocket-node>
This is the Bottlerocket administrative container...
```

Si no es posible migrar completamente a una de estas distros, el objetivo es replicar sus propiedades en una distro tradicional: mínima cantidad de paquetes, sin herramientas de compilación, sin shells innecesarios.

## 2. Deshabilitar y remover servicios innecesarios

Cualquier `systemd` unit corriendo que no sea estrictamente necesaria para el rol del nodo (kubelet, containerd, kube-proxy, CNI) debe deshabilitarse.

```bash
# Listar servicios activos
$ systemctl list-units --type=service --state=running

UNIT                 LOAD   ACTIVE SUB     DESCRIPTION
avahi-daemon.service  loaded active running Avahi mDNS/DNS-SD Stack
cups.service          loaded active running CUPS Scheduler
rpcbind.service       loaded active running RPC bind portmapper
containerd.service    loaded active running containerd container runtime
kubelet.service       loaded active running kubelet: The Kubernetes Node Agent
```

`avahi-daemon`, `cups` (impresión) y `rpcbind` no tienen ningún rol en un worker node y deben eliminarse:

```bash
$ systemctl disable --now avahi-daemon cups rpcbind
$ systemctl mask avahi-daemon cups rpcbind   # evita que se reactiven por dependencias
```

`disable` evita que el servicio arranque en el próximo boot; `mask` va un paso más allá creando un symlink a `/dev/null`, impidiendo que cualquier otro unit lo levante como dependencia — más robusto contra reactivaciones accidentales.

## 3. Remover paquetes innecesarios

Compiladores, intérpretes de scripting no usados, clientes de red adicionales y herramientas de desarrollo facilitan a un atacante que ya obtuvo ejecución de código escalar el ataque (descargar payloads, compilar exploits, moverse lateralmente).

```bash
# Debian/Ubuntu
$ apt list --installed | grep -E 'gcc|make|nmap|netcat'
$ apt purge -y gcc make netcat-openbsd nmap
$ apt autoremove -y

# RHEL/CentOS
$ rpm -qa | grep -E 'gcc|nc'
$ yum remove -y gcc nc
```

Buenas prácticas:

- No instalar herramientas de build (`gcc`, `make`, `cc`) en nodos de producción; compilar en pipelines de CI, no en runtime.
- Evitar clientes como `netcat`, `nmap`, `tcpdump` salvo que sean estrictamente necesarios para debugging operativo, y en ese caso instalarlos de forma temporal.
- Usar `dpkg -l` / `rpm -qa` para auditar periódicamente qué está instalado.

## 4. Reducir puertos de red expuestos

```bash
$ ss -tulpn
Netid  State   Local Address:Port   Process
tcp    LISTEN  0.0.0.0:10250        kubelet
tcp    LISTEN  0.0.0.0:22           sshd
tcp    LISTEN  0.0.0.0:6443         kube-apiserver
tcp    LISTEN  127.0.0.1:10248      kubelet (healthz, solo local — correcto)
```

Todo puerto en `0.0.0.0` que no necesite estar accesible desde fuera del host debería:

1. Cerrarse (deshabilitar el servicio que lo abre), o
2. Restringirse a `127.0.0.1` cuando el acceso es solo local, o
3. Filtrarse con un firewall (`nftables`/`iptables`) que solo permita el tráfico necesario (por ejemplo, `10250` del kubelet solo accesible desde el control plane).

```bash
# Ejemplo con nft: permitir solo tráfico del rango del control plane al puerto del kubelet
$ nft add rule inet filter input tcp dport 10250 ip saddr 10.0.0.0/24 accept
$ nft add rule inet filter input tcp dport 10250 drop
```

> Nota: las reglas de firewall a nivel de red del clúster (NetworkPolicy, Security Groups) se cubren en el tema 5.3 "Minimize external access to the network"; acá el foco es lo que corre y escucha *en el host* mismo.

## 5. Hardening de acceso remoto (SSH)

Si el SSH no puede eliminarse por completo (como en Talos/Bottlerocket), hay que endurecerlo:

```bash
# /etc/ssh/sshd_config
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
X11Forwarding no
AllowTcpForwarding no
MaxAuthTries 3
```

```bash
$ systemctl reload sshd
```

- `PermitRootLogin no`: obliga a autenticarse con un usuario sin privilegios y usar `sudo`, dejando rastro en logs.
- `PasswordAuthentication no`: elimina el vector de fuerza bruta/credential stuffing sobre SSH; solo claves.
- Deshabilitar forwarding de X11 y de puertos TCP reduce el uso del host como pivote.

## 6. Minimizar cuentas de usuario y privilegios locales

```bash
# Auditar usuarios con shell de login válida
$ awk -F: '$7 !~ /nologin|false/ {print $1, $7}' /etc/passwd
root /bin/bash
admin /bin/bash

# Forzar nologin a cuentas de servicio que no lo necesitan
$ usermod -s /usr/sbin/nologin admin
```

- Eliminar cuentas de usuario no utilizadas (`userdel`).
- Asegurar que las cuentas de servicio (las que corren daemons) usen `/usr/sbin/nologin` como shell.
- Restringir `sudo` con `visudo`, otorgando solo los comandos estrictamente necesarios en lugar de `ALL=(ALL) ALL`.

## 7. Deshabilitar módulos del kernel no usados

Reducir los módulos cargados reduce la superficie de kernel expuesta a exploits de escalación de privilegios.

```bash
$ lsmod | head
Module      Size  Used by
bluetooth  700416  10
btusb       57344  0

# Deshabilitar carga de módulos no usados en un nodo de datacenter
$ cat >> /etc/modprobe.d/blacklist-hardening.conf <<EOF
blacklist bluetooth
blacklist btusb
blacklist usb-storage
EOF
$ rmmod bluetooth
```

> Nota: la configuración de herramientas de kernel hardening como **AppArmor** y **seccomp** para restringir *syscalls* de contenedores corresponde al tema 5.4; acá se trata de reducir la cantidad de módulos y funcionalidad cargada a nivel de kernel del host en sí.

## 8. Auditar el hardening con benchmarks

**CIS Benchmarks** (Center for Internet Security) publica guías específicas para hardening de Kubernetes y de las distros de Linux subyacentes. `kube-bench` automatiza la verificación contra el **CIS Kubernetes Benchmark**, incluyendo checks a nivel de nodo:

```bash
$ kube-bench run --targets node

[INFO] 4 Worker Node Security Configuration
[PASS] 4.1.1 Ensure that the kubelet service file permissions are set to 600 or more restrictive
[FAIL] 4.2.1 Ensure that the --anonymous-auth argument is set to false
...
== Summary node ==
23 checks PASS
2 checks FAIL
1 checks WARN
```

Herramientas complementarias:

- **Lynis**: auditoría general de hardening de Linux (no específica de Kubernetes), detecta paquetes innecesarios, permisos débiles, servicios expuestos.
  ```bash
  $ lynis audit system
  ```
- Gestores de actualizaciones automáticas de seguridad (`unattended-upgrades` en Debian/Ubuntu, `dnf-automatic` en RHEL/Fedora) para mantener el footprint parcheado sin intervención manual, reduciendo la ventana de exposición a CVEs conocidos.

## Resumen de acciones concretas

| Acción | Comando/mecanismo |
|---|---|
| Elegir OS minimalista | Flatcar, Bottlerocket, COS, Talos |
| Deshabilitar servicios no usados | `systemctl disable --now && systemctl mask` |
| Remover paquetes innecesarios | `apt purge` / `yum remove` + `autoremove` |
| Cerrar/filtrar puertos expuestos | `ss -tulpn` + `nftables`/`iptables` |
| Endurecer SSH | `sshd_config`: `PermitRootLogin no`, `PasswordAuthentication no` |
| Minimizar cuentas locales | `usermod -s /usr/sbin/nologin`, `userdel` |
| Reducir módulos de kernel | `/etc/modprobe.d/blacklist-*.conf` |
| Verificar contra benchmark | `kube-bench run --targets node`, `lynis audit system` |

## Referencias

- CNCF CKS Curriculum v1.34: https://github.com/cncf/curriculum/raw/master/CKS_Curriculum%20v1.34.pdf
- CIS Kubernetes Benchmark: https://www.cisecurity.org/benchmark/kubernetes
- kube-bench (Aqua Security): https://github.com/aquasecurity/kube-bench
- Kubernetes docs — Nodes: https://kubernetes.io/docs/concepts/architecture/nodes/
- Flatcar Container Linux: https://www.flatcar.org/docs/latest/
- Bottlerocket OS: https://github.com/bottlerocket-os/bottlerocket
- Google Container-Optimized OS: https://cloud.google.com/container-optimized-os/docs
- Talos Linux: https://www.talos.dev/latest/introduction/what-is-talos/
- Lynis security auditing tool: https://cisofy.com/lynis/
- OpenSSH `sshd_config` manual: https://man.openbsd.org/sshd_config