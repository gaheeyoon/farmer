on run
    my launchBridge("")
end run
on open location theURL
    my launchBridge(theURL)
end open location
on launchBridge(theURL)
    set appPath to POSIX path of (path to me)
    set pythonPath to appPath & "Contents/Resources/bridge.py"
    set commandText to "/usr/bin/python3 " & quoted form of pythonPath
    if theURL is not "" then set commandText to commandText & " --url " & quoted form of theURL
    do shell script commandText & " > /dev/null 2>&1 &"
end launchBridge
