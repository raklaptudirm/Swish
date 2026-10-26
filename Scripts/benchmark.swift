// Times what Value's representation touches: the interpreter's loops, struct and dictionary
// updates, a pipeline's per-item path, and a value's description. Run with a release build:
//
//     swift build -c release && .build/release/swish Scripts/benchmark.swift
//
// Each case runs once warm and once timed; the numbers compare runs of the same machine only.

struct P { var x = 0; var y = 0 }

func measure(_ name: String, _ body: () -> Void) {
    body()  // warm
    let start = Date()
    body()
    let ms = Int(Date().timeIntervalSince(start) * 1000)
    print("\(name): \(ms) ms")
}

measure("arithmetic loop, 1M iterations") {
    var s = 0
    for i in 1...1_000_000 { s += i }
}

measure("struct field update, 200k iterations") {
    var p = P()
    for _ in 1...200_000 {
        p.x += 1
        p.y = p.x
    }
}

measure("list append and index, 200k iterations") {
    var xs: [Int] = []
    for i in 1...200_000 { xs.append(i) }
    var s = 0
    for i in 0..<200_000 { s += xs[i] }
}

measure("dictionary insert and lookup, 100k iterations") {
    var d: [Int: Int] = [:]
    for i in 1...100_000 { d[i] = i }
    var s = 0
    for i in 1...100_000 { s += d[i]! }
}

// Describing a value, as string interpolation does. The shell's own display path (DisplayFormatter)
// runs only for a prompt's values, so it is not timed here.
measure("describe a 5k-element list of structs") {
    let rows = (1...5_000).map { P(x: $0, y: $0) }
    let text = "\(rows)"
}

// A pipeline is a statement of its own, so it is timed here and not through `measure`.
(1...1_000) | count
let pipelineStart = Date()
(1...100_000) | map { $0 + 1 } | filter { $0 % 2 == 0 } | count
let pipelineMs = Int(Date().timeIntervalSince(pipelineStart) * 1000)
print("pipeline, 100k items through map and filter: \(pipelineMs) ms")
