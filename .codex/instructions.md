# Instruções para agentes Codex

Este projeto é uma infraestrutura baseada em Terraform, Kubernetes, scripts shell e recursos AWS.

## Regras gerais

- Use comandos reais de validação em vez de inferências.
- Não assuma que credenciais AWS, acesso de rede ao registry do Terraform, cluster EKS ativo ou contexto `kubectl` estejam disponíveis.
- Quando alterar Terraform, execute validações compatíveis do ambiente `lab`.
- Quando alterar manifests Kubernetes, renderize o overlay correspondente com `kubectl kustomize`.
- Quando alterar scripts shell, valide com `bash -n`.
- Quando a tarefa depender de AWS, prefira comandos de leitura e valide primeiro o contexto disponível.

## Terraform

Comandos preferenciais:

```bash
terraform fmt -check -recursive terraform
terraform -chdir=terraform/environments/lab init -backend=false
terraform -chdir=terraform/environments/lab validate
terraform -chdir=terraform/environments/lab plan -var-file=terraform.tfvars
```

Use `terraform fmt -check -recursive terraform` e `terraform -chdir=terraform/environments/lab validate` como validação mínima quando houver alteração em módulos, variáveis, outputs, providers, ambiente `lab` ou scripts que afetem a automação do Terraform.

Use `terraform -chdir=terraform/environments/lab plan -var-file=terraform.tfvars` quando a tarefa exigir inspeção mais fiel do impacto da infraestrutura e houver arquivo de variáveis disponível.

## Kubernetes

Use Kubernetes para validar a renderização dos manifests:

```bash
kubectl kustomize k8s/overlays/lab
```

Se a mudança afetar `base`, `components`, `addons` ou `overlays`, garanta que o overlay `lab` continue renderizando corretamente.

## Scripts

Valide scripts alterados com:

```bash
bash -n scripts/deploy-manual.sh
bash -n scripts/cleanup-orphan-eks.sh
bash -n scripts/start-port-forwards.sh
bash -n scripts/ci-deploy.sh
bash -n scripts/ci-terraform.sh
```

## AWS

Use AWS CLI quando precisar validar ambiente remoto:

```bash
aws sts get-caller-identity
```

Use comandos AWS de leitura quando forem necessários para validar EKS, ECR, API Gateway, Secrets Manager ou S3 relacionados ao projeto.

## Git

Ao concluir alterações no escopo da tarefa, prepare o commit explicitamente com:

```bash
git add <arquivos-da-tarefa>
git commit -m "<tipo>: <resumo>"
```

Prefira mensagens curtas em português seguindo Conventional Commits.
