import std/os, chronos, chronos/asyncproc, unittest2, ../lstransports
when defined(posix):
  import std/posix

# chronos learns that a child exited from a signalfd on SIGCHLD, which only sees the
# signal while every thread blocks it. The server's stdin reader is a thread of its own:
# one that doesn't block SIGCHLD takes the signal instead, and waitForExit never returns.

when defined(posix):
  proc otherThread() {.thread.} =
    # the stdin reader starts before chronos blocks SIGCHLD, so it starts with it
    # unblocked; a thread made here would inherit this one's mask instead
    var mask, old: Sigset
    discard sigemptyset(mask)
    discard sigaddset(mask, SIGCHLD)
    discard pthread_sigmask(SIG_UNBLOCK, mask, old)
    blockSigchld() # what the stdin reader does first
    sleep(3000)

  suite "Child processes while the stdin thread runs":
    test "waitForExit sees a child exit":
      var th: Thread[void]
      createThread(th, otherThread)
      sleep(100) # the thread is running, and has blocked SIGCHLD
      let exitCode = waitFor (
        proc(): Future[int] {.async.} =
          let p = await startProcess("/bin/sh", arguments = @["-c", "sleep 0.5; exit 3"])
          # a timer of our own: waitForExit's timeout kills the child and then waits for
          # the same SIGCHLD, so it never fires either
          let exited = p.waitForExit()
          if await exited.withTimeout(5.seconds):
            result = exited.read()
            await p.closeWait()
          else:
            result = -1 # never seen to exit
      )()
      check exitCode == 3
      joinThread(th)
