
import Lean

open Lean Core

axiom a : Type

def main (args: List String) : IO Unit := do
  -- IO.println s!"Hello, world! {args}"
  discard $ Lean.Elab.runFrontend args[0]! {} "<file>" "File"
