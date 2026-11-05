import JournalUI
import SwiftUI

/// The simple voice memo recorder: a timer, live level bars, pause, and stop to save.
/// The full-screen recorder with transcripts comes in Phase 5.
struct AudioRecorderSheet: View {
    /// Called with the finished file and when recording started.
    var onSave: (URL, Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var recorder = AudioRecorder()
    @State private var errorMessage: String?
    @State private var isConfirmingDiscard = false
    @State private var hasStarted = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer(minLength: 0)
                Text(Duration.seconds(recorder.elapsed).formatted(.time(pattern: .minuteSecond)))
                    .font(.system(size: 56, weight: .light, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                    .accessibilityLabel(Text("Recorded \(Duration.seconds(recorder.elapsed).formatted(.units(allowed: [.minutes, .seconds], width: .wide)))"))
                LevelBars(levels: recorder.levels, isActive: recorder.state == .recording)
                    .frame(height: 56)
                    .padding(.horizontal, 24)
                Spacer(minLength: 0)
                controls
                Text(recorder.state == .paused ? LocalizedStringKey("Paused") : "Tap stop to save the recording to this entry.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 20)
            .navigationTitle("New Recording")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { cancel() }
                }
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(recorder.state != .idle)
        .confirmationDialog("Discard this recording?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
            Button("Discard Recording", role: .destructive) {
                recorder.discard()
                dismiss()
            }
            Button("Keep Recording", role: .cancel) {}
        }
        .alert("Recording failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil; dismiss() } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        // DECISION: recording starts as soon as the sheet opens, since tapping Add Audio already
        // says you want to record. The permission prompt (first time only) comes before the sheet.
        .task {
            guard !hasStarted else { return }
            hasStarted = true
            do {
                try recorder.start()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .onDisappear {
            // Closed some other way (for example the app locked): never leave the mic running.
            if recorder.state != .idle { recorder.discard() }
        }
    }

    private var controls: some View {
        HStack(spacing: 48) {
            Button {
                recorder.state == .paused ? recorder.resume() : recorder.pause()
            } label: {
                Label(recorder.state == .paused ? LocalizedStringKey("Resume") : "Pause",
                      systemImage: recorder.state == .paused ? "record.circle" : "pause.fill")
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .frame(width: 56, height: 56)
                    .background(.fill.tertiary, in: .circle)
            }
            .disabled(recorder.state == .idle)

            Button(action: stopAndSave) {
                ZStack {
                    Circle()
                        .strokeBorder(.secondary, lineWidth: 3)
                        .frame(width: 76, height: 76)
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.red)
                        .frame(width: 30, height: 30)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Stop and Save"))
            }
            .disabled(recorder.state == .idle)

            // Balances the pause button so stop sits in the middle.
            Color.clear.frame(width: 56, height: 56)
        }
        .buttonStyle(.plain)
    }

    private func stopAndSave() {
        let started = recorder.startedAt ?? .now
        if let url = recorder.finish() {
            onSave(url, started)
        }
        dismiss()
    }

    private func cancel() {
        // A second or two of audio isn't worth asking about.
        if recorder.state == .idle || recorder.elapsed < 3 {
            recorder.discard()
            dismiss()
        } else {
            isConfirmingDiscard = true
        }
    }
}

/// Bars that scroll from right to left with the microphone level.
private struct LevelBars: View {
    let levels: [Float]
    let isActive: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(isActive ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity)
                    .frame(height: max(3, CGFloat(level) * 56))
            }
        }
        .frame(maxHeight: .infinity)
        .animation(.linear(duration: 0.05), value: levels)
        .accessibilityHidden(true)
    }
}

#Preview {
    Color.black.sheet(isPresented: .constant(true)) {
        AudioRecorderSheet { _, _ in }
    }
}
