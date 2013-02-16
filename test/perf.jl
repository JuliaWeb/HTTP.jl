# Seeing whether it's better to concatenate as you go or build-then-join
# an array.

macro timeit(name, ex)
    quote
        t = Inf
        for i=1:100
            t = min(t, @elapsed $ex)
        end
        println($name, "\t", t*1000)
    end
end

# For checking that both tests are generating the same stuff.
_ref = join([("test" * string(i)) for i = 1:1001], "")

global s = nothing
@timeit "concatenation" begin
  a = "test1"
  for i = 2:1001
    a *= ("test" * string(i))
  end
  global s = a
end
@assert s == _ref

global s = nothing
@timeit "array join" begin
  a = String[]
  for i = 1:1001
   push!(a, ("test" * string(i)))
  end
  global s = join(a, "")
end
@assert s == _ref
