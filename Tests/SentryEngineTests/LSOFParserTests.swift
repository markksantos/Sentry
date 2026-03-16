import XCTest
@testable import SentryEngine

final class LSOFParserTests: XCTestCase {

    // MARK: - Fixture Loading

    private func loadFixture() throws -> String {
        guard let url = Bundle.module.url(
            forResource: "lsof-sample-output",
            withExtension: "txt"
        ) else {
            XCTFail("Missing fixture file lsof-sample-output.txt")
            return ""
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Full Fixture Parse

    func testParseFixtureReturnsExpectedCount() throws {
        let output = try loadFixture()
        let entries = LSOFParser.parse(output)
        // Safari: 3, Chrome: 3, nginx: 2 LISTEN, mDNSResponder: 2 UDP = 10
        XCTAssertEqual(entries.count, 10, "Expected 10 connections from fixture")
    }

    // MARK: - TCP ESTABLISHED

    func testTCPEstablishedParsedCorrectly() throws {
        let output = try loadFixture()
        let entries = LSOFParser.parse(output)

        let safariConnections = entries.filter { $0.appName == "Safari" && $0.state == .established }
        XCTAssertEqual(safariConnections.count, 3)

        // Verify the first Safari connection.
        let first = safariConnections.first { $0.localPort == 52341 }
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.pid, 483)
        XCTAssertEqual(first?.protocolType, .tcp)
        XCTAssertEqual(first?.localAddress, "192.168.1.100")
        XCTAssertEqual(first?.localPort, 52341)
        XCTAssertEqual(first?.remoteAddress, "142.250.80.46")
        XCTAssertEqual(first?.remotePort, 443)
        XCTAssertEqual(first?.state, .established)
    }

    func testChromeConnectionsParsed() throws {
        let output = try loadFixture()
        let entries = LSOFParser.parse(output)

        let chrome = entries.filter { $0.appName == "Google Chrome" }
        XCTAssertEqual(chrome.count, 3)

        let timeWait = chrome.first { $0.state == .timeWait }
        XCTAssertNotNil(timeWait)
        XCTAssertEqual(timeWait?.remoteAddress, "104.244.42.65")
        XCTAssertEqual(timeWait?.remotePort, 443)
    }

    // MARK: - LISTEN State

    func testListenStateParsedCorrectly() throws {
        let output = try loadFixture()
        let entries = LSOFParser.parse(output)

        let listeners = entries.filter { $0.state == .listen }
        XCTAssertEqual(listeners.count, 2)

        let nginx8080 = listeners.first { $0.localPort == 8080 }
        XCTAssertNotNil(nginx8080)
        XCTAssertEqual(nginx8080?.appName, "nginx")
        XCTAssertEqual(nginx8080?.pid, 5678)
        XCTAssertEqual(nginx8080?.localAddress, "*")
        XCTAssertEqual(nginx8080?.remoteAddress, "*")
        XCTAssertEqual(nginx8080?.remotePort, 0)
    }

    func testListenDirectionIsInbound() throws {
        let output = try loadFixture()
        let entries = LSOFParser.parse(output)

        let listeners = entries.filter { $0.state == .listen }
        for listener in listeners {
            XCTAssertEqual(listener.direction, .inbound, "\(listener.appName) LISTEN should be inbound")
        }
    }

    // MARK: - UDP Connections

    func testUDPConnectionsParsed() throws {
        let output = try loadFixture()
        let entries = LSOFParser.parse(output)

        let udp = entries.filter { $0.protocolType == .udp }
        XCTAssertEqual(udp.count, 2)

        let mdns = udp.first { $0.localPort == 5353 }
        XCTAssertNotNil(mdns)
        XCTAssertEqual(mdns?.appName, "mDNSResponder")
        XCTAssertEqual(mdns?.pid, 9012)
        XCTAssertEqual(mdns?.state, .unknown)
        XCTAssertEqual(mdns?.localAddress, "*")
    }

    func testUDPWithRemoteAddress() throws {
        let output = try loadFixture()
        let entries = LSOFParser.parse(output)

        let dnsQuery = entries.first { $0.protocolType == .udp && $0.remotePort == 53 }
        XCTAssertNotNil(dnsQuery)
        XCTAssertEqual(dnsQuery?.remoteAddress, "8.8.8.8")
        XCTAssertEqual(dnsQuery?.localAddress, "192.168.1.100")
    }

    // MARK: - IPv6

    func testIPv6AddressesParsed() throws {
        let output = try loadFixture()
        let entries = LSOFParser.parse(output)

        // Safari IPv6 connection.
        let ipv6Connection = entries.first { $0.localAddress == "2607:f8b0:4004:800::200e" }
        XCTAssertNotNil(ipv6Connection)
        XCTAssertEqual(ipv6Connection?.appName, "Safari")
        XCTAssertEqual(ipv6Connection?.remoteAddress, "2607:f8b0:4004:836::2003")
        XCTAssertEqual(ipv6Connection?.remotePort, 443)
        XCTAssertEqual(ipv6Connection?.localPort, 52400)
        XCTAssertEqual(ipv6Connection?.state, .established)

        // nginx IPv6 LISTEN.
        let ipv6Listen = entries.first { $0.localAddress == "::1" && $0.localPort == 8443 }
        XCTAssertNotNil(ipv6Listen)
        XCTAssertEqual(ipv6Listen?.appName, "nginx")
        XCTAssertEqual(ipv6Listen?.state, .listen)
    }

    // MARK: - Empty & Malformed Input

    func testEmptyInputReturnsEmptyArray() {
        let entries = LSOFParser.parse("")
        XCTAssertTrue(entries.isEmpty)
    }

    func testMalformedInputReturnsEmptyArray() {
        let garbage = """
        this is not valid lsof output
        random garbage
        12345
        """
        let entries = LSOFParser.parse(garbage)
        XCTAssertTrue(entries.isEmpty)
    }

    func testPartialProcessBlockSkipped() {
        // A process block with PID and command but no FD blocks.
        let output = """
        p100
        cmyapp
        """
        let entries = LSOFParser.parse(output)
        XCTAssertTrue(entries.isEmpty)
    }

    func testMissingProtocolSkipped() {
        // FD block without a protocol field should be skipped.
        let output = """
        p100
        cmyapp
        f5
        tIPv4
        n192.168.1.1:80->10.0.0.1:12345
        """
        let entries = LSOFParser.parse(output)
        XCTAssertTrue(entries.isEmpty)
    }

    // MARK: - Direction Inference

    func testDirectionInferenceEphemeralPortIsOutbound() {
        let direction = ConnectionEntry.inferDirection(state: .established, localPort: 52341)
        XCTAssertEqual(direction, .outbound)
    }

    func testDirectionInferenceListenIsInbound() {
        let direction = ConnectionEntry.inferDirection(state: .listen, localPort: 8080)
        XCTAssertEqual(direction, .inbound)
    }

    func testDirectionInferenceLowPortDefaultsOutbound() {
        let direction = ConnectionEntry.inferDirection(state: .established, localPort: 443)
        XCTAssertEqual(direction, .outbound)
    }

    func testDirectionInferenceOnParsedEntries() throws {
        let output = try loadFixture()
        let entries = LSOFParser.parse(output)

        // All ephemeral-port established connections should be outbound.
        let outbound = entries.filter { $0.localPort >= 49152 && $0.state == .established }
        for entry in outbound {
            XCTAssertEqual(entry.direction, .outbound, "\(entry.appName):\(entry.localPort) should be outbound")
        }
    }

    // MARK: - State Display Properties

    func testStateDisplayName() {
        XCTAssertEqual(ConnectionState.established.displayName, "Established")
        XCTAssertEqual(ConnectionState.timeWait.displayName, "Time Wait")
        XCTAssertEqual(ConnectionState.closeWait.displayName, "Close Wait")
        XCTAssertEqual(ConnectionState.listen.displayName, "Listen")
    }
}
