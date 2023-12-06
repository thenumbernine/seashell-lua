#!/usr/bin/env luajit
local table = require 'ext.table'
local tolua = require 'ext.tolua'
local fromlua = require 'ext.fromlua'
local path = require 'ext.path'
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
local Targets = require 'make.targets'
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
		
		circleOfsX = 0,	-- set this to give it a point
		circleOfsY = 1,	-- keep this 1 to offset the initial circle to have its edge at the origin
		circleOfsZ = 0,	-- meh?
	
		gridWidth = 2000,
		gridHeight = 2000,
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

local i = 0
for k,v in pairs(vars) do
	v:nameForExporter('MathJax', string.char(('a'):byte() + i))
	i = i + 1
end

			local exvar = symmath.var'e_x'
			local eyvar = symmath.var'e_y'
			local ezvar = symmath.var'e_z'
			local Rxvar = symmath.var'R_x(2 \\pi u)'
			local Rzvar = symmath.var('R_z('..vars.shellRot:nameForExporter'MathJax'..' \\cdot v)')
			local ofsvar = symmath.var'\\vec{v}'
			
			-- start with our radius ...
			local x = (
				symmath.exp(vars.shellExpScaleMin * (1 - v) + vars.shellExpScaleMax * v)
				* 
				Rzvar
				* 
				(
					-- get a unit circle around origin
					Rxvar 
					* (exvar * 
						(1
						-- give the circle profile some oscillations...
						+ vars.shellSurfaceAmplitude 
						* symmath.cos(2 * symmath.pi * vars.shellSurfacePeriod * u)
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

			local Rz = (vars.shellRot * v * symmath.Matrix(
				{0, 0, 0},
				{0, 0, -1},
				{0, 1, 0}
			))():exp()
			print(Rz)
			local zexp = symmath.exp(vars.shellExpScaleMin * (1 - v) + vars.shellExpScaleMax * v)

			local Rzexp = Rz * zexp

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
						-- offset in y direction before applying v-based exp rescaling to make spiral shells
						vars.circleOfsX,
						-- offset it so the bottom is at origin
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
						+ vars.shellSurfaceAmplitude 
						* symmath.cos(2 * symmath.pi * vars.shellSurfacePeriod * u)
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

	self:rebuildObj()
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
				if ig.luatableInputFloatAsText(k, self.guivars, k) then
					if k == 'gridWidth' or k == 'gridHeight' then
						self:rebuildObj()
					end
				end
			end
			ig.igColorPicker3('background color', self.bgcolor.s, 0)
			ig.igEndMenu()
		end
		ig.igEndMainMenuBar()
	end
end

return App():run()
