// recorder <out.wav>
//
// Records the default mic to a 16 kHz mono WAV until it is told to stop.
// Prints the current loudness to stdout so the caller can draw a meter.
//
// Why not just use ffmpeg: `ffmpeg -f avfoundation` drops about 10% of the
// audio as it goes (measured: 0.41s lost from 3s, 1.50s lost from 12s), which
// mangles words all through the take. This loses ~0.11s at the start and
// nothing after that.

import AVFoundation
import Accelerate
import Darwin
import Dispatch
import Foundation

let sampleRate = 16000.0
let meterInterval = 0.033   // how often to print a loudness reading
let maxSeconds = 600.0      // hard limit, whatever the caller does
let watchdogInterval = 2.0

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("recorder: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 2 else { die("usage: recorder <out.wav>") }
let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])

let engine = AVAudioEngine()
let input = engine.inputNode
let hardwareFormat = input.outputFormat(forBus: 0)

guard hardwareFormat.sampleRate > 0 else { die("no input device available") }

// The mic runs at its own rate, so everything is resampled down to 16 kHz.
guard let tapFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                    sampleRate: sampleRate,
                                    channels: 1,
                                    interleaved: false),
      let converter = AVAudioConverter(from: hardwareFormat, to: tapFormat)
else { die("cannot resample \(hardwareFormat.sampleRate) Hz to \(sampleRate) Hz") }

// Optional so it can be closed on demand. AVAudioFile writes the WAV header
// when it is released, and calling exit() alone would leave an empty file.
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

let ratio = sampleRate / hardwareFormat.sampleRate
var framesWritten: AVAudioFramePosition = 0
var lastMeter = Date.distantPast

// This runs on the audio thread, so it stays cheap: convert, write, measure.
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

    guard Date().timeIntervalSince(lastMeter) >= meterInterval,
          let samples = out.floatChannelData?[0] else { return }
    lastMeter = Date()

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

let stop = {
    input.removeTap(onBus: 0)   // returns only once the tap is done
    engine.stop()
    file = nil                  // closes the file and writes the WAV header
    FileHandle.standardError.write(
        Data(String(format: "%.3f\n", Double(framesWritten) / sampleRate).utf8))
    exit(0)
}

// Nobody is guaranteed to send us a stop signal. If the parent dies we get
// adopted by launchd, and without this we would hold the mic open forever and
// grow the file at 32 KB/s.
let watchdog = DispatchSource.makeTimerSource(queue: .main)
watchdog.schedule(deadline: .now() + watchdogInterval, repeating: watchdogInterval)
watchdog.setEventHandler {
    if getppid() == 1 || Double(framesWritten) / sampleRate >= maxSeconds { stop() }
}
watchdog.resume()

// Ignore the signals at the C level so the Dispatch sources can own them.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)

let signals = [SIGTERM, SIGINT].map { sig -> DispatchSourceSignal in
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler(handler: stop)
    source.resume()
    return source
}
_ = signals

dispatchMain()
