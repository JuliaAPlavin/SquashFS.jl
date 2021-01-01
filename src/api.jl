import TranscodingStreams: Codec, Noop


@with_kw struct Image{TIO <: IO, TDECOMP <: Codec}
    io::TIO
    decompressor::Type{TDECOMP}
    superblock::Superblock
    root_inode_number::Int
    
    inodes::Vector{Tuple{InodeHeader, Inode}} = []  # array index equals to inode_number
    directory_table::Dict{UInt32, Vector{Pair{DirectoryHeader, Vector{DirectoryEntry}}}} = Dict()  # inode number => sequence of header-entries runs
    fragment_table::Vector{FragmentBlockEntry} = []  # array index equals entry number

    path_to_inode::Dict{String, Int} = Dict()
end

include("sqfs_parts.jl")


function open(fname::AbstractString)
    io = Base.open(fname, "r")
    superblock = read_bittypes(io, Superblock)
    img = Image(; io, superblock, root_inode_number=-1, decompressor=decompressor(superblock))

    @set! img.root_inode_number = read_root_inode_number(img, superblock)
    read_inodes!(img)
    read_directory_table!(img)
    read_fragment_table!(img)
    fill_path_to_inode!(img)
    return img
end

function readdir(img::Image, inode_number::Int)
    dir_tab = img.directory_table[inode_number]
    mapreduce(vcat, dir_tab) do (header, entries)
        map(e -> e.name, entries)
    end
end

readdir(img::Image, path::AbstractString) = readdir(img, img.path_to_inode[path])

function readfile(img::Image, inode_number::Int)
    header, inode = img.inodes[inode_number]
    @assert inode isa InodeFile
    @assert block_count(inode, img.superblock) == 0
    @assert is_valid(inode.fragment_block_index)
    bytes = read_data_block(img, img.fragment_table[begin + inode.fragment_block_index], inode.block_offset+1:inode.block_offset + inode.file_size)
    return String(bytes)
end

readfile(img::Image, path::AbstractString) = readfile(img, img.path_to_inode[path])


# = Helpers =
function fill_path_to_inode!(img::Image, cur_path::String="/", cur_inode::Int=img.root_inode_number)
    img.path_to_inode[cur_path] = cur_inode
    haskey(img.directory_table, cur_inode) || return
    dir_tab = img.directory_table[cur_inode]
    for (header, entries) in dir_tab
        for entry in entries
            img.path_to_inode[joinpath(cur_path, entry.name)] = header.inode_number + entry.inode_offset
        end
    end
end