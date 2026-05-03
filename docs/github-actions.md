# GitHub Actions

O projeto mantém tres workflows para o ambiente `lab`:

- `./.github/workflows/deploy-lab.yml`
- `./.github/workflows/eks-deactivate-lab.yml`
- `./.github/workflows/destroy-lab.yml`

## Deploy Lab

O workflow `Deploy Lab` valida o repositório em `develop` e `main`. O deploy roda somente na branch `main`, aplicando a infraestrutura Terraform e, em seguida, os componentes base do cluster no laboratório. O `oficina-app` fica opt-in neste repositório.

Gatilhos:

- `push` em `develop` e `main`
- `workflow_dispatch` para execução manual na branch `main`

O job de validação executa:

- `terraform fmt -check -recursive terraform`
- `terraform init -backend=false` e `terraform validate` no ambiente `lab`
- `kubectl kustomize k8s/overlays/lab-platform`
- `kubectl kustomize k8s/overlays/lab-app`
- `kubectl kustomize k8s/overlays/lab`
- `find scripts -type f -name '*.sh' -print0 | xargs -0 bash -n`

O job de deploy roda depois da validação apenas quando a ref e `main`. Ele usa o GitHub Environment `lab`, configura as credenciais AWS e executa `bash ./scripts/actions/ci-deploy.sh`. Esse script faz bootstrap do backend S3 quando necessario, migra o state para o backend remoto, executa `terraform apply`, atualiza o kubeconfig do EKS e aplica sempre o overlay `k8s/overlays/lab-platform`.

O overlay `k8s/overlays/lab-platform` inclui os pods e recursos de cluster que pertencem a este repositório, como MailHog e observabilidade. O deploy da aplicação roda em modo automático: quando há `IMAGE_REF`, `IMAGE_TAG` válida ou uma tag recente no ECR configurado, o mesmo fluxo também aplica `k8s/overlays/lab-app` e cria ou atualiza os secrets Kubernetes necessários para JWT e, quando configurado, para variáveis de banco.

Em pushes para `develop`, o workflow também abre automaticamente um pull request para `main` depois que o job de validação passa. Antes de criar um novo PR, ele verifica se ha diferenças de conteúdo entre `develop` e `main` e se já existe um PR aberto de `develop` para `main`. Merges reversos de `main` para `develop` sem alteração de arquivos não geram novo PR.

## Deactivate EKS Lab

O workflow `Deactivate EKS Lab` desativa somente o EKS. Ele exige confirmação manual com o valor `DEACTIVATE` e executa `bash ./scripts/actions/ci-terraform.sh` com:

- `TERRAFORM_ACTION=destroy`
- `TERRAFORM_DESTROY_TARGETS=module.eks`
- `TERRAFORM_REQUIRE_REMOTE_STATE=true`

Isso remove o cluster EKS, o managed node group e os access entries, preservando VPC, subnets, ECR, API Gateway e bucket de state.

Esse workflow exige state remoto existente. Rode `Deploy Lab` pelo menos uma vez antes de usá-lo.

## Destroy Lab

O workflow `Destroy Lab` desmonta a suíte inteira do laboratório. Ele exige confirmação manual com o valor `DESTROY` e executa primeiro `bash ./scripts/actions/cleanup-suite-aws.sh`, seguido de `bash ./scripts/actions/ci-terraform.sh`.

O cleanup prévio remove recursos que este repositório não gerencia diretamente no state, mas que ainda prendem a VPC compartilhada ou continuam cobrando:

- `oficina-auth-lambda-lab`
- `oficina-notificacao-lambda-lab`
- log groups dessas Lambdas e o legado `/aws/lambda/OficinaAuthLambdaNative`
- security group dedicado do `auth-lambda`
- repositório ECR da suíte, mesmo com imagens
- RDS `oficina-postgres-lab`
- parameter group, subnet group, security group, role de monitoring, log groups e alarmes do banco
- secrets runtime da suíte no Secrets Manager, incluindo `oficina/lab/database/auth-lambda` e seus sub-secrets, quando `delete_runtime_secrets=true`
- objetos de artefato das Lambdas no bucket configurado, quando `delete_lambda_artifact_objects=true`

Antes de apagar as Lambdas, o cleanup remove a associação VPC delas para acelerar a liberação das ENIs. Se algum security group ainda estiver preso por ENIs da AWS, o script continua removendo os demais recursos da suíte, tenta novamente no final e deixa o `terraform destroy` avancar. Se o destroy falhar por dependencias que acabaram de ser liberadas, o workflow roda um novo cleanup e repete o destroy uma vez. Os tempos podem ser ajustados por `NETWORK_INTERFACE_WAIT_SECONDS` e `FINAL_NETWORK_INTERFACE_WAIT_SECONDS`.

Depois desse cleanup, o workflow executa o destroy Terraform deste repositório com:

- `TERRAFORM_ACTION=destroy`
- `TF_VAR_ecr_force_delete=true`
- `TF_VAR_terraform_shared_data_bucket_force_destroy=true`

Ao carregar o backend S3, o script isola qualquer `terraform.tfstate` local que não tenha sido gerado por uma migração intencional do próprio destroy. Quando o bucket compartilhado faz parte do state, a migração para state local cria um marcador temporário; se uma tentativa falhar, a próxima continua desse state local em vez de tentar migrar novamente a partir do remoto. Depois da migração, o script esvazia explicitamente o bucket compartilhado versionado antes do `terraform destroy`, removendo versões, delete markers e multipart uploads pendentes para evitar falha `BucketNotEmpty`.

Com isso, o teardown remove, quando os recursos estiverem no state deste ambiente:

- VPC, subnets publicas, internet gateway, route table e associações
- cluster EKS, managed node group, access entry e access policy association
- NLBs internos do `oficina-app` e do SMTP do MailHog, listeners, target groups e attachments
- security groups dedicados da VPC, do VPC Link e da `notificacao-lambda`
- API Gateway HTTP API, stage, rotas, integrações, JWT authorizers, VPC Link e access log group
- stack AWS-native de observabilidade: log groups, metric filters, alarmes, dashboard, tópicos SNS, subscriptions e health checks do Route 53
- repositório ECR criado por este ambiente, mesmo com imagens
- bucket S3 compartilhado do Terraform quando ele pertence a este state, mesmo com objetos e versionamento

O input `skip_final_db_snapshot` controla se o RDS será removido sem snapshot final. O default e `true`, alinhado ao objetivo de zerar custo quando o laboratório não estiver em uso.

O input `delete_shared_state_bucket` controla a remoção do bucket S3 compartilhado de state ao final do destroy. Quando `true`, ele remove o bucket inteiro, incluindo versionamento e qualquer state remoto ainda armazenado nele.

Se o laboratorio estiver reutilizando um bucket de backend remoto ou um repositorio ECR externos ao state, o workflow os preserva por design, salvo quando `delete_shared_state_bucket=true`.

## Autenticação AWS

O caminho mais simples para este laboratório e usar credenciais temporárias do AWS CLI armazenadas como secrets do GitHub Environment:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_SESSION_TOKEN`

Como o laboratório recria essas credenciais a cada sessão, esses secrets precisam ser atualizados sempre que o laboratório for reiniciado.

## Variáveis Do Environment

Variáveis principais:

- `AWS_REGION`
- `EKS_CLUSTER_NAME`
- `IMAGE_REF` ou `IMAGE_TAG` para definir a imagem da aplicação. Se ambos forem omitidos, o workflow tenta usar a tag mais recente do ECR configurado

Variáveis opcionais:

- `EKS_ACCESS_PRINCIPAL_ARN`
- `EKS_CLUSTER_ROLE_ARN`
- `EKS_NODE_ROLE_ARN`
- `EKS_AZS`: lista JSON, por exemplo `["us-east-1a","us-east-1b"]`
- `EKS_PUBLIC_SUBNET_CIDRS`: lista JSON, por exemplo `["10.0.0.0/20","10.0.16.0/20"]`
- `EKS_CLUSTER_ENDPOINT_PUBLIC_ACCESS_CIDRS`: lista JSON de CIDRs
- `ECR_REPOSITORY_NAME`
- `API_GATEWAY_NAME`
- `API_GATEWAY_VPC_LINK_SUBNET_IDS`: lista JSON de subnets
- `API_GATEWAY_VPC_LINK_SECURITY_GROUP_IDS`: lista JSON de security groups
- `EXPOSE_MAILHOG_SMTP_PRIVATE_NLB`: default `true`; cria o NLB interno do SMTP do MailHog para a `notificacao-lambda`
- `NOTIFICACAO_LAMBDA_SECURITY_GROUP_NAME`: nome do SG dedicado da `notificacao-lambda`; default `<EKS_CLUSTER_NAME>-notificacao-lambda`
- `API_GATEWAY_HTTP_ROUTES`: objeto JSON compatível com `api_gateway_http_routes`
- `API_GATEWAY_LAMBDA_ROUTES`: objeto JSON compatível com `api_gateway_lambda_routes`
- `API_GATEWAY_JWT_AUTHORIZERS`: objeto JSON compatível com `api_gateway_jwt_authorizers`
- `OFICINA_APP_API_GATEWAY_JWT_AUTHORIZER_ENABLED`: default `false`; quando `true`, protege as rotas padrão da aplicação com JWT
- `OFICINA_APP_API_GATEWAY_JWT_ISSUER`: issuer do authorizer; quando ausente, usa o endpoint publico do próprio HTTP API
- `OFICINA_AUTH_ISSUER`: issuer repassado ao ConfigMap da aplicação; quando ausente no deploy integrado, e derivado do endpoint do API Gateway
- `OFICINA_AUTH_JWKS_URI`: JWKS repassado ao ConfigMap da aplicação; quando ausente no deploy integrado, e derivado de `OFICINA_AUTH_ISSUER`
- `OFICINA_AUTH_FORCE_LEGACY`: default `false`; quando `true`, preserva explicitamente o modo legado `oficina-api` + `file:/jwt/publicKey.pem`
- `OFICINA_OBSERVABILITY_ENABLED`: default `true`; prepara logs JSON, tracing e contratos de telemetria do `oficina-app`
- `OFICINA_OBSERVABILITY_JSON_LOGS_ENABLED`: default `true`
- `OFICINA_OBSERVABILITY_METRICS_ENABLED`: default `true`
- `OFICINA_OBSERVABILITY_TRACING_ENABLED`: default `true`
- `OTEL_SERVICE_NAME`: default `oficina-app`
- `OTEL_RESOURCE_ATTRIBUTES`: default `service.namespace=oficina,deployment.environment=lab`
- `OTEL_EXPORTER_OTLP_ENDPOINT`: default vazio nesta fase
- `OTEL_EXPORTER_OTLP_PROTOCOL`: default `grpc`
- `OTEL_TRACES_EXPORTER`: default `none`
- `OTEL_METRICS_EXPORTER`: default `none`
- `OTEL_LOGS_EXPORTER`: default `none`
- `OBSERVABILITY_ENABLED`: default `true`; liga a stack AWS-native de observabilidade
- `OBSERVABILITY_ENABLE_K8S_RESOURCE_METRICS`: default `true`; quando `false`, o deploy aplica `cwagent-prometheus` com `replicas=0`
- `OBSERVABILITY_MANAGE_NODE_ROLE_POLICY_ATTACHMENT`: default `false`; use `true` apenas quando o runner puder executar `iam:AttachRolePolicy` na role dos nodes do EKS
- `OBSERVABILITY_ALERT_EMAIL_ENDPOINTS`: lista JSON de emails inscritos nos tópicos SNS, por exemplo `["ops@example.com"]`

Quando `OFICINA_APP_API_GATEWAY_JWT_AUTHORIZER_ENABLED=true`, o workflow passa a aplicar no `oficina-app` um JWT authorizer com issuer do gateway atual (ou override explicito), audience `["oficina-app"]` e scope `["oficina-app"]` por default. Nesse modo, o gateway protege a aplicação por default e deixa públicos apenas `/q/swagger-ui`, `/q/swagger-ui/`, `/q/swagger-ui/*`, `GET /q/health/live`, `GET /q/health/ready` e as rotas vigentes de magic link.
- `TERRAFORM_SHARED_DATA_BUCKET_NAME`
- `TF_STATE_BUCKET`
- `TF_STATE_KEY`
- `TF_STATE_REGION`
- `TF_STATE_DYNAMODB_TABLE`
- `REGENERATE_JWT`: default `false`; use `true` apenas para rotacionar explicitamente chaves locais
- `ROTATE_JWT_SECRET`: default `false`; quando `true`, rotaciona o secret JWT no Secrets Manager
- `FETCH_RUNTIME_SECRETS_FROM_AWS`
- `K8S_DATABASE_SECRET_ID`
- `K8S_JWT_SECRET_ID`: default `oficina/lab/jwt`; usado para criar/reutilizar o par JWT compartilhado com o `oficina-auth-lambda`
- `K8S_JWT_SECRET_KMS_KEY_ID`: KMS key opcional para criação do secret JWT

Secrets opcionais:

- `K8S_DATABASE_ENV_FILE`: conteúdo `.env` usado para criar ou atualizar o secret Kubernetes `oficina-database-env`

O secret de banco deve informar `QUARKUS_DATASOURCE_REACTIVE_URL` ou conter dados suficientes para o deploy montar essa URL automaticamente. Formatos aceitos:

- `.env`/JSON com `QUARKUS_DATASOURCE_REACTIVE_URL`, `QUARKUS_DATASOURCE_USERNAME` e `QUARKUS_DATASOURCE_PASSWORD`
- `.env`/JSON com `quarkus.datasource.reactive.url`, `quarkus.datasource.username` e `quarkus.datasource.password`
- `.env`/JSON com `DATABASE_URL`, `DB_URL`, `POSTGRES_URL`, `POSTGRESQL_URL`, `QUARKUS_DATASOURCE_JDBC_URL` ou `SPRING_DATASOURCE_URL`
- JSON comum do Secrets Manager/RDS com `host`, `port`, `dbname`, `username` e `password`

## Estado Do Terraform

Se `TF_STATE_BUCKET` for informado, o workflow habilita backend remoto S3 com `TF_STATE_KEY`, `TF_STATE_REGION` e, opcionalmente, `TF_STATE_DYNAMODB_TABLE`.

Se o bucket ainda não existir, o script faz bootstrap com state local, cria o bucket via Terraform, migra o state para o backend S3 e continua o deploy.

Se o bucket já existir, o script o reutiliza normalmente. Quando o bucket já faz parte do state desse ambiente, ele continua sendo gerenciado pelo Terraform; quando for um bucket externo preexistente, o workflow apenas o usa como backend sem tentar recriá-lo.

Se `TF_STATE_BUCKET` não for informado, o workflow deriva automaticamente o nome do bucket compartilhado a partir de `shared_infra_name`/`cluster_name` e da conta AWS, usa state local apenas durante o bootstrap e migra em seguida para backend remoto S3.

Quando o bucket já existe, mas o state remoto deste repo ainda não, o workflow permite reutilizar a rede do `oficina-infra-db` se encontrar a VPC `<shared_infra_name>-vpc` com o security group `<database_identifier>-sg` e sem sinais de EKS/API Gateway deste repo na mesma VPC.

Se um `apply` falhar depois de criar recursos AWS, mas antes de persistir o state remoto, o proximo `Deploy Lab` pode bloquear para evitar duplicacao de recursos. Nesse caso, remova ou importe os recursos orfaos antes de tentar um novo deploy.
