return function(name, icon, tooltip, command, arguments)
	return {
		name = name,
		iconPath = "./src/assets/images/icons/" .. icon .. ".svg",
		tooltip = tooltip,
		action = {
			type = "topbar-command",
			command = command,
			arguments = arguments or {},
		},
	}
end
