#!/bin/bash
set -euo pipefail

# Variaveis do ambiente
NOME_INSTANCIA="machineOne"
NOME_CHAVE="machinePen"
NOME_SG="secgroup-microservicos-rabbit"
TIPO_INSTANCIA="t3.micro"
TAMANHO_DISCO_GB=8

echo "Iniciando o provisionamento da instancia $NOME_INSTANCIA..."

# 1. Verifica e cria o par de chaves (.pem)
if aws ec2 describe-key-pairs --key-names "$NOME_CHAVE" >/dev/null 2>&1; then
    echo "[OK] Par de chaves '$NOME_CHAVE' ja existe."
else
    echo "Criando par de chaves '$NOME_CHAVE'..."
    aws ec2 create-key-pair \
        --key-name "$NOME_CHAVE" \
        --query 'KeyMaterial' \
        --output text > "${NOME_CHAVE}.pem"

    chmod 400 "${NOME_CHAVE}.pem"
    echo "[OK] Chave salva como ${NOME_CHAVE}.pem na pasta atual."
fi

# 2. Verifica e cria o Security Group
SG_ID=$(aws ec2 describe-security-groups \
    --group-names "$NOME_SG" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || true)

if [ -n "${SG_ID:-}" ] && [ "$SG_ID" != "None" ]; then
    echo "[OK] Security Group '$NOME_SG' ja existe (ID: $SG_ID)."
else
    echo "Criando Security Group '$NOME_SG'..."
    SG_ID=$(aws ec2 create-security-group \
        --group-name "$NOME_SG" \
        --description "Permite SSH, APIs e RabbitMQ para testes" \
        --query 'GroupId' \
        --output text)

    echo "[OK] Security Group criado (ID: $SG_ID)."
fi

# 3. Garante as regras de entrada necessarias
echo "Garantindo regras de entrada no Security Group..."

autorizar_porta() {
    local porta="$1"
    aws ec2 authorize-security-group-ingress \
        --group-id "$SG_ID" \
        --protocol tcp \
        --port "$porta" \
        --cidr 0.0.0.0/0 >/dev/null 2>&1 || true
}

autorizar_porta 22
autorizar_porta 8080
autorizar_porta 8081
autorizar_porta 8082
autorizar_porta 8083
autorizar_porta 5672
autorizar_porta 15672

echo "[OK] Portas 22, 8080, 8081, 8082, 8083, 5672 e 15672 liberadas."

# 4. Busca a AMI mais recente do Ubuntu 22.04 LTS
echo "Buscando a AMI mais recente do Ubuntu 22.04..."
AMI_ID=$(aws ec2 describe-images \
    --owners 099720109477 \
    --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" "Name=state,Values=available" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" \
    --output text)

echo "[OK] AMI encontrada: $AMI_ID"

# 5. Gera o script de inicializacao (user data)
echo "Gerando script de inicializacao..."

cat << 'EOF' > user_data.sh
#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# Atualiza pacotes base
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release

# Adiciona repositorio oficial do Docker
install -m 0755 -d /etc/apt/keyrings

if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
fi

chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list

# Instala Docker Engine + Compose v2
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Habilita Docker
systemctl enable docker
systemctl start docker

# Adiciona usuario ubuntu ao grupo docker
usermod -aG docker ubuntu

# Cria pasta padrao para deploy
mkdir -p /home/ubuntu/app
chown -R ubuntu:ubuntu /home/ubuntu

# Informacao util no boot
docker --version > /home/ubuntu/docker-version.txt 2>/dev/null || true
docker compose version > /home/ubuntu/docker-compose-version.txt 2>/dev/null || true
EOF

echo "[OK] Script de inicializacao gerado."

# 6. Cria a instancia EC2
echo "Levantando a instancia EC2..."

aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$TIPO_INSTANCIA" \
    --key-name "$NOME_CHAVE" \
    --security-group-ids "$SG_ID" \
    --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":$TAMANHO_DISCO_GB,\"VolumeType\":\"gp3\"}}]" \
    --credit-specification CpuCredits=standard \
    --user-data file://user_data.sh \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NOME_INSTANCIA}]" \
    --output table > /dev/null

echo "================================================="
echo "✅ SUCESSO! A maquina '$NOME_INSTANCIA' esta subindo."
echo ""
echo "Docker sera instalado automaticamente no boot da instancia."
echo ""
echo "Portas liberadas para teste:"
echo "- 22    -> SSH"
echo "- 8080  -> catalogapi"
echo "- 8081  -> usersapi"
echo "- 8082  -> catalogapi"
echo "- 8083  -> payments-worker"
echo "- 5672  -> RabbitMQ"
echo "- 15672 -> painel RabbitMQ"
echo ""
echo "Para conectar via SSH depois:"
echo "ssh -i \"${NOME_CHAVE}.pem\" ubuntu@<IP_PUBLICO>"
echo "================================================="