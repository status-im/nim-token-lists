# The library tasks also run under plain nim (embedded wrapper), which imports nothing for them.
import std/[os, strutils]

version = "0.2.0"
author = "Status"
description = "Sans-I/O fungible token list core"
license = "MIT"
requires "nim >= 2.2.10", "results >= 0.5.1", "json_serialization >= 0.5.0",
  "serialization >= 0.5.4", "stew >= 0.5.1", "faststreams >= 0.5.1"
skipDirs = @["go", "build", "docs", "fixtures", "tests", "vendor"]
# The library tasks build from an installed package too.
installDirs = @["abi", "scripts", "tokenlists"]

task test, "Run core tests with vendored dependency pins":
  exec "bash scripts/test_core.sh"

# The library tasks follow the Nim library build contract. Embedders run them
# with plain nim through a wrapper that includes this file:
#   printf 'include "%s"\n' <pkg>/tokenlists.nimble > "$LIB_OUT_DIR/tokenlists.nims"
#   nim libtkl "$LIB_OUT_DIR/tokenlists.nims"
# thisDir() is then the wrapper's dir, so the package dir comes from this file.
const pkgDir = currentSourcePath().parentDir

proc writable(dir: string): bool =
  var dir = dir
  while not dirExists(dir):
    dir = parentDir(dir)
  gorgeEx("test -w " & quoteShell(dir)).exitCode == 0

# NIM (default: this compiler), NIM_PARAMS appended last (dependency --paths
# included) and every output under LIB_OUT_DIR; the sealed archive and header
# land in $LIB_OUT_DIR/link. Dependencies resolve only from the --paths given:
# NIM_PARAMS, plus nimble.paths when nimble runs the task in a checkout.
# The embedded entry (plain nim) never reads this package's nimble.paths.
proc prepareLibBuild(defaultOut: string): string =
  result = getEnv("LIB_OUT_DIR")
  if result.len == 0:
    # A store entry, or any package dir the default output cannot be written to.
    if fileExists(pkgDir / "nimblemeta.json") or
        not writable(pkgDir / defaultOut / "link"):
      quit "libtkl: set LIB_OUT_DIR; the package dir is read-only (" & pkgDir & ")"
    result = pkgDir / defaultOut
  elif not result.isAbsolute:
    result = getCurrentDir() / result
  mkDir result / "link"
  putEnv("OUT", result)
  putEnv("NIM", getEnv("NIM", selfExe()))
  putEnv("TKL_VENDOR_DEPS", "0")
  var params = "--noNimblePath "
  when declared(getPkgDir):
    # Run by nimble: resolve through a `nimble setup` checkout's nimble.paths,
    # or else through the nimble store as usual.
    if fileExists(pkgDir / "nimble.paths"):
      for line in readFile(pkgDir / "nimble.paths").splitLines:
        # nimble writes Nim string literals; NIM_PARAMS needs shell quoting.
        if line.startsWith("--path:"):
          var path = line["--path:".len .. ^1]
          if path.startsWith("\""):
            path = unescape(path)
          params.add quoteShellPosix("--path:" & path) & " "
    else:
      params = ""
  putEnv("NIM_PARAMS", params & getEnv("NIM_PARAMS"))

proc script(name: string): string =
  "bash " & quoteShell(pkgDir / "scripts" / name)

proc buildMobile(target: string) =
  let outDir = prepareLibBuild("build" / target)
  putEnv("TKL_BUILD_TESTS", getEnv("TKL_BUILD_TESTS", "0"))
  exec script("build_mobile.sh") & " " & target
  cpFile pkgDir / "abi/tkl.h", outDir / "link/tkl.h"

task libtkl, "Build the sealed host libtkl.a and tkl.h into LIB_OUT_DIR/link (default build)":
  let outDir = prepareLibBuild("build")
  exec script("build_lib.sh")
  exec script("isolate_lib.sh")
  cpFile outDir / "libtkl_isolated.a", outDir / "link/libtkl.a"
  cpFile pkgDir / "abi/tkl.h", outDir / "link/tkl.h"
  exec script("audit_symbols.sh") & " " & quoteShell(outDir / "link/libtkl.a")

task libtklAndroid, "Build libtkl for Android (ARCH=arm64|x86_64) into LIB_OUT_DIR/link (default build/android-ARCH)":
  buildMobile "android-" & getEnv("ARCH", "arm64")

task libtklIOS, "Build libtkl for iOS (IPHONE_SDK=iphoneos with ARCH=arm64, or IPHONE_SDK=iphonesimulator with ARCH=arm64|x86_64) into LIB_OUT_DIR/link (default build/ios-[simulator-]ARCH)":
  let sdk = getEnv("IPHONE_SDK", "iphoneos")
  let arch = getEnv("ARCH", "arm64")
  if sdk notin ["iphoneos", "iphonesimulator"]:
    quit "libtkl: IPHONE_SDK must be iphoneos or iphonesimulator, got " & sdk
  if arch notin ["arm64", "x86_64"]:
    quit "libtkl: ARCH must be arm64 or x86_64, got " & arch
  if sdk == "iphoneos" and arch != "arm64":
    quit "libtkl: iphoneos supports ARCH=arm64 only"
  buildMobile "ios-" & (if sdk == "iphonesimulator": "simulator-" else: "") & arch
