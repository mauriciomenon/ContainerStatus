# ContainerStatus

App nativo macOS (AppKit, Swift puro, sem dependencias) que vive na menu bar e
controla o servico Apple `container` (github.com/apple/container).

## O que faz

- Ponto **verde** na menu bar: servico ligado. **Vermelho**: desligado.
  **Cinza vazado**: CLI `container` indisponivel (nao instalada ou travada).
  Durante um toggle o dot fica esmaecido e o poll nao sobrescreve o estado
  (sem piscar no meio da transicao).
- Clique abre o menu, nesta ordem:

```
Apple Container x.y.z            versao da CLI em uso
/usr/local/bin/container         caminho resolvido; "destino via symlink"
                                 quando a instalacao e um link (ex.: brew)
─────────────────────────────
Status: Ligado / Desligado / Não instalado
Ligar daemon / Desligar daemon   sem a CLI, vira o link do projeto
[linha de erro, quando existe]   falha de operacao ou diagnostico do poll
Abrir no login                   (SMAppService, sem permissoes extras)
─────────────────────────────
Sobre Apple Container            abre github.com/apple/container
Sobre ContainerStatus x.y.z      painel Sobre do app
Sair
```

- A linha de erro de um toggle que falhou permanece visivel (nao e apagada
  pelo poll seguinte nem ao reabrir o menu); ela sai quando a operacao
  seguinte tem exito ou quando um poll traz um diagnostico proprio.
- **Sobre ContainerStatus**: painel centralizado com autor, commit-base do
  build, link do repositorio, data de build ISO e GPL 2.0 na ultima linha.
- Deteccao por polling da CLI oficial `container system status` (codigo de
  saida) a cada 3s, com watchdog de 2s. Start tem watchdog de 10s e stop de
  40s, permitindo a parada dos containers antes de remover o servico.
  O app nunca bloqueia a main thread.

## Politica de execucao e privilegios

O app roda como o usuario logado, sem root, sem senha e sem pedido de
autorizacao em momento algum. Nao possui helper privilegiado, daemon
proprio, setuid ou entitlements especiais.

**De onde vem o direito de startar/parar o daemon:** o servico Apple
container nao e um daemon de sistema. Ele vive no dominio launchd do
proprio usuario (`gui/<uid>`), nos labels `com.apple.container.*`
(apiserver, machine-apiserver, core-images, vmnet). Servicos desse dominio
pertencem a sessao do usuario, e o dono da sessao pode inicia-los e
interrompe-los sem elevacao. O app nunca fala com o launchd nem toca nos
processos do servico: ele apenas executa a CLI oficial `container`
(instalada em `/usr/local/bin`, `root:wheel`, executavel por qualquer
usuario), que faz o bootstrap/bootout no launchd do usuario. Qualquer
trabalho que exija privilegio (por exemplo, rede via vmnet) e resolvido
pelos proprios binarios Apple, que carregam os entitlements necessarios;
o app nao os reproduz nem interpoe.

**O que o app executa** (vocabulario fechado; o binario e re-localizado a
cada checagem enquanto nao for encontrado, sem restart):

| Comando | Quando | Watchdog |
|---|---|---|
| `container system status` | poll a cada 3s e ao abrir o menu | 2s |
| `container system start` | acao "Ligar daemon" | 10s |
| `container system start --disable-kernel-install` | so se o start puro falhar/travar | 10s |
| `container system stop` | acao "Desligar daemon" | 40s |
| `container --version` | descoberta ou alteracao de uma instalacao | 2s |

### Onde ele procura a CLI (independente de maquina)

O app nao depende de nenhum caminho desta ou daquela maquina. A cada
checagem em que a CLI ainda nao foi encontrada, ele re-escaneia, nesta
ordem, sem repetir diretorios:

1. `/usr/local/bin` - instalador .pkg oficial e `make install` padrao
2. `/opt/homebrew/bin` e `/opt/homebrew/sbin` - Homebrew (Apple Silicon)
3. `/usr/local/sbin`, `~/.local/bin`, `/opt/sbin`, `/usr/bin`, `/bin`
4. todos os diretorios do `PATH` do ambiente de lancamento (builds de
   codigo-fonte com prefixo customizado entram aqui)

Cobertura por metodo de instalacao: **.pkg do site** (instala em
`/usr/local/bin`), **brew** (`/opt/homebrew/bin` no Apple Silicon,
`/usr/local/bin` no Intel) e **build manual** (qualquer prefixo, contanto
que o binario `container` esteja em um dos diretorios acima ou no PATH do
usuario). Enquanto a CLI nao existe, o app mostra "Status: Nao instalado"
com o link do projeto; assim que ela aparece em qualquer um desses
lugares, o proximo poll (ate 3s) detecta e o menu passa a oferecer
ligar/desligar - sem reiniciar o app.

Quando existe **mais de uma copia** (por exemplo, .pkg antigo + brew
novo), o app compara as versoes (`container --version`) e usa sempre a
mais nova; a comparacao so roda quando as copias ou seus metadados mudam.
Cada poll verifica caminhos e metadados, incluindo o destino de symlinks;
nao executa consultas de versao se nada mudou. Versao do cabecalho
acompanha o binario em uso, inclusive em upgrades no mesmo caminho, a
partir do proximo poll. **Evite manter duas copias para sempre**: os launchd labels sao os
mesmos (`com.apple.container.*`), entao o ideal ao migrar de metodo e
parar o servico, remover a copia antiga e iniciar pela nova (uma unica
instalacao e o estado suportado).

O bundle `ContainerStatus.app` em si pode ficar em qualquer pasta
(`/Applications` e o recomendado, principalmente para o "Abrir no login");
a descoberta da CLI nao depende de onde o app esta instalado.

**Garantias:**

- Nenhum comando passa por shell: os argumentos sao passados direto pela
  API `Process`, sem interpolacao (nao existe superficie de injecao).
- Ambiente minimo e fixo (`PATH` e `HOME`); o app nao herda o ambiente de
  quem o lancou, entao o comportamento e o mesmo no Terminal, no Finder e
  no login.
- O watchdog mata somente o processo filho (a CLI), nunca o daemon. Se a
  CLI travar, o servico continua sob o launchd e o app marca "indisponivel"
  ate a proxima checagem.
- O stop e graceful pela CLI via launchd (encerra containers, espera a
  saida, para os servicos); o app apenas dispara e observa o codigo de
  saida.
- Nenhuma escrita em `/Library` ou `/System`; o app nao instala LaunchDaemon.
  "Abrir no login" usa `SMAppService` (LaunchAgent do usuario, reversivel
  no proprio menu ou nos Ajustes do Sistema).
- Um toggle por vez: a maquina de estados (idle/starting/stopping)
  desabilita a acao durante a transicao e o poll periodico nao sobrescreve
  o estado em curso.

## Requisitos

- macOS 13+ (testado no 27.0, Apple Silicon)
- Swift 6.2+ via Command Line Tools (nao precisa de Xcode)
- CLI `container` instalada (procurada em `/usr/local/bin/container`,
  `/opt/homebrew/bin/container` e PATH)

## Build e execucao

```bash
swift build                              # build de desenvolvimento
.build/debug/ContainerStatus --selftest  # autoteste do nucleo e regressoes
.build/debug/ContainerStatus --selftest-ui # inclui os testes de menu AppKit
Scripts/compile_and_run.sh               # empacota ContainerStatus.app e abre
Scripts/compile_and_run.sh --test        # valida antes de empacotar e abrir
Scripts/make_icon.sh                     # regenera Icon.icns de 16 a 1024 pixels
Scripts/validate_assets.sh               # confere tamanhos e transparencia do ICNS
Scripts/validate_assets.sh ContainerStatus.app # confere tambem bundle e assinatura
```

O script `Scripts/package_app.sh` monta o bundle `.app` (Info.plist com
`LSUIElement=true`, sem icone de Dock) e assina ad-hoc. Para abrir no login,
use o proprio menu do app.

O ICNS contem todas as 10 representacoes do
[conjunto padrao da Apple](https://developer.apple.com/library/archive/documentation/Xcode/Reference/xcode_ref-Asset_Catalog_Format/IconSetType.html).
A maior e 1024x1024 pixels (512 pontos em escala 2x). A geracao usa
dimensoes explicitas de bitmap e independe da escala da tela.

| Tamanho em pontos | Pixels 1x | Pixels 2x |
|---|---|---|
| 16 | 16x16 | 32x32 |
| 32 | 32x32 | 64x64 |
| 128 | 128x128 | 256x256 |
| 256 | 256x256 | 512x512 |
| 512 | 512x512 | 1024x1024 |

## Testes focados

`--selftest` executa 38 checagens do nucleo: estados, watchdog, parada
lenta, descoberta da CLI, cache e concorrencia durante upgrades.
`--selftest-ui` inclui mais 8 checagens do menu: insercao, atualizacao e
remocao da linha de erro, retencao de erro local de toggle apos polls
saudaveis e substituicao por diagnostico do polling. Exige uma sessao
grafica do macOS; nao abre o menu nem altera o daemon ou o login.
Os dois modos encerram o processo com codigo diferente de zero se falharem.

`validate_assets.sh` verifica as 10 imagens internas do ICNS, dimensoes,
canal alfa, cantos transparentes e centro opaco. Com um bundle, tambem
verifica nome do produto, identificador do bundle (sem placeholder de
template), macOS minimo, modo menu bar, ausencia intencional de
`CFBundleVersion`, icone copiado e assinatura de todas as arquiteturas.

## CI e entrega de builds

A [CI principal](https://github.com/mauriciomenon/ContainerStatus/actions/workflows/ci.yml)
roda em pushes para `master`, pull requests e por acionamento manual.
Usa runners nativos `macos-15` (ARM64) e `macos-15-intel` (x86_64), com
Xcode 26.2 / Swift 6.2. Cada um compila, executa `--selftest-ui`, regenera
o icone e valida o bundle. ShellCheck, actionlint e Gitleaks rodam uma vez.
Veja os [runners oficiais](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).

Em `master`, cada arquitetura disponibiliza um ZIP do app validado por
7 dias na pagina da execucao. A assinatura e ad-hoc; estes artefatos nao
sao releases notarizados. Pull requests apenas validam. O workflow tem
permissao de leitura, actions fixadas por SHA, sem cache compartilhado e
sem senhas, PATs ou variaveis de credenciais configuradas. Checkout e
upload usam somente a autenticacao temporaria gerenciada pelo GitHub.

Os remotes `schottge` e `gitlab` permanecem espelhos da CI principal,
evitando execucoes duplicadas. Nao ha pipeline macOS do GitLab pendente
de runner: os [runners macOS hospedados](https://docs.gitlab.com/ci/runners/hosted_runners/macos/)
exigem elegibilidade especifica e nao cobrem Intel.

Se os jobs falharem antes da primeira etapa com bloqueio de cobranca da
conta, confira os avisos em **Settings > Billing and licensing** e siga a
[orientacao para desbloqueio](https://docs.github.com/en/billing/how-tos/troubleshooting/locked-account).
Se nao houver pendencia visivel, consulte o suporte do GitHub; nao e uma
falha corrigivel no workflow. Apos liberar a conta, use **Re-run all jobs**
na execucao afetada ou acione o workflow em `master`. Confirme sucesso nos
dois jobs e a presenca dos dois ZIPs antes de considerar a CI validada.

## Validacao visual e acessos externos

- **Menu:** os testes AppKit verificam o comportamento, mas nao substituem
  a inspecao visual. Se a ferramenta de captura expirar, registre o timeout
  como falha de captura. Para validar manualmente, abra o menu e use
  `Cmd+Shift+4` para selecionar sua area; confira alinhamento, texto e escala
  da tela. O timeout sozinho nao comprova falta de permissao do macOS.
- **Intel:** compilacao universal so prova a presenca das duas arquiteturas.
  A execucao nativa e comprovada pelo job `macos-15-intel` concluido com
  sucesso para o mesmo commit. Os testes usam uma CLI simulada; nao validam
  virtualizacao ou containers reais em Intel.
- **GitLab:** push via SSH nao autentica a API de statuses externos.
  Para consulta local, use uma versao atual do `glab`, com suporte a
  `--device` e armazenamento no Chaves do macOS, e autorize sua conta:

  ```bash
  glab auth login --hostname gitlab.com --device --git-protocol ssh
  glab auth status --hostname gitlab.com
  glab api --hostname gitlab.com 'projects/mauricio.menon%2Fcontainerstatus/repository/commits/master/statuses'
  ```

  Faca isso no Terminal local com o Chaves disponivel e desbloqueado,
  nunca na CI ou com `--insecure-storage`. Se o `glab` indicar armazenamento
  em texto puro, interrompa e resolva o acesso ao Chaves antes de continuar.
  Nao copie tokens para arquivos, comandos ou variaveis. A
  [documentacao de autenticacao](https://docs.gitlab.com/cli/auth/login/)
  explica o fluxo. Sem essa autorizacao, a consulta fica **nao verificada**;
  isso nao bloqueia a CI principal no GitHub.
- **Arquivos internos:** `.gitignore` inclui `docs/` e `agents.md` para
  manter documentacao interna fora dos commits. Antes de publicar, confira
  `git status --short` e `git diff --cached --name-only`.

## Estrutura

```
Sources/ContainerStatus/
  AppMain.swift              bootstrap NSApplication (accessory) e autotestes
  ServiceState.swift         enum de estado + mapeamento de codigo de saida
  ContainerCLI.swift         wrapper da CLI com watchdog e ambiente explicito
  SelfTest.swift             checagens do nucleo e entrada dos testes de menu
  StatusItemController.swift NSStatusItem, menu, maquina de estados, polling
Scripts/                     icone, validacao e empacotamento .app sem Xcode
.github/workflows/ci.yml     validacao ARM64/Intel e artefatos de master
```

## Design

AppKit puro, CLI como fonte de verdade e uma maquina de estados pequena.
Timeouts limitam subprocessos; o estado "indisponivel" distingue falhas da
CLI de um servico parado.
