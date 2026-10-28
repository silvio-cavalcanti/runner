# GitHub Actions Self-Hosted Runners em uma EC2 (`t3.large`)

CloudFormation que cria **uma instância EC2** rodando **vários runners self-hosted do GitHub**
(`RunnerCount`, padrão **4**) como serviços `systemd` independentes.

Arquivos:

| Arquivo | Conteúdo |
|---|---|
| [`github-runners-stack.yaml`](./github-runners-stack.yaml) | template CloudFormation |
| [`scripts/deploy.ps1`](./scripts/deploy.ps1) | wrapper de deploy com validação |
| [`params.example.json`](./params.example.json) | exemplo de arquivo de parâmetros |
| [`examples/self-hosted-ci.yml`](./examples/self-hosted-ci.yml) | workflow de exemplo |

## O que é criado

| Recurso | Função |
|---|---|
| `RunnerInstance` | EC2 `t3.large` (Ubuntu 24.04 LTS), volume raiz gp3 criptografado, IMDSv2 obrigatório |
| `RunnerSecurityGroup` | Sem entrada por padrão (acesso via SSM); saída restrita a 80/443/DNS |
| `RunnerRole` / `RunnerInstanceProfile` | `AmazonSSMManagedInstanceCore` + leitura de **um único** secret do Secrets Manager |
| `InstanceRecoveryAlarm` | Recupera a instância automaticamente em falha de status check |
| `gh-runner@.service` (systemd) | Uma unidade por runner: `gh-runner@1` … `gh-runner@N` |

No boot o user data:

1. instala Docker, git, jq, curl, AWS CLI v2 e cria o usuário `runner`;
2. baixa **uma vez** o binário do runner e copia para `/opt/actions-runner-<N>`;
3. instala `/usr/local/bin/gh-runner-run.sh`, que a cada execução:
   - lê o PAT do **Secrets Manager** (nada de token no template/user data);
   - remove registro "fantasma" com o mesmo nome;
   - pede um `registration-token` novo via API do GitHub;
   - registra o runner como **efêmero** (`--ephemeral`, 1 job por registro) e executa.

Resultado esperado em *Settings → Actions → Runners*: `i-xxxxxxxx-1` … `i-xxxxxxxx-4`, **Idle**.

## Pré-requisitos

### 1. Token do GitHub em um secret do Secrets Manager

Escopos necessários (ver [docs](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/autoscaling-with-self-hosted-runners#authentication-requirements)):

| Escopo | PAT clássico | PAT fine-grained |
|---|---|---|
| Repositório privado | `repo` | Administration: Read and write |
| Repositório público | `public_repo` | Administration: Read and write |
| Organização | `admin:org` | Organization self-hosted runners: Read and write |

O secret deve estar **na mesma região** do stack. O valor pode ser texto puro ou JSON com a chave `token`:

```powershell
# texto puro
aws secretsmanager create-secret --name github/actions-runner-token --secret-string "ghp_xxxxxxxxx"

# ou JSON (também aceita .pat / .github_token)
aws secretsmanager create-secret --name github/actions-runner-token --secret-string '{"token":"ghp_xxxxxxxxx"}'
```

> Se o secret usar uma **CMK própria** do KMS, adicione `kms:Decrypt` na role do stack
> (o default `aws/secretsmanager` não exige permissão extra).

> **Windows/PowerShell 5.1:** JSON inline perde as aspas ao chamar o CLI (`{token:gho_...}`
> em vez de `{"token":"gho_..."}`) e o runner falha com **401**. Use o helper
> `.\scripts\create-token-secret.ps1` (grava o JSON em arquivo) ou `--secret-string file://token.json`.

### 2. VPC / subnet com saída para a internet

- Subnet pública (IGW) → `AssignPublicIp=true` (padrão).
- Subnet privada (NAT Gateway) → `AssignPublicIp=false`.

O host precisa resolver DNS e alcançar `github.com`, `api.github.com`, `*.actions.githubusercontent.com`
e os registries de pacotes/imagens.

## Deploy

```powershell
aws cloudformation deploy `
  --stack-name gh-runners `
  --template-file github-runners-stack.yaml `
  --capabilities CAPABILITY_IAM `
  --parameter-overrides `
      GitHubScope=repository `
      GitHubOwner=minha-org `
      GitHubRepo=meu-repo `
      GitHubTokenSecretArn=arn:aws:secretsmanager:us-east-1:123456789012:secret:github/actions-runner-token-AbCdEf `
      VpcId=vpc-0123456789abcdef0 `
      SubnetId=subnet-0123456789abcdef0 `
      RunnerCount=4
```

Variação para organização:

```powershell
      GitHubScope=organization `
      GitHubOwner=minha-org `
      RunnerGroup=Default
```

Acompanhar o bootstrap:

```powershell
aws ssm start-session --target (aws cloudformation describe-stacks --stack-name gh-runners `
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text)
# dentro da sessão:
sudo tail -f /var/log/gh-runner-bootstrap.log
journalctl -u gh-runner@1 -f
```

## Usando os runners no workflow

```yaml
jobs:
  build:
    runs-on: [self-hosted, linux, x64, t3-large]
```

`self-hosted`, `linux` e `x64` são adicionados automaticamente; `t3-large` vem do parâmetro
`RunnerLabels` (aceita lista separada por vírgula, ex.: `t3-large,docker,linux-amd64`).

## Scripts auxiliares

| Arquivo | Uso |
|---|---|
| `scripts/deploy.ps1` | wrapper de `aws cloudformation deploy` com validação de parâmetros e impressão das saídas |
| `scripts/create-token-secret.ps1` | cria/atualiza o secret do token GitHub sem quebrar o JSON no Windows |
| `params.example.json` | exemplo de arquivo de parâmetros (`--parameter-overrides file://params.example.json`) |
| `examples/self-hosted-ci.yml` | workflow de exemplo com job simples e job Docker |
| `.github/workflows/runner-smoke.yml` | smoke test que valida host, ferramentas e Docker nos runners |

```powershell
.\scripts\deploy.ps1 -Owner minha-org -Repo meu-repo `
  -TokenSecretArn <ARN> -VpcId vpc-xxx -SubnetId subnet-xxx -RunnerCount 4
```

## Parâmetros principais

| Parâmetro | Default | Observação |
|---|---|---|
| `GitHubScope` | `repository` | `repository` ou `organization` |
| `GitHubOwner` | — | usuário/organização |
| `GitHubRepo` | `""` | obrigatório no escopo de repositório |
| `GitHubTokenSecretArn` | — | ARN do secret com o PAT |
| `RunnerCount` | `4` | 1–10 serviços no mesmo host |
| `RunnerLabels` | `t3-large` | labels customizadas |
| `RunnerGroup` | `""` | apenas organização |
| `RunnerVersion` | `""` | vazio = última release no boot (hoje `2.338.2`) |
| `RunnerEphemeral` | `true` | 1 job por registro, workspace limpo |
| `InstanceType` | `t3.large` | lista fechada de tipos |
| `AssignPublicIp` | `true` | `false` para subnet privada/NAT |
| `EgressMode` | `restricted` | `restricted` (80/443/DNS) ou `all` |
| `SshAllowedCidr` | `""` | vazio = SSH bloqueado (use SSM) |
| `KeyName` | `""` | obrigatório se `SshAllowedCidr` for definido |
| `VolumeSizeGiB` | `100` | gp3 criptografado |

## Capacidade e custo

- `t3.large` = **2 vCPU / 8 GiB**. Para jobs pesados de CPU use **2 runners**; 4 funciona bem
  para jobs curtos/IO-bound. Precisa de mais paralelismo: `RunnerCount` + `t3.xlarge`,
  ou mais stacks (o runner é identificado por hostname, então não colide).
- Cada runner é efêmero: **1 job por vez** por serviço. `RunnerCount` = jobs paralelos.
- Custo aproximado (us-east-1, on-demand): ~US$ 60/mês de instância + ~US$ 8 pelo volume de
  100 GiB gp3 + IP público. Preços variam por região.

## Operação

```bash
# status dos runners
systemctl status 'gh-runner@*' --no-pager

# parar/religar um runner específico
sudo systemctl stop gh-runner@3
sudo systemctl start gh-runner@3

# logs (o runner efêmero loga no journal)
journalctl -u gh-runner@3 -f

# sair do pool sem alterar o stack
sudo systemctl disable --now gh-runner@3 gh-runner@4

# voltar ao pool
sudo systemctl enable --now gh-runner@3 gh-runner@4
```

Para dar `sudo` sem senha aos jobs (muitos workflows usam `sudo apt-get ...`):

```bash
echo 'runner ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/90-runner
sudo chmod 0440 /etc/sudoers.d/90-runner
```

> Isso é equivalente a root para código de workflow. Só faça em repositórios confiáveis.

## Atualizações e substituições

Todo o provisionamento está no **UserData**. Portanto mudanças em `RunnerCount`, `RunnerLabels`,
`RunnerVersion`, `RunnerEphemeral`, `GitHubScope/Owner/Repo` ou `GitHubTokenSecretArn`
**substituem a instância** (runners em execução são interrompidos).

- Alterar apenas `RunnerCount` na mão: `systemctl enable/disable gh-runner@N` (ver acima) sem update de stack.
- O runner tem auto-update ligado; `RunnerVersion` só fixa a versão inicial.
- O token no secret pode ser rotacionado sem update: o próximo registro lê o valor novo.
  Para forçar: `sudo systemctl restart 'gh-runner@*'`.

## Segurança

- Nenhuma porta de entrada aberta por padrão; acesso via SSM Session Manager.
- Token do GitHub nunca entra no template, no user data ou em logs — é lido em runtime e só a
  role da instância tem `secretsmanager:GetSecretValue` naquele ARN.
- O grupo `docker` equivale a root; e workflows executam código arbitrário do repositório.
  Use runners self-hosted apenas em repositórios/organizações confiáveis; para repositórios
  públicos, prefira runners efêmeros isolados por job (ARC/VM por job).
- `EgressMode=restricted` limita a saída a 80/443/DNS. Se algum workflow precisar de SSH, banco
  ou outro protocolo, mude para `all` ou edite as regras de saída do security group.
- Para produção, considere autenticação por **GitHub App** em vez de PAT (token de instalação
  de curta duração) e envio dos logs do runner para CloudWatch Logs.

## Troubleshooting

| Sintoma | Onde olhar |
|---|---|
| Nenhum runner aparece no GitHub | `journalctl -u gh-runner@1`; escopo do PAT; ARN do secret na mesma região; egress liberado |
| `did not start` no bootstrap | `/var/log/gh-runner-bootstrap.log` e `/var/log/cloud-init-output.log` |
| Job fica `queued` para sempre | `runs-on` precisa casar com `RunnerLabels`; runner precisa estar `Idle` |
| `A runner with this name already exists` | o launcher apaga registro antigo; se persistir, o PAT não tem permissão de *delete* |
| `permission denied` no Docker | `sudo usermod -aG docker runner` e reinicie o serviço |
| Sem SSH/SSM | role do SSM, agente (`systemctl status amazon-ssm-agent`), subnet/NAT |
| Stack falha na criação | `aws cloudformation describe-stack-events --stack-name gh-runners` |

## Validação feita neste template

- Parse YAML validado (sintaxe, chaves duplicadas, referências `Ref`/`!If`/`!Condition`).
- User data renderizado e checado com `bash -n`, incluindo os scripts embutidos
  (`gh-token.sh`, `gh-runner-run.sh`) e a unit `gh-runner@.service`.
- `scripts/deploy.ps1` checado com o parser do PowerShell; `params.example.json` e
  `examples/self-hosted-ci.yml` validados como JSON/YAML.
- Versão/asset do runner conferidos contra a API pública do GitHub
  (`actions-runner-linux-x64-2.338.2.tar.gz`).
- Não houve deploy real (sem credenciais AWS no ambiente); rode antes:

```powershell
aws cloudformation validate-template --template-body file://github-runners-stack.yaml
cfn-lint github-runners-stack.yaml
```
