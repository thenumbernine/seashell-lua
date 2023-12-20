local symmath = require 'symmath'
local tolua = require 'ext.tolua'
local path = require 'ext.path'
-- put all the eqn-specific stuff in here
-- so that I can cache the generated equation code and use this file's timestamp for its regeneration
return function(self)
	local vars = self.guivars:map(function(v,k)
		return symmath.var(k), k
	end)

	-- chart coordinates
	local u = symmath.var'u'
	local v = symmath.var'v'

	-- [[ give the parameters single-letter names for the html
	local i = 0
	for k,v in pairs(vars) do
		v:nameForExporter('MathJax', string.char(('a'):byte() + i))
		i = i + 1
	end
	--]]

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
	
	local df_du = x:diff(u)()
	local df_dv = x:diff(v)()
	local n = df_du:T()[1]:cross( df_dv:T()[1] )
	
	local code = symmath.export.C:toCode{
		assignOnly = true,
		output = {
			{['pos.x'] = x[1][1]},
			{['pos.y'] = x[2][1]},
			{['pos.z'] = x[3][1]},
			{['normal.x'] = n[1]},
			{['normal.y'] = n[2]},
			{['normal.z'] = n[3]},
		},
		input = {
			{['vtx.x'] = u},
			{['vtx.y'] = v},
		},
	}

	assert(path(self.cachefile):write(code))
end
