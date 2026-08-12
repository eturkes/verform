import Init.Data.ByteArray
import Init.System.IO

/-! Pure Lean SHA-256 with a lowercase hexadecimal interface. -/

namespace Verform.Sha256

private structure State where
  a : UInt32
  b : UInt32
  c : UInt32
  d : UInt32
  e : UInt32
  f : UInt32
  g : UInt32
  h : UInt32

private def initial : State := {
  a := 0x6a09e667
  b := 0xbb67ae85
  c := 0x3c6ef372
  d := 0xa54ff53a
  e := 0x510e527f
  f := 0x9b05688c
  g := 0x1f83d9ab
  h := 0x5be0cd19
}

private def roundWords : Array UInt32 := #[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
]

@[inline]
private def rotateRight (x n : UInt32) : UInt32 :=
  (x >>> n) ||| (x <<< (32 - n))

@[inline]
private def choose (x y z : UInt32) : UInt32 :=
  (x &&& y) ^^^ (~~~x &&& z)

@[inline]
private def majority (x y z : UInt32) : UInt32 :=
  (x &&& y) ^^^ (x &&& z) ^^^ (y &&& z)

@[inline]
private def bigSigma0 (x : UInt32) : UInt32 :=
  rotateRight x 2 ^^^ rotateRight x 13 ^^^ rotateRight x 22

@[inline]
private def bigSigma1 (x : UInt32) : UInt32 :=
  rotateRight x 6 ^^^ rotateRight x 11 ^^^ rotateRight x 25

@[inline]
private def smallSigma0 (x : UInt32) : UInt32 :=
  rotateRight x 7 ^^^ rotateRight x 18 ^^^ (x >>> 3)

@[inline]
private def smallSigma1 (x : UInt32) : UInt32 :=
  rotateRight x 17 ^^^ rotateRight x 19 ^^^ (x >>> 10)

@[inline]
private def byteWord (bytes : ByteArray) (i : Nat) : UInt32 :=
  UInt32.ofNat (bytes.get! i).toNat

private def readWord (bytes : ByteArray) (offset : Nat) : UInt32 :=
  (byteWord bytes offset <<< 24) |||
  (byteWord bytes (offset + 1) <<< 16) |||
  (byteWord bytes (offset + 2) <<< 8) |||
  byteWord bytes (offset + 3)

private def schedule (bytes : ByteArray) (offset : Nat) : Array UInt32 := Id.run do
  let mut words := Array.replicate 64 0
  for i in [0:16] do
    words := words.set! i (readWord bytes (offset + 4 * i))
  for i in [16:64] do
    let next := smallSigma1 words[i - 2]! + words[i - 7]! +
      smallSigma0 words[i - 15]! + words[i - 16]!
    words := words.set! i next
  return words

private def compress (state : State) (bytes : ByteArray) (offset : Nat) : State := Id.run do
  let words := schedule bytes offset
  let mut a := state.a
  let mut b := state.b
  let mut c := state.c
  let mut d := state.d
  let mut e := state.e
  let mut f := state.f
  let mut g := state.g
  let mut h := state.h
  for i in [0:64] do
    let t1 := h + bigSigma1 e + choose e f g + roundWords[i]! + words[i]!
    let t2 := bigSigma0 a + majority a b c
    h := g
    g := f
    f := e
    e := d + t1
    d := c
    c := b
    b := a
    a := t1 + t2
  return {
    a := state.a + a
    b := state.b + b
    c := state.c + c
    d := state.d + d
    e := state.e + e
    f := state.f + f
    g := state.g + g
    h := state.h + h
  }

private def pad (input : ByteArray) : ByteArray := Id.run do
  let bitLength : UInt64 := UInt64.ofNat input.size * 8
  let zeroCount := (55 + 64 - input.size % 64) % 64
  let mut bytes := input.push 0x80
  for _ in [0:zeroCount] do
    bytes := bytes.push 0
  bytes := bytes.push (bitLength >>> 56).toUInt8
  bytes := bytes.push (bitLength >>> 48).toUInt8
  bytes := bytes.push (bitLength >>> 40).toUInt8
  bytes := bytes.push (bitLength >>> 32).toUInt8
  bytes := bytes.push (bitLength >>> 24).toUInt8
  bytes := bytes.push (bitLength >>> 16).toUInt8
  bytes := bytes.push (bitLength >>> 8).toUInt8
  bytes := bytes.push bitLength.toUInt8
  return bytes

private def runBlocks (bytes : ByteArray) : State := Id.run do
  let mut state := initial
  for block in [0:bytes.size / 64] do
    state := compress state bytes (block * 64)
  return state

@[inline]
private def hexDigit (n : Nat) : Char :=
  if n < 10 then Char.ofNat (48 + n) else Char.ofNat (87 + n)

private def wordChars (word : UInt32) : List Char :=
  (List.range 8).map fun i =>
    hexDigit ((word >>> UInt32.ofNat ((7 - i) * 4)).toNat % 16)

private def stateHex (state : State) : String :=
  String.ofList <|
    wordChars state.a ++ wordChars state.b ++ wordChars state.c ++ wordChars state.d ++
    wordChars state.e ++ wordChars state.f ++ wordChars state.g ++ wordChars state.h

/-- Hashes arbitrary bytes to a lowercase, 64-character SHA-256 value. -/
def hash (input : ByteArray) : String :=
  stateHex (runBlocks (pad input))

/-- Hashes a file's binary contents to a lowercase, 64-character SHA-256 value. -/
def hashFile (path : System.FilePath) : IO String := do
  return hash (← IO.FS.readBinFile path)

end Verform.Sha256
