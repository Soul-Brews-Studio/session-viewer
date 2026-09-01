// Resources.swift — what this process is actually costing, right now.
//
// This exists because "is it working or is it stuck?" was asked repeatedly about a build
// that was working the whole time, and nothing on screen could answer it. A progress bar
// that advances slowly and a progress bar that has stopped look identical; CPU does not.
//
// SELF, NOT THE MACHINE. These read this process's own usage via Mach, rather than
// shelling out to `ps` or `top`. Two reasons, and the first is a real trap:
//
//   `ps -o %cpu` on macOS reports an average over the process's ENTIRE LIFETIME, not a
//   current reading. It showed 124.7% for this app at a moment when sampling proved every
//   thread was parked — which is exactly the sort of number that sends you looking for a
//   freeze that is not there. `top -l 2` gives an instantaneous figure, but costs a process
//   spawn and a sample interval.
//
// So: `task_info` for memory, and a sum over live threads for CPU. Both are cheap enough
// to call once a second from a view.

import Foundation
import Darwin

public struct ResourceSample {
    /// Percent of ONE core. 100 means one core saturated; on an 8-core machine the ceiling
    /// is 800, which is why this is not clamped to 100 — clamping would hide the fact that
    /// a build is using four cores.
    public let cpuPercent: Double
    /// Resident set size in bytes.
    public let residentBytes: UInt64
    /// Live threads in this process.
    public let threads: Int
}

/// Sample this process's CPU and memory. Returns nil if the kernel refuses, which is not
/// an error worth surfacing — the display simply omits the figure rather than showing a
/// zero that would read as "idle".
public func sampleOwnResources() -> ResourceSample? {
    // --- memory ---
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let memOK = withUnsafeMutablePointer(to: &info) { ptr -> Bool in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), raw, &count) == KERN_SUCCESS
        }
    }
    guard memOK else { return nil }

    // --- cpu: sum the per-thread usage ---
    //
    // `thread_basic_info.cpu_usage` is scaled by TH_USAGE_SCALE and is an instantaneous
    // figure, which is the whole point of reading it here rather than deriving a rate from
    // cumulative counters between two calls.
    var threadList: thread_act_array_t?
    var threadCount = mach_msg_type_number_t(0)
    guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
          let threads = threadList else {
        return ResourceSample(cpuPercent: 0, residentBytes: info.resident_size, threads: 0)
    }
    // The array is vm_allocate'd by the kernel and is ours to release — leaking one per
    // sample, once a second, for a window left open all day, is a real leak.
    defer {
        vm_deallocate(mach_task_self_,
                      vm_address_t(UInt(bitPattern: threads)),
                      vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride))
    }

    var total = 0.0
    for i in 0..<Int(threadCount) {
        var ti = thread_basic_info()
        // THREAD_BASIC_INFO_COUNT is a C macro and does not survive into Swift; compute it.
        var tiCount = mach_msg_type_number_t(
            MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size)
        let ok = withUnsafeMutablePointer(to: &ti) { ptr -> Bool in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(tiCount)) { raw in
                thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), raw, &tiCount) == KERN_SUCCESS
            }
        }
        guard ok, ti.flags & TH_FLAGS_IDLE == 0 else { continue }
        total += Double(ti.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
    }

    return ResourceSample(cpuPercent: total,
                          residentBytes: info.resident_size,
                          threads: Int(threadCount))
}

/// "182% cpu · 431 MB" — compact enough to sit at the end of a progress line.
public func formatResources(_ r: ResourceSample) -> String {
    "\(Int(r.cpuPercent.rounded()))% cpu · \(humanBytes(Int(r.residentBytes)))"
}
