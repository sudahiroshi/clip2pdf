-- テスト用: Keynote で書類を開き、スライド1の内容をすべてコピーする。
-- 使い方: osascript tests/copy_from_keynote.applescript /path/to/file.key
-- アクセシビリティの許可が要る（キー操作は環境によって拒まれるのでメニューを押す）。
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
	-- 書類ウィンドウが出て前面になるまで待つ（出る前にメニューを押すと固まる）
	repeat 60 times
		tell application "System Events"
			if (count of windows of process "Keynote") > 0 and frontmost of process "Keynote" then
				exit repeat
			end if
		end tell
		delay 0.3
	end repeat
	delay 1
	tell application "System Events" to tell process "Keynote"
		set editMenu to menu 1 of (first menu bar item of menu bar 1 whose name is in {"編集", "Edit"})
		my clickItem(editMenu, {"すべてを選択", "Select All"})
		delay 0.8
		my clickItem(editMenu, {"コピー", "Copy"})
		delay 0.8
	end tell
	tell application "Keynote" to close front document saving no
	return "copied"
end run

-- 名前が一致する有効なメニュー項目を押す（英語環境でも動くよう候補を複数受ける）
on clickItem(theMenu, names)
	tell application "System Events"
		repeat with nm in names
			try
				set mi to menu item nm of theMenu
				if enabled of mi then
					click mi
					return
				end if
			end try
		end repeat
	end tell
	error "メニュー項目を押せません: " & (item 1 of names)
end clickItem
