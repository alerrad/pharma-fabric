#!/usr/bin/env bash
# Задание 1 (п. 5–7): транзакции medicinebatch 1.0, состояние объектов, исследование ledger.
source "$(dirname "$0")/common.sh"
CC=medicinebatch
OUT="$RUNTIME/analysis"; mkdir -p "$OUT"
[[ -n ${SKIP_TX:-} ]] || : > "$OUT/txids.txt"

run_tx() {   # <метка> <org> <user> <json>
  local label=$1 org=$2 user=$3 ctor=$4
  use_identity "$org" "$user"
  log "$label  [$user@org$org]"
  echo "\$ peer chaincode invoke -C $CHANNEL -n $CC -c '$ctor' (endorsers: peer0.org1, peer0.org2)"
  local res; res=$(invoke "$CC" "$ctor")
  echo "$res" | grep -E "invoke successful|committed with status|Error" | sed -E 's/^.*(Chaincode invoke|txid|Error)/\1/' | cut -c1-220
  local txid; txid=$(echo "$res" | grep -oE 'txid \[[0-9a-f]{64}' | head -1 | grep -oE '[0-9a-f]{64}')
  echo "$label $txid" >> "$OUT/txids.txt"
}

if [[ -z ${SKIP_TX:-} ]]; then
run_tx "T1 CreateBatch BATCH-2026-001" 1 production \
  '{"function":"CreateBatch","Args":["BATCH-2026-001","Paracetamol 500 mg","A2026-001","10000","2026-09-01","2028-09-01"]}'
run_tx "T2 CreateBatch BATCH-2026-002" 1 production \
  '{"function":"CreateBatch","Args":["BATCH-2026-002","Amoxicillin 250 mg","B2026-077","5000","2026-09-15","2027-09-15"]}'
run_tx "T3 UpdateStatus BATCH-2026-001 → RELEASED" 1 qa \
  '{"function":"UpdateStatus","Args":["BATCH-2026-001","RELEASED"]}'
log "T4 TransferBatch BATCH-2026-001 → Org2MSP  [production@org1, через Fabric Gateway]"
echo "\$ gateway-client -peer localhost:$PEER1_PORT -msp Org1MSP -chaincode $CC -fn TransferBatch -args BATCH-2026-001,Org2MSP"
GW_OUT=$(gw 1 production -chaincode $CC -fn TransferBatch -args BATCH-2026-001,Org2MSP)
echo "$GW_OUT"
echo "T4 TransferBatch BATCH-2026-001 → Org2MSP $(echo "$GW_OUT" | grep -oE 'TxID=[0-9a-f]{64}' | cut -d= -f2)" >> "$OUT/txids.txt"
run_tx "T5 ReceiveBatch BATCH-2026-001" 2 logistics \
  '{"function":"ReceiveBatch","Args":["BATCH-2026-001"]}'
run_tx "T6 UpdateStatus BATCH-2026-002 → REJECTED" 1 qa \
  '{"function":"UpdateStatus","Args":["BATCH-2026-002","REJECTED"]}'
run_tx "T7 CreateBatch BATCH-2026-003" 1 production \
  '{"function":"CreateBatch","Args":["BATCH-2026-003","Ibuprofen 200 mg","C2026-03","7000","2026-09-20","2029-09-20"]}'

log "T8/T9 Конкурирующие транзакции к одному ключу (демонстрация MVCC)"
use_identity 1 qa
invoke $CC '{"function":"UpdateStatus","Args":["BATCH-2026-003","RELEASED"]}' > "$OUT/mvcc-a.log" 2>&1 &
invoke $CC '{"function":"UpdateStatus","Args":["BATCH-2026-003","REJECTED"]}' > "$OUT/mvcc-b.log" 2>&1 &
wait
for f in a b; do
  st=$(grep -oE 'txid \[[0-9a-f]{64}\] committed with status \([A-Z_]+\) at localhost:7051' "$OUT/mvcc-$f.log" | head -1)
  echo "  $( [[ $f == a ]] && echo 'RELEASED' || echo 'REJECTED' ): $st"
  echo "T$( [[ $f == a ]] && echo 8 || echo 9 ) UpdateStatus BATCH-2026-003 (MVCC) $(echo "$st" | grep -oE '[0-9a-f]{64}')" >> "$OUT/txids.txt"
done
echo "  итоговое состояние: $(query $CC '{"Args":["ReadBatch","BATCH-2026-003"]}' | python3 "$NETWORK_DIR/scripts/fmt_batch.py")"
fi

log "Проверка валидации (ожидаются отказы)"
expect_fail() {   # <описание> <json>
  local out; out=$(invoke $CC "$2" || true)
  printf -- "-- %s → %s\n" "$1" "$(echo "$out" | grep -oE 'message:"[^"]+"' | head -1)"
}
use_identity 1 production
expect_fail "повторное создание BATCH-2026-001" '{"function":"CreateBatch","Args":["BATCH-2026-001","Paracetamol 500 mg","A2026-001","1","2026-09-01","2027-01-01"]}'
expect_fail "срок годности раньше даты выпуска" '{"function":"CreateBatch","Args":["BATCH-2026-003","Ibuprofen 200 mg","C1","100","2026-09-01","2026-08-01"]}'
expect_fail "количество = 0" '{"function":"CreateBatch","Args":["BATCH-2026-004","Ibuprofen 200 mg","C2","0","2026-09-01","2027-08-01"]}'
expect_fail "недопустимый переход REJECTED→RELEASED" '{"function":"UpdateStatus","Args":["BATCH-2026-002","RELEASED"]}'
use_identity 2 logistics
expect_fail "Org2 создаёт партию" '{"function":"CreateBatch","Args":["BATCH-2026-009","Aspirin 100 mg","L9","1","2026-09-01","2027-01-01"]}'

log "Задание 1.6: текущее состояние бизнес-объектов"
use_identity 1 Admin
echo "\$ ReadBatch BATCH-2026-001";  query $CC '{"Args":["ReadBatch","BATCH-2026-001"]}' | python3 -m json.tool
echo "\$ BatchExists BATCH-2026-002"; query $CC '{"Args":["BatchExists","BATCH-2026-002"]}'
echo "\$ BatchExists BATCH-2026-404"; query $CC '{"Args":["BatchExists","BATCH-2026-404"]}'
echo "\$ GetAllBatches (через peer0.org2)"
use_identity 2 Admin
query $CC '{"Args":["GetAllBatches"]}' > "$OUT/all.json"
python3 - "$OUT/all.json" <<'PY'
import json, sys
for b in json.load(open(sys.argv[1])):
    print(f"{b['id']:16} {b['status']:9} holder={b['holderMSP']:8} lastTx={b['lastTxID'][:16]}...")
PY

log "Задание 1.7: ledger канала"
use_identity 1 Admin
peer channel getinfo -c "$CHANNEL" 2>&1 | grep "Blockchain info"
peer channel fetch newest "$OUT/newest.block" -c "$CHANNEL" "${ORDERER_ARGS[@]}" 2>&1 | grep -E "Received block"
configtxlator proto_decode --input "$OUT/newest.block" --type common.Block --output "$OUT/newest.json"
python3 - "$OUT/newest.json" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))
h = b["header"]
tx = b["data"]["data"][0]["payload"]
ch = tx["header"]["channel_header"]
print(f"Последний блок: number={h['number']}, previous_hash={h['previous_hash']}, data_hash={h['data_hash']}")
print(f"  транзакций в блоке: {len(b['data']['data'])}; первая: tx_id={ch['tx_id']}, type={ch['type']}, timestamp={ch['timestamp']}")
PY

log "Анализ транзакции T4 (TransferBatch) по этапам"
TX4=$(grep '^T4 ' "$OUT/txids.txt" | awk '{print $NF}')
peer chaincode query -C "$CHANNEL" -n qscc -c "{\"Args\":[\"GetBlockByTxID\",\"$CHANNEL\",\"$TX4\"]}" --hex 2>/dev/null \
  | python3 -c 'import sys; sys.stdout.buffer.write(bytes.fromhex(sys.stdin.read().strip()))' > "$OUT/t4.block"
configtxlator proto_decode --input "$OUT/t4.block" --type common.Block --output "$OUT/t4-block.json"
python3 "$NETWORK_DIR/scripts/analyze_tx.py" "$OUT/t4-block.json" "$TX4" "$LOGS"
cat "$OUT/txids.txt"
