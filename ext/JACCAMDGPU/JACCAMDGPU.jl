module JACCAMDGPU

using JACC, AMDGPU

# overloaded array functions
include("array.jl")

include("JACCMULTI.jl")
using .multi

# overloaded experimental functions
include("JACCEXPERIMENTAL.jl")
using .experimental

function JACC.parallel_for(N::I, f::F, x...) where {I <: Integer, F <: Function}
    numThreads = 512
    # shmem_size = attribute(device(),CUDA.DEVICE_ATTRIBUTE_MAX_SHARED_MEMORY_PER_BLOCK)
    # We must know how to get the max
    
    threads = min(N, numThreads)
    blocks = ceil(Int, N / threads) # shared memory to be used in AMDGPU as it is done in CUDA
    # threads = 128
    # blocks = 256
    # println("Threads: ", threads, " Blocks: ", blocks, " N: ", N)
    
    
    shmem_size = 2 * threads * sizeof(Float64)
    @roc groupsize = threads gridsize = blocks shmem = shmem_size _parallel_for_amdgpu(N,f, x...)
    AMDGPU.synchronize()
end

function JACC.parallel_for(
        (M, N)::Tuple{I, I}, f::F, x...) where {I <: Integer, F <: Function}
    numThreads = 16
    Mthreads = min(M, numThreads)
    Nthreads = min(N, numThreads)
    Mblocks = ceil(Int, M / Mthreads)
    Nblocks = ceil(Int, N / Nthreads)
    # shmem_size = attribute(device(),CUDA.DEVICE_ATTRIBUTE_MAX_SHARED_MEMORY_PER_BLOCK)
    # We must know how to get the max shared memory to be used in AMDGPU as it is done in CUDA
    shmem_size = 2 * Mthreads * Nthreads * sizeof(Float64)
    @roc groupsize = (Mthreads, Nthreads) gridsize = (Mblocks, Nblocks) shmem = shmem_size _parallel_for_amdgpu_MN(f, x...)
    AMDGPU.synchronize()
end

function JACC.parallel_for(
        (L, M, N)::Tuple{I, I, I}, f::F, x...) where {
        I <: Integer, F <: Function}
    numThreads = 32
    Lthreads = min(L, numThreads)
    Mthreads = min(M, numThreads)
    Nthreads = 1
    Lblocks = ceil(Int, L / Lthreads)
    Mblocks = ceil(Int, M / Mthreads)
    Nblocks = ceil(Int, N / Nthreads)
    # shmem_size = attribute(device(),CUDA.DEVICE_ATTRIBUTE_MAX_SHARED_MEMORY_PER_BLOCK)
    # We must know how to get the max shared memory to be used in AMDGPU as it is done in CUDA
    shmem_size = 2 * Lthreads * Mthreads * Nthreads * sizeof(Float64)
    @roc groupsize = (Lthreads, Mthreads, Nthreads) gridsize = (Lblocks, Mblocks, Nblocks) shmem = shmem_size _parallel_for_amdgpu_LMN(f, x...)
    AMDGPU.synchronize()
end

function JACC.parallel_reduce(
        N::I, f::F, x...) where {I <: Integer, F <: Function}
    numThreads = 512
    threads = min(N, numThreads)
    blocks = ceil(Int, N / threads)
    ret = AMDGPU.zeros(Float64, blocks)
    rret = AMDGPU.zeros(Float64, 1)
    @roc groupsize=threads gridsize=blocks _parallel_reduce_amdgpu(
        N, ret, f, x...)
    AMDGPU.synchronize()
    @roc groupsize=threads gridsize=1 reduce_kernel_amdgpu(
        blocks, ret, rret)
    AMDGPU.synchronize()
    return rret
end

function JACC.parallel_reduce(
        (M, N)::Tuple{I, I}, f::F, x...) where {I <: Integer, F <: Function}
    numThreads = 16
    Mthreads = min(M, numThreads)
    Nthreads = min(N, numThreads)
    Mblocks = ceil(Int, M / Mthreads)
    Nblocks = ceil(Int, N / Nthreads)
    ret = AMDGPU.zeros(Float64, (Mblocks, Nblocks))
    rret = AMDGPU.zeros(Float64, 1)
    @roc groupsize=(Mthreads, Nthreads) gridsize=(Mblocks, Nblocks) _parallel_reduce_amdgpu_MN(
        (M, N), ret, f, x...)
    AMDGPU.synchronize()
    @roc groupsize=(Mthreads, Nthreads) gridsize=(1, 1) reduce_kernel_amdgpu_MN(
        (Mblocks, Nblocks), ret, rret)
    AMDGPU.synchronize()
    return rret
end

function _parallel_for_amdgpu(N, f, x...)
    i = (workgroupIdx().x - 1) * workgroupDim().x + workitemIdx().x
    idx = workitemIdx().x + (workgroupIdx().x - 1) * workgroupDim().x
    total_workgroups = workgroupDim().x * workgroupDim().y * workgroupDim().z
    stride = total_workgroups * workgroupDim().x
    if idx <= N
        @inline f(i, x...)
        idx += stride
    end
    # while idx <= N
    #     @inline f(idx, x...)
    #     idx += stride
    # end
    return nothing
end

function _parallel_for_amdgpu_MN(f, x...)
    i = (workgroupIdx().x - 1) * workgroupDim().x + workitemIdx().x
    j = (workgroupIdx().y - 1) * workgroupDim().y + workitemIdx().y
    f(i, j, x...)
    return nothing
end

function _parallel_for_amdgpu_LMN(f, x...)
    i = (workgroupIdx().x - 1) * workgroupDim().x + workitemIdx().x
    j = (workgroupIdx().y - 1) * workgroupDim().y + workitemIdx().y
    k = (workgroupIdx().z - 1) * workgroupDim().z + workitemIdx().z
    f(i, j, k, x...)
    return nothing
end

function _parallel_reduce_amdgpu(N, ret, f, x...)
    shared_mem = @ROCStaticLocalArray(Float64, 512)
    i = (workgroupIdx().x - 1) * workgroupDim().x + workitemIdx().x
    ti = workitemIdx().x
    tmp::Float64 = 0.0
    shared_mem[ti] = 0.0

    if i <= N
        tmp = @inbounds f(i, x...)
        shared_mem[ti] = tmp
    end
    AMDGPU.sync_workgroup()
    if (ti <= 256)
        shared_mem[ti] += shared_mem[ti + 256]
    end
    AMDGPU.sync_workgroup()
    if (ti <= 128)
        shared_mem[ti] += shared_mem[ti + 128]
    end
    AMDGPU.sync_workgroup()
    if (ti <= 64)
        shared_mem[ti] += shared_mem[ti + 64]
    end
    AMDGPU.sync_workgroup()
    if (ti <= 32)
        shared_mem[ti] += shared_mem[ti + 32]
    end
    AMDGPU.sync_workgroup()
    if (ti <= 16)
        shared_mem[ti] += shared_mem[ti + 16]
    end
    AMDGPU.sync_workgroup()
    if (ti <= 8)
        shared_mem[ti] += shared_mem[ti + 8]
    end
    AMDGPU.sync_workgroup()
    if (ti <= 4)
        shared_mem[ti] += shared_mem[ti + 4]
    end
    AMDGPU.sync_workgroup()
    if (ti <= 2)
        shared_mem[ti] += shared_mem[ti + 2]
    end
    AMDGPU.sync_workgroup()
    if (ti == 1)
        shared_mem[ti] += shared_mem[ti + 1]
        ret[workgroupIdx().x] = shared_mem[ti]
    end
    AMDGPU.sync_workgroup()
    return nothing
end

function reduce_kernel_amdgpu(N, red, ret)
    shared_mem = @ROCStaticLocalArray(Float64, 512)
    i = workitemIdx().x
    ii = i
    tmp::Float64 = 0.0
    if N > 512
        while ii <= N
            tmp += @inbounds red[ii]
            ii += 512
        end
    elseif (i <= N)
        tmp = @inbounds red[i]
    end
    shared_mem[i] = tmp
    AMDGPU.sync_workgroup()
    if (i <= 256)
        shared_mem[i] += shared_mem[i + 256]
    end
    AMDGPU.sync_workgroup()
    if (i <= 128)
        shared_mem[i] += shared_mem[i + 128]
    end
    AMDGPU.sync_workgroup()
    if (i <= 64)
        shared_mem[i] += shared_mem[i + 64]
    end
    AMDGPU.sync_workgroup()
    if (i <= 32)
        shared_mem[i] += shared_mem[i + 32]
    end
    AMDGPU.sync_workgroup()
    if (i <= 16)
        shared_mem[i] += shared_mem[i + 16]
    end
    AMDGPU.sync_workgroup()
    if (i <= 8)
        shared_mem[i] += shared_mem[i + 8]
    end
    AMDGPU.sync_workgroup()
    if (i <= 4)
        shared_mem[i] += shared_mem[i + 4]
    end
    AMDGPU.sync_workgroup()
    if (i <= 2)
        shared_mem[i] += shared_mem[i + 2]
    end
    AMDGPU.sync_workgroup()
    if (i == 1)
        shared_mem[i] += shared_mem[i + 1]
        ret[1] = shared_mem[1]
    end
    return nothing
end

function _parallel_reduce_amdgpu_MN((M, N), ret, f, x...)
    shared_mem = @ROCStaticLocalArray(Float64, 256)
    i = (workgroupIdx().x - 1) * workgroupDim().x + workitemIdx().x
    j = (workgroupIdx().y - 1) * workgroupDim().y + workitemIdx().y
    ti = workitemIdx().x
    tj = workitemIdx().y
    bi = workgroupIdx().x
    bj = workgroupIdx().y

    tmp::Float64 = 0.0
    shared_mem[((ti - 1) * 16) + tj] = tmp

    if (i <= M && j <= N)
        tmp = @inbounds f(i, j, x...)
        shared_mem[(ti - 1) * 16 + tj] = tmp
    end
    AMDGPU.sync_workgroup()
    if (ti <= 8 && tj <= 8 && ti + 8 <= M && tj + 8 <= N)
        shared_mem[((ti - 1) * 16) + tj] += shared_mem[((ti + 7) * 16) + (tj + 8)]
        shared_mem[((ti - 1) * 16) + tj] += shared_mem[((ti - 1) * 16) + (tj + 8)]
        shared_mem[((ti - 1) * 16) + tj] += shared_mem[((ti + 7) * 16) + tj]
    end
    AMDGPU.sync_workgroup()
    if (ti <= 4 && tj <= 4 && ti + 4 <= M && tj + 4 <= N)
        shared_mem[((ti - 1) * 16) + tj] += shared_mem[((ti + 3) * 16) + (tj + 4)]
        shared_mem[((ti - 1) * 16) + tj] += shared_mem[((ti - 1) * 16) + (tj + 4)]
        shared_mem[((ti - 1) * 16) + tj] += shared_mem[((ti + 3) * 16) + tj]
    end
    AMDGPU.sync_workgroup()
    if (ti <= 2 && tj <= 2 && ti + 2 <= M && tj + 2 <= N)
        shared_mem[((ti - 1) * 16) + tj] += shared_mem[((ti + 1) * 16) + (tj + 2)]
        shared_mem[((ti - 1) * 16) + tj] += shared_mem[((ti - 1) * 16) + (tj + 2)]
        shared_mem[((ti - 1) * 16) + tj] += shared_mem[((ti + 1) * 16) + tj]
    end
    AMDGPU.sync_workgroup()
    if (ti == 1 && tj == 1 && ti + 1 <= M && tj + 1 <= N)
        shared_mem[((ti - 1) * 16) + tj] += shared_mem[ti * 16 + (tj + 1)]
        shared_mem[((ti - 1) * 16) + tj] += shared_mem[((ti - 1) * 16) + (tj + 1)]
        shared_mem[((ti - 1) * 16) + tj] += shared_mem[ti * 16 + tj]
        ret[bi, bj] = shared_mem[((ti - 1) * 16) + tj]
    end
    return nothing
end

function reduce_kernel_amdgpu_MN((M, N), red, ret)
    shared_mem = @ROCStaticLocalArray(Float64, 256)
    i = workitemIdx().x
    j = workitemIdx().y
    ii = i
    jj = j

    tmp::Float64 = 0.0
    shared_mem[(i - 1) * 16 + j] = tmp

    if M > 16 && N > 16
        while ii <= M
            jj = workitemIdx().y
            while jj <= N
                tmp = tmp + @inbounds red[ii, jj]
                jj += 16
            end
            ii += 16
        end
    elseif M > 16
        while ii <= N
            tmp = tmp + @inbounds red[ii, jj]
            ii += 16
        end
    elseif N > 16
        while jj <= N
            tmp = tmp + @inbounds red[ii, jj]
            jj += 16
        end
    elseif M <= 16 && N <= 16
        if i <= M && j <= N
            tmp = tmp + @inbounds red[i, j]
        end
    end
    shared_mem[(i - 1) * 16 + j] = tmp
    AMDGPU.sync_workgroup()
    if (i <= 8 && j <= 8)
        if (i + 8 <= M && j + 8 <= N)
            shared_mem[((i - 1) * 16) + j] += shared_mem[((i + 7) * 16) + (j + 8)]
        end
        if (i <= M && j + 8 <= N)
            shared_mem[((i - 1) * 16) + j] += shared_mem[((i - 1) * 16) + (j + 8)]
        end
        if (i + 8 <= M && j <= N)
            shared_mem[((i - 1) * 16) + j] += shared_mem[((i + 7) * 16) + j]
        end
    end
    AMDGPU.sync_workgroup()
    if (i <= 4 && j <= 4)
        if (i + 4 <= M && j + 4 <= N)
            shared_mem[((i - 1) * 16) + j] += shared_mem[((i + 3) * 16) + (j + 4)]
        end
        if (i <= M && j + 4 <= N)
            shared_mem[((i - 1) * 16) + j] += shared_mem[((i - 1) * 16) + (j + 4)]
        end
        if (i + 4 <= M && j <= N)
            shared_mem[((i - 1) * 16) + j] += shared_mem[((i + 3) * 16) + j]
        end
    end
    AMDGPU.sync_workgroup()
    if (i <= 2 && j <= 2)
        if (i + 2 <= M && j + 2 <= N)
            shared_mem[((i - 1) * 16) + j] += shared_mem[((i + 1) * 16) + (j + 2)]
        end
        if (i <= M && j + 2 <= N)
            shared_mem[((i - 1) * 16) + j] += shared_mem[((i - 1) * 16) + (j + 2)]
        end
        if (i + 2 <= M && j <= N)
            shared_mem[((i - 1) * 16) + j] += shared_mem[((i + 1) * 16) + j]
        end
    end
    AMDGPU.sync_workgroup()
    if (i == 1 && j == 1)
        if (i + 1 <= M && j + 1 <= N)
            shared_mem[((i - 1) * 16) + j] += shared_mem[i * 16 + (j + 1)]
        end
        if (i <= M && j + 1 <= N)
            shared_mem[((i - 1) * 16) + j] += shared_mem[((i - 1) * 16) + (j + 1)]
        end
        if (i + 1 <= M && j <= N)
            shared_mem[((i - 1) * 16) + j] += shared_mem[i * 16 + j]
        end
        ret[1] = shared_mem[((i - 1) * 16) + j]
    end
    return nothing
end

function JACC.shared(x::ROCDeviceArray{T,N}) where {T,N}
  size = length(x)
  shmem = @ROCDynamicLocalArray(T, size)
  num_threads = workgroupDim().x * workgroupDim().y
  if (size <= num_threads)
    if workgroupDim().y == 1
      ind = workitemIdx().x
      @inbounds shmem[ind] = x[ind]
    else
      i_local = workitemIdx().x
      j_local = workitemIdx().y
      ind = (i_local - 1) * workgroupDim().x + j_local
      if ndims(x) == 1
        @inbounds shmem[ind] = x[ind]
      elseif ndims(x) == 2
        @inbounds shmem[ind] = x[i_local,j_local]
      end
    end
  else
    if workgroupDim().y == 1
      ind = workgroupIdx().x
     for i in workgroupDim().x:workgroupDim().x:size
       @inbounds shmem[ind] = x[ind]
       ind += workgroupDim().x
      end
    else
      i_local = workgroupIdx().x
      j_local = workgroupIdx().y
      ind = (i_local - 1) * workgroupDim().x + j_local
      if ndims(x) == 1
        for i in num_threads:num_threads:size
          @inbounds shmem[ind] = x[ind]
          ind += num_threads
        end
      elseif ndims(x) == 2
        for i in num_threads:num_threads:size
          @inbounds shmem[ind] = x[i_local,j_local]
          ind += num_threads
        end
      end  
    end
  end
  AMDGPU.sync_workgroup()
  return shmem
end


function __init__()
    const JACC.Array = AMDGPU.ROCArray{T, N} where {T, N}
end

end # module JACCAMDGPU
