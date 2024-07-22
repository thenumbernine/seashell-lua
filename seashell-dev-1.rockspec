package = "seashell"
version = "dev-1"
source = {
	url = "git+https://github.com/thenumbernine/seashell-lua"
}
description = {
	summary = "seashell visualization",
	detailed = "seashell visualization",
	homepage = "https://github.com/thenumbernine/seashell-lua",
	license = "MIT"
}
dependencies = {
	"lua >= 5.1"
}
build = {
	type = "builtin",
	modules = {
		["seashell.eqn"] = "eqn.lua",
		["seashell.run"] = "run.lua"
	}
}
