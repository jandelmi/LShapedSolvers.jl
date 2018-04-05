@with_kw mutable struct ALevelSetData{T <: Real}
    Q::T = 1e10
    Q̃::T = 1e10
    θ::T = -1e10
    i::Int = 1
    timestamp::Int = 1
end

@with_kw struct ALevelSetParameters{T <: Real}
    κ::T = 0.3
    τ::T = 1e-6
    λ::T = 1.0
end

struct ALevelSet{T <: Real, A <: AbstractVector, M <: LQSolver, S <: LQSolver} <: AbstractLShapedSolver{T,A,M,S}
    structuredmodel::JuMP.Model
    solverdata::ALevelSetData{T}

    # Master
    mastersolver::M
    projectionsolver::M
    c::A
    x::A
    Q_history::A

    # Subproblems
    nscenarios::Int
    subobjectives::Vector{A}
    finished::Vector{Int}

    # Workers
    subworkers::Vector{SubWorker{T,A,S}}
    work::Vector{Work}
    decisions::Decisions{A}
    cutqueue::CutQueue{T}

    # Regularizer
    ξ::A
    Q̃_history::A
    levels::A

    # Cuts
    θs::A
    cuts::Vector{SparseHyperPlane{T}}
    θ_history::A

    # Params
    parameters::ALevelSetParameters{T}
    progress::ProgressThresh{T}

    @implement_trait ALevelSet HasLevels
    @implement_trait ALevelSet IsParallel

    function (::Type{ALevelSet})(model::JuMP.Model,ξ₀::AbstractVector,mastersolver::AbstractMathProgSolver,subsolver::AbstractMathProgSolver; kw...)
        if nworkers() == 1
            warn("There are no worker processes, defaulting to serial version of algorithm")
            return LevelSet(model,ξ₀,mastersolver,subsolver; kw...)
        end
        length(ξ₀) != model.numCols && error("Incorrect length of starting guess, has ",length(ξ₀)," should be ",model.numCols)
        !haskey(model.ext,:SP) && error("The provided model is not structured")

        T = promote_type(eltype(ξ₀),Float32)
        c_ = convert(AbstractVector{T},JuMP.prepAffObjective(model))
        c_ *= model.objSense == :Min ? 1 : -1
        x₀_ = convert(AbstractVector{T},copy(ξ₀))
        ξ₀_ = convert(AbstractVector{T},copy(ξ₀))
        A = typeof(x₀_)

        msolver = LQSolver(model,mastersolver)
        psolver = LQSolver(model,mastersolver)
        M = typeof(msolver)
        S = LQSolver{typeof(LinearQuadraticModel(subsolver)),typeof(subsolver)}
        n = StochasticPrograms.nscenarios(model)

        lshaped = new{T,A,M,S}(model,
                               ALevelSetData{T}(),
                               msolver,
                               psolver,
                               c_,
                               x₀_,
                               A(),
                               n,
                               Vector{A}(),
                               Vector{Int}(),
                               Vector{SubWorker{T,A,S}}(nworkers()),
                               Vector{Work}(nworkers()),
                               RemoteChannel(() -> DecisionChannel(Dict{Int,A}())),
                               RemoteChannel(() -> Channel{QCut{T}}(4*nworkers()*n)),
                               ξ₀_,
                               A(),
                               A(),
                               A(fill(-Inf,n)),
                               Vector{SparseHyperPlane{T}}(),
                               A(),
                               ALevelSetParameters{T}(;kw...),
                               ProgressThresh(1.0, "Asynchronous LV L-Shaped Gap "))
        lshaped.progress.thresh = lshaped.parameters.τ
        push!(lshaped.subobjectives,zeros(n))
        push!(lshaped.finished,0)
        push!(lshaped.Q_history,Inf)
        push!(lshaped.Q̃_history,Inf)
        push!(lshaped.θ_history,-Inf)

        init!(lshaped,subsolver)

        return lshaped
    end
end
ALevelSet(model::JuMP.Model,mastersolver::AbstractMathProgSolver,subsolver::AbstractMathProgSolver; kw...) = ALevelSet(model,rand(model.numCols),mastersolver,subsolver; kw...)

function (lshaped::ALevelSet{T,A,M,S})() where {T <: Real, A <: AbstractVector, M <: LQSolver, S <: LQSolver}
    # Reset timer
    lshaped.progress.tfirst = lshaped.progress.tlast = time()
    # Start workers
    finished_workers = Vector{Future}(nworkers())
    for w in workers()
        finished_workers[w-1] = remotecall(work_on_subproblems!,
                                           w,
                                           lshaped.subworkers[w-1],
                                           lshaped.work[w-1],
                                           lshaped.cutqueue,
                                           lshaped.decisions)
    end
    # Start procedure
    while true
        wait(lshaped.cutqueue)
        while isready(lshaped.cutqueue)
            # Add new cuts from subworkers
            t::Int,Q::T,cut::SparseHyperPlane{T} = take!(lshaped.cutqueue)
            if !bounded(cut)
                warn("Subproblem ",cut.id," is unbounded, aborting procedure.")
                return :Unbounded
            end
            addcut!(lshaped,cut,Q)
            lshaped.subobjectives[t][cut.id] = Q
            lshaped.finished[t] += 1
            if lshaped.finished[t] == lshaped.nscenarios
                lshaped.Q_history[t] = calculate_objective_value(lshaped,lshaped.subobjectives[t])
                if lshaped.Q_history[t] <= lshaped.solverdata.Q
                    lshaped.solverdata.Q = lshaped.Q_history[t]
                end
                lshaped.x[:] = fetch(lshaped.decisions,t)
                take_step!(lshaped)
            end
        end

        # Resolve master
        t = lshaped.solverdata.timestamp
        if lshaped.finished[t] >= lshaped.parameters.κ*lshaped.nscenarios && length(lshaped.cuts) >= lshaped.nscenarios
            # Update the optimization vector
            lshaped.mastersolver(lshaped.x)
            if status(lshaped.mastersolver) == :Infeasible
                warn("Master is infeasible, aborting procedure.")
                return :Infeasible
            end

            # Update master solution
            update_solution!(lshaped)

            θ = calculate_estimate(lshaped)
            lshaped.solverdata.θ = θ
            lshaped.Q̃_history[t] = lshaped.solverdata.Q̃
            lshaped.θ_history[t] = θ

            if check_optimality(lshaped)
                # Optimal
                map(w->put!(w,-1),lshaped.work)
                lshaped.x[:] = lshaped.ξ[:]
                lshaped.solverdata.Q = calculateObjective(lshaped,lshaped.x)
                lshaped.Q_history[t] = lshaped.solverdata.Q
                close(lshaped.cutqueue)
                map(wait,finished_workers)
                return :Optimal
            end

            project!(lshaped)

            # Send new decision vector to workers
            put!(lshaped.decisions,t+1,lshaped.x)
            for w in lshaped.work
                put!(w,t+1)
            end

            # Prepare memory for next timestamp
            lshaped.solverdata.timestamp += 1
            @unpack Q,Q̃,θ = lshaped.solverdata
            push!(lshaped.Q_history,Q)
            push!(lshaped.Q̃_history,Q̃)
            push!(lshaped.θ_history,θ)
            push!(lshaped.subobjectives,zeros(lshaped.nscenarios))
            push!(lshaped.finished,0)
            gap = abs(θ-Q)/(1+abs(Q))
            ProgressMeter.update!(lshaped.progress,gap,
                          showvalues = [
                              ("Objective",Q),
                              ("Gap",gap),
                              ("Number of cuts",length(lshaped.cuts))
                          ])
        end
    end
end