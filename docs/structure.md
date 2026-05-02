# Estrutura da Infra

O repositório segue uma organização inspirada em boas práticas de Terraform:

- `k8s/base/`, `k8s/components/` e `k8s/overlays/`: composição Kubernetes do laboratório
- `terraform/modules/`: módulos reutilizáveis da infraestrutura AWS
- `terraform/environments/`: pontos de entrada Terraform por ambiente
- `.github/workflows/`: automação de deploy em branch protegida
- `scripts/actions/`: automações usadas pelos workflows
- `scripts/manual/`: automações de uso manual e operacional
- `scripts/lib/`: helpers compartilhados dos scripts

## Módulos

- `k8s/base/oficina-app/`: `Deployment` e `Service` da aplicação
- `k8s/components/mailhog/`: componente de e-mail do laboratório
- `terraform/modules/network/`: VPC, subnets públicas e rotas
- `terraform/modules/eks/`: cluster EKS, access entry e managed node group
- `terraform/modules/ecr/`: repositório ECR opcional para a imagem da aplicação
- `terraform/modules/api_gateway/`: API Gateway HTTP API com rotas opcionais para backends HTTP e Lambda
- `terraform/modules/terraform_shared_data_bucket/`: bucket S3 para dados compartilhados e backend remoto do Terraform

## Ambiente

- `k8s/overlays/lab/`: composição Kubernetes do laboratório acadêmico
- `terraform/environments/lab/`: ponto de entrada Terraform do laboratório acadêmico
- `scripts/actions/ci-terraform.sh`: automação de `terraform apply/destroy` usada pelos workflows de infra

O ambiente de laboratório pode reutilizar o secret externo `oficina-database-env` no namespace `default`, mas o deploy não falha quando ele está ausente.
