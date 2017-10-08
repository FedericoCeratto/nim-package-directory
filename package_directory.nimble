# Package

version       = "0.1.0"
author        = "Federico Ceratto"
description   = "Nim package directory"
license       = "GPLv3"

bin = @["package_directory"]

# Dependencies

requires "nim >= 0.14.2", "jester", "tempfile", "rss", "sdnotify", "statsd_client", "morelogging"

task builddeb, "Generate deb":
  exec "dpkg-buildpackage -us -uc -b -j4"

