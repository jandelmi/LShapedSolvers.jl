@with_kw mutable struct TrustRegionSolverData{T <: Real}
    Q::T = 1e10
    Q̃::T = 1e10
    θ::T = -1e10
    Δ::T = 1.0
    cΔ::Int = 0
    major_steps::Int = 0
    minor_steps::Int = 0
end

struct TrustRegionLShapedSolver{T <: Real, A <: AbstractVector, M <: LQSolver, S <: LQSolver} <: AbstractLShapedSolver{T,A,M,S}
    structuredmodel::JuMPModel
    solverdata::TrustRegionSolverData{T}

    # Master
    mastersolver::M
    c::A
    x::A

    committee::Vector{SparseHyperPlane{T}}
    inactive::Vector{SparseHyperPlane{T}}
    violating::PriorityQueue{SparseHyperPlane{T},T}

    # Subproblems
    nscenarios::Int
    subproblems::Vector{SubProblem{T,A,S}}
    subobjectives::A

    # Trust region
    ξ::A
    Q_history::A
    Q̃_history::A
    Δ_history::A

    # Cuts
    θs::A
    cuts::Vector{SparseHyperPlane{T}}
    θ_history::A

    # Params
    γ::T
    τ::T
    Δ̅::T

    function (::Type{TrustRegionLShapedSolver})(model::JuMPModel,ξ₀::AbstractVector,mastersolver::AbstractMathProgSolver,subsolver::AbstractMathProgSolver)
        length(ξ₀) != model.numCols && error("Incorrect length of starting guess, has ",length(ξ₀)," should be ",model.numCols)
        !haskey(model.ext,:Stochastic) && error("The provided model is not structured")

        T = promote_type(eltype(ξ₀),Float32)
        c_ = convert(AbstractVector{T},JuMP.prepAffObjective(model))
        c_ *= model.objSense == :Min ? 1 : -1
        x₀_ = convert(AbstractVector{T},copy(ξ₀))
        ξ₀_ = convert(AbstractVector{T},copy(ξ₀))
        A = typeof(ξ₀_)

        msolver = LQSolver(model,mastersolver)
        M = typeof(msolver)
        S = LQSolver{typeof(LinearQuadraticModel(subsolver)),typeof(subsolver)}
        n = num_scenarios(model)

        lshaped = new{T,A,M,S}(model,
                               TrustRegionSolverData{T}(),
                               msolver,
                               c_,
                               x₀_,
                               convert(Vector{SparseHyperPlane{T}},linearconstraints(model)),
                               Vector{SparseHyperPlane{T}}(),
                               PriorityQueue{SparseHyperPlane{T},T}(Reverse),
                               n,
                               Vector{SubProblem{T,A,S}}(),
                               A(zeros(n)),
                               ξ₀_,
                               A(),
                               A(),
                               A(),
                               A(fill(-1e10,n)),
                               Vector{SparseHyperPlane{T}}(),
                               A(),
                               convert(T,1e-4),
                               convert(T,1e-6),
                               convert(T,max(1.0,0.05*norm(ξ₀_,Inf)))
                               )
        init!(lshaped,subsolver)

        return lshaped
    end
end
TrustRegionLShapedSolver(model::JuMPModel,mastersolver::AbstractMathProgSolver,subsolver::AbstractMathProgSolver) = TrustRegionLShapedSolver(model,rand(model.numCols),mastersolver,subsolver)

@implement_trait TrustRegionLShapedSolver UsesLocalization HasTrustRegion

function Base.show(io::IO, lshaped::TrustRegionLShapedSolver)
    print(io,"TrustRegionLShapedSolver")
end

function (lshaped::TrustRegionLShapedSolver)()
    println("Starting L-Shaped procedure with trust-region")
    println("======================")

    println("Main loop")
    println("======================")

    while true
        iterate!(lshaped)

        if check_optimality(lshaped)
            # Optimal
            update_structuredmodel!(lshaped)
            println("Optimal!")
            println("Objective value: ", calculate_objective_value(lshaped))
            println("======================")
            break
        end
    end
end

function iterate!(lshaped::TrustRegionLShapedSolver)
    if isempty(lshaped.violating)
        # Resolve all subproblems at the current optimal solution
        lshaped.solverdata.Q = resolve_subproblems!(lshaped)
        # Update the optimization vector
        take_step!(lshaped)
    else
        # Add at most L violating constraints
        # L = 0
        # while !isempty(lshaped.violating) && L < lshaped.nscenarios
        #     constraint = dequeue!(lshaped.violating)
        #     if satisfied(lshaped,constraint)
        #         push!(lshaped.inactive,constraint)
        #         continue
        #     end
        #     println("Adding violated constraint to committee")
        #     push!(lshaped.committee,constraint)
        #     addconstr!(lshaped.mastersolver.lqmodel,lowlevel(constraint)...)
        #     L += 1
        # end
    end
    # Resolve master
    println("Solving master problem")
    lshaped.mastersolver(lshaped.x)
    if status(lshaped.mastersolver) == :Infeasible
        println("Master is infeasible, aborting procedure.")
        println("======================")
        return
    end
    # Update master solution
    update_solution!(lshaped)
    lshaped.solverdata.θ = calculate_estimate(lshaped)
    # remove_inactive!(lshaped)
    # if length(lshaped.violating) <= lshaped.nscenarios
    #     queueViolated!(lshaped)
    # end
    push!(lshaped.Q_history,lshaped.solverdata.Q)
    push!(lshaped.Q̃_history,lshaped.solverdata.Q̃)
    push!(lshaped.θ_history,lshaped.solverdata.θ)
    nothing
end

## Trait functions
# ------------------------------------------------------------
@define_traitfn UsesLocalization set_trustregion!(lshaped::AbstractLShapedSolver)
@define_traitfn UsesLocalization enlarge_trustregion!(lshaped::AbstractLShapedSolver)
@define_traitfn UsesLocalization reduce_trustregion!(lshaped::AbstractLShapedSolver)

@implement_traitfn HasTrustRegion function init_solver!(lshaped::AbstractLShapedSolver)
    lshaped.solverdata.Δ = max(1.0,0.01*norm(lshaped.ξ,Inf))
    push!(lshaped.Δ_history,lshaped.solverdata.Δ)

    lshaped.solverdata.major_steps = 0
    lshaped.solverdata.minor_steps = 0

    set_trustregion!(lshaped)
end

@implement_traitfn HasTrustRegion function take_step!(lshaped::AbstractLShapedSolver)
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

@implement_traitfn HasTrustRegion function set_trustregion!(lshaped::AbstractLShapedSolver)
    l = max.(lshaped.structuredmodel.colLower, lshaped.ξ-lshaped.solverdata.Δ)
    append!(l,fill(-Inf,lshaped.nscenarios))
    u = min.(lshaped.structuredmodel.colUpper, lshaped.ξ+lshaped.solverdata.Δ)
    append!(u,fill(Inf,lshaped.nscenarios))
    setvarLB!(lshaped.mastersolver.lqmodel,l)
    setvarUB!(lshaped.mastersolver.lqmodel,u)
end

@implement_traitfn HasTrustRegion function enlarge_trustregion!(lshaped::AbstractLShapedSolver)
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

@implement_traitfn HasTrustRegion function reduce_trustregion!(lshaped::AbstractLShapedSolver)
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
