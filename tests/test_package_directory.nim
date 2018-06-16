
import unittest,
  sequtils,
  strutils,
  tables

import package_directory

const nimble_install_output = """
[36m[1m       Info [0m[36m[0mHint: used config file '/etc/nim.cfg' [Conf]
[36m[1m       Info [0m[36m[0mHint: used config file '/home/fede/.config/nim.cfg' [Conf]
[33m[1m   Warning: [0m[33m[0mFile inside package 'nim_package_directory' is outside of permitted namespace, should be named 'nim_package_directory.nim' but was named 'micron.nim' instead. This will be an error in the future.
[33m[1m      Hint: [0m[33m[0mRename this file to 'nim_package_directory.nim', move it into a 'nim_package_directory/' subdirectory, or prevent its installation by adding `skipFiles = @["micron.nim"]` to the .nimble file. See https://github.com/nim-lang/nimble#libraries for more info.
[36m[1mDownloading [0m[36m[0mhttps://github.com/dom96/jester using git
[33m[1m   Warning: [0m[33m[0mFile 'example2.nim' inside package 'jester' is outside of the permitted namespace, should be inside a directory named 'jester' but is in a directory named 'tests' instead. This will be an error in the future.
[33m[1m      Hint: [0m[33m[0mRename the directory to 'jester' or prevent its installation by adding `skipDirs = @["tests"]` to the .nimble file.
[36m[1m  Verifying [0m[36m[0mdependencies for jester@0.1.1
[33m[1m   Warning: [0m[33m[0mNo nimblemeta.json file found in /home/fede/.nimble/pkgs/nake-1.8
[36m[1m Installing [0m[36m[0mjester@0.1.1
[33m[1m    Prompt: [0m[33m[0mjester-0.1.1 already exists. Overwrite? [y/N]
[33m[1m    Answer: [0m[33m[0m
"""

suite "test pkgs":
  #test "search":
  #  load_packages()
  #  let ct = search_packages("high level game, little math")
  #  assert ct.len == 31
  #  assert ct.largest[0] == "linagl", $ct.largest

  test "translate_term_colors":
    let o = translate_term_colors nimble_install_output
    assert o.contains("m[") == false
    assert o.contains("[0m") == false

  test "CountTable sorted":
    var a = initCountTable[string]()
    a.inc("B", 2)
    a.inc("A", 3)
    a.inc("C", 1)
    let b = sorted(a)
    assert b.smallest() == ("C", 1)
    assert toSeq(b.keys()) == @["A", "B", "C"]
    assert toSeq(b.values()) == @[3, 2, 1]

  test "remove HTML":
    const
      html = "Sends <tt class=\"docutils literal\"><span class=\"pre\">status</span></tt> and <tt class=\"docutils literal\"><span class=\"pre\">Content-Type: text/html</span></tt>."
      exp = "Sends status and Content-Type: text/html."
    check exp == strip_html(html)
