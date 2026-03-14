# 📋 Infraestrutura — Guia de Subida do Ambiente

> ⚠️ Ao excluir a instância, lembrar de também excluir as chaves para que ao criar novamente, ele crie tudo.

---

## 1. Preparação do CloudShell

Abra o **CloudShell** e faça upload dos arquivos via **Ações → Carregar Arquivo**:

```
subir_rds2.sh
subir_ec2.sh
subir_gateway.sh
docker-compose.yml
```

Conceder permissão nos arquivos:

```bash
chmod +x subir_ec2.sh subir_rds2.sh subir_gateway.sh
```

---

## 2. Criar o RDS SQL Server

```bash
sed -i 's/\r//' subir_rds2.sh && ./subir_rds2.sh
```

Pegar o endpoint do banco:

```bash
aws rds describe-db-instances \
  --db-instance-identifier rds-sqlserver-instance \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text
```

Alterar o arquivo `.env` com o endpoint acima e realizar o upload no CloudShell.

> 💡 **Dica:** Eu preferi deixar o envio do `.env` por último, assim dá tempo de criar a instância, e já subo ele certo pro CloudShell com o novo endereço do banco de dados. Então fiz assim:
> 1. Deixei o RDS criando
> 2. Criei o EC2, fiz até o passo de copiar o docker-compose
> 3. Assim que o RDS criou, copiei a string, coloquei no `.env` → subi pro CloudShell → e depois fiz o passo de copiar ele pro EC2

---

## 3. Criar a Instância EC2

```bash
sed -i 's/\r//' subir_ec2.sh && ./subir_ec2.sh
```

Pegar o arquivo `.pem` para atualizar no GitHub Secret:

```bash
cat machinePen.pem
```

Pegar o IP público da EC2 para atualizar no GitHub Secret:

```bash
aws ec2 describe-instances \
  --filters 'Name=tag:Name,Values=machineOne' 'Name=instance-state-name,Values=running' \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text
```

---

## 4. Enviar arquivos para a EC2

> Executar no CloudShell. Substituir `IP_PUBLICO` pelo IP obtido no passo anterior.

Ajustar permissão da chave (necessário para o SCP funcionar):

```bash
chmod 400 machinePen.pem
```

Criar a pasta de destino na EC2:

```bash
ssh -i machinePen.pem -o StrictHostKeyChecking=no ubuntu@IP_PUBLICO \
  'mkdir -p /home/ubuntu/app'
```

Copiar o docker-compose para a EC2:

```bash
scp -i machinePen.pem -o StrictHostKeyChecking=no \
  docker-compose.yml \
  ubuntu@IP_PUBLICO:/home/ubuntu/app/docker-compose.yml
```

Copiar o `.env` para a EC2:

```bash
scp -i machinePen.pem -o StrictHostKeyChecking=no \
  .env \
  ubuntu@IP_PUBLICO:/home/ubuntu/app/.env
```

---

## 5. Executar o Pipeline no GitHub Actions

> ⚠️ **Importante:** não esqueça de alterar as secrets **antes** de rodar o pipeline:
> - `EC2_HOST` → IP da EC2
> - `EC2_SSH_KEY` → conteúdo do arquivo `.pem`

Repositórios:
- `FCG.UsersAPI`
- `FCG.CatalogAPI`
- [`FCG.PaymentsAPI`](https://github.com/anabordinhon/FCG.PaymentsAPI)

---

## 6. Criar o API Gateway

Após a execução dos pipelines com sucesso:

```bash
sed -i 's/\r//' subir_gateway.sh && ./subir_gateway.sh
```

O log da criação do API Gateway irá disponibilizar os links dos endpoints com a nova URL para utilizar nos testes.

> ⚠️ Após a subida do API Gateway, não será possível acessar o Swagger através do IP Público, pois as portas `8081` e `8082` ficam restritas aos CIDRs do API Gateway. Se precisar acessar o Swagger em algum momento, será necessário liberar temporariamente o IP no Security Group.

---

## 7. Testar se as APIs subiram

```
https://URL_API_GATEWAY/prod/users/swagger    → UserApi
https://URL_API_GATEWAY/prod/catalog/swagger  → CatalogApi
```

Para o **PaymentsAPI Worker** (rodar no console do EC2):

```bash
docker logs fcg-payments-worker --tail=50
```

> **Obs.:** Pode acontecer do Swagger não renderizar corretamente atrás do gateway. Importante sempre realizar os testes através do Postman (documentação para importação disponível no repositório — `FCG.postman_collection.json`).

> ⚠️ **Importante:** não esquecer de realizar a subida do Lambda através do passo a passo — `README-lambda.md`.

---

## 8. Comandos Úteis no EC2

Verificar se o Docker foi instalado:

```bash
docker --version
```

Verificar se os containers subiram:

```bash
docker compose ps
```

Ver os logs em tempo real:

```bash
# Todos os containers
docker compose logs -f

# Apenas um container específico
docker compose logs fcg-users-api -f
docker compose logs fcg-catalog-api -f
docker compose logs fcg-rabbitmq -f
```

---

## 9. Acesso ao Banco de Dados

Através do endereço de banco que colocamos no `.env`, é possível acessar via IDE (SSMS ou DBeaver).

> **DBeaver:** a primeira conexão deve ser feita sem informar o nome do database.

---

## 📌 Referência

| Variável | Valor |
|---|---|
| `DOCKER_USERNAME` | `daiana2026dev` |
| `DOCKER_PASSWORD` | *(ver time)* |
| `EC2_USER` | `ubuntu` |
