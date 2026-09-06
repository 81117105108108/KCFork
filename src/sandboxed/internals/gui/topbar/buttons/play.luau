return {
	name = "Play",
	iconPath = "./src/assets/images/icons/Play.svg",
	tooltip = "Start a local playtest",
	action = {
		type = "service-method",
		service = "PlaytestService",
		method = "CreatePlaytestAsync",
		arguments = { "game" },
	},
}
