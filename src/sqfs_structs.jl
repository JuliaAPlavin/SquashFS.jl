using Parameters
using Setfield
using FlagSets
import CBinding: @cstruct
import TranscodingStreams: initialize
import CodecZlib: ZlibDecompressor
import CodecZstd: ZstdDecompressor


const MAGIC = 0x73717368
is_valid(x::Integer) = count_zeros(x) > 0


# == Superblock ==
@flagset SuperblockFlags::UInt16 begin
    UNCOMPRESSED_INODES    = 0x0001  # Inodes are stored uncompressed. For backward compatibility reasons, UID/GIDs are also stored uncompressed.
    UNCOMPRESSED_DATA      = 0x0002  # Data are stored uncompressed
    CHECK                  = 0x0004  # Unused in squashfs 4+. Should always be unset
    UNCOMPRESSED_FRAGMENTS = 0x0008  # Fragments are stored uncompressed
    NO_FRAGMENTS           = 0x0010  # Fragments are not used. Files smaller than the block size are stored in a full block.
    ALWAYS_FRAGMENTS       = 0x0020  # If the last block of a file is smaller than the block size, it will be instead stored as a fragment
    DUPLICATES             = 0x0040  # Identical files are recognized, and stored only once
    EXPORTABLE             = 0x0080  # Filesystem has support for export via NFS (The export table is populated)
    UNCOMPRESSED_XATTRS    = 0x0100  # Xattrs are stored uncompressed
    NO_XATTRS              = 0x0200  # Xattrs are not stored
    COMPRESSOR_OPTIONS     = 0x0400  # The compression options section is present
    UNCOMPRESSED_IDS       = 0x0800  # UID/GIDs are stored uncompressed. Note that the UNCOMPRESSED_INODES flag also has this effect. If that flag is set, this flag has no effect. This flag is currently only available on master in git, no released version of squashfs yet supports it.
end

@enum CompressionMode::UInt16 GZIP = 1 LZMA = 2 LZO  = 3 XZ   = 4 LZ4  = 5 ZSTD = 6

const compression_mode_to_decompressor = Dict(
    GZIP => ZlibDecompressor,
    ZSTD => ZstdDecompressor,
)

@cstruct InodeReference {
    offset::UInt16
    block_start::UInt32
    __unused::UInt16
} __packed__

@with_kw struct Superblock
    magic                  ::UInt32  # Must match the value of 0x73717368 to be considered a squashfs archive
    inode_count            ::UInt32  # The number of inodes stored in the inode table
    modification_time      ::UInt32  # The number of seconds (not counting leap seconds) since 00:00, Jan 1 1970 UTC when the archive was created (or last appended to). This is unsigned, so it expires in the year 2106 (as opposed to 2038).
    block_size             ::UInt32  # The size of a data block in bytes. Must be a power of two between 4096 and 1048576 (1 MiB)
    fragment_entry_count   ::UInt32  # The number of entries in the fragment table
    compression_mode       ::CompressionMode  # 1 - GZIP, 2 - LZMA, 3 - LZO, 4 - XZ, 5 - LZ4, 6 - ZSTD
    block_log              ::UInt16  # The log2 of block_size. If block_size and block_log do not agree, the archive is considered corrupt
    flags                  ::SuperblockFlags  # Superblock Flags
    id_count               ::UInt16  # The number of entries in the id lookup table
    version_major          ::UInt16  # The major version of the squashfs file format. Should always equal 4
    version_minor          ::UInt16  # The minor version of the squashfs file format. Should always equal 0
    root_inode_ref         ::InodeReference  # A reference to the inode of the root directory of the archive
    bytes_used             ::UInt64  # The number of bytes used by the archive. Because squashfs archives are often padded to 4KiB, this can often be less than the file size
    id_table_start         ::UInt64  # The byte offset at which the id table starts
    xattr_id_table_start   ::UInt64  # The byte offset at which the xattr id table starts
    inode_table_start      ::UInt64  # The byte offset at which the inode table starts
    directory_table_start  ::UInt64  # The byte offset at which the directory table starts
    fragment_table_start   ::UInt64  # The byte offset at which the fragment table starts
    export_table_start     ::UInt64  # The byte offset at which the export table starts

    @assert magic == MAGIC
    @assert (version_major, version_minor) == (4, 0)
    @assert block_size == 2^block_log
end

function decompressor(sb::Superblock)
    decomp = compression_mode_to_decompressor[sb.compression_mode]()
    initialize(decomp)
    return decomp
end


# == Inodes ==
@enum InodeType::UInt16 DIRECTORY=1 FILE=2 SYMLINK=3 BLOCKDEV=4 CHARDEV=5 PIPE=6 SOCKET=7 DIRECTORYEXT=8 FILEEXT=9 SYMLINKEXT=10 BLOCKDEVEXT=11 CHARDEVEXT=12 PIPEEXT=13 SOCKETEXT=14

@with_kw struct InodeHeader
    inode_type    ::InodeType  # The type of item described by the inode which follows this header.
    permissions   ::UInt16  # A bitmask representing the permissions for the item described by the inode. The values match with the permission values of mode_t (the mode bits, not the file type)
    uid_idx       ::UInt16  # The index of the user id in the UID/GID Table
    gid_idx       ::UInt16  # The index of the group id in the UID/GID Table
    modified_time ::UInt32  # The unsigned number of seconds (not counting leap seconds) since 00:00, Jan 1 1970 UTC when the item described by the inode was last modified
    inode_number  ::UInt32  # The position of this inode in the full list of inodes. Value should be in the range [1, inode_count](from the superblock) This can be treated as a unique identifier for this inode, and can be used as a key to recreate hard links: when processing the archive, remember the visited values of inode_number. If an inode number has already been visited, this inode is hardlinked
end

inode_type_resolve(typ::InodeType) =
    if     typ ==         FILE          InodeFile
    elseif typ ==    DIRECTORY     InodeDirectory
    elseif typ == DIRECTORYEXT  InodeDirectoryExt
    else throw(ArgumentError("unknown inode type: $typ")) end

abstract type Inode end
is_directory_inode(::Inode) = false


# = Inode file ==
@with_kw struct BlockSize
    value::UInt32
end
is_compressed(bs::BlockSize) = bs.value & 0x1000000 == 0
size(bs::BlockSize) = bs.value & 0xFFFFFF

@with_kw struct InodeFile <: Inode
    blocks_start         ::UInt32    # The offset from the start of the archive where the data blocks are stored
    fragment_block_index ::UInt32    # The index of a fragment entry in the fragment table which describes the data block the fragment of this file is stored in. If this file does not end with a fragment, this should be 0xFFFFFFFF
    block_offset         ::UInt32    # The (uncompressed) offset within the fragment data block where the fragment for this file. Information about the fragment can be found at fragment_block_index. The size of the fragment can be found as file_size % superblock.block_size If this file does not end with a fragment, the value of this field is undefined (probably zero)
    file_size            ::Int32     # The (uncompressed) size of this file
    block_sizes          ::Vector{BlockSize} = [] # A list of block sizes. If this file ends in a fragment, the size of this list is the number of full data blocks needed to store file_size bytes. If this file does not have a fragment, the size of the list is the number of blocks needed to store file_size bytes, rounded up. Each item in the list describes the (possibly compressed) size of a block. See datablocks & fragments for information about how to interpret this size.
end
block_count(i::InodeFile, sb::Superblock) = !is_valid(i.fragment_block_index) ? cld(i.file_size, sb.block_size) : fld(i.file_size, sb.block_size)

function Base.read(io::IO, ::Type{InodeFile}, superblock::Superblock)
    res = read_bittypes(io, InodeFile)
    append!(res.block_sizes, [read_bittypes(io, BlockSize) for _ in 1:block_count(res, superblock)])
    return res
end

# = Inode dir =
@with_kw struct InodeDirectory <: Inode
    block_idx            ::UInt32  # The index of the block in the Directory Table where the directory entry information starts
    hard_link_count      ::UInt32  # The number of hard links to this directory
    file_size            ::UInt16  # Total (uncompressed) size in bytes of the entries in the Directory Table, including headers
    block_offset         ::UInt16  # The (uncompressed) offset within the block in the Directory Table where the directory entry information starts
    parent_inode_number  ::UInt32  # The inode_number of the parent of this directory. If this is the root directory, this will be 1
end
is_directory_inode(::InodeDirectory) = true
Base.read(io::IO, ::Type{InodeDirectory}, ::Superblock) = read_bittypes(io, InodeDirectory)

@with_kw struct DirectoryIndex
    index     ::UInt32  # This stores a byte offset from the first directory header to the current header, as if the uncompressed directory metadata blocks were laid out in memory consecutively.
    start     ::UInt32  # Start offset of a directory table metadata block
    name_size ::Int32   # One less than the size of the entry name
    name      ::String = ""  # The name of the first entry following the header without a trailing null byte
end

function Base.read(io::IO, ::Type{DirectoryIndex})
    res = read_bittypes(io, DirectoryIndex)
    @set! res.name = String(read_all(io, res.name_size + 1))
    return res
end

@with_kw struct InodeDirectoryExt <: Inode
    hard_link_count      ::Int32   # The number of hard links to this directory
    file_size            ::Int32   # Total (uncompressed) size in bytes of the entries in the Directory Table, including headers
    block_idx            ::UInt32  # The index of the block in the Directory Table where the directory entry information starts
    parent_inode_number  ::UInt32  # The inode_number of the parent of this directory. If this is the root directory, this will be 1
    index_count          ::Int16   # One less than the number of directory index entries following the inode structure
    block_offset         ::UInt16  # The (uncompressed) offset within the block in the Directory Table where the directory entry information starts
    xattr_idx            ::UInt32  # An index into the xattr lookup table. Set to 0xFFFFFFFF if the inode has no extended attributes
    index                ::Vector{DirectoryIndex} = []  # A list of directory index entries for faster lookup in the directory table
end
is_directory_inode(::InodeDirectoryExt) = true

function Base.read(io::IO, ::Type{InodeDirectoryExt}, superblock::Superblock)
    res = read_bittypes(io, InodeDirectoryExt)
    append!(res.index, [read(io, DirectoryIndex) for _ in 1:res.index_count])
    return res
end



# == Directory table ==
@with_kw struct DirectoryHeader
    count        ::Int32   # One less than the number of entries following the header
    start        ::UInt32  # The starting byte offset of the block in the Inode Table where the inodes are stored
    inode_number ::UInt32  # An arbitrary inode number. The entries that follow store their inode number as a difference to this. Typically the inode numbers are allocated in a continuous sequence for all children of a directory and the header simply stores the first one. Hard links of course break the sequence and require a new header if they are further away than +/- 32k of this number. Inode number allocation and picking of the reference could of course be optimized to prevent this.
    @assert count >= 0
end

@with_kw struct DirectoryEntry
    offset       ::UInt16  # An offset into the uncompressed inode metadata block
    inode_offset ::Int16   # The difference of this inode's number to the reference stored in the header
    type         ::InodeType  # The inode type. For extended inodes, the corresponding basic type is stored here instead
    name_size    ::Int16   # One less than the size of the entry name
    name         ::String = ""  # The file name of the entry without a trailing null byte
    @assert name_size >= 0
end

function Base.read(io::IO, ::Type{DirectoryEntry})
    res = read_bittypes(io, DirectoryEntry)
    @set! res.name = String(read_all(io, res.name_size + 1))
    return res
end


# == Fragment table == 
@with_kw struct FragmentBlockEntry
    start    ::UInt64  # The offset within the archive where the fragment block starts
    size     ::BlockSize  # This stores two pieces of information. If the block is uncompressed, the 0x1000000 (1<<24) bit wil be set. The remaining bits describe the size of the fragment block on disk. Because the max value of block_size is 1 MiB (1<<20), and the size of a fragment block should be less than block_size, the uncompressed bit will never be set by the size.
    __unused ::UInt32  # This field is unused
    @assert __unused == 0
end
