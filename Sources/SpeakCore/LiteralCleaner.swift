/// The only changes Literal mode makes to a transcript: tidy whitespace and
/// capitalize the first letter. Anything more is a rewrite and needs a preview.
public func cleanLiteral(_ text: String) -> String {
    let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    // Skip leading quotes and "¿" so the letter itself gets the capital,
    // but leave text that starts with a number alone.
    guard let index = collapsed.firstIndex(where: { $0.isLetter || $0.isNumber }),
          collapsed[index].isLetter else { return collapsed }
    return collapsed[..<index] + collapsed[index].uppercased() + collapsed[collapsed.index(after: index)...]
}
