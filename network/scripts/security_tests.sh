#!/usr/bin/env bash
# Задание 2 (п. 6–7): конфиденциальные данные через transient + PDC и security-тесты
# для medicinebatch_secure.
source "$(dirname "$0")/common.sh"
set +e   # тесты ожидают ошибки команд; результат оценивается по выводу
CC=medicinebatch_secure
B=${BATCH_ID:-BATCH-S-001}
PASS=0; FAILN=0
RES="$RUNTIME/analysis/security-results.txt"; : > "$RES"
P1=(--peerAddresses "localhost:$PEER1_PORT" --tlsRootCertFiles "$PEER1_TLS_CA")

# Данные контроля качества (конфиденциальные)
QC_JSON='{"assayPercent":99.6,"impurityPercent":0.08,"dissolutionPercent":92.0,"microbiology":"COMPLIANT","labProtocol":"QC-2026-0917","analyst":"Ivanova A.A.","passed":true}'
QC_B64=$(printf '%s' "$QC_JSON" | base64 | tr -d '\n')

# t <id> <ожидание ok|deny> <описание> <org> <user> <команда...>
t() {
  local id=$1 expect=$2 desc=$3 org=$4 user=$5; shift 5
  use_identity "$org" "$user"
  local out rc=0
  out=$("$@" 2>&1) || rc=$?
  local got=ok; [[ $rc -ne 0 ]] && got=deny
  echo "$out" | grep -qE 'status:(500|4[0-9][0-9])|Error:' && got=deny
  local detail; detail=$(echo "$out" | grep -oE 'message:"[^"]+"|Error: [^\\]+' | head -1 | cut -c1-150)
  [[ $got == ok ]] && detail=$(echo "$out" | grep -oE 'committed with status \([A-Z_]+\)|payload:"[^"]{0,80}' | head -1)
  [[ -z $detail ]] && detail=$(echo "$out" | tail -1 | cut -c1-120)
  local verdict=PASS; [[ $got != "$expect" ]] && verdict=FAIL
  [[ $verdict == PASS ]] && PASS=$((PASS+1)) || FAILN=$((FAILN+1))
  printf '%s | %s | %s@org%s | ожидание=%s получено=%s | %s | %s\n' "$id" "$desc" "$user" "$org" "$expect" "$got" "$verdict" "$detail" | tee -a "$RES"
  LAST_OUT=$out
}
inv()  { peer chaincode invoke "${ORDERER_ARGS[@]}" -C "$CHANNEL" -n "$CC" "${PEER_ARGS[@]}" -c "$1" --waitForEvent; }
inv1() { peer chaincode invoke "${ORDERER_ARGS[@]}" -C "$CHANNEL" -n "$CC" "${P1[@]}" -c "$1" --waitForEvent "${@:2}"; }
qry()  { peer chaincode query -C "$CHANNEL" -n "$CC" -c "$1"; }
qry_on_org1_peer() { CORE_PEER_ADDRESS=localhost:$PEER1_PORT CORE_PEER_TLS_ROOTCERT_FILE=$PEER1_TLS_CA peer chaincode query -C "$CHANNEL" -n "$CC" -c "$1"; }

log "Подготовка: production@org1 создаёт $B"
t ST0 ok "Создание партии (production@Org1)" 1 production inv "{\"function\":\"CreateBatch\",\"Args\":[\"$B\",\"Insulin glargine 100 IU/ml\",\"S2026-11\",\"3000\",\"2026-10-10\",\"2028-04-10\"]}"

log "Security-тесты"
t ST1  deny "Admin-идентичность (OU=admin) выполняет бизнес-операцию" 1 Admin \
  inv "{\"function\":\"CreateBatch\",\"Args\":[\"BATCH-S-002\",\"Aspirin 100 mg\",\"S2\",\"10\",\"2026-10-10\",\"2027-10-10\"]}"
t ST2  deny "Пользователь Org1 без роли qa (clerk) выпускает партию" 1 clerk \
  inv "{\"function\":\"UpdateStatus\",\"Args\":[\"$B\",\"RELEASED\"]}"
t ST3  deny "Org2 выпускает партию (атака из medicinebatch_vuln)" 2 logistics \
  inv "{\"function\":\"UpdateStatus\",\"Args\":[\"$B\",\"RELEASED\"]}"
t ST4  deny "QA выпускает партию без результатов контроля качества (инвариант)" 1 qa \
  inv "{\"function\":\"UpdateStatus\",\"Args\":[\"$B\",\"RELEASED\"]}"
t ST5  deny "Результаты контроля переданы обычными аргументами, без transient" 1 qa \
  inv1 "{\"function\":\"SetPrivateDetails\",\"Args\":[\"$B\",$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$QC_JSON")]}"
t ST6  deny "Org2 записывает privateDetails (через peer Org1)" 2 logistics \
  inv1 "{\"function\":\"SetPrivateDetails\",\"Args\":[\"$B\"]}" --transient "{\"privateDetails\":\"$QC_B64\"}"
t ST7  ok   "QA Org1 записывает privateDetails через transient" 1 qa \
  inv1 "{\"function\":\"SetPrivateDetails\",\"Args\":[\"$B\"]}" --transient "{\"privateDetails\":\"$QC_B64\"}"
SET_TX=$(echo "$LAST_OUT" | grep -oE 'txid \[[0-9a-f]{64}' | head -1 | grep -oE '[0-9a-f]{64}')
QC_HASH=$(echo "$LAST_OUT" | grep -oE 'payload:"[0-9a-f]{64}"' | grep -oE '[0-9a-f]{64}')
echo "    SetPrivateDetails TxID=$SET_TX, sha256(privateDetails)=$QC_HASH"
t ST8  ok   "Org1 читает privateDetails" 1 qa qry "{\"Args\":[\"ReadPrivateDetails\",\"$B\"]}"
echo "    privateDetails (Org1): $(echo "$LAST_OUT" | grep -v INFO)"
t ST9  deny "Org2 читает privateDetails через свой peer" 2 logistics qry "{\"Args\":[\"ReadPrivateDetails\",\"$B\"]}"
t ST10 deny "Org2 читает privateDetails через peer Org1 (член коллекции)" 2 logistics \
  qry_on_org1_peer "{\"Args\":[\"ReadPrivateDetails\",\"$B\"]}"
t ST11 ok   "Org2 проверяет хеш предъявленного документа (верный)" 2 logistics \
  qry "{\"Args\":[\"VerifyPrivateDetailsHash\",\"$B\",\"$QC_HASH\"]}"
echo "    результат: $(echo "$LAST_OUT" | grep -v INFO)"
t ST12 ok   "Org2 проверяет хеш подменённого документа" 2 logistics \
  qry "{\"Args\":[\"VerifyPrivateDetailsHash\",\"$B\",\"$(printf '%064d' 0)\"]}"
echo "    результат: $(echo "$LAST_OUT" | grep -v INFO)"
t ST13 ok   "QA выпускает партию после контроля качества" 1 qa \
  inv "{\"function\":\"UpdateStatus\",\"Args\":[\"$B\",\"RELEASED\"]}"
t ST14 deny "Производитель подтверждает приёмку вместо дистрибьютора" 1 production \
  inv "{\"function\":\"ReceiveBatch\",\"Args\":[\"$B\"]}"
t ST15 ok   "Отгрузка дистрибьютору (production@Org1)" 1 production \
  inv "{\"function\":\"TransferBatch\",\"Args\":[\"$B\",\"Org2MSP\"]}"
t ST16 ok   "Приёмка партии (logistics@Org2)" 2 logistics \
  inv "{\"function\":\"ReceiveBatch\",\"Args\":[\"$B\"]}"
t ST17 deny "Недопустимый переход RECEIVED → RELEASED" 1 qa \
  inv "{\"function\":\"UpdateStatus\",\"Args\":[\"$B\",\"RELEASED\"]}"
t ST18 deny "Повторное создание партии с тем же ID (уникальность)" 1 production \
  inv "{\"function\":\"CreateBatch\",\"Args\":[\"$B\",\"Insulin glargine 100 IU/ml\",\"S2026-11\",\"3000\",\"2026-10-10\",\"2028-04-10\"]}"
echo "ИТОГО: PASS=$PASS FAIL=$FAILN" | tee -a "$RES"

log "Проверка: исходные данные контроля качества отсутствуют в аргументах и публичном ledger"
use_identity 1 Admin
peer chaincode query -C "$CHANNEL" -n qscc -c "{\"Args\":[\"GetBlockByTxID\",\"$CHANNEL\",\"$SET_TX\"]}" --hex 2>/dev/null \
  | python3 -c 'import sys; sys.stdout.buffer.write(bytes.fromhex(sys.stdin.read().strip()))' > "$RUNTIME/analysis/pdc.block"
configtxlator proto_decode --input "$RUNTIME/analysis/pdc.block" --type common.Block --output "$RUNTIME/analysis/pdc-block.json"
python3 - "$RUNTIME/analysis/pdc.block" "$RUNTIME/analysis/pdc-block.json" "$SET_TX" "$QC_HASH" <<'PY'
import base64, json, sys
raw, js, txid, qc_hash = open(sys.argv[1], "rb").read(), open(sys.argv[2]).read(), sys.argv[3], sys.argv[4]
b = json.loads(js)
env = next(e for e in b["data"]["data"] if e["payload"]["header"]["channel_header"]["tx_id"] == txid)
act = env["payload"]["data"]["actions"][0]["payload"]
args = [base64.b64decode(a).decode() for a in act["chaincode_proposal_payload"]["input"]["chaincode_spec"]["input"]["args"]]
print(f"Блок #{b['header']['number']}, TxID {txid}")
print(f"Аргументы транзакции в ledger: {args}")
print(f"Поле TransientMap в сохранённом proposal payload: {'TransientMap' in act['chaincode_proposal_payload'] and bool(act['chaincode_proposal_payload'].get('TransientMap'))}")
for marker in ["QC-2026-0917", "Ivanova", "99.6", "assayPercent"]:
    print(f"  поиск «{marker}»: в JSON блока — {'НАЙДЕНО' if marker in js else 'нет'}, в бинарном блоке — {'НАЙДЕНО' if marker.encode() in raw else 'нет'}")
def pb_fields(buf):
    """Минимальный разбор protobuf: [(номер поля, значение)]."""
    i, out = 0, []
    def varint():
        nonlocal i
        v = s = 0
        while True:
            c = buf[i]; i += 1
            v |= (c & 0x7F) << s; s += 7
            if c < 0x80:
                return v
    while i < len(buf):
        key = varint(); fn, wt = key >> 3, key & 7
        if wt == 0:
            out.append((fn, varint()))
        elif wt == 2:
            n = varint(); out.append((fn, buf[i:i + n])); i += n
        else:
            raise ValueError("wire type %d" % wt)
    return out

ext = act["action"]["proposal_response_payload"]["extension"]
for ns in ext["results"]["ns_rwset"]:
    for c in ns.get("collection_hashed_rwset", []):
        hr = c["hashed_rwset"]
        if isinstance(hr, str):          # HashedRWSet не декодируется configtxlator — разбираем вручную
            for fn, w in pb_fields(base64.b64decode(hr)):
                if fn != 2:                 # 2 = hashed_writes (KVWriteHash)
                    continue
                f = dict(pb_fields(w))
                kh, vh = f.get(1, b"").hex(), f.get(3, b"").hex()
                print(f"  hashed write [{ns['namespace']}/{c['collection_name']}]: key_hash={kh[:24]}..., value_hash={vh}")
                print(f"  value_hash совпадает с sha256(privateDetails), возвращённым chaincode: {vh == qc_hash}")
    pub = [w["key"] for w in ns["rwset"].get("writes", [])] if isinstance(ns["rwset"], dict) else []
    if pub:
        print(f"  публичные записи в [{ns['namespace']}]: {pub}")
PY
for o in 1 2; do
  hits=$(grep -rla "QC-2026-0917" "$RUNTIME/peer0.org$o/data/ledgersData/pvtdataStore" 2>/dev/null | wc -l)
  echo "  peer0.org$o pvtdataStore: файлов с «QC-2026-0917» — $hits"
done
