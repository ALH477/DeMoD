-- SPDX-License-Identifier: MPL-2.0
--
-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at https://mozilla.org/MPL/2.0/.
--
-- i18n_demo.lua — UTF-8 / multi-script text rendering demo.
--
-- Exercises the extended glyph pipeline: halfwidth Latin/Greek/Cyrillic and
-- fullwidth CJK from the Unifont .dmf blob, mixed-width measurement
-- (dm.draw.text_width), integer scaling, and the tofu box for missing glyphs.
--
-- Run:  DEMOD_FONT=/path/to/unifont-full.dmf ./demod-ui examples/i18n_demo.lua
-- (without DEMOD_FONT every non-ASCII glyph draws as a tofu box — also a
--  useful state to see.)

local LINES = {
	{ "en", "The quick brown fox jumps over the lazy dog" },
	{ "es", "El veloz murcielago hindu comia feliz cardillo y kiwi: añejo" },
	{ "fr", "Voix ambiguë d'un cœur qui au zéphyr préfère les jattes de kiwis" },
	{ "de", "Zwölf Boxkämpfer jagen Viktor quer über den großen Sylter Deich" },
	{ "el", "Ελληνικά: Ξεσκεπάζω την ψυχοφθόρα βδελυγμία" },
	{ "ru", "Русский: Съешь же ещё этих мягких французских булок" },
	{ "ja", "日本語: いろはにほへと ちりぬるを 「音楽」" },
	{ "zh", "中文: 快速的棕色狐狸跳过懒狗 混合 width test" },
	{ "ko", "한국어: 다람쥐 헌 쳇바퀴에 타고파" },
	{ "mix", "Mixed: DSP 混合 kana カナ end" },
}

local W, H = 0, 0

function on_update(dt)
	dm.redraw()
end

function on_draw()
	W, H = dm.width(), dm.height()
	dm.draw.rect(0, 0, W, H, 10, 10, 15, 255)
	dm.draw.text(16, 8, "UTF-8 GLYPH PIPELINE", 0, 245, 212, 255)
	dm.draw.text(16, 26, "text_width-aligned right edge marks below:", 140, 140, 160, 200)

	local y = 48
	for _, l in ipairs(LINES) do
		local tag, s = l[1], l[2]
		dm.draw.text(16, y, tag, 139, 92, 246, 230)
		dm.draw.text(52, y, s, 232, 232, 240, 255)
		-- prove measurement matches rendering: a tick exactly at the string's end
		local wpx = dm.draw.text_width(s)
		dm.draw.rect(52 + wpx + 2, y, 3, 16, 76, 255, 130, 255)
		-- and the codepoint count vs byte count
		dm.draw.text(W - 180, y, string.format("cp=%d b=%d", dm.utf8_len(s), #s), 140, 140, 160, 180)
		y = y + 20
	end

	-- scaled CJK + deliberate missing glyph (tofu): U+FFFF is unassigned
	dm.draw.text(16, y + 8, "スケール x2 中文", 0, 245, 212, 255, 2)
	dm.draw.text(16, y + 44, "tofu: \239\191\191 <- unassigned cp", 255, 217, 76, 220)
end

dm.redraw()
