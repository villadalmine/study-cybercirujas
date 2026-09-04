# Tema 3.2 — Definir la infraestructura global de AWS

## Ejercicios guiados — CLF-C02, Dominio 3 (Cloud Technology and Services), peso 4,25%

> **Cómo usar este documento.** Cada bloque es una secuencia de pasos numerados que ejecutás de verdad, seguida de preguntas de verificación. No leas las respuestas primero: las preguntas están diseñadas para poder responderse *solo* a partir de la salida que produjiste, porque el sentido entero de este tema es que la infraestructura global de AWS es un **conjunto de datos consultable y versionado**, no una lista para memorizar. La cantidad de Regions, de AZ y de PoP cambia cada trimestre; las APIs no.
>
> **Costo.** Cada comando de los ejercicios 0–8, 10 y 11 es una llamada de solo lectura a la API, un GET HTTPS público o una operación gratuita del control plane — $0,00. El ejercicio 9 crea una VPC y subnets, que no tienen cargo; de todos modos el paso de limpieza es obligatorio. Hay dos comandos que se muestran pero deliberadamente **no** se ejecutan porque son facturables (asignación de una Elastic IP, NAT Gateway); están marcados con `# DO NOT RUN`.
>
> **No es un objetivo.** Esto no es un curso de redes. Tocamos VPC únicamente donde es la consecuencia observable de una decisión de infraestructura global.

---

## Ejercicio 0 — Preparar y verificar las herramientas

Necesitás AWS CLI v2, `jq`, `curl`, `dig` y `awk`. Un principal de IAM con `ReadOnlyAccess` alcanza para todo excepto el ejercicio 9 (que necesita `ec2:CreateVpc`, `ec2:CreateSubnet`, `ec2:DeleteSubnet`, `ec2:DeleteVpc`) y el paso opcional de opt-in del ejercicio 3 (`ec2:ModifyAvailabilityZoneGroup`).

1. Confirmá la versión mayor de la CLI. La v1 pagina y formatea de otra manera, y varios de los comandos de abajo se comportan raro con ella.

```bash
aws --version
```

```
aws-cli/2.28.11 Python/3.13.4 Linux/6.14.0 exe/x86_64.fedora.42
```

2. Confirmá quién sos y, sobre todo, **en qué partición** viven tus credenciales. Leé el ARN, no el número de cuenta.

```bash
aws sts get-caller-identity --output json
```

```json
{
    "UserId": "AIDA2EXAMPLEIDHERE",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/clf-lab"
}
```

3. Anotá la Region que la CLI toma por defecto, y de dónde salió ese valor. La precedencia es: flag `--region` → `AWS_REGION` → `AWS_DEFAULT_REGION` → `region` en el perfil activo → metadatos de la instancia EC2/ECS. **No** hay un valor global por defecto; una Region sin definir es un error, no un repliegue hacia `us-east-1`.

```bash
aws configure list
```

```
      Name                    Value             Type    Location
      ----                    -----             ----    --------
   profile                 clf-lab            manual    --profile
access_key     ****************MPLE shared-credentials-file
secret_key     ****************MPLE shared-credentials-file
    region                us-east-1      config-file    ~/.aws/config
```

4. Fijá una Region para el resto del laboratorio para que los resultados sean reproducibles, y exportala.

```bash
export AWS_REGION=us-east-1
export LAB_REGION=us-east-1
```

**Comprobá tu comprensión**

- **Q0.1** — Tu ARN empieza con `arn:aws:`. ¿Cuáles son los otros dos valores públicamente disponibles de ese campo, y qué consecuencia operativa concreta se sigue de que un recurso esté en otro?
- **Q0.2** — Un compañero dice: "si no configurás una Region, la CLI usa N. Virginia y listo". ¿Bajo qué circunstancia única y específica esa afirmación es *efectivamente* cierta, y por qué sigue siendo el modelo mental equivocado?

---

## Ejercicio 1 — Enumerar las Regions, y separar "existe" de "habilitada"

Una **Region** es un área geográfica nombrada y físicamente separada que contiene un conjunto de Availability Zones. Es el límite de aislamiento de fallos más grueso que ofrece AWS, y el límite en el que tus datos se quedan quietos: AWS no replica datos de clientes fuera de una Region a menos que configures un servicio para que lo haga.

1. Pedile a EC2 las Regions que tu cuenta puede usar actualmente.

```bash
aws ec2 describe-regions --query 'length(Regions)'
```

```
17
```

2. Ahora pedí *todas* las Regions de tu partición, incluidas las que nunca encendiste.

```bash
aws ec2 describe-regions --all-regions \
  --query 'sort_by(Regions,&RegionName)[].[RegionName,OptInStatus]' \
  --output table
```

```
-------------------------------------------
|             DescribeRegions             |
+------------------+----------------------+
|  af-south-1      |  not-opted-in        |
|  ap-east-1       |  not-opted-in        |
|  ap-northeast-1  |  opt-in-not-required |
|  ap-northeast-2  |  opt-in-not-required |
|  ap-northeast-3  |  opt-in-not-required |
|  ap-south-1      |  opt-in-not-required |
|  ap-south-2      |  not-opted-in        |
|  ap-southeast-1  |  opt-in-not-required |
|  ap-southeast-2  |  opt-in-not-required |
|  ap-southeast-3  |  not-opted-in        |
|  ca-central-1    |  opt-in-not-required |
|  eu-central-1    |  opt-in-not-required |
|  eu-central-2    |  not-opted-in        |
|  eu-north-1      |  opt-in-not-required |
|  eu-south-1      |  not-opted-in        |
|  eu-west-1       |  opt-in-not-required |
|  eu-west-2       |  opt-in-not-required |
|  eu-west-3       |  opt-in-not-required |
|  il-central-1    |  not-opted-in        |
|  sa-east-1       |  opt-in-not-required |
|  us-east-1       |  opt-in-not-required |
|  us-east-2       |  opt-in-not-required |
|  us-west-1       |  opt-in-not-required |
|  us-west-2       |  opt-in-not-required |
+------------------+----------------------+
```

*(Tu lista va a ser más larga que este extracto y no va a coincidir exactamente con él. Esa es la lección.)*

3. Aislá la diferencia entre los dos números.

```bash
aws ec2 describe-regions --all-regions \
  --query "Regions[?OptInStatus=='not-opted-in'].RegionName" --output text | tr '\t' '\n'
```

4. Decodificá un código de Region. Es `<geografía>-<punto-cardinal-o-calificador>-<ordinal>`, donde el ordinal es el **orden de lanzamiento dentro de esa geografía**, no un ranking, ni un tamaño, ni una preferencia.

```bash
aws ssm get-parameter --region us-east-1 \
  --name /aws/service/global-infrastructure/regions/ap-northeast-3/longName \
  --query 'Parameter.Value' --output text
```

```
Asia Pacific (Osaka)
```

5. Hacé la misma pregunta a través de la Account Management API, que es el camino consciente de la organización y el que puede *cambiar* la respuesta.

```bash
aws account list-regions --region-opt-status-contains ENABLED ENABLED_BY_DEFAULT \
  --query 'length(Regions)'
```

```
17
```

```bash
# Enabling a Region is free and takes minutes to hours. It is also a governance
# decision — an enabled Region is a Region in which somebody can create resources.
# aws account enable-region --region-name ap-east-1
```

**Comprobá tu comprensión**

- **Q1.1** — `describe-regions` devolvió menos Regions que `describe-regions --all-regions`. Explicá la diferencia en términos de lo que AWS construyó frente a lo que tu cuenta consintió, y nombrá las dos Regions que son permanentemente `opt-in-not-required` por razones estructurales.
- **Q1.2** — ¿Qué Regions eran `opt-in-not-required`, y qué tienen en común históricamente? ¿Por qué AWS cambió el valor por defecto para las Regions lanzadas después de ese punto?
- **Q1.3** — `ap-northeast-3` es Osaka y `ap-northeast-1` es Tokio. ¿El ordinal `1` te dice algo sobre capacidad relativa, cantidad de AZ o cobertura de servicios? ¿Qué *sí* te dice?
- **Q1.4** — El equipo de seguridad de tu organización quiere garantizar que ningún ingeniero pueda lanzar nada en Regions fuera de la UE. Nombrá dos mecanismos — uno de este ejercicio, otro de AWS Organizations — y explicá cuál es el control real y cuál es apenas una comodidad.
- **Q1.5** — Ninguno de los comandos de arriba va a devolver jamás `cn-north-1`. ¿Por qué no, y qué haría falta para que lo vieras?

---

## Ejercicio 2 — Availability Zones: el nombre miente, el ID no

Una **Availability Zone** es uno o más centros de datos discretos con energía, redes y conectividad redundantes, en instalaciones separadas, lo bastante lejos como para sobrevivir a un fallo localizado (AWS declara que todas las AZ de una Region están dentro de 100 km / 60 millas entre sí) y lo bastante cerca como para que la latencia entre AZ se mantenga en el rango de milisegundos de un solo dígito — que es lo que hace práctica la replicación **síncrona** entre AZ e impráctica la replicación síncrona entre Regions.

1. Listá las AZ de tu Region con su nombre y su ID.

```bash
aws ec2 describe-availability-zones --region "$LAB_REGION" \
  --query 'AvailabilityZones[].[ZoneName,ZoneId,ZoneType,State,NetworkBorderGroup]' \
  --output table
```

```
------------------------------------------------------------------------------
|                         DescribeAvailabilityZones                          |
+-------------+------------+--------------------+-----------+----------------+
|  us-east-1a |  use1-az2  |  availability-zone |  available|  us-east-1     |
|  us-east-1b |  use1-az4  |  availability-zone |  available|  us-east-1     |
|  us-east-1c |  use1-az6  |  availability-zone |  available|  us-east-1     |
|  us-east-1d |  use1-az1  |  availability-zone |  available|  us-east-1     |
|  us-east-1e |  use1-az3  |  availability-zone |  available|  us-east-1     |
|  us-east-1f |  use1-az5  |  availability-zone |  available|  us-east-1     |
+-------------+------------+--------------------+-----------+----------------+
```

2. Mirá bien el mapeo. En la salida de arriba, `us-east-1a` es **`use1-az2`**, no `use1-az1`. Ejecutá el mismo comando con las credenciales de otra cuenta de AWS si tenés una; el mapeo `ZoneName` → `ZoneId` va a ser distinto.

```bash
aws ec2 describe-availability-zones --region "$LAB_REGION" \
  --query 'AvailabilityZones[].{name:ZoneName,id:ZoneId}' --output json | jq -c '.[]'
```

```
{"name":"us-east-1a","id":"use1-az2"}
{"name":"us-east-1b","id":"use1-az4"}
{"name":"us-east-1c","id":"use1-az6"}
```

3. Compará la cantidad de AZ entre varias Regions. No des por sentado que son tres.

```bash
for r in us-east-1 us-west-1 sa-east-1 eu-west-1 eu-central-1 ap-southeast-1; do
  n=$(aws ec2 describe-availability-zones --region "$r" \
        --filters Name=zone-type,Values=availability-zone \
        --query 'length(AvailabilityZones)' --output text)
  printf '%-16s %s AZs\n' "$r" "$n"
done
```

```
us-east-1        6 AZs
us-west-1        2 AZs
sa-east-1        3 AZs
eu-west-1        3 AZs
eu-central-1     3 AZs
ap-southeast-1   3 AZs
```

4. Verificá si alguna AZ está reportando un problema en este momento. `Messages` normalmente está vacío; se llena durante una degradación de zona.

```bash
aws ec2 describe-availability-zones --region "$LAB_REGION" \
  --query 'AvailabilityZones[?length(Messages) > `0`]' --output json
```

```json
[]
```

**Comprobá tu comprensión**

- **Q2.1** — La cuenta A lanza en `us-east-1a` y la cuenta B lanza en `us-east-1a`. ¿Están en la misma zona física? Justificá con el campo que lo zanja.
- **Q2.2** — ¿Por qué AWS aleatorizó el mapeo nombre→ID por cuenta, para empezar? ¿Qué comportamiento estaba corrigiendo?
- **Q2.3** — Estás compartiendo subnets entre cuentas con AWS RAM, y necesitás la subnet compartida en la misma zona que la carga de trabajo existente del consumidor. ¿Qué identificador va en el ticket, y cuál es inútil?
- **Q2.4** — `us-west-1` devolvió 2 AZ. ¿Eso significa que la Region tiene físicamente dos conjuntos de centros de datos? ¿Cuál es la manera segura de formular lo que realmente aprendiste?
- **Q2.5** — Un despliegue de RDS Multi-AZ sobrevive a la pérdida de una AZ. Una única instancia EC2 en una AZ no. ¿Cuál mitad de eso es responsabilidad de AWS bajo el modelo de responsabilidad compartida, y cuál es tuya?
- **Q2.6** — ¿Por qué la replicación síncrona entre AZ es práctica de ingeniería normal mientras que la replicación síncrona entre Regions en general no lo es? Respondé en términos de un número que puedas calcular a partir de la geografía.

---

## Ejercicio 3 — La taxonomía de zonas: AZ, Local Zone, Wavelength Zone

No toda "zona" es una AZ. `zone-type` es el discriminador, y el campo `ParentZoneName` es lo que te dice que la cosa es una *extensión de* una Region y no una Region propia.

1. Enumerá cada tipo de zona visible para vos en una Region que tenga los tres.

```bash
aws ec2 describe-availability-zones --region us-west-2 --all-availability-zones \
  --query 'AvailabilityZones[].[ZoneName,ZoneId,ZoneType,GroupName,ParentZoneName,OptInStatus]' \
  --output table
```

```
--------------------------------------------------------------------------------------------------------
|                                     DescribeAvailabilityZones                                        |
+----------------------+-----------------+------------------+--------------------+-----------+---------+
|  us-west-2a          |  usw2-az1       |  availability-zone|  us-west-2        |  None     | opt-in-not-required |
|  us-west-2b          |  usw2-az2       |  availability-zone|  us-west-2        |  None     | opt-in-not-required |
|  us-west-2c          |  usw2-az3       |  availability-zone|  us-west-2        |  None     | opt-in-not-required |
|  us-west-2d          |  usw2-az4       |  availability-zone|  us-west-2        |  None     | opt-in-not-required |
|  us-west-2-lax-1a    |  usw2-lax1-az1  |  local-zone       |  us-west-2-lax-1  |  us-west-2| not-opted-in        |
|  us-west-2-lax-1b    |  usw2-lax1-az2  |  local-zone       |  us-west-2-lax-1  |  us-west-2| not-opted-in        |
|  us-west-2-phx-1a    |  usw2-phx1-az1  |  local-zone       |  us-west-2-phx-1  |  us-west-2| not-opted-in        |
+----------------------+-----------------+------------------+--------------------+-----------+---------+
```

2. Contá las Local Zones sin el ruido.

```bash
aws ec2 describe-availability-zones --all-availability-zones --region us-west-2 \
  --filters Name=zone-type,Values=local-zone \
  --query 'length(AvailabilityZones)'
```

3. Sondeá si hay Wavelength Zones. Una lista vacía es un resultado válido e informativo — la cobertura de Wavelength es angosta y cambia con los acuerdos con las operadoras.

```bash
for r in us-east-1 us-west-2 eu-west-2 ap-northeast-1; do
  n=$(aws ec2 describe-availability-zones --region "$r" --all-availability-zones \
        --filters Name=zone-type,Values=wavelength-zone \
        --query 'length(AvailabilityZones)' --output text)
  printf '%-16s %s wavelength zones\n' "$r" "$n"
done
```

4. *(Opcional, gratis.)* Hacé opt-in a un grupo de Local Zone. Habilitar el grupo no cuesta nada; solo se facturan los recursos que después lances ahí. Hacelo solo si vas a ejecutar la limpieza del paso 5.

```bash
aws ec2 modify-availability-zone-group \
  --region us-west-2 --group-name us-west-2-lax-1 --opt-in-status opted-in
```

```json
{ "Return": true }
```

```bash
aws ec2 describe-availability-zones --region us-west-2 \
  --filters Name=zone-name,Values=us-west-2-lax-1a \
  --query 'AvailabilityZones[].[ZoneName,OptInStatus,NetworkBorderGroup]' --output text
```

```
us-west-2-lax-1a	opted-in	us-west-2-lax-1
```

5. **Limpieza.** Salí del opt-in.

```bash
aws ec2 modify-availability-zone-group \
  --region us-west-2 --group-name us-west-2-lax-1 --opt-in-status not-opted-in
```

6. Observá el cuarto modelo de extensión, que no tiene entrada de zona alguna hasta que sos dueño del hardware:

```bash
aws outposts list-outposts --region "$LAB_REGION" --query 'Outposts' --output json
```

```json
[]
```

**Comprobá tu comprensión**

- **Q3.1** — Una Local Zone tiene `ParentZoneName` y una AZ no. ¿Qué te compra realmente ese campo desde el punto de vista arquitectónico — qué vive en la Region padre cuando ejecutás una carga de trabajo en `us-west-2-lax-1a`?
- **Q3.2** — Ordená AZ, Local Zone, Wavelength Zone y Outpost por "qué tan cerca del usuario final" y nombrá la única clase de carga de trabajo que justifica cada uno.
- **Q3.3** — Tanto `NetworkBorderGroup` como `GroupName` dicen `us-west-2-lax-1` para las zonas de LAX, mientras que para una AZ normal ambos dicen `us-west-2`. ¿Qué controla `NetworkBorderGroup`, y por qué no podés mover una Elastic IP entre border groups?
- **Q3.4** — Un Outpost está en tu propio edificio. ¿Cuál de estos sigue ejecutándose en la Region padre: el data plane de EC2, el control plane de EC2, los volúmenes EBS conectados a instancias del Outpost, las métricas de CloudWatch? ¿Qué le pasa a cada uno cuando tu edificio pierde el enlace con AWS?
- **Q3.5** — Un cliente dice "vamos a usar una Local Zone para recuperación ante desastres, porque es una ubicación separada de la Region". Refutalo en una sola oración usando el concepto de límite de aislamiento de fallos.

---

## Ejercicio 4 — El mapa autoritativo y legible por máquina

AWS publica el catálogo completo de infraestructura global como **parámetros públicos de Systems Manager**. Son los mismos datos que hay detrás del mapa de marketing, están versionados, y leerlos es gratis. Así es como respondés "¿está el servicio X en la Region Y?" en un script en lugar de en una pestaña del navegador.

1. Obtené la versión del conjunto de datos. Anotala; es la manera honesta de fechar cualquier afirmación que hagas sobre cantidad de Regions.

```bash
aws ssm get-parameter --region us-east-1 \
  --name /aws/service/global-infrastructure/version \
  --query 'Parameter.Value' --output text
```

```
1.0.0-20260901
```

2. Listá todas las Regions que AWS publica, con independencia del estado de opt-in de tu cuenta.

```bash
aws ssm get-parameters-by-path --region us-east-1 \
  --path /aws/service/global-infrastructure/regions \
  --query 'Parameters[].Value' --output text | tr '\t' '\n' | sort | tee /tmp/all-regions.txt | wc -l
```

3. Comparalas contra lo que tu cuenta puede usar. Esta es la auditoría del "qué no estoy usando, y por qué".

```bash
aws ec2 describe-regions --query 'Regions[].RegionName' --output text \
  | tr '\t' '\n' | sort > /tmp/enabled-regions.txt
comm -23 /tmp/all-regions.txt /tmp/enabled-regions.txt
```

4. Traé los atributos de una sola Region. Estos cuatro son las entradas crudas de una decisión de residencia de datos.

```bash
for attr in longName partition domain geolocationCountry geolocationRegion; do
  v=$(aws ssm get-parameter --region us-east-1 \
       --name "/aws/service/global-infrastructure/regions/sa-east-1/$attr" \
       --query 'Parameter.Value' --output text 2>/dev/null)
  printf '%-20s %s\n' "$attr" "$v"
done
```

```
longName             South America (Sao Paulo)
partition            aws
domain               amazonaws.com
geolocationCountry   BR
geolocationRegion    SA
```

5. Respondé "qué Regions ofrecen este servicio" sin adivinar.

```bash
aws ssm get-parameters-by-path --region us-east-1 \
  --path /aws/service/global-infrastructure/services/bedrock/regions \
  --query 'Parameters[].Value' --output text | tr '\t' '\n' | sort
```

6. Y la inversa — "qué ofrece esta Region".

```bash
aws ssm get-parameters-by-path --region us-east-1 \
  --path /aws/service/global-infrastructure/regions/sa-east-1/services \
  --query 'length(Parameters)'
```

```
243
```

```bash
aws ssm get-parameters-by-path --region us-east-1 \
  --path /aws/service/global-infrastructure/regions/us-east-1/services \
  --query 'length(Parameters)'
```

```
298
```

7. Calculá la brecha para una pregunta real de migración: ¿qué hay en `us-east-1` que *no* está en `sa-east-1`?

```bash
svc() { aws ssm get-parameters-by-path --region us-east-1 \
  --path "/aws/service/global-infrastructure/regions/$1/services" \
  --query 'Parameters[].Value' --output text | tr '\t' '\n' | sort; }
comm -23 <(svc us-east-1) <(svc sa-east-1) | head -20
```

**Comprobá tu comprensión**

- **Q4.1** — El paso 6 mostró una diferencia significativa en la cantidad de servicios entre dos Regions. Enunciá la regla general de cómo AWS despliega un servicio nuevo a lo largo de las Regions, y nombrá la Region que casi siempre es la primera.
- **Q4.2** — Diseñaste una arquitectura en `us-east-1` usando seis servicios y ahora tenés que redesplegarla en `il-central-1` por un requisito de residencia. Escribí la verificación exacta de una línea que ejecutarías *antes* de estimar el trabajo.
- **Q4.3** — `geolocationCountry` para `sa-east-1` es `BR`. ¿Alcanza eso para satisfacer una obligación brasileña de residencia de datos? ¿Qué más tiene que ser cierto, y qué recursos de AWS seguirían estando fuera de Brasil?
- **Q4.4** — ¿Por qué el parámetro `version` importa más que la cantidad de Regions que derivaste de él?

---

## Ejercicio 5 — Medir la física: elegir Region es una decisión de latencia

La luz en fibra monomodo viaja a aproximadamente ⅔ c ≈ 200 km/ms. Un viaje de ida y vuelta sobre una fibra perfectamente recta cuesta entonces alrededor de **1 ms por cada 100 km de separación**. Los caminos reales son entre 1,3 y 2 veces más largos que la distancia de círculo máximo y agregan retardo de conmutación y encolado. Ninguna cantidad de ingeniería de AWS deroga esto, y por eso "poné la Region cerca de los usuarios" es una restricción arquitectónica y no una preferencia.

1. Medí el handshake TCP — un viaje de ida y vuelta — contra varios endpoints regionales de la API. `time_connect - time_namelookup` es tu RTT; el TLS se cobra aparte para que puedas verlo.

```bash
for r in us-east-1 us-west-2 eu-west-1 eu-central-1 sa-east-1 ap-southeast-1 ap-northeast-1; do
  best=99
  for i in 1 2 3; do
    read -r dns conn tls <<<"$(curl -s -o /dev/null --connect-timeout 5 \
      -w '%{time_namelookup} %{time_connect} %{time_appconnect}' \
      "https://dynamodb.${r}.amazonaws.com/")"
    best=$(awk -v a="$best" -v c="$conn" -v d="$dns" 'BEGIN{r=(c-d)*1000; print (r<a && r>0)?r:a}')
  done
  printf '%-16s rtt≈%6.1f ms\n' "$r" "$best"
done
```

```
us-east-1        rtt≈ 122.4 ms
us-west-2        rtt≈ 176.9 ms
eu-west-1        rtt≈ 205.1 ms
eu-central-1     rtt≈ 221.7 ms
sa-east-1        rtt≈  32.8 ms
ap-southeast-1   rtt≈ 331.5 ms
ap-northeast-1   rtt≈ 289.2 ms
```

*(Medido desde Buenos Aires. El tuyo va a diferir; lo que importa es la forma.)*

2. Convertí tu mejor resultado de vuelta a una distancia y verificalo contra un mapa.

```bash
awk 'BEGIN{ rtt=32.8; printf "implied one-way path length ≈ %.0f km\n", (rtt/2)*200 }'
```

```
implied one-way path length ≈ 3280 km
```

3. Ahora medí lo que paga una aplicación conversadora. Una secuencia de petición de 12 viajes de ida y vuelta (TCP + TLS + auth + unas cuantas consultas dependientes) contra la *segunda* mejor Region:

```bash
awk 'BEGIN{ near=32.8; far=122.4; n=12;
  printf "near: %6.0f ms   far: %6.0f ms   penalty: %.1fx\n", near*n, far*n, far/near }'
```

```
near:    394 ms   far:   1469 ms   penalty: 3.7x
```

4. Confirmá que el endpoint que golpeaste es regional y no anycast, resolviéndolo y verificando que la IP se anuncia desde esa Region.

```bash
dig +short dynamodb.sa-east-1.amazonaws.com
```

```
52.94.5.44
```

**Comprobá tu comprensión**

- **Q5.1** — Tu RTT medido a la Region más cercana implica una longitud de camino notoriamente mayor que la distancia en línea recta. Dá dos razones por las que eso es esperable y *no* señal de un problema.
- **Q5.2** — El paso 3 multiplicó el RTT por 12. Explicá por qué alejar una Region 4.000 km más puede degradar la carga de una página muchísimo más que el delta crudo de RTT, y nombrá el cambio de diseño que lo mitiga sin mover la Region.
- **Q5.3** — ¿Cuáles de estos mejoran al elegir una Region más cercana y cuáles no: la latencia del primer byte de una llamada dinámica a la API; el tiempo de descarga de un video estático de 2 GB; la latencia de escritura en base de datos; el costo del handshake TLS?
- **Q5.4** — Tenés usuarios en São Paulo, Frankfurt y Singapur y una única base de datos relacional que debe permanecer consistente. ¿Qué te obliga a decidir la física de este ejercicio, y cuáles son las dos respuestas legítimas?

---

## Ejercicio 6 — La red de borde: PoP, regional edge caches y el espacio de direcciones

Las edge locations son el tercer nivel de la infraestructura, y hay muchísimas más que Regions. Sirven a CloudFront, Route 53, AWS Global Accelerator, AWS WAF y AWS Shield. **No** son un lugar donde desplegás una aplicación; son un lugar donde AWS termina conexiones en tu nombre.

1. Descargá la propia guía del examen — se sirve a través de CloudFront — y leé las cabeceras de borde.

```bash
curl -sI https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf \
  | grep -Ei 'x-amz-cf-pop|x-cache|via|age|x-amz-cf-id'
```

```
x-cache: Hit from cloudfront
via: 1.1 6f1c8a4e2b9d3f7a05c1e2d4b6a8c0f3.cloudfront.net (CloudFront)
x-amz-cf-pop: GRU1-C1
x-amz-cf-id: kQ8n2Z-vX1pR4tYbLmA0cJdWfHsE3iOu9Nx7gVqTlPzKrBySd6MwCg==
age: 8412
```

2. Decodificá `x-amz-cf-pop`. Los primeros tres caracteres son el **código IATA del aeropuerto** del área metropolitana; los dígitos distinguen varios PoP en esa metrópolis; el sufijo marca la instalación.

```bash
curl -sI https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf \
  | awk -F': ' '/x-amz-cf-pop/{print "IATA:", substr($2,1,3)}'
```

```
IATA: GRU
```

3. Demostrá que el borde se elige por ubicación *de red*, no por la Region del contenido, resolviendo un nombre de host de CloudFront a través de dos resolvers geográficamente distintos.

```bash
dig +short d1.awsstatic.com @1.1.1.1 | tail -2
dig +short d1.awsstatic.com @8.8.8.8 | tail -2
```

4. Descargá el archivo autoritativo de rangos de IP — sin credenciales, sin costo — y contá el espacio de direcciones por servicio.

```bash
curl -s https://ip-ranges.amazonaws.com/ip-ranges.json -o /tmp/ip-ranges.json
jq -r '.syncToken, .createDate' /tmp/ip-ranges.json
jq -r '[.prefixes[].service] | group_by(.) | map({s:.[0], n:length}) | sort_by(-.n)[:10][] | "\(.n)\t\(.s)"' /tmp/ip-ranges.json
```

```
1757001123
2026-09-04-14-32-03
2318	AMAZON
1204	EC2
 187	S3
  94	CLOUDFRONT
  61	CLOUDFRONT_ORIGIN_FACING
  38	ROUTE53_HEALTHCHECKS
  22	GLOBALACCELERATOR
  ...
```

5. Mirá el campo `region` de los dos servicios globales. Acá es donde "servicio global" deja de ser lenguaje de marketing.

```bash
jq -r '.prefixes[] | select(.service=="CLOUDFRONT" or .service=="GLOBALACCELERATOR")
       | "\(.service)\t\(.region)\t\(.network_border_group)"' /tmp/ip-ranges.json | sort -u | head -5
```

```
CLOUDFRONT	GLOBAL	GLOBAL
GLOBALACCELERATOR	GLOBAL	GLOBAL
```

6. Ahora encontrá los prefijos cuyo `network_border_group` es una Local Zone — la consecuencia, en el espacio de direcciones, del ejercicio 3.

```bash
jq -r '.prefixes[] | select(.network_border_group != .region)
       | "\(.region)\t\(.network_border_group)"' /tmp/ip-ranges.json | sort -u | head -8
```

```
us-east-1	us-east-1-atl-1
us-east-1	us-east-1-mia-1
us-west-2	us-west-2-den-1
us-west-2	us-west-2-lax-1
us-west-2	us-west-2-phx-1
```

7. En lugar de parsear ese archivo a mano hacia security groups, usá las listas de prefijos gestionadas por AWS — la forma mantenida y referenciable de los mismos datos.

```bash
aws ec2 describe-managed-prefix-lists --region "$LAB_REGION" \
  --filters Name=owner-id,Values=AWS \
  --query 'PrefixLists[].[PrefixListName,PrefixListId,AddressFamily]' --output table
```

```
------------------------------------------------------------------------------------
|                          DescribeManagedPrefixLists                              |
+---------------------------------------------------+----------------+-------------+
|  com.amazonaws.global.cloudfront.origin-facing     |  pl-3b927c52   |  IPv4       |
|  com.amazonaws.global.groundstation                |  pl-34a6465d   |  IPv4       |
|  com.amazonaws.us-east-1.dynamodb                  |  pl-02cd2c6b   |  IPv4       |
|  com.amazonaws.us-east-1.s3                        |  pl-63a5400a   |  IPv4       |
|  com.amazonaws.us-east-1.vpc-lattice               |  pl-0e1a2b3c   |  IPv4       |
+---------------------------------------------------+----------------+-------------+
```

```bash
# DO NOT RUN — allocating a public IPv4 address is billed hourly whether or not it is attached.
# aws ec2 allocate-address --network-border-group us-west-2-lax-1
```

**Comprobá tu comprensión**

- **Q6.1** — Tu `x-amz-cf-pop` mostró una metrópolis cercana a vos, pero el archivo en sí está guardado en un bucket de S3 en una Region de EE. UU. Describí el camino completo que hicieron los bytes ante un **miss** de caché, nombrando los tres niveles de infraestructura involucrados.
- **Q6.2** — `x-cache` decía `Hit from cloudfront`. ¿Qué nivel lo sirvió, y qué nivel habría consultado un `Miss` *antes* de llegar al origen? ¿Cómo se llama ese nivel intermedio y qué problema resuelve?
- **Q6.3** — Tanto CloudFront como Global Accelerator ponen tu tráfico en la backbone de AWS en el borde más cercano. Dá las dos diferencias decisivas que hacen que uno esté mal para un servidor de juego UDP y el otro esté mal para un sitio web estático.
- **Q6.4** — ¿Por qué `com.amazonaws.global.cloudfront.origin-facing` es un conjunto *más chico* que `CLOUDFRONT`, y cuál de los dos corresponde en el security group de tu origen?
- **Q6.5** — Las edge locations son muchísimo más numerosas que las Regions. Explicá en una oración por qué AWS puede construir cientos de las primeras y solo decenas de las segundas.
- **Q6.6** — Un colega propone "desplegar la aplicación en edge locations para reducir latencia". Corregí la afirmación con precisión: ¿qué *puede* ejecutarse en el borde y qué no?

---

## Ejercicio 7 — Global frente a regional: endpoints, ARNs y la trampa del namespace de S3

"Servicio global" significa que el **control plane** tiene un único namespace global. No significa que el servicio no tenga casa. Casi todo servicio global está anclado en una Region, y ese anclaje aparece en tus post-mortems de incidentes.

1. Contrastá un endpoint global con uno regional de la misma familia de servicios.

```bash
dig +short iam.amazonaws.com
dig +short sts.amazonaws.com
dig +short sts.sa-east-1.amazonaws.com
```

2. Confirmá desde dónde se anuncian las direcciones del endpoint de IAM, usando el archivo del ejercicio 6.

```bash
IAM_IP=$(dig +short iam.amazonaws.com | head -1)
python3 - "$IAM_IP" <<'PY'
import ipaddress, json, sys
ip = ipaddress.ip_address(sys.argv[1])
for p in json.load(open('/tmp/ip-ranges.json'))['prefixes']:
    if ip in ipaddress.ip_network(p['ip_prefix']):
        print(p['ip_prefix'], p['region'], p['service'])
PY
```

```
52.46.128.0/19 us-east-1 AMAZON
```

3. Notá que una llamada a un servicio global igual requiere una Region sobre el cable, y que la firma de la CLI lo refleja.

```bash
aws iam list-account-aliases --region sa-east-1 --debug 2>&1 \
  | grep -m1 -o 'AWS4-HMAC-SHA256 Credential=[^,]*'
```

```
AWS4-HMAC-SHA256 Credential=AKIA.../20260904/us-east-1/iam/aws4_request
```

4. Leé los ARN como datos estructurados. Que los campos `region` y `account` estén vacíos es información.

```bash
cat <<'EOF' | column -t -s'|'
arn:aws:ec2:us-east-1:123456789012:instance/i-0abc123|regional + account-scoped
arn:aws:iam::123456789012:role/AppRole|global, account-scoped
arn:aws:s3:::my-bucket|global namespace, no account in ARN
arn:aws:s3:us-east-1:123456789012:accesspoint/ap1|regional S3 construct
arn:aws:cloudfront::123456789012:distribution/E2QEXAMPLE|global service, account-scoped
arn:aws-cn:s3:::my-bucket|different partition entirely
EOF
```

5. Demostrá la personalidad dividida de S3: el **nombre** es global, los **datos** son regionales. Elegí un nombre de bucket único.

```bash
B="clf32-lab-$(aws sts get-caller-identity --query Account --output text)-$$"
aws s3api create-bucket --bucket "$B" --region eu-west-1 \
  --create-bucket-configuration LocationConstraint=eu-west-1
aws s3api get-bucket-location --bucket "$B" --query LocationConstraint --output text
```

```
eu-west-1
```

6. Ahora direccioná ese bucket a través del endpoint regional *equivocado* y leé el error con atención.

```bash
aws s3api head-bucket --bucket "$B" --region us-east-1 2>&1 | head -3
```

```
An error occurred (301) when calling the HeadBucket operation: Moved Permanently
```

7. Creá un bucket en `us-east-1` y observá la rareza heredada en el mismo campo.

```bash
B2="clf32-lab2-$(aws sts get-caller-identity --query Account --output text)-$$"
aws s3api create-bucket --bucket "$B2" --region us-east-1
aws s3api get-bucket-location --bucket "$B2" --output json
```

```json
{ "LocationConstraint": null }
```

8. **Limpieza.**

```bash
aws s3api delete-bucket --bucket "$B" --region eu-west-1
aws s3api delete-bucket --bucket "$B2" --region us-east-1
```

**Comprobá tu comprensión**

- **Q7.1** — `LocationConstraint` volvió `null` para el bucket de `us-east-1`. ¿Es entonces el bucket "global"? Explicá la razón real del null.
- **Q7.2** — El paso 3 mostró una llamada a IAM hecha con `--region sa-east-1` firmada para `us-east-1`. ¿Qué predice esto sobre el blast radius de un evento del control plane de `us-east-1` en las *escrituras* de IAM en todo el mundo? ¿Y en las *decisiones de autorización* de IAM en todo el mundo?
- **Q7.3** — AWS recomienda endpoints regionales de STS por sobre el global. Dá las dos razones — una sobre latencia, otra sobre aislamiento de fallos.
- **Q7.4** — Clasificá cada uno como global o regional, y enunciá el límite que lo hace así: hosted zones de Route 53, endpoints de Route 53 Resolver, distribuciones de CloudFront, nombres de bucket de S3, objetos de S3, usuarios de IAM, key pairs de EC2, certificados de ACM.
- **Q7.5** — ¿Por qué un certificado de ACM usado por una distribución de CloudFront debe solicitarse específicamente en `us-east-1`, y qué te dice eso sobre dónde vive el control plane de CloudFront?
- **Q7.6** — Dos clientes de AWS no pueden ser ambos dueños del nombre de bucket `logs`. Dos clientes de AWS *sí* pueden ser ambos dueños del tag de nombre de instancia EC2 `web-01`. Explicá la diferencia de namespace en términos de qué es direccionable por URL.

---

## Ejercicio 8 — La capacidad y el hardware son por AZ, no por Region

"La Region tiene el tipo de instancia X" es una afirmación que falla en producción. Las familias de instancias se despliegan por AZ, y un error `InsufficientInstanceCapacity` a las 09:00 de un lunes es un evento a nivel de AZ.

1. Averiguá qué Regions ofrecen siquiera un tipo de instancia dado.

```bash
for r in us-east-1 us-west-2 sa-east-1 eu-central-1 ap-south-1; do
  n=$(aws ec2 describe-instance-type-offerings --region "$r" --location-type region \
        --filters Name=instance-type,Values=c7g.large \
        --query 'length(InstanceTypeOfferings)' --output text)
  printf '%-16s c7g.large: %s\n' "$r" "$([ "$n" = 0 ] && echo NO || echo yes)"
done
```

2. Profundizá en una sola Region y mirá qué **AZ ID** lo ofrecen realmente.

```bash
aws ec2 describe-instance-type-offerings --region us-east-1 \
  --location-type availability-zone-id \
  --filters Name=instance-type,Values=c7g.large \
  --query 'sort_by(InstanceTypeOfferings,&Location)[].Location' --output text
```

```
use1-az1	use1-az2	use1-az4	use1-az6
```

3. Compará contra un tipo de uso común para ver que la brecha es específica del tipo, no de la zona.

```bash
aws ec2 describe-instance-type-offerings --region us-east-1 \
  --location-type availability-zone-id \
  --filters Name=instance-type,Values=m5.large \
  --query 'length(InstanceTypeOfferings)'
```

4. Calculá la diferencia de conjuntos para un tipo acelerado y escaso — la consulta exacta que ejecutás antes de prometerle una Region a un equipo de ML.

```bash
aws ec2 describe-instance-type-offerings --region us-east-1 \
  --location-type availability-zone-id \
  --filters Name=instance-type,Values=p5.48xlarge \
  --query 'InstanceTypeOfferings[].Location' --output text | tr '\t' '\n'
```

5. Contá cuántos tipos de instancia distintos existen en dos Regions.

```bash
for r in us-east-1 sa-east-1; do
  n=$(aws ec2 describe-instance-type-offerings --region "$r" --location-type region \
        --query 'length(InstanceTypeOfferings)' --output text)
  printf '%-16s %s instance types\n' "$r" "$n"
done
```

```
us-east-1        831 instance types
sa-east-1        412 instance types
```

**Comprobá tu comprensión**

- **Q8.1** — El paso 2 devolvió un subconjunto de las AZ de la Region. ¿Qué hace un Auto Scaling group que abarca *todas* las AZ y solicita únicamente `c7g.large` cuando intenta escalar hacia una AZ que no lo ofrece?
- **Q8.2** — ¿Por qué `--location-type availability-zone-id` es el flag correcto acá y no `availability-zone`, dado el ejercicio 2?
- **Q8.3** — Ofrecido ≠ disponible. ¿Qué fallo *no* predice esta API, y qué dos funcionalidades de AWS existen específicamente para garantizar esa otra cosa?
- **Q8.4** — `sa-east-1` tiene aproximadamente la mitad de los tipos de instancia de `us-east-1`. Conectá esto con tu respuesta a Q4.1 y enunciá el principio general en una sola oración.

---

## Ejercicio 9 — Construir una huella de tres AZ anclada a AZ IDs

Acá es donde la teoría se vuelve un artefacto. Las VPC y las subnets son gratis; las vas a borrar.

1. Creá la VPC.

```bash
VPC_ID=$(aws ec2 create-vpc --region "$LAB_REGION" --cidr-block 10.42.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=clf32-lab}]' \
  --query 'Vpc.VpcId' --output text)
echo "$VPC_ID"
```

```
vpc-0ab12cd34ef567890
```

2. Tomá los primeros tres **IDs** de AZ, ordenados de forma determinista, y creá una subnet por zona. Fijate en `--availability-zone-id`, no `--availability-zone`.

```bash
i=0
for ZID in $(aws ec2 describe-availability-zones --region "$LAB_REGION" \
      --filters Name=zone-type,Values=availability-zone Name=state,Values=available \
      --query 'AvailabilityZones[].ZoneId' --output text | tr '\t' '\n' | sort | head -3); do
  i=$((i+1))
  SID=$(aws ec2 create-subnet --region "$LAB_REGION" --vpc-id "$VPC_ID" \
        --cidr-block "10.42.$i.0/24" --availability-zone-id "$ZID" \
        --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=clf32-$ZID}]" \
        --query 'Subnet.SubnetId' --output text)
  printf '%-12s -> %s (10.42.%s.0/24)\n' "$ZID" "$SID" "$i"
done
```

```
use1-az1     -> subnet-0f1e2d3c4b5a69780 (10.42.1.0/24)
use1-az2     -> subnet-0a9b8c7d6e5f43210 (10.42.2.0/24)
use1-az3     -> subnet-01234abcd5678ef90 (10.42.3.0/24)
```

3. Verificá, mostrando ambos identificadores lado a lado. Esta tabla es lo que pegás en una revisión de diseño.

```bash
aws ec2 describe-subnets --region "$LAB_REGION" \
  --filters Name=vpc-id,Values="$VPC_ID" \
  --query 'sort_by(Subnets,&AvailabilityZoneId)[].[SubnetId,AvailabilityZone,AvailabilityZoneId,CidrBlock,AvailableIpAddressCount]' \
  --output table
```

```
--------------------------------------------------------------------------------------------------
|                                        DescribeSubnets                                         |
+--------------------------+--------------+------------+----------------+-----------------------+
|  subnet-0f1e2d3c4b5a69780|  us-east-1d  |  use1-az1  |  10.42.1.0/24  |  251                  |
|  subnet-0a9b8c7d6e5f43210|  us-east-1a  |  use1-az2  |  10.42.2.0/24  |  251                  |
|  subnet-01234abcd5678ef90|  us-east-1e  |  use1-az3  |  10.42.3.0/24  |  251                  |
+--------------------------+--------------+------------+----------------+-----------------------+
```

4. Leé el `AvailableIpAddressCount`. Un /24 tiene 256 direcciones; obtuviste 251.

```bash
# DO NOT RUN — a NAT Gateway is billed per hour plus per GB from the moment it exists,
# and the "one per AZ for real HA" rule multiplies that by three.
# aws ec2 create-nat-gateway --subnet-id <subnet> --allocation-id <eipalloc-...>
```

5. **Limpieza — esto sí ejecutalo.**

```bash
for S in $(aws ec2 describe-subnets --region "$LAB_REGION" \
    --filters Name=vpc-id,Values="$VPC_ID" --query 'Subnets[].SubnetId' --output text); do
  aws ec2 delete-subnet --region "$LAB_REGION" --subnet-id "$S" && echo "deleted $S"
done
aws ec2 delete-vpc --region "$LAB_REGION" --vpc-id "$VPC_ID" && echo "deleted $VPC_ID"
```

**Comprobá tu comprensión**

- **Q9.1** — Cada /24 reporta 251 direcciones utilizables en lugar de 254. ¿Qué cinco direcciones reservó AWS, y para qué sirve cada una?
- **Q9.2** — Una subnet abarca exactamente una AZ y una VPC abarca todas las AZ de una Region. Reformulá ambos hechos como afirmaciones de aislamiento de fallos: ¿qué le hace la pérdida de una AZ a la subnet, a la VPC, a las route tables?
- **Q9.3** — Tu módulo de Terraform tiene hardcodeado `us-east-1a`, `us-east-1b`, `us-east-1c`. Dos cuentas lo despliegan. Describí la forma específica en que esto falla, y reescribí la regla de selección en una oración.
- **Q9.4** — El comentario del NAT Gateway dice "one per AZ for real HA". Explicá qué se rompe si desplegás un único NAT Gateway y ruteás las tres subnets a través de él, e identificá los *dos* costos separados que incurre esa decisión.
- **Q9.5** — Ahora tenés tres subnets y cero instancias. ¿Tenés alta disponibilidad? Enunciá con precisión qué te da la huella de tres AZ y qué no.

---

## Ejercicio 10 — La elección de Region como decisión puntuada, no como costumbre

El examen pregunta "qué Region debería usar la empresa". La respuesta de producción pesa cuatro factores: **cumplimiento y residencia de datos**, **proximidad a los usuarios**, **disponibilidad de servicios y funcionalidades**, y **costo**. Solo el primero es siempre una compuerta dura.

1. Poné precio a la misma instancia en varias Regions. La Pricing API en sí misma solo está disponible en unas pocas Regions, que es una pequeña broma que la plataforma te hace.

```bash
price() {
  aws pricing get-products --region us-east-1 --service-code AmazonEC2 \
    --filters "Type=TERM_MATCH,Field=instanceType,Value=m5.large" \
              "Type=TERM_MATCH,Field=regionCode,Value=$1" \
              "Type=TERM_MATCH,Field=operatingSystem,Value=Linux" \
              "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
              "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" \
              "Type=TERM_MATCH,Field=capacitystatus,Value=Used" \
    --max-results 1 --output json \
  | jq -r '.PriceList[] | fromjson | .terms.OnDemand
           | to_entries[0].value.priceDimensions | to_entries[0].value.pricePerUnit.USD'
}
for r in us-east-1 us-east-2 eu-west-1 eu-central-1 ap-southeast-1 sa-east-1; do
  printf '%-16s $%s /hr\n' "$r" "$(price "$r")"
done
```

```
us-east-1        $0.0960000000 /hr
us-east-2        $0.0960000000 /hr
eu-west-1        $0.1070000000 /hr
eu-central-1     $0.1150000000 /hr
ap-southeast-1   $0.1180000000 /hr
sa-east-1        $0.1530000000 /hr
```

*(Ilustrativo. Volvé a ejecutarlo; el orden es la lección duradera, los dígitos no.)*

2. Expresá la dispersión como un múltiplo, porque así es como aterriza en una factura anual.

```bash
awk 'BEGIN{ lo=0.096; hi=0.153; printf "spread: %.0f%%   annual delta on 100 instances: $%.0f\n",
  (hi/lo-1)*100, (hi-lo)*24*365*100 }'
```

```
spread: 59%   annual delta on 100 instances: $49932
```

3. Construí la tabla de decisión para un escenario concreto. **Escenario:** una fintech brasileña, todos los usuarios en Brasil, el regulador exige que los registros de clientes se almacenen en Brasil, la carga de trabajo necesita Amazon Aurora y AWS Lambda, sensible al costo.

```bash
for r in sa-east-1 us-east-1; do
  cc=$(aws ssm get-parameter --region us-east-1 \
        --name "/aws/service/global-infrastructure/regions/$r/geolocationCountry" \
        --query 'Parameter.Value' --output text)
  for s in rds lambda; do
    ok=$(aws ssm get-parameters-by-path --region us-east-1 \
          --path "/aws/service/global-infrastructure/regions/$r/services" \
          --query "length(Parameters[?Value=='$s'])" --output text)
    printf '%-12s country=%s  %-8s %s\n' "$r" "$cc" "$s" "$([ "$ok" = 1 ] && echo present || echo ABSENT)"
  done
done
```

4. Completá la matriz a mano con tus propias mediciones. Ponderá las columnas antes de mirar los puntajes.

| Factor | ¿Compuerta o puntaje? | `sa-east-1` | `us-east-1` |
|---|---|---|---|
| Residencia de datos (BR) | **compuerta** | pasa | **falla** |
| RTT desde São Paulo | puntaje | ~10 ms | ~120 ms |
| Aurora + Lambda presentes | **compuerta** | pasa | pasa |
| m5.large on-demand | puntaje | $0.153 | $0.096 |
| Amplitud de tipos de instancia | puntaje | ~412 | ~831 |

**Comprobá tu comprensión**

- **Q10.1** — En la matriz, una Region es 59% más barata y tiene el doble de tipos de instancia. ¿Por qué, aun así, la decisión no está ni cerca de ser ajustada? Nombrá la propiedad de un factor "compuerta" que vuelve irrelevantes a los factores de puntaje.
- **Q10.2** — Las Regions difieren en precio hasta un ~60% por hardware idéntico. Dá las dos razones estructurales por las que AWS pone precios distintos a las Regions.
- **Q10.3** — La fintech más adelante quiere una Region de recuperación ante desastres. ¿Cuál de los cuatro factores cambia de peso, y qué Region preseleccionarías? Justificá usando `geolocationCountry` y el límite de aislamiento AZ/Region.
- **Q10.4** — Un equipo propone correr todo en `us-east-1` "porque es la más barata y tiene todos los servicios". Dá tres riesgos distintos de ese valor por defecto, uno de cada uno: latencia, cumplimiento y blast radius.
- **Q10.5** — ¿Cuál de los cuatro factores puede cambiar *después* de desplegar, forzando una reevaluación? Dá un ejemplo concreto de cada uno que pueda hacerlo.

---

## Ejercicio 11 — Extender el límite: Outposts, Local Zones, Wavelength, Dedicated Local Zones

La última pieza del tema es el conjunto de respuestas a "necesito AWS, pero no en una Region de AWS". Cada una es una *extensión de* una Region padre — el control plane se queda en la Region en todos los casos.

1. Confirmá que tu cuenta no tiene Outposts e inspeccioná la superficie de API que describiría uno.

```bash
aws outposts list-sites --region "$LAB_REGION" --output json
aws outposts list-outposts --region "$LAB_REGION" --output json
```

```json
{ "Sites": [] }
{ "Outposts": [] }
```

2. Listá el catálogo de hardware de Outpost — los factores de forma son la diferencia concreta entre "un servidor en un rack que es tuyo" y "un rack que entrega AWS".

```bash
aws outposts list-catalog-items --region "$LAB_REGION" \
  --query 'CatalogItems[].[CatalogItemId,ItemStatus,SupportedStorage[0]]' --output table 2>/dev/null | head -12
```

3. Mapeá los cuatro modelos de extensión sobre las dos preguntas que realmente eligen entre ellos. Completá esta tabla con lo que observaste en el ejercicio 3:

| Modelo | Dónde está el hardware | Quién lo opera | Objetivo de latencia | Control plane |
|---|---|---|---|---|
| Availability Zone | centro de datos de AWS en la Region | AWS | ~1 ms dentro de la Region | en la Region |
| Local Zone | instalación de AWS en una metrópolis | AWS | milisegundos de un dígito hacia la metrópolis | Region padre |
| Wavelength Zone | dentro de la red 5G de una telco | AWS + operadora | ~10 ms al dispositivo móvil | Region padre |
| Outpost | **tu** edificio | AWS (en remoto) | local a la LAN | Region padre |

4. Razoná sobre el modo de fallo que distingue a los Outposts. Respondé antes de leer la sección de respuestas: con el enlace cortado, ¿cuáles de los siguientes siguen funcionando en un Outpost — instancias EC2 en ejecución, lanzar una *nueva* instancia EC2, leer un volumen EBS local, la vista de la consola de AWS del Outpost, las alarmas de CloudWatch?

**Comprobá tu comprensión**

- **Q11.1** — Un hospital debe mantener las imágenes de pacientes on-premises por motivos legales pero quiere la superficie de API de AWS. ¿Qué modelo, y qué les cuesta exactamente que "el control plane se quede en la Region" durante una caída de la WAN?
- **Q11.2** — Una empresa de video en vivo necesita codificación por debajo de 10 ms para espectadores en Los Ángeles. ¿Local Zone o Wavelength Zone? ¿Qué único hecho sobre los *usuarios finales* lo decide?
- **Q11.3** — Explicá por qué ninguno de estos cuatro modelos es una estrategia de recuperación ante desastres para la Region padre.
- **Q11.4** — ¿Qué es una Dedicated Local Zone, y qué requisito satisface que una Local Zone estándar no?
- **Q11.5** — Los cuatro modelos mantienen el control plane en la Region padre. Enunciá el único principio de diseño que esto revela sobre cómo AWS extiende su infraestructura.

---

## Modelo mental consolidado

| Constructo | Cantidad (orden de magnitud) | ¿Límite de aislamiento? | ¿Desplegás dentro? | Falla independientemente de… |
|---|---|---|---|---|
| Partición | 3 públicas | **el más fuerte** — IAM separado, cuentas separadas, ARNs separados | sí, con credenciales separadas | todo lo de las otras particiones |
| Region | decenas | **sí** — el límite primario de fallos | sí | otras Regions |
| Availability Zone | 3–6 por Region | **sí** — energía, refrigeración, red, inundaciones | sí | otras AZ de la Region |
| Local Zone / Wavelength Zone | decenas–cientos | no — extensión de la Region padre | sí | no de la Region padre |
| Outpost | por cliente | no — extensión de la Region padre | sí | no de la Region padre |
| Edge location / PoP | cientos | no — sin estado, solo caché | **no** | individualmente irrelevante |
| Regional edge cache | ~una docena | no | **no** | individualmente irrelevante |

Tres oraciones que vale la pena llevarse al examen y a una revisión de diseño:

1. **Una Region es la unidad de residencia de datos y la unidad de recuperación ante desastres; una AZ es la unidad de alta disponibilidad.** Confundirlas produce arquitecturas que están altamente disponibles frente a un fallo que no va a ocurrir e indefensas frente al que sí.
2. **Todo lo que dice "global" tiene una Region de origen.** Encontrala antes de escribir el runbook.
3. **Nunca memorices los números.** `describe-regions`, `describe-availability-zones`, el árbol de parámetros `/aws/service/global-infrastructure/` e `ip-ranges.json` son la fuente de verdad, son gratis y están al día.

---

## Fuentes

- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- AWS Global Infrastructure — https://aws.amazon.com/about-aws/global-infrastructure/
- Regions and Availability Zones — https://aws.amazon.com/about-aws/global-infrastructure/regions_az/
- Amazon EC2 User Guide, *Regions and Zones* — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-regions-availability-zones.html
- AWS RAM User Guide, *Availability Zone IDs* — https://docs.aws.amazon.com/ram/latest/userguide/working-with-az-ids.html
- Systems Manager, *Public parameters — global infrastructure* — https://docs.aws.amazon.com/systems-manager/latest/userguide/parameter-store-public-parameters-global-infrastructure.html
- AWS Account Management, *Enabling and disabling Regions* — https://docs.aws.amazon.com/accounts/latest/reference/manage-acct-regions.html
- *AWS IP address ranges* — https://docs.aws.amazon.com/vpc/latest/userguide/aws-ip-ranges.html
- Amazon CloudFront, *How CloudFront delivers content* (edge locations and regional edge caches) — https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/HowCloudFrontWorks.html
- AWS Global Accelerator Developer Guide — https://docs.aws.amazon.com/global-accelerator/latest/dg/what-is-global-accelerator.html
- Amazon Route 53 Developer Guide — https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/Welcome.html
- AWS General Reference, *Service endpoints and quotas* — https://docs.aws.amazon.com/general/latest/gr/rande.html
- AWS General Reference, *ARNs and namespaces* — https://docs.aws.amazon.com/general/latest/gr/aws-arns-and-namespaces.html
- AWS Local Zones User Guide — https://docs.aws.amazon.com/local-zones/latest/ug/what-is-aws-local-zones.html
- AWS Wavelength Developer Guide — https://docs.aws.amazon.com/wavelength/latest/developerguide/what-is-wavelength.html
- AWS Outposts User Guide — https://docs.aws.amazon.com/outposts/latest/userguide/what-is-outposts.html
- Whitepaper, *AWS Fault Isolation Boundaries* — https://docs.aws.amazon.com/whitepapers/latest/aws-fault-isolation-boundaries/abstract-and-introduction.html
- API Reference, `DescribeInstanceTypeOfferings` — https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_DescribeInstanceTypeOfferings.html
- AWS Price List API, `GetProducts` — https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/API_pricing_GetProducts.html

---

<details>
<summary><strong>Respuestas</strong> — abrí solo después de completar los ejercicios</summary>

### Ejercicio 0

**A0.1** — Las otras dos particiones públicamente disponibles son `aws-cn` (China: `cn-north-1` Pekín, operada por Sinnet, y `cn-northwest-1` Ningxia, operada por NWCD) y `aws-us-gov` (`us-gov-west-1`, `us-gov-east-1`). También hay particiones no públicas para clientes de inteligencia de EE. UU. (`aws-iso`, `aws-iso-b`) a las que las cuentas comunes no pueden llegar.

La consecuencia operativa: una partición es una copia completamente separada de AWS. Raíz de cuenta separada, principales de IAM separados, credenciales separadas, endpoints de servicio separados (`amazonaws.com.cn` en lugar de `amazonaws.com`), URL de consola separada, y ninguna confianza de IAM entre particiones. No podés asumir un rol entre particiones, no podés replicar un bucket de S3 entre particiones con S3 Replication, y un ARN de una partición no significa nada en otra. En la práctica, un despliegue en China es el trabajo operativo de una segunda empresa, y además requiere una entidad china y una licencia ICP. Por eso la partición es el *primer* campo de todo ARN — es el límite más externo.

**A0.2** — Es efectivamente cierto solo cuando el entorno tiene una Region configurada en algún punto de la cadena de precedencia y esa Region resulta ser `us-east-1` — lo más común es porque `~/.aws/config` fue escrito por `aws configure` aceptando el valor por defecto, o porque una herramienta heredada dejó `AWS_DEFAULT_REGION=us-east-1`.

Sigue siendo el modelo equivocado porque, con *nada* configurado, la CLI falla con `You must specify a region`, y los SDK lanzan un error de configuración en vez de elegir en silencio. El modelo mental importa porque la creencia de que "por defecto se va calladamente a N. Virginia" es exactamente cómo se crean recursos en la Region equivocada — y en un contexto de residencia de datos, un recurso en la Region equivocada es un incidente de cumplimiento, no un error de tipeo. Fijá siempre la Region de forma explícita en la automatización.

### Ejercicio 1

**A1.1** — `describe-regions` devuelve las Regions **habilitadas para tu cuenta**; `--all-regions` devuelve todas las Regions de tu partición sin importar la habilitación. AWS construye Regions; tu cuenta debe consentir aquellas introducidas después de que empezó la política de opt-in (a grandes rasgos, las Regions lanzadas de 2019 en adelante), porque habilitar una Region tiene implicaciones de facturación, gobernanza y legales que el dueño de la cuenta debería elegir deliberadamente.

Las dos Regions estructuralmente siempre habilitadas en la partición comercial son `us-east-1` (aloja los control planes globales — IAM, Route 53, CloudFront, Organizations, facturación) y `us-west-2` (la segunda Region que AWS trata como siempre encendida para dependencias de servicio). Más en general, toda Region que existía antes del mecanismo de opt-in es `opt-in-not-required`.

**A1.2** — Las Regions `opt-in-not-required` son las más viejas — el conjunto que AWS había lanzado antes de introducir la habilitación por Region. AWS cambió el valor por defecto porque una Region disponible en silencio para toda cuenta es un agujero de gobernanza: un ingeniero podría crear recursos en una jurisdicción que la empresa nunca aprobó, el gasto aparecería en una Region que nadie monitorea, y el instrumental de seguridad (GuardDuty, CloudTrail, Config) se configura por Region y no estaría mirando. Hacer que las Regions nuevas estén desactivadas por defecto invierte eso: una Region está a oscuras hasta que alguien decide lo contrario, que es el valor por defecto correcto tanto para costo como para cumplimiento.

**A1.3** — El ordinal te dice el **orden de lanzamiento dentro de esa agrupación geográfica** y nada más. `ap-northeast-1` (Tokio) se lanzó antes que `ap-northeast-3` (Osaka); ese es todo el contenido del número. No codifica capacidad, cantidad de AZ, cobertura de servicios, precio ni preferencia. De hecho, Osaka empezó su vida como una "Local Region" restringida de acceso limitado y se convirtió en Region estándar más tarde — el código nunca cambió para reflejarlo. Trampa relacionada: `us-east-1` y `us-east-2` son ambas "US East" pero son Regions separadas con dominios de fallo independientes; el prefijo compartido significa geografía, no correlación de disponibilidad.

**A1.4** — Los dos mecanismos:

1. **Opt-out de Region** (`aws account disable-region` / la página de Account settings). Deshabilitá toda Region fuera de la UE. Este es el del ejercicio.
2. **Una SCP en AWS Organizations** usando la clave de condición `aws:RequestedRegion` para hacer `Deny` de todas las acciones cuando la Region solicitada no está en una lista permitida.

La SCP es el control real: se administra centralmente, no puede quitarla un administrador de la cuenta miembro, se aplica a cada principal de cada cuenta bajo la OU, y puede exceptuar los servicios globales (IAM, Route 53, CloudFront, Organizations, Support) que igual deben poder llamarse vía `us-east-1`. Deshabilitar Regions es una comodidad y una buena capa de defensa en profundidad, pero es una configuración a nivel de cuenta que un principal suficientemente privilegiado en esa cuenta puede revertir, y no puede expresar excepciones. Usá ambos; confiá en la SCP.

**A1.5** — `cn-north-1` está en la partición `aws-cn`, y toda llamada a la API de AWS está acotada a la partición de las credenciales que la hacen. Tus credenciales `arn:aws:` no pueden enumerar, describir ni alcanzar nada en `aws-cn`. Para verlo necesitarías una cuenta separada de AWS (China), obtenida a través de Sinnet o NWCD, con una entidad empresarial china y un registro ICP — más claves de acceso separadas, una consola separada en `amazonaws.cn` y una configuración de herramientas separada.

### Ejercicio 2

**A2.1** — Casi seguro que **no**. `ZoneName` (`us-east-1a`) se mapea a una zona física **de forma independiente para cada cuenta de AWS**; `ZoneId` (`use1-az2`) es el identificador estable e independiente de la cuenta de la zona física. Dos cuentas están en la misma zona física solo si sus valores de `ZoneId` coinciden. En la salida de ejemplo, `us-east-1a` era `use1-az2` — una cuenta donde `us-east-1a` mapea a `use1-az1` estaría en otro edificio a pesar del nombre idéntico.

**A2.2** — Antes de la aleatorización, el `us-east-1a` de toda cuenta era la *misma* zona física, y los seres humanos eligen el primer elemento de una lista. El resultado fue que las zonas "a" quedaban sistemáticamente sobresuscriptas y las "e"/"f" subutilizadas en toda la base de clientes, lo cual es malo para la planificación de capacidad de AWS y malo para los clientes que se amontonaban todos en el mismo dominio de fallo. Aleatorizar el mapeo por cuenta distribuye la carga de manera pareja por construcción y elimina la ilusión de que `-1a` es de algún modo la zona primaria o preferida. Vale la pena notar que la solución fue hacer que el *nombre* fuera insignificante en lugar de educar a los usuarios — un buen ejemplo de diseñar alrededor del comportamiento humano y no contra él.

**A2.3** — El **AZ ID** (`use1-az2`) va en el ticket. El nombre de AZ es inútil cruzando el límite de una cuenta, porque significa algo distinto de cada lado. Esto no es un caso de borde: es precisamente por eso que existe el campo `ZoneId`, y por eso `create-subnet` acepta `--availability-zone-id`. Cuando compartís una subnet vía AWS RAM, la cuenta consumidora ve el nombre de AZ propio de la subnet renderizado en *su* mapeo, así que coordinar por nombres produce tráfico entre AZ silencioso — pagás la transferencia de datos y te comés la latencia, y nada da error para avisarte.

**A2.4** — No. Todo lo que aprendiste es que **a tu cuenta actualmente se le ofrecen dos AZ en `us-west-1`**. AWS no garantiza que toda cuenta vea todas las AZ de una Region; las Regions más viejas y con restricciones de capacidad en particular se exponen de forma selectiva. La formulación segura es: *"al momento de esta llamada, esta cuenta puede usar N AZ en esta Region."* La regla de diseño que se sigue es más importante que el número: nunca hardcodees una cantidad de AZ, siempre derivala, y tratá "al menos tres" como una propiedad a verificar por Region en lugar de asumirla. El propio principio de diseño declarado por AWS es que las Regions lanzadas desde ~2018 tienen al menos tres AZ.

**A2.5** — AWS es responsable de que las AZ *existan y sean genuinamente independientes* — alimentaciones eléctricas separadas, refrigeración separada, caminos de red separados, instalaciones físicamente separadas y enlaces privados de baja latencia entre ellas. Eso es "de la nube".

**Vos** sos responsable de usar más de una. Elegir RDS Multi-AZ, repartir un Auto Scaling group en tres subnets en tres AZ, poner un ALB en varias AZ — esas son decisiones del cliente. AWS te va a dejar felizmente construir una arquitectura de una sola AZ y no va a hacer que sobreviva a la pérdida de una AZ. Esta es la ilustración más limpia del modelo de responsabilidad compartida en todo el dominio de infraestructura: AWS provee el aislamiento de fallos, vos elegís si lo consumís.

**A2.6** — Por la distancia. Las AZ de una Region están a ~100 km entre sí, así que el viaje de ida y vuelta es del orden de 1 ms (milisegundos de un solo dígito en el peor caso). Una escritura síncrona que espera una segunda copia cuesta entonces ~1 ms extra — aceptable para un commit de base de datos.

Las Regions están típicamente a miles de kilómetros. De `us-east-1` a `eu-west-1` hay ~5.800 km de círculo máximo, así que el *piso* del viaje de ida y vuelta es de unos 58 ms y la cifra real es de 70–80 ms. Un commit síncrono que paga 80 ms te limita a aproximadamente 12 escrituras secuenciales por segundo por cadena de transacciones — comercialmente inservible. De ahí: **síncrono dentro de una Region (Multi-AZ), asíncrono entre Regions (read replicas, Aurora Global Database, S3 CRR)** — y asíncrono significa un RPO distinto de cero, que es una decisión de negocio que hay que tomar explícitamente.

### Ejercicio 3

**A3.1** — `ParentZoneName` significa que la Local Zone no es una Region independiente sino un satélite de una. Arquitectónicamente: la VPC es la VPC *de la Region padre*, extendida por una subnet en la Local Zone. El **control plane está enteramente en la Region padre** — la API de EC2 que llamás es `ec2.us-west-2.amazonaws.com`, la autorización de IAM ocurre con normalidad, las métricas de CloudWatch aterrizan en `us-west-2`, y la enorme mayoría de los servicios de AWS (S3, DynamoDB, RDS más allá del conjunto soportado, Lambda, la mayoría de los servicios gestionados) existen solo en la Region padre. Lo que corre en la Local Zone es un subconjunto deliberadamente chico — EC2, EBS, ALB y unos pocos más — para la capa sensible a la latencia. Tu tráfico de data plane desde la Local Zone hacia cualquier servicio no soportado atraviesa el enlace de vuelta a la Region padre, así que el patrón de diseño es: front-end crítico en latencia en la Local Zone, todo lo demás en la Region.

**A3.2** — De más cerca a más lejos:

1. **Outpost** — físicamente en tu propio edificio. Justificado por datos que legal o contractualmente no pueden salir de tus instalaciones, o por una carga de trabajo con un requisito duro de latencia de LAN hacia equipamiento on-premises (control de planta fabril, modalidad de imágenes hospitalarias, colocation de trading).
2. **Wavelength Zone** — dentro de la red de una operadora móvil, de modo que el tráfico de un dispositivo 5G nunca sale de la operadora para llegarte. Justificado por cargas de trabajo de dispositivos móviles que necesitan ~10 ms: AR/VR en teléfonos, telemetría de vehículos conectados, análisis de video móvil en tiempo real.
3. **Local Zone** — una instalación de AWS dentro de una metrópolis grande que no tiene Region. Justificado por aplicaciones sensibles a la latencia para usuarios de esa metrópolis: juegos en tiempo real, producción de video en vivo, escritorio remoto/VDI, renderizado de medios.
4. **Availability Zone** — un centro de datos de AWS dentro de la Region. Justificado por todo lo demás, que es la abrumadora mayoría de las cargas de trabajo.

La disciplina es empezar en (4) y moverse hacia afuera solo cuando un requisito medido lo obliga, porque cada paso hacia afuera cuesta disponibilidad de servicios, complejidad operativa y dinero.

**A3.3** — `NetworkBorderGroup` es el **límite dentro del cual una IP pública se anuncia a internet**. AWS anuncia un prefijo dado desde un conjunto específico de ubicaciones; una dirección en el border group `us-west-2-lax-1` se anuncia desde Los Ángeles, y una dirección en el border group `us-west-2` se anuncia desde Oregón.

No podés mover una Elastic IP entre border groups porque la dirección pertenece literalmente a un prefijo que se anuncia por BGP desde otro lugar. Moverla significaría retirar y volver a anunciar una ruta, lo cual no es una operación a nivel de cuenta. La consecuencia práctica: cuando asignás una EIP para una instancia en Local Zone tenés que pasar `--network-border-group us-west-2-lax-1`, y una EIP que ya tenés en la Region padre no puede conectarse a una instancia de Local Zone. Equivocarse con esto produce un confuso `InvalidParameterCombination` exactamente en el peor momento de un despliegue.

**A3.4** — Con el enlace cortado:

- **Data plane de EC2 (instancias ya en ejecución)** — sigue corriendo. Las instancias continúan ejecutando, sirviendo tráfico local y hablando entre sí por la red local.
- **Control plane de EC2 (lanzar una *nueva* instancia)** — **falla**. El control plane está en la Region padre; sin camino hacia él no podés lanzar, detener, terminar ni modificar instancias. Este es el hecho más importante sobre los Outposts.
- **Volúmenes EBS conectados a instancias del Outpost** — siguen funcionando para lecturas y escrituras; el almacenamiento es local al Outpost. No podés crear, snapshotear ni modificar volúmenes, porque eso es trabajo de control plane.
- **Métricas de CloudWatch** — dejan de llegar a la Region. Las métricas se almacenan localmente por una ventana limitada y se entregan cuando vuelve la conectividad; las alarmas que dependen de ellas pasan a `INSUFFICIENT_DATA`.
- **Vista del Outpost en la consola** — muestra el último estado conocido, y las acciones mutantes fallan.

La implicancia de diseño: un Outpost no es una nube autónoma. Cualquier cosa que deba sobrevivir a una partición de WAN tiene que estar ya corriendo y no debe depender del escalado, de los servicios gestionados de la Region, ni de autenticación del lado de la Region para su camino de datos.

**A3.5** — Una Local Zone es una *extensión de* su Region padre y comparte el control plane de esa Region — así que un fallo del control plane de la Region padre se lleva puesta la Local Zone, lo que significa que no es un dominio de fallo independiente y por lo tanto no es un destino de DR. (Para DR necesitás otra **Region**.)

### Ejercicio 4

**A4.1** — Los servicios nuevos se lanzan en un número pequeño de Regions y se expanden a lo largo de meses o años, impulsados por la demanda, la capacidad, la dependencia de hardware y la regulación local. `us-east-1` (N. Virginia) casi siempre está en la primera ola, con frecuencia sola o acompañada de `us-west-2`; es la Region más grande y el destino por defecto de los lanzamientos de servicios nuevos. El corolario es que **la cobertura de servicios es específica de la Region y es una entrada de primer orden en la elección de Region** — una Region que es más barata y más cercana no sirve de nada si le falta un servicio que tu arquitectura requiere. La brecha se ensancha para todo lo que depende de hardware (cómputo acelerado, familias de instancias especializadas) y para todo lo nuevo.

**A4.2** —

```bash
for s in ec2 lambda rds dynamodb sqs cloudfront; do
  n=$(aws ssm get-parameters-by-path --region us-east-1 \
        --path /aws/service/global-infrastructure/regions/il-central-1/services \
        --query "length(Parameters[?Value=='$s'])" --output text)
  printf '%-14s %s\n' "$s" "$([ "$n" = 1 ] && echo present || echo MISSING)"
done
```

Dos advertencias que vale la pena enunciar en la revisión de diseño: la *presencia* de un servicio no implica paridad de funcionalidades (un servicio puede existir en una Region sin sus funcionalidades, clases de instancia o versiones de motor más nuevas), y no implica paridad de cuotas (las cuotas de servicio por defecto son más bajas en Regions chicas y llevan tiempo subirlas). Verificá la funcionalidad específica y pedí aumentos de cuota temprano.

**A4.3** — No, es necesario pero no suficiente. `geolocationCountry=BR` te dice dónde está físicamente la infraestructura de la Region; no dice nada sobre lo que *vos* hacés con los datos. Para satisfacer realmente la residencia tenés que además asegurarte de: ninguna replicación ni backup entre Regions hacia otra Region; ninguna agregación de CloudWatch/CloudTrail/Config hacia una Region fuera del país; ninguna dependencia de servicio entre Regions en el camino de datos; y un manejo adecuado de todo lo que exportes deliberadamente.

Recursos que igual quedarían fuera de Brasil sin importar qué: **IAM** (global, control plane en `us-east-1`) — nombres de usuario, nombres de rol, documentos de política; hosted zones y datos de registros de **Route 53**; la configuración de distribuciones de **CloudFront** y, más importante, los **objetos cacheados en edge locations de todo el mundo** — lo cual es un problema genuino de residencia si ponés contenido regulado detrás de CloudFront sin restricción geográfica; **AWS Organizations** y los datos de facturación consolidada; y el contenido de los casos de soporte que tipeás en un ticket. Los metadatos como nombres de recursos y etiquetas se pasan por alto con frecuencia y suelen estar en el alcance de un regulador.

**A4.4** — Porque la versión es lo que convierte el conteo en un *hecho citable* en lugar de un recuerdo. "AWS tiene N Regions" es falso dentro de un trimestre; "AWS publicó N Regions en el conjunto de datos de infraestructura global `1.0.0-20260901`" sigue siendo cierto para siempre. En un documento de diseño, un artefacto de auditoría o material de estudio, la versión con fecha convierte una afirmación que se degrada en una reproducible — cualquiera puede volver a ejecutar la consulta, obtener un número distinto, y ver exactamente por qué difiere.

### Ejercicio 5

**A5.1** — Dos razones estructurales, ambas esperables:

1. **La fibra no va derecha.** Las rutas terrestres siguen derechos de paso — vías férreas, autopistas, conductos existentes — y los cables submarinos siguen caminos relevados del lecho marino, rodeando plataformas continentales y fosas. Un multiplicador de 1,3–2× sobre la distancia de círculo máximo es normal.
2. **El ruteo es comercial, no geométrico.** Tu ISP entrega el tráfico a AWS en un punto de peering, y el punto de peering más cercano puede estar muy lejos del camino más corto — el tráfico latinoamericano históricamente pasa por Miami incluso entre dos extremos sudamericanos. Sumá serialización por salto, encolado y retardo de conmutación en cada router.

Ninguna de las dos es una falla. La lección es que hay que **medir** el RTT en lugar de calcularlo con un mapa.

**A5.2** — Porque la latencia se paga **por viaje de ida y vuelta**, y una petición real es una cadena de viajes dependientes: DNS, handshake TCP (1 RTT), handshake TLS (1–2 RTT), la propia petición HTTP y después una secuencia de llamadas dependientes al back-end — un chequeo de autenticación, una búsqueda de sesión, tres consultas a la base de datos donde cada una depende de la anterior. De diez a veinte viajes de ida y vuelta no tiene nada de extraordinario. Multiplicá un delta de RTT de 90 ms por 12 y agregaste aproximadamente un segundo entero antes de que ocurra trabajo alguno.

La mitigación que no requiere mover la Region es **reducir la cantidad de viajes de ida y vuelta**: agrupá consultas dependientes, paralelizá las independientes, cacheá en el borde con CloudFront, terminá TLS en el borde (Global Accelerator o CloudFront) para que el handshake caro ocurra cerca del usuario y el trayecto largo corra sobre una conexión ya establecida en la backbone de AWS, usá HTTP/2 o HTTP/3 con reutilización de conexiones, y habilitá TLS 1.3 para ahorrar un viaje de handshake. La verborragia, no la distancia, suele ser la palanca más grande.

**A5.3** —

- **Latencia del primer byte de una llamada dinámica a la API** — mejora. Esto está limitado por el viaje de ida y vuelta y es el caso clásico de proximidad de Region.
- **Tiempo de descarga de un archivo estático de 2 GB** — apenas mejora al elegir Region, y este es el contraintuitivo. La transferencia masiva está limitada por el throughput, no por la latencia. La solución correcta es CloudFront, que sirve el objeto desde una edge location a metros de distancia en términos de red, sin importar en qué Region esté el origen. (La latencia sí afecta el ramp-up de TCP, así que no es literalmente cero, pero elegir Region es la palanca equivocada.)
- **Latencia de escritura en base de datos** — mejora *si* el cliente está cerca de la base. Notá que esta es una pregunta distinta del retraso de réplica, que está acotado por la distancia entre Regions, no por tu distancia a ninguna de ellas.
- **Costo del handshake TLS** — mejora, y desproporcionadamente: TLS 1.2 cuesta dos viajes de ida y vuelta adicionales sobre el único de TCP, así que un delta de 90 ms de RTT se vuelve ~270 ms solo en el establecimiento de la conexión.

**A5.4** — La física te obliga a decidir **dónde vive el único punto de consistencia**, porque no podés tener consistencia síncrona y baja latencia de escritura para usuarios en tres continentes al mismo tiempo. Las dos respuestas legítimas:

1. **Una Region escritora, read replicas en todas partes.** Elegí la Region más cercana a la población de usuarios más grande o más sensible a la latencia, aceptá que los usuarios de otros lados paguen el RTT largo en las escrituras, y serví las lecturas localmente (Aurora Global Database, DynamoDB Global Tables en modo escritor único, read replicas de RDS entre Regions). Las escrituras son lentas para dos de las tres poblaciones; las lecturas son rápidas para todas. Esta es la respuesta correcta para la mayoría de los sistemas.
2. **Particioná los datos por región de pertenencia.** Los registros de un cliente de São Paulo viven y se escriben en `sa-east-1`; los de un cliente de Frankfurt en `eu-central-1`. Cada usuario obtiene escrituras locales rápidas; el costo es que las consultas entre particiones son difíciles y las vistas agregadas globales deben construirse asincrónicamente. Esta es la respuesta correcta cuando el modelo de datos realmente particiona por usuario — y tiene el agradable efecto secundario de resolver la residencia de datos al mismo tiempo.

La respuesta que **no** es legítima es multi-escritor síncrono entre Regions con consistencia fuerte. Cualquiera que la ofrezca está escondiendo una política de resolución de conflictos, una ventana de consistencia eventual, o ambas.

### Ejercicio 6

**A6.1** — Ante un miss de caché, los bytes viajan por los tres niveles:

1. La petición del usuario resuelve por DNS a la **edge location (PoP)** más cercana en términos de red — `GRU1-C1`, São Paulo. TCP y TLS terminan acá.
2. El PoP no tiene el objeto, así que le pregunta a su **regional edge cache** — una caché intermedia más grande y menos numerosa. Otro miss.
3. La regional edge cache trae el objeto del **origen** — el bucket de S3 en su Region — viajando por la **backbone de AWS**, no por internet público.
4. El objeto fluye de vuelta hacia abajo, guardándose en la regional edge cache y en el PoP en el camino, y se entrega al usuario.

Todos los usuarios subsiguientes de São Paulo obtienen un hit en el paso 1. Los tres niveles son: edge location, regional edge cache y Region.

**A6.2** — La **edge location (PoP)** lo sirvió. Ante un miss, CloudFront habría consultado la **regional edge cache** antes de ir al origen.

Las regional edge caches existen porque hay cientos de PoP, cada uno con almacenamiento limitado, cada uno desalojando de forma independiente. Sin un nivel intermedio, un objeto moderadamente popular se desaloja de cada PoP y cada miss se vuelve una búsqueda al origen — así que el origen ve cientos de peticiones por el mismo objeto y el contenido de cola larga nunca se cachea efectivamente en ningún lado. La regional edge cache es más grande y está detrás de muchos PoP, así que absorbe esos misses: la carga del origen cae abruptamente y mejoran las tasas de acierto de la cola larga. Notá que las regional edge caches se saltean para contenido dinámico (`PUT`/`POST`/`PATCH`/`DELETE`), para métodos proxy, y para contenido configurado con Origin Shield, que es una funcionalidad relacionada pero distinta que habilitás explícitamente.

**A6.3** — Dos diferencias decisivas:

1. **Protocolo.** CloudFront es una CDN HTTP/HTTPS — entiende peticiones, cachea respuestas, y no hace nada por otros protocolos. Global Accelerator opera en la capa de red/transporte y reenvía **TCP y UDP en cualquier puerto**, sin caché y sin conciencia del protocolo. Un servidor de juego UDP directamente no puede usar CloudFront.
2. **Direccionamiento.** Global Accelerator te da **dos direcciones IP anycast estáticas** que nunca cambian y pueden ponerse en una lista permitida de un firewall o hardcodearse en un cliente. CloudFront te da un nombre DNS cuyas direcciones cambian constantemente. Para un sitio web estático, la propiedad de IP estática no vale nada y el caché es todo el valor; para un cliente de juego o una flota de IoT que no puede hacer DNS de forma confiable, las IP estáticas son el punto.

Tercera diferencia que vale conocer: Global Accelerator hace failover rápido entre endpoints regionales ante un fallo de health check y puede ponderar tráfico entre Regions, así que también funciona como gestor de tráfico multi-Region con failover en menos de un minuto — mucho más rápido que el failover basado en DNS, que está acotado por el TTL y el comportamiento de los resolvers.

**A6.4** — `CLOUDFRONT` es el conjunto completo de prefijos que usa CloudFront, incluidos los que solo miran hacia los **usuarios**. `CLOUDFRONT_ORIGIN_FACING` es el subconjunto desde el cual CloudFront realmente inicia conexiones **hacia tu origen**. Solo este último corresponde en el security group de tu origen: permitir el conjunto completo ensancha innecesariamente el ingreso, y no permitir ninguno significa que expusiste tu origen a todo internet, dejando que los atacantes salteen CloudFront (y por lo tanto salteen tu WAF, tu caché y tu protección de Shield).

La mejor respuesta en la práctica no es parsear el JSON en absoluto, sino referenciar directamente la lista de prefijos gestionada por AWS `com.amazonaws.global.cloudfront.origin-facing` en la regla del security group — AWS la mantiene, se actualiza automáticamente, y no consume entradas de regla como sí lo hace una lista de CIDR expandida.

**A6.5** — Porque son objetos fundamentalmente distintos. Una Region es un conjunto de varios centros de datos grandes con subestaciones eléctricas independientes, refrigeración independiente, fibra de larga distancia redundante y datos de clientes con estado y durables — un proyecto de construcción de varios años, intensivo en capital, sujeto a regulación local, disponibilidad de energía y adquisición de tierras. Una edge location es una caché: un rack o una jaula pequeña en una instalación de colocation existente, sin estado, sin datos durables de clientes, y descartable sin más consecuencia que un miss de caché. Podés poner una en un carrier hotel de cualquier ciudad grande en semanas. La ausencia de estado es lo que hace posible la escala.

**A6.6** — Lo que *sí* puede correr en el borde: caché y entrega de contenido (CloudFront), resolución DNS (Route 53), terminación TLS, absorción de DDoS e inspección WAF (Shield, AWS WAF), ingreso anycast a la backbone (Global Accelerator), y **cómputo pequeño, de vida corta y sin estado** — CloudFront Functions (submilisegundo, JavaScript, solo manipulación de cabeceras y URL) y Lambda@Edge (más grande, corre en regional edge caches y no en los PoP, igualmente acotado).

Lo que no: tu aplicación. No hay instancias EC2, ni contenedores, ni bases de datos, ni almacenamiento persistente, ni VPC en una edge location. No podés desplegar un servicio ahí. La reformulación correcta de la propuesta del colega es: *"usemos CloudFront para servir contenido cacheable desde el borde y para terminar conexiones cerca de los usuarios, y consideremos una Local Zone si necesitamos cómputo real más cerca de una metrópolis específica."*

### Ejercicio 7

**A7.1** — No, el bucket no es global. `LocationConstraint` es `null` para `us-east-1` por una razón puramente **histórica**: `us-east-1` fue la Region original de S3 y durante un tiempo la única, y el elemento `LocationConstraint` se agregó después para nombrar a las otras. El valor vacío/`null` se dejó con el significado de "la Region original" para que los clientes existentes siguieran funcionando. También te vas a encontrar con el valor heredado `EU`, que significa `eu-west-1` y es anterior a los códigos de Region modernos.

Los datos del bucket se almacenan en `us-east-1`, replicados entre AZ dentro de esa Region, y no la abandonan a menos que configures replicación. El null es un artefacto de compatibilidad, no una afirmación sobre el alcance — y es una fuente real de bugs en código que hace `if location is None: raise`.

**A7.2** — El control plane de IAM está en `us-east-1`; el ámbito de firma prueba que la llamada fue ahí sin importar el flag `--region`.

- **Escrituras de IAM en todo el mundo** — un evento del control plane de `us-east-1` las bloquea en todas partes. No podés crear un rol, adjuntar una política, rotar una clave de acceso ni crear un usuario en ninguna Region mientras el control plane de IAM esté degradado, porque hay uno solo.
- **Decisiones de autorización de IAM en todo el mundo** — en gran medida no se ven afectadas. El *data plane* de IAM — la evaluación de políticas cuando llega una petición — está replicado en cada Region y está diseñado para una disponibilidad extremadamente alta y estabilidad estática. Tu aplicación en ejecución sigue autenticando y autorizando durante un evento del control plane de IAM.

Esta distinción, control plane frente a data plane, es la lente más útil que existe para razonar sobre el blast radius en AWS. La regla de diseño que se sigue: **no hagas que tu camino de recuperación dependa de un control plane.** Un runbook cuyo primer paso es "crear un rol de IAM" falla exactamente cuando lo necesitás. Aprovisioná los roles de antemano, aprovisioná la capacidad de antemano, y mantené el failover en operaciones de data plane — esto es lo que AWS llama estabilidad estática.

**A7.3** — Ambas razones son reales:

1. **Latencia.** El endpoint global `sts.amazonaws.com` resuelve a `us-east-1`. Una aplicación en `ap-southeast-1` que lo llama paga un viaje de ida y vuelta de ~200 ms para obtener credenciales — en cada renovación de credenciales, y en el camino frío de cada invocación de Lambda que asume un rol. El endpoint regional está a unos pocos milisegundos.
2. **Aislamiento de fallos.** Llamar a un endpoint de `us-east-1` desde una carga de trabajo en `ap-southeast-1` crea una dependencia dura de una Region con la que tu carga de trabajo no tiene nada que ver. Un evento en `us-east-1` entonces tira abajo una aplicación que corre a 15.000 km, sin razón arquitectónica alguna. Los endpoints regionales de STS mantienen el grafo de dependencias dentro de la Region.

Hay una tercera razón, más silenciosa: los endpoints regionales escalan de manera independiente, así que no estás compartiendo un techo de throttling con el mundo entero.

**A7.4** —

| Recurso | Alcance | Límite que lo hace así |
|---|---|---|
| Hosted zones de Route 53 | **Global** | El DNS es inherentemente global; servido por servidores de nombres anycast en todo el mundo, control plane en `us-east-1` |
| Endpoints de Route 53 Resolver | **Regional** | Son ENIs en una subnet de una VPC — tienen direcciones IP en una AZ específica |
| Distribuciones de CloudFront | **Global** | Configuración replicada a todos los PoP; control plane y ARNs anclados en `us-east-1` |
| Nombres de bucket de S3 | **Global** (por partición) | El nombre es parte de un nombre de host DNS, y los nombres DNS deben ser únicos |
| Objetos de S3 | **Regional** | Los bytes viven en una Region, replicados entre sus AZ |
| Usuarios, roles y políticas de IAM | **Global** | Un almacén de identidad por cuenta, control plane en `us-east-1` |
| Key pairs de EC2 | **Regional** | Se guardan por Region; el mismo material de clave importado en dos Regions son dos recursos independientes |
| Certificados de ACM | **Regional**, con un caso especial | Ligados a la Region donde se emiten; un certificado para CloudFront **debe** estar en `us-east-1` |

**A7.5** — Porque el control plane de CloudFront vive en `us-east-1`, y CloudFront necesita leer el certificado para distribuirlo a cada edge location del mundo. El requisito es una filtración directa y visible de dónde está anclado CloudFront — la misma razón por la que los ARNs de CloudFront llevan un campo de región vacío pero se gestionan a través de `us-east-1`, la misma razón por la que las métricas de CloudWatch de CloudFront aparecen en `us-east-1`, y la misma razón por la que las Web ACL de WAF con alcance de CloudFront deben crearse con `--scope CLOUDFRONT --region us-east-1`.

La consecuencia práctica para un equipo que por lo demás está enteramente en `eu-central-1`: igual necesitás una huella en `us-east-1`, `us-east-1` debe estar habilitada, y tu IaC necesita un alias de proveedor secundario. Planificalo en lugar de descubrirlo durante un despliegue.

**A7.6** — Porque el nombre de un bucket de S3 es **parte de un nombre de host DNS**: `my-bucket.s3.us-east-1.amazonaws.com`. Los nombres DNS deben ser globalmente únicos, así que el namespace de buckets debe ser globalmente único — a lo largo de cada cuenta y cada Region de la partición. Por eso los nombres de bucket son efectivamente por orden de llegada y por eso los buenos nombres cortos se agotaron hace una década, y por eso los nombres de bucket deben ser compatibles con DNS (minúsculas, sin guiones bajos, de 3 a 63 caracteres).

Un tag `Name` de EC2 no es direccionable por URL. Es un par clave-valor arbitrario sobre un recurso que en realidad se identifica por un ID opaco generado por AWS, `i-0abc...`, único solo dentro de una Region. Nadie lo resuelve, así que nadie necesita que sea único. Regla general: **todo lo que aparece en un nombre de host necesita un namespace global; todo lo que se identifica por un ID opaco no.**

### Ejercicio 8

**A8.1** — El intento de escalar hacia esa AZ falla con `Unsupported` (o `InsufficientInstanceCapacity`, según la causa exacta). El Auto Scaling group reintenta, puede entrar en backoff, y — algo crítico — tu techo efectivo de capacidad es más bajo de lo que diseñaste mientras tu monitoreo muestra un ASG que "existe en tres AZ".

Las soluciones, en orden de preferencia: (a) seleccionar las AZ intersectando los conjuntos de oferta de cada tipo de instancia que pensás usar; (b) usar una **mixed instances policy** con varios tipos compatibles para que el ASG pueda sustituir; (c) usar una política de **Attribute-Based Instance Type Selection**, que expresa los requisitos como vCPU/memoria/arquitectura y deja que EC2 elija lo que haya disponible. La opción (c) es la respuesta moderna y es marcadamente más robusta frente a exactamente esta clase de fallo.

**A8.2** — Porque `availability-zone` devuelve nombres (`us-east-1a`), que se mapean por cuenta y por lo tanto no son comparables con nada fuera de tu cuenta ni estables como documentación. `availability-zone-id` devuelve `use1-az2`, que identifica la zona física sin ambigüedad. Si estás registrando "c7g se ofrece en estas zonas" en un documento de diseño, una página de wiki o una variable de Terraform compartida entre cuentas, el nombre es activamente engañoso — una segunda cuenta que lea `us-east-1a` lo va a resolver a una zona física distinta. Todo artefacto que cruce el límite de una cuenta debe usar AZ IDs.

**A8.3** — No predice la **capacidad en el momento del lanzamiento**. "Ofrecido" significa que la familia de hardware está desplegada en esa zona y la API va a aceptar la petición; no dice nada sobre si existe un slot de instancia libre a las 09:00 del lunes del lanzamiento de tu producto. `InsufficientInstanceCapacity` es un error real y ordinario contra una oferta perfectamente válida.

Las dos funcionalidades que garantizan capacidad son las **On-Demand Capacity Reservations** (reservar capacidad para un tipo de instancia específico en una AZ específica, facturada la uses o no) y los **Capacity Blocks for ML** (reservar capacidad de cómputo acelerado para una ventana futura definida). Notá que una *Reserved Instance* o un *Savings Plan* es un constructo de **facturación**, no una garantía de capacidad — con la excepción de una RI zonal, que sí lleva una reserva de capacidad. Esa distinción es relevante para el examen y también se malinterpreta con frecuencia en producción.

**A8.4** — El mismo principio que A4.1: **las Regions no son uniformes, y las Regions más grandes y más viejas reciben más de todo primero.** `us-east-1` recibe las familias de instancias nuevas, los servicios nuevos y las funcionalidades nuevas antes y con mayor variedad; las Regions más chicas reciben un subconjunto, más tarde. La consecuencia de diseño es que "funciona en `us-east-1`" no es evidencia de que funcione en ningún otro lado — la disponibilidad de tipos de instancia, de servicios, de funcionalidades y las cuotas por defecto deben verificarse cada una por Region antes de comprometerte con un destino de despliegue.

### Ejercicio 9

**A9.1** — En toda subnet de AWS hay cinco direcciones reservadas e inutilizables; para un `10.42.1.0/24`:

- `10.42.1.0` — la dirección de red.
- `10.42.1.1` — el router de la VPC (router implícito / gateway por defecto).
- `10.42.1.2` — el **servidor DNS provisto por Amazon**. Siempre es la base del CIDR de la VPC + 2, y también es alcanzable en la dirección link-local `169.254.169.253`. Es la dirección en la que responde el Route 53 Resolver.
- `10.42.1.3` — reservada por AWS para uso futuro.
- `10.42.1.255` — la dirección de broadcast. AWS no soporta broadcast en una VPC, pero la dirección se reserva igual.

256 − 5 = 251. Esto importa en el extremo chico: un `/28` (el más chico que AWS permite) tiene 16 direcciones y rinde solo 11 utilizables, lo cual es una restricción genuina cuando un servicio como un ALB o un NAT gateway también consume direcciones en la subnet.

**A9.2** —

- **Subnet:** una subnet vive en exactamente una AZ. Perdé la AZ y todos los recursos de esa subnet desaparecen — instancias inalcanzables, ENIs muertas, todo lo que esté alojado solo ahí queda caído.
- **VPC:** una VPC abarca todas las AZ de su Region y no se ve afectada como constructo. Sobrevive por completo a la pérdida de una AZ; es un objeto lógico con alcance de Region, no algo que corre en un centro de datos.
- **Route tables:** con alcance de Region, replicadas y no afectadas. Las rutas que apuntan *hacia* la AZ caída se convierten en agujeros negros para el tráfico destinado ahí — lo más visible es una subnet privada ruteando a través de un NAT gateway en la AZ caída, que pierde la salida aunque la subnet en sí esté sana. Por eso exactamente existe la regla de un NAT por AZ.

Resumen: **la AZ es el dominio de fallo; la VPC es el contenedor de alcance regional que sobrevive.** La disponibilidad viene de tener recursos en más de una subnet en más de una AZ, más una capa de balanceo de carga o DNS que deje de mandar tráfico a la que está muerta.

**A9.3** — Falla de manera silenciosa y asimétrica. Como `us-east-1a` mapea a una zona física distinta en cada cuenta, los dos despliegues aterrizan en hardware distinto. Síntomas: una carga de trabajo repartida entre dos cuentas (digamos, una VPC de servicios compartidos y una VPC de carga de trabajo conectadas por RAM o peering) que cree estar co-ubicada pero en realidad cruza AZ — pagás transferencia de datos entre AZ en ambas direcciones, agregás ~1 ms a cada salto, y ni la consola ni ningún mensaje de error te lo dicen. Peor todavía, una degradación de AZ afecta a las dos cuentas de forma distinta, así que tus entornos "idénticos" no fallan de manera idéntica, y tu prueba de DR en una cuenta no prueba nada sobre la otra.

La regla reescrita: **seleccioná zonas por `ZoneId`, derivado en el momento del despliegue desde `describe-availability-zones` y ordenado de forma determinista — nunca hardcodees `ZoneName`.**

**A9.4** — Con un único NAT Gateway en la AZ-1 sirviendo a las tres subnets privadas, la pérdida de la AZ-1 elimina el acceso saliente a internet para las tres AZ, incluidas las dos que están perfectamente sanas. Tus instancias sobrevivientes ya no pueden alcanzar S3 por el camino de internet, bajar imágenes de contenedor, llamar a APIs externas ni obtener actualizaciones del sistema operativo — un fallo de una sola AZ se convirtió en una caída de tu camino de salida a nivel de toda la Region. Esta es la forma más común en que una arquitectura "multi-AZ" resulta no serlo.

Los dos costos de hacerlo correctamente (un NAT Gateway por AZ, con cada subnet privada ruteando al de su propia AZ):

1. **El cargo por hora del NAT Gateway, multiplicado por tres** — pagás por hora de gateway por cada uno.
2. **El cargo por GB de procesamiento de datos**, que pagás además de la tarifa horaria por cada gigabyte que pasa por cada gateway.

También hay un costo de hacerlo *incorrectamente* que es fácil pasar por alto: rutear el tráfico de la AZ-2 a un NAT Gateway en la AZ-1 incurre cargos de transferencia de datos entre AZ además del cargo de procesamiento del NAT, así que el "ahorro" del gateway único es en parte ilusorio incluso antes del problema de disponibilidad. Un VPC gateway endpoint para S3 y DynamoDB es gratis y elimina por completo una porción grande del tráfico NAT — suele ser la primera optimización a hacer.

**A9.5** — Tenés tres subnets en tres dominios de fallo distintos y **cero disponibilidad**, porque no tenés nada corriendo. La huella de tres AZ es una **precondición** para la alta disponibilidad, no la alta disponibilidad en sí.

Lo que te da: el espacio de direcciones y la estructura de emplazamiento para distribuir recursos en dominios de fallo independientes, y la capacidad de hacerlo sin rediseñar la red más adelante.

Lo que no te da: capacidad en ejecución; ningún balanceador de carga distribuyendo tráfico; ningún health checking; ningún reemplazo automático de instancias caídas; ninguna replicación de datos; ningún margen de capacidad para absorber la carga de una AZ perdida (la pregunta del "N+1" — si cada una de las tres AZ corre al 50% y perdés una, las dos restantes necesitan absorber el 150% de su carga actual, cosa que no pueden). La HA real requiere la huella **más** capacidad redundante en ejecución, **más** una capa de ALB o de health checking de Route 53 que deje de mandar tráfico a la zona caída, **más** suficiente capacidad de reserva en las sobrevivientes — e idealmente estabilidad estática, es decir que las sobrevivientes ya estén aprovisionadas en vez de necesitar una llamada al control plane para escalar en el peor momento posible.

### Ejercicio 10

**A10.1** — Porque una **compuerta** es un binario pasa/no pasa que se evalúa *antes* de puntuar, y cualquier candidato que falle una compuerta queda eliminado de la comparación por completo. `us-east-1` falla la compuerta de residencia de datos, así que su precio y su amplitud de tipos de instancia nunca se pesan — no podés comprarte la salida de un requisito regulatorio con un descuento del 59%, y el regulador de la fintech no va a aceptar "era más barato" como mitigación.

Esta es la forma general de la elección de Region: **el cumplimiento y la residencia de datos son compuertas; la latencia, el costo y la amplitud de servicios son puntajes.** La disponibilidad de servicios suele ser una compuerta también, aunque a veces blanda (podés sustituir un servicio o alojarlo vos mismo, a un costo que se vuelve puntaje). Correr las compuertas primero también ahorra trabajo, porque en general reduce la lista de candidatos a uno o dos.

**A10.2** — Dos motores estructurales:

1. **Costos de insumos locales.** La electricidad es el costo operativo dominante de un centro de datos, y los precios industriales de la energía varían por un factor de tres o más entre, digamos, Virginia y São Paulo. Sumá tierra, construcción, requisitos de refrigeración determinados por el clima, mano de obra, tránsito de red de larga distancia — mucho más caro en Sudamérica y Australia que en el norte de Virginia — e impuestos y aranceles de importación sobre el hardware, que son sustanciales en Brasil en particular.
2. **Escala y utilización.** `us-east-1` es por amplio margen la Region más grande. Una escala enorme significa mejores compras de hardware, mayor utilización de la flota y costos fijos amortizados entre muchísimos más clientes. Una Region chica carga la misma base de energía redundante, personal y red sobre una fracción de los ingresos.

Consecuencias prácticas: poné precio siempre en la Region objetivo en lugar de asumir, y recordá que el precio de la transferencia de datos también varía por Region — la salida entre Regions desde `sa-east-1` es marcadamente más cara que desde `us-east-1`, lo que puede dominar la factura de una carga de trabajo intensiva en datos.

**A10.3** — **La latencia baja de peso** — una Region de DR no sirve usuarios en operación normal, así que unas decenas de milisegundos son irrelevantes — mientras que **el cumplimiento sigue siendo una compuerta absoluta** y **la disponibilidad de servicios sube**, porque la Region de DR debe soportar todos los servicios que usa la primaria o el failover no funciona.

El problema de la preselección es que Brasil tiene una sola Region de AWS. Así que, o bien:

- **Quedarse en `sa-east-1` y apoyarse en multi-AZ.** `sa-east-1` tiene tres AZ, que son dominios de fallo genuinamente independientes (energía, refrigeración, red e inundaciones separadas). Esto protege contra todo fallo salvo un evento de Region entera. Satisface la residencia perfectamente. Es lo que hacen en la práctica la mayoría de las cargas de trabajo reguladas brasileñas.
- **Agregar una segunda Region y conseguir la aprobación legal primero.** Si el regulador permite backups cifrados fuera de Brasil bajo condiciones especificadas, una segunda Region da DR real a nivel de Region. Los candidatos se evaluarían por `geolocationCountry` contra lo que el regulador permita.

El encuadre honesto para la revisión de diseño: una AZ es el límite de aislamiento para fallos de infraestructura; solo una Region es el límite de aislamiento para un evento de Region entera. Si la residencia prohíbe una segunda Region, tenés que declarar explícitamente que la pérdida de la Region completa es un riesgo aceptado — y conseguir que esa aceptación se firme en lugar de dejarla implícita.

**A10.4** — Uno de cada categoría:

- **Latencia.** Los usuarios fuera del este de EE. UU. pagan de 100 a 300 ms en cada viaje de ida y vuelta, lo que se compone a lo largo de una cadena de peticiones conversadora hasta convertirse en segundos de carga de página adicional. Para una base de usuarios brasileña, europea o asiática esta es la diferencia entre un producto usable y uno inusable.
- **Cumplimiento.** Los datos están en Estados Unidos, lo que los pone en el alcance del proceso legal estadounidense y fuera de cumplimiento con los requisitos de transferencia de datos del GDPR, las expectativas de residencia de la LGPD brasileña, y la mayoría de las regulaciones sectoriales de otros lados — a menudo sin que nadie haya tomado una decisión, porque "la Region por defecto" no es una decisión.
- **Blast radius.** `us-east-1` aloja los control planes globales de IAM, Route 53, CloudFront, Organizations y facturación, y es la Region más grande y más concurrida. Históricamente, los eventos de AWS con mayor impacto sobre clientes se originaron ahí, y las cargas de trabajo en `us-east-1` se ven afectadas tanto por el evento local *como* por la dependencia del control plane global. Estar en `us-east-1` correlaciona al máximo tu disponibilidad con la de todos los demás — incluidas tus dependencias SaaS de terceros, que están desproporcionadamente ahí también, de modo que tu degradación llega desde varias direcciones a la vez.

**A10.5** — Los cuatro pueden cambiar, y cada uno tiene un disparador realista:

- **Cumplimiento** — una ley nueva (GDPR, LGPD, una norma bancaria sectorial), un contrato nuevo con un cliente que incluye cláusula de residencia, o la entrada en un mercado nuevo. Esta es la migración forzada más común y la más cara, porque es una compuerta: fallarla significa mudarse, no optimizar.
- **Latencia / proximidad a los usuarios** — tu base de usuarios se desplaza, o AWS lanza una Region o Local Zone nueva más cerca de ella. Que abra una Region en un país donde tenés usuarios significativos es una razón real para reevaluar.
- **Disponibilidad de servicios** — un servicio del que ahora dependés llega a una Region que antes no lo tenía, desbloqueando una opción más barata o más cercana; o adoptás un servicio nuevo que todavía no está en tu Region actual, que es la dirección más común y más molesta.
- **Costo** — AWS cambia precios (típicamente a la baja, y de forma despareja entre Regions), o el perfil de tu carga de trabajo cambia de manera tal que domina otro componente de costo — una carga que se vuelve intensiva en salida se ve afectada por diferencias de precio de transferencia de datos que eran despreciables cuando era intensiva en cómputo.

La disciplina: registrá los cuatro factores y sus valores *en el momento de la decisión* en un architecture decision record, junto con la versión del conjunto de datos del ejercicio 4, para que un ingeniero futuro pueda determinar si el razonamiento sigue siendo válido o meramente sigue existiendo.

### Ejercicio 11

**A11.1** — **AWS Outposts**, en el factor de forma de rack o de servidor según la escala.

Que "el control plane se quede en la Region" les cuesta, durante una caída de la WAN: la imposibilidad de lanzar, detener, terminar o modificar cualquier instancia; la imposibilidad de crear, redimensionar o snapshotear volúmenes EBS; la pérdida de la entrega de métricas de CloudWatch y, por lo tanto, de las alarmas; una consola que muestra estado desactualizado y rechaza acciones mutantes; y — la que más duele — **nada de escalado**. Si la carga sube durante la caída, no escala nada.

Lo que sigue funcionando: las instancias en ejecución, la E/S local de EBS, la red local del Outpost, y cualquier instancia de servicio local ya en ejecución. Las reglas de diseño que se siguen son las mismas que aplicarías a cualquier sistema tolerante a particiones: **aprovisioná capacidad de antemano para el pico, no para el promedio** (estabilidad estática); evitá diseños que necesiten una llamada al control plane en el camino crítico; mantené el camino de datos local libre de dependencias del lado de la Region; y probá el modo particionado deliberadamente, porque es el modo del que realmente depende tu caso de cumplimiento.

**A11.2** — **Local Zone**, y el hecho que decide es **cómo se conectan los usuarios finales**. Una Local Zone sirve a cualquiera en el área metropolitana de Los Ángeles alcanzable por internet común — cualquier ISP, cualquier dispositivo, fijo o móvil. Una Wavelength Zone está *dentro de la red 5G de una operadora móvil específica* y entrega su beneficio de latencia solo a dispositivos conectados a la red de radio 5G de esa operadora; un usuario en Wi-Fi, en una línea fija, o en otra operadora no obtiene beneficio alguno y puede quedar peor.

Entonces: público general en una metrópolis → Local Zone. Dispositivos en el 5G de una sola operadora, donde el tráfico nunca necesita salir de esa operadora → Wavelength Zone. Para una empresa de video en vivo que sirve a espectadores en general, Wavelength sería una apuesta angosta y frágil a la conexión con una operadora.

**A11.3** — Porque cada uno de ellos es una **extensión de una Region padre y comparte el control plane de esa Region**. Un evento del control plane a nivel de Region degrada la Local Zone, la Wavelength Zone y el Outpost junto con la Region misma — perdés la capacidad de lanzar, modificar o recuperar recursos en la extensión exactamente cuando lo necesitás. Más allá del control plane, dependen de la Region para la mayoría de los servicios: las extensiones ejecutan un subconjunto chico (EC2, EBS, algunos pocos más), así que casi cualquier aplicación real en una de ellas llama de vuelta a la Region padre para S3, DynamoDB, RDS, Lambda, Secrets Manager o autenticación, y esas llamadas fallan con la Region.

Tampoco están construidos para eso: una Local Zone es típicamente una sola instalación sin redundancia propia a nivel de AZ, así que es una ubicación *menos* resiliente que la Region, no más. **El único destino de DR para una Region es otra Region.**

**A11.4** — Una **Dedicated Local Zone** es una Local Zone construida para un único cliente o una comunidad definida (típicamente un gobierno o un organismo de una industria regulada), ubicada en un lugar que ese cliente especifica, con infraestructura física y lógicamente dedicada a él en lugar de compartida con la base general de clientes de AWS. Puede llevar controles adicionales: acceso físico restringido, requisitos de investigación de antecedentes del personal, procedimientos operativos definidos por el cliente, y garantías duras sobre qué corre en el hardware.

Lo que satisface y una Local Zone estándar no: requisitos sobre **de quién más son las cargas de trabajo que comparten la infraestructura** y **quién puede acceder a ella física o lógicamente**. Una Local Zone estándar es infraestructura multi-tenant de AWS en una metrópolis — la residencia de datos es correcta, pero un requisito de seguridad nacional o de nube soberana puede prohibir la tenencia compartida o exigir personal verificado localmente. Una Dedicated Local Zone atiende la tenencia y la soberanía operativa; una estándar atiende solo latencia y geografía. (Este es un concepto distinto de la AWS European Sovereign Cloud, que es una construcción separada, operada de forma independiente y a escala de Region, no una extensión de Region.)

**A11.5** — **AWS extiende su infraestructura empujando el data plane hacia afuera mientras mantiene el control plane en la Region.** La Region es el núcleo durable, redundante y multi-AZ donde viven el estado, la orquestación y la superficie de API; todo lo de afuera — extensiones de AZ, Local Zones, Wavelength Zones, Outposts, edge locations — es una proyección de ese núcleo hacia el usuario, que lleva cómputo o caché pero nunca la autoridad.

Este único principio predice casi todo en este tema: por qué un Outpost no puede lanzar instancias durante una caída de la WAN; por qué una Local Zone no es un destino de DR; por qué una edge location no tiene VPC ni base de datos; por qué un certificado de ACM para CloudFront debe vivir en `us-east-1`; por qué una llamada a IAM hecha con `--region sa-east-1` se firma para `us-east-1`. Aprendé el principio y podés derivar el resto en lugar de memorizarlo.

</details>