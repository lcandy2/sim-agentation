import Foundation

// Plain BSD sockets driven by dispatch sources. Network.framework's listener
// can't bind a port that still has connections in TIME_WAIT, whatever
// allowLocalEndpointReuse says, so restarting the server right after a
// browser was connected failed for half a minute. SO_REUSEADDR doesn't.

struct SocketError: Error, CustomStringConvertible {
    let code: Int32
    var description: String { String(cString: strerror(code)) }
}

/// Accepts connections on 127.0.0.1:port.
final class Listener: @unchecked Sendable {
    private let fd: Int32
    private let source: DispatchSourceRead

    init(port: UInt16, queue: DispatchQueue, accept: @escaping @Sendable (Connection) -> Void) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError(code: errno) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, SOMAXCONN) == 0 else {
            let code = errno
            close(fd)
            throw SocketError(code: code)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        self.fd = fd
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            while true {
                let client = Darwin.accept(fd, nil, nil)
                guard client >= 0 else { break }
                accept(Connection(fd: client, queue: queue))
            }
        }
        source.resume()
    }
}

/// One accepted TCP connection. Every callback runs on `queue`; the methods
/// may be called from any thread.
final class Connection: @unchecked Sendable {
    private let fd: Int32
    private let queue: DispatchQueue
    private let reader: DispatchSourceRead
    private let writer: DispatchSourceWrite
    private var reading = false // the reader is resumed
    private var writing = false // the writer is resumed
    private var onReceive: (@Sendable (Data?, Bool, Error?) -> Void)?
    private var maximumLength = 0
    private var outbox: [(data: Data, done: @Sendable (Error?) -> Void)] = []
    private var written = 0 // bytes of outbox[0] already sent
    private var closed = false

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        writer = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        // The handlers keep the connection alive until it's cancelled, as
        // Network.framework does; the fd closes once both sources are done.
        let group = DispatchGroup()
        group.enter(); group.enter()
        reader.setCancelHandler { group.leave() }
        writer.setCancelHandler { group.leave() }
        group.notify(queue: queue) { close(fd) }
        reader.setEventHandler { self.readable() }
        writer.setEventHandler { self.flush() }
    }

    /// Calls `completion` once with the next bytes (up to `maximumLength`),
    /// or with `done` at the end of the stream.
    func receive(maximumLength: Int, completion: @escaping @Sendable (Data?, Bool, Error?) -> Void) {
        queue.async {
            guard !self.closed else { return }
            self.onReceive = completion
            self.maximumLength = maximumLength
            if !self.reading { self.reading = true; self.reader.resume() }
        }
    }

    /// Queues `data`; `completion` runs once it is all handed to the kernel.
    func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void = { _ in }) {
        queue.async {
            guard !self.closed else { return completion(SocketError(code: ECANCELED)) }
            self.outbox.append((data, completion))
            self.flush()
        }
    }

    /// Closes after whatever was already handed to the kernel is sent.
    func cancel() {
        queue.async {
            guard !self.closed else { return }
            self.closed = true
            self.onReceive = nil
            let pending = self.outbox
            self.outbox = []
            for item in pending { item.done(SocketError(code: ECANCELED)) }
            // A source must be resumed for its cancel handler to run.
            self.reader.cancel()
            if !self.reading { self.reader.resume() }
            self.writer.cancel()
            if !self.writing { self.writer.resume() }
        }
    }

    private func readable() {
        guard let completion = onReceive else { return }
        var buffer = [UInt8](repeating: 0, count: max(1, min(maximumLength, Int(reader.data))))
        let count = read(fd, &buffer, buffer.count)
        if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
        onReceive = nil
        reading = false
        reader.suspend()
        if count > 0 {
            completion(Data(buffer[..<count]), false, nil)
        } else {
            completion(nil, true, count < 0 ? SocketError(code: errno) : nil)
        }
    }

    private func flush() {
        while let (data, done) = outbox.first {
            if data.isEmpty {
                outbox.removeFirst()
                done(nil)
                continue
            }
            let count = data.withUnsafeBytes { bytes in
                write(fd, bytes.baseAddress! + written, data.count - written)
            }
            if count < 0 {
                if errno == EAGAIN || errno == EINTR {
                    if !writing { writing = true; writer.resume() }
                    return
                }
                let error = SocketError(code: errno)
                let pending = outbox
                outbox = []
                written = 0
                for item in pending { item.done(error) }
                break
            }
            written += count
            if written == data.count {
                outbox.removeFirst()
                written = 0
                done(nil)
            }
        }
        if writing && !closed { writing = false; writer.suspend() }
    }
}
