local button = require("./button")

return {
	name = "Script",
	type = "category",
	buttons = {
		button("Script", "Script", "Insert a server Script", "insert", { "Script", "Script" }),
		button("Local Script", "LocalScript", "Insert a LocalScript", "insert", { "LocalScript", "LocalScript" }),
		button("Module Script", "ModuleScript", "Insert a ModuleScript", "insert", { "ModuleScript", "ModuleScript" }),
		button("Editor", "SyntaxHighlighter", "Open the script editor", "route", { "toggle_code_editor", true }),
		button("Debugger", "DebugOverlay", "Show the debugger output", "route", { "show_debugger" }),
		require("./buttons/play"),
		require("./buttons/stop"),
	},
}
