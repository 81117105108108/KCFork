local ffi = zune.ffi
local ptr, i32, f32, void = ffi.types.pointer, ffi.types.i32, ffi.types.float, ffi.types.void

return {
	Kine_Audio_Init = { returns = i32, args = {} },
	Kine_Audio_Shutdown = { returns = void, args = {} },
	Kine_Audio_SetMasterVolume = { returns = void, args = { f32 } },
	Kine_Audio_SetListener = {
		returns = void,
		args = { f32, f32, f32, f32, f32, f32, f32, f32, f32, f32, f32, f32 },
	},
	Kine_Audio_LoadSound = { returns = ptr, args = { ptr, i32 } },
	Kine_Audio_DestroySound = { returns = void, args = { ptr } },
	Kine_Audio_Play = { returns = i32, args = { ptr } },
	Kine_Audio_Stop = { returns = void, args = { ptr } },
	Kine_Audio_Pause = { returns = void, args = { ptr } },
	Kine_Audio_IsPlaying = { returns = i32, args = { ptr } },
	Kine_Audio_IsAtEnd = { returns = i32, args = { ptr } },
	Kine_Audio_Seek = { returns = void, args = { ptr, f32 } },
	Kine_Audio_GetTime = { returns = f32, args = { ptr } },
	Kine_Audio_GetDuration = { returns = f32, args = { ptr } },
	Kine_Audio_SetVolume = { returns = void, args = { ptr, f32 } },
	Kine_Audio_SetPitch = { returns = void, args = { ptr, f32 } },
	Kine_Audio_SetLooping = { returns = void, args = { ptr, i32 } },
	Kine_Audio_SetSpatial = { returns = void, args = { ptr, i32 } },
	Kine_Audio_SetPosition = { returns = void, args = { ptr, f32, f32, f32 } },
	Kine_Audio_SetVelocity = { returns = void, args = { ptr, f32, f32, f32 } },
	Kine_Audio_SetDirection = { returns = void, args = { ptr, f32, f32, f32 } },
	Kine_Audio_SetDistance = { returns = void, args = { ptr, f32, f32, i32 } },
	Kine_Audio_SetEffect = {
		returns = i32,
		args = { ptr, i32, i32, f32, f32, f32, f32, f32 },
	},
}
