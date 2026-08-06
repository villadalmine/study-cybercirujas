# LPI 050-100: Modelos de Negocio de Desarrollo de Software (Tema 4.1)
**Peso del examen:** 5  
**Contexto del rol:** Principal Platform Architect & Senior SRE Instructor  
**Certificación objetivo:** LPI Open Source Essentials (050-100)  
**Referencia oficial:** [LPI Open Source Essentials Overview](https://www.lpi.org/our-certifications/open-source-essentials-overview/)

---

## Resumen Ejecutivo y Arquitectura Conceptual

En la ingeniería de software cloud-native moderna, el software de código abierto (OSS) no es simplemente un marco de licenciamiento; es una estrategia de negocio fundamental. Las organizaciones que construyen productos comerciales alrededor del código abierto aprovechan distintas mecánicas de monetización para lograr ingresos sostenibles mientras fomentan la adopción por parte de la comunidad.

```
+-----------------------------------------------------------------------------------+
|                        SOFTWARE DEVELOPMENT BUSINESS MODELS                       |
+---------------------+---------------------+-------------------+-------------------+
|     Open Core       |    Dual-Licensing   | SaaS / Hosted     | Support & Services|
+---------------------+---------------------+-------------------+-------------------+
| Core: OSI-Approved  | Community: GPL/AGPL | Infrastructure:   | Distribution:     |
| (MIT/Apache 2.0/GPL)| Commercial: Private | Open Source (OSS) | Source-Available /|
|                     | EULA (No Copyleft)  |                   | RHEL / Subscriptions|
| Enterprise: Private |                     | Platform: Hosted  |                   |
| Modules / Plugins   |                     | Multi-Tenant SaaS | Consulting & SLAs |
+---------------------+---------------------+-------------------+-------------------+
```

---

## Ejercicio Guiado 1: Auditando Modelos de Negocio de COSS en una Arquitectura de Producción

### Contexto del Escenario
Sos un Principal Platform Architect revisando una plataforma de microservicios de terceros. La plataforma incorpora múltiples componentes de software de código abierto comercial (COSS - Commercial Open Source Software). Debés inspeccionar los paquetes de lanzamiento, los metadatos de licenciamiento y las estructuras de compilación para clasificar el modelo de negocio de cada componente.

### Pasos de Ejecución

1. Ejecutá un comando para crear un directorio de trabajo e inspeccionar manifiestos de componentes de muestra que imitan distribuciones comunes de software de código abierto empresarial:

```bash
mkdir -p ~/lpi-050-workspace/exercise1 && cd ~/lpi-050-workspace/exercise1

cat << 'EOF' > architecture_manifest.json
{
  "components": [
    {
      "name": "DB-Engine-Core",
      "license_community": "GPL-2.0-only",
      "license_enterprise": "Commercial-EULA",
      "commercial_model": "Dual-Licensing",
      "vendor": "DataCorp"
    },
    {
      "name": "App-Framework",
      "license_community": "Apache-2.0",
      "license_enterprise": "Proprietary-EE-Addons",
      "commercial_model": "Open Core",
      "vendor": "AppTech"
    },
    {
      "name": "Cloud-Queue",
      "license_community": "SSPL-1.0",
      "license_enterprise": "Managed-Cloud-SaaS",
      "commercial_model": "Source-Available / SaaS Protection",
      "vendor": "QueueInc"
    },
    {
      "name": "Enterprise-Linux-Kernel",
      "license_community": "GPL-2.0-only",
      "license_enterprise": "Support-Subscription-SLA",
      "commercial_model": "Services & Subscriptions",
      "vendor": "EnterpriseOS"
    }
  ]
}
EOF
```

2. Inspeccioná el manifiesto usando `jq` para aislar los componentes que operan bajo un modelo de **Dual-Licensing** vs. un modelo de **Open Core**:

```bash
jq '.components[] | select(.commercial_model == "Dual-Licensing" or .commercial_model == "Open Core")' architecture_manifest.json
```

*Salida esperada:*
```json
{
  "name": "DB-Engine-Core",
  "license_community": "GPL-2.0-only",
  "license_enterprise": "Commercial-EULA",
  "commercial_model": "Dual-Licensing",
  "vendor": "DataCorp"
}
{
  "name": "App-Framework",
  "license_community": "Apache-2.0",
  "license_enterprise": "Proprietary-EE-Addons",
  "commercial_model": "Open Core",
  "vendor": "AppTech"
}
```

3. Examiná la diferencia entre Dual-Licensing y Open Core a nivel de artefacto de código consultando las estructuras de paquetes:

```bash
cat << 'EOF' > parse_models.py
import json

with open('architecture_manifest.json') as f:
    data = json.load(f)

for comp in data['components']:
    print(f"Component: {comp['name']}")
    print(f"  Primary Business Model : {comp['commercial_model']}")
    print(f"  Community License     : {comp['license_community']}")
    print(f"  Enterprise Variant    : {comp['license_enterprise']}\n")
EOF

python3 parse_models.py
```

*Salida esperada:*
```text
Component: DB-Engine-Core
  Primary Business Model : Dual-Licensing
  Community License     : GPL-2.0-only
  Enterprise Variant    : Commercial-EULA

Component: App-Framework
  Primary Business Model : Open Core
  Community License     : Apache-2.0
  Enterprise Variant    : Proprietary-EE-Addons

Component: Cloud-Queue
  Primary Business Model : Source-Available / SaaS Protection
  Community License     : SSPL-1.0
  Enterprise Variant    : Managed-Cloud-SaaS

Component: Enterprise-Linux-Kernel
  Primary Business Model : Services & Subscriptions
  Community License     : GPL-2.0-only
  Enterprise Variant    : Support-Subscription-SLA
```

---

### Preguntas de Verificación (Ejercicio 1)

1. **¿Qué mecanismo principal permite a un proveedor de software ofrecer exactamente la misma base de código bajo una licencia copyleft fuerte (ej., GPL) al público y bajo una licencia propietaria a clientes empresariales?**
   - A) Open Core Feature Gating
   - B) Dual-Licensing junto con Contributor License Agreements (CLAs)
   - C) Cláusulas de exención de Software-as-a-Service (SaaS)
   - D) SLAs de suscripción empresarial

2. **¿En qué se diferencia fundamentalmente un modelo de negocio Open Core de un modelo de negocio de Dual-Licensing?**
   - A) Open Core ofrece el 100% de la base de código bajo una sola licencia, mientras que Dual-Licensing divide las características entre repositorios públicos y privados.
   - B) Open Core proporciona una base totalmente funcional bajo una licencia de código abierto mientras mantiene propietarias las características avanzadas (ej., SSO, RBAC, clustering); Dual-Licensing ofrece la misma base de código completa a elección bajo términos de código abierto o comerciales.
   - C) Dual-Licensing requiere que todas las extensiones enterprise estén licenciadas bajo AGPLv3, mientras que Open Core permite únicamente la licencia MIT.
   - D) Open Core es utilizado exclusivamente por fundaciones sin fines de lucro como la Apache Software Foundation.

---

## Ejercicio Guiado 2: Analizando la Explotación de SaaS por Proveedores Cloud y Cambios de Licencia a Source-Available

### Contexto del Escenario
Los principales proveedores de código abierto (ej., MongoDB, Elastic, HashiCorp) cambiaron sus licencias aprobadas por la OSI (Apache 2.0, BSD) a licencias Source-Available (Server Side Public License [SSPL], Business Source License [BSL/BUSL]). Este ejercicio te guía a través de la simulación de la evaluación del cambio de licencia desencadenado por proveedores de nube pública que revenden servicios gestionados sin realizar contribuciones al proyecto upstream.

### Pasos de Ejecución

1. Creá un script que simule la verificación de cumplimiento de licencias para una plataforma SaaS alojada en la nube:

```bash
mkdir -p ~/lpi-050-workspace/exercise2 && cd ~/lpi-050-workspace/exercise2

cat << 'EOF' > verify_saas_compliance.sh
#!/bin/bash

LICENSE_TYPE=$1

echo "Analyzing compliance for hosted SaaS provider deploying component licensed under: ${LICENSE_TYPE}"

case ${LICENSE_TYPE} in
  "Apache-2.0"|"MIT")
    echo "[COMPLIANT] OSI-Approved Permissive. Cloud providers can offer managed services without releasing management platform code."
    ;;
  "GPL-3.0")
    echo "[COMPLIANT WITH CAVEAT] Copyleft applies to binaries distributed. Running standard SaaS over network does not trigger source distribution obligations under standard GPL."
    ;;
  "AGPL-3.0")
    echo "[TRIGGER SOURCE OBLIGATION] Network Copyleft clause activated. Must make complete network management interface code available under AGPLv3 to remote users."
    ;;
  "SSPL-1.0")
    echo "[NOT OSI-APPROVED] Source-Available. Offering software as a commercial managed cloud service requires releasing all underlying service infrastructure/management source code or buying a commercial license."
    ;;
  "BSL-1.1")
    echo "[SOURCE-AVAILABLE / TIMED CONVERSION] Use in production as a managed competing service is restricted until the Change Date (e.g., 4 years), after which it converts to an OSI license (e.g., Apache 2.0)."
    ;;
  *)
    echo "[UNKNOWN] Unrecognized license type."
    ;;
esac
EOF

chmod +x verify_saas_compliance.sh
```

2. Ejecutá pruebas en diferentes escenarios de licenciamiento para analizar el impacto en los proveedores cloud:

```bash
./verify_saas_compliance.sh "Apache-2.0"
./verify_saas_compliance.sh "AGPL-3.0"
./verify_saas_compliance.sh "SSPL-1.0"
./verify_saas_compliance.sh "BSL-1.1"
```

*Salida esperada:*
```text
Analyzing compliance for hosted SaaS provider deploying component licensed under: Apache-2.0
[COMPLIANT] OSI-Approved Permissive. Cloud providers can offer managed services without releasing management platform code.
Analyzing compliance for hosted SaaS provider deploying component licensed under: AGPL-3.0
[TRIGGER SOURCE OBLIGATION] Network Copyleft clause activated. Must make complete network management interface code available under AGPLv3 to remote users.
Analyzing compliance for hosted SaaS provider deploying component licensed under: SSPL-1.0
[NOT OSI-APPROVED] Source-Available. Offering software as a commercial managed cloud service requires releasing all underlying service infrastructure/management source code or buying a commercial license.
Analyzing compliance for hosted SaaS provider deploying component licensed under: BSL-1.1
[SOURCE-AVAILABLE / TIMED CONVERSION] Use in production as a managed competing service is restricted until the Change Date (e.g., 4 years), after which it converts to an OSI license (e.g., Apache 2.0).
```

3. Consultá las reglas de cumplimiento de la Open Source Initiative (OSI) usando curl contra los estándares de definición oficiales:

```bash
# Verify OSI compliance criteria regarding field-of-endeavor restrictions
cat << 'EOF' > oski_clause_check.txt
OSD Requirement 6: No Discrimination Against Fields of Endeavor
The license must not restrict anyone from making use of the program in a specific field of endeavor.
For example, it may not restrict the program from being used in a business, or from being used for genetic research.
EOF

cat oski_clause_check.txt
```

---

### Preguntas de Verificación (Ejercicio 2)

1. **¿Por qué licencias como SSPL (Server Side Public License) y BSL (Business Source License) explícitamente NO están clasificadas como Open Source por la Open Source Initiative (OSI)?**
   - A) Porque restringen el uso comercial y discriminan contra campos de aplicación específicos (ej., ejecutar servicios cloud gestionados).
   - B) Porque no permiten a los usuarios inspeccionar el código fuente subyacente.
   - C) Porque requieren pagos directamente a la Linux Foundation.
   - D) Porque permiten la redistribución únicamente a través de paquetes binarios RPM.

2. **¿Qué vacío legal específico en las licencias copyleft estándar como GPLv2/v3 llevó a la creación de AGPLv3 (GNU Affero General Public License) en entornos cloud?**
   - A) GPLv2 prohibía la compilación de binarios en arquitecturas ARM.
   - B) Las obligaciones copyleft de la GPL estándar se activan con la *distribución* de software; ejecutar software como un servicio de red remoto (SaaS) no se consideraba distribución, lo que permitía a los proveedores cloud modificar el código sin compartir los cambios.
   - C) GPLv3 no permitía el enlazado estático en entornos cloud.
   - D) AGPLv3 fue creada para hacer cumplir el dual-licensing propietario para fabricantes de hardware.

---

## Ejercicio Guiado 3: Inspeccionando Modelos de Soporte, Suscripción y Distribución

### Contexto del Escenario
Empresas como Red Hat y Canonical generan ingresos empaquetando software de código abierto y ofreciendo suscripciones de soporte empresarial, Service Level Agreements (SLAs), binarios certificados y gestión de parches en lugar de vender claves de licencia. En este ejercicio, explorarás cómo los repositorios de paquetes distinguen entre distribuciones comunitarias abiertas y distribuciones de suscripción empresarial.

### Pasos de Ejecución

1. Creá un script para simular la inspección de metadatos de repositorios de paquetes empresariales:

```bash
mkdir -p ~/lpi-050-workspace/exercise3 && cd ~/lpi-050-workspace/exercise3

cat << 'EOF' > inspect_distribution_model.py
class DistributionModel:
    def __init__(self, dist_name, source_access, binary_access, support_tier, primary_revenue):
        self.dist_name = dist_name
        self.source_access = source_access
        self.binary_access = binary_access
        self.support_tier = support_tier
        self.primary_revenue = primary_revenue

    def display(self):
        print(f"Distribution Name  : {self.dist_name}")
        print(f"Source Code Access : {self.source_access}")
        print(f"Binary Access      : {self.binary_access}")
        print(f"Support & SLAs     : {self.support_tier}")
        print(f"Monetization Engine: {self.primary_revenue}")
        print("-" * 55)

distributions = [
    DistributionModel(
        dist_name="Enterprise OS (e.g., RHEL)",
        source_access="Open Source (GPL Upstream / Customer Portal Access)",
        binary_access="Restricted behind Subscription Portal / Paywall",
        support_tier="24/7 Production Support, SLAs, Long-Term Support (LTS)",
        primary_revenue="Annual Enterprise Subscriptions & Professional Services"
    ),
    DistributionModel(
        dist_name="Community Downstream (e.g., Rocky Linux / AlmaLinux)",
        source_access="Publicly Available Source Repositories",
        binary_access="Free / Unrestricted Public Binaries",
        support_tier="Community / Third-Party Vendor Support",
        primary_revenue="Donations, Commercial Sponsorships, Third-party Support"
    ),
    DistributionModel(
        dist_name="Upstream Rolling (e.g., CentOS Stream / Fedora)",
        source_access="Public Upstream Development Branch",
        binary_access="Free Public Access",
        support_tier="Community Forums / Bug Trackers",
        primary_revenue="R&D Pipeline for Enterprise Products"
    )
]

print("=== OPEN SOURCE DISTRIBUTION & SUBSCRIPTION MODEL AUDIT ===\n")
for dist in distributions:
    dist.display()
EOF

python3 inspect_distribution_model.py
```

*Salida esperada:*
```text
=== OPEN SOURCE DISTRIBUTION & SUBSCRIPTION MODEL AUDIT ===

Distribution Name  : Enterprise OS (e.g., RHEL)
Source Code Access : Open Source (GPL Upstream / Customer Portal Access)
Binary Access      : Restricted behind Subscription Portal / Paywall
Support & SLAs     : 24/7 Production Support, SLAs, Long-Term Support (LTS)
Monetization Engine: Annual Enterprise Subscriptions & Professional Services
-------------------------------------------------------
Distribution Name  : Community Downstream (e.g., Rocky Linux / AlmaLinux)
Source Code Access : Publicly Available Source Repositories
Binary Access      : Free / Unrestricted Public Binaries
Support & SLAs     : Community / Third-Party Vendor Support
Monetization Engine: Donations, Commercial Sponsorships, Third-party Support
-------------------------------------------------------
Distribution Name  : Upstream Rolling (e.g., CentOS Stream / Fedora)
Source Code Access : Public Upstream Development Branch
Binary Access      : Free Public Access
Support & SLAs     : Community Forums / Bug Trackers
Monetization Engine: R&D Pipeline for Enterprise Products
-------------------------------------------------------
```

2. Evaluá cómo los servicios de suscripción agregan valor a los binarios de software de código abierto sin violar las licencias copyleft:

```bash
cat << 'EOF' > evaluate_subscription_value.sh
#!/bin/bash

cat << "DETAILS"
Subscribing to Enterprise Open Source provides value through:
1. Lifecycle Management: 10+ years of backported security patches (CVEs) without breaking API/ABI.
2. Compliance & Certifications: FIPS 140-2/3, Common Criteria, ISO 27001 validation.
3. Indemnification: Legal defense against intellectual property infringement claims.
4. Guaranteed SLAs: 15-minute response times for critical production outages.
5. Ecosystem Certification: Validated compatibility with hardware vendors (ISVs) and cloud platforms.
DETAILS
EOF

chmod +x evaluate_subscription_value.sh
./evaluate_subscription_value.sh
```

---

### Preguntas de Verificación (Ejercicio 3)

1. **Bajo el modelo de Servicios y Suscripciones (ej., Red Hat Enterprise Linux), ¿por qué está pagando principalmente el cliente?**
   - A) Claves de licencia de software propietario necesarias para desbloquear núcleos de CPU.
   - B) Acceso a mantenimiento, binarios certificados, backports de seguridad, indemnización y soporte técnico respaldado por SLA.
   - C) Derechos exclusivos para volver a licenciar el kernel de Linux bajo una licencia comercial.
   - D) Derechos de patentes de software propiedad del proveedor.

2. **¿Restringir las descargas de binarios compilados detrás de un portal de suscripción de clientes viola la Licencia Pública General de GNU (GPL) si el proveedor proporciona el código fuente correspondiente a los clientes que pagan y reciben los binarios?**
   - A) Sí, porque la GPL requiere la distribución pública y gratuita de binarios a todos los usuarios de Internet.
   - B) No, porque la GPL otorga la libertad de obtener el código fuente a quienes reciben el binario del software, pero no exige la distribución gratuita de binarios al público en general.
   - C) Sí, porque la GPL prohíbe cobrar dinero por servicios de código abierto.
   - D) No, siempre que el proveedor convierta el kernel de Linux a Apache 2.0.

---

## Ejercicio Guiado 4: Gobernanza de Fundaciones, Patrocinios y Modelos de Crowdfunding

### Contexto del Escenario
No todos los proyectos de código abierto son impulsados por proveedores comerciales individuales. Los proyectos independientes a menudo dependen de fundaciones sin fines de lucro (ej., CNCF, Linux Foundation, Apache Software Foundation), patrocinios corporativos y crowdfunding de desarrolladores. En este ejercicio, analizarás los modelos de gobernanza de fundaciones e indicadores de salud de proyectos.

### Pasos de Ejecución

1. Creá un espacio de trabajo para analizar estructuras de gobernanza:

```bash
mkdir -p ~/lpi-050-workspace/exercise4 && cd ~/lpi-050-workspace/exercise4

cat << 'EOF' > foundation_governance.json
{
  "foundations": [
    {
      "name": "Cloud Native Computing Foundation (CNCF)",
      "parent": "Linux Foundation",
      "model": "Vendor-Neutral Governance & IP Holding",
      "revenue_sources": [
        "Corporate Membership Dues (Platinum, Gold, Silver)",
        "Conference Operations (KubeCon)",
        "Training & Certification (CKA, CKAD, CKS)"
      ],
      "ip_ownership": "Trademarks held by Foundation; Copyrights retained by contributors (DCO/CLA)"
    },
    {
      "name": "Apache Software Foundation (ASF)",
      "parent": "Independent 501(c)(3)",
      "model": "Individual Member Governance (Apache Way)",
      "revenue_sources": [
        "Corporate & Individual Sponsorships",
        "Targeted Grants & Public Donations"
      ],
      "ip_ownership": "Apache Contributor License Agreement (CLA) grants software rights to ASF"
    },
    {
      "name": "Independent Developer / Open Collective",
      "parent": "Fiscal Host",
      "model": "Crowdfunding & Micro-Sponsorships",
      "revenue_sources": [
        "GitHub Sponsors",
        "Open Collective",
        "Patreon / Tidelift"
      ],
      "ip_ownership": "Held directly by individual maintainers"
    }
  ]
}
EOF
```

2. Analizá el archivo de gobernanza para extraer cómo difieren la PI (propiedad intelectual) y el financiamiento entre las fundaciones:

```bash
python3 -c "
import json
with open('foundation_governance.json') as f:
    data = json.load(f)

for f in data['foundations']:
    print(f\"Foundation: {f['name']}\")
    print(f\"  Governance Model : {f['model']}\")
    print(f\"  IP Ownership     : {f['ip_ownership']}\")
    print(f\"  Revenue Model    : {', '.join(f['revenue_sources'])}\n\")
"
```

*Salida esperada:*
```text
Foundation: Cloud Native Computing Foundation (CNCF)
  Governance Model : Vendor-Neutral Governance & IP Holding
  IP Ownership     : Trademarks held by Foundation; Copyrights retained by contributors (DCO/CLA)
  Revenue Model    : Corporate Membership Dues (Platinum, Gold, Silver), Conference Operations (KubeCon), Training & Certification (CKA, CKAD, CKS)

Foundation: Apache Software Foundation (ASF)
  Governance Model : Individual Member Governance (Apache Way)
  IP Ownership     : Apache Contributor License Agreement (CLA) grants software rights to ASF
  Revenue Model    : Corporate & Individual Sponsorships, Targeted Grants & Public Donations

Foundation: Independent Developer / Open Collective
  Governance Model : Crowdfunding & Micro-Sponsorships
  IP Ownership     : Held directly by individual maintainers
  Revenue Model    : GitHub Sponsors, Open Collective, Patreon / Tidelift
```

3. Compará Developer Certificate of Origin (DCO) vs. Contributor License Agreement (CLA):

```bash
cat << 'EOF' > compare_contributions.md
### Legal Frameworks for Open Source Contributions

1. **Developer Certificate of Origin (DCO)**
   - Used by: Linux Kernel, CNCF projects.
   - Mechanism: Developers sign off on commits using `git commit -s` (`Signed-off-by: Name <email>`).
   - Purpose: Asserts that the contributor has the legal right to submit the code under the project's open-source license without transferring copyright.

2. **Contributor License Agreement (CLA)**
   - Used by: Apache Software Foundation, Google, FSF (Copyright Assignment).
   - Mechanism: Contributor signs a formal legal contract before submitting code.
   - Purpose: Grants explicit copyright and patent licenses to the project/foundation or transfers copyright entirely, enabling single-entity copyright control (useful for dual-licensing).
EOF

cat compare_contributions.md
```

---

### Preguntas de Verificación (Ejercicio 4)

1. **¿Qué ventaja principal ofrece a los adoptantes empresariales la transferencia de marcas registradas y activos del proyecto a una entidad neutral como la Cloud Native Computing Foundation (CNCF)?**
   - A) Garantiza que el software se convertirá a una licencia propietaria dentro de los 3 años.
   - B) Evita que cualquier proveedor comercial individual controle la dirección del proyecto o cambie el licenciamiento del proyecto de manera unilateral (Neutralidad de Proveedor).
   - C) Elimina la necesidad de aplicar parches de seguridad.
   - D) Impone el dual-licensing obligatorio para todos los usuarios downstream.

2. **¿Qué mecanismo en Git permite a los desarrolladores certificar que tienen el derecho legal de contribuir código bajo un Developer Certificate of Origin (DCO)?**
   - A) `git config --global user.signingkey`
   - B) `git commit --amend`
   - C) `git commit -s` (línea Signed-off-by)
   - D) `git push --force-with-lease`

---

<details>
<summary><strong>Respuestas y Explicaciones Técnicas Detalladas</strong></summary>

### Respuestas del Ejercicio 1

1. **Respuesta correcta: B**  
   *Explicación:* El dual-licensing requiere que el único titular de los derechos de autor (o una entidad que posea todos los derechos comerciales a través de Contributor License Agreements [CLAs]) emita el código bajo dos licencias distintas. Una configuración común es ofrecer el producto bajo GPL (que exige copyleft para obras derivadas enlazadas) junto con un EULA comercial propietario (que exime a los clientes comerciales de las restricciones de copyleft a cambio de una tarifa de licencia).

2. **Respuesta correcta: B**  
   *Explicación:* Bajo **Dual-Licensing**, la misma base de código exacta se ofrece bajo dos opciones de licencia diferentes (ej., GPL vs. EULA comercial). Bajo **Open Core**, la base de código está dividida: la base principal es de código abierto (ej., Apache 2.0 o MIT), mientras que las características avanzadas de nivel empresarial (ej., integración SAML, RBAC, módulos de alta disponibilidad) se mantienen como software propietario independiente de código cerrado.

---

### Respuestas del Ejercicio 2

1. **Respuesta correcta: A**  
   *Explicación:* La Definición de Código Abierto (OSD) prohíbe explícitamente la discriminación contra campos de aplicación (Criterio 6 de la OSD) y las restricciones de uso comercial (Criterio 5 de la OSD). Licencias como SSPL y BSL restringen a los proveedores cloud ofrecer el software como un servicio gestionado sin comprar una licencia comercial o liberar el código de toda su infraestructura de orquestación cloud. Debido a estas restricciones de campos de aplicación, se clasifican como **Source-Available**, no como Open Source.

2. **Respuesta correcta: B**  
   *Explicación:* Las obligaciones copyleft de la GPL estándar se activan cuando los binarios de software se *distribuyen* a los usuarios finales. En un entorno cloud, los usuarios interactúan con el software a través de una red sin recibir una distribución binaria (el "vacío legal del SaaS"). **AGPLv3** introdujo la cláusula de Network Copyleft (Sección 13), especificando que proporcionar acceso a través de una red informática activa el requisito de ofrecer el código fuente completo a los usuarios remotos.

---

### Respuestas del Ejercicio 3

1. **Respuesta correcta: B**  
   *Explicación:* Bajo un modelo de Servicios y Suscripción (ej., Red Hat, Canonical), los clientes pagan por garantías operativas de nivel empresarial: soporte de ciclo de vida a largo plazo (LTS), correcciones de seguridad retrocompatibles (mitigación de CVEs), certificaciones de cumplimiento, indemnización legal contra demandas de patentes y SLAs de respuesta garantizados. El software en sí sigue siendo de código abierto.

2. **Respuesta correcta: B**  
   *Explicación:* La Licencia Pública General de GNU (GPL) exige que a cualquier persona que *reciba una copia binaria* del software se le debe proporcionar acceso al código fuente correspondiente y el derecho a modificarlo/redistribuirlo. La GPL no obliga al creador de software a alojar descargas de binarios públicos gratuitos para no clientes que no hayan recibido el binario.

---

### Respuestas del Ejercicio 4

1. **Respuesta correcta: B**  
   *Explicación:* Las fundaciones neutrales con respecto a proveedores (como CNCF, Apache o la Linux Foundation) mantienen las marcas registradas y la propiedad intelectual del proyecto en fideicomiso. Este modelo de gobernanza neutral protege a los miembros de la comunidad y a los adoptantes corporativos del bloqueo de proveedor (vendor lock-in), forks hostiles o cambios unilaterales de licencias (como re-licenciar a SSPL o BSL).

2. **Respuesta correcta: C**  
   *Explicación:* El Developer Certificate of Origin (DCO) requiere que los desarrolladores añadan una línea final `Signed-off-by: Author <email>` a sus mensajes de commit usando `git commit -s`. Esto sirve como una afirmación legal de que el colaborador es el autor del código o tiene el derecho legal de enviarlo bajo la licencia de código abierto del proyecto.

</details>