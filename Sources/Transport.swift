//
//  Transport.swift
//  Embassy
//
//  Created by Fang-Pen Lin on 5/21/16.
//  Copyright © 2016 Fang-Pen Lin. All rights reserved.
//

import Foundation

protocol TransportDelegate:class {
    func closedCallback(_ reason: Transport.CloseReason) -> Void
    func readDataCallback(_ data:Data) -> Void
}

public final class Transport {
    enum CloseReason {
        /// Connection closed by peer
        case byPeer
        /// Connection closed by ourselve
        case byLocal
        
        var isByPeer: Bool {
            if case .byPeer = self {
                return true
            }
            return false
        }
        
        var isByLocal: Bool {
            if case .byLocal = self {
                return true
            }
            return false
        }
    }
    
    /// Size for recv
    static let recvChunkSize = 1024
    
    /// Is this transport closed or not
    private(set) var closed: Bool = false
    /// Is this transport closing
    private(set) var closing: Bool = false
    weak var delegate:TransportDelegate?
    
    private let socket: TCPSocket
    private let eventLoop: EventLoop
    // buffer for sending data out
    private var outgoingBuffer = Data()
    // is reading enabled or not
    private var reading: Bool = true
    
    init(
        socket: TCPSocket,
        eventLoop: EventLoop,
        delegate:TransportDelegate? = nil
    ) {
        socket.ignoreSigPipe = true
        self.socket = socket
        self.eventLoop = eventLoop
        self.delegate = delegate
        try? eventLoop.setReader(socket.fileDescriptor, callback: handleRead)
    }
    
    deinit {
        try? eventLoop.removeReader(socket.fileDescriptor)
        eventLoop.removeWriter(socket.fileDescriptor)
    }
    
    /// Send data to peer (append in buffer and will be sent out later)
    ///  - Parameter data: data to send
    func write(data: Data) throws{
        // ensure we are not closed nor closing
        guard !closed && !closing else {
            // TODO: or raise error?
            throw OSError.ioError(number: EPIPE, message: "connection closed")
        }
        // TODO: more efficient way to handle the outgoing buffer?
        outgoingBuffer.append(data)
        handleWrite()
    }
    
    /// Send string with UTF8 encoding to peer
    ///  - Parameter string: string to send as UTF8
    func write(string: String) throws{
        try write(data: Data(string.utf8))
    }
    
    /// Flush outgoing data and close the transport
    func close() {
        // ensure we are not closed nor closing
        guard !closed && !closing else {
            // TODO: or raise error?
            return
        }
        closing = true
        handleWrite()
    }
    
    func resume(reading: Bool) {
        // switch from not-reading to reading
        if reading && !self.reading {
            // call handle read later to check is there data available for reading
            eventLoop.call { [unowned self] in
                self.handleRead()
            }
        }
        self.reading = reading
    }
    
    private func closedByPeer() {
        closed = true
        try? eventLoop.removeReader(socket.fileDescriptor)
        eventLoop.removeWriter(socket.fileDescriptor)
        self.delegate?.closedCallback(.byPeer)
        socket.close()
    }
    
    private func handleRead() {
        // ensure we are not closed
        guard !closed else {
            return
        }
        guard reading else {
            return
        }
        var data: Data!
        do {
            data = try socket.recv(size: Transport.recvChunkSize)
        } catch OSError.ioError(let number, _) {
            guard number != EAGAIN else {
                // if it's EAGAIN, it means no data to be read for now, just return
                // (usually means that this function was called by resumeReading)
                return
            }
            fatalError("Failed to read, errno=\(errno), message=\(lastErrorDescription())")
        } catch {
            fatalError("Failed to read")
        }
        guard data.count > 0 else {
            closedByPeer()
            return
        }
        // ensure we are not closing
        guard !closing else {
            return
        }
        self.delegate?.readDataCallback(data)
    }
    
    private func handleWrite() {
        // ensure we are not closed
        guard !closed else {
            return
        }
        // ensure we have something to write
        guard outgoingBuffer.count > 0 else {
            if closing {
                closed = true
                eventLoop.removeWriter(socket.fileDescriptor)
                try? eventLoop.removeReader(socket.fileDescriptor)
                self.delegate?.closedCallback(.byLocal)
                socket.close()
            }
            return
        }
        do {
            let sentBytes = try socket.send(data: outgoingBuffer)
            outgoingBuffer.removeFirst(sentBytes)
            if outgoingBuffer.count > 0 {
                // Not all was written; register write handler.
                eventLoop.setWriter(socket.fileDescriptor, callback: handleWrite)
            } else {
                eventLoop.removeWriter(socket.fileDescriptor)
                if closing {
                    closed = true
                   try? eventLoop.removeReader(socket.fileDescriptor)
                    //                    if let callback = closedCallback {
                    //                        callback(.byLocal)
                    //                    }
                    self.delegate?.closedCallback(.byLocal)
                    socket.close()
                }
            }
        } catch let OSError.ioError(number, message) {
            switch number {
            case EAGAIN:
                fallthrough
                // Apparently on macOS EPROTOTYPE can be returned when the socket is not
                // fully shutdown (as an EPIPE would indicate). Here we treat them
                // essentially the same since we just tear the transport down anyway.
            // http://erickt.github.io/blog/2014/11/19/adventures-in-debugging-a-potential-osx-kernel-bug/
            case EPROTOTYPE:
                fallthrough
            case EPIPE:
                closedByPeer()
                
            default:
                fatalError("Failed to send, errno=\(number), message=\(message)")
            }
        } catch {
            fatalError("Failed to send")
        }
    }
}
