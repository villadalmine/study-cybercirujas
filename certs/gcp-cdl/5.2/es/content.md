# 5.2 — El valor de negocio de hacer de Google parte de tu equipo de seguridad

### Defensa en profundidad y el enfoque multicapa de la seguridad en la nube

**Certificación:** Google Cloud Digital Leader (versión del examen 2026-08-12)
**Dominio:** 5 — Confianza y seguridad
**Peso en el examen:** 9.0 (el objetivo con mayor peso del dominio)
**Perfil objetivo:** Principal Platform Architect / Senior SRE

---

## 1. Motivación: el problema arquitectónico de producción

### 1.1 La aritmética de dotación de personal que ningún CISO puede ganar

Considerá un escenario real de producción. Una organización de servicios financieros de tamaño mediano corre 340 microservicios repartidos en 12 clústeres de Kubernetes, 2 PB de almacenamiento de objetos, 90 instancias de Cloud SQL y un data warehouse que da servicio a 1.200 analistas. Su organización de seguridad tiene 14 personas: 4 en detección/respuesta, 3 en identidad, 3 en cumplimiento/auditoría, 2 en appsec, 2 en hardening de infraestructura.

Ahora enumerá lo que "defender" ese patrimonio realmente exige, 24/7/365:

| Función de seguridad | FTE realistas para operarla in-house con cobertura 24/7 | Cómo se ve un "buen" resultado |
|---|---|---|
| SOC tier-1/2/3 con follow-the-sun | 12–18 | MTTD < 1 h, MTTR < 4 h |
| Producción de inteligencia de amenazas | 6–10 | Investigación original de IOC/TTP, no una suscripción a un feed |
| Raíz de confianza en hardware y cadena de suministro de firmware | 5+ | Silicio propio, firmware firmado, arranque verificado |
| Absorción de DDoS en L3/L4/L7 | 4+ | Capacidad de scrubbing de varios Tbps, siempre activa |
| Seguridad física del datacenter | 20+ por sitio | Biometría, detección de intrusión por láser, destrucción de discos |
| Infraestructura criptográfica de claves (FIPS 140-2/3 L3) | 4+ | Flota de HSM, rotación, quórum, atestación |
| Evidencia continua de cumplimiento (SOC 2, ISO 27001, PCI DSS, FedRAMP) | 6+ | Continua, no anual en un punto del tiempo |
| Investigación de vulnerabilidades sobre el SO/hipervisor que corrés | 8+ | Encontrar 0-days antes que los adversarios |
| **Total** | **~65–90 FTE** | — |

La organización tiene 14. Esto no es un problema de presupuesto que se resuelva con un 20% más de headcount; es un **desajuste estructural entre la superficie de un patrimonio cloud moderno y la mano de obra disponible para defenderlo**. Toda organización que opera su propio stack de seguridad está resolviendo de nuevo, por su cuenta, problemas que (a) son idénticos en todas las organizaciones y (b) están sujetos a enormes economías de escala.

**La idea arquitectónica de este objetivo:** Google Cloud no es un proveedor de hosting que después tenés que asegurar. Es una organización de seguridad —miles de ingenieros de seguridad a tiempo completo, silicio propio, una red global y el brazo de inteligencia de amenazas de Mandiant y del Google Threat Intelligence Group— cuya producción se entrega como **controles heredados**. No "comprás productos de seguridad de Google". **Absorbés la ingeniería de seguridad de Google como un miembro permanente y sin headcount de tu equipo**.

### 1.2 Por qué falló el modelo de perímetro — el modo de fallo concreto

La arquitectura clásica es una cáscara dura alrededor de un interior blando:

```
Internet ──▶ [Firewall] ──▶ [DMZ] ──▶ [Corp VPN] ──▶ ██ FLAT TRUSTED NETWORK ██
                                                        ├─ HR database
                                                        ├─ Source control
                                                        ├─ Prod Kubernetes API
                                                        └─ Finance data warehouse
```

La afirmación implícita es: **la ubicación en la red es un sustituto de la confianza**. Esa afirmación tiene tres modos de fallo en producción que todo SRE ya vio:

1. **Movimiento lateral.** Una sola laptop phisheada en la VPN hereda la confianza completa de la red. En el análisis forense posterior al incidente, el tiempo de permanencia del atacante transcurre casi por entero *dentro* del perímetro, moviéndose este-oeste, sin ser observado, porque el tráfico este-oeste nunca fue autenticado ni registrado.
2. **El perímetro ya no tiene borde.** Con SaaS, contratistas, movilidad y multi-cloud, no hay un único punto de estrangulamiento donde poner el firewall. El "adentro" es ahora un conjunto de endpoints de API en la internet pública.
3. **La exfiltración de credenciales evita la red por completo.** Una clave de service account filtrada, usada desde un host controlado por el atacante, llega a `storage.googleapis.com` por la API pública. Ninguna regla de firewall de tu VPC está en ese camino.

El modo de fallo #3 es el que más se les escapa a los arquitectos. Un firewall de VPC protege *tu red*; no protege *la superficie de API de Google* detrás de la cual viven tus datos. Esa brecha es exactamente lo que VPC Service Controls existe para cerrar (Sección 4.3).

### 1.3 Responsabilidad compartida → destino compartido

El modelo mental de base es el **modelo de responsabilidad compartida**: el proveedor asegura la nube, el cliente asegura lo que pone dentro de ella. La división se corre según el modelo de servicio:

| Capa | On-prem | IaaS (GCE) | PaaS (GKE Autopilot, Cloud Run) | SaaS (Workspace) |
|---|---|---|---|---|
| Contenido / clasificación de datos | Cliente | Cliente | Cliente | Cliente |
| Políticas de acceso (IAM) | Cliente | Cliente | Cliente | Cliente |
| Identidad (usuarios, MFA) | Cliente | Cliente | Cliente | Cliente |
| Seguridad de la aplicación web | Cliente | Cliente | Cliente | **Google** |
| Configuración de despliegue / contenedores | Cliente | Cliente | Compartida | **Google** |
| SO invitado, parcheo, hardening | Cliente | Cliente | **Google** | **Google** |
| Segmentación de red | Cliente | Compartida | Compartida | **Google** |
| Hipervisor / host | Cliente | **Google** | **Google** | **Google** |
| Kernel, firmware, integridad de arranque | Cliente | **Google** | **Google** | **Google** |
| Hardware, silicio propio | Cliente | **Google** | **Google** | **Google** |
| Datacenter físico, destrucción de medios | Cliente | **Google** | **Google** | **Google** |
| Red global, backbone anti-DDoS | Cliente | **Google** | **Google** | **Google** |

La evolución declarada de Google más allá de esto es el **destino compartido** (shared fate): en lugar de trazar una línea y entregarte la mitad más difícil, Google se involucra *antes* del despliegue (blueprints seguros, landing zones), *durante* (Security Command Center, Assured Workloads, Policy Intelligence) y *después* (Risk Protection Program — ciberseguro tarifado según tu postura real medida, vía el informe de Risk Manager). El encuadre de negocio que aparece en el examen:

> La **responsabilidad compartida** te dice *dónde empieza tu trabajo*. El **destino compartido** significa que Google se juega algo en que vos tengas éxito haciéndolo.

**Traducción a valor de negocio (crítica para el examen):**

| Mecanismo técnico | Enunciado de valor de negocio |
|---|---|
| Controles de infraestructura heredados | Evitación de capex/opex de ~65–90 FTE de seguridad y de un programa de seguridad de datacenter |
| Artefactos continuos de cumplimiento | Los ciclos de auditoría pasan de meses a semanas; entrada más rápida a mercados regulados |
| Absorción global de DDoS en el edge | Protección de ingresos; el SLO de disponibilidad defendido por una capacidad que nunca podrías comprar |
| Cifrado en reposo/en tránsito por defecto | Radio de impacto de una brecha de datos reducido con **cero** esfuerzo de ingeniería |
| Mandiant + Google Threat Intelligence | Experiencia de respuesta a incidentes de primera línea contratada, no en la nómina |
| Risk Protection Program | Riesgo cuantificado y asegurable — convierte un problema de varianza en una línea de prima |

---

## 2. Las capas: lo que Google realmente opera debajo tuyo

Defensa en profundidad significa que *el fallo de un solo control no es fatal*. El stack de Google tiene seis capas; enumeralas, porque el examen evalúa el reconocimiento de en qué capa vive un control dado.

```
┌──────────────────────────────────────────────────────────────────────┐
│ 6. OPERATIONAL / DETECTION                                           │
│    Security Command Center · Google SecOps (Chronicle) · Mandiant    │
│    Access Transparency · Access Approval · Cloud Audit Logs          │
├──────────────────────────────────────────────────────────────────────┤
│ 5. IDENTITY & ACCESS  (the real perimeter)                           │
│    Cloud Identity · IAM · BeyondCorp Enterprise · IAP                │
│    Context-Aware Access · Titan Security Keys · Workload Identity    │
├──────────────────────────────────────────────────────────────────────┤
│ 4. DATA                                                              │
│    Encryption at rest (default AES-256) · CMEK · CSEK · Cloud EKM    │
│    Key Access Justifications · Sensitive Data Protection (DLP)       │
│    Confidential Computing (in-use encryption)                        │
├──────────────────────────────────────────────────────────────────────┤
│ 3. SERVICE / API PERIMETER                                           │
│    VPC Service Controls · Org Policy · Private Service Connect       │
│    Binary Authorization · Software Delivery Shield / SLSA            │
├──────────────────────────────────────────────────────────────────────┤
│ 2. NETWORK                                                           │
│    Global private backbone · Cloud Armor (L3–L7, WAF) · Cloud NGFW   │
│    ALTS mutual auth · Encryption in transit at the WAN edge          │
├──────────────────────────────────────────────────────────────────────┤
│ 1. HARDWARE & BOOT                                                   │
│    Titan security chip (hardware root of trust) · custom server      │
│    design · Verified/Shielded boot · datacenter physical security    │
│    · disk sanitization and destruction chain of custody              │
└──────────────────────────────────────────────────────────────────────┘
        ▲ Layers 1–2 are 100% inherited. You cannot misconfigure them.
```

### 2.1 Capa 1 — Raíz de confianza en hardware (totalmente heredada)

**Titan** es un microcontrolador de seguridad de propósito específico que Google diseña y coloca en servidores y periféricos. Establece una raíz de confianza en hardware: verifica el firmware de bajo nivel y la BIOS *antes* de que se permita ejecutar a la CPU, y provee una identidad criptográfica de máquina. Esto derrota una clase de ataque —implantes persistentes de firmware— que es esencialmente indetectable e irremediable desde el software.

El análogo de cara al cliente que *sí* podés configurar es la **Shielded VM** (vTPM, Secure Boot, monitoreo de integridad) y la **Confidential VM** (memoria cifrada por la CPU con una clave por VM que el hipervisor no puede leer).

**Valor de negocio:** heredás un programa de integridad de la cadena de suministro —silicio propio, firmware firmado, atestación de hardware— cuyo costo de I+D se amortiza sobre el planeta entero. Construir el equivalente no es meramente caro; para la mayoría de las organizaciones es imposible a cualquier precio.

### 2.2 Capa 2 — La red que no tuviste que construir

Google opera uno de los backbones privados más grandes del planeta, con presencia de edge en más de 200 países y territorios. Dos consecuencias importan arquitectónicamente:

- **El DDoS se absorbe como una propiedad de la red, no como un producto que se acopla.** El tráfico hacia un balanceador de carga global de Google Cloud se termina en el PoP de edge más cercano. Las inundaciones volumétricas L3/L4 se disipan sobre capacidad global antes de concentrarse jamás sobre tu backend. Las mitigaciones publicadas por Google incluyen ataques del orden de varios Tbps y de cientos de millones de RPS.
- **El tráfico entre datacenters de Google está autenticado y cifrado por defecto** usando **ALTS** (Application Layer Transport Security), el protocolo de autenticación mutua de Google, además del cifrado de los enlaces WAN a nivel físico/lógico.

> **Nota de SRE sobre aislamiento de fallos:** un Application Load Balancer externo global con Cloud Armor significa que el *primer* dispositivo que ve el tráfico del atacante es el de Google, no el tuyo. Tu autoscaler nunca ve la inundación, así que nunca escala hacia un evento de denegación-de-billetera impulsado por la factura. La **Adaptive Protection** de Cloud Armor usa ML para establecer la línea base de tu tráfico normal y proponer reglas contra ataques L7 que están por debajo de los umbrales volumétricos pero igualmente son capaces de agotar tus backends.

### 2.3 Capas 3–6

Cubiertas en profundidad en las secciones 3 y 4, ya que estas son las capas que vos configurás.

---

## 3. Comparativas técnicas y tablas de compromisos

### 3.1 Cifrado en reposo: cinco posturas de gestión de claves

Todos los datos en reposo en Google Cloud están cifrados por defecto — troceados, cada trozo con su propia clave de cifrado de datos (DEK), y las DEK envueltas por claves de cifrado de claves (KEK) en el KMS interno de Google. La decisión de diseño es *quién posee y controla la KEK*.

| Postura | Dónde vive la KEK | Quién puede técnicamente descifrar | Carga operativa | Riesgo de latencia/disponibilidad | Cuándo elegirla |
|---|---|---|---|---|---|
| **Gestionada por Google (por defecto)** | KMS interno de Google | Sistemas de Google | **Cero** | Ninguno | Por defecto. Correcta para la gran mayoría de las cargas de trabajo. No agregues complejidad sin un motivo. |
| **CMEK** (Cloud KMS, software) | Cloud KMS, tu proyecto | Sistemas de Google, condicionado al IAM y al estado de habilitación de tu clave | Baja: rotación, IAM, topología del key ring | Bajo — la clave es regional; una clave deshabilitada rompe las lecturas | Necesidad regulatoria de *demostrar* control de claves, revocar acceso y probar la cadencia de rotación |
| **CMEK sobre Cloud HSM** | HSM FIPS 140-2 Level 3 | Igual, la clave nunca sale del HSM | Baja–media | Bajo | Mandato contractual/regulatorio de HSM |
| **CSEK** (provista por el cliente) | **Vos**, fuera de la plataforma | Solo vos (la clave se pasa por llamada a la API, se mantiene en memoria) | **Alta** — construís la distribución de claves | Alto: si perdés la clave, perdés los datos, permanentemente | Estrecho. Soporte de servicios limitado (GCE, GCS). Preferí CMEK/EKM. |
| **Cloud EKM** (gestor de claves externo) | **KMS de terceros fuera de Google** (p. ej. HSM/KMS de un partner) | Google solo puede descifrar mientras tu sistema externo se lo conceda | **La más alta** | **El más alto** — una caída del KMS externo = datos ilegibles; agrega un salto de red | Verdadera soberanía de claves; mandatos de "mantener las claves fuera de la nube" |

**Cloud EKM + Key Access Justifications (KAJ)** es el control más afilado de esta tabla. Cada solicitud de desenvolver una clave lleva un *código de justificación* legible por máquina (p. ej. `CUSTOMER_INITIATED_ACCESS`, `GOOGLE_INITIATED_SYSTEM_OPERATION`). Tu KMS externo puede **denegar programáticamente** las solicitudes de desenvoltura cuya justificación no aceptes. Eso convierte el "confiá en nosotros" en "denegar por política, con una razón auditable en texto".

> **Compromiso de producción, dicho sin vueltas:** cada paso hacia abajo en esta tabla intercambia **disponibilidad** por **control**. EKM hace que la legibilidad de tus datos dependa de un sistema que Google no opera y sobre el que no puede dar un SLO. Diseñá el KMS externo con mayor disponibilidad que el plano de datos que controla, o aceptá que su caída es una caída del plano de datos. Elegí CMEK a menos que una regulación específica fuerce EKM.

### 3.2 Cifrado en uso: Confidential Computing

El cifrado en reposo y en tránsito deja una brecha: los datos están en texto plano en la RAM mientras se procesan. Las **Confidential VMs** y los **Confidential GKE Nodes** la cierran usando cifrado de memoria basado en CPU (AMD SEV / SEV-SNP, Intel TDX según la familia de máquinas), con claves generadas por VM dentro de la CPU y jamás expuestas al hipervisor ni al SO del host.

| Propiedad | VM estándar | Shielded VM | Confidential VM |
|---|---|---|---|
| Datos cifrados en reposo | ✅ | ✅ | ✅ |
| Datos cifrados en tránsito | ✅ | ✅ | ✅ |
| **Datos cifrados en uso (RAM)** | ❌ | ❌ | ✅ |
| Arranque verificado / vTPM / monitoreo de integridad | ❌ | ✅ | ✅ |
| Protección frente a un hipervisor comprometido | ❌ | ❌ | ✅ |
| Atestación remota de la identidad de la carga de trabajo | ❌ | Parcial | ✅ |
| Sobrecarga de rendimiento | — | ~0 | Baja, depende de la carga (las cargas limitadas por memoria son las que más lo sienten) |
| Restricción de familia de máquinas | Ninguna | La mayoría | **Sí** — solo familias/regiones específicas |

**Valor de negocio:** habilita computación multiparte sobre datos regulados — dos bancos modelando fraude conjuntamente sin que ninguno vea las filas del otro; un consorcio de hospitales entrenando un modelo con datos que ninguno de ellos puede exportar. Eso no es una historia de hardening, es una historia de **nuevos ingresos**, que es exactamente el encuadre que premia el examen Cloud Digital Leader.

### 3.3 El perímetro: cuatro herramientas distintas, cuatro amenazas distintas

Los arquitectos las confunden rutinariamente. Son ortogonales.

| Control | Opera sobre | Detiene | **No** detiene |
|---|---|---|---|
| **Reglas de firewall de VPC / Cloud NGFW** | Paquetes en tu VPC | Flujos *de red* este-oeste y norte-sur | Cualquier cosa que vaya a `*.googleapis.com` con una credencial válida |
| **IAM** | Identidad de API + permiso | *Principals* no autorizados | Un principal **autorizado** exfiltrando datos a un proyecto personal |
| **VPC Service Controls** | Acceso a las APIs de Google, por *perímetro de recursos* | **Exfiltración**: una credencial válida moviendo datos a través del límite del perímetro | Un llamador que actúa enteramente dentro del perímetro |
| **IAP / BeyondCorp Enterprise** | Sesiones HTTPS usuario→app | Acceso de *dispositivo/usuario* no autenticado o no conforme | Tráfico de servicio máquina a máquina |

**El escenario canónico de VPC-SC, porque al examen le encanta:** un desarrollador con `storage.objectViewer` legítimo sobre el bucket de producción ejecuta `gsutil cp` hacia un bucket de su proyecto personal. IAM dice que sí — el permiso es real. El firewall de la VPC es irrelevante — el tráfico nunca entró a tu VPC. **Solo VPC Service Controls detiene esto**, porque evalúa el *límite de perímetro del recurso*, no el permiso de la identidad. VPC-SC es un control contra el **riesgo interno y el robo de credenciales**, que se apoya ortogonalmente encima de IAM.

### 3.4 Acceso zero trust: VPN vs BeyondCorp

| Dimensión | VPN tradicional | BeyondCorp Enterprise / IAP |
|---|---|---|
| Ancla de confianza | Ubicación en la red | **Identidad + postura del dispositivo + contexto** |
| Radio de impacto de un endpoint comprometido | Toda la red enrutable | Una aplicación, una sesión |
| Onboarding de contratistas / BYOD | Enviar una laptop, aprovisionar la VPN | Otorgar un rol de IAM + Access Level; el navegador es el cliente |
| Modelo de disponibilidad | Capacidad del concentrador, regional | El edge global de Google |
| Señales disponibles para la política | IP de origen | IP, geo, SO/nivel de parcheo del dispositivo, cifrado de disco, bloqueo de pantalla, certificado, hora |
| Reevaluación por solicitud | ❌ (a nivel de sesión) | ✅ |
| Granularidad de auditoría | Logs de conexión | Logs por solicitud y por recurso |

**Modo de fallo que esto elimina:** una mala configuración de split-tunnel en la VPN que expone silenciosamente rangos internos. No hay túnel que configurar mal; hay una expresión de política evaluada en cada solicitud.

### 3.5 Detección: SIEM autoalojado vs Google SecOps

| Dimensión | SIEM autoalojado | Google SecOps (Chronicle) |
|---|---|---|
| Modelo de precios | Por GB ingerido → **incentiva registrar menos** | Predecible/basado en capacidad → **incentiva registrar todo** |
| Economía de la retención | Escalonado a almacenamiento frío, rehidratación dolorosa | Retención en caliente multianual por defecto (comúnmente 12 meses) |
| Retro-hunt sobre un año de telemetría | De horas a días, si los datos se conservaron | Típicamente menos de un minuto |
| Inteligencia de amenazas | Feeds comprados | Inteligencia de primera línea de Google + **Mandiant**, aplicada continuamente a los datos pasados |
| Escalar el índice | Tu problema | El problema de Google |

El **incentivo perverso** de la columna izquierda es el verdadero defecto. Cuando la ingesta se factura por GB, el ingeniero de SOC racional descarta los logs de "bajo valor" —DNS, NetFlow, telemetría de procesos de endpoint— que son precisamente las fuentes que reconstruyen una intrusión. Desacoplar el costo de retención de la calidad de detección es el valor de negocio.

### 3.6 Cumplimiento: controles DIY vs Assured Workloads

| Dimensión | Mapeo de controles DIY | Assured Workloads |
|---|---|---|
| Aplicación de residencia de datos | Revisión manual + ensamblado a mano de org policy | Declarativa, aplicada al crear la carpeta |
| Controles de acceso del personal (ubicación/ciudadanía del staff de soporte) | Contractual, no técnico | Aplicado técnicamente según el régimen de cumplimiento |
| Cobertura de regímenes | Mapeás cada control vos mismo | Empaquetado (p. ej. FedRAMP Moderate/High, IL4/IL5, ofertas regionales de soberanía) |
| Detección de deriva | Ad-hoc | Monitoreo continuo, violaciones expuestas |
| Evidencia de auditoría | Capturas de pantalla y planillas | Artefactos generados |

---

## 4. Infraestructura y manifiestos (completos, desplegables)

Todo lo que sigue es un artefacto completo. Sustituí `ORG_ID`, `PROJECT_ID`, `POLICY_ID`.

### 4.1 Línea base de Organization Policy — la capa del "no podés cometer ese error"

Las restricciones de Org Policy son controles **preventivos** evaluados en el momento de creación del recurso. Son la inversión de seguridad de mayor apalancamiento en Google Cloud porque vuelven clases enteras de vulnerabilidades estructuralmente inalcanzables.

`policies/00-domain-restricted-sharing.yaml`
```yaml
name: organizations/123456789012/policies/iam.allowedPolicyMemberDomains
spec:
  inheritFromParent: false
  rules:
    - values:
        allowedValues:
          # Cloud Identity customer IDs, NOT domain names.
          # Retrieve with: gcloud organizations list --format="value(owner.directoryCustomerId)"
          - "C03xh8abc"
```

`policies/01-no-public-ip.yaml`
```yaml
name: organizations/123456789012/policies/compute.vmExternalIpAccess
spec:
  inheritFromParent: false
  rules:
    - denyAll: true
```

`policies/02-require-shielded-vm.yaml`
```yaml
name: organizations/123456789012/policies/compute.requireShieldedVm
spec:
  rules:
    - enforce: true
```

`policies/03-uniform-bucket-level-access.yaml`
```yaml
name: organizations/123456789012/policies/storage.uniformBucketLevelAccess
spec:
  rules:
    - enforce: true
```

`policies/04-disable-sa-key-creation.yaml`
```yaml
name: organizations/123456789012/policies/iam.disableServiceAccountKeyCreation
spec:
  inheritFromParent: false
  rules:
    - enforce: true
    # Narrow, audited exception for a legacy on-prem integrator.
    - condition:
        title: legacy-onprem-connector-exception
        description: "Expires 2026-12-31. Tracked in RISK-4471."
        expression: "resource.matchTag('123456789012/exception', 'legacy-sa-keys')"
      enforce: false
```

`policies/05-restrict-vpc-peering.yaml`
```yaml
name: organizations/123456789012/policies/compute.restrictVpcPeering
spec:
  inheritFromParent: false
  rules:
    - values:
        allowedValues:
          - under:organizations/123456789012
```

`policies/06-resource-locations.yaml`
```yaml
name: organizations/123456789012/policies/gcp.resourceLocations
spec:
  inheritFromParent: false
  rules:
    - values:
        allowedValues:
          - in:eu-locations
```

Aplicá el paquete completo:

```bash
$ for f in policies/*.yaml; do
>   echo "==> $f"
>   gcloud org-policies set-policy "$f"
> done
==> policies/00-domain-restricted-sharing.yaml
Created policy [organizations/123456789012/policies/iam.allowedPolicyMemberDomains].
==> policies/01-no-public-ip.yaml
Created policy [organizations/123456789012/policies/compute.vmExternalIpAccess].
==> policies/02-require-shielded-vm.yaml
Created policy [organizations/123456789012/policies/compute.requireShieldedVm].
==> policies/03-uniform-bucket-level-access.yaml
Created policy [organizations/123456789012/policies/storage.uniformBucketLevelAccess].
==> policies/04-disable-sa-key-creation.yaml
Created policy [organizations/123456789012/policies/iam.disableServiceAccountKeyCreation].
==> policies/05-restrict-vpc-peering.yaml
Created policy [organizations/123456789012/policies/compute.restrictVpcPeering].
==> policies/06-resource-locations.yaml
Created policy [organizations/123456789012/policies/gcp.resourceLocations].
```

Verificá la política efectiva sobre un proyecto hoja (herencia ya resuelta):

```bash
$ gcloud org-policies describe compute.vmExternalIpAccess \
    --project=prod-payments-8871 --effective
name: projects/prod-payments-8871/policies/compute.vmExternalIpAccess
spec:
  rules:
  - denyAll: true
```

Demostrá el control preventivo disparándose:

```bash
$ gcloud compute instances create canary-public \
    --project=prod-payments-8871 --zone=europe-west1-b \
    --machine-type=e2-medium \
    --network-interface=network=prod-vpc,subnet=prod-eu-w1,address=''
ERROR: (gcloud.compute.instances.create) Could not fetch resource:
 - Constraint constraints/compute.vmExternalIpAccess violated for project
   prod-payments-8871. Add instance projects/prod-payments-8871/zones/
   europe-west1-b/instances/canary-public to the constraint to use external IP
   with it.
```

> **Este es todo el punto de la defensa en profundidad como modelo operativo.** El error no fue detectado en una auditoría seis semanas después. Fue vuelto **imposible**, en la API, por una política expresada como código.

### 4.2 Equivalente en Terraform (lo que realmente va en el repositorio)

`security-baseline/main.tf`
```hcl
terraform {
  required_version = ">= 1.6"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

variable "org_id"        { type = string }
variable "customer_id"   { type = string }
variable "billing_account" { type = string }

locals {
  org = "organizations/${var.org_id}"

  boolean_deny_constraints = [
    "compute.requireShieldedVm",
    "compute.requireOsLogin",
    "compute.disableSerialPortAccess",
    "compute.skipDefaultNetworkCreation",
    "storage.uniformBucketLevelAccess",
    "iam.disableServiceAccountKeyCreation",
    "iam.automaticIamGrantsForDefaultServiceAccounts",
    "sql.restrictPublicIp",
    "sql.restrictAuthorizedNetworks",
    "run.allowedIngress",
  ]
}

resource "google_org_policy_policy" "boolean_enforced" {
  for_each = toset(local.boolean_deny_constraints)

  name   = "${local.org}/policies/${each.value}"
  parent = local.org

  spec {
    inherit_from_parent = false
    rules {
      enforce = "TRUE"
    }
  }
}

resource "google_org_policy_policy" "no_external_ip" {
  name   = "${local.org}/policies/compute.vmExternalIpAccess"
  parent = local.org
  spec {
    inherit_from_parent = false
    rules { deny_all = "TRUE" }
  }
}

resource "google_org_policy_policy" "domain_restricted_sharing" {
  name   = "${local.org}/policies/iam.allowedPolicyMemberDomains"
  parent = local.org
  spec {
    inherit_from_parent = false
    rules {
      values { allowed_values = [var.customer_id] }
    }
  }
}

# ---- Org-wide audit log sink: immutable, outside the projects it observes ----

resource "google_project" "audit" {
  name            = "central-audit"
  project_id      = "central-audit-9021"
  org_id          = var.org_id
  billing_account = var.billing_account
}

resource "google_storage_bucket" "audit_archive" {
  project                     = google_project.audit.project_id
  name                        = "org-audit-archive-9021"
  location                    = "EU"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # Write-once, delete-never for the retention window.
  retention_policy {
    retention_period = 220752000 # 7 years, seconds
    is_locked        = true      # irreversible; even org admins cannot shorten it
  }

  versioning { enabled = true }

  lifecycle_rule {
    condition { age = 90 }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }
}

resource "google_logging_organization_sink" "all_admin_activity" {
  name             = "org-admin-activity-archive"
  org_id           = var.org_id
  include_children = true
  destination      = "storage.googleapis.com/${google_storage_bucket.audit_archive.name}"

  filter = <<-EOT
    logName:"cloudaudit.googleapis.com%2Factivity"
    OR logName:"cloudaudit.googleapis.com%2Fsystem_event"
    OR logName:"cloudaudit.googleapis.com%2Fpolicy"
    OR protoPayload.metadata.@type="type.googleapis.com/google.cloud.audit.TransparencyLog"
  EOT
}

resource "google_storage_bucket_iam_member" "sink_writer" {
  bucket = google_storage_bucket.audit_archive.name
  role   = "roles/storage.objectCreator"
  member = google_logging_organization_sink.all_admin_activity.writer_identity
}
```

> **Nota de SRE:** `is_locked = true` en la política de retención es **irreversible**. También es todo el valor del control — un atacante que obtiene org-admin no puede destruir la evidencia de cómo llegó ahí. Probalo primero en una organización descartable; no lo podés deshacer.

### 4.3 VPC Service Controls — el perímetro anti-exfiltración

Creá la access policy y un Access Level basado en dispositivo/contexto:

```bash
$ gcloud access-context-manager policies create \
    --organization=123456789012 --title="corp-security-perimeter"
Create request issued
Waiting for operation [operations/accessPolicies/418872341190/create] to complete...done.
Created.

$ gcloud access-context-manager policies list --organization=123456789012
NAME          ORGANIZATION      TITLE                    SCOPES
418872341190  123456789012      corp-security-perimeter
```

`access-levels/trusted-corp.yaml`
```yaml
- title: trusted_corp_device
  description: >-
    Corporate-managed, encrypted, screen-locked device on a known egress range,
    originating from a country where we hold operating licences.
  basic:
    combiningFunction: AND
    conditions:
      - ipSubnetworks:
          - 203.0.113.0/24
          - 198.51.100.0/24
      - devicePolicy:
          requireScreenlock: true
          requireCorpOwned: true
          allowedEncryptionStatuses:
            - ENCRYPTED
          osConstraints:
            - osType: DESKTOP_MAC
              minimumVersion: "14.0.0"
            - osType: DESKTOP_WINDOWS
              minimumVersion: "10.0.19045"
            - osType: DESKTOP_CHROME_OS
              requireVerifiedChromeOs: true
      - regions:
          - ES
          - DE
          - IE
      - members:
          - user:sre-oncall@example.com
          - group:platform-sre@example.com
```

```bash
$ gcloud access-context-manager levels replace-all \
    --policy=418872341190 --source-file=access-levels/trusted-corp.yaml
Replaced all access levels.
```

Ahora el perímetro. `perimeters/prod-data.yaml`:

```yaml
name: accessPolicies/418872341190/servicePerimeters/prod_data
title: prod_data
description: "Production payments + analytics. Nothing leaves without an explicit rule."
perimeterType: PERIMETER_TYPE_REGULAR
status:
  resources:
    - projects/887100211934   # prod-payments-8871
    - projects/887100211935   # prod-analytics-8872
    - projects/887100211936   # prod-kms-8873
  accessLevels:
    - accessPolicies/418872341190/accessLevels/trusted_corp_device
  restrictedServices:
    - storage.googleapis.com
    - bigquery.googleapis.com
    - cloudkms.googleapis.com
    - pubsub.googleapis.com
    - sqladmin.googleapis.com
    - secretmanager.googleapis.com
    - container.googleapis.com
    - artifactregistry.googleapis.com
    - logging.googleapis.com
    - aiplatform.googleapis.com
  vpcAccessibleServices:
    enableRestriction: true
    allowedServices:
      - RESTRICTED-SERVICES
  ingressPolicies:
    # CI/CD in a separate project may push images and read build config.
    - ingressFrom:
        identities:
          - serviceAccount:cloudbuild-prod@ci-shared-4410.iam.gserviceaccount.com
        sources:
          - resource: projects/441000778812   # ci-shared-4410
      ingressTo:
        resources:
          - projects/887100211934
        operations:
          - serviceName: artifactregistry.googleapis.com
            methodSelectors:
              - permission: artifactregistry.repositories.uploadArtifacts
              - method: google.devtools.artifactregistry.v1.ArtifactRegistry.GetRepository
          - serviceName: storage.googleapis.com
            methodSelectors:
              - method: google.storage.objects.get
    # Break-glass: SRE on-call from a compliant device, read-only on logs.
    - ingressFrom:
        identities:
          - group:platform-sre@example.com
        sources:
          - accessLevel: accessPolicies/418872341190/accessLevels/trusted_corp_device
      ingressTo:
        resources:
          - ALL_RESOURCES
        operations:
          - serviceName: logging.googleapis.com
            methodSelectors:
              - method: google.logging.v2.LoggingServiceV2.ListLogEntries
  egressPolicies:
    # Publish anonymised, aggregated metrics to the partner analytics project.
    - egressFrom:
        identities:
          - serviceAccount:metrics-exporter@prod-analytics-8872.iam.gserviceaccount.com
      egressTo:
        resources:
          - projects/990022114567   # partner-analytics-9900
        operations:
          - serviceName: bigquery.googleapis.com
            methodSelectors:
              - method: google.cloud.bigquery.v2.JobService.InsertJob
```

Desplegá primero en **dry-run**. Esto no es opcional en producción:

```bash
$ gcloud access-context-manager perimeters dry-run create prod_data \
    --policy=418872341190 --perimeter-title=prod_data \
    --perimeter-type=regular \
    --perimeter-resources=projects/887100211934,projects/887100211935,projects/887100211936 \
    --perimeter-restricted-services=storage.googleapis.com,bigquery.googleapis.com,cloudkms.googleapis.com
Create request issued for: [prod_data]
Waiting for operation [operations/accessPolicies/418872341190/servicePerimeters/
prod_data/create/1757308811] to complete...done.
Created dry-run spec for Service Perimeter [prod_data].
```

Dejalo correr 7–14 días, después leé qué *se habría* roto:

```bash
$ gcloud logging read '
    protoPayload.metadata.dryRun="true" AND
    protoPayload.status.details.violations.type="SERVICE_PERIMETER"' \
    --project=prod-payments-8871 --limit=3 --format=json
[
  {
    "protoPayload": {
      "@type": "type.googleapis.com/google.cloud.audit.AuditLog",
      "authenticationInfo": {
        "principalEmail": "legacy-etl@corp-dw-3301.iam.gserviceaccount.com"
      },
      "methodName": "google.storage.objects.list",
      "serviceName": "storage.googleapis.com",
      "resourceName": "projects/_/buckets/prod-payments-ledger",
      "metadata": {
        "dryRun": "true",
        "violationReason": "NO_MATCHING_ACCESS_LEVEL",
        "securityPolicyInfo": {
          "servicePerimeterName": "accessPolicies/418872341190/servicePerimeters/prod_data"
        }
      },
      "status": {
        "code": 7,
        "message": "Request is prohibited by organization's policy.",
        "details": [{
          "violations": [{
            "type": "SERVICE_PERIMETER",
            "description": "Request blocked by VPC Service Controls."
          }],
          "uniqueId": "8c1f0b2d-7a4e-4c11-9f3a-6d2e5b7c0a91"
        }]
      }
    },
    "timestamp": "2026-09-02T04:15:07.442Z"
  }
]
```

Esa salida es todo el flujo de trabajo: una service account de ETL heredada que habías olvidado está leyendo el libro mayor de producción. Ahora tenés una decisión —agregar una regla de ingreso, o arreglar el pipeline— tomada **antes** de romperlo. Después, aplicá:

```bash
$ gcloud access-context-manager perimeters dry-run enforce prod_data \
    --policy=418872341190
Enforce request issued for: [prod_data]
Waiting for operation [...]...done.
Enforced dry-run spec for Service Perimeter [prod_data].
```

Confirmá que el control ahora muerde:

```bash
$ gsutil cp gs://prod-payments-ledger/2026-09/settlement.parquet gs://my-personal-scratch/
AccessDeniedException: 403 Request is prohibited by organization's policy.
vpcServiceControlsUniqueIdentifier: 8c1f0b2d-7a4e-4c11-9f3a-6d2e5b7c0a91
```

**IAM dijo que sí. VPC Service Controls dijo que no.** Eso es defensa en profundidad en una sola transcripción de terminal.

### 4.4 Cloud Armor — defensa L7 en el edge

`armor/prod-edge-policy.yaml` (forma exportable/importable):
```yaml
name: prod-edge-policy
description: "Edge WAF + rate limiting + geo controls for the public payments API."
type: CLOUD_ARMOR
adaptiveProtectionConfig:
  layer7DdosDefenseConfig:
    enable: true
    ruleVisibility: STANDARD
advancedOptionsConfig:
  jsonParsing: STANDARD
  logLevel: VERBOSE
rules:
  - priority: 1000
    description: "Block sanctioned/embargoed jurisdictions at the edge."
    match:
      expr:
        expression: "origin.region_code in ['KP','IR','SY','CU']"
    action: deny(403)

  - priority: 1100
    description: "OWASP CRS: SQL injection, sensitivity 1 (low false positives)."
    match:
      expr:
        expression: "evaluatePreconfiguredWaf('sqli-v33-stable', {'sensitivity': 1})"
    action: deny(403)

  - priority: 1200
    description: "OWASP CRS: cross-site scripting."
    match:
      expr:
        expression: "evaluatePreconfiguredWaf('xss-v33-stable', {'sensitivity': 1})"
    action: deny(403)

  - priority: 1300
    description: "OWASP CRS: local/remote file inclusion."
    match:
      expr:
        expression: "evaluatePreconfiguredWaf('lfi-v33-stable', {'sensitivity': 1})"
    action: deny(403)

  - priority: 1400
    description: "Known-bad: log4j / RCE probing."
    match:
      expr:
        expression: "evaluatePreconfiguredWaf('cve-canary', {'sensitivity': 1})"
    action: deny(403)

  - priority: 2000
    description: "Per-IP rate limit on the auth endpoint: credential stuffing."
    match:
      expr:
        expression: "request.path.matches('/api/v1/auth/')"
    action: rate_based_ban
    rateLimitOptions:
      conformAction: allow
      exceedAction: deny(429)
      enforceOnKey: IP
      rateLimitThreshold:
        count: 20
        intervalSec: 60
      banDurationSec: 900
      banThreshold:
        count: 100
        intervalSec: 600

  - priority: 2100
    description: "Global per-IP ceiling on the rest of the API."
    match:
      expr:
        expression: "true"
    action: throttle
    rateLimitOptions:
      conformAction: allow
      exceedAction: deny(429)
      enforceOnKey: IP
      rateLimitThreshold:
        count: 600
        intervalSec: 60

  - priority: 2147483647
    description: "Default rule: allow."
    match:
      versionedExpr: SRC_IPS_V1
      config:
        srcIpRanges: ["*"]
    action: allow
```

```bash
$ gcloud compute security-policies import prod-edge-policy \
    --source=armor/prod-edge-policy.yaml --global
Importing security policy [prod-edge-policy]...done.

$ gcloud compute backend-services update payments-api-backend \
    --security-policy=prod-edge-policy --global
Updated [https://www.googleapis.com/compute/v1/projects/prod-payments-8871/global/backendServices/payments-api-backend].

$ gcloud compute security-policies describe prod-edge-policy --global \
    --format="table(rules.priority,rules.action,rules.description)" | head -8
PRIORITY     ACTION           DESCRIPTION
1000         deny(403)        Block sanctioned/embargoed jurisdictions at the edge.
1100         deny(403)        OWASP CRS: SQL injection, sensitivity 1 (low false positives).
1200         deny(403)        OWASP CRS: cross-site scripting.
1300         deny(403)        OWASP CRS: local/remote file inclusion.
1400         deny(403)        Known-bad: log4j / RCE probing.
2000         rate_based_ban   Per-IP rate limit on the auth endpoint: credential stuffing.
2100         throttle         Global per-IP ceiling on the rest of the API.
```

> **Disciplina de despliegue:** desplegá cada regla de WAF primero con `--preview` (o `action: preview`), leé `jsonPayload.enforcedSecurityPolicy.outcome` en los logs del balanceador de carga, y recién después aplicala. Una regla `sqli-v33-stable` con sensibilidad 4 va a bloquear el primer día las query strings legítimas de tu propio equipo de analítica.

### 4.5 Clúster de GKE endurecido + Binary Authorization (capa de cadena de suministro)

```bash
$ gcloud container clusters create-auto prod-payments \
    --project=prod-payments-8871 \
    --region=europe-west1 \
    --enable-private-nodes \
    --enable-master-authorized-networks \
    --master-authorized-networks=203.0.113.0/24 \
    --binauthz-evaluation-mode=PROJECT_SINGLETON_POLICY_ENFORCE \
    --enable-google-cloud-access \
    --workload-pool=prod-payments-8871.svc.id.goog \
    --database-encryption-key=projects/prod-kms-8873/locations/europe-west1/keyRings/gke/cryptoKeys/etcd-cmek \
    --logging=SYSTEM,WORKLOAD \
    --monitoring=SYSTEM
Creating cluster prod-payments in europe-west1... Cluster is being health-checked...done.
kubeconfig entry generated for prod-payments.
NAME           LOCATION      MASTER_VERSION      MASTER_IP     MACHINE_TYPE  NODE_VERSION        NUM_NODES  STATUS
prod-payments  europe-west1  1.32.4-gke.1106000  10.24.0.2     e2-medium     1.32.4-gke.1106000  3          RUNNING
```

`binauthz/policy.yaml`
```yaml
defaultAdmissionRule:
  evaluationMode: REQUIRE_ATTESTATION
  enforcementMode: ENFORCED_BLOCK_AND_AUDIT_LOG
  requireAttestationsBy:
    - projects/prod-payments-8871/attestors/built-by-cloud-build
    - projects/prod-payments-8871/attestors/vuln-scan-passed

globalPolicyEvaluationMode: ENABLE

admissionWhitelistPatterns:
  - namePattern: gke.gcr.io/*
  - namePattern: gcr.io/gke-release/*
  - namePattern: europe-docker.pkg.dev/prod-payments-8871/base-images/*

clusterAdmissionRules:
  europe-west1.prod-payments:
    evaluationMode: REQUIRE_ATTESTATION
    enforcementMode: ENFORCED_BLOCK_AND_AUDIT_LOG
    requireAttestationsBy:
      - projects/prod-payments-8871/attestors/built-by-cloud-build
      - projects/prod-payments-8871/attestors/vuln-scan-passed
      - projects/prod-payments-8871/attestors/change-approved

istioServiceIdentityAdmissionRules: {}
```

```bash
$ gcloud container binauthz policy import binauthz/policy.yaml \
    --project=prod-payments-8871
Updated policy [projects/prod-payments-8871/policy].

$ kubectl run rogue --image=docker.io/library/nginx:latest
Error from server (VIOLATES_POLICY): admission webhook
"imagepolicywebhook.image-policy.k8s.io" denied the request: Image
docker.io/library/nginx:latest denied by Binary Authorization cluster admission
rule for europe-west1.prod-payments. Denied by attestor. Image
docker.io/library/nginx:latest denied by attestor
projects/prod-payments-8871/attestors/built-by-cloud-build: No attestations found
that were valid and signed by a key trusted by the attestor
```

La carga de trabajo endurecida correspondiente — notá que **cada campo acá es una capa distinta**:

`k8s/payments-api.yaml`
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: payments
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: payments-api
  namespace: payments
  annotations:
    # Workload Identity Federation: no service account keys exist to be stolen.
    iam.gke.io/gcp-service-account: payments-api@prod-payments-8871.iam.gserviceaccount.com
automountServiceAccountToken: false
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payments-api
  namespace: payments
  labels:
    app: payments-api
spec:
  replicas: 6
  selector:
    matchLabels:
      app: payments-api
  template:
    metadata:
      labels:
        app: payments-api
    spec:
      serviceAccountName: payments-api
      automountServiceAccountToken: true
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: payments-api
      containers:
        - name: api
          # Digest-pinned. Tags are mutable; digests are not.
          image: europe-docker.pkg.dev/prod-payments-8871/apps/payments-api@sha256:9f2c1ab4d3e7885b0c1a6f4d2e9b7c3a5d8e1f0b4c7a2d9e6f3b8c5a1d4e7f0b
          ports:
            - name: http
              containerPort: 8443
          securityContext:
            allowPrivilegeEscalation: false
            privileged: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: "500m"
              memory: "512Mi"
              ephemeral-storage: "1Gi"
            limits:
              cpu: "2"
              memory: "2Gi"
              ephemeral-storage: "2Gi"
          env:
            - name: KMS_KEY
              value: projects/prod-kms-8873/locations/europe-west1/keyRings/app/cryptoKeys/pan-tokenizer
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: cache
              mountPath: /var/cache/app
          livenessProbe:
            httpGet: { path: /healthz, port: http, scheme: HTTPS }
            initialDelaySeconds: 10
            periodSeconds: 10
          readinessProbe:
            httpGet: { path: /readyz, port: http, scheme: HTTPS }
            initialDelaySeconds: 5
            periodSeconds: 5
      volumes:
        - name: tmp
          emptyDir: { medium: Memory, sizeLimit: 128Mi }
        - name: cache
          emptyDir: { sizeLimit: 512Mi }
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: payments
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: payments-api-allow
  namespace: payments
spec:
  podSelector:
    matchLabels:
      app: payments-api
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress
      ports:
        - protocol: TCP
          port: 8443
  egress:
    # DNS only to kube-dns.
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    # Google APIs via Private Google Access only (restricted VIP).
    - to:
        - ipBlock:
            cidr: 199.36.153.4/30
      ports:
        - protocol: TCP
          port: 443
    # Ledger database, explicit.
    - to:
        - podSelector:
            matchLabels:
              app: ledger-db
      ports:
        - protocol: TCP
          port: 5432
```

Notá la regla de egreso hacia `199.36.153.4/30` — el VIP de **restricted.googleapis.com**. Combinada con el perímetro de VPC-SC de §4.3, un Pod comprometido no puede alcanzar endpoints de `googleapis.com` fuera del perímetro *aunque* robe un token válido. Dos capas independientes, cualquiera de las cuales por sí sola sería insuficiente.

### 4.6 Security Command Center → pipeline de detección

```bash
$ gcloud scc notifications create scc-critical-findings \
    --organization=123456789012 \
    --pubsub-topic=projects/central-audit-9021/topics/scc-findings \
    --filter='state="ACTIVE" AND (severity="CRITICAL" OR severity="HIGH")'
Created notification config
 [organizations/123456789012/notificationConfigs/scc-critical-findings].

$ gcloud scc findings list 123456789012 \
    --filter='state="ACTIVE" AND severity="HIGH"' \
    --format="table(finding.category, finding.resourceName.basename(), finding.eventTime)" \
    --limit=6
CATEGORY                          RESOURCE_NAME                 EVENT_TIME
PUBLIC_BUCKET_ACL                 legacy-marketing-assets       2026-09-06T22:14:03Z
OVER_PRIVILEGED_SERVICE_ACCOUNT   ci-runner@ci-shared-4410      2026-09-07T01:02:55Z
NON_ORG_IAM_MEMBER                prod-analytics-8872           2026-09-07T03:41:12Z
OPEN_FIREWALL                     allow-ssh-from-anywhere       2026-09-07T06:20:31Z
MFA_NOT_ENFORCED                  contractor-group@example.com  2026-09-07T09:55:48Z
WEAK_SSL_POLICY                   ext-lb-frontend               2026-09-07T11:08:19Z
```

`scc/export-to-bigquery.tf`
```hcl
resource "google_scc_source" "custom" {
  organization = var.org_id
  display_name = "platform-sre-custom-detectors"
  description  = "Findings emitted by internal SRE tooling."
}

resource "google_bigquery_dataset" "scc" {
  project                     = "central-audit-9021"
  dataset_id                  = "scc_findings"
  location                    = "EU"
  default_table_expiration_ms = null

  default_encryption_configuration {
    kms_key_name = "projects/prod-kms-8873/locations/europe/keyRings/audit/cryptoKeys/bq-cmek"
  }
}

resource "google_scc_v2_organization_scc_big_query_export" "findings" {
  name         = "scc-to-bq"
  organization = var.org_id
  location     = "global"
  dataset      = google_bigquery_dataset.scc.id
  description  = "All active findings, continuously exported for SLO reporting."
  filter       = "state=\"ACTIVE\""
}
```

Ahora los hallazgos se vuelven un SLO consultable, no un tablero que alguien tal vez abra:

```sql
-- Mean time to remediate, by severity, last 90 days.
SELECT
  finding.severity,
  COUNT(*) AS findings,
  ROUND(AVG(TIMESTAMP_DIFF(
    finding.mute_update_time, finding.event_time, HOUR)), 1) AS mttr_hours,
  ROUND(APPROX_QUANTILES(TIMESTAMP_DIFF(
    finding.mute_update_time, finding.event_time, HOUR), 100)[OFFSET(95)], 1) AS p95_hours
FROM `central-audit-9021.scc_findings.findings`
WHERE finding.event_time > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY)
  AND finding.state = 'INACTIVE'
GROUP BY finding.severity
ORDER BY
  CASE finding.severity
    WHEN 'CRITICAL' THEN 1 WHEN 'HIGH' THEN 2
    WHEN 'MEDIUM' THEN 3 ELSE 4 END;
```

```
+----------+----------+------------+-----------+
| severity | findings | mttr_hours | p95_hours |
+----------+----------+------------+-----------+
| CRITICAL |       23 |        6.4 |      21.0 |
| HIGH     |      187 |       38.2 |     144.0 |
| MEDIUM   |      904 |      211.7 |     720.0 |
+----------+----------+------------+-----------+
```

### 4.7 Access Transparency y Access Approval — la capa del "quién vigila a Google"

Este es el control que responde la pregunta del directorio: *"¿qué impide que un ingeniero de Google lea nuestros datos?"*

- **Access Transparency** emite una **entrada de log de auditoría casi en tiempo real** cada vez que personal de Google accede a tu contenido — con el motivo (p. ej. un número de ticket de soporte), la ubicación de la oficina base de quien accede y el recurso tocado.
- **Access Approval** va más allá: Google debe **solicitar tu aprobación explícita** antes de que ese acceso ocurra. Podés conectarlo a Pub/Sub y exigir que una persona de guardia haga clic en aprobar.

```bash
$ gcloud access-approval settings update \
    --project=prod-payments-8871 \
    --notification_emails='security-oncall@example.com' \
    --enrolled_services=all
name: projects/prod-payments-8871/accessApprovalSettings
notificationEmails:
- security-oncall@example.com
enrolledServices:
- cloudProduct: all
  enrollmentLevel: BLOCK_ALL
enrolledAncestor: false

$ gcloud access-approval requests list --project=prod-payments-8871 --state=pending
NAME                                                              REQUESTED_REASON             REQUESTED_EXPIRATION
projects/prod-payments-8871/approvalRequests/abcdef0123456789     CUSTOMER_INITIATED_SUPPORT   2026-09-09T14:00:00Z

$ gcloud access-approval requests approve \
    projects/prod-payments-8871/approvalRequests/abcdef0123456789
approve:
  approveTime: '2026-09-08T12:41:09Z'
  expireTime: '2026-09-09T14:00:00Z'
```

Consultá el log de transparencia:

```bash
$ gcloud logging read \
    'protoPayload.@type="type.googleapis.com/google.cloud.audit.TransparencyLog"' \
    --project=prod-payments-8871 --limit=1 --format=json
[
  {
    "protoPayload": {
      "@type": "type.googleapis.com/google.cloud.audit.AuditLog",
      "methodName": "GoogleInternal.Read",
      "resourceName": "projects/prod-payments-8871/buckets/prod-payments-ledger",
      "metadata": {
        "@type": "type.googleapis.com/google.cloud.audit.TransparencyLog",
        "accesses": [{
          "principalOfficeCountry": "IE",
          "principalEmployingEntity": "Google_LLC",
          "principalPhysicalLocationCountry": "IE",
          "accessReason": "Customer-initiated support ticket 44219087.",
          "accessApprovalRequest": "projects/prod-payments-8871/approvalRequests/abcdef0123456789"
        }],
        "productName": ["Cloud Storage"]
      }
    },
    "timestamp": "2026-09-08T12:52:31.019Z"
  }
]
```

**Valor de negocio:** esta es una respuesta *auditable contractual y técnicamente* frente a un regulador, que reemplaza una carta de aseguramiento del proveedor por una línea de log.

---

## 5. Verificación y diagnóstico de fallos

### 5.1 Escalera de verificación — ejecutá esto en orden

```bash
# 1. Are the preventive controls actually in force on every leaf project?
$ for p in $(gcloud projects list --format="value(projectId)" --filter="parent.id=887100"); do
>   v=$(gcloud org-policies describe compute.vmExternalIpAccess \
>        --project="$p" --effective --format="value(spec.rules[0].denyAll)" 2>/dev/null)
>   printf "%-28s external-ip-denied=%s\n" "$p" "${v:-NOT_SET}"
> done
prod-payments-8871           external-ip-denied=True
prod-analytics-8872          external-ip-denied=True
prod-kms-8873                external-ip-denied=True
sandbox-legacy-8899          external-ip-denied=NOT_SET     # <-- investigate

# 2. Any service account keys in existence? (they should not exist)
$ gcloud asset search-all-resources \
    --scope=organizations/123456789012 \
    --asset-types=iam.googleapis.com/ServiceAccountKey \
    --query='NOT name:"*/keys/*system-managed*"' \
    --format="table(project, displayName, createTime)"
PROJECT               DISPLAY_NAME                       CREATE_TIME
corp-dw-3301          legacy-etl user-managed key        2024-03-11T08:22:41Z

# 3. Anything publicly reachable?
$ gcloud asset search-all-iam-policies \
    --scope=organizations/123456789012 \
    --query='policy:("allUsers" OR "allAuthenticatedUsers")' \
    --format="table(resource, policy.bindings.role)"
RESOURCE                                                    ROLE
//storage.googleapis.com/legacy-marketing-assets            ['roles/storage.objectViewer']

# 4. Is the perimeter enforcing, not just dry-run?
$ gcloud access-context-manager perimeters describe prod_data \
    --policy=418872341190 --format="value(status.restrictedServices.len(), spec)"
9

# 5. Is Binary Authorization enforcing on every cluster?
$ gcloud container clusters list --format="table(name,location,binaryAuthorization.evaluationMode)"
NAME           LOCATION      EVALUATION_MODE
prod-payments  europe-west1  PROJECT_SINGLETON_POLICY_ENFORCE
dev-scratch    europe-west1  DISABLED
```

### 5.2 Síntoma → causa → comando

| Síntoma | Causa más probable | Comando de diagnóstico |
|---|---|---|
| `403 Request is prohibited by organization's policy` + `vpcServiceControlsUniqueIdentifier` | Denegación del perímetro de VPC-SC | `gcloud logging read 'protoPayload.status.details.violations.type="SERVICE_PERIMETER"' --limit=5 --format=json` y hacer coincidir el `uniqueId` |
| `403` **sin** identificador único | Denegación simple de IAM | `gcloud policy-troubleshoot iam <RESOURCE> --principal-email=<SA> --permission=<PERM>` |
| `Constraint constraints/... violated` al momento de crear | Control preventivo de Org Policy | `gcloud org-policies describe <CONSTRAINT> --project=<P> --effective` |
| Pod trabado en `ImagePullBackOff`, los eventos mencionan `VIOLATES_POLICY` | Binary Authorization, sin atestación | `gcloud container binauthz attestations list --attestor=<A> --artifact-url=<IMAGE_DIGEST_URL>` |
| La app puede resolver `googleapis.com` pero cada llamada expira | NetworkPolicy de egreso o falta la ruta de Private Google Access | `gcloud compute networks subnets describe <SUBNET> --region=<R> --format="value(privateIpGoogleAccess)"` |
| `KMS_KEY_DISABLED` / datos súbitamente ilegibles | Clave CMEK deshabilitada, destruida, o EKM inalcanzable | `gcloud kms keys versions list --key=<K> --keyring=<KR> --location=<L>` |
| Usuarios legítimos bloqueados en una app protegida por IAP | Access Level demasiado estricto (política de dispositivo / región) | `gcloud logging read 'resource.type="iap_web" AND jsonPayload.status="DENIED"' --limit=5` |
| Cloud Armor devuelve 403 sobre tráfico válido | Falso positivo del WAF preconfigurado | filtrar los logs del LB por `jsonPayload.enforcedSecurityPolicy.name` e inspeccionar `matchedFieldValue` |
| Aparecen hallazgos en SCC pero no se dispara ninguna alerta | Filtro de notificación demasiado estrecho, o falta IAM de Pub/Sub | `gcloud scc notifications describe <ID> --organization=<ORG>` |

### 5.3 Diagnóstico resuelto — el triaje de los cuatro 403

La confusión de producción más común es *qué capa dijo que no*. Google Cloud te da un discriminador determinista; usalo.

```bash
# Step 1 — capture the raw error verbatim. The identifier field is the tell.
$ gsutil ls gs://prod-payments-ledger/
AccessDeniedException: 403 Request is prohibited by organization's policy.
vpcServiceControlsUniqueIdentifier: 4d0a91cc-2b17-4a83-b5e6-77f1c8a20d34
#            ^^^^^^^^^^^^^^^^^^^^^ present  => VPC Service Controls
#                                   absent  => IAM, Org Policy, or Context-Aware Access

# Step 2 — VPC-SC path: resolve the identifier to the exact violated rule.
$ gcloud logging read \
    'protoPayload.status.details.uniqueId="4d0a91cc-2b17-4a83-b5e6-77f1c8a20d34"' \
    --organization=123456789012 --limit=1 \
    --format="value(protoPayload.metadata.violationReason,
                    protoPayload.metadata.securityPolicyInfo.servicePerimeterName,
                    protoPayload.authenticationInfo.principalEmail,
                    protoPayload.methodName)"
NO_MATCHING_ACCESS_LEVEL   accessPolicies/418872341190/servicePerimeters/prod_data   analyst@example.com   google.storage.objects.list

# Step 3 — IAM path (no unique identifier): use Policy Troubleshooter, not guesswork.
$ gcloud policy-troubleshoot iam \
    //cloudresourcemanager.googleapis.com/projects/prod-payments-8871 \
    --principal-email=analyst@example.com \
    --permission=storage.objects.list
access: NOT_GRANTED
explainedPolicies:
- access: NOT_GRANTED
  fullResourceName: //cloudresourcemanager.googleapis.com/projects/prod-payments-8871
  bindingExplanations:
  - access: NOT_GRANTED
    role: roles/storage.objectViewer
    rolePermission: ROLE_PERMISSION_INCLUDED
    memberships:
      'user:analyst@example.com':
        membership: MEMBERSHIP_NOT_INCLUDED
    condition:
      expression: request.time < timestamp("2026-08-31T00:00:00Z")
      title: temporary-analyst-access
  relevance: HIGH
```

La condición expiró el 2026-08-31. Diagnosticado en tres comandos, sin adivinar y sin la remediación demasiado amplia de "dale Editor y listo".

### 5.4 Los modos de fallo de la propia defensa en profundidad

La seguridad por capas tiene sus propias patologías en producción. Nombralas para poder diseñar contra ellas:

| Patología | Cómo se manifiesta | Mitigación |
|---|---|---|
| **Colapso de la depurabilidad** | Cuatro capas pueden devolver 403 cada una; la guardia no puede distinguir cuál | Estandarizar el triaje según §5.3; registrar el campo discriminante en tu middleware de manejo de errores |
| **Amplificación del cambio** | Agregar un solo consumidor nuevo exige ediciones en IAM + VPC-SC + NetworkPolicy + Cloud Armor | Un módulo de Terraform que emita los cuatro a partir de una sola entrada |
| **Dry-run nunca aplicado** | El perímetro queda en dry-run durante 8 meses | Alertar sobre `spec != status` para cualquier perímetro con más de 30 días |
| **Podredumbre de excepciones** | Las excepciones temporales de org policy se vuelven permanentes | Cada excepción lleva una `condition` con una marca de tiempo de expiración (ver §4.1) |
| **Fatiga de alertas** | Hallazgos MEDIUM de SCC con más de 900 abiertos | Enrutar solo CRITICAL/HIGH al paging; MEDIUM a un backlog con un SLO |
| **Acoplamiento de disponibilidad** | Una caída de EKM/CMEK se vuelve una caída del plano de datos | Key rings multirregión, game day de indisponibilidad de claves probado |

---

## 6. Mapeo de controles técnicos al lenguaje de negocio del examen

El examen Cloud Digital Leader pregunta estas cosas en clave de negocio. Entrená la traducción en ambos sentidos.

| Enunciado al estilo del examen | Control correcto | Por qué |
|---|---|---|
| "Los empleados deben acceder a apps internas desde cualquier lugar sin VPN, con la postura del dispositivo verificada" | **BeyondCorp Enterprise / IAP** | Zero trust: identidad + contexto reemplazan a la ubicación en la red |
| "Impedir que un empleado autorizado copie datos de producción a un proyecto personal" | **VPC Service Controls** | IAM lo permite; solo un perímetro de recursos bloquea la exfiltración |
| "El regulador exige que mantengamos el control exclusivo de las claves de cifrado, fuera de Google" | **Cloud EKM** (+ Key Access Justifications) | Gestor de claves externo; Google no puede descifrar sin tu concesión |
| "Debemos saber, y aprobar, cada vez que el soporte de Google toca nuestros datos" | **Access Transparency + Access Approval** | Logs casi en tiempo real más aprobación previa explícita |
| "Nuestra API pública está siendo inundada y scrapeada" | **Cloud Armor** (Adaptive Protection, rate limiting, WAF) | Absorbido en el edge global de Google antes de que llegue a tus backends |
| "Solo pueden correr en producción imágenes construidas por nuestro pipeline y escaneadas limpias" | **Binary Authorization** + Software Delivery Shield | Aplicación de atestaciones en el momento del despliegue |
| "Necesitamos años de telemetría de seguridad consultable sin penalizaciones de ingesta por GB" | **Google SecOps (Chronicle)** | Desacopla el costo de retención de la calidad de detección; inteligencia de Mandiant aplicada retroactivamente |
| "Los datos sensibles de clientes no pueden salir de la UE, y el personal de soporte debe estar basado en la UE" | **Assured Workloads** (+ `gcp.resourceLocations`) | Residencia y controles de personal aplicados técnicamente |
| "Dos hospitales quieren entrenar un modelo conjunto sin exponer los datos del otro" | **Confidential Computing** | Datos cifrados en uso; ni la otra parte ni Google ven la memoria ajena |
| "Encontrar y clasificar PII en nuestro warehouse antes de abrirlo a los analistas" | **Sensitive Data Protection (Cloud DLP)** | Descubrimiento, clasificación, desidentificación, tokenización |
| "Reducir nuestra prima de ciberseguro demostrando nuestra postura" | **Risk Protection Program** (informe de Risk Manager) | La postura medida se vuelve una cantidad asegurable y tarifada |
| "Los ejecutivos son el principal objetivo de phishing" | **Titan Security Keys** / MFA resistente a phishing, Advanced Protection | Las llaves FIDO por hardware derrotan el phishing de credenciales |

### 6.1 Las tres frases que el examen está evaluando

1. **Google no es un proveedor alrededor del cual asegurás; Google es una organización de seguridad cuya ingeniería heredás.** Las capas 1–2 (silicio, arranque, backbone, DDoS) se absorben con costo de configuración cero.
2. **Defensa en profundidad significa que el fallo de un solo control no es fatal** — IAM, VPC Service Controls, Org Policy, Cloud Armor, Binary Authorization y Confidential Computing son *ortogonales*, y cada uno atrapa lo que los otros estructuralmente no pueden.
3. **El valor de negocio es medible en cuatro monedas:** headcount evitado, menor time-to-market en segmentos regulados, menor probabilidad de brecha y menor radio de impacto, y *nuevos ingresos* provenientes de cargas de trabajo (multiparte, soberanas, reguladas) que antes era imposible ejecutar.

---

## 7. Referencias

**Objetivo del examen**
- Cloud Digital Leader exam guide — https://services.google.com/fh/files/misc/cloud_digital_leader_exam_guide_english.pdf
- Cloud Digital Leader certification — https://cloud.google.com/learn/certification/cloud-digital-leader

**Modelo de seguridad y responsabilidad compartida**
- Google security overview / infrastructure security design — https://cloud.google.com/docs/security/infrastructure/design
- Shared responsibility and shared fate — https://cloud.google.com/architecture/framework/security/shared-responsibility-shared-fate
- Google Cloud security best practices center — https://cloud.google.com/security/best-practices
- Trust and security — https://cloud.google.com/security

**Hardware, boot y computación confidencial**
- Titan security key / hardware root of trust — https://cloud.google.com/blog/products/identity-security/titan-in-depth-security-in-plaintext
- Shielded VM — https://cloud.google.com/security/products/shielded-vm
- Confidential Computing — https://cloud.google.com/security/products/confidential-computing
- Confidential GKE Nodes — https://cloud.google.com/kubernetes-engine/docs/how-to/confidential-gke-nodes

**Red y edge**
- Cloud Armor — https://cloud.google.com/security/products/armor
- Cloud Armor security policies overview — https://cloud.google.com/armor/docs/security-policy-overview
- Adaptive Protection — https://cloud.google.com/armor/docs/adaptive-protection-overview
- Preconfigured WAF rules (OWASP CRS) — https://cloud.google.com/armor/docs/waf-rules
- Encryption in transit — https://cloud.google.com/docs/security/encryption-in-transit
- ALTS (Application Layer Transport Security) — https://cloud.google.com/docs/security/encryption-in-transit/application-layer-transport-security

**Identidad y zero trust**
- BeyondCorp Enterprise — https://cloud.google.com/beyondcorp-enterprise
- Identity-Aware Proxy — https://cloud.google.com/security/products/iap
- Context-Aware Access — https://cloud.google.com/beyondcorp-enterprise/docs/context-aware-access
- IAM overview — https://cloud.google.com/iam/docs/overview
- Workload Identity Federation for GKE — https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity
- Policy Troubleshooter — https://cloud.google.com/policy-intelligence/docs/troubleshoot-access

**Perímetro de servicios y política organizacional**
- VPC Service Controls overview — https://cloud.google.com/vpc-service-controls/docs/overview
- VPC-SC dry-run mode — https://cloud.google.com/vpc-service-controls/docs/dry-run-mode
- VPC-SC troubleshooting — https://cloud.google.com/vpc-service-controls/docs/troubleshooting
- Organization Policy Service — https://cloud.google.com/resource-manager/docs/organization-policy/overview
- Organization policy constraints reference — https://cloud.google.com/resource-manager/docs/organization-policy/org-policy-constraints
- Private Google Access / restricted VIP — https://cloud.google.com/vpc/docs/configure-private-google-access

**Datos y claves**
- Default encryption at rest — https://cloud.google.com/docs/security/encryption/default-encryption
- Customer-managed encryption keys (CMEK) — https://cloud.google.com/kms/docs/cmek
- Cloud External Key Manager (Cloud EKM) — https://cloud.google.com/kms/docs/ekm
- Key Access Justifications — https://cloud.google.com/assured-workloads/key-access-justifications/docs/overview
- Cloud HSM — https://cloud.google.com/kms/docs/hsm
- Sensitive Data Protection — https://cloud.google.com/security/products/sensitive-data-protection

**Cadena de suministro de software**
- Binary Authorization — https://cloud.google.com/binary-authorization/docs/overview
- Binary Authorization policy reference — https://cloud.google.com/binary-authorization/docs/policy-yaml-reference
- Software Delivery Shield — https://cloud.google.com/software-supply-chain-security/docs/overview
- GKE cluster hardening guide — https://cloud.google.com/kubernetes-engine/docs/how-to/hardening-your-cluster

**Detección, respuesta y transparencia**
- Security Command Center — https://cloud.google.com/security/products/security-command-center
- SCC findings and notifications — https://cloud.google.com/security-command-center/docs/how-to-notifications
- Google Security Operations (Chronicle) — https://cloud.google.com/security/products/security-operations
- Mandiant — https://cloud.google.com/security/mandiant
- Access Transparency — https://cloud.google.com/assured-workloads/access-transparency/docs/overview
- Access Approval — https://cloud.google.com/assured-workloads/access-approval/docs/overview
- Cloud Audit Logs — https://cloud.google.com/logging/docs/audit

**Cumplimiento y soberanía**
- Compliance resource center — https://cloud.google.com/security/compliance
- Compliance offerings / certifications — https://cloud.google.com/security/compliance/offerings
- Assured Workloads — https://cloud.google.com/security/products/assured-workloads
- Sovereign Cloud — https://cloud.google.com/sovereign-cloud
- Risk Protection Program — https://cloud.google.com/security/risk-protection-program