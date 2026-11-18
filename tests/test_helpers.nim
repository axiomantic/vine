import std/[os, strutils]
when defined(posix):
  import std/posix
elif defined(windows):
  proc c_dup(fd: cint): cint {.importc: "_dup", header: "<io.h>".}
  proc c_dup2(fd1, fd2: cint): cint {.importc: "_dup2", header: "<io.h>".}
  proc c_close(fd: cint): cint {.importc: "_close", header: "<io.h>".}
import config, vine

putEnv("RHIZO_EAR_DISABLED", "1")
putEnv("RHIZO_TEST", "1")

var ioCaptureSeq = 0

type
  InProcessResult* = tuple[outStr: string, errStr: string, combined: string, code: int]

proc captureIoSplit*(fn: proc()): tuple[outStr: string, errStr: string] =
  inc ioCaptureSeq
  let base = getTempDir() / ("vine_cap_" & $getCurrentProcessId() & "_" & $ioCaptureSeq)
  let outPath = base & ".out"
  let errPath = base & ".err"
  let fOut = open(outPath, fmReadWrite)
  let fErr = open(errPath, fmReadWrite)
  when defined(posix):
    let fdOut = getFileHandle(fOut)
    let fdErr = getFileHandle(fErr)
    flushFile(stdout)
    flushFile(stderr)
    let savedOut = dup(STDOUT_FILENO)
    let savedErr = dup(STDERR_FILENO)
    discard fcntl(fdOut, F_SETFD, FD_CLOEXEC)
    discard fcntl(fdErr, F_SETFD, FD_CLOEXEC)
    discard fcntl(savedOut, F_SETFD, FD_CLOEXEC)
    discard fcntl(savedErr, F_SETFD, FD_CLOEXEC)
    discard dup2(fdOut, STDOUT_FILENO)
    discard dup2(fdErr, STDERR_FILENO)
    try:
      fn()
    finally:
      flushFile(stdout)
      flushFile(stderr)
      discard dup2(savedOut, STDOUT_FILENO)
      discard dup2(savedErr, STDERR_FILENO)
      discard close(savedOut)
      discard close(savedErr)
      close(fOut)
      close(fErr)
  elif defined(windows):
    let fdOut = cint(getFileHandle(fOut))
    let fdErr = cint(getFileHandle(fErr))
    flushFile(stdout)
    flushFile(stderr)
    let savedOut = c_dup(1)
    let savedErr = c_dup(2)
    discard c_dup2(fdOut, 1)
    discard c_dup2(fdErr, 2)
    try:
      fn()
    finally:
      flushFile(stdout)
      flushFile(stderr)
      discard c_dup2(savedOut, 1)
      discard c_dup2(savedErr, 2)
      discard c_close(savedOut)
      discard c_close(savedErr)
      close(fOut)
      close(fErr)
  else:
    close(fOut)
    close(fErr)
    fn()
  let outStr = if fileExists(outPath): readFile(outPath) else: ""
  let errStr = if fileExists(errPath): readFile(errPath) else: ""
  try: removeFile(outPath) except CatchableError: discard
  try: removeFile(errPath) except CatchableError: discard
  result = (outStr, errStr)

proc captureIo*(fn: proc()): string =
  let (o, e) = captureIoSplit(fn)
  return o & e

proc captureRet*(fn: proc(): int): InProcessResult =
  var rc = 0
  let (o, e) = captureIoSplit(proc() =
    rc = fn()
  )
  result = (o, e, o & e, rc)

proc runVineInProcess*(args: openArray[string]): InProcessResult =
  let argSeq = @args
  var rc = 0
  let (o, e) = captureIoSplit(proc() =
    try:
      main(argSeq, true)
    except CliExitError as err:
      rc = err.exitCode
  )
  result = (o, e, o & e, rc)
