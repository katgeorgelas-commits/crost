// Crossings — where and when two people's camera rolls overlap.
// One file. Same app on both phones. Flow:
//   Their phone: "Export my photos" → send the file.
//   Your phone:  "Open their file"  → list of crossings, both photos side by side.

import SwiftUI
import Photos
import CoreLocation
import UniformTypeIdentifiers

// What counts as "crossed paths". Tweak and re-run.
let maxMeters = 300.0
let maxHours = 3.0

@main
struct CrossingsApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

// MARK: - Data

// One photo. `t` is absolute time (seconds since 1970, UTC), so time zones can't mix up dates.
struct Snap: Codable {
    let id: String
    let t: Double
    let lat: Double
    let lon: Double
    var thumb: Data? = nil   // small JPEG, only in exported files
}

struct Crossing: Codable, Identifiable {
    let mine: Snap
    let theirs: Snap
    var place: String? = nil
    var tz: String? = nil    // time zone where the photos were taken
    var id: String { mine.id + "|" + theirs.id }
    var meters: Double { distance(mine, theirs) }
    var secondsApart: Double { abs(mine.t - theirs.t) }
}

func distance(_ a: Snap, _ b: Snap) -> Double {
    let p = Double.pi / 180
    let dLat = (b.lat - a.lat) * p, dLon = (b.lon - a.lon) * p
    let h = sin(dLat / 2) * sin(dLat / 2) + cos(a.lat * p) * cos(b.lat * p) * sin(dLon / 2) * sin(dLon / 2)
    return 2 * 6_371_000 * asin(min(1, sqrt(h)))
}

func myGeotaggedPhotos() -> [Snap] {
    let o = PHFetchOptions()
    o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
    var out: [Snap] = []
    PHAsset.fetchAssets(with: o).enumerateObjects { a, _, _ in
        if let loc = a.location, let d = a.creationDate {
            out.append(Snap(id: a.localIdentifier, t: d.timeIntervalSince1970,
                            lat: loc.coordinate.latitude, lon: loc.coordinate.longitude))
        }
    }
    return out
}

// Drop burst shots (same 2 min, same 100 m) so the export stays small.
func thinned(_ snaps: [Snap]) -> [Snap] {
    var out: [Snap] = []
    for s in snaps {
        if let last = out.last, s.t - last.t < 120, distance(s, last) < 100 { continue }
        out.append(s)
    }
    return out
}

func thumbnail(_ a: PHAsset) -> Data? {
    let o = PHImageRequestOptions()
    o.isSynchronous = true
    o.isNetworkAccessAllowed = true
    o.resizeMode = .fast
    var out: Data?
    PHImageManager.default().requestImage(for: a, targetSize: CGSize(width: 400, height: 400),
                                          contentMode: .aspectFill, options: o) { img, _ in
        out = img?.jpegData(compressionQuality: 0.5)
    }
    return out
}

// For each of their photos, find my closest photo in space + time. Then keep one crossing per moment.
func findCrossings(mine: [Snap], theirs: [Snap]) -> [Crossing] {
    let gap = maxHours * 3600
    var candidates: [Crossing] = []
    var start = 0
    for o in theirs {
        while start < mine.count && mine[start].t < o.t - gap { start += 1 }
        var pick: Snap?
        var pickScore = Double.infinity
        var j = start
        while j < mine.count && mine[j].t <= o.t + gap {
            let d = distance(mine[j], o)
            let score = d + abs(mine[j].t - o.t) / 10   // 10 seconds apart ≈ 1 meter apart
            if d <= maxMeters && score < pickScore { pick = mine[j]; pickScore = score }
            j += 1
        }
        if let m = pick { candidates.append(Crossing(mine: m, theirs: o)) }
    }
    var kept: [Crossing] = []
    for c in candidates.sorted(by: { $0.secondsApart < $1.secondsApart }) {
        let dupe = kept.contains { abs($0.mine.t - c.mine.t) < 6 * 3600 && distance($0.mine, c.mine) < 2000 }
        if !dupe { kept.append(c) }
    }
    return kept.sorted { $0.mine.t > $1.mine.t }
}

// MARK: - Model

@MainActor
final class Model: ObservableObject {
    @Published var crossings: [Crossing] = []
    @Published var status = ""
    @Published var busy = false
    @Published var exportURL: URL?

    let saveURL = URL.documentsDirectory.appending(path: "crossings.json")

    init() {
        if let d = try? Data(contentsOf: saveURL),
           let c = try? JSONDecoder().decode([Crossing].self, from: d) { crossings = c }
    }

    func save() { try? JSONEncoder().encode(crossings).write(to: saveURL) }

    // Lets the screen redraw during long loops.
    func breathe() async { try? await Task.sleep(nanoseconds: 1_000_000) }

    func hasFullAccess() async -> Bool {
        if await PHPhotoLibrary.requestAuthorization(for: .readWrite) == .authorized { return true }
        status = "Needs Full Access: Settings → Crossings → Photos → Full Access."
        return false
    }

    func export() async {
        guard await hasFullAccess() else { return }
        busy = true; defer { busy = false }
        exportURL = nil
        status = "Reading your photos…"
        await breathe()
        let snaps = thinned(myGeotaggedPhotos())
        var assets: [String: PHAsset] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: snaps.map(\.id), options: nil)
            .enumerateObjects { a, _, _ in assets[a.localIdentifier] = a }

        // One photo per line, written as we go so memory stays low.
        let url = FileManager.default.temporaryDirectory.appending(path: "my-photos.json")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let file = try? FileHandle(forWritingTo: url) else { status = "Couldn't create file."; return }
        let enc = JSONEncoder()
        for (i, snap) in snaps.enumerated() {
            autoreleasepool {
                var s = snap
                if let a = assets[s.id] { s.thumb = thumbnail(a) }
                if s.thumb != nil, let line = try? enc.encode(s) { try? file.write(contentsOf: line + [10]) }
            }
            if i % 25 == 0 { status = "Packing \(i) of \(snaps.count)…"; await breathe() }
        }
        try? file.close()
        exportURL = url
        status = "Done. Send this file to your person."
    }

    func importFile(_ url: URL) async {
        guard await hasFullAccess() else { return }
        busy = true; defer { busy = false }
        status = "Reading their file…"
        await breathe()
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { status = "Couldn't read that file."; return }
        let dec = JSONDecoder()
        let theirs = data.split(separator: 10)
            .compactMap { try? dec.decode(Snap.self, from: Data($0)) }
            .sorted { $0.t < $1.t }
        status = "Comparing \(theirs.count) of their photos with yours…"
        await breathe()
        crossings = findCrossings(mine: myGeotaggedPhotos(), theirs: theirs)
        save()
        status = crossings.isEmpty ? "No crossings found." : "\(crossings.count) crossings."
    }

    // Place name + local time zone, looked up once per crossing as it scrolls into view.
    func locate(_ c: Crossing) async {
        guard c.tz == nil else { return }
        let loc = CLLocation(latitude: c.mine.lat, longitude: c.mine.lon)
        guard let p = try? await CLGeocoder().reverseGeocodeLocation(loc).first,
              let i = crossings.firstIndex(where: { $0.id == c.id }) else { return }
        crossings[i].place = [p.areasOfInterest?.first ?? p.name, p.locality].compactMap { $0 }.joined(separator: ", ")
        crossings[i].tz = p.timeZone?.identifier
        save()
    }
}

// MARK: - Screens

struct ContentView: View {
    @StateObject var model = Model()
    @State var picking = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("1. Export my photos") { Task { await model.export() } }
                    if let url = model.exportURL {
                        ShareLink("Send file (AirDrop / Messages)", item: url)
                    }
                    Button("2. Open their file") { picking = true }
                    if model.busy { ProgressView() }
                    if !model.status.isEmpty {
                        Text(model.status).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .disabled(model.busy)

                ForEach(model.crossings) { c in
                    CrossingRow(c: c).task { await model.locate(c) }
                }
            }
            .navigationTitle("Crossings")
            .fileImporter(isPresented: $picking, allowedContentTypes: [.json]) { result in
                if case .success(let url) = result { Task { await model.importFile(url) } }
            }
        }
    }
}

func format(_ t: Double, _ tz: TimeZone, _ pattern: String) -> String {
    let f = DateFormatter()
    f.timeZone = tz
    f.dateFormat = pattern
    return f.string(from: Date(timeIntervalSince1970: t))
}

struct CrossingRow: View {
    let c: Crossing

    var body: some View {
        // Real time zone once looked up; until then, a rough guess from longitude (marked ≈).
        let tz = c.tz.flatMap(TimeZone.init(identifier:))
            ?? TimeZone(secondsFromGMT: Int((c.mine.lon / 15).rounded()) * 3600) ?? .gmt
        VStack(alignment: .leading, spacing: 6) {
            Text(format(c.mine.t, tz, "EEE, MMM d, yyyy")).font(.headline)
            Text(c.place ?? String(format: "%.4f, %.4f", c.mine.lat, c.mine.lon)).font(.subheadline)
            HStack(spacing: 4) {
                MyPhoto(id: c.mine.id)
                Tile(image: c.theirs.thumb.flatMap(UIImage.init(data:)))
            }
            Text("You \(format(c.mine.t, tz, "h:mm a")) · Them \(format(c.theirs.t, tz, "h:mm a")) · \(Int(c.meters)) m apart\(c.tz == nil ? " · ≈ time" : "")")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct Tile: View {
    let image: UIImage?

    var body: some View {
        Color.secondary.opacity(0.15)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct MyPhoto: View {
    let id: String
    @State private var image: UIImage?

    var body: some View {
        Tile(image: image).onAppear {
            guard image == nil,
                  let a = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return }
            let o = PHImageRequestOptions()
            o.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(for: a, targetSize: CGSize(width: 600, height: 600),
                                                  contentMode: .aspectFill, options: o) { img, _ in
                if let img { DispatchQueue.main.async { image = img } }
            }
        }
    }
}
