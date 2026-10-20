## Live, peak and cumulative heap bytes from the force-included C shim.
{.compile: "counting.c".}
proc tkl_count_live(): clonglong {.importc, cdecl.}
proc tkl_count_churn(): clonglong {.importc, cdecl.}
proc tkl_count_peak(): clonglong {.importc, cdecl.}
proc tkl_count_reset_peak() {.importc, cdecl.}

type Usage* = object
  retained*, peak*, churn*: int

template measure*(body: untyped): Usage =
  let
    live = tkl_count_live()
    churn = tkl_count_churn()
  tkl_count_reset_peak()
  body
  Usage(retained: int(tkl_count_live() - live),
    peak: int(tkl_count_peak() - live), churn: int(tkl_count_churn() - churn))
