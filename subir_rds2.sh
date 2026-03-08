#!/bin/bash
set -euo pipefail

# Variáveis do RDS SQL Server
NOME_SG_RDS="secgroup-rds-sqlserver"
RDS_IDENTIFIER="rds-sqlserver-instance"
RDS_INSTANCE_CLASS="db.t3.small"
RDS_USERNAME="admin"
RDS_PASSWORD="Admin123456!"   # teste
RDS_PORT=1433
RDS_STORAGE_GB=20

echo "Iniciando o provisionamento do RDS SQL Server..."

# 1. Verifica e cria o Security Group dedicado ao RDS SQL Server
# Libera a porta 1433 para acesso externo
SG_RDS_ID=$(aws ec2 describe-security-groups \
  --group-names "$NOME_SG_RDS" \
  --query 'SecurityGroups[0].GroupId' \
  --output text 2>/dev/null || true)

if [ -n "${SG_RDS_ID:-}" ] && [ "$SG_RDS_ID" != "None" ]; then
    echo "[OK] Security Group '$NOME_SG_RDS' ja existe (ID: $SG_RDS_ID)."
else
    echo "Criando Security Group '$NOME_SG_RDS'..."
    SG_RDS_ID=$(aws ec2 create-security-group \
        --group-name "$NOME_SG_RDS" \
        --description "Permite acesso externo ao SQL Server (DBeaver, SSMS, etc.)" \
        --query 'GroupId' \
        --output text)

    aws ec2 authorize-security-group-ingress \
        --group-id "$SG_RDS_ID" \
        --protocol tcp \
        --port "$RDS_PORT" \
        --cidr 0.0.0.0/0

    echo "[OK] Security Group '$NOME_SG_RDS' criado e porta $RDS_PORT liberada."
fi

# 2. Verifica e cria a instância RDS SQL Server
RDS_EXISTS=$(aws rds describe-db-instances \
    --db-instance-identifier "$RDS_IDENTIFIER" \
    --query 'DBInstances[0].DBInstanceIdentifier' \
    --output text 2>/dev/null || true)

if [ "$RDS_EXISTS" = "$RDS_IDENTIFIER" ]; then
    echo "[OK] Instancia RDS '$RDS_IDENTIFIER' ja existe. Pulando criacao."
else
    echo "Criando instancia RDS SQL Server '$RDS_IDENTIFIER'..."
    aws rds create-db-instance \
        --db-instance-identifier "$RDS_IDENTIFIER" \
        --db-instance-class "$RDS_INSTANCE_CLASS" \
        --engine "sqlserver-ex" \
        --engine-version "15.00.4382.1.v1" \
        --master-username "$RDS_USERNAME" \
        --master-user-password "$RDS_PASSWORD" \
        --allocated-storage "$RDS_STORAGE_GB" \
        --storage-type "gp2" \
        --license-model "license-included" \
        --vpc-security-group-ids "$SG_RDS_ID" \
        --publicly-accessible \
        --no-multi-az \
        --no-deletion-protection \
        --tags "Key=Name,Value=$RDS_IDENTIFIER" \
        --output table > /dev/null

    echo "================================================="
    echo "✅ SUCESSO! RDS SQL Server '$RDS_IDENTIFIER' esta sendo criado."
    echo ""
    echo "⏳ Aguarde alguns minutos ate o banco ficar disponivel."
    echo ""
    echo "📌 Para obter o endpoint de conexao apos a criacao:"
    echo "aws rds describe-db-instances \\"
    echo "  --db-instance-identifier $RDS_IDENTIFIER \\"
    echo "  --query 'DBInstances[0].Endpoint.Address' \\"
    echo "  --output text"
    echo ""
    echo "🔌 Configuracoes para DBeaver / SSMS / Azure Data Studio:"
    echo "Host:     <ENDPOINT_ACIMA>"
    echo "Porta:    $RDS_PORT"
    echo "Usuario:  $RDS_USERNAME"
    echo "Senha:    $RDS_PASSWORD"
    echo "Driver:   SQL Server"
    echo "================================================="
fi