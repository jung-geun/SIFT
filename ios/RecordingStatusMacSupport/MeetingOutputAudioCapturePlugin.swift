import Foundation
import CoreAudio
import AVFoundation
import AppKit
import Darwin

/// Pure ownership checks shared by detection and capture. Bundle-name prefixes alone
/// are not ownership: a helper must execute inside this app and descend from this launch.
nonisolated enum MeetingOutputProcessOwnership {
    struct Process: Equatable, Sendable {
        let pid: Int32
        let parentPID: Int32
        let startSeconds: UInt64
        let startMicroseconds: UInt64
        let executablePath: String
    }
    struct Application: Equatable, Sendable {
        let process: Process
        let bundleIdentifier: String
        let bundlePath: String
    }
    struct AudioProcess: Equatable, Sendable {
        let objectID: AudioObjectID
        let bundleIdentifier: String
        let process: Process
    }
    struct OwnedProcess: Equatable, Sendable {
        let audio: AudioProcess
        let ancestry: [Process]
    }
    struct Selection: Equatable, Sendable {
        let application: Application
        let processes: [OwnedProcess]
    }

    static func owned(_ audio: AudioProcess, by application: Application,
                      readProcess: (Int32) -> Process?) -> OwnedProcess? {
        guard audio.objectID != 0, readProcess(audio.process.pid) == audio.process,
              audio.process.executablePath.hasPrefix(application.bundlePath + "/") else { return nil }
        var current = audio.process
        var ancestry: [Process] = []
        var visited = Set<Int32>()
        while visited.insert(current.pid).inserted {
            ancestry.append(current)
            if current.pid == application.process.pid {
                guard current == application.process else { return nil }
                return OwnedProcess(audio: audio, ancestry: ancestry)
            }
            guard current.parentPID > 1, let parent = readProcess(current.parentPID) else { return nil }
            current = parent
        }
        return nil
    }

    static func selection(for application: Application, audioProcesses: [AudioProcess],
                          readProcess: (Int32) -> Process?) -> Selection? {
        guard readProcess(application.process.pid) == application.process else { return nil }
        let processes = audioProcesses.compactMap { owned($0, by: application, readProcess: readProcess) }
            .sorted { $0.audio.objectID < $1.audio.objectID }
        guard !processes.isEmpty else { return nil }
        return Selection(application: application, processes: processes)
    }
}

/// libproc start times distinguish a live process from a reused PID; canonical paths
/// prevent a sibling bundle or symlink outside the approved app from becoming a helper.
nonisolated enum MeetingOutputProcessMetadata {
    static func process(_ pid: Int32) -> MeetingOutputProcessOwnership.Process? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_pid == UInt32(pid) else { return nil }
        // sys/proc_info.h defines PROC_PIDPATHINFO_MAXSIZE as (4 * MAXPATHLEN);
        // Swift cannot import that expression macro, so spell out its SDK bound.
        let pathCapacity = 4 * Int(MAXPATHLEN)
        var path = [CChar](repeating: 0, count: pathCapacity)
        guard proc_pidpath(pid, &path, UInt32(pathCapacity)) > 0 else { return nil }
        let executable = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().standardizedFileURL.path
        var current = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &current, size) == size,
              current.pbi_pid == info.pbi_pid, current.pbi_ppid == info.pbi_ppid,
              current.pbi_start_tvsec == info.pbi_start_tvsec,
              current.pbi_start_tvusec == info.pbi_start_tvusec else { return nil }
        return .init(pid: pid, parentPID: Int32(info.pbi_ppid), startSeconds: info.pbi_start_tvsec,
                     startMicroseconds: info.pbi_start_tvusec, executablePath: executable)
    }

    static func application(_ pid: Int32) -> MeetingOutputProcessOwnership.Application? {
        guard pid != getpid(), let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              let bundleID = app.bundleIdentifier, !bundleID.isEmpty,
              let url = app.bundleURL?.resolvingSymlinksInPath().standardizedFileURL,
              url.pathExtension == "app", let bundle = Bundle(url: url), bundle.bundleIdentifier == bundleID,
              let executable = bundle.executableURL?.resolvingSymlinksInPath().standardizedFileURL.path,
              let process = process(pid), process.executablePath == executable else { return nil }
        return .init(process: process, bundleIdentifier: bundleID, bundlePath: url.path)
    }
}

/// A private process tap reads a device stream without rerouting or muting playback.
@objc(SIFTMeetingOutputAudioCapturePlugin)
nonisolated final class MeetingOutputAudioCapturePlugin: NSObject, MeetingOutputAudioCaptureBridging, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.sift.meeting.output-tap", qos: .userInitiated)
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var io: AudioDeviceIOProcID?
    private var format = AudioStreamBasicDescription()
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var completion: (@Sendable (NSError?) -> Void)?
    private var failure: (@Sendable (NSError) -> Void)?
    private var generation = UUID()
    private var running = false
    private var processMonitor: DispatchSourceTimer?

    required override init() { super.init() }

    private func error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "SIFT.OutputAudioCapture", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private func check(_ status: OSStatus) throws {
        guard status == noErr else {
            throw error(Int(status), "Output audio capture was not authorized or could not start. Check System Settings → Privacy & Security → Screen & System Audio Recording, then select the output again.")
        }
    }
    private func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private func scalar<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) throws -> T {
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        var property = address(selector)
        try withUnsafeMutableBytes(of: &value) { bytes in
            try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, bytes.baseAddress!))
        }
        return value
    }
    private func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
        var property = address(selector, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size))
        var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try values.withUnsafeMutableBytes { bytes in
            if let base = bytes.baseAddress { try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, base)) }
        }
        return values
    }
    private func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var property = address(selector)
        try withUnsafeMutablePointer(to: &value) { pointer in
            try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, pointer))
        }
        guard let value else { throw error(2, "The selected output has no name or identifier.") }
        return value.takeRetainedValue() as String
    }
    private func routes() throws -> [[String: Any]] {
        let defaultID = try scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0))
        return try objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).flatMap { device -> [[String: Any]] in
            let streams = try objects(device, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
            guard !streams.isEmpty else { return [] }
            let transport = try scalar(device, kAudioDevicePropertyTransportType, initial: UInt32(0))
            // Private aggregate/tap devices and virtual loopback drivers are not physical outputs.
            guard transport != kAudioDeviceTransportTypeAggregate, transport != kAudioDeviceTransportTypeVirtual else { return [] }
            let uid = try string(device, kAudioDevicePropertyDeviceUID)
            let name = try string(device, kAudioObjectPropertyName)
            return streams.enumerated().map { index, _ in
                ["uid": uid, "name": streams.count > 1 ? "\(name) · \(index + 1)" : name,
                 "stream": index, "device": device, "default": device == defaultID]
            }
        }
    }
    func outputDevices() throws -> [[String: Any]] { try queue.sync { try routes() } }

    @available(macOS 14.2, *)
    private func selectedProcesses(for application: MeetingOutputProcessOwnership.Application) throws -> MeetingOutputProcessOwnership.Selection {
        guard MeetingOutputProcessMetadata.application(application.process.pid) == application else {
            throw error(3, "The detected meeting app changed. Select the meeting source again.")
        }
        let clients = try objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
            .compactMap { object -> MeetingOutputProcessOwnership.AudioProcess? in
                guard let pid = try? scalar(object, kAudioProcessPropertyPID, initial: Int32(0)),
                      let process = MeetingOutputProcessMetadata.process(pid),
                      let bundle = try? string(object, kAudioProcessPropertyBundleID) else { return nil }
                return .init(objectID: object, bundleIdentifier: bundle, process: process)
            }
        // Include this app's registered audio clients even between utterances. Never
        // replace an empty/unknown membership with an all-process tap.
        guard let selection = MeetingOutputProcessOwnership.selection(for: application, audioProcesses: clients,
                                                                       readProcess: MeetingOutputProcessMetadata.process),
              MeetingOutputProcessMetadata.application(application.process.pid) == application else {
            throw error(3, "The detected meeting app has no verified audio clients. Select the meeting source again.")
        }
        return selection
    }

    func start(deviceUID: String?, streamIndex: UInt32, processID: Int32,
               receive: @escaping @Sendable (UnsafeRawPointer, UnsafeRawPointer, Double) -> Void,
               failed: @escaping @Sendable (NSError) -> Void, completion: @escaping @Sendable (NSError?) -> Void) {
        queue.async { [self] in
            teardown()
            self.completion = completion
            failure = failed
            let ticket = generation
            do {
                guard #available(macOS 14.2, *) else { throw error(1, "Output capture requires macOS 14.2 or later.") }
                let available = try routes()
                guard let route = available.first(where: { route in
                    (deviceUID.map { route["uid"] as? String == $0 } ?? (route["default"] as? Bool == true))
                        && (route["stream"] as? Int == Int(streamIndex))
                }), let uid = route["uid"] as? String, let device = route["device"] as? UInt32 else {
                    throw error(2, "The selected output device or stream is unavailable. Select an available output; playback has not been changed.")
                }
                let description = CATapDescription()
                description.name = "SIFT meeting output"
                description.uuid = UUID()
                description.isPrivate = true
                description.muteBehavior = .unmuted
                description.isMixdown = false
                description.deviceUID = uid
                description.stream = UInt(streamIndex)
                let processSelection: MeetingOutputProcessOwnership.Selection?
                if processID > 0 {
                    guard let application = MeetingOutputProcessMetadata.application(processID) else {
                        throw error(3, "The detected meeting app is unavailable. Select the meeting source again.")
                    }
                    let selection = try selectedProcesses(for: application)
                    processSelection = selection
                    description.processes = selection.processes.map { $0.audio.objectID }
                    description.isExclusive = false
                } else {
                    processSelection = nil
                    description.processes = []
                    description.isExclusive = true
                }
                try check(AudioHardwareCreateProcessTap(description, &tap))
                format = try scalar(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
                guard format.mSampleRate > 0, format.mBytesPerFrame > 0 else { throw error(4, "The selected output has no supported PCM stream.") }
                guard let pcmFormat = AVAudioFormat(streamDescription: &format), pcmFormat.commonFormat != .otherFormat else {
                    throw error(4, "The selected output has no supported PCM stream.")
                }
                let specification: [String: Any] = [
                    kAudioAggregateDeviceNameKey: "SIFT private meeting capture",
                    kAudioAggregateDeviceUIDKey: UUID().uuidString,
                    kAudioAggregateDeviceIsPrivateKey: true,
                    // Do not make AudioDeviceStart wait for a process to produce audio.
                    kAudioAggregateDeviceTapAutoStartKey: false,
                    kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                                      kAudioSubTapDriftCompensationKey: true]]
                ]
                try check(AudioHardwareCreateAggregateDevice(specification as CFDictionary, &aggregate))
                try check(AudioDeviceCreateIOProcIDWithBlock(&io, aggregate, queue) { [weak self] _, input, inputTime, _, _ in
                    guard let self, self.running, self.generation == ticket else { return }
                    guard inputTime.pointee.mFlags.contains(.hostTimeValid) else { return }
                    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                    guard buffers.contains(where: { $0.mData != nil && $0.mDataByteSize > 0 }) else { return }
                    let ready = self.completion
                    self.completion = nil
                    ready?(nil)
                    withUnsafePointer(to: &self.format) { formatPointer in
                        receive(UnsafeRawPointer(input), UnsafeRawPointer(formatPointer), AVAudioTime.seconds(forHostTime: inputTime.pointee.mHostTime))
                    }
                })
                running = true
                try check(AudioDeviceStart(aggregate, io))
                try listen(device, selector: kAudioDevicePropertyDeviceIsAlive, ticket: ticket)
                try listen(device, selector: kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput, ticket: ticket)
                try listen(device, selector: kAudioDevicePropertyNominalSampleRate, ticket: ticket)
                let streams = try objects(device, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
                guard Int(streamIndex) < streams.count else { throw error(2, "The selected output stream was removed.") }
                try listen(streams[Int(streamIndex)], selector: kAudioStreamPropertyVirtualFormat, ticket: ticket)
                try listen(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDevices, ticket: ticket,
                           expectedDeviceUID: uid, streamIndex: streamIndex)
                if deviceUID == nil { try listen(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice, ticket: ticket) }
                if let processSelection {
                    try listen(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyProcessObjectList,
                               ticket: ticket, processSelection: processSelection)
                    // Reparenting or PID reuse need not emit a HAL topology event.
                    let monitor = DispatchSource.makeTimerSource(queue: queue)
                    monitor.schedule(deadline: .now() + 1, repeating: 1)
                    monitor.setEventHandler { [weak self] in
                        guard let self, self.generation == ticket, self.running else { return }
                        self.validate(processSelection)
                    }
                    processMonitor = monitor
                    monitor.resume()
                    validate(processSelection)
                }
            } catch { fail(error as NSError) }
        }
    }
    @available(macOS 14.2, *)
    private func validate(_ selection: MeetingOutputProcessOwnership.Selection) {
        guard (try? selectedProcesses(for: selection.application)) != selection else { return }
        fail(error(6, "The selected meeting app or its audio clients changed. Capture stopped for this source; explicitly select it again. Playback has not been changed."))
    }
    @available(macOS 14.2, *)
    private func listen(_ object: AudioObjectID, selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, ticket: UUID,
                        processSelection: MeetingOutputProcessOwnership.Selection? = nil,
                        expectedDeviceUID: String? = nil, streamIndex: UInt32 = 0) throws {
        var property = address(selector, scope: scope)
        let callback: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.generation == ticket, self.running else { return }
            if let expectedDeviceUID,
               let available = try? self.routes(), available.contains(where: {
                   $0["uid"] as? String == expectedDeviceUID && $0["stream"] as? Int == Int(streamIndex)
               }) { return }
            if let processSelection {
                self.validate(processSelection)
                return
            }
            self.fail(self.error(6, "The selected output route, stream, or meeting app changed. Capture stopped for this source; explicitly select it again. Playback has not been changed."))
        }
        try check(AudioObjectAddPropertyListenerBlock(object, &property, queue, callback))
        listeners.append((object, property, callback))
    }
    private func fail(_ error: NSError) {
        let pending = completion
        let failed = failure
        completion = nil
        failure = nil
        teardown()
        if let pending { pending(error) } else { failed?(error) }
    }
    private func teardown() {
        running = false
        generation = UUID()
        processMonitor?.cancel()
        processMonitor = nil
        for entry in listeners {
            var property = entry.1
            AudioObjectRemovePropertyListenerBlock(entry.0, &property, queue, entry.2)
        }
        listeners.removeAll()
        if aggregate != 0, let io { AudioDeviceStop(aggregate, io); AudioDeviceDestroyIOProcID(aggregate, io) }
        io = nil
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
        if tap != 0 { if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tap) }; tap = 0 }
    }
    func stop() {
        // HAL teardown can block; UI cancellation closes the host admission gate first.
        // The queue retains this object until its SDK resources have been released.
        queue.async { [self] in shutdown() }
    }
    private func shutdown() {
        let pending = completion
        completion = nil
        failure = nil
        teardown()
        pending?(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }
}
