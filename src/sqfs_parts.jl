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
        block_start_to_uncompressed_off[position(img.io) - first(rng)] = position(buf)
        write(buf, read_metadata_block(img, Vector{UInt8}))
    end
    @assert position(img.io) == last(rng) + 1
    return buf, block_start_to_uncompressed_off
end

# = Data =
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

read_data_block(img::Image, fbe::FragmentBlockEntry, rng::UnitRange) = read_data_block(img, fbe.start, fbe.size, rng)
read_data_block(img::Image, start::Unsigned, bs::BlockSize, rng::UnitRange) = read_data_block(img, start, size(bs), is_compressed(bs), rng)
function read_data_block(img::Image, start::Unsigned, size::Unsigned, is_compressed::Bool, rng::UnitRange)
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



# == Whole tables =
function read_root_inode_number(img::Image)
    seek(img.io, img.superblock.inode_table_start + img.superblock.root_inode_ref.block_start)
    block_io = read_metadata_block(img, IO)
    skip_all(block_io, img.superblock.root_inode_ref.offset)
    header = read_bittypes(block_io, InodeHeader)
    return header.inode_number
end

function read_inodes!(img::Image)
    @assert isempty(img.inodes)
    table_io, _ = read_metadata_blocks(img, img.superblock.inode_table_start:img.superblock.directory_table_start - 1)

    while !eof(table_io)
        header = read_bittypes(table_io, InodeHeader)
        typ = inode_type_resolve(header.inode_type)
        inode = read(table_io, typ, img.superblock)
        push!(img.inodes, (header, inode))
    end
    permute!(img.inodes, map(i -> i[1].inode_number, img.inodes))
    @assert map(i -> i[1].inode_number, img.inodes) == 1:img.superblock.inode_count
end

function read_directory_table!(img::Image)
    @assert isempty(img.directory_table)
    table_io, block_start_to_uncompressed_off = read_metadata_blocks(img, img.superblock.directory_table_start:img.superblock.fragment_table_start - 1)
    
    dir_inodes = filter(i -> is_directory_inode(i[2]), img.inodes)
    for (iheader, inode) in dir_inodes
        img.directory_table[iheader.inode_number] = []

        uncompressed_start = block_start_to_uncompressed_off[inode.block_idx] + inode.block_offset
        seek(table_io, uncompressed_start)
        while position(table_io) < uncompressed_start + inode.file_size - 3  # XXX: why -3???
            header = read_bittypes(table_io, DirectoryHeader)
            entries = [read(table_io, DirectoryEntry) for _  in 1:header.count + 1]
            push!(img.directory_table[iheader.inode_number], header => entries)
        end
    end
end

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
