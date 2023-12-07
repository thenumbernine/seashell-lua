#!/usr/bin/env luajit
local table = require 'ext.table'
local tolua = require 'ext.tolua'
local fromlua = require 'ext.fromlua'
local path = require 'ext.path'
local template = require 'template'
local sdl = require 'ffi.req' 'sdl'
local gl = require 'gl'
local GLProgram = require 'gl.program'
local GLFBO = require 'gl.fbo'
local GLTex2D = require 'gl.tex2d'
local ig = require 'imgui'
require 'glapp.view'.useBuiltinMatrixMath = true -- do this before imguiapp.withorbit
local App = require 'imguiapp.withorbit'()
local symmath = require 'symmath'
local ffi = require 'ffi'
local vec2f = require 'vec-ffi.vec2f'
local vec3f = require 'vec-ffi.vec3f'
local vec4f = require 'vec-ffi.vec4f'
local vector = require 'ffi.cpp.vector'
local Targets = require 'make.targets'
App.title = 'seashell'

function App:initGL(...)
	App.super.initGL(self, ...)

	self.view.zfar = 1000

	-- uniforms
	self.guivars = table{
		-- hmm if I make these perturbations positive-only, I can add an exponent to them and control their sharpness...
		shellPerturbAmplU = .01,
		shellPerturbPeriodU = 40,
		shellPerturbAmplV = .02,
		shellPerturbPeriodV = 500,
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
	}

	self.guicallbacks = {
		gridWidth = function() self:rebuildObj() end,
		gridHeight = function() self:rebuildObj() end,
		fboScaleX = function() self:rebuildFBO() end,
		fboScaleY = function() self:rebuildFBO() end,
	}

	local cachefile = 'cached-eqns.lua'
	Targets{verbose=true, {
		dsts = {cachefile},
		srcs = {'run.lua'},		-- cache as long as this file hasn't changed
		rule = function()

			local vars = self.guivars:map(function(v,k)
				return symmath.var(k), k
			end)

			-- chart coordinates
			local u = symmath.var'u'
			local v = symmath.var'v'

-- give the parameters single-letter names for the html
local i = 0
for k,v in pairs(vars) do
	v:nameForExporter('MathJax', string.char(('a'):byte() + i))
	i = i + 1
end

			local exvar = symmath.var'e_x'
			local ofsvar = symmath.var'\\vec{v}'
			
			-- start with our radius ...
			local x = (
				-- these should technically combine ... 
				-- https://www.wolframalpha.com/input?i=exp%28%5B%5By%2C0%2C0%5D%2C+%5B0%2Cy%2C-x%5D%2C%5B0%2Cx%2Cy%5D%5D%29
				-- but I've broken it in my own matrix-exp, so ...
				-- :replace() will no longer evaluate this correctly
				symmath.exp(
					(vars.shellExpScaleMinV * (1 - v) + vars.shellExpScaleMaxV * v) * symmath.var'I'
					+ symmath.var'\\star e_y' * 2 * symmath.pi * vars.shellPeriodV * v
				)
				* 
				(
					-- get a unit circle around origin
					symmath.exp(
						symmath.var'\\star e_x' * 2 * symmath.pi * u
					)
					* (exvar * 
						(1
						-- give the circle profile some oscillations...
						+ vars.shellPerturbAmplU 
						* symmath.cos(2 * symmath.pi * vars.shellPerturbPeriodU * u)
						-- also oscillate along the spiral
						+ vars.shellPerturbAmplV
						* symmath.cos(2 * symmath.pi * vars.shellPerturbPeriodV * v)
					))
				
					+ ofsvar
				)
			)

			local xorig = x
			
			print(x)
			
			local ex = symmath.Matrix{1, 0, 0}:T()
			local ey = symmath.Matrix{0, 1, 0}:T()
			local ez = symmath.Matrix{0, 0, 1}:T()
			
			local Rx = (2 * symmath.pi * u * symmath.Matrix(
				{0, -1, 0},
				{1, 0, 0},
				{0, 0, 0}
			))():exp()
			print(Rx)

			-- [[
			local Rz = (2 * symmath.pi * vars.shellPeriodV * v * symmath.Matrix(
				{0, 0, 0},
				{0, 0, -1},
				{0, 1, 0}
			))():exp()
			print(Rz)
			local zexp = symmath.exp(vars.shellExpScaleMinV * (1 - v) + vars.shellExpScaleMaxV * v)
			local Rzexp = Rz * zexp
			--]]
			--[[ can I combine these into one?
			-- ... ehhh not at the moment.  matrix-exp doesn't like it.
			local Rzdiag = vars.shellExpScaleMinV * (1 - v) + vars.shellExpScaleMaxV * v
			local Rzrot = 2 * symmath.pi * vars.shellPeriodV * v
			local Rzexp = symmath.Matrix(
				{Rzdiag , 0, 0},
				{0, Rzdiag, -Rzrot},
				{0, Rzrot, Rzdiag}
			)():exp()
			print(Rzexp)
			--]]

-- TODO WHY ISNT THIS WORKING?!?!??!??!
--[[			
			x = x
				:replace(exvar, ex)
				:replace(eyvar, ey)
				:replace(Rxvar, Rx)
				:replace(Rzvar, Rz)
				:replace(
					ofsvar,
					symmath.Matrix{
						-- offset in x direction before applying v-based exp rescaling to make pointed spiral shells
						vars.circleOfsX,
						-- offset in x by 1 to put the bottom at origin
						vars.circleOfsY,
						-- meh
						vars.circleOfsZ
					}:T()
				)
			x = x()
--]]
-- [[ JUST WRITE IT WITHOUT REPLACE
			local x = (
				Rzexp
				*
				(
					-- get a unit circle around origin
					Rx
					* (ex * 
						(1
						-- give the circle profile some oscillations...
						+ vars.shellPerturbAmplU
						* symmath.cos(2 * symmath.pi * vars.shellPerturbPeriodU * u)
						-- also oscillate along the spiral
						+ vars.shellPerturbAmplV
						* symmath.cos(2 * symmath.pi * vars.shellPerturbPeriodV * v)
					))
					
					+ symmath.Matrix{
						-- offset in y direction before applying v-based exp rescaling to make spiral shells
						vars.circleOfsX,
						-- offset it so the bottom is at origin
						vars.circleOfsY,
						-- meh
						vars.circleOfsZ
					}:T()
				)
			)()
--]]
			path'eqns.html':write(
				symmath.export.MathJax.header
				.. symmath.export.MathJax(xorig) .. '<br><br>\n'
				.. symmath.export.MathJax(x) .. '<br><br>\n'
				.. symmath.export.MathJax.footer
			)

			print(x)

			symmath.export.C.numberType = 'float'
			local poscode = symmath.export.C:toCode{
				assignOnly = true,
				output = {
					{['pos.x'] = x[1][1]},
					{['pos.y'] = x[2][1]},
					{['pos.z'] = x[3][1]},
				},
				input = {
					{['vtx.x'] = u},
					{['vtx.y'] = v},
				},
			}
		print'poscode'
			print(poscode)

			local df_du = x:diff(u)()
			local df_dv = x:diff(v)()
			local n = df_du:T()[1]:cross( df_dv:T()[1] )
			local normalcode = symmath.export.C:toCode{
				assignOnly = true,
				output = {
					{['normal.x'] = n[1]},
					{['normal.y'] = n[2]},
					{['normal.z'] = n[3]},
				},
				input = {
					{['vtx.x'] = u},
					{['vtx.y'] = v},
				},
			}
		print'normalcode'
			print(normalcode)

			assert(path(cachefile):write(tolua{
				poscode=poscode,
				normalcode=normalcode,
			}))
		end,
	}}:run(cachefile)

	local d = fromlua((assert(path(cachefile):read())))
	local poscode = d.poscode
	local normalcode = d.normalcode

	gl.glEnable(gl.GL_DEPTH_TEST)
	self.bgcolor = vec4f(.3,.3,.3,1)

	self.shader = GLProgram{
		vertexCode = template([[
#version 460
#define M_PI <?=('%.50f'):format(math.pi)?>
in vec2 vtx;
out vec3 normalv;

uniform mat4 mvMat, projMat;

<? for k,v in pairs(self.guivars) do
?>uniform float <?=k?>;
<? end
?>

void main() {
	vec3 normal;
	{
<?=normalcode?>
	}
	normalv = normalize((mvMat * vec4(normal, 0)).xyz);

	vec3 pos;
	{
<?=poscode?>
	}
	gl_Position = projMat * (mvMat * vec4(pos, 1.));
}
]], {
	self = self,
	poscode = poscode,
	normalcode = normalcode,
}),
		fragmentCode = [[
#version 460
in vec3 normalv;
out vec4 fragColor;
void main() {
#if 0 // lum only
	float l = abs(normalv.z);
	fragColor = vec4(l, l, l, 1);
#endif
#if 1	//normal only
	fragColor = vec4(normalv * .5 + .5, 1.);
#endif
}
]],
	}:useNone()

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

	local shader = self.shader
	shader:use()
	gl.glUniformMatrix4fv(shader.uniforms.mvMat.loc, 1, gl.GL_FALSE, self.view.mvMat.ptr)
	gl.glUniformMatrix4fv(shader.uniforms.projMat.loc, 1, gl.GL_FALSE, self.view.projMat.ptr)
	shader:setUniforms(self.guivars)
	shader:useNone()

	self.obj:draw()

end

function App:update()
	if not self.guivars.useFBO then
		self:drawScene()
	else
		--[[
		self.fbo:draw{
			--viewport = {0, 0, self.fbo.width, self.fbo.height},	-- seems the fbo could figure this out itself ...
			draw = function()
				gl.glViewport(0, 0, self.fbo.width, self.fbo.height)
				self.view:setup(self.fbo.width / self.fbo.height)
				self:drawScene()
			end,
		}
		--]]
		-- [[
		self.fbo:bind()
		--self.fbo:setColorAttachmentTex2D(self.fboTex.id)
		assert(self.fbo.check())
gl.glDrawBuffer(gl.GL_COLOR_ATTACHMENT0)
		gl.glViewport(0, 0, self.fbo.width, self.fbo.height)
		--self.view:setup(self.fbo.width / self.fbo.height)
		self:drawScene()
gl.glDrawBuffer(gl.GL_BACK)
		self.fbo:unbind()
		--]]
		gl.glViewport(0, 0, self.width, self.height)

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

function App:updateGUI()
	local mesh = self.mesh
	if ig.igBeginMainMenuBar() then
		if ig.igBeginMenu'Settings' then
			for k,v in pairs(self.guivars) do
				local changed
				local vt = type(v)
				if vt == 'boolean' then
					changed = ig.luatableCheckbox(k, self.guivars, k)
				elseif vt == 'number' then
					changed = ig.luatableInputFloatAsText(k, self.guivars, k)
				else	
					error("here with luatype "..vt)
				end
				if changed then
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
