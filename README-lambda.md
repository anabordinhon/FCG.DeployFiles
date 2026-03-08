# Checklist Nova Sessão — Notificações (SNS + SQS + Lambda)

---

## 1 — Atualizar Credenciais

### Onde encontrar as credenciais
1. Acesse o **AWS Academy** → **Learner Lab** → **Start Lab** (aguarde ficar verde)
2. Clique em **AWS Details** → **Show** ao lado de "AWS CLI"
3. Copie os 3 valores: `aws_access_key_id`, `aws_secret_access_key` e `aws_session_token`

### GitHub Secrets
Repositório **FCG.NotificationsLambda** → **Settings → Secrets → Actions**

Atualize os 3 secrets com os valores copiados acima:
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_SESSION_TOKEN`

### .env do EC2
```env
AWS_ACCESS_KEY_ID=ASIA...
AWS_SECRET_ACCESS_KEY=xxxxx...
AWS_SESSION_TOKEN=xxxxx...
```

---

## 2 — Recriar o Tópico SNS

1. **AWS Console → SNS → Topics → Create topic**
2. **Type:** Standard
3. **Name:** `fcg-email-topic`
4. Clique em **Create topic**
5. Copie o **ARN** gerado

### Confirmar e-mail na subscription
1. Na página do tópico → **Create subscription**
2. **Protocol:** Email
3. **Endpoint:** seu e-mail
4. Clique em **Create subscription**
5. Acesse o e-mail e clique em **"Confirm subscription"**
6. Status deve ficar **Confirmed** ✅

### ⚠️ Atualizar o ARN no GitHub Secret ANTES de continuar
Repositório **FCG.NotificationsLambda** → **Settings → Secrets → Actions**
- Edite `SNS_TOPIC_ARN` com o novo ARN

> Faça isso agora antes de prosseguir — o deploy da Lambda depende desse valor para configurar a variável de ambiente corretamente.

---

## 3 — Recriar a Fila SQS

1. **AWS Console → SQS → Create queue**
2. **Type:** Standard
3. **Name:** `fcg-email-queue`
4. **Visibility timeout:** 60 segundos
5. Clique em **Create queue**
6. Copie a **URL da fila**

### Atualizar a URL no .env do EC2
```env
AWS_SQS_QUEUE_URL=https://sqs.us-east-1.amazonaws.com/SEU_ACCOUNT_ID/fcg-email-queue
```

---

## 4 — Deploy da Lambda

1. Acesse o repositório **FCG.NotificationsLambda** no GitHub
2. Clique na aba **Actions**
3. Selecione o workflow **Deploy Lambda .NET**
4. Clique em **Run workflow** → **Run workflow**
5. Aguarde o ✅ verde

Após o deploy, confirme em **Lambda → fcg-email-lambda → Configuration → Environment variables** que `SNS_TOPIC_ARN` está com o novo ARN.

---

## 5 — Reconectar o SQS como Gatilho da Lambda

1. **AWS Console → Lambda → fcg-email-lambda**
2. Clique em **Adicionar gatilho**
3. Selecione **SQS**
4. **Fila SQS:** `fcg-email-queue`
5. **Tamanho do lote:** 1
6. Clique em **Adicionar**

---

## 6 — Testar

### Teste rápido da Lambda isolada
1. **Lambda → fcg-email-lambda → Testar**
2. Cole o JSON:
```json
{
  "Records": [
    { "body": "{\"Type\": \"payment\"}" }
  ]
}
```
3. Clique em **Testar** → verifique se o e-mail chegou

### Teste do fluxo completo
1. Cadastre um usuário via Swagger → verifique e-mail de **welcome**
2. Faça uma compra via Swagger → verifique e-mail de **payment**

### Ver logs se algo falhar
```bash
# Logs da API de usuários
docker logs fcg-users-api --tail 100

# Logs do payments worker
docker logs fcg-payments-worker --tail 100
```

Logs da Lambda → **CloudWatch → Log groups → /aws/lambda/fcg-email-lambda**
