import std/asyncdispatch
import std/[unittest, options]
import ../socketcan


test "read write":
  let can0 = createCANSocket("vcan0")
  let can1 = createCANSocket("vcan0")

  let frame = CANFrame(
    id: CANId 1234,
    format: Extended,
    data: [1, 2, 3, 4, 5, 6, 7, 8],
    len: 8
  )

  check can0.write(frame)
  let frameReceived = can1.read()
  check frameReceived.isSome()
  check frameReceived.get() == frame

test "read write (async)":
  proc test() {.async.} =
    let can0 = createAsyncCANSocket("vcan0")
    let can1 = createAsyncCANSocket("vcan0")

    let frame = CANFrame(
      id: CANId 1234,
      format: Extended,
      data: [1, 2, 3, 4, 5, 6, 7, 8],
      len: 8
    )

    check await can0.write(frame)
    let frameReceived = await can1.read()
    check frameReceived.isSome()
    check frameReceived.get() == frame

  waitFor test()
