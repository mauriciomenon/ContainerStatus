# Changelog

Formato: [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/).

## [Unreleased]

### Alterado
- Docker, Lume e Lima viram linhas com submenu: deteccao, acoes e
  informacao (contexto, instancias do Lima) ficam dentro do submenu, nao
  mais espalhadas no menu principal.
- Rodape em linhas proprias: Refresh (antes o botao do cabecalho), About
  e Quit na ultima linha. About virou submenu com o painel do app e os
  links do GitHub de Apple Container, OrbStack, Lima e Lume (o item GitHub
  saiu do bloco Apple).

## [1.1.1] - 2026-10-16

### Corrigido
- O ponto da barra nascia depois do relogio, quase invisivel ("o app nao
  abre"): status item com nome de posicao estavel.
- Reabrir o app ja em execucao nao mostrava nada; agora abre o menu.
- Menu mais estreito: ~190pt em vez de 260pt fixos.

### Adicionado
- Lima (limactl) detectado, com as instancias no tooltip.
- `--dump-menu`: imprime o menu real e sua largura apos um poll.

### Alterado
- Checagem a cada 15s com o menu fechado e 3s com ele aberto (~5x menos
  processos curtos).
- Lima: prazo proprio de 10s e um so `limactl` por ciclo, inclusive quando a
  consulta estoura o prazo.

### Seguranca
- vmnet: cada `vmnet-cli` roda como root com ambiente zerado (o HOME do
  usuario fazia o binario ler config gravavel por ele); requisito de
  assinatura designado completo da VMware; daemons contados so do root.
- Timeout de CLI encerra a arvore de descendentes (neto preso sobrevivia).
- Binario confiavel exige dono root ou o proprio usuario.
- Aviso de release: URL montada pelo app, tag com teto, sessao sem cache.
- Testes e `--dump-menu` nao gravam mais o ponto como oculto.

## [1.1.0] - 2026-10-16

### Adicionado
- Aviso "Update available: x.y.z" quando sai release nova do apple/container
  (API do GitHub no arranque, a cada 6h e no rescan; unica conexao de rede).
- Aviso "(running x.y.z, restart to update)" quando o servico de pe roda
  versao anterior a CLI instalada.
- Docker Desktop, Rancher Desktop e Finch passam a ser detectados.
- Acao Enable/Disable Daemon do Podman no menu.
- `--probe-runtimes` mostra a release do GitHub e o veredito de elevacao do vmnet.

### Corrigido
- Enable Daemon do vmnet: o AppleScript gerado nao compilava.
- Lume: `brew services` recebia o label do launchd; o estado agora e o do
  servidor `lume serve`, nao das VMs.
- Upgrade da CLI nao detectado quando o primeiro `--version` falhava.
- Podman aparecia ligado com qualquer maquina existente, ate parada.
- Comandos longos podiam morrer no watchdog com stderr acima de 64KB.
- Menu travava: o apply rodava `docker context show`/`ps -q` na main thread.
- Polls se acumulavam sem limite com sondas travadas.
- Erro de login persistia apos um registro bem-sucedido.
- Clique de toggle podia inverter a acao exibida.
- Tooltip dizia "CLI not found" com a CLI instalada mas sem responder.
- Podman passa a seguir a maquina padrao, a mesma que Enable/Disable controla.
- Rescan com uma checagem em andamento era descartado; agora roda em seguida.
- Leitura de saida dos comandos cancelavel: processo neto segurando o pipe
  nao prende mais threads; saida limitada a 1MB.
- Falha transitoria de `system version` nao desliga mais o aviso de servico.
- Empacotamento so substitui o bundle depois de assinar com sucesso.

### Seguranca
- CLI em `~/.local/bin` ou no PATH so e usada sem instalacao no sistema;
  binario gravavel por grupo/outros e ignorado.
- vmnet-cli so e elevado a root se o arquivo e o caminho forem do root, e o
  shell elevado confere a assinatura da VMware antes de executar.
- Sondas de runtime tambem ignoram binario gravavel por grupo/outros.
- Ids de container sem caracteres de controle no menu.
- Watchdog confere se o filho vive antes do SIGKILL e nao espera sem prazo.

### Removido
- Codigo morto do app e restos de template do `package_app.sh`.
