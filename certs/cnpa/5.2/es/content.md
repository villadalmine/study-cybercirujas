# 5.2 Traffic Management, Canary Releases, and Circuit Breaking

## Motivación y Enrutamiento Avanzado de Tráfico

Enrutamiento inteligente de tráfico, despliegues **Canary** (VirtualService/DestinationRule en Istio) y patrones de resiliencia como **Circuit Breaking** y Retries.

---

## 1. Istio VirtualService y Traffic Shifting

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: platform-api-route
  namespace: platform-prod
spec:
  hosts:
  - platform-api
  http:
  - route:
    - destination:
        host: platform-api
        subset: v1
      weight: 90
    - destination:
        host: platform-api
        subset: v2
      weight: 10
```

---

## Referencias

- CNCF CNPA Curriculum — https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
- Istio Traffic Management — https://istio.io/latest/docs/tasks/traffic-management/