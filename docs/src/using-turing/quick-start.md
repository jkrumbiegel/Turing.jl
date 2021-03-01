---
title: Probabilistic Programming in Thirty Seconds
---

# Probabilistic Programming in Thirty Seconds

If you are already well-versed in probabilistic programming and just want to take a quick look at how Turing's syntax works or otherwise just want a model to start with, we have provided a Bayesian coin-flipping model to play with.


This example can be run however you have Julia installed (see [Getting Started]({{site.baseurl}}/docs/using-turing/get-started)), but you will need to install the packages `Turing` and `StatsPlots` if you have not done so already.


This is an excerpt from a more formal example introducing probabilistic programming which can be found in Jupyter notebook form [here](https://nbviewer.jupyter.org/github/TuringLang/TuringTutorials/blob/master/0_Introduction.ipynb) or as part of the documentation website [here]({{site.baseurl}}/tutorials).


```julia
# Import libraries.
using Turing, StatsPlots, Random

# Set the true probability of heads in a coin.
p_true = 0.5

# Set the number of observations to 100.
N = 100

# Draw data from a Bernoulli distribution, i.e. draw heads or tails.
Random.seed!(12)
data = rand(Bernoulli(p_true), N)

# Declare our Turing model.
@model function coinflip(y)
    # Our prior belief about the probability of heads in a coin.
    p ~ Beta(1, 1)

    # The number of observations.
    N = length(y)
    for n in 1:N
        # Heads or tails of a coin are drawn from a Bernoulli distribution.
        y[n] ~ Bernoulli(p)
    end
end

# Settings of the Hamiltonian Monte Carlo (HMC) sampler.
iterations = 1000
ϵ = 0.05
τ = 10

# Start sampling.
chain = sample(coinflip(data), HMC(ϵ, τ), iterations)

# Plot a summary of the sampling process for the parameter p, i.e. the probability of heads in a coin.
histogram(chain[:p])
```
