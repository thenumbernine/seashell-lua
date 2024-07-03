#!/usr/bin/env luajit
local table = require 'ext.table'
local fromlua = require 'ext.fromlua'
local path = require 'ext.path'
local assertindex = require 'ext.assert'.index
local template = require 'template'
local sdl = require 'ffi.req' 'sdl'
local gl = require 'gl'
local GLProgram = require 'gl.program'
local GLFBO = require 'gl.fbo'
local GLTex2D = require 'gl.tex2d'
local GLTexCube = require 'gl.texcube'
local ig = require 'imgui'
require 'glapp.view'.useBuiltinMatrixMath = true -- do this before imguiapp.withorbit
local ffi = require 'ffi'
local vec2f = require 'vec-ffi.vec2f'
local vec3f = require 'vec-ffi.vec3f'
local vec4f = require 'vec-ffi.vec4f'
local vector = require 'ffi.cpp.vector-lua'
local Targets = require 'make.targets'

local App = require 'imguiapp.withorbit'()

App.title = 'seashell'

-- used here and eqn.lua for where to read/write the eqn cache
App.cachefile = 'cached-eqns.glsl'

function App:initGL(...)
	App.super.initGL(self, ...)

	self.view.zfar = 1000

	-- uniforms
	self.guivars = table{
		-- hmm if I make these perturbations positive-only, I can add an exponent to them and control their sharpness...
		shellPerturbAmplU = .01,
		shellPerturbPeriodU = 40,
		shellPerturbAmplV = .02,
		shellPerturbPeriodV = 50,
		shellPeriodV = 1.1,
		shellExpScaleMinV = -3,
		shellExpScaleMaxV = 3,

		circleOfsX = 0,	-- set this to give it a point
		circleOfsY = 1,	-- keep this 1 to offset the initial circle to have its edge at the origin
		circleOfsZ = 0,	-- meh?

		gridWidth = 2000,
		gridHeight = 2000,

		fboScaleX = 2,
		fboScaleY = 2,

		useFBO = true,

		-- chromatic aberration ratios
		ratioR = .3,
		ratioG = .2,
		ratioB = .1,
	}
	self.guivarnames = self.guivars:map(function(v,k,t) return k, #t+1 end):sort()

	self.guicallbacks = {
		gridWidth = function() self:rebuildObj() end,
		gridHeight = function() self:rebuildObj() end,
		fboScaleX = function() self:rebuildFBO() end,
		fboScaleY = function() self:rebuildFBO() end,
	}

	Targets{verbose=true, {
		dsts = {self.cachefile},
		srcs = {'eqn.lua'},		-- cache as long as this file hasn't changed
		rule = function() require 'eqn'(self) end,
	}}:run(self.cachefile)

	local glslcode = assert(path(self.cachefile):read())

	gl.glEnable(gl.GL_DEPTH_TEST)
	self.bgcolor = vec4f(.3, .3, .3, 1)

	self.shader = GLProgram{
		vertexCode = template(
GLProgram.getVersionPragma()..'\n'
..[[
#define M_PI <?=('%.50f'):format(math.pi)?>
in vec2 vtx;
out vec3 redv, greenv, bluev;
uniform mat4 mvMat, projMat;

<? for _,k in ipairs(self.guivarnames) do
	local v = self.guivars[k]
?>uniform float <?=k?>;
<? end
?>

void main() {
	vec3 normal;
	vec3 pos;

	{
<?=glslcode?>
	}

	vec3 normalv = normalize((mvMat * vec4(normal, 0)).xyz);
	gl_Position = projMat * (mvMat * vec4(pos, 1.));

	vec3 view = -mvMat[0].xyz;
	vec3 incident = reflect(view, normalv);
	redv = refract(incident, normalv, ratioR);
	greenv = refract(incident, normalv, ratioG);
	bluev = refract(incident, normalv, ratioB);
}
]], {
	self = self,
	glslcode = glslcode,
}),
		fragmentCode =
GLProgram.getVersionPragma()..'\n'
..[[
in vec3 redv, greenv, bluev;
out vec4 fragColor;
uniform samplerCube skyTex;
void main() {

	fragColor = vec4(
		texture(skyTex, redv).r,
		texture(skyTex, greenv).g,
		texture(skyTex, bluev).b,
		1.);
}
]],
		uniforms = {
			skyTex = 0,
		},
	}:useNone()

	local skytexbase = 'cloudy/bluecloud_'
	self.skyTex = GLTexCube{
		--[[
		filenames = {
			skytexbase..'posx.jpg',
			skytexbase..'negx.jpg',
			skytexbase..'posy.jpg',
			skytexbase..'negy.jpg',
			skytexbase..'posz.jpg',
			skytexbase..'negz.jpg',
		},
		--]]
		-- [[
		filenames = {
			skytexbase..'ft.jpg',
			skytexbase..'bk.jpg',
			skytexbase..'up.jpg',
			skytexbase..'dn.jpg',
			skytexbase..'rt.jpg',
			skytexbase..'lf.jpg',
		},
		--]]
		wrap={
			s=gl.GL_CLAMP_TO_EDGE,
			t=gl.GL_CLAMP_TO_EDGE,
			r=gl.GL_CLAMP_TO_EDGE,
		},
		magFilter = gl.GL_LINEAR,
		minFilter = gl.GL_LINEAR,	-- GL_LINEAR_MIPMAP_LINEAR,
		--generateMipmap = true,
	}:unbind()

	self:rebuildFBO()
	self:rebuildObj()
end

function App:rebuildFBO()
	local fboWidth = self.width * self.guivars.fboScaleX
	local fboHeight = self.height * self.guivars.fboScaleY
	self.fboTex = GLTex2D{
		width = fboWidth,
		height = fboHeight,
		internalFormat = gl.GL_RGBA,
		format = gl.GL_RGBA,
		type = gl.GL_UNSIGNED_BYTE,
		data = ffi.new('uint8_t[?]', fboWidth * fboHeight * 4),
		minFilter = gl.GL_LINEAR_MIPMAP_LINEAR,
		magFilter = gl.GL_LINEAR,
	}:unbind()

	self.fbo = GLFBO{
		width = fboWidth,
		height = fboHeight,
		useDepth = true,
		dest = self.fboTex,
	}:unbind()
end

function App:rebuildObj()
	local m = self.guivars.gridWidth
	local n = self.guivars.gridHeight

	self.vtxVec = vector'vec2f_t'
	self.vtxVec:resize((m + 1) * (n + 1))
	self.indexVec = vector'int'
	self.indexVec:resize(m * n * 6)

	local vi = 0
	local ei = 0
	for j=0,n do
		for i=0,m do
			local u = i/m
			local v = j/n
			self.vtxVec.v[vi]:set(u, v)
			vi = vi + 1
			if i < m and j < n then
				self.indexVec.v[ei] = i + (m+1) * j
				ei=ei+1
				self.indexVec.v[ei] = (i+1) + (m+1) * j
				ei=ei+1
				self.indexVec.v[ei] = (i+1) + (m+1) * (j+1)
				ei=ei+1
				self.indexVec.v[ei] = (i+1) + (m+1) * (j+1)
				ei=ei+1
				self.indexVec.v[ei] = i + (m+1) * (j+1)
				ei=ei+1
				self.indexVec.v[ei] = i + (m+1) * j
				ei=ei+1
			end
		end
	end

	self.vtxBuf = require 'gl.arraybuffer'{
		data = self.vtxVec.v,
		size = ffi.sizeof(self.vtxVec.type) * self.vtxVec.size,
	}:unbind()

	self.geometry = require 'gl.geometry'{
		mode = gl.GL_TRIANGLES,
		vertexes = self.vtxBuf,
		indexes = require 'gl.elementarraybuffer'{
			data = self.indexVec.v,
			size = ffi.sizeof(self.indexVec.type) * self.indexVec.size,
			type = gl.GL_UNSIGNED_INT,
		}:unbind(),
		count = self.indexVec.size,
	}

	self.obj = require 'gl.sceneobject'{
		geometry = self.geometry,
		program = self.shader,
		attrs = {
			vtx = self.vtxBuf,
		},
	}
end

-- assumes the viewport and self.view is already set up
function App:drawScene()
	gl.glClearColor(self.bgcolor:unpack())
	gl.glClear(bit.bor(gl.GL_COLOR_BUFFER_BIT, gl.GL_DEPTH_BUFFER_BIT))

	-- draw sky cube with no depth
	-- TODO make it rotate with the orbit angle

	gl.glDisable(gl.GL_DEPTH_TEST)
	self.skyTex
		:enable()
		:bind()
	--gl.glEnable(gl.GL_CULL_FACE)
	gl.glBegin(gl.GL_QUADS)
	local s = 1
	for dim=0,2 do
		for bit2 = 0,1 do	-- plus/minus side
			for bit1 = 0,1 do	-- v texcoord
				for bit0 = 0,1 do	-- u texcoord
					local i2 = bit.bor(
						bit.bxor(bit0, bit1, bit2),
						bit.lshift(bit1, 1),
						bit.lshift(bit2, 2)
					)
					-- now rotate i2 by dim
					local i = bit.band(7, bit.bor(
						bit.lshift(i2, dim),
						bit.rshift(i2, 3 - dim)
					))
					local x = bit.band(1, i)
					local y = bit.band(1, bit.rshift(i, 1))
					local z = bit.band(1, bit.rshift(i, 2))
					gl.glTexCoord3d(s*(x*2-1),s*(y*2-1),s*(z*2-1))
					gl.glVertex3d(s*(x*2-1),s*(y*2-1),s*(z*2-1))
				end
			end
		end
	end
	gl.glEnd()
	self.skyTex
		:unbind()
		:disable()
	gl.glEnable(gl.GL_DEPTH_TEST)

	-- draw scene

	local shader = self.shader
	shader:use()
	gl.glUniformMatrix4fv(shader.uniforms.mvMat.loc, 1, gl.GL_FALSE, self.view.mvMat.ptr)
	gl.glUniformMatrix4fv(shader.uniforms.projMat.loc, 1, gl.GL_FALSE, self.view.projMat.ptr)
	shader:setUniforms(self.guivars)
	shader:useNone()

	self.skyTex:bind()
	self.obj:draw()
	self.skyTex:unbind()

end

function App:update()
	if not self.guivars.useFBO then
		self:drawScene()
	else
		self.fbo:draw{
			viewport = {0, 0, self.fbo.width, self.fbo.height},	-- seems the fbo could figure this out itself ...
			callback = function() self:drawScene() end,
		}

		-- generate mipmap
		self.fboTex
			:bind()
			:generateMipmap()
			:unbind()

		-- draw supersample back to screen

		gl.glClear(bit.bor(gl.GL_COLOR_BUFFER_BIT, gl.GL_DEPTH_BUFFER_BIT))

		gl.glMatrixMode(gl.GL_PROJECTION)
		gl.glLoadIdentity()
		gl.glOrtho(0, 1, 0, 1, -1, 1)
		gl.glMatrixMode(gl.GL_MODELVIEW)
		gl.glLoadIdentity()
		self.fboTex
			:enable()
			:bind()
		gl.glBegin(gl.GL_TRIANGLE_STRIP)
		gl.glTexCoord2f(0, 0)	gl.glVertex2f(0, 0)
		gl.glTexCoord2f(1, 0)	gl.glVertex2f(1, 0)
		gl.glTexCoord2f(0, 1)	gl.glVertex2f(0, 1)
		gl.glTexCoord2f(1, 1)	gl.glVertex2f(1, 1)
		gl.glEnd()
		self.fboTex
			:unbind()
			:disable()
	end
	App.super.update(self)
end

local typeHandlers = {
	boolean = function(self, k) ig.luatableCheckbox(k, self.guivars, k) end,
	number = function(self, k) ig.luatableInputFloatAsText(k, self.guivars, k) end,
}

function App:updateGUI()
	local mesh = self.mesh
	if ig.igBeginMainMenuBar() then
		if ig.igBeginMenu'Settings' then
			for _,k in ipairs(self.guivarnames) do
				if assertindex(typeHandlers, type(self.guivars[k]))(self, k) then
					local callback = self.guicallbacks[k]
					if callback then
						callback()
					end
				end
			end
			ig.igColorPicker3('background color', self.bgcolor.s, 0)
			ig.igEndMenu()
		end
		ig.igEndMainMenuBar()
	end
end

function App:event(event, eventPtr)
	App.super.event(self, event, eventPtr)
	if eventPtr[0].type == sdl.SDL_WINDOWEVENT then
		if eventPtr[0].window.event == sdl.SDL_WINDOWEVENT_SIZE_CHANGED then
			self:rebuildFBO()
		end
	end
end

return App():run()
