#!/usr/bin/env bash
set -euo pipefail

export AWS_PAGER=""

NOME_GATEWAY="${NOME_GATEWAY:-microservicos-gateway-eks}"
NOME_STAGE="${NOME_STAGE:-prod}"
AWS_REGION="${AWS_REGION:-us-east-1}"
NAMESPACE="${NAMESPACE:-fcg}"
USERS_SERVICE="${USERS_SERVICE:-usersapi-service}"
CATALOG_SERVICE="${CATALOG_SERVICE:-catalogapi-service}"
RECRIAR_GATEWAY="${RECRIAR_GATEWAY:-true}"
LB_TIMEOUT_SECONDS="${LB_TIMEOUT_SECONDS:-600}"
LB_SLEEP_SECONDS="${LB_SLEEP_SECONDS:-15}"

log() {
  echo ""
  echo "==> $1"
}

fail() {
  echo "ERRO: $1" >&2
  exit 1
}

aws_cli() {
  aws --no-cli-pager "$@"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Comando obrigatório não encontrado: $1"
}

service_exists() {
  local svc="$1"
  kubectl get svc "$svc" -n "$NAMESPACE" >/dev/null 2>&1
}

service_type() {
  local svc="$1"
  kubectl get svc "$svc" -n "$NAMESPACE" -o jsonpath='{.spec.type}'
}

get_lb_hostname() {
  local svc="$1"
  kubectl get svc "$svc" -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true
}

wait_for_lb_hostname() {
  local svc="$1"
  local waited=0
  local hostname=""

  while [ "$waited" -lt "$LB_TIMEOUT_SECONDS" ]; do
    hostname="$(get_lb_hostname "$svc")"
    if [ -n "$hostname" ]; then
      echo "$hostname"
      return 0
    fi
    sleep "$LB_SLEEP_SECONDS"
    waited=$((waited + LB_SLEEP_SECONDS))
  done

  return 1
}

main() {
  require_cmd aws
  require_cmd kubectl

  log "Validando contexto kubectl"
  kubectl config current-context >/dev/null 2>&1 || fail "kubectl sem contexto válido"

  log "Validando services no namespace $NAMESPACE"
  service_exists "$USERS_SERVICE" || fail "Service não encontrado: $USERS_SERVICE"
  service_exists "$CATALOG_SERVICE" || fail "Service não encontrado: $CATALOG_SERVICE"

  [ "$(service_type "$USERS_SERVICE")" = "LoadBalancer" ] || fail "Service $USERS_SERVICE não é LoadBalancer"
  [ "$(service_type "$CATALOG_SERVICE")" = "LoadBalancer" ] || fail "Service $CATALOG_SERVICE não é LoadBalancer"

  log "Aguardando hostname do LoadBalancer de $USERS_SERVICE"
  USERS_LB="$(wait_for_lb_hostname "$USERS_SERVICE")" || fail "Não foi possível obter o hostname do service $USERS_SERVICE"

  log "Aguardando hostname do LoadBalancer de $CATALOG_SERVICE"
  CATALOG_LB="$(wait_for_lb_hostname "$CATALOG_SERVICE")" || fail "Não foi possível obter o hostname do service $CATALOG_SERVICE"

  echo "================================================="
  echo "  API Gateway - UserApi + CatalogApi no EKS"
  echo "================================================="
  echo "usersapi   -> http://$USERS_LB"
  echo "catalogapi -> http://$CATALOG_LB"

  log "Verificando gateway existente"
  GATEWAY_ID_EXISTENTE="$(aws_cli apigatewayv2 get-apis --region "$AWS_REGION" --query "Items[?Name=='$NOME_GATEWAY'].ApiId" --output text 2>/dev/null || true)"

  if [ -n "$GATEWAY_ID_EXISTENTE" ] && [ "$GATEWAY_ID_EXISTENTE" != "None" ]; then
    if [ "$RECRIAR_GATEWAY" = "true" ]; then
      echo "[AVISO] Gateway '$NOME_GATEWAY' já existe. Removendo para recriar limpo..."
      aws_cli apigatewayv2 delete-api --region "$AWS_REGION" --api-id "$GATEWAY_ID_EXISTENTE" >/dev/null
      sleep 5
    else
      fail "Gateway '$NOME_GATEWAY' já existe e RECRIAR_GATEWAY=false"
    fi
  fi

  log "Criando HTTP API Gateway"
  GATEWAY_ID="$(aws_cli apigatewayv2 create-api \
    --region "$AWS_REGION" \
    --name "$NOME_GATEWAY" \
    --protocol-type HTTP \
    --cors-configuration AllowOrigins="*",AllowMethods="GET,POST,PUT,DELETE,OPTIONS,PATCH",AllowHeaders="Content-Type,Authorization" \
    --query 'ApiId' \
    --output text)"

  API_ENDPOINT="$(aws_cli apigatewayv2 get-api \
    --region "$AWS_REGION" \
    --api-id "$GATEWAY_ID" \
    --query 'ApiEndpoint' \
    --output text)"

  log "Criando integrações HTTP_PROXY"
  INTEGRATION_USERS="$(aws_cli apigatewayv2 create-integration \
    --region "$AWS_REGION" \
    --api-id "$GATEWAY_ID" \
    --integration-type HTTP_PROXY \
    --integration-method ANY \
    --integration-uri "http://${USERS_LB}/{proxy}" \
    --payload-format-version "1.0" \
    --request-parameters '{"overwrite:path": "/$request.path.proxy"}' \
    --query 'IntegrationId' \
    --output text)"

  INTEGRATION_CATALOG="$(aws_cli apigatewayv2 create-integration \
    --region "$AWS_REGION" \
    --api-id "$GATEWAY_ID" \
    --integration-type HTTP_PROXY \
    --integration-method ANY \
    --integration-uri "http://${CATALOG_LB}/{proxy}" \
    --payload-format-version "1.0" \
    --request-parameters '{"overwrite:path": "/$request.path.proxy"}' \
    --query 'IntegrationId' \
    --output text)"

  log "Criando rotas"
  aws_cli apigatewayv2 create-route --region "$AWS_REGION" --api-id "$GATEWAY_ID" --route-key 'ANY /users/{proxy+}' --target "integrations/$INTEGRATION_USERS" >/dev/null
  aws_cli apigatewayv2 create-route --region "$AWS_REGION" --api-id "$GATEWAY_ID" --route-key 'ANY /catalog/{proxy+}' --target "integrations/$INTEGRATION_CATALOG" >/dev/null

  log "Criando stage"
  aws_cli apigatewayv2 create-stage \
    --region "$AWS_REGION" \
    --api-id "$GATEWAY_ID" \
    --stage-name "$NOME_STAGE" \
    --auto-deploy \
    --default-route-settings ThrottlingRateLimit=100,ThrottlingBurstLimit=200 >/dev/null

  URL_BASE="${API_ENDPOINT}/${NOME_STAGE}"

  echo ""
  echo "================================================="
  echo "GATEWAY EKS CRIADO COM SUCESSO"
  echo "================================================="
  echo "API ID: $GATEWAY_ID"
  echo "URL Base: $URL_BASE"
  echo ""
  echo "POST  $URL_BASE/users/api/auth/login"
  echo "GET   $URL_BASE/users/api/users"
  echo "POST  $URL_BASE/users/api/users"
  echo ""
  echo "GET   $URL_BASE/catalog/api/games"
  echo "GET   $URL_BASE/catalog/api/promotions"
  echo "POST  $URL_BASE/catalog/api/gamepurchase"
}

main "$@"