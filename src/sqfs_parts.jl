

function read_metadata_block(io::IO)
    header = read(io, UInt16)
    compressed = header & 0x8000 == 0
    size = header & ~0x8000
    data = read(io, size)
    if compressed
        data = transcode(ZlibDecompressor, data)
    end
    return data
end

function read_metadata_blocks(io::IO, rng::UnitRange{UInt64})
    data = UInt8[]
    seek(io, first(rng))
    block_off_to_uncompressed_idx = Dict{UInt64, UInt64}()
    while position(io) < last(rng)
        block_off_to_uncompressed_idx[position(io) - first(rng)] = length(data) + 1
        block = read_metadata_block(io)
        if position(io) <= last(rng)
            # last block can be smaller
            # @assert length(block) == 8192
        end
        append!(data, block)
    end
    @assert position(io) == last(rng) + 1
    return data, block_off_to_uncompressed_idx
end

function read_inodes!(img::Image)
    @assert isempty(img.inodes)
    table_data, block_off_to_uncompressed_idx = read_metadata_blocks(img.io, img.superblock.inode_table_start:img.superblock.directory_table_start - 1)
    table_io = IOBuffer(table_data, read=true)

    root_inode_uncompressed_start = block_off_to_uncompressed_idx[img.superblock.root_inode_ref.block_start] + img.superblock.root_inode_ref.offset

    root_inode_number = nothing
    while !eof(table_io)
        is_root = position(table_io) == root_inode_uncompressed_start - 1
        header = read_bittypes(table_io, InodeHeader)
        typ = inode_type_resolve(header.inode_type)
        inode = read(table_io, typ, img.superblock)
        push!(img.inodes, (header, inode))
        if is_root
            root_inode_number = header.inode_number
        end
    end
    @assert map(i -> i[1].inode_number, img.inodes) == 1:img.superblock.inode_count
    @assert root_inode_number != nothing
    @set! img.root_inode_number = root_inode_number
    return img
end

function read_directory_table!(img::Image)
    @assert isempty(img.directory_table)
    table_data, block_off_to_uncompressed_idx = read_metadata_blocks(img.io, img.superblock.directory_table_start:img.superblock.fragment_table_start - 1)
    
    dir_inodes = filter(i -> i[2] isa InodeDirectoryExt, img.inodes)
    map(dir_inodes) do (iheader, inode)
        img.directory_table[iheader.inode_number] = []

        uncompressed_start = block_off_to_uncompressed_idx[inode.block_idx] + inode.block_offset
        table_data_cur = @view table_data[uncompressed_start:uncompressed_start + inode.file_size - 1 - 3]  # XXX: why -3???
        table_io = IOBuffer(table_data_cur, read=true)

        while !eof(table_io)
            header = read_bittypes(table_io, DirectoryHeader)
            entries = map(1:header.count + 1) do _
                read(table_io, DirectoryEntry)
            end
            push!(img.directory_table[iheader.inode_number], header => entries)
        end
    end
    return img
end

function read_fragment_table!(img::Image)
    @assert isempty(img.fragment_table)
    seek(img.io, img.superblock.fragment_table_start)
    
    nbytes = sizeof(FragmentBlockEntry) * img.superblock.fragment_entry_count
    nblocks = cld(nbytes, 8192)

    start_indices = [read(img.io, UInt64) for _ in 1:nblocks]
    table_data = mapreduce(vcat, start_indices) do ix
        seek(img.io, ix)
        read_metadata_block(img.io)
    end
    @assert length(table_data) == nbytes
    append!(img.fragment_table, reinterpret(FragmentBlockEntry, table_data))
    return img
end

function read_data_block(img::Image, start::UInt64, size::UInt32, is_compressed::Bool, rng::UnitRange)
    @assert is_compressed
    if is_compressed
        seek(img.io, start)
        decomp_io = ZlibDecompressorStream(img.io)
        read_all(decomp_io, first(rng) - 1)
        read_all(decomp_io, length(rng))
    else
        seek(img.io, start + first(rng) - 1)
        read_all(img.io, length(rng))
    end
end

read_data_block(img::Image, fbe::FragmentBlockEntry, rng::UnitRange) = read_data_block(img, fbe.start, size(fbe), is_compressed(fbe), rng)