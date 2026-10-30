#!/usr/bin/env bash
# Управление сетью PharmaChain:
#   network.sh up      — CA, идентичности, orderer (Raft), 2 peer, канал pharmachannel
#   network.sh down    — остановить процессы и удалить runtime/
#   network.sh stop    — остановить процессы, сохранив данные
#   network.sh start   — запустить узлы с ранее созданными данными
source "$(dirname "$0")/common.sh"

stop_all() {
  # шаблоны вида [p]eer не совпадают с командной строкой самого pkill/скрипта
  pkill -f "[p]eer node start" 2>/dev/null || true
  pkill -x orderer 2>/dev/null || true
  pkill -f "[f]abric-ca-server start" 2>/dev/null || true
  pkill -f "[c]haincode -peer.address" 2>/dev/null || true
  sleep 2
}

# Копия core.yaml для peer с external builder golang-native и без Docker
peer_config() {   # <dir>
  mkdir -p "$1"
  python3 - "$FABRIC_HOME/config/core.yaml" "$1/core.yaml" "$PROJECT_DIR/builders/golang-native" <<'PY'
import sys, yaml
src, dst, builder = sys.argv[1:4]
cfg = yaml.safe_load(open(src))
cfg["vm"]["endpoint"] = ""                        # Docker не используется
cfg["chaincode"]["externalBuilders"] = [{
    "name": "golang-native",
    "path": builder,
    "propagateEnvironment": ["HOME", "PATH", "GOCACHE", "GOPATH", "GOFLAGS", "GOPROXY", "GOTOOLCHAIN"],
}]
cfg["chaincode"]["executetimeout"] = "60s"
cfg["chaincode"]["installTimeout"] = "600s"
yaml.safe_dump(cfg, open(dst, "w"), sort_keys=False)
PY
}

start_orderer() {
  local O="$ORGS_DIR/ordererOrganizations/example.com/orderers/orderer.example.com"
  mkdir -p "$RUNTIME/orderer"
  log "Запуск orderer.example.com (Raft) :$ORDERER_PORT, admin :$ORDERER_ADMIN_PORT"
  FABRIC_CFG_PATH="$FABRIC_HOME/config" \
  ORDERER_GENERAL_LISTENADDRESS=127.0.0.1 ORDERER_GENERAL_LISTENPORT=$ORDERER_PORT \
  ORDERER_GENERAL_LOCALMSPID=OrdererMSP ORDERER_GENERAL_LOCALMSPDIR="$O/msp" \
  ORDERER_GENERAL_TLS_ENABLED=true \
  ORDERER_GENERAL_TLS_PRIVATEKEY="$O/tls/server.key" ORDERER_GENERAL_TLS_CERTIFICATE="$O/tls/server.crt" \
  ORDERER_GENERAL_TLS_ROOTCAS="[$O/tls/ca.crt]" \
  ORDERER_GENERAL_CLUSTER_CLIENTCERTIFICATE="$O/tls/server.crt" \
  ORDERER_GENERAL_CLUSTER_CLIENTPRIVATEKEY="$O/tls/server.key" \
  ORDERER_GENERAL_CLUSTER_ROOTCAS="[$O/tls/ca.crt]" \
  ORDERER_GENERAL_BOOTSTRAPMETHOD=none ORDERER_CHANNELPARTICIPATION_ENABLED=true \
  ORDERER_ADMIN_LISTENADDRESS=127.0.0.1:$ORDERER_ADMIN_PORT \
  ORDERER_ADMIN_TLS_ENABLED=true ORDERER_ADMIN_TLS_CLIENTAUTHREQUIRED=true \
  ORDERER_ADMIN_TLS_CERTIFICATE="$O/tls/server.crt" ORDERER_ADMIN_TLS_PRIVATEKEY="$O/tls/server.key" \
  ORDERER_ADMIN_TLS_ROOTCAS="[$O/tls/ca.crt]" ORDERER_ADMIN_TLS_CLIENTROOTCAS="[$O/tls/ca.crt]" \
  ORDERER_OPERATIONS_LISTENADDRESS=127.0.0.1:$ORDERER_OPS_PORT \
  ORDERER_FILELEDGER_LOCATION="$RUNTIME/orderer/ledger" \
  ORDERER_CONSENSUS_WALDIR="$RUNTIME/orderer/etcdraft/wal" ORDERER_CONSENSUS_SNAPDIR="$RUNTIME/orderer/etcdraft/snapshot" \
  nohup orderer > "$LOGS/orderer.log" 2>&1 &
  wait_port $ORDERER_PORT orderer
  wait_port $ORDERER_ADMIN_PORT orderer-admin
}

start_peer() {   # <org 1|2> <port> <cc_port> <ops_port>
  local org=$1 port=$2 ccport=$3 ops=$4
  local P="$ORGS_DIR/peerOrganizations/org$org.example.com/peers/peer0.org$org.example.com"
  local cfg="$RUNTIME/peer0.org$org/config"
  peer_config "$cfg"
  log "Запуск peer0.org$org.example.com :$port"
  FABRIC_CFG_PATH="$cfg" \
  CORE_PEER_ID=peer0.org$org.example.com CORE_PEER_NETWORKID=pharma \
  CORE_PEER_LISTENADDRESS=127.0.0.1:$port CORE_PEER_ADDRESS=localhost:$port \
  CORE_PEER_CHAINCODELISTENADDRESS=127.0.0.1:$ccport CORE_PEER_CHAINCODEADDRESS=localhost:$ccport \
  CORE_PEER_GOSSIP_BOOTSTRAP=localhost:$port CORE_PEER_GOSSIP_EXTERNALENDPOINT=localhost:$port \
  CORE_PEER_LOCALMSPID=Org${org}MSP CORE_PEER_MSPCONFIGPATH="$P/msp" \
  CORE_PEER_TLS_ENABLED=true CORE_PEER_TLS_CERT_FILE="$P/tls/server.crt" \
  CORE_PEER_TLS_KEY_FILE="$P/tls/server.key" CORE_PEER_TLS_ROOTCERT_FILE="$P/tls/ca.crt" \
  CORE_PEER_FILESYSTEMPATH="$RUNTIME/peer0.org$org/data" \
  CORE_LEDGER_STATE_STATEDATABASE=goleveldb CORE_LEDGER_HISTORY_ENABLEHISTORYDATABASE=true \
  CORE_OPERATIONS_LISTENADDRESS=127.0.0.1:$ops CORE_METRICS_PROVIDER=prometheus \
  CORE_PEER_GATEWAY_ENABLED=true \
  nohup peer node start > "$LOGS/peer0.org$org.log" 2>&1 &
  wait_port "$port" "peer0.org$org"
}

create_channel() {
  log "Генерация блока конфигурации канала $CHANNEL (configtxgen)"
  cp "$NETWORK_DIR/configtx/configtx.yaml" "$RUNTIME/configtx.yaml"
  mkdir -p "$RUNTIME/channel-artifacts"
  FABRIC_CFG_PATH="$RUNTIME" configtxgen -profile PharmaChannelRaft \
      -outputBlock "$RUNTIME/channel-artifacts/$CHANNEL.block" -channelID "$CHANNEL"

  log "Подключение orderer к каналу (osnadmin, Channel Participation API)"
  osnadmin channel join --channelID "$CHANNEL" --config-block "$RUNTIME/channel-artifacts/$CHANNEL.block" \
      -o "localhost:$ORDERER_ADMIN_PORT" --ca-file "$ORDERER_CA" \
      --client-cert "$ORDERER_TLS_DIR/server.crt" --client-key "$ORDERER_TLS_DIR/server.key"
  sleep 3
  for org in 1 2; do
    use_identity $org Admin
    log "peer0.org$org присоединяется к каналу"
    peer channel join -b "$RUNTIME/channel-artifacts/$CHANNEL.block"
  done
  sleep 3
  use_identity 1 Admin
  peer channel list
  peer channel getinfo -c "$CHANNEL"
}

case "${1:-}" in
  up)
    stop_all
    rm -rf "$RUNTIME"
    bash "$NETWORK_DIR/scripts/ca.sh"
    start_orderer
    start_peer 1 $PEER1_PORT $PEER1_CC_PORT $PEER1_OPS_PORT
    start_peer 2 $PEER2_PORT $PEER2_CC_PORT $PEER2_OPS_PORT
    create_channel
    ok "Сеть запущена: канал $CHANNEL, Org1MSP + Org2MSP + OrdererMSP"
    ;;
  start)
    source "$SECRETS"
    start_orderer
    start_peer 1 $PEER1_PORT $PEER1_CC_PORT $PEER1_OPS_PORT
    start_peer 2 $PEER2_PORT $PEER2_CC_PORT $PEER2_OPS_PORT
    ok "Узлы запущены"
    ;;
  stop) stop_all; ok "Узлы остановлены" ;;
  down) stop_all; rm -rf "$RUNTIME"; ok "Сеть удалена" ;;
  *) echo "usage: $0 up|down|start|stop"; exit 1 ;;
esac
