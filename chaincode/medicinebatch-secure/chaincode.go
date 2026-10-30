// Chaincode MedicineBatch (SECURE) — защищённая версия, имя в канале: medicinebatch_secure.
// Практическая работа №4, вариант 15 «Фармацевтика».
//
// Меры защиты относительно v1.0 и medicinebatch_vuln:
//   - проверка MSP организации и типа идентичности (только OU=client, не admin/peer);
//   - проверка полномочий пользователя по атрибуту сертификата Fabric CA "role":
//     Org1: production (создание, отгрузка), qa (решения по качеству, privateDetails);
//     Org2: logistics (приёмка);
//   - явная таблица допустимых переходов + инварианты, проверяемые перед каждой записью;
//   - разделение обязанностей: партию не может выпустить тот же пользователь, что её создал;
//   - результаты контроля качества (privateDetails) передаются только через transient field
//     и хранятся в Private Data Collection, доступной лишь Org1 (GetTransient, PutPrivateData,
//     GetPrivateData); в публичном ledger остаётся только хеш SHA-256.
package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/hyperledger/fabric-chaincode-go/v2/pkg/cid"
	"github.com/hyperledger/fabric-chaincode-go/v2/shim"
	"github.com/hyperledger/fabric-protos-go-apiv2/peer"
)

const (
	ManufacturerMSP = "Org1MSP"
	DistributorMSP  = "Org2MSP"
	docType         = "medicineBatch"
	dateLayout      = "2006-01-02"
	maxQuantity     = 10_000_000

	// Private Data Collection (см. collections_config.json): члены — только Org1MSP.
	PrivateCollection = "privateDetailsOrg1"
	TransientKey      = "privateDetails"

	RoleProduction = "production"
	RoleQA         = "qa"
	RoleLogistics  = "logistics"
)

const (
	StatusCreated  = "CREATED"
	StatusReleased = "RELEASED"
	StatusRejected = "REJECTED"
	StatusShipped  = "SHIPPED"
	StatusReceived = "RECEIVED"
	StatusRecalled = "RECALLED"
)

var statusTransitions = map[string][]string{
	StatusCreated:  {StatusReleased, StatusRejected},
	StatusReleased: {StatusRecalled},
	StatusShipped:  {StatusRecalled},
	StatusReceived: {StatusRecalled},
}

// Какая организация должна быть держателем партии в каждом статусе (инвариант).
var holderByStatus = map[string]string{
	StatusCreated: ManufacturerMSP, StatusReleased: ManufacturerMSP, StatusRejected: ManufacturerMSP,
	StatusShipped: DistributorMSP, StatusReceived: DistributorMSP,
}

var (
	idPattern  = regexp.MustCompile(`^[A-Z0-9][A-Z0-9-]{2,63}$`)
	lotPattern = regexp.MustCompile(`^[A-Za-z0-9-]{1,32}$`)
	textSafe   = regexp.MustCompile(`^[\p{L}\p{N} .,()/%+-]{1,128}$`)
)

type MedicineBatch struct {
	DocType         string `json:"docType"`
	ID              string `json:"id"`
	MedicineName    string `json:"medicineName"`
	LotNumber       string `json:"lotNumber"`
	Quantity        int    `json:"quantity"`
	ManufactureDate string `json:"manufactureDate"`
	ExpiryDate      string `json:"expiryDate"`
	ManufacturerMSP string `json:"manufacturerMSP"`
	HolderMSP       string `json:"holderMSP"`
	Status          string `json:"status"`
	CreatedBy       string `json:"createdBy"`
	CreatedAt       string `json:"createdAt"`
	UpdatedAt       string `json:"updatedAt"`
	LastTxID        string `json:"lastTxID"`
	ReleasedBy      string `json:"releasedBy,omitempty"`
}

// PrivateDetails — результаты контроля качества (конфиденциальные данные Org1).
type PrivateDetails struct {
	BatchID            string  `json:"batchId"`
	AssayPercent       float64 `json:"assayPercent"`       // содержание действующего вещества, %
	ImpurityPercent    float64 `json:"impurityPercent"`    // примеси, %
	DissolutionPercent float64 `json:"dissolutionPercent"` // растворение за 30 мин, %
	Microbiology       string  `json:"microbiology"`       // COMPLIANT / NON_COMPLIANT
	LabProtocol        string  `json:"labProtocol"`
	Analyst            string  `json:"analyst"`
	Passed             bool    `json:"passed"`
	RecordedBy         string  `json:"recordedBy,omitempty"`
	RecordedAt         string  `json:"recordedAt,omitempty"`
}

type MedicineBatchContract struct{}

func (c *MedicineBatchContract) Init(stub shim.ChaincodeStubInterface) *peer.Response {
	return shim.Success(nil)
}

func (c *MedicineBatchContract) Invoke(stub shim.ChaincodeStubInterface) *peer.Response {
	fn, args := stub.GetFunctionAndParameters()
	handlers := map[string]func(shim.ChaincodeStubInterface, []string) ([]byte, error){
		"CreateBatch":              c.CreateBatch,
		"ReadBatch":                c.ReadBatch,
		"UpdateStatus":             c.UpdateStatus,
		"TransferBatch":            c.TransferBatch,
		"ReceiveBatch":             c.ReceiveBatch,
		"BatchExists":              c.BatchExistsTx,
		"GetAllBatches":            c.GetAllBatches,
		"SetPrivateDetails":        c.SetPrivateDetails,
		"ReadPrivateDetails":       c.ReadPrivateDetails,
		"VerifyPrivateDetailsHash": c.VerifyPrivateDetailsHash,
	}
	h, ok := handlers[fn]
	if !ok {
		return shim.Error(fmt.Sprintf("unknown function %q", fn))
	}
	payload, err := h(stub, args)
	if err != nil {
		return shim.Error(err.Error())
	}
	return shim.Success(payload)
}

// ======================================================= бизнес-операции

// CreateBatch(id, medicineName, lotNumber, quantity, manufactureDate, expiryDate) — Org1, role=production.
func (c *MedicineBatchContract) CreateBatch(stub shim.ChaincodeStubInterface, args []string) ([]byte, error) {
	if len(args) != 6 {
		return nil, fmt.Errorf("CreateBatch expects 6 arguments, got %d", len(args))
	}
	caller, err := authorize(stub, ManufacturerMSP, RoleProduction)
	if err != nil {
		return nil, err
	}
	id, name, lot := strings.TrimSpace(args[0]), strings.TrimSpace(args[1]), strings.TrimSpace(args[2])
	if !idPattern.MatchString(id) {
		return nil, fmt.Errorf("invalid batch id %q", id)
	}
	if !textSafe.MatchString(name) || len([]rune(name)) < 2 {
		return nil, fmt.Errorf("medicineName must be 2..128 safe characters")
	}
	if !lotPattern.MatchString(lot) {
		return nil, fmt.Errorf("invalid lotNumber %q", lot)
	}
	qty, err := strconv.Atoi(args[3])
	if err != nil || qty <= 0 || qty > maxQuantity {
		return nil, fmt.Errorf("quantity must be an integer in 1..%d", maxQuantity)
	}
	mfg, err1 := time.Parse(dateLayout, args[4])
	exp, err2 := time.Parse(dateLayout, args[5])
	if err1 != nil || err2 != nil {
		return nil, fmt.Errorf("dates must be YYYY-MM-DD")
	}
	now, err := txTime(stub)
	if err != nil {
		return nil, err
	}
	if !exp.After(mfg) || mfg.After(now) || !exp.After(now) {
		return nil, fmt.Errorf("invalid dates: require manufactureDate <= now < expiryDate")
	}
	if exists, err := batchExists(stub, id); err != nil {
		return nil, err
	} else if exists {
		return nil, fmt.Errorf("batch %s already exists", id)
	}
	ts := now.Format(time.RFC3339)
	b := &MedicineBatch{
		DocType: docType, ID: id, MedicineName: name, LotNumber: lot, Quantity: qty,
		ManufactureDate: args[4], ExpiryDate: args[5],
		ManufacturerMSP: ManufacturerMSP, HolderMSP: ManufacturerMSP, Status: StatusCreated,
		CreatedBy: caller, CreatedAt: ts, UpdatedAt: ts, LastTxID: stub.GetTxID(),
	}
	return putBatch(stub, b, "BatchCreated")
}

func (c *MedicineBatchContract) ReadBatch(stub shim.ChaincodeStubInterface, args []string) ([]byte, error) {
	if len(args) != 1 {
		return nil, fmt.Errorf("ReadBatch expects 1 argument")
	}
	b, err := getBatch(stub, args[0])
	if err != nil {
		return nil, err
	}
	return json.Marshal(b)
}

// UpdateStatus(id, newStatus) — решения по качеству: только Org1, role=qa.
func (c *MedicineBatchContract) UpdateStatus(stub shim.ChaincodeStubInterface, args []string) ([]byte, error) {
	if len(args) != 2 {
		return nil, fmt.Errorf("UpdateStatus expects 2 arguments")
	}
	caller, err := authorize(stub, ManufacturerMSP, RoleQA) // исправление уязвимости medicinebatch_vuln
	if err != nil {
		return nil, err
	}
	b, err := getBatch(stub, args[0])
	if err != nil {
		return nil, err
	}
	newStatus := strings.ToUpper(strings.TrimSpace(args[1]))
	if !slices.Contains(statusTransitions[b.Status], newStatus) {
		return nil, fmt.Errorf("transition %s -> %s is not allowed", b.Status, newStatus)
	}
	if newStatus == StatusReleased {
		// Инвариант: партия выпускается только при наличии записанных результатов контроля качества
		h, err := stub.GetPrivateDataHash(PrivateCollection, b.ID)
		if err != nil {
			return nil, err
		}
		if h == nil {
			return nil, fmt.Errorf("invariant violated: batch %s has no QC privateDetails", b.ID)
		}
		// Разделение обязанностей: создатель партии не может её выпустить
		if caller == b.CreatedBy {
			return nil, fmt.Errorf("separation of duties: creator cannot release own batch")
		}
		b.ReleasedBy = caller
	}
	return setStatus(stub, b, newStatus, b.HolderMSP)
}

// TransferBatch(id, toMSP) — отгрузка дистрибьютору: Org1, role=production.
func (c *MedicineBatchContract) TransferBatch(stub shim.ChaincodeStubInterface, args []string) ([]byte, error) {
	if len(args) != 2 {
		return nil, fmt.Errorf("TransferBatch expects 2 arguments")
	}
	if _, err := authorize(stub, ManufacturerMSP, RoleProduction); err != nil {
		return nil, err
	}
	b, err := getBatch(stub, args[0])
	if err != nil {
		return nil, err
	}
	if args[1] != DistributorMSP {
		return nil, fmt.Errorf("batch can only be transferred to %s", DistributorMSP)
	}
	if b.Status != StatusReleased {
		return nil, fmt.Errorf("only RELEASED batch can be shipped, current status %s", b.Status)
	}
	if err := requireNotExpired(stub, b); err != nil {
		return nil, err
	}
	return setStatus(stub, b, StatusShipped, DistributorMSP)
}

// ReceiveBatch(id) — приёмка: Org2, role=logistics, партия должна быть отгружена именно Org2.
func (c *MedicineBatchContract) ReceiveBatch(stub shim.ChaincodeStubInterface, args []string) ([]byte, error) {
	if len(args) != 1 {
		return nil, fmt.Errorf("ReceiveBatch expects 1 argument")
	}
	if _, err := authorize(stub, DistributorMSP, RoleLogistics); err != nil {
		return nil, err
	}
	b, err := getBatch(stub, args[0])
	if err != nil {
		return nil, err
	}
	if b.Status != StatusShipped || b.HolderMSP != DistributorMSP {
		return nil, fmt.Errorf("batch %s is not shipped to %s (status %s)", b.ID, DistributorMSP, b.Status)
	}
	return setStatus(stub, b, StatusReceived, DistributorMSP)
}

func (c *MedicineBatchContract) BatchExistsTx(stub shim.ChaincodeStubInterface, args []string) ([]byte, error) {
	if len(args) != 1 {
		return nil, fmt.Errorf("BatchExists expects 1 argument")
	}
	ok, err := batchExists(stub, args[0])
	if err != nil {
		return nil, err
	}
	return []byte(strconv.FormatBool(ok)), nil
}

func (c *MedicineBatchContract) GetAllBatches(stub shim.ChaincodeStubInterface, args []string) ([]byte, error) {
	if len(args) != 0 {
		return nil, fmt.Errorf("GetAllBatches expects no arguments")
	}
	it, err := stub.GetStateByRange("", "")
	if err != nil {
		return nil, err
	}
	defer it.Close()
	out := []MedicineBatch{}
	for it.HasNext() {
		kv, err := it.Next()
		if err != nil {
			return nil, err
		}
		var b MedicineBatch
		if json.Unmarshal(kv.Value, &b) == nil && b.DocType == docType {
			out = append(out, b)
		}
	}
	return json.Marshal(out)
}

// ======================================================= конфиденциальные данные

// SetPrivateDetails(id) — запись результатов контроля качества. Данные передаются ТОЛЬКО через
// transient field "privateDetails" и не попадают в аргументы транзакции и публичный ledger.
// Политика подтверждения коллекции: OR('Org1MSP.member') — транзакция подтверждается только peer Org1.
func (c *MedicineBatchContract) SetPrivateDetails(stub shim.ChaincodeStubInterface, args []string) ([]byte, error) {
	if len(args) != 1 {
		return nil, fmt.Errorf("SetPrivateDetails expects only batch id; QC data must be passed in transient field %q", TransientKey)
	}
	caller, err := authorize(stub, ManufacturerMSP, RoleQA)
	if err != nil {
		return nil, err
	}
	b, err := getBatch(stub, args[0])
	if err != nil {
		return nil, err
	}
	if b.Status != StatusCreated {
		return nil, fmt.Errorf("QC results can be recorded only for CREATED batch, current status %s", b.Status)
	}
	transient, err := stub.GetTransient()
	if err != nil {
		return nil, err
	}
	raw, ok := transient[TransientKey]
	if !ok || len(raw) == 0 {
		return nil, fmt.Errorf("transient field %q is required", TransientKey)
	}
	var d PrivateDetails
	dec := json.NewDecoder(strings.NewReader(string(raw)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&d); err != nil {
		return nil, fmt.Errorf("invalid privateDetails JSON: %v", err)
	}
	if err := validateDetails(&d); err != nil {
		return nil, err
	}
	now, err := txTime(stub)
	if err != nil {
		return nil, err
	}
	d.BatchID, d.RecordedBy, d.RecordedAt = b.ID, caller, now.Format(time.RFC3339)
	data, err := json.Marshal(d)
	if err != nil {
		return nil, err
	}
	if err := stub.PutPrivateData(PrivateCollection, b.ID, data); err != nil {
		return nil, err
	}
	sum := sha256.Sum256(data)
	return []byte(hex.EncodeToString(sum[:])), nil // клиенту возвращается только хеш
}

// ReadPrivateDetails(id) — чтение результатов контроля качества: только Org1 (qa или production).
func (c *MedicineBatchContract) ReadPrivateDetails(stub shim.ChaincodeStubInterface, args []string) ([]byte, error) {
	if len(args) != 1 {
		return nil, fmt.Errorf("ReadPrivateDetails expects 1 argument")
	}
	if _, err := authorize(stub, ManufacturerMSP, RoleQA, RoleProduction); err != nil {
		return nil, err
	}
	data, err := stub.GetPrivateData(PrivateCollection, args[0])
	if err != nil {
		return nil, err
	}
	if data == nil {
		return nil, fmt.Errorf("no privateDetails for batch %s", args[0])
	}
	return data, nil
}

// VerifyPrivateDetailsHash(id, sha256hex) — любая организация канала может проверить, что
// предъявленный ей off-chain документ совпадает с записанным, не получая доступа к данным.
func (c *MedicineBatchContract) VerifyPrivateDetailsHash(stub shim.ChaincodeStubInterface, args []string) ([]byte, error) {
	if len(args) != 2 {
		return nil, fmt.Errorf("VerifyPrivateDetailsHash expects 2 arguments")
	}
	h, err := stub.GetPrivateDataHash(PrivateCollection, args[0])
	if err != nil {
		return nil, err
	}
	return []byte(strconv.FormatBool(h != nil && hex.EncodeToString(h) == strings.ToLower(args[1]))), nil
}

// ======================================================= авторизация и инварианты

// authorize проверяет: MSP организации, тип идентичности (OU=client) и роль (атрибут "role").
// Возвращает идентификатор вызывающего (subject::issuer).
func authorize(stub shim.ChaincodeStubInterface, msp string, roles ...string) (string, error) {
	got, err := cid.GetMSPID(stub)
	if err != nil {
		return "", fmt.Errorf("cannot read client MSP: %w", err)
	}
	if got != msp {
		return "", fmt.Errorf("access denied: operation requires %s, caller is %s", msp, got)
	}
	cert, err := cid.GetX509Certificate(stub)
	if err != nil || cert == nil {
		return "", fmt.Errorf("access denied: x509 identity required")
	}
	if !slices.Contains(cert.Subject.OrganizationalUnit, "client") {
		return "", fmt.Errorf("access denied: business operations require a client identity (OU=client), got %v", cert.Subject.OrganizationalUnit)
	}
	role, found, err := cid.GetAttributeValue(stub, "role")
	if err != nil || !found || !slices.Contains(roles, role) {
		return "", fmt.Errorf("access denied: role %v required, caller role %q", roles, role)
	}
	return clientID(stub)
}

func validateDetails(d *PrivateDetails) error {
	inRange := func(v, lo, hi float64) bool { return !math.IsNaN(v) && v >= lo && v <= hi }
	switch {
	case !inRange(d.AssayPercent, 0, 200):
		return fmt.Errorf("assayPercent out of range")
	case !inRange(d.ImpurityPercent, 0, 100):
		return fmt.Errorf("impurityPercent out of range")
	case !inRange(d.DissolutionPercent, 0, 100):
		return fmt.Errorf("dissolutionPercent out of range")
	case d.Microbiology != "COMPLIANT" && d.Microbiology != "NON_COMPLIANT":
		return fmt.Errorf("microbiology must be COMPLIANT or NON_COMPLIANT")
	case !textSafe.MatchString(d.LabProtocol) || !textSafe.MatchString(d.Analyst):
		return fmt.Errorf("labProtocol and analyst are required")
	}
	return nil
}

// checkInvariants выполняется перед каждой записью партии в World State.
func checkInvariants(b *MedicineBatch) error {
	want, ok := holderByStatus[b.Status]
	switch {
	case b.ManufacturerMSP != ManufacturerMSP:
		return fmt.Errorf("invariant violated: manufacturerMSP must be %s", ManufacturerMSP)
	case b.Status == StatusRecalled:
		return nil // отозванная партия может находиться у любого участника
	case !ok:
		return fmt.Errorf("invariant violated: unknown status %q", b.Status)
	case b.HolderMSP != want:
		return fmt.Errorf("invariant violated: status %s requires holder %s, got %s", b.Status, want, b.HolderMSP)
	case (b.Status == StatusReleased || b.Status == StatusShipped || b.Status == StatusReceived) && b.ReleasedBy == "":
		return fmt.Errorf("invariant violated: batch in status %s was never released by QA", b.Status)
	}
	return nil
}

// ======================================================= вспомогательные функции

func clientID(stub shim.ChaincodeStubInterface) (string, error) {
	id, err := cid.GetID(stub)
	if err != nil {
		return "", fmt.Errorf("cannot read client identity: %w", err)
	}
	raw, err := base64.StdEncoding.DecodeString(id)
	if err != nil {
		return id, nil
	}
	return string(raw), nil
}

func txTime(stub shim.ChaincodeStubInterface) (time.Time, error) {
	ts, err := stub.GetTxTimestamp()
	if err != nil {
		return time.Time{}, err
	}
	return ts.AsTime().UTC(), nil
}

func requireNotExpired(stub shim.ChaincodeStubInterface, b *MedicineBatch) error {
	now, err := txTime(stub)
	if err != nil {
		return err
	}
	exp, err := time.Parse(dateLayout, b.ExpiryDate)
	if err != nil {
		return err
	}
	if !now.Before(exp) {
		return fmt.Errorf("batch %s expired on %s", b.ID, b.ExpiryDate)
	}
	return nil
}

func batchExists(stub shim.ChaincodeStubInterface, id string) (bool, error) {
	v, err := stub.GetState(id)
	if err != nil {
		return false, fmt.Errorf("failed to read world state: %w", err)
	}
	return v != nil, nil
}

func getBatch(stub shim.ChaincodeStubInterface, id string) (*MedicineBatch, error) {
	if !idPattern.MatchString(id) {
		return nil, fmt.Errorf("invalid batch id %q", id)
	}
	v, err := stub.GetState(id)
	if err != nil {
		return nil, fmt.Errorf("failed to read world state: %w", err)
	}
	if v == nil {
		return nil, fmt.Errorf("batch %s does not exist", id)
	}
	var b MedicineBatch
	if err := json.Unmarshal(v, &b); err != nil {
		return nil, err
	}
	return &b, nil
}

func setStatus(stub shim.ChaincodeStubInterface, b *MedicineBatch, status, holder string) ([]byte, error) {
	now, err := txTime(stub)
	if err != nil {
		return nil, err
	}
	b.Status, b.HolderMSP = status, holder
	b.UpdatedAt, b.LastTxID = now.Format(time.RFC3339), stub.GetTxID()
	return putBatch(stub, b, "BatchStatusChanged")
}

func putBatch(stub shim.ChaincodeStubInterface, b *MedicineBatch, event string) ([]byte, error) {
	if err := checkInvariants(b); err != nil {
		return nil, err
	}
	data, err := json.Marshal(b)
	if err != nil {
		return nil, err
	}
	if err := stub.PutState(b.ID, data); err != nil {
		return nil, err
	}
	if err := stub.SetEvent(event, data); err != nil {
		return nil, err
	}
	return data, nil
}
