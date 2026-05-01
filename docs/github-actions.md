# GitHub Actions

O projeto mantem apenas dois workflows para o ambiente `lab`:

- `./.github/workflows/deploy-lab.yml`
- `./.github/workflows/eks-deactivate-lab.yml`

## Deploy Lab

O workflow `Deploy Lab` valida o repositorio em `develop` e `main`. O deploy completo roda somente na branch `main`, aplicando a infraestrutura Terraform e, em seguida, o overlay Kubernetes do laboratorio com `oficina-app` e MailHog.

Gatilhos:

- `push` em `develop` e `main`
- `workflow_dispatch` para execucao manual na branch `main`

O job de validacao executa:

- `terraform fmt -check -recursive terraform`
- `terraform init -backend=false` e `terraform validate` no ambiente `lab`
- `kubectl kustomize k8s/overlays/lab`
- `bash -n scripts/*.sh`

O job de deploy roda depois da validacao apenas quando a ref e `main`. Ele usa o GitHub Environment `lab`, configura as credenciais AWS e executa `bash ./scripts/ci-deploy.sh`. Esse script faz bootstrap do backend S3 quando necessario, migra o state para o backend remoto, executa `terraform apply`, atualiza o kubeconfig do EKS e aplica o overlay `k8s/overlays/lab`.

O overlay `k8s/overlays/lab` inclui a aplicacao `oficina-app`, o `ConfigMap` da aplicacao e o componente MailHog. O deploy tambem cria ou atualiza os secrets Kubernetes necessarios para JWT e, quando configurado, para variaveis de banco.

Em pushes para `develop`, o workflow tambem abre automaticamente um pull request para `main` depois que o job de validacao passa. Antes de criar um novo PR, ele verifica se ha diferencas de conteudo entre `develop` e `main` e se ja existe um PR aberto de `develop` para `main`. Merges reversos de `main` para `develop` sem alteracao de arquivos nao geram novo PR.

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
- `IMAGE_REF` ou `IMAGE_TAG` para definir a imagem da aplicacao. Se ambos forem omitidos, o workflow tenta usar a tag mais recente do ECR configurado

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
- `EXPOSE_MAILHOG_SMTP_PRIVATE_NLB`: default `true`; cria o NLB interno do SMTP do MailHog para a `notificacao-lambda`
- `MAILHOG_SMTP_NODE_PORT`: default `31025`; deve bater com o manifesto Kubernetes `mailhog-smtp-private`
- `MAILHOG_SMTP_PRIVATE_LISTENER_PORT`: default `1025`
- `NOTIFICACAO_LAMBDA_SECURITY_GROUP_NAME`: nome do SG dedicado da `notificacao-lambda`; default `<EKS_CLUSTER_NAME>-notificacao-lambda`
- `API_GATEWAY_HTTP_ROUTES`: objeto JSON compativel com `api_gateway_http_routes`
- `API_GATEWAY_LAMBDA_ROUTES`: objeto JSON compativel com `api_gateway_lambda_routes`
- `API_GATEWAY_JWT_AUTHORIZERS`: objeto JSON compativel com `api_gateway_jwt_authorizers`
- `OFICINA_APP_API_GATEWAY_JWT_AUTHORIZER_ENABLED`: default `false`; quando `true`, protege as rotas padrao da aplicacao com JWT
- `OFICINA_APP_API_GATEWAY_JWT_ISSUER`: issuer do authorizer; quando ausente, usa o endpoint publico do proprio HTTP API
- `OFICINA_APP_API_GATEWAY_JWT_AUDIENCE`: lista JSON de audiences; default `["oficina-app"]`
- `OFICINA_APP_API_GATEWAY_JWT_SCOPES`: lista JSON de scopes exigidos pelo authorizer; default `["oficina-app"]`
- `OFICINA_AUTH_ISSUER`: issuer repassado ao ConfigMap da aplicacao; quando ausente no deploy integrado, e derivado do endpoint do API Gateway
- `OFICINA_AUTH_JWKS_URI`: JWKS repassado ao ConfigMap da aplicacao; quando ausente no deploy integrado, e derivado de `OFICINA_AUTH_ISSUER`
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
- `OBSERVABILITY_ENVIRONMENT_NAME`: default `lab`
- `OBSERVABILITY_ENABLE_DASHBOARD`: default `true`
- `OBSERVABILITY_ENABLE_ROUTE53_HEALTHCHECKS`: default `true`
- `OBSERVABILITY_ENABLE_K8S_RESOURCE_METRICS`: default `true`; quando `false`, o deploy aplica `cwagent-prometheus` com `replicas=0`
- `OBSERVABILITY_ALERT_EMAIL_ENDPOINTS`: lista JSON de emails inscritos nos tópicos SNS, por exemplo `["ops@example.com"]`
- `OBSERVABILITY_APP_LOG_RETENTION_IN_DAYS`: default `14`
- `OBSERVABILITY_PROMETHEUS_LOG_RETENTION_IN_DAYS`: default `7`
- `OBSERVABILITY_METRIC_NAMESPACE`: default `Oficina/Observability`
- `OBSERVABILITY_API_LATENCY_WARNING_THRESHOLD_MS`: default `1500`
- `OBSERVABILITY_API_LATENCY_CRITICAL_THRESHOLD_MS`: default `3000`
- `OBSERVABILITY_INTEGRATION_FAILURES_WARNING_THRESHOLD`: default `1`
- `OBSERVABILITY_INTEGRATION_FAILURES_CRITICAL_THRESHOLD`: default `3`
- `OBSERVABILITY_OS_PROCESSING_FAILURES_WARNING_THRESHOLD`: default `1`
- `OBSERVABILITY_OS_PROCESSING_FAILURES_CRITICAL_THRESHOLD`: default `3`
- `OBSERVABILITY_ALARM_PERIOD_SECONDS`: default `300`
- `OBSERVABILITY_APP_LOG_GROUP_NAME`: default `/oficina/lab/eks/oficina-app`
- `OBSERVABILITY_PROMETHEUS_LOG_GROUP_NAME`: default `/aws/containerinsights/<EKS_CLUSTER_NAME>/prometheus`
- `OBSERVABILITY_FLUENT_BIT_IMAGE`: default `public.ecr.aws/aws-observability/aws-for-fluent-bit:2.34.3.20260423`
- `OBSERVABILITY_CWAGENT_IMAGE`: default `public.ecr.aws/cloudwatch-agent/cloudwatch-agent:1.300066.1`

Quando `OFICINA_APP_API_GATEWAY_JWT_AUTHORIZER_ENABLED=true`, o workflow passa a aplicar no `oficina-app` um JWT authorizer com issuer do gateway atual (ou override explicito), audience `["oficina-app"]` e scope `["oficina-app"]` por default. Nesse modo, o gateway protege a aplicacao por default e deixa publicos apenas `/q/swagger-ui`, `/q/swagger-ui/`, `/q/swagger-ui/*`, `GET /q/health/live`, `GET /q/health/ready` e as rotas vigentes de magic link.
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

Secrets opcionais:

- `K8S_DATABASE_ENV_FILE`: conteudo `.env` usado para criar ou atualizar o secret Kubernetes `oficina-database-env`

O secret de banco deve informar `QUARKUS_DATASOURCE_REACTIVE_URL` ou conter dados suficientes para o deploy montar essa URL automaticamente. Formatos aceitos:

- `.env`/JSON com `QUARKUS_DATASOURCE_REACTIVE_URL`, `QUARKUS_DATASOURCE_USERNAME` e `QUARKUS_DATASOURCE_PASSWORD`
- `.env`/JSON com `quarkus.datasource.reactive.url`, `quarkus.datasource.username` e `quarkus.datasource.password`
- `.env`/JSON com `DATABASE_URL`, `DB_URL`, `POSTGRES_URL`, `POSTGRESQL_URL`, `QUARKUS_DATASOURCE_JDBC_URL` ou `SPRING_DATASOURCE_URL`
- JSON comum do Secrets Manager/RDS com `host`, `port`, `dbname`, `username` e `password`

## Estado Do Terraform

Se `TF_STATE_BUCKET` for informado, o workflow habilita backend remoto S3 com `TF_STATE_KEY`, `TF_STATE_REGION` e, opcionalmente, `TF_STATE_DYNAMODB_TABLE`.

Se o bucket ainda nao existir, o script faz bootstrap com state local, cria o bucket via Terraform, migra o state para o backend S3 e continua o deploy.

Se o bucket ja existir, o script o reutiliza normalmente. Quando o bucket ja faz parte do state desse ambiente, ele continua sendo gerenciado pelo Terraform; quando for um bucket externo preexistente, o workflow apenas o usa como backend sem tentar recria-lo.

Se `TF_STATE_BUCKET` nao for informado, o workflow deriva automaticamente o nome do bucket compartilhado a partir do cluster e da conta AWS, usa state local apenas durante o bootstrap e migra em seguida para backend remoto S3.

Se um `apply` falhar depois de criar recursos AWS, mas antes de persistir o state remoto, o proximo `Deploy Lab` pode bloquear para evitar duplicacao de recursos. Nesse caso, remova ou importe os recursos orfaos antes de tentar um novo deploy.
