import std/[os, nativesockets, posix, strformat, bitops, options, hashes]


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
    can_id{.importc.}: uint32
    len{.importc.}: uint8
    data{.importc.}: array[8, uint8]

const
  IdSlice = 0..28
  ErrMsgFrameFlagPos = 29
  RtrFlagPos = 30
  FrameFormatFlagPos = 31

proc ioctl(fd: cint, request: culong): cint {.importc, header: "<sys/ioctl.h>", varargs.}

type
  CANSocketObj = object
    isOpened: bool
    handle: SocketHandle
  
  CANSocket* = ref CANSocketObj

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
  proc `=destroy`(self: CANSocketObj) =
    if self.isOpened:
      self.handle.close()
else:
  proc `=destroy`(self: var CANSocketObj) =
    if self.isOpened:
      self.handle.close()

proc close*(self: CANSocket) =
  if self.isOpened:
    self.handle.close()
    self.isOpened = false

func isOpened*(self: CANSocket): bool =
  self.isOpened

func getHandle*(self: CANSocket): SocketHandle =
  doAssert self.isOpened
  self.handle

proc createCANSocket*(name: string): CANSocket =
  new result
  result.handle = createNativeSocket(PF_CAN, posix.SOCK_RAW, CAN_RAW)
  let ifindex = if_nametoindex(name)
  if ifindex == 0:
    raise newException(IOError):
      fmt"interface {name} not found"
  var sockaddr: sockaddr_can
  sockaddr.can_family = AF_CAN
  sockaddr.can_ifindex = ifindex
  let res = result.handle.bindAddr(cast[ptr SockAddr](addr sockaddr), sizeof(sockaddr_can).SockLen)
  if res < 0:
    raiseOSError(osLastError(), name)
  var val = 1.cint
  discard ioctl(result.handle.cint, FIONBIO.culong, addr val)
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
