import AppKit
import SwiftUI

/// The Settings window: sleep, alerts, phone.
struct SettingsView: View {
    @ObservedObject var settings: VigilSettings
    @State private var lidInstalled = LidHelper.isInstalled
    @State private var lidCurrent = LidHelper.isCurrent
    @State private var lidMessage: String?
    @State private var phoneMessage: String?

    var body: some View {
        Form {
            Section("Sleep") {
                Picker("After Claude finishes, stay awake for", selection: $settings.graceSeconds) {
                    ForEach(VigilSettings.graceChoices, id: \.self) { seconds in
                        Text(seconds < 120 ? "1 minute" : "\(seconds / 60) minutes").tag(seconds)
                    }
                }
                Toggle("Keep the screen on too (no dimming, no lock)", isOn: $settings.keepScreenOn)
                Toggle("Stay awake while a command Claude started is still running", isOn: $settings.trackBackground)
                Toggle("Let go on battery below", isOn: $settings.batteryGuard)
                if settings.batteryGuard {
                    Stepper("\(settings.batteryFloor)%", value: $settings.batteryFloor, in: 5...80, step: 5)
                }
            }
            Section {
                Toggle("Stay awake with the lid closed", isOn: $settings.lidClosed)
                    .disabled(!lidInstalled)
                HStack {
                    Text(!lidInstalled ? "Needs a small helper, installed once with your admin password."
                         : lidCurrent ? "Lid helper installed." : "An older lid helper is installed. Update it.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if lidInstalled, !lidCurrent {
                        Button("Update helper") { updateLidHelper() }
                    }
                    Button(lidInstalled ? "Remove helper" : "Install helper") { toggleLidHelper() }
                }
                if let lidMessage { Text(lidMessage).font(.caption).foregroundStyle(.secondary) }
            } header: {
                Text("Lid closed")
            } footer: {
                Text("While held, the Mac keeps running with the lid shut. If Vigil quits or crashes, normal lid sleep comes back within a minute. Below 10% on battery the helper always lets the Mac sleep.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Alerts") {
                Toggle("Mute all sounds", isOn: $settings.muted)
                soundPicker("Claude finished", selection: $settings.finishedSound)
                soundPicker("Claude needs you", selection: $settings.waitingSound)
                soundPicker("All sessions done", selection: $settings.allDoneSound)
                Toggle("Quiet hours (banners, no sounds)", isOn: $settings.quietHours)
                if settings.quietHours {
                    Picker("From", selection: $settings.quietFrom) { hourOptions }
                    Picker("To", selection: $settings.quietTo) { hourOptions }
                }
            }
            Section {
                Toggle("Send alerts to my phone", isOn: $settings.phoneAlerts)
                if settings.phoneAlerts {
                    LabeledContent("Topic") {
                        Text(settings.ntfyTopic).textSelection(.enabled).font(.system(.body, design: .monospaced))
                    }
                    HStack {
                        Button("Copy link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(settings.ntfyURL.absoluteString, forType: .string)
                        }
                        Button("Send a test") { sendTest() }
                        Button("New topic") { settings.renewTopic() }
                    }
                    if let phoneMessage { Text(phoneMessage).font(.caption).foregroundStyle(.secondary) }
                }
            } header: {
                Text("Phone")
            } footer: {
                Text("Install the free ntfy app on your phone and subscribe to the topic above. Anyone who knows the topic can read these alerts, so keep it private; New topic replaces it. Only the alert title and text are sent, through ntfy.sh.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 560)
    }

    private func soundPicker(_ label: String, selection: Binding<String>) -> some View {
        HStack {
            Picker(label, selection: selection) {
                ForEach(VigilSettings.soundChoices, id: \.self) { Text($0).tag($0) }
            }
            Button {
                NSSound(named: NSSound.Name(selection.wrappedValue))?.play()
            } label: {
                Image(systemName: "speaker.wave.2")
            }
            .buttonStyle(.borderless)
            .help("Play")
        }
    }

    private var hourOptions: some View {
        ForEach(0..<24, id: \.self) { hour in
            Text(String(format: "%02d:00", hour)).tag(hour)
        }
    }

    private func toggleLidHelper() {
        do {
            if lidInstalled {
                try LidHelper.uninstall()
                settings.lidClosed = false
                lidMessage = "Helper removed. Lid sleep is back to normal."
            } else {
                try LidHelper.install()
                lidMessage = "Helper installed. Turn on the switch above to use it."
            }
        } catch LidHelper.Failure.cancelled {
            lidMessage = nil
        } catch {
            lidMessage = "That did not work. Nothing was changed."
        }
        lidInstalled = LidHelper.isInstalled
        lidCurrent = LidHelper.isCurrent
    }

    private func updateLidHelper() {
        do {
            try LidHelper.install()
            lidMessage = "Helper updated."
        } catch LidHelper.Failure.cancelled {
            lidMessage = nil
        } catch {
            lidMessage = "That did not work. The old helper is still in place."
        }
        lidInstalled = LidHelper.isInstalled
        lidCurrent = LidHelper.isCurrent
    }

    private func sendTest() {
        phoneMessage = "Sending…"
        PhoneAlerts.send(title: "Vigil test", body: "Phone alerts work.", to: settings.ntfyURL) { ok in
            Task { @MainActor in
                phoneMessage = ok ? "Sent. It should show on your phone if you subscribed." : "Could not reach ntfy.sh."
            }
        }
    }
}
