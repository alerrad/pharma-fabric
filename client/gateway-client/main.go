// gateway-client — клиентское приложение, работающее через Fabric Gateway (встроен в peer с 2.4).
// Показывает этапы транзакции: Proposal → Endorse → Submit (Ordering) → CommitStatus (Validation/Commit).
//
// Пример:
//
//	gateway-client -peer localhost:7051 -tlsca peer-tls-ca.crt -msp Org1MSP \
//	  -cert user/msp/signcerts/cert.pem -keydir user/msp/keystore \
//	  -channel pharmachannel -chaincode medicinebatch -fn TransferBatch -args BATCH-2026-001,Org2MSP
package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/asn1"
	"encoding/hex"
	"encoding/pem"
	"flag"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/hyperledger/fabric-protos-go-apiv2/common"
	"github.com/hyperledger/fabric-protos-go-apiv2/gateway"
	"github.com/hyperledger/fabric-protos-go-apiv2/msp"
	"github.com/hyperledger/fabric-protos-go-apiv2/peer"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"
)

type identity struct {
	mspID   string
	certPEM []byte
	key     *ecdsa.PrivateKey
}

func (id *identity) serialized() []byte {
	b, err := proto.Marshal(&msp.SerializedIdentity{Mspid: id.mspID, IdBytes: id.certPEM})
	must(err)
	return b
}

// sign — ECDSA P-256/SHA-256, подпись в DER с нормализацией low-S (требование Fabric).
func (id *identity) sign(msg []byte) []byte {
	digest := sha256.Sum256(msg)
	r, s, err := ecdsa.Sign(rand.Reader, id.key, digest[:])
	must(err)
	half := new(big.Int).Rsh(elliptic.P256().Params().N, 1)
	if s.Cmp(half) > 0 {
		s.Sub(elliptic.P256().Params().N, s)
	}
	der, err := asn1.Marshal(struct{ R, S *big.Int }{r, s})
	must(err)
	return der
}

func loadIdentity(mspID, certPath, keyDir string) *identity {
	certPEM, err := os.ReadFile(certPath)
	must(err)
	entries, err := os.ReadDir(keyDir)
	must(err)
	if len(entries) == 0 {
		fail("no key in %s", keyDir)
	}
	keyPEM, err := os.ReadFile(filepath.Join(keyDir, entries[0].Name()))
	must(err)
	block, _ := pem.Decode(keyPEM)
	k, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	must(err)
	return &identity{mspID, certPEM, k.(*ecdsa.PrivateKey)}
}

// newProposal строит подписанное предложение транзакции (Proposal).
func newProposal(id *identity, channel, cc string, args []string, transient map[string][]byte) (*peer.SignedProposal, string) {
	nonce := make([]byte, 24)
	_, err := rand.Read(nonce)
	must(err)
	creator := id.serialized()
	h := sha256.Sum256(append(append([]byte{}, nonce...), creator...))
	txID := hex.EncodeToString(h[:])

	ext, err := proto.Marshal(&peer.ChaincodeHeaderExtension{ChaincodeId: &peer.ChaincodeID{Name: cc}})
	must(err)
	chHdr, err := proto.Marshal(&common.ChannelHeader{
		Type: int32(common.HeaderType_ENDORSER_TRANSACTION), ChannelId: channel, TxId: txID,
		Timestamp: timestamppb.Now(), Extension: ext,
	})
	must(err)
	sigHdr, err := proto.Marshal(&common.SignatureHeader{Creator: creator, Nonce: nonce})
	must(err)
	hdr, err := proto.Marshal(&common.Header{ChannelHeader: chHdr, SignatureHeader: sigHdr})
	must(err)
	input := &peer.ChaincodeInput{}
	for _, a := range args {
		input.Args = append(input.Args, []byte(a))
	}
	spec, err := proto.Marshal(&peer.ChaincodeInvocationSpec{ChaincodeSpec: &peer.ChaincodeSpec{
		Type: peer.ChaincodeSpec_GOLANG, ChaincodeId: &peer.ChaincodeID{Name: cc}, Input: input}})
	must(err)
	payload, err := proto.Marshal(&peer.ChaincodeProposalPayload{Input: spec, TransientMap: transient})
	must(err)
	propBytes, err := proto.Marshal(&peer.Proposal{Header: hdr, Payload: payload})
	must(err)
	return &peer.SignedProposal{ProposalBytes: propBytes, Signature: id.sign(propBytes)}, txID
}

// describeEndorsements извлекает из подготовленной транзакции подтверждения и ответ chaincode.
func describeEndorsements(env *common.Envelope) (msps []string, status int32, payload string) {
	var pl common.Payload
	must(proto.Unmarshal(env.Payload, &pl))
	var tx peer.Transaction
	must(proto.Unmarshal(pl.Data, &tx))
	var cap peer.ChaincodeActionPayload
	must(proto.Unmarshal(tx.Actions[0].Payload, &cap))
	for _, e := range cap.Action.Endorsements {
		var sid msp.SerializedIdentity
		must(proto.Unmarshal(e.Endorser, &sid))
		msps = append(msps, sid.Mspid)
	}
	var prp peer.ProposalResponsePayload
	must(proto.Unmarshal(cap.Action.ProposalResponsePayload, &prp))
	var act peer.ChaincodeAction
	must(proto.Unmarshal(prp.Extension, &act))
	return msps, act.Response.Status, string(act.Response.Payload)
}

func main() {
	peerAddr := flag.String("peer", "localhost:7051", "адрес peer (Gateway)")
	tlsCA := flag.String("tlsca", "", "TLS CA peer")
	mspID := flag.String("msp", "Org1MSP", "MSP ID клиента")
	certPath := flag.String("cert", "", "сертификат клиента (signcerts)")
	keyDir := flag.String("keydir", "", "каталог закрытого ключа клиента (keystore)")
	channel := flag.String("channel", "pharmachannel", "канал")
	cc := flag.String("chaincode", "medicinebatch", "chaincode")
	fn := flag.String("fn", "", "функция chaincode")
	argStr := flag.String("args", "", "аргументы через запятую")
	evaluate := flag.Bool("evaluate", false, "только чтение (Evaluate), без фиксации")
	flag.Parse()

	id := loadIdentity(*mspID, *certPath, *keyDir)
	creds, err := credentials.NewClientTLSFromFile(*tlsCA, "")
	must(err)
	conn, err := grpc.NewClient(*peerAddr, grpc.WithTransportCredentials(creds))
	must(err)
	defer conn.Close()
	gw := gateway.NewGatewayClient(conn)
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	args := []string{*fn}
	if *argStr != "" {
		args = append(args, strings.Split(*argStr, ",")...)
	}
	t0 := time.Now()
	sp, txID := newProposal(id, *channel, *cc, args, nil)
	fmt.Printf("[1 Proposal]    TxID=%s; клиент %s подписал предложение %s%v (%d байт)\n", txID, id.mspID, *cc, args, len(sp.ProposalBytes))

	if *evaluate {
		r, err := gw.Evaluate(ctx, &gateway.EvaluateRequest{TransactionId: txID, ChannelId: *channel, ProposedTransaction: sp})
		must(err)
		fmt.Printf("[Evaluate]      status=%d payload=%s\n", r.Result.Status, r.Result.Payload)
		return
	}

	t1 := time.Now()
	er, err := gw.Endorse(ctx, &gateway.EndorseRequest{TransactionId: txID, ChannelId: *channel, ProposedTransaction: sp})
	must(err)
	msps, st, pl := describeEndorsements(er.PreparedTransaction)
	if len(pl) > 90 {
		pl = pl[:90] + "…"
	}
	fmt.Printf("[2 Endorsement] Gateway собрал подтверждения %v за %v; chaincode status=%d, payload=%s\n", msps, time.Since(t1).Round(time.Millisecond), st, pl)

	env := er.PreparedTransaction
	env.Signature = id.sign(env.Payload)
	t2 := time.Now()
	_, err = gw.Submit(ctx, &gateway.SubmitRequest{TransactionId: txID, ChannelId: *channel, PreparedTransaction: env})
	must(err)
	fmt.Printf("[3 Ordering]    подписанная транзакция передана Gateway в Ordering Service (%v)\n", time.Since(t2).Round(time.Millisecond))

	req, err := proto.Marshal(&gateway.CommitStatusRequest{TransactionId: txID, ChannelId: *channel, Identity: id.serialized()})
	must(err)
	t3 := time.Now()
	cs, err := gw.CommitStatus(ctx, &gateway.SignedCommitStatusRequest{Request: req, Signature: id.sign(req)})
	must(err)
	fmt.Printf("[4 Validation]  результат проверки: %s (VSCC + MVCC)\n", cs.Result)
	fmt.Printf("[5 Commit]      транзакция в блоке #%d; ожидание фиксации %v; всего %v\n", cs.BlockNumber, time.Since(t3).Round(time.Millisecond), time.Since(t0).Round(time.Millisecond))
	if cs.Result != peer.TxValidationCode_VALID {
		os.Exit(3)
	}
}

func must(err error) {
	if err != nil {
		fail("%v", err)
	}
}

func fail(f string, a ...any) {
	fmt.Fprintf(os.Stderr, "ERROR: "+f+"\n", a...)
	os.Exit(1)
}
