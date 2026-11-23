use std::{
    collections::{BTreeMap, BTreeSet},
    env,
    io::{self, Read, Write},
    process::ExitCode,
};

struct Package<'a> {
    name: &'a str,
    source: &'a str,
    version: &'a str,
}

fn verify(label: &str, input: &str) -> Result<(), String> {
    if !matches!(label, "Cargo.lock" | "Cargo metadata") {
        return Err("Invalid Cargo evidence label".into());
    }
    // Cargo names and source identifiers can be sent without JSON escapes.
    // Framing with NUL keeps paths encoded in Git URLs independent of whitespace.
    let fields: Vec<_> = input.split('\0').collect();
    let (records, remainder) = fields.as_chunks::<4>();
    if !remainder.is_empty() {
        return Err("Incomplete Cargo package evidence record".into());
    }
    let mut packages = Vec::new();
    let mut git = BTreeMap::new();
    let mut registry = Vec::new();
    for record in records {
        match *record {
            ["git", name, source, optional @ ("" | "optional")] => {
                git.insert(name, (source, optional == "optional"));
            }
            ["registry", name, source, version] => registry.push(Package {
                name,
                source,
                version,
            }),
            ["package", name, source, version] => packages.push(Package {
                name,
                source,
                version,
            }),
            _ => return Err("Invalid Cargo package evidence record".into()),
        }
    }
    let names: BTreeSet<_> = packages.iter().map(|package| package.name).collect();
    git.retain(|name, (_, optional)| !*optional || names.contains(name));
    let allowed: BTreeSet<_> = git.values().map(|(source, _)| *source).collect();
    let invalid_git =
        || format!("The client {label} must retain the exact public SDK Git identities");
    let mut visited = BTreeSet::new();
    for package in &packages {
        if let Some((source, _)) = git.get(package.name)
            && (*source != package.source || !visited.insert(package.name))
        {
            return Err(invalid_git());
        }
        if package.source.starts_with("git+") && !allowed.contains(package.source) {
            return Err(invalid_git());
        }
    }
    if visited.len() != git.len() {
        return Err(invalid_git());
    }
    for pin in registry {
        let mut matching = packages.iter().filter(|package| package.name == pin.name);
        let exact = matching
            .next()
            .is_some_and(|package| package.version == pin.version && package.source == pin.source);
        if !exact || matching.next().is_some() {
            return Err(format!(
                "The client {label} must retain the pinned crates.io dependency {}",
                pin.name
            ));
        }
    }
    Ok(())
}

fn select_binary(input: &str) -> Result<&str, String> {
    let mut fields = input.split('\0');
    let default = fields.next().unwrap_or_default();
    let error = "Select the external Rust fixture binary with default-run";
    if !default.is_empty() {
        return fields
            .any(|name| name == default)
            .then_some(default)
            .ok_or_else(|| error.into());
    }
    match (fields.next(), fields.next()) {
        (Some(binary), None) if !binary.is_empty() => Ok(binary),
        _ => Err(error.into()),
    }
}

fn select_executable(input: &str) -> Result<&str, String> {
    let error = "Cargo must report the freshly built Windows Rust fixture executable";
    let fields: Vec<_> = input.split('\0').collect();
    let [root, binary, rows @ ..] = fields.as_slice() else {
        return Err(error.into());
    };
    let (records, remainder) = rows.as_chunks::<4>();
    if !remainder.is_empty() {
        return Err("Incomplete Cargo fixture artifact record".into());
    }
    let mut matches = records.iter().filter_map(|[id, name, kind, executable]| {
        (id == root && name == binary && *kind == "bin" && !executable.is_empty())
            .then_some(*executable)
    });
    match (matches.next(), matches.next()) {
        (Some(executable), None) => Ok(executable),
        _ => Err(error.into()),
    }
}

fn select_ci_bundle(input: &str) -> Result<String, String> {
    let fields: Vec<_> = input.split('\0').collect();
    let [
        repository,
        folded_repository,
        url,
        folded_url,
        revision,
        rows @ ..,
    ] = fields.as_slice()
    else {
        return Err("Incomplete CI source manifest evidence".into());
    };
    let (records, remainder) = rows.as_chunks::<6>();
    if !remainder.is_empty() {
        return Err("Incomplete CI source manifest evidence".into());
    }
    let mut matching = records
        .iter()
        .enumerate()
        .filter(|(_, row)| row[1] == *folded_repository || row[3] == *folded_url);
    let (
        Some((
            index,
            [
                observed_repository,
                _,
                observed_url,
                _,
                observed_revision,
                bundle,
            ],
        )),
        None,
    ) = (matching.next(), matching.next())
    else {
        return Err("Missing or ambiguous additional SDK Git pin in CI source manifest".into());
    };
    let member = format!("{index}.bundle");
    if observed_repository != repository
        || observed_url != url
        || observed_revision != revision
        || *bundle != member
        || records.iter().filter(|row| row[5] == member).count() != 1
    {
        return Err("Invalid additional SDK Git bundle identity".into());
    }
    Ok(index.to_string())
}

fn run() -> Result<(), String> {
    let operation = env::args().nth(1).ok_or("Missing Cargo evidence label")?;
    let mut input = String::new();
    io::stdin()
        .read_to_string(&mut input)
        .map_err(|_| "Cannot read Cargo package evidence")?;
    let selected = match operation.as_str() {
        "select-binary" => select_binary(&input)?.to_owned(),
        "select-executable" => select_executable(&input)?.to_owned(),
        "select-ci-bundle" => select_ci_bundle(&input)?,
        _ => return verify(&operation, &input),
    };
    io::stdout()
        .lock()
        .write_all(selected.as_bytes())
        .map_err(|_| "Cannot write Cargo fixture selection".into())
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("{message}");
            ExitCode::from(2)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::verify;

    const PRIMARY: &str = "git+https://github.com/naviapps/sdk.git?rev=aaa#aaa";
    const EXTRA: &str = "git+https://github.com/naviapps/extra.git?rev=bbb#bbb";
    const PUBLIC: &str = "registry+https://github.com/rust-lang/crates.io-index";

    fn evidence(records: &[[&str; 4]]) -> String {
        records
            .iter()
            .flatten()
            .copied()
            .collect::<Vec<_>>()
            .join("\0")
    }

    #[test]
    fn accepts_exact_gits_and_other_packages_with_the_same_pinned_workspace_identity() {
        let proof = evidence(&[
            ["git", "producer", PRIMARY, ""],
            ["git", "dependency", EXTRA, ""],
            ["package", "producer", PRIMARY, "1.0.0"],
            ["package", "dependency", EXTRA, "1.0.0"],
            ["package", "workspace-companion", EXTRA, "1.0.0"],
            ["package", "public-crate", PUBLIC, "1.0.0"],
        ]);
        for label in ["Cargo.lock", "Cargo metadata"] {
            assert_eq!(verify(label, &proof), Ok(()));
        }
    }

    #[test]
    fn rejects_missing_duplicate_wrong_source_and_undeclared_git_dependencies() {
        for rows in [
            vec![],
            vec![["package", "producer", EXTRA, "1.0.0"]],
            vec![
                ["package", "producer", PRIMARY, "1.0.0"],
                ["package", "dependency", EXTRA, "1.0.0"],
                ["package", "dependency", EXTRA, "2.0.0"],
            ],
            vec![
                ["package", "producer", PRIMARY, "1.0.0"],
                ["package", "dependency", EXTRA, "1.0.0"],
                ["package", "unexpected", "git+file:///local", "1.0.0"],
            ],
        ] {
            let mut records = vec![
                ["git", "producer", PRIMARY, ""],
                ["git", "dependency", EXTRA, ""],
            ];
            records.extend(rows);
            for label in ["Cargo.lock", "Cargo metadata"] {
                assert_eq!(
                    verify(label, &evidence(&records)),
                    Err(format!(
                        "The client {label} must retain the exact public SDK Git identities"
                    ))
                );
            }
        }
    }

    #[test]
    fn an_optional_package_may_be_absent_but_its_observed_identity_is_checked() {
        let mut records = vec![
            ["git", "producer", PRIMARY, ""],
            ["git", "optional", PRIMARY, "optional"],
            ["package", "producer", PRIMARY, "1.0.0"],
        ];
        assert_eq!(verify("Cargo metadata", &evidence(&records)), Ok(()));
        records.push(["package", "optional", PRIMARY, "1.0.0"]);
        assert_eq!(verify("Cargo metadata", &evidence(&records)), Ok(()));
        records.last_mut().unwrap()[2] = EXTRA;
        assert!(verify("Cargo metadata", &evidence(&records)).is_err());
    }

    #[test]
    fn registry_identity_requires_exact_source_and_version_and_a_single_match() {
        let base = [
            ["git", "producer", PRIMARY, ""],
            ["package", "producer", PRIMARY, "1.0.0"],
            ["registry", "tokio", PUBLIC, "1.54.1"],
        ];
        let accepted = ["package", "tokio", PUBLIC, "1.54.1"];
        assert_eq!(
            verify("Cargo.lock", &evidence(&[&base[..], &[accepted]].concat())),
            Ok(())
        );
        for rows in [
            vec![],
            vec![["package", "tokio", PUBLIC, "1.54.2"]],
            vec![[
                "package",
                "tokio",
                "registry+https://example.invalid",
                "1.54.1",
            ]],
            vec![accepted, accepted],
        ] {
            let records = [&base[..], &rows].concat();
            for label in ["Cargo.lock", "Cargo metadata"] {
                assert_eq!(
                    verify(label, &evidence(&records)),
                    Err(format!(
                        "The client {label} must retain the pinned crates.io dependency tokio"
                    ))
                );
            }
        }
    }

    #[test]
    fn git_failure_precedes_a_registry_failure() {
        let proof = evidence(&[
            ["git", "producer", PRIMARY, ""],
            ["registry", "tokio", PUBLIC, "1.54.1"],
        ]);
        assert_eq!(
            verify("Cargo.lock", &proof),
            Err("The client Cargo.lock must retain the exact public SDK Git identities".into())
        );
    }

    #[test]
    fn rejects_incomplete_evidence_before_checking_claims() {
        assert_eq!(
            verify("Cargo.lock", "package\0producer\0some-source"),
            Err("Incomplete Cargo package evidence record".into())
        );
    }
}
