# Package

version       = "0.1.1"
author        = "Federico Ceratto"
description   = "Nim package directory"
license       = "GPLv3"

bin = @["package_directory"]

# Dependencies

requires "nim >= 1.0.0", "jester >= 0.4.1", "tempfile", "sdnotify", "statsd_client > 0.1.0", "morelogging >= 0.1.4"

task builddeb, "Generate deb":
  exec "dpkg-buildpackage -us -uc -b -j4"
