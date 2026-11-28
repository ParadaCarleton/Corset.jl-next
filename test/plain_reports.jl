using Supposition: Supposition
using Test: Test

"""
Reduce each Supposition report under `set` to data runner process can deserialize: report holds property function
and stack frames, whose types live only in worker. Pass, fail and error stay; worker output shows counterexamples.
"""
function plain_reports!(set::Test.DefaultTestSet)::Nothing
    for child in set.results
        child isa Test.DefaultTestSet && plain_reports!(child)
        child isa Supposition.SuppositionReport && plain_report!(child)
    end
    return nothing
end

"""Drop test state of `report`, which holds property function, and reduce its result to text."""
function plain_report!(report::Supposition.SuppositionReport)::Nothing
    report.final_state = nothing
    report.result = Some(plain_result(something(report.result)))
    return nothing
end

plain_result(result::Supposition.Pass)::Supposition.Pass = Supposition.Pass(nothing, Pair{AbstractString, Any}[], result.score)
plain_result(result::Supposition.Fail)::Supposition.Fail = Supposition.Fail((; example = repr(result.example)), Pair{AbstractString, Any}[], result.score)
plain_result(result::Supposition.Error)::Supposition.Error =
    Supposition.Error((; example = repr(result.example)), Pair{AbstractString, Any}[], ErrorException(sprint(showerror, result.exception)), nothing)
