import TranscodingStreams: Codec, TranscodingStream

using DocStringExtensions
@template DEFAULT = """
$(TYPEDSIGNATURES)
$(DOCSTRING)
"""


@with_kw struct Directory
    inode_number::Int
    files::Dict{String, Int} = Dict()
    dirs::Dict{String, Directory} = Dict()
end

readdir(dir::Directory)::Vector{String} = String[keys(dir.dirs)..., keys(dir.files)...]
files_recursive(dir::Directory)::Vector{String} = String[keys(dir.files)..., [joinpath(name, f) for (name, d) in pairs(dir.dirs) for f in files_recursive(d)]...]
rglob(pattern, dir::Directory)::Vector{String} = String[[f for f in keys(dir.files) if occursin(pattern, f)]..., [joinpath(name, f) for (name, d) in pairs(dir.dirs) for f in rglob(pattern, d)]...]


@with_kw struct Image{TIO <: IO, TDECOMP <: Codec}
    io::TIO
    decompressor::TDECOMP
    decompressor_stream::TranscodingStream{TDECOMP, TIO} = TranscodingStream{typeof(decompressor)}(io)

    superblock::Superblock
    
    inodes_files::Vector{InodeFile} = []  # array index equals to inode_number
    inodes_dirs::Dict{Int, Inode} = Dict()  # inode number => inode
    root_directory::Directory = Directory(inode_number=-1)
    fragment_table::Vector{FragmentBlockEntry} = []  # array index equals entry number
end

include("sqfs_parts.jl")

"""Open SquashFS image file.
Immediately reads list of all inodes, directory structure, and fragments table.
These are always kept in memory for implementation simplicity and performance."""
function open(fname::AbstractString)::Image
    io = Base.open(fname, "r")
    superblock = read_bittypes(io, Superblock)
    img = Image(; io, superblock, decompressor=decompressor(superblock))

    @set! img.root_directory.inode_number = read_root_inode_number(img)
    read_inodes!(img)
    read_directory_table!(img)
    read_fragment_table!(img)
    return img
end

"""Return the names in the directory `path` within SquashFS image `img`."""
readdir(img::Image, path::AbstractString) = readdir(directory_by_path(img, path))

"""Return the paths of all files contained in the directory `path` within SquashFS image `img`, recursively.
Returned paths are relative to the specified `path`."""
files_recursive(img::Image, path::AbstractString) = files_recursive(directory_by_path(img, path))

"""Returns the paths of all files matching `pattern` in directory `path` within SquashFS image `img`, recursively.
`pattern` can be any object that supports `occursin(pattern, name::String)`: e.g. `String`, `Regex`, or patterns from the `Glob.jl` package."""
rglob(img::Image, pattern, path::AbstractString="/") = rglob(pattern, directory_by_path(img, path))


function readfile(img::Image, inode::InodeFile)
    bytes = UInt8[]
    start = inode.blocks_start
    for bs in inode.block_sizes
        block = size(bs) > 0 ? read_data_block(img, start, bs) : zeros(UInt8, min(img.superblock.block_size, inode.file_size - length(bytes)))
        append!(bytes, block)
        start += size(bs)
    end
    if is_valid(inode.fragment_block_index)
        frag_blk = img.fragment_table[begin + inode.fragment_block_index]
        append!(bytes, read_data_block_part(img, frag_blk, inode))
    end
    @assert length(bytes) == inode.file_size  (length(bytes), inode, inode.block_sizes)
    return bytes
end

"""Read content of the file at `path` in the SquashFS image `img`. Return a bytearray."""
readfile(img::Image, path::AbstractString) = readfile(img, file_inode_by_path(img, path))

readfile(img::Image, inode_number::Int) = readfile(img, img.inodes_files[inode_number])

"""Read content of the file `spec` in the SquashFS image `img`. Returns a `String`.
`spec` can be a path or another supported value such as an inode number."""
readfile(img::Image, spec, ::Type{String}) = String(readfile(img, spec))

"""Open the file at `path` in the SquashFS image `img` and return as an `IO` object.
For now just reads the whole content of the file and wraps it into an `IOBuffer`.
May become more efficient in the future."""
openfile(img::Image, spec) = IOBuffer(readfile(img, spec))


function directory_by_path(img::Image, path::AbstractString)
    components = splitpath(path)
    components[1] == "/" && deleteat!(components, 1)
    foldl(components, init=img.root_directory) do dir, subname
        dir.dirs[subname]
    end
end

function file_inode_by_path(img::Image, path::AbstractString)
    dirpath, name = splitdir(path)
    dir = directory_by_path(img, dirpath)
    return dir.files[name]
end
