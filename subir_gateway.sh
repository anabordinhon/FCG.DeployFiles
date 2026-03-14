#!/bin/bash
set -euo pipefail

# =============================================================
#  API Gateway - UserApi + CatalogApi
#  + Restrição automática do Security Group
# =============================================================
#
#  ROTAS EXTRAÍDAS DO CÓDIGO FONTE:
#
#  fcg-users-api (porta 8081 → container 8080)
#    [Route("api/[controller]")] em AuthController
#      POST   /api/auth/login
#
#    [Route("api/[controller]")] em UsersController
#      GET    /api/users
#      GET    /api/users/{publicId}
#      POST   /api/users
#      PATCH  /api/users/{publicId}/deactivate
#      POST   /api/users/create-admin
#
#  fcg-catalog-api (porta 8082 → container 8080)
#    [Route("api/[controller]")] em GamesController
#      GET    /api/games
#      GET    /api/games/{publicId}
#      POST   /api/games
#
#    [Route("api/[controller]")] em PromotionsController
#      GET    /api/promotions
#      GET    /api/promotions/{publicId}
#      POST   /api/promotions
#
#    [Route("api/[controller]")] em GamePurchaseController
#      GET    /api/gamepurchase
#      POST   /api/gamepurchase
#
#  CORREÇÃO DO BUG ANTERIOR:
#  O script anterior usava rotas com prefixo (/auth/{proxy+},
#  /users/{proxy+}) combinadas com path rewrite via
#  $request.path.proxy. O {proxy} capturava apenas o trecho
#  APÓS o prefixo da rota, descartando o segmento inicial
#  e enviando path errado ao backend.
#
#  Exemplo do problema:
#    Chamada:  POST /prod/auth/login
#    proxy     = "login"              ← perdeu o "/auth"
#    rewrite   = /login               ← backend recebia errado
#    Backend:  EC2:8081/login         → NOT FOUND ❌
#
#  Solução aplicada:
#  Cada serviço tem UMA integração com rota catch-all própria.
#  O path completo é preservado no rewrite.
#
#    Chamada:  POST /prod/users/api/auth/login
#    proxy     = "api/auth/login"
#    rewrite   = /api/auth/login
#    Backend:  EC2:8081/api/auth/login  ✅
#
# =============================================================

NOME_GATEWAY="microservicos-gateway"
NOME_STAGE="prod"
NOME_INSTANCIA="machineOne"
NOME_SG="secgroup-microservicos-rabbit"

# Portas conforme docker-compose.yml (host:container → 8081:8080 e 8082:8080)
PORTA_USERS=8081    # fcg-users-api
PORTA_CATALOG=8082  # fcg-catalog-api

# CIDRs públicos do API Gateway na us-east-1
CIDRS_API_GATEWAY=(
    "3.216.135.0/24"
    "3.216.136.0/21"
    "3.216.144.0/23"
    "3.216.148.0/22"
    "3.235.26.0/23"
    "3.235.32.0/21"
    "3.238.166.0/24"
    "3.238.212.0/22"
    "44.206.4.0/22"
    "44.210.64.0/22"
    "44.212.176.0/23"
    "44.212.178.0/23"
    "44.212.180.0/23"
    "44.212.182.0/23"
    "44.218.96.0/23"
    "44.220.28.0/22"
)

echo "================================================="
echo "  API Gateway - UserApi + CatalogApi"
echo "================================================="

# ── 1. Descobre o IP do EC2 ───────────────────────────────────
echo ""
echo "[1/6] Buscando IP da instância '$NOME_INSTANCIA'..."

EC2_IP=$(aws ec2 describe-instances \
    --filters \
        "Name=tag:Name,Values=$NOME_INSTANCIA" \
        "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].PublicIpAddress" \
    --output text)

if [ -z "$EC2_IP" ] || [ "$EC2_IP" = "None" ]; then
    echo "❌ Instância '$NOME_INSTANCIA' não encontrada ou não está running."
    exit 1
fi

echo "[OK] EC2 IP: $EC2_IP"
echo "     fcg-users-api   → http://${EC2_IP}:${PORTA_USERS}"
echo "     fcg-catalog-api → http://${EC2_IP}:${PORTA_CATALOG}"

# ── 2. Restringe o Security Group ─────────────────────────────
echo ""
echo "[2/6] Restringindo Security Group '$NOME_SG'..."

SG_ID=$(aws ec2 describe-security-groups \
    --group-names "$NOME_SG" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || true)

if [ -z "$SG_ID" ] || [ "$SG_ID" = "None" ]; then
    echo "❌ Security Group '$NOME_SG' não encontrado."
    exit 1
fi

echo "[OK] SG encontrado: $SG_ID"

restringir_porta() {
    local porta="$1"
    echo -n "     Removendo 0.0.0.0/0 da porta $porta... "
    aws ec2 revoke-security-group-ingress \
        --group-id "$SG_ID" \
        --protocol tcp \
        --port "$porta" \
        --cidr 0.0.0.0/0 >/dev/null 2>&1 && echo "removido ✅" || echo "já não existia"

    for CIDR in "${CIDRS_API_GATEWAY[@]}"; do
        aws ec2 authorize-security-group-ingress \
            --group-id "$SG_ID" \
            --protocol tcp \
            --port "$porta" \
            --cidr "$CIDR" >/dev/null 2>&1 || true
    done
    echo "     CIDRs do API Gateway adicionados na porta $porta ✅"
}

restringir_porta "$PORTA_USERS"
restringir_porta "$PORTA_CATALOG"

# ── 3. Cria o API Gateway ─────────────────────────────────────
echo ""
echo "[3/6] Criando HTTP API Gateway '$NOME_GATEWAY'..."

GATEWAY_ID_EXISTENTE=$(aws apigatewayv2 get-apis \
    --query "Items[?Name=='$NOME_GATEWAY'].ApiId" \
    --output text 2>/dev/null || true)

if [ -n "$GATEWAY_ID_EXISTENTE" ] && [ "$GATEWAY_ID_EXISTENTE" != "None" ]; then
    echo "[AVISO] Gateway '$NOME_GATEWAY' já existe. Removendo para recriar limpo..."
    aws apigatewayv2 delete-api --api-id "$GATEWAY_ID_EXISTENTE" >/dev/null
    sleep 3
fi

GATEWAY_ID=$(aws apigatewayv2 create-api \
    --name "$NOME_GATEWAY" \
    --protocol-type HTTP \
    --cors-configuration \
        AllowOrigins="*",AllowMethods="GET,POST,PUT,DELETE,OPTIONS,PATCH",AllowHeaders="Content-Type,Authorization" \
    --query 'ApiId' \
    --output text)

echo "[OK] Gateway criado (ID: $GATEWAY_ID)"

# ── 4. Cria integrações (uma por serviço, catch-all) ──────────
#
#  O rewrite "/$request.path.proxy" preserva o path completo,
#  incluindo o prefixo /api/ que os backends .NET esperam.
#
echo ""
echo "[4/6] Criando integrações..."

# Integração fcg-users-api → EC2:8081
INTEGRATION_USERS=$(aws apigatewayv2 create-integration \
    --api-id "$GATEWAY_ID" \
    --integration-type HTTP_PROXY \
    --integration-method ANY \
    --integration-uri "http://${EC2_IP}:${PORTA_USERS}/{proxy}" \
    --payload-format-version "1.0" \
    --request-parameters '{"overwrite:path": "/$request.path.proxy"}' \
    --query 'IntegrationId' \
    --output text)

echo "[OK] Integração fcg-users-api criada (ID: $INTEGRATION_USERS)"

# Integração fcg-catalog-api → EC2:8082
INTEGRATION_CATALOG=$(aws apigatewayv2 create-integration \
    --api-id "$GATEWAY_ID" \
    --integration-type HTTP_PROXY \
    --integration-method ANY \
    --integration-uri "http://${EC2_IP}:${PORTA_CATALOG}/{proxy}" \
    --payload-format-version "1.0" \
    --request-parameters '{"overwrite:path": "/$request.path.proxy"}' \
    --query 'IntegrationId' \
    --output text)

echo "[OK] Integração fcg-catalog-api criada (ID: $INTEGRATION_CATALOG)"

# ── 5. Cria as rotas ──────────────────────────────────────────
#
#  /users/{proxy+}   → tudo que chegar com /users/ vai para EC2:8081
#  /catalog/{proxy+} → tudo que chegar com /catalog/ vai para EC2:8082
#
#  Fluxo completo (exemplos):
#    POST /prod/users/api/auth/login
#      proxy = "api/auth/login" → backend recebe /api/auth/login  ✅
#
#    GET  /prod/users/api/users
#      proxy = "api/users"      → backend recebe /api/users       ✅
#
#    GET  /prod/catalog/api/games
#      proxy = "api/games"      → backend recebe /api/games       ✅
#
echo ""
echo "[5/6] Criando rotas..."

criar_rota() {
    local rota="$1"
    local integration_id="$2"
    aws apigatewayv2 create-route \
        --api-id "$GATEWAY_ID" \
        --route-key "ANY $rota" \
        --target "integrations/$integration_id" \
        --output text >/dev/null 2>&1
    echo "     ANY $rota"
}

echo "[OK] Rotas fcg-users-api (porta $PORTA_USERS):"
criar_rota "/users/{proxy+}"   "$INTEGRATION_USERS"

echo "[OK] Rotas fcg-catalog-api (porta $PORTA_CATALOG):"
criar_rota "/catalog/{proxy+}" "$INTEGRATION_CATALOG"

# ── 6. Cria o Stage ───────────────────────────────────────────
echo ""
echo "[6/6] Criando stage '$NOME_STAGE'..."

aws apigatewayv2 create-stage \
    --api-id "$GATEWAY_ID" \
    --stage-name "$NOME_STAGE" \
    --auto-deploy \
    --default-route-settings \
        ThrottlingRateLimit=100,ThrottlingBurstLimit=200 \
    >/dev/null

echo "[OK] Stage '$NOME_STAGE' criado com auto-deploy e throttling"

# ── Resultado ─────────────────────────────────────────────────
REGIAO=$(aws configure get region 2>/dev/null || echo "us-east-1")
URL_BASE="https://${GATEWAY_ID}.execute-api.${REGIAO}.amazonaws.com/${NOME_STAGE}"

echo ""
echo "================================================="
echo "✅ GATEWAY CRIADO COM SUCESSO!"
echo "================================================="
echo ""
echo "  URL Base: $URL_BASE"
echo ""
echo "  📬 fcg-users-api (porta $PORTA_USERS)"
echo "  Prefixo no gateway: /users  →  backend recebe: /api/..."
echo ""
echo "    POST   $URL_BASE/users/api/auth/login"
echo "    GET    $URL_BASE/users/api/users"
echo "    GET    $URL_BASE/users/api/users/{publicId}"
echo "    POST   $URL_BASE/users/api/users"
echo "    PATCH  $URL_BASE/users/api/users/{publicId}/deactivate"
echo ""
echo "  📬 fcg-catalog-api (porta $PORTA_CATALOG)"
echo "  Prefixo no gateway: /catalog  →  backend recebe: /api/..."
echo ""
echo "    GET    $URL_BASE/catalog/api/games"
echo "    GET    $URL_BASE/catalog/api/games/{publicId}"
echo "    POST   $URL_BASE/catalog/api/games"
echo "    GET    $URL_BASE/catalog/api/promotions"
echo "    GET    $URL_BASE/catalog/api/promotions/{publicId}"
echo "    POST   $URL_BASE/catalog/api/promotions"
echo "    GET    $URL_BASE/catalog/api/gamepurchases"
echo "    POST   $URL_BASE/catalog/api/gamepurchases"
echo ""
echo "  🔒 Segurança:"
echo "    ✅ Porta $PORTA_USERS restrita aos CIDRs do API Gateway"
echo "    ✅ Porta $PORTA_CATALOG restrita aos CIDRs do API Gateway"
echo "    ✅ Throttling: 100 req/s (burst 200)"
echo "    ✅ CORS configurado"
echo ""
echo "  ⚠️  Para reverter restrições do SG (emergência):"
echo "    aws ec2 authorize-security-group-ingress \\"
echo "      --group-id $SG_ID --protocol tcp --port $PORTA_USERS --cidr 0.0.0.0/0"
echo "    aws ec2 authorize-security-group-ingress \\"
echo "      --group-id $SG_ID --protocol tcp --port $PORTA_CATALOG --cidr 0.0.0.0/0"
echo ""
echo "  🗑️  Para deletar o gateway:"
echo "    aws apigatewayv2 delete-api --api-id $GATEWAY_ID"
echo "================================================="
