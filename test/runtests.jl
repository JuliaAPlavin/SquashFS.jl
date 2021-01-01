using Test
using BenchmarkTools
import SquashFS

const large_file = "/home/aplavin/Downloads/noflag.sqsh"

img = SquashFS.open(large_file)
@show Base.summarysize(img)/1e6 img.superblock img.superblock.root_inode_ref length.(values(img.directory_table))
files = SquashFS.readdir(img, "/")
@show length(files) files[1:5] files[end-5:end]
@show SquashFS.readfile(img, 1)
@show SquashFS.readfile(img, "/" * files[1])
@btime SquashFS.readfile($img, 1)
