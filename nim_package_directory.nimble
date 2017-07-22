# Package

version       = "0.1.0"
author        = "Federico Ceratto"
description   = "Nim package directory"
license       = "GPLv3"

bin            = @["package_directory"]

# Dependencies

requires "nim >= 0.14.2", "jester", "tempfile", "rss", "sdnotify"

task release, "Build a relase":
  exec "nim c -d:release package_directory"

task hardening_check, "check hardening":
  exec "/usr/bin/hardening-check package_directory"

