{.push raises: [], gcsafe.}

import results
export results

type
  TklStatus* = enum
    Ok = 0, NotFound, Unchanged, Aborted, SupersededPlan, Busy,
    PartialSuccess, InvalidContent, UnsupportedSchema, UnsupportedChain,
    ValidationFailed, NetworkFailure, StorageFailure, InvalidArgument,
    InvalidHandle, Closed, AbiMismatch, Internal

  TklError* = object
    code*: TklStatus
    detail*: string
    sourceId*: string

func tklError*(code: TklStatus, detail: string, sourceId = ""): TklError =
  TklError(code: code, detail: detail, sourceId: sourceId)
