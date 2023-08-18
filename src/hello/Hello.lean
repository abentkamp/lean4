
import Lean

open Lean Core

axiom a : Type

def main (args: List String) : IO Unit := do
  -- IO.println s!"Hello, world! {args}"
  let code ← IO.FS.readFile args[0]!
  let (env, ok) ← Lean.Elab.runFrontend code {} args[0]! "File" 0
  if ok then
    writeModule env args[1]!
