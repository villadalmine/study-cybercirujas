# Ejercicios Guiados — 5.4 Ingress Controllers, Gateway API, and External Traffic Management

## Ejercicio 1 — Configuración de HTTPRoute con Gateway API

1. Inspeccionar los GatewayClass disponibles en el clúster:
   ```bash
   kubectl get gatewayclasses
   ```
2. Crear un Gateway y un HTTPRoute para exponer un servicio:
   ```bash
   kubectl get gateways -A
   kubectl get httproutes -A
   ```
3. Verificar la resolución DNS y el certificado TLS del endpoint expuesto:
   ```bash
   curl -v https://api.platform.example.com/v1/health
   ```

---

<details>
<summary>Ver Respuestas</summary>

1. Gateway API separa responsabilidades: el equipo de infraestructura gestiona el `GatewayClass` y `Gateway`, mientras los equipos de desarrollo configuran sus `HTTPRoute` de forma autónoma.
2. El modelo multi-namespace de Gateway API permite el enrutamiento cross-namespace sin necesidad de permisos elevados.

</details>