#!/usr/bin/env bash
# Задание 3 (п. 7): отдельный стенд Fabric 3.x с SmartBFT Ordering Service (4 orderer, f = 1).
#   bft.sh up       — криптоматериал, 4 orderer, peer0.org1, канал bftchannel, chaincode
#   bft.sh test     — контрольные транзакции при отказах orderer и восстановление
#   bft.sh down     — остановить и удалить стенд
source "$(dirname "$0")/../network/scripts/common.sh"

BFT_DIR="$PROJECT_DIR/network-bft"
RT="$BFT_DIR/runtime"; ORGS="$RT/organizations"; L="$RT/logs"
CH=bftchannel; CC=medicinebatch
OO="$ORGS/ordererOrganizations/example.com"
P1="$ORGS/peerOrganizations/org1.example.com"
PEER_PORT=7251; PEER_CC=7252; PEER_OPS=9560
port_of()  { echo $((7140 + $1 * 10)); }        # orderer1 → 7150 … orderer4 → 7180
admin_of() { echo $((7143 + $1 * 10)); }        # osnadmin 7153 … 7183
ops_of()   { echo $((9549 + $1)); }             # operations 9550 … 9553
otls()     { echo "$OO/orderers/orderer$1.example.com/tls"; }

cli() {
  export FABRIC_CFG_PATH="$FABRIC_HOME/config" FABRIC_LOGGING_SPEC="info:grpc=error"
  export CORE_PEER_TLS_ENABLED=true CORE_PEER_LOCALMSPID=Org1MSP
  export CORE_PEER_TLS_ROOTCERT_FILE="$P1/peers/peer0.org1.example.com/tls/ca.crt"
  export CORE_PEER_MSPCONFIGPATH="$P1/users/Admin@org1.example.com/msp"
  export CORE_PEER_ADDRESS=localhost:$PEER_PORT
}

start_orderer() {   # <i>
  local i=$1 O="$OO/orderers/orderer$1.example.com"
  mkdir -p "$RT/orderer$i"
  FABRIC_CFG_PATH="$FABRIC_HOME/config" \
  ORDERER_GENERAL_LISTENADDRESS=127.0.0.1 ORDERER_GENERAL_LISTENPORT=$(port_of $i) \
  ORDERER_GENERAL_LOCALMSPID=OrdererMSP ORDERER_GENERAL_LOCALMSPDIR="$O/msp" \
  ORDERER_GENERAL_TLS_ENABLED=true ORDERER_GENERAL_TLS_PRIVATEKEY="$O/tls/server.key" \
  ORDERER_GENERAL_TLS_CERTIFICATE="$O/tls/server.crt" ORDERER_GENERAL_TLS_ROOTCAS="[$O/tls/ca.crt]" \
  ORDERER_GENERAL_CLUSTER_CLIENTCERTIFICATE="$O/tls/server.crt" ORDERER_GENERAL_CLUSTER_CLIENTPRIVATEKEY="$O/tls/server.key" \
  ORDERER_GENERAL_CLUSTER_ROOTCAS="[$O/tls/ca.crt]" \
  ORDERER_GENERAL_BOOTSTRAPMETHOD=none ORDERER_CHANNELPARTICIPATION_ENABLED=true \
  ORDERER_ADMIN_LISTENADDRESS=127.0.0.1:$(admin_of $i) ORDERER_ADMIN_TLS_ENABLED=true \
  ORDERER_ADMIN_TLS_CLIENTAUTHREQUIRED=true ORDERER_ADMIN_TLS_CERTIFICATE="$O/tls/server.crt" \
  ORDERER_ADMIN_TLS_PRIVATEKEY="$O/tls/server.key" ORDERER_ADMIN_TLS_ROOTCAS="[$O/tls/ca.crt]" \
  ORDERER_ADMIN_TLS_CLIENTROOTCAS="[$O/tls/ca.crt]" \
  ORDERER_OPERATIONS_LISTENADDRESS=127.0.0.1:$(ops_of $i) \
  ORDERER_FILELEDGER_LOCATION="$RT/orderer$i/ledger" ORDERER_CONSENSUS_WALDIR="$RT/orderer$i/wal" \
  ORDERER_CONSENSUS_SNAPDIR="$RT/orderer$i/snapshot" \
  nohup orderer >> "$L/orderer$i.log" 2>&1 &
  echo $! > "$RT/orderer$i.pid"
  wait_port "$(port_of $i)" "orderer$i"
}

stop_orderer() { kill "$(cat "$RT/orderer$1.pid")" 2>/dev/null || true; sleep 2; }

osn() {   # <i> <osnadmin args...>
  local i=$1; shift
  osnadmin "$@" -o "localhost:$(admin_of $i)" --ca-file "$(otls $i)/ca.crt" \
    --client-cert "$(otls $i)/server.crt" --client-key "$(otls $i)/server.key"
}

height_of() {   # высота ledger канала на orderer <i>
  osn "$1" channel list --channelID $CH 2>/dev/null | python3 -c 'import json,sys
try: print(json.loads(sys.stdin.read().split("\n",1)[1]).get("height"))
except Exception: print(-1)'
}

wait_sync() {   # ожидание, пока orderer <i> догонит orderer <j>
  for _ in $(seq 1 30); do
    [[ $(height_of "$1") == "$(height_of "$2")" ]] && { echo "   orderer$1 синхронизирован за $SECONDS с"; return; }
    sleep 2
  done
  echo "   orderer$1 ещё синхронизируется"
}

heights() {
  for i in 1 2 3 4; do
    local h; h=$(osn $i channel list --channelID $CH 2>/dev/null | python3 -c 'import json,sys
try: d=json.loads(sys.stdin.read().split("\n",1)[1]); print(d.get("height"), d.get("status"))
except Exception: print("недоступен")')
    printf '   orderer%s (:%s): height=%s\n' "$i" "$(port_of $i)" "$h"
  done
  cli; printf '   peer0.org1: %s\n' "$(peer channel getinfo -c $CH 2>/dev/null | sed 's/Blockchain info: //')"
}

leader() {   # текущий лидер SmartBFT по последним сообщениям ChangeRole в журналах
  grep -h "current leader:" "$L"/orderer*.log 2>/dev/null | sed -r 's/\x1B\[[0-9;]*[mK]//g' \
    | sort | tail -1 | grep -oE "current view: [0-9]+, current leader: [0-9]+"
}

control_tx() {   # <метка> <id партии> <номер orderer для отправки>
  cli
  local out
  out=$(peer chaincode invoke -o "localhost:$(port_of $3)" --tls --cafile "$(otls $3)/ca.crt" -C $CH -n $CC \
        --peerAddresses localhost:$PEER_PORT --tlsRootCertFiles "$P1/peers/peer0.org1.example.com/tls/ca.crt" \
        -c "{\"function\":\"CreateBatch\",\"Args\":[\"$2\",\"Control batch\",\"BFT1\",\"1\",\"2026-10-01\",\"2028-10-01\"]}" \
        --waitForEvent --waitForEventTimeout 40s 2>&1) || true
  local res; res=$(echo "$out" | grep -oE 'txid \[[0-9a-f]+\] committed with status \([A-Z_]+\)' | head -1)
  if [[ -z $res ]] && echo "$out" | grep -qE 'DeadlineExceeded|timed out'; then
    res="нет фиксации за 40 с (тайм-аут ожидания события): транзакция не упорядочена"
  elif [[ -z $res ]]; then
    res=$(echo "$out" | grep -oE 'Error: .{0,120}' | head -1)
  fi
  echo "   $1: CreateBatch $2 через orderer$3 → ${res:-нет подтверждения}"
}

case "${1:-}" in
up)
  pkill -f "[p]eer node start" 2>/dev/null || true; pkill -x orderer 2>/dev/null || true; sleep 2
  rm -rf "$RT"; mkdir -p "$L"
  log "Криптоматериал (cryptogen) для 4 orderer и Org1"
  cryptogen generate --config "$BFT_DIR/crypto-config.yaml" --output "$ORGS" >/dev/null
  for i in 1 2 3 4; do start_orderer $i; done
  ok "orderer1..4 запущены"

  log "Блок конфигурации канала $CH (OrdererType: BFT, Channel capability V3_0)"
  cp "$BFT_DIR/configtx.yaml" "$RT/configtx.yaml"
  FABRIC_CFG_PATH="$RT" configtxgen -profile ChannelUsingBFT -outputBlock "$RT/$CH.block" -channelID $CH 2>&1 | tail -1
  for i in 1 2 3 4; do osn $i channel join --channelID $CH --config-block "$RT/$CH.block" | head -1; done

  log "peer0.org1 :$PEER_PORT"
  mkdir -p "$RT/peer/config"
  python3 - "$FABRIC_HOME/config/core.yaml" "$RT/peer/config/core.yaml" "$PROJECT_DIR/builders/golang-native" <<'PY'
import sys, yaml
src, dst, builder = sys.argv[1:4]
c = yaml.safe_load(open(src)); c["vm"]["endpoint"] = ""
c["chaincode"]["externalBuilders"] = [{"name": "golang-native", "path": builder,
    "propagateEnvironment": ["HOME", "PATH", "GOCACHE", "GOPATH", "GOFLAGS", "GOPROXY", "GOTOOLCHAIN"]}]
c["chaincode"]["installTimeout"] = "600s"
yaml.safe_dump(c, open(dst, "w"), sort_keys=False)
PY
  P="$P1/peers/peer0.org1.example.com"
  FABRIC_CFG_PATH="$RT/peer/config" CORE_PEER_ID=peer0.org1.example.com \
  CORE_PEER_LISTENADDRESS=127.0.0.1:$PEER_PORT CORE_PEER_ADDRESS=localhost:$PEER_PORT \
  CORE_PEER_CHAINCODELISTENADDRESS=127.0.0.1:$PEER_CC CORE_PEER_CHAINCODEADDRESS=localhost:$PEER_CC \
  CORE_PEER_GOSSIP_BOOTSTRAP=localhost:$PEER_PORT CORE_PEER_GOSSIP_EXTERNALENDPOINT=localhost:$PEER_PORT \
  CORE_PEER_LOCALMSPID=Org1MSP CORE_PEER_MSPCONFIGPATH="$P/msp" CORE_PEER_TLS_ENABLED=true \
  CORE_PEER_TLS_CERT_FILE="$P/tls/server.crt" CORE_PEER_TLS_KEY_FILE="$P/tls/server.key" \
  CORE_PEER_TLS_ROOTCERT_FILE="$P/tls/ca.crt" CORE_PEER_FILESYSTEMPATH="$RT/peer/data" \
  CORE_OPERATIONS_LISTENADDRESS=127.0.0.1:$PEER_OPS \
  nohup peer node start > "$L/peer0.org1.log" 2>&1 &
  wait_port $PEER_PORT peer0.org1
  cli; peer channel join -b "$RT/$CH.block" 2>&1 | tail -1
  sleep 3

  log "Chaincode $CC 1.0 на стенде BFT (политика OR('Org1MSP.peer'))"
  SRC="$PROJECT_DIR/chaincode/medicinebatch-v1"
  [[ -d $SRC/vendor ]] || (cd "$SRC" && GOFLAGS=-mod=mod go mod vendor)
  peer lifecycle chaincode package "$RT/cc.tar.gz" --path "$SRC" --lang golang --label ${CC}_1.0
  PKG=$(peer lifecycle chaincode calculatepackageid "$RT/cc.tar.gz")
  peer lifecycle chaincode install "$RT/cc.tar.gz" 2>&1 | grep -o "Chaincode code package identifier.*"
  ORD=(-o localhost:7150 --tls --cafile "$(otls 1)/ca.crt")
  peer lifecycle chaincode approveformyorg "${ORD[@]}" -C $CH -n $CC -v 1.0 --sequence 1 --package-id "$PKG" \
    --signature-policy "OR('Org1MSP.peer')" --waitForEvent 2>&1 | grep -oE "committed with status.*"
  peer lifecycle chaincode commit "${ORD[@]}" -C $CH -n $CC -v 1.0 --sequence 1 --signature-policy "OR('Org1MSP.peer')" \
    --peerAddresses localhost:$PEER_PORT --tlsRootCertFiles "$P/tls/ca.crt" --waitForEvent 2>&1 | grep -oE "committed with status.*"
  peer lifecycle chaincode querycommitted -C $CH -n $CC 2>/dev/null
  ok "Стенд SmartBFT готов"
  ;;

test)
  set +e   # отказы узлов ожидаемы
  log "Конфигурация консенсуса канала $CH"
  cli
  peer channel fetch config "$RT/config.block" -c $CH -o localhost:7150 --tls --cafile "$(otls 1)/ca.crt" >/dev/null 2>&1
  configtxlator proto_decode --input "$RT/config.block" --type common.Block --output "$RT/config.json"
  python3 - "$RT/config.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))["data"]["data"][0]["payload"]["data"]["config"]
o = c["channel_group"]["groups"]["Orderer"]["values"]
ct = o["ConsensusType"]["value"]
cons = ["%s:%s:%s" % (x["id"], x["host"], x["port"]) for x in o["Orderers"]["value"]["consenter_mapping"]]
print("   ConsensusType:", ct["type"], "| consenters:", cons)
print("   Channel capabilities:", list(c["channel_group"]["values"]["Capabilities"]["value"]["capabilities"]))
PY
  echo "   n = 4 узла, f = (n - 1) / 3 = 1, кворум = 2f + 1 = 3"

  log "Шаг 0. Все 4 orderer работают"
  heights; control_tx "T0" BFT-CTRL-000 1
  echo "   лидер (по журналам): $(leader)"

  log "Шаг 1. Контролируемый отказ одного orderer (orderer4 — ведомый)"
  stop_orderer 4; echo "   orderer4 остановлен (kill $(cat "$RT/orderer4.pid"))"
  control_tx "T1" BFT-CTRL-001 1
  heights

  log "Шаг 2. Восстановление orderer4 и догон ledger"
  start_orderer 4
  control_tx "T1b" BFT-CTRL-001B 2
  SECONDS=0; wait_sync 4 1; heights

  log "Шаг 3. Отказ лидера (orderer1) — смена представления (view change)"
  stop_orderer 1; echo "   orderer1 остановлен"
  control_tx "T2" BFT-CTRL-002 2
  echo "   новый лидер (по журналам): $(leader)"
  grep -h "ChangeRole\|ViewChange\|viewchange" "$L"/orderer2.log 2>/dev/null | sed -r 's/\x1B\[[0-9;]*[mK]//g' | tail -3 | cut -c1-190
  start_orderer 1; sleep 12

  log "Шаг 4. Граница отказоустойчивости: остановлены 2 orderer (> f)"
  stop_orderer 3; stop_orderer 4; echo "   orderer3 и orderer4 остановлены — осталось 2 узла < кворума 3"
  control_tx "T3" BFT-CTRL-003 1
  log "Шаг 5. Восстановление orderer3 и orderer4"
  start_orderer 3; start_orderer 4; sleep 15
  control_tx "T4" BFT-CTRL-004 2
  heights
  cli; echo "   партии в ledger: $(peer chaincode query -C $CH -n $CC -c '{"Args":["GetAllBatches"]}' 2>/dev/null | python3 -c 'import json,sys; print([b["id"]+":"+b["status"] for b in json.load(sys.stdin)])')"
  ;;

down)
  pkill -f "[p]eer node start" 2>/dev/null || true; pkill -x orderer 2>/dev/null || true
  rm -rf "$RT"; ok "Стенд BFT удалён" ;;
*) echo "usage: $0 up|test|down"; exit 1 ;;
esac
