// flowrec <out.wav>
//
// Records the default input device to a 16 kHz mono 16-bit WAV until it
// receives SIGTERM or SIGINT, then flushes and exits 0.
//
// Why not ffmpeg: `ffmpeg -f avfoundation` drops ~10% of the stream on this
// machine (measured: 0.41s lost of 3s, 1.50s lost of 12s), which corrupts
// speech throughout the take rather than only at the edges.
//
// stdout carries one `<rms>` line per ~66 ms for the caller's level meter.
// stderr carries the final duration in seconds.

import AVFoundation
import Accelerate
import Darwin
import Dispatch
import Foundation

let sampleRate = 16000.0
let meterInterval = 0.066
let maxSeconds = 600.0        // hard cap, independent of any caller
let watchdogInterval = 2.0

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("flowrec: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 2 else { die("usage: flowrec <out.wav>") }
let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])

let engine = AVAudioEngine()
let input = engine.inputNode
let hardwareFormat = input.outputFormat(forBus: 0)

guard hardwareFormat.sampleRate > 0 else { die("no input device available") }

guard let tapFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                    sampleRate: sampleRate,
                                    channels: 1,
                                    interleaved: false),
      let converter = AVAudioConverter(from: hardwareFormat, to: tapFormat)
else { die("cannot resample \(hardwareFormat.sampleRate) Hz to \(sampleRate) Hz") }

// processingFormat is float32 @ 16 kHz; the file on disk is 16-bit PCM.
// Optional so it can be released on stop: AVAudioFile finalises the WAV
// header on deallocation, and exit() alone would leave a 0-frame header.
var file: AVAudioFile?
do {
    file = try AVAudioFile(forWriting: outputURL,
                           settings: [
                               AVFormatIDKey: kAudioFormatLinearPCM,
                               AVSampleRateKey: sampleRate,
                               AVNumberOfChannelsKey: 1,
                               AVLinearPCMBitDepthKey: 16,
                               AVLinearPCMIsFloatKey: false,
                               AVLinearPCMIsBigEndianKey: false,
                           ],
                           commonFormat: .pcmFormatFloat32,
                           interleaved: false)
} catch {
    die("cannot open \(outputURL.path): \(error.localizedDescription)")
}

// The tap runs on a realtime thread: no allocation-heavy work, no locks.
let ratio = sampleRate / hardwareFormat.sampleRate
var framesWritten: AVAudioFramePosition = 0
var lastMeter = Date.distantPast

input.installTap(onBus: 0, bufferSize: 1024, format: hardwareFormat) { buffer, _ in
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
    guard let out = AVAudioPCMBuffer(pcmFormat: tapFormat, frameCapacity: capacity) else { return }

    var consumed = false
    var error: NSError?
    converter.convert(to: out, error: &error) { _, status in
        if consumed {
            status.pointee = .noDataNow
            return nil
        }
        consumed = true
        status.pointee = .haveData
        return buffer
    }
    guard error == nil, out.frameLength > 0 else { return }

    do { try file?.write(from: out) } catch { return }
    framesWritten += AVAudioFramePosition(out.frameLength)

    let now = Date()
    guard now.timeIntervalSince(lastMeter) >= meterInterval,
          let samples = out.floatChannelData?[0] else { return }
    lastMeter = now

    var meanSquare: Float = 0
    vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(out.frameLength))
    print(String(format: "%.4f", sqrt(meanSquare)))
    fflush(stdout)
}

do {
    try engine.start()
} catch {
    die("cannot start audio engine: \(error.localizedDescription)")
}

// Ignore the signals at the C level so the Dispatch sources own them.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)

let stop = {
    input.removeTap(onBus: 0)   // synchronous: no tap is in flight after this
    engine.stop()
    file = nil                  // flushes and writes the final WAV header
    let seconds = Double(framesWritten) / sampleRate
    FileHandle.standardError.write(Data(String(format: "%.3f\n", seconds).utf8))
    exit(0)
}

// Nothing above guarantees a caller ever sends SIGTERM: if Hammerspoon
// reloads or crashes mid-take, this process is reparented to launchd and would
// otherwise hold the microphone open forever, growing the file at 32 KB/s.
let watchdog = DispatchSource.makeTimerSource(queue: .main)
watchdog.schedule(deadline: .now() + watchdogInterval, repeating: watchdogInterval)
watchdog.setEventHandler {
    if getppid() == 1 || Double(framesWritten) / sampleRate >= maxSeconds { stop() }
}
watchdog.resume()

let sources = [SIGTERM, SIGINT].map { sig -> DispatchSourceSignal in
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler(handler: stop)
    source.resume()
    return source
}
_ = sources

dispatchMain()
