# LPI DevOps Tools Engineer (Exam 701-100) — Tema 4.1: Guía de Producción Avanzada y Ejercicios de Laboratorio de Ansible

**Certificación Objetivo:** LPI DevOps Tools Engineer (Exam 701-100, Versión 1.0)  
**Tema 4.1:** Gestión de Configuración con Ansible  
**Peso:** 13.33  
**Referencias Oficiales:**
* LPI DevOps Certification Overview: [https://www.lpi.org/our-certifications/devops-tools-engineer-overview/](https://www.lpi.org/our-certifications/devops-tools-engineer-overview/)
* Arquitectura del Motor Core de Ansible: [https://docs.ansible.com/ansible/latest/reference_manual/architecture.html](https://docs.ansible.com/ansible/latest/reference_manual/architecture.html)
* Diseño de Inventario de Ansible: [https://docs.ansible.com/ansible/latest/inventory_guide/intro_inventory.html](https://docs.ansible.com/ansible/latest/inventory_guide/intro_inventory.html)
* Guía de Ansible Vault: [https://docs.ansible.com/ansible/latest/vault_guide/index.html](https://docs.ansible.com/ansible/latest/vault_guide/index.html)
* Roles y Reutilización en Ansible: [https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_reuse_roles.html](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_reuse_roles.html)

---

## 1. Arquitectura Técnica Profunda y Mecánica Interna

### 1.1 Arquitectura y Motor de Ejecución Remota
Ansible opera sobre una **arquitectura sin agentes (agentless) basada en empuje (push-based)**. A diferencia de los modelos basados en agentes (como Puppet o Chef) que requieren un demonio cliente persistente en los nodos administrados, Ansible se apoya en protocolos de red estándar—principalmente **OpenSSH** para Linux/Unix y **WinRM/PSRP** para Windows.

```
+-------------------------------------------------------------------------+
|                           CONTROL NODE                                  |
|                                                                         |
|  +-------------------+   +--------------------+   +------------------+  |
|  | Ansible Playbook  | --> | Jinja2 & Core Engine| --> | Module Execution |  |
|  +-------------------+   +--------------------+   |  Payload Builder |  |
|                                                   +--------+---------+  |
+------------------------------------------------------------|------------+
                                                             | (SFTP/SCP)
                                                             v
+-------------------------------------------------------------------------+
|                            MANAGED NODE                                 |
|                                                                         |
|  1. Write payload to transient path: ~/.ansible/tmp/ansible-tmp-XXX/   |
|  2. Execute Python interpreter: /usr/bin/python3 payload.py             |
|  3. Return JSON response payload via stdout over SSH                    |
|  4. Delete transient directory (or retain if ANSIBLE_KEEP_REMOTE_FILES=1)|
+-------------------------------------------------------------------------+
```

#### Secuencia del Ciclo de Vida de Ejecución
1. **Análisis del Inventario y Resolución de Configuración**: Ansible carga la configuración siguiendo una jerarquía de precedencia estricta (`ANSIBLE_CONFIG` env var > `./ansible.cfg` > `~/.ansible.cfg` > `/etc/ansible/ansible.cfg`).
2. **Recolección de Facts (módulo `setup`)**: Si `gather_facts: true`, Ansible genera un payload de Python efímero, lo transfiere vía SFTP/SCP al directorio temporal del objetivo (`~/.ansible/tmp/ansible-tmp-*`), lo ejecuta y lee la telemetría del sistema en formato JSON (`ansible_facts`).
3. **Generación del Payload del Módulo**: Para cada tarea, Ansible empaqueta el código del módulo, las especificaciones de argumentos y las dependencias internas (como `ansible.module_utils.basic`) en un solo archivo Python comprimido en ZIP (un archivo ZIP wrapper que contiene `#!/usr/bin/python`).
4. **Transporte SSH y Multiplexación**: Las conexiones utilizan pooling de conexiones SSH (`ControlMaster=auto -o ControlPersist=60s`) para reducir drásticamente el overhead de negociación (handshaking) a lo largo de las ejecuciones serializadas o en paralelo de los plays.
5. **Ejecución y Limpieza**: El nodo remoto ejecuta el payload independiente utilizando el intérprete de Python remoto (`ansible_python_interpreter`), emite una respuesta JSON estructurada a `stdout` y elimina el directorio temporal remoto.

### 1.2 Compromisos de Arquitectura (Trade-Offs)

| Característica de Arquitectura | Ventajas | Compromisos y Riesgos en Producción |
| :--- | :--- | :--- |
| **Agentless (SSH/Python)** | Baja huella operacional; sin overhead de memoria por demonios; cero necesidad de bootstrapping remoto. | Alto overhead de conexión SSH a escala (>1,000 nodos); sensible al rate-limiting de SSH (`MaxStartups`). Requiere Python en los hosts administrados. |
| **Control Push-Based** | Control inmediato de la ejecución; sin esperar a intervalos de pull del cliente; fácil integración con CI/CD. | El nodo de control es un punto único de falla (SPOF) durante los despliegues; las particiones de red interrumpen la ejecución a mitad de camino. |
| **Idempotencia Declarativa** | Las tareas declaran el estado deseado en lugar de pasos; es seguro volver a ejecutar los playbooks múltiples veces sin deriva de estado no deseada. | Las sobreescrituras imperativas (ej. `command`, `shell`) omiten la idempotencia a menos que se gestionen explícitamente mediante `changed_when` / `creates`. |

---

## 2. Ejercicios Guiados de Producción

---

### Ejercicio Guiado 1: Jerarquía de Inventario Multientorno y Precedencia de Variables

#### Escenario
Estás diseñando una estrategia de gestión de configuración en producción para una Plataforma E-Commerce Empresarial. La arquitectura segrega la infraestructura en entornos de `staging` y `production` utilizando inventarios estáticos INI/YAML combinados con `group_vars` y `host_vars` jerárquicos.

#### Paso 1: Crear la Estructura de Directorios del Proyecto
Ejecutá los siguientes comandos en tu nodo de control:

```bash
mkdir -p enterprise_ansible/inventory/{staging,production}/group_vars
mkdir -p enterprise_ansible/inventory/{staging,production}/host_vars
cd enterprise_ansible
```

#### Paso 2: Definir Inventarios de Staging y Producción
Creá el inventario de producción en `inventory/production/hosts.yml`:

```yaml
---
all:
  children:
    webservers:
      hosts:
        web-prod-01.internal.net:
          ansible_host: 192.168.10.11
        web-prod-02.internal.net:
          ansible_host: 192.168.10.12
    dbservers:
      hosts:
        db-prod-01.internal.net:
          ansible_host: 192.168.10.21
  vars:
    ansible_user: deploy_admin
    ansible_port: 22
```

Creá el inventario de staging en `inventory/staging/hosts.ini`:

```ini
[webservers]
web-stage-01.internal.net ansible_host=172.16.10.11

[dbservers]
db-stage-01.internal.net ansible_host=172.16.10.21

[all:vars]
ansible_user=stage_admin
ansible_port=2222
```

#### Paso 3: Configurar Variables Específicas del Entorno (`group_vars`)
Creá `inventory/production/group_vars/webservers.yml`:

```yaml
---
http_port: 443
max_clients: 500
enable_debug: false
db_endpoint: "db-prod-01.internal.net"
```

Creá `inventory/staging/group_vars/webservers.yml`:

```yaml
---
http_port: 8080
max_clients: 50
enable_debug: true
db_endpoint: "db-stage-01.internal.net"
```

#### Paso 4: Validar la Estructura del Inventario vía CLI
Ejecutá `ansible-inventory` para inspeccionar la salida del grafo unificado para producción:

```bash
ansible-inventory -i inventory/production/hosts.yml --graph
```

##### Salida Esperada:
```text
@all:
  |--@dbservers:
  |  |--db-prod-01.internal.net
  |--@ungrouped:
  |--@webservers:
  |  |--web-prod-01.internal.net
  |  |--web-prod-02.internal.net
```

Ejecutá `ansible-inventory` para volcar la resolución de variables para un host específico de producción:

```bash
ansible-inventory -i inventory/production/hosts.yml --host web-prod-01.internal.net
```

##### Salida Esperada:
```json
{
    "ansible_host": "192.168.10.11",
    "ansible_port": 22,
    "ansible_user": "deploy_admin",
    "db_endpoint": "db-prod-01.internal.net",
    "enable_debug": false,
    "http_port": 443,
    "max_clients": 500
}
```

---

#### Preguntas de Verificación — Ejercicio 1

1. **Pregunta 1.1**: Si una variable `http_port: 80` está definida en `inventory/production/group_vars/all.yml` y `http_port: 443` está definida en `inventory/production/group_vars/webservers.yml`, ¿qué valor se aplicará a `web-prod-01.internal.net` y por qué?
2. **Pregunta 1.2**: En la precedencia de variables de Ansible, ¿en qué lugar se ubica una variable definida dentro del bloque `vars:` de una tarea de playbook en comparación con las variables configuradas dentro de archivos `host_vars`?

---

### Ejercicio Guiado 2: Playbooks Avanzados, Plantillas Jinja2 y Flujo de Control

#### Escenario
Debés escribir un playbook de grado de producción completamente idempotente que despliegue NGINX con configuración dinámica de virtual host, ejecución de handlers personalizados, lógica condicional compleja (`when`), registro de estado (`register`), controles de bucle (`loop_control`) y manejo de fallas (`block`/`rescue`).

#### Paso 1: Crear la Configuración del Motor `ansible.cfg`
Creá `ansible.cfg` en la raíz del proyecto para hacer cumplir un comportamiento operacional estricto:

```ini
[defaults]
inventory = ./inventory/production/hosts.yml
remote_user = deploy_admin
host_key_checking = False
stdout_callback = yaml
callbacks_enabled = timer, profile_tasks
forks = 10

[privilege_escalation]
become = True
become_method = sudo
become_user = root
become_ask_pass = False
```

#### Paso 2: Escribir la Plantilla Dinámica Jinja2
Creá `templates/nginx_vhost.conf.j2`:

```jinja2
# Generated by Ansible - DO NOT EDIT MANUALLY
# Host: {{ inventory_hostname }}
# Environment: {{ env_name | default('production') }}

server {
    listen {{ http_port | mandatory }};
    server_name {{ ansible_fqdn | default(inventory_hostname) }};

    access_log /var/log/nginx/{{ inventory_hostname }}_access.log;
    error_log /var/log/nginx/{{ inventory_hostname }}_error.log;

    location / {
        proxy_pass http://{{ db_endpoint }}:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_connect_timeout 5s;
        proxy_read_timeout 60s;
    }

{% if enable_debug %}
    location /stub_status {
        stub_status on;
        allow 127.0.0.1;
        deny all;
    }
{% endif %}
}
```

#### Paso 3: Escribir el Playbook Completo de Ansible
Creá `site_webserver.yml`:

```yaml
---
- name: Deploy and Configure NGINX Web Tier
  hosts: webservers
  gather_facts: true
  vars:
    env_name: production
    required_packages:
      - nginx
      - curl
      - ufw

  handlers:
    - name: Reload Nginx Service
      ansible.builtin.systemd:
        name: nginx
        state: reloaded
      listen: "trigger_nginx_reload"

    - name: Restart Nginx Service
      ansible.builtin.systemd:
        name: nginx
        state: restarted
      listen: "trigger_nginx_restart"

  tasks:
    - name: Robust Package Installation with Rescue Fallback
      block:
        - name: Install required baseline packages
          ansible.builtin.apt:
            name: "{{ item }}"
            state: present
            update_cache: true
          loop: "{{ required_packages }}"
          loop_control:
            label: "Package: {{ item }}"
      rescue:
        - name: Log package installation error
          ansible.builtin.debug:
            msg: "APT installation failed. Attempting repository repair."

        - name: Fix broken APT dependencies
          ansible.builtin.command: apt-get install -f -y
          changed_when: true

        - name: Retry package installation
          ansible.builtin.apt:
            name: "{{ required_packages }}"
            state: present

    - name: Generate Virtual Host Configuration
      ansible.builtin.template:
        src: templates/nginx_vhost.conf.j2
        dest: /etc/nginx/sites-available/app_vhost.conf
        owner: root
        group: root
        mode: '0644'
        validate: '/usr/sbin/nginx -t -c /etc/nginx/nginx.conf'
      notify: "trigger_nginx_reload"

    - name: Enable Virtual Host Symlink
      ansible.builtin.file:
        src: /etc/nginx/sites-available/app_vhost.conf
        dest: /etc/nginx/sites-enabled/app_vhost.conf
        state: link
      notify: "trigger_nginx_reload"

    - name: Check NGINX Syntax Integrity
      ansible.builtin.command: nginx -t
      register: nginx_check
      changed_when: false
      failed_when: nginx_check.rc != 0

    - name: Ensure NGINX is Enabled and Started
      ansible.builtin.systemd:
        name: nginx
        enabled: true
        state: started
```

#### Paso 4: Ejecutar Verificaciones de Sintaxis y Ejecución Dry-Run
Realizá la validación de sintaxis:

```bash
ansible-playbook site_webserver.yml --syntax-check
```

##### Salida Esperada:
```text
playbook: site_webserver.yml
```

Realizá una ejecución dry-run (modo `--check`) mostrando las diferencias (diff):

```bash
ansible-playbook site_webserver.yml --check --diff -i inventory/staging/hosts.ini
```

##### Salida Esperada (Truncada):
```text
PLAY [Deploy and Configure NGINX Web Tier] *************************************************

TASK [Gathering Facts] *********************************************************************
ok: [web-stage-01.internal.net]

TASK [Install required baseline packages] **************************************************
ok: [web-stage-01.internal.net] => (item=Package: nginx)
ok: [web-stage-01.internal.net] => (item=Package: curl)
ok: [web-stage-01.internal.net] => (item=Package: ufw)

TASK [Generate Virtual Host Configuration] *************************************************
--- before
+++ after: /home/deploy/enterprise_ansible/templates/nginx_vhost.conf.j2
@@ -0,0 +1,21 @@
+# Generated by Ansible - DO NOT EDIT MANUALLY
+# Host: web-stage-01.internal.net
+# Environment: production
+
+server {
+    listen 8080;
+    server_name web-stage-01.internal.net;
+...
changed: [web-stage-01.internal.net]

RUNNING HANDLER [Reload Nginx Service] *****************************************************
changed: [web-stage-01.internal.net]

PLAY RECAP *********************************************************************************
web-stage-01.internal.net  : ok=5    changed=2    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
```

---

#### Preguntas de Verificación — Ejercicio 2

1. **Pregunta 2.1**: Si tres tareas distintas en un playbook activan el handler `notify: "trigger_nginx_reload"`, ¿cuántas veces se ejecutará el handler `Reload Nginx Service` durante la ejecución del playbook y en qué punto del ciclo de vida de ejecución del play?
2. **Pregunta 2.2**: ¿Por qué se utiliza `changed_when: false` en la tarea `ansible.builtin.command: nginx -t` y qué pasaría con la idempotencia del playbook si se omitiera este parámetro?

---

### Ejercicio Guiado 3: Seguridad y Gestión de Secretos usando Ansible Vault

#### Escenario
Los despliegues en producción requieren pasar contraseñas maestras de base de datos y claves privadas TLS sensibles sin exponer credenciales en repositorios de git en texto plano. Gestionarás archivos de variables encriptados usando `ansible-vault` e integrándolos de forma transparente en los flujos de trabajo de los playbooks.

#### Paso 1: Crear un Archivo de Secretos Encriptado
Creá un archivo de contraseña en el nodo de control para almacenar de manera segura el secreto de desencriptación de Vault:

```bash
echo "SuperSecretVaultKey2026!" > ~/.ansible_vault_pass
chmod 600 ~/.ansible_vault_pass
```

Creá un archivo de payload encriptado `inventory/production/group_vars/dbservers/vault.yml`:

```bash
ansible-vault create inventory/production/group_vars/dbservers/vault.yml --vault-password-file ~/.ansible_vault_pass
```

Cuando se abra el editor, pegá la siguiente estructura YAML y guardá:

```yaml
---
vault_db_master_user: "db_admin_prod"
vault_db_master_password: "P@ssw0rd_Production_Secured_99!"
vault_api_token: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.e30"
```

#### Paso 2: Verificar el Estado de Encriptación
Inspeccioná el archivo encriptado directamente a través de herramientas de texto estándar para confirmar que las cadenas en texto plano no se puedan leer:

```bash
cat inventory/production/group_vars/dbservers/vault.yml
```

##### Salida Esperada:
```text
$ANSIBLE_VAULT;1.1;AES256
36343763373763326162393233343162343232336237303037323631333333333939316533353434
3730346162363135323937396637373336343534303437340a323334323537333230303130633230
...
```

#### Paso 3: Referenciar Variables de Vault dentro de Código No Encriptado
Creá `inventory/production/group_vars/dbservers/vars.yml` mapeando las variables de vault a propiedades operacionales:

```yaml
---
db_user: "{{ vault_db_master_user }}"
db_pass: "{{ vault_db_master_password }}"
db_port: 5432
```

#### Paso 4: Escribir el Playbook Utilizando Secretos de Vault
Creá `site_database.yml`:

```yaml
---
- name: Configure Production Database Tier
  hosts: dbservers
  gather_facts: false
  tasks:
    - name: Validate Database Credentials Binding
      ansible.builtin.debug:
        msg: "Connecting user {{ db_user }} to database with password payload length {{ db_pass | length }}"

    - name: Ensure Secret Masking in Task Logs
      ansible.builtin.no_log: true
      ansible.builtin.command:
        cmd: "echo 'Initializing DB with user {{ db_user }} and pass {{ db_pass }}'"
```

#### Paso 5: Ejecutar el Playbook con Desencriptación de Vault
Ejecutá el playbook pasando el archivo de contraseña de vault:

```bash
ansible-playbook site_database.yml -i inventory/production/hosts.yml --vault-password-file ~/.ansible_vault_pass
```

##### Salida Esperada:
```text
PLAY [Configure Production Database Tier] **************************************************

TASK [Validate Database Credentials Binding] ***********************************************
ok: [db-prod-01.internal.net] => {
    "msg": "Connecting user db_admin_prod to database with password payload length 31"
}

TASK [Ensure Secret Masking in Task Logs] **************************************************
censored decision made for sensitive values: result log suppressed

PLAY RECAP *********************************************************************************
db-prod-01.internal.net    : ok=2    changed=1    unreachable=0    failed=0    skipped=0
```

---

#### Preguntas de Verificación — Ejercicio 3

1. **Pregunta 3.1**: ¿Cuál es el propósito de configurar `no_log: true` en una tarea que consume variables de `ansible-vault` desencriptadas?
2. **Pregunta 3.2**: Si un usuario ejecuta `ansible-vault rekey inventory/production/group_vars/dbservers/vault.yml`, ¿qué cambio operacional ocurre dentro del archivo y se altera el contenido subyacente en texto plano?

---

### Ejercicio Guiado 4: Roles Empresariales y Arquitectura de Ansible Galaxy

#### Escenario
Para garantizar la modularidad y la reutilización de código, tenés la tarea de encapsular el aprovisionamiento de la base de datos PostgreSQL en un Role de Ansible estandarizado respetando las convenciones oficiales de estructura de directorios. También gestionarás las dependencias externas de roles vía Ansible Galaxy.

#### Paso 1: Inicializar la Estructura de Directorios del Role
Ejecutá `ansible-galaxy` para generar un esqueleto conforme a las convenciones:

```bash
mkdir -p roles
ansible-galaxy role init roles/db_postgres
```

Inspeccioná la jerarquía de directorios generada:

```bash
tree roles/db_postgres
```

##### Salida Esperada:
```text
roles/db_postgres
├── README.md
├── defaults
│   └── main.yml
├── files
├── handlers
│   └── main.yml
├── meta
│   └── main.yml
├── tasks
│   └── main.yml
├── templates
├── tests
│   ├── inventory
│   └── test.yml
└── vars
    └── main.yml
```

#### Paso 2: Implementar la Lógica del Role a través de Componentes Estructurales
Definí variables por defecto de menor precedencia en `roles/db_postgres/defaults/main.yml`:

```yaml
---
postgres_port: 5432
postgres_max_connections: 100
postgres_shared_buffers: "128MB"
```

Definí los handlers de ejecución del role en `roles/db_postgres/handlers/main.yml`:

```yaml
---
- name: Restart Postgres
  ansible.builtin.systemd:
    name: postgresql
    state: restarted
```

Definí las tareas operacionales en `roles/db_postgres/tasks/main.yml`:

```yaml
---
- name: Install PostgreSQL server packages
  ansible.builtin.apt:
    name:
      - postgresql
      - postgresql-contrib
    state: present
    update_cache: true

- name: Configure postgresql.conf Parameters
  ansible.builtin.lineinfile:
    path: "/etc/postgresql/14/main/postgresql.conf"
    regexp: "^#?{{ item.param }}"
    line: "{{ item.param }} = {{ item.val }}"
    state: present
  loop:
    - { param: 'port', val: '{{ postgres_port }}' }
    - { param: 'max_connections', val: '{{ postgres_max_connections }}' }
    - { param: 'shared_buffers', val: "'{{ postgres_shared_buffers }}'" }
  notify: Restart Postgres

- name: Ensure PostgreSQL service is started
  ansible.builtin.systemd:
    name: postgresql
    state: started
    enabled: true
```

#### Paso 3: Definir Dependencias Externas de Galaxy (`requirements.yml`)
Creá `requirements.yml` en la raíz del proyecto para descargar roles de infraestructura externos:

```yaml
---
roles:
  - name: geerlingguy.security
    version: 1.6.0
  - src: git+https://github.com/geerlingguy/ansible-role-firewall.git
    scm: git
    version: master
    name: firewall
```

#### Paso 4: Instalar Roles Externos vía Ansible Galaxy CLI
Ejecutá `ansible-galaxy` para instalar las dependencias en un directorio `roles/` localizado:

```bash
ansible-galaxy install -r requirements.yml -p ./roles/
```

##### Salida Esperada:
```text
- downloading role 'security', image geerlingguy.security
- downloading role from https://github.com/geerlingguy/ansible-role-firewall.git
- extracting geerlingguy.security to /home/deploy/enterprise_ansible/roles/geerlingguy.security
- geerlingguy.security (1.6.0) was installed successfully
- firewall (master) was installed successfully
```

---

#### Preguntas de Verificación — Ejercicio 4

1. **Pregunta 4.1**: ¿Cuál es la diferencia estructural en la precedencia de variables entre `defaults/main.yml` y `vars/main.yml` dentro de un role de Ansible?
2. **Pregunta 4.2**: ¿Cómo determina Ansible el orden de resolución cuando están definidas tanto una variable de playbook `postgres_port: 5433` como una variable de role en `vars/main.yml` `postgres_port: 5432`?

---

### Ejercicio Guiado 5: Solución de Problemas Avanzada, Profiling de Ejecución y Depuración de Payloads Remotos

#### Escenario
Una tarea en un playbook complejo está fallando en un host remoto durante la ejecución del payload. Debés aplicar técnicas avanzadas de diagnóstico: inspeccionar la documentación del módulo vía CLI, realizar profiling de los cuellos de botella de ejecución, habilitar el rastreo detallado de conexiones y conservar los artefactos de ejecución remotos temporales.

#### Paso 1: Consultar la Documentación de Módulos vía `ansible-doc`
Inspeccioná los parámetros de interfaz, valores de retorno y ejemplos para el módulo `ansible.builtin.template` directamente en la terminal:

```bash
ansible-doc ansible.builtin.template
```

Consultá fragmentos específicos para una rápida verificación de sintaxis:

```bash
ansible-doc -s ansible.builtin.apt
```

##### Salida Esperada:
```yaml
- name: Manage libcurl3 package version in the cache
  ansible.builtin.apt:
      allow_downgrade:     # Only has an effect if raw specs defined...
      autoclean:           # If yes, remove useless packages from the local repository.
      autoremove:          # If yes, remove unused dependency packages.
      cache_valid_time:    # Update the apt cache if its older than the cache_valid_time in seconds.
      dpkg_options:        # Add dpkg options to apt command.
      force:               # Force package installation.
      name:                # A list of package names, or a package name with version.
...
```

#### Paso 2: Configurar Callbacks de Profiling de Rendimiento
Editá `ansible.cfg` para incluir plugins de profiling de ejecución para identificar tareas lentas:

```ini
[defaults]
callbacks_enabled = timer, profile_tasks, profile_roles
```

Ejecutá `site_webserver.yml` para inspeccionar las métricas de duración de las tareas:

```bash
ansible-playbook site_webserver.yml -i inventory/staging/hosts.ini
```

##### Salida Esperada (Pie de página de Profiling):
```text
PLAY RECAP *********************************************************************************
web-stage-01.internal.net  : ok=5    changed=0    unreachable=0    failed=0    skipped=0

Thursday 07 August 2026  12:45:10 +0000 (0:00:00.082)       0:00:04.112 **************** 
=============================================================================== 
Install required baseline packages -------------------------------------- 2.45s
Gathering Facts --------------------------------------------------------- 1.12s
Generate Virtual Host Configuration ------------------------------------- 0.31s
Ensure NGINX is Enabled and Started ------------------------------------- 0.15s
Check NGINX Syntax Integrity -------------------------------------------- 0.08s
```

#### Paso 3: Retener e Inspeccionar Payloads de Ejecución Remotos
Para diagnosticar fallas remotas a nivel de Python, indicale a Ansible que omita la eliminación del directorio temporal configurando `ANSIBLE_KEEP_REMOTE_FILES=1` junto con un nivel alto de verbosidad (`-vvv`):

```bash
ANSIBLE_KEEP_REMOTE_FILES=1 ansible webservers -i inventory/staging/hosts.ini -m ping -vvv
```

##### Salida Esperada (Rastreo de la Ruta de Artefactos Remotos):
```text
ansible 2.15.0
  config file = /home/deploy/enterprise_ansible/ansible.cfg
  configured module search path = ['/home/deploy/.ansible/plugins/modules']
  ansible python module location = /usr/lib/python3/dist-packages/ansible
...
<172.16.10.11> ESTABLISH SSH CONNECTION FOR USER: stage_admin
<172.16.10.11> EXEC /bin/sh -c 'mkdir -p "$( echo ~/.ansible/tmp/ansible-tmp-169141231.12-991823 )" && echo "$( echo ~/.ansible/tmp/ansible-tmp-169141231.12-991823 )"'
<172.16.10.11> PUT /tmp/ansible-tmp-169141231.12-991823/AnsiballZ_ping.py TO /home/stage_admin/.ansible/tmp/ansible-tmp-169141231.12-991823/AnsiballZ_ping.py
<172.16.10.11> EXEC /bin/sh -c 'chmod u+x /home/stage_admin/.ansible/tmp/ansible-tmp-169141231.12-991823/ /home/stage_admin/.ansible/tmp/ansible-tmp-169141231.12-991823/AnsiballZ_ping.py'
<172.16.10.11> EXEC /bin/sh -c '/usr/bin/python3 /home/stage_admin/.ansible/tmp/ansible-tmp-169141231.12-991823/AnsiballZ_ping.py'
web-stage-01.internal.net | SUCCESS => {
    "changed": false,
    "invocation": {
        "module_args": {
            "data": "pong"
        }
    },
    "keep_remote_files": true,
    "ping": "pong"
}
```

#### Paso 4: Depurar el Payload Remoto de Forma Manual
Ingresá por SSH al host objetivo y ejecutá el payload de Python `AnsiballZ` conservado manualmente en modo debug:

```bash
ssh -p 2222 stage_admin@172.16.10.11
python3 ~/.ansible/tmp/ansible-tmp-169141231.12-991823/AnsiballZ_ping.py explode
```

##### Salida Esperada:
```text
Module expanded into:
/home/stage_admin/debug_dir/ansible_module_ping.py
```

---

#### Preguntas de Verificación — Ejercicio 5

1. **Pregunta 5.1**: ¿Qué transformación interna realiza Ansible en los archivos de módulo al compilarlos en un paquete wrapper `AnsiballZ` antes de la transmisión por SSH?
2. **Pregunta 5.2**: ¿Cómo altera la configuración `forks = 50` en `ansible.cfg` el modelo de ejecución paralela de Ansible cuando se ejecutan playbooks en 200 nodos administrados?

---

## 3. Respuestas de Verificación y Explicaciones Detalladas

<details>
<summary>Hacé clic para desplegar las Respuestas y Explicaciones Detalladas</summary>

### Respuestas del Ejercicio 1

* **Respuesta 1.1**: Se aplicará el valor `http_port: 443` de `group_vars/webservers.yml`.
  * **Explicación de Arquitectura**: En la jerarquía de precedencia de variables de Ansible, las variables de grupos padre (`group_vars/all.yml`) tienen menor precedencia que las variables de grupos hijo específicos (`group_vars/webservers.yml`). Los grupos hijo heredan de los grupos padre pero sobreescriben explícitamente las claves superpuestas.
* **Respuesta 1.2**: Una variable definida dentro del bloque `vars:` de una tarea tiene una precedencia significativamente mayor que las variables en los archivos `host_vars`.
  * **Explicación de Arquitectura**: Las variables a nivel de tarea (`task vars`) se ubican cerca de la cima de la jerarquía de precedencia de 22 niveles (nivel 17), sobreescribiendo variables de inventario, `group_vars`, `host_vars`, `vars` del play y variables de role. Solo las extra vars (`-e` / `--extra-vars`) superan a las vars a nivel de tarea.

---

### Respuestas del Ejercicio 2

* **Respuesta 2.1**: El handler se ejecutará **exactamente una vez** al final de la ejecución del play (después de que se completen todas las tareas del play).
  * **Explicación de Arquitectura**: Los handlers se desduplican por nombre. Independientemente de cuántas tareas notifiquen a un handler durante la ejecución, Ansible pone en cola la notificación y ejecuta el handler una sola vez durante la fase de vaciado (flush) de handlers. Si una tarea falla a mitad de camino antes de la fase de vaciado de handlers, estos no se ejecutarán a menos que se llame explícitamente a `flush_handlers` o se use `meta: flush_handlers`.
* **Respuesta 2.2**: `changed_when: false` informa al motor core de Ansible que la ejecución del comando es de solo lectura y no muta el estado del sistema objetivo.
  * **Explicación de Arquitectura**: Los módulos `command` y `shell` no pueden determinar de forma nativa los cambios de estado y, por defecto, reportan `changed: true` con el código de salida 0. Omitir `changed_when: false` provocaría que Ansible marque la tarea como `changed` en cada ejecución, rompiendo el reporte de idempotencia del playbook y activando innecesariamente handlers dependientes a lo largo del grafo de ejecución.

---

### Respuestas del Ejercicio 3

* **Respuesta 3.1**: `no_log: true` le indica a Ansible que sanitice y suprima los parámetros de la tarea, stdout y stderr de la salida de logs en la CLI, syslog y callbacks de visualización.
  * **Explicación de Arquitectura**: Incluso si un archivo está encriptado en disco con `ansible-vault`, una vez que Ansible desencripta la variable en memoria y la pasa a un módulo, el registro estándar de la tarea imprimiría la cadena secreta desencriptada en texto plano en la salida estándar o en los logs de CI/CD. Configurar `no_log: true` impone la ocultación de secretos en tiempo de ejecución.
* **Respuesta 3.2**: `ansible-vault rekey` cambia la clave de encriptación simétrica (o contraseña) subyacente utilizada para proteger el payload; **no** altera el contenido en texto plano.
  * **Explicación de Arquitectura**: El comando desencripta el flujo de cifrado AES-256 utilizando la clave antigua en memoria, genera un nuevo payload de derivación de clave/sal (PBKDF2/HMAC) y vuelve a encriptar la estructura de datos original en texto plano con la nueva clave.

---

### Respuestas del Ejercicio 4

* **Respuesta 4.1**: `defaults/main.yml` tiene la precedencia de variable más baja dentro de un role (Nivel de Precedencia 2), mientras que `vars/main.yml` tiene una precedencia de variable muy alta (Nivel de Precedencia 15).
  * **Explicación de Arquitectura**: `defaults/main.yml` está diseñado para proporcionar valores por defecto que se pueden sobreescribir fácilmente por el inventario, `group_vars` o parámetros del play. Por el contrario, `vars/main.yml` está diseñado para la inmutabilidad interna del role; las variables definidas allí sobreescriben los `host_vars`, `group_vars` y los `vars` del play.
* **Respuesta 4.2**: El valor `postgres_port: 5432` del archivo `vars/main.yml` del role tendrá precedencia sobre la variable del playbook `postgres_port: 5433` (a menos que la variable del playbook esté configurada dentro del bloque `vars:` al invocar el role).
  * **Explicación de Arquitectura**: El archivo `vars/main.yml` del role (Nivel 15) supera a las definiciones de `vars:` estándar del play (Nivel 12). Para sobreescribir una variable de role declarada en `vars/main.yml`, un ingeniero debe usar extra vars (`-e`) o pasarla directamente en el bloque de parámetros de la tarea o del role.

---

### Respuestas del Ejercicio 5

* **Respuesta 5.1**: Ansible encapsula el código del módulo, las librerías de utilidad (`ansible.module_utils`) y el payload de parámetros JSON en un solo script de Python comprimido en ZIP y codificado en base64 (paquete wrapper `AnsiballZ`).
  * **Explicación de Arquitectura**: Este empaquetado garantiza que las dependencias complejas del módulo se transmitan sobre SSH como un único payload, evitando múltiples transferencias de archivos de ida y vuelta y asegurando una ejecución atómica en el nodo administrado.
* **Respuesta 5.2**: Incrementar `forks = 50` permite a Ansible generar hasta 50 procesos de trabajo en paralelo en el nodo de control, procesando 50 hosts administrados de forma concurrente por lote de tareas en lugar del valor por defecto de 5.
  * **Explicación de Arquitectura**: Ansible ejecuta plays en los hosts en lotes paralelos definidos por `forks`. Para 200 nodos con `forks = 50`, Ansible completa cada tarea en todos los hosts en 4 olas paralelas (lotes de 50), reduciendo drásticamente el tiempo total de ejecución del playbook, siempre que el nodo de control disponga de suficientes núcleos de CPU, memoria y ancho de banda de sockets SSH.

</details>