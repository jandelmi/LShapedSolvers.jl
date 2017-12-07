abstract type HyperPlaneType end

abstract type OptimalityCut <: HyperPlaneType end
abstract type FeasibilityCut <: HyperPlaneType end
abstract type LinearConstraint <: HyperPlaneType end
abstract type Unbounded <: HyperPlaneType end

struct HyperPlane{htype <: HyperPlaneType, float_t <: Real, array_t <: AbstractVector}
    δQ::array_t
    q::float_t
    id::Int

    function (::Type{HyperPlane})(δQ::AbstractVector, q::Real, id::Int, ::Type{htype}) where htype <: HyperPlaneType
        float_t = promote_type(eltype(δQ),Float32)
        δQ_ = convert(AbstractVector{float_t},δQ)
        new{htype, float_t, typeof(δQ_)}(δQ_,q,id)
    end
end
OptimalityCut(δQ::AbstractVector,q::Real,id::Int) = HyperPlane(δQ,q,id,OptimalityCut)
FeasibilityCut(δQ::AbstractVector,q::Real,id::Int) = HyperPlane(δQ,q,id,FeasibilityCut)
LinearConstraint(δQ::AbstractVector,q::Real,id::Int) = HyperPlane(δQ,q,id,LinearConstraint)
Unbounded(id::Int) = HyperPlane{[],Inf,id,Unbounded}

function (hyperplane::HyperPlane{htype})(x::AbstractVector) where htype <: HyperPlaneType
    if length(hyperplane.δQ) != length(x)
        throw(ArgumentError(@sprintf("Dimensions of the cut (%d)) and the given optimization vector (%d) does not match",length(hyperplane.δQ),length(x))))
    end
    return hyperplane.δQ⋅x,hyperplane.q
end

function (cut::HyperPlane{OptimalityCut})(x::AbstractVector)
    if length(cut.δQ) != length(x)
        throw(ArgumentError(@sprintf("Dimensions of the cut (%d)) and the given optimization vector (%d) does not match",length(cut.δQ),length(x))))
    end
    return cut.q-cut.δQ⋅x
end

bounded(hyperplane::HyperPlane) = true
bounded(hyperplane::HyperPlane{Unbounded}) = false
function optimal(lshaped::AbstractLShapedSolver,cut::HyperPlane{OptimalityCut})
    Q = cut(lshaped.x)
    θ = lshaped.θs[cut.id]
    return θ > -Inf && abs(θ-Q) <= lshaped.τ*(1+abs(Q))
end
function active(lshaped::AbstractLShapedSolver,hyperplane::HyperPlane)
    Gval,g = hyperplane(lshaped.x)
    return abs(Gval-g) <= lshaped.τ*(1+abs(Gval))
end
function active(lshaped::AbstractLShapedSolver,cut::HyperPlane{OptimalityCut})
    optimal(lshaped,cut)
end
function satisfied(lshaped::AbstractLShapedSolver,hyperplane::HyperPlane)
    Gval,g = hyperplane(lshaped.x)
    return Gval >= g - lshaped.τ*(1+abs(Gval))
end
function satisfied(lshaped::AbstractLShapedSolver,cut::HyperPlane{OptimalityCut})
    Q = cut(lshaped.x)
    θ = lshaped.θs[cut.id]
    return θ > -Inf && θ >= Q - lshaped.τ*(1+abs(Q))
end
function violated(lshaped::AbstractLShapedSolver,hyperplane::HyperPlane)
    return !satisfied(lshaped,hyperplane)
end
function gap(lshaped::AbstractLShapedSolver,hyperplane::HyperPlane)
    Gval,g = hyperplane(lshaped.x)
    return Gval-g
end
function gap(lshaped::AbstractLShapedSolver,cut::HyperPlane{OptimalityCut})
    Q = cut(lshaped.x)
    θ = lshaped.θs[cut.id]
    if θ > -Inf
        return θ-Q
    else
        return Inf
    end
end
function lowlevel(hyperplane::HyperPlane{htype,float_t,SparseVector{float_t,Int}}) where {htype <: HyperPlaneType, float_t <: Real}
    return hyperplane.δQ.nzind,hyperplane.δQ.nzval,hyperplane.q,Inf
end
function lowlevel(cut::HyperPlane{OptimalityCut,float_t,SparseVector{float_t,Int}}) where float_t <: Real
    nzind = copy(cut.δQ.nzind)
    nzval = copy(cut.δQ.nzval)
    push!(nzind,length(cut.δQ)+cut.id)
    push!(nzval,1.0)
    return nzind,nzval,cut.q,Inf
end

# Constructors #
# ======================================================================== #
function OptimalityCut(subprob::SubProblem)
    @assert status(subprob.solver) == :Optimal
    λ = subprob.solver.λ
    π = subprob.π
    cols = zeros(length(subprob.masterTerms))
    vals = zeros(length(subprob.masterTerms))
    for (s,(i,j,coeff)) in enumerate(subprob.masterTerms)
        cols[s] = j
        vals[s] = -π*λ[i]*coeff
    end
    δQ = sparsevec(cols,vals,length(subprob.x))
    q = π*subprob.solver.obj+δQ⋅subprob.x

    return OptimalityCut(δQ, q, subprob.id)
end

function FeasibilityCut(subprob::SubProblem)
    @assert status(subprob.solver) == :Infeasible "Trying to generate feasibility cut from non-infeasible subproblem"
    λ = subprob.solver.λ
    cols = zeros(length(subprob.masterTerms))
    vals = zeros(length(subprob.masterTerms))
    for (s,(i,j,coeff)) in enumerate(subprob.masterTerms)
        cols[s] = j
        vals[s] = -λ[i]*coeff
    end
    G = sparsevec(cols,vals,subprob.nMasterCols)
    g = subprob.solver.obj-G⋅subprob.x

    return FeasibilityCut(G, g, subprob.id)
end

function LinearConstraint(constraint::JuMP.LinearConstraint,i::Integer)
    sense = JuMP.sense(constraint)
    if sense == :range
        throw(ArgumentError("Cannot handle range constraints"))
    end
    cols = map(v->v.col,constraint.terms.vars)
    vals = constraint.terms.coeffs * (sense == :(>=) ? 1 : -1)
    G = sparsevec(cols,vals,constraint.terms.vars[1].m.numCols)
    g = JuMP.rhs(constraint) * (sense == :(>=) ? 1 : -1)

    return LinearConstraint(G,g,i)
end

function linearconstraints(m::JuMPModel)
    constraints = Vector{HyperPlane{LinearConstraint}}(length(m.linconstr))
    for (i,c) in enumerate(m.linconstr)
        constraints[i] = LinearConstraint(c,i)
    end
    return constraints
end

Unbounded(subprob::SubProblem) = Unbounded(subprob.id)
# ======================================================================== #

#  #
# ======================================================================== #
function addCut!(lshaped::AbstractLShapedSolver,cut::HyperPlane{OptimalityCut},x::AbstractVector)
    cutIdx = numvar(lshaped.masterSolver.model)

    Q = cut(x)
    θ = lshaped.θs[cut.id]
    τ = lshaped.τ

    lshaped.subObjectives[cut.id] = Q

    println("θ",cut.id,": ", θ)
    println("Q",cut.id,": ", Q)

    if θ > -Inf && abs(θ-Q) <= τ*(1+abs(Q))
        # Optimal with respect to this subproblem
        println("Optimal with respect to subproblem ", cut.id)
        return false
    end

    lshaped.nOptimalityCuts += 1
    println("Added Optimality Cut")
    if hastrait(lshaped,IsRegularized)
        push!(lshaped.committee,cut)
        addconstr!(lshaped.masterSolver.model,lowlevel(cut)...)
    elseif hastrait(lshaped,HasTrustRegion)
        push!(lshaped.committee,cut)
        addconstr!(lshaped.masterSolver.model,lowlevel(cut)...)
    else
        addconstr!(lshaped.masterSolver.model,lowlevel(cut)...)
    end
    push!(lshaped.cuts,cut)
    return true
end
addCut!(lshaped::AbstractLShapedSolver,cut::HyperPlane{OptimalityCut}) = addCut!(lshaped,cut,lshaped.x)

function addCut!(lshaped::AbstractLShapedSolver,cut::HyperPlane{FeasibilityCut})
    cutIdx = lshaped.masterSolver.lp.numCols

    D = cut.δQ
    d = cut.q

    # Scale to avoid numerical issues
    scaling = abs(d)
    if scaling == 0
        scaling = maximum(D)
    end

    D = D/scaling

    lshaped.nFeasibilityCuts += 1
    println("Added Feasibility Cut")
    if hastrait(lshaped,IsRegularized)
        push!(lshaped.committee,cut)
        addconstr!(lshaped.masterSolver.model,lowlevel(cut)...)
    elseif hastrait(lshaped,HasTrustRegion)
        push!(lshaped.committee,cut)
        addconstr!(lshaped.masterSolver.model,lowlevel(cut)...)
    else
        addconstr!(lshaped.masterSolver.model,lowlevel(cut)...)
    end
    push!(lshaped.cuts,cut)
    return true
end