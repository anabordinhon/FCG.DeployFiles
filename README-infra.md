Ao excluir a instancia, lembrar de também excluir as chaves para que ao criar novamente, 
ele crie tudo.

Abrir o cloudshell
	Subir através do Acoes > Carregar Arquivo:
		subir_rds2.sh
		subir_ec2.sh
		subir_gateway.sh
		docker-compose.yml
		
	Conceder permissão pros arquivos:
		chmod +x subir_ec2.sh subir_rds2.sh subir_gateway.sh
		
	Criar o RDS SQL Server
		sed -i 's/\r//' subir_rds2.sh && ./subir_rds2.sh
	Pegar o endpoint do banco:
aws rds describe-db-instances \
  --db-instance-identifier rds-sqlserver-instance \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text
	
	Alterar o arquivo .env com as credenciais acima, e realizar o upload no cloudshell.
	(Eu preferi deixar o envio do .env por ultimo, assim da tempo de criar a instancia, e 
	ai ja subo ele certo pro cloudshell com o novo endereco do banco de dados. 
	Entao fiz assim:
		Deixei o rds criando
		Criei o EC2, fiz até o passo de copiar o docker compose
		Assim que o rds criou, eu copiei a string, coloquei no .env > subi pro cloudshell 
		e depois fiz o passo de copiar ele pro EC2.)
	
	Criar a Instância EC2
		sed -i 's/\r//' subir_ec2.sh && ./subir_ec2.sh

		Pegar o arquivo .pem para atualizar no github secret:
			cat machinePen.pem
			
		Pegar o IP público da EC2 para atualizar no github secret:
aws ec2 describe-instances \
  --filters 'Name=tag:Name,Values=machineOne' 'Name=instance-state-name,Values=running' \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text
		
	Enviar docker-compose e .env para a EC2 - executar no cloudshell
		Ajustar permissão da chave (necessário para o SCP funcionar):
			chmod 400 machinePen.pem

		Criar a pasta de destino na EC2:
ssh -i machinePen.pem -o StrictHostKeyChecking=no ubuntu@IP_PUBLICO \
  'mkdir -p /home/ubuntu/app'

		Copiar o docker-compose para a EC2:
scp -i machinePen.pem -o StrictHostKeyChecking=no \
  docker-compose.yml \
  ubuntu@IP_PUBLICO:/home/ubuntu/app/docker-compose.yml

		Copiar o .env para a EC2:
scp -i machinePen.pem -o StrictHostKeyChecking=no \
  .env \
  ubuntu@IP_PUBLICO:/home/ubuntu/app/.env


Executar o pipe no github action. 
Importante : Nao esqueca de alterar as secrets 
	EC2_HOST : ip do EC2
	EC2_SSH_KEY : info do arquivo .pem
antes de rodar o PIPE.

Após a execuçao dos pipelines com sucesso, executar a subida do API Gateway:
		sed -i 's/\r//' subir_gateway.sh && ./subir_gateway.sh
	O log da criaçao do API Gateway irá disponibilizar os links dos endpoints com a nova URL para utilizar com testes.
	Após a subida do API Gateway, não será possível acessar o swagger através do IP Publico, pois as portas 8081 e 8082 ficam 
	restritas aos CIDRs do API Gateway. Se precisar acessar o Swagger (através do IP Publico) em algum momento, 
	será necessário liberar temporariamente o IP no Security Group.

Testar se a API subiu:
	https://URL_API_GATEWAY/prod/users/swagger -> UserApi
	https://URL_API_GATEWAY/prod/catalog/swagger -> CatalogApi
	docker logs fcg-payments-worker --tail=50 (rodar no console do EC2) - PaymentsAPI Worker

Obs.: Pode acontecer do swagger não renderizar corretamente atrás do gateway, importante sempre realizar os testes
através do postman (documentaçao para importaçao disponivel no repositório - FCG.postman_collection.json)

IMPORTANTE:
	Não esquecer de realizar a subida do lambda através do passo a passo - README-lambda.md.
	
No console do EC2:

Verificar se o docker foi instalado:
docker --version

Verificar se os containers subiram  
docker compose ps

Ver os logs em tempo real:
# Todos os containers
docker compose logs -f

# Apenas um container específico
docker compose logs fcg-users-api -f
docker compose logs fcg-catalog-api -f
docker compose logs fcg-rabbitmq -f

Através do endereço de banco que colocamos no .env, é possível acessar atraves de uma IDE (SSMS, DBEAVER)
Para o dbeaver, a primeira conexao deve ser feita sem informar o nome do database.

DOCKER_USERNAME: daiana2026dev

DOCKER_PASSWORD: 

EC2_USER: ubuntu
