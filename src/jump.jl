
# The following is largely inspired from JuMP/test/JuMPExtension.jl

@enum Level BOTH LOWER UPPER

abstract type AbstractBilevelModel <: JuMP.AbstractModel end

mutable struct BilevelModel <: AbstractBilevelModel
    # Structured data
    upper::JuMP.AbstractModel
    lower::JuMP.AbstractModel

    # Model data
    nextvaridx::Int                                 # Next variable index is nextvaridx+1
    variables::Dict{Int, JuMP.AbstractVariable}     # Map varidx -> variable
    varnames::Dict{Int, String}                     # Map varidx -> name
    var_level::Dict{Int, Level}
    var_upper::Dict{Int, JuMP.AbstractVariableRef}
    var_lower::Dict{Int, JuMP.AbstractVariableRef}

    # upper level decisions that are "paramters" of the second level
    upper_to_lower_link::Dict{JuMP.AbstractVariableRef, JuMP.AbstractVariableRef}
    # lower level decisions that are input to upper
    lower_to_upper_link::Dict{JuMP.AbstractVariableRef, JuMP.AbstractVariableRef}
    # joint link
    link::Dict{JuMP.AbstractVariableRef, JuMP.AbstractVariableRef}

    nextconidx::Int                                 # Next constraint index is nextconidx+1
    constraints::Dict{Int, JuMP.AbstractConstraint} # Map conidx -> variable
    connames::Dict{Int, String}                     # Map varidx -> name
    ctr_level::Dict{Int, Level}
    ctr_upper::Dict{Int, JuMP.ConstraintRef}
    ctr_lower::Dict{Int, JuMP.ConstraintRef}

    upper_objective_sense::MOI.OptimizationSense
    upper_objective_function::JuMP.AbstractJuMPScalar

    lower_objective_sense::MOI.OptimizationSense
    lower_objective_function::JuMP.AbstractJuMPScalar

    # solution data
    solver#::MOI.ModelLike
    upper_to_sblm
    lower_to_sblm
    sblm_to_solver

    objdict::Dict{Symbol, Any}                      # Same that JuMP.Model's field `objdict`

    function BilevelModel()

        model = new(
            JuMP.Model(),
            JuMP.Model(),

            # var
            0, Dict{Int, JuMP.AbstractVariable}(),   Dict{Int, String}(),    # Model Variables
            Dict{Int, Level}(), Dict{Int, JuMP.AbstractVariable}(), Dict{Int, JuMP.AbstractVariable}(),
            # links
            Dict{Int, JuMP.AbstractVariable}(), Dict{Int, JuMP.AbstractVariable}(),
            Dict{Int, JuMP.AbstractVariable}(),
            #ctr
            0, Dict{Int, JuMP.AbstractConstraint}(), Dict{Int, String}(),    # Model Constraints
            Dict{Int, Level}(), Dict{Int, JuMP.AbstractConstraint}(), Dict{Int, JuMP.AbstractConstraint}(),
            #obj
            MOI.FEASIBILITY_SENSE,
            zero(JuMP.GenericAffExpr{Float64, BilevelVariableRef}), # Model objective
            MOI.FEASIBILITY_SENSE,
            zero(JuMP.GenericAffExpr{Float64, BilevelVariableRef}), # Model objective

            nothing,
            nothing,
            nothing,
            nothing,
            Dict{Symbol, Any}(),
            )

        return model
    end
end

abstract type InnerBilevelModel <: AbstractBilevelModel end
struct UpperModel <: InnerBilevelModel
    m::BilevelModel
end
Upper(m::BilevelModel) = UpperModel(m)
struct LowerModel <: InnerBilevelModel
    m::BilevelModel
end
Lower(m::BilevelModel) = LowerModel(m)
bilevel_model(m::InnerBilevelModel) = m.m
mylevel_model(m::UpperModel) = bilevel_model(m).upper
mylevel_model(m::LowerModel) = bilevel_model(m).lower
level(m::LowerModel) = LOWER
level(m::UpperModel) = UPPER
mylevel_ctr_list(m::LowerModel) = bilevel_model(m).ctr_lower
mylevel_ctr_list(m::UpperModel) = bilevel_model(m).ctr_upper
mylevel_var_list(m::LowerModel) = bilevel_model(m).var_lower
mylevel_var_list(m::UpperModel) = bilevel_model(m).var_upper

# obj

mylevel_obj_sense(m::LowerModel) = bilevel_model(m).lower_objective_sense
mylevel_obj_function(m::LowerModel) = bilevel_model(m).lower_objective_function
mylevel_obj_sense(m::UpperModel) = bilevel_model(m).upper_objective_sense
mylevel_obj_function(m::UpperModel) = bilevel_model(m).upper_objective_function

set_mylevel_obj_sense(m::LowerModel, val) = bilevel_model(m).lower_objective_sense = val
set_mylevel_obj_function(m::LowerModel, val) = bilevel_model(m).lower_objective_function = val
set_mylevel_obj_sense(m::UpperModel, val) = bilevel_model(m).upper_objective_sense = val
set_mylevel_obj_function(m::UpperModel, val) = bilevel_model(m).upper_objective_function = val

# UpperToLower / LowerParameter / ParamterInLower
# LowerToUpper / ArgMin
abstract type BridgeBilevelModel <: AbstractBilevelModel end
struct UpperToLowerModel <: BridgeBilevelModel
    m::BilevelModel
end
UpperToLower(m::BilevelModel) = UpperToLowerModel(m)
struct LowerToUpperModel <: BridgeBilevelModel
    m::BilevelModel
end
LowerToUpper(m::BilevelModel) = LowerToUpperModel(m)
bilevel_model(m::BridgeBilevelModel) = m.m

function set_link!(m::UpperToLowerModel, upper::JuMP.AbstractVariableRef, lower::JuMP.AbstractVariableRef)
    bilevel_model(m).upper_to_lower_link[upper] = lower
    bilevel_model(m).link[upper] = lower
    nothing
end
function set_link!(m::LowerToUpperModel, upper::JuMP.AbstractVariableRef, lower::JuMP.AbstractVariableRef)
    bilevel_model(m).lower_to_upper_link[lower] = upper
    bilevel_model(m).link[upper] = lower
    nothing
end

#### Model ####

# Variables
struct BilevelVariableRef <: JuMP.AbstractVariableRef
    model::BilevelModel # `model` owning the variable
    idx::Int       # Index in `model.variables`
    level::Level
end
mylevel(v::BilevelVariableRef) = v.level
function solver_ref(v::BilevelVariableRef)
    m = v.model
    if mylevel(v) == LOWER
        return m.sblm_to_solver[
            m.lower_to_sblm[JuMP.index(m.var_lower[v.idx])]]
    else
        return m.sblm_to_solver[
            m.upper_to_sblm[JuMP.index(m.var_upper[v.idx])]]
    end
end
Base.broadcastable(v::BilevelVariableRef) = Ref(v)
Base.copy(v::BilevelVariableRef) = v
Base.:(==)(v::BilevelVariableRef, w::BilevelVariableRef) =
    v.model === w.model && v.idx == w.idx && v.level == w.level
JuMP.owner_model(v::BilevelVariableRef) = v.model
JuMP.isequal_canonical(v::BilevelVariableRef, w::BilevelVariableRef) = v == w
JuMP.variable_type(::AbstractBilevelModel) = BilevelVariableRef
# add in BOTH levels
function JuMP.add_variable(bb::BridgeBilevelModel, v::JuMP.AbstractVariable, name::String="")
    m = bilevel_model(bb)
    m.nextvaridx += 1
    vref = BilevelVariableRef(m, m.nextvaridx, BOTH)
    v_upper = JuMP.add_variable(m.upper, v, name)
    m.var_upper[vref.idx] = v_upper
    v_lower = JuMP.add_variable(m.lower, v, name)
    m.var_lower[vref.idx] = v_lower
    m.var_level[vref.idx] = BOTH
    set_link!(bb, v_upper, v_lower)
    m.variables[vref.idx] = v
    JuMP.set_name(vref, name)
    vref
end
function JuMP.add_variable(inner::InnerBilevelModel, v::JuMP.AbstractVariable, name::String="")
    m = bilevel_model(inner)
    m.nextvaridx += 1
    vref = BilevelVariableRef(m, m.nextvaridx, level(inner))
    v_level = JuMP.add_variable(mylevel_model(inner), v, name)
    mylevel_var_list(inner)[vref.idx] = v_level
    m.var_level[vref.idx] = level(inner)
    m.variables[vref.idx] = v
    JuMP.set_name(vref, name)
    vref
end
function MOI.delete!(m::AbstractBilevelModel, vref::BilevelVariableRef)
    error("No deletion on bilevel models")
    delete!(m.variables, vref.idx)
    delete!(m.varnames, vref.idx)
end
MOI.is_valid(m::BilevelModel, vref::BilevelVariableRef) = vref.idx in keys(m.variables)
JuMP.num_variables(m::BilevelModel) = length(m.variables)
JuMP.num_variables(m::InnerBilevelModel) = JuMP.num_variables(bilevel_model(m))

# -------------------------
# begin
# Unchanged from StructJuMP
# -------------------------

# Internal function
variable_info(vref::BilevelVariableRef) = vref.model.variables[vref.idx].info
function update_variable_info(vref::BilevelVariableRef, info::JuMP.VariableInfo)
    vref.model.variables[vref.idx] = JuMP.ScalarVariable(info)
end

JuMP.has_lower_bound(vref::BilevelVariableRef) = variable_info(vref).has_lb
function JuMP.lower_bound(vref::BilevelVariableRef)
    @assert !JuMP.is_fixed(vref)
    variable_info(vref).lower_bound
end
function JuMP.set_lower_bound(vref::BilevelVariableRef, lower)
    info = variable_info(vref)
    update_variable_info(vref,
                         JuMP.VariableInfo(true, lower,
                                           info.has_ub, info.upper_bound,
                                           info.has_fix, info.fixed_value,
                                           info.has_start, info.start,
                                           info.binary, info.integer))
end
function JuMP.delete_lower_bound(vref::BilevelVariableRef)
    info = variable_info(vref)
    update_variable_info(vref,
                         JuMP.VariableInfo(false, info.lower_bound,
                                           info.has_ub, info.upper_bound,
                                           info.has_fix, info.fixed_value,
                                           info.has_start, info.start,
                                           info.binary, info.integer))
end
JuMP.has_upper_bound(vref::BilevelVariableRef) = variable_info(vref).has_ub
function JuMP.upper_bound(vref::BilevelVariableRef)
    @assert !JuMP.is_fixed(vref)
    variable_info(vref).upper_bound
end
function JuMP.set_upper_bound(vref::BilevelVariableRef, upper)
    info = variable_info(vref)
    update_variable_info(vref,
                         JuMP.VariableInfo(info.has_lb, info.lower_bound,
                                           true, upper,
                                           info.has_fix, info.fixed_value,
                                           info.has_start, info.start,
                                           info.binary, info.integer))
end
function JuMP.delete_upper_bound(vref::BilevelVariableRef)
    info = variable_info(vref)
    update_variable_info(vref,
                         JuMP.VariableInfo(info.has_lb, info.lower_bound,
                                           false, info.upper_bound,
                                           info.has_fix, info.fixed_value,
                                           info.has_start, info.start,
                                           info.binary, info.integer))
end
JuMP.is_fixed(vref::BilevelVariableRef) = variable_info(vref).has_fix
JuMP.fix_value(vref::BilevelVariableRef) = variable_info(vref).fixed_value
function JuMP.fix(vref::BilevelVariableRef, value)
    info = variable_info(vref)
    update_variable_info(vref,
                         JuMP.VariableInfo(info.has_lb, info.lower_bound,
                                           info.has_ub, info.upper_bound,
                                           true, value,
                                           info.has_start, info.start,
                                           info.binary, info.integer))
end
function JuMP.unfix(vref::BilevelVariableRef)
    info = variable_info(vref)
    update_variable_info(vref,
                         JuMP.VariableInfo(info.has_lb, info.lower_bound,
                                           info.has_ub, info.upper_bound,
                                           false, info.fixed_value,
                                           info.has_start, info.start,
                                           info.binary, info.integer))
end
JuMP.start_value(vref::BilevelVariableRef) = variable_info(vref).start
function JuMP.set_start_value(vref::BilevelVariableRef, start)
    info = variable_info(vref)
    update_variable_info(vref,
                         JuMP.VariableInfo(info.has_lb, info.lower_bound,
                                           info.has_ub, info.upper_bound,
                                           info.has_fix, info.fixed_value,
                                           true, start,
                                           info.binary, info.integer))
end
JuMP.is_binary(vref::BilevelVariableRef) = variable_info(vref).binary
function JuMP.set_binary(vref::BilevelVariableRef)
    @assert !JuMP.is_integer(vref)
    info = variable_info(vref)
    update_variable_info(vref,
                         JuMP.VariableInfo(info.has_lb, info.lower_bound,
                                           info.has_ub, info.upper_bound,
                                           info.has_fix, info.fixed_value,
                                           info.has_start, info.start,
                                           true, info.integer))
end
function JuMP.unset_binary(vref::BilevelVariableRef)
    info = variable_info(vref)
    update_variable_info(vref,
                         JuMP.VariableInfo(info.has_lb, info.lower_bound,
                                           info.has_ub, info.upper_bound,
                                           info.has_fix, info.fixed_value,
                                           info.has_start, info.start,
                                           false, info.integer))
end
JuMP.is_integer(vref::BilevelVariableRef) = variable_info(vref).integer
function JuMP.set_integer(vref::BilevelVariableRef)
    @assert !JuMP.is_binary(vref)
    info = variable_info(vref)
    update_variable_info(vref,
                         JuMP.VariableInfo(info.has_lb, info.lower_bound,
                                           info.has_ub, info.upper_bound,
                                           info.has_fix, info.fixed_value,
                                           info.has_start, info.start,
                                           info.binary, true))
end
function JuMP.unset_integer(vref::BilevelVariableRef)
    info = variable_info(vref)
    update_variable_info(vref,
                         JuMP.VariableInfo(info.has_lb, info.lower_bound,
                                           info.has_ub, info.upper_bound,
                                           info.has_fix, info.fixed_value,
                                           info.has_start, info.start,
                                           info.binary, false))
end

# -------------------------
# end
# Unchanged from StructJuMP
# -------------------------


# Constraints
struct BilevelConstraintRef
    model::BilevelModel # `model` owning the constraint
    idx::Int       # Index in `model.constraints`
end
JuMP.constraint_type(::AbstractBilevelModel) = BilevelConstraintRef
function JuMP.add_constraint(m::BilevelModel, c::JuMP.AbstractConstraint, name::String="")
    error(
        "Can't add constraint directly to the bilevel model `m`, "*
        "attach the constraint to the upper or lower model "*
        "with @constraint(Upper(m), ...) or @constraint(Lower(m), ...)")
end
# function constraint_object(con_ref::ConstraintRef{Model, _MOICON{FuncType, SetType}}) where
#     {FuncType <: MOI.AbstractScalarFunction, SetType <: MOI.AbstractScalarSet}
#     model = con_ref.model
#     f = MOI.get(model, MOI.ConstraintFunction(), con_ref)::FuncType
#     s = MOI.get(model, MOI.ConstraintSet(), con_ref)::SetType
#     return ScalarConstraint(jump_function(model, f), s)
# end
JuMP.add_constraint(m::UpperModel, c::JuMP.VectorConstraint, name::String="") = 
error("no vec ctr")
function JuMP.add_constraint(m::InnerBilevelModel, c::JuMP.ScalarConstraint{F,S}, name::String="") where {F,S}
    blm = bilevel_model(m)
    blm.nextconidx += 1
    cref = BilevelConstraintRef(blm, blm.nextconidx)
    func = JuMP.jump_function(c)
    level_func = replace_variables(func, bilevel_model(m), mylevel_model(m), mylevel_var_list(m))
    level_c = JuMP.build_constraint(error, level_func, c.set)
    level_cref = JuMP.add_constraint(mylevel_model(m), level_c, name)
    blm.ctr_level[cref.idx] = level(m)
    mylevel_ctr_list(m)[cref.idx] = level_cref
    blm.constraints[cref.idx] = c
    JuMP.set_name(cref, name)
    cref
end
function MOI.delete!(m::AbstractBilevelModel, cref::BilevelConstraintRef)
    error("can't delete")
    delete!(m.constraints, cref.idx)
    delete!(m.connames, cref.idx)
end
MOI.is_valid(m::BilevelModel, cref::BilevelConstraintRef) = cref.idx in keys(m.constraints)
MOI.is_valid(m::InnerBilevelModel, cref::BilevelConstraintRef) =
    MOI.is_valid(bilevel_model(m), cref) && bilevel_model(m).ctr_level[cref.idx] == level(m)
function JuMP.constraint_object(cref::BilevelConstraintRef, F::Type, S::Type)
    c = cref.model.constraints[cref.idx]
    # `TypeError` should be thrown is `F` and `S` are not correct
    # This is needed for the tests in `constraints.jl`
    c.func::F
    c.set::S
    c
end

# Objective
function JuMP.set_objective(m::InnerBilevelModel, sense::MOI.OptimizationSense,
                            f::JuMP.AbstractJuMPScalar)
    set_mylevel_obj_sense(m, sense)
    set_mylevel_obj_function(m, f)
    level_f = replace_variables(f, bilevel_model(m), mylevel_model(m), mylevel_var_list(m))
    JuMP.set_objective(mylevel_model(m), sense, level_f)
end
JuMP.objective_sense(m::InnerBilevelModel) = mylevel_obj_sense(m)
JuMP.objective_function_type(m::InnerBilevelModel) = typeof(mylevel_obj_function(m))
JuMP.objective_function(m::InnerBilevelModel) = mylevel_obj_function(m)
function JuMP.objective_function(m::InnerBilevelModel, FT::Type)
    mylevel_obj_function(m) isa FT || error("The objective function is not of type $FT")
    mylevel_obj_function(m)
end

# todo remove
JuMP.objective_sense(m::AbstractBilevelModel) = MOI.FEASIBILITY_SENSE
# end todo remove
JuMP.num_variables(m::AbstractBilevelModel) = JuMP.num_variables(bilevel_model(m))
JuMP.show_constraints_summary(::Any, ::AbstractBilevelModel) = "no summary"
JuMP.show_backend_summary(::Any, ::AbstractBilevelModel) = "no summary"
JuMP.object_dictionary(m::BilevelModel) = m.objdict
JuMP.object_dictionary(m::AbstractBilevelModel) = JuMP.object_dictionary(bilevel_model(m))
JuMP.show_objective_function_summary(::IO, ::AbstractBilevelModel) = "no summary"

bileve_obj_error() = error("There is no objective for BilevelModel use Upper(.) and Lower(.)")

function JuMP.set_objective(m::BilevelModel, sense::MOI.OptimizationSense,
    f::JuMP.AbstractJuMPScalar)
    bileve_obj_error()
end
JuMP.objective_sense(m::BilevelModel) = JuMP.objective_sense(m.upper)#bileve_obj_error()
JuMP.objective_function_type(model::BilevelModel) = bileve_obj_error()
JuMP.objective_function(model::BilevelModel) = bileve_obj_error()
function JuMP.objective_function(model::BilevelModel, FT::Type)
    bileve_obj_error()
end

# Names
JuMP.name(vref::BilevelVariableRef) = vref.model.varnames[vref.idx]
function JuMP.set_name(vref::BilevelVariableRef, name::String)
    vref.model.varnames[vref.idx] = name
end
JuMP.name(cref::BilevelConstraintRef) = cref.model.connames[cref.idx]
function JuMP.set_name(cref::BilevelConstraintRef, name::String)
    cref.model.connames[cref.idx] = name
end


# replace variables
function replace_variables(var::BilevelVariableRef,
    model::BilevelModel, 
    inner::JuMP.AbstractModel,
    variable_map::Dict{Int, V}) where {V<:JuMP.AbstractVariableRef}
    if var.model === model
        return variable_map[var.idx]
    else
        error("A BilevelModel cannot have expression using variables of a BilevelModel different from itself")
    end
end
function replace_variables(aff::JuMP.GenericAffExpr{C, BilevelVariableRef},
    model::BilevelModel,
    inner::JuMP.AbstractModel,
    variable_map::Dict{Int, V}) where {C,V<:JuMP.AbstractVariableRef}
    result = JuMP.GenericAffExpr{C, JuMP.VariableRef}(0.0)#zero(aff)
    result.constant = aff.constant
    for (coef, var) in JuMP.linear_terms(aff)
        JuMP.add_to_expression!(result,
        coef,
        replace_variables(var, model, model, variable_map))
    end
    return result
end
# function replace_variables(quad::JuMP.GenericQuadExpr{C, BilevelVariableRef},
#     model::BilevelModel,
#     inner::JuMP.AbstractModel,
#     variable_map::Dict{Int, V}) where {C,V<:JuMP.AbstractVariableRef}
#     error("A BilevelModel cannot have quadratic function")
# end
function replace_variables(quad::C,
    model::BilevelModel,
    inner::JuMP.AbstractModel,
    variable_map::Dict{Int, V}) where {C,V<:JuMP.AbstractVariableRef}
    error("A BilevelModel cannot have $(C) function")
end
replace_variables(funcs::Vector, args...) = map(f -> replace_variables(f, args...), funcs)
using MathOptFormat
function print_lp(m, name)
    lp_model = MathOptFormat.MOF.Model()
    MOI.copy_to(lp_model, m)
    MOI.write_to_file(lp_model, name)
end

JuMP.optimize!(::T) where {T<:AbstractBilevelModel} = 
    error("cant solve a model of type: $T ")
function JuMP.optimize!(model::BilevelModel, optimizer)

    upper = JuMP.backend(model.upper)
    lower = JuMP.backend(model.lower)

    # print_lp(upper, "upper.lp")
    # print_lp(lower, "lower.lp")

    moi_upper = JuMP.index.(
        collect(values(model.upper_to_lower_link)))
    moi_link = JuMP.index(model.link)

    single_blm, upper_to_sblm, lower_to_sblm = build_bilivel(upper, lower, moi_link, moi_upper)

    solver = MOI.Bridges.full_bridge_optimizer(optimizer, Float64)
    # MOI.empty!(solver)
    # MOI.is_empty(solver)
    sblm_to_solver = MOI.copy_to(solver, single_blm)

    MOI.optimize!(solver)

    # map from bridged to single_blm
    # map from single_blm to upper & lowel
    # map from upper & lower to model
    model.solver  = solver#::MOI.ModelLike
    model.upper_to_sblm = upper_to_sblm
    model.lower_to_sblm = lower_to_sblm
    model.sblm_to_solver = sblm_to_solver

    # feasible = JuMP.primal_status(single_blm)# == MOI.FEASIBLE_POINT
    # termination = JuMP.termination_status(single_blm)# == MOI.OPTIMAL
    # objective_value = NaN
    # if feasible == MOI.FEASIBLE_POINT
    #     objective_value = JuMP.objective_value(single_blm)
    # end
    # variable_value = Dict{JuMP.VariableRef, Float64}()
    return nothing
end

function JuMP.index(d::Dict)
    ret = Dict{VI,VI}()
    # sizehint!(ret, length(d))
    for (k,v) in d
        ret[JuMP.index(k)] = JuMP.index(v)
    end
    return ret
end

function JuMP.value(v::BilevelVariableRef)::Float64
    m = owner_model(v)
    solver = m.solver
    ref = solver_ref(v)
    return MOI.get(solver, MOI.VariablePrimal(), ref)
end
function JuMP.value(v::BilevelConstraintRef)::Float64
    error("value of BilevelConstraintRef not enabled")
end
function JuMP.dual(v::BilevelConstraintRef)::Float64
    error("dual of BilevelConstraintRef not enabled")
end
function JuMP.primal_status(model::BilevelModel)
    return MOI.get(model.solver, MOI.PrimalStatus())
end
JuMP.dual_status(model::BilevelModel) = error("dual status cant be queried for BilevelModel")
function JuMP.termination_status(model::BilevelModel)
    return MOI.get(model.solver, MOI.TerminationStatus())
end
function JuMP.objective_value(model::BilevelModel)
    return MOI.get(model.solver, MOI.ObjectiveValue())
end