#!/usr/bin/env bash
# Полный прогон практической работы №4 (вариант 15) с сохранением журналов в reports/.
#   FABRIC_HOME=~/fabric ./run_all.sh
set -euo pipefail
cd "$(dirname "$0")"
export FABRIC_HOME="${FABRIC_HOME:-$HOME/fabric}"
R=reports; mkdir -p "$R/analysis"
step() { echo -e "\n\033[1;35m######## $1\033[0m"; }
run()  { local log=$1; shift; echo "\$ $*" > "$R/$log"; "$@" >> "$R/$log" 2>&1; echo "   → $R/$log"; }

step "Сборка клиента Fabric Gateway"
(cd client/gateway-client && go build -o ../bin/gateway-client .)

step "Задание 1: сеть, chaincode 1.0, транзакции, ledger"
run 01-network-up.log      bash network/scripts/network.sh up
run 01b-env-org1.log       bash -c 'source network/scripts/env_org1.sh && peer channel list 2>/dev/null && peer channel getinfo -c pharmachannel 2>/dev/null'
run 02-deploy-v1.log       bash network/scripts/deploy_cc.sh medicinebatch 1.0 1 chaincode/medicinebatch-v1
run 03-transactions-v1.log bash network/scripts/tx_v1.sh

step "Задание 2: уязвимая и защищённая версии, PDC, security-тесты"
run 04-deploy-vuln.log     bash network/scripts/deploy_cc.sh medicinebatch_vuln 1.0 1 chaincode/medicinebatch-vuln
run 06-deploy-secure.log   bash network/scripts/deploy_cc.sh medicinebatch_secure 1.0 1 chaincode/medicinebatch-secure chaincode/medicinebatch-secure/collections_config.json
run 05-attack-vuln.log     bash network/scripts/attack_vuln.sh
run 07-security-tests.log  bash network/scripts/security_tests.sh

step "Задание 3: обновление 1.0 → 2.0 и SmartBFT"
run 08-upgrade-v2.log      bash network/scripts/upgrade_v2.sh
cp network/runtime/analysis/*.txt network/runtime/analysis/*.json "$R/analysis/" 2>/dev/null || true
run 08b-network-stop.log   bash network/scripts/network.sh stop
run 09-bft-up.log          bash network-bft/bft.sh up
run 10-bft-test.log        bash network-bft/bft.sh test
run 10b-bft-down.log       bash network-bft/bft.sh down

# Журналы без ANSI-цветов
for f in "$R"/*.log; do sed -i -r 's/\x1B\[[0-9;]*[mK]//g' "$f"; done
step "Готово: журналы в $R/"
