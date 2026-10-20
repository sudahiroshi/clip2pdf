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
	my clickItem({"すべてを選択", "Select All"})
	delay 0.8
	my clickItem({"コピー", "Copy"})
	delay 0.8
	tell application "Keynote" to close front document saving no
	return "copied"
end run

-- 「編集」メニューを開いてから項目を押す（開く前は enabled が当てにならない）。
-- 英語環境でも動くよう名前の候補を複数受ける。
on clickItem(names)
	tell application "System Events" to tell process "Keynote"
		set mb to missing value
		repeat with nm in {"編集", "Edit"}
			try
				set mb to menu bar item (nm as string) of menu bar 1
				exit repeat
			end try
		end repeat
		if mb is missing value then error "編集メニューが見つかりません"
		click mb
		delay 0.4
		repeat with nm in names
			try
				click menu item (nm as string) of menu 1 of mb
				return
			end try
		end repeat
		-- 押せなかったらメニューを閉じておく（開いたままだと以後の操作が固まる）
		try
			click mb
		end try
	end tell
	error "メニュー項目を押せません"
end clickItem
