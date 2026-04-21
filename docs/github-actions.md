# GitHub Actions

O projeto mantem apenas dois workflows para o ambiente `lab`:

- `./.github/workflows/deploy-lab.yml`
- `./.github/workflows/eks-deactivate-lab.yml`

## Deploy Lab

O workflow `Deploy Lab` garante que a infraestrutura Terraform declarada em `terraform/environments/lab` seja aplicada.

Gatilhos:

- `push` em branch protegida
- `workflow_dispatch` para execucao manual

O job de validacao executa:

- `terraform fmt -check -recursive terraform`
- `terraform init -backend=false` e `terraform validate` no ambiente `lab`
- `bash -n scripts/*.sh`

O job de deploy roda depois da validacao, usa o GitHub Environment `lab`, configura as credenciais AWS e executa `bash ./scripts/ci-terraform.sh`. Esse script faz bootstrap do backend S3 quando necessario, migra o state para o backend remoto e executa `terraform apply` no ambiente `lab`.

## Deactivate EKS Lab

O workflow `Deactivate EKS Lab` desativa somente o EKS. Ele exige confirmacao manual com o valor `DEACTIVATE` e executa `bash ./scripts/ci-terraform.sh` com:

- `TERRAFORM_ACTION=destroy`
- `TERRAFORM_DESTROY_TARGETS=module.eks`
- `TERRAFORM_REQUIRE_REMOTE_STATE=true`

Isso remove o cluster EKS, o managed node group e os access entries, preservando VPC, subnets, ECR, API Gateway e bucket de state.

Esse workflow exige state remoto existente. Rode `Deploy Lab` pelo menos uma vez antes de usa-lo.

## Autenticacao AWS

O caminho mais simples para este laboratorio e usar credenciais temporarias do AWS CLI armazenadas como secrets do GitHub Environment:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_SESSION_TOKEN`

Como o laboratorio recria essas credenciais a cada sessao, esses secrets precisam ser atualizados sempre que o laboratorio for reiniciado.

## Variaveis Do Environment

Variaveis principais:

- `AWS_REGION`
- `EKS_CLUSTER_NAME`
- `KUBERNETES_VERSION`

Se `KUBERNETES_VERSION` nao for informado em `vars`, o workflow usa o padrao `1.35`.

Variaveis opcionais:

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
- `API_GATEWAY_HTTP_ROUTES`: objeto JSON compativel com `api_gateway_http_routes`
- `API_GATEWAY_LAMBDA_ROUTES`: objeto JSON compativel com `api_gateway_lambda_routes`
- `CREATE_TERRAFORM_SHARED_DATA_BUCKET`
- `TERRAFORM_SHARED_DATA_BUCKET_NAME`
- `TERRAFORM_SHARED_DATA_BUCKET_FORCE_DESTROY`
- `TF_STATE_BUCKET`
- `TF_STATE_KEY`
- `TF_STATE_REGION`
- `TF_STATE_DYNAMODB_TABLE`

## Estado Do Terraform

Se `TF_STATE_BUCKET` for informado, o workflow habilita backend remoto S3 com `TF_STATE_KEY`, `TF_STATE_REGION` e, opcionalmente, `TF_STATE_DYNAMODB_TABLE`.

Se o bucket ainda nao existir, o script faz bootstrap com state local, cria o bucket via Terraform, migra o state para o backend S3 e continua o deploy.

Se o bucket ja existir, o script o reutiliza normalmente. Quando o bucket ja faz parte do state desse ambiente, ele continua sendo gerenciado pelo Terraform; quando for um bucket externo preexistente, o workflow apenas o usa como backend sem tentar recria-lo.

Se `TF_STATE_BUCKET` nao for informado, o workflow deriva automaticamente o nome do bucket compartilhado a partir do cluster e da conta AWS, usa state local apenas durante o bootstrap e migra em seguida para backend remoto S3.

Se um `apply` falhar depois de criar recursos AWS, mas antes de persistir o state remoto, o proximo `Deploy Lab` pode bloquear para evitar duplicacao de recursos. Nesse caso, remova ou importe os recursos orfaos antes de tentar um novo deploy.
