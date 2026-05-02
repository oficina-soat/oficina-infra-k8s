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
  - latência do HTTP API via métricas nativas do API Gateway
  - CPU e memória do `oficina-app` via `cloudwatch-agent` mínimo, raspando `cAdvisor`
- `CloudWatch Dashboard`
  - um dashboard consolidado para negócio e operação mínima
- `CloudWatch Alarms`
  - warning/critical para latência, integração, processamento de OS e healthchecks
- `Route 53 Health Checks`
  - `live` e `ready`, com integração nativa ao CloudWatch
- `SNS`
  - entrega de alertas por e-mail

## Por que esta foi a opção mais barata aceitável

- latência da API usa métrica nativa do API Gateway, sem APM nem custom metric extra
- uptime usa `Route 53 Health Checks`, que é mais barato e mais simples do que `CloudWatch Synthetics` para este caso
- dashboards ficam em `CloudWatch Dashboard`, evitando `Amazon Managed Grafana`
- métricas de negócio saem de logs estruturados com `Metric Filters`, evitando collector permanente para esses sinais
- o namespace de métricas é particionado por ambiente (`<namespace-base>/<environment>`), evitando mistura entre `lab` e ambientes futuros sem precisar de dimensões extras
- consumo k8s coleta só duas métricas úteis do `oficina-app` via `cAdvisor`:
  - `container_cpu_usage_seconds_total`
  - `container_memory_working_set_bytes`
- não usa `Application Signals`, `X-Ray`, `Container Insights` completo, `Amazon Managed Prometheus` nem `SES`

## Recursos com custo recorrente mesmo com baixo tráfego

- `Route 53 Health Checks`, enquanto a stack AWS-native estiver ativa
- `CloudWatch Dashboard`, se a conta ultrapassar a faixa gratuita
- métricas customizadas contínuas de CPU/memória do `oficina-app`, enquanto `OBSERVABILITY_ENABLE_K8S_RESOURCE_METRICS=true`
- retenção de logs nos log groups do `oficina-app`, API Gateway e Prometheus/EMF

`SNS` por e-mail não tem custo fixo relevante; cobra por uso. Os metric filters de negócio só geram custo quando há logs correspondentes.

## Ativação e desativação no `lab`

O caminho integrado continua sendo o workflow `Deploy Lab`.

Para deixar a observabilidade AWS-native ligada:

- `OBSERVABILITY_ENABLED=true`
- `OBSERVABILITY_ENABLE_K8S_RESOURCE_METRICS=true`
- `OBSERVABILITY_MANAGE_NODE_ROLE_POLICY_ATTACHMENT=true` somente se o runner do deploy tiver permissao `iam:AttachRolePolicy`

Por padrao, `OBSERVABILITY_MANAGE_NODE_ROLE_POLICY_ATTACHMENT=false` para nao bloquear o deploy em contas onde o laboratorio nao pode alterar IAM. Nesse caso, a role dos nodes do EKS precisa ja ter permissao equivalente a `CloudWatchAgentServerPolicy` para que `aws-for-fluent-bit` e `cloudwatch-agent` consigam publicar logs e metricas.

Para reduzir custo recorrente sem mexer no resto da stack:

- `OBSERVABILITY_ENABLE_K8S_RESOURCE_METRICS=false`
  - mantém logs, dashboard, alarmes e healthchecks
  - escala o `cwagent-prometheus` para `0`
- `OBSERVABILITY_ENABLED=false`
  - remove toda a stack AWS-native de observabilidade do `lab`

Depois de alterar as variáveis do environment `lab`, rode novamente `Deploy Lab`.

## Dashboards

O dashboard `oficina-lab-observability` concentra:

- volume diário de OS
- tempo médio por status
- falhas de integração e processamento
- latência da API
- CPU/memória do `oficina-app`
- live/ready

## Alertas

Topicos SNS:

- `oficina-lab-observability-warning`
- `oficina-lab-observability-critical`

Alarmes mínimos:

- `uptime-live-critical`
- `uptime-ready-warning`
- `api-latency-warning`
- `api-latency-critical`
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
- a coleta k8s foi intencionalmente limitada ao `oficina-app`; não há `Container Insights` completo do cluster
- as métricas de negócio dependem dos logs estruturados permanecerem compatíveis com os filtros CloudWatch
