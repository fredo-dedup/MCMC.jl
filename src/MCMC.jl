#################################################################
#
#    Main file of MCMC.jl module
#
#################################################################

module MCMC

using DataFrames
using Distributions
using Stats

import Base.*, Base.show
export show, *
export MCMCTask, MCMCChain, MCMCLikModel, MCMCSampler, MCMCTuner, MCMCRunner

# Abstract types
abstract Model
abstract MCMCModel <: Model
abstract MCMCSampler
abstract MCMCTuner
abstract MCMCRunner

###########  Model experssion parsing   ##########
include("parser/parser.jl")     #  include model expression parsing function

###########  Models    ##########
include("modellers/mcmcmodels.jl")      #  include model types definitions    

### MCMCTask type, generated by combining a MCMCModel, a MCMCSampler and a MCMCRunner
type MCMCTask
  task::Task
  model::MCMCModel
  sampler::MCMCSampler
  runner::MCMCRunner
end
reset(t::MCMCTask, x) = t.task.storage[:reset](x)

#############  samplers  ########################
include("samplers/samplers.jl")  # Common definitions for samplers
include("samplers/IMH.jl")    # Independent Metropolis-Hastings sampler
include("samplers/RWM.jl")    # Random-walk Metropolis sampler
include("samplers/RAM.jl")    # Robust adaptive Metropolis sampler
include("samplers/MALA.jl")   # Metropolis adjusted Langevin algorithm sampler
include("samplers/HMC.jl")    # Hamiltonian Monte-Carlo sampler
include("samplers/HMCDA.jl")    # Adaptive Hamiltonian Monte-Carlo sampler with dual averaging
include("samplers/NUTS.jl")   # No U-Turn Hamiltonian Monte-Carlo sampler
include("samplers/SMMALA.jl") # Simplified manifold Metropolis adjusted Langevin algorithm sampler
# include("samplers/MMALA.jl")  # Manifold Metropolis adjusted Langevin algorithm sampler (deprecated)
include("samplers/PMALA.jl")  # Position-dependent Metropolis adjusted Langevin algorithm sampler
include("samplers/RMHMC.jl")  # Riemannian manifold Hamiltonian Monte Carlo sampler
include("samplers/ERMLMC.jl") # Explicit Riemannian manifold Lagrangian Monte Carlo (ERMLMC)
include("samplers/RMLMC.jl") # Semi-explicit Riemannian manifold Lagrangian Monte Carlo (RMLMC)

### MCMCChain, the result of running a MCMCTask
type MCMCChain
  range::Range{Int}
  samples::DataFrame
  gradients::DataFrame
  diagnostics::Dict
  task::Union(MCMCTask, Array{MCMCTask})
  runTime::Float64
   
  function MCMCChain(r::Range{Int}, s::DataFrame, g::DataFrame, d::Dict, t::Union(MCMCTask, Array{MCMCTask}),
    rt::Float64)
    if !isempty(g); @assert size(s) == size(g) "samples and gradients must have the same number of rows and columns"; end
    new(r, s, g, d, t, rt)
  end
end

MCMCChain(r::Range{Int}, s::DataFrame, d::Dict, t::Union(MCMCTask, Array{MCMCTask}), rt::Float64) = 
	MCMCChain(r, s, DataFrame(), d, t, rt)
MCMCChain(r::Range{Int}, s::DataFrame, t::Union(MCMCTask, Array{MCMCTask}), rt::Float64) = 
	MCMCChain(r, s, DataFrame(), Dict(), t, rt)
MCMCChain(r::Range{Int}, s::DataFrame, d::Dict, t::Union(MCMCTask, Array{MCMCTask})) = 
	MCMCChain(r, s, DataFrame(), d, t, NaN)
MCMCChain(r::Range{Int}, s::DataFrame, t::Union(MCMCTask, Array{MCMCTask})) = 
	MCMCChain(r, s, DataFrame(), Dict(), t, NaN)

function show(io::IO, res::MCMCChain)
  println("$(ncol(res.samples)) parameters x $(nrow(res.samples)) samples, $(round(res.runTime, 1)) sec.")
end

<<<<<<< HEAD
#  Definition of * as a shortcut operator for (model, sampler, runner) combination
*{M<:MCMCModel, S<:MCMCSampler, R<:MCMCRunner}(m::M, s::S, r::R) = spinTask(m, s, r)
*{M<:MCMCModel, S<:MCMCSampler, R<:MCMCRunner}(m::Array{M}, s::S, r::R) = map((me) -> spinTask(me, s, r), m)
*{M<:MCMCModel, S<:MCMCSampler, R<:MCMCRunner}(m::M, s::Array{S}, r::R) = map((se) -> spinTask(m, se, r), s)

#############  runners    ########################
include("runners/runners.jl")
include("runners/SerialMC.jl") # Ordinary serial MCMC runner
include("runners/SerialTempMC.jl") # Serial Tempering Monte-Carlo runner
include("runners/SeqMC.jl") # Sequential Monte-Carlo runner
=======
#############  runners    ########################
include("runners/run.jl")         # Vanilla runner
include("runners/seqMC.jl")       # Sequential Monte-Carlo runner
include("runners/serialMC.jl")    # Serial Tempering Monte-Carlo runner
>>>>>>> all tests pass, except syntax, TBD

#############  MCMC output analysis and diagnostics    ########################
include("stats/mean.jl") # MCMC mean estimators
include("stats/var.jl") # MCMC variance estimators
include("stats/ess.jl") # Effective sample size and integrated autocorrelation time functions
include("stats/summary.jl") # Summary statistics for MCMCChain
include("stats/zv.jl")  # ZV-MCMC estimators
end
