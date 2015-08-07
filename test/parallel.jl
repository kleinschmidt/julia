# This file is a part of Julia. License is MIT: http://julialang.org/license

# NOTE: worker processes cannot add more workers, only the client process can.
using Base.Test

if nworkers() < 3
    remotecall_fetch(1, () -> addprocs(3 - nworkers()))
end

id_me = myid()
id_other = filter(x -> x != id_me, procs())[rand(1:(nprocs()-1))]

@test fetch(@spawnat id_other myid()) == id_other
@test @fetchfrom id_other begin myid() end == id_other
@fetch begin myid() end

rr=RemoteRef()
@test typeof(rr) == RemoteRef{Channel{Any}}
a = rand(5,5)
put!(rr, a)
@test rr[2,3] == a[2,3]
@test rr[] == a

rr=RemoteRef(workers()[1])
@test typeof(rr) == RemoteRef{Channel{Any}}
a = rand(5,5)
put!(rr, a)
@test rr[1,5] == a[1,5]
@test rr[] == a

dims = (20,20,20)

@linux_only begin
    S = SharedArray(Int64, dims)
    @test startswith(S.segname, "/jl")
    @test !ispath("/dev/shm" * S.segname)

    S = SharedArray(Int64, dims; pids=[id_other])
    @test startswith(S.segname, "/jl")
    @test !ispath("/dev/shm" * S.segname)
end

# TODO : Need a similar test of shmem cleanup for OSX

# SharedArray tests
d = Base.shmem_rand(1:100, dims)
a = convert(Array, d)

partsums = Array(Int, length(procs(d)))
@sync begin
    for (i, p) in enumerate(procs(d))
        @async partsums[i] = remotecall_fetch(p, D->sum(D.loc_subarr_1d), d)
    end
end
@test sum(a) == sum(partsums)

d = Base.shmem_rand(dims)
for p in procs(d)
    idxes_in_p = remotecall_fetch(p, D -> parentindexes(D.loc_subarr_1d)[1], d)
    idxf = first(idxes_in_p)
    idxl = last(idxes_in_p)
    d[idxf] = Float64(idxf)
    rv = remotecall_fetch(p, (D,idxf,idxl) -> begin assert(D[idxf] == Float64(idxf)); D[idxl] = Float64(idxl); D[idxl];  end, d,idxf,idxl)
    @test d[idxl] == rv
end

@test ones(10, 10, 10) == Base.shmem_fill(1.0, (10,10,10))
@test zeros(Int32, 10, 10, 10) == Base.shmem_fill(0, (10,10,10))

d = Base.shmem_rand(dims)
s = Base.shmem_rand(dims)
copy!(s, d)
@test s == d
s = Base.shmem_rand(dims)
copy!(s, sdata(d))
@test s == d
a = rand(dims)
@test sdata(a) == a

d = SharedArray(Int, dims; init = D->fill!(D.loc_subarr_1d, myid()))
for p in procs(d)
    idxes_in_p = remotecall_fetch(p, D -> parentindexes(D.loc_subarr_1d)[1], d)
    idxf = first(idxes_in_p)
    idxl = last(idxes_in_p)
    @test d[idxf] == p
    @test d[idxl] == p
end

# reshape

d = Base.shmem_fill(1.0, (10,10,10))
@test ones(100, 10) == reshape(d,(100,10))
d = Base.shmem_fill(1.0, (10,10,10))
@test_throws DimensionMismatch reshape(d,(50,))

# rand, randn
d = Base.shmem_rand(dims)
@test size(rand!(d)) == dims
d = Base.shmem_fill(1.0, dims)
@test size(randn!(d)) == dims

# similar
d = Base.shmem_rand(dims)
@test size(similar(d, Complex128)) == dims
@test size(similar(d, dims)) == dims

# issue #6362
d = Base.shmem_rand(dims)
s = copy(sdata(d))
ds = deepcopy(d)
@test ds == d
pids_ds = procs(ds)
remotecall_fetch(pids_ds[findfirst(id->(id != myid()), pids_ds)], setindex!, ds, 1.0, 1:10)
@test ds != d
@test s == d


# SharedArray as an array
# Since the data in d will depend on the nprocs, just test that these operations work
a = d[1:5]
@test_throws BoundsError d[-1:5]
a = d[1,1,1:3:end]
d[2:4] = 7
d[5,1:2:4,8] = 19

AA = rand(4,2)
A = convert(SharedArray, AA)
B = convert(SharedArray, AA')
@test B*A == ctranspose(AA)*AA

d=SharedArray(Int64, (10,10); init = D->fill!(D.loc_subarr_1d, myid()), pids=[id_me, id_other])
d2 = map(x->1, d)
@test reduce(+, d2) == 100

@test reduce(+, d) == ((50*id_me) + (50*id_other))
map!(x->1, d)
@test reduce(+, d) == 100

@test fill!(d, 1) == ones(10, 10)
@test fill!(d, 2.) == fill(2, 10, 10)
@test d[:] == fill(2, 100)
@test d[:,1] == fill(2, 10)
@test d[1,:] == fill(2, 1, 10)

# Boundary cases where length(S) <= length(pids)
@test 2.0 == remotecall_fetch(id_other, D->D[2], Base.shmem_fill(2.0, 2; pids=[id_me, id_other]))
@test 3.0 == remotecall_fetch(id_other, D->D[1], Base.shmem_fill(3.0, 1; pids=[id_me, id_other]))

# Test @parallel load balancing - all processors should get either M or M+1
# iterations out of the loop range for some M.
workloads = hist(@parallel((a,b)->[a;b], for i=1:7; myid(); end), nprocs())[2]
@test maximum(workloads) - minimum(workloads) <= 1

# @parallel reduction should work even with very short ranges
@test @parallel(+, for i=1:2; i; end) == 3

# Testing timedwait on multiple channels
@sync begin
    rr1 = Channel()
    rr2 = Channel()
    rr3 = Channel()

    @async begin sleep(0.5); put!(rr1, :ok) end
    @async begin sleep(1.0); put!(rr2, :ok) end
    @async begin sleep(2.0); put!(rr3, :ok) end

    tic()
    timedwait(1.0) do
        all(map(isready, [rr1, rr2, rr3]))
    end
    et=toq()
    # assuming that 0.5 seconds is a good enough buffer on a typical modern CPU
    try
        @test (et >= 1.0) && (et <= 1.5)
        @test !isready(rr3)
    catch
        warn("timedwait tests delayed. et=$et, isready(rr3)=$(isready(rr3))")
    end
    @test isready(rr1)
end

@test_throws ArgumentError sleep(-1)
@test_throws ArgumentError timedwait(()->false, 0.1, pollint=-0.5)

# specify pids for pmap
@test sort(workers()[1:2]) == sort(unique(pmap(x->(sleep(0.1);myid()), 1:10, pids = workers()[1:2])))

# Testing buffered  and unbuffered reads
# This large array should write directly to the socket
a = ones(10^6)
@test a == remotecall_fetch(id_other, (x)->x, a)

# Not a bitstype, should be buffered
s = [randstring() for x in 1:10^5]
@test s == remotecall_fetch(id_other, (x)->x, s)

#large number of small requests
num_small_requests = 10000
@test fill(id_other, num_small_requests) == [remotecall_fetch(id_other, myid) for i in 1:num_small_requests]

# test parallel sends of large arrays from multiple tasks to the same remote worker
ntasks = 10
rr_list = [Channel() for x in 1:ntasks]
a=ones(2*10^5);
for rr in rr_list
    @async let rr=rr
        try
            for i in 1:10
                @test a == remotecall_fetch(id_other, (x)->x, a)
                yield()
            end
            put!(rr, :OK)
        catch
            put!(rr, :ERROR)
        end
    end
end

@test [fetch(rr) for rr in rr_list] == [:OK for x in 1:ntasks]

function test_channel(c)
    put!(c, 1)
    put!(c, "Hello")
    put!(c, 5.0)

    @test isready(c) == true
    @test fetch(c) == 1
    @test fetch(c) == 1   # Should not have been popped previously
    @test take!(c) == 1
    @test take!(c) == "Hello"
    @test fetch(c) == 5.0
    @test take!(c) == 5.0
    @test isready(c) == false
    close(c)
end

test_channel(Channel(10))
test_channel(RemoteRef(()->Channel(10)))

c=Channel{Int}(1)
@test_throws MethodError put!(c, "Hello")

c=Channel(256)
# Test growth of channel
@test c.szp1 <= 33
for x in 1:40
  put!(c, x)
end
@test c.szp1 <= 65
for x in 1:39
  take!(c)
end
for x in 1:64
  put!(c, x)
end
@test (c.szp1 > 65) && (c.szp1 <= 129)
for x in 1:39
  take!(c)
end
@test fetch(c) == 39
for x in 1:26
  take!(c)
end
@test isready(c) == false

# test channel iterations
function test_iteration(in_c, out_c)
    t=@schedule for v in in_c
        put!(out_c, v)
    end

    isa(in_c, Channel) && @test isopen(in_c) == true
    put!(in_c, 1)
    @test take!(out_c) == 1
    put!(in_c, "Hello")
    close(in_c)
    @test take!(out_c) == "Hello"
    isa(in_c, Channel) && @test isopen(in_c) == false
    @test_throws InvalidStateException put!(in_c, :foo)
    yield()
    @test istaskdone(t) == true
end

test_iteration(Channel(10), Channel(10))
# make sure exceptions propagate when waiting on Tasks
@test_throws CompositeException (@sync (@async error("oops")))
try
    @sync begin
        for i in 1:5
            @async error(i)
        end
    end
catch ex
    @test typeof(ex) == CompositeException
    @test length(ex) == 5
    @test typeof(ex.exceptions[1]) == CapturedException
    @test typeof(ex.exceptions[1].ex) == ErrorException
    errors = map(x->x.ex.msg, ex.exceptions)
    @test collect(1:5) == sort(map(x->parse(Int, x), errors))
end

try
    remotecall_fetch(id_other, ()->throw(ErrorException("foobar")))
catch ex
    @test typeof(ex) == RemoteException
    @test typeof(ex.captured) == CapturedException
    @test typeof(ex.captured.ex) == ErrorException
    @test ex.captured.ex.msg == "foobar"
end

# The below block of tests are usually run only on local development systems, since:
# - tests which print errors
# - addprocs tests are memory intensive
# - ssh addprocs requires sshd to be running locally with passwordless login enabled.
# The test block is enabled by defining env JULIA_TESTFULL=1

DoFullTest = Bool(parse(Int,(get(ENV, "JULIA_TESTFULL", "0"))))

if DoFullTest
    # pmap tests
    # needs at least 4 processors dedicated to the below tests
    ppids = remotecall_fetch(1, ()->addprocs(4))
    s = "abcdefghijklmnopqrstuvwxyz";
    ups = uppercase(s);
    @test ups == bytestring(UInt8[UInt8(c) for c in pmap(x->uppercase(x), s)])
    @test ups == bytestring(UInt8[UInt8(c) for c in pmap(x->uppercase(Char(x)), s.data)])

    # retry, on error exit
    res = pmap(x->(x=='a') ? error("EXPECTED TEST ERROR. TO BE IGNORED.") : (sleep(0.1);uppercase(x)), s; err_retry=true, err_stop=true, pids=ppids);
    @test (length(res) < length(ups))
    @test isa(res[1], Exception)

    # no retry, on error exit
    res = pmap(x->(x=='a') ? error("EXPECTED TEST ERROR. TO BE IGNORED.") : (sleep(0.1);uppercase(x)), s; err_retry=false, err_stop=true, pids=ppids);
    @test (length(res) < length(ups))
    @test isa(res[1], Exception)

    # retry, on error continue
    res = pmap(x->iseven(myid()) ? error("EXPECTED TEST ERROR. TO BE IGNORED.") : (sleep(0.1);uppercase(x)), s; err_retry=true, err_stop=false, pids=ppids);
    @test length(res) == length(ups)
    @test ups == bytestring(UInt8[UInt8(c) for c in res])

    # no retry, on error continue
    res = pmap(x->(x=='a') ? error("EXPECTED TEST ERROR. TO BE IGNORED.") : (sleep(0.1);uppercase(x)), s; err_retry=false, err_stop=false, pids=ppids);
    @test length(res) == length(ups)
    @test isa(res[1], Exception)

    # Topology tests need to run externally since a given cluster at any
    # time can only support a single topology and the current session
    # is already running in parallel under the default topology.
    script = joinpath(dirname(@__FILE__), "topology.jl")
    cmd = `$(joinpath(JULIA_HOME,Base.julia_exename())) $script`

    (strm, proc) = open(cmd)
    wait(proc)
    if !success(proc) && ccall(:jl_running_on_valgrind,Cint,()) == 0
        println(readall(strm))
        error("Topology tests failed : $cmd")
    end

    println("Testing exception printing on remote worker from a `remote_do` call")
    println("Please ensure the remote error and backtrace is displayed on screen")

    Base.remote_do(id_other, ()->throw(ErrorException("TESTING EXCEPTION ON REMOTE DO. PLEASE IGNORE")))
    sleep(0.5)  # Give some time for the above error to be printed

@unix_only begin
    function test_n_remove_pids(new_pids)
        for p in new_pids
            w_in_remote = sort(remotecall_fetch(p, workers))
            try
                @test intersect(new_pids, w_in_remote) == new_pids
            catch e
                print("p       :     $p\n")
                print("newpids :     $new_pids\n")
                print("w_in_remote : $w_in_remote\n")
                print("intersect   : $(intersect(new_pids, w_in_remote))\n\n\n")
                rethrow(e)
            end
        end

        @test :ok == remotecall_fetch(1, (p)->rmprocs(p; waitfor=5.0), new_pids)
    end

    print("\n\nTesting SSHManager. A minimum of 4GB of RAM is recommended.\n")
    print("Please ensure sshd is running locally with passwordless login enabled.\n")

    sshflags = `-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR `
    #Issue #9951
    hosts=[]
    localhost_aliases = ["localhost", string(getipaddr()), "127.0.0.1"]
    num_workers = parse(Int,(get(ENV, "JULIA_ADDPROCS_NUM", "9")))

    for i in 1:(num_workers/length(localhost_aliases))
        append!(hosts, localhost_aliases)
    end

    print("\nTesting SSH addprocs with $(length(hosts)) workers...\n")
    new_pids = remotecall_fetch(1, (h, sf) -> addprocs(h; sshflags=sf), hosts, sshflags)
    @test length(new_pids) == length(hosts)
    test_n_remove_pids(new_pids)

    print("\nMixed ssh addprocs with :auto\n")
    new_pids = sort(remotecall_fetch(1, (h, sf) -> addprocs(h; sshflags=sf), ["localhost", ("127.0.0.1", :auto), "localhost"], sshflags))
    @test length(new_pids) == (2 + Sys.CPU_CORES)
    test_n_remove_pids(new_pids)

    print("\nMixed ssh addprocs with numeric counts\n")
    new_pids = sort(remotecall_fetch(1, (h, sf) -> addprocs(h; sshflags=sf), [("localhost", 2), ("127.0.0.1", 2), "localhost"], sshflags))
    @test length(new_pids) == 5
    test_n_remove_pids(new_pids)

    print("\nssh addprocs with tunnel\n")
    new_pids = sort(remotecall_fetch(1, (h, sf) -> addprocs(h; tunnel=true, sshflags=sf), [("localhost", num_workers)], sshflags))
    @test length(new_pids) == num_workers
    test_n_remove_pids(new_pids)

end
end

# issue #7727
let A = [], B = []
    t = @task produce(11)
    @sync begin
        @async for x in t; push!(A,x); end
        @async for x in t; push!(B,x); end
    end
    @test (A == [11]) != (B == [11])
end
