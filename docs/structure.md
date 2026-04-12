# Estrutura da Infra

O repositório segue uma organização inspirada em boas práticas de Terraform:

- `k8s/base/`, `k8s/components/`, `k8s/addons/` e `k8s/overlays/`: composição Kubernetes do laboratório
- `terraform/modules/`: módulos reutilizáveis da infraestrutura AWS
- `terraform/environments/`: pontos de entrada Terraform por ambiente
- `.github/workflows/`: automação de deploy em branch protegida
- `scripts/`: automações operacionais

## Módulos

- `k8s/base/oficina-app/`: `Deployment` e `Service` da aplicação
- `k8s/components/mailhog/`: componente de e-mail do laboratório
- `k8s/addons/keycloak/`: addon opcional para demonstração local
- `terraform/modules/network/`: VPC, subnets públicas e rotas
- `terraform/modules/eks/`: cluster EKS, access entry e managed node group
- `terraform/modules/ecr/`: repositório ECR opcional para a imagem da aplicação
- `terraform/modules/terraform_shared_data_bucket/`: bucket S3 para dados compartilhados e backend remoto do Terraform

## Ambiente

- `k8s/overlays/lab/`: composição Kubernetes do laboratório acadêmico
- `terraform/environments/lab/`: entrypoint Terraform do laboratório acadêmico
- `scripts/ci-terraform.sh`: automação de `terraform apply/destroy` usada pelos workflows de infra

O ambiente de laboratório depende do secret externo `oficina-database-env` no namespace `default`.
