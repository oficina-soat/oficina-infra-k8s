# AGENTS.md

## Contexto

Este repositório concentra a infraestrutura da Oficina para AWS e Kubernetes, com foco no ambiente `lab`.

Stack e organização atuais do projeto:

- Terraform `>= 1.6`
- AWS EKS, ECR, API Gateway HTTP API e recursos de rede na AWS
- manifests Kubernetes organizados com `kustomize`
- automações operacionais em `scripts/`
- workflows em `.github/workflows/deploy-lab.yml` e `.github/workflows/eks-deactivate-lab.yml`

Os diretórios principais são:

- `terraform/modules`: módulos reutilizáveis da infraestrutura AWS
- `terraform/environments/lab`: root module do ambiente atual
- `k8s/base`, `k8s/components`, `k8s/addons` e `k8s/overlays/lab`: composição Kubernetes
- `scripts/`: deploy manual, CI Terraform, CI deploy, port-forward e limpeza operacional
- `docs/`: documentação de estrutura e GitHub Actions

Este repositório faz parte de uma suíte maior. Quando existirem na mesma raiz, consulte primeiro os repositórios irmãos relevantes para manter consistência entre aplicação, autenticação e infraestrutura:

- `../oficina-app`
- `../oficina-auth-lambda`
- `../oficina-infra-db`

Ao definir ou alterar nomes compartilhados, valide nesses repositórios antes de introduzir novos valores:

- nomes de environments
- nomes de secrets e parâmetros
- variáveis de ambiente
- rotas expostas
- nomes de recursos AWS e Kubernetes
- convenções de integração entre app, auth e infra

## Diretrizes Gerais

- Preserve a estrutura atual do projeto em Terraform, Kubernetes e scripts; prefira mudanças pequenas, objetivas e compatíveis com o padrão existente.
- Não introduza novos módulos, componentes, addons, variáveis ou recursos sem necessidade clara e sem alinhamento com a arquitetura já documentada no `README.md`.
- Ao mexer em Kubernetes, mantenha a lógica baseada em `base`, `components`, `addons` e `overlays`.
- Ao mexer em Terraform, preserve a separação entre `modules` reutilizáveis e `environments/lab` como ponto de entrada do ambiente.
- Ao mexer em automação, preserve o fluxo atual dos scripts em `scripts/` e dos workflows de GitHub Actions.
- Quando houver erro simples, warning simples ou ajuste mecânico evidente dentro do escopo da tarefa, resolva junto em vez de deixar pendência.

## Implementação

- Mantenha o ambiente `lab` como referência principal deste repositório, salvo quando a tarefa pedir explicitamente outro ambiente.
- Preserve os contratos implícitos entre Terraform e Kubernetes, especialmente os valores compartilhados entre `terraform/environments/lab` e `k8s/overlays/lab`.
- Tenha atenção especial a identificadores já padronizados no projeto, como:
  - `oficina-app`
  - `oficina-database-env`
  - `oficina/lab/jwt`
  - `k8s/overlays/lab`
  - `terraform/environments/lab`
- Ao ajustar o `Service` ou a publicação da aplicação, confirme se o `NodePort` e as integrações privadas do API Gateway continuam coerentes com a documentação e os outputs Terraform.
- Ao ajustar secrets, variáveis de ambiente ou integração com autenticação, confirme compatibilidade com `../oficina-app` e `../oficina-auth-lambda`.
- Evite alterar nomes de recursos, inputs Terraform, outputs, chaves de secret ou caminhos de workflow sem necessidade explícita, porque isso tende a quebrar integração entre repositórios da suíte.

## Validação

Antes de encerrar uma alteração, execute a validação compatível com o impacto da mudança:

- `terraform fmt -check -recursive terraform`
- `terraform -chdir=terraform/environments/lab init -backend=false`
- `terraform -chdir=terraform/environments/lab validate`
- `kubectl kustomize k8s/overlays/lab`
- `bash -n scripts/*.sh`

Quando houver mudança localizada, complemente com verificações direcionadas ao arquivo ou diretório alterado.

Se alguma verificação não puder ser executada no ambiente atual, registre isso claramente na resposta final.

## Commits

Sempre que houver alterações no repositório ao final da tarefa, crie um commit antes de encerrar a resposta.

- Use mensagens em português seguindo Conventional Commits.
- Inclua no commit todos os arquivos novos e modificados relacionados à tarefa concluída.
- Não deixe alterações relacionadas sem commit ao final do trabalho.

Exemplos válidos:

- `docs: adiciona orientações para agentes do repositório`
- `fix: corrige validacao do terraform no ambiente lab`
- `chore: ajusta script de deploy do laboratorio`
- `ci: corrige fluxo de deploy do ambiente lab`

## Restrições Práticas

- Não quebre o fluxo atual de bootstrap do state Terraform, deploy do EKS e aplicação do overlay Kubernetes.
- Não troque soluções existentes por alternativas mais complexas sem justificativa técnica clara.
- Não ignore falhas simples de lint, validação, shell ou renderização de manifests quando estiverem no escopo da tarefa.
- Não altere arquivos ou diretórios não relacionados apenas para refatoração estética.
