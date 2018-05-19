const LOGGER_MH = getlogger("$(current_module()).MH")


doc"""
    MH(n_iters::Int)

Metropolis-Hasting sampler.

Usage:

```julia
MH(100, (:m, (x) -> Normal(x, 0.1)))
```

Example:

```julia
# Define a simple Normal model with unknown mean and variance.
@model gdemo(x) = begin
  s ~ InverseGamma(2,3)
  m ~ Normal(0,sqrt(s))
  x[1] ~ Normal(m, sqrt(s))
  x[2] ~ Normal(m, sqrt(s))
  return s, m
end

sample(gdemo([1.5, 2]), MH(1000, (:m, (x) -> Normal(x, 0.1)), :s))
```
"""
immutable MH <: InferenceAlgorithm
  n_iters   ::  Int       # number of iterations
  proposals ::  Dict{Symbol,Any}  # Proposals for paramters
  space     ::  Set       # sampling space, emtpy means all
  gid       ::  Int       # group ID
  function MH(n_iters::Int, space...)
    new_space = Set()
    proposals = Dict{Symbol,Any}()

    # parse random variables with their hypothetical proposal
    for element in space
        if isa(element, Symbol)
          push!(new_space, element)
        else
          if !isa(element[1], Symbol)
              error(LOGGER_MH, "($element[1]) should be a Symbol. For proposal, use the syntax MH(N, (:m, (x) -> Normal(x, 0.1)))")
          end
          push!(new_space, element[1])
          proposals[element[1]] = element[2]
        end
    end

    new(n_iters, proposals, Set(new_space), 0)
  end
  MH(alg::MH, new_gid::Int) = new(alg.n_iters, alg.proposals, alg.space, new_gid)
end

Sampler(alg::MH) = begin
  # Sanity check for space
  if alg.gid == 0 && !isempty(alg.space)
    if !issubset(Turing._compiler_[:pvars], alg.space)
        error(LOGGER_MH, "symbols specified to samplers ($alg.space) doesn't cover the model parameters ($(Turing._compiler_[:pvars]))")
    end
    if Turing._compiler_[:pvars] != alg.space
      warn(LOGGER_MH, "extra parameters specified by samplers don't exist in model: $(setdiff(alg.space, Turing._compiler_[:pvars]))")
    end
  end

  info = Dict{Symbol, Any}()
  info[:accept_his] = []
  info[:total_eval_num] = 0
  info[:proposal_ratio] = 0.0
  info[:prior_prob] = 0.0
  info[:violating_support] = false

  Sampler(alg, info)
end

propose(model::Function, spl::Sampler{MH}, vi::VarInfo) = begin
  spl.info[:proposal_ratio] = 0.0
  spl.info[:prior_prob] = 0.0
  spl.info[:violating_support] = false
  runmodel(model, vi ,spl)
end

step(model::Function, spl::Sampler{MH}, vi::VarInfo, is_first::Bool) = begin
  if is_first
    push!(spl.info[:accept_his], true)
    vi

  else
    if spl.alg.gid != 0 # Recompute joint in logp
      runmodel(model, vi, nothing)
    end
    old_θ = copy(vi[spl])
    old_logp = getlogp(vi)

    debug(LOGGER_MH, "proposing new parameters")
    propose(model, spl, vi)

    debug(LOGGER_MH, "computing acceptance rate")
    α = getlogp(vi) - old_logp + spl.info[:proposal_ratio]

    debug(LOGGER_MH, "deciding whether to accept")
    if log(rand()) < α && !spl.info[:violating_support]  # accepted
      push!(spl.info[:accept_his], true)
    else                      # rejected
      push!(spl.info[:accept_his], false)
      vi[spl] = old_θ         # reset Θ
      setlogp!(vi, old_logp)  # reset logp
    end

    vi
  end
end

function sample(model::Function, alg::MH;
                save_state=false,         # flag for state saving
                resume_from=nothing,      # chain to continue
                reuse_spl_n=0,            # flag for spl re-using
                show_progress::Bool=true  # Show progress
                )

  spl = reuse_spl_n > 0 ?
        resume_from.info[:spl] :
        Sampler(alg)

  # Initialization
  time_total = 0.0
  n = reuse_spl_n > 0 ?
      reuse_spl_n :
      alg.n_iters
  samples = Array{Sample}(n)
  weight = 1 / n
  for i = 1:n
    samples[i] = Sample(weight, Dict{Symbol, Any}())
  end

  vi = resume_from == nothing ?
            Base.invokelatest(model, VarInfo(), nothing) :
            resume_from.info[:vi]

  if spl.alg.gid == 0
    runmodel(model, vi, spl)
  end

  # Initialise the progress bar.
  if show_progress
      p = ProgressMeter.Progress(n; dt=.5, desc="Sampling: ", color=:green)
  end

  for i = 1:n
    time_elapsed = @elapsed vi = step(model, spl, vi, i == 1)
    time_total += time_elapsed

    if spl.info[:accept_his][end]     # accepted => store the new predcits
      samples[i].value = Sample(vi, spl).value
    else                              # rejected => store the previous predcits
      samples[i] = samples[i - 1]
    end
    samples[i].value[:elapsed] = time_elapsed

    # Update the progress bar.
    show_progress && next!(p)
  end

  info(LOGGER_MH, "running time: $time_total s")
  accept_rate = sum(spl.info[:accept_his]) / n
  info(LOGGER_MH, "acceptance rate: $accept_rate")

  if resume_from != nothing   # concat samples
    unshift!(samples, resume_from.value2...)
  end
  c = Chain(0, samples)       # wrap the result by Chain
  if save_state               # save state
    save!(c, spl, model, vi)
  end

  c
end

assume(spl::Sampler{MH}, dist::Distribution, vn::VarName, vi::VarInfo) = begin
    if isempty(spl.alg.space) || vn.sym in spl.alg.space
      if ~haskey(vi, vn) error(LOGGER_MH, "does not handle stochastic existence yet") end
      old_val = vi[vn]

      if vn.sym in keys(spl.alg.proposals) # Custom proposal for this parameter
        proposal = spl.alg.proposals[vn.sym](old_val)

        if typeof(proposal) == Distributions.Normal{Float64} # If Gaussian proposal
          σ = std(proposal)
          lb = support(dist).lb
          ub = support(dist).ub
          stdG = Normal()
          r = rand(TruncatedNormal(proposal.μ, proposal.σ, lb, ub))
          # cf http://fsaad.scripts.mit.edu/randomseed/metropolis-hastings-sampling-with-gaussian-drift-proposal-on-bounded-support/
          spl.info[:proposal_ratio] += log(cdf(stdG, (ub-old_val)/σ) - cdf(stdG,(lb-old_val)/σ))
          spl.info[:proposal_ratio] -= log(cdf(stdG, (ub-r)/σ) - cdf(stdG,(lb-r)/σ))

        else # Other than Gaussian proposal
          r = rand(proposal)
          if (r < support(dist).lb) | (r > support(dist).ub) # check if value lies in support
            spl.info[:violating_support] = true
            r = old_val
          end
          spl.info[:proposal_ratio] -= logpdf(proposal, r) # accumulate pdf of proposal
          reverse_proposal = spl.alg.proposals[vn.sym](r)
          spl.info[:proposal_ratio] += logpdf(reverse_proposal, old_val)
        end

      else # Prior as proposal
        r = rand(dist)
        spl.info[:proposal_ratio] += (logpdf(dist, old_val) - logpdf(dist, r))
      end

      spl.info[:prior_prob] += logpdf(dist, r) # accumulate prior for PMMH
      vi[vn] = vectorize(dist, r)
      setgid!(vi, spl.alg.gid, vn)
    else
      r = vi[vn]
    end

    # acclogp!(vi, logpdf(dist, r)) # accumulate pdf of prior
    r, logpdf(dist, r)
end

assume{D<:Distribution}(spl::Sampler{MH}, dists::Vector{D}, vn::VarName, var::Any, vi::VarInfo) =
  error(LOGGER_MH, "no support for vectorizing assume statement")

observe(spl::Sampler{MH}, d::Distribution, value::Any, vi::VarInfo) =
  observe(nothing, d, value, vi)  # accumulate pdf of likelihood

observe{D<:Distribution}(spl::Sampler{MH}, ds::Vector{D}, value::Any, vi::VarInfo) =
  observe(nothing, ds, value, vi) # accumulate pdf of likelihood
