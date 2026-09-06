return {
	name = "Stop",
	iconPath = "./src/assets/images/icons/Stop.svg",
	tooltip = "Stop the current playtest",
	action = {
		type = "service-method",
		service = "PlaytestService",
		method = "StopCurrentPlaytest",
		arguments = { "game" },
	},
}
