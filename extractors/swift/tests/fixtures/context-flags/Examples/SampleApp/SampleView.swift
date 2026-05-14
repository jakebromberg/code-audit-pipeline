// Fixture for V7 §6.6 — `is_sample_app` from path. File lives under
// Examples/SampleApp/, matching both the "Examples/" and "SampleApp/" path
// patterns. Either alone would set the flag; both together exercise the
// case where a sample-app fixture also implicitly carries the parent
// Examples/ context.
struct SampleView {
    let title: String
}
