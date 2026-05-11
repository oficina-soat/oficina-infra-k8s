# Observabilidade AWS-Native do `lab`

Esta etapa conecta a base vendor-neutral da suíte Oficina a serviços nativos da AWS com foco explícito em custo mínimo no ambiente `lab`.

## Arquitetura escolhida

- `CloudWatch Logs`
  - logs estruturados do `oficina-app` coletados no EKS via `aws-for-fluent-bit`
  - access logs JSON do API Gateway
  - logs nativos das Lambdas continuam no CloudWatch Logs
- `CloudWatch Logs Metric Filters`
  - `OsCreatedTotal`
  - `OsStatusDurationMs*` por status
  - `IntegrationFailuresTotal`
  - `OsProcessingFailuresTotal`
- `CloudWatch Metrics`
  - latência agregada e por rota do HTTP API via métricas nativas detalhadas do API Gateway
  - CPU, throttling, memória, rede e filesystem dos pods/containers do cluster via `cloudwatch-agent` mínimo, raspando `cAdvisor`
- `CloudWatch Dashboard`
  - um dashboard para métricas negociais
  - um dashboard separado para métricas técnicas
- `CloudWatch Alarms`
  - warning/critical para latência, integração, processamento de OS e healthchecks
- `Route 53 Health Checks`
  - `live` e `ready`, com integração nativa ao CloudWatch
- `SNS`
  - entrega de alertas por e-mail

## Por que esta foi a opção mais barata aceitável

- latência da API usa métrica nativa detalhada do API Gateway, sem APM nem custom metric extra
- uptime usa `Route 53 Health Checks`, que é mais barato e mais simples do que `CloudWatch Synthetics` para este caso
- dashboards ficam em `CloudWatch Dashboard`, evitando `Amazon Managed Grafana`
- métricas de negócio saem de logs estruturados com `Metric Filters`, evitando collector permanente para esses sinais
- o namespace de métricas é particionado por ambiente (`<namespace-base>/<environment>`), evitando mistura entre `lab` e ambientes futuros sem precisar de dimensões extras
- consumo k8s usa `cAdvisor` com dimensões por cluster, namespace, service, pod e container. O label `service` é derivado do nome do pod para agrupar réplicas do mesmo serviço nos gráficos:
  - `container_cpu_usage_seconds_total`
  - `container_cpu_cfs_throttled_seconds_total`
  - `container_memory_working_set_bytes`
  - `container_network_receive_bytes_total`
  - `container_network_transmit_bytes_total`
  - `container_fs_usage_bytes`
- não usa `Application Signals`, `X-Ray`, `Container Insights` completo, `Amazon Managed Prometheus` nem `SES`

## Recursos com custo recorrente mesmo com baixo tráfego

- `Route 53 Health Checks`, enquanto a stack AWS-native estiver ativa
- `CloudWatch Dashboard`, se a conta ultrapassar a faixa gratuita
- métricas customizadas contínuas de recursos k8s em `ContainerInsights/Prometheus`, enquanto `OBSERVABILITY_ENABLE_K8S_RESOURCE_METRICS=true`
- retenção de logs nos log groups do `oficina-app`, API Gateway e Prometheus/EMF

`SNS` por e-mail não tem custo fixo relevante; cobra por uso. Os metric filters de negócio só geram custo quando há logs correspondentes.

## Ativação e desativação no `lab`

O caminho integrado continua sendo o workflow `Deploy Lab`.

Para deixar a observabilidade AWS-native ligada:

- `OBSERVABILITY_ENABLED=true`
- `OBSERVABILITY_ENABLE_K8S_RESOURCE_METRICS=true`
- `OBSERVABILITY_AWS_CREDENTIALS_SECRET_ENABLED=true`
- `OBSERVABILITY_LAMBDA_FUNCTION_NAMES=["oficina-auth-lambda-lab","oficina-notificacao-lambda-lab"]`, ou a lista completa de Lambdas da suíte quando houver nomes customizados

Por padrao, `OBSERVABILITY_AWS_CREDENTIALS_SECRET_ENABLED=true`. O deploy cria a secret Kubernetes `amazon-cloudwatch/oficina-observability-aws-credentials` com as credenciais AWS do runner para que `aws-for-fluent-bit` e `cloudwatch-agent` consigam publicar no CloudWatch mesmo quando a conta do laboratorio nao permite alterar IAM.

Quando a role dos nodes ja tiver permissao equivalente a `CloudWatchAgentServerPolicy`, ou quando o runner puder executar `iam:AttachRolePolicy`, voce pode preferir `OBSERVABILITY_MANAGE_NODE_ROLE_POLICY_ATTACHMENT=true` e `OBSERVABILITY_AWS_CREDENTIALS_SECRET_ENABLED=false`.

Se as credenciais do runner forem temporarias, rode novamente o deploy quando elas forem renovadas para atualizar a secret usada pelos coletores.

Para reduzir custo recorrente sem mexer no resto da stack:

- `OBSERVABILITY_ENABLE_K8S_RESOURCE_METRICS=false`
  - mantém logs, dashboards, alarmes e healthchecks
  - escala o `cwagent-prometheus` para `0`
- `OBSERVABILITY_ENABLED=false`
  - remove toda a stack AWS-native de observabilidade do `lab`

Depois de alterar as variáveis do environment `lab`, rode novamente `Deploy Lab`.

## Dashboards

O dashboard `oficina-lab-observability` concentra as métricas negociais:

- volume de OS
- tempo médio por status
- falhas de integração e processamento

Os widgets negociais usam período de 60 segundos para evitar atraso artificial de visualização no CloudWatch. Como esses sinais vêm de `CloudWatch Logs Metric Filters`, a atualização ainda depende da ingestão dos logs estruturados do `oficina-app` e da publicação padrão de métricas do CloudWatch.

O dashboard `oficina-lab-technical-observability` concentra as métricas técnicas:

- latência agregada da API, respostas 5xx e latência p95 por rota
- disponibilidade por serviço, com healthchecks do `oficina-app`, percentual sem 5xx do API Gateway e percentual sem erro das Lambdas configuradas
- volume, erros, throttles e duração p95 das Lambdas configuradas
- CPU, memória, rede e filesystem dos recursos k8s agrupados por serviço

Para HTTP API, a latência p95 por rota usa as dimensões detalhadas `ApiId`, `Method`, `Resource` e `Stage` publicadas pelo API Gateway. Por isso, cada route key do Terraform, como `ANY /{proxy+}`, é quebrada em `Method=ANY` e `Resource=/{proxy+}` no dashboard e nos alarmes por rota.

O widget de disponibilidade normaliza os sinais em percentual para manter uma escala única: os healthchecks `live` e `ready` do Route 53 aparecem como `0%` ou `100%`, enquanto API Gateway e Lambdas usam métricas nativas para estimar percentual sem falha no período. Cada série inclui o nome do serviço no rótulo.

Os widgets de Lambda usam período de 60 segundos. O widget de volume separa invocações no eixo esquerdo e erros/throttles no eixo direito, porque todos são contadores mas têm escala diferente. O widget de duração exibe p95 em milissegundos. Quando uma Lambda for informada como ARN ou `nome:alias`, o dashboard usa o nome base da função na dimensão `FunctionName`.

## Alertas

Topicos SNS:

- `oficina-lab-observability-warning`
- `oficina-lab-observability-critical`

Alarmes mínimos:

- `uptime-live-critical`
- `uptime-ready-warning`
- `api-latency-warning`
- `api-latency-critical`
- `api-route-<hash>-latency-warning` para cada rota publicada no HTTP API
- `api-route-<hash>-latency-critical` para cada rota publicada no HTTP API
- `api-5xx-warning`
- `api-5xx-critical`
- `integration-failures-warning`
- `integration-failures-critical`
- `os-processing-failures-warning`
- `os-processing-failures-critical`

Para receber e-mail real, configure `OBSERVABILITY_ALERT_EMAIL_ENDPOINTS` com uma lista JSON, por exemplo:

```json
["ops@example.com","owner@example.com"]
```

## Limites assumidos

- a correlação principal fica em `request_id`, `trace_id` e `span_id` nos logs estruturados
- o API Gateway sobrescreve `X-Request-Id` com `$context.requestId`, permitindo correlacionar access logs do gateway e logs JSON do backend pelo mesmo identificador
- a coleta k8s continua mínima e via Prometheus/cAdvisor; ela cobre consumo de recursos dos pods/containers, mas não habilita o pacote completo de Container Insights gerenciado
- as métricas de negócio dependem dos logs estruturados permanecerem compatíveis com os filtros CloudWatch
