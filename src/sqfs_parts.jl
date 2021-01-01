import TranscodingStreams: TranscodingStream, State, initbuffer!

# == Blocks ==

# = Metadata =
function read_metadata_block(img::Image, ::Type{Vector{UInt8}})
    header = read(img.io, UInt16)
    compressed = header & 0x8000 == 0
    size = header & ~0x8000
    data = read(img.io, size)
    if compressed
        data = transcode(img.decompressor, data)
    end
    return data
end
read_metadata_block(img::Image, ::Type{IO}) = IOBuffer(read_metadata_block(img, Vector{UInt8}))

function read_metadata_blocks(img::Image, rng::UnitRange{UInt64})
    seek(img.io, first(rng))
    buf = IOBuffer(read=true, append=true)
    block_start_to_uncompressed_off = Dict{UInt64, UInt64}(0 => 0)
    while position(img.io) < last(rng)
        block_start_to_uncompressed_off[position(img.io) - first(rng)] = buf.size
        write(buf, read_metadata_block(img, Vector{UInt8}))
    end
    @assert position(img.io) == last(rng) + 1
    return buf, block_start_to_uncompressed_off
end

# = Data =
# - Full block -
read_data_block(img::Image, start::Unsigned, bs::BlockSize) = read_data_block(img, start, size(bs), is_compressed(bs))
function read_data_block(img::Image, start::Unsigned, size::Unsigned, is_compressed::Bool)
    if is_compressed
        seek(img.io, start)
        data = read_all(img.io, size)
        transcode(img.decompressor, data)
    else
        seek(img.io, start)
        read_all(img.io, size)
    end
end

# - Part of block -
read_data_block_part(img::Image, fbe::FragmentBlockEntry, inode::InodeFile) = read_data_block_part(img, fbe, inode.block_offset+1:inode.block_offset + inode.file_size % img.superblock.block_size)
read_data_block_part(img::Image, fbe::FragmentBlockEntry, rng::UnitRange) = read_data_block_part(img, fbe.start, fbe.size, rng)
read_data_block_part(img::Image, start::Unsigned, bs::BlockSize, rng::UnitRange) = read_data_block_part(img, start, size(bs), is_compressed(bs), rng)
function read_data_block_part(img::Image, start::Unsigned, size::Unsigned, is_compressed::Bool, rng::UnitRange)
    if is_compressed
        seek(img.io, start)

        ds = let
            # reinit buffers: fast, just shuffles pointers around
            initbuffer!(img.decompressor_stream.state.buffer1)
            initbuffer!(img.decompressor_stream.state.buffer2)
            # create "fresh" state: otherwise decompressor errors sometimes
            state = State(img.decompressor_stream.state.buffer1, img.decompressor_stream.state.buffer2)
            # create transcoding stream from existing buffers and initialized codec, fast
            TranscodingStream(img.decompressor, img.io, state, initialized=true)
        end
        # simpler version of the above block, but creates buffers and initializes codec every time
        # leaks memory!
        # ds = TranscodingStream(img.decompressor, img.io)

        skip_all(ds, first(rng) - 1)
        read_all(ds, length(rng))
    else
        seek(img.io, start + first(rng) - 1)
        read_all(img.io, length(rng))
    end
end



# == Whole tables ==
# = Inodes =
function read_root_inode_number(img::Image)
    seek(img.io, img.superblock.inode_table_start + img.superblock.root_inode_ref.block_start)
    block_io = read_metadata_block(img, IO)
    skip_all(block_io, img.superblock.root_inode_ref.offset)
    header = read_bittypes(block_io, InodeHeader)
    return header.inode_number
end

function read_inodes!(img::Image)
    @assert isempty(img.inodes_files) && isempty(img.inodes_dirs)
    resize!(img.inodes_files, img.superblock.inode_count)

    table_io, _ = read_metadata_blocks(img, img.superblock.inode_table_start:img.superblock.directory_table_start - 1)

    while !eof(table_io)
        header = read_bittypes(table_io, InodeHeader)
        typ = inode_type_resolve(header.inode_type)
        read_inode!(img, header, typ, table_io)
    end
end

@inline function read_inode!(img::Image, header::InodeHeader, typ::Type{InodeFile}, table_io::IO)
    inode = read(table_io, typ, img.superblock)
    img.inodes_files[header.inode_number] = inode
end

@inline function read_inode!(img::Image, header::InodeHeader, typ::Type{<:Union{InodeDirectory, InodeDirectoryExt}}, table_io::IO)
    @assert !haskey(img.inodes_dirs, header.inode_number)
    inode = read(table_io, typ, img.superblock)
    img.inodes_dirs[header.inode_number] = inode
end


# = Directory table =
function read_directory_table!(img::Image)
    table_io, block_start_to_uncompressed_off = read_metadata_blocks(img, img.superblock.directory_table_start:img.superblock.fragment_table_start - 1)
    seek_to_inode(inode::Inode) = seek(table_io, block_start_to_uncompressed_off[inode.block_idx] + inode.block_offset)
    read_directory_table!(img, seek_to_inode, img.root_directory)
end

function read_directory_table!(img::Image, seek_to_inode::Function, dir::Directory)
    @assert isempty(dir.files) && isempty(dir.dirs)

    dir_inode = img.inodes_dirs[dir.inode_number]
    table_io = seek_to_inode(dir_inode)
    start_pos = position(table_io)

    while position(table_io) < start_pos + dir_inode.file_size - 3  # XXX: why -3???
        header = read_bittypes(table_io, DirectoryHeader)
        for _ in 1:header.count + 1
            entry = read(table_io, DirectoryEntry)
            entry_inode_n = header.inode_number + entry.inode_offset
            if entry.type == DIRECTORY
                dir.dirs[entry.name] = Directory(inode_number=entry_inode_n)
            elseif entry.type == FILE
                dir.files[entry.name] = entry_inode_n
            end
        end
    end

    for subdir in values(dir.dirs)
        read_directory_table!(img, seek_to_inode, subdir)
    end
end


# = Fragment table =
function read_fragment_table!(img::Image)
    @assert isempty(img.fragment_table)
    seek(img.io, img.superblock.fragment_table_start)
    
    nbytes = sizeof(FragmentBlockEntry) * img.superblock.fragment_entry_count
    nblocks = cld(nbytes, 8192)

    start_indices = [read(img.io, UInt64) for _ in 1:nblocks]
    for ix in start_indices
        seek(img.io, ix)
        block = read_metadata_block(img, Vector{UInt8})
        append!(img.fragment_table, reinterpret(FragmentBlockEntry, block))
    end
    @assert length(img.fragment_table) == img.superblock.fragment_entry_count
end
