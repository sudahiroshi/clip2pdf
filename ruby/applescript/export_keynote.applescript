-- Keynote の書類を PDF に書き出す。
-- 使い方: osascript export_keynote.applescript <入力.key> <出力.pdf>
-- すでに開いている書類ならそれを使い、こちらで開いた場合だけ閉じる
--（ユーザの作業中の書類を勝手に閉じないため）。書き出したスライド枚数を返す。
on run argv
	set srcPath to item 1 of argv
	set dstPath to item 2 of argv
	waitForKeynote()
	tell application "Keynote"
		with timeout of 600 seconds
			set theDoc to missing value
			set wasOpen to false
			repeat with d in documents
				try
					if (POSIX path of (file of d)) is srcPath then
						set theDoc to d
						set wasOpen to true
						exit repeat
					end if
				end try
			end repeat
			if theDoc is missing value then
				set theDoc to open (POSIX file srcPath as alias)
			end if
			set slideCount to count of slides of theDoc
			export theDoc to POSIX file dstPath as PDF with properties {export style:IndividualSlides, all stages:false, skipped slides:false, PDF image quality:Best}
			if not wasOpen then close theDoc saving no
			return slideCount as string
		end timeout
	end tell
end run

-- Keynote は起動直後だとイベントを受け取れず -600 になるため、応答するまで待つ。
-- do shell script / delay は Keynote への tell の外で呼ぶ必要がある。
on waitForKeynote()
	if application "Keynote" is not running then
		do shell script "open -g -a Keynote"
	end if
	-- version はアプリが起動していなくてもバンドルから返るので、
	-- 実際に動いていないと答えられない documents を使って判定する
	repeat 150 times
		try
			tell application "Keynote" to count documents
			return
		on error
			delay 0.2
		end try
	end repeat
	error "Keynote を起動できませんでした"
end waitForKeynote
