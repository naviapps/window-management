use std::{
    env,
    ffi::OsStr,
    fs,
    io::{self, Read, Write},
    path::Path,
    process::ExitCode,
};

fn line_boundary(character: char) -> bool {
    matches!(
        character,
        '\n' | '\r' | '\u{b}' | '\u{c}' | '\u{1c}'..='\u{1e}' | '\u{85}' | '\u{2028}' | '\u{2029}'
    )
}

fn dependency_words(text: &str) -> Result<Vec<String>, &'static str> {
    // Keep the line and space handling of the accepted Make-rule spelling.
    let flattened = text.replace("\\\n", "");
    let first = flattened
        .split(line_boundary)
        .find(|line| !line.is_empty() && !line.starts_with('#'))
        .unwrap_or_default();
    let (_, dependencies) = first
        .split_once(": ")
        .ok_or("Rust dependency information has no dependency rule")?;
    let mut words = Vec::new();
    let mut word = String::new();
    let mut characters = dependencies.chars().peekable();
    while let Some(character) = characters.next() {
        if character == '\\'
            && let Some(escaped @ (' ' | '\\' | '#' | '\t')) = characters.peek().copied()
        {
            word.push(escaped);
            characters.next();
        } else if character.is_whitespace() || matches!(character, '\u{1c}'..='\u{1f}') {
            if !word.is_empty() {
                words.push(word.replace("$$", "$"));
                word.clear();
            }
        } else {
            word.push(character);
        }
    }
    if !word.is_empty() {
        words.push(word.replace("$$", "$"));
    }
    if words.is_empty() {
        return Err("Rust dependency information contains no sources");
    }
    Ok(words)
}

fn read_rule(path: &Path) -> io::Result<String> {
    fs::read_to_string(path)
        .map(|text| text.replace("\r\n", "\n").replace('\r', "\n"))
        .map_err(|error| io::Error::new(error.kind(), format!("{}: {error}", path.display())))
}

fn write_sources(
    inputs: impl IntoIterator<Item = io::Result<String>>,
    mut output: impl Write,
) -> io::Result<ExitCode> {
    let mut words = Vec::new();
    for input in inputs {
        match dependency_words(&input?) {
            Ok(parsed) => words.extend(parsed),
            Err(message) => {
                eprintln!("{message}");
                return Ok(ExitCode::from(2));
            }
        }
    }
    output.write_all(words.join("\n").as_bytes())?;
    Ok(ExitCode::SUCCESS)
}

fn main() -> io::Result<ExitCode> {
    let mut arguments = env::args_os().skip(1);
    if arguments.next().as_deref() == Some(OsStr::new("--files")) {
        write_sources(
            arguments.map(|path| read_rule(Path::new(&path))),
            io::stdout(),
        )
    } else {
        let mut input = String::new();
        io::stdin().read_to_string(&mut input)?;
        write_sources([Ok(input)], io::stdout())
    }
}

#[cfg(test)]
mod tests {
    use super::{dependency_words, write_sources};
    use std::{io, process::ExitCode};

    #[test]
    fn decodes_make_escapes_without_shell_tokenization() {
        let text = concat!(
            "output: /source/a\\ b.rs /source/a\\#b.rs /source/dollar$$.rs \\\n ",
            r"C:\w\source.rs /source/quoted'file'.rs literal\\path.rs",
            "\n/source/a\\ b.rs:\n",
        );
        assert_eq!(
            dependency_words(text).unwrap(),
            [
                "/source/a b.rs",
                "/source/a#b.rs",
                "/source/dollar$.rs",
                r"C:\w\source.rs",
                "/source/quoted'file'.rs",
                r"literal\path.rs",
            ]
        );
    }

    #[test]
    fn selects_the_first_non_comment_rule_even_if_later_rules_are_valid() {
        assert_eq!(
            dependency_words("# comment\n\nfirst: left.rs\nsecond: right.rs").unwrap(),
            ["left.rs"]
        );
        assert_eq!(
            dependency_words("   \nvalid: ok.rs"),
            Err("Rust dependency information has no dependency rule")
        );
    }

    #[test]
    fn retains_legacy_line_boundaries_spaces_and_literal_bytes() {
        for boundary in [
            '\n', '\r', '\u{b}', '\u{c}', '\u{1c}', '\u{1d}', '\u{1e}', '\u{85}', '\u{2028}',
            '\u{2029}',
        ] {
            let text = format!("# comment{boundary}out: one\u{1f}二\u{a0}nul\0path{boundary}junk");
            assert_eq!(dependency_words(&text).unwrap(), ["one", "二", "nul\0path"]);
        }
    }

    #[test]
    fn writes_the_complete_sequence_in_file_and_rule_order() {
        let mut output = Vec::new();
        let inputs = [
            Ok("out: first second".into()),
            Ok("out: second third".into()),
        ];
        assert_eq!(
            write_sources(inputs, &mut output).unwrap(),
            ExitCode::SUCCESS
        );
        assert_eq!(output, b"first\nsecond\nsecond\nthird");
    }

    #[test]
    fn a_failed_later_input_leaves_no_partial_output() {
        let mut output = Vec::new();
        let inputs = [Ok("out: first".into()), Ok("missing rule".into())];
        assert_eq!(
            write_sources(inputs, &mut output).unwrap(),
            ExitCode::from(2)
        );
        assert!(output.is_empty());
        let inputs = [
            Ok("out: first".into()),
            Err(io::ErrorKind::InvalidData.into()),
        ];
        assert_eq!(
            write_sources(inputs, &mut output).unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );
        assert!(output.is_empty());
    }

    #[test]
    fn rejects_missing_rule_and_missing_sources_distinctly() {
        for text in ["", "not a rule", "# comment\n", "output:\tfile"] {
            assert_eq!(
                dependency_words(text),
                Err("Rust dependency information has no dependency rule")
            );
        }
        for text in ["output: ", "output: \t\u{1f}\u{2003}", "output: \\\n"] {
            assert_eq!(
                dependency_words(text),
                Err("Rust dependency information contains no sources")
            );
        }
    }
}
