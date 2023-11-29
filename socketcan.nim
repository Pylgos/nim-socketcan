import std/[asyncdispatch, os, nativesockets, posix, strformat, bitops, options, hashes]


let
  PF_CAN {.importc, header: "<linux/can.h>"}: cint
  CAN_RAW {.importc, header: "<linux/can.h>"}: cint
  AF_CAN {.importc, header: "<sys/socket.h>"}: cushort
  FIONBIO {.importc, header: "<sys/ioctl.h>"}: cint

type
  sockaddr_can {.importc: "struct sockaddr_can", header: "<linux/can.h>"} = object
    can_family {.importc.}: cushort
    can_ifindex {.importc.}: cint

  can_frame {.importc: "struct can_frame", header: "<linux/can.h>"} = object
    can_id {.importc.}: uint32
    len {.importc.}: uint8
    data {.importc.}: array[8, uint8]

const
  IdSlice = 0..28
  ErrMsgFrameFlagPos = 29
  RtrFlagPos = 30
  FrameFormatFlagPos = 31

proc ioctl(fd: cint, request: culong): cint {.importc, header: "<sys/ioctl.h>", varargs.}

type
  CANSocketObj[HandleType] = object
    isOpened: bool
    handle: HandleType

  CANSocket* = ref CANSocketObj[SocketHandle]
  AsyncCANSocket* = ref CANSocketObj[AsyncFD]

  CANKind* = enum
    Data
    Remote

  CANFormat* = enum
    Standard
    Extended

  CANId* = distinct int

  CANFrame* = object
    id*: CANId
    kind*: CANKind
    format*: CANFormat
    len*: int
    data*: array[8, byte]

  CANError* = object of IOError

  ZeroLengthReadError* = object of IOError

proc `==`*(a, b: CANId): bool {.borrow.}
proc hash*(a: CANId): Hash {.borrow.}
proc `$`*(a: CANId): string {.borrow.}

when (NimMajor, NimMinor) > (1, 6):
  proc `=destroy`(self: CANSocketObj[SocketHandle]) =
    if self.isOpened:
      self.handle.close()
  proc `=destroy`(self: CANSocketObj[AsyncFD]) =
    if self.isOpened:
      try:
        unregister(self.handle)
      except:
        discard
      self.handle.SocketHandle.close()
else:
  proc `=destroy`(self: var CANSocketObj[SocketHandle]) =
    if self.isOpened:
      self.handle.close()
  proc `=destroy`(self: var CANSocketObj[AsyncFD]) =
    if self.isOpened:
      try:
        unregister(self.handle)
      except:
        discard
      self.handle.SocketHandle.close()

proc close*(self: CANSocket) =
  if self.isOpened:
    self.handle.close()
    self.isOpened = false

proc close*(self: AsyncCANSocket) =
  if self.isOpened:
    unregister(self.handle)
    self.handle.SocketHandle.close()
    self.isOpened = false

func isOpened*(self: CANSocket | AsyncCanSocket): bool =
  self.isOpened

func getHandle*(self: CANSocket): SocketHandle =
  doAssert self.isOpened
  self.handle

func getHandle*(self: AsyncCANSocket): SocketHandle =
  doAssert self.isOpened
  self.handle.SocketHandle

proc createCANSocketHandle(name: string): SocketHandle =
  result = createNativeSocket(PF_CAN, posix.SOCK_RAW, CAN_RAW)
  let ifindex = if_nametoindex(name)
  if ifindex == 0:
    raise newException(IOError):
      fmt"interface {name} not found"
  var sockaddr: sockaddr_can
  sockaddr.can_family = AF_CAN
  sockaddr.can_ifindex = ifindex
  let res = result.bindAddr(cast[ptr SockAddr](addr sockaddr), sizeof(sockaddr_can).SockLen)
  if res < 0:
    raiseOSError(osLastError(), name)
  var val = 1.cint
  discard ioctl(result.cint, FIONBIO.culong, addr val)

proc createCANSocket*(name: string): CANSocket =
  new result
  result.handle = createCANSocketHandle(name)
  result.isOpened = true

proc createAsyncCANSocket*(name: string): AsyncCANSocket =
  new result
  let handle = createCANSocketHandle(name)
  result.handle = AsyncFD(handle)
  register(result.handle)
  result.isOpened = true

proc parseRawFrame(raw: can_frame): CANFrame =
  if raw.can_id.testBit(ErrMsgFrameFlagPos):
    raise newException(CANError, "something bad happened")

  if raw.can_id.testBit(RtrFlagPos):
    result.kind = Remote
  else:
    result.kind = Data

  if raw.can_id.testBit(FrameFormatFlagPos):
    result.format = Extended
  else:
    result.format = Standard

  result.id = raw.can_id.bitsliced(IdSlice).CANId
  result.len = raw.len.int
  result.data = raw.data

proc read*(self: CANSocket): Option[CANFrame] =
  var raw: can_frame
  let ret = read(self.handle.cint, addr raw, sizeof(raw))
  if ret == -1:
    let error = osLastError()
    if error == EAGAIN.OSErrorCode:
      return none(CANFrame)
    else:
      raiseOSError(error)
  elif ret == 0:
    raise newException(ZeroLengthReadError, "zero length read")
  else:
    result = some parseRawFrame(raw)

proc read*(self: AsyncCANSocket): Future[Option[CANFrame]] =
  var retFuture = newFuture[Option[CANFrame]]("socketcan.read")

  proc cb(fd: AsyncFD): bool =
    result = true
    var raw: can_frame
    let ret = read(self.handle.cint, addr raw, sizeof(raw))
    if ret == -1:
      let error = osLastError()
      if error == EAGAIN.OSErrorCode:
        result = false
      else:
        retFuture.fail(newException(OSError, osErrorMsg(error)))
    elif ret == 0:
      retFuture.fail(newException(ZeroLengthReadError, "zero length read"))
    else:
      retFuture.complete(some(parseRawFrame(raw)))

  addRead(self.handle, cb)
  return retFuture

proc write*(self: CANSocket, frame: CANFrame): bool =
  var raw: can_frame

  raw.can_id = frame.id.uint32
  if frame.kind == Remote:
    raw.can_id.setBit(RtrFlagPos)
  if frame.format == Extended:
    doAssert frame.id.uint32 <= ((1 shl 29) - 1)
    raw.can_id.setBit(FrameFormatFlagPos)
  else:
    doAssert frame.id.uint32 <= ((1 shl 12) - 1)

  doAssert frame.len <= 8
  raw.len = frame.len.uint8
  raw.data = frame.data

  let ret = write(self.handle.cint, addr raw, sizeof(raw))
  if ret == -1:
    let error = osLastError()
    if error == EAGAIN.OSErrorCode:
      return false
    else:
      raiseOSError(error)
  else:
    return true

proc write*(self: AsyncCANSocket, frame: CANFrame): Future[bool] =
  var retFuture = newFuture[bool]("socketcan.write")

  proc cb(fd: AsyncFD): bool =
    result = true
    var raw: can_frame
    raw.can_id = frame.id.uint32
    if frame.kind == Remote:
      raw.can_id.setBit(RtrFlagPos)
    if frame.format == Extended:
      doAssert frame.id.uint32 <= ((1 shl 29) - 1)
      raw.can_id.setBit(FrameFormatFlagPos)
    else:
      doAssert frame.id.uint32 <= ((1 shl 12) - 1)

    doAssert frame.len <= 8
    raw.len = frame.len.uint8
    raw.data = frame.data

    let ret = write(self.handle.cint, addr raw, sizeof(raw))
    if ret == -1:
      let error = osLastError()
      if error == EAGAIN.OSErrorCode:
        return false
      else:
        retFuture.fail(newException(OSError, osErrorMsg(error)))
    else:
      retFuture.complete(true)

  addWrite(self.handle, cb)
  return retFuture
