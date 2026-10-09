package tkl

import "encoding/json"

type Token struct {
	ChainID      uint64 `json:"chainId"`
	Address      string `json:"address"`
	CrossChainID string `json:"crossChainId,omitempty"`
	Decimals     uint8  `json:"decimals"`
	Name         string `json:"name,omitempty"`
	Symbol       string `json:"symbol"`
	LogoURI      string `json:"logoUri,omitempty"`
	Custom       bool   `json:"custom,omitempty"`
}
type Identity struct {
	ChainID uint64 `json:"chainId"`
	Address string `json:"address"`
}
type Version struct {
	Major int64 `json:"major"`
	Minor int64 `json:"minor"`
	Patch int64 `json:"patch"`
}
type TokenList struct {
	ID               string          `json:"id"`
	Name             string          `json:"name"`
	Timestamp        string          `json:"timestamp"`
	FetchedTimestamp string          `json:"fetchedTimestamp"`
	Source           string          `json:"source"`
	Version          Version         `json:"version"`
	Tags             json.RawMessage `json:"tags"`
	LogoURI          string          `json:"logoUri"`
	Keywords         []string        `json:"keywords"`
	Tokens           []Token         `json:"tokens"`
}
type Page[T any] struct {
	Revision uint64 `json:"revision"`
	Total    int    `json:"total"`
	Items    []T    `json:"items"`
}
type Diagnostic struct {
	Code     string `json:"code,omitempty"`
	Detail   string `json:"detail,omitempty"`
	SourceID string `json:"sourceId,omitempty"`
}

// ListContent is the identity and fetch metadata of a list document. Bodies
// travel separately and the library never retains them.
type ListContent struct {
	ID               string      `json:"id"`
	Format           string      `json:"format,omitempty"`
	Source           string      `json:"source,omitempty"`
	FetchedTimestamp string      `json:"fetchedTimestamp,omitempty"`
	ETag             string      `json:"etag,omitempty"`
	FetchedAt        int64       `json:"fetchedAt,omitempty"`
	Failure          *Diagnostic `json:"failure,omitempty"`
}

const (
	StandardFormat = "StandardFormat"
	StatusFormat   = "StatusFormat"
	RegistryFormat = "RegistryFormat"
)

type Policy struct {
	Priority      string     `json:"priority,omitempty"`
	SkippedKeys   []string   `json:"skippedKeys,omitempty"`
	NativeAliases []Identity `json:"nativeAliases,omitempty"`
	NativeTokens  []Token    `json:"nativeTokens,omitempty"`
}
type Config struct {
	Chains       []uint64      `json:"chains,omitempty"`
	MainListID   string        `json:"mainListId,omitempty"`
	RegistryID   string        `json:"registryId,omitempty"`
	RegistryURL  string        `json:"registryUrl,omitempty"`
	InitialLists []ListContent `json:"initialLists,omitempty"`
	Policy       Policy        `json:"policy"`
}
type Limits struct {
	MaxBytes         int `json:"maxBytes"`
	MaxDepth         int `json:"maxDepth"`
	MaxArrayItems    int `json:"maxArrayItems"`
	MaxObjectMembers int `json:"maxObjectMembers"`
	MaxStringBytes   int `json:"maxStringBytes"`
}

// Bootstrap describes the host's persisted state; Stored is the metadata of
// its persisted lists and registry.
type Bootstrap struct {
	Stored  []ListContent `json:"stored,omitempty"`
	Customs []Token       `json:"customs,omitempty"`
	State   RefreshState  `json:"state"`
}

// BodyOrigin says which copy of a list a load body is.
type BodyOrigin uint32

const (
	Bundled BodyOrigin = 0
	Stored  BodyOrigin = 1
)

// ListBody is one list document to load. Data is only borrowed for the call.
type ListBody struct {
	ID     string
	Origin BodyOrigin
	Data   []byte
}
type Change struct {
	Revision uint64   `json:"revision"`
	Kind     string   `json:"kind"`
	Chains   []uint64 `json:"chains"`
	Lists    []string `json:"lists"`
}
type Mutation struct {
	ID    uint64 `json:"id"`
	Kind  string `json:"kind"`
	Key   string `json:"key"`
	Token Token  `json:"token"`
}
type FetchRequest struct {
	ID     string `json:"id"`
	URL    string `json:"url"`
	ETag   string `json:"etag"`
	Format string `json:"format"`
}

// FetchResult is one fetched response. Body is passed to the library on its
// own and only borrowed for that call; it is not part of the JSON envelope.
type FetchResult struct {
	ID      string      `json:"id"`
	Status  int         `json:"status,omitempty"`
	Body    []byte      `json:"-"`
	ETag    string      `json:"etag,omitempty"`
	Failure *Diagnostic `json:"failure,omitempty"`
}
type RefreshPlan struct {
	ID        uint64         `json:"id"`
	ExpiresAt int64          `json:"expiresAt"`
	Requests  []FetchRequest `json:"requests"`
}
type SourceReport struct {
	ID      string     `json:"id"`
	Outcome string     `json:"outcome"`
	Error   Diagnostic `json:"error"`
}
type RefreshReport struct {
	Step        string         `json:"step"`
	Outcome     string         `json:"outcome"`
	Requests    []FetchRequest `json:"requests"`
	Writes      []ListContent  `json:"writes"`
	Sources     []SourceReport `json:"sources"`
	Diagnostics []Diagnostic   `json:"diagnostics"`
}
type RefreshState struct {
	LastSuccess int64  `json:"lastSuccess"`
	LastAttempt int64  `json:"lastAttempt"`
	LastOutcome string `json:"lastOutcome,omitempty"`
	HasSuccess  bool   `json:"hasSuccess"`
	HasAttempt  bool   `json:"hasAttempt"`
}
