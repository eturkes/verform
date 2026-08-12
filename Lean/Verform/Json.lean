import Lean.Data.Json

namespace Verform.Json

open Lean

def escape (value : String) : String :=
  Json.compress (.str value)

def object (fields : Array (String × String)) (indent := 0) : String :=
  if fields.isEmpty then "{}" else
    let padding := String.ofList (List.replicate indent ' ')
    let inner := String.ofList (List.replicate (indent + 2) ' ')
    let values := fields.map fun (key, value) => s!"{inner}{escape key}: {value}"
    "{\n" ++ String.intercalate ",\n" values.toList ++ "\n" ++ padding ++ "}"

def array (values : Array String) (indent := 0) : String :=
  if values.isEmpty then "[]" else
    let padding := String.ofList (List.replicate indent ' ')
    let inner := String.ofList (List.replicate (indent + 2) ' ')
    "[\n" ++ String.intercalate ",\n" (values.map (inner ++ ·)).toList ++ s!"\n{padding}]"

def strings (values : Array String) (indent := 0) : String :=
  array (values.map escape) indent

def bool (value : Bool) : String := if value then "true" else "false"

def nat (value : Nat) : String := toString value

def nullable (value : Option String) : String := value.getD "null"

end Verform.Json
