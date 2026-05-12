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
  - `OsStatusTransitionsTotal*` por status de destino
  - `IntegrationFailuresTotal`
  - `OsProcessingFailuresTotal`, derivado dos logs HTTP estruturados do `oficina-app`
- `CloudWatch Metrics`
  - latência agregada, latência de integração, 4xx, 5xx e latência por rota do HTTP API via métricas nativas detalhadas do API Gateway
- CPU, throttling, memória e rede dos pods/containers do cluster via `cloudwatch-agent` mínimo, raspando `cAdvisor`
- latência e falhas de integração do `oficina-app` via scrape Prometheus de `/q/metrics`
- `CloudWatch Dashboard`
  - um dashboard para métricas negociais
  - um dashboard separado para métricas técnicas
- `CloudWatch Alarms`
  - warning/critical para latência, integração, processamento de OS detectado no app e healthchecks
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

- volume diário de OS
- tempo médio por status
- transições diárias por status
- falhas diárias de integração e processamento

Os widgets negociais de contagem usam período de 1 dia e estatística `Sum`, exibindo buckets diários para volume de OS e falhas. O widget de tempo médio por status continua com período de 60 segundos e `setPeriodToTimeRange`, para resumir a janela selecionada no dashboard. Como esses sinais vêm de `CloudWatch Logs Metric Filters`, a atualização ainda depende da ingestão dos logs estruturados do `oficina-app` e da publicação padrão de métricas do CloudWatch.

O dashboard negocial abre por padrão com janela de 7 dias e `periodOverride=inherit`, para preservar os períodos configurados nos widgets e evitar que o console do CloudWatch aplique período automático incompatível com os buckets diários.

O dashboard `oficina-lab-technical-observability` concentra as métricas técnicas:

- latência agregada da API, respostas 5xx e latência p95 por rota
- latência de integração e respostas 4xx do API Gateway
- disponibilidade por serviço, com healthchecks do `oficina-app` e percentual sem 5xx do API Gateway
- latência e falhas de integração por integração/operação
- saúde HTTP por rota da API, calculada por `Count` e `5xx`
- volume, throttles, concorrência e duração p95 das Lambdas configuradas
- CPU, throttling, memória e rede dos recursos k8s agrupados por serviço
- consultas Logs Insights para falhas recentes de OS, integrações e 5xx do gateway

O dashboard técnico não exibe filesystem por serviço porque `container_fs_usage_bytes` pode não trazer labels de pod/container suficientes em todos os runtimes, especialmente com containerd/cAdvisor, o que deixa a série por `service` vazia no CloudWatch. O quarto gráfico k8s usa throttling de CPU por serviço, que é coletado pelo mesmo `cAdvisor` e mantém a agregação por serviço consistente.

Para HTTP API, a latência p95 por rota usa as dimensões detalhadas `ApiId`, `Method`, `Resource` e `Stage` publicadas pelo API Gateway. Por isso, cada route key do Terraform, como `ANY /{proxy+}`, é quebrada em `Method=ANY` e `Resource=/{proxy+}` no dashboard e nos alarmes por rota.

O widget de disponibilidade normaliza os sinais em percentual para manter uma escala única: os healthchecks `live` e `ready` do Route 53 aparecem como `0%` ou `100%`, enquanto o API Gateway usa métricas nativas para estimar percentual sem 5xx no período. Cada série inclui o nome do serviço no rótulo.

O widget de saúde HTTP por rota usa as métricas `Count` e `5xx` do API Gateway para capturar falhas vistas pelo consumidor, inclusive quando uma Lambda HTTP retorna resposta 5xx sem gerar `Errors` no namespace `AWS/Lambda`. O widget técnico de Lambda usa período de 60 segundos e exibe `Invocations`, `Throttles`, `ConcurrentExecutions` com estatística `Maximum` e `Duration` p95 em milissegundos. Quando uma Lambda for informada como ARN ou `nome:alias`, o dashboard usa o nome base da função na dimensão `FunctionName`.

Os widgets de integrações do app dependem do `cwagent-prometheus` ativo. O agente raspa `oficina-app.default.svc:8080/q/metrics` e publica as métricas `integration_latency_ms_*` e `integration_failures_total` no namespace `ContainerInsights/Prometheus`, mantendo dimensões controladas por ambiente, integração, operação e tipo de falha.

Os widgets Logs Insights do dashboard técnico mantêm a investigação operacional no próprio CloudWatch. Eles exibem eventos recentes com `request_id`, `trace_id`, rota, status HTTP e detalhes de integração sempre que esses campos existirem nos logs estruturados.

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
- `api-4xx-warning`
- `api-4xx-critical`
- `integration-failures-warning`
- `integration-failures-critical`
- `os-processing-failures-warning`
- `os-processing-failures-critical`
- `k8s-memory-warning`
- `k8s-memory-critical`
- `k8s-cpu-throttling-warning`
- `k8s-cpu-throttling-critical`

Para receber e-mail real, configure `OBSERVABILITY_ALERT_EMAIL_ENDPOINTS` com uma lista JSON, por exemplo:

```json
["ops@example.com","owner@example.com"]
```

## Limites assumidos

- a correlação principal fica em `request_id`, `trace_id` e `span_id` nos logs estruturados
- o API Gateway sobrescreve `X-Request-Id` com `$context.requestId`, permitindo correlacionar access logs do gateway e logs JSON do backend pelo mesmo identificador
- a coleta k8s continua mínima e via Prometheus/cAdvisor; ela cobre consumo de recursos dos pods/containers, mas não habilita o pacote completo de Container Insights gerenciado
- as métricas de negócio dependem dos logs estruturados permanecerem compatíveis com os filtros CloudWatch
