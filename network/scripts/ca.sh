#!/usr/bin/env bash
# Запуск Fabric CA трёх организаций и выпуск идентичностей (MSP + TLS).
#   Org1 (Производитель)  — ca-org1,     порт 7054
#   Org2 (Дистрибьютор)   — ca-org2,     порт 8054
#   OrdererOrg            — ca-orderer,  порт 9054
# Пароли генерируются случайно и хранятся только в runtime/secrets.env (chmod 600).
source "$(dirname "$0")/common.sh"

mkdir -p "$RUNTIME" "$LOGS" "$ORGS_DIR"
umask 077
if [[ ! -f $SECRETS ]]; then
  {
    for v in CA_ORG1_ADMIN_PW CA_ORG2_ADMIN_PW CA_ORDERER_ADMIN_PW PEER_PW ORDERER_PW ADMIN_PW USER_PW; do
      echo "$v=$(openssl rand -hex 16)"
    done
  } > "$SECRETS"
fi
source "$SECRETS"
umask 022

start_ca() {   # <name> <port> <admin_pw>
  local name=$1 port=$2 pw=$3 home="$RUNTIME/ca/$1"
  mkdir -p "$home"
  log "Запуск $name на порту $port"
  (cd "$home" && nohup fabric-ca-server start \
      -b "admin:$pw" --home "$home" --port "$port" --ca.name "$name" \
      --tls.enabled --csr.cn "$name" --csr.hosts localhost --csr.hosts "$name" \
      --operations.listenaddress "127.0.0.1:$((port + 10000))" \
      > "$LOGS/$name.log" 2>&1 &)
  wait_port "$port" "$name"
  for _ in $(seq 1 20); do [[ -f $home/tls-cert.pem ]] && break; sleep 0.5; done
}

# NodeOU-конфигурация MSP: роли client / peer / admin / orderer определяются по OU сертификата
write_nodeous() {   # <msp_dir> <cacert_file_name>
  cat > "$1/config.yaml" <<EOF
NodeOUs:
  Enable: true
  ClientOUIdentifier:  { Certificate: cacerts/$2, OrganizationalUnitIdentifier: client }
  PeerOUIdentifier:    { Certificate: cacerts/$2, OrganizationalUnitIdentifier: peer }
  AdminOUIdentifier:   { Certificate: cacerts/$2, OrganizationalUnitIdentifier: admin }
  OrdererOUIdentifier: { Certificate: cacerts/$2, OrganizationalUnitIdentifier: orderer }
EOF
}

enroll_org() {   # <org_dir> <ca_name> <port> <admin_pw> <domain> <node_type: peer|orderer> <node_name>
  local dir=$1 ca=$2 port=$3 pw=$4 domain=$5 ntype=$6 node=$7
  local tlsca="$RUNTIME/ca/$ca/tls-cert.pem" url="localhost:$port"
  local cacert="localhost-$port-$ca.pem"
  export FABRIC_CA_CLIENT_HOME="$dir"
  mkdir -p "$dir"

  log "[$ca] enroll bootstrap admin"
  fabric-ca-client enroll -u "https://admin:$pw@$url" --caname "$ca" --tls.certfiles "$tlsca" -M "$dir/ca-admin-msp" >/dev/null 2>&1

  # MSP организации (только публичные сертификаты)
  mkdir -p "$dir/msp/cacerts" "$dir/msp/tlscacerts"
  cp "$dir/ca-admin-msp/cacerts/"* "$dir/msp/cacerts/$cacert"
  cp "$dir/ca-admin-msp/cacerts/"* "$dir/msp/tlscacerts/ca.crt"
  write_nodeous "$dir/msp" "$cacert"

  reg() { fabric-ca-client register --caname "$ca" -u "https://$url" --tls.certfiles "$tlsca" \
          -M "$dir/ca-admin-msp" "$@" >/dev/null 2>&1 || true; }

  # --- узел (peer/orderer): MSP + TLS
  reg --id.name "$node" --id.secret "$NODE_PW" --id.type "$ntype"
  local ndir="$dir/${ntype}s/$node.$domain"
  fabric-ca-client enroll -u "https://$node:$NODE_PW@$url" --caname "$ca" --tls.certfiles "$tlsca" \
      -M "$ndir/msp" --csr.hosts "$node.$domain" --csr.hosts localhost >/dev/null 2>&1
  write_nodeous "$ndir/msp" "$cacert"
  fabric-ca-client enroll -u "https://$node:$NODE_PW@$url" --caname "$ca" --tls.certfiles "$tlsca" \
      -M "$ndir/tls" --enrollment.profile tls --csr.hosts "$node.$domain" --csr.hosts localhost \
      --csr.hosts 127.0.0.1 >/dev/null 2>&1
  cp "$ndir/tls/tlscacerts/"* "$ndir/tls/ca.crt"
  cp "$ndir/tls/signcerts/"*  "$ndir/tls/server.crt"
  cp "$ndir/tls/keystore/"*   "$ndir/tls/server.key"
  ok "$node.$domain: MSP и TLS выпущены"
}

enroll_user() {   # <org_dir> <ca> <port> <domain> <user> <type> [attrs]
  local dir=$1 ca=$2 port=$3 domain=$4 user=$5 type=$6 attrs=${7:-}
  local tlsca="$RUNTIME/ca/$ca/tls-cert.pem" url="localhost:$port" cacert="localhost-$port-$ca.pem"
  local id="${user,,}-$domain"
  export FABRIC_CA_CLIENT_HOME="$dir"
  local extra=()
  [[ -n $attrs ]] && extra=(--id.attrs "$attrs")
  fabric-ca-client register --caname "$ca" -u "https://$url" --tls.certfiles "$tlsca" -M "$dir/ca-admin-msp" \
      --id.name "$id" --id.secret "$USER_PW" --id.type "$type" "${extra[@]}" >/dev/null 2>&1 || true
  local udir="$dir/users/$user@$domain"
  fabric-ca-client enroll -u "https://$id:$USER_PW@$url" --caname "$ca" --tls.certfiles "$tlsca" \
      -M "$udir/msp" >/dev/null 2>&1
  write_nodeous "$udir/msp" "$cacert"
  ok "$user@$domain ($type${attrs:+, $attrs})"
}

start_ca ca-org1    "$CA_ORG1_PORT"    "$CA_ORG1_ADMIN_PW"
start_ca ca-org2    "$CA_ORG2_PORT"    "$CA_ORG2_ADMIN_PW"
start_ca ca-orderer "$CA_ORDERER_PORT" "$CA_ORDERER_ADMIN_PW"

NODE_PW=$PEER_PW
O1="$ORGS_DIR/peerOrganizations/org1.example.com"
O2="$ORGS_DIR/peerOrganizations/org2.example.com"
OO="$ORGS_DIR/ordererOrganizations/example.com"

enroll_org "$O1" ca-org1 "$CA_ORG1_PORT" "$CA_ORG1_ADMIN_PW" org1.example.com peer peer0
enroll_user "$O1" ca-org1 "$CA_ORG1_PORT" org1.example.com Admin      admin
enroll_user "$O1" ca-org1 "$CA_ORG1_PORT" org1.example.com production client 'role=production:ecert'
enroll_user "$O1" ca-org1 "$CA_ORG1_PORT" org1.example.com qa         client 'role=qa:ecert'
enroll_user "$O1" ca-org1 "$CA_ORG1_PORT" org1.example.com clerk      client 'role=clerk:ecert'

enroll_org "$O2" ca-org2 "$CA_ORG2_PORT" "$CA_ORG2_ADMIN_PW" org2.example.com peer peer0
enroll_user "$O2" ca-org2 "$CA_ORG2_PORT" org2.example.com Admin      admin
enroll_user "$O2" ca-org2 "$CA_ORG2_PORT" org2.example.com logistics  client 'role=logistics:ecert'

NODE_PW=$ORDERER_PW
enroll_org "$OO" ca-orderer "$CA_ORDERER_PORT" "$CA_ORDERER_ADMIN_PW" example.com orderer orderer
enroll_user "$OO" ca-orderer "$CA_ORDERER_PORT" example.com Admin admin

# Ключи bootstrap-админа CA больше не нужны клиентским скриптам
chmod -R go-rwx "$RUNTIME/ca" "$ORGS_DIR"
ok "Fabric CA: идентичности выпущены"
