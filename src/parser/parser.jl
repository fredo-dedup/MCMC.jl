##########################################################################
#
#    Model Expression parsing
#      - transforms MCMC specific idioms (~) into regular Julia syntax
#      - calls Autodiff module for gradient code generation
#      - creates function
#
##########################################################################

using Distributions
using Base.LinAlg.BLAS

include("autodiff/Autodiff.jl")
using .Autodiff

# Distributions extensions, TODO : ask for inclusion in Distributions package
include("vector_dists.jl")

# Add new derivation rules to Autodiff for LLAcc type
include("loglik_acc_rules.jl")

# Add new derivation rules to Autodiff for distributions
include("MCMC_deriv_rules.jl")

# naming conventions
const ACC_SYM = :__acc       # name of accumulator variable
const PARAM_SYM = :__beta    # name of parameter vector


#######################################################################
#   generates the log-likelihood function
#######################################################################
# - 'init' contains the dictionary of model params and their initial value
# - If 'debug' is set to true, the function returns only the function expression
#  that would have been created
function generateModelFunction(model::Expr; gradient=false, debug=false, init...)

	model.head != :block && (model = Expr(:block, model))  # enclose in block if needed
	length(model.args)==0 && error("model should have at least 1 statement")

	vsize, pmap, vinit = modelVars(;init...) # model param info

	model = translate(model) # rewrite ~ statements
	model = Expr(:block, [ :($ACC_SYM = LLAcc(0.)), # add log-lik accumulator initialization
		                   model.args, 
		                   :( $ACC_SYM = $(Expr(:., ACC_SYM, Expr(:quote, :val)) ) )]... )

	resetvar()  # reset temporary variable numbering (for legibility, not strictly necessary)
	head, body, outsym = diff(model, ACC_SYM; init...)

	## build function expression
	if gradient  # case with gradient
		body = [ vec2var(;init...),              # assigments beta vector -> model parameter vars
		         body.args,
		         :(($outsym, $(var2vec(;init...))))]

		# enclose in a try block
		body = Expr(:try, Expr(:block, body...),
				          :e, 
				          quote 
				          	if isa(e, OutOfSupportError)
				          		return(-Inf, zero($PARAM_SYM))
				          	else
				          		throw(e)
				          	end
				          end)

	else  # case without gradient
		# body = [ betaAssign(m)...,         # assigments beta vector -> model parameter vars
		#          :($ACC_SYM = LLAcc(0.)),  # initialize accumulator
  #                m.source.args...,         # model statements
  #                :(return $( Expr(:., ACC_SYM, Expr(:quote, :val)) )) ]

		# # enclose in a try block
		# body = Expr(:try, Expr(:block, body...),
		# 		          :e, 
		# 		          :(if isa(e, OutOfSupportError); return(-Inf); else; throw(e); end) )

		# header = Expr[]
	end


	# build and evaluate the let block containing the function and var declarations
	fn = gensym("ll")
	body = Expr(:function, Expr(:call, fn, :($PARAM_SYM::Vector{Float64})),	Expr(:block, body) )
	body = Expr(:let, Expr(:block, :(global $fn), head.args..., body))

	# println("#############\n$body\n############")

	debug ? body : (eval(body) ; (eval(fn), vsize, pmap, vinit) )
end

#### translates ~ into regular syntax
function translate(ex::Expr)
	if ex.head == :block 
		return Expr(:block, translate(ex.args)...)
	elseif ex.head == :call && ex.args[1] == :~
		fn = symbol("logpdf$(ex.args[3].args[1])")
		return :( $ACC_SYM += logpdf( $(ex.args[3]), $(ex.args[2]) ) )
	else
		return ex
	end
end
translate(ex::Vector) = map(translate, ex)
translate(ex::Any) = ex

### creates mapping statements from Vector{Float64} to model parameter variables
function vec2var(;init...)
	ex = Expr[]
	pos = 1
	for (v,i) in init
		sz = size(i)
		if length(sz) == 0  # scalar
			push!(ex, :($v = $PARAM_SYM[ $pos ]) )
			pos += 1
		elseif length(sz) == 1  # vector
			r = pos:(pos+sz[1]-1)
			push!(ex, :($v = $PARAM_SYM[ $(Expr(:(:), pos, pos+sz[1]-1)) ]) )
			pos += sz[1]
		else # matrix case  (needs a reshape)
			r = pos:(pos+prod(sz)-1)
			push!(ex, :($v = reshape($PARAM_SYM[ $(Expr(:(:), pos, pos+prod(sz)-1)) ], $(sz[1]), $(sz[2]))) )
			pos += prod(sz)
		end
	end
	ex
end

### creates mapping statements from model parameter variables to Vector{Float64}
function var2vec(;init...)
	ex = {}
	for (v,i) in init
		sz = size(i)
		if in(length(sz), [0,1]) # scalar or vector
			push!(ex, dprefix(v))
		else # matrix case  (needs a reshape)
			push!(ex, :( vec($(dprefix(v))) ) )
		end
	end
	Expr(:vcat, ex...)
end

### returns parameter info : total size, vector <-> model parameter map, inital values vector
function modelVars(;init...)
	# init = [(:x, 3.)]
    pars = Dict{Symbol, NTuple{2}}()
    pos = 1
    vi = Float64[]

    for (par, def) in init  # par, def = init[1]
    	isa(def, Real) || isa(def, AbstractVector) || isa(def, AbstractMatrix) ||
    		error("unsupported parameter type for $(par)")

        pars[par] = (pos, size(def))
        pos += length(def)
        vi = [vi, float64([def...])]
    end
    (pos-1, pars, vi)
end