# oficina-k8s-infra

Infraestrutura Terraform e Kubernetes da Oficina com baseline voltado para laboratório acadêmico, priorizando simplicidade operacional e baixo custo.

O projeto provisiona a base da nuvem e publica a aplicação com:

- VPC enxuta com duas sub-redes públicas para evitar NAT Gateway
- cluster Amazon EKS com managed node group mínimo para laboratório
- repositório Amazon ECR opcional para a imagem da aplicação
- API Gateway HTTP API com logs e throttling, pronto para expor app HTTP e Lambdas de forma opcional
- manifests Kubernetes organizados com `kustomize` em `base`, `components`, `addons` e `overlays`
- telemetria vendor-neutral preparada com logs JSON, OpenTelemetry e probes HTTP no `oficina-app`
- workflow de GitHub Actions para validar `develop`, promover mudanças para `main` via PR e fazer deploy completo após merge em `main`
- workflow manual de GitHub Actions para desativar somente o EKS sem remover VPC, ECR, API Gateway e state remoto

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
- `docs/telemetria.md`: convenção de telemetria vendor-neutral da suíte

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
- `expose_oficina_app_api_gateway`: publica o `oficina-app` na raiz do HTTP API usando `VPC_LINK`, NLB interno e o `NodePort` do Service Kubernetes. Padrão: `true`
- `oficina_app_api_gateway_jwt_authorizer_enabled`: quando `true`, ativa o JWT authorizer nativo do HTTP API nas rotas padrão do `oficina-app`
- `oficina_app_api_gateway_jwt_issuer`: issuer esperado para os access tokens; se omitido, usa o endpoint público do próprio HTTP API
- `oficina_app_api_gateway_jwt_audience`: audience do authorizer. Contrato atual: `["oficina-app"]`
- `oficina_app_api_gateway_jwt_scopes`: scopes exigidos nas rotas protegidas. Padrão e contrato atual: `["oficina-app"]`
- `oficina_app_node_port`: `NodePort` fixo usado como target do NLB interno. Padrão: `30080`, alinhado ao manifesto em `k8s/base/oficina-app`
- `oficina_app_private_listener_port`: porta privada do listener do NLB interno usado pelo API Gateway. Padrão: `8080`
- `expose_mailhog_smtp_private_nlb`: publica o SMTP do MailHog por NLB interno para a `notificacao-lambda`. Padrão: `true`
- `mailhog_smtp_node_port`: `NodePort` fixo do Service `mailhog-smtp-private`. Padrão: `31025`
- `mailhog_smtp_private_listener_port`: porta privada do listener do NLB interno do SMTP do MailHog. Padrão: `1025`
- `notificacao_lambda_security_group_name`: nome do SG dedicado da `notificacao-lambda`. Se omitido, usa `<cluster_name>-notificacao-lambda`
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
- `oficina_app_public_base_url`
- `oficina_app_private_nlb_dns_name`
- `oficina_app_private_nlb_listener_arn`
- `oficina_app_node_port`
- `mailhog_smtp_private_nlb_dns_name`
- `mailhog_smtp_private_listener_port`
- `mailhog_smtp_node_port`
- `notificacao_lambda_security_group_name`
- `notificacao_lambda_security_group_id`
- `terraform_shared_data_bucket_name`
- `vpc_id`
- `public_subnet_ids`

## API Gateway

O ambiente `lab` cria um `API Gateway HTTP API` por padrão porque ele oferece o melhor equilíbrio para laboratório acadêmico: custo por requisição, menor complexidade operacional que o `REST API` e suporte tanto a backends HTTP quanto a Lambda.

Por padrão, o ambiente `lab` publica o `oficina-app` diretamente na raiz do gateway, sem prefixo:

- `ANY /`
- `ANY /{proxy+}`

Essa publicação usa integração privada `VPC_LINK`. O Terraform cria um NLB interno com listener TCP na porta `8080`, registra o Auto Scaling Group do node group EKS em um target group na porta `30080` e configura o HTTP API para usar o listener ARN como `integration_uri`. No Kubernetes, o Service `oficina-app` permanece sem `LoadBalancer` público e usa `type: NodePort` com `nodePort: 30080`, encaminhando para `targetPort: 8080` nos pods.

Para o MailHog, o ambiente `lab` também cria um NLB interno separado para SMTP. O Kubernetes expõe o Service `mailhog-smtp-private` em `NodePort 31025`, e o Terraform publica esse NodePort em um listener TCP privado na porta `1025`, liberado apenas para o security group dedicado da `notificacao-lambda`. Isso mantém o MailHog inacessível pela internet e evita abrir o SMTP para toda a VPC.

O gateway ainda não exige que a aplicação esteja pronta no momento do `apply`: os recursos AWS são criados, mas as chamadas só retornam sucesso depois que o overlay Kubernetes do `oficina-app` estiver aplicado e com endpoints prontos. Para voltar ao comportamento de gateway sem rota padrão, defina:

```hcl
expose_oficina_app_api_gateway = false
```

Quando `oficina_app_api_gateway_jwt_authorizer_enabled = true`, a rota padrão `ANY /` e `ANY /{proxy+}` passa a exigir JWT authorizer nativo do HTTP API com:

- `issuer`: `oficina_app_api_gateway_jwt_issuer` ou, se nulo, o endpoint público do próprio HTTP API
- `audience`: `["oficina-app"]`
- `scope`: `["oficina-app"]` por padrão

Nesse modo, a exposição do `oficina-app` fica em deny by default no gateway. Permanecem públicas apenas as exceções necessárias para a suíte atual:

- `GET /q/swagger-ui`
- `GET /q/swagger-ui/`
- `GET /q/swagger-ui/{proxy+}`
- `GET /q/health/live`
- `GET /q/health/ready`
- `GET /ordem-de-servico/{id}/acompanhar-link`
- `GET|POST /ordem-de-servico/{id}/aprovar-link`
- `GET|POST /ordem-de-servico/{id}/recusar-link`

`/q/openapi` não fica público quando a flag está ativa.

Para a aplicação principal, há dois padrões suportados:

- rota HTTP pública, usando `HTTP_PROXY` com uma URL já publicada
- rota privada, usando `HTTP_PROXY` com `connection_type = "VPC_LINK"` e `integration_uri` apontando para um listener ARN de ALB ou NLB

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

Com a rota padrão do `oficina-app`, o teste público usa o output `oficina_app_public_base_url`:

```bash
API_URL="$(terraform -chdir=terraform/environments/lab output -raw oficina_app_public_base_url)"
curl -i "${API_URL}/q/swagger-ui/"
curl -i "${API_URL}/q/openapi"
curl -i "${API_URL}/q/health/live"
curl -i "${API_URL}/q/health/ready"
curl -i "${API_URL}/ordem-de-servico/2b2276e8-fa72-4f4c-a3b0-2c5b1bf427ef/acompanhar-link?actionToken=<magic-link>"
curl -i -H "Authorization: Bearer <jwt-valido>" "${API_URL}/ordem-de-servico"
```

## Observabilidade

O repositório mantém duas camadas complementares de observabilidade:

- a convenção vendor-neutral da suíte, preservada em [docs/telemetria.md](docs/telemetria.md)
- a implantação AWS-native do `lab`, descrita em [docs/observabilidade-aws.md](docs/observabilidade-aws.md)

- logs estruturados em JSON no app
- OpenTelemetry habilitado para tracing e propagação de contexto
- métricas de negócio e técnicas expostas pelo app
- probes Kubernetes em `GET /q/health/live` e `GET /q/health/ready`
- env vars OTEL e `OFICINA_OBSERVABILITY_*` padronizadas no `ConfigMap`
- dashboard, alarmes, healthchecks e log groups na AWS para o ambiente `lab`

Contratos e arquitetura:

- [docs/telemetria.md](docs/telemetria.md)
- [docs/observabilidade-aws.md](docs/observabilidade-aws.md)

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
- reutiliza chaves JWT em `JWT_DIR`; se ausentes, gera um par local
- aplica o overlay `k8s/overlays/lab`
- opcionalmente publica o addon `k8s/addons/keycloak`

Para acesso local:

```bash
./scripts/start-port-forwards.sh
```

## Deploy com GitHub Actions

O repositório mantém três workflows para o ambiente de laboratório:

- [`.github/workflows/deploy-lab.yml`](.github/workflows/deploy-lab.yml): valida o repositório, aplica a infraestrutura Terraform e publica a aplicação no EKS
- [`.github/workflows/eks-deactivate-lab.yml`](.github/workflows/eks-deactivate-lab.yml): remove somente o módulo EKS para reduzir custo quando o laboratório estiver parado
- [`.github/workflows/destroy-lab.yml`](.github/workflows/destroy-lab.yml): remove a infraestrutura completa criada pelo repositório para zerar o custo recorrente do laboratório quando ele não estiver em uso

O workflow `Deploy Lab` executa em pushes para `develop` e `main`. O job `validate` roda nas duas branches, mas o job de deploy só roda quando a ref é `main`. A execução manual por `workflow_dispatch` também deve ser feita a partir de `main`.

Em pushes para `develop`, depois que o job `validate` passa, o workflow abre automaticamente um pull request para `main` quando ainda não existir um PR aberto e houver diferença de conteúdo entre as branches. Merges reversos de `main` para `develop` sem mudança de arquivos não geram novo PR.

No deploy em `main`, o workflow executa `scripts/ci-deploy.sh`. Esse script aplica o Terraform, atualiza o kubeconfig do EKS e aplica o overlay `k8s/overlays/lab`, que inclui `oficina-app`, `oficina-app-config` e MailHog. O workflow tenta publicar a aplicação sempre; se `IMAGE_REF` não for informado, ele resolve a imagem pela tag `IMAGE_TAG` ou pela tag mais recente disponível no ECR configurado. Se nenhuma imagem válida existir, o deploy falha em vez de seguir sem a oficina.

Os jobs usam o GitHub Environment `lab` para centralizar `vars` e `secrets`.

Os workflows também aceitam `organization secrets/variables` e `repository secrets/variables` com os mesmos nomes. O GitHub resolve isso por precedência: `environment` sobrescreve `repository`, que sobrescreve `organization`.

O acesso à AWS é feito com credenciais clássicas do AWS CLI expostas como variáveis de ambiente do job, porque esse é o caminho mais simples para o laboratório atual.

Valores esperados no Environment:

- `AWS_REGION`
- `EKS_CLUSTER_NAME`
- `KUBERNETES_VERSION`
- `IMAGE_REF` ou `IMAGE_TAG`: imagem da aplicação. Se ambos forem omitidos, o workflow tenta usar a tag mais recente do ECR configurado
- `AWS_ACCESS_KEY_ID`: credencial AWS em `secrets`
- `AWS_SECRET_ACCESS_KEY`: credencial AWS em `secrets`
- `AWS_SESSION_TOKEN`: opcional, mas necessário quando o laboratório entregar credenciais temporárias

Se `KUBERNETES_VERSION` não for informado em `vars`, o workflow usa o padrão `1.35`.

Valores opcionais no Environment:

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
- `API_GATEWAY_JWT_AUTHORIZERS`: objeto JSON compatível com `api_gateway_jwt_authorizers`
- `OFICINA_APP_API_GATEWAY_JWT_AUTHORIZER_ENABLED`: default `false`; quando `true`, protege as rotas padrão da aplicação com JWT
- `OFICINA_APP_API_GATEWAY_JWT_ISSUER`: issuer do authorizer; quando ausente, usa o endpoint público do próprio HTTP API
- `OFICINA_APP_API_GATEWAY_JWT_AUDIENCE`: lista JSON de audiences; default `["oficina-app"]`
- `OFICINA_APP_API_GATEWAY_JWT_SCOPES`: lista JSON de scopes exigidos pelo authorizer; default `["oficina-app"]`
- `OFICINA_AUTH_ISSUER`: issuer repassado ao ConfigMap da aplicação; quando ausente no deploy integrado, é derivado do endpoint do API Gateway
- `OFICINA_AUTH_JWKS_URI`: JWKS repassado ao ConfigMap da aplicação; quando ausente no deploy integrado, é derivado de `OFICINA_AUTH_ISSUER`
- `OFICINA_AUTH_FORCE_LEGACY`: default `false`; quando `true`, preserva explicitamente o modo legado `oficina-api` + `file:/jwt/publicKey.pem`
- `CREATE_TERRAFORM_SHARED_DATA_BUCKET`
- `TERRAFORM_SHARED_DATA_BUCKET_NAME`
- `TERRAFORM_SHARED_DATA_BUCKET_FORCE_DESTROY`
- `TF_STATE_BUCKET`
- `TF_STATE_KEY`
- `TF_STATE_REGION`
- `TF_STATE_DYNAMODB_TABLE`
- `DEPLOY_KEYCLOAK`
- `REGENERATE_JWT`: default `false`; use `true` apenas para rotacionar explicitamente chaves locais
- `ROTATE_JWT_SECRET`: default `false`; quando `true`, rotaciona o secret JWT no Secrets Manager
- `FETCH_RUNTIME_SECRETS_FROM_AWS`
- `K8S_DATABASE_SECRET_ID`
- `K8S_JWT_SECRET_ID`: default `oficina/lab/jwt`; usado para criar/reutilizar o par JWT compartilhado com o `oficina-auth-lambda`
- `K8S_JWT_SECRET_PRIVATE_KEY_FIELD`: default `privateKeyPem`
- `K8S_JWT_SECRET_PUBLIC_KEY_FIELD`: default `publicKeyPem`
- `K8S_JWT_SECRET_KMS_KEY_ID`: KMS key opcional para criação do secret JWT

Secret opcional:

- `K8S_DATABASE_ENV_FILE`: conteúdo `.env` usado para criar ou atualizar o secret Kubernetes `oficina-database-env`

O secret de banco deve informar `QUARKUS_DATASOURCE_REACTIVE_URL` ou conter dados suficientes para o deploy montar essa URL automaticamente. Formatos aceitos:

- `.env`/JSON com `QUARKUS_DATASOURCE_REACTIVE_URL`, `QUARKUS_DATASOURCE_USERNAME` e `QUARKUS_DATASOURCE_PASSWORD`
- `.env`/JSON com `quarkus.datasource.reactive.url`, `quarkus.datasource.username` e `quarkus.datasource.password`
- `.env`/JSON com `DATABASE_URL`, `DB_URL`, `POSTGRES_URL`, `POSTGRESQL_URL`, `QUARKUS_DATASOURCE_JDBC_URL` ou `SPRING_DATASOURCE_URL`
- JSON comum do Secrets Manager/RDS com `host`, `port`, `dbname`, `username` e `password`

Se o laboratório recriar as credenciais a cada nova sessão, atualize os `secrets` `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` e, quando houver, `AWS_SESSION_TOKEN` antes do merge que vai disparar o deploy.

Se `TF_STATE_BUCKET` apontar para um bucket que ainda não existe, o script de CI faz o bootstrap automaticamente com state local, cria o bucket, migra o state para o backend S3 e segue a execução.

Se `TF_STATE_BUCKET` apontar para um bucket que já existe, o workflow reutiliza esse bucket normalmente. Quando o bucket já estiver no state desse ambiente, ele continua gerenciado pelo Terraform; quando for um bucket externo preexistente, o workflow apenas o utiliza como backend remoto sem tentar recriá-lo.

Se `TF_STATE_BUCKET` não for informado, o script deriva automaticamente o nome do bucket compartilhado a partir do cluster, da conta AWS e da região. Se necessário, ele faz bootstrap com state local e migra o state para esse backend remoto S3.

O workflow:

- valida formatação Terraform, inicialização/validação Terraform sem backend, renderização do overlay Kubernetes e sintaxe dos scripts shell
- inicializa e aplica o Terraform em `terraform/environments/lab`
- faz bootstrap do backend S3 quando necessário e migra o state para o backend remoto
- atualiza o kubeconfig do EKS e aplica a oficina com suas dependências Kubernetes, incluindo MailHog
- em pushes para `develop`, abre automaticamente um pull request para `main` depois que as validações passam e existe diferença real de conteúdo

## Operações manuais de Terraform

Use o workflow `Deploy Lab` quando quiser convergir a infraestrutura declarada neste repositório.

Use o workflow `Deactivate EKS Lab` quando quiser remover somente o EKS durante períodos de inatividade. Ele exige o valor `DEACTIVATE` no campo de confirmação e executa um `terraform destroy` direcionado ao alvo `module.eks`, preservando VPC, ECR, API Gateway e bucket de state.

O workflow `Deactivate EKS Lab` exige state remoto existente. Rode `Deploy Lab` pelo menos uma vez antes de usá-lo.

Use o workflow `Destroy Lab` quando quiser desmontar a suíte inteira do laboratório. Antes do `terraform destroy` deste repositório, ele remove também os recursos AWS criados pelos fluxos dos repositórios irmãos `oficina-auth-lambda` e `oficina-infra-db`, para evitar que ENIs de Lambda ou o RDS prendam a VPC compartilhada.

O `Destroy Lab` remove, quando existirem:

- `auth-lambda` e `notificacao-lambda`, seus log groups, o log group legado `/aws/lambda/OficinaAuthLambdaNative` e o security group dedicado do `auth-lambda`
- repositório ECR da suíte, mesmo com imagens
- RDS PostgreSQL do laboratório, log groups, alarmes, parameter group, subnet group, security group e role de enhanced monitoring
- secrets runtime compartilhados da suíte no Secrets Manager, como `oficina/lab/jwt`, `oficina/lab/database/app` e os sub-secrets de `oficina/lab/database/auth-lambda`, quando `delete_runtime_secrets=true`
- objetos de artefato das Lambdas no bucket S3 configurado, quando `delete_lambda_artifact_objects=true`

Depois disso, o workflow destrói, quando gerenciados por este repositório/state:

- VPC, subnets públicas, internet gateway, route table e associações
- cluster EKS, managed node group, access entry e access policy association
- security groups dedicados, NLBs internos, listeners, target groups e attachments
- API Gateway HTTP API, stage, integrações, rotas, JWT authorizers, VPC Link e access log group
- stack de observabilidade AWS-native: log groups, metric filters, alarmes, dashboard, tópicos SNS, subscriptions e health checks do Route 53
- repositório ECR criado por este ambiente, mesmo com imagens
- bucket S3 compartilhado do Terraform quando ele faz parte do state deste ambiente, mesmo com objetos/versionamento

Para zerar custo de armazenamento do banco, o input `skip_final_db_snapshot` fica disponível no workflow. Com o default `true`, o RDS é removido sem snapshot final.

O workflow preserva recursos externos que o laboratório apenas reutiliza, como bucket de backend remoto fora do state e repositório ECR externo.

## Validações recomendadas

```bash
terraform fmt -check -recursive terraform
terraform -chdir=terraform/environments/lab validate
kubectl kustomize k8s/overlays/lab >/tmp/oficina-lab-rendered.yaml
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
