"""Формирует «скриншоты» терминала из реальных журналов прогона (reports/*.log)."""
import os, re, subprocess, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
R = os.path.join(ROOT, "reports")
OUT = os.path.dirname(os.path.abspath(__file__))


def log(name):
    t = open(os.path.join(R, name), encoding="utf-8").read()
    t = re.sub(r"\x1b\[[0-9;]*m", "", t)
    t = t.replace(ROOT, "~/pharma-fabric").replace(os.path.expanduser("~/fabric"), "~/fabric")
    out = []
    for ln in t.split("\n"):
        if not ln.strip() or "InitCmdFactory" in ln or "submitInstallProposal -> Installed remotely" in ln:
            continue
        ln = re.sub(r"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+ \+\d\d \w+ (INFO|WARN) \[[\w.]+\] \w+ -> ", "", ln)
        out.append(ln)
    return out


def between(lines, start, end=None):
    res, on = [], False
    for ln in lines:
        if start in ln:
            on = True
        elif end and end in ln and on:
            break
        if on:
            res.append(ln)
    return res


def render(name, title, lines):
    lines = [re.sub(r"\b([0-9a-f]{16})[0-9a-f]{48}\b", r"\1…", l) for l in lines]
    lines = [re.sub(r", Endorsement Plugin: escc, Validation Plugin: vscc", "", l) for l in lines]
    p = subprocess.run([sys.executable, os.path.join(OUT, "render_terminal.py"), os.path.join(OUT, name), title],
                       input="\n".join(lines), text=True)
    assert p.returncode == 0


# 1. Сеть и идентичность Org1
up = log("01-network-up.log")
env = log("01b-env-org1.log")
s1 = ["$ ./network/scripts/network.sh up"] + [l for l in up if l.startswith(("✔", "Status"))][:12] + \
     ["$ source network/scripts/env_org1.sh && peer channel list && peer channel getinfo -c pharmachannel"] + env[1:]
render("s1-network.png", "Задание 1.1–1.2: Fabric CA, узлы, канал, идентичность Admin@org1", s1)

# 2. Развёртывание chaincode 1.0
dep = log("02-deploy-v1.log")
s2 = [l for l in dep if re.search(r"^==>|PACKAGE_ID|Package ID|txid|\"Org[12]MSP\"|Version:|✔", l)]
render("s2-deploy-v1.png", "Задание 1.4: жизненный цикл medicinebatch 1.0 (sequence 1)", s2)

# 3. Транзакции, MVCC и разбор T4
tx = log("03-transactions-v1.log")
s3 = between(tx, "==> T4 TransferBatch", "==> T5") + between(tx, "==> T8/T9", "==> Проверка валидации") + \
     between(tx, "==> Анализ транзакции T4", "T1 CreateBatch")
render("s3-tx.png", "Задание 1.5: транзакция через Fabric Gateway и демонстрация MVCC", s3)

# 4. Ledger и состояние
s4 = between(tx, "$ GetAllBatches", "==> Анализ транзакции")
render("s4-ledger.png", "Задание 1.6–1.7: состояние объектов и ledger канала", s4)

# 5. Атака
att = log("05-attack-vuln.log")
s5 = [l for l in att if not l.startswith("     ReadSet  [_lifecycle]")]
render("s5-attack.png", "Задание 2.3: воспроизведение уязвимости medicinebatch_vuln от имени Org2", s5[1:])

# 6. PDC и проверка ledger
sec = log("07-security-tests.log")
s6 = between(sec, "ST7 ", "ST9 ")[:4] + between(sec, "ST9 ", "ST11 ")[:2] + \
     between(sec, "==> Проверка: исходные данные", None)
s6 = [re.sub(r"Error: endorsement failure during (query|invoke)\. response: status:500 ", "", l) for l in s6]
render("s6-pdc.png", "Задание 2.6: transient + Private Data Collection, проверка публичного ledger", s6)

# 7. Обновление
upg = log("08-upgrade-v2.log")
keep = r"^==> 3\.|Version:|Package ID: medicinebatch_[12]|version:|Endorsement Policy|GetChaincodeInfo|прочитан v2|schemaVersion|^--|txid|message:|^   20"
s7 = [l for l in upg if re.search(keep, l) and "Approve" not in l and "INFO" not in l]
seen, s7u = set(), []
for l in s7:
    if l.startswith("Package ID") and l in seen:
        continue
    seen.add(l); s7u.append(l)
s7u = [l for l in s7u if l != "-- GetAllBatches:"]
render("s7-upgrade.png", "Задание 3.1–3.6: обновление medicinebatch 1.0/seq 1 → 2.0/seq 2", s7u)

# 8. SmartBFT
bft = log("10-bft-test.log")
s8 = [l for l in bft[1:] if "LoadViewChange" not in l]
s8 = [re.sub(r"\"currentBlockHash\".*$", "…}", l) for l in s8 if "Nothing to restore" not in l]
merged, buf = [], []
for l in s8 + ["<end>"]:
    m = re.match(r"\s+orderer(\d) \(:\d+\): height=(\S+)", l)
    if m:
        buf.append(f"o{m.group(1)}={m.group(2)}")
        continue
    if buf:
        merged.append("   высота ledger orderer: " + ", ".join(buf)); buf = []
    if l != "<end>":
        merged.append(l)
s8 = merged
render("s8-bft.png", "Задание 3.7: стенд SmartBFT — отказ и восстановление orderer", s8)
print("ok")
