import std/asyncdispatch
import std/[unittest, options]
import ../socketcan

const frame = CANFrame(
  id: CANId 1234,
  format: Extended,
  data: [1, 2, 3, 4, 5, 6, 7, 8],
  len: 8
)
const frame_filtered = CANFrame(
  id: CANId 4321,
  format: Extended,
  data: [1, 2, 3, 4, 5, 6, 7, 8],
  len: 8
)

test "read write":
  let can0 = createCANSocket("vcan0")
  let can1 = createCANSocket("vcan0")

  can0.set_loopback(false)
  check can0.write(frame_filtered)
  can0.set_loopback(true)
  check can0.write(frame)
  let frameReceived = can1.read()
  check frameReceived.isSome()
  check frameReceived.get() == frame

test "read write (async)":
  proc test() {.async.} =
    let can0 = createAsyncCANSocket("vcan0")
    let can1 = createAsyncCANSocket("vcan0")

    can0.set_loopback(false)
    check await can0.write(frame_filtered)
    can0.set_loopback(true)
    check await can0.write(frame)
    let frameReceived = await can1.read()
    check frameReceived.isSome()
    check frameReceived.get() == frame

  waitFor test()

test "filter":
  let can0 = createCANSocket("vcan0")
  let can1 = createCANSocket("vcan0")

  var rfilter = newSeqOfCap[can_filter](1)
  rfilter.add(can_filter_extended(4321, invert = true))
  rfilter.add(can_filter_extended(1234))
  check can1.set_filter(rfilter)
  check can0.write(frame_filtered)
  check can0.write(frame)
  let frameReceived = can1.read()
  check frameReceived.isSome()
  check frameReceived.get() == frame
