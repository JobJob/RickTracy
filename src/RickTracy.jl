module RickTracy

export TraceItem,
#standard snaps
@snap, @snap_everyN_at, storeNthsnapsat,
#watchall related
@watch, @unwatch, @unwatchall, @snapall,
#reset fns
clearsnaps, @clearsnaps, @clearallsnaps, @resetallsnaps, brandnewsnaps!,
#view/process traces
tracesat, @tracesat, tracevals, @tracevals, traceitems, @traceitems,
tracevalsat, @tracevalsat, @tracevalsdict, allsnaps, @allsnaps,
#utilities
next_global_location, kwargparse,
#module globals
_num_trace_locations, trace_kwargspec, happysnaps


using DataStructures

__init__() = begin
    global _num_trace_locations = 0
    global location_counts = DefaultDict(String, Int, 0) #number of times tracepoint at each location has been hit (but not necessarily logged)
    global watched_exprs = Dict{String, Bool}()
    global happysnaps = Vector{TraceItem}()
    global autowatch = true
end


###############################################################################
# Types
###############################################################################
type TraceItem{T}
    location::String
    exprstr::String
    val::T
    ts::Float64 #time stamp
end
TraceItem{T}(location, exprstr, val::T) = TraceItem{T}(location, exprstr, val, time())

###############################################################################
# Clearance Clarence
###############################################################################

brandnewsnaps!() = begin
    empty!(happysnaps)
    empty!(location_counts)
    empty!(watched_exprs)
    global _num_trace_locations = 0
end

macro resetallsnaps()
    :(brandnewsnaps!()) |> esc
end

macro clearallsnaps()
    :(empty!(happysnaps)) |> esc
end

clearsnaps(exprstr) = begin
    #find snaps that match key, and remove them from the happysnaps vector
    filter!((st)->st.exprstr == exprstr, happysnaps) #slow
end

macro clearsnaps(exprs...)
    res = :()
    for expr in exprs
        exprstr = "$expr" #expr as a string
        res = :($res; clearsnaps(exprstr))
    end
    res |> esc
end

macro clearunwatch(exprs...)
    :(@unwatch exprs; @clearsnaps(exprs)) |> esc
end

###############################################################################
# Trace View/Accessor Functions
###############################################################################
tracesat(location) = filter((ti)->ti.location == "$location", happysnaps)
traceitems(exprstr) = filter((ti)->ti.exprstr == exprstr, happysnaps)
tracevals(exprstr) = pluck(traceitems(exprstr), :val)
tracevalsat(location, exprstr) = begin
    traceitems = filter(happysnaps) do (ti)
        ti.exprstr == exprstr && ti.location == location
    end
    pluck(traceitems, :val)
end
allsnaps() = copy(happysnaps)

macro allsnaps()
    :(allsnaps()) |> esc
end

macro tracesat(location_expr)
    location = string(location_expr)
    :(tracesat($location)) |> esc
end

macro tracevalsat(location_expr, expr)
    location = string(location_expr)
    exprstr = string(expr)
    :(tracevalsat($location, $exprstr)) |> esc
end

macro tracevals(expr)
    exprstr = string(expr)
    :(tracevals($exprstr)) |> esc
end

macro traceitems(expr)
    exprstr = string(expr)
    :(traceitems($exprstr)) |> esc
end

dicout() = begin
    res = DefaultDict(String, Vector{Any}, Vector{Any})
    for si in happysnaps
        push!(res[si.exprstr], si.val)
    end
    res
end

macro tracevalsdict()
    :(RickTracy.dicout())
end

###############################################################################
# Watched Expressions / Snapall
###############################################################################
set_autowatch(on::Bool) = global autowatch = on
get_autowatch() = autowatch

watched_exprstrs() = keys(watched_exprs)

watch_exprstr(exprstr) = begin
    watched_exprs[exprstr] = true
end

unwatch_exprstr(exprstr) = begin
    delete!(watched_exprs, exprstr)
end

macro watch(exprs...)
    for expr in exprs
        watch_exprstr(string(expr)) #called at macro expansion time, not run time
    end
    :()
end

macro unwatch(exprs...)
    for expr in exprs
        unwatch_exprstr(string(expr))
    end
    :()
end

macro unwatchall()
    empty!(watched_exprs)
    :()
end

macro snapall(kwexprs...)
    kwargs, extra_exprs = kwargparse(trace_kwargspec, kwexprs)
    watched_exprs = map(parse, watched_exprstrs())
    exprs = vcat(watched_exprs, extra_exprs)
    :(@snap_everyN_at $(kwargs[:location]) $(kwargs[:everyN]) $exprs) |> esc
end

###############################################################################
# Make regular snaps
###############################################################################
"""
adds a trace entry in happysnaps for each expr in exprstrs with
corresponding val from vals
"""
storeNthsnapsat(location, everyN, exprstrs, vals) = begin
    if location_counts[location]%everyN == 0
        for (exprstr, val) in zip(exprstrs, vals)
            storesnap(location, exprstr, val)
        end
    end
    location_counts[location] += 1
end

storesnap(location, exprstr, val) = push!(happysnaps, TraceItem(location, exprstr, val))

macro snap_everyN_at(location, N, exprs)
    res = :(exprstrs = []; vals=[])
    for expr in exprs
        exprstr = string(expr)
        res = quote
            $res
            push!(exprstrs, $exprstr)
            push!(vals,
                try
                    $expr
                catch e
                    typeof(e) != UndefVarError && throw(e)
                    :undefined
                end)
        end
        autowatch && watch_exprstr(exprstr) #called at macro expansion time, not run time
    end
    res = :($res; storeNthsnapsat(string($location), $N, exprstrs, vals))
    res = :($res; happysnaps)
    res |> esc
end

"""
Take a snap/trace of a variable/expression.
#example

    fred = "flintstone"
    barney = 10

    @snap fred barney
    @tracevals fred

outputs:

    1-element Array{String,1}:
    "flintstone"

By default the variable/expression will be added to the watch list,
and logged/snapped on calls to `@snapall` that are parsed/loaded later than
this call.. To disable this behaviour call RickTracy.set_autowatch(false).

A numbered location string will be added to the trace entry to identify
the code location. To specify your own location use:

    @snap loc="decriptive location name" var1 var2
    #or
    @snapat location=@__LINE__ var1 var2

# n.b. `location`, `loc`, or just plain `l` are valid

    for person in ["wilma", "fred", "betty", "barney"]
        @snap N=2 person
    end
    @tracevals person

    returns:

    2-element Array{String,1}:
     "wilma"
     "betty"

"""
macro snap(exprs...)
    kwargs, exprs = kwargparse(trace_kwargspec, exprs)
    :(@snap_everyN_at $(kwargs[:location]) $(kwargs[:everyN]) $exprs) |> esc
end

###############################################################################
# Helpers
###############################################################################
pluck(objarr, sym) = map((obj)->getfield(obj, sym), objarr)

"""
Create default auto-incremented numbered location for the tracepoint

n.b. File and line number of call site in macro-expansion isn't possible yet
Waiting on https://github.com/JuliaLang/julia/issues/9577
"""
next_global_location() = begin
    global _num_trace_locations
    _num_trace_locations += 1
end

location_spec = Dict(:aliases=>[:location, :loc, :l],
                    :convert=>string, :default=>next_global_location)

throttle_spec = Dict(:aliases=>[:everyN, :every, :N],
                    :convert=>Int, :default=>1)

trace_kwargspec = Dict(:location=>location_spec, :everyN=>throttle_spec)

get_default(spec) = begin
    !haskey(spec, :default) && return nothing
    !isempty(methods(spec[:default])) ?
                        spec[:default]() : spec[:default]
end

"""
Parse keyword args passed to your macro
For each keyword argument you want to handle, provide a argument specification:
    :aliases ::Vector{Symbol} #possible names used for this variable
    :default ::Union{Function, Literal} #(optional) default value for the var if keyword not provided
    :convert ::Function #(optional) - called after arg is parsed to e.g. convert it to a correct type
kwargspec (key word argument specification) is then a Dict from your symbol names => their argument specification as defined aboive
Returns: a Dict{Symbol, Any} with values for all keys in your kwargspec
"""
kwargparse(kwargspec, exprs) = begin
    kwargs = Dict{Symbol, Any}(key => get_default(spec) for (key, spec) in kwargspec)
    args = []
    for expr in exprs
        if typeof(expr) == Expr && expr.head == Symbol("=")
            for (key, spec) in kwargspec
                expr.args[1] in spec[:aliases] && (kwargs[key] = expr.args[2])
            end
        else
            push!(args, expr)
        end
    end
    for (key, spec) in kwargspec
        haskey(spec, :convert) && (kwargs[key] = spec[:convert](kwargs[key]))
    end
    kwargs, args
end

end
