package main

import (
	"log"

	"github.com/hyperledger/fabric-chaincode-go/v2/shim"
)

func main() {
	if err := shim.Start(new(MedicineBatchContract)); err != nil {
		log.Fatalf("error starting MedicineBatch chaincode: %v", err)
	}
}
