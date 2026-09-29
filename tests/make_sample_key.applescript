-- Keynote 経路（①段）の手動検証用サンプルを作る。
-- 使い方: osascript tests/make_sample_key.applescript /path/to/sample.key
-- 既定テーマで2枚のスライドを作り、プレースホルダを消して図形代わりのテキストを1つずつ置く。
on run argv
	set outPath to item 1 of argv
	tell application "Keynote"
		with timeout of 180 seconds
			set doc to make new document
			tell doc
				tell slide 1
					set title showing to false
					set body showing to false
					make new text item with properties {object text:"Figure A", position:{300, 220}, width:300}
				end tell
				set s2 to make new slide at end of slides
				tell s2
					set title showing to false
					set body showing to false
					make new text item with properties {object text:"Figure B", position:{500, 400}, width:200}
				end tell
			end tell
			save doc in POSIX file outPath
			set info to (width of doc as string) & "x" & (height of doc as string)
			close doc saving no
			return info
		end timeout
	end tell
end run
