using Test
import SquashFS
import squashfs_tools_jll: mksquashfs_path; const mksquashfs = mksquashfs_path

import CompatHelperLocal
CompatHelperLocal.@check()

withenv("JULIA_LOAD_PATH" => nothing) do
    run(`$(Base.julia_cmd()) ../docs/make.jl`)
end


@testset "empty" begin
    cd(mktempdir())
    mkdir("./xdir")
    run(pipeline(`$mksquashfs xdir xdir.sqsh`, stdout=devnull))
    img = SquashFS.open("xdir.sqsh")
    @test SquashFS.readdir(img, "/") == []
    @test SquashFS.files_recursive(img, "/") == []
    @test_throws KeyError SquashFS.readdir(img, "/abc")
    @test_throws KeyError SquashFS.readfile(img, "/abc")
end

@testset "simple" begin
    cd(mktempdir())
    mkdir("./xdir")
    write("./xdir/emptyfile", "")
    write("./xdir/tmpfile", "abc def\n\n\r")
    write("./xdir/fsdsfаоывладылfkdsf", "привет! abc def\n\n\r")
    run(pipeline(`$mksquashfs xdir xdir.sqsh`, stdout=devnull))
    img = SquashFS.open("xdir.sqsh")
    @test Set(SquashFS.readdir(img, "/")) == Set(["emptyfile", "tmpfile", "fsdsfаоывладылfkdsf"])
    @test Set(SquashFS.files_recursive(img, "/")) == Set(["emptyfile", "tmpfile", "fsdsfаоывладылfkdsf"])
    @test_throws KeyError SquashFS.readdir(img, "/abc")
    @test_throws KeyError SquashFS.readfile(img, "/abc")
    @test SquashFS.readfile(img, "/emptyfile", String) == ""
    @test SquashFS.readfile(img, "/tmpfile", String) == "abc def\n\n\r"
    @test SquashFS.readfile(img, "/fsdsfаоывладылfkdsf", String) == "привет! abc def\n\n\r"
end

@testset "large files compression" begin
    cd(mktempdir())
    mkdir("./xdir")
    content1 = String(ones(UInt8, 100_000))
    write("./xdir/longfile1", content1)
    content2 = String(ones(UInt8, 1_000_000))
    write("./xdir/longfile2", content2)
    content3 = String(ones(UInt8, 10_000_000))
    write("./xdir/longfile3", content3)
    content4 = String(zeros(UInt8, 10_000_000))
    write("./xdir/longfile4", content4)
    run(pipeline(`$mksquashfs xdir xdir.sqsh`, stdout=devnull))
    @test stat("xdir.sqsh").size < 50_000  # confirm compression
    img = SquashFS.open("xdir.sqsh")
    @test Set(SquashFS.readdir(img, "/")) == Set(["longfile1"; "longfile2"; "longfile3"; "longfile4"])
    @test Set(SquashFS.files_recursive(img, "/")) == Set(["longfile1"; "longfile2"; "longfile3"; "longfile4"])
    @test SquashFS.readfile(img, "/longfile1", String) == content1
    @test SquashFS.readfile(img, "/longfile2", String) == content2
    @test SquashFS.readfile(img, "/longfile3", String) == content3
    @test SquashFS.readfile(img, "/longfile4", String) == content4
end

@testset for args in [("-always-use-fragments",), ("-Xcompression-level", "5",), ("-noDataCompression",), ("-noDataCompression", "-noInodeCompression", "-noFragmentCompression")]
    cd(mktempdir())
    mkdir("./xdir")
    content1 = String(ones(UInt8, 100_000))
    write("./xdir/longfile1", content1)
    content2 = String(rand(UInt8, 1_000_000))
    write("./xdir/longfile2", content2)
    content3 = String(ones(UInt8, 10_000_000))
    write("./xdir/longfile3", content3)
    run(pipeline(`$mksquashfs xdir xdir.sqsh $args`, stdout=devnull))
    img = SquashFS.open("xdir.sqsh")
    @test Set(SquashFS.readdir(img, "/")) == Set(["longfile1"; "longfile2"; "longfile3"])
    @test Set(SquashFS.files_recursive(img, "/")) == Set(["longfile1"; "longfile2"; "longfile3"])
    @test SquashFS.readfile(img, "/longfile1", String) == content1
    @test SquashFS.readfile(img, "/longfile2", String) == content2
    @test SquashFS.readfile(img, "/longfile3", String) == content3
end

@testset "different compression formats" for comp in ["gzip", "zstd"]
    cd(mktempdir())
    mkdir("./xdir")
    content1 = String(ones(UInt8, 100_000))
    write("./xdir/longfile1", content1)
    content2 = String(ones(UInt8, 1_000_000))
    write("./xdir/longfile2", content2)
    content3 = String(zeros(UInt8, 10_000_000))
    write("./xdir/longfile3", content3)
    content4 = String(rand(UInt8, 100_000))  # random to test uncompressed blocks - check coverage and confirm
    write("./xdir/longfile4", content4)
    run(pipeline(`$mksquashfs xdir xdir.sqsh -comp $comp`, stdout=devnull))
    @test stat("xdir.sqsh").size < 200_000  # confirm compression
    img = SquashFS.open("xdir.sqsh")
    @test Set(SquashFS.readdir(img, "/")) == Set(["longfile1"; "longfile2"; "longfile3"; "longfile4"])
    @test Set(SquashFS.files_recursive(img, "/")) == Set(["longfile1"; "longfile2"; "longfile3"; "longfile4"])
    @test SquashFS.readfile(img, "/longfile1", String) == content1
    @test SquashFS.readfile(img, "/longfile2", String) == content2
    @test SquashFS.readfile(img, "/longfile3", String) == content3
    @test SquashFS.readfile(img, "/longfile4", String) == content4
end

@testset "mix" begin
    cd(mktempdir())
    mkdir("./xdir")
    write("./xdir/emptyfile", "")
    write("./xdir/tmpfile", "abc def\n\n\r")
    write("./xdir/fsdsfаоывладылfkdsf", "привет! abc def\n\n\r")
    content1 = String(ones(UInt8, 100_000))
    write("./xdir/longfile1", content1)
    content2 = String(ones(UInt8, 1_000_000))
    write("./xdir/longfile2", content2)
    content3 = String(ones(UInt8, 10_000_000))
    write("./xdir/longfile3", content3)
    for i in 1:1000
        write("./xdir/smallfile$i", join([string(j) for j in 1:i], "\n"))
    end
    mkpath("./xdir/abc/def/првиет/")
    write("./xdir/abc/def/првиет/file.txt", "\nabc\n")
    run(pipeline(`$mksquashfs xdir xdir.sqsh`, stdout=devnull))

    img = SquashFS.open("xdir.sqsh")
    @test Set(SquashFS.readdir(img, "/")) == Set(["emptyfile"; "tmpfile"; "longfile1"; "longfile2"; "longfile3"; "fsdsfаоывладылfkdsf"; "abc"; ["smallfile$i" for i in 1:1000]])
    @test Set(SquashFS.files_recursive(img, "/")) == Set(["emptyfile"; "tmpfile"; "longfile1"; "longfile2"; "longfile3"; "fsdsfаоывладылfkdsf"; "abc/def/првиет/file.txt"; ["smallfile$i" for i in 1:1000]])
    @test Set(SquashFS.rglob(img, ".txt", "/")) == Set(["abc/def/првиет/file.txt"])
    @test SquashFS.readfile(img, "/emptyfile", String) == ""
    @test SquashFS.readfile(img, "/tmpfile", String) == "abc def\n\n\r"
    @test SquashFS.readfile(img, "/fsdsfаоывладылfkdsf", String) == "привет! abc def\n\n\r"
    @test SquashFS.readfile(img, "/longfile1", String) == content1
    @test SquashFS.readfile(img, "/longfile2", String) == content2
    @test SquashFS.readfile(img, "/longfile3", String) == content3
    for i in [1, 2, 3, 4, 5, 123, 500, 999, 1000]  # test several files among those 1000
        @test SquashFS.readfile(img, "/smallfile$i", String) == join([string(j) for j in 1:i], "\n")
    end
    @test SquashFS.readdir(img, "/abc") == ["def"]
    @test SquashFS.readfile(img, "/abc/def/првиет/file.txt", String) == "\nabc\n"
end

# import SquashFS
# const large_file = "/home/aplavin/Downloads/noflag.sqsh"
# img = SquashFS.open(large_file)
# SquashFS.readfile(img, 1)
# header, inode = img.inodes[1]
# frag_blk = img.fragment_table[begin + inode.fragment_block_index]
# @time for _ in 1:10^3
#     SquashFS.read_data_block(img, frag_blk.start, SquashFS.size(frag_blk.size), true, inode.block_offset+1:inode.block_offset + inode.file_size)
# end

# @show img.superblock img.superblock.root_inode_ref length.(values(img.directory_table))
# files = SquashFS.readdir(img, "/")
# @show length(files) files[1:5] files[end-5:end]
# @show SquashFS.readfile(img, 1)
# @show SquashFS.readfile(img, "/" * files[1])
# @btime SquashFS.readfile($img, 1)
