local typedefs = require("../typedefs")
local argon = require("@Argon")

return function(params: typedefs.ImageParams, dt: number)
	local window = params.engine_window
	local image = params.Image

	-- Images are optional in several composite controls (for example toolbar
	-- entries supplied by plugins). Failed or absent image loads should leave a
	-- text-only control instead of reaching the native renderer with nil.
	if not image or not image._handle then
		return
	end

	argon:DrawImageSized(
		window,
		image,
		{ width = params.width, height = params.height, x = params.x, y = params.y, Color = argon:RGBA(1, 1, 1) }
	)
end
