import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import HorizonNav

struct PhoneNavigationTests {
    private func point(_ x: Double, _ y: Double = 0) -> RoadPoint {
        RoadPoint(lat: y / 111_195, lon: x / 111_195)
    }

    private func route(_ positions: [RoadPoint]) -> RoadCorridor {
        var distances = [0.0]
        for (a, b) in zip(positions, positions.dropFirst()) { distances.append(distances.last! + a.distance(to: b)) }
        return RoadCorridor(points: positions, progress: distances)
    }

    private func node(_ id: Int64, _ p: RoadPoint, _ tags: [String: String]) -> OverpassRoadData.Element {
        .init(type: "node", id: id, lat: p.lat, lon: p.lon, nodes: nil, geometry: nil, tags: tags)
    }

    private func way(_ id: Int64, _ nodes: [Int64], _ geometry: [RoadPoint], _ oneWay: String? = nil) -> OverpassRoadData.Element {
        var tags = ["highway": "residential"]
        tags["oneway"] = oneWay
        return .init(type: "way", id: id, lat: nil, lon: nil, nodes: nodes, geometry: geometry, tags: tags)
    }

    @Test func directionalControlsRespectWayOrder() {
        let data = OverpassRoadData(elements: [
            node(1, point(100), ["highway": "traffic_signals", "traffic_signals:direction": "forward"]),
            node(2, point(160), ["highway": "stop", "direction": "backward"]),
            way(10, [10, 1, 2, 11], [point(0), point(100), point(160), point(240)])
        ], remark: nil)
        let east = RoadEventMatcher.match(data, corridor: route([point(0), point(240)]))
        let west = RoadEventMatcher.match(data, corridor: route([point(240), point(0)]))
        #expect(east.map(\.kind) == [.signal])
        #expect(west.map(\.kind) == [.stop])
    }

    @Test func ignoresPerpendicularApproachesAndParallelOppositeLanes() {
        let data = OverpassRoadData(elements: [
            node(1, point(110, 4), ["highway": "traffic_signals"]),
            node(2, point(150), ["highway": "stop", "direction": "forward"]),
            node(3, point(190, 4), ["highway": "traffic_signals", "traffic_signals:direction": "forward"]),
            way(10, [20, 1, 3, 21], [point(0, 4), point(110, 4), point(190, 4), point(250, 4)], "-1"),
            way(11, [30, 2, 31], [point(150, -40), point(150), point(150, 40)])
        ], remark: nil)
        #expect(RoadEventMatcher.match(data, corridor: route([point(0), point(250)])).isEmpty)
    }

    @Test func crossingBarrierUsesMappedValueAndEventsSortByDrivingDistance() {
        let data = OverpassRoadData(elements: [
            node(3, point(180), ["railway": "level_crossing", "crossing:barrier": "half"]),
            node(1, point(80), ["highway": "stop"]),
            node(2, point(125), ["highway": "traffic_signals"]),
            way(10, [20, 1, 2, 3, 21], [point(0), point(80), point(125), point(180), point(250)], "yes")
        ], remark: nil)
        let events = RoadEventMatcher.match(data, corridor: route([point(0), point(250)]))
        #expect(events.map(\.kind) == [.stop, .signal, .rail])
        #expect(events.last?.crossingBarrier == "half")
        #expect(RoadEvent.upcoming(events, progress: 90, within: 75).map(\.kind) == [.signal])
        #expect(RoadEvent.upcoming(events, progress: 200).isEmpty)
    }

    @Test func ambiguousDirectionAndMissingMembershipAreDiscarded() {
        let data = OverpassRoadData(elements: [
            node(1, point(50), ["highway": "traffic_signals"]),
            node(2, point(80), ["highway": "stop"]),
            node(3, point(100), ["railway": "level_crossing"]),
            way(10, [20, 1, 2, 21], [point(0), point(50), point(80), point(150)])
        ], remark: nil)
        #expect(RoadEventMatcher.match(data, corridor: route([point(0), point(150)])).isEmpty)
    }

    @Test func reroutedCorridorRematchesTheOriginalData() {
        let data = OverpassRoadData(elements: [
            node(1, point(110), ["highway": "traffic_signals"]),
            way(10, [20, 1, 21], [point(0), point(110), point(250)], "yes")
        ], remark: nil)
        #expect(RoadEventMatcher.match(data, corridor: route([point(0), point(250)])).count == 1)
        #expect(RoadEventMatcher.match(data, corridor: route([point(0, 13), point(250, 13)])).isEmpty)
    }

    @Test func rejectsPartialResponseAndReportsNetworkLoss() async {
        let corridor = route([point(0), point(150)])
        let partial = RoadEventService { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"elements":[],"remark":"runtime error: timeout"}"#.utf8), response)
        }
        await #expect(throws: RoadEventService.Failure.self) {
            try await partial.events(along: corridor, online: true)
        }
        let down = RoadEventService { _ in throw URLError(.timedOut) }
        await #expect(throws: URLError.self) { try await down.events(along: corridor, online: true) }
        await #expect(throws: RoadEventService.Failure.self) { try await down.events(along: corridor, online: false) }
    }

    @Test func successfulEmptyResponseRemainsUsableOffline() async throws {
        let corridor = route([point(0), point(150)])
        let service = RoadEventService { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"elements":[]}"#.utf8), response)
        }
        #expect(try await service.events(along: corridor, online: true).isEmpty)
        #expect(try await service.events(along: corridor, online: false).isEmpty)
    }

    @Test func mapSelectionKeepsOfflineMapAvailable() {
        #expect(PhoneMapSource.resolve(choice: "mapbox", online: true, mapboxAvailable: true) == .mapbox)
        #expect(PhoneMapSource.resolve(choice: "mapbox", online: true, mapboxAvailable: false) == .openstreetmap)
        #expect(PhoneMapSource.resolve(choice: "apple", online: false, mapboxAvailable: true) == .openstreetmap)
        #expect(PhoneMapSource.resolve(choice: "apple", online: true, mapboxAvailable: false) == .apple)
        #expect(PhoneMapSource.resolve(choice: "openstreetmap", online: true, mapboxAvailable: true) == .openstreetmap)
    }

    @Test func cameraWidensAtSpeedAndMovesCloserForComplexTurn() {
        let city = PhoneCameraPolicy.framing(mode: .automatic, speed: 10, fastRoad: false, maneuverDistance: nil)
        let motorway = PhoneCameraPolicy.framing(mode: .automatic, speed: 31, fastRoad: true, maneuverDistance: nil)
        let turn = PhoneCameraPolicy.framing(mode: .automatic, speed: 31, fastRoad: true, maneuverDistance: 40)
        let flat = PhoneCameraPolicy.framing(mode: .flat, speed: 20, fastRoad: false, maneuverDistance: nil)
        #expect(motorway.zoom < city.zoom)
        #expect(turn.zoom > motorway.zoom)
        #expect(turn.pitch < motorway.pitch)
        #expect(flat.pitch == 0)
        #expect(PhoneCameraPolicy.easedBearing(from: 350, to: 10, amount: 0.5) == 0)
    }
}
