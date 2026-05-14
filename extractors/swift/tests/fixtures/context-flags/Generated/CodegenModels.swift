// Fixture for V7 §6.6 — `is_codegen` from path. File lives under a
// `Generated/` directory (capital G — the common Swift convention vs the
// legacy lowercase `/generated/` that `is_generated` checks). Tests that
// `is_codegen` is a strict superset of `generated` and fires on this path.
struct CodegenModel {
    let id: String
    let createdAt: String
}
