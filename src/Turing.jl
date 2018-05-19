module Turing

##############
# Dependency #
########################################################################
# NOTE: when using anything from external packages,                    #
#       let's keep the practice of explictly writing Package.something #
#       to indicate that's not implemented inside Turing.jl            #
########################################################################

using Distributions
using ForwardDiff
import ReverseDiff
using ProgressMeter
using Stan
using ReverseDiff: GradientTape, GradientConfig, gradient!, compile, TrackedArray

import Base: ~, convert, promote_rule, rand, getindex, setindex!
import Distributions: sample
import ForwardDiff: gradient
import ReverseDiff: gradient
import Mamba: AbstractChains, Chains
import Stan: Adapt, Hmc

##############################
# Global variables/constants #
##############################

global ADBACKEND = :reverse_diff
setadbackend(backend_sym) = begin
  @assert backend_sym == :forward_diff || backend_sym == :reverse_diff
  global ADBACKEND = backend_sym
end

global ADSAFE = false
setadsafe(switch::Bool) = begin
  println("[Turing]: global ADSAFE is set as $switch")
  global ADSAFE = switch
end

global CHUNKSIZE = 0        # default chunksize used by AD
global SEEDS                # pre-alloced dual parts
setchunksize(chunk_size::Int) = begin
  if ~(CHUNKSIZE == chunk_size)
    println("[Turing]: AD chunk size is set as $chunk_size")
    global CHUNKSIZE = chunk_size
    global SEEDS = ForwardDiff.construct_seeds(ForwardDiff.Partials{chunk_size,Float64})
  end
end

setchunksize(40)

global PROGRESS = true
turnprogress(switch::Bool) = begin
  println("[Turing]: global PROGRESS is set as $switch")
  global PROGRESS = switch
end

global VERBOSITY = 1        # verbosity for dprintln & dwarn
global const FCOMPILER = 0  # verbose printing flag for compiler

# Constans for caching
global const CACHERESET  = 0b00
global const CACHEIDCS   = 0b10
global const CACHERANGES = 0b01

global TRANS_CACHE = Dict{Tuple,Any}()

#######################
# Sampler abstraction #
#######################

abstract type InferenceAlgorithm end
abstract type Hamiltonian <: InferenceAlgorithm end

doc"""
    Sampler{T}

Generic interface for implementing inference algorithms.
An implementation of an algorithm should include the following:

1. A type specifying the algorithm and its parameters, derived from InferenceAlgorithm
2. A method of `sample` function that produces results of inference, which is where actual inference happens.

Turing translates models to chunks that call the modelling functions at specified points. The dispatch is based on the value of a `sampler` variable. To include a new inference algorithm implements the requirements mentioned above in a separate file,
then include that file at the end of this one.
"""
type Sampler{T<:InferenceAlgorithm}
  alg   ::  T
  info  ::  Dict{Symbol, Any}         # sampler infomation
end

include("helper.jl")
include("transform.jl")
include("core/varinfo.jl")  # core internal variable container
include("trace/trace.jl")   # to run probabilistic programs as tasks

using Turing.Traces
using Turing.VarReplay

###########
# Exports #
###########

# Turing essentials - modelling macros and inference algorithms
export @model, @~, @VarName                   # modelling
export MH, Gibbs                              # classic sampling
export HMC, SGLD, SGHMC, HMCDA, NUTS          # Hamiltonian-like sampling
export IS, SMC, CSMC, PG, PIMH, PMMH, IPMCMC  # particle-based sampling
export sample, setchunksize, resume           # inference
export auto_tune_chunk_size!, setadbackend, setadsafe # helper
export dprintln, set_verbosity, turnprogress  # debugging

# Turing-safe data structures and associated functions
export TArray, tzeros, localcopy, IArray

export @sym_str

export UnivariateGMM2, Flat, FlatPos

##################
# Turing helpers #
##################

set_verbosity(v::Int) = global VERBOSITY = v

doc"""
    dprintln(v, args...)

Debugging print function. The first argument controls the verbosity of message.
"""
dprintln(v::Int, args...) = v < Turing.VERBOSITY ?
                            println("\r[Turing]: ", args..., "\n $(stacktrace()[2])") :
                            nothing
dwarn(v::Int, args...)    = v < Turing.VERBOSITY ?
                            print_with_color(:red, "\r[Turing.WARNING]: ", mapreduce(string,*,args), "\n $(stacktrace()[2])\n") :
                            nothing
derror(v::Int, args...)   = error("\r[Turing.ERROR]: ", mapreduce(string,*,args))

###########
# Logging #
###########

using Memento

# Create the loggers.
const LOGGER = getlogger(current_module())
const LOGGER_MH = getlogger("$(current_module()).MH")

# Register loggers at runtime so that folks can access the logger via
# `get_logger(MyModule)`.
function __init__()
    Memento.register(LOGGER)
    Memento.register(LOGGER_MH)
end

# Set the logging levels by default to "info" and attach a handler to the root logger.
Memento.setlevel!(LOGGER, "info"; recursive=true)
handler = DefaultHandler(
    STDOUT,
    DefaultFormatter(),
    Dict{Symbol, Any}(:is_colorized => true)
)
LOGGER.handlers["console"] = handler

##################
# Inference code #
##################

include("depreciated.jl")
include("core/util.jl")         # utility functions
include("core/compiler.jl")     # compiler
include("core/container.jl")    # particle container
include("core/io.jl")           # I/O
include("samplers/sampler.jl")  # samplers
include("core/ad.jl")           # Automatic Differentiation

end
