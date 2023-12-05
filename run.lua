#!/usr/bin/env luajit
local table = require 'ext.table'
local template = require 'template'
local gl = require 'gl'
local GLProgram = require 'gl.program'
local ig = require 'imgui'
require 'glapp.view'.useBuiltinMatrixMath = true -- do this before imguiapp.withorbit
local App = require 'imguiapp.withorbit'()
local symmath = require 'symmath'
local ffi = require 'ffi'
local vec3f = require 'vec-ffi.vec3f'
local vec4f = require 'vec-ffi.vec4f'
local vector = require 'ffi.cpp.vector'
App.title = 'seashell'

function App:initGL(...)
	App.super.initGL(self, ...)

	

	-- chart coordinates
	local u = symmath.var'u'
	local v = symmath.var'v'

	local Rx = (2 * symmath.pi * u * symmath.Matrix(
		{0, -1, 0},
		{1, 0, 0},
		{0, 0, 0}
	))():exp()
	print(Rx)

	-- start with our radius ...
	local x = symmath.Matrix{
		1 
		-- give the circle profile some oscillations...
		+ .01 * symmath.cos(2 * symmath.pi * 40 * u),
		0,
		0
	}:T()
	-- get a unit circle around origin
	local x = (Rx * x)()
	-- offset it so the bottom is at origin
	x[2][1] = x[2][1] + 1
	print(x)
	
	local Rz = (7 * v * symmath.Matrix(
		{0, 0, 0},
		{0, 0, -1},
		{0, 1, 0}
	))():exp()
	print(Rz)

	x = (symmath.exp(-3 * (1 - v) + 3 * v) * Rz * x)()
	print(x)

	local function compileVec(x)
		local fs = table()
		for i=1,#x do
			local code
			fs[i], code = x[i]:compile{u, v}
			print(code)
		end
		return fs
	end

	-- offset back to center
	x[2][1] = x[2][1] - 1
	
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

	gl.glEnable(gl.GL_NORMALIZE)
	gl.glEnable(gl.GL_LIGHTING)
	gl.glEnable(gl.GL_LIGHT0)
	gl.glLightfv(gl.GL_LIGHT0, gl.GL_POSITION, vec4f(0, 0, 0, 1).s)
	gl.glEnable(gl.GL_DEPTH_TEST)
	self.bgcolor = vec4f(.3,.3,.3,1)

	self.shader = GLProgram{
		vertexCode = template([[
#version 460
#define M_PI <?=('%.50f'):format(math.pi)?>
in vec3 vtx;
out vec3 normalv;
uniform mat4 mvMat, projMat;
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
	poscode = poscode,
	normalcode = normalcode,
}),
		fragmentCode = [[
#version 460
in vec3 normalv;
out vec4 fragColor;
void main() {
	float l = abs(normalv.z);
	fragColor = vec4(l, l, l, 1);
}
]],
	}:useNone()

	self.vtxVec = vector'vec3f_t'
	self.indexVec = vector'int'
	
	local m = 100
	local n = 100

	for j=0,n do
		for i=0,m do
			local u = i/m
			local v = j/n
			self.vtxVec:emplace_back()[0]:set(u, v, 0)
			if i < m and j < n then
				self.indexVec:emplace_back()[0] = i + (m+1) * j
				self.indexVec:emplace_back()[0] = (i+1) + (m+1) * j
				self.indexVec:emplace_back()[0] = (i+1) + (m+1) * (j+1)
				self.indexVec:emplace_back()[0] = (i+1) + (m+1) * (j+1)
				self.indexVec:emplace_back()[0] = i + (m+1) * (j+1)
				self.indexVec:emplace_back()[0] = i + (m+1) * j
			end
		end
	end

	local GLArrayBuffer = require 'gl.arraybuffer'
	self.vtxBuf = GLArrayBuffer{
		data = self.vtxVec.v,
		size = ffi.sizeof(self.vtxVec.type) * self.vtxVec.size,
	}:unbind()

	local GLElementArrayBuffer = require 'gl.elementarraybuffer'
	self.indexBuf = GLElementArrayBuffer{
		data = self.indexVec.v,
		size = ffi.sizeof(self.indexVec.type) * self.indexVec.size,
	}:unbind()
	-- used by gl.geometry:draw but not set in gl.buffer ... hmm ... TODO ...
	self.indexBuf.type = gl.GL_UNSIGNED_INT

	local GLGeometry = require 'gl.geometry'
	self.geometry = GLGeometry{
		mode = gl.GL_TRIANGLES,
		vertexes = self.vtxBuf,
		count = self.indexVec.size,
		indexes = self.indexBuf,
		-- hmm, default value is 0 for glDrawArrays, but glDrawElements expects a void* ... 
		offset = ffi.cast('void*', nil),
	}

	local GLAttribute = require 'gl.attribute'
	local GLSceneObject = require 'gl.sceneobject'
	self.obj = GLSceneObject{
		geometry = self.geometry,
		program = self.shader,
		attrs = {
			pos = {
				buffer = self.vtxBuf,
			},
		},
		createVAO = true,
	}

	-- WHY ISNT THIS BEING DONE ON INIT?!?!?!?!?
	local shader = self.shader
	self.obj.vao:bind()
	self.vtxBuf:bind()
	gl.glVertexAttribPointer(shader.attrs.vtx.loc, 3, gl.GL_FLOAT, gl.GL_FALSE, 0, ffi.cast('void*', 0))
	gl.glEnableVertexAttribArray(shader.attrs.vtx.loc)
	self.vtxBuf:unbind()
	self.obj.vao:unbind()
	
end

function App:update()
	gl.glClearColor(self.bgcolor:unpack())
	gl.glClear(bit.bor(gl.GL_COLOR_BUFFER_BIT, gl.GL_DEPTH_BUFFER_BIT))

	local shader = self.shader	
	shader:use()
	gl.glUniformMatrix4fv(shader.uniforms.mvMat.loc, 1, gl.GL_FALSE, self.view.mvMat.ptr)
	gl.glUniformMatrix4fv(shader.uniforms.projMat.loc, 1, gl.GL_FALSE, self.view.projMat.ptr)
	shader:useNone()

	self.obj:draw()

	App.super.update(self)
end

function App:updateGUI()
	local mesh = self.mesh
	if ig.igBeginMainMenuBar() then
		if ig.igBeginMenu'Settings' then
			ig.igColorPicker3('background color', self.bgcolor.s, 0)
			ig.igEndMenu()
		end
		ig.igEndMainMenuBar()
	end
end

return App():run()
