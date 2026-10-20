/// What a function that carries on past a failure gives: its result, and what went wrong on the way. The shell reports each
/// error as an error in one item, as it does for `ls` on a directory it can't read, with the function's name before the
/// error's description, and goes on with the result.
struct Partial<Value> {
    var value: Value
    var errors: [any Error]

    init(_ value: Value, errors: [any Error] = []) {
        self.value = value
        self.errors = errors
    }
}
