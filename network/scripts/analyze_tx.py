#!/usr/bin/env python3
"""Разбор транзакции по этапам Proposal → Endorsement → Ordering → Validation → Commit.
Источники: блок (qscc GetBlockByTxID, декодирован configtxlator) и журналы orderer/peer.
usage: analyze_tx.py <block.json> <txid> <logs_dir>"""
import base64, json, re, sys, os

block_file, txid, logs = sys.argv[1:4]
b = json.load(open(block_file))
num = int(b["header"]["number"])
idx, env = next((i, e) for i, e in enumerate(b["data"]["data"])
                if e["payload"]["header"]["channel_header"]["tx_id"] == txid)
pl = env["payload"]
ch, sh = pl["header"]["channel_header"], pl["header"]["signature_header"]
action = pl["data"]["actions"][0]
cpp = action["payload"]["chaincode_proposal_payload"]
args = [base64.b64decode(a).decode(errors="replace") for a in cpp["input"]["chaincode_spec"]["input"]["args"]]
prp = action["payload"]["action"]["proposal_response_payload"]
ext = prp["extension"]
def mspid_of(endorser):
    """endorser — base64(SerializedIdentity); поле 1 protobuf = mspid."""
    if isinstance(endorser, dict):
        return endorser.get("mspid")
    raw = base64.b64decode(endorser)
    ln, pos = 0, 1
    shift = 0
    while True:
        byte = raw[pos]; pos += 1
        ln |= (byte & 0x7F) << shift; shift += 7
        if byte < 0x80:
            break
    return raw[pos:pos + ln].decode()

endorsers = [mspid_of(e["endorser"]) for e in action["payload"]["action"]["endorsements"]]
flt = base64.b64decode(b["metadata"]["metadata"][2])
codes = {0: "VALID", 11: "MVCC_READ_CONFLICT", 10: "ENDORSEMENT_POLICY_FAILURE"}

def grep(path, pattern):
    if not os.path.exists(path):
        return []
    rx = re.compile(pattern)
    out = []
    for line in open(path, errors="replace"):
        line = re.sub(r"\x1b\[[0-9;]*m", "", line).rstrip()
        if rx.search(line):
            out.append(line)
    return out

print(f"TxID: {txid}")
print(f"1. Proposal:    клиент {sh['creator']['mspid']} подписал предложение {ch['timestamp']};"
      f" chaincode={ext['chaincode_id']['name']} v{ext['chaincode_id']['version']}, args={args}")
print(f"2. Endorsement: подтверждения от {endorsers} (политика AND('Org1MSP.peer','Org2MSP.peer'));"
      f" ответ chaincode: status={ext['response']['status']}")
for ns in ext["results"]["ns_rwset"]:
    rw = ns["rwset"]
    if not rw.get("reads") and not rw.get("writes"):
        continue
    for r in rw.get("reads", []):
        v = r.get("version") or {}
        print(f"     ReadSet  [{ns['namespace']}] key={r['key']} version=(block {v.get('block_num','-')}, tx {v.get('tx_num','-')})")
    for w in rw.get("writes", []):
        val = base64.b64decode(w.get("value", "")).decode(errors="replace")
        st = json.loads(val).get("status") if val.startswith("{") else val
        print(f"     WriteSet [{ns['namespace']}] key={w['key']} → status={st}")
ord_lines = grep(os.path.join(logs, "orderer.log"), rf"Writing block \[{num}\]")
print(f"3. Ordering:    orderer (Raft) включил транзакцию в блок #{num} (позиция {idx});"
      f" {ord_lines[0].split(' -> ')[-1] if ord_lines else ''}")
print(f"4. Validation:  код в TRANSACTIONS_FILTER блока = {flt[idx]} ({codes.get(flt[idx], 'INVALID')}); "
      "VSCC проверил политику подтверждения, MVCC — версии ReadSet")
for p in ("peer0.org1", "peer0.org2"):
    for line in grep(os.path.join(logs, f"{p}.log"), rf"Committed block \[{num}\]")[:1]:
        print(f"5. Commit:      {p}: {line.split(' -> ')[-1]}")
