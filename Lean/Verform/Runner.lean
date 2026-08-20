import Std
import Std.Internal.UV.System

namespace Verform.Runner

private def supervisorScript :=
  "limit=$1; stdout=$2; stderr=$3; supervisor_stderr=$4; shift 4; " ++
  "locale_set=${LC_ALL+x}; locale=${LC_ALL-}; export LC_ALL=C; " ++
  "exec setpriv --pdeathsig KILL timeout --verbose --signal=TERM --kill-after=1s \"$limit\" " ++
    "setpriv --pdeathsig KILL unshare --kill-child=KILL --user --map-current-user --pid " ++
    "--fork --mount-proc -- " ++
    "sh -c 'stdout=$1; stderr=$2; locale_set=$3; locale=$4; shift 4; " ++
      "if [ \"$locale_set\" = x ]; then export LC_ALL=\"$locale\"; else unset LC_ALL; fi; " ++
      "exec \"$@\" >\"$stdout\" 2>\"$stderr\"' " ++
    "verform-command \"$stdout\" \"$stderr\" \"$locale_set\" \"$locale\" \"$@\" " ++
    "2>\"$supervisor_stderr\""

private def forcedTimeoutMarker := "timeout: sending signal KILL to command 'setpriv'"

private structure CapturedOutput where
  exitCode : UInt32
  stdout : String
  stderr : String
  supervisorStderr : String

structure Result where
  command : Array String
  exitCode : UInt32
  stdout : String
  stderr : String
  failure : String := ""
  deriving Repr

def Result.ok (result : Result) : Bool :=
  result.exitCode == 0 && result.failure.isEmpty

private def presentationUnsafe (character : Char) : Bool :=
  let code := character.toNat
  (code < 0x20 && code != 0x09 && code != 0x0a) ||
    (0x7f ≤ code && code ≤ 0x9f) || code == 0x061c ||
    (0x200b ≤ code && code ≤ 0x200f) || (0x202a ≤ code && code ≤ 0x202e) ||
    (0x2060 ≤ code && code ≤ 0x206f) || code == 0xfeff

def plainText (value : String) : String :=
  String.ofList <| value.toList.map fun character =>
    if presentationUnsafe character then '�' else character

private def blockedNames : Array String :=
  #["BASH_ENV", "ENV", "ELAN_TOOLCHAIN", "LD_AUDIT", "LD_LIBRARY_PATH", "LD_PRELOAD"]

private def blockedPrefixes : Array String := #["DYLD_", "LAKE_", "LEAN_"]

private def isBlockedName (name : String) : Bool :=
  blockedNames.contains name || blockedPrefixes.any (fun p => name.startsWith p)

private def controlledEnvironment
    (overrides : Array (String × Option String)) : IO (Array (String × Option String)) := do
  let inherited ← Std.Internal.UV.System.osEnviron
  let inheritedBlocks := inherited.filterMap fun (name, _) =>
    if isBlockedName name then some (name, none) else none
  let explicitBlocks := blockedNames.map fun name => (name, none)
  let safeOverrides := overrides.filter fun (name, _) => !isBlockedName name
  return explicitBlocks ++ inheritedBlocks ++ safeOverrides

def run
    (command : Array String)
    (cwd : System.FilePath)
    (stdin : Option String := none)
    (timeoutSeconds : Nat := 600)
    (environment : Array (String × Option String) := #[])
    (outputLimitBytes : Nat := 8 * 1024 * 1024) : IO Result := do
  let some executable := command[0]?
    | return {
        command := command
        exitCode := 126
        stdout := ""
        stderr := ""
        failure := "cannot execute an empty command"
      }
  try
    let processEnvironment ← controlledEnvironment environment
    let (_, stdoutPath) ← IO.FS.createTempFile
    let output ← try
      let (_, stderrPath) ← IO.FS.createTempFile
      try
        let (_, supervisorStderrPath) ← IO.FS.createTempFile
        try
          let processOutput ← IO.Process.output {
            cmd := "sh"
            args := #["-c", supervisorScript, "verform-supervisor", s!"{timeoutSeconds}s",
              stdoutPath.toString, stderrPath.toString, supervisorStderrPath.toString,
              executable] ++ command.extract 1 command.size
            cwd := some cwd
            env := processEnvironment
            inheritEnv := true
            setsid := false
          } stdin
          let stdout ← IO.FS.readFile stdoutPath
          let stderr ← IO.FS.readFile stderrPath
          let supervisorStderr ← IO.FS.readFile supervisorStderrPath
          pure ({exitCode := processOutput.exitCode, stdout, stderr, supervisorStderr} : CapturedOutput)
        finally
          if ← supervisorStderrPath.pathExists then IO.FS.removeFile supervisorStderrPath
      finally
        if ← stderrPath.pathExists then IO.FS.removeFile stderrPath
    finally
      if ← stdoutPath.pathExists then IO.FS.removeFile stdoutPath
    let forcedTimeout := output.exitCode == (137 : UInt32) &&
      output.supervisorStderr.contains forcedTimeoutMarker
    let timedOut := output.exitCode == (124 : UInt32) || forcedTimeout
    let stderr := if timedOut then output.stderr else output.stderr ++ output.supervisorStderr
    if output.exitCode == (127 : UInt32) && (stderr.contains "failed to run command" ||
        stderr.contains "failed to execute") then
      return {
        command := command
        exitCode := 127
        stdout := output.stdout
        stderr
        failure := s!"command not found: {executable}"
      }
    let outputBytes := output.stdout.toUTF8.size + stderr.toUTF8.size
    if outputBytes > outputLimitBytes then
      return {
        command := command
        exitCode := 125
        stdout := output.stdout
        stderr
        failure := s!"combined stdout/stderr exceeded {outputLimitBytes}-byte capture limit"
      }
    if timedOut then
      return {
        command := command
        exitCode := 124
        stdout := output.stdout
        stderr
        failure := s!"timed out after {timeoutSeconds}s"
      }
    return {
      command
      exitCode := output.exitCode
      stdout := output.stdout
      stderr
    }
  catch error =>
    return {
      command := command
      exitCode := 126
      stdout := ""
      stderr := ""
      failure := s!"cannot execute {executable}: {error}"
    }

def diagnostic (result : Result) (maxLines : Nat := 40) : Array String :=
  let initial := if result.failure.isEmpty then #[] else #[plainText result.failure]
  let combined := [plainText result.stdout.trimAscii.toString,
    plainText result.stderr.trimAscii.toString]
    |>.filter (fun value => !value.isEmpty)
    |> String.intercalate "\n"
  let lines := combined.splitOn "\n" |>.toArray
  if lines.size ≤ maxLines then initial ++ lines
  else
    initial ++ #[s!"… {lines.size - maxLines} earlier output line(s) omitted"] ++
      lines.extract (lines.size - maxLines) lines.size

end Verform.Runner
