import SwiftUI
import CoreAudio

struct ContentView: View {
    @ObservedObject var controller: AudioEngineController

    private var autotuneBinding: Binding<Double> {
        Binding(
            get: { controller.autotuneAmount },
            set: { controller.setAutotuneAmount($0) }
        )
    }

    private var reverbBinding: Binding<Double> {
        Binding(
            get: { controller.reverbAmount },
            set: { controller.setReverbAmount($0) }
        )
    }

    private var modeBinding: Binding<AudioMode> {
        Binding(
            get: { controller.mode },
            set: { controller.setMode($0) }
        )
    }

    private var inputBinding: Binding<AudioDeviceID> {
        Binding(
            get: { controller.selectedInputDeviceID },
            set: { controller.selectInputDevice(id: $0) }
        )
    }

    private var outputBinding: Binding<AudioDeviceID> {
        Binding(
            get: { controller.selectedOutputDeviceID },
            set: { controller.selectOutputDevice(id: $0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AutoTune Live")
                .font(.system(size: 30, weight: .semibold, design: .rounded))

            Text("Starts immediately with your current macOS default mic and speaker. You can switch devices any time.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Mode", selection: modeBinding) {
                        ForEach(AudioMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack(spacing: 12) {
                        Button(controller.isRunning ? "Stop" : "Start") {
                            controller.toggleStartStop()
                        }

                        Button("Refresh Devices") {
                            controller.refreshDevices()
                        }

                        Button("Open Recordings Folder") {
                            controller.openRecordingsFolder()
                        }
                    }
                }
                .padding(.vertical, 4)
            } label: {
                Text("Transport")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Autotune Amount")
                        Spacer()
                        Text("\(Int(controller.autotuneAmount))%")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: autotuneBinding, in: 0 ... 100, step: 1)

                    HStack {
                        Text("Reverb Amount")
                        Spacer()
                        Text("\(Int(controller.reverbAmount))%")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: reverbBinding, in: 0 ... 100, step: 1)
                }
                .padding(.vertical, 4)
            } label: {
                Text("Effects")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    if controller.inputDevices.isEmpty {
                        Text("No input devices found")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Input Microphone", selection: inputBinding) {
                            ForEach(controller.inputDevices) { device in
                                Text(device.name).tag(device.id)
                            }
                        }
                    }

                    if controller.outputDevices.isEmpty {
                        Text("No output devices found")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Output Device", selection: outputBinding) {
                            ForEach(controller.outputDevices) { device in
                                Text(device.name).tag(device.id)
                            }
                        }
                    }

                    Text("Changing devices updates macOS default input/output so live audio follows your selection.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } label: {
                Text("Devices")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text(controller.statusMessage)
                        .font(.system(.body, design: .monospaced))

                    if !controller.lastRecordingPath.isEmpty {
                        Text(controller.lastRecordingPath)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            } label: {
                Text("Status")
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 480)
        .onAppear {
            controller.startIfPossible()
        }
    }
}
