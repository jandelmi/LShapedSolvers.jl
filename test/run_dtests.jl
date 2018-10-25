using Test
using Distributed
include(joinpath(Sys.BINDIR, "..", "share", "julia", "test", "testenv.jl"))
addprocs_with_testenv(3)
@test nworkers() == 3

@everywhere using Logging
for w in workers()
    # Do not log on worker nodes
    remotecall(()->global_logger(NullLogger()),w)
end

@everywhere using StochasticPrograms
using LShapedSolvers
using JuMP
using GLPKMathProgInterface

τ = 1e-5
reference_solver = GLPKSolverLP()
dlsolvers = [(LShapedSolver(:dls,reference_solver,log=false),"L-Shaped"),
             (LShapedSolver(:drd,reference_solver,crash=Crash.EVP(),autotune=true,log=false,linearize=true),"Linearized RD L-Shaped"),
             (LShapedSolver(:dtr,reference_solver,crash=Crash.EVP(),autotune=true,log=false),"TR L-Shaped"),
             (LShapedSolver(:dlv,reference_solver,log=false,linearize=true),"Linearized Leveled L-Shaped")]

lsolvers = [(LShapedSolver(:ls,reference_solver,log=false),"L-Shaped"),
            (LShapedSolver(:rd,reference_solver,crash=Crash.EVP(),autotune=true,log=false,linearize=true),"Linearized RD L-Shaped"),
            (LShapedSolver(:tr,reference_solver,crash=Crash.EVP(),autotune=true,log=false),"TR L-Shaped"),
            (LShapedSolver(:lv,reference_solver,log=false,linearize=true),"Linearized Leveled L-Shaped")]
problems = Vector{Tuple{JuMP.Model,String}}()
@info "Loading test problems..."
@info "Loading simple..."
include("simple.jl")
@info "Loading farmer..."
include("farmer.jl")
@info "Loading infeasible..."
include("infeasible.jl")

@testset "Distributed solvers" begin
    @testset "Simple problems" begin
        @info "Test problems loaded. Starting test sequence."
        @testset "Distributed $lsname Solver with Distributed Data: $name" for (lsolver,lsname) in dlsolvers, (sp,name) in problems
            solve(sp,solver=reference_solver)
            x̄ = copy(sp.colVal)
            Q̄ = copy(sp.objVal)
            solve(sp,solver=lsolver)
            @test abs(optimal_value(sp) - Q̄)/(1e-10+abs(Q̄)) <= τ
        end
        @testset "Distributed Bundled $lsname Solver: $name" for (lsolver,lsname) in dlsolvers, (sp,name) in problems
            solve(sp,solver=reference_solver)
            x̄ = optimal_decision(sp)
            Q̄ = optimal_value(sp)
            add_params!(lsolver,bundle=2)
            solve(sp,solver=lsolver)
            @test abs(optimal_value(sp) - Q̄)/(1e-10+abs(Q̄)) <= τ
        end
        @testset "Distributed $lsname Solver: $name" for (lsolver,lsname) in dlsolvers, (sp,name) in problems
            sp_nondist = StochasticProgram(first_stage_data(sp),second_stage_data(sp),scenarios(sp),procs=[1])
            transfer_model!(stochastic(sp_nondist),stochastic(sp))
            generate!(sp_nondist)
            solve(sp_nondist,solver=reference_solver)
            x̄ = copy(sp_nondist.colVal)
            Q̄ = copy(sp_nondist.objVal)
            solve(sp_nondist,solver=lsolver)
            @test abs(optimal_value(sp_nondist) - Q̄)/(1e-10+abs(Q̄)) <= τ
        end
        @testset "$lsname Solver with Distributed Data: $name" for (lsolver,lsname) in lsolvers, (sp,name) in problems
            solve(sp,solver=reference_solver)
            x̄ = copy(sp.colVal)
            Q̄ = copy(sp.objVal)
            with_logger(NullLogger()) do
                solve(sp,solver=lsolver)
            end
            @test abs(optimal_value(sp) - Q̄)/(1e-10+abs(Q̄)) <= τ
        end
    end
    @testset "Infeasible problem" begin
        @testset "$lsname Solver: Feasibility cuts" for (lsolver,lsname) in dlsolvers
            solve(infeasible,solver=reference_solver)
            x̄ = optimal_decision(infeasible)
            Q̄ = optimal_value(infeasible)
            with_logger(NullLogger()) do
                @test solve(infeasible,solver=lsolver) == :Infeasible
            end
            add_params!(lsolver,checkfeas=true)
            solve(infeasible,solver=lsolver)
            @test abs(optimal_value(infeasible) - Q̄)/(1e-10+abs(Q̄)) <= τ
        end
        @testset "Bundled $lsname Solver: Feasibility cuts" for (lsolver,lsname) in dlsolvers
            solve(infeasible,solver=reference_solver)
            x̄ = optimal_decision(infeasible)
            Q̄ = optimal_value(infeasible)
            add_params!(lsolver,checkfeas=false,bundle=2)
            with_logger(NullLogger()) do
                @test solve(infeasible,solver=lsolver) == :Infeasible
            end
            add_params!(lsolver,checkfeas=true,bundle=2)
            solve(infeasible,solver=lsolver)
            @test abs(optimal_value(infeasible) - Q̄)/(1e-10+abs(Q̄)) <= τ
        end
    end
end
