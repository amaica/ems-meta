#!/usr/bin/env bash

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

CONTAINER_CMD=""

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

resolve_container_cmd() {
  local candidate

  if [ -n "${CONTAINER_CMD_OVERRIDE:-}" ]; then
    CONTAINER_CMD="$CONTAINER_CMD_OVERRIDE"
    return 0
  fi

  for candidate in podman docker /usr/bin/podman /usr/bin/docker; do
    if command -v "$candidate" >/dev/null 2>&1; then
      CONTAINER_CMD="$(command -v "$candidate")"
      return 0
    fi
    if [ -x "$candidate" ]; then
      CONTAINER_CMD="$candidate"
      return 0
    fi
  done

  return 1
}

port_in_use() {
  local port="$1"
  ss -tln 2>/dev/null | grep -q ":${port} "
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
  local pids

  pids="$(ss -tlnp 2>/dev/null | grep ":${port} " | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u || true)"
  if [ -z "$pids" ]; then
    return 0
  fi

  while read -r pid; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done <<< "$pids"

  sleep 1

  pids="$(ss -tlnp 2>/dev/null | grep ":${port} " | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u || true)"
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
    error "Podman/Docker não encontrado no PATH."
    error "Instale o Podman, adicione /usr/bin ao PATH ou defina CONTAINER_CMD_OVERRIDE=/usr/bin/podman"
    return 1
  fi

  log "Usando runtime de container: $CONTAINER_CMD"

  if "$CONTAINER_CMD" container exists "$RABBITMQ_CONTAINER" >/dev/null 2>&1; then
    log "Iniciando container $RABBITMQ_CONTAINER..."
    "$CONTAINER_CMD" start "$RABBITMQ_CONTAINER" >/dev/null
  else
    log "Criando container $RABBITMQ_CONTAINER..."
    "$CONTAINER_CMD" run -d \
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
  if resolve_container_cmd && "$CONTAINER_CMD" container exists "$RABBITMQ_CONTAINER" >/dev/null 2>&1; then
    log "Parando container $RABBITMQ_CONTAINER..."
    "$CONTAINER_CMD" stop "$RABBITMQ_CONTAINER" >/dev/null || true
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

  log "Iniciando $name na porta $port..."
  (
    cd "$service_dir"
    export SPRING_RABBITMQ_HOST="${SPRING_RABBITMQ_HOST:-localhost}"
    export SPRING_RABBITMQ_PORT="${RABBITMQ_AMQP_PORT}"
    export SPRING_RABBITMQ_USERNAME="${RABBITMQ_USER}"
    export SPRING_RABBITMQ_PASSWORD="${RABBITMQ_PASS}"
    nohup ./gradlew bootRun >>"$log_file" 2>&1 &
    echo $! >"$pid_file"
  )

  if ! wait_for_port "$port" 90; then
    error "$name não subiu na porta $port. Veja: $log_file"
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
    fi
    rm -f "$pid_file"
  fi

  if port_in_use "$port"; then
    log "Liberando porta $port de $name..."
    kill_port "$port"
  fi
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
  start     Inicia RabbitMQ e os 3 microserviços
  stop      Para tudo
  restart   Reinicia tudo
  status    Mostra o status das portas
  logs      Acompanha os logs dos serviços
  demo      Executa demonstração E2E do fluxo completo

Variáveis opcionais:
  RABBITMQ_AMQP_PORT   (padrão: 5673)
  RABBITMQ_MGMT_PORT   (padrão: 15673)
  RABBITMQ_USER        (padrão: rabbitmq)
  RABBITMQ_PASS        (padrão: rabbitmq)
  CONTAINER_CMD_OVERRIDE  (ex.: /usr/bin/podman)
EOF
}

main() {
  local cmd="${1:-}"

  case "$cmd" in
    start) cmd_start ;;
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
