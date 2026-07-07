/- Pure JSON helpers for Codex app-server protocol messages. -/
import Lean

open Lean

namespace LLMlean.Codex.Protocol

abbrev RequestId := Nat

structure RpcError where
  code : Option Int
  message : String
  data : Option Json := none
deriving BEq

def emptyParams : Json :=
  Json.mkObj []

def jsonObj (fields : List (String × Option Json)) : Json :=
  let pairs : List (String × Json) :=
    fields.foldr
      (fun field acc =>
        match field with
        | (key, some value) => (key, value) :: acc
        | (_, none) => acc)
      []
  Json.mkObj pairs

def requestWithJsonId (id : Json) (method : String) (params : Json := emptyParams) : Json :=
  Json.mkObj [
    ("id", id),
    ("method", method),
    ("params", params)
  ]

def request (id : RequestId) (method : String) (params : Json := emptyParams) : Json :=
  requestWithJsonId (id : Json) method params

def notification (method : String) (params : Json := emptyParams) : Json :=
  Json.mkObj [
    ("method", method),
    ("params", params)
  ]

def resultResponse (id : Json) (result : Json) : Json :=
  Json.mkObj [
    ("id", id),
    ("result", result)
  ]

def errorResponse (id : Json) (code : Int) (message : String) (data : Option Json := none) :
    Json :=
  Json.mkObj [
    ("id", id),
    ("error", jsonObj [
      ("code", some (code : Json)),
      ("message", some (message : Json)),
      ("data", data)
    ])
  ]

def initializeRequest (id : RequestId := 1) : Json :=
  request id "initialize" <| Json.mkObj [
    ("capabilities", Json.mkObj [
      ("experimentalApi", true)
    ]),
    ("clientInfo", Json.mkObj [
      ("name", "llmlean"),
      ("title", "LLMlean"),
      ("version", "0.1.0")
    ])
  ]

def initializedNotification : Json :=
  notification "initialized"

def textInput (text : String) : Json :=
  Json.mkObj [
    ("type", "text"),
    ("text", text)
  ]

def inputTextContent (text : String) : Json :=
  Json.mkObj [
    ("type", "inputText"),
    ("text", text)
  ]

def threadStartRequest
    (id : RequestId := 2)
    (cwd : Option String := none)
    (approvalPolicy : Option Json := none)
    (sandbox : Option Json := none)
    (model : Option String := none)
    (dynamicTools : Option (Array Json) := some #[]) : Json :=
  request id "thread/start" <| jsonObj [
    ("approvalPolicy", approvalPolicy),
    ("sandbox", sandbox),
    ("cwd", cwd.map fun value => (value : Json)),
    ("model", model.map fun value => (value : Json)),
    ("dynamicTools", dynamicTools.map fun tools => Json.arr tools)
  ]

def turnStartRequest
    (id : RequestId := 3)
    (threadId : String)
    (prompt : String)
    (cwd : Option String := none)
    (title : Option String := none)
    (approvalPolicy : Option Json := none)
    (sandboxPolicy : Option Json := none)
    (model : Option String := none)
    (outputSchema : Option Json := none) : Json :=
  request id "turn/start" <| jsonObj [
    ("threadId", some (threadId : Json)),
    ("input", some (Json.arr #[textInput prompt])),
    ("cwd", cwd.map fun value => (value : Json)),
    ("title", title.map fun value => (value : Json)),
    ("approvalPolicy", approvalPolicy),
    ("sandboxPolicy", sandboxPolicy),
    ("model", model.map fun value => (value : Json)),
    ("outputSchema", outputSchema)
  ]

def dynamicToolResult (id : Json) (success : Bool) (output : String) : Json :=
  resultResponse id <| Json.mkObj [
    ("success", success),
    ("output", output),
    ("contentItems", Json.arr #[inputTextContent output])
  ]

def dynamicToolSuccess (id : Json) (output : String) : Json :=
  dynamicToolResult id true output

def dynamicToolFailure (id : Json) (output : String) : Json :=
  dynamicToolResult id false output

def approvalDecisionResponse (id : Json) (decision : String) : Json :=
  resultResponse id <| Json.mkObj [
    ("decision", decision)
  ]

def acceptForSessionResponse (id : Json) : Json :=
  approvalDecisionResponse id "acceptForSession"

def approvedForSessionResponse (id : Json) : Json :=
  approvalDecisionResponse id "approved_for_session"

def declineResponse (id : Json) : Json :=
  approvalDecisionResponse id "decline"

def mcpElicitationDeclineResponse (id : Json) : Json :=
  resultResponse id <| Json.mkObj [
    ("action", "decline")
  ]

def userInputAnswerResponse (id : Json) (answers : List (String × List String)) : Json :=
  let answerPayload :=
    answers.map fun answer =>
      (answer.1, Json.mkObj [
        ("answers", toJson answer.2)
      ])
  resultResponse id <| Json.mkObj [
    ("answers", Json.mkObj answerPayload)
  ]

def nonInteractiveInputAnswer : String :=
  "This is a non-interactive session. Operator input is unavailable."

def field? (json : Json) (key : String) : Option Json :=
  (json.getObjVal? key).toOption

def fieldString? (json : Json) (key : String) : Option String := do
  let value ← field? json key
  value.getStr?.toOption

def fieldNat? (json : Json) (key : String) : Option Nat := do
  let value ← field? json key
  value.getNat?.toOption

def fieldInt? (json : Json) (key : String) : Option Int := do
  let value ← field? json key
  value.getInt?.toOption

def fieldBool? (json : Json) (key : String) : Option Bool := do
  let value ← field? json key
  value.getBool?.toOption

def fieldArray? (json : Json) (key : String) : Option (Array Json) := do
  let value ← field? json key
  value.getArr?.toOption

def method? (message : Json) : Option String :=
  fieldString? message "method"

def hasMethod (message : Json) (method : String) : Bool :=
  match method? message with
  | some actual => actual == method
  | none => false

def id? (message : Json) : Option Json :=
  field? message "id"

def natId? (message : Json) : Option RequestId :=
  fieldNat? message "id"

def params? (message : Json) : Option Json :=
  field? message "params"

def atPath? (json : Json) : List String → Option Json
  | [] => some json
  | key :: rest => do
      let child ← field? json key
      atPath? child rest

def firstPath? (json : Json) : List (List String) → Option Json
  | [] => none
  | path :: rest =>
      match atPath? json path with
      | some value => some value
      | none => firstPath? json rest

def stringAtPath? (json : Json) (path : List String) : Option String := do
  let value ← atPath? json path
  value.getStr?.toOption

def firstStringPath? (json : Json) : List (List String) → Option String
  | [] => none
  | path :: rest =>
      match stringAtPath? json path with
      | some value => some value
      | none => firstStringPath? json rest

def resultFor? (expected : RequestId) (message : Json) : Option Json := do
  let actual ← natId? message
  if actual == expected then field? message "result" else none

def errorFor? (expected : RequestId) (message : Json) : Option RpcError := do
  let actual ← natId? message
  if actual == expected then
    let error ← field? message "error"
    some {
      code := fieldInt? error "code",
      message := (fieldString? error "message").getD "Codex app-server returned an error",
      data := field? error "data"
    }
  else
    none

def threadIdFromResult? (result : Json) : Option String := do
  let thread ← field? result "thread"
  fieldString? thread "id"

def threadIdFromResponse? (expected : RequestId) (message : Json) : Option String := do
  let result ← resultFor? expected message
  threadIdFromResult? result

def turnIdFromResult? (result : Json) : Option String := do
  let turn ← field? result "turn"
  fieldString? turn "id"

def turnIdFromResponse? (expected : RequestId) (message : Json) : Option String := do
  let result ← resultFor? expected message
  turnIdFromResult? result

def turnCompleted? (message : Json) : Bool :=
  hasMethod message "turn/completed"

def turnFailed? (message : Json) : Bool :=
  hasMethod message "turn/failed"

def turnCancelled? (message : Json) : Bool :=
  hasMethod message "turn/cancelled"

def isTurnInputRequiredMethod (method : String) : Bool :=
  method == "turn/input_required" ||
  method == "turn/needs_input" ||
  method == "turn/need_input" ||
  method == "turn/request_input" ||
  method == "turn/request_response" ||
  method == "turn/provide_input" ||
  method == "turn/approval_required"

def isInputRequiredMethod (method : String) : Bool :=
  isTurnInputRequiredMethod method || method == "mcpServer/elicitation/request"

def hasNeedsInputFlag (json : Json) : Bool :=
  (fieldBool? json "requiresInput").getD false ||
  (fieldBool? json "needsInput").getD false ||
  (fieldBool? json "input_required").getD false ||
  (fieldBool? json "inputRequired").getD false ||
  (fieldString? json "type" == some "input_required") ||
  (fieldString? json "type" == some "needs_input")

def payloadRequiresInput? (message : Json) : Bool :=
  hasNeedsInputFlag message ||
  match params? message with
  | some params => hasNeedsInputFlag params
  | none => false

def needsInput? (message : Json) : Bool :=
  match method? message with
  | some method =>
      method == "mcpServer/elicitation/request" ||
      (method.startsWith "turn/" &&
        (isTurnInputRequiredMethod method || payloadRequiresInput? message))
  | none => false

def toolCallName? (params : Json) : Option String :=
  match fieldString? params "tool" with
  | some name =>
      let trimmed := name.trim
      if trimmed == "" then none else some trimmed
  | none =>
      match fieldString? params "name" with
      | some name =>
          let trimmed := name.trim
          if trimmed == "" then none else some trimmed
      | none => none

def toolCallArguments (params : Json) : Json :=
  (field? params "arguments").getD emptyParams

def filterMapArray (f : α → Option β) (values : Array α) : Array β := Id.run do
  let mut out := #[]
  for value in values do
    match f value with
    | some mapped => out := out.push mapped
    | none => pure ()
  return out

def last? (values : Array α) : Option α :=
  if values.isEmpty then none else values[values.size - 1]?

def joinNonEmpty (parts : Array String) : Option String :=
  let parts := parts.filter fun part => part.trim.length > 0
  if parts.isEmpty then none else some ("\n".intercalate parts.toList)

def textField? (json : Json) : Option String :=
  match fieldString? json "text" with
  | some text => some text
  | none => fieldString? json "output"

def textFromArray? (items : Array Json) : Option String :=
  joinNonEmpty <| filterMapArray textField? items

def contentText? (json : Json) : Option String :=
  match field? json "content" with
  | some (.str text) => some text
  | some value =>
      match value.getArr?.toOption with
      | some items => textFromArray? items
      | none => none
  | none =>
      match fieldArray? json "contentItems" with
      | some items => textFromArray? items
      | none => textField? json

def itemText? (item : Json) : Option String :=
  match contentText? item with
  | some text => some text
  | none => textField? item

def isAgentItem (item : Json) : Bool :=
  match fieldString? item "role" with
  | some role => role == "assistant" || role == "agent"
  | none =>
      match fieldString? item "type" with
      | some kind => kind == "agentMessage" || kind == "assistantMessage"
      | none => false

def turnItems? (message : Json) : Option (Array Json) := do
  let items ← firstPath? message [
    ["params", "turn", "items"],
    ["turn", "items"],
    ["params", "items"],
    ["items"]
  ]
  items.getArr?.toOption

def extractMessageTexts (message : Json) : Array String :=
  match turnItems? message with
  | some items => filterMapArray itemText? items
  | none => #[]

def extractAgentMessages (message : Json) : Array String :=
  match turnItems? message with
  | some items => filterMapArray (fun item => if isAgentItem item then itemText? item else none) items
  | none => #[]

def finalAgentMessage? (message : Json) : Option String :=
  match last? (extractAgentMessages message) with
  | some text => some text
  | none => last? (extractMessageTexts message)

def isAgentTextMethod (method : String) : Bool :=
  method == "item/agentMessage/delta" ||
  method == "item/agentMessage" ||
  method == "agentMessage/delta" ||
  method == "turn/agent_message_delta" ||
  method == "turn/agent_message"

def agentTextUpdate? (message : Json) : Option String := do
  let method ← method? message
  if isAgentTextMethod method then
    match firstPath? message [["params", "item"], ["params", "message"]] with
    | some item =>
        match itemText? item with
        | some text => some text
        | none => firstStringPath? message [
            ["params", "delta"],
            ["params", "text"],
            ["params", "content"]
          ]
    | none => firstStringPath? message [
        ["params", "delta"],
        ["params", "text"],
        ["params", "content"]
      ]
  else
    none

end LLMlean.Codex.Protocol
