# Home Lab

App de barra de menus para macOS que monitora e controla uma máquina Linux com GNOME pela rede:
área de trabalho remota com tela virtual (funciona sem monitor ligado no host), métricas, arquivos,
serviços, containers, portas, Tailscale e Cloudflare.

Tudo passa por SSH. Nada fica instalado nem escutando no host além do RDP do próprio GNOME.

## O que faz

- **Conectar**: RDP para a sessão em andamento ou para o login remoto, com tela virtual na resolução
  escolhida, um ou vários monitores, ou espelhando um monitor físico do host.
- **Visão geral**: CPU, memória, GPU, discos, rede, ações rápidas e atualizações pendentes do host.
- **Serviços**: unidades systemd, containers e imagens Docker, processos; iniciar, parar, logs,
  editar arquivos de unidade e de compose.
- **Rede**: portas abertas (com túnel SSH para as que só escutam no host), firewall ufw,
  publicações do Tailscale e túneis do Cloudflare.
- **Segurança**: destrancar tela e cofres do GNOME e rodar ações de administrador sem ir até o host.
- **Ambientes**: várias máquinas, cada uma com certificado fixado e credenciais próprias no Keychain.

## Instalar

No Mac (macOS 14 ou mais novo; o vidro usa o Liquid Glass a partir do macOS 26):

1. Baixe o `Home-Lab-<versão>.dmg` da [última versão](https://github.com/BarretoDiego/homelab-controller/releases/latest)
   e arraste o app para Applications. Ele não é assinado pela Apple: na primeira vez, botão direito › Abrir.
2. `brew install freerdp`. Para acesso de fora de casa, Tailscale no Mac e no host.
3. Abra o app e siga o assistente **Novo ambiente**.

No host, nada é obrigatório: o assistente prepara a máquina por SSH. Para preparar à mão, instale o
pacote da mesma versão e rode `homelab-host setup`:

```sh
sudo apt install ./homelab-host_*_all.deb
homelab-host setup
```

Requisitos do host: Debian ou Ubuntu com GNOME, sessão gráfica aberta (login automático recomendado) e SSH.

## Atualizações

O app consulta as versões publicadas aqui ao abrir e duas vezes por dia. Quando há uma mais nova, mostra
"Atualizar" no topo da janela e no menu do painel; ao aceitar, baixa o `Home-Lab-<versão>.app.zip`,
confere o SHA-256 publicado pelo GitHub e a assinatura, troca o app de lugar e reabre.

Como o app é assinado ad hoc, cada versão tem outra assinatura e o macOS pede de novo o acesso às
credenciais no Keychain depois de atualizar.

## Compilar

Precisa das ferramentas de linha de comando do Xcode 26 (o código usa a API do Liquid Glass) e de Python 3.

```sh
./build.sh --ci      # compila, roda o autoteste e gera dist/
./build.sh           # o mesmo, e instala o app em ~/Desktop/Home Lab
```

`dist/` recebe o app, o DMG, o `.app.zip` e o `.deb`. O autoteste (`HomeLab selftest`) cobre a lógica
pura: planejamento da conexão, validações, decodificação do que o host responde, comparação de versões.

| Caminho | O que é |
| --- | --- |
| `Core.swift` | modelos e lógica sem interface nem E/S |
| `Logic.swift` | SSH, Keychain, estado do app |
| `Views.swift` | painel da barra de menus |
| `MainWindow.swift`, `Services.swift`, `Network.swift`, `Wizard.swift` | janela principal e suas seções |
| `Update.swift` | atualização pelo GitHub |
| `host/homelab-host.py` | lado Linux; o app o envia por SSH a cada chamada |
| `packaging/` | `.deb`, artes derivadas e layout do DMG |
| `assets/generated/` | artes originais e os prompts que as geraram |

## Publicar uma versão

```sh
git tag v5.1.0 && git push origin v5.1.0
```

O workflow `Release` compila o app num runner macOS, monta o `.deb` num runner Linux e publica os três
arquivos na versão. Rodado à mão (workflow_dispatch), só compila e guarda os artefatos.

## Segurança

- Senhas RDP e a senha do Linux ficam no Keychain do Mac. Elas chegam ao FreeRDP e ao host por pipe,
  nunca em argumentos, arquivos ou logs.
- A conexão RDP exige NLA e o certificado fixado na criação do ambiente.
- Valores de variáveis de ambiente de containers cujo nome parece segredo não saem do host.
- "Liberar diálogos de administrador" instala uma regra polkit que dá esse poder a qualquer programa
  rodando como o seu usuário no host. É opcional e reversível.
