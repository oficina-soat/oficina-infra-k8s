# Kubernetes

Estrutura recomendada para este repositório:

- `base/`: manifests reutilizáveis da aplicação
- `components/`: recursos adicionais compostos para o laboratório
- `addons/`: recursos opcionais e independentes
- `overlays/`: entrypoints por ambiente

## Laboratório

O entrypoint do laboratório é `k8s/overlays/lab`.

- `k8s/base/oficina-app/`: `Deployment` e `Service` da aplicação
- `k8s/components/mailhog/`: componente de e-mail usado no laboratório
- `k8s/addons/keycloak/`: addon opcional para demonstração
- `k8s/overlays/lab/`: composição final do ambiente

Render:

```bash
kubectl kustomize k8s/overlays/lab
```
