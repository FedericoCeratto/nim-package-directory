
import marshal,
  streams

const pkgs_history_fname = "pkgs_history.json"

proc save_pkgs_history*(ph: seq[string]) =
  store(newFileStream(pkgs_history_fname, fmWrite), ph)

proc load_pkgs_history*(): seq[string] =
  try:
    load(newFileStream(pkgs_history_fname, fmRead), result)
  except:
    result = @[]
    save_pkgs_history(result)

