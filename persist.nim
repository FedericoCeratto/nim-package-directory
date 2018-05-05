#
# Nimble package directory - persistent data
#
# Copyright 2016 Federico Ceratto <federico.ceratto@gmail.com>
# Released under GPLv3 License, see LICENSE file
#
import marshal,
  streams

from net import Port

const
  pkgs_history_fname = "pkgs_history.json"
  conf_fname = "conf.json"

proc save_pkgs_history*(ph: seq[string]) =
  store(newFileStream(pkgs_history_fname, fmWrite), ph)

proc load_pkgs_history*(): seq[string] =
  try:
    load(newFileStream(pkgs_history_fname, fmRead), result)
  except:
    result = @[]
    save_pkgs_history(result)

# conf

type
  Conf* = object of RootObj
    github_token*, log_fname*, packages_list_fname*, public_baseurl*, tmp_nimble_root_dir*: string
    port*: Port

proc load_conf*(): Conf =
  result = to[Conf](readFile(conf_fname))
