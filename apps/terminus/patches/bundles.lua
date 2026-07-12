-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
-- GENERATED from patches/bundles.json by scripts/steam/verify-bundles.py --emit-lua.
-- Do not edit by hand; edit bundles.json + regenerate. The Steam PACKS UI reads this.
return {
	v = 1,
	bundles = {
		{
			id = "deluxe", name = "Deluxe Edition", value = 420, count = 81,
			steam_price = 120, marketplace_price = 150,
			complete_the_set = { "metal-forge", "voices", "effects" },
		},
		{
			id = "metal-forge", name = "Metal Forge Pack", value = 200, count = 30,
			steam_price = 59.99, marketplace_price = 74.99, dlc_appid = "STEAM_DLC_APPID_METAL_FORGE",
		},
		{
			id = "voices", name = "Voices Pack", value = 110, count = 18,
			steam_price = 34.99, marketplace_price = 44.99, dlc_appid = "STEAM_DLC_APPID_VOICES",
		},
		{
			id = "effects", name = "Effects & More Pack", value = 110, count = 33,
			steam_price = 34.99, marketplace_price = 44.99, dlc_appid = "STEAM_DLC_APPID_EFFECTS",
		},
	},
}
