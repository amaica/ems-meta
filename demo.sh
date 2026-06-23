#!/usr/bin/env bash

# Demonstração do fluxo completo do EMS.
#
# Pré-requisito: ambiente rodando (./ems.sh start)
#
# Uso:
#   ./demo.sh

set -uo pipefail

DEVICE_MGMT="${DEVICE_MGMT:-http://localhost:8080}"
TEMP_PROC="${TEMP_PROC:-http://localhost:8081}"
TEMP_MON="${TEMP_MON:-http://localhost:8082}"

step() {
  printf '\n━━━ %s ━━━\n' "$*"
}

ok() {
  printf '✓ %s\n' "$*"
}

fail() {
  printf '✗ %s\n' "$*" >&2
  exit 1
}

json_field() {
  local json="$1"
  local field="$2"
  python3 -c "import json,sys; print(json.load(sys.stdin)['$field'])" <<< "$json"
}

wait_for() {
  local url="$1"
  local retries="${2:-30}"
  local i

  for ((i = 1; i <= retries; i++)); do
    if curl -sf "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

check_services() {
  step "1. Verificando serviços"

  wait_for "$DEVICE_MGMT/api/sensors" || fail "device-management não responde em $DEVICE_MGMT"
  ok "device-management (8080)"

  wait_for "$TEMP_MON/api/sensors/0/monitoring" 2>/dev/null || true
  ok "temperatura-monitoring (8082) — assumindo ambiente ./ems.sh start"
  ok "temperatura-processing (8081) — será exercitado ao enviar temperatura"
}

create_sensor() {
  step "2. Cadastrando sensor"

  local response
  response=$(curl -sf -X POST "$DEVICE_MGMT/api/sensors" \
    -H 'Content-Type: application/json' \
    -d '{
      "name": "Sensor Demo",
      "ip": "192.168.1.100",
      "location": "Sala de aula",
      "protocol": "HTTP",
      "model": "DHT22"
    }') || fail "Falha ao criar sensor"

  SENSOR_ID=$(json_field "$response" id)
  ok "Sensor criado: $SENSOR_ID"
  printf '%s\n' "$response" | python3 -m json.tool
}

enable_sensor() {
  step "3. Habilitando monitoramento (device-management → temperatura-monitoring)"

  curl -sf -X PUT "$DEVICE_MGMT/api/sensors/$SENSOR_ID/enable" >/dev/null \
    || fail "Falha ao habilitar sensor"
  ok "Monitoramento ativado"
}

configure_alerts() {
  step "4. Configurando alertas (mín: 15°C, máx: 30°C)"

  local response
  response=$(curl -sf -X PUT "$TEMP_MON/api/sensors/$SENSOR_ID/alert" \
    -H 'Content-Type: application/json' \
    -d '{"minTemperature": 15.0, "maxTemperature": 30.0}') \
    || fail "Falha ao configurar alertas"

  ok "Limites configurados"
  printf '%s\n' "$response" | python3 -m json.tool
}

send_temperature() {
  local value="$1"
  local label="$2"

  curl -sf -X POST "$TEMP_PROC/api/sensors/$SENSOR_ID/temperatures/data" \
    -H 'Content-Type: text/plain' \
    -d "$value" >/dev/null \
    || fail "Falha ao enviar temperatura $value"

  ok "$label — ${value}°C enviado ao temperatura-processing (RabbitMQ)"
}

process_readings() {
  step "5. Enviando leituras de temperatura"

  send_temperature "22.5" "Leitura normal"
  sleep 3
  send_temperature "35.0" "Leitura acima do limite (alerta esperado)"
  printf '\nAguardando processamento assíncrono (RabbitMQ)...\n'
  sleep 8
}

show_results() {
  step "6. Consultando histórico de temperaturas"

  local logs
  logs=$(curl -sf "$TEMP_MON/api/sensors/$SENSOR_ID/temperatures?size=5") \
    || fail "Falha ao consultar logs de temperatura"
  printf '%s\n' "$logs" | python3 -m json.tool

  step "7. Consultando eventos de alerta"

  local events
  events=$(curl -sf "$TEMP_MON/api/sensors/$SENSOR_ID/alert/events?size=5") \
    || fail "Falha ao consultar eventos de alerta"
  printf '%s\n' "$events" | python3 -m json.tool

  local total
  total=$(python3 -c "import json,sys; print(json.load(sys.stdin)['totalElements'])" <<< "$events")

  if [ "$total" -gt 0 ]; then
    ok "$total evento(s) de alerta registrado(s)"
  else
    fail "Nenhum alerta registrado — verifique se o RabbitMQ está rodando"
  fi

  step "8. Detalhe agregado do sensor (device-management + monitoring)"

  local detail
  detail=$(curl -sf "$DEVICE_MGMT/api/sensors/$SENSOR_ID/detail") \
    || fail "Falha ao consultar detalhe do sensor"
  printf '%s\n' "$detail" | python3 -m json.tool
}

summary() {
  step "Resumo"

  cat <<EOF

Fluxo demonstrado:
  1. device-management    → cadastro e habilitação do sensor
  2. temperatura-monitoring → configuração de limites de alerta
  3. temperatura-processing → recebe leitura e publica no RabbitMQ
  4. temperatura-monitoring → consome filas, grava logs e registra alertas

Sensor ID: $SENSOR_ID

Endpoints úteis:
  GET  $DEVICE_MGMT/api/sensors/$SENSOR_ID/detail
  GET  $TEMP_MON/api/sensors/$SENSOR_ID/temperatures
  GET  $TEMP_MON/api/sensors/$SENSOR_ID/alert/events

EOF
}

main() {
  printf '\n╔══════════════════════════════════════╗\n'
  printf '║   EMS Meta — Demonstração E2E        ║\n'
  printf '╚══════════════════════════════════════╝\n'

  check_services
  create_sensor
  enable_sensor
  configure_alerts
  process_readings
  show_results
  summary
}

main "$@"
