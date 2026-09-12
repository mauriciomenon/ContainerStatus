# ContainerStatus

App nativo macOS (AppKit, Swift puro, sem dependencias) que vive na menu bar e
controla o servico Apple `container` (github.com/apple/container).

## O que faz

- Ponto **verde** na menu bar: servico ligado. **Vermelho**: desligado.
- **Cinza vazado**: CLI `container` indisponivel (nao instalada ou travada).
- Clique abre um menu com a chave liga/desliga do servico, indicador de
  "Abrir no login" (SMAppService, sem permissoes extras) e "Sair".
- Deteccao por polling da CLI oficial `container system status` (codigo de
  saida) a cada 3s, com watchdog de 2s. Start/stop tem watchdog de 10s e o
  app nunca bloqueia a main thread.
- Durante o toggle o dot fica esmaecido e o poll nao sobrescreve o estado
  (sem piscar vermelho no meio da transicao).

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
