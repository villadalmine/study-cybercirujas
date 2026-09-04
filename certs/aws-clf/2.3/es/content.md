# 2.3 — Identificar las capacidades de gestión de acceso de AWS

**Certificación:** AWS Certified Cloud Practitioner (CLF-C02) · Dominio 2: Seguridad y cumplimiento · Task Statement 2.3
**Peso en el examen:** 7.5
**Perfil de audiencia:** SRE / Arquitecto de Plataforma. Este módulo va más allá de "IAM tiene usuarios y roles" y entra en el pipeline de autorización de peticiones, los ciclos de vida de las credenciales, las topologías de federación y el procedimiento de diagnóstico que ejecutás a las 03:00 cuando una carga de trabajo en producción empieza a devolver `AccessDenied`.

---

## 1. El problema en producción

La gestión de acceso es el único plano de control en AWS del que dependen todos los demás planos de control. Las fallas de red son localizadas; una identidad mal configurada es global y silenciosa.

Consideremos una plataforma realista: tres cuentas de AWS (`shared-services`, `prod`, `dev`) bajo una AWS Organization, un clúster EKS en `prod` corriendo 40 microservicios, un sistema de CI que despliega, un equipo de datos que consulta, y un auditor de cumplimiento que debe ver todo y no cambiar nada.

Los modos de falla que realmente ocurren con esta forma:

| Modo de falla | Mecanismo | Radio de impacto |
|---|---|---|
| Clave de acceso de larga duración commiteada a un repositorio público | Credencial estática `AKIA...`, nunca expira | Permisos completos de la identidad asociada, hasta que se revoque manualmente |
| Usuario root con una clave de acceso | Root evita por completo las políticas de identidad de IAM | Compromiso total de la cuenta; las SCP no restringen al root de la cuenta de gestión |
| `"Action": "*"` en un rol de depuración "temporal" | Nadie lo elimina; Access Advisor lo muestra sin uso desde hace 400 días | Ruta de movimiento lateral |
| Confianza de rol entre cuentas con `"Principal": {"AWS": "*"}` | Confused deputy; cualquiera en el planeta puede asumirlo | Exfiltración de datos desde S3/DynamoDB |
| El Pod hereda el instance profile del nodo EC2 | Sin IRSA/Pod Identity; el contenedor alcanza IMDS | Todos los pods del nodo tienen los permisos del nodo |
| Identidades humanas gestionadas como usuarios IAM por cuenta | 3 cuentas × 60 ingenieros = 180 identidades, 180 políticas de contraseñas para auditar | La baja de personal es un barrido manual y propenso a errores |

Cada uno de estos se previene con una capacidad de AWS específica y examinable. El objetivo arquitectónico es una sola afirmación:

> **Ningún humano y ninguna carga de trabajo debería jamás tener una credencial que (a) no expire, (b) sea más amplia que la tarea actual, o (c) no pueda rastrearse hasta un principal con nombre en CloudTrail.**

Todo lo que sigue es la maquinaria que hace que esa afirmación sea exigible en lugar de aspiracional.

---

## 2. El modelo de identidad: principals, credenciales y el contexto de la petición

### 2.1 Anatomía de una petición autorizada

Cada llamada a la API de AWS — clic en la consola, llamada del SDK, `kubectl` contra EKS, `GetObject` de S3 — es una petición HTTPS firmada con **SigV4** y evaluada de forma idéntica:

```
┌────────────────────────────────────────────────────────────────────────┐
│ 1. AUTHENTICATION                                                      │
│    Signature (SigV4) over: credential scope, canonical request, date   │
│    Resolves the caller to a PRINCIPAL:                                 │
│      arn:aws:iam::111122223333:user/alice                              │
│      arn:aws:sts::111122223333:assumed-role/payments-api/i-0abc123     │
│      arn:aws:iam::111122223333:root                                    │
├────────────────────────────────────────────────────────────────────────┤
│ 2. REQUEST CONTEXT is assembled                                        │
│    action  = s3:GetObject                                              │
│    resource= arn:aws:s3:::prod-ledger/2026/09/tx.parquet               │
│    context = aws:SourceIp, aws:PrincipalTag/team, aws:PrincipalOrgID,  │
│              aws:MultiFactorAuthPresent, aws:RequestedRegion,          │
│              aws:SecureTransport, aws:VpcSourceIp, aws:userid …        │
├────────────────────────────────────────────────────────────────────────┤
│ 3. AUTHORIZATION — policy evaluation (Section 5)                       │
├────────────────────────────────────────────────────────────────────────┤
│ 4. CloudTrail event emitted regardless of allow/deny                   │
└────────────────────────────────────────────────────────────────────────┘
```

Dos consecuencias que un SRE debe internalizar:

- **Un deny queda registrado.** `AccessDenied` siempre produce un evento de CloudTrail con `errorCode`. La ausencia de un evento de CloudTrail significa que la petición nunca llegó a AWS (DNS, proxy, red) — no que fue denegada.
- **IAM es global y de consistencia eventual.** Una política asociada en `us-east-1` se propaga en segundos, pero la lógica de reintentos debe tolerar una breve ventana en la que un rol recién creado todavía no es asumible. Nunca construyas un pipeline de despliegue que cree un rol y lo asuma inmediatamente sin reintentos.

### 2.2 Taxonomía de credenciales

| Credencial | Emitida a | Duración | Rotable | A dónde pertenece |
|---|---|---|---|---|
| Email + contraseña de root | Usuario root de la cuenta | Permanente | Manual | Guardada bajo llave en una bóveda de emergencia, MFA por hardware |
| Contraseña de consola | Usuario IAM | Permanente (rotación forzada por política) | Sí | Solo donde Identity Center no esté disponible |
| ID de clave de acceso / secreto (`AKIA…`) | Usuario IAM | **Nunca expira** | Manual (rotación de 2 claves) | Solo integraciones on-premise heredadas |
| Credenciales temporales (`ASIA…` + token de sesión) | Sesión de rol (STS) | 15 min – 12 h | Reemisión automática | **Por defecto para todo** |
| Sesión de IAM Identity Center | Humano federado | Hasta 12 h de sesión de rol / sesión SSO configurable | Automática | Todo acceso humano |
| Credenciales de instance profile | Instancia EC2 | Rotadas automáticamente por el servicio | Automática | Cargas de trabajo EC2 |
| Token de IRSA / EKS Pod Identity | ServiceAccount de Kubernetes | Token proyectado de ~15 min → sesión STS de 1 h | Automática | Cargas de trabajo en contenedores |
| Credenciales de identity pool de Cognito | Usuario final de tu aplicación | Hasta 12 h | Automática | Usuarios de apps móviles/web, **no** empleados |

El prefijo `ASIA` vs `AKIA` es un atajo de diagnóstico en campo: si una clave filtrada empieza con `AKIA`, es permanente y el incidente es grave; `ASIA` expira por sí sola.

---

## 3. El usuario root: la única identidad que no podés arreglar después

El usuario root no es "un admin con más permisos" — es un principal estructuralmente diferente:

- **No está gobernado por políticas de identidad de IAM**. No podés asociar una política a root para restringirlo.
- En la **cuenta de gestión**, las SCP no restringen al usuario root.
- Es el único principal que puede realizar un conjunto fijo de tareas.

**Tareas que requieren el usuario root (lista crítica para el examen):**

| Tarea | Por qué root |
|---|---|
| Cambiar el nombre de la cuenta, la dirección de email o la contraseña de root | Atributo a nivel de cuenta |
| Cambiar o cancelar el plan de AWS Support | Operación de nivel de facturación |
| Cerrar la cuenta de AWS | Operación de cuenta irreversible |
| Restaurar permisos de usuarios IAM después de que un admin deje a todos afuera | Break-glass |
| Registrarse como vendedor en el Reserved Instance Marketplace | Comercial |
| Habilitar MFA delete en un bucket de S3 / configurar MFA delete en el versionado de un bucket de S3 | Ruta de API exclusiva de root |
| Editar una política de bucket de S3 o una política de SQS que contenga un principal inválido/huérfano | Solo root puede reparar el bloqueo |
| Registrarse en GovCloud | Aprovisionamiento de cuenta |

**El procedimiento de endurecimiento — memorizá el orden:**

1. Habilitar **MFA en el usuario root**, preferentemente una llave de seguridad por hardware FIDO2. (IAM admite hasta **8 dispositivos MFA por usuario**, así que registrá una llave principal y una de respaldo guardada en bóveda.)
2. **Eliminar todas las claves de acceso de root.** Una clave de acceso de root es una credencial ilimitada, sin expiración y no restringible. No existe una arquitectura legítima que requiera una.
3. Establecer una contraseña de root larga y única, almacenada en una bóveda física o de secretos empresarial.
4. Asociar un alias de email monitoreado (una lista de distribución, no una persona que pueda irse).
5. Crear una regla de EventBridge sobre CloudTrail para `userIdentity.type = Root` y que dispare una alerta de guardia.
6. En AWS Organizations, habilitar la **gestión centralizada de acceso root** para eliminar por completo las credenciales root de las cuentas miembro, y usar sesiones root privilegiadas solo para las tareas de reparación específicas que las requieran.

```bash
$ aws iam get-account-summary --query 'SummaryMap.{RootMFA:AccountMFAEnabled,RootKeys:AccountAccessKeysPresent}'
{
    "RootMFA": 1,
    "RootKeys": 0
}
```

`RootMFA: 1` y `RootKeys: 0` es la única salida aceptable. Cualquier otra cosa es un hallazgo P1.

---

## 4. Usuarios, grupos, roles: qué es realmente cada uno

| | Usuario IAM | Grupo IAM | Rol IAM |
|---|---|---|---|
| Representa | Una identidad permanente con sus propias credenciales | Un **contenedor para asociar políticas** — no una identidad | Un conjunto de permisos que se **asume** temporalmente |
| ¿Tiene credenciales? | Sí (contraseña y/o claves de acceso) | **No** — un grupo nunca puede ser un principal | Sin credenciales permanentes; STS emite unas temporales |
| ¿Puede referenciarse en un bloque `Principal`? | Sí | **No** | Sí |
| Anidamiento | — | **Los grupos no pueden anidarse** | Los roles pueden encadenarse (sesión máx. 1 h) |
| Límite (por defecto) | 5.000 por cuenta | 300 por cuenta; 10 grupos por usuario | 1.000 por cuenta |
| Uso típico | Integraciones heredadas, break-glass | Agrupar humanos por función laboral | **Todo lo demás** |
| Riesgo de ciclo de vida | Las credenciales sobreviven al empleo | Ninguno | La sesión expira automáticamente |

Un **rol** tiene dos políticas, y confundirlas es el error de IAM más común de todos:

- **Política de confianza** (`AssumeRolePolicyDocument`) — *quién puede asumir el rol*. Es una política basada en recursos sobre el propio rol; su elemento `Principal` es obligatorio.
- **Política de permisos** — *qué puede hacer el rol una vez asumido*.

Un `AccessDenied` sobre `sts:AssumeRole` es un problema de **política de confianza**. Un `AccessDenied` sobre `s3:GetObject` después de asumir con éxito es un problema de **política de permisos**. Esa sola distinción resuelve la mayoría de los incidentes en menos de un minuto.

**Casos de uso de roles (todos examinables):**

| Caso de uso | Principal de la política de confianza | API de STS |
|---|---|---|
| Una instancia EC2 necesita acceso a S3 | `ec2.amazonaws.com` | Interna (instance profile) |
| Función Lambda | `lambda.amazonaws.com` | Interna |
| Acceso entre cuentas | `arn:aws:iam::111122223333:root` (+ `ExternalId`) | `sts:AssumeRole` |
| Proveedor SaaS de terceros | ARN de la cuenta del proveedor + **`sts:ExternalId` obligatorio** | `sts:AssumeRole` |
| IdP SAML corporativo (Okta, Entra ID, ADFS) | `arn:aws:iam::…:saml-provider/Okta` | `sts:AssumeRoleWithSAML` |
| IdP OIDC (GitHub Actions, EKS IRSA) | `arn:aws:iam::…:oidc-provider/…` | `sts:AssumeRoleWithWebIdentity` |
| Usuarios finales de apps móviles/web | `cognito-identity.amazonaws.com` | `sts:AssumeRoleWithWebIdentity` |
| EKS Pod Identity | `pods.eks.amazonaws.com` | `sts:AssumeRole` + `sts:TagSession` |

---

## 5. Tipos de políticas y el algoritmo de evaluación

### 5.1 Los siete tipos de políticas

| Tipo | Se asocia a | ¿Otorga permisos? | Alcance |
|---|---|---|---|
| **Basada en identidad** (gestionada o inline) | Usuario, grupo, rol | **Sí** | Qué puede hacer este principal |
| **Basada en recursos** (p. ej. política de bucket de S3, política de clave KMS, política de SQS/SNS, política de recursos de Lambda) | El recurso | **Sí** (y habilita el acceso entre cuentas sin una política de identidad en algunos flujos) | Quién puede tocar este recurso; tiene un elemento `Principal` |
| **Permissions boundary** | Usuario o rol | **No — solo limita** | Permisos máximos que un principal puede llegar a tener |
| **Service control policy (SCP)** | OU o cuenta (Organizations) | **No — solo limita** | Permisos máximos para los *principals* de la cuenta |
| **Resource control policy (RCP)** | OU o cuenta (Organizations) | **No — solo limita** | Permisos máximos sobre los *recursos* de la cuenta, sin importar quién llame |
| **Política de sesión** | Pasada al momento del `AssumeRole` | **No — solo limita** | Acota una sola sesión |
| **ACL** (S3 heredado, solo entre cuentas) | Bucket/objeto de S3, VPC | Sí (heredado) | Evitar; usar políticas de bucket |

El modelo mental crítico: **solo las políticas basadas en identidad y las basadas en recursos otorgan. Todo lo demás es un techo.** Una permissions boundary con `AdministratorAccess` no otorga nada por sí sola.

### 5.2 Lógica de evaluación

```
                      ┌─────────────────────────┐
   Request context →  │  Any EXPLICIT DENY?     │── yes ──► DENY (final)
                      └───────────┬─────────────┘
                                  │ no
                      ┌───────────▼─────────────┐
                      │  SCP allows? (if org)   │── no ──► DENY
                      └───────────┬─────────────┘
                      ┌───────────▼─────────────┐
                      │  RCP allows? (if org)   │── no ──► DENY
                      └───────────┬─────────────┘
                      ┌───────────▼─────────────┐
                      │ Resource-based policy   │── allows principal ──► ALLOW*
                      └───────────┬─────────────┘
                      ┌───────────▼─────────────┐
                      │ Permissions boundary    │── no ──► DENY
                      │   allows?               │
                      └───────────┬─────────────┘
                      ┌───────────▼─────────────┐
                      │ Session policy allows?  │── no ──► DENY
                      └───────────┬─────────────┘
                      ┌───────────▼─────────────┐
                      │ Identity-based allows?  │── no ──► DENY (implicit)
                      └───────────┬─────────────┘
                                  ▼  ALLOW

*Same account: a resource-based policy naming the principal is sufficient on its own.
 Cross account: BOTH the identity policy (caller's account) AND the resource policy
 (resource's account) must allow. Two locks, two keys.
```

Tres reglas que responden la mayoría de las preguntas del examen:

1. **Un `Deny` explícito siempre gana**, desde cualquier tipo de política, en cualquier capa.
2. **Por defecto hay denegación implícita.** La ausencia de un allow es un deny.
3. **Entre cuentas = ambos lados deben permitir.** Sin excepciones que valga la pena memorizar a este nivel.

### 5.3 Anatomía de una declaración de política

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadLedgerObjectsFromCorpNetworkWithMFA",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion"
      ],
      "Resource": "arn:aws:s3:::prod-ledger/team/${aws:PrincipalTag/team}/*",
      "Condition": {
        "Bool":        { "aws:MultiFactorAuthPresent": "true" },
        "IpAddress":   { "aws:SourceIp": ["203.0.113.0/24", "198.51.100.0/24"] },
        "StringEquals":{ "aws:PrincipalOrgID": "o-a1b2c3d4e5" },
        "NumericLessThan": { "aws:MultiFactorAuthAge": "3600" }
      }
    }
  ]
}
```

`"Version": "2012-10-17"` es una **versión del lenguaje de políticas**, no una fecha que puedas editar. Cambiarla desactiva silenciosamente las variables de política como `${aws:PrincipalTag/team}`.

### 5.4 Políticas gestionadas vs inline

| | Gestionada por AWS | Gestionada por el cliente | Inline |
|---|---|---|---|
| Escrita por | AWS | Vos | Vos |
| Reutilizable entre principals | Sí | Sí | **No — 1:1 con la identidad** |
| Versionado / rollback | AWS las actualiza | **Hasta 5 versiones, con rollback soportado** | Ninguno |
| Se elimina cuando se elimina la identidad | No | No | **Sí** |
| Uso típico | Bootstrapping, `ReadOnlyAccess`, roles de servicio | **Valor por defecto en producción** | Acoplamiento estricto 1:1 que nunca querés reutilizar |

Las políticas gestionadas por AWS derivan: AWS les agrega acciones con el tiempo. `PowerUserAccess` y `ReadOnlyAccess` son cómodas e imprecisas; en un entorno regulado, fijá políticas gestionadas por el cliente que vos controles.

---

## 6. Mínimo privilegio, en la práctica

"Mínimo privilegio" no es una política que escribís una vez; es un bucle:

```
grant broad in dev  →  observe with Access Advisor / CloudTrail
                    →  generate a scoped policy (IAM Access Analyzer policy generation)
                    →  apply as customer-managed policy
                    →  enforce a permissions boundary so it cannot re-widen
                    →  re-audit unused access findings quarterly
```

### 6.1 Permissions boundaries — delegación segura

El problema: querés que los equipos de aplicación creen sus propios roles IAM (autoservicio), pero un equipo podría crear un rol con `AdministratorAccess` y asumirlo — una ruta de escalada de privilegios.

La boundary lo resuelve: el rol de desarrollador puede crear roles **solo si** les asocia una boundary específica, y la boundary limita los permisos efectivos de todo lo que creen.

Permisos efectivos = **política de identidad ∩ permissions boundary**.

### 6.2 RBAC vs ABAC

| | RBAC (un rol por función laboral) | ABAC (basado en atributos) |
|---|---|---|
| Mecanismo | Un rol/política por equipo o función | Una política que usa `aws:PrincipalTag` vs `aws:ResourceTag` |
| Escalabilidad | La cantidad de políticas crece con equipos × entornos | **Constante** — una política cubre todos los equipos |
| Alta de un equipo nuevo | Crear rol + política + asignación | Etiquetar la identidad y los recursos; nada que escribir |
| Auditabilidad | Explícita, fácil de leer | Requiere etiquetado confiable; más difícil de razonar |
| Prerrequisito | Ninguno | **Hay que hacer cumplir la gobernanza de etiquetas** (tag policies, condiciones `aws:RequestTag`) |
| Modo de falla | Proliferación de políticas, roles obsoletos | Un recurso sin etiquetar o mal etiquetado cambia el acceso silenciosamente |
| Veredicto | Por defecto para organizaciones chicas y para rutas privilegiadas/break-glass | Por defecto para plataformas multi-tenant grandes con etiquetado maduro |

Declaración ABAC canónica:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ABACSameTeamEC2Control",
      "Effect": "Allow",
      "Action": ["ec2:StartInstances", "ec2:StopInstances", "ec2:RebootInstances"],
      "Resource": "arn:aws:ec2:*:*:instance/*",
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/team": "${aws:PrincipalTag/team}",
          "aws:ResourceTag/env":  "${aws:PrincipalTag/env}"
        }
      }
    },
    {
      "Sid": "DenyUntaggedLaunch",
      "Effect": "Deny",
      "Action": "ec2:RunInstances",
      "Resource": "arn:aws:ec2:*:*:instance/*",
      "Condition": {
        "Null": { "aws:RequestTag/team": "true" }
      }
    }
  ]
}
```

---

## 7. Federación e IAM Identity Center

### 7.1 Por qué los usuarios IAM pierden

Con N cuentas y M ingenieros, los usuarios IAM requieren N×M identidades, N políticas de contraseñas, N pasos de baja y N inscripciones de MFA. La federación lo convierte en M identidades en un solo directorio y cero credenciales en AWS.

### 7.2 Comparación de opciones

| Capacidad | Usuarios IAM | IAM Identity Center | Federación SAML 2.0 directa a IAM | Amazon Cognito |
|---|---|---|---|---|
| Sujeto previsto | Cargas de trabajo/heredado | **Fuerza laboral (empleados)** | Fuerza laboral (patrón previo a Identity Center) | **Usuarios finales de la aplicación (clientes)** |
| Fuente de identidad | AWS | Directorio integrado, AD o IdP externo (Okta, Entra ID, Ping) | IdP externo | User pools, IdP sociales, SAML/OIDC |
| Credenciales en AWS | Permanentes | **Ninguna** — solo temporales | Ninguna | Ninguna |
| Multi-cuenta | Usuarios por cuenta | **Nativo**, vía permission sets | Rol + configuración de confianza por cuenta | N/A |
| Experiencia de CLI | Claves estáticas en `~/.aws/credentials` | `aws sso login` → sesión SSO con refresco automático | Scripting a medida | N/A |
| Escala a 10k usuarios | Pobre | Excelente | Buena | Excelente (millones) |
| MFA | Por usuario, manual | Aplicado centralmente; soporta passkeys/FIDO2 | Delegado al IdP | Integrado |
| Palabra clave del examen | "long-term credentials" | "**centrally manage access to multiple AWS accounts**" | "existing corporate directory" | "**sign-up and sign-in for your web/mobile app**" |

La discriminación de mayor valor en el examen: **Identity Center = tus empleados a través de las cuentas de AWS. Cognito = tus clientes usando tu aplicación.**

### 7.3 Cómo se materializa un permission set

Un **permission set** de IAM Identity Center es una plantilla. Cuando asignás `{permission set} × {cuenta} × {grupo}`, Identity Center aprovisiona un rol IAM real en esa cuenta con el nombre:

```
AWSReservedSSO_PlatformEngineer_9f0e1d2c3b4a5678
```

La política de confianza de ese rol apunta al proveedor SAML de Identity Center. Esto importa operativamente: esos ARN de rol no son determinísticos, así que **nunca los escribas de forma fija** en políticas de bucket o de claves KMS. En su lugar, hacé match por path o por etiqueta:

```json
{
  "Sid": "AllowIdentityCenterRolesByPath",
  "Effect": "Allow",
  "Principal": { "AWS": "arn:aws:iam::111122223333:root" },
  "Action": "s3:GetObject",
  "Resource": "arn:aws:s3:::prod-ledger/*",
  "Condition": {
    "ArnLike": {
      "aws:PrincipalArn": "arn:aws:iam::111122223333:role/aws-reserved/sso.amazonaws.com/*/AWSReservedSSO_DataReader_*"
    }
  }
}
```

### 7.4 Capacidades de MFA

| Tipo de MFA | Resistente a phishing | Usar para |
|---|---|---|
| Llave de seguridad FIDO2 / passkey | **Sí** | Root, break-glass, todo acceso privilegiado |
| Token TOTP por hardware | No | Operadores air-gapped |
| MFA virtual (app autenticadora) | No | Línea base para todos los usuarios |
| SMS | No (obsoleto) | No usar |

Hacelo cumplir con una condición, no con un documento de política que simplemente lo recomiende:

```json
{
  "Sid": "DenyAllExceptSelfServiceUnlessMFA",
  "Effect": "Deny",
  "NotAction": [
    "iam:CreateVirtualMFADevice", "iam:EnableMFADevice",
    "iam:ListMFADevices", "iam:ListVirtualMFADevices",
    "iam:ResyncMFADevice", "iam:GetUser", "sts:GetSessionToken"
  ],
  "Resource": "*",
  "Condition": {
    "BoolIfExists": { "aws:MultiFactorAuthPresent": "false" }
  }
}
```

`BoolIfExists` — no `Bool` — es obligatorio, de lo contrario las llamadas vinculadas a servicios donde la clave está ausente se deniegan incorrectamente.

---

## 8. Identidad de cargas de trabajo

### 8.1 Instance profiles de EC2 e IMDSv2

Una instancia EC2 nunca almacena una clave. Obtiene sus credenciales del **Instance Metadata Service**. IMDSv1 era un simple GET, lo que convertía cualquier vulnerabilidad SSRF de tu aplicación en una primitiva de robo de credenciales. **IMDSv2** requiere un token de sesión obtenido con un `PUT` que lleva una cabecera, algo que SSRF no puede falsificar, más un límite de saltos (hop limit) que impide que los contenedores del host lo alcancen.

```bash
# IMDSv1 (legacy — must be disabled)
$ curl http://169.254.169.254/latest/meta-data/iam/security-credentials/
<html><body><b>401 - Unauthorized</b></body></html>

# IMDSv2
$ TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
$ curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/iam/security-credentials/
payments-api-instance-role
$ curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/iam/security-credentials/payments-api-instance-role
{
  "Code" : "Success",
  "LastUpdated" : "2026-09-03T04:12:07Z",
  "Type" : "AWS-HMAC",
  "AccessKeyId" : "ASIAIOSFODNN7EXAMPLE",
  "SecretAccessKey" : "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
  "Token" : "IQoJb3JpZ2luX2VjEJr//////////wEaCXVzLWVhc3QtMSJHMEUC...TRUNCATED",
  "Expiration" : "2026-09-03T10:37:44Z"
}
```

Fijate en el prefijo `ASIA` y en `Expiration` — ese es todo el punto.

### 8.2 La cadena de proveedores de credenciales del SDK

El orden importa cuando diagnosticás "funciona en mi laptop pero no en producción":

1. Parámetros explícitos en el código
2. Variables de entorno (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`)
3. Archivo de token de identidad web (`AWS_WEB_IDENTITY_TOKEN_FILE` — **esto es IRSA**)
4. Archivos compartidos de config/credenciales (`~/.aws/credentials`, `~/.aws/config`, incluyendo perfiles `sso_session`)
5. Credenciales de contenedor (`AWS_CONTAINER_CREDENTIALS_FULL_URI` — **task roles de ECS y EKS Pod Identity**)
6. Instance profile de EC2 vía IMDS

Un `AWS_ACCESS_KEY_ID` obsoleto en el bloque env de un Deployment supera silenciosamente a IRSA. Revisá el paso 2 primero, siempre.

### 8.3 EKS: IRSA vs Pod Identity

| | IRSA (IAM Roles for Service Accounts) | EKS Pod Identity |
|---|---|---|
| Mecanismo | Proveedor OIDC + `sts:AssumeRoleWithWebIdentity` | DaemonSet `eks-pod-identity-agent` + `sts:AssumeRole` |
| Principal de la política de confianza | `arn:aws:iam::…:oidc-provider/oidc.eks.<region>.amazonaws.com/id/<ID>` | `pods.eks.amazonaws.com` |
| Configuración IAM por clúster | **Un proveedor OIDC por clúster** | Ninguna — reutilizable entre clústeres |
| Entre cuentas | Nativo | Soportado vía encadenamiento de roles |
| Reutilización del rol entre clústeres | Requiere editar la política de confianza por clúster | **La política de confianza es agnóstica al clúster** |
| Etiquetas de sesión | No | **Sí** — clúster/namespace/SA disponibles para ABAC |
| Dónde vive el mapeo | Anotación del ServiceAccount (en el clúster) | Asociación en la API de EKS (en AWS) |
| Veredicto | Clústeres existentes, paridad OIDC entre nubes | **Por defecto para clústeres nuevos** — menos objetos IAM, escala linealmente |

Ambos eliminan el antipatrón de que los pods hereden el rol del nodo. Hacelo cumplir con un hop limit de 1 en la configuración de IMDS del nodo.

---

## 9. Infraestructura completa: CloudFormation

Una plantilla desplegable y sintácticamente válida que cubre las primitivas de identidad de este task statement.

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  Baseline access-management stack for CLF-C02 Task 2.3.
  Creates: a delegated-admin permissions boundary, a self-service developer role,
  a cross-account auditor role with ExternalId, an EC2 instance profile scoped by
  tag, an EKS IRSA role, and an Access Analyzer. No IAM users are created.

Parameters:
  OrgId:
    Type: String
    Description: AWS Organizations ID used to fence principals.
    AllowedPattern: '^o-[a-z0-9]{10,32}$'
    Default: o-a1b2c3d4e5
  AuditorAccountId:
    Type: String
    Description: Account ID of the third-party auditor.
    AllowedPattern: '^[0-9]{12}$'
    Default: '444455556666'
  AuditorExternalId:
    Type: String
    NoEcho: true
    Description: Shared secret that defeats the confused-deputy problem.
    MinLength: 16
  EksOidcProviderUrl:
    Type: String
    Description: EKS cluster OIDC issuer WITHOUT the https:// scheme.
    Default: oidc.eks.us-east-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B716D3041E
  DataBucketName:
    Type: String
    Default: prod-ledger-111122223333

Resources:

  ##########################################################################
  # 1. Permissions boundary — the ceiling for every self-service identity
  ##########################################################################
  DeveloperPermissionsBoundary:
    Type: AWS::IAM::ManagedPolicy
    Properties:
      ManagedPolicyName: platform-developer-boundary
      Description: Maximum permissions any self-service created principal may hold.
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: AllowedServiceSurface
            Effect: Allow
            Action:
              - 's3:*'
              - 'dynamodb:*'
              - 'logs:*'
              - 'sqs:*'
              - 'lambda:*'
              - 'ec2:Describe*'
              - 'cloudwatch:*'
              - 'xray:*'
            Resource: '*'
          - Sid: DenyPrivilegeEscalationPaths
            Effect: Deny
            Action:
              - 'iam:CreateUser'
              - 'iam:CreateAccessKey'
              - 'iam:DeleteRolePermissionsBoundary'
              - 'iam:PutUserPermissionsBoundary'
              - 'iam:AttachUserPolicy'
              - 'organizations:*'
              - 'account:*'
            Resource: '*'
          - Sid: DenyBoundaryTampering
            Effect: Deny
            Action:
              - 'iam:DeleteRolePolicy'
              - 'iam:DetachRolePolicy'
              - 'iam:PutRolePolicy'
            Resource: !Sub 'arn:${AWS::Partition}:iam::${AWS::AccountId}:policy/platform-developer-boundary'
          - Sid: RegionFence
            Effect: Deny
            NotAction:
              - 'iam:*'
              - 'sts:*'
              - 'cloudfront:*'
              - 'route53:*'
              - 'support:*'
            Resource: '*'
            Condition:
              StringNotEquals:
                'aws:RequestedRegion':
                  - us-east-1
                  - eu-west-1

  ##########################################################################
  # 2. Self-service role creation, fenced by the boundary above
  ##########################################################################
  DelegatedRoleCreationPolicy:
    Type: AWS::IAM::ManagedPolicy
    Properties:
      ManagedPolicyName: platform-delegated-role-creation
      PolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Sid: CreateRolesOnlyUnderBoundaryAndPath
            Effect: Allow
            Action:
              - 'iam:CreateRole'
              - 'iam:PutRolePolicy'
              - 'iam:AttachRolePolicy'
            Resource: !Sub 'arn:${AWS::Partition}:iam::${AWS::AccountId}:role/app/*'
            Condition:
              StringEquals:
                'iam:PermissionsBoundary': !Ref DeveloperPermissionsBoundary
          - Sid: ReadOnlyIamIntrospection
            Effect: Allow
            Action:
              - 'iam:Get*'
              - 'iam:List*'
              - 'iam:SimulatePrincipalPolicy'
            Resource: '*'

  DeveloperRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: platform-developer
      Path: /platform/
      MaxSessionDuration: 3600
      PermissionsBoundary: !Ref DeveloperPermissionsBoundary
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              AWS: !Sub 'arn:${AWS::Partition}:iam::${AWS::AccountId}:root'
            Action:
              - 'sts:AssumeRole'
              - 'sts:TagSession'
            Condition:
              StringEquals:
                'aws:PrincipalOrgID': !Ref OrgId
              Bool:
                'aws:MultiFactorAuthPresent': 'true'
              NumericLessThan:
                'aws:MultiFactorAuthAge': '3600'
      ManagedPolicyArns:
        - !Ref DelegatedRoleCreationPolicy
      Tags:
        - Key: team
          Value: platform
        - Key: env
          Value: prod

  ##########################################################################
  # 3. Cross-account auditor — read-only, ExternalId mandatory
  ##########################################################################
  ThirdPartyAuditorRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: third-party-auditor
      MaxSessionDuration: 3600
      Description: Read-only access for the external audit firm. Confused-deputy safe.
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              AWS: !Sub 'arn:${AWS::Partition}:iam::${AuditorAccountId}:root'
            Action: 'sts:AssumeRole'
            Condition:
              StringEquals:
                'sts:ExternalId': !Ref AuditorExternalId
              Bool:
                'aws:SecureTransport': 'true'
      ManagedPolicyArns:
        - !Sub 'arn:${AWS::Partition}:iam::aws:policy/SecurityAudit'
        - !Sub 'arn:${AWS::Partition}:iam::aws:policy/job-function/ViewOnlyAccess'
      Policies:
        - PolicyName: deny-data-plane-reads
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Sid: MetadataOnlyNeverObjectContents
                Effect: Deny
                Action:
                  - 's3:GetObject'
                  - 'dynamodb:GetItem'
                  - 'dynamodb:Query'
                  - 'dynamodb:Scan'
                  - 'kms:Decrypt'
                Resource: '*'

  ##########################################################################
  # 4. EC2 workload identity — no keys, tag-scoped, instance profile
  ##########################################################################
  PaymentsApiRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: payments-api-instance-role
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: ec2.amazonaws.com
            Action: 'sts:AssumeRole'
      Policies:
        - PolicyName: payments-api-least-privilege
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Sid: ReadOwnPrefixOnly
                Effect: Allow
                Action:
                  - 's3:GetObject'
                  - 's3:ListBucket'
                Resource:
                  - !Sub 'arn:${AWS::Partition}:s3:::${DataBucketName}'
                  - !Sub 'arn:${AWS::Partition}:s3:::${DataBucketName}/payments/*'
                Condition:
                  Bool:
                    'aws:SecureTransport': 'true'
              - Sid: WriteOwnLogs
                Effect: Allow
                Action:
                  - 'logs:CreateLogStream'
                  - 'logs:PutLogEvents'
                Resource: !Sub 'arn:${AWS::Partition}:logs:${AWS::Region}:${AWS::AccountId}:log-group:/aws/payments-api:*'
      Tags:
        - Key: team
          Value: payments

  PaymentsApiInstanceProfile:
    Type: AWS::IAM::InstanceProfile
    Properties:
      InstanceProfileName: payments-api-instance-profile
      Roles:
        - !Ref PaymentsApiRole

  ##########################################################################
  # 5. Kubernetes workload identity (IRSA)
  ##########################################################################
  EksOidcProvider:
    Type: AWS::IAM::OIDCProvider
    Properties:
      Url: !Sub 'https://${EksOidcProviderUrl}'
      ClientIdList:
        - sts.amazonaws.com
      ThumbprintList:
        - 9e99a48a9960b14926bb7f3b02e22da2b0ab7280

  LedgerWriterIrsaRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: eks-ledger-writer
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Federated: !Sub 'arn:${AWS::Partition}:iam::${AWS::AccountId}:oidc-provider/${EksOidcProviderUrl}'
            Action: 'sts:AssumeRoleWithWebIdentity'
            Condition:
              StringEquals:
                # BOTH conditions are required. Omitting :sub lets ANY
                # ServiceAccount in the cluster assume this role.
                !Sub '${EksOidcProviderUrl}:aud': 'sts.amazonaws.com'
                !Sub '${EksOidcProviderUrl}:sub': 'system:serviceaccount:ledger:ledger-writer'
      Policies:
        - PolicyName: ledger-write
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - 's3:PutObject'
                  - 's3:AbortMultipartUpload'
                Resource: !Sub 'arn:${AWS::Partition}:s3:::${DataBucketName}/ledger/*'

  ##########################################################################
  # 6. Continuous verification
  ##########################################################################
  ExternalAccessAnalyzer:
    Type: AWS::AccessAnalyzer::Analyzer
    Properties:
      AnalyzerName: org-external-access
      Type: ACCOUNT
      Tags:
        - Key: purpose
          Value: least-privilege

Outputs:
  DeveloperRoleArn:
    Description: Assume this with aws sts assume-role (MFA required).
    Value: !GetAtt DeveloperRole.Arn
  AuditorRoleArn:
    Description: Hand this ARN plus the ExternalId to the audit firm.
    Value: !GetAtt ThirdPartyAuditorRole.Arn
  IrsaRoleArn:
    Description: Annotate the Kubernetes ServiceAccount with this ARN.
    Value: !GetAtt LedgerWriterIrsaRole.Arn
  BoundaryArn:
    Value: !Ref DeveloperPermissionsBoundary
```

**Detalle a tener en cuenta:** no existe un recurso nativo de CloudFormation para la política de contraseñas de la cuenta. Hay que configurarla vía CLI/API o con un recurso personalizado:

```bash
$ aws iam update-account-password-policy \
    --minimum-password-length 16 \
    --require-symbols --require-numbers \
    --require-uppercase-characters --require-lowercase-characters \
    --allow-users-to-change-password \
    --max-password-age 90 \
    --password-reuse-prevention 24
```
(sin salida si tuvo éxito — verificá con `get-account-password-policy`)

### 9.1 El lado Kubernetes de IRSA

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ledger-writer
  namespace: ledger
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::111122223333:role/eks-ledger-writer
    # Optional: shorten the STS session from the default 1h
    eks.amazonaws.com/token-expiration: "1800"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ledger-writer
  namespace: ledger
spec:
  replicas: 3
  selector:
    matchLabels:
      app: ledger-writer
  template:
    metadata:
      labels:
        app: ledger-writer
    spec:
      serviceAccountName: ledger-writer
      automountServiceAccountToken: true
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: writer
          image: 111122223333.dkr.ecr.us-east-1.amazonaws.com/ledger-writer:1.14.2
          env:
            - name: AWS_REGION
              value: us-east-1
            # STS regional endpoint: avoids the global us-east-1 dependency
            - name: AWS_STS_REGIONAL_ENDPOINTS
              value: regional
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests: { cpu: "100m", memory: "128Mi" }
            limits:   { memory: "256Mi" }
```

El webhook inyecta `AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE` y un volumen con token proyectado de forma automática. Si esas variables no están dentro del pod, la anotación del ServiceAccount está mal o el pod se creó antes de que existiera la anotación — el webhook solo muta en el momento de la admisión, así que **el pod debe recrearse**.

---

## 10. Usuarios de la aplicación y secretos

### 10.1 Amazon Cognito

| Componente | Propósito | Salida |
|---|---|---|
| **User pool** | Directorio de autenticación para los usuarios de tu app; registro, inicio de sesión, MFA, restablecimiento de contraseña, hosted UI, federación social/SAML/OIDC | JWTs (tokens de ID, de acceso y de refresco) |
| **Identity pool** (identidades federadas) | **Autorización** — intercambia un token por credenciales temporales de AWS vía STS | Credenciales `ASIA…` acotadas a un rol IAM |

La distinción es examinable: un user pool prueba *quién* es el usuario; un identity pool le otorga *acceso a la API de AWS* a ese usuario. Una app móvil que solo llama a tu propio API Gateway necesita únicamente el user pool.

### 10.2 Dónde viven las credenciales cuando una credencial es inevitable

| | AWS Secrets Manager | SSM Parameter Store (SecureString) |
|---|---|---|
| Rotación automática | **Sí**, rotación nativa con Lambda para RDS/Redshift/DocumentDB, personalizada para los demás | No (lo armás vos con EventBridge) |
| Acceso entre cuentas | Política basada en recursos sobre el secreto | Advanced tier + patrones de compartición de recursos |
| Costo | Por secreto por mes + por cada 10k llamadas a la API | **Standard tier gratuito**; advanced tier con cargo |
| Límite de tamaño | 64 KB | 4 KB standard / 8 KB advanced |
| Cifrado | KMS, obligatorio | KMS para SecureString, opcional |
| Replicación | Replicación multi-región del secreto | Manual |
| Usar cuando | Credenciales de base de datos, claves de API de terceros, cualquier cosa que rote | Valores de configuración, tokens que no rotan, sensibilidad al costo |

Ninguno de los dos sustituye a un rol. Si una carga de trabajo puede usar un rol, debería hacerlo — un secreto que nunca almacenás no puede filtrarse.

---

## 11. Runbook de CLI

### 11.1 Asumir un rol con MFA y usarlo

```bash
$ aws sts get-caller-identity
{
    "UserId": "AIDACKCEVSQ6C2EXAMPLE",
    "Account": "111122223333",
    "Arn": "arn:aws:iam::111122223333:user/alice"
}

$ aws sts assume-role \
    --role-arn arn:aws:iam::111122223333:role/platform/platform-developer \
    --role-session-name alice-ticket-4471 \
    --serial-number arn:aws:iam::111122223333:mfa/alice-yubikey \
    --token-code 492013 \
    --duration-seconds 3600
{
    "Credentials": {
        "AccessKeyId": "ASIAIOSFODNN7EXAMPLE",
        "SecretAccessKey": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        "SessionToken": "IQoJb3JpZ2luX2VjEJr//////////wEaCXVzLWVhc3QtMSJHMEUCIQ...TRUNCATED",
        "Expiration": "2026-09-03T11:42:18+00:00"
    },
    "AssumedRoleUser": {
        "AssumedRoleId": "AROA3XFRBF535PLBIFPI4:alice-ticket-4471",
        "Arn": "arn:aws:sts::111122223333:assumed-role/platform-developer/alice-ticket-4471"
    }
}
```

El `--role-session-name` pasa a formar parte del ARN y aparece en cada evento de CloudTrail. Poné ahí el número de ticket; tu yo futuro se lo va a agradecer a tu yo presente durante la revisión del incidente.

### 11.2 Sesión de Identity Center (la forma en que los humanos deberían trabajar realmente)

```bash
$ cat ~/.aws/config
[sso-session corp]
sso_start_url = https://d-9067abc123.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access

[profile prod-admin]
sso_session = corp
sso_account_id = 111122223333
sso_role_name = PlatformEngineer
region = us-east-1
output = json

$ aws sso login --sso-session corp
Attempting to automatically open the SSO authorization page in your default browser.
If the browser does not open, open the following URL:

https://oidc.us-east-1.amazonaws.com/authorize?...

Then enter the code:

FTQR-VXBK
Successfully logged into Start URL: https://d-9067abc123.awsapps.com/start

$ aws sts get-caller-identity --profile prod-admin
{
    "UserId": "AROA3XFRBF535PLBIFPI4:alice@example.com",
    "Account": "111122223333",
    "Arn": "arn:aws:sts::111122223333:assumed-role/AWSReservedSSO_PlatformEngineer_9f0e1d2c3b4a5678/alice@example.com"
}
```

Ningún secreto toca jamás el disco en una forma que sobreviva a la sesión.

### 11.3 El credential report — tu auditoría trimestral en un solo comando

```bash
$ aws iam generate-credential-report
{
    "State": "STARTED",
    "Description": "No report exists. Starting a new report generation task"
}

$ aws iam get-credential-report --query Content --output text | base64 -d | \
    awk -F, 'NR==1 || $4=="true" || $9=="true" {print $1","$4","$8","$9","$10","$12}' | column -s, -t
user                              password_enabled  access_key_1_active  access_key_1_last_rotated
<root_account>                    not_supported     false                N/A
legacy-backup-agent               false             true                 2023-11-02T09:14:00+00:00
ci-deploy-bot                     false             true                 2026-08-30T02:00:11+00:00
```

`legacy-backup-agent` tiene una clave que no rota desde hace casi tres años. Ese es el hallazgo.

### 11.4 Access Advisor — reducción de privilegios basada en evidencia

```bash
$ JOB=$(aws iam generate-service-last-accessed-details \
    --arn arn:aws:iam::111122223333:role/payments-api-instance-role \
    --query JobId --output text)

$ aws iam get-service-last-accessed-details --job-id "$JOB" \
    --query 'ServicesLastAccessed[?TotalAuthenticatedEntities>`0`].[ServiceNamespace,LastAuthenticated]' \
    --output table
------------------------------------------------
|        GetServiceLastAccessedDetails          |
+-----------+----------------------------------+
|  s3       |  2026-09-03T09:58:12+00:00       |
|  logs     |  2026-09-03T09:59:40+00:00       |
+-----------+----------------------------------+
```

Cualquier servicio otorgado pero ausente de esta tabla durante 90 días o más es candidato a eliminación.

### 11.5 IAM Access Analyzer — acceso externo y sin uso

```bash
$ aws accessanalyzer list-findings --analyzer-arn "$ANALYZER_ARN" \
    --filter '{"status":{"eq":["ACTIVE"]}}' \
    --query 'findings[].{Resource:resource,Type:resourceType,External:principal,Public:isPublic}' \
    --output table
--------------------------------------------------------------------------------------
|                                    ListFindings                                     |
+--------+----------------------------------------+-------------------+---------------+
| Public | Resource                               | Type              | External      |
+--------+----------------------------------------+-------------------+---------------+
| True   | arn:aws:s3:::prod-ledger-backups       | AWS::S3::Bucket   | {"AWS":"*"}   |
| False  | arn:aws:iam::111122223333:role/vendor  | AWS::IAM::Role    | 999988887777  |
+--------+----------------------------------------+-------------------+---------------+
```

La primera fila es un bucket público — un hallazgo de gravedad equivalente a una caída de servicio. La segunda fila solo es esperable si `999988887777` es un proveedor conocido; si no está en tu inventario, es una intrusión.

Validá una política **antes** de publicarla:

```bash
$ aws accessanalyzer validate-policy \
    --policy-type IDENTITY_POLICY \
    --policy-document file://payments-policy.json \
    --query 'findings[].{Type:findingType,Issue:issueCode,Detail:findingDetails}' --output table
------------------------------------------------------------------------------------------
|                                     ValidatePolicy                                      |
+-----------+--------------------------+--------------------------------------------------+
| Type      | Issue                    | Detail                                           |
+-----------+--------------------------+--------------------------------------------------+
| SECURITY_ | PASS_ROLE_WITH_STAR_IN_  | Using the iam:PassRole action with wildcards     |
| WARNING   | RESOURCE                 | in the resource can be overly permissive.        |
| WARNING   | MISSING_TAG_KEY          | Condition key aws:ResourceTag/ has no tag key.   |
+-----------+--------------------------+--------------------------------------------------+
```

---

## 12. Verificación y diagnóstico de fallas

### 12.1 El árbol de decisión de `AccessDenied`

```
AccessDenied received
   │
   ├─ Does the message name sts:AssumeRole?
   │     └─ YES → TRUST POLICY problem.
   │              Check: Principal ARN, ExternalId, MFA condition,
   │              aws:PrincipalOrgID, and whether the caller's identity
   │              policy allows sts:AssumeRole on that role ARN.
   │
   ├─ Message says "with an explicit deny in a service control policy"?
   │     └─ SCP. Check the OU chain from root down. RegionFence and
   │        service-restriction SCPs are the usual culprits.
   │
   ├─ Message says "with an explicit deny in a resource control policy"?
   │     └─ RCP on the resource's account.
   │
   ├─ Message says "with an explicit deny in a permissions boundary"?
   │     └─ Boundary is narrower than the identity policy. Effective = intersection.
   │
   ├─ Message says "because no identity-based policy allows"?
   │     └─ IMPLICIT deny. Nothing granted it. Add the action/resource.
   │
   ├─ Message says "because no session policy allows"?
   │     └─ The --policy passed at AssumeRole time is too narrow.
   │
   ├─ Message mentions KMS / "not authorized to perform kms:Decrypt"?
   │     └─ TWO policies: the IAM policy AND the KMS KEY POLICY.
   │        A key policy without your principal denies you regardless of IAM.
   │
   ├─ Cross-account S3/SQS/SNS?
   │     └─ BOTH sides required. Also check the S3 Block Public Access
   │        settings and the bucket's Object Ownership setting.
   │
   └─ Encoded message present (EC2/ASG/RunInstances)?
         └─ Decode it (12.3).
```

### 12.2 Simulá antes de desplegar

```bash
$ aws iam simulate-principal-policy \
    --policy-source-arn arn:aws:iam::111122223333:role/payments-api-instance-role \
    --action-names s3:GetObject s3:DeleteObject \
    --resource-arns arn:aws:s3:::prod-ledger-111122223333/payments/2026/09/tx.parquet \
    --query 'EvaluationResults[].{Action:EvalActionName,Decision:EvalDecision,MatchedBy:MatchedStatements[0].SourcePolicyId}' \
    --output table
------------------------------------------------------------------------
|                       SimulatePrincipalPolicy                         |
+-------------------+------------------------+--------------------------+
|      Action       |       Decision         |        MatchedBy         |
+-------------------+------------------------+--------------------------+
|  s3:GetObject     |  allowed               |  payments-api-least-priv |
|  s3:DeleteObject  |  implicitDeny          |  None                    |
+-------------------+------------------------+--------------------------+
```

`implicitDeny` = ninguna declaración coincidió. `explicitDeny` = algo lo denegó activamente. El simulador evalúa políticas de identidad, boundaries y SCP, pero **no evalúa las políticas basadas en recursos para la cuenta propietaria del recurso en todos los casos** — confirmá siempre las rutas entre cuentas con una llamada real.

### 12.3 Decodificar un mensaje de falla de autorización

```bash
$ aws ec2 run-instances --image-id ami-0abcdef1234567890 --instance-type m6i.large

An error occurred (UnauthorizedOperation) when calling the RunInstances operation:
You are not authorized to perform this operation.
User: arn:aws:sts::111122223333:assumed-role/platform-developer/alice-ticket-4471
is not authorized to perform: ec2:RunInstances on resource:
arn:aws:ec2:us-east-1:111122223333:instance/*.
Encoded authorization failure message: 8f3Kd9x2QpL...TRUNCATED

$ aws sts decode-authorization-message \
    --encoded-message '8f3Kd9x2QpL...TRUNCATED' \
    --query DecodedMessage --output text | python3 -m json.tool
{
    "allowed": false,
    "explicitDeny": true,
    "matchedStatements": {
        "items": [
            {
                "statementId": "RegionFence",
                "effect": "DENY",
                "principals":  { "items": [{ "value": "AROA3XFRBF535PLBIFPI4" }] },
                "resources":   { "items": [{ "value": "*" }] },
                "conditions":  { "items": [
                    { "key": "aws:RequestedRegion", "values": { "items": [{ "value": "us-east-1" }] } }
                ]}
            }
        ]
    },
    "failures": { "items": [] },
    "context": {
        "principal": { "id": "AROA3XFRBF535PLBIFPI4:alice-ticket-4471",
                       "arn": "arn:aws:sts::111122223333:assumed-role/platform-developer/alice-ticket-4471" },
        "action": "ec2:RunInstances",
        "resource": "arn:aws:ec2:us-east-1:111122223333:instance/*"
    }
}
```

`statementId: RegionFence` nombra la declaración exacta. Esta es la ruta más rápida del síntoma a la causa en toda la cadena de herramientas de IAM, y requiere `sts:DecodeAuthorizationMessage` en la política del que llama — otorgáselo a todo rol de operador.

### 12.4 CloudTrail: encontrar la denegación que no atrapaste en vivo

```bash
$ aws cloudtrail lookup-events \
    --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRole \
    --start-time 2026-09-03T08:00:00Z --end-time 2026-09-03T10:00:00Z \
    --max-results 50 \
    --query 'Events[].CloudTrailEvent' --output text | \
  python3 -c 'import sys,json
for l in sys.stdin.read().split("\n"):
    if not l.strip(): continue
    e=json.loads(l)
    if e.get("errorCode"):
        print(e["eventTime"], e.get("errorCode"),
              e["userIdentity"].get("arn","-"),
              e.get("requestParameters",{}).get("roleArn","-"))'
2026-09-03T09:14:22Z AccessDenied arn:aws:iam::111122223333:user/ci-deploy-bot arn:aws:iam::555566667777:role/deployer
2026-09-03T09:14:52Z AccessDenied arn:aws:iam::111122223333:user/ci-deploy-bot arn:aws:iam::555566667777:role/deployer
```

Denegaciones repetidas de `AssumeRole` de un bot hacia un rol de otra cuenta = política de confianza faltante o desviada en `555566667777`, no un problema de permisos en `111122223333`.

### 12.5 Triage específico de IRSA

```bash
$ kubectl -n ledger exec deploy/ledger-writer -- env | grep AWS_
AWS_REGION=us-east-1
AWS_DEFAULT_REGION=us-east-1
AWS_ROLE_ARN=arn:aws:iam::111122223333:role/eks-ledger-writer
AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token
AWS_STS_REGIONAL_ENDPOINTS=regional

$ kubectl -n ledger exec deploy/ledger-writer -- \
    aws sts get-caller-identity
{
    "UserId": "AROAZZ7EXAMPLE4KDXQ:botocore-session-1788436092",
    "Account": "111122223333",
    "Arn": "arn:aws:sts::111122223333:assumed-role/eks-ledger-writer/botocore-session-1788436092"
}
```

Si falta `AWS_ROLE_ARN`: la anotación del ServiceAccount está ausente, o el pod es anterior a ella — eliminá el pod. Si `get-caller-identity` devuelve el ARN del rol del **nodo** en su lugar: el SDK cayó hasta IMDS, lo que significa que el token proyectado no está montado. Si devuelve `InvalidIdentityToken`: la condición `:sub` de la política de confianza no coincide exactamente con `system:serviceaccount:<namespace>:<serviceaccount>`.

### 12.6 Checklist de verificación (ejecutar como tarea programada)

| Verificación | Comando | Criterio de aprobación |
|---|---|---|
| MFA de root activo, sin claves de root | `aws iam get-account-summary` | `AccountMFAEnabled=1`, `AccountAccessKeysPresent=0` |
| Sin claves de acceso con más de 90 días | credential report, columna `access_key_1_last_rotated` | ninguna con más de 90 d |
| Sin usuarios IAM con acceso a consola | `aws iam list-users` + credential report | cero, fuera de break-glass |
| La política de contraseñas cumple el estándar | `aws iam get-account-password-policy` | ≥14 caracteres, prevención de reutilización activada |
| Ninguna política otorga `Action:*` sobre `Resource:*` | `aws accessanalyzer validate-policy` en CI | cero `SECURITY_WARNING` |
| Sin recursos compartidos externamente | `aws accessanalyzer list-findings` | cero hallazgos ACTIVE sin revisar |
| Sin roles/permisos sin uso | analizador de acceso sin uso | cero durante el período de seguimiento |
| IMDSv2 aplicado en todas partes | `aws ec2 describe-instances --query 'Reservations[].Instances[?MetadataOptions.HttpTokens!=\`required\`].InstanceId'` | lista vacía |
| El trail de organización de CloudTrail está activo y es inmutable | `aws cloudtrail describe-trails` | `IsOrganizationTrail=true`, validación de archivos de log habilitada |

---

## 13. Discriminaciones a nivel de examen

Estos son los pares que deciden las preguntas:

| Si la pregunta dice… | La respuesta es… | No… |
|---|---|---|
| "centrally manage user access to **multiple AWS accounts**" | **IAM Identity Center** | Usuarios/grupos IAM |
| "sign-up and sign-in for a **mobile/web application's users**" | **Amazon Cognito** | IAM Identity Center |
| "grant an **EC2 instance** access to S3" | **Rol IAM + instance profile** | Claves de acceso en la instancia |
| "**temporary**, limited-privilege credentials" | **AWS STS** | Claves de acceso de IAM |
| "reduce the **maximum** permissions available to an OU" | **SCP** | Política IAM |
| "restrict who can access **a resource**, org-wide" | **RCP** | SCP |
| "a **third-party vendor** needs access to your account" | **Rol entre cuentas con ExternalId** | Un usuario IAM para el proveedor |
| "which tasks **require the root user**" | Cerrar la cuenta, cambiar el plan de soporte, cambiar el email/contraseña de root | Cualquier cosa rutinaria |
| "identify **unused** permissions or **externally shared** resources" | **IAM Access Analyzer** | Trusted Advisor (solo solapamiento parcial) |
| "list **when each service was last used** by a principal" | **Access Advisor / service last accessed** | CloudWatch |
| "report of **all users and their credential status**" | **Credential report de IAM** | Config |
| "automatically **rotate a database password**" | **AWS Secrets Manager** | Parameter Store |
| "record **who did what** in the account" | **AWS CloudTrail** | CloudWatch Logs |
| "IAM is …" | **Global, sin costo** | Regional, facturado |

Hechos que se evalúan textualmente:
- IAM es un servicio **global** y se ofrece **sin costo adicional**.
- **Los grupos no pueden anidarse**, no pueden contener roles y no pueden ser un `Principal`.
- Un usuario puede pertenecer a **hasta 10 grupos**.
- **Un deny explícito siempre anula cualquier allow.**
- Todo está **denegado implícitamente** por defecto.
- **Los usuarios IAM nuevos no tienen permisos** hasta que se les asocia una política.
- **Los roles no tienen credenciales permanentes.**
- Habilitar MFA en el usuario root es la **primera** acción recomendada en una cuenta nueva.
- El **modelo de responsabilidad compartida de AWS** ubica la configuración de IAM — usuarios, roles, políticas, MFA — de lleno en la mitad del **cliente**.

---

## 14. Referencias

**Material oficial del examen**
- AWS Certified Cloud Practitioner (CLF-C02) Exam Guide — https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
- Página de la certificación AWS Certified Cloud Practitioner — https://aws.amazon.com/certification/certified-cloud-practitioner/

**Núcleo de IAM**
- AWS Identity and Access Management User Guide — https://docs.aws.amazon.com/IAM/latest/UserGuide/introduction.html
- Security best practices in IAM — https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html
- Policy evaluation logic — https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html
- Policies and permissions in IAM — https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies.html
- Permissions boundaries for IAM entities — https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_boundaries.html
- IAM JSON policy elements reference — https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_elements.html
- Global condition context keys — https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_condition-keys.html
- IAM roles — https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles.html
- Attribute-based access control (ABAC) — https://docs.aws.amazon.com/IAM/latest/UserGuide/introduction_attribute-based-access-control.html
- IAM and AWS STS quotas — https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_iam-quotas.html

**Usuario root**
- AWS account root user — https://docs.aws.amazon.com/IAM/latest/UserGuide/id_root-user.html
- Tasks that require root user credentials — https://docs.aws.amazon.com/accounts/latest/reference/root-user-tasks.html
- Centralized root access for member accounts — https://docs.aws.amazon.com/IAM/latest/UserGuide/id_root-user-access-management.html

**MFA y credenciales**
- Multi-factor authentication in IAM — https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_mfa.html
- Managing access keys for IAM users — https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_access-keys.html
- Getting credential reports — https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_getting-report.html
- Refining permissions using last accessed information — https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_access-advisor.html

**STS y federación**
- AWS Security Token Service API Reference — https://docs.aws.amazon.com/STS/latest/APIReference/welcome.html
- Temporary security credentials in IAM — https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_temp.html
- The confused deputy problem — https://docs.aws.amazon.com/IAM/latest/UserGuide/confused-deputy.html
- Identity providers and federation — https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers.html

**IAM Identity Center**
- AWS IAM Identity Center User Guide — https://docs.aws.amazon.com/singlesignon/latest/userguide/what-is.html
- Permission sets — https://docs.aws.amazon.com/singlesignon/latest/userguide/permissionsetsconcept.html
- ABAC with IAM Identity Center — https://docs.aws.amazon.com/singlesignon/latest/userguide/abac.html

**Organizations**
- Service control policies (SCPs) — https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html
- Resource control policies (RCPs) — https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_rcps.html

**Identidad de cargas de trabajo**
- IAM roles for Amazon EC2 — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/iam-roles-for-amazon-ec2.html
- Use IMDSv2 — https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html
- IAM roles for service accounts (EKS) — https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html
- EKS Pod Identity — https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html

**Herramientas de verificación**
- IAM Access Analyzer — https://docs.aws.amazon.com/IAM/latest/UserGuide/what-is-access-analyzer.html
- IAM policy simulator — https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_testing-policies.html
- AWS CloudTrail User Guide — https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-user-guide.html

**Identidad de aplicación y secretos**
- Amazon Cognito Developer Guide — https://docs.aws.amazon.com/cognito/latest/developerguide/what-is-amazon-cognito.html
- AWS Secrets Manager User Guide — https://docs.aws.amazon.com/secretsmanager/latest/userguide/intro.html
- AWS Systems Manager Parameter Store — https://docs.aws.amazon.com/systems-manager/latest/userguide/systems-manager-parameter-store.html

**Modelo y arquitectura de referencia**
- AWS Shared Responsibility Model — https://aws.amazon.com/compliance/shared-responsibility-model/
- AWS Well-Architected Framework — Security Pillar — https://docs.aws.amazon.com/wellarchitected/latest/security-pillar/welcome.html
- AWS Security Reference Architecture (AWS SRA) — https://docs.aws.amazon.com/prescriptive-guidance/latest/security-reference-architecture/welcome.html
- AWS::IAM resource type reference (CloudFormation) — https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/AWS_IAM.html