import Darwin
import Testing
@testable import Tempra

@Suite("Process network activity probe")
struct ProcessNetworkActivityProbeTests {
    @Test("Connected TCP sockets are latency-sensitive")
    func connectedTCPSocketIsProtected() {
        var socket = socket_fdinfo()
        socket.psi.soi_family = AF_INET
        socket.psi.soi_protocol = IPPROTO_TCP
        socket.psi.soi_state = Int16(SOI_S_ISCONNECTED)
        socket.psi.soi_proto.pri_tcp.tcpsi_state = TCPS_ESTABLISHED

        #expect(ProcessNetworkActivityProbe.isLatencySensitive(socketInfo: socket))
    }

    @Test("Listening TCP sockets do not imply active traffic")
    func listeningTCPSocketIsNotProtected() {
        var socket = socket_fdinfo()
        socket.psi.soi_family = AF_INET6
        socket.psi.soi_protocol = IPPROTO_TCP
        socket.psi.soi_proto.pri_tcp.tcpsi_state = TCPS_LISTEN

        #expect(!ProcessNetworkActivityProbe.isLatencySensitive(socketInfo: socket))
    }

    @Test("Internet UDP sockets are treated conservatively")
    func udpSocketIsProtected() {
        var socket = socket_fdinfo()
        socket.psi.soi_family = AF_INET
        socket.psi.soi_protocol = IPPROTO_UDP

        #expect(ProcessNetworkActivityProbe.isLatencySensitive(socketInfo: socket))
    }

    @Test("Local IPC sockets are not classified as network activity")
    func localSocketIsNotProtected() {
        var socket = socket_fdinfo()
        socket.psi.soi_family = AF_UNIX

        #expect(!ProcessNetworkActivityProbe.isLatencySensitive(socketInfo: socket))
    }

    @Test("A stale or missing identity is protected")
    func staleIdentityIsUnknown() {
        let identity = ProcessIdentity(
            pid: Int32.max,
            startTimeMicroseconds: UInt64.max
        )

        #expect(ProcessNetworkActivityProbe().activity(for: identity) == .unknown)
    }
}
