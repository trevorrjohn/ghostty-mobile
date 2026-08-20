import Foundation

enum SessionState: Equatable {
    case disconnected
    case connecting
    case authenticating
    case connected
    case failed(String)
}

protocol SSHTransport: AnyObject {
    var output: AsyncThrowingStream<Data, Error> { get }
    func connect(to host: Host, secret: String?) async throws
    func write(_ data: Data) async throws
    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async throws
    func disconnect() async
}

protocol TerminalEngine: AnyObject {
    func feed(_ data: Data)
    func resize(columns: Int, rows: Int)
    func encode(text: String) -> Data
    func visibleText() -> String
}
