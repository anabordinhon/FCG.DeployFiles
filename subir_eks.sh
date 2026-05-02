#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# LER ARQUIVO .ENV AUTOMATICAMENTE
# ==========================================
if [ -f .env ]; then
  echo "==> Encontrado arquivo .env. Carregando variáveis..."
  source .env
fi
# ==========================================

CLUSTER_NAME="${CLUSTER_NAME:-fcg-eks}"
AWS_REGION="${AWS_REGION:-us-east-1}"
K8S_VERSION="${K8S_VERSION:-1.32}"

NODEGROUP_NAME="${NODEGROUP_NAME:-fcg-nodes}"
NODE_TYPE="${NODE_TYPE:-t3.medium}"
NODES_DESIRED="${NODES_DESIRED:-2}"
NODES_MIN="${NODES_MIN:-1}"
NODES_MAX="${NODES_MAX:-2}"
DISK_SIZE="${DISK_SIZE:-20}"
AMI_TYPE="${AMI_TYPE:-AL2023_x86_64_STANDARD}"

CLUSTER_ROLE_NAME="${CLUSTER_ROLE_NAME:-LabRole}"
NODE_ROLE_NAME="${NODE_ROLE_NAME:-LabRole}"

RABBITMQ_USERNAME="${RABBITMQ_USERNAME:-}"
RABBITMQ_PASSWORD="${RABBITMQ_PASSWORD:-}"

log() {
  echo ""
  echo "==> $1"
}

fail() {
  echo "ERRO: $1" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Comando obrigatório não encontrado: $1"
}

aws_cli() {
  aws --no-cli-pager "$@"
}

ensure_local_bin() {
  mkdir -p "$HOME/bin"
  case ":$PATH:" in
    *":$HOME/bin:"*) ;;
    *) export PATH="$HOME/bin:$PATH" ;;
  esac
}

install_kubectl() {
  if command -v kubectl >/dev/null 2>&1; then
    log "kubectl já está instalado: $(command -v kubectl)"
    return
  fi

  log "Instalando kubectl..."
  ensure_local_bin

  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64) K8S_ARCH="amd64" ;;
    aarch64|arm64) K8S_ARCH="arm64" ;;
    *) fail "Arquitetura não suportada para kubectl: $ARCH" ;;
  esac

  KUBECTL_VERSION="$(curl -fsSL "https://dl.k8s.io/release/stable-${K8S_VERSION}.txt" || true)"
  if [ -z "${KUBECTL_VERSION:-}" ]; then
    KUBECTL_VERSION="$(curl -fsSL "https://dl.k8s.io/release/stable.txt")"
  fi

  curl -fsSL -o "$HOME/bin/kubectl" "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${K8S_ARCH}/kubectl"
  chmod +x "$HOME/bin/kubectl"

  require_cmd kubectl
  log "kubectl instalado com sucesso em $HOME/bin/kubectl"
}

check_aws_identity() {
  log "Validando credenciais AWS..."
  aws_cli sts get-caller-identity >/dev/null || fail "AWS CLI sem credenciais válidas no ambiente"
  aws_cli sts get-caller-identity
}

resolve_cluster_role_arn() {
  log "Resolvendo Cluster Role..."
  CLUSTER_ROLE_ARN="$(aws_cli iam get-role \
    --role-name "$CLUSTER_ROLE_NAME" \
    --query 'Role.Arn' \
    --output text)" || fail "Não encontrei a role do cluster: $CLUSTER_ROLE_NAME"

  [ -n "$CLUSTER_ROLE_ARN" ] && [ "$CLUSTER_ROLE_ARN" != "None" ] || fail "Role do cluster inválida: $CLUSTER_ROLE_NAME"

  log "Cluster Role ARN: $CLUSTER_ROLE_ARN"
}

resolve_node_role_arn() {
  log "Resolvendo Node Role..."
  NODE_ROLE_ARN="$(aws_cli iam get-role \
    --role-name "$NODE_ROLE_NAME" \
    --query 'Role.Arn' \
    --output text)" || fail "Não encontrei a node role: $NODE_ROLE_NAME"

  [ -n "$NODE_ROLE_ARN" ] && [ "$NODE_ROLE_ARN" != "None" ] || fail "Node role inválida: $NODE_ROLE_NAME"

  log "Node Role ARN: $NODE_ROLE_ARN"
}

resolve_default_vpc_and_subnets() {
  log "Buscando VPC e subnets padrão..."

  VPC_ID="$(aws_cli ec2 describe-vpcs \
    --region "$AWS_REGION" \
    --filters Name=isDefault,Values=true \
    --query 'Vpcs[0].VpcId' \
    --output text)" || fail "Erro ao buscar VPC padrão"

  [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ] || fail "Não encontrei VPC padrão"

  mapfile -t SUBNET_ARRAY < <(
    aws_cli ec2 describe-subnets \
      --region "$AWS_REGION" \
      --filters Name=vpc-id,Values="$VPC_ID" \
      --query 'Subnets[].[SubnetId,AvailabilityZone,AvailabilityZoneId]' \
      --output text | awk '$3 != "use1-az3" && !seen[$2]++ {print $1}' | head -n 2
  )

  [ "${#SUBNET_ARRAY[@]}" -ge 2 ] || fail "Não encontrei duas subnets válidas em AZs diferentes na VPC padrão"

  SUBNET_IDS_CSV="$(IFS=,; echo "${SUBNET_ARRAY[*]}")"

  log "VPC: $VPC_ID"
  log "Subnets selecionadas: $SUBNET_IDS_CSV"
}

cluster_exists() {
  aws_cli eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1
}

nodegroup_exists() {
  aws_cli eks describe-nodegroup \
    --cluster-name "$CLUSTER_NAME" \
    --nodegroup-name "$NODEGROUP_NAME" \
    --region "$AWS_REGION" >/dev/null 2>&1
}

create_cluster_if_needed() {
  if cluster_exists; then
    log "Cluster EKS '$CLUSTER_NAME' já existe. Pulando criação."
    return
  fi

  log "Criando cluster EKS '$CLUSTER_NAME'..."
  aws_cli eks create-cluster \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --kubernetes-version "$K8S_VERSION" \
    --role-arn "$CLUSTER_ROLE_ARN" \
    --resources-vpc-config "subnetIds=${SUBNET_IDS_CSV},endpointPublicAccess=true,endpointPrivateAccess=false" \
    --output json || fail "Falha ao criar cluster EKS"

  aws_cli eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1 || fail "O create-cluster terminou, mas o cluster não apareceu. Verifique permissões/quota do laboratório."

  log "Cluster criado. Aguardando ficar ativo..."
  aws_cli eks wait cluster-active --name "$CLUSTER_NAME" --region "$AWS_REGION" || fail "Timeout aguardando cluster ficar ativo"

  log "Status do cluster:"
  aws_cli eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.status' --output text
}

create_nodegroup_if_needed() {
  if nodegroup_exists; then
    log "Nodegroup '$NODEGROUP_NAME' já existe. Pulando criação."
    return
  fi

  log "Criando nodegroup '$NODEGROUP_NAME'..."
  aws_cli eks create-nodegroup \
    --cluster-name "$CLUSTER_NAME" \
    --nodegroup-name "$NODEGROUP_NAME" \
    --region "$AWS_REGION" \
    --subnets "${SUBNET_ARRAY[@]}" \
    --node-role "$NODE_ROLE_ARN" \
    --scaling-config "minSize=${NODES_MIN},maxSize=${NODES_MAX},desiredSize=${NODES_DESIRED}" \
    --disk-size "$DISK_SIZE" \
    --instance-types "$NODE_TYPE" \
    --ami-type "$AMI_TYPE" \
    --capacity-type ON_DEMAND \
    --output json || fail "Falha ao criar nodegroup"

  log "Nodegroup criado. Aguardando ficar ativo..."
  aws_cli eks wait nodegroup-active \
    --cluster-name "$CLUSTER_NAME" \
    --nodegroup-name "$NODEGROUP_NAME" \
    --region "$AWS_REGION" || fail "Timeout aguardando nodegroup ficar ativo"

  log "Status do nodegroup:"
  aws_cli eks describe-nodegroup \
    --cluster-name "$CLUSTER_NAME" \
    --nodegroup-name "$NODEGROUP_NAME" \
    --region "$AWS_REGION" \
    --query 'nodegroup.status' \
    --output text
}

update_kubeconfig() {
  log "Atualizando kubeconfig..."
  aws_cli eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" --alias "$CLUSTER_NAME" || fail "Falha ao atualizar kubeconfig"
}

show_status() {
  log "Contexto atual do kubectl:"
  kubectl config current-context || true

  log "Nodes do cluster:"
  kubectl get nodes -o wide || true

  log "Cluster EKS pronto para receber manifests."
}

deploy_rabbitmq() {
  log "Provisionando RabbitMQ no cluster (Modo Lab/emptyDir)..."

  if [ -z "${RABBITMQ_USERNAME:-}" ] || [ -z "${RABBITMQ_PASSWORD:-}" ]; then
    fail "Defina RABBITMQ_USERNAME e RABBITMQ_PASSWORD antes de executar o script."
  fi

  kubectl apply -f - <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: fcg
YAML

  kubectl create secret generic rabbitmq-secret \
    --namespace=fcg \
    --from-literal=username="${RABBITMQ_USERNAME}" \
    --from-literal=password="${RABBITMQ_PASSWORD}" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl apply -f - <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fcg-rabbitmq
  namespace: fcg
  labels:
    app: fcg-rabbitmq
spec:
  replicas: 1
  selector:
    matchLabels:
      app: fcg-rabbitmq
  template:
    metadata:
      labels:
        app: fcg-rabbitmq
    spec:
      containers:
        - name: rabbitmq
          image: rabbitmq:3-management
          ports:
            - name: amqp
              containerPort: 5672
            - name: management
              containerPort: 15672
          env:
            - name: RABBITMQ_DEFAULT_USER
              valueFrom:
                secretKeyRef:
                  name: rabbitmq-secret
                  key: username
            - name: RABBITMQ_DEFAULT_PASS
              valueFrom:
                secretKeyRef:
                  name: rabbitmq-secret
                  key: password
          volumeMounts:
            - name: rabbitmq-data
              mountPath: /var/lib/rabbitmq
          livenessProbe:
            exec:
              command: ["rabbitmq-diagnostics", "-q", "ping"]
            initialDelaySeconds: 30
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 12
          readinessProbe:
            exec:
              command: ["rabbitmq-diagnostics", "-q", "ping"]
            initialDelaySeconds: 20
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 12
          resources:
            requests:
              cpu: "200m"
              memory: "256Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"
      volumes:
        - name: rabbitmq-data
          emptyDir: {}
YAML

  kubectl apply -f - <<YAML
apiVersion: v1
kind: Service
metadata:
  name: fcg-rabbitmq
  namespace: fcg
  labels:
    app: fcg-rabbitmq
spec:
  selector:
    app: fcg-rabbitmq
  type: ClusterIP
  ports:
    - name: amqp
      port: 5672
      targetPort: 5672
    - name: management
      port: 15672
      targetPort: 15672
YAML

  log "Aguardando RabbitMQ ficar disponivel..."
  kubectl rollout status deployment/fcg-rabbitmq \
    --namespace=fcg \
    --timeout=180s || fail "Timeout aguardando RabbitMQ"

  log "RabbitMQ disponivel em fcg-rabbitmq:5672 (interno ao cluster)."
}

deploy_elasticsearch() {
  log "Provisionando Elasticsearch no cluster (Modo Lab/emptyDir)..."

  kubectl apply -f - <<YAML
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: fcg-elasticsearch
  namespace: fcg
  labels:
    app: fcg-elasticsearch
spec:
  serviceName: fcg-elasticsearch
  replicas: 1
  selector:
    matchLabels:
      app: fcg-elasticsearch
  template:
    metadata:
      labels:
        app: fcg-elasticsearch
    spec:
      initContainers:
        - name: fix-map-count
          image: busybox
          command: ["sysctl", "-w", "vm.max_map_count=262144"]
          securityContext:
            privileged: true
        - name: fix-permissions
          image: busybox
          command: ["sh", "-c", "chown -R 1000:1000 /usr/share/elasticsearch/data"]
          volumeMounts:
            - name: es-data
              mountPath: /usr/share/elasticsearch/data
      containers:
        - name: elasticsearch
          image: docker.elastic.co/elasticsearch/elasticsearch:8.13.4
          ports:
            - name: http
              containerPort: 9200
            - name: transport
              containerPort: 9300
          env:
            - name: discovery.type
              value: "single-node"
            - name: xpack.security.enabled
              value: "false"
            - name: ES_JAVA_OPTS
              value: "-Xms512m -Xmx512m"
            - name: cluster.name
              value: "fcg-cluster"
            - name: bootstrap.memory_lock
              value: "false"
          volumeMounts:
            - name: es-data
              mountPath: /usr/share/elasticsearch/data
          readinessProbe:
            httpGet:
              path: /_cluster/health?wait_for_status=yellow&timeout=5s
              port: 9200
            initialDelaySeconds: 40
            periodSeconds: 10
            failureThreshold: 18
          livenessProbe:
            httpGet:
              path: /_cluster/health
              port: 9200
            initialDelaySeconds: 90
            periodSeconds: 20
            failureThreshold: 6
          resources:
            requests:
              cpu: "300m"
              memory: "768Mi"
            limits:
              cpu: "1000m"
              memory: "1Gi"
      volumes:
        - name: es-data
          emptyDir: {}
YAML

  kubectl apply -f - <<YAML
apiVersion: v1
kind: Service
metadata:
  name: fcg-elasticsearch
  namespace: fcg
  labels:
    app: fcg-elasticsearch
spec:
  selector:
    app: fcg-elasticsearch
  type: ClusterIP
  ports:
    - name: http
      port: 9200
      targetPort: 9200
    - name: transport
      port: 9300
      targetPort: 9300
YAML

  log "Aguardando Elasticsearch ficar disponivel (pode levar ate 3 minutos)..."
  kubectl rollout status statefulset/fcg-elasticsearch \
    --namespace=fcg \
    --timeout=300s || fail "Timeout aguardando Elasticsearch"

  log "Elasticsearch disponivel em fcg-elasticsearch:9200 (interno ao cluster)."
}


deploy_cloudwatch_agent() {
  log "Provisionando CloudWatch Agent DaemonSet no cluster..."

  # Namespace
  kubectl apply -f - <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: amazon-cloudwatch
  labels:
    name: amazon-cloudwatch
YAML

  # ServiceAccount
  kubectl apply -f - <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cloudwatch-agent
  namespace: amazon-cloudwatch
YAML

  # ConfigMap
  kubectl apply -f - <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: cloudwatch-agent-config
  namespace: amazon-cloudwatch
data:
  amazon-cloudwatch-agent.json: |
    {
      "traces": {
        "traces_collected": {
          "otlp": {
            "grpc_endpoint": "0.0.0.0:4317",
            "http_endpoint": "0.0.0.0:4318"
          }
        }
      },
      "logs": {
        "metrics_collected": {
          "otlp": {
            "grpc_endpoint": "0.0.0.0:4317",
            "http_endpoint": "0.0.0.0:4318"
          }
        }
      },
      "metrics": {
        "namespace": "FCG/Payments",
        "metrics_collected": {
          "otlp": {
            "grpc_endpoint": "0.0.0.0:4317",
            "http_endpoint": "0.0.0.0:4318"
          }
        }
      }
    }
YAML

  # DaemonSet
  kubectl apply -f - <<YAML
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: cloudwatch-agent
  namespace: amazon-cloudwatch
  labels:
    app: cloudwatch-agent
spec:
  selector:
    matchLabels:
      app: cloudwatch-agent
  template:
    metadata:
      labels:
        app: cloudwatch-agent
    spec:
      serviceAccountName: cloudwatch-agent
      containers:
        - name: cloudwatch-agent
          image: amazon/cloudwatch-agent:latest
          ports:
            - name: otlp-grpc
              containerPort: 4317
              hostPort: 4317
            - name: otlp-http
              containerPort: 4318
              hostPort: 4318
          env:
            - name: AWS_REGION
              value: "us-east-1"
          volumeMounts:
            - name: config
              mountPath: /etc/cwagentconfig
            - name: rootfs
              mountPath: /rootfs
              readOnly: true
            - name: dockersock
              mountPath: /var/run/docker.sock
              readOnly: true
            - name: varlibdocker
              mountPath: /var/lib/docker
              readOnly: true
            - name: sys
              mountPath: /sys
              readOnly: true
            - name: devdisk
              mountPath: /dev/disk
              readOnly: true
          resources:
            requests:
              cpu: "100m"
              memory: "100Mi"
            limits:
              cpu: "200m"
              memory: "200Mi"
      volumes:
        - name: config
          configMap:
            name: cloudwatch-agent-config
            items:
              - key: amazon-cloudwatch-agent.json
                path: cwagentconfig.json
        - name: rootfs
          hostPath:
            path: /
        - name: dockersock
          hostPath:
            path: /var/run/docker.sock
        - name: varlibdocker
          hostPath:
            path: /var/lib/docker
        - name: sys
          hostPath:
            path: /sys
        - name: devdisk
          hostPath:
            path: /dev/disk
      terminationGracePeriodSeconds: 60
YAML

  log "CloudWatch Agent DaemonSet aplicado. Verificando rollout..."
  kubectl rollout status daemonset/cloudwatch-agent \
    --namespace=amazon-cloudwatch \
    --timeout=120s || fail "Timeout aguardando CloudWatch Agent DaemonSet"

  log "CloudWatch Agent disponivel em HOST_IP:4317 em todos os nodes."
}

main() {
  export AWS_PAGER=""

  ensure_local_bin
  require_cmd aws
  require_cmd curl

  install_kubectl
  require_cmd kubectl

  check_aws_identity
  resolve_cluster_role_arn
  resolve_node_role_arn
  resolve_default_vpc_and_subnets

  create_cluster_if_needed
  create_nodegroup_if_needed
  update_kubeconfig
  
  show_status
  deploy_rabbitmq
  deploy_elasticsearch 
  deploy_cloudwatch_agent

  log "Provisionamento do EKS concluído com sucesso."
}

main "$@"
