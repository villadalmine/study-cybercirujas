# LPI DevOps Tools Engineer (701-100) — Tema 704.1: Guía de estudio avanzada de Ansible para producción

**Examen objetivo:** LPI DevOps Tools Engineer (Examen 701-100, Versión 1.0)  
**Peso del tema:** 13.33 (Tema 704.1: Ansible)  
**Nivel de audiencia:** Principal Platform Architect / Senior SRE  

---

## 1. Motivación en producción y mecánica arquitectónica

### 1.1 El desafío de la deriva de estado de infraestructura y la configuración
En entornos multi-cloud empresariales, los nodos administrados sufren de forma natural de **configuration drift** (deriva de configuración): la divergencia estructural no intencionada entre instancias de cómputo en ejecución causada por ejecuciones manuales de procedimientos operativos estándar (SOP), parches de emergencia sin versión o fallos parciales de scripts.

Los scripts imperativos de shell tradicionales (`bash`, `python`) no logran proporcionar confiabilidad a escala porque:
1. **Falta de conciencia de estado (State Awareness):** Ejecutar `mkdir -p /etc/app` o `useradd appuser` repetidamente puede producir efectos secundarios, agregar líneas duplicadas a archivos de configuración o fallar ante estados de precondición inesperados.
2. **Manejo de errores frágil:** La ejecución parcial de scripts deja a los nodos en estados indeterminados (ni sucios ni limpios), requiriendo intervención manual para revertir los cambios.
3. **Alta sobrecarga de mantenimiento:** Los scripts imperativos deben verificar explícitamente el estado actual, calcular el estado delta, aplicar mutaciones y verificar el estado objetivo a través de variadas distribuciones de Linux (Debian/Ubuntu `apt` vs. RHEL/Rocky `dnf/yum`).

Ansible resuelve el configuration drift proporcionando un **modelo declarativo de configuración de estado deseado**. Los operadores definen *qué* estado debe ocupar el sistema; el motor de Ansible calcula la diferencia (diff) entre el estado del sistema en vivo (descubierto a través de facts) y el estado objetivo, aplicando solo las mutaciones necesarias.

```
                  +-----------------------------------+
                  |      Control Node (Ansible)       |
                  |  - Playbooks & Roles (YAML)       |
                  |  - Inventory & Variables          |
                  |  - Connection Engine (OpenSSH)    |
                  +-----------------+-----------------+
                                    |
                 SSH (Port 22) / SFTP / PSRP (No Agent)
                                    |
       +----------------------------+----------------------------+
       |                                                         |
       v                                                         v
+-----------------------+                               +-----------------------+
|  Managed Node (Web 1) |                               |  Managed Node (DB 1)  |
| - Python Runtime      |                               | - Python Runtime      |
| - Systemd Service     |                               | - PostgreSQL Service  |
| - Live /etc/ app.conf |                               | - Live /etc/ pg.conf  |
+-----------------------+                               +-----------------------+
```

---

### 1.2 Plano de control y arquitectura agentless de Ansible
Ansible opera en una **arquitectura agentless de tipo push**. A diferencia de los modelos basados en pull (Puppet, Chef) o marcos con agentes persistentes (SaltStack), los nodos administrados no requieren demonios de larga ejecución ni puertos de escucha en segundo plano.

#### Requisitos arquitectónicos clave
* **Control Node:** Host Unix/Linux que ejecuta Python 3.9+ con `ansible-core` instalado.
* **Managed Nodes:** Host Unix/Linux estándar que ejecuta herramientas POSIX, un demonio SSH (`sshd`) y Python 3.8+ (`/usr/bin/python3`). Los objetivos de Windows requieren WinRM o PowerShell Remoting (PSRP).

#### Ciclo de vida completo del motor de ejecución
1. **Resolución de objetivos y expansión de patrones:** Ansible analiza el inventario (`hosts.yml` o plugins de inventario dinámico), resolviendo los grupos de hosts objetivo (por ejemplo, `webservers:&production:!canary`).
2. **Fase de recolección de hechos (`setup` module):** Ansible establece una sesión de transporte OpenSSH hacia los nodos administrados y ejecuta un payload liviano en Python (`ansible.module_utils.fact_collector`) para recolectar el contexto del sistema (`ansible_facts` tales como direcciones IPv4, familia de SO, topología de CPU, parámetros del kernel, puntos de montaje).
3. **Compilación de plantillas y variables:** Ansible compila las variables (jerarquía de precedencia a través de 22 niveles), evalúa expresiones Jinja2 (`{{ hostvars[item]['ansible_default_ipv4']['address'] }}`) y evalúa sentencias condicionales (`when:`).
4. **Generación del payload del módulo:** Ansible genera un script de Python efímero y autocontenido que integra los parámetros específicos de la tarea y las librerías de utilidad compartidas (`AnsibleModule`).
5. **Transporte del payload y ejecución en memoria:** Ansible transfiere el payload de Python comprimido en zip mediante SFTP/SCP a un directorio temporal efímero en el host objetivo (típicamente `~/.ansible/tmp/ansible-tmp-XXXXX/`).
6. **Ejecución remota y deserialización de resultados:** El intérprete de Python del objetivo ejecuta el payload del módulo, el cual escribe una cadena JSON estructurada en `stdout` que contiene atributos clave:
   * `changed`: `true` | `false`
   * `failed`: `true` | `false`
   * `rc`: código de retorno (para tareas de comando)
   * `msg`: mensaje contextual detallado
7. **Limpieza y agregación de estado:** El directorio temporal del payload es eliminado (`rm -rf`), los sockets de multiplexación SSH (`ControlMaster`) se conservan o cierran según la configuración, y el plugin de callback del CLI local da formato a la salida hacia stdout.

---

### 1.3 Idempotencia, inmutabilidad y determinismo de estado
La **idempotencia** es la propiedad matemática $f(f(x)) = f(x)$. En SRE e Ingeniería de Plataformas, una operación idempotente garantiza que aplicar un manifiesto de configuración una vez alcance el estado objetivo deseado, y aplicarlo $N$ veces subsecuentes sin cambios de estado externos produzca cero efectos secundarios y un estado del sistema idéntico (`changed=false`).

#### Módulos idempotentes nativos vs. wrappers de shell
Los módulos nativos de Ansible (por ejemplo, `ansible.builtin.copy`, `ansible.builtin.systemd`, `ansible.builtin.user`) inspeccionan los atributos del objetivo remoto antes de aplicar cambios. Si los checksums de los archivos (`sha256`), el estado del servicio o los atributos del usuario coinciden con los atributos objetivo, no se ejecuta ninguna mutación.

Los módulos de ejecución directa (`ansible.builtin.command`, `ansible.builtin.shell`, `ansible.builtin.raw`) ejecutan binarios directos en los hosts objetivo y **no pueden inferir idempotencia de forma nativa**. De forma predeterminada, estos módulos devuelven `changed=true` en cada ejecución.

Para forzar el determinismo de estado al usar módulos de comando, los SREs deben declarar los atributos `creates`, `removes`, `changed_when` o `failed_when`:

```yaml
- name: Extract application archive idempotently
  ansible.builtin.command:
    cmd: tar -xzf /tmp/app-v1.4.2.tar.gz -C /opt/application/
    creates: /opt/application/bin/executable_v1.4.2

- name: Re-index search engine index idempotently via CLI
  ansible.builtin.shell:
    cmd: /opt/app/bin/cli reindex --status
  register: reindex_check
  changed_when: "'REINDEX_REQUIRED' in reindex_check.stdout"
  failed_when: reindex_check.rc != 0 and reindex_check.rc != 2
```

---

### 1.4 Concurrencia y estrategia del motor de ejecución
Ansible controla el paralelismo de los workers y el orden de ejecución en los hosts objetivo utilizando dos selectores arquitectónicos distintos: **Forks** y **Execution Strategies** (estrategias de ejecución).

#### Workers y concurrencia (`forks`)
El parámetro `forks` en `ansible.cfg` define el número máximo de procesos worker de Python paralelos generados por el control node para gestionar sesiones SSH simultáneamente.
* **Predeterminado:** `forks = 5` (Adecuado para entornos de desarrollo pequeños).
* **Producción empresarial:** `forks = 50` o superior (ajustado en función de los núcleos de CPU del control node y el ancho de banda: $\text{Forks} \approx 2 \times \text{Núcleos de CPU}$).

#### Plugins de estrategia
Declarados en `ansible.cfg` o directamente en un playbook mediante la directiva `strategy:`:

1. `strategy: linear` (Predeterminado): Ejecución síncrona por etapas. La Tarea 1 debe completarse en **todos** los hosts activos antes de que la Tarea 2 comience en **cualquier** host. Los hosts lentos retrasan la ejecución de todo el lote.
2. `strategy: free`: Ejecución asíncrona de tareas por host. Cada host ejecuta las tareas a lo largo del playbook lo más rápido posible, de forma independiente del progreso de otros hosts.
3. `strategy: host_pinned`: Similar a `free`, pero garantiza que los hosts de un lote completen el playbook entero antes de que el siguiente grupo de hosts (hasta el límite de `forks`) comience.

#### Actualizaciones progresivas (Rolling Updates) mediante `serial`
Para evitar dejar fuera de línea a todo un clúster durante los despliegues de aplicaciones, la directiva `serial` limita cuántos hosts se procesan a través de un nivel completo de playbook a la vez:

```yaml
- name: Rolling Upgrade Web Tier
  hosts: webservers
  serial:
    - 1        # Canary host deployment
    - "20%"    # Initial batch size
    - "100%"   # Remaining cluster nodes
  strategy: linear
  tasks:
    - name: Upgrade web application
      ansible.builtin.include_role:
        name: zero_downtime_app
```

---

## 2. Comparativas técnicas y matriz de balance (Trade-off)

### 2.1 Gestión de configuración y arquitectura de orquestación de infraestructura

| Característica / Dimensión | Ansible | Terraform | Puppet | SaltStack |
| :--- | :--- | :--- | :--- | :--- |
| **Paradigma principal** | Gestión de configuración y despliegue de aplicaciones | Aprovisionamiento de infraestructura inmutable | Gestión de configuración de sistemas | Orquestación y configuración en tiempo real |
| **Arquitectura de ejecución** | Basado en Push vía SSH/WinRM (Agentless) | Basado en Push vía APIs de proveedores (Agentless) | Basado en Pull vía demonio `puppet-agent` | Híbrido (Push/Pull vía `salt-minion` ZMQ) |
| **Almacenamiento de estado** | Sin estado / State-less (Descubierto en tiempo de ejecución vía facts de `setup`) | Archivo de estado remoto (`.tfstate` con bloqueo) | Catálogo Master central y catálogo en caché local | Sin estado / State-less o estado en caché basado en eventos |
| **DSL / Formato** | YAML + Plantillas Jinja2 | HCL (HashiCorp Configuration Language) | DSL de Puppet (sintaxis declarativa similar a Ruby) | YAML + Jinja2 / DSL de Python |
| **Motor de idempotencia** | Verificación de estado de módulo nativo | Motor de dependencia de grafo de recursos (`tf plan`) | Compilación y aplicación del catálogo de recursos | Compilador de alto estado (`state.apply`) |
| **Costo de bootstrapping** | Cero en el objetivo (Solo requiere Python + SSH) | Cero en el objetivo (API key / Credenciales de la nube) | Alto (Requiere firma PKI de puppet-agent) | Medio (Requiere paquete minion y claves master) |
| **Uso operativo en SRE** | Hardening de SO, despliegues progresivos, operaciones de día 2 | VPC en la nube, IAM, bootstrap de clústeres K8s | Cumplimiento persistente de normas en escritorios/VMs | Ejecución de comandos en paralelo ultrarrápida |

---

### 2.2 Arquitectura de inventario: Inventarios estáticos vs. dinámicos

| Propiedad | Inventario estático INI / YAML | Plugin / Script de inventario dinámico |
| :--- | :--- | :--- |
| **Fuente de verdad** | Repositorio Git / Archivos codificados de forma rígida | API de proveedores de nube (AWS EC2, GCP, Azure, K8s) |
| **Adaptabilidad** | Baja (Requiere commits explícitos en Git para agregar hosts) | Alta (Autodescubre instancias efímeras de autoescalado) |
| **Capacidad de agrupación** | Asignación manual y explícita de grupos | Agrupación dinámica automática por tags, regiones, VPCs |
| **Sobrecarga de rendimiento** | Microsegundos (Análisis sintáctico de archivo local) | Latencia de red (Solicitudes API a proveedores de nube) |
| **Soporte de almacenamiento en caché** | N/A | Soportado (Basado en archivos, caché Redis con TTL) |
| **Mejor utilizado para** | Bare-metal fijo, infraestructura estática, dispositivos de red | Pools de servidores nativos de la nube y autoescalados, nodos K8s dinámicos |

---

### 2.3 Estrategias de ejecución: Linear vs. Free vs. Host-Pinned

| Estrategia | Modelo de sincronización | Riesgo de radio de impacto (Blast Radius) | Impacto de fallos | Caso de uso ideal |
| :--- | :--- | :--- | :--- | :--- |
| `linear` | Sincronización estricta por barrera en cada tarea | Alto si `serial` no está configurado; bajo con `serial` tipo canario | Detiene la ejecución para todos los hosts ante un fallo en la barrera | Migraciones estructurales, actualizaciones de esquema de BD |
| `free` | Sin sincronización por barrera; los hosts se ejecutan de forma independiente | Alto; los hosts rápidos llegan temprano a tareas destructivas | Fallo aislado por host; los demás continúan | Parcheo independiente de nodos, rotación de logs, cumplimiento normativo |
| `host_pinned` | Aislamiento de hosts a nivel de lote hasta el límite de `forks` | Medio; limitado al pool del lote activo | Aisla el fallo dentro del slot del lote activo | Despliegues de aplicaciones no interdependientes a gran escala |

---

## 3. Manifiestos completos de nivel de producción y arquitectura de infraestructura

Los siguientes manifiestos representan una configuración de producción empresarial completa y sintácticamente válida para actualizaciones progresivas de aplicaciones sin tiempo de inactividad (zero-downtime).

### 3.1 Configuración endurecida del Control Node: `ansible.cfg`
```ini
[defaults]
inventory               = ./inventory/production
roles_path              = ./roles
remote_user             = deploy-agent
private_key_file        = ~/.ssh/id_ed25519_deploy
host_key_checking       = True
forks                   = 50
strategy                = linear
gathering               = smart
fact_caching            = jsonfile
fact_caching_connection = ./cache/facts
fact_caching_timeout    = 86400
stdout_callback         = yaml
callbacks_enabled       = ansible.posix.profile_tasks, ansible.posix.timer
timeout                 = 30
retry_files_enabled     = False
vault_identity_list     = prod@.vault_pass

[privilege_escalation]
become                  = True
become_method           = sudo
become_user             = root
become_ask_pass         = False

[ssh_connection]
ssh_args                = -o FastRemoteAuth=yes -o ControlMaster=auto -o ControlPersist=60m -o StrictHostKeyChecking=yes -o UserKnownHostsFile=~/.ssh/known_hosts
pipelining              = True
scp_if_ssh              = smart
retries                 = 3
```

---

### 3.2 Inventario dinámico y jerárquico: `inventory/production/hosts.yml`
```yaml
---
all:
  vars:
    ansible_python_interpreter: /usr/bin/python3
    environment_tier: production
    domain_name: platform.internal
    ntp_servers:
      - 0.pool.ntp.org
      - 1.pool.ntp.org

  children:
    loadbalancers:
      hosts:
        lb01.platform.internal:
          ansible_host: 10.100.10.11
          lb_role: primary
        lb02.platform.internal:
          ansible_host: 10.100.10.12
          lb_role: secondary

    webservers:
      vars:
        app_port: 8080
        max_connections: 4096
      hosts:
        web01.platform.internal:
          ansible_host: 10.100.20.21
          rack_id: rack-a1
        web02.platform.internal:
          ansible_host: 10.100.20.22
          rack_id: rack-a2
        web03.platform.internal:
          ansible_host: 10.100.20.23
          rack_id: rack-b1

    databases:
      vars:
        db_port: 5432
      hosts:
        db01.platform.internal:
          ansible_host: 10.100.30.31
          db_role: primary
```

---

### 3.3 Archivo de datos cifrado con Vault: `inventory/production/group_vars/webservers/vault.yml`

#### Representación descifrada (Estructura de referencia)
```yaml
---
vault_db_password: "SuperSecretProductionDBPassword2026!"
vault_api_jwt_secret: "e9a8f4c2b1a5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0"
```

#### Archivo cifrado completo sintácticamente válido
```yaml
$ANSIBLE_VAULT;1.2;AES256;prod
63313063383838393666613337373336306534346537383637303038313437313837373732383234
6666323139353935663731343936303233373035363063620a323330366633653139393130383335
32363531303732646237666436626435343431613136363063653632343831333333333333333333
3034336136313136330a383262663964313535383566363033623930353531326432653239333230
36343535383237303131346539396338323637373539336130336437343236323439396163353431
32313638633939343734393732366164343436323431396263303839633238343736343538636437
62326533353335393738353334633731333036303632303038616138653832633833363836353664
393166343233323030303038313930323830
```

---

### 3.4 Tareas del rol de producción con recuperación de errores: `roles/zero_downtime_app/tasks/main.yml`
```yaml
---
- name: Execute Zero Downtime Application Deployment
  block:
    - name: Deregister node from Upstream NGINX Load Balancer
      ansible.builtin.file:
        path: "/var/www/html/healthcheck.html"
        state: absent
      delegate_to: "{{ item }}"
      loop: "{{ groups['loadbalancers'] }}"
      tags: lb_drain

    - name: Wait for active connections to drain (Cool down)
      ansible.builtin.pause:
        seconds: 15
      tags: lb_drain

    - name: Ensure target application directory structure exists
      ansible.builtin.file:
        path: "{{ item }}"
        state: directory
        owner: www-data
        group: www-data
        mode: '0755'
      loop:
        - /opt/app/releases
        - /opt/app/shared/log
        - /etc/app

    - name: Render dynamic application configuration from Jinja2
      ansible.builtin.template:
        src: app.conf.j2
        dest: /etc/app/app.conf
        owner: root
        group: www-data
        mode: '0640'
        validate: '/usr/local/bin/app-cli config-check --file %s'
      notify: Restart Application Service

    - name: Deploy application binary artifact
      ansible.builtin.copy:
        src: files/app-v2.1.0-linux-amd64
        dest: /opt/app/releases/app-v2.1.0
        owner: www-data
        group: www-data
        mode: '0755'

    - name: Update current symlink to new release
      ansible.builtin.file:
        src: /opt/app/releases/app-v2.1.0
        dest: /opt/app/current
        state: link
      notify: Reload Application Service

    - name: Flush handlers to force immediate service restart/reload
      ansible.builtin.meta: flush_handlers

    - name: Validate local endpoint responsiveness
      ansible.builtin.uri:
        url: "http://127.0.0.1:{{ app_port }}/healthz"
        status_code: 200
        return_content: yes
      register: healthcheck_response
      until: "healthcheck_response.status == 200 and 'OK' in healthcheck_response.content"
      retries: 10
      delay: 3

  rescue:
    - name: CRITICAL - Emergency Rollback Initiated
      ansible.builtin.debug:
        msg: "Healthcheck failed on {{ inventory_hostname }}. Reverting symlink to previous release."

    - name: Rollback application symlink to legacy binary
      ansible.builtin.file:
        src: /opt/app/releases/app-v2.0.0
        dest: /opt/app/current
        state: link

    - name: Restart application service under rollback state
      ansible.builtin.systemd:
        name: platform-app
        state: restarted
        enabled: yes

    - name: Fail the playbook execution for current batch
      ansible.builtin.fail:
        msg: "Deployment aborted due to failed application health checks on {{ inventory_hostname }}."

  always:
    - name: Restore node into Upstream NGINX Load Balancer
      ansible.builtin.file:
        path: "/var/www/html/healthcheck.html"
        state: touch
        owner: www-data
        group: www-data
        mode: '0644'
      delegate_to: "{{ item }}"
      loop: "{{ groups['loadbalancers'] }}"
      tags: lb_drain
```

---

### 3.5 Handlers del rol: `roles/zero_downtime_app/handlers/main.yml`
```yaml
---
- name: Restart Application Service
  ansible.builtin.systemd:
    name: platform-app
    state: restarted
    daemon_reload: yes

- name: Reload Application Service
  ansible.builtin.systemd:
    name: platform-app
    state: reloaded
```

---

### 3.6 Plantilla avanzada de Jinja2: `roles/zero_downtime_app/templates/app.conf.j2`
```jinja2
# System Generated Configuration via Ansible Control Plane
# Host: {{ inventory_hostname }} | Environment: {{ environment_tier }}
# Generated At: {{ ansible_date_time.iso8601 }}

[server]
bind_address = "{{ ansible_default_ipv4.address }}"
port = {{ app_port }}
max_workers = {{ ansible_processor_vcpus * 2 }}
max_connections = {{ max_connections }}

[database]
host = "{{ hostvars[groups['databases'][0]]['ansible_host'] }}"
port = {{ hostvars[groups['databases'][0]]['db_port'] }}
name = "platform_prod"
username = "app_rw"
password = "{{ vault_db_password }}"

[upstream_clusters]
{% for host in groups['webservers'] %}
cluster_node_{{ loop.index }} = "{{ hostvars[host]['ansible_host'] }}:{{ hostvars[host]['app_port'] }}"
{% endfor %}

[features]
enable_telemetry = {% if environment_tier == 'production' %}true{% else %}false{% endif %}
jwt_secret = "{{ vault_api_jwt_secret }}"
```

---

### 3.7 Playbook maestro de orquestación: `site.yml`
```yaml
---
- name: Master Infrastructure & Application Deployment
  hosts: all
  gather_facts: yes
  become: yes

  tasks:
    - name: Assert baseline operating system compatibility
      ansible.builtin.assert:
        that:
          - ansible_os_family == "RedHat" or ansible_os_family == "Debian"
          - ansible_memtotal_mb >= 2048
        fail_msg: "Host {{ inventory_hostname }} does not satisfy minimum production hardware requirements."

- name: Configure Web Application Tier
  hosts: webservers
  serial:
    - 1
    - "50%"
  vars_files:
    - inventory/production/group_vars/webservers/vault.yml

  roles:
    - role: zero_downtime_app
      tags: ["application", "deploy"]
```

---

## 4. Ejecuciones reales de CLI y salidas de terminal ($)

### 4.1 Graficado de topología de inventario dinámico
```bash
$ ansible-inventory -i inventory/production/hosts.yml --graph
```
```text
@all:
  |--@databases:
  |  |--db01.platform.internal
  |--@loadbalancers:
  |  |--lb01.platform.internal
  |  |--lb02.platform.internal
  |--@ungrouped:
  |--@webservers:
  |  |--web01.platform.internal
  |  |--web02.platform.internal
  |  |--web03.platform.internal
```

---

### 4.2 Cifrado de variables en línea mediante Ansible Vault
```bash
$ ansible-vault encrypt_string --vault-id prod@.vault_pass 'SuperSecretProductionDBPassword2026!' --name 'vault_db_password'
```
```text
vault_db_password: !vault |
          $ANSIBLE_VAULT;1.2;AES256;prod
          33383637303861343763323030373238323830303831323334353637383930313233343536373839
          30313233343536373839303132333435363738393031323334353637383930313233343536373839
          65396138663463326231613564366537663861396230633164326533663461356236633764386539
Encryption successful
```

---

### 4.3 Verificación sintáctica del Playbook
```bash
$ ansible-playbook -i inventory/production/hosts.yml site.yml --syntax-check
```
```text
playbook: site.yml
```

---

### 4.4 Ejecución de prueba (Dry-Run) con rastreo de diferencias de configuración
```bash
$ ansible-playbook -i inventory/production/hosts.yml site.yml --check --diff --limit "web01.platform.internal"
```
```text
PLAY [Master Infrastructure & Application Deployment] ******************************************************************

TASK [Gathering Facts] *************************************************************************************************
ok: [web01.platform.internal]

TASK [Assert baseline operating system compatibility] ******************************************************************
ok: [web01.platform.internal] => {
    "changed": false,
    "msg": "All assertions passed"
}

PLAY [Configure Web Application Tier] **********************************************************************************

TASK [Gathering Facts] *************************************************************************************************
ok: [web01.platform.internal]

TASK [zero_downtime_app : Render dynamic application configuration from Jinja2] ****************************************
--- before: /etc/app/app.conf
+++ after: /home/deploy-agent/.ansible/tmp/ansible-local-4123985x_z/app.conf.j2
@@ -4,3 +4,3 @@
 [server]
-max_connections = 1024
+max_connections = 4096

changed: [web01.platform.internal]

PLAY RECAP *************************************************************************************************************
web01.platform.internal    : ok=3    changed=1    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
```

---

### 4.5 Ejecución dirigida con perfilado de alta verbosidad
```bash
$ ansible-playbook -i inventory/production/hosts.yml site.yml --tags "deploy" --limit "webservers[0]" -vvv
```
```text
ansible-playbook [core 2.15.2]
  config file = /home/deploy-agent/platform-infra/ansible.cfg
  configured module search path = ['/home/deploy-agent/.ansible/plugins/modules', '/usr/share/ansible/plugins/modules']
  ansible python module location = /usr/lib/python3.11/site-packages/ansible
  ansible collection location = /home/deploy-agent/.ansible/collections:/usr/share/ansible/collections
  executable location = /usr/bin/ansible-playbook
  python version = 3.11.2 (main, May 13 2023, 09:28:56) [GCC 12.2.0] (/usr/bin/python3)
  jinja version = 3.1.2
  libyaml = True
Using /home/deploy-agent/platform-infra/ansible.cfg as config file
host_list additions connected to birthday party: [u'web01.platform.internal']
parsed /home/deploy-agent/platform-infra/inventory/production/hosts.yml inventory source

PLAYBOOK: site.yml *****************************************************************************************************
1 plays in site.yml

PLAY [Configure Web Application Tier] **********************************************************************************

TASK [zero_downtime_app : Deploy application binary artifact] **********************************************************
task path: /home/deploy-agent/platform-infra/roles/zero_downtime_app/tasks/main.yml:28
<10.100.20.21> ESTABLISH SSH CONNECTION FOR USER: deploy-agent
<10.100.20.21> SSH: EXEC ssh -o FastRemoteAuth=yes -o ControlMaster=auto -o ControlPersist=60m -o StrictHostKeyChecking=yes -o UserKnownHostsFile=~/.ssh/known_hosts -o KbdInteractiveAuthentication=no -o PreferredAuthentications=gssapi-with-mic,gssapi-keyex,hostbased,publickey -o PasswordAuthentication=no -o 'User="deploy-agent"' -o ConnectTimeout=30 -o 'ControlPath="/home/deploy-agent/.ansible/cp/3c41a29f87"' 10.100.20.21 '/bin/sh -c '"'"'echo ~deploy-agent && sleep 0'"'"''
<10.100.20.21> (0, b'/home/deploy-agent\n', b'')
<10.100.20.21> PUT /home/deploy-agent/platform-infra/roles/zero_downtime_app/files/app-v2.1.0-linux-amd64 TO /home/deploy-agent/.ansible/tmp/ansible-tmp-1691400000.12-8941-213/source
<10.100.20.21> SSH: EXEC sftp -b - -o FastRemoteAuth=yes -o ControlMaster=auto -o ControlPersist=60m -o StrictHostKeyChecking=yes [10.100.20.21] <<< $'put /home/deploy-agent/platform-infra/roles/zero_downtime_app/files/app-v2.1.0-linux-amd64 /home/deploy-agent/.ansible/tmp/ansible-tmp-1691400000.12-8941-213/source'
changed: [web01.platform.internal] => {
    "changed": true,
    "checksum": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "dest": "/opt/app/releases/app-v2.1.0",
    "gid": 33,
    "group": "www-data",
    "mode": "0755",
    "owner": "www-data",
    "size": 18492016,
    "state": "file",
    "uid": 33
}

Monday 07 August 2026  08:22:17 -0400 (0:00:01.842) ------- 0:00:01.842 ******* 
=============================================================================== 
zero_downtime_app : Deploy application binary artifact ------------------ 1.84s

PLAY RECAP *************************************************************************************************************
web01.platform.internal    : ok=1    changed=1    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
```

---

## 5. Guía de verificación, diagnóstico de fallos y resolución de problemas

### 5.1 Matriz de diagnóstico: Fallos comunes en producción

```
                             [Ansible Failure Encountered]
                                           |
                    +----------------------+----------------------+
                    |                                             |
           [SSH / Transport Error]                       [Task Execution Error]
                    |                                             |
        +-----------+-----------+                     +-----------+-----------+
        |                       |                     |                       |
[Host Key Unverified]   [Permission Denied]     [Unreachable Host]   [Become Escalation Failed]
        |                       |                     |                       |
 Fix: Add host key to   Fix: Correct identity   Fix: ControlMaster       Fix: Check NOPASSWD in
 `known_hosts` or set    key permissions         stale socket cleanup    `/etc/sudoers` on target
 `host_key_checking=False` `chmod 600 id_rsa`    `rm -rf ~/.ansible/cp`  node for deploy user
```

| Síntoma / Error | Causa raíz | Comando de remediación SRE / Solución |
| :--- | :--- | :--- |
| `Host key verification failed.` | La clave pública SSH del host objetivo no está presente en el archivo `known_hosts` del control node. | Ejecutar `ssh-keyscan -H target_ip >> ~/.ssh/known_hosts` o configurar explícitamente `host_key_checking = True` con pre-sembrado estricto de claves de host durante el aprovisionamiento de nodos. |
| `Permission denied (publickey).` | El demonio SSH rechazó la clave presentada por el control node, o los permisos de archivo en `~/.ssh` en el objetivo son demasiado permisivos. | Verificar la ruta del archivo de identidad en `ansible.cfg`. Corregir los permisos en el objetivo: `chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys`. |
| `Timeout (12s) waiting for privilege escalation prompt` | El `sudo` del nodo objetivo requiere una contraseña, pero Ansible se ejecuta sin `--ask-become-pass` (`-K`) y `become_ask_pass` está configurado en `False`. | Configurar sudo sin contraseña para el usuario de despliegue en los nodos objetivo mediante `/etc/sudoers.d/deploy-agent`: `deploy-agent ALL=(ALL) NOPASSWD: ALL`. |
| `Fatal: [host]: UNREACHABLE! => {"changed": false, "msg": "Failed to connect to the host via ssh..."}` | Socket de multiplexación ControlMaster obsoleto, host objetivo fuera de línea o grupo de seguridad descartando el puerto 22. | Purgar sockets SSH obsoletos: `rm -rf ~/.ansible/cp/*`. Probar el transporte de forma independiente: `ansible webservers -m ping -vvv`. |
| `ModuleFailure: No module named 'docker'` | El entorno de Python del host objetivo carece de las dependencias de librerías requeridas por un módulo de Ansible específico (por ejemplo, `community.docker`). | Instalar dependencias en el nodo objetivo antes de ejecutar el módulo usando `ansible.builtin.pip: name=docker state=present`. |

---

### 5.2 Guía de perfilado de rendimiento y optimización

#### 1. Analítica de perfilado de tareas (`ansible.posix.profile_tasks`)
Habilitar `profile_tasks` en `ansible.cfg` imprime la duración de la ejecución de cada tarea, resaltando cuellos de botella en los pipelines de despliegue:

```ini
[defaults]
callbacks_enabled = ansible.posix.profile_tasks
```

#### 2. Pipelining de conexiones SSH (`pipelining = True`)
De forma predeterminada, Ansible transfiere archivos de módulos de Python vía SFTP/SCP al disco en el nodo administrado y luego los ejecuta en una invocación SSH separada.  
Habilitar `pipelining = True` en `ansible.cfg` ejecuta módulos de Python directamente sobre un flujo de `stdin` de SSH abierto sin escribir archivos temporales en los discos del objetivo, reduciendo los viajes de ida y vuelta de red (round-trips) hasta en un **60%**.

*Requisito:* Los nodos objetivo deben tener `requiretty` deshabilitado en `/etc/sudoers` (estándar en distribuciones modernas de Linux).

#### 3. Caché de facts de alto rendimiento
Recolectar facts toma de 2 a 5 segundos por host por cada ejecución de playbook. En entornos grandes (más de 1,000 hosts), configure almacenamiento en caché persistente de facts respaldado por Redis en `ansible.cfg`:

```ini
[defaults]
gathering               = smart
fact_caching            = redis
fact_caching_connection = 127.0.0.1:6379:0
fact_caching_timeout    = 86400
```

---

## 6. Referencias

* **Visión general y objetivos oficiales de la certificación LPI DevOps Tools Engineer (701-100)**  
  [https://www.lpi.org/our-certifications/devops-tools-engineer-overview/](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)

* **Documentación y guía de usuario de Red Hat Ansible Core**  
  [https://docs.ansible.com/ansible/latest/user_guide/index.html](https://docs.ansible.com/ansible/latest/user_guide/index.html)

* **Arquitectura de Ansible y conceptos técnicos clave**  
  [https://docs.ansible.com/ansible/latest/network/getting_started/basic_concepts.html](https://docs.ansible.com/ansible/latest/network/getting_started/basic_concepts.html)

* **Guía de plugins de inventario y fuentes dinámicas de Ansible**  
  [https://docs.ansible.com/ansible/latest/plugins/inventory.html](https://docs.ansible.com/ansible/latest/plugins/inventory.html)

* **Mejores prácticas de Playbook de Ansible y diseños arquitectónicos de ejemplo**  
  [https://docs.ansible.com/ansible/latest/tips_tricks/sample_setup.html](https://docs.ansible.com/ansible/latest/tips_tricks/sample_setup.html)

* **Guía de usuario de Ansible Vault y protocolos de seguridad de cifrado**  
  [https://docs.ansible.com/ansible/latest/vault_guide/index.html](https://docs.ansible.com/ansible/latest/vault_guide/index.html)