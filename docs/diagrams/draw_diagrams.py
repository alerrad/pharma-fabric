"""Схемы для отчёта ПР4: архитектура сети Fabric и жизненный цикл MedicineBatch."""
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyArrowPatch, FancyBboxPatch

plt.rcParams["font.family"] = "DejaVu Sans"
INK, MUTED = "#24324a", "#5d6b82"


def box(ax, x, y, w, h, title, body="", fc="#ffffff", ec=MUTED, lw=1.2, ts=8.6, bs=7.2, z=3):
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.02,rounding_size=0.6", fc=fc, ec=ec, lw=lw, zorder=z))
    if body:
        n = title.count("\n") + 1
        ax.text(x + w / 2, y + h - 0.7, title, ha="center", va="top", fontsize=ts, fontweight="bold", color=INK, zorder=z + 1)
        ax.text(x + w / 2, y + h - 0.9 - 1.55 * n, body, ha="center", va="top", fontsize=bs, color=MUTED, zorder=z + 1, linespacing=1.25)
    else:
        ax.text(x + w / 2, y + h / 2, title, ha="center", va="center", fontsize=ts, fontweight="bold", color=INK, zorder=z + 1)


def zone(ax, x, y, w, h, fc, ec, label, ls="-"):
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.02,rounding_size=1.0", fc=fc, ec=ec, lw=1.4, ls=ls, zorder=1))
    ax.text(x + 0.8, y + h - 0.6, label, ha="left", va="top", fontsize=9.8, fontweight="bold", color=INK, zorder=2)


def arrow(ax, x1, y1, x2, y2, label="", ls="-", color="#4a5670", style="-|>", rad=0.0, lx=0.4, ly=0.0, fs=7):
    ax.add_patch(FancyArrowPatch((x1, y1), (x2, y2), arrowstyle=style, mutation_scale=10, lw=1.05, color=color,
                                 linestyle=ls, zorder=6, connectionstyle=f"arc3,rad={rad}"))
    if label:
        ax.text((x1 + x2) / 2 + lx, (y1 + y2) / 2 + ly, label, fontsize=fs, color="#36425a", ha="left", va="center",
                zorder=7, bbox=dict(fc="white", ec="none", pad=0.4, alpha=0.92))


def architecture(path):
    fig, ax = plt.subplots(figsize=(17, 12.4))
    ax.set_xlim(0, 100); ax.set_ylim(0, 90); ax.axis("off")
    ax.text(50, 89, "Архитектура корпоративной сети Hyperledger Fabric 3.1.5 «PharmaChain»", ha="center", va="top",
            fontsize=15.5, fontweight="bold", color=INK)
    ax.text(50, 86.6, "Вариант 15 · Org1 — производитель · Org2 — дистрибьютор · бизнес-объект MedicineBatch · "
            "конфиденциальные данные — результаты контроля качества", ha="center", va="top", fontsize=9.5, color=MUTED)

    # ---------- клиенты
    zone(ax, 1, 74.5, 98, 10, "#f4f6f8", "#9aa7b8", "Клиентские приложения")
    box(ax, 15, 75.6, 21, 6.6, "peer CLI (Org1/Org2)", "lifecycle, channel, chaincode invoke/query;\nидентичности Admin / production / qa / logistics")
    box(ax, 40, 75.6, 20, 6.6, "gateway-client (Go)", "Fabric Gateway API: Evaluate, Endorse,\nSubmit, CommitStatus; подпись ECDSA")
    box(ax, 64, 75.6, 20, 6.6, "osnadmin / configtxgen", "Channel Participation API orderer;\nблок конфигурации канала")

    # ---------- организации
    zone(ax, 1, 25, 33, 48, "#eef2fb", "#8ea3d1", "Org1 — Производитель (Org1MSP)")
    zone(ax, 67, 25, 32, 48, "#f3effb", "#ad97da", "Org2 — Дистрибьютор (Org2MSP)")
    zone(ax, 36, 46, 29, 27, "#e8f5ef", "#6fbf98", "OrdererOrg (OrdererMSP)")

    for (x, ca, port, users) in [(2.5, "ca-org1", 7054, "Admin (OU=admin)\nproduction, qa, clerk\n(атрибут role в ecert)"),
                                  (68.5, "ca-org2", 8054, "Admin (OU=admin)\nlogistics\n(атрибут role в ecert)")]:
        cx = x if x < 50 else x + 6
        box(ax, cx, 62.5, 11, 8.2, f"Fabric CA {ca}", f":{port}, TLS;\nMSP и TLS-\nсертификаты", ts=8)
        box(ax, cx + 11.8, 62.5, 11, 8.2, "MSP + NodeOUs", users, ts=8, bs=6.8)

    for (x, name, port, ledger) in [
        (2.5, "peer0.org1.example.com", 7051, "Blockchain (блоки)\nWorld State — LevelDB\nHistory DB\nPrivate data store:\nprivateDetailsOrg1"),
        (68.5, "peer0.org2.example.com", 9051, "Blockchain (блоки)\nWorld State — LevelDB\nHistory DB\nтолько хеши privateDetails")]:
        box(ax, x, 26.5, 28.5, 34, "", fc="#ffffff", ec="#3d5a8c", lw=1.8)
        ax.text(x + 14.25, 59.6, f"{name} :{port}", ha="center", va="top", fontsize=9, fontweight="bold", color=INK, zorder=5)
        box(ax, x + 1, 50.5, 12.6, 7.3, "Fabric Gateway", "встроен в peer:\nendorse, submit,\ncommit status", fc="#f6f8fc", ts=8, bs=6.8, z=5)
        box(ax, x + 14.9, 50.5, 12.6, 7.3, "Endorser + Committer", "симуляция, VSCC,\nMVCC, фиксация\nблоков", fc="#f6f8fc", ts=8, bs=6.8, z=5)
        box(ax, x + 1, 37.2, 12.6, 12, "Ledger канала", ledger, fc="#f6f8fc", ts=8, bs=6.6, z=5)
        box(ax, x + 14.9, 37.2, 12.6, 12, "Chaincode (Go)", "medicinebatch 2.0\nmedicinebatch_vuln\nmedicinebatch_secure\nпроцессы, собранные\ngolang-native builder", fc="#fff8e8", ec="#d9a441", ts=8, bs=6.6, z=5)
        box(ax, x + 1, 27.6, 26.5, 8.4, "golang-native external builder", "detect → build (go build, vendor) → release → run;\nchaincode подключается к peer по mTLS (без Docker)", fc="#f6f8fc", ts=7.8, bs=6.6, z=5)

    box(ax, 37.5, 61.5, 26, 8.5, "Fabric CA ca-orderer :9054", "MSP и TLS-сертификаты orderer, Admin")
    box(ax, 37.5, 47.3, 26, 11.2, "orderer.example.com :7050", "Ordering Service: etcdraft (CFT)\nadmin :7053 (osnadmin), ops :9443\nBatchTimeout 2s, MaxMessageCount 10", fc="#ffffff", ec="#2f8f6a", lw=1.8)

    # ---------- канал
    zone(ax, 36, 29.5, 29, 14.8, "#fdf3e6", "#e0ad6a", "Channel «pharmachannel»")
    ax.text(50.5, 41.6, "Capabilities: Channel V3_0 · Orderer V2_0 ·\nApplication V2_5\n\n"
            "Endorsement Policy: AND('Org1MSP.peer','Org2MSP.peer')\n"
            "PDC privateDetailsOrg1: OR('Org1MSP.member'),\nmemberOnlyRead/Write, endorsement Org1",
            ha="center", va="top", fontsize=7.4, color=INK, zorder=3, linespacing=1.35)

    # ---------- стрелки
    arrow(ax, 26, 75.6, 28, 60.6)
    ax.text(26.6, 72.3, "proposal,\nquery", fontsize=7, color="#36425a", zorder=7, bbox=dict(fc="white", ec="none", pad=0.3))
    arrow(ax, 45, 75.6, 30.5, 60.6, rad=0.05)
    ax.text(36.6, 73.6, "1 Endorse / Submit /\nCommitStatus", fontsize=7, color="#36425a", zorder=7, bbox=dict(fc="white", ec="none", pad=0.3))
    arrow(ax, 66, 75.6, 63.6, 54)
    ax.text(64.3, 72.6, "channel\njoin", fontsize=7, color="#36425a", zorder=7, bbox=dict(fc="white", ec="none", pad=0.3))
    arrow(ax, 31, 54, 37.5, 53, "3 Submit", lx=-2.6, ly=2.2)
    arrow(ax, 68.5, 53, 63.5, 53, "deliver", ls="--", lx=-1, ly=1.8)
    arrow(ax, 31, 45.2, 68.5, 45.2, ls="--", color="#7a5bbf")
    ax.text(49.8, 45.2, "2 Gateway Org1 запрашивает endorsement у peer Org2 (политика AND)", fontsize=6.8, color="#5b3f9a",
            ha="center", va="center", zorder=7, bbox=dict(fc="white", ec="none", pad=0.3))
    arrow(ax, 31, 27.3, 68.5, 27.3, ls=":", style="<|-|>")
    ax.text(49.8, 27.3, "gossip между организациями (anchor peers): только хеши private data", fontsize=6.8,
            color="#36425a", ha="center", va="center", zorder=7, bbox=dict(fc="white", ec="none", pad=0.3))
    arrow(ax, 8, 62.5, 8, 60.6, ls=":")
    arrow(ax, 80, 62.5, 80, 60.6, ls=":")

    # ---------- стенд BFT
    zone(ax, 1, 3, 98, 20, "#fff5f5", "#e09a9a", "Отдельный стенд (задание 3.7): канал «bftchannel», Ordering Service SmartBFT, n = 3f + 1 = 4, f = 1", ls="--")
    for i in range(4):
        box(ax, 3 + i * 15.5, 7, 13.5, 10, f"orderer{i + 1}", f":{7150 + i * 10}  admin :{7153 + i * 10}\nconsenter ID {i + 1}\nподпись блоков", fc="#ffffff", ec="#c05c5c")
    box(ax, 66, 7, 14, 10, "peer0.org1 :7251", "проверяет подписи\n2f+1 orderer на блоке;\nmedicinebatch 1.0")
    box(ax, 82, 7, 15.5, 10, "Эксперимент", "отказ ведомого → OK\nотказ лидера → view change\n2 отказа (> f) → нет кворума\nвосстановление → догон", fc="#fffdf5", ec="#d9a441")
    for i in range(3):
        arrow(ax, 16.5 + i * 15.5, 12, 18.5 + i * 15.5, 12, style="<|-|>")
    arrow(ax, 63, 12, 66, 12)
    ax.text(64.5, 14.2, "deliver", fontsize=7, ha="center", color="#36425a")

    fig.savefig(path, dpi=190, bbox_inches="tight", facecolor="white")
    plt.close(fig)


def lifecycle(path):
    fig, ax = plt.subplots(figsize=(12, 4.3))
    ax.set_xlim(0, 100); ax.set_ylim(0, 36); ax.axis("off")
    S = {"CREATED": (2, 16, "#e7eefc"), "RELEASED": (26, 16, "#e3f4ea"), "SHIPPED": (50, 16, "#e3f4ea"),
         "RECEIVED": (74, 16, "#e3f4ea"), "REJECTED": (26, 1.5, "#fdeaea"), "RECALLED": (62, 1.5, "#fdeaea")}
    W, H = 16, 7
    for n, (x, y, c) in S.items():
        ax.add_patch(FancyBboxPatch((x, y), W, H, boxstyle="round,pad=0.02,rounding_size=1.5", fc=c, ec=MUTED,
                                    lw=2 if n in ("REJECTED", "RECALLED") else 1.3))
        ax.text(x + W / 2, y + H / 2, n, ha="center", va="center", fontsize=10.5, fontweight="bold", color=INK)

    def a(p1, p2, lab, lx=0, ly=3.2):
        arrow(ax, *p1, *p2)
        ax.text((p1[0] + p2[0]) / 2 + lx, (p1[1] + p2[1]) / 2 + ly, lab, fontsize=7.6, ha="center", color="#36425a",
                bbox=dict(fc="white", ec="none", pad=0.3) if lab else None)
    a((18, 19.5), (26, 19.5), "UpdateStatus\nOrg1 · qa*")
    a((42, 19.5), (50, 19.5), "TransferBatch\nOrg1 · production*")
    a((66, 19.5), (74, 19.5), "ReceiveBatch\nOrg2 · logistics*")
    a((10, 16), (26, 5), "UpdateStatus\n(QC не пройден)", lx=-7, ly=0.3)
    a((34, 16), (64, 8.5), "", ly=0)
    a((58, 16), (68, 8.5), "", ly=0)
    a((82, 16), (74, 8.5), "", ly=0)
    ax.text(81, 11.5, "UpdateStatus(RECALLED)\nOrg1 · qa*", fontsize=7.6, ha="left", color="#36425a")
    ax.text(50, 33.8, "Жизненный цикл MedicineBatch (* роль проверяется в medicinebatch_secure; в v1/v2 — только MSP)",
            ha="center", fontsize=11, fontweight="bold", color=INK)
    ax.text(10, 28.5, "CreateBatch · Org1 · production*", fontsize=7.6, ha="center", color="#36425a")
    arrow(ax, 10, 27.5, 10, 23)
    ax.text(50, 0.2, "REJECTED и RECALLED — терминальные; в secure RELEASED требует записанных privateDetails (инвариант)",
            ha="center", fontsize=8, color="#a33")
    fig.savefig(path, dpi=190, bbox_inches="tight", facecolor="white")
    plt.close(fig)


if __name__ == "__main__":
    architecture("architecture.png")
    lifecycle("lifecycle.png")
    print("ok")
