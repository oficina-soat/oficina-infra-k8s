# Telemetria da Suíte Oficina

Este documento define a convenção vendor-neutral de observabilidade da suíte Oficina para a fase preparatória.

## Objetivo

- padronizar logs estruturados em JSON
- padronizar tracing distribuído com OpenTelemetry
- expor métricas técnicas e de negócio com baixa cardinalidade
- manter configuração por env vars e contratos reaproveitáveis
- evitar acoplamento prematuro com AWS nativa, Datadog ou New Relic

## Serviços padronizados

- `service.name=oficina-app`
- `service.name=oficina-auth-lambda`
- `service.namespace=oficina`
- `deployment.environment=lab` no ambiente de referência
- `service.version` derivada da versão já publicada em cada `pom.xml`

## Logs JSON

O formato padrão dos logs estruturados é JSON.

Campos obrigatórios, quando disponíveis:

- `timestamp`
- `severity`
- `message`
- `service.name`
- `service.namespace`
- `service.version`
- `deployment.environment`
- `trace_id`
- `span_id`
- `request_id`

Campos HTTP, quando aplicáveis:

- `http.method`
- `http.route`
- `url.path`
- `http.status_code`
- `client.address`

Campos de erro, quando aplicáveis:

- `error.type`
- `error.message`
- `error.stack`

Campos de integração, quando aplicáveis:

- `integration.name`
- `integration.operation`
- `integration.status`

Campos de domínio, quando aplicáveis:

- `ordem_servico_id`
- `ordem_servico_status`
- `ordem_servico_status_anterior`
- `ordem_servico_status_novo`

Regras:

- não logar tokens, action tokens, JWTs completos, senhas, CPF completo, e-mail completo ou segredos
- preferir IDs técnicos e status estáveis em vez de payloads completos
- mascarar ou omitir PII

## Correlação e tracing

- toda request HTTP recebida deve carregar ou gerar `request_id`
- `trace_id` e `span_id` devem acompanhar logs quando existir contexto ativo
- OpenTelemetry é o padrão de tracing da suíte
- propagação padrão: contexto W3C
- atributos mínimos úteis:
  - `service.name`
  - `deployment.environment`
  - `http.method`
  - `http.route`
  - `http.status_code`
  - `integration.name`
  - `integration.operation`
  - `ordem_servico.status`
  - `ordem_servico.id` apenas em span/log

## Métricas do `oficina-app`

Negócio:

- `os_created_total{service,env}`
- `os_status_transition_total{service,env,from_status,to_status}`
- `os_status_duration_ms{service,env,status}`
- `integration_failures_total{service,env,integration,operation,failure_type}`
- `integration_latency_ms{service,env,integration,operation}`

Técnicas:

- métricas de runtime e HTTP do Quarkus/Micrometer
- endpoint padrão no app: `/q/metrics`

Regras:

- não usar `ordem_servico_id`, `trace_id`, `span_id`, `request_id`, CPF, e-mail, URL completa ou mensagem livre de exceção como label
- labels devem ser finitas e estáveis
- em dúvida entre label e log, usar log

## Métricas do `oficina-auth-lambda`

- `auth_requests_total{service,env}`
- `auth_failures_total{service,env,failure_type}`
- `auth_latency_ms{service,env,outcome}`

## Health, readiness e liveness

No `oficina-app`:

- `GET /q/health/live`
- `GET /q/health/ready`
- probes Kubernetes usam HTTP, não `tcpSocket`
- esses endpoints não precisam ficar públicos no API Gateway

## Env vars padronizadas

Contrato principal:

- `OTEL_SERVICE_NAME`
- `OTEL_RESOURCE_ATTRIBUTES`
- `OTEL_EXPORTER_OTLP_ENDPOINT`
- `OTEL_EXPORTER_OTLP_PROTOCOL`
- `OTEL_TRACES_EXPORTER`
- `OTEL_METRICS_EXPORTER`
- `OTEL_LOGS_EXPORTER`
- `OFICINA_OBSERVABILITY_ENABLED`
- `OFICINA_OBSERVABILITY_JSON_LOGS_ENABLED`
- `OFICINA_OBSERVABILITY_METRICS_ENABLED`
- `OFICINA_OBSERVABILITY_TRACING_ENABLED`
- `DEPLOYMENT_ENVIRONMENT`

Valores de referência em `lab`:

- `OTEL_SERVICE_NAME=oficina-app` no deployment do app
- `OTEL_RESOURCE_ATTRIBUTES=service.namespace=oficina,deployment.environment=lab`
- exporters mantidos em `none` nesta fase

## O que fica para a próxima etapa

Quando houver escolha do backend observability, a suíte já ficará pronta para:

- apontar OTLP para collector/agent do backend escolhido
- decidir rota final de ingestão de logs
- publicar dashboards e alertas
- ativar componentes de coleta específicos do backend, se necessário
