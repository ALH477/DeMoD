-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
-- home_render.lua — wrapper to render the demod-ui home menu as video
dm.config({
	duration = 5.0,
	resolution = "1280x720",
	fps = 30,
	output = "output/home_menu.mp4",
})

dofile("/home/asher/Downloads/unified-UI/home.lua")
