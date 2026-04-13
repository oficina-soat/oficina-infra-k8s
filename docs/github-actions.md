# GitHub Actions

O deploy automatizado usa o workflow `./.github/workflows/deploy-lab.yml`.

Para operacoes de infraestrutura sem deploy da aplicacao, use tambem:

- `./.github/workflows/terraform-apply-lab.yml`
- `./.github/workflows/terraform-destroy-lab.yml`
- `./.github/workflows/cleanup-orphan-eks-lab.yml`

## Gatilho

- `push` em branch protegida
- `workflow_dispatch` para execução manual

O job usa o GitHub Environment `lab`.

O workflow tambem aceita `organization secrets/variables` e `repository secrets/variables` com os mesmos nomes. A precedencia do GitHub Actions e: `environment` > `repository` > `organization`.

Todos os workflows que alteram a infraestrutura compartilham o mesmo grupo de `concurrency`, entao `apply`, `deploy`, `destroy` e `cleanup` nao executam em paralelo no mesmo ambiente.

## Autenticação AWS

O caminho mais simples para este laboratório é usar credenciais temporárias do AWS CLI armazenadas como secrets do GitHub Environment:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_SESSION_TOKEN`

Como o laboratório recria essas credenciais a cada sessão, esses secrets precisam ser atualizados sempre que o laboratório for reiniciado.

## Variables do Environment

- `AWS_REGION`
- `EKS_CLUSTER_NAME`
- `KUBERNETES_VERSION`

Se `KUBERNETES_VERSION` nao for informado em `vars`, o workflow usa o default `1.35`.

Variáveis opcionais:

- `IMAGE_REF`: referencia completa da imagem. Se informado, tem prioridade sobre `IMAGE_TAG`
- `IMAGE_TAG`: tag da imagem. Quando `IMAGE_REF` nao for informado, o workflow monta `${ecr_repository_url}:${IMAGE_TAG}` automaticamente a partir do output do Terraform. Default: `latest`
- `EKS_ACCESS_PRINCIPAL_ARN`
- `EKS_CLUSTER_ROLE_ARN`
- `EKS_NODE_ROLE_ARN`
- `EKS_INSTANCE_TYPE`
- `EKS_NODE_CAPACITY_TYPE`
- `EKS_NODE_AMI_TYPE`
- `EKS_DESIRED_SIZE`
- `EKS_MIN_SIZE`
- `EKS_MAX_SIZE`
- `EKS_AZS`: lista JSON, por exemplo `["us-east-1a","us-east-1b"]`
- `EKS_PUBLIC_SUBNET_CIDRS`: lista JSON, por exemplo `["10.0.0.0/20","10.0.16.0/20"]`
- `EKS_CLUSTER_ENDPOINT_PUBLIC_ACCESS_CIDRS`: lista JSON de CIDRs
- `ECR_REPOSITORY_NAME`
- `CREATE_ECR_REPOSITORY`
- `CREATE_TERRAFORM_SHARED_DATA_BUCKET`
- `TERRAFORM_SHARED_DATA_BUCKET_NAME`
- `TERRAFORM_SHARED_DATA_BUCKET_FORCE_DESTROY`
- `TF_STATE_BUCKET`
- `TF_STATE_KEY`
- `TF_STATE_REGION`
- `TF_STATE_DYNAMODB_TABLE`
- `DEPLOY_KEYCLOAK`
- `REGENERATE_JWT`

## Secrets opcionais

- `K8S_DATABASE_ENV_FILE`: conteúdo completo do arquivo `.env` usado para criar ou atualizar o secret `oficina-database-env` no cluster

Se `K8S_DATABASE_ENV_FILE` não for informado, o workflow não cria esse secret e o deploy da aplicação só funciona se ele já existir no cluster.

## Estado do Terraform

Se `TF_STATE_BUCKET` for informado, o workflow habilita backend remoto S3 com `TF_STATE_KEY`, `TF_STATE_REGION` e, opcionalmente, `TF_STATE_DYNAMODB_TABLE`.

Se o bucket ainda nao existir, o script faz bootstrap com state local, cria o bucket via Terraform, migra o state para o backend S3 e continua o deploy.

Se o bucket ja existir, o script o reutiliza normalmente. Quando o bucket ja faz parte do state desse ambiente, ele continua sendo gerenciado pelo Terraform; quando for um bucket externo preexistente, o workflow apenas o usa como backend sem tentar recria-lo.

Se `TF_STATE_BUCKET` nao for informado, o workflow deriva automaticamente o nome do bucket compartilhado a partir do cluster e da conta AWS, usa state local apenas durante o bootstrap e migra em seguida para backend remoto S3. Em outras palavras: a ausencia de `TF_STATE_BUCKET` nao desabilita o backend remoto; ela apenas faz o workflow calcular o nome do bucket automaticamente.

No workflow manual de `destroy`, se o bucket S3 de backend fizer parte do state desse ambiente, o script migra o state para backend local antes de destruir a infraestrutura. Isso evita o bloqueio classico de tentar apagar o proprio bucket usado pelo backend remoto.

Se um `apply` falhar depois de criar recursos AWS, mas antes de persistir o state remoto, use o workflow manual `Cleanup Orphan Lab Infra`. Ele remove o cluster EKS orfao e tambem a VPC/subnets/route tables/internet gateway/security groups associados ao laboratorio, permitindo um novo bootstrap limpo.
