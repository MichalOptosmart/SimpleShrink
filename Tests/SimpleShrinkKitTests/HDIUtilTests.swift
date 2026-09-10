// SimpleShrink — Copyright (C) 2026 OptoSmart. GPL-2.0-only, see COPYING.

import Testing

@testable import SimpleShrinkKit

@Suite("hdiutil plist decoding")
struct HDIUtilTests {
    /// Trimmed from real `hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount
    /// -plist` output. The human-readable table is deliberately never parsed; this is the
    /// shape the tool depends on, so a change in it should break a test, not an image.
    let attachOutput = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>system-entities</key>
            <array>
                <dict>
                    <key>content-hint</key>
                    <string>Windows_FAT_32</string>
                    <key>dev-entry</key>
                    <string>/dev/disk4s1</string>
                    <key>potentially-mountable</key>
                    <true/>
                </dict>
                <dict>
                    <key>content-hint</key>
                    <string>Linux</string>
                    <key>dev-entry</key>
                    <string>/dev/disk4s2</string>
                    <key>potentially-mountable</key>
                    <false/>
                </dict>
                <dict>
                    <key>content-hint</key>
                    <string>FDisk_partition_scheme</string>
                    <key>dev-entry</key>
                    <string>/dev/disk4</string>
                </dict>
            </array>
        </dict>
        </plist>
        """

    @Test("Every device node is read out of the plist")
    func decodesEntities() throws {
        let entities = try HDIUtil.parseSystemEntities(plist: attachOutput)
        #expect(entities.count == 3)
        #expect(entities[0].contentHint == "Windows_FAT_32")
    }

    @Test("Slices and the whole disk are told apart")
    func findsDevices() throws {
        let entities = try HDIUtil.parseSystemEntities(plist: attachOutput)
        let attachment = AttachedImage(
            imagePath: .init(filePath: "/tmp/pi.img"), entities: entities, detachesOnClose: false)
        #expect(attachment.wholeDisk == "/dev/disk4")
        #expect(attachment.device(forPartition: 1) == "/dev/disk4s1")
        #expect(attachment.device(forPartition: 2) == "/dev/disk4s2")
        #expect(attachment.device(forPartition: 3) == nil)
    }

    @Test("The 's' in 'disk' is not mistaken for a slice marker")
    func sliceIndexIsStrict() {
        #expect(AttachedEntity(devEntry: "/dev/disk4", contentHint: nil, mountPoint: nil).sliceIndex == nil)
        #expect(AttachedEntity(devEntry: "/dev/disk12s3", contentHint: nil, mountPoint: nil).sliceIndex == 3)
    }

    @Test("Output that is not a plist is an error, not an empty attachment")
    func rejectsGarbage() {
        #expect(throws: ShrinkError.self) {
            try HDIUtil.parseSystemEntities(plist: "/dev/disk4  FDisk_partition_scheme")
        }
    }

    @Test("hdiutil info is searched for the attachment belonging to one image")
    func findsStaleAttachment() throws {
        let info = """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0">
            <dict>
                <key>images</key>
                <array>
                    <dict>
                        <key>image-path</key>
                        <string>/tmp/other.img</string>
                        <key>system-entities</key>
                        <array>
                            <dict><key>dev-entry</key><string>/dev/disk9</string></dict>
                        </array>
                    </dict>
                    <dict>
                        <key>image-path</key>
                        <string>/tmp/pi.img</string>
                        <key>system-entities</key>
                        <array>
                            <dict><key>dev-entry</key><string>/dev/disk4s1</string></dict>
                            <dict><key>dev-entry</key><string>/dev/disk4</string></dict>
                        </array>
                    </dict>
                </array>
            </dict>
            </plist>
            """
        #expect(try HDIUtil.parseAttachedDisks(plist: info, imagePath: "/tmp/pi.img") == ["/dev/disk4"])
        #expect(try HDIUtil.parseAttachedDisks(plist: info, imagePath: "/tmp/none.img").isEmpty)
    }
}
