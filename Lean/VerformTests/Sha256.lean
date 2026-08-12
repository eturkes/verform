import Verform.Sha256

namespace VerformTests.Sha256

private structure TestVector where
  label : String
  input : String
  expected : String

private def vectors : Array TestVector := #[
  {
    label := "empty"
    input := ""
    expected := "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  },
  {
    label := "abc"
    input := "abc"
    expected := "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  },
  {
    label := "two-block"
    input := "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
    expected := "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
  },
  {
    label := "quick-brown-fox"
    input := "The quick brown fox jumps over the lazy dog"
    expected := "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"
  }
]

def tests : IO Unit := do
  for vector in vectors do
    let actual := Verform.Sha256.hash vector.input.toByteArray
    unless actual == vector.expected do
      throw <| IO.userError s!"SHA-256 {vector.label}: expected {vector.expected}, got {actual}"
  IO.FS.withTempFile fun handle path => do
    handle.write "abc".toByteArray
    handle.flush
    let actual ← Verform.Sha256.hashFile path
    let expected := "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    unless actual == expected do
      throw <| IO.userError s!"SHA-256 file: expected {expected}, got {actual}"

end VerformTests.Sha256
