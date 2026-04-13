# oficina-k8s-infra

Infraestrutura Terraform e Kubernetes da Oficina com baseline voltado para laboratório acadêmico, priorizando simplicidade operacional e baixo custo.

O projeto provisiona a base da nuvem e publica a aplicação com:

- VPC enxuta com duas sub-redes públicas para evitar NAT Gateway
- cluster Amazon EKS com managed node group mínimo para laboratório
- repositório Amazon ECR opcional para a imagem da aplicação
- manifests Kubernetes organizados com `kustomize` em `base`, `components`, `addons` e `overlays`
- workflow de GitHub Actions para aplicar Terraform e fazer deploy no cluster após merge em branch protegida
- workflows manuais de GitHub Actions para `terraform apply` e `terraform destroy` sem depender de novo deploy da aplicação

## O que este projeto não cria

- banco de dados PostgreSQL
- VPC privada, NAT Gateway ou topologia de produção
- domínio, ingress público ou API Gateway
- pipeline de build da imagem da aplicação
- migrations de schema da aplicação

## Pré-requisitos

- Terraform `>= 1.6`
- AWS CLI autenticada
- tabela DynamoDB para lock do state, se quiser locking remoto
- `kubectl`
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

O ambiente `lab` cria por default um bucket S3 dedicado aos dados compartilhados do Terraform. Mesmo assim, o bootstrap precisa começar com state local:

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
- `kubernetes_version`: versão do Kubernetes. Default do projeto: `1.35`
- `eks_cluster_role_arn` e `eks_node_role_arn`: roles pré-existentes do laboratório para o control plane e os nodes; por default o ambiente `lab` usa as roles padrão do laboratório
- `eks_access_principal_arn`: principal que receberá acesso administrativo ao cluster; por default o ambiente `lab` usa `arn:aws:iam::998977374439:role/voclabs`
- `instance_type`, `desired_size`, `min_size` e `max_size`: dimensionamento do managed node group
- `public_subnet_cidrs` e `azs`: rede mínima do laboratório
- `cluster_endpoint_public_access_cidrs`: CIDRs permitidos no endpoint público do EKS
- `ecr_repository_name` e `create_ecr_repository`: repositório ECR da aplicação
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
- `terraform_shared_data_bucket_name`
- `vpc_id`
- `public_subnet_ids`

## Deploy da aplicação

Antes do deploy da aplicação, o projeto externo do banco precisa criar o secret `oficina-database-env` no namespace `default`.

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

- valida a existência do secret `oficina-database-env`
- gera ou reutiliza as chaves JWT
- aplica o overlay `k8s/overlays/lab`
- opcionalmente publica o addon `k8s/addons/keycloak`

Para acesso local:

```bash
./scripts/start-port-forwards.sh
```

## Deploy com GitHub Actions

O workflow [`.github/workflows/deploy-lab.yml`](.github/workflows/deploy-lab.yml) executa em todo `push`, mas só faz deploy quando a ref de destino é uma branch protegida. Na prática, isso cobre o merge do PR para a branch protegida.

Além dele, o repositório expõe dois workflows manuais:

- [`.github/workflows/terraform-apply-lab.yml`](.github/workflows/terraform-apply-lab.yml): executa apenas o `terraform apply`
- [`.github/workflows/terraform-destroy-lab.yml`](.github/workflows/terraform-destroy-lab.yml): executa apenas o `terraform destroy`, com confirmação explícita

O job usa o GitHub Environment `lab` para centralizar `vars` e `secrets`.

O workflow tambem aceita `organization secrets/variables` e `repository secrets/variables` com os mesmos nomes. O GitHub resolve isso por precedencia: `environment` sobrescreve `repository`, que sobrescreve `organization`.

O acesso à AWS é feito com credenciais clássicas do AWS CLI via `aws-actions/configure-aws-credentials`, porque esse é o caminho mais simples para o laboratório atual.

Valores esperados no Environment:

- `AWS_REGION`
- `EKS_CLUSTER_NAME`
- `KUBERNETES_VERSION`
- `AWS_ACCESS_KEY_ID`: credencial AWS em `secrets`
- `AWS_SECRET_ACCESS_KEY`: credencial AWS em `secrets`
- `AWS_SESSION_TOKEN`: opcional, mas necessário quando o laboratório entregar credenciais temporárias

Se `KUBERNETES_VERSION` nao for informado em `vars`, o workflow usa o default `1.35`.

Valores opcionais no Environment:

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
- `K8S_DATABASE_ENV_FILE`: em `secrets`, com o conteúdo completo do `.env` usado para criar ou atualizar o secret `oficina-database-env`

Se o laboratório recriar as credenciais a cada nova sessão, atualize os `secrets` `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` e, quando houver, `AWS_SESSION_TOKEN` antes do merge que vai disparar o deploy.

Se `TF_STATE_BUCKET` apontar para um bucket que ainda nao existe, o script de CI faz o bootstrap automaticamente com state local, cria o bucket, migra o state para o backend S3 e segue a execucao.

Se `TF_STATE_BUCKET` apontar para um bucket que ja existe, o workflow reutiliza esse bucket normalmente. Quando o bucket ja estiver no state desse ambiente, ele continua gerenciado pelo Terraform; quando for um bucket externo preexistente, o workflow apenas o utiliza como backend remoto sem tentar recria-lo.

O workflow:

- inicializa e aplica o Terraform em `terraform/environments/lab`
- monta `IMAGE_REF` automaticamente com o output `ecr_repository_url` quando apenas `IMAGE_TAG` for informado
- atualiza o kubeconfig do cluster EKS
- opcionalmente cria o secret `oficina-database-env`
- executa o deploy da aplicação no cluster

Sem `TF_STATE_BUCKET`, o workflow usa state local temporário no runner. Isso só serve para execuções efemeras, porque não preserva o state entre execuções.

## Operacoes manuais de Terraform

Use o workflow `Terraform Apply Lab` quando quiser reprovisionar apenas a infraestrutura, sem redeploy da aplicacao.

Use o workflow `Terraform Destroy Lab` quando quiser remover a infraestrutura manualmente. Esse workflow exige o valor `DESTROY` no campo de confirmação. Se o bucket S3 de backend fizer parte do state desse ambiente, o workflow migra o state para backend local antes do `destroy`, para conseguir apagar o bucket tambem.

## Validações recomendadas

```bash
terraform fmt -check -recursive terraform
terraform -chdir=terraform/environments/lab validate
kubectl kustomize k8s/overlays/lab
bash -n scripts/*.sh
```

## Perfil de custo

Defaults pensados para laboratório acadêmico:

- duas sub-redes públicas
- sem NAT Gateway
- managed node group mínimo
- `t3.medium` por default
- repositório ECR opcional
- MailHog dentro do cluster
- Keycloak apenas como addon opcional de demonstração

Esses defaults preservam:

- separação entre infraestrutura da aplicação e infraestrutura do banco
- deploy reproduzível via Terraform e `kustomize`
- publicação automatizada em branch protegida
- custo mais baixo que uma topologia de produção
