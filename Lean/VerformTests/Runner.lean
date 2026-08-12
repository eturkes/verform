import Verform.Runner

namespace VerformTests.Runner

private def assert (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw <| IO.userError message

def tests : IO Unit := do
  let ok ← Verform.Runner.run #["sh", "-c", "printf out; printf err >&2"] "."
  assert ok.ok "runner success"
  assert (ok.stdout == "out") "runner stdout"
  assert (ok.stderr == "err") "runner stderr"
  let missing ← Verform.Runner.run #["verform-command-that-does-not-exist"] "."
  assert (!missing.ok) "runner missing command"
  assert (missing.exitCode == 127) "runner missing exit"
  let timeout ← Verform.Runner.run #["sh", "-c", "sleep 2"] "." none 1
  assert (timeout.exitCode == 124) "runner timeout exit"
  assert (!timeout.ok) "runner timeout failure"
  let started ← IO.monoNanosNow
  let background ← Verform.Runner.run #["sh", "-c", "sleep 4 &"] "." none 1
  let elapsed ← IO.monoNanosNow
  assert background.ok "runner background descendant namespace teardown"
  assert (elapsed - started < 3 * 1000 * 1000 * 1000) "runner capture deadline"
  let escapedStarted ← IO.monoNanosNow
  let escaped ← Verform.Runner.run #["sh", "-c", "setsid sh -c 'sleep 4' &"] "." none 1
  let escapedElapsed ← IO.monoNanosNow
  assert escaped.ok "runner escaped session leader result"
  assert (escapedElapsed - escapedStarted < 3 * 1000 * 1000 * 1000)
    "runner escaped session capture deadline"
  let directStarted ← IO.monoNanosNow
  let direct ← Verform.Runner.run
    #["setsid", "sh", "-c", "while :; do sleep 8; done", "verform-runner-direct-escape"]
    "." none 1
  let directElapsed ← IO.monoNanosNow
  assert (!direct.ok) "runner direct session escape deadline"
  assert (directElapsed - directStarted < 3 * 1000 * 1000 * 1000)
    "runner direct session escape deadline bound"
  let survivors ← Verform.Runner.run
    #["sh", "-c", "! pgrep -f '[v]erform-runner-direct-escape'"] "." none 10
  assert survivors.ok "runner direct session escape teardown"
  let nestedSource := "" ++
    "import Verform.Runner\n" ++
    "#eval do\n" ++
    "  let result ← Verform.Runner.run #[\"sh\", \"-c\", \"printf nested\"] \".\" none 5\n" ++
    "  unless result.ok && result.stdout == \"nested\" do throw <| IO.userError \"nested runner failed\"\n"
  let nested ← Verform.Runner.run #["lake", "env", "lean", "--stdin"] "." (some nestedSource) 30
  assert nested.ok "nested runner composition"
  let scrubbed ← Verform.Runner.run
    #["sh", "-c", "test -z \"${LEAN_VERFORM_SENTINEL+x}\""] "." none 10
    #[("LEAN_VERFORM_SENTINEL", some "must-not-propagate")]
  assert scrubbed.ok "runner Lean/Lake prefix scrub"
  assert (Verform.Runner.plainText "x\x1b[2Jy" == "x�[2Jy") "runner control sanitization"
  assert (Verform.Runner.plainText "left\u202eright\u009b" == "left�right�")
    "runner bidirectional and C1 sanitization"

end VerformTests.Runner
