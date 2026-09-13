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
  saida) a cada 3s, com watchdog de 2s. Start tem watchdog de 10s e stop de
  40s, permitindo a parada dos containers antes de remover o servico.
  O app nunca bloqueia a main thread.
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
.build/debug/ContainerStatus --selftest  # autoteste do nucleo e regressoes
Scripts/compile_and_run.sh               # empacota ContainerStatus.app e abre
Scripts/compile_and_run.sh --test        # valida antes de empacotar e abrir
Scripts/make_icon.sh                     # regenera Icon.icns de 16 a 1024 pixels
```

O script `Scripts/package_app.sh` monta o bundle `.app` (Info.plist com
`LSUIElement=true`, sem icone de Dock) e assina ad-hoc. Para abrir no login,
use o proprio menu do app.

O icone preserva as representacoes padrao do macOS, incluindo 512x512
pontos em escala 2x (1024x1024 pixels). A geracao usa dimensoes explicitas
de bitmap e independe da escala da tela.

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
