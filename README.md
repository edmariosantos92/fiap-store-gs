# FIAP Store no Amazon EKS — Global Solution

**Cloud Developer II · Kubernetes e Serverless**

A aplicação (pastas `store-api/`, `store-worker/`, `store-front/`) é o código entregue pelo professor,
**sem alterações**. Este repositório acrescenta a **plataforma**: cluster EKS, manifestos Kubernetes
em `k8s/`, entrega por GitOps (Argo CD), segurança e escalonamento.

> A documentação original da aplicação (contrato de cada serviço, API, execução local) está em
> [`docs/APLICACAO.md`](docs/APLICACAO.md).

## Integrantes

| Nome | RM | Papel |
|---|---|---|
| Edmário Souza Santos | RM_____ | Plataforma |
| _preencher_ | RM_____ | Aplicação |
| _preencher_ | RM_____ | Segurança |

**Argo CD Application:** `fiap-store` (namespace `argocd`) — sincroniza a pasta
[`k8s/`](k8s/) deste repositório: <https://github.com/edmariosantos92/fiap-store-gs/tree/main/k8s>

---

## Estrutura

```
cluster.yaml                 cluster EKS (eksctl) para o AWS Academy Learner Lab
scripts/build-push.sh        cria os repositórios ECR, build e push das 3 imagens (store-api 1.0 e 2.0)
argocd/application.yaml      Application do Argo CD (prune + selfHeal)
k8s/                         TODOS os manifestos (Kustomize) — pasta sincronizada pelo Argo CD
  kustomization.yaml         lista de recursos + registro/tag das imagens (rollout 1.0 <-> 2.0)
  cluster/                   namespaces (Pod Security), StorageClass gp3 (EBS CSI), ClusterRole de nodes
  store-data/                Postgres (StatefulSet + EBS), Redis, NetworkPolicies
  store-prod/                ConfigMap, quota, RBAC, store-api (+HPA, PDB), store-front, store-worker
                             (+KEDA ScaledObject), Job db-migrate, CronJob store-report, Ingress
  observabilidade/           DaemonSet node-exporter (um Pod por nó)
local/minikube/              overlay Kustomize para desenvolver no minikube
avaliacao/verifica-gs.sh     script de correção do professor
avaliacao/trivy/             relatório de scan das 3 imagens + justificativas
.github/workflows/           CI: build, scan (Trivy) e push para o ECR
```

### Decisões principais

| Requisito | Como foi atendido |
|---|---|
| Não pode cair | `store-api` com 3–6 réplicas (HPA), `topologySpreadConstraints` por zona, PDB `minAvailable: 2`, rolling update `maxUnavailable: 0`; `store-front` com 2 réplicas e PDB |
| Pico sem custo fora dele | HPA por CPU na API; `store-worker` escalado pelo **KEDA** de 0 a 5 pelo tamanho da lista Redis `pedidos` |
| Segurança | PSA `restricted` (enforce) em `store-prod` **e** `store-data`; `securityContext` completo em todos os Pods; senha só em Secret montado como arquivo; NetworkPolicy *default deny* em `store-data` liberando só o necessário; token da API desligado onde não é usado; ServiceAccount da API só lê `nodes` |
| Devs olham, não mexem | Role + RoleBinding para o grupo `fiap:devs`: `get/list/watch` em pods e `pods/log` |
| Tudo no Git | Argo CD com `prune` + `selfHeal`; Job `db-migrate` como hook de Sync; ordem por `sync-wave` (dados → migração → aplicação → HPA/KEDA/Ingress) |

---

## Pré-requisitos

`aws` CLI v2, `eksctl`, `kubectl`, `helm`, `docker` (com buildx), `openssl` e `trivy`.

No Windows: `winget install Amazon.AWSCLI eksctl.eksctl Helm.Helm AquaSecurity.Trivy` (o `kubectl`
vem com o Docker Desktop). Use **Git Bash** para os comandos abaixo.

---

## Como criar o ambiente do zero

Tempo total: ~30 minutos (20 deles são o `eksctl`).

### 1. Credenciais do Learner Lab

*Start Lab* → *AWS Details* → *AWS CLI: Show* → copie o bloco para `~/.aws/credentials`.
As credenciais mudam a cada sessão. Confira:

```bash
aws sts get-caller-identity           # mostra o ID da conta
```

Se você usa outra conta, troque `992859658230` pelo seu ID em `cluster.yaml` e em
`k8s/kustomization.yaml`.

### 2. Cluster EKS

```bash
eksctl create cluster -f cluster.yaml          # 15 a 20 minutos
aws eks update-kubeconfig --name fiap-store --region us-east-1
kubectl get nodes -L topology.kubernetes.io/zone   # 4 nós em 3 zonas
```

### 3. Imagens no ECR

```bash
./scripts/build-push.sh       # cria os repositórios (1a vez) e publica store-api:1.0, store-api:2.0,
                              # store-worker:1.0 e store-front:1.0 (sempre --platform linux/amd64)
```

### 4. Componentes de plataforma (Traefik, KEDA, Argo CD)

```bash
helm repo add traefik https://traefik.github.io/charts
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm upgrade --install traefik traefik/traefik -n traefik --create-namespace \
  --set deployment.replicas=2 --wait
helm upgrade --install keda kedacore/keda -n keda --create-namespace --wait
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-repo-server
```

### 5. Namespaces e Secrets (fora do Git)

Os Secrets **nunca** vão para o Git. Primeiro criamos os namespaces (o Argo CD depois os adota),
depois os Secrets direto no cluster:

```bash
kubectl apply -f k8s/cluster/namespaces.yaml

# Senha do banco: gerada na hora, nunca escrita em arquivo. O MESMO valor nos dois namespaces.
SENHA=$(openssl rand -base64 24 | tr -d '/+=')
for ns in store-prod store-data; do
  kubectl -n $ns create secret generic store-db-credentials --from-literal=password="$SENHA"
done
unset SENHA

# Certificado TLS autoassinado com o hostname do balanceador do Traefik no subjectAltName
LB=$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
openssl req -x509 -nodes -newkey rsa:2048 -days 30 \
  -keyout /tmp/tls.key -out /tmp/tls.crt \
  -subj "/CN=$LB" -addext "subjectAltName=DNS:$LB"
kubectl -n store-prod create secret tls store-tls --cert=/tmp/tls.crt --key=/tmp/tls.key
rm -f /tmp/tls.key /tmp/tls.crt
```

> O Postgres só lê a senha **na criação** do banco. Não troque o Secret de um banco já
> inicializado: para trocar a senha, apague o PVC `data-store-db-0` (perde os dados).

### 6. Aplicação via GitOps

```bash
kubectl apply -f argocd/application.yaml
kubectl -n argocd get application fiap-store -w     # até Synced / Healthy (~3 min)
```

O Argo CD cria tudo na ordem das `sync-wave`: namespaces, StorageClass, RBAC e ConfigMap →
Postgres e Redis → Job `db-migrate` → Deployments e CronJob → HPA, ScaledObject e Ingress.

### 7. Rollout 1.0 → 2.0 (obrigatório no cluster da demonstração — B7)

Em `k8s/kustomization.yaml`, troque `newTag: "1.0"` da `store-api` por `"2.0"`, depois faça commit e push:

```bash
git commit -am "store-api 2.0" && git push
kubectl -n store-prod rollout status deploy/store-api
```

### 8. Conferir

```bash
LB=$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "https://$LB"                          # abra no navegador (certificado autoassinado)
kubectl -n store-prod create job --from=cronjob/store-report relatorio-agora   # E2 na hora
./avaliacao/verifica-gs.sh "https://$LB"
```

Interface do Argo CD (opcional):

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n argocd port-forward svc/argocd-server 8443:443    # https://localhost:8443  (admin)
```

---

## Como destruir tudo

Rode **ao fim de cada sessão** (o ambiente custa ~US$ 0,30/h). A ordem importa:

```bash
# 1. apagar a Application do Argo CD (senão ele recria tudo)
kubectl -n argocd delete application fiap-store

# 2. apagar os namespaces da aplicação e esperar os volumes EBS sumirem
kubectl delete namespace store-prod store-data observabilidade
kubectl get pv -w                 # espere a lista ficar vazia

# 3. remover o balanceador da AWS
helm uninstall traefik -n traefik

# 4. apagar o cluster
eksctl delete cluster -f cluster.yaml --disable-nodegroup-eviction

# 5. conferir que não sobrou nada
aws ec2 describe-volumes --filters Name=tag-key,Values=kubernetes.io/cluster/fiap-store \
  --query 'Volumes[].VolumeId'
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'
aws elb describe-load-balancers --query 'LoadBalancerDescriptions[].LoadBalancerName'
```

As imagens no ECR podem ficar (custo desprezível). Para apagar:
`for r in store-api store-worker store-front; do aws ecr delete-repository --repository-name $r --force; done`

---

## Roteiro dos desafios ao vivo

| # | Desafio | Comandos |
|---|---|---|
| 1 | Self-healing | `kubectl -n store-prod delete $(kubectl -n store-prod get pod -l app=store-api -o name \| head -1)` → `kubectl -n store-prod get pods -l app=store-api -w` |
| 2 | Manutenção de nó | `kubectl -n store-data get pod store-db-0 -o wide` (veja o nó) → `kubectl drain <outro-no> --ignore-daemonsets --delete-emptydir-data` → `kubectl uncordon <no>` |
| 3 | Rollback por GitOps | trocar `newTag` da `store-api` em `k8s/kustomization.yaml` (2.0 → 1.0), commit + push; o selo no topo da página muda |
| 4 | Escala a zero | botão de 50 pedidos no painel (ou `curl -k -X POST https://$LB/api/pedidos/lote?quantidade=50`) → `kubectl -n store-prod get deploy store-worker -w` |
| 5 | Persistência | `kubectl -n store-data delete pod store-db-0` → os pedidos continuam no painel |
| 6 | Pod Security | `kubectl -n store-prod run priv --image=busybox:1.36 --overrides='{"spec":{"containers":[{"name":"priv","image":"busybox:1.36","securityContext":{"privileged":true}}]}}'` → recusado (`violates PodSecurity "restricted"`) |
| 7 | RBAC | `kubectl auth can-i list pods -n store-prod --as=dev --as-group=fiap:devs` (yes); `get pods --subresource=log` (yes); `delete pods`, `get secrets`, `create pods --subresource=exec` (no) |
| 8 | Drift | `kubectl -n store-prod delete service store-front` → o Argo CD recria em segundos |
| 9 | Rede | `kubectl -n store-prod exec deploy/store-front -- nc -z -w 3 store-db.store-data.svc.cluster.local 5432` (falha) e `kubectl -n store-prod exec deploy/store-api -- python -c "import socket; socket.create_connection(('store-db.store-data.svc.cluster.local',5432),3); print('ok')"` (ok) |
| 10 | Relatório sob demanda | `kubectl -n store-prod create job --from=cronjob/store-report relatorio-$(date +%s)` |

---

## Desenvolvimento no minikube

```bash
minikube start --nodes 2 --cni calico --cpus 2 --memory 4g
docker build -t store-api:1.0 store-api && docker build -t store-worker:1.0 store-worker \
  && docker build -t store-front:1.0 store-front
minikube image load store-api:1.0 store-worker:1.0 store-front:1.0
kubectl apply -f k8s/cluster/namespaces.yaml     # depois crie os Secrets como no passo 5
kubectl apply -k local/minikube                  # StorageClass "standard" e imagens locais
```

---

## Scan de vulnerabilidades (M3)

Relatórios em [`avaliacao/trivy/`](avaliacao/trivy/), gerados com:

```bash
trivy image --severity HIGH,CRITICAL <registro>/store-api:1.0 > avaliacao/trivy/store-api.txt
```

As justificativas de cada `CRITICAL` estão em [`avaliacao/trivy/JUSTIFICATIVAS.md`](avaliacao/trivy/JUSTIFICATIVAS.md).

---

## Uso de IA (declaração)

| Ferramenta | Para quê |
|---|---|
| Claude Code (Anthropic) | apoio na escrita dos manifestos Kubernetes, do README e dos scripts de build; revisão contra o checklist do enunciado |

Todos os integrantes revisaram e conseguem explicar cada manifesto do repositório.
