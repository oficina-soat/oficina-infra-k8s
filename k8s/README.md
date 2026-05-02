# Kubernetes

Estrutura recomendada para este repositório:

- `base/`: manifests reutilizáveis da aplicação
- `components/`: recursos adicionais compostos para o laboratório
- `overlays/`: pontos de entrada por ambiente

## Laboratório

Os pontos de entrada do laboratório são:

- `k8s/base/oficina-app/`: `Deployment` e `Service` da aplicação
- `k8s/components/mailhog/`: componente de e-mail usado no laboratório
- `k8s/overlays/lab-platform/`: componentes de cluster gerenciados por este repositório, sem o `oficina-app`
- `k8s/overlays/lab-app/`: `Deployment`, `Service` e `ConfigMap` do `oficina-app`
- `k8s/overlays/lab/`: composição final do ambiente para renderização e validação integrada

O Service `oficina-app` usa `type: NodePort` com `nodePort: 30080`. Esse valor é consumido pelo Terraform do ambiente `lab` para registrar os nodes do EKS em um NLB interno acessado pelo API Gateway via `VPC_LINK`; ele não cria um `LoadBalancer` Kubernetes público.

O componente `mailhog` mantém um Service `ClusterIP` para uso interno do cluster e adiciona o Service `mailhog-smtp-private` com `type: NodePort` e `nodePort: 31025`. Esse NodePort não é público por si só; ele serve como target de um NLB interno dedicado ao SMTP do MailHog para acesso privado da `notificacao-lambda`.

Renderização:

```bash
kubectl kustomize k8s/overlays/lab-platform
kubectl kustomize k8s/overlays/lab-app
kubectl kustomize k8s/overlays/lab
```
