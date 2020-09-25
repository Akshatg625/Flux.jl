"""
    _handle_batchin(isize, dimsize)

Gracefully handle ignoring batch dimension by padding `isize` with a 1 if necessary.
Also returns a boolean indicating if the batch dimension was padded.

# Arguments:
- `isize`: the input size as specified by the user
- `dimsize`: the expected number of dimensions for this layer (including batch)
"""
function _handle_batchin(isize, dimsize)
  indims = length(isize)
  @assert indims == dimsize || indims == dimsize - 1
    "outdims expects ndims(isize) == $dimsize (got isize = $isize). isize should be the size of the input to the function (with batch size optionally left off)"
  
  return (indims == dimsize) ? (isize, false) : ((isize..., 1), true)
end

"""
    _handle_batchout(outsize, ispadded; preserve_batch = false)

Drop the batch dimension if requested.

# Arguments:
- `outsize`: the output size from a function
- `ispadded`: indicates whether the batch dimension in `outsize` is padded (see _handle_batchin)
- `preserve_batch`: set to `true` to always retain the batch dimension
"""
_handle_batchout(outsize, ispadded; preserve_batch = false) =
  (ispadded && !preserve_batch) ? outsize[1:(end - 1)] : outsize

# fallback for arbitrary functions/layers
# ideally, users should only rely on this for flatten, etc. inside Chains
"""
    outdims(f, isize...)

Calculates the output dimensions of `f(x)` where `size(x) == isize`.
The batch dimension **must** be included.
*Warning: this may be slow depending on `f`*
"""
outdims(f, isize...; preserve_batch = false) = size(f([ones(Float32, s) for s in isize]...))

### start basic ###
"""
    outdims(c::Chain, isize)
    outdims(layers::AbstractVector, isize)

Calculate the output dimensions given the input dimensions, `isize`.

```julia
m = Chain(Conv((3, 3), 3 => 16), Conv((3, 3), 16 => 32))
outdims(m, (10, 10)) == (6, 6)
```
"""
function outdims(layers::T, isize; preserve_batch = false) where T<:Union{Tuple, AbstractVector}
  # if the first layer has different output with
  # preserve_batch = true vs preserve_batch = false
  # then the batch dimension is not included by the user
  initsize = outdims(first(layers), isize; preserve_batch = true)
  hasbatch = (outdims(first(layers), isize) == initsize)
  outsize = foldl((isize, layer) -> outdims(layer, isize; preserve_batch = true),
                  tail(layers); init = initsize)
  
  return hasbatch ? outsize : outsize[1:(end - 1)]
end
outdims(c::Chain, isize; preserve_batch = false) =
  outdims(c.layers, isize; preserve_batch = preserve_batch)

"""
outdims(l::Dense, isize; preserve_batch = false)

Calculate the output dimensions given the input dimensions, `isize`.
Set `preserve_batch` to `true` to always return with the batch dimension included.

```julia
m = Dense(10, 5)
outdims(m, (10,)) == (5,)
outdims(m, (10, 2)) == (5, 2)
```
"""
function outdims(l::Dense, isize; preserve_batch = false)
  first(isize) == size(l.W, 2) ||
    throw(DimensionMismatch("input size should equal ($(size(l.W, 2)), nbatches), got $isize"))

  isize, ispadded = _handle_batchin(isize, 2)
  return _handle_batchout((size(l.W, 1), Base.tail(isize)...), ispadded; preserve_batch = preserve_batch)
end

function outdims(l::Diagonal, isize; preserve_batch = false)
  first(isize) == length(l.α) ||
    throw(DimensionMismatch("input length should equal $(length(l.α)), got $(first(isize))"))

  isize, ispadded = _handle_batchin(isize, 2)
  return _handle_batchout((length(l.α), Base.tail(isize)...), ispadded; preserve_batch = preserve_batch)
end

outdims(l::Maxout, isize; preserve_batch = false) = outdims(first(l.over), isize; preserve_batch = preserve_batch)

function outdims(l::SkipConnection, isize; preserve_batch = false)
  branch_outsize = outdims(l.layers, isize; preserve_batch = preserve_batch)

  return outdims(l.connection, branch_outsize, isize; preserve_batch = preserve_batch)
end

#### end basic ####

#### start conv ####

_convtransoutdims(isize, ksize, ssize, dsize, pad) =
  (isize .- 1) .* ssize .+ 1 .+ (ksize .- 1) .* dsize .- (pad[1:2:end] .+ pad[2:2:end])

"""
    outdims(l::Conv, isize; preserve_batch = false)

Calculate the output dimensions given the input dimensions `isize`.
Set `preserve_batch` to `true` to always return with the batch dimension included.

```julia
m = Conv((3, 3), 3 => 16)
outdims(m, (10, 10)) == (8, 8)
outdims(m, (10, 10, 1, 3)) == (8, 8)
```
"""
function outdims(l::Conv, isize; preserve_batch = false)
  isize, ispadded = _handle_batchin(isize, ndims(l.weight))
  cdims = DenseConvDims(isize, size(l.weight);
                        stride = l.stride, padding = l.pad, dilation = l.dilation)
  
  return _handle_batchout((output_size(cdims)..., NNlib.channels_out(cdims), isize[end]), ispadded;
                          preserve_batch = preserve_batch)
end

function outdims(l::ConvTranspose{N}, isize; preserve_batch = false) where N
  isize, ispadded = _handle_batchin(isize, 4)
  cdims = _convtransoutdims(isize[1:(end - 2)], size(l.weight)[1:N], l.stride, l.dilation, l.pad)
  
  return _handle_batchout((cdims..., size(l.weight)[end - 1], isize[end]), ispadded;
                          preserve_batch = preserve_batch)
end

function outdims(l::DepthwiseConv, isize; preserve_batch = false)
  isize, ispadded = _handle_batchin(isize, 4)
  cdims = DepthwiseConvDims(isize, size(l.weight);
                            stride = l.stride, padding = l.pad, dilation = l.dilation)
  
  return _handle_batchout((output_size(cdims)..., NNlib.channels_out(cdims), isize[end]), ispadded;
                          preserve_batch = preserve_batch)
end

function outdims(l::CrossCor, isize; preserve_batch = false)
  isize, ispadded = _handle_batchin(isize, 4)
  cdims = DenseConvDims(isize, size(l.weight);
                        stride = l.stride, padding = l.pad, dilation = l.dilation)
  
  return _handle_batchout((output_size(cdims)..., NNlib.channels_out(cdims), isize[end]), ispadded;
                          preserve_batch = preserve_batch)
end

function outdims(l::MaxPool{N}, isize; preserve_batch = false) where N
  isize, ispadded = _handle_batchin(isize, 4)
  pdims = PoolDims(isize, l.k; stride = l.stride, padding = l.pad)
  
  return _handle_batchout((output_size(pdims)..., NNlib.channels_out(pdims), isize[end]), ispadded;
                          preserve_batch = preserve_batch)
end

function outdims(l::MeanPool{N}, isize; preserve_batch = false) where N
  isize, ispadded = _handle_batchin(isize, 4)
  pdims = PoolDims(isize, l.k; stride = l.stride, padding = l.pad)

  return _handle_batchout((output_size(pdims)..., NNlib.channels_out(pdims), isize[end]), ispadded;
                          preserve_batch = preserve_batch)
end

function outdims(l::AdaptiveMaxPool, isize; preserve_batch = false)
  isize, ispadded = _handle_batchin(isize, 4)

  return _handle_batchout((l.out..., isize[end - 1], isize[end]), ispadded; preserve_batch = preserve_batch)
end

function outdims(l::AdaptiveMeanPool, isize; preserve_batch = false)
  isize, ispadded = _handle_batchin(isize, 4)

  return _handle_batchout((l.out..., isize[end - 1], isize[end]), ispadded; preserve_batch = preserve_batch)
end

function outdims(::GlobalMaxPool, isize; preserve_batch = false)
  isize, ispadded = _handle_batchin(isize, 4)

  return _handle_batchout((1, 1, isize[end - 1], isize[end]), ispadded; preserve_batch = preserve_batch)
end

function outdims(::GlobalMeanPool, isize; preserve_batch = false)
  isize, ispadded = _handle_batchin(isize, 4)

  return _handle_batchout((1, 1, isize[end - 1], isize[end]), ispadded; preserve_batch = preserve_batch)
end

#### end conv ####

#### start normalise ####

"""
    outdims(::Dropout, isize)
    outdims(::AlphaDropout, isize)
    outdims(::LayerNorm, isize)
    outdims(::BatchNorm, isize)
    outdims(::InstanceNorm, isize)
    outdims(::GroupNorm, isize)

Calculate the output dimensions given the input dimensions, `isize`.
For a these layers, `outdims(layer, isize) == isize`.

*Note*: since normalisation layers do not store the input size info,
  `isize` is directly returned with no dimension checks.
These definitions exist for convenience.
"""
outdims(::Dropout, isize) = isize
outdims(::AlphaDropout, isize) = isize
outdims(::LayerNorm, isize) = isize
outdims(::BatchNorm, isize) = isize
outdims(::InstanceNorm, isize) = isize
outdims(::GroupNorm, isize) = isize

#### end normalise ####