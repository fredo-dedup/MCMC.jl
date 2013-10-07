
######## unfolds expressions to prepare derivation ###################
function unfold!(m::ParsingStruct)

	explore(ex::Expr)           = explore(toExH(ex))
	explore(ex::ExH)            = error("[unfold] unmanaged expr type $(ex.head) in ($ex)")
	explore(ex::ExLine)         = nothing     # remove line info
	explore(ex::LineNumberNode) = nothing
	explore(ex::ExRef)          = toExpr(ex)  # unchanged
	explore(ex::ExComp)         = toExpr(ex)  # unchanged
	explore(ex::ExVcat)         = explore(Expr(:call, :vcat, ex.args...) )  # translate to vcat() call, and explore
	explore(ex::ExTrans)        = explore(Expr(:call, :transpose, ex.args[1]) )  # translate to transpose() and explore
	explore(ex::ExDot)          = toExpr(ex)   # unchanged
	explore(ex::ExPEqual)       = (args = ex.args ; explore( Expr(:(=), args[1], Expr(:call, :+, args[1], args[2])) ) )
	explore(ex::ExMEqual)       = (args = ex.args ; explore( Expr(:(=), args[1], Expr(:call, :-, args[1], args[2])) ) )
	explore(ex::ExTEqual)       = (args = ex.args ; explore( Expr(:(=), args[1], Expr(:call, :*, args[1], args[2])) ) )
	explore(ex::ExTrans)        = explore(Expr(:call, :transpose, ex.args[1]))
	explore(ex::Any)            = ex

	# explore(ex::ExBlock) =  mapreduce(explore, (a,b)->b, ex.args)  # process, and return last evaluated
	function explore(ex::ExBlock)
		for i in 1:length(ex.args)
			re = explore(ex.args[i])
			re==nothing || push!(m.exprs, re)
		end
	end

	function explore(ex::ExEqual) 
		lhs = ex.args[1]
		isSymbol(lhs) || isRef(lhs) || error("[unfold] not a symbol on LHS of assigment $ex")

		rhs = ex.args[2]
		if isSymbol(rhs) || isa(rhs, Real) || isDot(rhs)
			push!(m.exprs, Expr(:(=), lhs, rhs))
		elseif isa(rhs, Expr) 
			ue = explore(toExH(rhs)) # explore will return something in this case
			push!(m.exprs, Expr(:(=), lhs, ue))
		else  # unmanaged kind of rhs
			error("[unfold] can't handle RHS of assignment $(toExpr(ex))")
		end
		return nothing
		# lhs
	end

	function explore(ex::ExCall) 
		na = {ex.args[1]}   # function name
		args = ex.args[2:end]  # arguments

		# if more than 2-ary, conversion to nested binary calls
		#  (easier for derivation)
		#   applies to +, sum, *, min, max
		# TODO : apply to other n-ary (n>2) operators ?
		if in(na[1], [:+, :*, :sum, :min, :max]) 
			while length(args) > 2
				a2 = pop!(args)
				a1 = pop!(args)
				push!(args, Expr(:call, ex.args[1], a1, a2))
			end
		end

		for e2 in args  
			if isa(e2, Expr) # only refs and calls will work
				ue = explore(e2)
				nv = newvar(TEMP_NAME)
				push!(m.exprs, :($nv = $ue))
				push!(na, nv)
			else
				push!(na, e2)
			end
		end

		Expr(ex.head, na...)
	end

	m.exprs = Expr[]
	explore(m.source)
end

######### analyzes and transforms for derivation #############
# - makes variables set several times unique (necessary for back propagation)
# - processes functions that transform their arguments (copy!, gemm!, etc...)
# - builds the variable dependency graph
# FIXME : algo doesn't work when a variable sets individual elements, x = .. then x[3] = ...; 
function varGraph(vex::Vector{Expr})
	subst = Dict{Symbol, Symbol}()     # will store variable renamings
	used = Set{Symbol}()               # variables used
	touched = Set{Symbol}()            # variables set
	external = Set{Symbol}()           # variables defined outside
	vg = Dict{Symbol, Set{Symbol}}()   # dependency graph

	nvex = Expr[]                      # returned transformed vector of expressions


	explore(ex::Expr) =       explore(toExH(ex))
	explore(ex::ExH) =      error("[varGraph!] unmanaged expr type $(ex.head) in ($ex)")
	
	function explore(ex::ExCall)
		#  where to look for changed variable, TODO : generalize, make user settable
		const inplace_var = {:copy! => 1, :gemm! => 7 }

		fn = ex.args[1]
		fa = ex.args[2:end]

		haskey(inplace_var, fn) || error("[varGraph!] unknown function $(ex.args[1])")

		ex = substSymbols(ex, subst) # first, do renaming

		lhss = fa[ get(inplace_var, fn, 1) ]
		assert(isSymbol(lhss), "[varGraph!] expected symbol got $lhss in $ex")

		rhss = getSymbols( fa[ 1:length(fa) .!= get(inplace_var, fn, 1) ] )

		external = union(external, {setdiff(rhss, touched)...})
		used = union(used, {rhss...})

		in(lhss, external) && error("$lhss is both an external variable and a variable set by the model")

		if in(lhss, touched) # ex is setting an already used variable => new var creation
			subst[lhss] = newvar(lhss) # generate new name, add it to substitution list for following statements
	        ex.args[2:end] = substSymbols(fa, subst) # replace in lhs
	        push!(nvex, :( $(subst[lhss]) = similar($lhss) ) ) # need to allocate variable in this case
	    end

		push!(touched, get(subst, lhss, lhss))
		push!(nvex, ex)
		vg[get(subst, lhss, lhss)] = rhss
	end

	function explore(ex::ExEqual)
		ex = substSymbols(ex, subst) # first, do renaming

		lhs = ex.args[1]
		lhss = isSymbol(lhs) ? lhs : lhs.args[1]  # extract only symbol if ref
		rhss = getSymbols(ex.args[2])
		external = union(external, {setdiff(rhss, touched)...})
		used = union(used, {rhss...})

		in(lhss, external) && error("$lhss is both an external var and set by the model")

		if in(lhss, touched) # ex is setting an already used variable => new var creation
			subst[lhss] = newvar(lhss) # generate new name, add it to substitution list for following statements
	        ex.args[1] = substSymbols(lhs, subst) # replace in lhs
	    end

		push!(touched, get(subst, lhss, lhss))

		push!(nvex, ex)
		vg[get(subst, lhss, lhss)] = rhss
	end

	map(explore, vex)

	# invert dependency graph
	vgi = Dict{Symbol, Set}()
	for (k,v) in vg
		for s in v
			haskey(vgi,s) ? push!(vgi[s], k) : (vgi[s] = Set(k))
		end
	end

	(vg, vgi, subst, nvex)
	# println("#### $nvex ####")
	# println("used $used")
	# println("touched $touched")
	# println("external $external")
	# println("substitutions $subst")
	# println("graph  $vg")
end

# ######### renames variables set several times to make them unique  #############
# # FIXME : algo doesn't work when a variable sets individual elements, x = .. then x[3] = ...; 
# # FIXME 2 : external variables redefined within model are not renamed
# function uniqueVars!(m::ParsingStruct)
# 	el = m.exprs
# 	subst = Dict{Symbol, Symbol}()
# 	used = Set{Symbol}()

#     for idx in 1:length(el) # idx=4
#         # first, substitute in the rhs the variables names that have been renamed
#         el[idx].args[2] = substSymbols(el[idx].args[2], subst)

#         # second, rename lhs symbol if set before
#         lhs = collect(getSymbols(el[idx].args[1]))[1]  # there should be only one
#         if contains(used, lhs) # if var already set once => create a new one
#             subst[lhs] = newvar(lhs) # generate new name, add it to substitution list for following statements
#             el[idx].args[1] = substSymbols(el[idx].args[1], subst)
#         else # var set for the first time
# 	        union!(used, Set(lhs)) 
#     	end
# 	end

# 	m.outsym = get(subst, m.outsym, m.outsym)  # update name of output var if renamed
# end

######### identifies vars #############
# - lists variables that depend on model parameters 
# - lists variables that influence the accumulator
# - lists variables defined
# In order to 
#   1) restrict gradient code to the strictly necessary variables 
#   2) move parameter independant variables definition out the function (but within closure) 
#   3) TODO : remove unnecessary variables (with warning)
#   4) identify external vars
# function categorizeVars!(m::ParsingStruct) 
# 	lhsSymbol(ex) = Set(isSymbol(ex.args[1]) ? ex.args[1] : ex.args[1].args[1])

# 	m.varsset = mapreduce(lhsSymbol, union, m.exprs)

#     local parset = Set{Symbol}(m.insyms...)  # [p.sym for p in m.pars]...)
#     m.pardesc = copy(parset)  # start with parameter symbols
#     for ex2 in m.exprs 
#     	lhs = lhsSymbol(ex2)
#     	rhs = getSymbols(ex2.args[2])

#     	!isempty(intersect(rhs, m.pardesc)) && union!(m.pardesc, lhs)
#     end

#     m.accanc = Set{Symbol}(m.outsym)
#     for ex2 in reverse(m.exprs) # proceed backwards ex2 = reverse(m.exprs)[3]
#     	lhs = lhsSymbol(ex2)
#         rhs = setdiff(getSymbols(ex2), lhs) # to pickup potential index on lhs as an ancestor

#         !isempty(intersect(lhs, m.accanc)) && union!(m.accanc, rhs)
#     end

#     contains(m.pardesc, m.outsym) || warn("Model parameters do not seem to influence model outcome")

#     local parset2 = setdiff(parset, m.accanc)
#     isempty(parset2) || warn("Model parameter(s) $(collect(parset2)) do not seem to influence model outcome")
# end
