# AGENTS.md

## Contexto

Este repositório concentra a infraestrutura da Oficina para AWS e Kubernetes, com foco no ambiente `lab`.

Stack atual do projeto:

- Terraform `>= 1.6`
- AWS EKS, ECR, API Gateway HTTP API, VPC e recursos auxiliares
- Kubernetes com manifests organizados via `kustomize`
- scripts operacionais em `scripts/`
- workflows em `.github/workflows/deploy-lab.yml` e `.github/workflows/eks-deactivate-lab.yml`

Os diretórios principais são:

- `terraform/modules`: módulos reutilizáveis da infraestrutura AWS
- `terraform/environments/lab`: root module do ambiente atual
- `k8s/base`, `k8s/components` e `k8s/overlays/lab`: composição Kubernetes
- `scripts/`: automações de deploy manual, CI Terraform, CI deploy, port-forward e limpeza operacional
- `docs/`: documentação de estrutura e GitHub Actions

Este repositório faz parte de uma suíte maior. Assuma que, quando presentes na mesma raiz deste diretório, os repositórios irmãos relevantes são:

- `../oficina-app`
- `../oficina-auth-lambda`
- `../oficina-infra-db`

Quando esses repositórios estiverem disponíveis, eles devem ser consultados para manter consistência de nomes, contratos e integrações compartilhadas da suíte, especialmente:

- nomes de environments
- nomes de secrets
- nomes de variáveis de ambiente
- identificadores de recursos compartilhados
- rotas expostas publicamente
- issuer, audience e JWKS usados na autenticação
- convenções de integração entre aplicação, autenticação e infraestrutura

## Diretrizes Gerais

- Preserve a estrutura já usada no projeto: módulos Terraform reutilizáveis em `terraform/modules`, ambiente em `terraform/environments/lab` e composição Kubernetes em `k8s/base`, `k8s/components` e `k8s/overlays`.
- Prefira mudanças pequenas, objetivas e compatíveis com o padrão existente em Terraform, Kubernetes, scripts e workflows.
- Ao adicionar ou ajustar integração de infraestrutura, dê preferência aos recursos já adotados no projeto antes de introduzir novas variações arquiteturais.
- Evite introduzir módulos, recursos, variáveis, scripts ou workflows novos sem necessidade clara.
- Mantenha compatibilidade com o fluxo atual de bootstrap do state, `terraform apply`, deploy do overlay Kubernetes e publicação via API Gateway.
- Quando houver dúvida sobre nomes que precisam ser iguais entre app, autenticação e infra, consulte primeiro `../oficina-app`, `../oficina-auth-lambda` e `../oficina-infra-db` antes de definir novos valores.

## Implementação

- Mantenha o ambiente `lab` como referência principal deste repositório, salvo quando a tarefa pedir explicitamente outro ambiente.
- Preserve os contratos implícitos entre Terraform e Kubernetes, especialmente os valores compartilhados entre `terraform/environments/lab` e `k8s/overlays/lab`.
- Ao mexer no `oficina-app`, preserve coerência entre o `NodePort`, o NLB interno e o API Gateway com `VPC_LINK`.
- Ao mexer em autenticação, preserve compatibilidade com os valores e nomes compartilhados usados por `oficina-app` e `oficina-auth-lambda`, como `OFICINA_AUTH_ISSUER`, `OFICINA_AUTH_JWKS_URI`, `oficina-jwt-keys` e `oficina/lab/jwt`.
- Ao mexer em deploy, preserve os defaults e convenções atuais, como `lab`, `oficina-app`, `oficina-database-env`, `k8s/overlays/lab` e `terraform/environments/lab`, salvo quando a mudança exigir coordenação explícita com os repositórios irmãos.
- Não altere nomes de recursos, inputs Terraform, outputs, secrets, variáveis de workflow ou caminhos de scripts sem necessidade explícita.
- Se houver erro simples, warning simples ou ajuste mecânico evidente no escopo da tarefa, resolva junto em vez de deixar pendência.

## Validação

Antes de encerrar uma alteração, execute a validação compatível com o impacto da mudança:

- `terraform fmt -check -recursive terraform`
- `terraform -chdir=terraform/environments/lab init -backend=false`
- `terraform -chdir=terraform/environments/lab validate`
- `kubectl kustomize k8s/overlays/lab`
- `find scripts -type f -name '*.sh' -print0 | xargs -0 bash -n`

Use validações adicionais quando a mudança afetar comportamento de deploy, bootstrap do state, integração com AWS ou renderização de manifests.

Comandos úteis:

- `terraform -chdir=terraform/environments/lab plan -var-file=terraform.tfvars`
- `terraform -chdir=terraform/environments/lab apply -var-file=terraform.tfvars`
- `bash ./scripts/actions/ci-terraform.sh`
- `bash ./scripts/actions/ci-deploy.sh`
- `./scripts/manual/deploy-manual.sh`
- `./scripts/manual/start-port-forwards.sh`

Se alguma verificação não puder ser executada, registre isso claramente na resposta final.

## Versionamento e Build

Este projeto depende de versionamento explícito da infraestrutura e da automação operacional para manter reprodutibilidade do laboratório.

- Preserve compatibilidade com os workflows `.github/workflows/deploy-lab.yml` e `.github/workflows/eks-deactivate-lab.yml`.
- Ao alterar variáveis, outputs, scripts ou fluxos que impactem deploy, confirme se a documentação do `README.md` e de `docs/` também precisa ser atualizada.
- Não introduza mudanças que exijam intervenção manual implícita sem registrar isso no repositório.

## Commits

Sempre que houver alterações no repositório como resultado da tarefa, crie um commit ao final do trabalho.

Antes de criar o commit:

- adicione ao Git todos os arquivos novos criados no escopo da tarefa com `git add <arquivos-da-tarefa>`
- faça stage dos arquivos alterados que pertencem à tarefa

Ao criar o commit, use mensagens em português seguindo Conventional Commits:

```bash
git add <arquivos-da-tarefa>
git commit -m "<tipo>: <resumo>"
```

Exemplos válidos:

- `docs: adiciona orientações para agentes do repositório`
- `fix: corrige validacao do terraform no ambiente lab`
- `chore: ajusta script de deploy do laboratorio`
- `ci: corrige fluxo de deploy do ambiente lab`

Prefira mensagens curtas, objetivas e diretamente relacionadas à alteração.

## Restrições Práticas

- Não quebre o fluxo atual de bootstrap do state Terraform, deploy do EKS e aplicação do overlay Kubernetes.
- Não mova para este repositório responsabilidades que pertencem à aplicação ou à Lambda de autenticação.
- Não altere silenciosamente contratos compartilhados com `oficina-app`, `oficina-auth-lambda` ou `oficina-infra-db`.
- Não troque soluções já adotadas no projeto por alternativas mais complexas sem justificativa técnica clara.
- Não ignore falhas simples de lint, validação Terraform, shell ou renderização de manifests quando estiverem no escopo da tarefa.
