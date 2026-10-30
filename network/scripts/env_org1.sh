#!/usr/bin/env bash
# Задание 1.2: настройка peer CLI на административную идентичность Org1.
#   source network/scripts/env_org1.sh
# После этого доступны команды peer channel ..., peer lifecycle ..., peer chaincode ...
_d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set +eu; source "$_d/common.sh"; set +eu +o pipefail
use_identity 1 Admin
export ORDERER_CA PEER1_TLS_CA PEER2_TLS_CA CHANNEL
echo "FABRIC_CFG_PATH=$FABRIC_CFG_PATH"
echo "CORE_PEER_LOCALMSPID=$CORE_PEER_LOCALMSPID"
echo "CORE_PEER_ADDRESS=$CORE_PEER_ADDRESS"
echo "CORE_PEER_MSPCONFIGPATH=$CORE_PEER_MSPCONFIGPATH"
echo "CORE_PEER_TLS_ROOTCERT_FILE=$CORE_PEER_TLS_ROOTCERT_FILE"
