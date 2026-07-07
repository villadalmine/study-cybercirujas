# 1.3 Open Source Software and Licensing

**Peso en el examen: 1**

## Introducción

El software libre y de código abierto (FOSS, *Free and Open Source Software*) es la base del ecosistema Linux. Este tema cubre los conceptos de licenciamiento, las diferencias entre *free software* y *open source*, las licencias más comunes y los modelos de negocio asociados.

---

## Software libre vs. Open Source

Aunque en la práctica se refieren casi al mismo conjunto de software, los dos términos nacen de movimientos con filosofías distintas:

- **Free Software** (Software Libre): definido por la **Free Software Foundation (FSF)**, fundada por **Richard Stallman** en 1985. El énfasis es ético y social: la libertad del usuario. "Free" refiere a libertad (*free as in freedom*), no a precio (*free as in beer*).
- **Open Source**: definido por la **Open Source Initiative (OSI)**, fundada en 1998 por Eric S. Raymond y Bruce Perens. El énfasis es pragmático: las ventajas técnicas y de desarrollo que trae el código abierto (más ojos revisando el código, desarrollo colaborativo).

El término paraguas **FOSS** (o **FLOSS**, *Free/Libre and Open Source Software*) abarca ambos enfoques.

### Las cuatro libertades del software libre

Según la FSF, un programa es software libre si otorga estas cuatro libertades (numeradas desde 0, como corresponde en informática):

| Libertad | Descripción |
|---|---|
| **0** | Ejecutar el programa como se desee, con cualquier propósito |
| **1** | Estudiar cómo funciona el programa y modificarlo (requiere acceso al código fuente) |
| **2** | Redistribuir copias para ayudar a otros |
| **3** | Distribuir copias de las versiones modificadas (requiere acceso al código fuente) |

Si falta cualquiera de las cuatro, el software es **propietario** (*proprietary* o *non-free*), aunque sea gratuito.

> **Ojo para el examen:** *freeware* (gratuito pero cerrado, ej. Skype) y *shareware* (de prueba) **no** son software libre. El precio no es el criterio: el software libre puede venderse.

---

## Copyleft y tipos de licencias

Una **licencia** es el instrumento legal que define qué puede hacer el usuario con el software. Las licencias FOSS se agrupan en dos grandes familias:

### Licencias copyleft (recíprocas / restrictivas)

El **copyleft** usa el derecho de autor (*copyright*) para garantizar que las libertades se preserven: cualquier obra derivada debe distribuirse bajo la misma licencia. Es el efecto "viral" o hereditario.

- **GPL (GNU General Public License)**: la licencia copyleft más conocida. Versiones vigentes: **GPLv2** (1991, usada por el kernel Linux) y **GPLv3** (2007, agrega protecciones contra patentes de software y *tivoization*). No son automáticamente compatibles entre sí.
- **AGPL (GNU Affero GPL)**: extiende la GPL al software usado como servicio de red (SaaS): quien lo ejecuta en un servidor también debe ofrecer el código fuente.
- **LGPL (GNU Lesser GPL)**: copyleft débil, pensada para bibliotecas. Permite que programas propietarios enlacen (*link*) contra la biblioteca sin quedar obligados a liberar su propio código.

### Licencias permisivas (no copyleft)

Imponen requisitos mínimos, generalmente solo conservar el aviso de copyright. Permiten incorporar el código en software propietario.

- **MIT License**: extremadamente breve y permisiva.
- **BSD (2-Clause y 3-Clause)**: similar a MIT; la variante de 3 cláusulas prohíbe usar el nombre de los autores para promocionar derivados.
- **Apache License 2.0**: permisiva pero más detallada; incluye una concesión explícita de patentes.

### Ejemplo concreto: ver la licencia de un paquete

En una distribución Debian/Ubuntu, cada paquete instala su licencia en `/usr/share/doc/`:

```bash
$ head -n 12 /usr/share/doc/bash/copyright
This is Debian GNU/Linux's prepackaged version of the FSF's GNU Bash,
the Bourne Again SHell.

...
License: GPL-3+
 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License...
```

El propio kernel declara su licencia con identificadores **SPDX**, un estándar para etiquetar licencias en el código fuente:

```bash
$ head -n 1 init/main.c   # en el árbol de fuentes del kernel
// SPDX-License-Identifier: GPL-2.0-only
```

### Creative Commons

Para obras que no son software (documentación, imágenes, música) se usan las licencias **Creative Commons (CC)**, que se componen combinando módulos:

- **BY** (Attribution): exige atribuir al autor — presente en casi todas.
- **SA** (ShareAlike): las derivadas deben usar la misma licencia (equivalente a copyleft).
- **ND** (NoDerivatives): no se permiten obras derivadas.
- **NC** (NonCommercial): prohíbe el uso comercial.
- **CC0**: renuncia a los derechos; equivale a dominio público.

Ejemplos: `CC BY-SA 4.0` (usada por Wikipedia), `CC BY-NC-ND 4.0` (la más restrictiva). Las variantes con **NC** o **ND** no se consideran licencias "libres" según la definición de la FSF.

---

## Modelos de negocio con Open Source

Que el software sea libre no impide ganar dinero con él. Modelos habituales:

1. **Suscripciones y soporte comercial**: se cobra por soporte, certificación y actualizaciones garantizadas. Ejemplo: **Red Hat Enterprise Linux (RHEL)** o **SUSE Linux Enterprise Server (SLES)**.
2. **Servicios profesionales**: consultoría, capacitación, desarrollo a medida sobre proyectos FOSS.
3. **Dual licensing**: el mismo producto se ofrece bajo GPL (gratis) y bajo licencia comercial para quien no quiere las obligaciones del copyleft. Ejemplo histórico: MySQL.
4. **Open core**: núcleo abierto con extensiones propietarias de pago. Ejemplo: GitLab.
5. **SaaS / hosting**: se cobra por ejecutar y administrar el software en la nube (ej. bases de datos gestionadas sobre PostgreSQL).
6. **Hardware**: vender dispositivos que corren FOSS (routers, Android, sistemas embebidos).

---

## Puntos clave para el examen

- Las **cuatro libertades** (0–3) definen el software libre; conocerlas de memoria.
- **FSF** → Richard Stallman, proyecto **GNU**, énfasis ético. **OSI** → énfasis pragmático, define la *Open Source Definition*.
- **GPL = copyleft** (derivados con la misma licencia); **MIT/BSD/Apache = permisivas**.
- El **kernel Linux usa GPLv2**.
- **LGPL** para bibliotecas; **AGPL** para servicios de red.
- Gratis ≠ libre: *freeware* y *shareware* no son FOSS.
- Creative Commons es para contenido, no para software; **NC** y **ND** la vuelven no-libre.

---

## Referencias

- LPI Learning Materials — Tema 1.3: https://learning.lpi.org/en/learning-materials/010-160/1/1.3/
- Definición de Software Libre (FSF/GNU): https://www.gnu.org/philosophy/free-sw.html
- Licencias GNU (GPL, LGPL, AGPL): https://www.gnu.org/licenses/licenses.html
- Open Source Definition (OSI): https://opensource.org/osd
- Licencias aprobadas por la OSI: https://opensource.org/licenses
- Creative Commons — About the licenses: https://creativecommons.org/licenses/
- SPDX License List: https://spdx.org/licenses/