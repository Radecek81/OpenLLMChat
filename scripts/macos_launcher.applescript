use AppleScript version "2.4"
use scripting additions

on run
  set appPath to POSIX path of (path to me)
  set bootstrapPath to quoted form of (appPath & "Contents/Resources/bootstrap_macos.sh")
  do shell script "open -a Terminal " & bootstrapPath
end run
