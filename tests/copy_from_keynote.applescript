-- テスト用: Keynote で書類を開き、スライド1の内容をすべてコピーする。
-- 使い方: osascript tests/copy_from_keynote.applescript /path/to/file.key
-- ⌘A / ⌘C を送るのでアクセシビリティの許可が要る。
on run argv
	set p to item 1 of argv
	if application "Keynote" is not running then
		do shell script "open -g -a Keynote"
	end if
	repeat 150 times
		try
			tell application "Keynote" to count documents
			exit repeat
		on error
			delay 0.2
		end try
	end repeat
	tell application "Keynote"
		activate
		open (POSIX file p as alias)
	end tell
	delay 2
	tell application "System Events" to tell process "Keynote"
		keystroke "a" using command down
		delay 0.8
		keystroke "c" using command down
	end tell
	delay 1.5
	tell application "Keynote" to close front document saving no
	return "copied"
end run
