module github.com/status-im/nim-token-lists/tests/differential

go 1.26

require (
	github.com/status-im/go-wallet-sdk v0.0.0-20260831150359-0d553d87d783
	github.com/status-im/nim-token-lists/go/tkl v0.0.0
)

require (
	github.com/ethereum/go-ethereum v1.16.3 // indirect
	github.com/go-playground/locales v0.14.0 // indirect
	github.com/go-playground/universal-translator v0.18.0 // indirect
	github.com/go-playground/validator/v10 v10.11.1 // indirect
	github.com/holiman/uint256 v1.3.2 // indirect
	github.com/leodido/go-urn v1.2.1 // indirect
	golang.org/x/crypto v0.41.0 // indirect
	golang.org/x/sys v0.35.0 // indirect
	golang.org/x/text v0.28.0 // indirect
)

replace github.com/status-im/nim-token-lists/go/tkl => ../../go/tkl
