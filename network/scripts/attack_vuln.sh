#!/usr/bin/env bash
# Задание 2 (п. 2–3): воспроизведение уязвимости medicinebatch_vuln от имени Org2
# и проверка той же атаки против medicinebatch (v1) и medicinebatch_secure.
source "$(dirname "$0")/common.sh"

msg() { echo "$1" | grep -oE 'message:"[^"]+"' | head -1; }
status_of() { query "$1" "{\"Args\":[\"ReadBatch\",\"$2\"]}" | python3 "$NETWORK_DIR/scripts/fmt_batch.py"; }

log "Подготовка: Org1 (production) создаёт партию BATCH-V-001 в medicinebatch_vuln — контроль качества не проводился"
use_identity 1 production
invoke medicinebatch_vuln '{"function":"CreateBatch","Args":["BATCH-V-001","Metformin 850 mg","V2026-01","20000","2026-10-01","2028-10-01"]}' \
  | grep -oE 'txid \[[0-9a-f]+\] committed with status \([A-Z_]+\) at localhost:7051'
use_identity 1 Admin
echo "Состояние до атаки: $(status_of medicinebatch_vuln BATCH-V-001)"

log "АТАКА: Org2 (logistics@org2, дистрибьютор) выпускает партию в обращение без контроля качества"
use_identity 2 logistics
echo "\$ peer chaincode invoke -n medicinebatch_vuln -c '{\"function\":\"UpdateStatus\",\"Args\":[\"BATCH-V-001\",\"RELEASED\"]}'  (MSP: $CORE_PEER_LOCALMSPID)"
OUT=$(invoke medicinebatch_vuln '{"function":"UpdateStatus","Args":["BATCH-V-001","RELEASED"]}' || true)
echo "$OUT" | grep -oE 'txid \[[0-9a-f]+\] committed with status \([A-Z_]+\) at localhost:[0-9]+'
ATTACK_TX=$(echo "$OUT" | grep -oE 'txid \[[0-9a-f]{64}' | head -1 | grep -oE '[0-9a-f]{64}')
echo "ATTACK_TXID=$ATTACK_TX"
use_identity 1 Admin
echo "Состояние после атаки: $(status_of medicinebatch_vuln BATCH-V-001)"

log "Проверка, кем подписана и подтверждена транзакция атаки (блок из ledger)"
peer chaincode query -C "$CHANNEL" -n qscc -c "{\"Args\":[\"GetBlockByTxID\",\"$CHANNEL\",\"$ATTACK_TX\"]}" --hex 2>/dev/null \
  | python3 -c 'import sys; sys.stdout.buffer.write(bytes.fromhex(sys.stdin.read().strip()))' > "$RUNTIME/analysis/attack.block"
configtxlator proto_decode --input "$RUNTIME/analysis/attack.block" --type common.Block --output "$RUNTIME/analysis/attack-block.json"
python3 "$NETWORK_DIR/scripts/analyze_tx.py" "$RUNTIME/analysis/attack-block.json" "$ATTACK_TX" "$LOGS"

log "Та же атака против исправленных версий"
use_identity 1 production
invoke medicinebatch_secure '{"function":"CreateBatch","Args":["BATCH-V-001","Metformin 850 mg","V2026-01","20000","2026-10-01","2028-10-01"]}' >/dev/null || true
use_identity 2 logistics
echo "-- medicinebatch (v1, проверка MSP):  $(msg "$(invoke medicinebatch '{"function":"UpdateStatus","Args":["BATCH-2026-002","RECALLED"]}' || true)")"
echo "-- medicinebatch_secure:              $(msg "$(invoke medicinebatch_secure '{"function":"UpdateStatus","Args":["BATCH-V-001","RELEASED"]}' || true)")"
use_identity 1 Admin
echo "Состояние BATCH-V-001 в medicinebatch_secure: $(status_of medicinebatch_secure BATCH-V-001)"
