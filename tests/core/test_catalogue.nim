import std/[unittest, strutils]
import ../../tokenlists/core/catalogue

const address = "0x000000000000000000000000000000000000000a"
func custom(symbol = "CUSTOM"): Token =
  Token(chainId: 1, address: address, name: "Custom", symbol: symbol, decimals: 18)

suite "catalogue publication and custom transactions":
  test "direct queries match owned snapshot results without exposing state":
    var catalogue = initCatalogue(CatalogueConfig(chains: @[1'u64]),
      customs = @[custom()]).get
    let held = catalogue.snapshot
    check catalogue.getByKey("1-" & address) == held.getByKey("1-" & address)
    check catalogue.getByChainAddress(1, address) == held.getByChainAddress(1, address)
    check catalogue.getNative(1) == held.getNative(1)
    check catalogue.getAll() == held.getAll()
    check catalogue.getByChains([1'u64], 1, 1) == held.getByChains([1'u64], 1, 1)
    check catalogue.getByKeys(["1-" & address]) == held.getByKeys(["1-" & address])
    check catalogue.getList("custom") == held.getList("custom")
    check catalogue.getLists() == held.getLists()
    check catalogue.getDiagnostics() == held.getDiagnostics()
    var token = catalogue.getByKey("1-" & address).get
    token.symbol = "COPY"
    check catalogue.getByKey("1-" & address).get.symbol == "CUSTOM"

  test "duplicate custom identities are rejected before publication":
    var duplicate = custom("DUPLICATE")
    duplicate.address = address.toUpperAscii()
    let created = initCatalogue(CatalogueConfig(chains: @[1'u64]),
      customs = @[custom(), duplicate])
    check created.isErr
    if created.isErr:
      check created.error.code == InvalidArgument
      check created.error.detail == "DuplicateCustomKey"

  test "history cursors at exactly 64 and 65 revisions":
    var catalogue = initCatalogue(CatalogueConfig(chains: @[1'u64])).get
    for index in 0 ..< 63:
      discard catalogue.setChains(if index mod 2 == 0: @[10'u64] else: @[1'u64]).get
    check catalogue.revision == 64
    check catalogue.changesSince(0).get.items.len == 64
    discard catalogue.setChains(@[1'u64]).get
    check catalogue.revision == 65
    check catalogue.changesSince(0).error.detail == "ChangeHistoryExpired"
    check catalogue.changesSince(1).get.items.len == 64
    check catalogue.changesSince(high(uint64)).error.code == InvalidArgument

  test "bootstrap publishes revision one and abort preserves the snapshot":
    var catalogue = initCatalogue(CatalogueConfig(chains: @[1'u64])).get
    check catalogue.revision == 1
    let held = catalogue.snapshot
    let mutation = catalogue.customValidateUpsert(custom()).get
    check mutation.token.custom
    check catalogue.snapshot.getByKey("1-" & address).isErr
    check catalogue.customValidateUpsert(custom()).error.code == Busy
    check catalogue.customAbort(mutation.id).isOk
    check catalogue.revision == 1
    check held.getAll().get == catalogue.snapshot.getAll().get

  test "commit makes custom edits immediately visible without changing held values":
    var catalogue = initCatalogue(CatalogueConfig(chains: @[1'u64])).get
    let held = catalogue.snapshot
    var mutation = catalogue.customValidateUpsert(custom()).get
    mutation.token.symbol = "HOST COPY"
    let change = catalogue.customCommit(mutation.id).get
    check change.revision == 2
    check change.kind == CustomChange
    check change.chains == @[1'u64]
    check change.lists == @["custom"]
    check catalogue.snapshot.getByKey("1-" & address).get.symbol == "CUSTOM"
    check held.getByKey("1-" & address).error.code == NotFound
    let update = catalogue.customValidateUpsert(custom("UPDATED")).get
    discard catalogue.customCommit(update.id).get
    check catalogue.snapshot.getByKey("1-" & address).get.symbol == "UPDATED"
    let deletion = catalogue.customValidateDelete("1-" & address).get
    discard catalogue.customCommit(deletion.id).get
    check catalogue.snapshot.getByKey("1-" & address).error.code == NotFound
    check catalogue.revision == 4
    check catalogue.customCommit(deletion.id).isErr

  test "custom tokens never override curated tokens under the default policy":
    let body = "{\"tokens\":[{\"chainId\":1,\"address\":\"" & address &
      "\",\"symbol\":\"CURATED\",\"decimals\":18}]}"
    var catalogue = initCatalogue(CatalogueConfig(chains: @[1'u64],
      initialLists: @[ListContent(id: "main", body: body)])).get
    let mutation = catalogue.customValidateUpsert(custom()).get
    discard catalogue.customCommit(mutation.id).get
    check catalogue.snapshot.getByKey("1-" & address).get.symbol == "CURATED"
    check catalogue.snapshot.getList("custom").get.tokens.len == 1

  test "chain changes supersede proposals and failed rebuilds are atomic":
    var catalogue = initCatalogue(CatalogueConfig(chains: @[1'u64])).get
    let mutation = catalogue.customValidateUpsert(custom()).get
    let before = catalogue.snapshot
    check catalogue.setChains(@[1'u64, 1]).isErr
    check catalogue.revision == 1
    discard catalogue.setChains(@[10'u64]).get
    check catalogue.epoch == 1
    check catalogue.customCommit(mutation.id).error.code == SupersededPlan
    check catalogue.snapshot.getNative(1).isErr
    check catalogue.snapshot.getNative(10).isOk
    check before.getNative(1).isOk
    check catalogue.customValidateUpsert(custom()).error.code == UnsupportedChain

  test "policy changes publish immediately and invalidate pending writes":
    var catalogue = initCatalogue(CatalogueConfig(chains: @[1'u64]),
      customs = @[custom()]).get
    let mutation = catalogue.customValidateDelete("1-" & address).get
    discard catalogue.setPolicy(CataloguePolicy(skippedKeys: @["1-" & address])).get
    check catalogue.customCommit(mutation.id).error.code == SupersededPlan
    check catalogue.snapshot.getByKey("1-" & address).isErr
    check catalogue.snapshot.getList("custom").get.tokens.len == 1
    let before = catalogue.revision
    check catalogue.setPolicy(CataloguePolicy(skippedKeys: @["bad"])).isErr
    check catalogue.revision == before

  test "changes are revision tagged and invalid requests do not publish":
    var catalogue = initCatalogue(CatalogueConfig(chains: @[1'u64])).get
    check catalogue.changesSince(0).get.items[0].kind == BootstrapChange
    check catalogue.changesSince(1).get.items.len == 0
    check catalogue.changesSince(2).error.code == InvalidArgument
    check catalogue.customValidateUpsert(custom("")).error.code == ValidationFailed
    check catalogue.customValidateDelete("bad").error.code == InvalidArgument
    check catalogue.customValidateDelete("1-" & address).error.code == NotFound
    check catalogue.customAbort(999).isErr
    check catalogue.revision == 1

  test "unchanged configuration does not invalidate a pending mutation":
    var catalogue = initCatalogue(CatalogueConfig(chains: @[1'u64])).get
    let mutation = catalogue.customValidateUpsert(custom()).get
    check catalogue.setChains(@[1'u64]).get.kind == NoChange
    check catalogue.setPolicy(CataloguePolicy()).get.kind == NoChange
    check catalogue.epoch == 0
    check catalogue.customCommit(mutation.id).get.revision == 2

  test "change retention is bounded and signals expired cursors":
    var catalogue = initCatalogue(CatalogueConfig(chains: @[1'u64])).get
    for index in 0 ..< 70:
      let chains = if index mod 2 == 0: @[10'u64] else: @[1'u64]
      discard catalogue.setChains(chains).get
    check catalogue.changesSince(0).error.detail == "ChangeHistoryExpired"
    check catalogue.changesSince(7).get.items.len == 64
    check catalogue.changesSince(70).get.items.len == 1

  test "aborting an obsolete proposal cannot clear the next one":
    var catalogue = initCatalogue(CatalogueConfig(chains: @[1'u64])).get
    let first = catalogue.customValidateUpsert(custom()).get
    check catalogue.customAbort(first.id).isOk
    let second = catalogue.customValidateUpsert(custom("SECOND")).get
    check second.id > first.id
    check catalogue.customAbort(first.id).isErr
    check catalogue.customCommit(second.id).isOk
    check catalogue.snapshot.getByKey("1-" & address).get.symbol == "SECOND"

  test "alias-only policy changes invalidate lookup consumers for that chain":
    var catalogue = initCatalogue(CatalogueConfig(chains: @[1'u64])).get
    check catalogue.snapshot.getByKey("1-" & address).isErr
    let changed = catalogue.setPolicy(CataloguePolicy(nativeAliases:
      @[TokenIdentity(chainId: 1, address: address)])).get
    check changed.chains == @[1'u64]
    check changed.lists.len == 0
    check catalogue.snapshot.getByKey("1-" & address).get.symbol == "ETH"
    let skipped = catalogue.setPolicy(CataloguePolicy(nativeAliases:
      @[TokenIdentity(chainId: 1, address: address)],
      skippedKeys: @["1-" & address])).get
    check skipped.chains == @[1'u64]
    check catalogue.snapshot.getByKey("1-" & address).isErr
    check catalogue.setPolicy(CataloguePolicy(nativeAliases:
      @[TokenIdentity(chainId: 1, address: address)])).get.chains == @[1'u64]
    check catalogue.setPolicy(CataloguePolicy()).get.chains == @[1'u64]
