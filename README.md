# PharmaChain — Hyperledger Fabric 3.1 (ПР №4, вариант 15)

Корпоративная сеть Hyperledger Fabric для учёта партий лекарственных препаратов:
**Org1 — производитель**, **Org2 — дистрибьютор**, бизнес-объект **MedicineBatch**,
конфиденциальные данные — **результаты контроля качества** (Private Data Collection).

Сеть работает **без Docker**: узлы запускаются из официальных бинарных файлов Fabric,
Go-chaincode собирает и запускает сам peer через external builder `builders/golang-native`.

## Требования

| Компонент | Версия |
|---|---|
| Linux / WSL2 (Ubuntu 22.04+) | — |
| Hyperledger Fabric (peer, orderer, configtxgen, osnadmin, cryptogen) | 3.1.5 |
| Fabric CA (fabric-ca-server, fabric-ca-client) | 1.5.22 |
| Go | ≥ 1.22 |
| python3 + PyYAML, openssl, curl | — |

```bash
sudo apt install -y python3 python3-yaml openssl curl
mkdir -p ~/fabric && cd ~/fabric
curl -sSL https://github.com/hyperledger/fabric/releases/download/v3.1.5/hyperledger-fabric-linux-amd64-3.1.5.tar.gz | tar xz
curl -sSL https://github.com/hyperledger/fabric-ca/releases/download/v1.5.22/hyperledger-fabric-ca-linux-amd64-1.5.22.tar.gz | tar xz
```

## Запуск всего сценария

```bash
FABRIC_HOME=~/fabric ./run_all.sh        # ~10 минут, журналы — в reports/
```

`run_all.sh` последовательно выполняет:

| Шаг | Скрипт | Журнал |
|---|---|---|
| CA, идентичности, orderer (Raft), 2 peer, канал `pharmachannel` | `network/scripts/network.sh up` | `01-network-up.log` |
| CLI от имени Admin@org1 | `source network/scripts/env_org1.sh` | `01b-env-org1.log` |
| medicinebatch 1.0 / sequence 1, политика AND | `network/scripts/deploy_cc.sh` | `02-deploy-v1.log` |
| Транзакции T1–T9 (T4 — через Fabric Gateway), MVCC, ledger | `network/scripts/tx_v1.sh` | `03-transactions-v1.log` |
| Уязвимая версия `medicinebatch_vuln` | `deploy_cc.sh` | `04-deploy-vuln.log` |
| Защищённая версия `medicinebatch_secure` + PDC | `deploy_cc.sh … collections_config.json` | `06-deploy-secure.log` |
| Атака от имени Org2 | `network/scripts/attack_vuln.sh` | `05-attack-vuln.log` |
| 19 security-тестов, проверка блока на утечку данных | `network/scripts/security_tests.sh` | `07-security-tests.log` |
| Обновление 1.0/seq 1 → 2.0/seq 2, совместимость | `network/scripts/upgrade_v2.sh` | `08-upgrade-v2.log` |
| Стенд SmartBFT (4 orderer), отказы и восстановление | `network-bft/bft.sh up / test` | `09-…`, `10-bft-test.log` |

Отдельные шаги можно запускать вручную в том же порядке.
Остановка: `network/scripts/network.sh down`, `network-bft/bft.sh down`.

## Структура

```
chaincode/medicinebatch-v1      chaincode 1.0 (7 операций)
chaincode/medicinebatch-v2      chaincode 2.0 (совместим с 1.0, + RecordTemperature, GetBatchHistory)
chaincode/medicinebatch-vuln    учебная уязвимая версия: нет проверки MSP в UpdateStatus
chaincode/medicinebatch-secure  защищённая версия + collections_config.json (PDC privateDetailsOrg1)
client/gateway-client           клиент Fabric Gateway (Endorse → Submit → CommitStatus)
builders/golang-native          external builder: сборка и запуск Go-chaincode без Docker
network/                        configtx.yaml и скрипты основной сети
network-bft/                    стенд SmartBFT (cryptogen, configtx, bft.sh)
reports/                        журналы прогона
docs/                           схемы и изображения для отчёта
```

## Безопасность

Каталоги `network/runtime/` и `network-bft/runtime/` (ключи, сертификаты, ledger, `secrets.env`
со случайными паролями CA) создаются при запуске и **не должны попадать в репозиторий** —
они перечислены в `.gitignore`.
