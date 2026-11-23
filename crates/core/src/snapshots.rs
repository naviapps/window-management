use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

/// Reusable snapshot selection. Identifiers belong to their native platform;
/// application identifiers are opaque host/adapter strings, not paths to execute.
#[derive(Debug, Default, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase", deny_unknown_fields)]
pub struct SnapshotFilter {
    pub included_owner_application_identifiers: BTreeSet<String>,
    pub included_owner_process_identifiers: BTreeSet<i64>,
    pub included_window_identifiers: BTreeSet<u64>,
    pub excluded_owner_application_identifiers: BTreeSet<String>,
    pub excluded_owner_process_identifiers: BTreeSet<i64>,
    pub excluded_window_identifiers: BTreeSet<u64>,
}

/// Candidate selection before resolving optional application metadata.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SnapshotIdentityMatch {
    /// A numeric identity condition rejected the candidate.
    Excluded,
    /// The candidate passed every condition without an application identifier.
    Included,
    /// The numeric identity passed and application conditions still need evaluation.
    RequiresApplicationIdentifier,
}

impl SnapshotFilter {
    /// Evaluate the numeric identity and determine whether application metadata can affect selection.
    pub fn match_identity(&self, window: u64, process: i64) -> SnapshotIdentityMatch {
        let included = (self.included_window_identifiers.is_empty()
            || self.included_window_identifiers.contains(&window))
            && (self.included_owner_process_identifiers.is_empty()
                || self.included_owner_process_identifiers.contains(&process));
        if !included
            || self.excluded_window_identifiers.contains(&window)
            || self.excluded_owner_process_identifiers.contains(&process)
        {
            SnapshotIdentityMatch::Excluded
        } else if self.included_owner_application_identifiers.is_empty()
            && self.excluded_owner_application_identifiers.is_empty()
        {
            SnapshotIdentityMatch::Included
        } else {
            SnapshotIdentityMatch::RequiresApplicationIdentifier
        }
    }

    /// All nonempty include sets must match. Any exclusion wins, including when
    /// the same identifier is also included. A missing application ID never
    /// satisfies an application include set.
    pub fn includes(&self, window: u64, process: i64, application: Option<&str>) -> bool {
        match self.match_identity(window, process) {
            SnapshotIdentityMatch::Excluded => false,
            SnapshotIdentityMatch::Included => true,
            SnapshotIdentityMatch::RequiresApplicationIdentifier => {
                (self.included_owner_application_identifiers.is_empty()
                    || application
                        .is_some_and(|id| self.included_owner_application_identifiers.contains(id)))
                    && !application
                        .is_some_and(|id| self.excluded_owner_application_identifiers.contains(id))
            }
        }
    }
}
