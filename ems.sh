#!/bin/bash

# Sobe e para o ambiente local do ems-meta (RabbitMQ + 3 microserviços).
#
# Uso:
#   ./ems.sh start    # inicia tudo
#   ./ems.sh stop     # para tudo
#   ./ems.sh restart  # reinicia tudo
#   ./ems.sh status   # mostra o que está rodando
#   ./ems.sh logs     # acompanha os logs (Ctrl+C para sair)
#
# RabbitMQ usa Podman nas portas 5673 (AMQP) e 15673 (management),
# para não conflitar com outros RabbitMQ já rodando na 5672.

set -uo pipefail

# Shells mínimos (ex.: terminal do IntelliJ) podem não incluir /usr/bin no PATH.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="$ROOT_DIR/.run"
LOG_DIR="$RUN_DIR/logs"
PID_DIR="$RUN_DIR/pids"

RABBITMQ_CONTAINER="ems-rabbitmq"
RABBITMQ_IMAGE="docker.io/rabbitmq:3-management"
RABBITMQ_AMQP_PORT="${RABBITMQ_AMQP_PORT:-5673}"
RABBITMQ_MGMT_PORT="${RABBITMQ_MGMT_PORT:-15673}"
RABBITMQ_USER="${RABBITMQ_USER:-rabbitmq}"
RABBITMQ_PASS="${RABBITMQ_PASS:-rabbitmq}"

CONTAINER_BIN=""
CONTAINER_VIA_FLATPAK=false
FLATPAK_SPAWN=""

SERVICES=(
  "device-management:8080:services/device-management"
  "temperatura-processing:8081:services/temperatura-processing"
  "temperatura-monitoring:8082:services/temperatura-monitoring"
)

log() {
  printf '[ems] %s\n' "$*"
}

error() {
  printf '[ems] ERRO: %s\n' "$*" >&2
}

ensure_dirs() {
  mkdir -p "$LOG_DIR" "$PID_DIR"
}

load_shell_profile() {
  local profile

  for profile in "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.bashrc"; do
    if [ -f "$profile" ]; then
      # shellcheck disable=SC1090
      . "$profile" 2>/dev/null || true
    fi
  done
}

is_flatpak_sandbox() {
  [ -n "${FLATPAK_ID:-}" ] || [ -f /.flatpak-info ]
}

find_flatpak_spawn() {
  local candidate

  for candidate in /usr/sbin/flatpak-spawn /usr/bin/flatpak-spawn flatpak-spawn; do
    if command -v "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$(command -v "$candidate")"
      return 0
    fi
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

try_flatpak_host_container() {
  local runtime="${1:-podman}"
  local spawn

  spawn="$(find_flatpak_spawn)" || return 1

  if ! "$spawn" --host "$runtime" --version >/dev/null 2>&1; then
    return 1
  fi

  FLATPAK_SPAWN="$spawn"
  CONTAINER_BIN="$runtime"
  CONTAINER_VIA_FLATPAK=true
  return 0
}

run_container() {
  if [ "$CONTAINER_VIA_FLATPAK" = true ]; then
    "$FLATPAK_SPAWN" --host "$CONTAINER_BIN" "$@"
  else
    "$CONTAINER_BIN" "$@"
  fi
}

container_runtime_label() {
  if [ "$CONTAINER_VIA_FLATPAK" = true ]; then
    printf 'flatpak-spawn --host %s' "$CONTAINER_BIN"
  else
    printf '%s' "$CONTAINER_BIN"
  fi
}

resolve_container_cmd() {
  local candidate

  CONTAINER_BIN=""
  CONTAINER_VIA_FLATPAK=false
  FLATPAK_SPAWN=""

  if [ -n "${CONTAINER_CMD_OVERRIDE:-}" ]; then
    if [ -x "$CONTAINER_CMD_OVERRIDE" ]; then
      CONTAINER_BIN="$CONTAINER_CMD_OVERRIDE"
      return 0
    fi
    if is_flatpak_sandbox && try_flatpak_host_container "$(basename "$CONTAINER_CMD_OVERRIDE")"; then
      return 0
    fi
    error "CONTAINER_CMD_OVERRIDE definido mas não executável: $CONTAINER_CMD_OVERRIDE"
    return 1
  fi

  for candidate in podman docker \
      /usr/bin/podman /usr/bin/docker \
      /usr/local/bin/podman /usr/local/bin/docker \
      /snap/bin/podman; do
    if command -v "$candidate" >/dev/null 2>&1; then
      CONTAINER_BIN="$(command -v "$candidate")"
      return 0
    fi
    if [ -x "$candidate" ]; then
      CONTAINER_BIN="$candidate"
      return 0
    fi
  done

  if is_flatpak_sandbox; then
    try_flatpak_host_container podman && return 0
    try_flatpak_host_container docker && return 0
  fi

  return 1
}

run_on_host() {
  local spawn
  spawn="$(find_flatpak_spawn)"
  "$spawn" --host bash -lc "$1"
}

uses_host_java() {
  if is_flatpak_sandbox && ! command -v java >/dev/null 2>&1; then
    find_flatpak_spawn >/dev/null 2>&1 && \
      "$(find_flatpak_spawn)" --host java -version >/dev/null 2>&1
    return $?
  fi
  return 1
}

resolve_java_home() {
  if [ -n "${JAVA_HOME:-}" ] && [ ! -x "${JAVA_HOME}/bin/java" ]; then
    unset JAVA_HOME
  fi

  if [ -z "${JAVA_HOME:-}" ]; then
    local java_bin
    java_bin="$(command -v java 2>/dev/null || true)"
    if [ -n "$java_bin" ]; then
      JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$java_bin")")")"
      export JAVA_HOME
    fi
  fi
}

port_in_use() {
  local port="$1"

  if command -v ss >/dev/null 2>&1; then
    ss -tln 2>/dev/null | grep -q ":${port} " && return 0
  fi

  if command -v nc >/dev/null 2>&1; then
    nc -z localhost "$port" >/dev/null 2>&1 && return 0
  fi

  # Bash built-in — funciona no terminal Flatpak do IntelliJ (sem ss/nc)
  (echo >/dev/tcp/localhost/"$port") >/dev/null 2>&1 && return 0

  return 1
}

wait_for_port() {
  local port="$1"
  local retries="${2:-30}"
  local i

  for ((i = 1; i <= retries; i++)); do
    if port_in_use "$port"; then
      return 0
    fi
    sleep 1
  done

  return 1
}

kill_port() {
  local port="$1"
  local pids=""

  if command -v ss >/dev/null 2>&1; then
    pids="$(ss -tlnp 2>/dev/null | grep ":${port} " | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u || true)"
  elif command -v lsof >/dev/null 2>&1; then
    pids="$(lsof -ti tcp:"$port" 2>/dev/null || true)"
  fi

  if [ -z "$pids" ]; then
    return 0
  fi

  while read -r pid; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done <<< "$pids"

  sleep 1

  pids=""
  if command -v ss >/dev/null 2>&1; then
    pids="$(ss -tlnp 2>/dev/null | grep ":${port} " | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u || true)"
  elif command -v lsof >/dev/null 2>&1; then
    pids="$(lsof -ti tcp:"$port" 2>/dev/null || true)"
  fi

  if [ -n "$pids" ]; then
    while read -r pid; do
      [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null || true
    done <<< "$pids"
  fi
}

start_rabbitmq() {
  if port_in_use "$RABBITMQ_AMQP_PORT"; then
    log "RabbitMQ já está rodando na porta ${RABBITMQ_AMQP_PORT}"
    return 0
  fi

  if ! resolve_container_cmd; then
    load_shell_profile
  fi

  if ! resolve_container_cmd; then
    error "Podman/Docker não encontrado."
    error "PATH atual: ${PATH:-<vazio>}"
    if is_flatpak_sandbox; then
      error "IntelliJ via Flatpak: o sandbox não enxerga o Podman do sistema."
      error "Configure uma vez (fora do IntelliJ):"
      error "  flatpak override --user com.jetbrains.IntelliJ-IDEA-Community --talk-name=org.freedesktop.Flatpak"
      error "Depois rode ./ems.sh start no terminal do IntelliJ."
      error "Ou suba só os serviços: ./ems.sh start-services (com RabbitMQ já rodando fora do IDE)"
    else
      error "Tente: CONTAINER_CMD_OVERRIDE=/usr/bin/podman ./ems.sh start"
    fi
    return 1
  fi

  log "Usando runtime de container: $(container_runtime_label)"

  if run_container container exists "$RABBITMQ_CONTAINER" >/dev/null 2>&1; then
    log "Iniciando container $RABBITMQ_CONTAINER..."
    run_container start "$RABBITMQ_CONTAINER" >/dev/null
  else
    log "Criando container $RABBITMQ_CONTAINER..."
    run_container run -d \
      --name "$RABBITMQ_CONTAINER" \
      -p "${RABBITMQ_AMQP_PORT}:5672" \
      -p "${RABBITMQ_MGMT_PORT}:15672" \
      -e "RABBITMQ_DEFAULT_USER=${RABBITMQ_USER}" \
      -e "RABBITMQ_DEFAULT_PASS=${RABBITMQ_PASS}" \
      -v "${ROOT_DIR}/configs/rabbitmq/enabled_plugins:/etc/rabbitmq/enabled_plugins:ro,Z" \
      "$RABBITMQ_IMAGE" >/dev/null
  fi

  log "Aguardando RabbitMQ na porta ${RABBITMQ_AMQP_PORT}..."
  if ! wait_for_port "$RABBITMQ_AMQP_PORT" 45; then
    error "RabbitMQ não respondeu na porta ${RABBITMQ_AMQP_PORT}."
    return 1
  fi

  log "RabbitMQ pronto (AMQP: ${RABBITMQ_AMQP_PORT}, UI: http://localhost:${RABBITMQ_MGMT_PORT})"
}

stop_rabbitmq() {
  if resolve_container_cmd && run_container container exists "$RABBITMQ_CONTAINER" >/dev/null 2>&1; then
    log "Parando container $RABBITMQ_CONTAINER..."
    run_container stop "$RABBITMQ_CONTAINER" >/dev/null || true
  fi
}

start_service() {
  local name="$1"
  local port="$2"
  local dir="$3"
  local service_dir="$ROOT_DIR/$dir"
  local pid_file="$PID_DIR/${name}.pid"
  local log_file="$LOG_DIR/${name}.log"

  if port_in_use "$port"; then
    log "$name já está rodando na porta $port"
    return 0
  fi

  if [ ! -x "$service_dir/gradlew" ]; then
    chmod +x "$service_dir/gradlew"
  fi

  resolve_java_home

  log "Iniciando $name na porta $port..."
  if uses_host_java; then
    log "Usando Java do host (IntelliJ Flatpak)..."
    run_on_host "
      cd '$service_dir' || exit 1
      export SPRING_RABBITMQ_HOST='${SPRING_RABBITMQ_HOST:-localhost}'
      export SPRING_RABBITMQ_PORT='${RABBITMQ_AMQP_PORT}'
      export SPRING_RABBITMQ_USERNAME='${RABBITMQ_USER}'
      export SPRING_RABBITMQ_PASSWORD='${RABBITMQ_PASS}'
      unset JAVA_HOME
      if command -v java >/dev/null 2>&1; then
        export JAVA_HOME=\$(dirname \$(dirname \$(readlink -f \$(command -v java))))
      fi
      nohup ./gradlew bootRun >>'$log_file' 2>&1 &
      echo \$! >'$pid_file'
    " || return 1
  else
    (
      cd "$service_dir"
      export SPRING_RABBITMQ_HOST="${SPRING_RABBITMQ_HOST:-localhost}"
      export SPRING_RABBITMQ_PORT="${RABBITMQ_AMQP_PORT}"
      export SPRING_RABBITMQ_USERNAME="${RABBITMQ_USER}"
      export SPRING_RABBITMQ_PASSWORD="${RABBITMQ_PASS}"
      nohup ./gradlew bootRun >>"$log_file" 2>&1 &
      echo $! >"$pid_file"
    )
  fi

  if ! wait_for_port "$port" 120; then
    error "$name não subiu na porta $port. Veja: $log_file"
    if [ -f "$log_file" ]; then
      error "Últimas linhas do log:"
      tail -n 8 "$log_file" >&2 || true
    fi
    if grep -q 'JAVA_HOME is set to an invalid directory' "$log_file" 2>/dev/null; then
      error "JAVA_HOME inválido no terminal do IntelliJ (Flatpak)."
      error "Rode ./ems.sh restart neste terminal após atualizar o script."
    fi
    return 1
  fi

  log "$name pronto (http://localhost:$port)"
}

stop_service() {
  local name="$1"
  local port="$2"
  local pid_file="$PID_DIR/${name}.pid"

  if [ -f "$pid_file" ]; then
    local pid
    pid="$(cat "$pid_file")"
    if kill -0 "$pid" 2>/dev/null; then
      log "Parando $name (pid $pid)..."
      kill "$pid" 2>/dev/null || true
      sleep 2
      kill -9 "$pid" 2>/dev/null || true
    elif find_flatpak_spawn >/dev/null 2>&1; then
      log "Parando $name no host (pid $pid)..."
      run_on_host "kill '$pid' 2>/dev/null || kill -9 '$pid' 2>/dev/null || true" || true
    fi
    rm -f "$pid_file"
  fi

  if port_in_use "$port"; then
    log "Liberando porta $port de $name..."
    kill_port "$port"
  fi
}

cmd_start_services() {
  ensure_dirs

  if ! port_in_use "$RABBITMQ_AMQP_PORT"; then
    error "RabbitMQ não está rodando na porta ${RABBITMQ_AMQP_PORT}."
    error "Suba o RabbitMQ fora do IntelliJ: podman start ems-rabbitmq"
    error "Ou use ./ems.sh start num terminal normal do sistema."
    return 1
  fi

  local entry name port dir
  for entry in "${SERVICES[@]}"; do
    IFS=':' read -r name port dir <<< "$entry"
    start_service "$name" "$port" "$dir" || return 1
  done

  echo
  log "Microserviços iniciados (RabbitMQ já estava no ar)."
  cmd_status
}

cmd_start() {
  ensure_dirs

  start_rabbitmq || return 1

  local entry name port dir
  for entry in "${SERVICES[@]}"; do
    IFS=':' read -r name port dir <<< "$entry"
    start_service "$name" "$port" "$dir" || return 1
  done

  echo
  log "Ambiente iniciado."
  cmd_status
}

cmd_stop() {
  local entry name port dir
  for ((idx = ${#SERVICES[@]} - 1; idx >= 0; idx--)); do
    entry="${SERVICES[$idx]}"
    IFS=':' read -r name port dir <<< "$entry"
    stop_service "$name" "$port"
  done

  stop_rabbitmq
  log "Ambiente parado."
}

cmd_restart() {
  cmd_stop
  sleep 2
  cmd_start
}

cmd_status() {
  printf '\n%-26s %-8s %-8s\n' "COMPONENTE" "PORTA" "STATUS"
  printf '%-26s %-8s %-8s\n' "-------------------------" "--------" "--------"

  if port_in_use "$RABBITMQ_AMQP_PORT"; then
    printf '%-26s %-8s %-8s\n' "rabbitmq" "$RABBITMQ_AMQP_PORT" "UP"
  else
    printf '%-26s %-8s %-8s\n' "rabbitmq" "$RABBITMQ_AMQP_PORT" "DOWN"
  fi

  local entry name port dir
  for entry in "${SERVICES[@]}"; do
    IFS=':' read -r name port dir <<< "$entry"
    if port_in_use "$port"; then
      printf '%-26s %-8s %-8s\n' "$name" "$port" "UP"
    else
      printf '%-26s %-8s %-8s\n' "$name" "$port" "DOWN"
    fi
  done

  echo
  log "API principal: http://localhost:8080/api/sensors"
  log "RabbitMQ UI:   http://localhost:${RABBITMQ_MGMT_PORT} (${RABBITMQ_USER}/${RABBITMQ_PASS})"
  log "Logs em:       $LOG_DIR"
}

cmd_logs() {
  ensure_dirs
  touch "$LOG_DIR/device-management.log" "$LOG_DIR/temperatura-processing.log" "$LOG_DIR/temperatura-monitoring.log"
  tail -n 50 -F \
    "$LOG_DIR/device-management.log" \
    "$LOG_DIR/temperatura-processing.log" \
    "$LOG_DIR/temperatura-monitoring.log"
}

cmd_demo() {
  if [ ! -x "$ROOT_DIR/demo.sh" ]; then
    chmod +x "$ROOT_DIR/demo.sh"
  fi
  "$ROOT_DIR/demo.sh"
}

usage() {
  cat <<EOF
Uso: $(basename "$0") <comando>

Comandos:
  start            Inicia RabbitMQ e os 3 microserviços
  start-services   Inicia só os microserviços (RabbitMQ já deve estar rodando)
  stop             Para tudo
  restart          Reinicia tudo
  status           Mostra o status das portas
  logs             Acompanha os logs dos serviços
  demo             Executa demonstração E2E do fluxo completo

Variáveis opcionais:
  RABBITMQ_AMQP_PORT      (padrão: 5673)
  RABBITMQ_MGMT_PORT      (padrão: 15673)
  RABBITMQ_USER           (padrão: rabbitmq)
  RABBITMQ_PASS           (padrão: rabbitmq)
  CONTAINER_CMD_OVERRIDE  (ex.: podman — no Flatpak use só o nome, não o caminho)
EOF
}

main() {
  local cmd="${1:-}"

  case "$cmd" in
    start) cmd_start ;;
    start-services) cmd_start_services ;;
    stop) cmd_stop ;;
    restart) cmd_restart ;;
    status) cmd_status ;;
    logs) cmd_logs ;;
    demo) cmd_demo ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
