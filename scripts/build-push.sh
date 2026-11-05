#!/usr/bin/env bash
# Build e push das 3 imagens para o ECR do grupo (rodar da raiz do repositorio)
set -euo pipefail
export AWS_REGION=${AWS_REGION:-us-east-1}
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export REGISTRY=$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

for repo in store-api store-worker store-front; do
  aws ecr describe-repositories --repository-names $repo --region $AWS_REGION >/dev/null 2>&1 \
    || aws ecr create-repository --repository-name $repo --region $AWS_REGION \
         --image-scanning-configuration scanOnPush=true >/dev/null
done

aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $REGISTRY

docker buildx build --platform linux/amd64 --build-arg APP_VERSION=1.0 -t $REGISTRY/store-api:1.0 --push store-api
docker buildx build --platform linux/amd64 --build-arg APP_VERSION=2.0 -t $REGISTRY/store-api:2.0 --push store-api
docker buildx build --platform linux/amd64 -t $REGISTRY/store-worker:1.0 --push store-worker
docker buildx build --platform linux/amd64 -t $REGISTRY/store-front:1.0 --push store-front
echo "Imagens publicadas em $REGISTRY"
