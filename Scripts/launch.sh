#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME=${APP_NAME:-ContainerStatus}
APP_PATH="$PROJECT_ROOT/${APP_NAME}.app"

# Confere o bundle antes de encerrar: sem ele a instancia em uso fica de pe.
if [[ ! -d "$APP_PATH" ]]; then
    echo "ERROR: ${APP_NAME}.app not found at $APP_PATH"
    echo "Run ./Scripts/package_app.sh first to build the app"
    exit 1
fi
# Diretorio existir nao basta: bundle incompleto ou com assinatura quebrada
# nao abre, e a instancia em uso ja teria sido encerrada.
if ! codesign --verify --strict "$APP_PATH" 2>/dev/null; then
    echo "ERROR: ${APP_NAME}.app at $APP_PATH is incomplete or has an invalid signature"
    exit 1
fi

echo "==> Killing existing ${APP_NAME} instances"
# -x compara o nome exato; -f "<nome>.app" casava qualquer linha de comando
# que citasse o caminho (editor, tail de log).
pkill -x "$APP_NAME" || true
sleep 0.5

echo "==> Launching ${APP_NAME} from $APP_PATH"
open -n "$APP_PATH"

sleep 1
if pgrep -x "$APP_NAME" > /dev/null; then
    echo "OK: ${APP_NAME} is running."
else
    echo "ERROR: App exited immediately. Check crash logs in Console.app (User Reports)."
    exit 1
fi
