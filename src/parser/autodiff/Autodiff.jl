############################################################################
#  First attempt at decoupling automatic derivation from MCMC specific
#    code.
#
#  a unique entry point : diff(ex, out::Symbol, in as keyword-args)
#  returns an expression + var allocation expressions
#
############################################################################


module Autodiff

	# using Distributions
	using Base.LinAlg.BLAS

	export getSymbols, substSymbols, diff, @dfunc, dfunc, linkType

	# naming conventions
	const TEMP_NAME = "tmp"     # prefix of temporary variables in log-likelihood function
	const DERIV_PREFIX = "_d"   # prefix of gradient variables
	
	##########  Parameterized type to ease AST exploration  ############
	type ExprH{H}
		head::Symbol
		args::Vector
		typ::Any
	end
	toExprH(ex::Expr) = ExprH{ex.head}(ex.head, ex.args, ex.typ)
	toExpr(ex::ExprH) = Expr(ex.head, ex.args...)

	typealias Exprequal    ExprH{:(=)}
	typealias Exprdcolon   ExprH{:(::)}
	typealias Exprpequal   ExprH{:(+=)}
	typealias Exprmequal   ExprH{:(-=)}
	typealias Exprtequal   ExprH{:(*=)}
	typealias Exprtrans    ExprH{symbol("'")} 
	typealias Exprcall     ExprH{:call}
	typealias Exprblock	   ExprH{:block}
	typealias Exprline     ExprH{:line}
	typealias Exprvcat     ExprH{:vcat}
	typealias Exprref      ExprH{:ref}
	typealias Exprif       ExprH{:if}
	typealias Exprcomp     ExprH{:comparison}
	typealias Exprdot      ExprH{:.}

	## variable symbol sampling functions
	getSymbols(ex::Any) =        Set{Symbol}()
	getSymbols(ex::Symbol) =     Set{Symbol}(ex)
	getSymbols(ex::Array) =      mapreduce(getSymbols, union, ex)
	getSymbols(ex::Expr) =       getSymbols(toExprH(ex))
	getSymbols(ex::ExprH) =      mapreduce(getSymbols, union, ex.args)
	getSymbols(ex::Exprcall) =   mapreduce(getSymbols, union, ex.args[2:end])  # skip function name
	getSymbols(ex::Exprref) =    setdiff(mapreduce(getSymbols, union, ex.args), Set(:(:), symbol("end")) )# ':'' and 'end' do not count
	getSymbols(ex::Exprcomp) =   setdiff(mapreduce(getSymbols, union, ex.args), 
		Set(:(>), :(<), :(>=), :(<=), :(.>), :(.<), :(.<=), :(.>=), :(==)) )

	getSymbols(ex::Exprdot) =     Set{Symbol}(ex.args[1])  # return variable, not fields

	## variable symbol subsitution functions
	substSymbols(ex::Any, smap::Dict) =           ex
	substSymbols(ex::Expr, smap::Dict) =          substSymbols(toExprH(ex), smap::Dict)
	substSymbols(ex::Vector, smap::Dict) =        map(e -> substSymbols(e, smap), ex)
	substSymbols(ex::ExprH, smap::Dict) =         Expr(ex.head, map(e -> substSymbols(e, smap), ex.args)...)
	substSymbols(ex::Exprcall, smap::Dict) =      Expr(:call, ex.args[1], map(e -> substSymbols(e, smap), ex.args[2:end])...)
	substSymbols(ex::Exprdot, smap::Dict) =       (ex = toExpr(ex) ; ex.args[1] = substSymbols(ex.args[1], smap) ; ex)
	substSymbols(ex::Symbol, smap::Dict) =        get(smap, ex, ex)

	
	## misc functions
	dprefix(v::Union(Symbol, String, Char)) = symbol("$DERIV_PREFIX$v")
	dprefix(v::Expr) = dprefix(toExprH(v))
	dprefix(v::Exprref) = Expr(:ref, dprefix(v.args[1]), v.args[2:end]...)
	dprefix(v::Exprdot) = Expr(:., dprefix(v.args[1]), v.args[2:end]...)

	isSymbol(ex)   = isa(ex, Symbol)
	isDot(ex)      = isa(ex, Expr) && ex.head == :.   && isa(ex.args[1], Symbol)
	isRef(ex)      = isa(ex, Expr) && ex.head == :ref && isa(ex.args[1], Symbol)

	## var name generator
	let
		vcount = Dict()
		global newvar
		function newvar(radix::Union(String, Symbol)="")
			vcount[radix] = haskey(vcount, radix) ? vcount[radix]+1 : 1
			return symbol("$radix#$(vcount[radix])")
		end

		global resetvar
		function resetvar()
			vcount = Dict()
		end
	end

	######### structure for parsing model  ##############
	type ParsingStruct
		bsize::Int                # length of beta, the parameter vector
		init::Vector 			  # initial values of input variables
		insyms::Vector{Symbol}    # input vars symbols
		outsym::Symbol            # output variable name (possibly renamed from initial out argument)
		source::Expr              # model source
		exprs::Vector{Expr}       # vector of assigments that make the model
		dexprs::Vector{Expr}      # vector of assigments that make the gradient

		ag::Dict  # variable ancestors graph
		dg::Dict  # variable decendants graph

		vhint					  # stores all expression values to match adequate derivation rule

		ParsingStruct() = new()   # uninitialized constructor
	end

	# find variables in dependency graph g
	relations(v::Symbol, g) = haskey(g, v) ? union( g[v], relations(g[v] ,g) ) : Set()
	relations(vs::Vector, g) = union( map( s->relations(s,g) , vs)... )
	relations(vs::Set, g) = union( map( s->relations(s,g) , [vs...])... )

	# active variables whose gradient need to be calculated
	activeVars(m::ParsingStruct) = intersect(relations(m.outsym, m.ag), relations(m.insyms, m.dg))
	# variables that are not defined in expression and are not input variables
	external(m::ParsingStruct) = setdiff(union(values(m.ag)...), union(Set(keys(m.ag)...), Set(m.insyms...)))

	##### now include parsing and derivation scripts
	include("deriv_rules.jl")
	include("pass1.jl")
	include("pass2.jl")
	include("diff.jl")
end