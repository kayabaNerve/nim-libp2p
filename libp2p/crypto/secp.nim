## Nim-Libp2p
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.
import strutils
import secp256k1, nimcrypto/sysrand, nimcrypto/utils, nimcrypto/hash,
       nimcrypto/sha2
export sha2

const
  SkRawPrivateKeySize* = 256 div 8
    ## Size of private key in octets (bytes)
  SkRawSignatureSize* = SkRawPrivateKeySize * 2 + 1
    ## Size of signature in octets (bytes)
  SkRawPublicKeySize* = SkRawPrivateKeySize + 1
    ## Size of public key in octets (bytes)

type
  SkPublicKey* = secp256k1_pubkey
    ## Representation of public key.

  SkPrivateKey* = object
    ## Representation of secret key.
    data*: array[SkRawPrivateKeySize, byte]

  SkKeyPair* = object
    ## Representation of private/public keys pair.
    seckey*: SkPrivateKey
    pubkey*: SkPublicKey

  SkSignature* = secp256k1_ecdsa_recoverable_signature
    ## Representation of signature.

  SkContext* = ref object
    ## Representation of Secp256k1 context object.
    context: ptr secp256k1_context
    error: string

  Secp256k1Error* = object of CatchableError
    ## Exceptions generated by `libsecp256k1`

##
## Private procedures interface
##

var secpContext {.threadvar.}: SkContext
  ## Thread local variable which holds current context

proc illegalCallback(message: cstring, data: pointer) {.cdecl.} =
  let ctx = cast[SkContext](data)
  ctx.error = $message

proc errorCallback(message: cstring, data: pointer) {.cdecl.} =
  let ctx = cast[SkContext](data)
  ctx.error = $message

proc shutdownLibsecp256k1(ctx: SkContext) =
  # TODO: use destructor when finalizer are deprecated for destructors
  if not(isNil(ctx.context)):
    secp256k1_context_destroy(ctx.context)

proc newSkContext(): SkContext =
  ## Create new Secp256k1 context object.
  new(result, shutdownLibsecp256k1)
  let flags = cuint(SECP256K1_CONTEXT_VERIFY or SECP256K1_CONTEXT_SIGN)
  result.context = secp256k1_context_create(flags)
  secp256k1_context_set_illegal_callback(result.context, illegalCallback,
                                         cast[pointer](result))
  secp256k1_context_set_error_callback(result.context, errorCallback,
                                       cast[pointer](result))
  result.error = ""

proc getContext(): SkContext =
  ## Get current `EccContext`
  if isNil(secpContext):
    secpContext = newSkContext()
  result = secpContext

template raiseSecp256k1Error() =
  ## Raises `libsecp256k1` error as exception
  let mctx = getContext()
  if len(mctx.error) > 0:
    let msg = mctx.error
    mctx.error.setLen(0)
    raise newException(Secp256k1Error, msg)
  else:
    raise newException(Secp256k1Error, "")

proc init*(key: var SkPrivateKey, data: openarray[byte]): bool =
  ## Initialize Secp256k1 `private key` ``key`` from raw binary
  ## representation ``data``.
  ##
  ## Procedure returns ``true`` on success.
  let ctx = getContext()
  if len(data) >= SkRawPrivateKeySize:
    let res = secp256k1_ec_seckey_verify(ctx.context,
                                         cast[ptr cuchar](unsafeAddr data[0]))
    result = (res == 1) and (len(ctx.error) == 0)
    if result:
      copyMem(addr key.data[0], unsafeAddr data[0], SkRawPrivateKeySize)

proc init*(key: var SkPrivateKey, data: string): bool {.inline.} =
  ## Initialize Secp256k1 `private key` ``key`` from hexadecimal string
  ## representation ``data``.
  ##
  ## Procedure returns ``true`` on success.
  var buffer: seq[byte]
  try:
    buffer = fromHex(stripSpaces(data))
  except:
    return false
  result = init(key, buffer)

proc init*(key: var SkPublicKey, data: openarray[byte]): bool =
  ## Initialize Secp256k1 `public key` ``key`` from raw binary
  ## representation ``data``.
  ##
  ## Procedure returns ``true`` on success.
  let ctx = getContext()
  var length = 0
  if len(data) > 0:
    if data[0] == 0x02'u8 or data[0] == 0x03'u8:
      length = min(len(data), 33)
    elif data[0] == 0x04'u8 or data[0] == 0x06'u8 or data[0] == 0x07'u8:
      length = min(len(data), 65)
    else:
      return false
    let res = secp256k1_ec_pubkey_parse(ctx.context, addr key,
                                        cast[ptr cuchar](unsafeAddr data[0]),
                                        length)
    result = (res == 1) and (len(ctx.error) == 0)

proc init*(key: var SkPublicKey, data: string): bool =
  ## Initialize Secp256k1 `public key` ``key`` from hexadecimal string
  ## representation ``data``.
  ##
  ## Procedure returns ``true`` on success.
  var buffer: seq[byte]
  try:
    buffer = fromHex(stripSpaces(data))
  except:
    return false
  result = init(key, buffer)

proc init*(sig: var SkSignature, data: openarray[byte]): bool =
  ## Initialize Secp256k1 `signature` ``sig`` from raw binary
  ## representation ``data``.
  ##
  ## Procedure returns ``true`` on success.
  let ctx = getContext()
  let length = len(data)
  if length >= SkRawSignatureSize:
    var recid = cint(data[SkRawPrivateKeySize * 2])
    let res = secp256k1_ecdsa_recoverable_signature_parse_compact(ctx.context,
                    addr sig, cast[ptr cuchar](unsafeAddr data[0]), recid)
    result = (res == 1) and (len(ctx.error) == 0)

proc init*(sig: var SkSignature, data: string): bool =
  ## Initialize Secp256k1 `signature` ``sig`` from hexadecimal string
  ## representation ``data``.
  ##
  ## Procedure returns ``true`` on success.
  var buffer: seq[byte]
  try:
    buffer = fromHex(stripSpaces(data))
  except:
    return false
  result = init(sig, buffer)

proc init*(t: typedesc[SkPrivateKey],
           data: openarray[byte]): SkPrivateKey {.inline.} =
  ## Initialize Secp256k1 `private key` from raw binary
  ## representation ``data``.
  ##
  ## Procedure returns `private key` on success.
  if not init(result, data):
    raise newException(Secp256k1Error, "Incorrect binary form")

proc init*(t: typedesc[SkPrivateKey],
           data: string): SkPrivateKey {.inline.} =
  ## Initialize Secp256k1 `private key` from hexadecimal string
  ## representation ``data``.
  ##
  ## Procedure returns `private key` on success.
  if not init(result, data):
    raise newException(Secp256k1Error, "Incorrect binary form")

proc init*(t: typedesc[SkPublicKey],
           data: openarray[byte]): SkPublicKey {.inline.} =
  ## Initialize Secp256k1 `public key` from raw binary
  ## representation ``data``.
  ##
  ## Procedure returns `public key` on success.
  if not init(result, data):
    raise newException(Secp256k1Error, "Incorrect binary form")

proc init*(t: typedesc[SkPublicKey],
           data: string): SkPublicKey {.inline.} =
  ## Initialize Secp256k1 `public key` from hexadecimal string
  ## representation ``data``.
  ##
  ## Procedure returns `public key` on success.
  if not init(result, data):
    raise newException(Secp256k1Error, "Incorrect binary form")

proc init*(t: typedesc[SkSignature],
           data: openarray[byte]): SkSignature {.inline.} =
  ## Initialize Secp256k1 `signature` from raw binary
  ## representation ``data``.
  ##
  ## Procedure returns `signature` on success.
  if not init(result, data):
    raise newException(Secp256k1Error, "Incorrect binary form")

proc init*(t: typedesc[SkSignature],
           data: string): SkSignature {.inline.} =
  ## Initialize Secp256k1 `signature` from hexadecimal string
  ## representation ``data``.
  ##
  ## Procedure returns `signature` on success.
  if not init(result, data):
    raise newException(Secp256k1Error, "Incorrect binary form")

proc getKey*(key: SkPrivateKey): SkPublicKey =
  ## Calculate and return Secp256k1 `public key` from `private key` ``key``.
  let ctx = getContext()
  let res = secp256k1_ec_pubkey_create(ctx.context, addr result,
                                       cast[ptr cuchar](unsafeAddr key))
  if (res != 1) or (len(ctx.error) != 0):
    raiseSecp256k1Error()

proc random*(t: typedesc[SkPrivateKey]): SkPrivateKey =
  ## Generates new random private key.
  let ctx = getContext()
  while true:
    if randomBytes(result.data) == SkRawPrivateKeySize:
      let res = secp256k1_ec_seckey_verify(ctx.context,
                                          cast[ptr cuchar](addr result.data[0]))
      if (res == 1) and (len(ctx.error) == 0):
        break

proc random*(t: typedesc[SkKeyPair]): SkKeyPair {.inline.} =
  ## Generates new random key pair.
  result.seckey = SkPrivateKey.random()
  result.pubkey = result.seckey.getKey()

proc toBytes*(key: SkPrivateKey, data: var openarray[byte]): int =
  ## Serialize Secp256k1 `private key` ``key`` to raw binary form and store it
  ## to ``data``.
  ##
  ## Procedure returns number of bytes (octets) needed to store
  ## Secp256k1 private key.
  result = SkRawPrivateKeySize
  if len(data) >= SkRawPrivateKeySize:
    copyMem(addr data[0], unsafeAddr key.data[0], SkRawPrivateKeySize)

proc toBytes*(key: SkPublicKey, data: var openarray[byte]): int =
  ## Serialize Secp256k1 `public key` ``key`` to raw binary form and store it
  ## to ``data``.
  ##
  ## Procedure returns number of bytes (octets) needed to store
  ## Secp256k1 public key.
  let ctx = getContext()
  var length = csize(len(data))
  result = SkRawPublicKeySize
  if len(data) >= SkRawPublicKeySize:
    let res = secp256k1_ec_pubkey_serialize(ctx.context,
                                            cast[ptr cuchar](addr data[0]),
                                            addr length, unsafeAddr key,
                                            SECP256K1_EC_COMPRESSED)

proc toBytes*(sig: SkSignature, data: var openarray[byte]): int =
  ## Serialize Secp256k1 `signature` ``sig`` to raw binary form and store it
  ## to ``data``.
  ##
  ## Procedure returns number of bytes (octets) needed to store
  ## Secp256k1 signature.
  let ctx = getContext()
  var recid = cint(0)
  result = SkRawSignatureSize
  if len(data) >= SkRawSignatureSize:
    let res = secp256k1_ecdsa_recoverable_signature_serialize_compact(
                              ctx.context, cast[ptr cuchar](unsafeAddr data[0]),
                              addr recid, unsafeAddr sig)
    if (res == 1) and (len(ctx.error) == 0):
      data[64] = uint8(recid)

proc getBytes*(key: SkPrivateKey): seq[byte] {.inline.} =
  ## Serialize Secp256k1 `private key` and return it.
  result = @(key.data)

proc getBytes*(key: SkPublicKey): seq[byte] {.inline.} =
  ## Serialize Secp256k1 `public key` and return it.
  result = newSeq[byte](SkRawPublicKeySize)
  discard toBytes(key, result)

proc getBytes*(sig: SkSignature): seq[byte] {.inline.} =
  ## Serialize Secp256k1 `signature` and return it.
  result = newSeq[byte](SkRawSignatureSize)
  discard toBytes(sig, result)

proc `==`*(ska, skb: SkPrivateKey): bool =
  ## Compare Secp256k1 `private key` objects for equality.
  result = (ska.data == skb.data)

proc `==`*(pka, pkb: SkPublicKey): bool =
  ## Compare Secp256k1 `public key` objects for equality.
  var
    akey: array[SkRawPublicKeySize, byte]
    bkey: array[SkRawPublicKeySize, byte]
  discard pka.toBytes(akey)
  discard pkb.toBytes(bkey)
  result = (akey == bkey)

proc `==`*(sia, sib: SkSignature): bool =
  ## Compare Secp256k1 `signature` objects for equality.
  var
    asig: array[SkRawSignatureSize, byte]
    bsig: array[SkRawSignatureSize, byte]
  discard sia.toBytes(asig)
  discard sib.toBytes(bsig)
  result = (asig == bsig)

proc `$`*(key: SkPrivateKey): string = toHex(key.data)
  ## Return string representation of Secp256k1 `private key`.

proc `$`*(key: SkPublicKey): string =
  ## Return string representation of Secp256k1 `private key`.s
  var spub: array[SkRawPublicKeySize, byte]
  discard key.toBytes(spub)
  result = toHex(spub)

proc `$`*(sig: SkSignature): string =
  ## Return string representation of Secp256k1 `signature`.s
  var ssig: array[SkRawSignatureSize, byte]
  discard sig.toBytes(ssig)
  result = toHex(ssig)

proc sign*[T: byte|char](key: SkPrivateKey, msg: openarray[T]): SkSignature =
  ## Sign message `msg` using private key `key` and return signature object.
  let ctx = getContext()
  var hash = sha256.digest(msg)
  let res = secp256k1_ecdsa_sign_recoverable(ctx.context, addr result,
                                            cast[ptr cuchar](addr hash.data[0]),
                                            cast[ptr cuchar](unsafeAddr key),
                                            nil, nil)
  if (res != 1) or (len(ctx.error) != 0):
    raiseSecp256k1Error()

proc verify*[T: byte|char](sig: SkSignature, msg: openarray[T],
                           key: SkPublicKey): bool =
  var pubkey: SkPublicKey
  let ctx = getContext()
  var hash = sha256.digest(msg)
  let res = secp256k1_ecdsa_recover(ctx.context, addr pubkey, unsafeAddr sig,
                                    cast[ptr cuchar](addr hash.data[0]))
  if (res == 1) and (len(ctx.error) == 0):
    if key == pubkey:
      result = true

proc clear*(key: var SkPrivateKey) {.inline.} =
  ## Wipe and clear memory of Secp256k1 `private key`.
  burnMem(key.data)

proc clear*(key: var SkPublicKey) {.inline.} =
  ## Wipe and clear memory of Secp256k1 `public key`.
  burnMem(addr key, SkRawPrivateKeySize * 2)

proc clear*(sig: var SkSignature) {.inline.} =
  ## Wipe and clear memory of Secp256k1 `signature`.
  # Internal memory representation size of signature object is 64 bytes.
  burnMem(addr sig, SkRawPrivateKeySize * 2)

proc clear*(pair: var SkKeyPair) {.inline.} =
  ## Wipe and clear memory of Secp256k1 `key pair`.
  pair.seckey.clear()
  pair.pubkey.clear()
