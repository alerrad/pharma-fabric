#!/usr/bin/env bash
# Общие параметры и функции сети PharmaChain (Hyperledger Fabric 3.1.x, без Docker).
# Используется всеми скриптами: source network/scripts/common.sh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NETWORK_DIR="$PROJECT_DIR/network"
RUNTIME="${RUNTIME:-$NETWORK_DIR/runtime}"           # всё, что генерируется при запуске (в .gitignore)
FABRIC_HOME="${FABRIC_HOME:-$HOME/fabric}"             # распакованные бинарники Fabric 3.1.x и Fabric CA
export PATH="$FABRIC_HOME/bin:$PATH"

ORGS_DIR="$RUNTIME/organizations"
LOGS="$RUNTIME/logs"
SECRETS="$RUNTIME/secrets.env"                          # случайные пароли CA (chmod 600, в отчёт/репозиторий не попадают)
CHANNEL="pharmachannel"

# Порты
CA_ORG1_PORT=7054;  CA_ORG2_PORT=8054;  CA_ORDERER_PORT=9054
ORDERER_PORT=7050;  ORDERER_ADMIN_PORT=7053; ORDERER_OPS_PORT=9443
PEER1_PORT=7051;    PEER1_CC_PORT=7052;  PEER1_OPS_PORT=9444
PEER2_PORT=9051;    PEER2_CC_PORT=9052;  PEER2_OPS_PORT=9445

ORDERER_CA="$ORGS_DIR/ordererOrganizations/example.com/orderers/orderer.example.com/tls/ca.crt"
ORDERER_TLS_DIR="$ORGS_DIR/ordererOrganizations/example.com/orderers/orderer.example.com/tls"
PEER1_TLS_CA="$ORGS_DIR/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt"
PEER2_TLS_CA="$ORGS_DIR/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt"

log()  { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✔ %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m✘ %s\033[0m\n' "$*" >&2; exit 1; }

# Ожидание открытия TCP-порта
wait_port() {
  local port=$1 name=$2
  for _ in $(seq 1 60); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then exec 3>&- 3<&-; return 0; fi
    sleep 0.5
  done
  fail "$name не открыл порт $port (см. $LOGS)"
}

# Переключение идентичности peer CLI.
#   use_identity <org: 1|2> <user: Admin|production|qa|clerk|logistics>
use_identity() {
  local org=$1 user=${2:-Admin}
  export FABRIC_CFG_PATH="$FABRIC_HOME/config"
  export FABRIC_LOGGING_SPEC="info:grpc=error"
  export CORE_PEER_TLS_ENABLED=true
  if [[ $org == 1 ]]; then
    export CORE_PEER_LOCALMSPID=Org1MSP
    export CORE_PEER_TLS_ROOTCERT_FILE="$PEER1_TLS_CA"
    export CORE_PEER_ADDRESS="localhost:$PEER1_PORT"
    export CORE_PEER_MSPCONFIGPATH="$ORGS_DIR/peerOrganizations/org1.example.com/users/$user@org1.example.com/msp"
  else
    export CORE_PEER_LOCALMSPID=Org2MSP
    export CORE_PEER_TLS_ROOTCERT_FILE="$PEER2_TLS_CA"
    export CORE_PEER_ADDRESS="localhost:$PEER2_PORT"
    export CORE_PEER_MSPCONFIGPATH="$ORGS_DIR/peerOrganizations/org2.example.com/users/$user@org2.example.com/msp"
  fi
  [[ -d $CORE_PEER_MSPCONFIGPATH ]] || fail "нет MSP идентичности $user@org$org"
}

# Аргументы для отправки транзакции с подтверждением обоих peer (политика AND)
PEER_ARGS=(--peerAddresses "localhost:$PEER1_PORT" --tlsRootCertFiles "$PEER1_TLS_CA"
           --peerAddresses "localhost:$PEER2_PORT" --tlsRootCertFiles "$PEER2_TLS_CA")
ORDERER_ARGS=(-o "localhost:$ORDERER_PORT" --tls --cafile "$ORDERER_CA")

# invoke <chaincode> <json-args> [доп. флаги]; печатает TxID и статус фиксации
invoke() {
  local cc=$1 ctor=$2; shift 2
  peer chaincode invoke "${ORDERER_ARGS[@]}" -C "$CHANNEL" -n "$cc" "${PEER_ARGS[@]}" \
    -c "$ctor" --waitForEvent "$@" 2>&1
}

query() {
  local cc=$1 ctor=$2; shift 2
  local err="$RUNTIME/.query.err"
  if ! peer chaincode query -C "$CHANNEL" -n "$cc" -c "$ctor" "$@" 2>"$err"; then
    grep -oE 'Error: .*' "$err" | head -1 | sed -E 's/\x1b\[[0-9;]*m//g'
    return 1
  fi
}

# Транзакция через Fabric Gateway (client/gateway-client):  gw <org> <user> -fn <функция> -args a,b
gw() {
  local org=$1 user=$2; shift 2
  local d="$ORGS_DIR/peerOrganizations/org$org.example.com/users/$user@org$org.example.com/msp"
  local port=$PEER1_PORT tls=$PEER1_TLS_CA
  [[ $org == 2 ]] && { port=$PEER2_PORT; tls=$PEER2_TLS_CA; }
  "$PROJECT_DIR/client/bin/gateway-client" -peer "localhost:$port" -tlsca "$tls" -msp "Org${org}MSP" \
    -cert "$d/signcerts/cert.pem" -keydir "$d/keystore" -channel "$CHANNEL" "$@"
}
