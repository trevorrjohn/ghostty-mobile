import XCTest
@testable import GhosttyConnect

final class ItermInlineImageParserTests: XCTestCase {
    func testExtractsImageByteByByte() {
        var terminal = Data()
        var images: [ItermInlineImage] = []
        let parser = ItermInlineImageParser(onBytes: { terminal.append($0) }, onImage: { images.append($0) })
        let sequence = Data("before\u{1b}]1337;File=inline=1;width=4:AQIDBA==\u{07}after".utf8)

        sequence.forEach { parser.feed(Data([$0])) }

        XCTAssertEqual(String(decoding: terminal, as: UTF8.self), "beforeafter")
        XCTAssertEqual(images, [ItermInlineImage(options: ["inline": "1", "width": "4"], data: Data([1, 2, 3, 4]))])
    }

    func testMultipartThroughTmux() {
        var images: [ItermInlineImage] = []
        let imageParser = ItermInlineImageParser(onBytes: { _ in }, onImage: { images.append($0) })
        let tmux = TmuxPassthroughParser(onBytes: imageParser.feed)
        let inner = Array("\u{1b}]1337;File=inline=1:AQID\u{07}".utf8)
        let escaped = inner.flatMap { $0 == 0x1b ? [$0, $0] : [$0] }
        let wrapped = Data(Array("\u{1b}Ptmux;".utf8) + escaped + Array("\u{1b}\\".utf8))

        wrapped.forEach { tmux.feed(Data([$0])) }

        XCTAssertEqual(images.first?.data, Data([1, 2, 3]))
    }

    func testUnrelatedCommandPassesThrough() {
        var terminal = Data()
        let parser = ItermInlineImageParser(onBytes: { terminal.append($0) }, onImage: { _ in XCTFail() })
        let sequence = Data("\u{1b}]1337;CurrentDir=file:///tmp\u{07}".utf8)
        parser.feed(sequence)
        XCTAssertEqual(terminal, sequence)
    }
}
