type EB{T_samplespace<:SampleSpace} <: VagueAlternative
    samplespace::T_samplespace
    p0
    pmcrv
    prior
    gamma
    lambda
    a
    b
    k
    alpha
    minconditionalpower
    MONOTONECONDITIONALPOWER::Bool
    npriorpivots::Integer # number of pivots for prior evaluation
    ngpivots::Integer # number of pivots for approximation of g

    function EB(
        samplespace,
        p0, pmcrv, prior,
        gamma, lambda,
        a, b, k,
        alpha,
        minconditionalpower, MONOTONECONDITIONALPOWER,
        npriorpivots, ngpivots
    )
        @checkprob p0 pmcrv alpha minconditionalpower
        z = quadgk(prior, 0, 1, abstol = .0001)[1]
        abs(z - 1)   > .001 ? error(@sprintf("prior must integrate to one, is %.6f", z)) : nothing
        gamma        < 0    ? error(@sprintf("gamma must be positive, is %.6f", gamma)) : nothing
        lambda       < 0    ? error(@sprintf("lambda must be positive, is %.6f", gamma)) : nothing
        lambda/gamma > 500  ? warn(@sprintf("lambda/gamma is large (%.3f), potentially infeasible", lambda/gamma)) : nothing
        a            <= 0   ? error(@sprintf("a must be positive, is %.3f", a)) : nothing
        b            <= 0   ? error(@sprintf("b must be positive, is %.3f", b)) : nothing
        npriorpivots < 5    ? error(@sprintf("npriorpivots must be at least 5, is %i", npriorpivots)) : nothing
        ngpivots     < 5    ? error(@sprintf("npivots must be at least 5, is %i", ngpivots)) : nothing
        new(
            samplespace,
            p0, pmcrv, prior,
            gamma, lambda,
            a, b, k,
            alpha,
            minconditionalpower, MONOTONECONDITIONALPOWER,
            npriorpivots, ngpivots
        )
    end
end
function EB{T_samplespace<:SampleSpace}( # default values
    samplespace::T_samplespace,
    p0::Real, pmcrv::Real, prior,
    gamma::Real, lambda::Real;
    a::Real = 1, b::Real = 1, k::Real = 1,
    alpha::Real = 0.05,
    minconditionalpower::Real = 0.0, MONOTONECONDITIONALPOWER::Bool = true,
    npriorpivots::Integer = 50, ngpivots::Integer = 15
)
    EB{T_samplespace}(
        samplespace,
        p0, pmcrv, prior,
        gamma, lambda,
        a, b, k,
        alpha,
        minconditionalpower, MONOTONECONDITIONALPOWER,
        npriorpivots, ngpivots
    )
end

maxsamplesize(params::EB) = maxsamplesize(params.samplespace)
isgroupsequential{T_samplespace}(params::EB{T_samplespace}) = isgroupsequential(params.ss)
hasmonotoneconditionalpower{T_samplespace}(params::EB{T_samplespace}) = params.MONOTONECONDITIONALPOWER
minconditionalpower(params::EB) = params.minconditionalpower



function expectedcost(design::AbstractBinaryTwoStageDesign, params::EB, p::Real)
    @checkprob p
    ess = SampleSize(design, p) |> mean
    return params.gamma*ess * (p + params.k*(1 - p))
end
function g(params::EB, power)
    @checkprob power
    return Distributions.cdf(Distributions.Beta(params.a, params.b), power)
end
function expectedbenefit(design::AbstractBinaryTwoStageDesign, params::EB, p::Real)
    @checkprob p
    if p < mcrv(params)
        return 0.0
    else
        return params.lambda * g(params, power(design, p))
    end
end
score(design::AbstractBinaryTwoStageDesign, params::EB, p::Real) = -(expectedbenefit(design, params, p) - expectedcost(design, params, p))
function score(design::AbstractBinaryTwoStageDesign, params::EB)
    return quadgk(p -> params.prior(p)*score(design, params, p), 0, 1, reltol = .001)[1]
end

function completemodel{T<:Integer}(ipm::IPModel, params::EB, n1::T)
    ss = samplespace(params)
    !possible(n1, ss) ? error("n1 and sample space incompatible") : nothing
    # extract ip model
    m             = ipm.m
    y             = ipm.y
    nvals         = ipm.nvals
    cvals         = ipm.cvals
    cvalsfinite   = ipm.cvalsfinite
    cvalsinfinite = [-Inf; Inf]
    # extract other parameters
    nmax          = maxsamplesize(ss, n1)
    p0            = null(params)
    pmcrv         = mcrv(params)
    prior         = params.prior
    npriorpivots  = params.npriorpivots
    ngpivots      = params.ngpivots
    # get grid for prior and conditional prior
    priorpivots, dcdf   = findgrid(prior, 0, 1, npriorpivots)
    # add type one error rate constraint
    @constraint(m,
        sum(dbinom(x1, n1, p0)*_cpr(x1, n1, n, c, p0)*y[x1, n, c] for
            x1 in 0:n1, n in nvals, c in cvals
        ) <= alpha(params)
    )
    z = zeros(n1 + 1) # normalizing constants for prior conditional on p >= mcrv, X1=x1
    for x1 in 0:n1
        z[x1 + 1] = quadgk(p -> prior(p)*dbinom(x1, n1, p), pmcrv, 1, abstol = .001)[1]
    end
    @expression(m, cep[x1 in 0:n1], # define expressions for conditional power given X1=x1
        sum(quadgk(p -> prior(p)*dbinom(x1, n1, p)*_cpr.(x1, n1, n, c, p), pmcrv, 1, abstol = 0.001)[1] / z[x1 + 1] * y[x1, n, c]
            for n in nvals, c in cvals
        )
    )
    for x1 in 0:n1
        @constraint(m, # add conditional type two error rate constraint (power) # TODO: must be conditional on continuation!
            cep[x1] >= minconditionalpower(params)
        )
        if x1 >= 1 & hasmonotoneconditionalpower(params)
            @constraint(m, # ensure monotonicity if required
                cep[x1] - cep[x1 - 1] >= 0
            )
        end
    end
    z = zeros(n1 + 1) # normalizing constant for prior conditional on X1=x1
    for x1 in 0:n1
        z[x1 + 1] = quadgk(p -> dbinom(x1, n1, p) * prior(p), 0, 1, abstol = .001)[1]
    end
    @expression(m, ec[x1 in 0:n1], # weighted expected sample size conditional on X1=x1
        sum(
            (params.gamma*(x1 + params.k*(n1 - x1)) + # stage one cost
             quadgk(p -> params.gamma*(p + params.k*(1 - p))*(n - n1) * dbinom(x1, n1, p)*prior(p)/z[x1 + 1], 0, 1, abstol = .001)[1]  # stage two expected
            ) *
            y[x1, n, c]
            for n in nvals, c in cvals
        )
    )
    # construct expressions for power
    @expression(m, designpower[p in priorpivots],
        sum(
            dbinom(x1, n1, p)*_cpr(x1, n1, n, c, p) * y[x1, n, c]
            for x1 in 0:n1, n in nvals, c in cvals
        )
    )
    lbound = quantile(Distributions.Beta(params.a, params.b), .025)
    ubound = quantile(Distributions.Beta(params.a, params.b), .975)
    pivots = [0; collect(linspace(lbound, ubound, max(1, ngpivots - 2))); 1] # lambda formulaion requires edges! exploitn fact that function is locally linear!
    @variable(m, 0 <= lambdaSOS2[priorpivots, pivots] <= 1)
    @variable(m, wpwr[priorpivots]) # weighted power
    for p in priorpivots
        addSOS2(m, [lambdaSOS2[p, piv] for piv in pivots])
        @constraint(m, sum(lambdaSOS2[p, piv] for piv in pivots) == 1)
        @constraint(m, sum(lambdaSOS2[p, piv]*piv for piv in pivots) == designpower[p]) # defines lambdas!
        if p >= params.pmcrv
            @constraint(m, sum(lambdaSOS2[p, piv]*g(params, piv) for piv in pivots) == wpwr[p])
        else
            @constraint(m, wpwr[p] == 0)
        end
    end
    @expression(m, obj,
        sum( ec[x1]*z[x1 + 1] for x1 in 0:n1 ) - params.lambda*sum( wpwr[priorpivots[i]]*dcdf[i] for i in 1:npriorpivots ) # negative score!
    )
    @constraint(m, obj <= 0) # solutions with negative benefit are not feasible
    @objective(m, Min,
        obj
    )
    return true
end

function _isfeasible(design::BinaryTwoStageDesign, params::EB)
    return true
end