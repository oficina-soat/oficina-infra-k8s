# oficina-k8s-infra

Infraestrutura Terraform e Kubernetes da Oficina com baseline voltado para laboratório acadêmico, priorizando simplicidade operacional e baixo custo.

O projeto provisiona a base da nuvem e publica a aplicação com:

- VPC enxuta com duas sub-redes públicas para evitar NAT Gateway
- cluster Amazon EKS com managed node group mínimo para laboratório
- repositório Amazon ECR opcional para a imagem da aplicação
- API Gateway HTTP API com logs e throttling, pronto para expor app HTTP e Lambdas de forma opcional
- manifests Kubernetes organizados com `kustomize` em `base`, `components`, `addons` e `overlays`
- workflow de GitHub Actions para aplicar Terraform e fazer deploy no cluster após merge em branch protegida
- workflows manuais de GitHub Actions para `terraform apply`, `terraform destroy` e ativação/desativação do EKS sem depender de novo deploy da aplicação

## O que este projeto não cria

- banco de dados PostgreSQL
- VPC privada, NAT Gateway ou topologia de produção
- domínio, CDN ou WAF
- pipeline de build da imagem da aplicação
- migrations de schema da aplicação

## Pré-requisitos

- Terraform `>= 1.6`
- AWS CLI autenticada
- tabela DynamoDB para lock do state, se quiser locking remoto
- `kubectl`
- `jq`
- `openssl`
- imagem da aplicação em um registry acessível pelo cluster

## Estrutura

O repositório segue um layout em diretórios:

- `terraform/modules`: módulos reutilizáveis com os recursos AWS
- `terraform/environments/lab`: root module do ambiente atual, com provider, inputs e outputs
- `k8s/base/oficina-app`: `Deployment` e `Service` base da aplicação
- `k8s/components/mailhog`: componente de e-mail usado no laboratório
- `k8s/addons/keycloak`: addon opcional para demonstração
- `k8s/overlays/lab`: composição final do ambiente Kubernetes
- `scripts/`: automações operacionais e de CI

## Estado do Terraform

O ambiente `lab` cria por padrão um bucket S3 dedicado aos dados compartilhados do Terraform. Mesmo assim, o bootstrap manual precisa começar com state local:

```bash
terraform -chdir=terraform/environments/lab init
```

Depois do primeiro `apply`, capture o nome do bucket criado:

```bash
terraform -chdir=terraform/environments/lab output terraform_shared_data_bucket_name
```

Em seguida, migre o state para backend remoto S3. Crie um arquivo local a partir do exemplo e reconfigure o `init`:

```bash
cp terraform/environments/lab/backend.s3.tf.example terraform/environments/lab/backend.s3.tf
terraform -chdir=terraform/environments/lab init -migrate-state -force-copy \
  -backend-config="bucket=<bucket-criado>" \
  -backend-config="key=oficina/lab/terraform.tfstate" \
  -backend-config="region=<region>"
```

Se quiser lock remoto, acrescente:

```bash
-backend-config="dynamodb_table=<table>"
```

Para voltar ao state local, remova `terraform/environments/lab/backend.s3.tf` e rode:

```bash
terraform -chdir=terraform/environments/lab init -reconfigure
```

## Configuração

Use `terraform.tfvars.example` como base:

```bash
cp terraform/environments/lab/terraform.tfvars.example terraform/environments/lab/terraform.tfvars
```

Variáveis principais:

- `region`: região AWS do laboratório
- `cluster_name`: nome do cluster EKS
- `kubernetes_version`: versão do Kubernetes. Padrão do projeto: `1.35`
- `eks_cluster_role_arn` e `eks_node_role_arn`: roles preexistentes do laboratório para o control plane e os nodes; por padrão o ambiente `lab` usa as roles do laboratório
- `eks_access_principal_arn`: principal que receberá acesso administrativo ao cluster; se omitido, o Terraform tenta usar a identidade atual
- `instance_type`, `desired_size`, `min_size` e `max_size`: dimensionamento do managed node group
- `public_subnet_cidrs` e `azs`: rede mínima do laboratório
- `cluster_endpoint_public_access_cidrs`: CIDRs permitidos no endpoint público do EKS
- `ecr_repository_name` e `create_ecr_repository`: repositório ECR da aplicação
- `create_api_gateway`: cria o HTTP API do laboratório. Padrão: `true`
- `api_gateway_http_routes`: rotas `HTTP_PROXY` para expor a aplicação principal ou outros backends HTTP
- `api_gateway_lambda_routes`: rotas `AWS_PROXY` para expor Lambdas existentes
- `api_gateway_vpc_link_subnet_ids`, `api_gateway_vpc_link_security_group_ids` e `api_gateway_create_vpc_link_security_group`: usados apenas quando uma rota HTTP precisar de integração privada via `VPC_LINK`
- `create_terraform_shared_data_bucket`, `terraform_shared_data_bucket_name` e `terraform_shared_data_bucket_force_destroy`: bucket S3 usado pelos dados compartilhados do Terraform

## Aplicação da infraestrutura

```bash
terraform -chdir=terraform/environments/lab plan -var-file=terraform.tfvars
terraform -chdir=terraform/environments/lab apply -var-file=terraform.tfvars
```

Saídas principais:

- `cluster_name`
- `cluster_endpoint`
- `kubeconfig_command`
- `ecr_repository_name`
- `ecr_repository_url`
- `api_gateway_endpoint`
- `api_gateway_invoke_url`
- `terraform_shared_data_bucket_name`
- `vpc_id`
- `public_subnet_ids`

## API Gateway

O ambiente `lab` cria um `API Gateway HTTP API` por padrão porque ele oferece o melhor equilíbrio para laboratório acadêmico: custo por requisição, menor complexidade operacional que o `REST API` e suporte tanto a backends HTTP quanto a Lambda.

O gateway não exige que a aplicação principal nem os Lambdas existam no momento do `apply`. Se `api_gateway_http_routes` e `api_gateway_lambda_routes` ficarem vazios, ele é criado apenas como porta de entrada pronta para uso posterior.

Para a aplicação principal, há dois padrões suportados:

- rota HTTP pública, usando `HTTP_PROXY` com uma URL já publicada
- rota privada, usando `HTTP_PROXY` com `connection_type = "VPC_LINK"` e `integration_uri` apontando para um listener ARN de ALB

Para Lambdas, use `api_gateway_lambda_routes`. Quando `function_name` também for informado, o Terraform cria a permissão `aws_lambda_permission` para o API Gateway invocar a função.

Exemplo mínimo com app HTTP pública e um Lambda:

```hcl
api_gateway_http_routes = {
  "ANY /app" = {
    integration_uri = "https://app-lab.exemplo.edu.br/app"
  }
  "ANY /app/{proxy+}" = {
    integration_uri = "https://app-lab.exemplo.edu.br/app/{proxy}"
  }
}

api_gateway_lambda_routes = {
  "POST /payments" = {
    invoke_arn    = "arn:aws:lambda:us-east-1:123456789012:function:payments:live"
    function_name = "arn:aws:lambda:us-east-1:123456789012:function:payments:live"
  }
}
```

Se a aplicação principal for publicada por ALB privado, troque a rota HTTP por:

```hcl
api_gateway_http_routes = {
  "ANY /app" = {
    integration_uri = "arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/oficina/abc123/def456"
    connection_type = "VPC_LINK"
  }
  "ANY /app/{proxy+}" = {
    integration_uri = "arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/oficina/abc123/def456"
    connection_type = "VPC_LINK"
  }
}
```

Nesse caso, use o output `api_gateway_vpc_link_security_group_id` para liberar entrada no ALB a partir do VPC Link.

## Deploy da aplicação

Se o projeto externo do banco criar o secret `oficina-database-env` no namespace `default`, o deploy da aplicação o reutiliza automaticamente. Se esse secret não existir, o deploy segue normalmente sem carregar variáveis de banco.

Exemplo:

```bash
kubectl create secret generic oficina-database-env \
  --namespace default \
  --from-env-file=<caminho-para-o-env-do-banco>
```

Depois aplique a aplicação:

```bash
IMAGE_REF=<registry>/oficina:<tag> \
./scripts/deploy-manual.sh
```

O script:

- reutiliza o secret `oficina-database-env` quando ele existir
- gera ou reutiliza as chaves JWT
- aplica o overlay `k8s/overlays/lab`
- opcionalmente publica o addon `k8s/addons/keycloak`

Para acesso local:

```bash
./scripts/start-port-forwards.sh
```

## Deploy com GitHub Actions

O workflow [`.github/workflows/deploy-lab.yml`](.github/workflows/deploy-lab.yml) executa em todo `push`, mas só faz deploy quando a ref de destino é uma branch protegida. Na prática, isso cobre o merge do PR para a branch protegida.

Além dele, o repositório expõe workflows manuais para operações de infraestrutura:

- [`.github/workflows/terraform-apply-lab.yml`](.github/workflows/terraform-apply-lab.yml): executa apenas o `terraform apply`
- [`.github/workflows/terraform-destroy-lab.yml`](.github/workflows/terraform-destroy-lab.yml): executa apenas o `terraform destroy`, com confirmação explícita
- [`.github/workflows/eks-deactivate-lab.yml`](.github/workflows/eks-deactivate-lab.yml): remove somente o módulo EKS para reduzir custo quando o laboratório estiver parado
- [`.github/workflows/eks-activate-lab.yml`](.github/workflows/eks-activate-lab.yml): recria somente o módulo EKS
- [`.github/workflows/cleanup-orphan-eks-lab.yml`](.github/workflows/cleanup-orphan-eks-lab.yml): remove recursos órfãos quando uma execução falha antes de persistir o state remoto

Os jobs usam o GitHub Environment `lab` para centralizar `vars` e `secrets`.

Os workflows também aceitam `organization secrets/variables` e `repository secrets/variables` com os mesmos nomes. O GitHub resolve isso por precedência: `environment` sobrescreve `repository`, que sobrescreve `organization`.

O acesso à AWS é feito com credenciais clássicas do AWS CLI via `aws-actions/configure-aws-credentials`, porque esse é o caminho mais simples para o laboratório atual.

Valores esperados no Environment:

- `AWS_REGION`
- `EKS_CLUSTER_NAME`
- `KUBERNETES_VERSION`
- `AWS_ACCESS_KEY_ID`: credencial AWS em `secrets`
- `AWS_SECRET_ACCESS_KEY`: credencial AWS em `secrets`
- `AWS_SESSION_TOKEN`: opcional, mas necessário quando o laboratório entregar credenciais temporárias

Se `KUBERNETES_VERSION` não for informado em `vars`, o workflow usa o padrão `1.35`.

Valores opcionais no Environment:

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
- `K8S_DATABASE_ENV_FILE`: em `secrets`, com o conteúdo completo do `.env` usado para criar ou atualizar opcionalmente o secret `oficina-database-env`

Se o laboratório recriar as credenciais a cada nova sessão, atualize os `secrets` `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` e, quando houver, `AWS_SESSION_TOKEN` antes do merge que vai disparar o deploy.

Se `TF_STATE_BUCKET` apontar para um bucket que ainda não existe, o script de CI faz o bootstrap automaticamente com state local, cria o bucket, migra o state para o backend S3 e segue a execução.

Se `TF_STATE_BUCKET` apontar para um bucket que já existe, o workflow reutiliza esse bucket normalmente. Quando o bucket já estiver no state desse ambiente, ele continua gerenciado pelo Terraform; quando for um bucket externo preexistente, o workflow apenas o utiliza como backend remoto sem tentar recriá-lo.

Se `TF_STATE_BUCKET` não for informado, o script deriva automaticamente o nome do bucket compartilhado a partir do cluster, da conta AWS e da região. Se necessário, ele faz bootstrap com state local e migra o state para esse backend remoto S3.

O workflow:

- inicializa e aplica o Terraform em `terraform/environments/lab`
- atualiza o kubeconfig do cluster EKS
- quando `DEPLOY_APP=auto`, procura uma imagem pronta no ECR e só executa o deploy da aplicação se encontrar uma tag
- cria ou atualiza o secret `oficina-database-env` a partir de `K8S_DATABASE_ENV_FILE` ou do Secrets Manager, quando disponível
- recria `oficina-jwt-keys` a partir do Secrets Manager, quando disponível; se não existir, gera um novo par de chaves para o cluster
- monta `IMAGE_REF` automaticamente com o output `ecr_repository_url` e a tag informada ou, na ausência dela, com a tag mais recente do ECR
- aplica o overlay Kubernetes e valida o rollout de `mailhog` e `oficina-app`, além dos endpoints do `service/oficina-app`

O API Gateway continua sendo aplicado mesmo quando `DEPLOY_APP=false` ou quando `DEPLOY_APP=auto` não encontra imagem no ECR, o que permite preparar a porta de entrada antes da publicação da aplicação principal ou dos Lambdas.

Os workflows pontuais `Deactivate EKS Lab` e `Activate EKS Lab` exigem state remoto existente. Rode `Terraform Apply Lab` ou `Deploy Lab` pelo menos uma vez antes de usá-los.

## Operações manuais de Terraform

Use o workflow `Terraform Apply Lab` quando quiser reprovisionar apenas a infraestrutura, sem redeploy da aplicação.

Use o workflow `Terraform Destroy Lab` quando quiser remover a infraestrutura manualmente. Esse workflow exige o valor `DESTROY` no campo de confirmação. Se o bucket S3 de backend fizer parte do state desse ambiente, o workflow migra o state para backend local antes do `destroy`, para conseguir apagar o bucket também.

Use o workflow `Deactivate EKS Lab` quando quiser remover somente o EKS durante períodos de inatividade. Ele executa um `terraform destroy` direcionado ao alvo `module.eks`, preservando VPC, ECR, API Gateway e bucket de state. Use `Activate EKS Lab` para recriar somente esse módulo.

Use o workflow `Cleanup Orphan Lab Infra` quando houver recursos criados na AWS sem state remoto recuperável. Ele remove o cluster EKS órfão, a rede associada e também o API Gateway do laboratório, incluindo `VPC Link` e `CloudWatch Log Group`, usando `EKS_CLUSTER_NAME` e `API_GATEWAY_NAME` para localizar os recursos.

## Validações recomendadas

```bash
terraform fmt -check -recursive terraform
terraform -chdir=terraform/environments/lab validate
kubectl kustomize k8s/overlays/lab
bash -n scripts/*.sh
```

## Perfil de custo

Padrões pensados para laboratório acadêmico:

- duas sub-redes públicas
- sem NAT Gateway
- managed node group mínimo
- `t3.medium` por padrão
- repositório ECR opcional
- API Gateway HTTP API com logs e throttling padrão
- MailHog dentro do cluster
- Keycloak apenas como addon opcional de demonstração

Esses padrões preservam:

- separação entre infraestrutura da aplicação e infraestrutura do banco
- deploy reproduzível via Terraform e `kustomize`
- publicação automatizada em branch protegida
- custo mais baixo que uma topologia de produção
