#!/usr/bin/env bash
# Задание 3 (п. 1–6): обновление chaincode medicinebatch 1.0 (seq 1) → 2.0 (seq 2)
# и проверка обратной совместимости с World State, созданным версией 1.0.
source "$(dirname "$0")/common.sh"
CC=medicinebatch
A="$RUNTIME/analysis"; mkdir -p "$A"

log "3.1 Исходное состояние ДО обновления"
use_identity 1 Admin
peer lifecycle chaincode querycommitted --channelID "$CHANNEL" --name $CC 2>/dev/null
peer lifecycle chaincode querycommitted --channelID "$CHANNEL" --name $CC --output json 2>/dev/null > "$A/committed-v1.json"
peer lifecycle chaincode queryinstalled 2>/dev/null | grep "Label: ${CC}_"
query $CC '{"Args":["ReadBatch","BATCH-2026-001"]}' > "$A/batch001-before.json"
echo "ReadBatch BATCH-2026-001 (до):"; python3 "$NETWORK_DIR/scripts/fmt_batch.py" < "$A/batch001-before.json"
query $CC '{"Args":["GetAllBatches"]}' | python3 "$NETWORK_DIR/scripts/fmt_batch.py"
echo "GetChaincodeInfo в v1.0: $(query $CC '{"Args":["GetChaincodeInfo"]}' || true)"

log "3.2–3.5 Package → Install → Approve → Commit для версии 2.0 / sequence 2"
bash "$NETWORK_DIR/scripts/deploy_cc.sh" $CC 2.0 2 "$PROJECT_DIR/chaincode/medicinebatch-v2"

log "3.5 Проверка определения ПОСЛЕ обновления"
use_identity 2 Admin
peer lifecycle chaincode querycommitted --channelID "$CHANNEL" --name $CC 2>/dev/null
peer lifecycle chaincode querycommitted --channelID "$CHANNEL" --name $CC --output json 2>/dev/null > "$A/committed-v2.json"
peer lifecycle chaincode queryinstalled 2>/dev/null | grep "Label: ${CC}_"
python3 - "$A/committed-v1.json" "$A/committed-v2.json" <<'PY'
import json, sys
a, b = (json.load(open(p)) for p in sys.argv[1:3])
print(f"version: {a['version']} → {b['version']}; sequence: {a['sequence']} → {b['sequence']}")
print(f"Endorsement Policy сохранена (validation_parameter совпадает): {a['validation_parameter'] == b['validation_parameter']}")
PY

log "3.6 Обратная совместимость"
use_identity 1 Admin
echo "GetChaincodeInfo (новая функция): $(query $CC '{"Args":["GetChaincodeInfo"]}')"
query $CC '{"Args":["ReadBatch","BATCH-2026-001"]}' > "$A/batch001-after.json"
python3 - "$A/batch001-before.json" "$A/batch001-after.json" <<'PY'
import json, sys
a, b = (json.load(open(p)) for p in sys.argv[1:3])
print(f"Объект BATCH-2026-001, записанный v1.0, прочитан v2.0 без изменений: {a == b}")
print(f"  lastTxID={b['lastTxID'][:20]}..., status={b['status']}, schemaVersion в объекте: {b.get('schemaVersion', 'нет (объект v1.0)')}")
PY

use_identity 1 production
echo "-- старая операция CreateBatch с 6 аргументами (формат v1.0):"
invoke $CC '{"function":"CreateBatch","Args":["BATCH-2026-005","Ibuprofen 200 mg","D2026-05","8000","2026-10-01","2029-10-01"]}' \
  | grep -oE 'txid \[[0-9a-f]+\] committed with status \([A-Z_]+\) at localhost:7051'
use_identity 1 qa
echo "-- старая операция UpdateStatus на объекте v1.0 (BATCH-2026-002 REJECTED → RELEASED, ожидается отказ по правилам v1.0):"
invoke $CC '{"function":"UpdateStatus","Args":["BATCH-2026-002","RELEASED"]}' | grep -oE 'message:"[^"]+"' || true
use_identity 1 production
echo "-- новый формат CreateBatch (7-й аргумент storageCondition=2-8C):"
invoke $CC '{"function":"CreateBatch","Args":["BATCH-2026-006","Insulin aspart 100 IU/ml","E2026-06","2000","2026-10-05","2028-04-05","2-8C"]}' \
  | grep -oE 'txid \[[0-9a-f]+\] committed with status \([A-Z_]+\) at localhost:7051'

use_identity 2 logistics
echo "-- новая операция RecordTemperature на объекте v1.0 (держатель Org2, 6.5 °C при норме 15–25 °C):"
invoke $CC '{"function":"RecordTemperature","Args":["BATCH-2026-001","6.5"]}' \
  | grep -oE 'txid \[[0-9a-f]+\] committed with status \([A-Z_]+\) at localhost:9051'
invoke $CC '{"function":"RecordTemperature","Args":["BATCH-2026-001","21.0"]}' \
  | grep -oE 'txid \[[0-9a-f]+\] committed with status \([A-Z_]+\) at localhost:9051'
query $CC '{"Args":["ReadBatch","BATCH-2026-001"]}' | python3 -c '
import json, sys
b = json.load(sys.stdin)
print("BATCH-2026-001 после RecordTemperature: schemaVersion=%s storageCondition=%s excursions=%s readings=%s" % (
    b.get("schemaVersion"), b.get("storageCondition"), b.get("temperatureExcursions", 0),
    [(r["celsius"], r["inTolerance"]) for r in b.get("temperatureLog", [])]))'
use_identity 1 production
echo "-- RecordTemperature от не-держателя (Org1), ожидается отказ:"
invoke $CC '{"function":"RecordTemperature","Args":["BATCH-2026-001","20"]}' | grep -oE 'message:"[^"]+"' || true

use_identity 1 Admin
echo "-- GetBatchHistory BATCH-2026-001 (изменения v1.0 и v2.0):"
query $CC '{"Args":["GetBatchHistory","BATCH-2026-001"]}' > "$A/history.json"
python3 - "$A/history.json" <<'PY'
import json, sys
for h in json.load(open(sys.argv[1])):
    print("   %s  %s...  %-9s holder=%s" % (h["timestamp"], h["txId"][:16], h["status"], h["holderMSP"]))
PY
echo "-- GetAllBatches:"
query $CC '{"Args":["GetAllBatches"]}' | python3 "$NETWORK_DIR/scripts/fmt_batch.py"
