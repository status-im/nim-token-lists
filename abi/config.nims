# The default configuration of every build of this directory's libtkl.nim.
# A caller's flags come later and win; libtkl.nim rejects what it cannot run
# under. The target, toolchain, policy, outputs and link are the caller's.
switch("app", "staticlib")
switch("noMain", "on")
switch("nimMainPrefix", "libtkl")
switch("define", "noSignalHandler")
switch("passC", "-fvisibility=hidden")
switch("passC", "-fno-common")
switch("define", "useMalloc")
