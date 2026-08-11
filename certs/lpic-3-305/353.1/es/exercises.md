# LPIC-3 305 (305-300) — Topic 353.1: Cloud Management Tools

## Ejercicios guiados

Estos ejercicios te llevan a través de la gestión de una nube IaaS con **OpenStack** y **Apache Libcloud**, mapeados directamente al objetivo LPI 305-300 *353.1 Cloud Management Tools*. Vas a autenticarte contra el servicio de Identidad, publicar una imagen, arrancar y conectar en red una instancia, adjuntar almacenamiento en bloque, orquestar un stack con Heat y, finalmente, manejar la misma nube programáticamente a través de Libcloud.

**Entorno de laboratorio de referencia.** Sirve cualquier nube OpenStack con el cliente unificado `openstack` (`python-openstackclient`). Los comandos y salidas de abajo asumen un despliegue **DevStack** de un solo nodo (`stable/2024.1`, nombre de release *Caracal*) alcanzable en `controller` (`10.0.0.11`), con las credenciales demo tomadas de un `clouds.yaml`. Si no tenés una nube, DevStack construye una sobre una VM descartable: <https://docs.openstack.org/devstack/latest/>.

> Convención usada en todo el documento: `$` es un prompt de shell sin privilegios. Los IDs en las salidas de ejemplo están truncados por legibilidad — los tuyos van a diferir. Todo comando es idempotente al re-ejecutarse, excepto donde un paso crea o elimina explícitamente un recurso.

---

### Ejercicio 1 — Autenticarse y mapear el catálogo de servicios de OpenStack

Toda la nube es un conjunto de servicios REST independientes pegados entre sí por **Keystone** (Identity). Antes de tocar cualquier recurso, tenés que obtener un token y descubrir qué servicios y endpoints existen.

1. Creá un `clouds.yaml` en `~/.config/openstack/` que describa tus credenciales. Esto reemplaza el hacer source de un archivo `openrc` y te permite seleccionar una nube con `--os-cloud`:

   ```yaml
   # ~/.config/openstack/clouds.yaml
   clouds:
     devstack:
       auth:
         auth_url: http://controller:5000/v3
         username: demo
         password: "secret"
         project_name: demo
         user_domain_name: Default
         project_domain_name: Default
       region_name: RegionOne
       identity_api_version: 3
       interface: public
   ```

2. Apuntá cada comando a esa nube por el resto de la sesión:

   ```bash
   $ export OS_CLOUD=devstack
   ```

3. Probá que tus credenciales funcionan emitiendo un token con scope. Esto es una llamada al `POST /v3/auth/tokens` de Keystone:

   ```bash
   $ openstack token issue
   ```

   Salida esperada (abreviada):

   ```
   +------------+----------------------------------+
   | Field      | Value                            |
   +------------+----------------------------------+
   | expires    | 2026-08-11T13:44:07+0000         |
   | id         | gAAAAABm...                      |
   | project_id | 8f2c1e...                        |
   | user_id    | 4a91bd...                        |
   +------------+----------------------------------+
   ```

4. Listá los tipos de servicio registrados. Cada fila es un proyecto de OpenStack respondiendo a una API distinta:

   ```bash
   $ openstack service list
   ```

   ```
   +----------------------------------+-----------+----------------+
   | ID                               | Name      | Type           |
   +----------------------------------+-----------+----------------+
   | 5c1e...                          | keystone  | identity       |
   | 7a09...                          | glance    | image          |
   | 9b31...                          | nova      | compute        |
   | 2f88...                          | neutron   | network        |
   | c4d0...                          | cinder    | volumev3       |
   | e6a2...                          | heat      | orchestration  |
   | 1d7f...                          | swift     | object-store   |
   | 3b55...                          | placement | placement      |
   +----------------------------------+-----------+----------------+
   ```

5. Inspeccioná los endpoints de un servicio para ver la URL con la que tu cliente realmente habla. Fijate en el `publicURL` frente a las interfaces internal/admin:

   ```bash
   $ openstack endpoint list --service compute --interface public
   ```

   ```
   +------+-----------+--------------+--------------+---------+-----------+-------------------------------+
   | ID   | Region    | Service Name | Service Type | Enabled | Interface | URL                           |
   +------+-----------+--------------+--------------+---------+-----------+-------------------------------+
   | a1.. | RegionOne | nova         | compute      | True    | public    | http://controller:8774/v2.1   |
   +------+-----------+--------------+--------------+---------+-----------+-------------------------------+
   ```

6. Volcá el catálogo con el que tu token quedó con scope — esto es lo que el cliente cachea para enrutar cada llamada posterior:

   ```bash
   $ openstack catalog list
   ```

**Preguntas de comprensión**

- **Q1.1** ¿Qué componente de OpenStack emite el token, y qué dos hechos debe llevar un token *con scope* que uno sin scope no lleva?
- **Q1.2** Tu `clouds.yaml` fija `interface: public`. ¿Cuál es la diferencia práctica entre las interfaces de endpoint `public`, `internal` y `admin`, y por qué DevStack expone las tres?
- **Q1.3** Ejecutás `openstack server list` y obtenés `Unable to establish connection to http://controller:8774/...`. La autenticación de Keystone claramente tuvo éxito porque `openstack token issue` funcionó. ¿Qué pieza de dato del catálogo está usando el cliente para llegar a Nova, y dónde mirarías para confirmar que está mal?

---

### Ejercicio 2 — Publicar una imagen booteable con Glance

**Glance** es el registro de imágenes. Una instancia arranca desde una imagen de Glance copiada al disco efímero del hipervisor (o, más tarde, clonada en un volumen de Cinder).

1. Listá las imágenes existentes. En un DevStack recién armado vas a ver la imagen de prueba CirrOS:

   ```bash
   $ openstack image list
   ```

   ```
   +--------------------------------------+--------------------------+--------+
   | ID                                   | Name                     | Status |
   +--------------------------------------+--------------------------+--------+
   | b7f3c2a1-...                         | cirros-0.6.2-x86_64-disk | active |
   +--------------------------------------+--------------------------+--------+
   ```

2. Descargá una imagen de nube pequeña para subirla vos:

   ```bash
   $ wget -q https://download.cirros-cloud.net/0.6.2/cirros-0.6.2-x86_64-disk.img
   ```

3. Creá la imagen en Glance, declarando su formato en disco y su formato de contenedor. `qcow2` es el disco copy-on-write de QEMU; `bare` significa que el disco no está envuelto en ningún metadato de contenedor extra:

   ```bash
   $ openstack image create \
       --disk-format qcow2 \
       --container-format bare \
       --file cirros-0.6.2-x86_64-disk.img \
       --public \
       cirros-custom
   ```

   ```
   +------------------+--------------------------------------------------------+
   | Field            | Value                                                  |
   +------------------+--------------------------------------------------------+
   | container_format | bare                                                   |
   | disk_format      | qcow2                                                  |
   | id               | 4d9a77e1-3c2b-4f0a-9a2e-1b8c7d6e5f40                   |
   | min_disk         | 0                                                      |
   | min_ram          | 0                                                      |
   | name             | cirros-custom                                          |
   | status           | active                                                 |
   | visibility       | public                                                 |
   +------------------+--------------------------------------------------------+
   ```

4. Adjuntá metadatos buscables (*properties* de la imagen). Los schedulers y la CLI pueden filtrar por estos:

   ```bash
   $ openstack image set --property os_distro=cirros --property hw_disk_bus=virtio cirros-custom
   ```

5. Confirmá que las properties y el checksum calculado están almacenados:

   ```bash
   $ openstack image show cirros-custom -c name -c checksum -c properties
   ```

   ```
   +------------+----------------------------------------------------+
   | Field      | Value                                              |
   +------------+----------------------------------------------------+
   | checksum   | 0b3 b1a...                                         |
   | name       | cirros-custom                                      |
   | properties | hw_disk_bus='virtio', os_distro='cirros', ...      |
   +------------+----------------------------------------------------+
   ```

**Preguntas de comprensión**

- **Q2.1** ¿Cuál es la diferencia entre `--disk-format` y `--container-format`, y cuándo sería `container-format` algo distinto de `bare`?
- **Q2.2** Creaste la imagen con `--public`. ¿Qué servicio de OpenStack decide si al usuario `demo` se le *permite* crear una imagen pública, y cuál es el resultado habitual para un usuario que no es admin?
- **Q2.3** `min_disk` y `min_ram` eran ambos `0`. ¿Qué se rompe en el momento del boot si subís una imagen de 20 GB pero dejás `min_disk` en `0`, y un usuario selecciona un flavor con un disco raíz de 10 GB?

---

### Ejercicio 3 — Arrancar e inspeccionar una instancia con Nova

**Nova** es el servicio de cómputo. Arrancar un servidor es una decisión de scheduling (`placement` elige un host) más el cableado de una imagen, un **flavor** (la plantilla de dimensionamiento de CPU/RAM/disco), un puerto de red y, opcionalmente, una clave SSH.

1. Listá los flavors — estas son las plantillas de dimensionamiento fijas entre las que un tenant puede elegir:

   ```bash
   $ openstack flavor list
   ```

   ```
   +----+-----------+-------+------+-----------+-------+-----------+
   | ID | Name      |   RAM | Disk | Ephemeral | VCPUs | Is Public |
   +----+-----------+-------+------+-----------+-------+-----------+
   | 1  | m1.tiny   |   512 |    1 |         0 |     1 | True      |
   | 2  | m1.small  |  2048 |   20 |         0 |     1 | True      |
   | 3  | m1.medium |  4096 |   40 |         0 |     2 | True      |
   +----+-----------+-------+------+-----------+-------+-----------+
   ```

2. Creá un par de claves SSH para poder alcanzar la instancia. Nova almacena solo la clave pública y la inyecta vía el servicio de metadatos / cloud-init:

   ```bash
   $ openstack keypair create labkey > ~/labkey.pem && chmod 600 ~/labkey.pem
   ```

3. Identificá la red del tenant a la que adjuntarte (creada en el Ejercicio 4 si no existe; DevStack trae una red `private`):

   ```bash
   $ openstack network list
   ```

4. Arrancá el servidor. `--wait` bloquea hasta que Nova reporta `ACTIVE`:

   ```bash
   $ openstack server create \
       --flavor m1.small \
       --image cirros-custom \
       --network private \
       --key-name labkey \
       --wait \
       web01
   ```

   ```
   +-------------------------+-----------------------------------------------+
   | Field                   | Value                                         |
   +-------------------------+-----------------------------------------------+
   | OS-EXT-STS:power_state  | Running                                       |
   | OS-EXT-STS:vm_state     | active                                        |
   | addresses               | private=10.0.5.14                             |
   | flavor                  | m1.small (2)                                  |
   | id                      | 7c2e6b9a-2f1d-4c88-b0a3-9e1f2a7c4d55          |
   | image                   | cirros-custom (4d9a77e1-...)                  |
   | key_name                | labkey                                        |
   | status                  | ACTIVE                                         |
   +-------------------------+-----------------------------------------------+
   ```

5. Leé el log de consola para confirmar que el SO realmente booteó (esto es Nova leyendo la consola serie del hipervisor, invaluable cuando SSH falla):

   ```bash
   $ openstack console log show web01 | tail -n 5
   ```

   ```
   === cirros: current=0.6.2 ...
   login as 'cirros' user. default password: 'gocubsgo'.
   web01 login:
   ```

6. Mostrá la decisión de placement y el puerto que Neutron le entregó a esta instancia:

   ```bash
   $ openstack server show web01 -c OS-EXT-SRV-ATTR:host -c addresses
   $ openstack port list --server web01
   ```

**Preguntas de comprensión**

- **Q3.1** Rastreá los cuatro servicios involucrados desde el momento en que ejecutás `openstack server create` hasta que la VM está `ACTIVE`. Nombrá cada uno y enunciá su única tarea en el flujo.
- **Q3.2** La instancia levantó pero no podés entrar por SSH, sin embargo `openstack console log show` muestra un prompt de login. ¿Es esto más probablemente un problema de Nova o de Neutron? Justificalo.
- **Q3.3** ¿Por qué Nova almacena solo la mitad *pública* del par de claves, y mediante qué mecanismo la instancia CirrOS en ejecución la recupera durante el primer boot?

---

### Ejercicio 4 — Construir la red del tenant con Neutron

**Neutron** provee redes, subnets, routers y floating IPs. Una red privada de tenant llega al mundo exterior a través de un router que tiene su gateway configurado en la red provider/external.

1. Creá una red de tenant aislada y una subnet con un rango DHCP:

   ```bash
   $ openstack network create lab-net
   $ openstack subnet create lab-subnet \
       --network lab-net \
       --subnet-range 192.168.50.0/24 \
       --gateway 192.168.50.1 \
       --dns-nameserver 1.1.1.1
   ```

   ```
   +----------------------+--------------------------------------+
   | Field                | Value                                |
   +----------------------+--------------------------------------+
   | allocation_pools     | 192.168.50.2-192.168.50.254          |
   | cidr                 | 192.168.50.0/24                      |
   | enable_dhcp          | True                                 |
   | gateway_ip           | 192.168.50.1                         |
   | network_id           | 2b7c...                              |
   +----------------------+--------------------------------------+
   ```

2. Creá un router y adjuntá la subnet del tenant a él como interfaz interna:

   ```bash
   $ openstack router create lab-router
   $ openstack router add subnet lab-router lab-subnet
   ```

3. Configurá el gateway externo del router en la red provider para que el tráfico del tenant sea SNAT'eado hacia afuera:

   ```bash
   $ openstack router set lab-router --external-gateway public
   ```

4. Asigná una floating IP del pool externo y asociala con `web01` para alcanzabilidad entrante (DNAT):

   ```bash
   $ openstack floating ip create public
   ```

   ```
   +---------------------+--------------------------------------+
   | Field               | Value                                |
   +---------------------+--------------------------------------+
   | floating_ip_address | 172.24.4.87                          |
   | id                  | f1a9...                              |
   | status              | DOWN                                 |
   +---------------------+--------------------------------------+
   ```

   ```bash
   $ openstack server add floating ip web01 172.24.4.87
   ```

5. Abrí ICMP y SSH en el **security group** por defecto (un firewall con estado de Neutron aplicado en el puerto), luego verificá la alcanzabilidad:

   ```bash
   $ openstack security group rule create --proto icmp default
   $ openstack security group rule create --proto tcp --dst-port 22 default
   $ ping -c1 172.24.4.87
   $ ssh -i ~/labkey.pem cirros@172.24.4.87
   ```

**Preguntas de comprensión**

- **Q4.1** Distinguí una *network*, una *subnet* y un *port* en el modelo de datos de Neutron. ¿A cuál se enlaza realmente un security group?
- **Q4.2** ¿Qué operación NAT realiza una floating IP para el tráfico entrante, y qué operación NAT distinta realiza el gateway externo del router para el tráfico saliente de una instancia que *no* tiene floating IP?
- **Q4.3** Asociaste la floating IP y el security group permite ICMP, pero el ping sigue fallando. Nombrá dos causas independientes de la capa de Neutron a revisar antes de culpar al SO de la instancia.

---

### Ejercicio 5 — Adjuntar almacenamiento en bloque persistente con Cinder

**Cinder** provee volúmenes en bloque cuyo ciclo de vida es independiente de cualquier instancia. El disco raíz efímero de una instancia muere con la instancia; un volumen de Cinder sobrevive.

1. Creá un volumen de 10 GB:

   ```bash
   $ openstack volume create --size 10 data-vol
   ```

   ```
   +---------------------+--------------------------------------+
   | Field               | Value                                |
   +---------------------+--------------------------------------+
   | id                  | 9d21c4e8-...                         |
   | name                | data-vol                             |
   | size                | 10                                   |
   | status              | available                            |
   | volume_type         | lvmdriver-1                          |
   +---------------------+--------------------------------------+
   ```

2. Adjuntalo a la instancia en ejecución. Nova le pide a Cinder que exporte el volumen y lo hot-pluggea en el guest:

   ```bash
   $ openstack server add volume web01 data-vol --device /dev/vdb
   ```

3. Confirmá el attachment desde el plano de control:

   ```bash
   $ openstack volume show data-vol -c status -c attachments
   ```

   ```
   +-------------+-------------------------------------------------------------+
   | Field       | Value                                                       |
   +-------------+-------------------------------------------------------------+
   | attachments | [{'server_id': '7c2e6b9a-...', 'device': '/dev/vdb', ...}]  |
   | status      | in-use                                                      |
   +-------------+-------------------------------------------------------------+
   ```

4. Dentro del guest, comprobá que el dispositivo de bloque apareció, luego formatealo y montalo:

   ```bash
   $ ssh -i ~/labkey.pem cirros@172.24.4.87
   $ sudo fdisk -l /dev/vdb          # 10 GiB unpartitioned disk
   $ sudo mkfs.ext4 /dev/vdb
   $ sudo mount /dev/vdb /mnt && df -h /mnt
   ```

5. Tomá un snapshot puntual en el tiempo (un snapshot de Cinder, no una imagen de Glance) para backup/branching:

   ```bash
   $ openstack volume snapshot create --volume data-vol data-vol-snap-1
   ```

**Preguntas de comprensión**

- **Q5.1** ¿Cuál es la diferencia fundamental de durabilidad entre el disco raíz efímero de una instancia y un volumen de Cinder, y qué flag en `server create` difumina esa línea booteando *desde* un volumen?
- **Q5.2** Después de adjuntar el volumen, `openstack volume show` reporta `status: in-use` pero dentro del guest `/dev/vdb` nunca aparece. El plano de control claramente cree que el attach tuvo éxito — ¿en qué parte del stack está la falla, y cuál es un comando de diagnóstico?
- **Q5.3** ¿Por qué generalmente no podés adjuntar un único volumen `available` a dos instancias a la vez, y qué característica de Cinder relaja esto — con qué salvedad puesta sobre el *guest*?

---

### Ejercicio 6 — Orquestar un stack completo con Heat

**Heat** es el motor de orquestación. Un **HOT** (Heat Orchestration Template) declara recursos y sus dependencias; Heat los crea, actualiza y elimina como un único **stack** atómico, calculando el orden a partir de las referencias.

1. Escribí una plantilla HOT que aprovisione una red, subnet y servidor juntos:

   ```yaml
   # lab-stack.yaml
   heat_template_version: 2021-04-16

   description: >
     LPIC-3 353.1 demo stack: private network + subnet + one server.

   parameters:
     image:
       type: string
       default: cirros-custom
     flavor:
       type: string
       default: m1.small
     public_net:
       type: string
       default: public

   resources:
     stack_net:
       type: OS::Neutron::Net
       properties:
         name: heat-net

     stack_subnet:
       type: OS::Neutron::Subnet
       properties:
         network: { get_resource: stack_net }
         cidr: 192.168.60.0/24
         dns_nameservers: [1.1.1.1]

     stack_server:
       type: OS::Nova::Server
       properties:
         name: heat-web01
         image: { get_param: image }
         flavor: { get_param: flavor }
         networks:
           - network: { get_resource: stack_net }

   outputs:
     server_ip:
       description: Fixed IP of the provisioned server
       value: { get_attr: [stack_server, first_address] }
   ```

2. Validá la plantilla *antes* de desplegar — Heat verifica el schema y los tipos de recurso sin crear nada:

   ```bash
   $ openstack orchestration template validate -t lab-stack.yaml
   ```

3. Creá el stack, sobrescribiendo un parámetro en la línea de comandos:

   ```bash
   $ openstack stack create -t lab-stack.yaml --parameter flavor=m1.tiny lab-stack --wait
   ```

   ```
   2026-08-11 13:20:41 [stack_net]: CREATE_IN_PROGRESS  state changed
   2026-08-11 13:20:46 [stack_subnet]: CREATE_COMPLETE  state changed
   2026-08-11 13:21:02 [stack_server]: CREATE_COMPLETE  state changed
   +---------------------+--------------------------------------+
   | id                  | 5e8b3a11-...                        |
   | stack_name          | lab-stack                            |
   | stack_status        | CREATE_COMPLETE                      |
   +---------------------+--------------------------------------+
   ```

4. Leé el output declarado — Heat calculó la IP del servidor después de que Nova la asignó:

   ```bash
   $ openstack stack output show lab-stack server_ip
   ```

5. Realizá una actualización declarativa: cambiá `flavor` de vuelta a `m1.small` en la plantilla y dejá que Heat reconcilie solo lo que cambió:

   ```bash
   $ openstack stack update -t lab-stack.yaml lab-stack --wait
   ```

6. Desmantelá todo como una única unidad (Heat elimina en orden inverso de dependencias):

   ```bash
   $ openstack stack delete lab-stack --yes
   ```

**Preguntas de comprensión**

- **Q6.1** En ningún lugar de la plantilla dijiste "creá la red *antes* del servidor". ¿Cómo determina Heat ese ordenamiento, y cuál función intrínseca es la señal?
- **Q6.2** ¿Cuál es la diferencia entre `get_resource`, `get_param` y `get_attr`, y en qué momento del ciclo de vida del stack se resuelve cada una?
- **Q6.3** Cambiás la property `image` de `stack_server` y ejecutás `stack update`. Algunos cambios de property disparan una actualización in-place y otros fuerzan un *reemplazo* del recurso. ¿Qué comportamiento es probable aquí, y por qué esa distinción le importa a una carga de trabajo de producción en ejecución?

---

### Ejercicio 7 — Manejar la misma nube con Apache Libcloud

**Apache Libcloud** es una biblioteca de abstracción en Python que presenta *una* API a través de más de 50 proveedores de nube, incluyendo OpenStack. Es la respuesta del objetivo LPI a "gestionar muchas nubes desde una sola base de código". Aquí reproducís el boot del Ejercicio 3 usando el driver de cómputo de OpenStack de Libcloud.

1. Instalá la biblioteca en un virtualenv:

   ```bash
   $ python3 -m venv ~/lc && source ~/lc/bin/activate
   (lc) $ pip install "apache-libcloud>=3.8.0"
   ```

2. Instanciá el driver de OpenStack contra Keystone v3. Fijate en los argumentos de palabra clave `ex_force_*` — Libcloud expone detalles de auth específicos del proveedor como extensiones `ex_`:

   ```python
   # lc_boot.py
   from libcloud.compute.types import Provider
   from libcloud.compute.providers import get_driver

   OpenStack = get_driver(Provider.OPENSTACK)

   driver = OpenStack(
       "demo",                                   # username
       "secret",                                 # password / api_key
       ex_force_auth_url="http://controller:5000",
       ex_force_auth_version="3.x_password",
       ex_domain_name="Default",
       ex_tenant_name="demo",
       ex_force_service_region="RegionOne",
   )
   ```

3. Listá los sizes (flavors) e imágenes a través de los objetos *normalizados* de Libcloud — `NodeSize` y `NodeImage`, idénticos en forma sin importar el proveedor:

   ```python
   sizes = driver.list_sizes()
   images = driver.list_images()

   size = next(s for s in sizes if s.name == "m1.small")
   image = next(i for i in images if i.name == "cirros-custom")

   print(size.id, size.ram, size.disk, size.vcpus)
   print(image.id, image.name)
   ```

4. Creá un node (instancia). Las redes se pasan como una extensión `ex_` porque son específicas de OpenStack:

   ```python
   networks = driver.ex_list_networks()
   net = next(n for n in networks if n.name == "private")

   node = driver.create_node(
       name="lc-web01",
       size=size,
       image=image,
       networks=[net],
   )
   print("created:", node.id, node.state)
   ```

5. Esperá hasta que el node esté corriendo e imprimí sus direcciones usando el enum de estado portable:

   ```python
   from libcloud.compute.types import NodeState

   node = driver.wait_until_running([node])[0][0]
   print(node.state, node.private_ips, node.public_ips)
   assert node.state == NodeState.RUNNING
   ```

6. Ejecutalo, luego confirmá desde la CLI que Libcloud y el cliente `openstack` están mirando el *mismo* estado de la nube:

   ```bash
   (lc) $ python3 lc_boot.py
   (lc) $ openstack server list --name lc-web01
   ```

7. Destruí el node a través de Libcloud para cerrar el ciclo:

   ```python
   driver.destroy_node(node)
   ```

**Preguntas de comprensión**

- **Q7.1** Libcloud llama a un flavor `NodeSize` y a una instancia `Node`. ¿Cuál es el propósito de diseño de este renombrado, y qué *perdés* al trabajar a través de él en lugar del cliente nativo `openstack`?
- **Q7.2** ¿Por qué `size`, `image` y `name` de `create_node` son argumentos comunes, mientras que `networks` tuvo que pasarse vía `ex_list_networks()` / la extensión `networks`? ¿Qué comunica la convención del prefijo `ex_` sobre la portabilidad?
- **Q7.3** Apuntás el mismo script a AWS EC2 cambiando solo `get_driver(Provider.EC2)` y las credenciales. `list_nodes()` y `create_node()` siguen funcionando, pero tu llamada a `ex_list_networks()` se rompe. Explicá con precisión por qué, en términos del contrato "base API vs. extension" de Libcloud.

---

<details>
<summary><strong>Respuestas</strong></summary>

**Ejercicio 1 — Keystone y el catálogo**

- **A1.1** **Keystone** (el servicio de Identidad) emite el token vía `POST /v3/auth/tokens`. Un token *con scope* lleva adicionalmente un **scope de proyecto (y/o dominio)** y el **catálogo de servicios + asignaciones de rol** válidas para ese scope. Un token sin scope prueba *quién sos* pero no autoriza recursos de ningún proyecto y no contiene catálogo, así que no puede usarse para llamar a Nova/Neutron/etc.
- **A1.2** Son tres URLs separadas para el mismo servicio, pensadas para distintas rutas de red: **public** = el endpoint de cara al tenant (a menudo detrás de un load balancer / floating IP), **internal** = la misma API sobre la red de management/backplane (evita el salto público para el tráfico servicio-a-servicio), **admin** = históricamente un puerto privilegiado (importa sobre todo para la API admin deprecada de Keystone v2; en v3 suele ser idéntico a public). DevStack registra las tres para que las herramientas de laboratorio puedan ejercitar cada interfaz aunque resuelvan al mismo host.
- **A1.3** El cliente enrutó hacia Nova usando la **URL del endpoint de compute del catálogo de servicios** embebido en tu token con scope. Confirmalo con `openstack endpoint list --service compute` (o `openstack catalog show compute`); una URL incorrecta/inalcanzable ahí — hostname obsoleto, puerto `8774` equivocado, o un servicio registrado pero con su proceso caído — produce exactamente ese error de conexión aunque la auth de Keystone haya tenido éxito.

**Ejercicio 2 — Glance**

- **A2.1** `--disk-format` describe el **layout en disco del disco virtual** que el hipervisor debe entender (`qcow2`, `raw`, `vmdk`, `vdi`, `qed`, `iso`). `--container-format` describe cualquier **envoltorio/sobre de metadatos alrededor de ese disco** (`bare` = ninguno). *No* es `bare` para formatos que empaquetan disco+metadatos, p. ej. `ovf`/`ova` (una descripción de VM más discos) o bundles al estilo `docker`/`ami`.
- **A2.2** La autorización de **Keystone** — dirigida por la política (RBAC) de Glance — lo decide. Crear una imagen **pública** normalmente requiere un rol admin; un usuario `demo` común típicamente obtiene `403 Forbidden` (o la imagen se crea silenciosamente como `private`/`shared`), porque una imagen pública es visible para cada tenant de la nube.
- **A2.3** El scheduler de Nova va a **rechazar el boot** (no hay host válido / flavor demasiado chico) o el guest va a fallar porque el disco raíz no puede contener la imagen. `min_disk` es el *contrato* de que el disco raíz de un flavor debe ser de al menos esa cantidad de GB para bootear esta imagen; dejarlo en `0` quita la protección, así que un usuario puede combinar una imagen de 20 GB con un flavor de 10 GB y toparse con una falla de disco-demasiado-chico en el momento del build.

**Ejercicio 3 — Nova**

- **A3.1** (1) **Keystone** autentica la solicitud y valida el token/scope. (2) **Glance** suministra la imagen a partir de la cual se construye el disco raíz. (3) **Placement + el scheduler de Nova** seleccionan un host de compute que satisface la CPU/RAM/disco del flavor. (4) **Neutron** crea/enlaza un puerto y le entrega a la instancia su red/IP; el agente de compute de Nova luego bootea el dominio en el hipervisor y pasa a `ACTIVE`.
- **A3.2** Más probablemente un problema de **Neutron**. El prompt de login de la consola prueba que el SO del guest booteó y que la ruta imagen/flavor/hipervisor (Nova/Glance) está sana; la falla para alcanzarlo por red apunta a reglas del security group, la asociación de la floating IP, el ruteo de subnet, o el binding del puerto — todo Neutron.
- **A3.3** Almacenar solo la clave pública significa que la **clave privada nunca toca el plano de control de la nube**, así que un Nova/DB comprometido no puede filtrarla. La instancia recupera la clave pública en el primer boot desde el **servicio de metadatos** (`http://169.254.169.254/…`) — o config-drive — que **cloud-init** lee y escribe en `~/.ssh/authorized_keys`.

**Ejercicio 4 — Neutron**

- **A4.1** Una **network** es un dominio de broadcast L2 aislado; una **subnet** es un rango de IP L3 (CIDR + gateway + pool DHCP + DNS) superpuesto sobre una network; un **port** es un punto de attachment de NIC virtual sobre una network, que sostiene una MAC y una o más IPs fijas. Un **security group se enlaza al port** (vía el puerto de la instancia), no a la network ni a la subnet.
- **A4.2** La floating IP realiza **DNAT** (NAT de destino) entrante — externo `172.24.4.87` → la IP fija de la instancia. El gateway externo del router realiza **SNAT** (NAT de origen / PAT) saliente — muchas IPs fijas de tenant comparten la dirección externa del gateway para que las instancias *sin* floating IP igual puedan llegar a internet.
- **A4.3** Dos cualesquiera de: el router **no tiene gateway externo configurado** (o la subnet nunca fue `router add subnet`'eada, así que no hay ruta de salida); la **floating IP no está asociada** (todavía `DOWN`) o asociada al puerto equivocado; la **regla del security group tiene la dirección/ethertype equivocada** (ingress vs egress, IPv4 vs IPv6); o **port security / allowed-address-pairs** descartando el tráfico. Cada una es una causa del plano de control independiente del SO del guest.

**Ejercicio 5 — Cinder**

- **A5.1** El **disco raíz efímero se elimina cuando la instancia se elimina** (vive en el almacenamiento local/de instancia de Nova); un **volumen de Cinder persiste independientemente** y puede re-adjuntarse en otro lado. `openstack server create --boot-from-volume <size>` (o `--volume <id>`) difumina la línea haciendo que el propio disco raíz sea un volumen de Cinder que sobrevive a la instancia.
- **A5.2** La falla está en el **lado del guest / el hot-plug del attach** — Cinder y Nova registraron el attachment, pero el dispositivo virtio-blk no surgió en la VM. Diagnosticá desde adentro con `dmesg | grep -i vd` (o `lsblk`) para ver si el kernel enumeró un disco nuevo; en el host, revisá el log de compute de Nova y `virsh domblklist <instance>` para confirmar que el dispositivo de bloque fue realmente enchufado al dominio.
- **A5.3** Un volumen por defecto es **single-attach** porque un sistema de archivos normal (ext4/xfs) asume propiedad exclusiva del bloque; dos escritores lo corromperían. El tipo de volumen **multi-attach** de Cinder relaja esto, pero la salvedad está en el guest: tenés que correr un **sistema de archivos cluster-aware / de disco compartido o un coordinador** (p. ej. GFS2, OCFS2, o una aplicación que arbitre el acceso) — ext4 plano igual se corromperá.

**Ejercicio 6 — Heat**

- **A6.1** Heat construye un **grafo de dependencias** escaneando las funciones intrínsecas que referencian otros recursos. Ver `network: { get_resource: stack_net }` dentro de la subnet/servidor le dice a Heat que esos recursos dependen de `stack_net`, así que crea `stack_net` primero y lo elimina último. `get_resource` (y cualquier referencia entre recursos, o un `depends_on` explícito) es la señal de ordenamiento.
- **A6.2** `get_param` resuelve un **parámetro de entrada de la plantilla** en el momento de crear/actualizar el stack (antes de que existan los recursos). `get_resource` devuelve el **ID físico de otro recurso en este stack** y por lo tanto fuerza el ordenamiento de creación. `get_attr` lee un **atributo en tiempo de ejecución de un recurso ya creado** (p. ej. una IP asignada) y solo puede resolverse *después* de que ese recurso alcance CREATE_COMPLETE.
- **A6.3** Cambiar `image` casi siempre fuerza un **reemplazo** — la imagen de boot de un servidor no es mutable in-place, así que Heat elimina el servidor viejo y crea uno nuevo, lo que significa **nueva instancia, nueva IP/pérdida de datos** a menos que el disco esté en un volumen persistente. La distinción in-place-vs-reemplazo es crítica en producción porque una "pequeña edición de plantilla" puede destruir y recrear silenciosamente una carga de trabajo en vivo; revisá el plan de actualización (`stack update --dry-run` / preview) antes de aplicar.

**Ejercicio 7 — Libcloud**

- **A7.1** El renombrado existe para dar un **vocabulario agnóstico del proveedor**: `NodeSize`, `NodeImage`, `Node`, `NodeState` significan lo mismo en OpenStack, EC2, GCE, etc., así que una sola base de código maneja muchas nubes. Lo que perdés es acceso a la **cola larga de características específicas del proveedor** — cualquier cosa que no esté en el modelo base de Libcloud queda expuesta solo a través de extensiones `ex_` o no queda expuesta en absoluto, mientras que el cliente nativo `openstack` expone cada capacidad específica de OpenStack y las microversiones actualizadas.
- **A7.2** `size`, `image` y `name` son parte de la **API de compute base portable** de Libcloud — cada proveedor tiene un equivalente, así que son argumentos de primera clase. Las redes **no están modeladas de manera uniforme entre proveedores**, así que la red de OpenStack se expone a través de `ex_list_networks()` y la extensión `networks`. El **prefijo `ex_` marca la superficie específica del proveedor, no portable**: apoyarte en él significa que tu código ya no se mueve limpiamente a otro driver.
- **A7.3** `list_nodes()` y `create_node()` pertenecen a la **API base portable `NodeDriver`** que todo driver implementa, así que siguen funcionando en EC2. `ex_list_networks()` es una **extensión del driver de OpenStack**; el driver de EC2 no implementa ese método (EC2 modela la red como VPCs/subnets vía distintas llamadas `ex_`), así que el atributo no existe y la llamada lanza un error. Ese es el contrato base-API-vs-extensión: solo la superficie sin `ex_` está garantizada entre drivers.

</details>

---

### Sources

- LPI — *Exam 305-300 Objectives* (Objective 353.1, Cloud Management Tools): <https://www.lpi.org/our-certifications/exam-305-objectives/>
- OpenStack — *Logical architecture / Get started*: <https://docs.openstack.org/install-guide/get-started-logical-architecture.html>
- OpenStack — *`python-openstackclient` command reference*: <https://docs.openstack.org/python-openstackclient/latest/>
- Keystone (Identity) — *Administrator & concepts*: <https://docs.openstack.org/keystone/latest/>
- Glance (Image) — *User & admin guides*: <https://docs.openstack.org/glance/latest/>
- Nova (Compute): <https://docs.openstack.org/nova/latest/>
- Neutron (Networking): <https://docs.openstack.org/neutron/latest/>
- Cinder (Block Storage): <https://docs.openstack.org/cinder/latest/>
- Heat (Orchestration) — *HOT specification & template guide*: <https://docs.openstack.org/heat/latest/template_guide/hot_spec.html>
- Apache Libcloud — *Compute base API & OpenStack driver*: <https://libcloud.readthedocs.io/en/stable/compute/drivers/openstack.html>
- CirrOS test image (lab asset): <https://download.cirros-cloud.net/>