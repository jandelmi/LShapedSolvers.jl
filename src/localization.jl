# ------------------------------------------------------------
# UsesLocalization: Algorithm uses some localization method
# ------------------------------------------------------------
@define_trait UsesLocalization = begin
    IsRegularized # Algorithm uses the regularized decomposition method of Ruszczyński
    HasTrustRegion # Algorithm uses the trust-region method of Linderoth/Wright
end

@define_traitfn UsesLocalization init_solver!(lshaped::AbstractLShapedSolver) = begin
    function init_solver!(lshaped::AbstractLShapedSolver,!UsesLocalization)
        nothing
    end
end

@define_traitfn UsesLocalization take_step!(lshaped::AbstractLShapedSolver)

@define_traitfn UsesLocalization check_optimality(lshaped::AbstractLShapedSolver) = begin
    function check_optimality(lshaped::AbstractLShapedSolver,!UsesLocalization)
        Q = get_objective_value(lshaped)
        θ = calculate_estimate(lshaped)
        return θ > -Inf && abs(θ-Q) <= lshaped.τ*(1+abs(θ))
    end

    function check_optimality(lshaped::AbstractLShapedSolver,UsesLocalization)
        Q = lshaped.solverdata.Q̃
        θ = lshaped.solverdata.θ
        return θ > -Inf && abs(θ-Q) <= lshaped.τ*(1+abs(θ))
    end
end

@define_traitfn UsesLocalization remove_inactive!(lshaped::AbstractLShapedSolver) = begin
    function remove_inactive!(lshaped::AbstractLShapedSolver,UsesLocalization)
        inactive = find(c->!active(lshaped,c),lshaped.committee)
        diff = length(lshaped.committee) - length(lshaped.structuredmodel.linconstr) - lshaped.nscenarios
        if isempty(inactive) || diff <= 0
            return false
        end
        if diff <= length(inactive)
            inactive = inactive[1:diff]
        end
        append!(lshaped.inactive,lshaped.committee[inactive])
        deleteat!(lshaped.committee,inactive)
        delconstrs!(lshaped.mastersolver.lqmodel,inactive)
        return true
    end
end

@define_traitfn UsesLocalization queueViolated!(lshaped::AbstractLShapedSolver) = begin
    function queueViolated!(lshaped::AbstractLShapedSolver,UsesLocalization)
        violating = find(c->violated(lshaped,c),lshaped.inactive)
        if isempty(violating)
            return false
        end
        gaps = map(c->gap(lshaped,c),lshaped.inactive[violating])
        for (c,g) in zip(lshaped.inactive[violating],gaps)
            enqueue!(lshaped.violating,c,g)
        end
        deleteat!(lshaped.inactive,violating)
        return true
    end
end

# Is Regularized
# ------------------------------------------------------------
@define_traitfn IsRegularized update_objective!(lshaped::AbstractLShapedSolver)

@implement_traitfn function init_solver!(lshaped::AbstractLShapedSolver,IsRegularized)
    lshaped.solverdata.σ = lshaped.σ
    lshaped.solverdata.exact_steps = 0
    lshaped.solverdata.approximate_steps = 0
    lshaped.solverdata.null_steps = 0

    update_objective!(lshaped)
end

@implement_traitfn function take_step!(lshaped::AbstractLShapedSolver,IsRegularized)
    Q = lshaped.solverdata.Q
    Q̃ = lshaped.solverdata.Q̃
    θ = lshaped.solverdata.θ
    if abs(θ-Q) <= lshaped.τ*(1+abs(θ))
        println("Exact serious step")
        lshaped.ξ[:] = lshaped.x[:]
        lshaped.solverdata.Q̃ = Q
        lshaped.solverdata.exact_steps += 1
        lshaped.solverdata.σ *= 2
        update_objective!(lshaped)
        push!(lshaped.step_hist,3)
    elseif Q + lshaped.τ*(1+abs(Q)) <= lshaped.γ*Q̃ + (1-lshaped.γ)*θ
        println("Approximate serious step")
        lshaped.ξ[:] = lshaped.x[:]
        lshaped.solverdata.Q̃ = Q
        lshaped.solverdata.approximate_steps += 1
        push!(lshaped.step_hist,2)
    else
        println("Null step")
        lshaped.solverdata.null_steps += 1
        lshaped.solverdata.σ *= 0.5
        update_objective!(lshaped)
        push!(lshaped.step_hist,1)
    end
    nothing
end

@implement_traitfn function update_objective!(lshaped::AbstractLShapedSolver,IsRegularized)
    # Linear regularizer penalty
    c = copy(lshaped.c)
    c -= (1/lshaped.solverdata.σ)*lshaped.ξ
    append!(c,fill(1.0,lshaped.nscenarios))
    setobj!(lshaped.mastersolver.lqmodel,c)

    # Quadratic regularizer penalty
    qidx = collect(1:length(lshaped.ξ)+lshaped.nscenarios)
    qval = fill(1/lshaped.solverdata.σ,length(lshaped.ξ))
    append!(qval,zeros(lshaped.nscenarios))
    if applicable(setquadobj!,lshaped.mastersolver.lqmodel,qidx,qidx,qval)
        setquadobj!(lshaped.mastersolver.lqmodel,qidx,qidx,qval)
    else
        error("The regularized decomposition algorithm requires a solver that handles quadratic objectives")
    end
end

# HasTrustRegion
# ------------------------------------------------------------
@define_traitfn HasTrustRegion set_trustregion!(lshaped::AbstractLShapedSolver)
@define_traitfn HasTrustRegion enlarge_trustregion!(lshaped::AbstractLShapedSolver)
@define_traitfn HasTrustRegion reduce_trustregion!(lshaped::AbstractLShapedSolver)

@implement_traitfn function init_solver!(lshaped::AbstractLShapedSolver,HasTrustRegion)
    lshaped.solverdata.Δ = max(1.0,0.01*norm(lshaped.ξ,Inf))
    push!(lshaped.Δ_history,lshaped.solverdata.Δ)

    lshaped.solverdata.major_steps = 0
    lshaped.solverdata.minor_steps = 0

    set_trustregion!(lshaped)
end

@implement_traitfn function take_step!(lshaped::AbstractLShapedSolver,HasTrustRegion)
    Q = lshaped.solverdata.Q
    Q̃ = lshaped.solverdata.Q̃
    θ = lshaped.solverdata.θ
    if Q <= Q̃ - lshaped.γ*abs(Q̃-θ)
        println("Major step")
        lshaped.solverdata.cΔ = 0
        lshaped.ξ[:] = lshaped.x[:]
        lshaped.solverdata.Q̃ = Q
        enlarge_trustregion!(lshaped)
        lshaped.solverdata.major_steps += 1
    else
        println("Minor step")
        reduce_trustregion!(lshaped)
        lshaped.solverdata.minor_steps += 1
    end
    nothing
end

@implement_traitfn function set_trustregion!(lshaped::AbstractLShapedSolver,HasTrustRegion)
    l = max.(lshaped.structuredmodel.colLower, lshaped.ξ-lshaped.solverdata.Δ)
    append!(l,fill(-Inf,lshaped.nscenarios))
    u = min.(lshaped.structuredmodel.colUpper, lshaped.ξ+lshaped.solverdata.Δ)
    append!(u,fill(Inf,lshaped.nscenarios))
    setvarLB!(lshaped.mastersolver.lqmodel,l)
    setvarUB!(lshaped.mastersolver.lqmodel,u)
end

@implement_traitfn function enlarge_trustregion!(lshaped::AbstractLShapedSolver,HasTrustRegion)
    Q = lshaped.solverdata.Q
    Q̃ = lshaped.solverdata.Q̃
    θ = lshaped.solverdata.θ
    if abs(Q - Q̃) <= 0.5*(Q̃-θ) && norm(lshaped.ξ-lshaped.x,Inf) - lshaped.solverdata.Δ <= lshaped.τ
        # Enlarge the trust-region radius
        lshaped.solverdata.Δ = min(lshaped.Δ̅,2*lshaped.solverdata.Δ)
        push!(lshaped.Δ_history,lshaped.solverdata.Δ)
        set_trustregion!(lshaped)
        return true
    else
        return false
    end
end

@implement_traitfn function reduce_trustregion!(lshaped::AbstractLShapedSolver,HasTrustRegion)
    Q = lshaped.solverdata.Q
    Q̃ = lshaped.solverdata.Q̃
    θ = lshaped.solverdata.θ
    ρ = min(1,lshaped.solverdata.Δ)*(Q-Q̃)/(Q̃-θ)
    @show ρ
    if ρ > 0
        lshaped.solverdata.cΔ += 1
    end
    if ρ > 3 || (lshaped.solverdata.cΔ >= 3 && 1 < ρ <= 3)
        # Reduce the trust-region radius
        lshaped.solverdata.cΔ = 0
        lshaped.solverdata.Δ = (1/min(ρ,4))*lshaped.solverdata.Δ
        push!(lshaped.Δ_history,lshaped.solverdata.Δ)
        set_trustregion!(lshaped)
        return true
    else
        return false
    end
end