module StaticArrayInterface

using ArrayInterface
import ArrayInterface: allowed_getindex, allowed_setindex!, aos_to_soa, buffer,
                           parent_type, fast_matrix_colors, findstructralnz,
                           has_sparsestruct,
                           issingular, isstructured, matrix_colors, restructure,
                           lu_instance,
                           safevec, zeromatrix, undefmatrix, ColoringAlgorithm,
                           fast_scalar_indexing, parameterless_type,
                           is_forwarding_wrapper,
                           childdims,
                           map_tuple_type, flatten_tuples, GetIndex, SetIndex!,
                           defines_strides,
                           stride_preserving_index

# ArrayIndex subtypes and methods
import ArrayInterface: ArrayIndex, MatrixIndex, VectorIndex, BidiagonalIndex,
                           TridiagonalIndex, StrideIndex
# managing immutables
import ArrayInterface: ismutable, can_change_size, can_setindex
# constants
import ArrayInterface: MatAdjTrans, VecAdjTrans, UpTri, LoTri
# device pieces
import ArrayInterface: AbstractDevice, AbstractCPU, CPUPointer, CPUTuple, CheckParent,
                           CPUIndex, GPU, can_avx, device

using Static
using Static: Zero, One, nstatic, eq, ne, gt, ge, lt, le, eachop, eachop_tuple,
            permute, invariant_permutation, field_type, reduce_tup, find_first_eq,
            OptionallyStaticUnitRange, OptionallyStaticStepRange, OptionallyStaticRange,
            IntType,
            SOneTo, SUnitRange

using IfElse

using Base.Cartesian
using Base: @propagate_inbounds, tail, OneTo, LogicalIndex, Slice, ReinterpretArray,
            ReshapedArray, AbstractCartesianIndex

using Base.Iterators: Pairs
using LinearAlgebra

import Compat

@generated function merge_tuple_type(::Type{X}, ::Type{Y}) where {X <: Tuple, Y <: Tuple}
    Tuple{X.parameters..., Y.parameters...}
end

Base.size(A::AbstractArray2) = map(Int, ArrayInterface.static_size(A))
Base.size(A::AbstractArray2, dim) = Int(ArrayInterface.static_size(A, dim))

function Base.axes(A::AbstractArray2)
    is_forwarding_wrapper(A) && return ArrayInterface.static_axes(parent(A))
    throw(ArgumentError("Subtypes of `AbstractArray2` must define an axes method"))
end
function Base.axes(A::AbstractArray2, dim::Union{Symbol, StaticSymbol})
    static_axes(A, to_dims(A, dim))
end

function Base.strides(A::AbstractArray2)
    defines_strides(A) && return map(Int, ArrayInterface.static_strides(A))
    throw(MethodError(Base.strides, (A,)))
end
Base.strides(A::AbstractArray2, dim) = Int(ArrayInterface.static_strides(A, dim))

function Base.IndexStyle(::Type{T}) where {T <: AbstractArray2}
    is_forwarding_wrapper(T) ? IndexStyle(parent_type(T)) : IndexCartesian()
end

function Base.length(A::AbstractArray2)
    len = known_length(A)
    if len === nothing
        return Int(prod(static_size(A)))
    else
        return Int(len)
    end
end

@propagate_inbounds Base.getindex(A::AbstractArray2, args...) = static_getindex(A, args...)
@propagate_inbounds Base.getindex(A::AbstractArray2; kwargs...) = static_getindex(A; kwargs...)

@propagate_inbounds function Base.setindex!(A::AbstractArray2, val, args...)
    return setindex!(A, val, args...)
end
@propagate_inbounds function Base.setindex!(A::AbstractArray2, val; kwargs...)
    return setindex!(A, val; kwargs...)
end

@inline static_first(x) = Static.maybe_static(known_first, first, x)
@inline static_last(x) = Static.maybe_static(known_last, last, x)
@inline static_step(x) = Static.maybe_static(known_step, step, x)

@inline function _to_cartesian(a, i::IntType)
    @inbounds(CartesianIndices(ntuple(dim -> indices(a, dim), Val(ndims(a))))[i])
end
@inline function _to_linear(a, i::Tuple{IntType, Vararg{IntType}})
    _strides2int(offsets(a), size_to_strides(static_size(a), static(1)), i) + static(1)
end

"""
    has_parent(::Type{T}) -> StaticBool

Returns `static(true)` if `parent_type(T)` a type unique to `T`.
"""
has_parent(x) = has_parent(typeof(x))
has_parent(::Type{T}) where {T} = _has_parent(parent_type(T), T)
_has_parent(::Type{T}, ::Type{T}) where {T} = False()
_has_parent(::Type{T1}, ::Type{T2}) where {T1, T2} = True()

"""
    is_lazy_conjugate(::AbstractArray) -> Bool

Determine if a given array will lazyily take complex conjugates, such as with `Adjoint`. This will work with
nested wrappers, so long as there is no type in the chain of wrappers such that `parent_type(T) == T`

Examples

    julia> a = transpose([1 + im, 1-im]')
    2×1 transpose(adjoint(::Vector{Complex{Int64}})) with eltype Complex{Int64}:
     1 - 1im
     1 + 1im

    julia> ArrayInterface.is_lazy_conjugate(a)
    True()

    julia> b = a'
    1×2 adjoint(transpose(adjoint(::Vector{Complex{Int64}}))) with eltype Complex{Int64}:
     1+1im  1-1im

    julia> ArrayInterface.is_lazy_conjugate(b)
    False()

"""
is_lazy_conjugate(::T) where {T <: AbstractArray} = _is_lazy_conjugate(T, False())
is_lazy_conjugate(::AbstractArray{<:Real}) = False()

function _is_lazy_conjugate(::Type{T}, isconj) where {T <: AbstractArray}
    Tp = parent_type(T)
    if T !== Tp
        _is_lazy_conjugate(Tp, isconj)
    else
        isconj
    end
end

function _is_lazy_conjugate(::Type{T}, isconj) where {T <: Adjoint}
    Tp = parent_type(T)
    if T !== Tp
        _is_lazy_conjugate(Tp, !isconj)
    else
        !isconj
    end
end

"""
    insert(collection, index, item)

Returns a new instance of `collection` with `item` inserted into at the given `index`.
"""
Base.@propagate_inbounds function insert(collection, index, item)
    @boundscheck checkbounds(collection, index)
    ret = similar(collection, static_length(collection) + 1)
    @inbounds for i in firstindex(ret):(index - 1)
        ret[i] = collection[i]
    end
    @inbounds ret[index] = item
    @inbounds for i in (index + 1):lastindex(ret)
        ret[i] = collection[i - 1]
    end
    return ret
end

function insert(x::Tuple{Vararg{Any, N}}, index, item) where {N}
    @boundscheck if !checkindex(Bool, StaticInt{1}():StaticInt{N}(), index)
        throw(BoundsError(x, index))
    end
    return unsafe_insert(x, Int(index), item)
end

@inline function unsafe_insert(x::Tuple, i::Int, item)
    if i === 1
        return (item, x...)
    else
        return (first(x), unsafe_insert(tail(x), i - 1, item)...)
    end
end

"""
    deleteat(collection, index)

Returns a new instance of `collection` with the item at the given `index` removed.
"""
Base.@propagate_inbounds function deleteat(collection::AbstractVector, index)
    @boundscheck if !checkindex(Bool, eachindex(collection), index)
        throw(BoundsError(collection, index))
    end
    return unsafe_deleteat(collection, index)
end
Base.@propagate_inbounds function deleteat(collection::Tuple{Vararg{Any, N}},
                                           index) where {N}
    @boundscheck if !checkindex(Bool, StaticInt{1}():StaticInt{N}(), index)
        throw(BoundsError(collection, index))
    end
    return unsafe_deleteat(collection, index)
end

function unsafe_deleteat(src::AbstractVector, index)
    dst = similar(src, static_length(src) - 1)
    @inbounds for i in indices(dst)
        if i < index
            dst[i] = src[i]
        else
            dst[i] = src[i + 1]
        end
    end
    return dst
end

@inline function unsafe_deleteat(src::AbstractVector, inds::AbstractVector)
    dst = similar(src, static_length(src) - static_length(inds))
    dst_index = firstindex(dst)
    @inbounds for src_index in indices(src)
        if !in(src_index, inds)
            dst[dst_index] = src[src_index]
            dst_index += one(dst_index)
        end
    end
    return dst
end

@inline function unsafe_deleteat(src::Tuple, inds::AbstractVector)
    dst = Vector{eltype(src)}(undef, static_length(src) - static_length(inds))
    dst_index = firstindex(dst)
    @inbounds for src_index in static(1):static_length(src)
        if !in(src_index, inds)
            dst[dst_index] = src[src_index]
            dst_index += one(dst_index)
        end
    end
    return Tuple(dst)
end

@inline unsafe_deleteat(x::Tuple{T}, i) where {T} = ()
@inline unsafe_deleteat(x::Tuple{T1, T2}, i) where {T1, T2} = isone(i) ? (x[2],) : (x[1],)
@inline function unsafe_deleteat(x::Tuple, i)
    if i === one(i)
        return tail(x)
    elseif i == static_length(x)
        return Base.front(x)
    else
        return (first(x), unsafe_deleteat(tail(x), i - one(i))...)
    end
end

include("array_index.jl")
include("ranges.jl")
include("axes.jl")
include("size.jl")
include("dimensions.jl")
include("indexing.jl")
include("stridelayout.jl")
include("broadcast.jl")


## Precompilation

using SnoopPrecompile
@precompile_setup begin
    # Putting some things in `setup` can reduce the size of the
    # precompile file and potentially make loading faster.
    arrays = [rand(4), Base.oneto(5)]
    @precompile_all_calls begin for x in arrays
        known_first(x)
        known_step(x)
        known_last(x)
    end end
end

end