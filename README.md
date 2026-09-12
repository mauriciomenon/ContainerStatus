# ContainerStatus

App nativo macOS (AppKit, Swift puro, sem dependencias) que vive na menu bar e
controla o servico Apple `container` (github.com/apple/container).

## O que faz

- Ponto **verde** na menu bar: servico ligado. **Vermelho**: desligado.
- **Cinza vazado**: CLI `container` indisponivel (nao instalada ou travada).
- Clique abre o menu:
  - `Apple Container x.y.z` (versao da CLI)
  - `Status: Ligado` / `Status: Desligado` / `Status: Não instalado`
  - `Ligar daemon` / `Desligar daemon`; sem a CLI, vira o link
    `github.com/apple/container`
  - `Abrir no login` (SMAppService, sem permissoes extras)
  - `Sair` com um `link` discreto para o projeto no canto oposto
- Deteccao por polling da CLI oficial `container system status` (codigo de
  saida) a cada 3s, com watchdog de 2s. Start/stop tem watchdog de 10s e o
  app nunca bloqueia a main thread.
- Durante o toggle o dot fica esmaecido e o poll nao sobrescreve o estado
  (sem piscar vermelho no meio da transicao).

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

**O que o app executa** (vocabulario fechado, resolvido uma vez no boot
em `/usr/local/bin/container`, `/opt/homebrew/bin/container` ou PATH):

| Comando | Quando | Watchdog |
|---|---|---|
| `container system status` | poll a cada 3s e ao abrir o menu | 2s |
| `container system start` | acao "Ligar daemon" | 10s |
| `container system start --disable-kernel-install` | so se o start puro falhar/travar | 10s |
| `container system stop` | acao "Desligar daemon" | 10s |
| `container --version` | uma vez, para o cabecalho do menu | 2s |

**Garantias:**

- Nenhum comando passa por shell: os argumentos sao passados direto pela
  API `Process`, sem interpolacao (nao existe superficie de injecao).
- Ambiente minimo e fixo (`PATH` e `HOME`); o app nao herda o ambiente de
  quem o lancou, então o comportamento e o mesmo no Terminal, no Finder e
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
- Swift 6 via Command Line Tools (nao precisa de Xcode)
- CLI `container` instalada (procurada em `/usr/local/bin/container`,
  `/opt/homebrew/bin/container` e PATH)

## Build e execucao

```bash
swift build                              # build de desenvolvimento
.build/debug/ContainerStatus --selftest  # self-test do nucleo (13 checagens)
Scripts/compile_and_run.sh               # empacota ContainerStatus.app e abre
```

O script `Scripts/package_app.sh` monta o bundle `.app` (Info.plist com
`LSUIElement=true`, sem icone de Dock) e assina ad-hoc. Para abrir no login,
use o proprio menu do app.

## Estrutura

```
Sources/ContainerStatus/
  AppMain.swift              bootstrap NSApplication (accessory) + --selftest
  ServiceState.swift         enum de estado + mapeamento de codigo de saida
  ContainerCLI.swift         wrapper da CLI com watchdog e ambiente explicito
  SelfTest.swift             checagens do nucleo (roda com --selftest)
  StatusItemController.swift NSStatusItem, menu, maquina de estados, polling
Scripts/                     empacotamento .app sem Xcode
docs/superpowers/specs/      documento de design (council validado)
```

## Design

A decisao de arquitetura (AppKit puro, CLI como fonte de verdade, timeouts,
maquina de estados, estado "indisponivel" distinto) foi validada por um
council de quatro vozes; detalhes em
`docs/superpowers/specs/2026-09-12-container-status-macos-app-design.md`.
