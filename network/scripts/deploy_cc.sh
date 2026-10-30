#!/usr/bin/env bash
# Развёртывание / обновление chaincode через жизненный цикл Fabric:
#   Package → Install (Org1, Org2) → Approve (Org1, Org2) → Check Readiness → Commit → QueryCommitted
#
#   deploy_cc.sh <name> <version> <sequence> <source_dir> [collections_config.json]
# Политика подтверждения: обе организации — AND('Org1MSP.peer','Org2MSP.peer')
source "$(dirname "$0")/common.sh"

CC_NAME=$1; CC_VERSION=$2; CC_SEQUENCE=$3; CC_SRC=$(cd "$4" && pwd); COLLECTIONS=${5:-}
POLICY="AND('Org1MSP.peer','Org2MSP.peer')"
LABEL="${CC_NAME}_${CC_VERSION}"
PKG_DIR="$RUNTIME/packages"; mkdir -p "$PKG_DIR"
PKG="$PKG_DIR/$LABEL.tar.gz"

EXTRA=()
[[ -n $COLLECTIONS ]] && EXTRA=(--collections-config "$COLLECTIONS")

log "0. Зависимости Go (vendor) для $CC_SRC"
if [[ ! -d $CC_SRC/vendor ]]; then (cd "$CC_SRC" && GOFLAGS=-mod=mod go mod vendor); fi
(cd "$CC_SRC" && go vet . && echo "go vet: OK")

log "1. Package: label=$LABEL"
use_identity 1 Admin
peer lifecycle chaincode package "$PKG" --path "$CC_SRC" --lang golang --label "$LABEL"
PACKAGE_ID=$(peer lifecycle chaincode calculatepackageid "$PKG")
echo "PACKAGE_ID=$PACKAGE_ID"

for org in 1 2; do
  use_identity $org Admin
  if peer lifecycle chaincode queryinstalled --output json | grep -q "\"$PACKAGE_ID\""; then
    log "2. Install на peer0.org$org: уже установлен"
  else
    log "2. Install на peer0.org$org (сборка golang-native builder)"
    peer lifecycle chaincode install "$PKG"
  fi
done
use_identity 2 Admin
peer lifecycle chaincode queryinstalled

for org in 1 2; do
  use_identity $org Admin
  log "3. Approve for Org${org}MSP: version=$CC_VERSION sequence=$CC_SEQUENCE"
  peer lifecycle chaincode approveformyorg "${ORDERER_ARGS[@]}" --channelID "$CHANNEL" --name "$CC_NAME" \
    --version "$CC_VERSION" --package-id "$PACKAGE_ID" --sequence "$CC_SEQUENCE" \
    --signature-policy "$POLICY" "${EXTRA[@]}" --waitForEvent
done

log "4. Check commit readiness"
peer lifecycle chaincode checkcommitreadiness --channelID "$CHANNEL" --name "$CC_NAME" \
  --version "$CC_VERSION" --sequence "$CC_SEQUENCE" --signature-policy "$POLICY" "${EXTRA[@]}" --output json

log "5. Commit"
use_identity 1 Admin
peer lifecycle chaincode commit "${ORDERER_ARGS[@]}" --channelID "$CHANNEL" --name "$CC_NAME" \
  --version "$CC_VERSION" --sequence "$CC_SEQUENCE" --signature-policy "$POLICY" "${EXTRA[@]}" \
  "${PEER_ARGS[@]}" --waitForEvent

log "6. Query committed"
peer lifecycle chaincode querycommitted --channelID "$CHANNEL" --name "$CC_NAME"
peer lifecycle chaincode querycommitted --channelID "$CHANNEL" --name "$CC_NAME" --output json
ok "$CC_NAME $CC_VERSION (sequence $CC_SEQUENCE) зафиксирован в канале $CHANNEL"
