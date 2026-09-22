import std/unittest
import ../../tokenlists/core/catalogue

const address = "0x000000000000000000000000000000000000000a"
func custom(symbol = "CUSTOM"): Token =
  Token(chainId: 1, address: address, name: "Custom", symbol: symbol, decimals: 18)

suite "catalogue publication and custom transactions":
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
