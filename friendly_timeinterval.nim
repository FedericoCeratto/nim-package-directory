
import std/[times, strutils]

proc toFriendlyInterval*(i: TimeInterval, approx = 10): string =
  ## Convert TimeInterval to human-friendly description
  ## e.g. "5 minutes ago"
  result = ""
  var approx = approx
  let vals = [i.years, i.months, i.days, i.hours, i.minutes, i.seconds]
  var i = i
  var negative = false
  for v in vals:
    if v < 0:
      negative = true
      continue

  for i, fname in ["year", "month", "day", "hour", "minute", "second"]:
    var fvalue = vals[i]
    if approx != 0 and fvalue != 0:
      if result.len != 0:
        result.add ", "

      if negative:
        fvalue = -fvalue

      result.add "$# $#" % [$fvalue, fname]
      if fvalue != 1:
        result.add "s"
      approx.dec

  if result.len == 0:
    result.add "now"
  elif negative:
    result.add " from now"
  else:
    result.add " ago"


proc toNonLinearInterval(a, b: Time): TimeInterval =
  ##
  const
    minutes_s = 60
    hours_s = minutes_s * 60
    days_s = hours_s * 24
    months_s = 2592000
    years_s = months_s * 12

  var seconds = (b - a).seconds.int
  let years = seconds div years_s
  seconds -= years * years_s
  let months = seconds div months_s
  seconds -= months * months_s
  let days = seconds div days_s
  seconds -= days * days_s
  let hours = seconds div hours_s
  seconds -= hours * hours_s
  let minutes = seconds div minutes_s
  seconds -= minutes * minutes_s
  result = initInterval(seconds, minutes, hours, days,
    months, years)

proc toNonLinearInterval2(a, b: Time): TimeInterval =
  var remaining = (b - a).seconds.int
  let years = remaining div 31536000
  remaining -= years * 31536000
  let months = remaining div 2592000
  remaining -= months * 2592000
  let days = remaining div 86400
  remaining -= days * 86400
  let hours = remaining div 3600
  remaining -= hours * 3600
  let minutes = remaining div 60
  remaining -= minutes * 60
  result = initInterval(remaining.int, minutes.int, hours.int, days.int,
    months.int, years.int)

proc toNonLinearInterval3(a, b: Time): (TimeInterval, bool) =
  ##
  var i = b.toTimeInterval - a.toTimeInterval

  let in_future = ((b - a).seconds.int < 0)
  if in_future:
    i.seconds *= -1
    i.minutes *= -1
    i.hours *= -1
    i.days *= -1
    i.months *= -1
    i.years *= -1

  if i.seconds < 0:
    i.seconds.inc 60
    i.minutes.dec
  if i.minutes < 0:
    i.minutes.inc 60
    i.hours.dec
  if i.hours < 0:
    i.hours.inc 24
    i.days.dec
  if i.days < 0:
    i.days += 30
    i.months.dec
  if i.months < 0:
    i.months.inc 12
    i.years.dec

  return (i, in_future)

proc toFriendlyInterval3*(i: TimeInterval, in_future: bool, approx = 10): string =
  ## Convert TimeInterval to human-friendly description
  ## e.g. "5 minutes ago"
  result = ""
  var approx = approx
  let vals = [i.years, i.months, i.days, i.hours, i.minutes, i.seconds]
  var i = i

  for i, fname in ["year", "month", "day", "hour", "minute", "second"]:
    var fvalue = vals[i]
    if approx != 0 and fvalue != 0:
      if result.len != 0:
        result.add ", "

      result.add "$# $#" % [$fvalue, fname]
      if fvalue != 1:
        result.add "s"
      approx.dec

  if result.len == 0:
    result.add "now"
  elif in_future:
    result.add " from now"
  else:
    result.add " ago"



proc toFriendlyInterval*(a, b: Time, approx = 10): string =
  # creates inc
  #let i = b.toTimeInterval - a.toTimeInterval

  #let i2 = initInterval(seconds=int(b - a))
  let (i, in_future) = toNonLinearInterval3(a, b)
  for v in [i.years, i.months, i.days, i.hours, i.minutes, i.seconds]:
    assert v >= 0
  toFriendlyInterval3(i, in_future, approx)

#proc toFriendlyInterval(a, b: TimeInfo, approx = 10): string =
#  (a - b).fromSeconds.toTimeInterval.toFriendlyInterval(approx)

