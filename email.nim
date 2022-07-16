import std/[asyncdispatch, smtp, strutils]

type
  Config* = object
    smtpAddress: string
    smtpPort: int
    smtpUser: string
    smtpPassword: string
    mlistAddress: string

proc sendEMail(config: Config, subject, message, recipient: string, from_addr = "forum@nim-lang.org") {.async.} =
  var client = newAsyncSmtp()
  await client.connect(config.smtpAddress, Port(config.smtpPort))
  if config.smtpUser.len > 0:
    await client.auth(config.smtpUser, config.smtpPassword)

  let toList = @[recipient]
  let encoded = createMessage(subject, message,
      toList, @[], [])

  await client.sendMail(from_addr, toList,
      $encoded)

#let c = Config(smtpAddress: "localhost", smtpPort: 2525, smtpUser: "", smtpPassword: "")
