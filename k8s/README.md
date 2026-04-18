# Kubernetes

Estrutura recomendada para este repositório:

- `base/`: manifests reutilizáveis da aplicação
- `components/`: recursos adicionais compostos para o laboratório
- `addons/`: recursos opcionais e independentes
- `overlays/`: pontos de entrada por ambiente

## Laboratório

O ponto de entrada do laboratório é `k8s/overlays/lab`.

- `k8s/base/oficina-app/`: `Deployment` e `Service` da aplicação
- `k8s/components/mailhog/`: componente de e-mail usado no laboratório
- `k8s/addons/keycloak/`: addon opcional para demonstração
- `k8s/overlays/lab/`: composição final do ambiente

Renderização:

```bash
kubectl kustomize k8s/overlays/lab
```
