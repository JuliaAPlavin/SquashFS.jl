import TranscodingStreams: TranscodingStream

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
    block_start_to_uncompressed_off = Dict{UInt64, UInt64}()
    while position(img.io) < last(rng)
        block_start_to_uncompressed_off[position(img.io) - first(rng)] = position(buf)
        write(buf, read_metadata_block(img, Vector{UInt8}))
    end
    @assert position(img.io) == last(rng) + 1
    return buf, block_start_to_uncompressed_off
end

# = Data =
function read_data_block(img::Image, start::UInt64, size::UInt32, is_compressed::Bool, rng::UnitRange)
    @assert is_compressed
    if is_compressed
        seek(img.io, start)
        decomp_io = TranscodingStream{img.decompressor}(img.io)
        skip_all(decomp_io, first(rng) - 1)
        read_all(decomp_io, length(rng))
    else
        seek(img.io, start + first(rng) - 1)
        read_all(img.io, length(rng))
    end
end

read_data_block(img::Image, fbe::FragmentBlockEntry, rng::UnitRange) = read_data_block(img, fbe.start, size(fbe), is_compressed(fbe), rng)



# == Whole tables =
function read_root_inode_number(img::Image, superblock::Superblock)
    seek(img.io, superblock.inode_table_start + superblock.root_inode_ref.block_start)
    block_io = read_metadata_block(img, IO)
    skip_all(block_io, superblock.root_inode_ref.offset)
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
    @assert map(i -> i[1].inode_number, img.inodes) == 1:img.superblock.inode_count
end

function read_directory_table!(img::Image)
    @assert isempty(img.directory_table)
    table_io, block_start_to_uncompressed_off = read_metadata_blocks(img, img.superblock.directory_table_start:img.superblock.fragment_table_start - 1)
    
    dir_inodes = filter(i -> i[2] isa InodeDirectoryExt, img.inodes)
    map(dir_inodes) do (iheader, inode)
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
