import AnnotationCore
import AppKit
import SwiftUI
import TriCapKit

/// The annotation editor: toolbar, canvas, clip trimming, export controls.
struct EditorView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            canvas
            if model.source.isClip {
                Divider()
                clipControls
            }
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 460)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 14) {
            Picker("", selection: $model.tool) {
                ForEach(AnnotationTool.allCases) { tool in
                    Label(tool.displayName, systemImage: tool.symbolName)
                        .labelStyle(.iconOnly)
                        .tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .help("Annotation tool")

            colorSwatches

            HStack(spacing: 6) {
                Image(systemName: "lineweight")
                    .foregroundStyle(.secondary)
                Slider(value: $model.style.lineWidth, in: 1...40)
                    .frame(width: 90)
            }
            .help("Stroke width")

            if model.tool == .rectangle {
                Toggle("Fill", isOn: $model.style.filled)
                    .toggleStyle(.checkbox)
            }
            if model.tool == .mosaic {
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.3x3")
                        .foregroundStyle(.secondary)
                    Slider(value: $model.style.mosaicBlockSize, in: 4...80)
                        .frame(width: 90)
                }
                .help("Mosaic block size")
            }
            if model.tool == .text {
                HStack(spacing: 6) {
                    Image(systemName: "textformat.size")
                        .foregroundStyle(.secondary)
                    Slider(value: $model.style.fontSize, in: 10...160)
                        .frame(width: 90)
                }
                .help("Text size")
            }

            Spacer()

            Button {
                model.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!model.document.canUndo)
            .keyboardShortcut("z", modifiers: .command)
            .help("Undo")

            Button {
                model.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!model.document.canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .help("Redo")

            Button {
                model.clearAnnotations()
            } label: {
                Image(systemName: "trash")
            }
            .disabled(model.document.isEmpty)
            .help("Remove all annotations")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var colorSwatches: some View {
        HStack(spacing: 5) {
            ForEach(Array(AnnotationColor.palette.enumerated()), id: \.offset) { _, color in
                let isSelected = color == model.style.color
                Circle()
                    .fill(Color(cgColor: color.cgColor))
                    .frame(width: 17, height: 17)
                    .overlay(
                        Circle().strokeBorder(
                            isSelected ? Color.accentColor : Color.secondary.opacity(0.4),
                            lineWidth: isSelected ? 2.5 : 1
                        )
                    )
                    .onTapGesture { model.style.color = color }
            }
        }
        .help("Annotation colour")
    }

    // MARK: - Canvas

    private var canvas: some View {
        AnnotationCanvas(
            baseImage: model.currentBaseImage(),
            canvasSize: model.canvasSize,
            items: model.document.items,
            tool: model.tool,
            style: model.style,
            onCommit: { model.add($0) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Clip trimming

    private var clipControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    "\(model.trimmedFrameCount) of \(model.frameCount) frames · \(String(format: "%.1f", model.trimmedDuration)) s",
                    systemImage: "film"
                )
                .foregroundStyle(.secondary)
                .font(.callout)

                Spacer()

                Button("Reset trim") {
                    model.trimStart = 0
                    model.trimEnd = model.frameCount - 1
                    model.clampPreviewToTrim()
                }
                .disabled(!model.isTrimmable || (model.trimStart == 0 && model.trimEnd == model.frameCount - 1))
            }

            // A one-frame clip has nothing to trim and nothing to scrub. Showing sliders whose
            // range had to be padded to 0...1 would let the user select a frame index that does
            // not exist.
            if !model.isTrimmable {
                Text("Single frame — nothing to trim.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {

            HStack(spacing: 10) {
                Text("Start").font(.caption).foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
                Slider(
                    value: Binding(
                        get: { Double(model.trimStart) },
                        set: { newValue in
                            model.trimStart = min(Int(newValue.rounded()), model.trimEnd)
                            model.previewIndex = model.trimStart
                        }
                    ),
                    in: model.trimHandleRange
                )
                Text("\(model.trimStart)").font(.caption.monospacedDigit()).frame(width: 34)
            }

            HStack(spacing: 10) {
                Text("End").font(.caption).foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
                Slider(
                    value: Binding(
                        get: { Double(model.trimEnd) },
                        set: { newValue in
                            model.trimEnd = max(Int(newValue.rounded()), model.trimStart)
                            model.previewIndex = model.trimEnd
                        }
                    ),
                    in: model.trimHandleRange
                )
                Text("\(model.trimEnd)").font(.caption.monospacedDigit()).frame(width: 34)
            }

            HStack(spacing: 10) {
                Text("Frame").font(.caption).foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
                Slider(
                    value: Binding(
                        get: { Double(model.previewIndex) },
                        set: { model.previewIndex = Int($0.rounded()).clamped(to: model.trimStart...model.trimEnd) }
                    ),
                    in: model.previewScrubRange
                )
                Text("\(model.previewIndex)").font(.caption.monospacedDigit()).frame(width: 34)
            }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notice = model.truncationNotice {
                notceLabel(notice, systemImage: "exclamationmark.triangle", color: .orange)
            }
            if let notice = model.colorSpaceNotice {
                notceLabel(notice, systemImage: "paintpalette", color: .orange)
            }
            if let error = model.errorMessage {
                notceLabel(error, systemImage: "xmark.octagon", color: .red)
            }
            if let status = model.statusMessage {
                notceLabel(status, systemImage: "checkmark.circle", color: .green)
            }

            HStack(spacing: 12) {
                Text("\(Int(model.canvasSize.width)) × \(Int(model.canvasSize.height)) px")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)

                if !model.source.isClip {
                    Picker("Format", selection: $model.format) {
                        ForEach([OutputFormat.png, .jpeg, .webp], id: \.self) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .frame(width: 170)
                } else {
                    Label("Animated WebP", systemImage: "square.stack.3d.down.right")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if model.isExporting {
                    ProgressView(value: model.exportProgress)
                        .frame(width: 120)
                }

                Button("Close") { model.close() }
                    .keyboardShortcut(.cancelAction)

                Button(model.isExporting ? "Saving…" : "Save") { model.export() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isExporting)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func notceLabel(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
