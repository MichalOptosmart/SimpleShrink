// SimpleShrink — Copyright (C) 2026 OptoSmart. GPL-2.0-only, see COPYING.

import Testing

@testable import SimpleShrinkKit

@Suite("e2fsprogs output")
struct E2fsprogsParsingTests {
    let dumpe2fs = """
        dumpe2fs 1.47.1 (20-May-2024)
        Filesystem volume name:   rootfs
        Last mounted on:          /
        Filesystem UUID:          0a1b2c3d-4e5f-6071-8293-a4b5c6d7e8f9
        Filesystem magic number:  0xEF53
        Filesystem revision #:    1 (dynamic)
        Filesystem features:      has_journal ext_attr resize_inode dir_index filetype extent 64bit flex_bg
        Default mount options:    user_xattr acl
        Filesystem state:         clean
        Errors behavior:          Continue
        Filesystem OS type:       Linux
        Inode count:              793800
        Block count:              3177216
        Reserved block count:     158860
        Free blocks:              2564883
        Free inodes:              730321
        First block:              0
        Block size:               4096
        Fragment size:            4096
        Journal UUID:             <none>
        """

    @Test("The fields the pipeline acts on are read out of dumpe2fs -h")
    func parsesSuperblock() throws {
        let superblock = try #require(E2fsprogs.parseSuperblock(dumpe2fs))
        #expect(superblock.blockSize == 4096)
        #expect(superblock.blockCount == 3_177_216)
        #expect(superblock.freeBlocks == 2_564_883)
        #expect(superblock.isClean)
        #expect(superblock.byteSize == 13_013_876_736)
        #expect(superblock.volumeName == "rootfs")
        #expect(!superblock.hasExternalJournal)
        #expect(superblock.features.contains("extent"))
        #expect(superblock.unknownFeatures.isEmpty)
    }

    @Test("Output with no superblock in it yields nothing rather than a wrong answer")
    func rejectsNonExtOutput() {
        #expect(E2fsprogs.parseSuperblock("dumpe2fs: Bad magic number in super-block") == nil)
    }

    @Test("An unclean filesystem is reported as such")
    func detectsUnclean() throws {
        let text = dumpe2fs.replacingOccurrences(
            of: "Filesystem state:         clean",
            with: "Filesystem state:         clean with errors")
        let superblock = try #require(E2fsprogs.parseSuperblock(text))
        #expect(superblock.filesystemState == "clean with errors")
    }

    @Test("An external journal is visible in the superblock")
    func detectsExternalJournal() throws {
        let text = dumpe2fs.replacingOccurrences(
            of: "Journal UUID:             <none>",
            with: "Journal UUID:             1111-2222")
        let superblock = try #require(E2fsprogs.parseSuperblock(text))
        #expect(superblock.hasExternalJournal)
    }

    @Test("A feature this build does not know about is singled out")
    func flagsUnknownFeatures() throws {
        let text = dumpe2fs.replacingOccurrences(
            of: "flex_bg", with: "flex_bg some_future_feature")
        let superblock = try #require(E2fsprogs.parseSuperblock(text))
        #expect(superblock.unknownFeatures == ["some_future_feature"])
    }

    @Test("resize2fs -P gives up its estimate in filesystem blocks")
    func parsesMinimum() {
        let text = """
            resize2fs 1.47.1 (20-May-2024)
            Estimated minimum size of the filesystem: 612443
            """
        #expect(E2fsprogs.parseMinimumBlocks(text) == 612_443)
        #expect(E2fsprogs.parseMinimumBlocks("resize2fs: No such file or directory") == nil)
    }

    @Test("The percentage e2fsprogs prints is turned into a fraction")
    func parsesProgress() {
        #expect(E2fsprogs.parseProgress("Pass 1: Checking inodes  42.5%") == 0.425)
        #expect(E2fsprogs.parseProgress("100%") == 1.0)
        #expect(E2fsprogs.parseProgress("Pass 1: Checking inodes") == nil)
        #expect(E2fsprogs.parseProgress("120%") == nil)
    }
}
