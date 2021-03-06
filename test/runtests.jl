using BinaryTwoStageDesigns
using Base.Test
using QuadGK
using Roots
using Gurobi
import Distributions

solver = GurobiSolver(
  MIPGap     = 10^(-6.0),
  TimeLimit  = 300,
  OutputFlag = 0
)

include("test_Design.jl")

include("test_SampleSize.jl")

include("test_SampleSpace.jl")

include("test_MESS.jl")

include("test_MBESS.jl")

include("test_EB.jl")

include("test_Liu.jl")

include("test_optimization.jl")

include("test_estimators.jl")

include("test_ci.jl")
