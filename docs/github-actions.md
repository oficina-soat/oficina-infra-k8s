# GitHub Actions

O deploy automatizado usa o workflow `./.github/workflows/deploy-lab.yml`.

Para operações de infraestrutura sem deploy da aplicação, use também:

- `./.github/workflows/terraform-apply-lab.yml`
- `./.github/workflows/terraform-destroy-lab.yml`
- `./.github/workflows/eks-deactivate-lab.yml`
- `./.github/workflows/eks-activate-lab.yml`
- `./.github/workflows/cleanup-orphan-eks-lab.yml`

## Gatilho

- `push` em branch protegida
- `workflow_dispatch` para execução manual

Os jobs usam o GitHub Environment `lab`.

Os workflows também aceitam `organization secrets/variables` e `repository secrets/variables` com os mesmos nomes. A precedência do GitHub Actions é: `environment` > `repository` > `organization`.

Todos os workflows que alteram a infraestrutura compartilham o mesmo grupo de `concurrency`, então `apply`, `deploy`, `destroy`, `deactivate/activate EKS` e `cleanup` não executam em paralelo no mesmo ambiente.

## Desativar e reativar somente o EKS

O EKS não possui um modo nativo de "stop". Para parar também o custo do control plane, o workflow `Deactivate EKS Lab` executa um `terraform destroy` direcionado somente ao alvo `module.eks`. Isso remove o cluster EKS, o managed node group e os access entries, mantendo VPC, subnets, ECR, bucket de state e API Gateway.

O workflow `Activate EKS Lab` faz o caminho inverso: executa um `terraform apply` direcionado ao alvo `module.eks` e recria somente o módulo EKS usando as mesmas variáveis de EKS do ambiente `lab`.

Esses dois workflows exigem que o state remoto já exista. Se o laboratório ainda não passou pelo bootstrap, rode primeiro `Terraform Apply Lab` ou `Deploy Lab`.

Ao desativar o EKS, os objetos Kubernetes dentro do cluster são removidos junto com o cluster. Depois de reativar, rode `Deploy Lab` se precisar recriar a aplicação, Keycloak, MailHog ou outros manifestos Kubernetes.

## Autenticação AWS

O caminho mais simples para este laboratório é usar credenciais temporárias do AWS CLI armazenadas como secrets do GitHub Environment:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_SESSION_TOKEN`

Como o laboratório recria essas credenciais a cada sessão, esses secrets precisam ser atualizados sempre que o laboratório for reiniciado.

## Variáveis do Environment

- `AWS_REGION`
- `EKS_CLUSTER_NAME`
- `KUBERNETES_VERSION`

Se `KUBERNETES_VERSION` não for informado em `vars`, o workflow usa o padrão `1.35`.

Variáveis opcionais:

- `DEPLOY_APP`: controla o deploy da aplicação no cluster. Use `auto`, `true` ou `false`. Padrão do workflow `Deploy Lab`: `auto`
- `IMAGE_REF`: referência completa da imagem. Se informado, tem prioridade sobre `IMAGE_TAG`
- `IMAGE_TAG`: tag da imagem. Quando `DEPLOY_APP=true` ou `DEPLOY_APP=auto` e `IMAGE_REF` não for informado, o workflow monta `${ecr_repository_url}:${IMAGE_TAG}` automaticamente a partir do output do Terraform capturado no mesmo `apply`. Se `IMAGE_TAG` não for informado, o workflow usa a imagem tagueada mais recente do ECR
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
- `CREATE_API_GATEWAY`
- `API_GATEWAY_NAME`
- `API_GATEWAY_STAGE_NAME`
- `API_GATEWAY_ENABLE_ACCESS_LOGS`
- `API_GATEWAY_ACCESS_LOG_RETENTION_IN_DAYS`
- `API_GATEWAY_DEFAULT_ROUTE_THROTTLING_BURST_LIMIT`
- `API_GATEWAY_DEFAULT_ROUTE_THROTTLING_RATE_LIMIT`
- `API_GATEWAY_VPC_LINK_SUBNET_IDS`: lista JSON de subnets
- `API_GATEWAY_VPC_LINK_SECURITY_GROUP_IDS`: lista JSON de security groups
- `API_GATEWAY_CREATE_VPC_LINK_SECURITY_GROUP`
- `API_GATEWAY_HTTP_ROUTES`: objeto JSON compatível com `api_gateway_http_routes`
- `API_GATEWAY_LAMBDA_ROUTES`: objeto JSON compatível com `api_gateway_lambda_routes`
- `CREATE_TERRAFORM_SHARED_DATA_BUCKET`
- `TERRAFORM_SHARED_DATA_BUCKET_NAME`
- `TERRAFORM_SHARED_DATA_BUCKET_FORCE_DESTROY`
- `TF_STATE_BUCKET`
- `TF_STATE_KEY`
- `TF_STATE_REGION`
- `TF_STATE_DYNAMODB_TABLE`
- `DEPLOY_KEYCLOAK`
- `REGENERATE_JWT`
- `FETCH_RUNTIME_SECRETS_FROM_AWS`: controla a busca automática de secrets de runtime no AWS Secrets Manager. Padrão: `true`
- `K8S_DATABASE_SECRET_ID`: secret do Secrets Manager usado para recriar `oficina-database-env` quando `K8S_DATABASE_ENV_FILE` não for informado. Padrão: `oficina/lab/database/app`
- `K8S_JWT_SECRET_ID`: secret do Secrets Manager usado para recriar `oficina-jwt-keys` quando existir. Padrão: `oficina/lab/jwt`

## Secrets opcionais

- `K8S_DATABASE_ENV_FILE`: conteúdo completo do arquivo `.env` usado para criar ou atualizar opcionalmente o secret `oficina-database-env` no cluster quando a aplicação for implantada

Se `K8S_DATABASE_ENV_FILE` não for informado, o workflow tenta recriar `oficina-database-env` a partir de `K8S_DATABASE_SECRET_ID` no AWS Secrets Manager. O secret pode ser um `.env` em texto ou um JSON plano de chaves e valores. O deploy também acrescenta as variáveis SSL necessárias para o RDS do laboratório: `QUARKUS_DATASOURCE_REACTIVE_POSTGRESQL_SSL_MODE=require` e `QUARKUS_DATASOURCE_REACTIVE_TRUST_ALL=true`.

Quando `K8S_JWT_SECRET_ID` existir no Secrets Manager, ele deve ser JSON com `privateKey`/`publicKey`, `privateKey.pem`/`publicKey.pem` ou `JWT_PRIVATE_KEY`/`JWT_PUBLIC_KEY`. Se ele não existir, o deploy gera um novo par de chaves JWT para o cluster.

Depois de aplicar o overlay, o deploy valida o rollout de `mailhog` e `oficina-app`; para a aplicação, também confirma que o `service/oficina-app` possui endpoints prontos.

## Estado do Terraform

Se `TF_STATE_BUCKET` for informado, o workflow habilita backend remoto S3 com `TF_STATE_KEY`, `TF_STATE_REGION` e, opcionalmente, `TF_STATE_DYNAMODB_TABLE`.

Se o bucket ainda não existir, o script faz bootstrap com state local, cria o bucket via Terraform, migra o state para o backend S3 e continua o deploy.

Se o bucket já existir, o script o reutiliza normalmente. Quando o bucket já faz parte do state desse ambiente, ele continua sendo gerenciado pelo Terraform; quando for um bucket externo preexistente, o workflow apenas o usa como backend sem tentar recriá-lo.

Se `TF_STATE_BUCKET` não for informado, o workflow deriva automaticamente o nome do bucket compartilhado a partir do cluster e da conta AWS, usa state local apenas durante o bootstrap e migra em seguida para backend remoto S3. Em outras palavras: a ausência de `TF_STATE_BUCKET` não desabilita o backend remoto; ela apenas faz o workflow calcular o nome do bucket automaticamente.

No workflow manual de `destroy`, se o bucket S3 de backend fizer parte do state desse ambiente, o script migra o state para backend local antes de destruir a infraestrutura. Isso evita o bloqueio clássico de tentar apagar o próprio bucket usado pelo backend remoto.

Se um `apply` falhar depois de criar recursos AWS, mas antes de persistir o state remoto, use o workflow manual `Cleanup Orphan Lab Infra`. Ele remove o cluster EKS órfão, a VPC/subnets/route tables/internet gateway/security groups associados ao laboratório e também o API Gateway do lab, incluindo `VPC Link` e o log group `/aws/apigateway/<API_GATEWAY_NAME>`, permitindo um novo bootstrap limpo.
