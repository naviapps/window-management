use window_management::{SnapshotFilter, SnapshotIdentityMatch};

#[test]
fn identity_checks_finish_before_optional_application_metadata() {
    use SnapshotIdentityMatch::{Excluded, Included, RequiresApplicationIdentifier};
    let mut filter = SnapshotFilter {
        included_owner_process_identifiers: [12].into(),
        included_window_identifiers: [1, 2].into(),
        excluded_window_identifiers: [2].into(),
        ..SnapshotFilter::default()
    };
    assert_eq!(filter.match_identity(1, 12), Included);
    assert_eq!(filter.match_identity(2, 12), Excluded);
    assert_eq!(filter.match_identity(3, 12), Excluded);
    assert_eq!(filter.match_identity(1, 13), Excluded);
    filter
        .excluded_owner_application_identifiers
        .insert("".into());
    assert_eq!(filter.match_identity(1, 12), RequiresApplicationIdentifier);
    assert_eq!(filter.match_identity(2, 12), Excluded);
    assert!(filter.includes(1, 12, None));
    assert!(!filter.includes(1, 12, Some("")));
    filter.excluded_owner_application_identifiers.clear();
    filter
        .included_owner_application_identifiers
        .insert("".into());
    assert_eq!(filter.match_identity(1, 12), RequiresApplicationIdentifier);
    assert!(!filter.includes(1, 12, None));
    assert!(filter.includes(1, 12, Some("")));
}

#[test]
fn filters_intersect_include_sets_and_give_exclusions_precedence() {
    use SnapshotIdentityMatch::{Excluded, Included, RequiresApplicationIdentifier};

    let filter: SnapshotFilter = serde_json::from_str(
        r#"{
        "includedOwnerApplicationIdentifiers":["example.日本","example.blocked"],
        "includedOwnerProcessIdentifiers":[12,13],"includedWindowIdentifiers":[2,18446744073709551615],
        "excludedOwnerApplicationIdentifiers":["example.blocked"],
        "excludedOwnerProcessIdentifiers":[13],"excludedWindowIdentifiers":[2]
    }"#,
    )
    .unwrap();
    for (window, process) in [(1, 12), (u64::MAX, 11), (2, 12), (u64::MAX, 13)] {
        assert_eq!(
            filter.match_identity(window, process),
            Excluded,
            "{window} {process}"
        );
        assert!(!filter.includes(window, process, Some("example.日本")));
    }
    assert_eq!(
        filter.match_identity(u64::MAX, 12),
        RequiresApplicationIdentifier
    );
    for (application, expected) in [
        (Some("example.日本"), true),
        (Some("example.blocked"), false),
        (Some("example.other"), false),
        (None, false),
    ] {
        assert_eq!(
            filter.includes(u64::MAX, 12, application),
            expected,
            "{application:?}"
        );
    }
    let default: SnapshotFilter = serde_json::from_str("{}").unwrap();
    assert_eq!(default, SnapshotFilter::default());
    assert_eq!(default.match_identity(0, 0), Included);
    assert!(default.includes(0, 0, None));
}

#[test]
fn canonical_filter_json_uses_application_identifiers_and_rejects_legacy_fields() {
    let filter: SnapshotFilter =
        serde_json::from_str(r#"{"includedOwnerApplicationIdentifiers":["b","a","a"]}"#).unwrap();
    let bytes = serde_json::to_vec(&filter).unwrap();
    assert_eq!(
        serde_json::from_slice::<SnapshotFilter>(&bytes).unwrap(),
        filter
    );
    assert!(
        String::from_utf8(bytes)
            .unwrap()
            .contains(r#""includedOwnerApplicationIdentifiers":["a","b"]"#)
    );
    for value in [
        r#"{"unexpected":1}"#,
        r#"{"includedOwnerBundleIdentifiers":["a"]}"#,
        r#"{"excludedOwnerBundleIdentifiers":["a"]}"#,
        r#"{"includedWindowIdentifiers":null}"#,
        r#"{"includedWindowIdentifiers":[-1]}"#,
        r#"{"includedWindowIdentifiers":[18446744073709551616]}"#,
        r#"{"includedOwnerProcessIdentifiers":[9223372036854775808]}"#,
        r#"{"includedOwnerProcessIdentifiers":[-9223372036854775809]}"#,
        r#"{"includedOwnerApplicationIdentifiers":["a"],"includedOwnerApplicationIdentifiers":["b"]}"#,
        r#"{"includedWindowIdentifiers":[1],"includedWindowIdentifiers":[2]}"#,
    ] {
        assert!(
            serde_json::from_str::<SnapshotFilter>(value).is_err(),
            "{value}"
        );
    }
}

#[test]
fn numeric_filter_identifiers_keep_the_shared_integer_widths() {
    let filter: SnapshotFilter = serde_json::from_str(
        r#"{"includedOwnerProcessIdentifiers":[111,-9223372036854775808,9223372036854775807],
            "includedWindowIdentifiers":[222,18446744073709551615],
            "excludedOwnerProcessIdentifiers":[4294967407],"excludedWindowIdentifiers":[4294967518]}"#,
    )
    .unwrap();
    assert!(filter.includes(u64::MAX, i64::MIN, None));
    assert!(filter.includes(u64::MAX, i64::MAX, None));
    assert!(filter.includes(222, 111, None));
    assert_eq!(
        filter.excluded_owner_process_identifiers,
        [4_294_967_407].into()
    );
    assert_eq!(filter.excluded_window_identifiers, [4_294_967_518].into());
    let process_only = SnapshotFilter {
        included_owner_process_identifiers: filter.excluded_owner_process_identifiers.clone(),
        ..SnapshotFilter::default()
    };
    let window_only = SnapshotFilter {
        included_window_identifiers: filter.excluded_window_identifiers.clone(),
        ..SnapshotFilter::default()
    };
    assert!(process_only.includes(222, 4_294_967_407, None));
    assert!(window_only.includes(4_294_967_518, 111, None));
    assert!(!process_only.includes(222, 111, None));
    assert!(!window_only.includes(222, 111, None));
    assert_eq!(
        serde_json::from_slice::<SnapshotFilter>(&serde_json::to_vec(&filter).unwrap()).unwrap(),
        filter
    );
}

#[test]
fn application_identifiers_preserve_scalar_spelling_and_presence() {
    let composed = "\u{00e9}";
    let decomposed = "e\u{0301}";
    let filter: SnapshotFilter = serde_json::from_str(
        r#"{"includedOwnerApplicationIdentifiers":["\u00e9","e\u0301","","a\u0000b","\ud83d\udca1"],"excludedOwnerApplicationIdentifiers":["e\u0301"]}"#,
    )
    .unwrap();
    assert_eq!(filter.included_owner_application_identifiers.len(), 5);
    let bytes = serde_json::to_vec(&filter).unwrap();
    let round_trip: SnapshotFilter = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(round_trip, filter);
    for application in [composed, "", "a\0b", "💡"] {
        assert!(
            round_trip.includes(1, 2, Some(application)),
            "{application:?}"
        );
    }
    for application in [Some(decomposed), Some("a"), Some("\u{fffd}"), None] {
        assert!(!round_trip.includes(1, 2, application), "{application:?}");
    }
}

#[test]
fn optional_application_identifier_is_matched_exactly_for_each_policy() {
    for application in ["", "com.example.allowed", "日本語😀", "owner\0window"] {
        let include = SnapshotFilter {
            included_owner_application_identifiers: [application.to_owned()].into(),
            ..SnapshotFilter::default()
        };
        let exclude = SnapshotFilter {
            excluded_owner_application_identifiers: [application.to_owned()].into(),
            ..SnapshotFilter::default()
        };
        let other = format!("{application}other");
        for (candidate, exact) in [
            (Some(application), true),
            (None, false),
            (Some(other.as_str()), false),
        ] {
            assert_eq!(
                include.includes(222, 111, candidate),
                exact,
                "{candidate:?}"
            );
            assert_eq!(
                exclude.includes(222, 111, candidate),
                !exact,
                "{candidate:?}"
            );
        }
    }
}

#[test]
fn malformed_identifier_unicode_is_rejected() {
    for json in [
        br#"{"includedOwnerApplicationIdentifiers":["\ud800"]}"#.as_slice(),
        br#"{"excludedOwnerApplicationIdentifiers":["\udc00"]}"#.as_slice(),
        b"{\"includedOwnerApplicationIdentifiers\":[\"\xed\xa0\x80\"]}".as_slice(),
        b"{\"includedOwnerApplicationIdentifiers\":[\"\xff\"]}".as_slice(),
    ] {
        assert!(serde_json::from_slice::<SnapshotFilter>(json).is_err());
    }
}
