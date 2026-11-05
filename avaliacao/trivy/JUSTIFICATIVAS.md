# Scan de vulnerabilidades (Trivy) — FIAP Store

Gerado em 05/11/2026 com Trivy, severidades `HIGH` e `CRITICAL`, sobre as imagens publicadas no ECR:

| Imagem | Relatório | HIGH | CRITICAL |
|---|---|---:|---:|
| `store-api:1.0` (também 2.0) | [store-api.txt](store-api.txt) | 49 | 0 |
| `store-worker:1.0` | [store-worker.txt](store-worker.txt) | 46 | 0 |
| `store-front:1.0` | [store-front.txt](store-front.txt) | 71 | 4 |

Comando (para cada imagem):

```bash
trivy image --severity HIGH,CRITICAL <registro>/store-front:1.0 > avaliacao/trivy/store-front.txt
```

## Justificativa dos CRITICAL (`store-front`)

Os 4 achados vêm da **imagem base oficial** `nginxinc/nginx-unprivileged:1.28-alpine` (Alpine 3.23.3),
definida no `Dockerfile` do professor. O enunciado não permite alterar o código da aplicação, e a
imagem base mais recente da tag `1.28-alpine` ainda traz essas versões. A correção é reconstruir a
imagem quando a tag oficial for atualizada (o pipeline em `.github/workflows/imagens.yml` faz isso).

| CVE | Pacote | Por que o risco é aceito no nosso ambiente |
|---|---|---|
| CVE-2026-42945 | `nginx` 1.28.2 → 1.28.3 | O nginx só serve arquivos **estáticos** (HTML/JS/CSS) atrás do Traefik. Mesmo com execução de código, o processo roda como UID 101, com `readOnlyRootFilesystem`, `capabilities: drop ALL`, `allowPrivilegeEscalation: false`, seccomp `RuntimeDefault`, sem token da API do Kubernetes, e a NetworkPolicy impede o acesso ao banco e ao Redis. |
| CVE-2026-31789 | `libssl3` 3.5.5 → 3.5.6 | O problema afeta **sistemas de 32 bits**; os nós do EKS são `x86_64`. Além disso, o nginx do front não termina TLS (o TLS fica no Traefik). |
| CVE-2026-31789 | `libcrypto3` 3.5.5 → 3.5.6 | Mesmo CVE e mesma justificativa da linha anterior. |
| CVE-2026-111497 | `brotli-libs` 1.2.0 → 1.2.1 | Falha no **decodificador** Brotli. O nginx do front não descompacta conteúdo recebido; só serve arquivos estáticos. |

**Correção possível sem tocar no código:** se o professor autorizar, basta trocar a base para uma tag
corrigida (ex.: `1.28.3-alpine` ou `1.29-alpine`) e reconstruir. Nenhuma alteração no HTML ou JS.

## HIGH

Os HIGH das imagens Python (`store-api` e `store-worker`) vêm de pacotes Debian da base
`python:3.12-slim` e de dependências do `requirements.txt` do professor. Nenhum deles é
`CRITICAL`, e todos os contêineres rodam com o `securityContext` restrito descrito acima.
