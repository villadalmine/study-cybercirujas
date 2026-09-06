# Ejercicios — 1.2 Describir los beneficios de usar servicios en la nube

**Certificación:** AZ-900 (versión de examen 2026-07-20) · **Peso en el examen:** 9.4
**Formato:** práctico. Cada comando de abajo es real y ejecutable. Las salidas que se muestran son representativas — los valores que devuelve tu suscripción son los que mandan, y parte del sentido de estos ejercicios es justamente que *la fuente de verdad es la plataforma, no la página de marketing*.

> **Advertencia de costo.** Los bloques 2, 4 y 7 crean recursos facturables (un VM Scale Set, storage accounts). El costo total, si lo terminás de una sentada, es menos de **USD 1**. El bloque 8 es el desmantelamiento — no lo saltees. Los bloques 1, 3 y 5 son de solo lectura y gratuitos.
>
> **Permisos.** Necesitás `Contributor` sobre un resource group más `Resource Policy Contributor` y `User Access Administrator` (u `Owner`) a nivel de suscripción para el bloque 6.

---

## Bloque 0 — Entorno y el modelo mental que vas a poner a prueba

**Objetivo:** conseguir un shell reproducible y fijar el vocabulario antes de medir nada.

Los cuatro beneficios sobre los que pregunta el AZ-900 no son eslóganes; cada uno es una *propiedad medible de la plataforma* con una perilla que podés girar:

| Beneficio | La propiedad que se afirma | Dónde la expone la plataforma |
|---|---|---|
| Alta disponibilidad | % del tiempo que el servicio responde | nivel de SLA, availability zones, fault/update domains |
| Escalabilidad | la capacidad sigue a la demanda | vertical (cambio de SKU) / horizontal (cantidad de instancias) |
| Fiabilidad y previsibilidad | sobrevive al fallo *y* se comporta igual mañana | opciones de redundancia, topes de rendimiento del SKU, budgets |
| Seguridad y gobernanza | los estados no conformes se previenen, no solo se reportan | efectos de Azure Policy, RBAC, Defender for Cloud |
| Manejabilidad | el estado deseado se declara, no se clickea | ARM/Bicep, autoscale, Monitor, Resource Health |

### Pasos

1. Verificá tus herramientas. Se asume Azure CLI 2.60+; `jq` se usa para dar forma al JSON.

   ```bash
   az version --output json | jq -r '."azure-cli"'
   jq --version
   ```

   ```
   2.67.0
   jq-1.7.1
   ```

2. Autenticate y fijá la suscripción de forma explícita. Nunca confíes en la predeterminada — una suscripción por defecto equivocada es la causa más común de "mis recursos desaparecieron".

   ```bash
   az login --only-show-errors >/dev/null
   az account list --query "[].{Name:name, Id:id, Default:isDefault}" --output table
   ```

   ```
   Name                      Id                                    Default
   ------------------------  ------------------------------------  ---------
   Visual Studio Enterprise  8f2c1b74-3d9a-4a1e-9f0b-2c7d5e6a1b33  True
   Production                1a0e6c52-77b4-4c1f-8e3d-90a4b2c11d55  False
   ```

3. Exportá las variables que reutiliza el resto de los ejercicios. Usar una sola región con soporte de zonas es un requisito estricto para los bloques 1, 2 y 4.

   ```bash
   export SUB=$(az account show --query id --output tsv)
   export LOC=eastus
   export RG=rg-az900-benefits
   az account set --subscription "$SUB"
   az group create --name "$RG" --location "$LOC" --tags course=az900 topic=1.2 owner="$USER" \
     --query "{name:name, location:location, state:properties.provisioningState}" --output json
   ```

   ```json
   {
     "name": "rg-az900-benefits",
     "location": "eastus",
     "state": "Succeeded"
   }
   ```

4. Confirmá que los resource providers que vas a necesitar estén registrados en esta suscripción. Un provider no registrado hace fallar los despliegues con un mensaje que parece un error de permisos pero no lo es.

   ```bash
   for p in Microsoft.Compute Microsoft.Storage Microsoft.Insights Microsoft.PolicyInsights Microsoft.ResourceHealth; do
     printf '%-28s %s\n' "$p" "$(az provider show --namespace $p --query registrationState --output tsv)"
   done
   ```

   ```
   Microsoft.Compute            Registered
   Microsoft.Storage            Registered
   Microsoft.Insights           Registered
   Microsoft.PolicyInsights     Registered
   Microsoft.ResourceHealth     NotRegistered
   ```

5. Registrá todo lo que haya vuelto como `NotRegistered`. El registro es asincrónico e idempotente.

   ```bash
   az provider register --namespace Microsoft.ResourceHealth --wait
   az provider show --namespace Microsoft.ResourceHealth --query registrationState --output tsv
   ```

   ```
   Registered
   ```

#### Comprobá tu comprensión

- **Q0.1** — Ejecutaste `az group create` dos veces con argumentos idénticos y obtuviste `Succeeded` las dos veces, sin error. ¿Qué propiedad de ARM hace que esto sea seguro, y por qué la misma garantía *no* se sostiene para `az vmss scale`?
- **Q0.2** — El registro de un resource provider es por suscripción, no por resource group. ¿Qué te dice eso sobre dónde vive el estado del plano de control del provider dentro de la jerarquía de recursos de Azure?

---

## Bloque 1 — Alta disponibilidad: derivar el SLA en vez de citarlo

**Objetivo:** dejar de tratar "99.99%" como un número que se memoriza. Vas a leer la topología de zonas desde la API, convertir un SLA en un presupuesto de caída y componer un SLA multiservicio — que es el cálculo que realmente decide arquitecturas.

### Pasos

1. Listá las regiones físicas que exponen availability zones. `availabilityZoneMappings` es la señal autoritativa; una región que no lo tiene no tiene AZs, y ninguna arquitectura va a conseguir el 99.99% ahí.

   ```bash
   az account list-locations \
     --query "[?metadata.regionType=='Physical' && availabilityZoneMappings != null].{Region:name, Display:displayName, Zones:length(availabilityZoneMappings)}" \
     --output table | head -15
   ```

   ```
   Region          Display              Zones
   --------------  -------------------  -------
   eastus          East US              3
   eastus2         East US 2            3
   westus2         West US 2            3
   westus3         West US 3            3
   northeurope     North Europe         3
   westeurope      West Europe          3
   brazilsouth     Brazil South         3
   southeastasia   Southeast Asia       3
   ```

2. Ahora inspeccioná el mapeo en sí. Este es el detalle que sorprende a la mayoría de la gente en producción.

   ```bash
   az account list-locations \
     --query "[?name=='$LOC'].availabilityZoneMappings[]" --output table
   ```

   ```
   LogicalZone    PhysicalZone
   -------------  --------------
   1              eastus-az1
   2              eastus-az3
   3              eastus-az2
   ```

   La zona lógica `1` en **tu** suscripción no es necesariamente la zona física `1` en la de otra persona. Azure aleatoriza el mapeo por suscripción para que los despliegues de los clientes se repartan de manera pareja entre datacenters. Dos suscripciones que despliegan ambas en la "zona 1" pueden caer en edificios distintos — por eso alinear zonas entre suscripciones requiere esta API, no una suposición.

3. Confirmá que el SKU de VM que pensás usar realmente se ofrece en las tres zonas. La disponibilidad de SKU es por zona, no por región.

   ```bash
   az vm list-skus --location "$LOC" --size Standard_D2s_v5 --resource-type virtualMachines \
     --query "[0].{Name:name, Zones:locationInfo[0].zones, Restrictions:restrictions[].reasonCode}" --output json
   ```

   ```json
   {
     "Name": "Standard_D2s_v5",
     "Zones": ["1", "2", "3"],
     "Restrictions": []
   }
   ```

   Un array `Restrictions` no vacío que contenga `NotAvailableForSubscription` significa que el SKU existe en la región pero tu suscripción no puede desplegarlo ahí — una restricción de capacidad o de cuota, y una causa muy común de que un diseño "zone-redundant" degrade silenciosamente a dos zonas.

4. Convertí los porcentajes de SLA en un presupuesto de caída. Los porcentajes no son intuitivos; los minutos sí.

   ```bash
   for sla in 99 99.9 99.95 99.99 99.999; do
     awk -v s="$sla" 'BEGIN {
       d = (100 - s) / 100
       printf "%-8s  %10.2f h/year  %10.2f min/month\n", s"%", d*8760, d*43800
     }'
   done
   ```

   ```
   99%           87.60 h/year      438.00 min/month
   99.9%          8.76 h/year       43.80 min/month
   99.95%         4.38 h/year       21.90 min/month
   99.99%         0.88 h/year        4.38 min/month
   99.999%        0.09 h/year        0.44 min/month
   ```

   El salto de 99.9% a 99.99% elimina ~39 minutos de caída mensual permitida. Eso es menos que un solo despliegue descuidado. Por eso "cuatro nueves" es un compromiso *operativo*, no solamente arquitectónico.

5. Calculá un **SLA compuesto** para una cadena de dependencias en serie — una capa web que debe llamar a una base de datos que debe llegar al storage. Los componentes en serie se *multiplican*.

   ```bash
   awk 'BEGIN {
     web = 0.9995; db = 0.9999; storage = 0.999
     c = web * db * storage
     printf "Composite: %.6f%%   Downtime: %.2f h/year\n", c*100, (1-c)*8760
   }'
   ```

   ```
   Composite: 99.840065%   Downtime: 14.01 h/year
   ```

   Tres SLAs de aspecto saludable producen un sistema peor que cualquiera de ellos. **Cada dependencia que agregás baja el techo.**

6. Ahora calculá la misma capa de storage desplegada como dos réplicas independientes detrás de un load balancer — componentes en *paralelo*, donde el sistema sobrevive si cualquiera de las dos vive.

   ```bash
   awk 'BEGIN {
     a = 0.999
     c = 1 - (1 - a) * (1 - a)
     printf "Redundant pair: %.6f%%   Downtime: %.2f min/year\n", c*100, (1-c)*525600
   }'
   ```

   ```
   Redundant pair: 99.999900%   Downtime: 0.53 min/year
   ```

   La aritmética asume que las dos réplicas fallan de manera **independiente**. Si ambas están en el mismo rack, comparten una alimentación eléctrica o leen el mismo registro corrupto del plano de control, el supuesto de independencia se derrumba y el número real vuelve hacia el 99.9%. Las availability zones existen precisamente para que ese supuesto de independencia sea defendible: energía, refrigeración y red separadas, dentro de una envolvente de latencia que todavía permite replicación sincrónica.

7. Contrastá las formas de despliegue y el nivel de SLA que compra cada una, directamente del documento de SLA ([Microsoft SLA for Online Services](https://www.microsoft.com/licensing/docs/view/Service-Level-Agreements-SLA-for-Online-Services)):

   | Forma de despliegue | SLA de conectividad de VM | Dominio de fallo que sobrevive |
   |---|---|---|
   | Una sola VM, discos de OS/datos Standard HDD | 95% | ninguno |
   | Una sola VM, discos de OS/datos Standard SSD | 99.5% | ninguno |
   | Una sola VM, Premium SSD o Ultra Disk | 99.9% | solo reinicio del host (vía live migration) |
   | 2+ VMs en un availability set | 99.95% | rack (fault domain) y parcheo de hosts (update domain) |
   | 2+ VMs en 2+ availability zones | 99.99% | edificio de datacenter |
   | Multirregión, activo/activo | no cubierto por un único SLA | caída regional |

#### Comprobá tu comprensión

- **Q1.1** — Tu suscripción reporta que la zona lógica `2` mapea a `eastus-az3`. Una suscripción socia despliega su base de datos en su propia zona lógica `2`. ¿Podés asumir que tu VM y su base de datos están en el mismo datacenter físico? ¿Cuál es la consecuencia operativa si asumís mal, en ambas direcciones (asumir que son la misma cuando son distintas, y que son distintas cuando son la misma)?
- **Q1.2** — Una sola VM con Premium SSD obtiene 99.9%. Dos VMs así en un availability set obtienen 99.95%. Dos en zonas distintas obtienen 99.99%. Explicá, en términos de *qué dominio de fallo elimina cada forma*, por qué el availability set vale apenas 0.05 puntos porcentuales más que la VM única mientras que el reparto por zonas vale otros 0.04.
- **Q1.3** — Recalculá el paso 5 reemplazando la capa de storage de 99.9% por una de 99.99%. ¿En cuántas horas por año mejora el compuesto? ¿Qué te dice eso sobre dónde invertir el esfuerzo en una cadena de dependencias?
- **Q1.4** — Un colega afirma "somos zone-redundant, así que estamos en 99.99%", pero `az vm list-skus` muestra el SKU restringido en la zona 3 y el scale set tiene 2 instancias que ambas cayeron en la zona 1. ¿Qué campo específico de la salida del paso 3 habría detectado esto antes de producción, y por qué la cantidad de instancias por sí sola no prueba el reparto entre zonas?

---

## Bloque 2 — Escalabilidad: el lazo de control de autoscale, y cómo oscila

**Objetivo:** construir una unidad real de escalado horizontal, engancharle un lazo de control de autoscale y entender las dos perillas (umbrales y cooldown) que deciden si se estabiliza o se pone a oscilar.

### Pasos

1. Creá un VM Scale Set con orquestación Flexible repartido en las tres zonas. Flexible es el modo de orquestación predeterminado actual y el que hay que usar para trabajo nuevo — gestiona las VMs como recursos de primera clase en lugar de instancias opacas de scale set.

   ```bash
   export VMSS=vmss-web-az900
   az vmss create \
     --resource-group "$RG" \
     --name "$VMSS" \
     --orchestration-mode Flexible \
     --platform-fault-domain-count 1 \
     --zones 1 2 3 \
     --image Ubuntu2204 \
     --vm-sku Standard_B2s \
     --instance-count 2 \
     --load-balancer "" \
     --generate-ssh-keys \
     --output none
   echo "created"
   ```

   ```
   created
   ```

   `--platform-fault-domain-count 1` es obligatorio cuando especificás zonas: dentro de una zona Azure ya provee el aislamiento de fallos, así que el eje de fault domain colapsa a 1 y la zona pasa a ser la frontera de fallo.

2. Confirmá que las instancias efectivamente cayeron en zonas distintas. **Este es el paso de verificación que la gente saltea.**

   ```bash
   az vm list --resource-group "$RG" \
     --query "[?contains(name, 'vmss-web')].{Name:name, Zone:zones[0], Size:hardwareProfile.vmSize}" \
     --output table
   ```

   ```
   Name                  Zone    Size
   --------------------  ------  ------------
   vmss-web-az900_a1b2   1       Standard_B2s
   vmss-web-az900_c3d4   2       Standard_B2s
   ```

   Dos instancias, dos zonas distintas. Si ambas mostraran `1`, el despliegue *no* es zone-redundant sin importar lo que pidió `--zones 1 2 3`.

3. Enganchá una configuración de autoscale. Esto crea el lazo de control: una fuente de métrica, umbrales y límites.

   ```bash
   az monitor autoscale create \
     --resource-group "$RG" \
     --resource "$VMSS" \
     --resource-type Microsoft.Compute/virtualMachineScaleSets \
     --name autoscale-web \
     --min-count 2 --max-count 10 --count 2 \
     --query "{name:name, enabled:enabled, default:profiles[0].capacity}" --output json
   ```

   ```json
   {
     "name": "autoscale-web",
     "enabled": true,
     "default": {
       "default": "2",
       "maximum": "10",
       "minimum": "2"
     }
   }
   ```

   `min-count 2` es el piso que preserva el SLA de 99.99% por zonas. Ponerlo en 1 para ahorrar dinero te baja silenciosamente al SLA de instancia única durante las horas tranquilas — justo las horas en que nadie está mirando.

4. Agregá la regla de scale-out.

   ```bash
   az monitor autoscale rule create \
     --resource-group "$RG" --autoscale-name autoscale-web \
     --condition "Percentage CPU > 70 avg 5m" \
     --scale out 2 --cooldown 5 \
     --output none
   echo "scale-out rule added"
   ```

   ```
   scale-out rule added
   ```

5. Agregá la regla de scale-in — deliberadamente asimétrica.

   ```bash
   az monitor autoscale rule create \
     --resource-group "$RG" --autoscale-name autoscale-web \
     --condition "Percentage CPU < 25 avg 10m" \
     --scale in 1 --cooldown 10 \
     --output none
   az monitor autoscale show --resource-group "$RG" --name autoscale-web \
     --query "profiles[0].rules[].{Metric:metricTrigger.metricName, Op:metricTrigger.operator, Threshold:metricTrigger.threshold, Window:metricTrigger.timeWindow, Dir:scaleAction.direction, By:scaleAction.value, Cooldown:scaleAction.cooldown}" \
     --output table
   ```

   ```
   Metric          Op             Threshold  Window    Dir       By    Cooldown
   --------------  -----------  -----------  --------  --------  ----  ----------
   Percentage CPU  GreaterThan           70  PT5M      Increase  2     PT5M
   Percentage CPU  LessThan              25  PT10M     Decrease  1     PT10M
   ```

   Leé la asimetría con atención. Hacia afuera: **+2 instancias**, 70%, ventana de 5 minutos, cooldown de 5 minutos. Hacia adentro: **−1 instancia**, 25%, ventana de 10 minutos, cooldown de 10 minutos. Escalar hacia afuera es barato y rápido porque estar subaprovisionado te cuesta usuarios; escalar hacia adentro es lento y cauto porque equivocarse te cuesta una caída. Esta es la forma estándar en producción, y es la respuesta correcta a "¿por qué no usar el mismo umbral en las dos direcciones?".

6. Demostrá por qué los umbrales simétricos oscilan. Supongamos que el scale-out dispara con CPU > 50% y el scale-in con CPU < 50%, con 4 instancias al 60% de CPU agregado:

   ```bash
   awk 'BEGIN {
     load = 4 * 60          # total CPU work units
     printf "4 instances @ %.0f%% -> scale OUT\n", load/4
     printf "5 instances @ %.0f%% -> scale IN\n",  load/5
     printf "4 instances @ %.0f%% -> scale OUT ... (flap)\n", load/4
   }'
   ```

   ```
   4 instances @ 60% -> scale OUT
   5 instances @ 48% -> scale IN
   4 instances @ 60% -> scale OUT ... (flap)
   ```

   El sistema nunca se asienta. El motor de autoscale de Azure tiene una protección incorporada contra el flapping — antes de escalar hacia adentro, estima la métrica posterior al scale-in y rechaza la acción si dispararía de inmediato un scale-out. Pero apoyarse en esa protección en vez de establecer una brecha real entre umbrales es arquitectura por accidente. La regla práctica: la brecha entre umbrales debe superar el desplazamiento de la métrica causado por un solo paso de escalado.

7. Agregá un **perfil programado** para carga previsible. El autoscale reactivo siempre se atrasa al menos la ventana de métrica; la capacidad programada no.

   ```bash
   az monitor autoscale profile create \
     --resource-group "$RG" --autoscale-name autoscale-web \
     --name weekday-business-hours \
     --min-count 4 --max-count 20 --count 6 \
     --recurrence week mon tue wed thu fri \
     --start 08:00 --end 20:00 \
     --timezone "Argentina Standard Time" \
     --output none
   az monitor autoscale show --resource-group "$RG" --name autoscale-web \
     --query "profiles[].{Profile:name, Min:capacity.minimum, Default:capacity.default, Max:capacity.maximum}" --output table
   ```

   ```
   Profile                            Min    Default    Max
   ---------------------------------  -----  ---------  -----
   weekday-business-hours             4      6          20
   weekday-business-hours_e_*         2      2          10
   default                            2      2          10
   ```

   La CLI genera automáticamente un perfil "else" apareado para que fuera de la ventana de recurrencia aplique la línea de base. Un batch job que arranca a las 08:00 en punto encuentra seis instancias tibias en lugar de dos frías más cinco minutos de 5xx.

8. Contrastá con el escalado **vertical**. Redimensioná una sola VM y mirá lo que te cuesta.

   ```bash
   VM=$(az vm list -g "$RG" --query "[0].name" --output tsv)
   az vm show -g "$RG" -n "$VM" --query "hardwareProfile.vmSize" --output tsv
   ```

   ```
   Standard_B2s
   ```

   Un cambio de tamaño a `Standard_D4s_v5` requiere desasignar la VM: el OS invitado se detiene, el disco efímero se descarta, la IP pública dinámica se libera. El escalado vertical es un **evento de caída en una única instancia**, acotado por el SKU más grande de la familia. El escalado horizontal es **en línea** y está acotado solo por la cuota. Este es el compromiso central de escalabilidad que evalúa el examen.

#### Comprobá tu comprensión

- **Q2.1** — Tu regla de scale-out usa una ventana de promedio de 5 minutos y un cooldown de 5 minutos, y las instancias tardan ~3 minutos en arrancar y pasar los health checks. ¿Cuál es la demora en el peor caso entre la llegada real de la carga y la nueva capacidad sirviendo tráfico? ¿Cuál de esos tres intervalos acortarías primero, y qué se arriesga al acortarlo?
- **Q2.2** — `--min-count` es 2 para sostener el SLA de redundancia por zonas. Finanzas te pide ponerlo en 1 durante la noche para reducir a la mitad el costo de cómputo. Cuantificá qué están comprando realmente y qué están resignando, usando los niveles de SLA del bloque 1.
- **Q2.3** — Explicá por qué la regla de scale-in quita 1 instancia pero la de scale-out agrega 2. Dá un escenario de fallo donde una configuración simétrica `−2 / +2` provoca una caída visible para el usuario.
- **Q2.4** — La carga de un workload es totalmente previsible: se triplica todos los días hábiles a las 08:00 y baja a las 20:00. ¿Cuál de los dos perfiles que configuraste (reglas por métrica vs. programado) está haciendo el trabajo útil, y por qué mantener *además* las reglas por métrica sigue importando?
- **Q2.5** — En el paso 2, ambas instancias podrían haber caído en la zona 1 pese a `--zones 1 2 3`. Nombrá una condición concreta de la plataforma que produce ese resultado, e indicá qué comando del bloque 1 lo detecta por anticipado.

---

## Bloque 3 — Previsibilidad de costos: consultá la lista de precios real, no la calculadora

**Objetivo:** la Azure Retail Prices API es pública, sin autenticación y legible por máquina. Usala para ver lado a lado los precios de consumo, spot y reserva — que es lo que significa concretamente "previsibilidad de costos".

### Pasos

1. Traé el precio pay-as-you-go de Linux para un SKU en una región.

   ```bash
   curl -s "https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&currencyCode='USD'&\$filter=serviceName%20eq%20'Virtual%20Machines'%20and%20armRegionName%20eq%20'eastus'%20and%20armSkuName%20eq%20'Standard_D2s_v5'%20and%20priceType%20eq%20'Consumption'" \
     | jq -r '.Items[] | select(.productName | test("Windows") | not) | "\(.skuName)\t\(.retailPrice)\t\(.unitOfMeasure)"'
   ```

   ```
   D2s v5          0.096   1 Hour
   D2s v5 Low Priority     0.0096  1 Hour
   D2s v5 Spot     0.0096  1 Hour
   ```

   Spot está más o menos al **10% del on-demand** acá — y viene con un aviso de desalojo de 30 segundos y sin SLA. Esa diferencia de precio es el precio de mercado de la *previsibilidad*.

2. Comparalo contra los medidores de instancia reservada para el mismo SKU.

   ```bash
   curl -s "https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&currencyCode='USD'&\$filter=serviceName%20eq%20'Virtual%20Machines'%20and%20armRegionName%20eq%20'eastus'%20and%20armSkuName%20eq%20'Standard_D2s_v5'%20and%20priceType%20eq%20'Reservation'" \
     | jq -r '.Items[] | select(.productName | test("Windows") | not) | "\(.reservationTerm)\t\(.retailPrice)\t\(.unitOfMeasure)"'
   ```

   ```
   1 Year          701.28  1 Hour
   3 Years         1461.24 1 Hour
   ```

   Los medidores de reserva se facturan como una **suma global por todo el plazo**, a pesar de que `unitOfMeasure` diga `1 Hour` — una trampa bien conocida de esta API. Normalizá antes de comparar.

3. Normalizá las tres a una tarifa horaria y calculá el ahorro real.

   ```bash
   awk 'BEGIN {
     ondemand = 0.096
     y1 = 701.28  / 8760
     y3 = 1461.24 / (8760 * 3)
     spot = 0.0096
     printf "%-14s %8.5f  %7s  %s\n", "On-demand", ondemand, "-",    "no commitment, full SLA"
     printf "%-14s %8.5f  %6.1f%%  %s\n", "1-year RI", y1, (1-y1/ondemand)*100, "12-month commitment"
     printf "%-14s %8.5f  %6.1f%%  %s\n", "3-year RI", y3, (1-y3/ondemand)*100, "36-month commitment"
     printf "%-14s %8.5f  %6.1f%%  %s\n", "Spot",      spot, (1-spot/ondemand)*100, "evictable, NO SLA"
   }'
   ```

   ```
   On-demand       0.09600        -  no commitment, full SLA
   1-year RI       0.08006     16.6%  12-month commitment
   3-year RI       0.05560     42.1%  36-month commitment
   Spot            0.00960     90.0%  evictable, NO SLA
   ```

4. Encontrá la utilización de equilibrio para la reserva de 1 año. Una reserva solo conviene si el recurso realmente corre.

   ```bash
   awk 'BEGIN {
     ondemand = 0.096; y1 = 701.28 / 8760
     printf "Break-even utilisation: %.1f%% of the year (%.0f h of 8760)\n", (y1/ondemand)*100, (y1/ondemand)*8760
   }'
   ```

   ```
   Break-even utilisation: 83.4% of the year (7305 h of 8760)
   ```

   Por debajo de ~83% de uptime, la reserva pierde plata. Por eso las reservas se adecuan a líneas de base de estado estacionario y nunca a la capa autoescalada por encima de la línea de base — el patrón correcto es *reservar el piso, hacer burst on-demand o spot*.

5. Comparación de precios entre regiones, dado que la elección de región es una palanca de costo de primer orden.

   ```bash
   for r in eastus westeurope brazilsouth japaneast; do
     price=$(curl -s "https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&currencyCode='USD'&\$filter=serviceName%20eq%20'Virtual%20Machines'%20and%20armRegionName%20eq%20'$r'%20and%20armSkuName%20eq%20'Standard_D2s_v5'%20and%20priceType%20eq%20'Consumption'" \
       | jq -r '[.Items[] | select(.skuName == "D2s v5")][0].retailPrice')
     printf '%-14s %s USD/h\n' "$r" "$price"
   done
   ```

   ```
   eastus         0.096 USD/h
   westeurope     0.107 USD/h
   brazilsouth    0.1728 USD/h
   japaneast      0.1408 USD/h
   ```

   El mismo SKU cuesta un 80% más en Brazil South que en East US. La selección de región es un compromiso entre precio, latencia hacia los usuarios, legislación de residencia de datos y disponibilidad de zonas — y no es reversible barato una vez que los datos aterrizaron.

#### Comprobá tu comprensión

- **Q3.1** — El medidor de reserva reporta `unitOfMeasure: "1 Hour"` con un valor de `701.28`. Explicá qué representa realmente ese número y qué reportaría como costo anual de un D2s v5 reservado un dashboard ingenuo que confíe en `unitOfMeasure`.
- **Q3.2** — El punto de equilibrio de la RI de 1 año es 83.4% de utilización. Tus VMs de dev/test corren 10 horas por día, 5 días por semana. Calculá su utilización e indicá si una reserva es correcta para ellas. ¿Qué opción de compra de Azure, si alguna, encaja mejor con ese patrón?
- **Q3.3** — Spot es 90% más barato sin SLA y con aviso de desalojo de 30 segundos. Dá un workload que encaje correctamente y uno que sea categóricamente inadecuado, e indicá la única propiedad del workload que lo decide.
- **Q3.4** — Tenés un rango de autoscale de mín. 4 / máx. 20 instancias, y la telemetría muestra que estás entre 4 y 6 instancias el 95% del tiempo. ¿Cuántas instancias reservarías, y por qué reservar las 20 es activamente peor que no reservar ninguna?
- **Q3.5** — Brazil South es 80% más caro que East US para hardware idéntico. Nombrá dos razones que *no* sean "Azure cobra lo que quiere", y un escenario donde pagar el sobreprecio es obligatorio en vez de opcional.

---

## Bloque 4 — Fiabilidad: niveles de redundancia, y lo que "durabilidad" no significa

**Objetivo:** distinguir **durabilidad** (¿van a sobrevivir los bytes?) de **disponibilidad** (¿puedo alcanzarlos ahora mismo?). Son SLAs distintos con modos de fallo distintos, y confundirlos es el error clásico de fiabilidad.

### Pasos

1. Creá tres storage accounts con distintos niveles de replicación.

   ```bash
   SUFFIX=$(az group show -n "$RG" --query id --output tsv | md5sum | cut -c1-8)
   for sku in Standard_LRS Standard_ZRS Standard_GZRS; do
     name="st${SUFFIX}$(echo $sku | tr 'A-Z_' 'a-z' | cut -c10-13)"
     az storage account create --name "$name" --resource-group "$RG" --location "$LOC" \
       --sku "$sku" --kind StorageV2 --min-tls-version TLS1_2 \
       --allow-blob-public-access false --https-only true --output none
     echo "$name -> $sku"
   done
   ```

   ```
   st3f9a1c22lrs -> Standard_LRS
   st3f9a1c22zrs -> Standard_ZRS
   st3f9a1c22gzr -> Standard_GZRS
   ```

2. Leé de vuelta la configuración de replicación desde la plataforma.

   ```bash
   az storage account list --resource-group "$RG" \
     --query "[].{Name:name, Sku:sku.name, Tier:sku.tier, Primary:primaryLocation, Secondary:secondaryLocation, Status:statusOfPrimary}" \
     --output table
   ```

   ```
   Name           Sku             Tier      Primary    Secondary    Status
   -------------  --------------  --------  ---------  -----------  --------
   st3f9a1c22lrs  Standard_LRS    Standard  eastus                  available
   st3f9a1c22zrs  Standard_ZRS    Standard  eastus                  available
   st3f9a1c22gzr  Standard_GZRS   Standard  eastus     westus       available
   ```

   Solo la cuenta georredundante tiene una `secondaryLocation`. LRS y ZRS no tienen ninguna copia entre regiones — una caída regional las deja completamente fuera de línea.

3. Mapeá cada nivel a lo que realmente sobrevive:

   | SKU | Copias | Repartidas en | Sobrevive a | Durabilidad anual |
   |---|---|---|---|---|
   | `Standard_LRS` | 3 | un datacenter, racks separados | fallo de disco, nodo, rack | 11 nueves |
   | `Standard_ZRS` | 3 | 3 availability zones, una región | pérdida de un datacenter entero | 12 nueves |
   | `Standard_GRS` | 6 | 3 locales + 3 en la región emparejada (asíncrono) | pérdida de una región | 16 nueves |
   | `Standard_GZRS` | 6 | 3 zonas + 3 en la región emparejada (asíncrono) | pérdida de zona *y* pérdida de región | 16 nueves |
   | `Standard_RA_GRS` / `RA_GZRS` | 6 | igual que arriba, secundaria legible | igual que arriba, más acceso de lectura durante la caída de la primaria | 16 nueves |

4. Descubrí la región emparejada de forma programática en vez de memorizar la tabla.

   ```bash
   az account list-locations \
     --query "[?name=='$LOC'].{Region:name, Paired:metadata.pairedRegion[0].name, Geography:metadata.geographyGroup}" \
     --output table
   ```

   ```
   Region    Paired    Geography
   --------  --------  -----------
   eastus    westus    US
   ```

   Los pares de regiones importan por dos razones más allá del storage: las actualizaciones de plataforma se despliegan en una sola región del par por vez, y la recuperación en una caída amplia se prioriza para al menos una región por par. Ojo que algunas regiones más nuevas de Azure llegan **sin** par y dependen enteramente de availability zones — verificá antes de diseñar alrededor del emparejamiento.

5. Inspeccioná el retraso de georreplicación en la cuenta georredundante. Replicación asincrónica significa que hay un RPO real y medible.

   ```bash
   GZRS=$(az storage account list -g "$RG" --query "[?sku.name=='Standard_GZRS'].name | [0]" --output tsv)
   az storage account show --name "$GZRS" --resource-group "$RG" --expand geoReplicationStats \
     --query "geoReplicationStats.{Status:status, LastSync:lastSyncTime, CanFailover:canFailover}" --output json
   ```

   ```json
   {
     "Status": "Live",
     "LastSync": "2026-09-04T14:22:07+00:00",
     "CanFailover": true
   }
   ```

   `lastSyncTime` es el límite real del RPO: cada escritura confirmada en la primaria *después* de ese timestamp todavía no está en la secundaria. Si la primaria se pierde en este momento, esas escrituras desaparecieron. La georredundancia **no** es un espejo sincrónico, y ninguna cantidad de nueves en la columna de durabilidad cambia eso.

6. Leé — **no** ejecutes — el comando de failover, y entendé su consecuencia.

   ```bash
   # az storage account failover --name "$GZRS" --resource-group "$RG" --failover-type Planned
   az storage account show --name "$GZRS" --resource-group "$RG" \
     --query "{failoverInProgress:failoverInProgress, allowedCopyScope:allowedCopyScope}" --output json
   ```

   ```json
   {
     "failoverInProgress": null,
     "allowedCopyScope": null
   }
   ```

   Un failover **no planificado** promueve la secundaria de inmediato, acepta la pérdida de datos implicada por `lastSyncTime` y **convierte la cuenta a LRS** — aterrizás en la región secundaria sin redundancia hasta que la reconfigures. Un failover **planificado** (disponible en GZRS/GRS cuando la primaria está sana) replica todo primero, así que el RPO es cero, pero requiere una primaria sana y por lo tanto no puede usarse durante la caída para la que lo construiste. Ambos son a nivel de cuenta y tardan horas en revertirse.

7. Preguntale a Azure Advisor qué opina de tu postura de fiabilidad. Esta es la versión gratuita y siempre activa de una revisión de fiabilidad.

   ```bash
   az advisor recommendation list --category HighAvailability \
     --query "[?contains(resourceMetadata.resourceId, '$RG')].{Impact:impact, Problem:shortDescription.problem}" \
     --output table
   ```

   ```
   Impact    Problem
   --------  ----------------------------------------------------------
   Medium    Use ZRS or GZRS for higher storage resiliency
   High      Enable virtual machine backup to protect against data loss
   ```

#### Comprobá tu comprensión

- **Q4.1** — LRS publicita 11 nueves de durabilidad. Un desarrollador ejecuta `DELETE` contra el container equivocado y desaparecen 4 TB. ¿Cumplió la storage account con su SLA de durabilidad? Explicá con precisión contra qué protege la durabilidad, y nombrá las dos funcionalidades que *sí* protegen contra este escenario.
- **Q4.2** — Tu cuenta GZRS reporta un `lastSyncTime` de hace 12 minutos. La región primaria se pierde ahora mismo y disparás un failover no planificado. Indicá (a) la ventana de pérdida de datos, (b) el nivel de redundancia sobre el que estás corriendo inmediatamente después, y (c) el riesgo adicional que eso crea.
- **Q4.3** — ZRS sobrevive a la pérdida de un datacenter entero y GRS sobrevive a la pérdida de una región entera, y sin embargo ZRS tiene *mayor disponibilidad* para lecturas que la secundaria de GRS durante la operación normal. Reconciliá esos dos hechos.
- **Q4.4** — Un regulador exige que los datos nunca salgan del país, y la única región dentro del país tiene tres availability zones pero ninguna región emparejada. ¿Qué SKU de replicación elegís, qué riesgo queda, y qué control compensatorio lo aborda?
- **Q4.5** — El failover planificado tiene RPO cero pero requiere una primaria sana. Dá un escenario real donde el failover planificado es exactamente la herramienta correcta, dado que no puede usarse durante una caída regional no planificada.

---

## Bloque 5 — Previsibilidad de rendimiento: los topes de SKU son contratos, no sugerencias

**Objetivo:** el rendimiento en la nube es previsible *porque está topeado*. Encontrá los topes, y mirá cómo un desajuste entre el tope de la VM y el del disco estrangula silenciosamente un workload.

### Pasos

1. Leé las capacidades de rendimiento de un SKU de VM. Estos números son el contrato.

   ```bash
   az vm list-skus --location "$LOC" --size Standard_D2s_v5 --resource-type virtualMachines \
     --query "[0].capabilities[?name=='vCPUs' || name=='MemoryGB' || name=='MaxDataDiskCount' || name=='UncachedDiskIOPS' || name=='UncachedDiskBytesPerSecond' || name=='MaxNetworkInterfaces' || name=='PremiumIO'].{Capability:name, Value:value}" \
     --output table
   ```

   ```
   Capability                    Value
   ----------------------------  ----------
   MaxDataDiskCount              4
   MaxNetworkInterfaces          2
   MemoryGB                      8
   PremiumIO                     True
   UncachedDiskIOPS              3750
   UncachedDiskBytesPerSecond    85983232
   vCPUs                         2
   ```

   `UncachedDiskBytesPerSecond` de 85.983.232 es ~82 MiB/s. **Ese es el techo para todos los discos adjuntos en conjunto, sin importar lo rápidos que sean los discos.**

2. Leé los niveles de rendimiento de los managed disks en la misma región.

   ```bash
   az disk list-skus --location "$LOC" --resource-type disks \
     --query "[?name=='Premium_LRS'].capabilities[?name=='MaxIOpsReadWrite' || name=='MaxBandwidthMBps'] | [0]" \
     --output table 2>/dev/null || echo "(query per-size below)"
   ```

   Los niveles de Premium SSD v1 se derivan del tamaño y son fijos:

   | Nivel | Tamaño | IOPS aprovisionadas | Throughput aprovisionado |
   |---|---|---|---|
   | P6 | 64 GiB | 240 | 50 MB/s |
   | P10 | 128 GiB | 500 | 100 MB/s |
   | P20 | 512 GiB | 2.300 | 150 MB/s |
   | P30 | 1 TiB | 5.000 | 200 MB/s |
   | P40 | 2 TiB | 7.500 | 250 MB/s |

3. Calculá el throughput efectivo de un D2s_v5 con un P30 adjunto. La restricción vinculante es el límite que sea menor.

   ```bash
   awk 'BEGIN {
     vm_iops = 3750; vm_mbps = 85983232 / 1048576
     disk_iops = 5000; disk_mbps = 200
     printf "VM cap    : %6d IOPS  %7.1f MiB/s\n", vm_iops, vm_mbps
     printf "Disk cap  : %6d IOPS  %7.1f MiB/s\n", disk_iops, disk_mbps
     printf "Effective : %6d IOPS  %7.1f MiB/s  <- min() of both\n", \
       (vm_iops < disk_iops ? vm_iops : disk_iops), (vm_mbps < disk_mbps ? vm_mbps : disk_mbps)
     printf "Wasted    : %6d IOPS  %7.1f MiB/s of provisioned disk you are paying for\n", \
       disk_iops - vm_iops, disk_mbps - vm_mbps
   }'
   ```

   ```
   VM cap    :   3750 IOPS     82.0 MiB/s
   Disk cap  :   5000 IOPS    200.0 MiB/s
   Effective :   3750 IOPS     82.0 MiB/s  <- min() of both
   Wasted    :   1250 IOPS    118.0 MiB/s of provisioned disk you are paying for
   ```

   Estás pagando precios de P30 y recibiendo bastante menos de la mitad del throughput, porque el cuello de botella es la **VM**. Este es el ticket de "la nube está lenta" más común de todos, y no es un problema de la nube — es un problema de emparejamiento de SKUs, visible por anticipado con los dos comandos de arriba.

4. Confirmá que existe el mismo tipo de tope para la red, así dimensionás también el camino de la NIC de manera deliberada.

   ```bash
   az vm list-skus --location "$LOC" --size Standard_D --resource-type virtualMachines \
     --query "[?starts_with(name,'Standard_D') && contains(name,'s_v5')].{SKU:name, vCPU:capabilities[?name=='vCPUs'].value|[0], IOPS:capabilities[?name=='UncachedDiskIOPS'].value|[0]}" \
     --output table | head -8
   ```

   ```
   SKU               vCPU    IOPS
   ----------------  ------  ------
   Standard_D2s_v5   2       3750
   Standard_D4s_v5   4       6400
   Standard_D8s_v5   8       12800
   Standard_D16s_v5  16      25600
   Standard_D32s_v5  32      51200
   ```

   Las IOPS de disco escalan con el tamaño del SKU. Si tu cuello de botella es la E/S y no la CPU, el arreglo es una VM más grande aun cuando la CPU esté ociosa — un desenlace que parece irracional hasta que leíste esta tabla.

5. Ahora la mitad de costos de la previsibilidad: creá un budget con umbrales de alerta, para que el gasto tenga un lazo de control igual que la capacidad.

   ```bash
   cat > /tmp/budget.json <<'JSON'
   {
     "properties": {
       "category": "Cost",
       "amount": 50,
       "timeGrain": "Monthly",
       "timePeriod": { "startDate": "2026-09-01T00:00:00Z", "endDate": "2027-09-01T00:00:00Z" },
       "notifications": {
         "forecast-90": {
           "enabled": true,
           "operator": "GreaterThan",
           "threshold": 90,
           "thresholdType": "Forecasted",
           "contactEmails": ["you@example.com"],
           "contactRoles": ["Owner"]
         },
         "actual-100": {
           "enabled": true,
           "operator": "GreaterThan",
           "threshold": 100,
           "thresholdType": "Actual",
           "contactEmails": ["you@example.com"]
         }
       }
     }
   }
   JSON
   az rest --method put \
     --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Consumption/budgets/budget-az900?api-version=2021-10-01" \
     --body @/tmp/budget.json \
     --query "{name:name, amount:properties.amount, grain:properties.timeGrain}" --output json
   ```

   ```json
   {
     "name": "budget-az900",
     "amount": 50.0,
     "grain": "Monthly"
   }
   ```

   Los dos tipos de notificación cumplen trabajos distintos. `Forecasted > 90%` dispara **antes** de que se gaste la plata, en base a la proyección del ritmo de gasto — esa es la que te permite actuar. `Actual > 100%` dispara después del hecho y es un registro de auditoría. Un budget con solo una alerta de umbral real es un detector de humo que suena a la mañana siguiente.

6. Verificá que el budget esté registrado y sea legible.

   ```bash
   az rest --method get \
     --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Consumption/budgets?api-version=2021-10-01" \
     --query "value[].{Name:name, Amount:properties.amount, Spent:properties.currentSpend.amount, Currency:properties.currentSpend.unit}" \
     --output table
   ```

   ```
   Name          Amount    Spent    Currency
   ------------  --------  -------  ----------
   budget-az900  50.0      1.87     USD
   ```

   Fijate en lo que un budget **no** es: no detiene el gasto. Notifica. La aplicación efectiva requiere un action group cableado a automatización (una Logic App o un runbook que desasigne recursos), y eso es una decisión de diseño deliberada — apagar producción en silencio porque saltó un umbral suele ser peor que el sobregasto.

#### Comprobá tu comprensión

- **Q5.1** — Un D2s_v5 con un disco P30 entrega 3.750 IOPS y 82 MiB/s. El arreglo del equipo es actualizar el disco a P40. ¿Qué va a pasar con el throughput medido, y cuál es el arreglo correcto?
- **Q5.2** — El topeo es lo que hace previsible el rendimiento en la nube, y a la vez los topes son lo que lo hace lento cuando está mal dimensionado. Explicá por qué una plataforma multiinquilino *sin topes* sería peor para todos los inquilinos, incluido el que habría usado el margen extra.
- **Q5.3** — Tu budget tiene notificaciones `Forecasted > 90%` y `Actual > 100%`. El día 9 del mes dispara la alerta de pronóstico. ¿Qué te dice eso que la cifra de gasto real por sí sola no te dice, y cuál es el primer comando de diagnóstico que ejecutarías?
- **Q5.4** — Un budget no detiene el gasto. Diseñá, en dos o tres oraciones, un camino de aplicación efectiva para una suscripción *no productiva*, e indicá la razón específica por la que no aplicarías la misma automatización a producción.
- **Q5.5** — El paso 4 muestra las IOPS de disco escalando linealmente con la cantidad de vCPU. Tu base de datos está al 20% de CPU pero clavada en su tope de IOPS. ¿Qué cambiás, y por qué esto se siente mal para alguien que razona con hábitos de dimensionamiento on-premises?

---

## Bloque 6 — Seguridad y gobernanza: la prevención le gana a la detección

**Objetivo:** el beneficio de gobernanza no es "podés ver las violaciones". Es que una solicitud que viola nunca se confirma. Vas a construir una barrera `Deny`, observar el rechazo y ver la diferencia entre `Audit` y `Deny` en el plano de control.

### Pasos

1. Encontrá la definición de policy incorporada por nombre visible en lugar de hardcodear un GUID.

   ```bash
   ALLOWED_LOC_ID=$(az policy definition list \
     --query "[?displayName=='Allowed locations' && policyType=='BuiltIn'].id | [0]" --output tsv)
   echo "$ALLOWED_LOC_ID"
   ```

   ```
   /providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c
   ```

2. Inspeccioná la definición antes de asignarla. Leer el `effect` y el contrato de parámetros es la diferencia entre gobernanza y culto a la carga.

   ```bash
   az policy definition show --name e56962a6-4747-49cd-b67b-bf8b01975c4c \
     --query "{effect:policyRule.then.effect, params:keys(parameters), mode:mode}" --output json
   ```

   ```json
   {
     "effect": "deny",
     "params": ["listOfAllowedLocations"],
     "mode": "Indexed"
   }
   ```

   `mode: Indexed` significa que la policy solo evalúa tipos de recurso que soportan tags y ubicación — los resource groups en sí quedan excluidos, y por eso existe una definición aparte de "Allowed locations for resource groups".

3. Asignala a nivel de resource group, restringida a una región que deliberadamente *no* sea tu región de trabajo, para poder observar la denegación.

   ```bash
   az policy assignment create \
     --name deny-wrong-region \
     --display-name "AZ900 lab: restrict deployments to westus2" \
     --scope "/subscriptions/$SUB/resourceGroups/$RG" \
     --policy "$ALLOWED_LOC_ID" \
     --params '{"listOfAllowedLocations":{"value":["westus2"]}}' \
     --query "{name:name, scope:scope, enforcement:enforcementMode}" --output json
   ```

   ```json
   {
     "name": "deny-wrong-region",
     "scope": "/subscriptions/8f2c1b74-3d9a-4a1e-9f0b-2c7d5e6a1b33/resourceGroups/rg-az900-benefits",
     "enforcement": "Default"
   }
   ```

   `enforcementMode: Default` significa que el deny está activo. `DoNotEnforce` evaluaría y reportaría sin bloquear — la configuración correcta cuando estás introduciendo una policy nueva en un parque existente y necesitás los datos de cumplimiento antes de romperle el pipeline a alguien.

4. Esperá a que la asignación se propague y después intentá un despliegue que viole la regla.

   ```bash
   sleep 45
   az storage account create --name "stdenied$SUFFIX" --resource-group "$RG" \
     --location "$LOC" --sku Standard_LRS --kind StorageV2 --output none
   ```

   ```
   (RequestDisallowedByPolicy) Resource 'stdenied3f9a1c22' was disallowed by policy.
   Policy identifiers: '[{"policyAssignment":{"name":"AZ900 lab: restrict deployments to westus2",
   "id":"/subscriptions/8f2c.../providers/Microsoft.Authorization/policyAssignments/deny-wrong-region"},
   "policyDefinition":{"name":"Allowed locations",
   "id":"/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c"}}]'
   Code: RequestDisallowedByPolicy
   ```

   Leé lo que pasó: **Azure Resource Manager rechazó la solicitud antes de que se creara ningún recurso.** No hay recurso parcial, no hay limpieza, no hay ventana de deriva. El error nombra la asignación y la definición exactas — un rechazo autodocumentado sobre el que un ingeniero puede actuar sin abrir un ticket.

5. Confirmá que la misma solicitud tiene éxito en la región permitida, probando que la barrera es un límite y no un bloqueo general.

   ```bash
   az storage account create --name "stallowed$SUFFIX" --resource-group "$RG" \
     --location westus2 --sku Standard_LRS --kind StorageV2 \
     --min-tls-version TLS1_2 --allow-blob-public-access false \
     --query "{name:name, location:primaryLocation}" --output json
   ```

   ```json
   {
     "name": "stallowed3f9a1c22",
     "location": "westus2"
   }
   ```

6. Ahora asigná una policy de **Audit** para comparar los dos efectos sobre infraestructura idéntica.

   ```bash
   TLS_ID=$(az policy definition list \
     --query "[?contains(displayName,'Secure transfer to storage accounts') && policyType=='BuiltIn'].id | [0]" --output tsv)
   az policy assignment create \
     --name audit-secure-transfer \
     --scope "/subscriptions/$SUB/resourceGroups/$RG" \
     --policy "$TLS_ID" \
     --params '{"effect":{"value":"Audit"}}' \
     --output none
   echo "audit assignment created"
   ```

   ```
   audit assignment created
   ```

7. Disparé un escaneo de cumplimiento bajo demanda y leé el resultado. Si no, los escaneos se evalúan aproximadamente cada 24 horas, o al cambiar un recurso.

   ```bash
   az policy state trigger-scan --resource-group "$RG" --no-wait
   sleep 120
   az policy state summarize --resource-group "$RG" \
     --query "value[0].results.{NonCompliant:nonCompliantResources, Policies:nonCompliantPolicies}" --output json
   ```

   ```json
   {
     "NonCompliant": 0,
     "Policies": 0
   }
   ```

   Cero no conformes, porque cada cuenta que creaste estableció `--https-only true`. **Este es el contraste crucial que hay que internalizar:** la policy de Audit habría reportado una violación *después* de que una cuenta mala existiera y estuviera sirviendo tráfico por HTTP. La policy de Deny hizo que la solicitud mala nunca llegara a ser un recurso. El mismo motor de gobernanza, una postura de seguridad completamente distinta.

8. Examiná RBAC como la otra mitad de la gobernanza — quién puede actuar, en oposición a qué puede existir.

   ```bash
   az role assignment list --resource-group "$RG" --include-inherited \
     --query "[].{Principal:principalName, Type:principalType, Role:roleDefinitionName, Scope:scope}" \
     --output table
   ```

   ```
   Principal              Type   Role         Scope
   ---------------------  -----  -----------  ------------------------------------------
   villadalmine@...       User   Owner        /subscriptions/8f2c1b74-...
   ```

9. Construí un rol personalizado de mínimo privilegio — la expresión concreta de "gobernanza", en oposición a repartir `Contributor`.

   ```bash
   cat > /tmp/role-vm-operator.json <<JSON
   {
     "Name": "AZ900 VM Restart Operator",
     "Description": "May start, stop and restart VMs. May not create, delete or resize them.",
     "Actions": [
       "Microsoft.Compute/virtualMachines/read",
       "Microsoft.Compute/virtualMachines/start/action",
       "Microsoft.Compute/virtualMachines/restart/action",
       "Microsoft.Compute/virtualMachines/deallocate/action",
       "Microsoft.Compute/virtualMachines/instanceView/read",
       "Microsoft.Resources/subscriptions/resourceGroups/read"
     ],
     "NotActions": [],
     "DataActions": [],
     "NotDataActions": [],
     "AssignableScopes": [ "/subscriptions/$SUB/resourceGroups/$RG" ]
   }
   JSON
   az role definition create --role-definition @/tmp/role-vm-operator.json \
     --query "{name:roleName, type:roleType, actions:length(permissions[0].actions)}" --output json
   ```

   ```json
   {
     "name": "AZ900 VM Restart Operator",
     "type": "CustomRole",
     "actions": 6
   }
   ```

   Fijate que no hay `virtualMachines/write` ni `virtualMachines/delete`. Un operador con este rol puede recuperar una VM colgada a las 03:00 y no puede redimensionarla, borrarla ni adjuntarle un disco. RBAC responde *quién*; Policy responde *qué*. Ambos son evaluados por ARM en cada solicitud, y **deny siempre le gana a allow**.

#### Comprobá tu comprensión

- **Q6.1** — La misma definición de policy "Secure transfer" puede asignarse con `Audit` o con `Deny`. Describí la línea de tiempo de los eventos para un desarrollador que crea una storage account solo-HTTP bajo cada efecto, e identificá el intervalo específico durante el cual los datos están en riesgo bajo `Audit`.
- **Q6.2** — Estás introduciendo una nueva policy de convención de nombres sobre 400 recursos existentes, la mayoría de los cuales la violan. ¿Qué `enforcementMode` asignás primero, y cuál es el fallo exacto que estás evitando al no ir directo a `Deny`?
- **Q6.3** — La asignación de la policy tardó ~45 segundos en hacerse efectiva, y los escaneos de cumplimiento corren aproximadamente cada 24 horas salvo que se disparen manualmente. Explicá por qué esas dos latencias son tan distintas, y cuál de ellas te preocuparía en una revisión de seguridad.
- **Q6.4** — Un usuario tiene `Owner` a nivel de suscripción, y una policy `Deny` a nivel de resource group prohíbe la región que necesita. ¿Puede desplegar? Explicá el orden de evaluación de ARM que produce la respuesta, y cómo procedería legítimamente.
- **Q6.5** — El rol personalizado omite `Microsoft.Compute/virtualMachines/write`. Un operador se queja de que no puede agregar un tag a una VM que por lo demás sí puede reiniciar. ¿Es un bug del rol, y cuál es el cambio mínimo que lo arregla sin conceder redimensionar ni borrar?

---

## Bloque 7 — Manejabilidad: declarar el estado, previsualizar el cambio, cerrar el lazo

**Objetivo:** la manejabilidad son dos cosas distintas que el examen separa. **Gestión *de* la nube** — automatizar y configurar recursos (plantillas, autoscale, monitoreo). **Gestión *en* la nube** — las interfaces que usás (portal, CLI, PowerShell, Cloud Shell, ARM/Bicep, REST). Vas a ejercitar ambas, y a ver el lazo de previsualizar-antes-de-aplicar que hace segura la gestión declarativa.

### Pasos

1. Escribí una plantilla ARM completa y sintácticamente válida. Este es el artefacto declarativo — el estado deseado, no los pasos para alcanzarlo.

   ```bash
   cat > /tmp/storage.json <<'JSON'
   {
     "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
     "contentVersion": "1.0.0.0",
     "parameters": {
       "storageAccountName": {
         "type": "string",
         "minLength": 3,
         "maxLength": 24,
         "metadata": { "description": "Globally unique, lowercase alphanumeric." }
       },
       "location": {
         "type": "string",
         "defaultValue": "[resourceGroup().location]"
       },
       "replication": {
         "type": "string",
         "defaultValue": "Standard_ZRS",
         "allowedValues": ["Standard_LRS", "Standard_ZRS", "Standard_GRS", "Standard_GZRS"],
         "metadata": { "description": "Redundancy tier. ZRS or better for production." }
       }
     },
     "variables": {
       "requiredTags": {
         "costCenter": "training",
         "env": "lab",
         "managedBy": "arm-template"
       }
     },
     "resources": [
       {
         "type": "Microsoft.Storage/storageAccounts",
         "apiVersion": "2023-05-01",
         "name": "[parameters('storageAccountName')]",
         "location": "[parameters('location')]",
         "tags": "[variables('requiredTags')]",
         "sku": { "name": "[parameters('replication')]" },
         "kind": "StorageV2",
         "properties": {
           "accessTier": "Hot",
           "supportsHttpsTrafficOnly": true,
           "minimumTlsVersion": "TLS1_2",
           "allowBlobPublicAccess": false,
           "allowSharedKeyAccess": false,
           "networkAcls": {
             "defaultAction": "Deny",
             "bypass": "AzureServices"
           }
         }
       }
     ],
     "outputs": {
       "blobEndpoint": {
         "type": "string",
         "value": "[reference(resourceId('Microsoft.Storage/storageAccounts', parameters('storageAccountName'))).primaryEndpoints.blob]"
       },
       "resourceId": {
         "type": "string",
         "value": "[resourceId('Microsoft.Storage/storageAccounts', parameters('storageAccountName'))]"
       }
     }
   }
   JSON
   python3 -c "import json,sys; json.load(open('/tmp/storage.json')); print('template parses')"
   ```

   ```
   template parses
   ```

2. Validá contra ARM antes de desplegar. La validación es una verificación de esquema y referencias del lado del servidor, y es gratuita.

   ```bash
   az deployment group validate \
     --resource-group "$RG" --template-file /tmp/storage.json \
     --parameters storageAccountName="stdecl$SUFFIX" location=westus2 \
     --query "{status:properties.provisioningState, errors:error}" --output json
   ```

   ```json
   {
     "status": "Succeeded",
     "errors": null
   }
   ```

3. Ejecutá **what-if**. Esta es la funcionalidad de manejabilidad más útil de Azure y la que más gente nunca activa: calcula el delta entre el estado declarado y el estado real antes de que cambie nada.

   ```bash
   az deployment group what-if \
     --resource-group "$RG" --template-file /tmp/storage.json \
     --parameters storageAccountName="stdecl$SUFFIX" location=westus2 \
     --result-format FullResourcePayload 2>&1 | head -30
   ```

   ```
   Note: The result may contain false positive predictions (noise).
   You can help us improve the accuracy of the result by opening an issue here: https://aka.ms/arm-template-what-if-issues

   Resource and property changes are indicated with these symbols:
     + Create
     ~ Modify
     - Delete
     = NoChange

   The deployment will update the following scope:

   Scope: /subscriptions/8f2c1b74-.../resourceGroups/rg-az900-benefits

     + Microsoft.Storage/storageAccounts/stdecl3f9a1c22 [2023-05-01]

         apiVersion:                            "2023-05-01"
         kind:                                  "StorageV2"
         location:                              "westus2"
         properties.accessTier:                 "Hot"
         properties.allowBlobPublicAccess:      false
         properties.allowSharedKeyAccess:       false
         properties.minimumTlsVersion:          "TLS1_2"
         properties.supportsHttpsTrafficOnly:   true
         sku.name:                              "Standard_ZRS"
         tags.costCenter:                       "training"

   Resource changes: 1 to create.
   ```

4. Desplegá, y después volvé a correr what-if para ver la idempotencia demostrada en vez de afirmada.

   ```bash
   az deployment group create \
     --resource-group "$RG" --name declare-storage --template-file /tmp/storage.json \
     --parameters storageAccountName="stdecl$SUFFIX" location=westus2 \
     --query "properties.outputs.blobEndpoint.value" --output tsv

   az deployment group what-if \
     --resource-group "$RG" --template-file /tmp/storage.json \
     --parameters storageAccountName="stdecl$SUFFIX" location=westus2 2>&1 | tail -5
   ```

   ```
   https://stdecl3f9a1c22.blob.core.windows.net/

     = Microsoft.Storage/storageAccounts/stdecl3f9a1c22

   Resource changes: no change.
   ```

   `no change` con la plantilla idéntica es la definición de idempotencia: el artefacto describe un estado final, así que reaplicarlo es un no-op. La misma plantilla en un pipeline de CI es segura de ejecutar en cada commit.

5. Simulá deriva de configuración y dejá que what-if la detecte — el lazo de manejabilidad cerrándose sobre un cambio manual.

   ```bash
   az storage account update --name "stdecl$SUFFIX" --resource-group "$RG" \
     --set tags.costCenter=misc --output none
   az deployment group what-if \
     --resource-group "$RG" --template-file /tmp/storage.json \
     --parameters storageAccountName="stdecl$SUFFIX" location=westus2 2>&1 | grep -A4 '~ Microsoft'
   ```

   ```
     ~ Microsoft.Storage/storageAccounts/stdecl3f9a1c22 [2023-05-01]
       ~ tags.costCenter: "misc" => "training"

   Resource changes: 1 to modify.
   ```

   Alguien cambió un tag en el portal; la plantilla se dio cuenta, nombró la propiedad exacta y mostró ambos valores. Detectar deriva en un parque on-premises requiere un sistema de gestión de configuración que tenés que operar vos. Acá es un comando gratuito contra el registro de estado de la propia plataforma.

6. Leé el rastro de auditoría del plano de control. Cada operación de ARM en la suscripción se registra durante 90 días sin que habilites nada.

   ```bash
   az monitor activity-log list --resource-group "$RG" --offset 1h --max-events 8 \
     --query "[?operationName.value != 'Microsoft.Resources/deployments/write'].{Time:eventTimestamp, Operation:operationName.localizedValue, Status:status.value, Caller:caller}" \
     --output table
   ```

   ```
   Time                              Operation                                  Status     Caller
   --------------------------------  -----------------------------------------  ---------  --------------------
   2026-09-04T14:58:11.4021Z         Create/Update Storage Account              Succeeded  villadalmine@...
   2026-09-04T14:51:03.9117Z         Create/Update Storage Account              Failed     villadalmine@...
   2026-09-04T14:47:22.1980Z         Create policy assignment                   Succeeded  villadalmine@...
   2026-09-04T14:33:50.7714Z         Create or Update Virtual Machine Scale Set Succeeded  villadalmine@...
   ```

   La entrada `Failed` de las 14:51 es tu denegación de policy del bloque 6 — quién intentó, qué, cuándo, y que fue bloqueado. Ese es el rastro de auditoría de gobernanza, y existe por defecto.

7. Consultá **Resource Health** — la opinión propia de la plataforma sobre si tu recurso está funcionando, distinta de tu monitoreo.

   ```bash
   VMID=$(az vm list -g "$RG" --query "[0].id" --output tsv)
   az rest --method get \
     --url "https://management.azure.com${VMID}/providers/Microsoft.ResourceHealth/availabilityStatuses/current?api-version=2022-10-01" \
     --query "properties.{State:availabilityState, Summary:summary, Since:occuredTime, ReportedAt:reportedTime}" --output json
   ```

   ```json
   {
     "State": "Available",
     "Summary": "There aren't any known Azure platform problems affecting this virtual machine.",
     "Since": "2026-09-04T14:34:12Z",
     "ReportedAt": "2026-09-04T15:02:44Z"
   }
   ```

   Los estados son `Available`, `Unavailable`, `Degraded` y `Unknown`. Esta es la respuesta a la pregunta de las 03:00, "¿soy yo o es Azure?" — y es la distinción diagnóstica que convierte una investigación de dos horas en una de dos minutos.

8. Revisá Service Health en busca de eventos a nivel de plataforma que afecten a la suscripción.

   ```bash
   az rest --method get \
     --url "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.ResourceHealth/events?api-version=2022-10-01&\$filter=properties/eventType%20eq%20'ServiceIssue'" \
     --query "value[:3].properties.{Type:eventType, Status:status, Title:title, Impact:impact[0].impactedRegions[0].impactedRegion}" --output table
   ```

   ```
   Type          Status     Title                                          Impact
   ------------  ---------  ---------------------------------------------  ---------
   ServiceIssue  Resolved   Storage - West Europe - Mitigated              westeurope
   ```

   Tres capas distintas, y saber a cuál mirar es la habilidad diagnóstica: **Service Health** = eventos a nivel Azure que tocan tu suscripción. **Resource Health** = este recurso específico. **Azure Monitor** = tu telemetría sobre tu aplicación. Un error 500 con Resource Health en `Available` y sin evento de Service Health es un bug tuyo.

#### Comprobá tu comprensión

- **Q7.1** — Distinguí "gestión *de* la nube" de "gestión *en* la nube" y clasificá cada uno de estos: una plantilla ARM, el portal de Azure, una regla de autoscale, Cloud Shell, una alerta de Monitor, la CLI `az`.
- **Q7.2** — What-if sobre una plantilla sin cambios reportó `no change`. Explicá por qué esto hace segura la plantilla para ejecutarse en cada commit de CI, y nombrá una categoría de cambio manual que what-if *no* va a marcar como deriva.
- **Q7.3** — El paso 5 detectó un tag que alguien cambió en el portal. Desplegar la plantilla lo revierte. Dá un escenario donde esa reversión automática es exactamente lo correcto y otro donde destruye algo valioso, e indicá el control de proceso que separa a los dos.
- **Q7.4** — Un usuario reporta errores 500. Resource Health dice `Available` y no hay evento de Service Health para tu región. ¿Qué descartaste, qué queda, y a cuál de las tres capas de telemetría vas después?
- **Q7.5** — El activity log registró la creación denegada por policy de la storage account como `Failed` con la identidad de quien la llamó. ¿Por qué una solicitud *rechazada* merece 90 días de retención, si nunca se creó ningún recurso?

---

## Bloque 8 — Desmantelamiento

**Objetivo:** el camino de borrado es parte del beneficio. On-premises, dar de baja es un proyecto; acá es una sola llamada idempotente — pero solo si sabés qué vive fuera del resource group.

### Pasos

1. Inventariá lo que está por destruirse. Nunca borres un resource group que no listaste antes.

   ```bash
   az resource list --resource-group "$RG" \
     --query "[].{Name:name, Type:type, Location:location}" --output table
   ```

   ```
   Name                   Type                                             Location
   ---------------------  -----------------------------------------------  ----------
   vmss-web-az900         Microsoft.Compute/virtualMachineScaleSets        eastus
   vmss-web-az900_a1b2    Microsoft.Compute/virtualMachines                eastus
   vmss-web-az900_c3d4    Microsoft.Compute/virtualMachines                eastus
   st3f9a1c22lrs          Microsoft.Storage/storageAccounts                eastus
   st3f9a1c22zrs          Microsoft.Storage/storageAccounts                eastus
   st3f9a1c22gzr          Microsoft.Storage/storageAccounts                eastus
   stallowed3f9a1c22      Microsoft.Storage/storageAccounts                westus2
   stdecl3f9a1c22         Microsoft.Storage/storageAccounts                westus2
   ```

2. Borrá primero el rol personalizado con alcance de suscripción — **no** está dentro del resource group y va a sobrevivir al borrado, dejando una definición huérfana.

   ```bash
   az role definition delete --name "AZ900 VM Restart Operator"
   az role definition list --custom-role-only true --name "AZ900 VM Restart Operator" --output tsv | wc -l
   ```

   ```
   0
   ```

3. Borrá el resource group. Las asignaciones de policy y el budget están acotados a él y se van con él.

   ```bash
   az group delete --name "$RG" --yes --no-wait
   az group exists --name "$RG"
   ```

   ```
   true
   ```

   `true` inmediatamente después de emitir el borrado es lo esperado — `--no-wait` volvió apenas ARM aceptó la solicitud. El borrado es asincrónico y ARM calcula por sí mismo el orden de dependencias: NICs antes que VNets, discos antes que VMs.

4. Confirmá la finalización unos minutos después, y verificá que no haya sobrevivido nada a nivel de suscripción.

   ```bash
   sleep 300
   az group exists --name "$RG"
   az policy assignment list --query "[?contains(name,'az900') || contains(name,'deny-wrong-region')].name" --output tsv | wc -l
   ```

   ```
   false
   0
   ```

#### Comprobá tu comprensión

- **Q8.1** — La definición de rol personalizado necesitó un borrado aparte pero las asignaciones de policy no. Enunciá la regla general, y nombrá otros dos tipos de objeto que comúnmente sobreviven al borrado de un resource group.
- **Q8.2** — `az group delete` no necesitó que le dieras ningún orden de dependencias. ¿Qué componente calcula ese orden, y por qué esta capacidad específica es un ejemplo del beneficio de manejabilidad y no del de disponibilidad?
- **Q8.3** — Un failover GZRS no planificado (bloque 4) convierte la cuenta a LRS y tarda horas en revertirse, mientras que un resource group entero se borra en minutos y no puede revertirse en absoluto. ¿Cuál amerita un resource lock, cuál amerita un runbook, y por qué son controles distintos?

---

## Respuestas

<details>
<summary><strong>Hacé clic para revelar todas las respuestas</strong></summary>

### Bloque 0

**A0.1** — Los despliegues de ARM son **declarativos**: `az group create` envía un estado final deseado, y ARM reconcilia la realidad con él. Si el resource group ya existe con esas propiedades, la reconciliación es un no-op y devuelve `Succeeded`. `az vmss scale` es distinto porque fija una cantidad absoluta de instancias, no relativa — ejecutarlo dos veces con el mismo valor *sí* es idempotente, pero es una acción del plano de control más que una declaración de estado, así que no se fusiona con decisiones concurrentes de autoscale. Dos fuentes de verdad en competencia para la cantidad de instancias (un escalado manual y un perfil de autoscale activo) van a pelear; el motor de autoscale gana en su siguiente evaluación.

**A0.2** — El registro de un provider es una propiedad de la **suscripción**, que está por encima de los resource groups en la jerarquía (management group → suscripción → resource group → recurso). Registrar `Microsoft.ResourceHealth` hace que ese tipo de recurso sea desplegable en *todos* los resource groups de la suscripción. En la práctica: una plantilla que funciona en una suscripción puede fallar en otra con un error oscuro de "resource type not found" puramente porque nunca se registró un provider ahí.

### Bloque 1

**A1.1** — **No.** El mapeo lógico-a-físico de zonas está aleatorizado **por suscripción**. Que tu lógica `2` mapee a `eastus-az3` no dice nada sobre su lógica `2`. Las consecuencias corren en ambas direcciones:
- *Asumir que son la misma cuando son distintas*: creés que la VM y la base de datos están colocadas juntas y presupuestás latencia intrazona (~submilisegundo), pero el tráfico en realidad cruza zonas (~1–2 ms) — un workload conversador que hace miles de idas y vueltas por request se degrada de forma medible.
- *Asumir que son distintas cuando son la misma*: creés que tenés aislamiento de fallos a nivel de zona entre dos capas, pero ambas viven en el mismo edificio físico. Un solo evento de datacenter se lleva a las dos, y tu arquitectura "zone-redundant" tiene la disponibilidad de una monozona.

El arreglo es comparar `availabilityZoneMappings` entre ambas suscripciones y alinear sobre zonas *físicas*, que es exactamente por lo que Microsoft expone esa API.

**A1.2** — Cada forma elimina un dominio de fallo distinto, y los tamaños reflejan con qué frecuencia falla realmente cada dominio:
- VM única sobre Premium SSD (99.9%): no sobrevive a nada estructural. Azure puede hacer live migration esquivando algunos problemas de host, pero el fallo de host, el fallo de rack y el mantenimiento planificado de hosts causan caída.
- Availability set (99.95%): distribuye entre **fault domains** (racks independientes — alimentación y switch top-of-rack separados) y **update domains** (parcheo escalonado de hosts). Esto elimina el fallo de rack y, más importante, el mantenimiento planificado — la causa más *frecuente* de caída de una VM única. La ganancia es de apenas 0.05 puntos porque ambas instancias siguen compartiendo la energía, la refrigeración y la entrada de red de un mismo datacenter.
- Availability zones (99.99%): elimina la correlación de datacenter compartido. Los 0.04 puntos adicionales son pequeños en términos porcentuales pero representan eliminar una *clase* entera de fallo correlacionado — inundación, incendio, red eléctrica, fallo de refrigeración — que ninguna redundancia dentro del datacenter aborda.

Los porcentajes se comprimen porque los eventos subyacentes se vuelven más raros a medida que el dominio se agranda. Los fallos de rack son comunes y baratos de sobrevivir; las pérdidas de datacenter son raras y caras de sobrevivir.

**A1.3** — `0.9995 × 0.9999 × 0.9999 = 0.99930008` → 99.93%, o **6.13 h/año**, bajando desde 14.01. Una mejora de **~7.9 horas por año** por arreglar el único eslabón más débil. Principio general: **en una cadena en serie el compuesto está dominado por el peor componente.** Mejorar cualquier otra cosa rinde muchísimo menos. Antes de gastar esfuerzo en la base de datos de 99.99%, encontrá y arreglá la capa de storage de 99.9%. Corolario: agregar *cualquier* dependencia nueva, por confiable que sea, solo puede bajar el compuesto — así que quitar una dependencia es en sí mismo una mejora de disponibilidad.

**A1.4** — El campo `Zones` de la salida de `az vm list-skus`. Una lista vacía o parcial (por ejemplo `["1","2"]`), o una entrada de `Restrictions` con `NotAvailableForSubscription`, significa que el SKU no puede colocarse en todas las zonas.

La cantidad de instancias no prueba nada sobre el reparto por zonas porque la colocación en zonas es una **solicitud de colocación, no una garantía bajo restricción**. Con `--zones 1 2 3` y 2 instancias, Azure distribuye entre las zonas *disponibles*; si la capacidad o una restricción de SKU descartan las zonas 2 y 3, ambas instancias caen en la zona 1 y el despliegue igual reporta éxito. La única prueba es consultar la propiedad `zones` real en las instancias desplegadas — bloque 2, paso 2. Por eso la regla operativa es "verificá la colocación, no la asumas".

### Bloque 2

**A2.1** — El peor caso es de aproximadamente **13 minutos**: hasta 5 minutos para que la ventana de métrica se llene de muestras de CPU alta (un pico en el minuto 0 no empuja un *promedio* de 5 minutos por encima del 70% hasta que domina la ventana), ~1 minuto para el intervalo de evaluación del motor de autoscale y la emisión de la acción de escalado, más ~3 minutos de aprovisionamiento de instancia, arranque y aprobación del health probe. El cooldown de 5 minutos aplica después a la *siguiente* acción, no a esta.

Acortá primero la **ventana de métrica** — es la mayor y la más barata de cambiar. El riesgo es sensibilidad a picos transitorios: una ventana de 60 segundos va a escalar hacia afuera por una pausa de garbage collection o un batch job que se habría resuelto solo, costando plata y, si se combina con una regla de scale-in agresiva, causando flapping. El compromiso habitual es una ventana de 2–3 minutos con un umbral de scale-out lo bastante bajo (55–60%) como para empezar a aprovisionar antes de que la capa esté realmente saturada. El tiempo de aprovisionamiento se ataca por separado — con imágenes prehorneadas o instancias precalentadas — no ajustando el autoscale.

**A2.2** — Están comprando una hora-instancia de B2s por cada hora fuera de pico, más o menos **USD 0.04/hora** a precio de lista, o sea alrededor de **USD 15/mes** si el fuera de pico son 12 h/día.

Están resignando el SLA completo de redundancia por zonas. Con `min-count 1` hay una instancia en una zona, que es el nivel de VM única — **99.9%** con Premium SSD, o 99.5% con Standard SSD. Eso es pasar de 4.38 a 43.8 minutos de caída mensual permitida, un **aumento de 10x en el presupuesto de caída**, a cambio de USD 15. Peor, aplica precisamente de noche, cuando la detección y la respuesta son más lentas y el fallo de una sola instancia significa una caída total en vez de capacidad degradada. El encuadre correcto para la conversación no es "fiabilidad vs costo" sino "USD 15/mes vs 39 minutos extra de riesgo de caída mensual sin supervisión".

**A2.3** — La asimetría codifica el costo asimétrico de equivocarse. Estar subaprovisionado causa errores visibles para el usuario e ingresos perdidos; estar sobreaprovisionado cuesta unas pocas horas-instancia. Entonces: escalar hacia afuera rápido y con generosidad, hacia adentro lento y con cautela.

Escenario de fallo con un `−2 / +2` simétrico: una capa corre con 4 instancias al 24% de CPU. La regla de scale-in dispara y quita 2, dejando 2 instancias a ~48%. Después el tráfico sube 40% — variación diaria normal — poniendo a las 2 instancias restantes a ~67%, por debajo de un umbral de scale-out del 70%, así que no pasa nada. Luego una instancia falla o se parchea, y la última absorbe el 100% del tráfico, se satura y empieza a dar timeouts. El scale-in agresivo eliminó el margen que habría absorbido tanto la suba de tráfico como la pérdida de instancia. Quitar de a 1 mantiene el tamaño del paso más chico que el colchón del que dependés.

**A2.4** — El **perfil programado** es el que hace el trabajo útil. Aprovisiona capacidad a las 08:00 por reloj, sin retraso — el autoscale reactivo no puede arrancar hasta que la carga ya llegó y llenó una ventana de métrica, así que los primeros 5–13 minutos del pico pegan contra una capa subaprovisionada.

Mantener las reglas por métrica importa porque el cronograma codifica lo que *predijiste*, y las reglas por métrica manejan lo que efectivamente pasa: una campaña de marketing, una tormenta de reintentos, una lentitud de dependencia que infla la duración de las requests, o un feriado en el que la carga predicha nunca llega. El perfil programado del paso 7 tiene su propio `min 4 / max 20` con las reglas por métrica todavía activas dentro — así que el cronograma fija el *piso y el techo* mientras las reglas se mueven dentro de ellos. Programá para lo conocido, reaccioná ante lo desconocido.

**A2.5** — Condiciones concretas de plataforma que producen colocación en una sola zona: (1) **restricción de capacidad** — el SKU solicitado no tiene capacidad disponible en las zonas 2 y 3 en ese momento, y Azure satisface el despliegue desde la zona que puede servirlo; (2) **restricción de zona del SKU** — el SKU simplemente no se ofrece en esas zonas para tu suscripción, mostrado como `NotAvailableForSubscription` en `restrictions`; (3) **cuota agotada** en la familia regional de vCPU.

El comando de detección es `az vm list-skus --location $LOC --size <SKU> --resource-type virtualMachines --query "[0].{Zones:locationInfo[0].zones, Restrictions:restrictions}"` del bloque 1, paso 3, ejecutado *antes* del despliegue. Después del despliegue, `az vm list --query "[].zones"` del bloque 2, paso 2, confirma qué pasó realmente. Usá los dos: el primero predice, el segundo verifica.

### Bloque 3

**A3.1** — `701.28` es el **precio total de una reserva de 1 año para un D2s v5**, pagado por adelantado o amortizado mensualmente a lo largo del plazo. No es una tarifa horaria; el campo `unitOfMeasure: "1 Hour"` se hereda del esquema del medidor y es engañoso para los registros de tipo reserva — el discriminador es `type: "Reservation"` más el campo `reservationTerm`.

Un dashboard que confíe en `unitOfMeasure` multiplicaría 701.28 × 8760 horas y reportaría **USD 6.143.213 por año** para una VM chica — un error de aproximadamente cuatro órdenes de magnitud. La normalización correcta es `retailPrice ÷ (8760 × años)`. Ramificá siempre según `type` y `reservationTerm` antes de hacer aritmética con esta API.

**A3.2** — 10 h/día × 5 días = 50 h/semana, contra 168 h en una semana → **29.8% de utilización**, muy por debajo del equilibrio de 83.4%. Una reserva costaría más o menos 2.8x lo que costaría simplemente pagar on-demand. **Una reserva es incorrecta para este workload.**

Mejores opciones, en orden de preferencia: (1) **apagado automático / arranque-parada programados** (`az vm auto-shutdown`, o una Logic App / runbook de Automation) para pagar on-demand solo las 50 horas — esta es la palanca más grande y se compone con todo lo demás; (2) **precios Azure Dev/Test** si la suscripción califica, que quitan el componente de licencia de Windows/SQL y descuentan muchos medidores; (3) **instancias spot** si el trabajo tolera el desalojo, que es el caso de la mayoría de dev/test. Un **Azure savings plan for compute** es más flexible que una reserva (compromete gasto por hora en vez de un SKU específico) pero igual asume una línea de base sostenida, así que tampoco rescata a un workload al 30% de utilización.

**A3.3** — Encaje correcto: **transcodificación de video por lotes**, agentes de build de CI, simulación Monte Carlo, o cualquier batch job vergonzosamente paralelo con checkpointing. Si una instancia es desalojada a mitad del trabajo, el ítem vuelve a la cola y otro worker lo toma; el throughput total baja, la corrección no.

Categóricamente inadecuado: **el nodo primario de una base de datos con estado**, una API de procesamiento de pagos, o una capa web que sostiene sesiones. El desalojo con 30 segundos de aviso significa que las transacciones en vuelo mueren y, para un primario con estado, potencialmente se pierden escrituras no replicadas.

La propiedad que decide es la **interrumpibilidad** — específicamente, si el trabajo está checkpointeado o es reencolable de manera tal que perder una instancia a mitad de tarea cueste *tiempo* y no *corrección*. Si perder un worker significa rehacer trabajo, spot está bien. Si significa perder datos o fallar una request de usuario que no puede reintentarse de forma transparente, no.

**A3.4** — Reservá **4** — el piso observado y el `min-count` del autoscale. Esas 4 instancias corren el 100% del tiempo por construcción, así que están muy por encima del equilibrio de 83.4% y capturan el descuento completo. Las instancias 5 a 20 corren de forma intermitente; deberían ser on-demand (o spot, si la capa lo tolera).

Reservar las 20 es peor que no reservar ninguna porque una reserva se **paga se use o no la capacidad**. Dieciséis de ellas quedarían con ~5% de utilización, costando el precio completo de reserva de 1 año por casi ningún consumo — pagarías aproximadamente 4x lo necesario y lo habrías fijado por 12 meses. No reservar nada simplemente renuncia a un descuento del 16.6% sobre la línea de base; reservar todo desperdicia activamente plata que no podés recuperar. Las reservas se aplican automáticamente a cualquier instancia en ejecución que coincida dentro del alcance, así que subreservar degrada con gracia mientras que sobrerreservar no.

**A3.5** — Dos razones legítimas: (1) **diferencias en los costos de insumos** — electricidad, terreno, construcción, mano de obra, tránsito de red e impuestos locales varían enormemente por país; la energía y la conectividad sudamericanas cuestan sustancialmente más por unidad que las norteamericanas. (2) **escala y utilización** — East US es una de las regiones más grandes de Azure, con un volumen de hardware enorme y alta utilización sostenida, así que los costos fijos se amortizan sobre muchas más horas facturables; una región más chica arrastra más capacidad ociosa por cliente. Un tercer factor son los **derechos de importación y el costo de cumplimiento regulatorio** sobre el hardware en algunas jurisdicciones.

Sobreprecio obligatorio: **legislación de residencia de datos**. Si la regulación brasileña (la LGPD en sectores específicos, o normas del sector financiero) exige que los datos personales permanezcan dentro de las fronteras nacionales, desplegar en East US no es una optimización de costos — es una violación de cumplimiento. Lo mismo aplica a los requisitos de residencia derivados del GDPR europeo, los mandatos de nube soberana del sector público y las normas de datos sanitarios. En esos casos el diferencial de precio no es una variable de decisión en absoluto.

### Bloque 4

**A4.1** — **Sí, el SLA se cumplió.** La durabilidad mide la probabilidad de que Azure pierda tus datos por un fallo de *infraestructura* — corrupción de disco, muerte de una unidad, pérdida de nodo, degradación de bits. Once nueves significan una probabilidad esperada de pérdida anual del 0.000000001% para un objeto dado. No dice nada sobre llamadas a la API autorizadas. El `DELETE` vino de un principal con credenciales, fue autorizado por RBAC, y Azure lo ejecutó correctamente replicando el borrado a las tres copias en milisegundos. **La replicación propaga los errores con exactamente la misma fidelidad con la que propaga los datos.**

Las dos protecciones que sí abordan esto:
- **Soft delete** para blobs y containers (`az storage account blob-service-properties update --enable-delete-retention true --delete-retention-days 30`), que retiene los datos borrados durante una ventana de retención y permite deshacer el borrado.
- **Point-in-time restore** para block blobs, y **versionado de blobs**, que conservan versiones anteriores para que una sobrescritura o un borrado sea recuperable.

Más allá de esas, **políticas de inmutabilidad** (WORM / legal hold) para datos regulatorios, **resource locks** (`CanNotDelete`) contra el borrado de la cuenta en sí, y un **backup** genuino en una cuenta separada con credenciales separadas — porque una credencial comprometida puede deshabilitar el soft delete. La redundancia no es backup: la redundancia protege contra el fallo de la plataforma, el backup protege contra tu propio fallo.

**A4.2** — (a) **12 minutos de pérdida de datos** — cada escritura confirmada al cliente después de `lastSyncTime` existe solo en la primaria perdida. Esas transacciones se fueron, y los clientes que recibieron una respuesta 200 por ellas no lo van a saber.
(b) La cuenta ahora es **LRS en la antigua región secundaria** (West US). El failover no planificado promueve la secundaria y degrada el nivel de redundancia.
(c) El riesgo adicional: ahora estás corriendo **en una sola región, un solo datacenter** durante un incidente activo, exactamente en el momento en que se está redirigiendo carga hacia vos y la plataforma puede seguir inestable. Un segundo fallo — incluso uno rutinario — no tiene redundancia que lo absorba. Restablecer la georredundancia significa reconfigurar la cuenta a GRS/GZRS y esperar una replicación inicial completa de todo el dataset, que para una cuenta grande lleva de horas a días. Planificá la recuperación de tu postura de recuperación, no solo el failover.

**A4.3** — Miden cosas distintas.
- **Durabilidad vs. disponibilidad**: las copias extra de GRS están en otra *región*, alcanzadas de forma asincrónica. Esas copias elevan la probabilidad de que los bytes sobrevivan a una catástrofe (16 nueves vs 12) pero no hacen nada por la latencia de lectura ni por la disponibilidad de lectura en la primaria durante la operación normal.
- **La secundaria de GRS no es legible en absoluto** salvo que la cuenta sea específicamente **RA-GRS**. La secundaria del GRS común existe solo como destino de failover; un cliente no puede leer de ella, así que aporta cero a la disponibilidad en operación normal.
- **ZRS sirve lecturas desde tres zonas de forma sincrónica.** Las tres copias están vivas, consistentes y en el camino de la request. Perder una zona significa que las requests se sirven desde las otras dos sin failover, sin pérdida de datos y sin acción del operador — la disponibilidad se preserva de forma *transparente*.

Entonces: ZRS compra **mayor disponibilidad con RPO cero dentro de una región**; GRS compra **sobrevivir a la pérdida de la región, con un RPO no nulo y un failover manual y disruptivo**. GZRS es la combinación, y por eso es la recomendación por defecto para datos productivos que deben sobrevivir a ambas cosas.

**A4.4** — Elegí **`Standard_ZRS`** (o `Premium_ZRS` para workloads sensibles a la latencia). Es la redundancia más fuerte disponible sin salir del país: tres copias sincrónicas en tres availability zones, sobreviviendo a la pérdida de un datacenter entero con RPO cero.

El riesgo que queda es la **pérdida de la región entera** — un evento a escala de país, o un fallo del plano de control regional de Azure. ZRS no tiene ninguna copia fuera de esa región, así que un evento así significa indisponibilidad total y potencialmente pérdida total de datos.

Controles compensatorios: (1) **Azure Backup o una exportación programada a una segunda storage account en la misma región pero en otra cuenta y otra suscripción**, que como mínimo protege contra accidentes a nivel de cuenta y compromiso de credenciales aunque comparta el destino regional; (2) **un backup offline o fuera de Azure mantenido dentro de las fronteras nacionales** — la región dentro del país de un segundo proveedor de nube, o cinta/almacenamiento de objetos on-premises — que normalmente es el único control que aborda genuinamente la pérdida regional bajo una restricción de residencia; (3) un **RPO/RTO para el escenario de pérdida regional** explícitamente documentado y firmado por el negocio, ya que el riesgo no puede eliminarse por ingeniería, solo aceptarse a sabiendas. Confirmá también si la regulación prohíbe que los datos salgan del país o simplemente exige que estén *almacenados* en el país — algunos marcos permiten un backup cifrado en el exterior siempre que las claves permanezcan domésticas, lo que cambia por completo la respuesta.

**A4.5** — **Una migración planificada entre regiones.** Concretamente: estás relocalizando un workload de East US a West US por razones de latencia o costo, y necesitás mover los datos de la storage account con pérdida cero. La primaria está sana, así que iniciás un failover planificado; Azure replica por completo todas las escrituras pendientes y después promueve la secundaria. El RPO es cero y no se pierde ninguna transacción.

Otros casos válidos: **ensayar tu runbook de DR** (probar que el camino de failover funciona, que el DNS y las cadenas de conexión lo siguen, y que las aplicaciones se reconectan — antes de tener que hacerlo bajo presión); y **evacuar proactivamente una región ante un evento anunciado**, como un aviso de Service Health por mantenimiento planificado o un desastre natural pronosticado, donde todavía tenés una primaria sana y tiempo para actuar. El failover planificado es una herramienta de *migración y ensayo*; el no planificado es la de emergencia. Confundirlos es la forma en que los equipos descubren durante una caída que su runbook nunca fue probado.

### Bloque 5

**A5.1** — **El throughput no va a cambiar en absoluto.** Las 3.750 IOPS y los 82 MiB/s medidos son los topes `UncachedDiskIOPS` y `UncachedDiskBytesPerSecond` de la *VM*. Un P40 eleva los límites aprovisionados del disco a 7.500 IOPS / 250 MB/s, pero la VM ya no podía consumir los 5.000 / 200 del P30. El cuello de botella no cambia; la factura sube.

El arreglo correcto es **redimensionar la VM** a una cuyos topes de disco superen el rendimiento aprovisionado del disco — `Standard_D8s_v5` (12.800 IOPS) o mayor, según la tabla del paso 4. Entonces el P30 pasa a ser la restricción vinculante y obtenés sus 5.000 IOPS completas. La regla general: **verificá `min(tope de VM, tope de disco)` antes de aprovisionar cualquiera de los dos**, y emparejalos. Si la CPU queda ociosa después del cambio de tamaño, eso no es desperdicio — compraste la VM por su envolvente de E/S, y en Azure la envolvente de E/S se vende empaquetada con vCPUs.

Una opción secundaria, si redimensionar es inaceptable, es el **host caching** (`--caching ReadOnly` en el disco de datos) — las IOPS cacheadas usan un presupuesto separado y mayor (`CachedDiskIOPS`) y se sirven desde NVMe/RAM local en el host. Eso ayuda a workloads con mucha lectura cuyo working set entra en la caché, y no hace nada para los de escritura intensiva.

**A5.2** — Una plataforma multiinquilino sin topes hace que el rendimiento sea función de **lo que están haciendo tus vecinos**, que es el problema del vecino ruidoso. Concretamente:
- **Nadie puede dimensionar capacidad.** No podés hacer pruebas de carga de forma significativa, porque el resultado de hoy depende de la carga de los otros inquilinos hoy. La planificación de capacidad se vuelve adivinanza y toda revisión de incidente termina en "ese día estaba más lento".
- **Ningún SLA es posible.** Una garantía de rendimiento requiere que la plataforma controle las variables; si cualquier inquilino puede consumir E/S sin límite, la plataforma no puede prometerle nada a nadie.
- **El inquilino que habría usado el margen también sale perjudicado**, que es la parte contraintuitiva. A veces obtiene ráfagas de rendimiento extra y a veces no — así que debe diseñar para el *peor* caso que haya observado, que es lo mismo que el caso topeado, pero sin nada de la previsibilidad. No puede diseñar con seguridad para el buen caso, así que el margen es inutilizable incluso cuando está presente. Mientras tanto sus propias ráfagas vuelven impredecibles los números de todos los demás, invitando a un sobreaprovisionamiento en represalia por toda la plataforma.

El topeo convierte una variable que no podés controlar en una constante alrededor de la cual podés diseñar. Eso es precisamente el beneficio de "previsibilidad": un rendimiento sobre el que podés *razonar* vale más que un rendimiento ocasionalmente más alto. La válvula de escape para necesidades genuinas de ráfaga es explícita y con precio — las B-series burstables con créditos, o los Ultra Disks con IOPS aprovisionadas de forma independiente — donde la ráfaga es una funcionalidad del producto con límites definidos y no un accidente del comportamiento del vecino.

**A5.3** — Una alerta de pronóstico el día 9 te informa el **ritmo de gasto**, no el total. El gasto real en ese momento podría ser de USD 15 sobre un budget de USD 50 — nada alarmante en aislamiento — pero el pronóstico extrapola el ritmo diario reciente a los 21 días restantes y proyecta un total de fin de mes por encima de USD 45. En otras palabras: *algo cambió recientemente y, si continúa, te vas a pasar.* Las alertas de gasto real no pueden decirte esto, porque para cuando el real cruza el 100% la plata ya se gastó y el mes ya terminó.

Primer diagnóstico: obtener la **tendencia de costo diaria desglosada por recurso**, para encontrar qué empezó y cuándo.

```bash
az costmanagement query --type ActualCost \
  --scope "/subscriptions/$SUB/resourceGroups/$RG" \
  --timeframe MonthToDate --dataset-granularity Daily \
  --dataset-aggregation '{"cost":{"name":"PreTaxCost","function":"Sum"}}' \
  --dataset-grouping name=ResourceId type=Dimension
```

La forma que buscás es un cambio escalonado — un costo diario plano que salta en una fecha específica — que apunta al despliegue, evento de escalado o recurso olvidado que lo causó. Cruzá esa fecha contra `az monitor activity-log list` para encontrar el cambio que lo produjo. Culpables comunes: un `max-count` de autoscale alcanzado y sostenido, una VM que quedó corriendo después de una prueba, un disco premium adjuntado y nunca desconectado, o egress de un job de backup mal configurado.

**A5.4** — **Camino de aplicación efectiva para no producción:** cableá la notificación del budget a un **action group** que dispare un runbook de Azure Automation o una Logic App; en el umbral de 100% real, el runbook enumera los recursos de la suscripción etiquetados con `env=dev` y desasigna las VMs, baja los App Service plans al nivel gratuito/compartido y publica en el canal del equipo qué detuvo. Los budgets por sí mismos solo notifican, así que la automatización es lo que convierte una notificación en un control. Combinalo con la notificación más suave de 90% de pronóstico dirigida primero a humanos, así alguien tiene chance de intervenir antes de que actúe la automatización.

**Por qué no en producción:** la automatización no puede distinguir "costo descontrolado por un bug" de "costo legítimo por un pico de tráfico" — y un pico de tráfico es exactamente cuando salta un umbral de budget y exactamente cuando menos querés que se quite capacidad. Desasignar producción automáticamente convierte un problema de costo, que se recupera con una tarjeta de crédito y una conversación, en una caída, que no. El sobregasto está acotado y es reversible; la caída no está acotada en términos reputacionales ni de ingresos. En producción la alerta de budget debería despertar a una persona, y la aplicación efectiva debería ser arquitectónica — cobertura de reservas, techos de `max-count` en autoscale y límites de cuota que acoten el radio de explosión *antes* del gasto en vez de reaccionar después.

**A5.5** — **Redimensioná la VM a un SKU más grande**, aunque la CPU esté ociosa — por ejemplo `Standard_D2s_v5` → `Standard_D8s_v5`, llevando `UncachedDiskIOPS` de 3.750 a 12.800. Alternativamente, mudate a una familia optimizada para storage (Lsv3) cuyos topes de E/S son altos en relación con la cantidad de vCPU, si el workload es genuinamente ligado a E/S y liviano en CPU.

Esto se siente mal desde el hábito on-premises porque allá la CPU, la RAM, la controladora de storage y los discos son **comprables de forma independiente**. Si un servidor estaba ligado a E/S, agregabas un HBA, más discos o una capa de SSD, y dejabas la CPU en paz — comprar CPU que no ibas a usar era obviamente un desperdicio.

En Azure el SKU de VM es un **paquete**: vCPUs, memoria, ancho de banda de red, cantidad de NICs e IOPS/throughput de disco escalan juntos como una única unidad comprable. No podés comprar la envolvente de E/S por separado, así que la única palanca para más E/S es un paquete más grande. La corrección mental es dejar de pensar el SKU como "una cantidad de CPU" y empezar a pensarlo como "una envolvente de rendimiento en cinco dimensiones", y después dimensionar según la dimensión que ate. Existen dos escapes parciales — **Ultra Disk** y **Premium SSD v2** permiten aprovisionar IOPS y throughput independientemente de la capacidad, y el host caching usa un presupuesto separado — pero el tope a nivel de VM sigue acotando todo, así que el cambio de tamaño normalmente sigue siendo necesario.

### Bloque 6

**A6.1** — **Bajo `Audit`:** la solicitud de `create` del desarrollador es autorizada por RBAC y se ejecuta. La storage account existe, solo-HTTP, y es alcanzable de inmediato. El desarrollador conecta una aplicación a ella y los datos empiezan a fluir en texto claro. Hasta 24 horas después (o antes si se dispara un escaneo, o por la evaluación al cambiar el recurso) el estado de cumplimiento pasa a no conforme. Alguien tiene que notar el dashboard, identificar al dueño, abrir un ticket y conseguir que se remedie — realistamente de horas a semanas. **La ventana de exposición corre desde la creación del recurso hasta que se completa la remediación manual**, y cada byte transmitido en esa ventana viajó sin cifrar por la red. Nada de `Audit` acorta esa ventana; solo la registra.

**Bajo `Deny`:** ARM evalúa la policy durante la admisión de la solicitud, *antes* de invocar al resource provider. La solicitud devuelve `RequestDisallowedByPolicy` en unos segundos. **No existe ningún recurso, no fluye ningún dato, y la ventana de exposición es cero.** El desarrollador recibe un error inmediato y específico que nombra la policy, corrige la plantilla y sigue — normalmente dentro del mismo minuto de trabajo.

El intervalo en riesgo bajo `Audit` es: *momento de creación → detección → triaje → remediación*, del cual el componente de detección solo puede ser de 24 horas. `Deny` colapsa todo el intervalo a nada al mover la aplicación efectiva de *después del hecho* al *control de admisión*. Este es el núcleo del beneficio de gobernanza: la prevención no es meramente detección más rápida, elimina el estado de fallo por completo.

**A6.2** — Asigná primero con **`enforcementMode: DoNotEnforce`** (`--enforcement-mode DoNotEnforce`). La policy evalúa cada recurso y llena el informe de cumplimiento completo, pero no bloquea ninguna solicitud.

El fallo exacto que se evita: con `Deny` y `enforcementMode: Default`, la policy **no** borra ni modifica los 400 recursos existentes que violan — deny es control de admisión, así que los recursos preexistentes simplemente se reportan como no conformes y siguen corriendo. Pero cada **escritura** posterior sobre ellos queda bloqueada. Eso significa que el próximo `PUT` rutinario de un pipeline de CI, una operación de autoscale, una actualización de tag, una rotación de certificado o cualquier redespliegue de plantilla ARM falla con `RequestDisallowedByPolicy`. No rompiste los recursos; rompiste la capacidad de *gestionarlos*, en 400 recursos y en todos los equipos que los poseen, simultáneamente y sin aviso. La recuperación significa quitar la asignación bajo presión o correr a remediar 400 recursos mientras sus dueños no pueden desplegar.

El despliegue seguro: (1) asignar `DoNotEnforce` y recolectar el informe de cumplimiento; (2) publicar la lista de infractores a los dueños con una fecha límite; (3) remediar — con una policy `Modify`/`DeployIfNotExists` y una tarea de remediación donde el arreglo sea mecánico; (4) confirmar que el cumplimiento esté en o cerca del 100%; (5) pasar a `Default` para que la policy prevenga violaciones *nuevas*. Opcionalmente usar `notScopes` o una exención de policy con fecha de vencimiento para los rezagados, así la excepción queda rastreada y acotada en el tiempo en vez de ser silenciosamente permanente.

**A6.3** — Son distintas porque sirven propósitos distintos en capas distintas:

- **La propagación de la asignación (~30 segundos a unos pocos minutos)** es un problema de *distribución del plano de control*. ARM debe empujar la nueva asignación a cada frontal regional de evaluación de policies que pudiera recibir una solicitud para ese alcance. Es corta porque está en el camino de admisión: una vez propagada, la policy se evalúa **de forma sincrónica en cada solicitud de escritura entrante**, así que no hay más demora — la aplicación efectiva es inmediata y continua a partir de ahí.

- **El escaneo de cumplimiento (~24 horas)** es un barrido de *reconciliación en segundo plano* sobre todos los recursos existentes en el alcance, evaluando cada uno contra cada asignación aplicable. Es caro y corre en un ciclo lento porque es una función de reporte, no de aplicación efectiva. También corre al cambiar un recurso y puede dispararse bajo demanda (`az policy state trigger-scan`).

**Cuál debería preocupar a quien revisa seguridad: la latencia de 24 horas del escaneo — pero solo para policies de efecto `Audit`.** Para policies `Deny` la latencia del escaneo es casi irrelevante, porque la aplicación efectiva ocurre en la admisión y el escaneo solo reporta sobre recursos anteriores a la asignación. Para policies `Audit` la latencia del escaneo *es* la latencia de detección, y un control cuyo tiempo medio de detección se mide en horas es un control débil. Esa asimetría es en sí misma el argumento para preferir `Deny` donde el negocio lo tolere: hace que el camino lento deje de importar.

**A6.4** — **No, no pueden desplegar.** Azure Policy y RBAC son compuertas independientes evaluadas por ARM en cada solicitud, y ambas deben pasar:

1. **Autenticación** — ¿quién sos?
2. **Autorización RBAC** — ¿tiene este principal una `Action` que permita esta operación en este alcance? `Owner` otorga `*`, así que esto pasa.
3. **Evaluación de policy** — ¿alguna asignación aplicable hace `Deny` de esta solicitud? La asignación a nivel de resource group coincide, así que esto **falla**.

Policy deliberadamente **no** puede ser anulada por un rol de RBAC, y `Owner` no confiere ninguna exención de policy. Este es el propósito del diseño: la policy expresa reglas organizacionales que valen sin importar el privilegio individual, así que una cuenta Owner comprometida o descuidada no puede desplegar en una jurisdicción prohibida. Además, deny se evalúa último y le gana a todo.

Caminos legítimos hacia adelante, en orden de preferencia:
- **Desplegar en una región permitida** — normalmente la policy tiene razón y la solicitud está equivocada.
- **Solicitar una exención de policy** (`az policy exemption create`) para el recurso o alcance específico, con una categoría (`Waiver` o `Mitigated`), una justificación y una **fecha de vencimiento**. Esto crea una excepción auditable y acotada en el tiempo.
- **Modificar los parámetros de la asignación** para agregar la región, si el requisito de negocio genuinamente cambió — un cambio a la regla en sí, revisado como tal.
- **Usar `notScopes`** para recortar un alcance hijo específico, si un resource group entero legítimamente queda fuera de la regla.

Lo que *no* deberían hacer es borrar la asignación. Eso remueve silenciosamente la barrera para todo el mundo, no deja registro de por qué, y es la forma más común en que un control de gobernanza desaparece calladamente de un parque.

**A6.5** — **No es un bug — el rol funciona como fue diseñado, aunque el diseño puede ser demasiado ajustado para el trabajo real del operador.**

Etiquetar una VM es una operación `Microsoft.Compute/virtualMachines/write`: ARM no tiene una acción separada de "solo tags" sobre el recurso mismo, porque los tags viven en la definición del propio recurso y actualizarlos es un `PUT`/`PATCH` sobre él. Dado que `write` también permite redimensionar, cambiar el perfil de OS, adjuntar discos y alterar el perfil de red, concederlo entregaría exactamente lo que el rol fue construido para retener.

El cambio mínimo que lo arregla sin conceder redimensionar ni borrar: asignar el rol incorporado **`Tag Contributor`** junto al rol personalizado, acotado al mismo resource group. `Tag Contributor` otorga `Microsoft.Resources/tags/*` — la acción del *subrecurso* tags — que permite leer y escribir tags sobre cualquier recurso del alcance sin otorgar ningún otro permiso sobre los recursos en sí. No puede redimensionar, no puede borrar, no puede leer propiedades del recurso más allá de lo que permita el otro rol.

Agregar `Microsoft.Resources/tags/*` directamente al array `Actions` del rol personalizado logra el mismo resultado en un solo rol en vez de dos, y es preferible si querés un único rol asignable. En cualquier caso, lo que *no* hay que hacer es agregar `Microsoft.Compute/virtualMachines/write` — esa única acción convierte silenciosamente a un operador de reinicio en algo muy cercano a un Contributor sobre las VMs. Cuando a un rol de mínimo privilegio le falta una acción, revisá si una acción de subrecurso o un rol incorporado angosto cubre el hueco antes de ensanchar el amplio.

### Bloque 7

**A7.1** — **Gestión *de* la nube** = automatizar, configurar y operar los recursos en sí — las cosas que construís para que el entorno funcione sin intervención manual. **Gestión *en* la nube** = las interfaces y herramientas a través de las cuales interactuás con Azure — las superficies que tocás.

| Ítem | Categoría | Razonamiento |
|---|---|---|
| Plantilla ARM | **de** la nube | Declara y automatiza la configuración de recursos; el artefacto define qué existe |
| Portal de Azure | **en** la nube | Una interfaz web para interactuar con Azure |
| Regla de autoscale | **de** la nube | Gestión automática de recursos respondiendo a la demanda, sin operador involucrado |
| Cloud Shell | **en** la nube | Un shell alojado en el navegador |
| Alerta de Monitor | **de** la nube | Monitoreo configurado y respuesta automatizada a condiciones de los recursos |
| CLI `az` | **en** la nube | Una interfaz de línea de comandos para interactuar con Azure |

La pregunta que divide: *¿es esto algo que gestiona recursos en mi nombre (de), o algo que uso para gestionar recursos yo mismo (en)?* El autoscale sigue funcionando cuando todos duermen; el portal no hace nada salvo que alguien esté clickeando.

**A7.2** — `no change` al reaplicar es **idempotencia**, y hace segura la CI porque la plantilla describe un *estado final deseado* en vez de una secuencia de acciones. Ejecutarla en cada commit converge la realidad hacia la declaración: si la realidad ya coincide, no pasa nada; si derivó, solo cambian las propiedades derivadas. No hay error de "ya existe" que haya que tratar como caso especial, no hace falta ramificar según si es el primer despliegue o el número cien, y no hay riesgo de que una reejecución duplique recursos. Esa propiedad es la que permite a un pipeline ejecutar `deployment group create` incondicionalmente al mergear a main.

**Lo que what-if no va a marcar: el estado del plano de datos.** What-if compara únicamente propiedades del plano de control de ARM. No va a detectar blobs agregados o borrados dentro de una storage account, filas en una base de datos, archivos en el disco de una VM, secretos rotados dentro del plano de datos de Key Vault, ni configuración cambiada *dentro* del OS invitado. También tiene puntos ciegos documentados en el plano de control: propiedades que el resource provider calcula o completa por defecto del lado del servidor pueden producir falsos positivos u omitirse por completo, los recursos creados fuera de la plantilla en el mismo resource group simplemente no se evalúan (what-if en modo `Incremental` reporta solo sobre los recursos que la plantilla declara), y los recursos hijos gestionados por otros medios pueden no aparecer. La advertencia impresa en la salida — "the result may contain false positive predictions (noise)" — es Microsoft reconociendo exactamente esto.

**A7.3** — **La reversión automática es exactamente lo correcto cuando:** la plantilla es la única fuente de verdad y el cambio manual fue no autorizado o accidental. Alguien editó a mano una storage account de producción en el portal para poner `allowBlobPublicAccess: true` mientras depuraba, y se olvidó de deshacerlo. Revertir cierra un agujero de seguridad, restaura la configuración revisada y lo hace sin que nadie tenga que acordarse. Este es el modelo operativo pretendido — infraestructura como código con reconciliación continua.

**La reversión automática destruye algo valioso cuando:** un ingeniero de guardia hizo un cambio deliberado de emergencia a las 03:00 — escaló una capa durante un incidente, abrió una regla de firewall para restaurar la integración con un socio, elevó un límite de throttling para absorber una oleada de tráfico — y la siguiente corrida de CI lo revierte silenciosamente con el incidente todavía abierto. El pipeline "exitosamente" reintroduce la caída, y como la reversión parece un despliegue verde de rutina, nadie conecta las dos cosas durante horas.

**El control de proceso que los separa: todo cambio de emergencia debe volcarse a la plantilla antes de la siguiente corrida de despliegue, y el pipeline debe poder pausarse.** Concretamente — (1) el último paso del runbook de incidentes es "portar el arreglo a la plantilla y abrir un PR", tratado como parte de la resolución, no como seguimiento posterior; (2) un mecanismo documentado de break-glass para deshabilitar el despliegue automático de un resource group nombrado durante un incidente activo, con la reactivación como ítem explícito de checklist; (3) **what-if ejecutado en el pipeline con el diff publicado para revisión** antes de aplicar, así una persona ve "revirtiendo `maxCount: 40 → 20`" y pregunta por qué; y (4) resource locks o exenciones de policy para los casos genuinamente manuales por diseño. El principio de fondo: la detección de deriva solo es segura cuando existe un camino rápido y de baja fricción para que los cambios legítimos se conviertan en cambios declarados. Si actualizar la plantilla es lento o burocrático, los ingenieros lo van a esquivar bajo presión y el lazo de reconciliación se convierte en un arma.

**A7.4** — **Lo que descartaste:** un incidente de plataforma a nivel Azure o regional (no hay evento de Service Health para tu región y servicios), y un problema con el host, la red o el storage subyacentes de ese recurso específico tal como los ve la plataforma (Resource Health en `Available` significa que el propio modelo de salud de Azure no encuentra nada mal con la VM — está corriendo, es alcanzable en la capa de infraestructura, y no está afectada por mantenimiento de host ni fallo de hardware).

**Lo que queda — todo lo que está por encima de la línea de infraestructura:** código de aplicación lanzando excepciones no manejadas; una dependencia fallando (pool de conexiones a la base de datos agotado, una API downstream con timeout, un certificado o credencial vencidos); agotamiento de recursos dentro del invitado (disco lleno, sin memoria, inanición del thread pool) que la plataforma no puede ver; mala configuración (una cadena de conexión incorrecta de un despliegue reciente, un feature flag equivocado); una regla de NSG o firewall bloqueando una dependencia; fallo de resolución DNS; o un tope de rendimiento alcanzado — un límite de IOPS de disco saturado del bloque 5 causando timeouts de request que se manifiestan como 500s. Notá que Resource Health reporta la visión de la *plataforma*: una VM puede estar `Available` mientras la aplicación adentro está completamente muerta.

**A dónde ir después: Azure Monitor** — específicamente Application Insights si está instrumentado. Empezá por la vista de fallos para obtener el tipo de excepción y el stack trace, después el mapa de dependencias para ver qué llamada downstream está lenta o fallando, y luego la distribución de duración de requests para distinguir "todo está lento" (saturación de recursos o de dependencias) de "un endpoint está roto" (un camino de código). En paralelo, revisá el activity log en busca de un despliegue o cambio de configuración inmediatamente anterior al primer error — un cambio que correlacione con el inicio del incidente es en la práctica la pista de mayor rendimiento. Si Application Insights no está, andá a las métricas de invitado de la VM y a los logs del OS invitado. La disciplina de las tres capas es lo que hace que esto sea rápido: dos de las tres capas ya quedaron despejadas en segundos, así que el espacio de búsqueda ahora está acotado a tu propio stack.

**A7.5** — Una solicitud rechazada es una **señal de seguridad y gobernanza**, y el hecho de que no se haya creado ningún recurso es precisamente lo que la vuelve interesante:

- **Telemetría de violaciones intentadas.** Un patrón de `RequestDisallowedByPolicy` desde un mismo principal puede indicar una credencial comprometida tanteando qué puede hacer, alguien de adentro probando límites o — mucho más a menudo, y tan digno de saberse como lo anterior — un equipo cuyo pipeline de despliegue está mal configurado e intenta repetidamente algo que la organización prohíbe. Ambos requieren acción; ninguno deja otro rastro.
- **Prueba de que el control funcionó.** Los auditores y los marcos de cumplimiento te piden *demostrar* que un control es efectivo, no meramente que está configurado. Un registro de solicitudes bloqueadas, con timestamps, identidades y la policy específica que las bloqueó, es esa evidencia. "La policy está asignada" es una afirmación de configuración; "acá hay 47 solicitudes que denegó el trimestre pasado" es una afirmación operativa.
- **Atribución para la reconstrucción de incidentes.** Durante una investigación de seguridad, la pregunta "¿qué *intentó* hacer este principal?" importa tanto como qué logró hacer. Las acciones exitosas dejan recursos; las fallidas dejan solo el log. Descartar los fallos dejaría una reconstrucción con la mitad del cuadro, y específicamente la mitad que revela la intención.
- **Diagnóstico de trabajo bloqueado.** Cuando alguien dice "mi despliegue no funciona", el activity log nombra la asignación y la definición exactas que lo detuvieron, convirtiendo una conversación de soporte en una consulta.

Más en general: el activity log registra la **intención en el plano de control**, no solo los resultados. Filtrar a solo éxitos lo convertiría en un registro de lo que pasó en vez de un registro de lo que se intentó — y la seguridad es en gran medida el estudio de lo que se intentó. Noventa días es la retención gratuita por defecto; para regímenes de cumplimiento que requieren más, exportá a un workspace de Log Analytics o a una storage account con una política de inmutabilidad.

### Bloque 8

**A8.1** — **La regla general: el borrado de un resource group elimina exactamente los objetos cuyo ID de recurso de ARM contiene ese resource group.** Cualquier cosa acotada *por encima* del resource group — a nivel de suscripción, management group o tenant — sobrevive, porque nunca fue hija del grupo. Las asignaciones de policy en este laboratorio se crearon con `--scope /subscriptions/.../resourceGroups/$RG`, así que sus IDs están dentro del grupo y se van con él. El ID de la definición de rol personalizado es `/subscriptions/$SUB/providers/Microsoft.Authorization/roleDefinitions/...` — con alcance de suscripción, sin importar lo que diga su `AssignableScopes` — así que persiste como huérfano.

Otros dos tipos de objeto que quedan huérfanos habitualmente:
- **Role assignments** creados a nivel de suscripción o de management group. (Las role assignments *acotadas al resource group borrado* se limpian, pero las que otorgan acceso a un principal a nivel de suscripción obviamente permanecen — y si el propio principal era una identidad administrada asignada por el sistema sobre un recurso borrado, te quedan asignaciones que referencian un object ID inexistente, que aparecen como identidades desconocidas en `az role assignment list`.)
- **Objetos de Microsoft Entra ID** — registros de aplicaciones, service principals e identidades administradas asignadas por el usuario que vivían en *otro* resource group. Los objetos de Entra tienen alcance de tenant y quedan enteramente fuera del ciclo de vida del resource group de ARM.

Otros que vale la pena revisar: **asignaciones de policy, iniciativas y exenciones** a nivel de suscripción o management group; **diagnostic settings** sobre los activity logs a nivel de suscripción; **budgets y alertas de costo** a nivel de suscripción; **Key Vaults y storage accounts en soft-delete**, que se retienen (y mantienen reservados sus nombres globalmente únicos) durante el período de retención incluso después de que el grupo ya no está, y que deben purgarse explícitamente; y los **ítems de backup de un Recovery Services vault**, que bloquean directamente el borrado del grupo hasta que se detiene la protección del vault con eliminación de datos.

**A8.2** — **Azure Resource Manager calcula el orden.** ARM construye un grafo de dependencias a partir de las relaciones entre recursos que ya rastrea — una NIC referencia una subnet, una subnet pertenece a una VNet, una VM referencia NICs y discos — y borra las hojas antes que sus padres, paralelizando donde el grafo lo permite. El mismo motor de grafos que ordena la *creación* a partir de `dependsOn` y de las referencias implícitas ordena el *borrado* recorriéndolo en reversa.

Esto es **manejabilidad**, no disponibilidad, porque la disponibilidad tiene que ver con que un servicio siga siendo alcanzable durante un fallo, mientras que esto tiene que ver con el *esfuerzo operativo requerido para gestionar el ciclo de vida del sistema*. Concretamente: on-premises, dar de baja es un proyecto — alguien tiene que saber que el load balancer referencia la VIP, que la VIP está atada a la NIC, que la LUN de storage está enmascarada a este iniciador, y acertar el orden o dejar entradas huérfanas en tres sistemas. Ese conocimiento vive en la cabeza de las personas y en una página de wiki desactualizada. Acá la plataforma mantiene el grafo de dependencias como estado autoritativo y ejecuta el desmantelamiento correctamente con un comando y sin ninguna pericia de tu parte.

La misma propiedad es lo que hace barato *recrear* todo el entorno: como ARM conoce el grafo, una plantilla puede reconstruir el parque entero en el orden correcto. Desmantelamiento reproducible y construcción reproducible son la misma capacidad vista desde dos direcciones, y juntas son lo que hace practicables los entornos efímeros — un stack completo por pull request, destruido al mergear. Ese es el verdadero rédito de la manejabilidad: cambia qué flujos de trabajo son económicamente posibles, no solo cuánto tarda una tarea.

**A8.3** — **El borrado del resource group amerita un resource lock.** Es instantáneo en relación con el tiempo de reacción humano, totalmente irreversible, y se dispara con un solo comando fácil de ejecutar contra el `$RG` equivocado — el modo de fallo es un *error*, y el control para los errores es hacer que la acción sea imposible sin un segundo paso deliberado. `az lock create --lock-type CanNotDelete --resource-group $RG` hace que el borrado falle hasta que alguien quite explícitamente el lock, lo que fuerza un momento de intención consciente y, en un entorno auditado, deja registro de quién lo quitó y cuándo. Los locks son la herramienta correcta para operaciones de gran radio de explosión, baja frecuencia y sin vuelta atrás.

**El failover de GZRS amerita un runbook.** No es un error a evitar — es una *acción correcta tomada bajo presión*, durante un incidente, por alguien que puede estar cansado y trabajando fuera de su pericia habitual. Los riesgos no son "alguien podría hacerlo por accidente" sino "alguien lo va a hacer y se va a equivocar en los pasos alrededor": no registrar `lastSyncTime` antes de disparar, no saber que después la cuenta queda en LRS, olvidarse de actualizar cadenas de conexión y DNS, y no tener plan para restaurar la georredundancia después. Un lock acá sería activamente dañino, agregando fricción a una acción de emergencia que debe ocurrir rápido. Lo que hace falta es un procedimiento escrito y probado que cubra precondiciones, los comandos exactos, la ventana esperada de pérdida de datos, la reconfiguración downstream y los pasos de recuperación de la redundancia.

**Por qué los controles difieren:** la pregunta que distingue es *si la acción debería ocurrir alguna vez en operación normal*. Los locks previenen acciones que no deberían ocurrir — agregan fricción, y la fricción solo es aceptable donde la acción es genuinamente indeseable. Los runbooks guían acciones que **sí deben** ocurrir pero son raras, complejas y de consecuencias grandes — eliminan la incertidumbre sin agregar demora. Aplicar el control equivocado es un modo de fallo real en ambas direcciones: bloquear el failover retrasa la recuperación ante desastres, y escribir un runbook para el borrado de un resource group documenta un error en vez de prevenirlo. En la práctica, los entornos maduros usan ambos juntos sobre el mismo sistema para operaciones distintas — borrado bloqueado, failover con runbook.

</details>

---

## Fuentes

- [AZ-900 Study Guide — Microsoft Certified: Azure Fundamentals](https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900)
- [Describe the benefits of using cloud services (training module)](https://learn.microsoft.com/en-us/training/modules/describe-benefits-use-cloud-services/)
- [SLA for Online Services — Microsoft Product Terms](https://www.microsoft.com/licensing/docs/view/Service-Level-Agreements-SLA-for-Online-Services)
- [Azure availability zones overview](https://learn.microsoft.com/en-us/azure/reliability/availability-zones-overview)
- [Azure region pairs](https://learn.microsoft.com/en-us/azure/reliability/regions-paired)
- [Azure Storage redundancy](https://learn.microsoft.com/en-us/azure/storage/common/storage-redundancy)
- [Storage account failover](https://learn.microsoft.com/en-us/azure/storage/common/storage-disaster-recovery-guidance)
- [Overview of autoscale in Azure](https://learn.microsoft.com/en-us/azure/azure-monitor/autoscale/autoscale-overview)
- [Virtual Machine Scale Sets orchestration modes](https://learn.microsoft.com/en-us/azure/virtual-machine-scale-sets/virtual-machine-scale-sets-orchestration-modes)
- [Azure managed disk types and performance tiers](https://learn.microsoft.com/en-us/azure/virtual-machines/disks-types)
- [Azure Retail Prices REST API](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices)
- [Create and manage Azure budgets](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-acm-create-budgets)
- [Azure Policy overview](https://learn.microsoft.com/en-us/azure/governance/policy/overview)
- [Understand Azure Policy effects](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/effects)
- [Azure RBAC overview](https://learn.microsoft.com/en-us/azure/role-based-access-control/overview)
- [ARM template deployment what-if](https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/deploy-what-if)
- [Azure Resource Health overview](https://learn.microsoft.com/en-us/azure/service-health/resource-health-overview)
- [Azure Monitor activity log](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/activity-log)
- [Azure Well-Architected Framework](https://learn.microsoft.com/en-us/azure/well-architected/)
- [Lock resources to prevent unexpected changes](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/lock-resources)