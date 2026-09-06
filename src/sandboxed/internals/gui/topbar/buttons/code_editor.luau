return {
	name = "Script Editor",
	iconPath = "./src/assets/images/icons/Script.svg",
	tooltip = "Open the script editor",
	action = {
		type = "studio-route",
		route = "toggle_code_editor",
		arguments = { true },
	},
}
