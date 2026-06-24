#!/bin/bash

# Faz add, commit e push para o GitHub automaticamente.
#
# Uso:
#   ./push.sh "mensagem do commit"
#   ./push.sh                    # pede a mensagem interativamente
#
# Exemplo:
#   ./push.sh "feat: adiciona endpoint de alertas"

set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GIT="git -c safe.directory=$ROOT_DIR -C $ROOT_DIR"
BRANCH="$($GIT branch --show-current)"
REMOTE="${GIT_REMOTE:-origin}"

log() {
  printf '[push] %s\n' "$*"
}

error() {
  printf '[push] ERRO: %s\n' "$*" >&2
  exit 1
}

read_commit_message() {
  local message=""

  if [ -n "${1:-}" ]; then
    printf '%s' "$1"
    return 0
  fi

  printf 'Mensagem do commit: '
  read -r message

  if [ -z "$message" ]; then
    error "Mensagem do commit é obrigatória."
  fi

  printf '%s' "$message"
}

main() {
  local message

  log "Repositório: $ROOT_DIR"
  log "Branch: $BRANCH"
  log "Remote: $REMOTE"
  echo

  if ! $GIT rev-parse --git-dir >/dev/null 2>&1; then
    error "Esta pasta não é um repositório Git."
  fi

  message="$(read_commit_message "${1:-}")"

  echo
  log "Status atual:"
  $GIT status --short
  echo

  if $GIT diff --quiet && $GIT diff --cached --quiet && [ -z "$($GIT status --porcelain)" ]; then
    log "Nada para commitar."

    if $GIT rev-parse "@{u}" >/dev/null 2>&1; then
      local ahead
      ahead="$($GIT rev-list --count "@{u}..HEAD" 2>/dev/null || echo 0)"
      if [ "$ahead" -gt 0 ]; then
        log "Enviando $ahead commit(s) pendente(s)..."
        $GIT push "$REMOTE" "$BRANCH"
        log "Push concluído: $REMOTE/$BRANCH"
      else
        log "Repositório já está sincronizado."
      fi
    else
      log "Sem upstream configurado. Nada a fazer."
    fi
    return 0
  fi

  log "Adicionando arquivos..."
  $GIT add -A

  log "Criando commit..."
  $GIT commit -m "$message"

  log "Enviando para $REMOTE/$BRANCH..."
  $GIT push "$REMOTE" "$BRANCH"

  echo
  log "Concluído."
  $GIT log -1 --oneline
}

main "$@"
