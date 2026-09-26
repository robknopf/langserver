import std/[strutils]
import regex
import chronos, chronos/asyncproc
import stew/[byteutils]
import chronicles
import utils

type
  CheckStacktrace* = object
    file*: string
    line*: int
    column*: int
    msg*: string

  CheckResult* = object
    file*: string
    line*: int
    column*: int
    msg*: string
    severity*: string
    stacktrace*: seq[CheckStacktrace]

proc parseCheckResults(lines: seq[string]): seq[CheckResult] =
  result = @[]
  var
    messageText = ""
    stacktrace: seq[CheckStacktrace]
    lastFile, lastLineStr, lastCharStr: string
    m: RegexMatch2

  let dotsPattern = re2"^\.+$"
  let errorPattern = re2"^([^(]+)\((\d+),\s*(\d+)\)\s*(\w+):\s*(.*)$"

  for line in lines:
    let line = line.strip()

    if line.startsWith("Hint: used config file") or line == "" or line.match(
      dotsPattern
    ):
      continue

    if not find(line, errorPattern, m):
      if messageText.len < 1024:
        messageText &= "\n" & line
    else:
      try:
        let
          file = line[m.captures[0]]
          lineStr = line[m.captures[1]]
          charStr = line[m.captures[2]]
          severity = line[m.captures[3]]
          msg = line[m.captures[4]]

        let
          lineNum = parseInt(lineStr)
          colNum = parseInt(charStr)

        result.add(
          CheckResult(
            file: file,
            line: lineNum,
            column: colNum,
            msg: msg,
            severity: severity,
            stacktrace: @[],
          )
        )
      except Exception as e:
        error "Error processing line", line = line, msg = e.msg
        continue

  if messageText.len > 0 and result.len > 0:
    result[^1].msg &= "\n" & messageText

proc nimCheck*(filePath: string, nimPath: string): Future[seq[CheckResult]] {.async.} =
  debug "nimCheck", filePath = filePath, nimPath = nimPath
  let isNimble = filePath.endsWith(".nimble")
  var extraArgs = newSeq[string]()
  # `nim check foo.nims` checks it as NimScript already (its system has the NimScript
  # API): importing it again makes every NimScript proc ambiguous. A .nimble isn't
  if isNimble:
    extraArgs.add("--import: system/nimscript")
  if isNimble:
    extraArgs.add("--include: " & getNimScriptAPITemplatePath())
  let process = await startProcess(
    nimPath,
    arguments = @["check", "--listFullPaths"] & extraArgs & @[filePath],
    options = {UsePath},
    stderrHandle = AsyncProcess.Pipe,
    stdoutHandle = AsyncProcess.Pipe,
  )
  try:
    # nim writes its errors, warnings and hints to stderr, whatever it exits with: read
    # it (and stdout) while nim runs, since a pipe that fills up (64 KiB) would block nim
    # and it would never exit
    let
      errOutput = process.stderrStream.read()
      stdOutput = process.stdoutStream.read()
    discard await process.waitForExit(15.seconds)
    let output =
      string.fromBytes(errOutput.await) & "\n" & string.fromBytes(stdOutput.await)

    let lines = output.splitLines()
    parseCheckResults(lines)
  finally:
    await shutdownChildProcess(process)
