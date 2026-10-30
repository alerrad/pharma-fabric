// Chaincode MedicineBatch v2.0 — реестр партий лекарственных препаратов
// Изменения относительно v1.0 (обратно совместимые):
//   - модель MedicineBatch дополнена необязательными полями schemaVersion, storageCondition,
//     temperatureLog, temperatureExcursions (omitempty: объекты v1.0 читаются без изменений);
//   - новые операции RecordTemperature (контроль холодовой цепи), GetBatchHistory, GetChaincodeInfo;
//   - CreateBatch принимает необязательный 7-й аргумент storageCondition.
//
// Ключи, формат JSON и правила переходов v1.0 не изменены.
// (практическая работа №4, вариант 15 «Фармацевтика»).
//
// Org1 (Org1MSP) — производитель, Org2 (Org2MSP) — дистрибьютор.
//
// Жизненный цикл партии:
//
//	CREATED ──UpdateStatus──▶ RELEASED ──TransferBatch──▶ SHIPPED ──ReceiveBatch──▶ RECEIVED
//	   │                         │                           │                         │
//	   └──UpdateStatus──▶ REJECTED └──────────── UpdateStatus(RECALLED) ◀──────────────┘
//
// REJECTED и RECALLED — терминальные состояния.
package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"regexp"
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
	chaincodeVer    = "2.0"
	schemaVersion   = 2
	maxTempLog      = 50
)

// Условия хранения: допустимый диапазон температуры, °C.
var storageRanges = map[string][2]float64{
	"15-25C": {15, 25}, // по умолчанию (в т.ч. для объектов, созданных v1.0)
	"2-8C":   {2, 8},   // термолабильные препараты
}

const defaultStorage = "15-25C"

// Статусы партии.
const (
	StatusCreated  = "CREATED"
	StatusReleased = "RELEASED"
	StatusRejected = "REJECTED"
	StatusShipped  = "SHIPPED"
	StatusReceived = "RECEIVED"
	StatusRecalled = "RECALLED"
)

// Допустимые переходы, выполняемые через UpdateStatus (решения производителя).
// Переходы SHIPPED и RECEIVED выполняются только бизнес-операциями TransferBatch/ReceiveBatch.
var statusTransitions = map[string][]string{
	StatusCreated:  {StatusReleased, StatusRejected},
	StatusReleased: {StatusRecalled},
	StatusShipped:  {StatusRecalled},
	StatusReceived: {StatusRecalled},
}

var (
	idPattern  = regexp.MustCompile(`^[A-Z0-9][A-Z0-9-]{2,63}$`)
	lotPattern = regexp.MustCompile(`^[A-Za-z0-9-]{1,32}$`)
)

// MedicineBatch — бизнес-объект, хранимый в World State.
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

	// --- поля версии 2.0 (необязательные) ---
	SchemaVersion         int                  `json:"schemaVersion,omitempty"`
	StorageCondition      string               `json:"storageCondition,omitempty"`
	TemperatureLog        []TemperatureReading `json:"temperatureLog,omitempty"`
	TemperatureExcursions int                  `json:"temperatureExcursions,omitempty"`
}

// TemperatureReading — показание датчика холодовой цепи (v2.0).
type TemperatureReading struct {
	Timestamp   string  `json:"timestamp"`
	Celsius     float64 `json:"celsius"`
	RecordedBy  string  `json:"recordedBy"`
	InTolerance bool    `json:"inTolerance"`
}

// MedicineBatchContract реализует shim.Chaincode.
type MedicineBatchContract struct{}

func (c *MedicineBatchContract) Init(stub shim.ChaincodeStubInterface) *peer.Response {
	return shim.Success(nil)
}

func (c *MedicineBatchContract) Invoke(stub shim.ChaincodeStubInterface) *peer.Response {
	fn, args := stub.GetFunctionAndParameters()
	var (
		payload []byte
		err     error
	)
	switch fn {
	case "CreateBatch":
		payload, err = c.CreateBatch(stub, args)
	case "ReadBatch":
		payload, err = c.ReadBatch(stub, args)
	case "UpdateStatus":
		payload, err = c.UpdateStatus(stub, args)
	case "TransferBatch":
		payload, err = c.TransferBatch(stub, args)
	case "ReceiveBatch":
		payload, err = c.ReceiveBatch(stub, args)
	case "BatchExists":
		payload, err = c.BatchExistsTx(stub, args)
	case "GetAllBatches":
		payload, err = c.GetAllBatches(stub, args)
	case "RecordTemperature": // v2.0
		payload, err = c.RecordTemperature(stub, args)
	case "GetBatchHistory": // v2.0
		payload, err = c.GetBatchHistory(stub, args)
	case "GetChaincodeInfo": // v2.0
		payload, err = json.Marshal(map[string]any{"version": chaincodeVer, "schemaVersion": schemaVersion})
	default:
		err = fmt.Errorf("unknown function %q", fn)
	}
	if err != nil {
		return shim.Error(err.Error())
	}
	return shim.Success(payload)
}

// CreateBatch(id, medicineName, lotNumber, quantity, manufactureDate, expiryDate[, storageCondition])
// Создание партии. Только производитель (Org1MSP). 7-й аргумент добавлен в v2.0 и необязателен.
func (c *MedicineBatchContract) CreateBatch(stub shim.ChaincodeStubInterface, args []string) ([]byte, error) {
	if len(args) != 6 && len(args) != 7 {
		return nil, fmt.Errorf("CreateBatch expects 6 or 7 arguments, got %d", len(args))
	}
	storage := defaultStorage
	if len(args) == 7 {
		storage = strings.TrimSpace(args[6])
		if _, ok := storageRanges[storage]; !ok {
			return nil, fmt.Errorf("unknown storageCondition %q (allowed: 15-25C, 2-8C)", storage)
		}
	}
	if err := requireMSP(stub, ManufacturerMSP); err != nil {
		return nil, err
	}
	id, name, lot := strings.TrimSpace(args[0]), strings.TrimSpace(args[1]), strings.TrimSpace(args[2])
	if !idPattern.MatchString(id) {
		return nil, fmt.Errorf("invalid batch id %q: expected ^[A-Z0-9][A-Z0-9-]{2,63}$", id)
	}
	if l := len([]rune(name)); l < 2 || l > 128 {
		return nil, fmt.Errorf("medicineName must be 2..128 characters")
	}
	if !lotPattern.MatchString(lot) {
		return nil, fmt.Errorf("invalid lotNumber %q", lot)
	}
	qty, err := strconv.Atoi(args[3])
	if err != nil || qty <= 0 || qty > maxQuantity {
		return nil, fmt.Errorf("quantity must be an integer in 1..%d", maxQuantity)
	}
	mfg, err := time.Parse(dateLayout, args[4])
	if err != nil {
		return nil, fmt.Errorf("manufactureDate must be YYYY-MM-DD")
	}
	exp, err := time.Parse(dateLayout, args[5])
	if err != nil {
		return nil, fmt.Errorf("expiryDate must be YYYY-MM-DD")
	}
	if !exp.After(mfg) {
		return nil, fmt.Errorf("expiryDate must be after manufactureDate")
	}
	now, err := txTime(stub)
	if err != nil {
		return nil, err
	}
	if mfg.After(now) {
		return nil, fmt.Errorf("manufactureDate cannot be in the future")
	}
	exists, err := batchExists(stub, id)
	if err != nil {
		return nil, err
	}
	if exists {
		return nil, fmt.Errorf("batch %s already exists", id)
	}
	creator, err := clientID(stub)
	if err != nil {
		return nil, err
	}
	ts := now.Format(time.RFC3339)
	b := &MedicineBatch{
		DocType: docType, ID: id, MedicineName: name, LotNumber: lot, Quantity: qty,
		ManufactureDate: args[4], ExpiryDate: args[5],
		ManufacturerMSP: ManufacturerMSP, HolderMSP: ManufacturerMSP, Status: StatusCreated,
		CreatedBy: creator, CreatedAt: ts, UpdatedAt: ts, LastTxID: stub.GetTxID(),
		SchemaVersion: schemaVersion, StorageCondition: storage,
	}
	return putBatch(stub, b, "BatchCreated")
}

// ReadBatch(id) — чтение партии.
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

// UpdateStatus(id, newStatus) — решение производителя по партии:
// выпуск в обращение (RELEASED), отклонение (REJECTED), отзыв (RECALLED).
func (c *MedicineBatchContract) UpdateStatus(stub shim.ChaincodeStubInterface, args []string) ([]byte, error) {
	if len(args) != 2 {
		return nil, fmt.Errorf("UpdateStatus expects 2 arguments")
	}
	if err := requireMSP(stub, ManufacturerMSP); err != nil {
		return nil, err
	}
	b, err := getBatch(stub, args[0])
	if err != nil {
		return nil, err
	}
	newStatus := strings.ToUpper(strings.TrimSpace(args[1]))
	if !transitionAllowed(b.Status, newStatus) {
		return nil, fmt.Errorf("transition %s -> %s is not allowed", b.Status, newStatus)
	}
	return setStatus(stub, b, newStatus, b.HolderMSP)
}

// TransferBatch(id, toMSP) — основная бизнес-операция: производитель отгружает
// выпущенную и не просроченную партию дистрибьютору.
func (c *MedicineBatchContract) TransferBatch(stub shim.ChaincodeStubInterface, args []string) ([]byte, error) {
	if len(args) != 2 {
		return nil, fmt.Errorf("TransferBatch expects 2 arguments")
	}
	if err := requireMSP(stub, ManufacturerMSP); err != nil {
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
	return setStatus(stub, b, StatusShipped, args[1])
}

// ReceiveBatch(id) — дистрибьютор подтверждает получение партии.
func (c *MedicineBatchContract) ReceiveBatch(stub shim.ChaincodeStubInterface, args []string) ([]byte, error) {
	if len(args) != 1 {
		return nil, fmt.Errorf("ReceiveBatch expects 1 argument")
	}
	if err := requireMSP(stub, DistributorMSP); err != nil {
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

// BatchExists(id) — проверка существования ("true"/"false").
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

// GetAllBatches() — список всех партий.
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
		if err := json.Unmarshal(kv.Value, &b); err != nil || b.DocType != docType {
			continue
		}
		out = append(out, b)
	}
	return json.Marshal(out)
}

// RecordTemperature(id, celsius) — v2.0: текущий держатель партии фиксирует показание
// температуры. Выход за допустимый диапазон учитывается как температурная экскурсия.
func (c *MedicineBatchContract) RecordTemperature(stub shim.ChaincodeStubInterface, args []string) ([]byte, error) {
	if len(args) != 2 {
		return nil, fmt.Errorf("RecordTemperature expects 2 arguments")
	}
	b, err := getBatch(stub, args[0])
	if err != nil {
		return nil, err
	}
	if err := requireMSP(stub, b.HolderMSP); err != nil {
		return nil, fmt.Errorf("only current holder may record temperature: %w", err)
	}
	if b.Status == StatusRejected || b.Status == StatusRecalled {
		return nil, fmt.Errorf("batch %s is %s", b.ID, b.Status)
	}
	t, err := strconv.ParseFloat(args[1], 64)
	if err != nil || t < -40 || t > 60 {
		return nil, fmt.Errorf("celsius must be a number in -40..60")
	}
	upgradeSchema(b) // ленивое обновление объекта v1.0 до схемы v2
	rng := storageRanges[b.StorageCondition]
	now, err := txTime(stub)
	if err != nil {
		return nil, err
	}
	r := TemperatureReading{Timestamp: now.Format(time.RFC3339), Celsius: t, RecordedBy: b.HolderMSP,
		InTolerance: t >= rng[0] && t <= rng[1]}
	if !r.InTolerance {
		b.TemperatureExcursions++
	}
	b.TemperatureLog = append(b.TemperatureLog, r)
	if len(b.TemperatureLog) > maxTempLog {
		b.TemperatureLog = b.TemperatureLog[len(b.TemperatureLog)-maxTempLog:]
	}
	b.UpdatedAt, b.LastTxID = r.Timestamp, stub.GetTxID()
	return putBatch(stub, b, "TemperatureRecorded")
}

// GetBatchHistory(id) — v2.0: история изменений партии из History DB peer.
func (c *MedicineBatchContract) GetBatchHistory(stub shim.ChaincodeStubInterface, args []string) ([]byte, error) {
	if len(args) != 1 {
		return nil, fmt.Errorf("GetBatchHistory expects 1 argument")
	}
	it, err := stub.GetHistoryForKey(args[0])
	if err != nil {
		return nil, err
	}
	defer it.Close()
	type entry struct {
		TxID      string `json:"txId"`
		Timestamp string `json:"timestamp"`
		Status    string `json:"status"`
		HolderMSP string `json:"holderMSP"`
	}
	out := []entry{}
	for it.HasNext() {
		m, err := it.Next()
		if err != nil {
			return nil, err
		}
		var b MedicineBatch
		_ = json.Unmarshal(m.Value, &b)
		out = append(out, entry{m.TxId, m.Timestamp.AsTime().UTC().Format(time.RFC3339), b.Status, b.HolderMSP})
	}
	return json.Marshal(out)
}

// upgradeSchema заполняет поля v2.0 значениями по умолчанию для объектов, созданных v1.0.
func upgradeSchema(b *MedicineBatch) {
	if b.SchemaVersion < schemaVersion {
		b.SchemaVersion = schemaVersion
	}
	if b.StorageCondition == "" {
		b.StorageCondition = defaultStorage
	}
}

// ----------------------------------------------------------------- helpers

func requireMSP(stub shim.ChaincodeStubInterface, msp string) error {
	got, err := cid.GetMSPID(stub)
	if err != nil {
		return fmt.Errorf("cannot read client MSP: %w", err)
	}
	if got != msp {
		return fmt.Errorf("access denied: operation requires %s, caller is %s", msp, got)
	}
	return nil
}

// clientID возвращает идентичность вызывающего в виде "x509::<subject>::<issuer>".
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

func transitionAllowed(from, to string) bool {
	for _, s := range statusTransitions[from] {
		if s == to {
			return true
		}
	}
	return false
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
