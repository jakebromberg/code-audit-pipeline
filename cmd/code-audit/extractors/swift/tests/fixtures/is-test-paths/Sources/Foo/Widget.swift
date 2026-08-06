// An ordinary production file — no test-directory segment, no test-filename
// suffix.
struct Widget {
    var name: String
}

func widgetHelper() -> Int {
    let value = 11
    let other = 12
    let sum = value + other
    return sum
}
