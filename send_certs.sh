#!/usr/bin/env bash
set -euo pipefail

CERT_DIR="/certs"
PASS_FILE="/run/secrets/pfx_passwords"

ZABBIX_SERVER="${ZABBIX_SERVER:-192.168.0.40}"
ZABBIX_HOST="${ZABBIX_HOST:-cert-monitor-local}"

if [[ ! -f "$PASS_FILE" ]]; then
  echo "Arquivo de senhas não encontrado em $PASS_FILE"
  exit 1
fi

get_password() {
  local cert_name="$1"
  local line
  line=$(grep -E "^${cert_name}=" "$PASS_FILE" || true)
  if [[ -z "$line" ]]; then
    return 1
  fi
  printf '%s' "${line#*=}"
}

send_value() {
  local key="$1"
  local value="$2"

  zabbix_sender \
    -z "$ZABBIX_SERVER" \
    -s "$ZABBIX_HOST" \
    -k "$key" \
    -o "$value" >/dev/null
}

process_cert() {
  local cert_path="$1"
  local cert_name
  cert_name="$(basename "$cert_path")"

  local cert_pass
  cert_pass="$(get_password "$cert_name" || true)"

  if [[ -z "${cert_pass:-}" ]]; then
    echo "Senha não encontrada para $cert_name"
    send_value "cert.status[$cert_name]" "2"
    send_value "cert.error[$cert_name]" "senha_nao_encontrada"
    return
  fi

  local cert_pem
  cert_pem="$(openssl pkcs12 \
    -legacy \
    -in "$cert_path" \
    -clcerts \
    -nokeys \
    -passin "pass:$cert_pass" 2>/dev/null || true)"

  if [[ -z "$cert_pem" ]]; then
    echo "Falha ao ler $cert_name"
    send_value "cert.status[$cert_name]" "3"
    send_value "cert.error[$cert_name]" "falha_leitura_pfx"
    return
  fi

  local subject issuer serial not_before not_after sha256 end_ts now_ts days_left

  subject="$(printf '%s\n' "$cert_pem" | openssl x509 -noout -subject 2>/dev/null | sed 's/^subject=//')"
  issuer="$(printf '%s\n' "$cert_pem" | openssl x509 -noout -issuer 2>/dev/null | sed 's/^issuer=//')"
  serial="$(printf '%s\n' "$cert_pem" | openssl x509 -noout -serial 2>/dev/null | sed 's/^serial=//')"
  not_before="$(printf '%s\n' "$cert_pem" | openssl x509 -noout -startdate 2>/dev/null | sed 's/^notBefore=//')"
  not_after="$(printf '%s\n' "$cert_pem" | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
  sha256="$(printf '%s\n' "$cert_pem" | openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/^sha256 Fingerprint=//')"

  end_ts="$(date -d "$not_after" +%s 2>/dev/null || echo 0)"
  now_ts="$(date +%s)"

  if [[ "$end_ts" -gt 0 ]]; then
    days_left="$(( (end_ts - now_ts) / 86400 ))"
  else
    days_left="-99999"
  fi

  echo "Enviando métricas de $cert_name para $ZABBIX_SERVER"

  send_value "cert.status[$cert_name]" "0"
  send_value "cert.error[$cert_name]" ""
  send_value "cert.days_left[$cert_name]" "$days_left"
  send_value "cert.expiry_ts[$cert_name]" "$end_ts"
  send_value "cert.subject[$cert_name]" "$subject"
  send_value "cert.issuer[$cert_name]" "$issuer"
  send_value "cert.serial[$cert_name]" "$serial"
  send_value "cert.not_before[$cert_name]" "$not_before"
  send_value "cert.not_after[$cert_name]" "$not_after"
  send_value "cert.sha256[$cert_name]" "$sha256"
}

shopt -s nullglob
CERTS=("$CERT_DIR"/*.pfx)

if [[ ${#CERTS[@]} -eq 0 ]]; then
  echo "Nenhum .pfx encontrado em $CERT_DIR"
  exit 1
fi

for cert in "${CERTS[@]}"; do
  process_cert "$cert"
done

echo "Coleta finalizada."