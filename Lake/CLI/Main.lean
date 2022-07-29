/-
Copyright (c) 2021 Mac Malone. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Mac Malone
-/
import Lake.Load
import Lake.Build.Imports
import Lake.Util.Error
import Lake.Util.MainM
import Lake.Util.Cli
import Lake.CLI.Init
import Lake.CLI.Help
import Lake.CLI.Build
import Lake.CLI.Error

-- # CLI

open System
open Lean (Json toJson fromJson?)

namespace Lake

/-! ## General options for top-level `lake` -/

structure LakeOptions where
  rootDir : FilePath := "."
  configFile : FilePath := defaultConfigFile
  leanInstall? : Option LeanInstall := none
  lakeInstall? : Option LakeInstall := none
  configOpts : NameMap String := {}
  subArgs : List String := []
  wantsHelp : Bool := false
  verbosity : Verbosity := .normal

/-- Get the Lean installation. Error if missing. -/
def LakeOptions.getLeanInstall (opts : LakeOptions) : Except CliError LeanInstall :=
  match opts.leanInstall? with
  | none => .error CliError.unknownLeanInstall
  | some lean => .ok lean

/-- Get the Lake installation. Error if missing. -/
def LakeOptions.getLakeInstall (opts : LakeOptions) : Except CliError LakeInstall :=
  match opts.lakeInstall? with
  | none => .error CliError.unknownLakeInstall
  | some lake => .ok lake

/-- Get the Lean and Lake installation. Error if either is missing. -/
def LakeOptions.getInstall (opts : LakeOptions) : Except CliError (LeanInstall × LakeInstall) := do
  return (← opts.getLeanInstall, ← opts.getLakeInstall)

/-- Compute the Lake environment based on `opts`. Error if an install is missing. -/
def LakeOptions.computeEnv (opts : LakeOptions) : EIO CliError Lake.Env := do
  Env.compute (← opts.getLakeInstall) (← opts.getLeanInstall)

/-- Make a `LoadConfig` from a `LakeOptions`. -/
def LakeOptions.mkLoadConfig
(opts : LakeOptions) (updateDeps := false) : EIO CliError LoadConfig :=
  return {
    env := ← opts.computeEnv
    rootDir := opts.rootDir
    configFile := opts.rootDir / opts.configFile
    configOpts := opts.configOpts
    leanOpts := Lean.Options.empty
    verbosity := opts.verbosity
    updateDeps
  }

export LakeOptions (mkLoadConfig)

/-! ## Monad -/

abbrev CliMainM := ExceptT CliError MainM
abbrev CliStateM := StateT LakeOptions CliMainM
abbrev CliM := ArgsT CliStateM

def CliM.run (self : CliM α) (args : List String) : BaseIO ExitCode := do
  let (leanInstall?, lakeInstall?) ← findInstall?
  let main := self args |>.run' {leanInstall?, lakeInstall?}
  let main := main.run >>= fun | .ok a => pure a | .error e => error e.toString
  main.run

instance : MonadLift LogIO CliStateM :=
  ⟨fun x => do MainM.runLogIO x (← get).verbosity⟩

instance : MonadLift OptionIO MainM where
  monadLift x := x.adaptExcept (fun _ => 1)

/-! ## Argument Parsing -/

def takeArg (arg : String) : CliM String := do
  match (← takeArg?) with
  | none => throw <| CliError.missingArg arg
  | some arg => pure arg

def takeOptArg (opt arg : String) : CliM String := do
  match (← takeArg?) with
  | none => throw <| CliError.missingOptArg opt arg
  | some arg => pure arg

/--
Verify that there are no CLI arguments remaining
before running the given action.
-/
def noArgsRem (act : CliStateM α) : CliM α := do
  let args ← getArgs
  if args.isEmpty then act else
    throw <| CliError.unexpectedArguments args

/-! ## Option Parsing -/

def getWantsHelp : CliStateM Bool :=
  (·.wantsHelp) <$> get

def setLean (lean : String) : CliStateM PUnit := do
  let leanInstall? ← findLeanCmdInstall? lean
  modify ({·  with leanInstall?})

def setConfigOpt (kvPair : String) : CliM PUnit :=
  let pos := kvPair.posOf '='
  let (key, val) :=
    if pos = kvPair.endPos then
      (kvPair.toName, "")
    else
      (kvPair.extract 0 pos |>.toName, kvPair.extract (kvPair.next pos) kvPair.endPos)
  modifyThe LakeOptions fun opts =>
    {opts with configOpts := opts.configOpts.insert key val}

def lakeShortOption : (opt : Char) → CliM PUnit
| 'h' => modifyThe LakeOptions ({· with wantsHelp := true})
| 'q' => modifyThe LakeOptions ({· with verbosity := .quiet})
| 'v' => modifyThe LakeOptions ({· with verbosity := .verbose})
| 'd' => do let rootDir ← takeOptArg "-d" "path"; modifyThe LakeOptions ({· with rootDir})
| 'f' => do let configFile ← takeOptArg "-f" "path"; modifyThe LakeOptions ({· with configFile})
| 'K' => do setConfigOpt <| ← takeOptArg "-K" "key-value pair"
| opt => throw <| CliError.unknownShortOption opt

def lakeLongOption : (opt : String) → CliM PUnit
| "--help"    => modifyThe LakeOptions ({· with wantsHelp := true})
| "--quiet"   => modifyThe LakeOptions ({· with verbosity := .quiet})
| "--verbose" => modifyThe LakeOptions ({· with verbosity := .verbose})
| "--dir"     => do let rootDir ← takeOptArg "--dir" "path"; modifyThe LakeOptions ({· with rootDir})
| "--file"    => do let configFile ← takeOptArg "--file" "path"; modifyThe LakeOptions ({· with configFile})
| "--lean"    => do setLean <| ← takeOptArg "--lean" "path or command"
| "--"        => do let subArgs ← takeArgs; modifyThe LakeOptions ({· with subArgs})
| opt         => throw <| CliError.unknownLongOption opt

def lakeOption :=
  option {
    short := lakeShortOption
    long := lakeLongOption
    longShort := shortOptionWithArg lakeShortOption
  }

/-! ## Actions -/

/-- Verify the Lean version Lake was built with matches that of the give Lean installation. -/
def verifyLeanVersion (leanInstall : LeanInstall) : Except CliError PUnit := do
  unless leanInstall.githash == Lean.githash do
    throw <| CliError.leanRevMismatch Lean.githash leanInstall.githash

/-- Output the detected installs and verify the Lean version. -/
def verifyInstall (opts : LakeOptions) : ExceptT CliError MainM PUnit := do
  IO.println s!"Lean:\n{repr <| opts.leanInstall?}"
  IO.println s!"Lake:\n{repr <| opts.lakeInstall?}"
  let (leanInstall, _) ← opts.getInstall
  verifyLeanVersion leanInstall

/-- Exit code to return if `print-paths` cannot find the config file. -/
def noConfigFileCode : ExitCode := 2

/--
Environment variable that is set when `lake serve` cannot parse the Lake configuration file
and falls back to plain `lean --server`.
-/
def invalidConfigEnvVar := "LAKE_INVALID_CONFIG"

/--
Build a list of imports of the package
and print the `.olean` and source directories of every used package.
If no configuration file exists, exit silently with `noConfigFileCode` (i.e, 2).

The `print-paths` command is used internally by Lean 4 server.
-/
def printPaths (config : LoadConfig) (imports : List String := []) : MainM PUnit := do
  let configFile := config.rootDir / config.configFile
  if (← configFile.pathExists) then
    if (← IO.getEnv invalidConfigEnvVar) matches some .. then
      IO.eprintln s!"Error parsing '{configFile}'.  Please restart the lean server after fixing the Lake configuration file."
      exit 1
    let ws ← MainM.runLogIO (loadWorkspace config) config.verbosity
    let ctx ← mkBuildContext ws
    let dynlibs ← ws.root.buildImportsAndDeps imports |>.run (MonadLog.eio config.verbosity) ctx
    IO.println <| Json.compress <| toJson {ws.leanPaths with loadDynlibPaths := dynlibs}
  else
    exit noConfigFileCode

def env (cmd : String) (args : Array String := #[]) : LakeT IO UInt32 := do
  IO.Process.spawn {cmd, args, env := ← getAugmentedEnv} >>= (·.wait)

def serve (config : LoadConfig) (args : Array String) : LogIO UInt32 := do
  let (extraEnv, moreServerArgs) ←
    try
      let ws ← loadWorkspace config
      let ctx := mkLakeContext ws
      pure (← LakeT.run ctx getAugmentedEnv, ws.root.moreServerArgs)
    catch _ =>
      logWarning "package configuration has errors, falling back to plain `lean --server`"
      pure (config.env.installVars.push (invalidConfigEnvVar, "1"), #[])
  (← IO.Process.spawn {
    cmd := config.env.lean.lean.toString
    args := #["--server"] ++ moreServerArgs ++ args
    env := extraEnv
  }).wait

def exe (name : Name) (args  : Array String := #[]) (verbosity : Verbosity) : LakeT IO UInt32 := do
  let ws ← getWorkspace
  if let some exe := ws.findLeanExe? name then
    let ctx ← mkBuildContext ws
    let exeFile ← (exe.build >>= (·.await)).run (MonadLog.eio verbosity) ctx
    env exeFile.toString args
  else
    error s!"unknown executable `{name}`"

def uploadRelease (pkg : Package) (tag : String) : BuildIO Unit := do
  let archiveName := pkg.releaseArchive?.getD tag
  let archiveFileName := s!"{archiveName}-{osDescriptor}.tar.gz"
  let archiveFile := pkg.buildDir / archiveFileName
  let mut args := #["release", "upload", tag, archiveFile.toString]
  if let some repo := pkg.releaseRepo? then
    args := args.append #["-R", repo]
  tar archiveFileName pkg.buildDir archiveFile (excludePaths := #["*.tar.gz", "*.tar.gz.trace"])
  logAuxInfo s!"Uploading {tag}/{archiveFileName}"
  proc {cmd := "gh", args}

def parseScriptSpec (ws : Workspace) (spec : String) : Except CliError (Package × String) :=
  match spec.splitOn "/" with
  | [script] => return (ws.root, script)
  | [pkg, script] => return (← parsePackageSpec ws pkg, script)
  | _ => throw <| CliError.invalidScriptSpec spec

def parseTemplateSpec (spec : String) : Except CliError InitTemplate :=
  if spec.isEmpty then
    pure default
  else if let some tmp := InitTemplate.parse? spec then
    pure tmp
  else
    throw <| CliError.unknownTemplate spec

/-! ## Commands -/

namespace lake

/-! ### `lake script` CLI -/

namespace script

protected def list : CliM PUnit := do
  processOptions lakeOption
  let config ← mkLoadConfig (← getThe LakeOptions)
  noArgsRem do
    let ws ← loadWorkspace config
    ws.packageMap.forM fun _ pkg => do
      let pkgName := pkg.name.toString (escape := false)
      pkg.scripts.forM fun name _ =>
        let scriptName := name.toString (escape := false)
        IO.println s!"{pkgName}/{scriptName}"

protected nonrec def run : CliM PUnit := do
  processOptions lakeOption
  let spec ← takeArg "script name"; let args ← takeArgs
  let config ← mkLoadConfig (← getThe LakeOptions)
  let ws ← loadWorkspace config
  let (pkg, scriptName) ← parseScriptSpec ws spec
  if let some script := pkg.scripts.find? scriptName then
    exit <| ← script.run args |>.run {
      opaqueWs := ws
    }
  else do
    throw <| CliError.unknownScript scriptName

protected def doc : CliM PUnit := do
  processOptions lakeOption
  let spec ← takeArg "script name"
  let config ← mkLoadConfig (← getThe LakeOptions)
  noArgsRem do
    let ws ← loadWorkspace config
    let (pkg, scriptName) ← parseScriptSpec ws spec
    if let some script := pkg.scripts.find? scriptName then
      match script.doc? with
      | some doc => IO.println doc
      | none => throw <| CliError.missingScriptDoc scriptName
    else
      throw <| CliError.unknownScript scriptName

protected def help : CliM PUnit := do
  IO.println <| helpScript <| (← takeArg?).getD ""

end script

def scriptCli : (cmd : String) → CliM PUnit
| "list"  => script.list
| "run"   => script.run
| "doc"   => script.doc
| "help"  => script.help
| cmd     => throw <| CliError.unknownCommand cmd

/-! ### `lake` CLI -/

protected def new : CliM PUnit := do
  processOptions lakeOption
  let pkgName ← takeArg "package name"
  let template ← parseTemplateSpec <| (← takeArg?).getD ""
  noArgsRem do MainM.runLogIO (new pkgName template) (← getThe LakeOptions).verbosity

protected def init : CliM PUnit := do
  processOptions lakeOption
  let pkgName ← takeArg "package name"
  let template ← parseTemplateSpec <| (← takeArg?).getD ""
  noArgsRem do MainM.runLogIO (init pkgName template) (← getThe LakeOptions).verbosity

protected def build : CliM PUnit := do
  processOptions lakeOption
  let opts ← getThe LakeOptions
  let config ← mkLoadConfig opts
  let ws ← loadWorkspace config
  let targetSpecs ← takeArgs
  let specs ← parseTargetSpecs ws targetSpecs
  let ctx ← mkBuildContext ws
  BuildM.run (MonadLog.io config.verbosity) ctx <| buildSpecs specs

protected def update : CliM PUnit := do
  processOptions lakeOption
  let config ← mkLoadConfig (← getThe LakeOptions) (updateDeps := true)
  noArgsRem do discard <| loadWorkspace config

protected def upload : CliM PUnit := do
  processOptions lakeOption
  let tag ← takeArg "release tag"
  let opts ← getThe LakeOptions
  let config ← mkLoadConfig opts
  let ws ← loadWorkspace config
  noArgsRem do
    liftM <| uploadRelease ws.root tag |>.run (MonadLog.io opts.verbosity)

protected def printPaths : CliM PUnit := do
  processOptions lakeOption
  let config ← mkLoadConfig (← getThe LakeOptions)
  printPaths config (← takeArgs)

protected def clean : CliM PUnit := do
  processOptions lakeOption
  let config ← mkLoadConfig (← getThe LakeOptions)
  noArgsRem do (← loadWorkspace config).root.clean

protected def script : CliM PUnit := do
  if let some cmd ← takeArg? then
    processLeadingOptions lakeOption -- between `lake script <cmd>` and args
    if (← getWantsHelp) then
      IO.println <| helpScript cmd
    else
      scriptCli cmd
  else
    throw <| CliError.missingCommand

protected def serve : CliM PUnit := do
  processOptions lakeOption
  let opts ← getThe LakeOptions
  let args := opts.subArgs.toArray
  let config ← mkLoadConfig opts
  noArgsRem do exit <| ← serve config args

protected def env : CliM PUnit := do
  let cmd ← takeArg "command"; let args ← takeArgs
  let config ← mkLoadConfig (← getThe LakeOptions)
  let ws ← loadWorkspace config
  let ctx := mkLakeContext ws
  exit <| ← (env cmd args.toArray).run ctx

protected def exe : CliM PUnit := do
  let exeName ← takeArg "executable name"; let args ← takeArgs
  let config ← mkLoadConfig (← getThe LakeOptions)
  let ws ← loadWorkspace config
  let ctx := mkLakeContext ws
  exit <| ← (exe exeName args.toArray config.verbosity).run ctx

protected def selfCheck : CliM PUnit := do
  processOptions lakeOption
  noArgsRem do verifyInstall (← getThe LakeOptions)

protected def help : CliM PUnit := do
  IO.println <| help <| (← takeArg?).getD ""

end lake

def lakeCli : (cmd : String) → CliM PUnit
| "new"         => lake.new
| "init"        => lake.init
| "build"       => lake.build
| "update"      => lake.update
| "upload"      => lake.upload
| "print-paths" => lake.printPaths
| "clean"       => lake.clean
| "script"      => lake.script
| "scripts"     => lake.script.list
| "run"         => lake.script.run
| "serve"       => lake.serve
| "env"         => lake.env
| "exe"         => lake.exe
| "self-check"  => lake.selfCheck
| "help"        => lake.help
| cmd           => throw <| CliError.unknownCommand cmd

def lake : CliM PUnit := do
  match (← getArgs) with
  | [] => IO.println usage
  | ["--version"] => IO.println uiVersionString
  | _ => -- normal CLI
    processLeadingOptions lakeOption -- between `lake` and command
    if let some cmd ← takeArg? then
      processLeadingOptions lakeOption -- between `lake <cmd>` and args
      if (← getWantsHelp) then
        IO.println <| help cmd
      else
        lakeCli cmd
    else
      if (← getWantsHelp) then
        IO.println usage
      else
        throw <| CliError.missingCommand

def cli (args : List String) : BaseIO ExitCode :=
  (lake).run args
