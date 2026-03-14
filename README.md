# 🚀 Guia de Infraestrutura — Fiap Cloud Games (FCG)

> **Contexto:** Este projeto utiliza AWS Academy (Learner Lab), onde as credenciais e recursos são resetados a cada nova sessão. Este guia cobre todos os passos necessários para recriar o ambiente do zero.

---

## 📋 Índice

1. [Pré-requisitos](#-pré-requisitos)
2. [Visão Geral da Arquitetura](#-visão-geral-da-arquitetura)
3. [Credenciais e Secrets](#-credenciais-e-secrets)
4. [Subindo a Infraestrutura Principal](#-subindo-a-infraestrutura-principal)
   - [1. Preparação do CloudShell](#1-preparação-do-cloudshell)
   - [2. Criar o RDS SQL Server](#2-criar-o-rds-sql-server)
   - [3. Criar a Instância EC2](#3-criar-a-instância-ec2)
   - [4. Enviar arquivos para a EC2](#4-enviar-arquivos-para-a-ec2)
   - [5. Deploy via GitHub Actions](#5-deploy-via-github-actions)
   - [6. Criar o API Gateway](#6-criar-o-api-gateway)
5. [Subindo o Lambda e Notificações](#-subindo-o-lambda-e-notificações)
   - [1. Atualizar Credenciais AWS](#1-atualizar-credenciais-aws)
   - [2. Recriar o Tópico SNS](#2-recriar-o-tópico-sns)
   - [3. Recriar a Fila SQS](#3-recriar-a-fila-sqs)
   - [4. Deploy da Lambda](#4-deploy-da-lambda)
   - [5. Reconectar o SQS como Gatilho](#5-reconectar-o-sqs-como-gatilho)
6. [Validação do Ambiente](#-validação-do-ambiente)
7. [Endpoints Disponíveis](#-endpoints-disponíveis)
8. [Collection do Postman](#-collection-do-postman)
9. [Comandos Úteis no EC2](#-comandos-úteis-no-ec2)
10. [Acesso ao Banco de Dados](#-acesso-ao-banco-de-dados)
11. [Referência de Credenciais](#-referência-de-credenciais)

---

## ✅ Pré-requisitos

- Acesso ao **AWS Academy → Learner Lab** com sessão ativa (status verde)
- Arquivos disponíveis localmente:
  - `subir_rds2.sh`
  - `subir_ec2.sh`
  - `subir_gateway.sh`
  - `docker-compose.yml`
  - `.env` (atualizado com as credenciais da sessão atual)
- Acesso aos repositórios no GitHub:
  - `FCG.UsersAPI` / `FCG.CatalogAPI` (pipeline de deploy)
  - [`FCG.PaymentsAPI`](https://github.com/anabordinhon/FCG.PaymentsAPI) (pipeline do payments-worker)
  - `FCG.NotificationsLambda` (pipeline da Lambda)

> ⚠️ **Ao excluir a instância EC2**, lembre de excluir também o par de chaves associado. Na próxima criação, o script irá gerar um novo par automaticamente.

---

## 🏗️ Visão Geral da Arquitetura

```
Cliente (Postman / Frontend)
         │
         ▼
  [API Gateway]
  /users/{proxy+}   →  EC2:8081  →  fcg-users-api   (ASP.NET)
  /catalog/{proxy+} →  EC2:8082  →  fcg-catalog-api (ASP.NET)
         │
         ▼
  [RDS SQL Server]  ←  migrations automáticas na subida dos containers
         │
  [RabbitMQ] → [fcg-payments-worker] → [SQS] → [Lambda] → [SNS] → E-mail
```

---

## 🔐 Credenciais e Secrets

### Onde encontrar as credenciais AWS da sessão
1. Acesse **AWS Academy → Learner Lab → Start Lab** (aguarde ficar verde)
2. Clique em **AWS Details → Show** (ao lado de "AWS CLI")
3. Copie os 3 valores: `aws_access_key_id`, `aws_secret_access_key` e `aws_session_token`

### GitHub Secrets — repositório de aplicação

| Secret | Descrição |
|---|---|
| `EC2_HOST` | IP público da EC2 (obtido após criação) |
| `EC2_SSH_KEY` | Conteúdo do arquivo `machinePen.pem` |
| `DOCKER_USERNAME` | *(ver time)*  |
| `DOCKER_PASSWORD` | *(ver time)* |

### GitHub Secrets — repositório FCG.NotificationsLambda

| Secret | Descrição |
|---|---|
| `AWS_ACCESS_KEY_ID` | Credencial da sessão atual |
| `AWS_SECRET_ACCESS_KEY` | Credencial da sessão atual |
| `AWS_SESSION_TOKEN` | Credencial da sessão atual |
| `SNS_TOPIC_ARN` | ARN do tópico SNS recriado |

---

## 🖥️ Subindo a Infraestrutura Principal

### 1. Preparação do CloudShell

Abra o **CloudShell** no console AWS e faça upload dos arquivos via **Ações → Carregar arquivo**:

```
subir_rds2.sh
subir_ec2.sh
subir_gateway.sh
docker-compose.yml
```

Conceda permissão de execução:

```bash
chmod +x subir_ec2.sh subir_rds2.sh subir_gateway.sh
```

---

### 2. Criar o RDS SQL Server

Execute o script de criação:

```bash
sed -i 's/\r//' subir_rds2.sh && ./subir_rds2.sh
```

> ⏳ A criação do RDS leva alguns minutos. Aproveite para criar a EC2 em paralelo (próximo passo) enquanto aguarda.

Após a conclusão, obtenha o endpoint do banco:

```bash
aws rds describe-db-instances \
  --db-instance-identifier rds-sqlserver-instance \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text
```

Atualize o arquivo `.env` com o endpoint obtido e faça upload dele no CloudShell.

---

### 3. Criar a Instância EC2

Execute o script de criação:

```bash
sed -i 's/\r//' subir_ec2.sh && ./subir_ec2.sh
```

Após a criação, colete as informações necessárias para os **GitHub Secrets**:

**Conteúdo do arquivo `.pem`** (para o secret `EC2_SSH_KEY`):
```bash
cat machinePen.pem
```

**IP público da instância** (para o secret `EC2_HOST`):
```bash
aws ec2 describe-instances \
  --filters 'Name=tag:Name,Values=machineOne' 'Name=instance-state-name,Values=running' \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text
```

> ⚠️ Atualize os secrets `EC2_HOST` e `EC2_SSH_KEY` no GitHub **antes** de executar o pipeline.

---

### 4. Enviar arquivos para a EC2

Execute os comandos abaixo no **CloudShell** (substitua `IP_PUBLICO` pelo IP obtido no passo anterior):

```bash
# Ajustar permissão da chave (necessário para o SCP funcionar)
chmod 400 machinePen.pem

# Criar a pasta de destino na EC2
ssh -i machinePen.pem -o StrictHostKeyChecking=no ubuntu@IP_PUBLICO \
  'mkdir -p /home/ubuntu/app'

# Copiar o docker-compose para a EC2
scp -i machinePen.pem -o StrictHostKeyChecking=no \
  docker-compose.yml \
  ubuntu@IP_PUBLICO:/home/ubuntu/app/docker-compose.yml

# Copiar o .env para a EC2
scp -i machinePen.pem -o StrictHostKeyChecking=no \
  .env \
  ubuntu@IP_PUBLICO:/home/ubuntu/app/.env
```

---

### 5. Deploy via GitHub Actions

Execute o pipeline nos **3 repositórios**, todos seguem o mesmo padrão:

| Repositório | Descrição |
|---|---|
| `FCG.UsersAPI` | Deploy da fcg-users-api |
| `FCG.CatalogAPI` | Deploy da fcg-catalog-api |
| [`FCG.PaymentsAPI`](https://github.com/anabordinhon/FCG.PaymentsAPI) | Deploy do fcg-payments-worker |

Para cada repositório:
1. Confirme que os secrets `EC2_HOST` e `EC2_SSH_KEY` estão atualizados
2. Execute o pipeline manualmente ou via push
3. Aguarde a conclusão com ✅

> ⚠️ Todos os pipelines devem ser executados **antes** da criação do API Gateway.

---

### 6. Criar o API Gateway

Após o pipeline concluir com sucesso, execute no **CloudShell**:

```bash
sed -i 's/\r//' subir_gateway.sh && ./subir_gateway.sh
```

O log de saída exibirá a **URL base** e todos os endpoints disponíveis. Guarde essa URL para os testes.

> ⚠️ Após a criação do gateway, as portas `8081` e `8082` ficam restritas aos CIDRs do API Gateway. O acesso direto via IP público deixa de funcionar.
>
> Caso precise acessar o EC2 diretamente em caráter emergencial (ex.: Swagger via IP), libere temporariamente seu IP no Security Group:
> ```bash
> aws ec2 authorize-security-group-ingress \
>   --group-id SG_ID --protocol tcp --port 8081 --cidr SEU_IP/32
> ```
> Lembre de revogar após o uso.

---

## 📬 Subindo o Lambda e Notificações

> Este processo deve ser repetido a cada nova sessão do AWS Academy, pois as credenciais e recursos são resetados.

### 1. Atualizar Credenciais AWS

Atualize os 3 secrets no repositório **FCG.NotificationsLambda** → **Settings → Secrets → Actions**:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_SESSION_TOKEN`

Atualize também o `.env` da EC2 com as novas credenciais e reinicie os containers:

```bash
# Na EC2
cd /home/ubuntu/app && docker compose down && docker compose up -d
```

---

### 2. Recriar o Tópico SNS

1. **AWS Console → SNS → Topics → Create topic**
2. **Type:** Standard
3. **Name:** `fcg-email-topic`
4. Clique em **Create topic** e copie o **ARN** gerado

**Criar a subscription de e-mail:**
1. Na página do tópico → **Create subscription**
2. **Protocol:** Email | **Endpoint:** seu e-mail
3. Acesse o e-mail e clique em **"Confirm subscription"**
4. Confirme que o status ficou **Confirmed** ✅

**Atualizar o ARN no GitHub Secret antes de continuar:**

Repositório **FCG.NotificationsLambda** → **Settings → Secrets → Actions** → edite `SNS_TOPIC_ARN` com o novo ARN.

> O deploy da Lambda depende desse valor para configurar a variável de ambiente corretamente. Faça isso antes de prosseguir.

---

### 3. Recriar a Fila SQS

1. **AWS Console → SQS → Create queue**
2. **Type:** Standard | **Name:** `fcg-email-queue`
3. **Visibility timeout:** 60 segundos
4. Clique em **Create queue** e copie a **URL da fila**

Atualize o `.env` da EC2 com a nova URL:

```env
AWS_SQS_QUEUE_URL=https://sqs.us-east-1.amazonaws.com/SEU_ACCOUNT_ID/fcg-email-queue
```

Reinicie os containers para aplicar:

```bash
cd /home/ubuntu/app && docker compose down && docker compose up -d
```

---

### 4. Deploy da Lambda

1. Acesse o repositório **FCG.NotificationsLambda** no GitHub
2. Aba **Actions → Deploy Lambda .NET → Run workflow**
3. Aguarde o ✅ verde

Confirme em **Lambda → fcg-email-lambda → Configuration → Environment variables** que `SNS_TOPIC_ARN` está com o novo ARN.

---

### 5. Reconectar o SQS como Gatilho

1. **AWS Console → Lambda → fcg-email-lambda → Adicionar gatilho**
2. **Fonte:** SQS | **Fila:** `fcg-email-queue` | **Tamanho do lote:** 1
3. Clique em **Adicionar**

---

## ✔️ Validação do Ambiente

### APIs via Gateway

> O Swagger pode não renderizar corretamente atrás do gateway. **Use o Postman** para os testes funcionais (collection disponível no repositório: `FCG.postman_collection.json`).

```
https://URL_API_GATEWAY/prod/users/swagger    → UserApi
https://URL_API_GATEWAY/prod/catalog/swagger  → CatalogApi
```

### Payments Worker (na EC2)

```bash
docker logs fcg-payments-worker --tail=50
```

### Teste do fluxo de notificações

**Teste isolado da Lambda:**
1. **Lambda → fcg-email-lambda → Testar**
2. Cole o payload:
```json
{
  "Records": [
    { "body": "{\"Type\": \"payment\"}" }
  ]
}
```
3. Verifique se o e-mail chegou

**Teste do fluxo completo:**
1. Cadastre um usuário via Postman → verifique e-mail de **welcome**
2. Realize uma compra via Postman → verifique e-mail de **payment**

---

## 🌐 Endpoints Disponíveis

Após a criação do gateway, os endpoints seguem o padrão abaixo (substitua `URL_API_GATEWAY` pela URL exibida no log do script):

### fcg-users-api

| Método | Endpoint |
|---|---|
| `POST` | `/prod/users/api/auth/login` |
| `GET` | `/prod/users/api/users` |
| `GET` | `/prod/users/api/users/{publicId}` |
| `POST` | `/prod/users/api/users` |
| `PATCH` | `/prod/users/api/users/{publicId}/deactivate` |

### fcg-catalog-api

| Método | Endpoint |
|---|---|
| `GET` | `/prod/catalog/api/games` |
| `GET` | `/prod/catalog/api/games/{publicId}` |
| `POST` | `/prod/catalog/api/games` |
| `GET` | `/prod/catalog/api/promotions` |
| `GET` | `/prod/catalog/api/promotions/{publicId}` |
| `POST` | `/prod/catalog/api/promotions` |
| `GET` | `/prod/catalog/api/gamepurchase` |
| `POST` | `/prod/catalog/api/gamepurchase` |

### fcg-payments-worker

O payments-worker não expõe endpoints HTTP — ele roda como um consumer de fila. Consome mensagens do **RabbitMQ**, publica na fila **SQS** e o fluxo segue para a Lambda de notificações.

Para verificar se está operacional:

```bash
docker logs fcg-payments-worker --tail=50
```

Um worker saudável exibe nos logs a conexão bem-sucedida com o RabbitMQ e fica aguardando mensagens.

---

## 🧪 Collection do Postman

Todos os endpoints estão pré-configurados na collection disponível no repositório.

**Para importar:**
1. Abra o Postman
2. Clique em **Import**
3. Selecione o arquivo [`FCG.postman_collection.json`](./FCG.postman_collection.json)

> ⚠️ Após importar, atualize a variável `base_url` na collection com a URL do API Gateway gerada pelo script `subir_gateway.sh`.

---

## 🔧 Comandos Úteis no EC2

Acesse a EC2 via SSH:
```bash
ssh -i machinePen.pem -o StrictHostKeyChecking=no ubuntu@IP_PUBLICO
```

**Verificar instalação do Docker:**
```bash
docker --version
```

**Status dos containers:**
```bash
docker compose ps
```

**Logs em tempo real:**
```bash
# Todos os containers
docker compose logs -f

# Container específico
docker compose logs fcg-users-api -f
docker compose logs fcg-catalog-api -f
docker compose logs fcg-rabbitmq -f
docker compose logs fcg-payments-worker -f
```

**Logs pontuais (últimas 50 linhas):**
```bash
docker logs fcg-users-api --tail 50
docker logs fcg-catalog-api --tail 50
docker logs fcg-payments-worker --tail 50
```

**Reiniciar containers após atualizar o `.env`:**
```bash
cd /home/ubuntu/app && docker compose down && docker compose up -d
```

**Logs da Lambda:**

AWS Console → **CloudWatch → Log groups → `/aws/lambda/fcg-email-lambda`**

---

## 🗄️ Acesso ao Banco de Dados

O banco pode ser acessado via IDE (SSMS ou DBeaver) usando o endpoint do RDS obtido durante a criação.

> **DBeaver:** na primeira conexão, deixe o campo **Database** em branco. Após conectar, selecione o banco desejado (`FCG_Users` ou `FCG_Catalog`).

---

## 📌 Referência de Credenciais

| Variável | Valor |
|---|---|
| `DOCKER_USERNAME` | *(ver time)*  |
| `DOCKER_PASSWORD` | *(ver time)* |
| `EC2_USER` | `ubuntu` |
| `RDS_USER` | `admin` |
| `RDS_PORT` | `1433` |
