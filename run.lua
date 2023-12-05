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
local vec2f = require 'vec-ffi.vec2f'
local vec3f = require 'vec-ffi.vec3f'
local vec4f = require 'vec-ffi.vec4f'
local vector = require 'ffi.cpp.vector'
App.title = 'seashell'

function App:initGL(...)
	App.super.initGL(self, ...)

	self.view.zfar = 1000

	-- uniforms
	self.guivars = table{
		shellSurfaceAmplitude = .01,
		shellSurfacePeriod = 40,
		shellRot = 7,
		shellExpScaleMin = -3,
		shellExpScaleMax = 3,
		pointAmpl = 0,
		pointExpScaleMin = 1,
		pointExpScaleMax = 10,
	}
	local vars = self.guivars:map(function(v,k)
		return symmath.var(k), k
	end)

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
		+ vars.shellSurfaceAmplitude  * symmath.cos(2 * symmath.pi * vars.shellSurfacePeriod * u),
		0,
		0
	}:T()
	-- get a unit circle around origin
	local x = (Rx * x)()
	-- offset it so the bottom is at origin
	x[2][1] = x[2][1] + 1
	print(x)
	
	local Rz = (vars.shellRot * v * symmath.Matrix(
		{0, 0, 0},
		{0, 0, -1},
		{0, 1, 0}
	))():exp()
	print(Rz)

	x = (symmath.exp(vars.shellExpScaleMin * (1 - v) + vars.shellExpScaleMax * v) * Rz * x)()
	
	x[1][1] = x[1][1] + vars.pointAmpl 
		* symmath.exp(vars.pointExpScaleMin * (1 - v) + vars.pointExpScaleMax * v)

	print(x)

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
	float l = abs(normalv.z);
	fragColor = vec4(l, l, l, 1);
}
]],
	}:useNone()
	
	local m = 200
	local n = 200

	self.vtxVec = vector'vec2f_t'
	self.vtxVec:reserve((m + 1) * (n + 1))
	self.indexVec = vector'int'
	self.indexVec:reserve(m * n * 3)

	for j=0,n do
		for i=0,m do
			local u = i/m
			local v = j/n
			self.vtxVec:emplace_back()[0]:set(u, v)
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
			pos = {
				buffer = self.vtxBuf,
			},
		},
		--createVAO = true,
	}

	-- WHY ISNT THIS BEING DONE ON INIT?!?!?!?!?
	self.obj.vao:bind()
	self.vtxBuf:bind()
	gl.glVertexAttribPointer(self.obj.program.attrs.vtx.loc, 2, gl.GL_FLOAT, gl.GL_FALSE, 0, ffi.cast('void*', 0))
	gl.glEnableVertexAttribArray(self.obj.program.attrs.vtx.loc)
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
	shader:setUniforms(self.guivars)
	shader:useNone()

	self.obj:draw()

	App.super.update(self)
end

function App:updateGUI()
	local mesh = self.mesh
	if ig.igBeginMainMenuBar() then
		if ig.igBeginMenu'Settings' then
			for k,v in pairs(self.guivars) do
				ig.luatableInputFloatAsText(k, self.guivars, k)
			end
			ig.igColorPicker3('background color', self.bgcolor.s, 0)
			ig.igEndMenu()
		end
		ig.igEndMainMenuBar()
	end
end

return App():run()
