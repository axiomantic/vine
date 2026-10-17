# /Users/eek/Development/vine/src/process.nim
# Process Tree Supervision & Timeout Rails for Vine.
# Ensures that hung tests or frozen subprocesses are terminated with SIGKILL
# across their entire process tree, leaving zero zombie processes or held ports.

import std/[os, osproc, times, strutils]
when defined(posix):
  import std/posix

proc getDescendantPids*(pid: int): seq[int] =
  result = @[]
  when defined(posix):
    var queue = @[pid]
    while queue.len > 0:
      let curr = queue[0]
      queue.delete(0)
      let (outp, code) = execCmdEx("pgrep -P " & $curr)
      if code == 0:
        for line in outp.splitLines():
          let t = line.strip()
          if t.len > 0:
            try:
              let childPid = parseInt(t)
              if childPid notin result and childPid != pid:
                result.add(childPid)
                queue.add(childPid)
            except CatchableError: discard
  else:
    discard

proc killProcessTree*(pid: int) =
  when defined(posix):
    let descendants = getDescendantPids(pid)
    for cpid in descendants:
      discard kill(cpid.Pid, SIGKILL)
    discard kill(-pid.Pid, SIGKILL)
    discard kill(pid.Pid, SIGKILL)
  elif defined(windows):
    discard execCmdEx("taskkill /F /T /PID " & $pid)
  else:
    discard

proc execCmdExWithTimeout*(
  command: string,
  timeoutSec: float = 180.0,
  workingDir: string = ""
): tuple[output: string, exitCode: int, timedOut: bool, elapsedSec: float] =
  let t0 = getTime().toUnixFloat()
  let p = startProcess(
    command,
    workingDir = workingDir,
    options = {poStdErrToStdOut, poUsePath, poEvalCommand}
  )
  let pid = p.processID.int

  when defined(posix):
    discard setpgid(pid.Pid, pid.Pid)

  let fd = p.outputHandle.cint
  when defined(posix):
    let flags = fcntl(fd, F_GETFL, 0)
    discard fcntl(fd, F_SETFL, flags or O_NONBLOCK)

  var buf: array[4096, char]
  var captured = ""
  var timedOut = false
  var finalExitCode = -1

  while true:
    when defined(posix):
      let n = read(fd, addr buf[0], sizeof(buf))
      if n > 0:
        for i in 0 ..< n: captured.add(buf[i])
      elif n == 0:
        finalExitCode = peekExitCode(p)
        if finalExitCode == -1:
          discard p.waitForExit(100)
          finalExitCode = peekExitCode(p)
        break
      else:
        let err = osLastError().int
        if err != EAGAIN and err != EWOULDBLOCK:
          finalExitCode = peekExitCode(p)
          break
        finalExitCode = peekExitCode(p)
        if finalExitCode != -1:
          while true:
            let rem = read(fd, addr buf[0], sizeof(buf))
            if rem > 0:
              for i in 0 ..< rem: captured.add(buf[i])
            else: break
          break
    elif defined(windows):
      if p.hasData():
        try:
          let chunk = p.outputStream.readStr(4096)
          captured.add(chunk)
        except CatchableError: discard
      finalExitCode = peekExitCode(p)
      if finalExitCode != -1:
        if p.outputStream != nil:
          try:
            captured.add(p.outputStream.readAll())
          except CatchableError: discard
        break
    else:
      finalExitCode = peekExitCode(p)
      if finalExitCode != -1:
        break

    let elapsed = getTime().toUnixFloat() - t0
    if timeoutSec > 0.0 and elapsed >= timeoutSec:
      timedOut = true
      break

    os.sleep(20)

  let elapsedSec = getTime().toUnixFloat() - t0

  if timedOut:
    killProcessTree(pid)
    p.kill()
    when defined(posix):
      while true:
        let rem = read(fd, addr buf[0], sizeof(buf))
        if rem > 0:
          for i in 0 ..< rem: captured.add(buf[i])
        else: break
    close(p)
    return (captured, -1, true, elapsedSec)

  close(p)
  return (captured, finalExitCode, false, elapsedSec)
