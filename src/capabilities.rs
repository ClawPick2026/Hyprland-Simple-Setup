//! Desktop harmonization capability ledger (plan F01).
//!
//! `capabilities.json` beside `packages.json` plus every `capabilities.d/*.json`
//! fragment form one logical ledger. The reader is strict: unknown fields, unknown
//! vocabulary values, duplicate definitions and catalog mismatches are errors.
//! A missing base document means harmonization metadata is absent, which is not an
//! error: callers label every choice unverified and keep it selectable.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::fs;
use std::io::ErrorKind;
use std::marker::PhantomData;
use std::path::Path;

use anyhow::{Context, Result, bail};
use serde::Deserialize;
use serde::de::{self, Deserializer, MapAccess, Visitor};

use crate::packages::{PackageSource, PackagesRoot, ROLE_ORDER};

pub const LEDGER_FILE: &str = "capabilities.json";
pub const FRAGMENT_DIR: &str = "capabilities.d";
const FRAGMENT_PATTERN: &str = "capabilities.d/*.json";
const SCHEMA_VERSION: u32 = 1;
const MAX_SUMMARY_CHARS: usize = 160;

macro_rules! vocabulary_enum {
    ($name:ident, $kind:literal, { $($variant:ident => $text:literal),+ $(,)? }) => {
        #[derive(Clone, Copy, Debug, PartialEq, Eq)]
        pub enum $name {
            $($variant),+
        }

        impl $name {
            pub const ALL: &'static [Self] = &[$(Self::$variant),+];

            pub fn as_str(self) -> &'static str {
                match self {
                    $(Self::$variant => $text),+
                }
            }
        }

        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D: Deserializer<'de>>(
                deserializer: D,
            ) -> std::result::Result<Self, D::Error> {
                let text = String::deserialize(deserializer)?;
                Self::ALL
                    .iter()
                    .copied()
                    .find(|value| value.as_str() == text)
                    .ok_or_else(|| {
                        de::Error::custom(format!(
                            "unknown {} {text:?}; expected one of {}",
                            $kind,
                            vocabulary_list(Self::ALL.iter().map(|value| value.as_str()))
                        ))
                    })
            }
        }
    };
}

fn vocabulary_list<'a>(values: impl Iterator<Item = &'a str>) -> String {
    values.collect::<Vec<_>>().join(", ")
}

vocabulary_enum!(OptionSupport, "option support", {
    Full => "full",
    Limited => "limited",
    Unverified => "unverified",
});

vocabulary_enum!(CapabilitySupport, "capability support", {
    Supported => "supported",
    Partial => "partial",
    Unsupported => "unsupported",
    Unverified => "unverified",
    NotApplicable => "not-applicable",
});

vocabulary_enum!(Mechanism, "mechanism", {
    NativeCli => "native-cli",
    NativeConfig => "native-config",
    NativeApi => "native-api",
    NativeUi => "native-ui",
    None => "none",
});

vocabulary_enum!(Family, "family", {
    Gtk3 => "gtk3",
    Gtk4 => "gtk4",
    Libadwaita => "libadwaita",
    Qt5 => "qt5",
    Qt6 => "qt6",
    Kde => "kde",
    Electron => "electron",
    Custom => "custom",
    Tui => "tui",
    Cli => "cli",
});

vocabulary_enum!(Startup, "startup", {
    OnDemand => "on-demand",
    Daemon => "daemon",
    DbusActivated => "dbus-activated",
    SessionService => "session-service",
    Terminal => "terminal",
});

vocabulary_enum!(EvidenceKind, "evidence kind", {
    Documentation => "documentation",
    Static => "static",
    Argv => "argv",
    ModeledEffect => "modeled-effect",
    RealEffect => "real-effect",
    Visual => "visual",
});

vocabulary_enum!(Requirement, "requirement", {
    Required => "required",
    Optional => "optional",
});

vocabulary_enum!(FailureState, "failure state", {
    Failed => "failed",
    Usage => "usage",
    Cancelled => "cancelled",
    Disabled => "disabled",
    Unsupported => "unsupported",
    MissingDependency => "missing-dependency",
    Unavailable => "unavailable",
    Timeout => "timeout",
    Denied => "denied",
    Conflict => "conflict",
});

vocabulary_enum!(GenericClass, "generic package class", {
    ThemedInterface => "themed-interface",
    IntegratedAction => "integrated-action",
    BackendDependency => "backend-dependency",
    OutsideVisualScope => "outside-visual-scope",
});

/// A JSON object whose keys must be unique. serde_json keeps the last duplicate
/// silently, which would let one definition shadow another inside a fragment.
#[derive(Clone, Debug)]
struct UniqueMap<V>(BTreeMap<String, V>);

impl<V> Default for UniqueMap<V> {
    fn default() -> Self {
        Self(BTreeMap::new())
    }
}

impl<'de, V: Deserialize<'de>> Deserialize<'de> for UniqueMap<V> {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> std::result::Result<Self, D::Error> {
        struct UniqueVisitor<V>(PhantomData<V>);

        impl<'de, V: Deserialize<'de>> Visitor<'de> for UniqueVisitor<V> {
            type Value = UniqueMap<V>;

            fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
                formatter.write_str("an object with unique keys")
            }

            fn visit_map<A: MapAccess<'de>>(
                self,
                mut access: A,
            ) -> std::result::Result<Self::Value, A::Error> {
                let mut values = BTreeMap::new();
                while let Some(key) = access.next_key::<String>()? {
                    if values.contains_key(&key) {
                        return Err(de::Error::custom(format!("duplicate key {key:?}")));
                    }
                    let value = access.next_value()?;
                    values.insert(key, value);
                }
                Ok(UniqueMap(values))
            }
        }

        deserializer.deserialize_map(UniqueVisitor(PhantomData))
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct BaseDocument {
    schema_version: u32,
    description: String,
    vocabulary: Vocabulary,
    identifiers: UniqueMap<String>,
    fragments: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Vocabulary {
    option_support: UniqueMap<String>,
    capability_support: UniqueMap<String>,
    mechanism: UniqueMap<String>,
    family: UniqueMap<String>,
    startup: UniqueMap<String>,
    evidence_kind: UniqueMap<String>,
    requirement: UniqueMap<String>,
    failure_state: UniqueMap<String>,
    generic_class: UniqueMap<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Fragment {
    schema_version: u32,
    owner: String,
    #[serde(default)]
    capabilities: UniqueMap<CapabilityDefinition>,
    #[serde(default)]
    options: UniqueMap<OptionRecord>,
    #[serde(default)]
    none_states: UniqueMap<NoneState>,
    #[serde(default)]
    generic_packages: UniqueMap<GenericPackage>,
    #[serde(default)]
    evidence: UniqueMap<Evidence>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CapabilityDefinition {
    pub domain: String,
    pub requirement: Requirement,
    pub outcome: String,
    pub failure_states: Vec<FailureState>,
    #[serde(default)]
    pub actions: Vec<String>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OptionRecord {
    pub support: OptionSupport,
    pub summary: String,
    #[serde(default)]
    pub limitations: Vec<String>,
    // Typed for strict validation; consumed by later previews, not by the chooser.
    #[allow(dead_code)]
    pub family: Family,
    #[allow(dead_code)]
    pub startup: Startup,
    pub data_boundary: String,
    #[serde(default)]
    capabilities: UniqueMap<OptionCapability>,
    #[serde(default)]
    pub theme: Option<ThemeSupport>,
}

impl OptionRecord {
    pub fn capabilities(&self) -> &BTreeMap<String, OptionCapability> {
        &self.capabilities.0
    }
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OptionCapability {
    pub support: CapabilitySupport,
    pub mechanism: Mechanism,
    #[serde(default)]
    pub evidence: Vec<String>,
    #[serde(default)]
    pub note: String,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ThemeSupport {
    pub support: CapabilitySupport,
    #[serde(default)]
    pub units: Vec<String>,
    #[serde(default)]
    pub note: String,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NoneState {
    pub behavior: String,
    pub theme: String,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GenericPackage {
    pub class: GenericClass,
    pub owner: String,
    pub reason: String,
    /// Theme coverage of a themed-interface package; absent for other classes.
    #[serde(default)]
    pub theme: Option<ThemeSupport>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Evidence {
    pub kind: EvidenceKind,
    pub source: String,
    pub date: String,
    #[serde(default)]
    pub environment: String,
    #[serde(default)]
    pub command: String,
    pub result: String,
}

/// The merged and validated ledger.
#[derive(Clone, Debug, Default)]
pub struct CapabilityLedger {
    capabilities: BTreeMap<String, CapabilityDefinition>,
    options: BTreeMap<String, OptionRecord>,
    none_states: BTreeMap<String, NoneState>,
    generic_packages: BTreeMap<String, GenericPackage>,
    evidence: BTreeMap<String, Evidence>,
}

impl CapabilityLedger {
    /// Loads `capabilities.json` and `capabilities.d/*.json` from `root`, the directory
    /// that contains `packages.json`. A missing base document returns `Ok(None)`.
    pub fn load(root: &Path, registry: &PackagesRoot) -> Result<Option<Self>> {
        let base_path = root.join(LEDGER_FILE);
        let base = match fs::read_to_string(&base_path) {
            Ok(text) => text,
            Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("read capability ledger {}", base_path.display()));
            }
        };
        let fragments = read_fragment_texts(&root.join(FRAGMENT_DIR))?;
        Self::from_texts(&base, &fragments, registry).map(Some)
    }

    /// Parses and validates a base document and `(name, text)` fragments in the given order.
    fn from_texts(
        base: &str,
        fragments: &[(String, String)],
        registry: &PackagesRoot,
    ) -> Result<Self> {
        let base: BaseDocument =
            serde_json::from_str(base).with_context(|| format!("parse {LEDGER_FILE}"))?;
        validate_base(&base)?;
        let mut ledger = Self::default();
        let mut origins: BTreeMap<(&'static str, String), String> = BTreeMap::new();
        for (name, text) in fragments {
            let fragment: Fragment =
                serde_json::from_str(text).with_context(|| format!("parse {name}"))?;
            ledger
                .merge_fragment(name, fragment, &mut origins)
                .with_context(|| format!("invalid {name}"))?;
        }
        ledger.validate_references(&origins)?;
        ledger.validate_coverage(registry)?;
        Ok(ledger)
    }

    pub fn option(&self, role: &str, package: &str) -> Option<&OptionRecord> {
        self.options.get(&format!("{role}/{package}"))
    }

    fn merge_fragment(
        &mut self,
        name: &str,
        fragment: Fragment,
        origins: &mut BTreeMap<(&'static str, String), String>,
    ) -> Result<()> {
        if fragment.schema_version != SCHEMA_VERSION {
            bail!(
                "schema_version {} is not supported (expected {SCHEMA_VERSION})",
                fragment.schema_version
            );
        }
        if !is_owner(&fragment.owner) {
            bail!("owner {:?} must look like D03 or F01", fragment.owner);
        }
        // One fragment per owner keeps E-<owner>-NNN evidence IDs globally unique.
        claim(origins, "fragment owner", &fragment.owner, name)?;
        let owner = fragment.owner.as_str();
        for (id, evidence) in fragment.evidence.0 {
            validate_evidence(owner, &id, &evidence).with_context(|| format!("evidence {id}"))?;
            claim(origins, "evidence", &id, name)?;
            self.evidence.insert(id, evidence);
        }
        for (id, capability) in fragment.capabilities.0 {
            validate_capability(&id, &capability).with_context(|| format!("capability {id}"))?;
            claim(origins, "capability", &id, name)?;
            self.capabilities.insert(id, capability);
        }
        for (id, option) in fragment.options.0 {
            validate_option_text(&option).with_context(|| format!("option {id}"))?;
            claim(origins, "option", &id, name)?;
            self.options.insert(id, option);
        }
        for (role, state) in fragment.none_states.0 {
            require_text("behavior", &state.behavior)
                .and_then(|()| require_text("theme", &state.theme))
                .with_context(|| format!("None state {role}"))?;
            claim(origins, "None state", &role, name)?;
            self.none_states.insert(role, state);
        }
        for (package, generic) in fragment.generic_packages.0 {
            if !is_owner(&generic.owner) {
                bail!(
                    "generic package {package} owner {:?} must look like D07",
                    generic.owner
                );
            }
            validate_generic_text(&generic)
                .with_context(|| format!("generic package {package}"))?;
            claim(origins, "generic package", &package, name)?;
            self.generic_packages.insert(package, generic);
        }
        Ok(())
    }

    fn validate_references(
        &self,
        origins: &BTreeMap<(&'static str, String), String>,
    ) -> Result<()> {
        for (id, option) in &self.options {
            let origin = &origins[&("option", id.clone())];
            self.validate_option_references(option)
                .with_context(|| format!("invalid {origin}: option {id}"))?;
        }
        Ok(())
    }

    fn validate_option_references(&self, option: &OptionRecord) -> Result<()> {
        let mut gap = option.theme.as_ref().is_some_and(|theme| {
            matches!(
                theme.support,
                CapabilitySupport::Unsupported | CapabilitySupport::Partial
            )
        });
        for (capability_id, record) in option.capabilities() {
            let definition = self.capabilities.get(capability_id).with_context(|| {
                format!("capability {capability_id} is not defined by any fragment")
            })?;
            for evidence_id in &record.evidence {
                if !self.evidence.contains_key(evidence_id) {
                    bail!("capability {capability_id} cites undefined evidence {evidence_id}");
                }
            }
            if definition.requirement != Requirement::Required {
                continue;
            }
            match (option.support, record.support) {
                (
                    OptionSupport::Full,
                    CapabilitySupport::Supported | CapabilitySupport::NotApplicable,
                ) => {}
                (OptionSupport::Full, other) => bail!(
                    "full support conflicts with required capability {capability_id} marked {}",
                    other.as_str()
                ),
                (_, CapabilitySupport::Unsupported | CapabilitySupport::Partial) => gap = true,
                _ => {}
            }
        }
        match option.support {
            OptionSupport::Full if option.capabilities().is_empty() => {
                bail!("full support needs at least one capability record")
            }
            OptionSupport::Full if gap => {
                bail!("full support conflicts with an unsupported or partial theme")
            }
            OptionSupport::Limited if !gap => bail!(
                "limited support needs a required capability or the theme marked unsupported or partial"
            ),
            OptionSupport::Limited if option.limitations.is_empty() => {
                bail!("limited support needs at least one user-facing limitation")
            }
            _ => Ok(()),
        }
    }

    fn validate_coverage(&self, registry: &PackagesRoot) -> Result<()> {
        let expected_options: BTreeSet<String> = ROLE_ORDER
            .into_iter()
            .flat_map(|role| {
                registry.roles[role]
                    .options
                    .iter()
                    .map(move |option| format!("{role}/{}", option.package))
            })
            .collect();
        compare_sets(
            "role options",
            &expected_options,
            &self.options.keys().cloned().collect(),
        )?;

        let expected_none: BTreeSet<String> = ROLE_ORDER
            .into_iter()
            .filter(|role| !registry.roles[*role].required)
            .map(str::to_string)
            .collect();
        compare_sets(
            "None states",
            &expected_none,
            &self.none_states.keys().cloned().collect(),
        )?;

        compare_sets(
            "generic packages",
            &generic_packages(registry),
            &self.generic_packages.keys().cloned().collect(),
        )
    }
}

/// Every catalog package that is neither a role option nor a role extra.
pub fn generic_packages(registry: &PackagesRoot) -> BTreeSet<String> {
    [
        PackageSource::Pacman,
        PackageSource::Aur,
        PackageSource::Official,
    ]
    .into_iter()
    .flat_map(|source| registry.categorized(source))
    .flat_map(|(_, packages)| packages)
    .collect()
}

fn read_fragment_texts(directory: &Path) -> Result<Vec<(String, String)>> {
    let entries = match fs::read_dir(directory) {
        Ok(entries) => entries,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => {
            return Err(error).with_context(|| format!("list {}", directory.display()));
        }
    };
    let mut names = Vec::new();
    for entry in entries {
        let entry = entry.with_context(|| format!("list {}", directory.display()))?;
        let Ok(name) = entry.file_name().into_string() else {
            bail!("{} contains a non-UTF-8 file name", directory.display());
        };
        if name.ends_with(".json") && !name.starts_with('.') {
            names.push(name);
        }
    }
    names.sort();
    names
        .into_iter()
        .map(|name| {
            let path = directory.join(&name);
            let text = fs::read_to_string(&path)
                .with_context(|| format!("read capability fragment {}", path.display()))?;
            Ok((format!("{FRAGMENT_DIR}/{name}"), text))
        })
        .collect()
}

fn validate_base(base: &BaseDocument) -> Result<()> {
    if base.schema_version != SCHEMA_VERSION {
        bail!(
            "{LEDGER_FILE} schema_version {} is not supported (expected {SCHEMA_VERSION})",
            base.schema_version
        );
    }
    if base.fragments != FRAGMENT_PATTERN {
        bail!("{LEDGER_FILE} fragments must be {FRAGMENT_PATTERN:?}");
    }
    require_text("description", &base.description).context(LEDGER_FILE)?;
    let vocabulary = &base.vocabulary;
    let checks: [(&str, &UniqueMap<String>, Vec<&str>); 9] = [
        (
            "option_support",
            &vocabulary.option_support,
            values(OptionSupport::ALL, |value| value.as_str()),
        ),
        (
            "capability_support",
            &vocabulary.capability_support,
            values(CapabilitySupport::ALL, |value| value.as_str()),
        ),
        (
            "mechanism",
            &vocabulary.mechanism,
            values(Mechanism::ALL, |value| value.as_str()),
        ),
        (
            "family",
            &vocabulary.family,
            values(Family::ALL, |value| value.as_str()),
        ),
        (
            "startup",
            &vocabulary.startup,
            values(Startup::ALL, |value| value.as_str()),
        ),
        (
            "evidence_kind",
            &vocabulary.evidence_kind,
            values(EvidenceKind::ALL, |value| value.as_str()),
        ),
        (
            "requirement",
            &vocabulary.requirement,
            values(Requirement::ALL, |value| value.as_str()),
        ),
        (
            "failure_state",
            &vocabulary.failure_state,
            values(FailureState::ALL, |value| value.as_str()),
        ),
        (
            "generic_class",
            &vocabulary.generic_class,
            values(GenericClass::ALL, |value| value.as_str()),
        ),
    ];
    for (name, documented, known) in checks {
        let documented_keys: BTreeSet<&str> = documented.0.keys().map(String::as_str).collect();
        let known: BTreeSet<&str> = known.into_iter().collect();
        if documented_keys != known {
            bail!(
                "{LEDGER_FILE} vocabulary.{name} must document exactly: {}",
                vocabulary_list(known.into_iter())
            );
        }
        for (value, text) in &documented.0 {
            require_text(&format!("vocabulary.{name}.{value}"), text).context(LEDGER_FILE)?;
        }
    }
    for (name, text) in &base.identifiers.0 {
        require_text(&format!("identifiers.{name}"), text).context(LEDGER_FILE)?;
    }
    Ok(())
}

fn values<T: Copy>(all: &[T], text: fn(T) -> &'static str) -> Vec<&'static str> {
    all.iter().copied().map(text).collect()
}

fn claim(
    origins: &mut BTreeMap<(&'static str, String), String>,
    kind: &'static str,
    id: &str,
    origin: &str,
) -> Result<()> {
    if let Some(previous) = origins.insert((kind, id.to_string()), origin.to_string()) {
        bail!("{kind} {id} is defined in both {previous} and {origin}");
    }
    Ok(())
}

fn compare_sets(kind: &str, expected: &BTreeSet<String>, actual: &BTreeSet<String>) -> Result<()> {
    let missing: Vec<&str> = expected.difference(actual).map(String::as_str).collect();
    let unknown: Vec<&str> = actual.difference(expected).map(String::as_str).collect();
    match (missing.is_empty(), unknown.is_empty()) {
        (true, true) => Ok(()),
        (false, true) => bail!(
            "capability ledger is missing {kind}: {}",
            missing.join(", ")
        ),
        (true, false) => bail!(
            "capability ledger defines unknown {kind}: {}",
            unknown.join(", ")
        ),
        (false, false) => bail!(
            "capability ledger is missing {kind}: {}; and defines unknown {kind}: {}",
            missing.join(", "),
            unknown.join(", ")
        ),
    }
}

fn validate_capability(id: &str, capability: &CapabilityDefinition) -> Result<()> {
    if !is_dotted_id(id) {
        bail!("capability IDs must match <domain>.<name> in lowercase");
    }
    if !is_segment(&capability.domain) || !id.starts_with(&format!("{}.", capability.domain)) {
        bail!(
            "domain {:?} must be the first segment of the capability ID",
            capability.domain
        );
    }
    require_text("outcome", &capability.outcome)?;
    if capability.failure_states.is_empty() {
        bail!("failure_states must list at least one outcome");
    }
    let mut states = BTreeSet::new();
    for state in &capability.failure_states {
        if !states.insert(state.as_str()) {
            bail!("failure state {} is listed twice", state.as_str());
        }
    }
    let mut actions = BTreeSet::new();
    for action in &capability.actions {
        if !is_dotted_id(action) {
            bail!("action {action:?} must match ^[a-z][a-z0-9_]*(\\.[a-z][a-z0-9_]*)+$");
        }
        if !actions.insert(action.as_str()) {
            bail!("action {action} is listed twice");
        }
    }
    Ok(())
}

fn validate_option_text(option: &OptionRecord) -> Result<()> {
    require_text("summary", &option.summary)?;
    if option.summary.chars().count() > MAX_SUMMARY_CHARS {
        bail!("summary is longer than {MAX_SUMMARY_CHARS} characters");
    }
    for limitation in &option.limitations {
        require_text("limitation", limitation)?;
    }
    require_text("data_boundary", &option.data_boundary)?;
    for (capability_id, record) in option.capabilities() {
        optional_text("note", &record.note)
            .with_context(|| format!("capability {capability_id}"))?;
        let claims = matches!(
            record.support,
            CapabilitySupport::Supported | CapabilitySupport::Partial
        );
        if claims && record.evidence.is_empty() {
            bail!(
                "capability {capability_id} is marked {} without evidence",
                record.support.as_str()
            );
        }
        if claims && record.mechanism == Mechanism::None {
            bail!(
                "capability {capability_id} is marked {} without a native mechanism",
                record.support.as_str()
            );
        }
        if matches!(
            record.support,
            CapabilitySupport::Partial | CapabilitySupport::Unsupported
        ) && record.note.trim().is_empty()
        {
            bail!(
                "capability {capability_id} is marked {} without an explanatory note",
                record.support.as_str()
            );
        }
    }
    if let Some(theme) = &option.theme {
        validate_theme_text(theme)?;
    }
    Ok(())
}

fn validate_generic_text(generic: &GenericPackage) -> Result<()> {
    require_text("reason", &generic.reason)?;
    if let Some(theme) = &generic.theme {
        if generic.class != GenericClass::ThemedInterface {
            bail!("theme is only valid for themed-interface packages");
        }
        validate_theme_text(theme)?;
    }
    Ok(())
}

fn validate_theme_text(theme: &ThemeSupport) -> Result<()> {
    optional_text("theme note", &theme.note)?;
    for unit in &theme.units {
        if unit.is_empty()
            || !unit.bytes().all(|byte| {
                byte.is_ascii_lowercase() || byte.is_ascii_digit() || b"._-".contains(&byte)
            })
        {
            bail!("theme unit {unit:?} is not a valid unit ID");
        }
    }
    Ok(())
}

fn validate_evidence(owner: &str, id: &str, evidence: &Evidence) -> Result<()> {
    let digits = id
        .strip_prefix("E-")
        .and_then(|rest| rest.strip_prefix(owner))
        .and_then(|rest| rest.strip_prefix('-'));
    if !digits.is_some_and(|digits| digits.len() == 3 && digits.bytes().all(|b| b.is_ascii_digit()))
    {
        bail!("evidence IDs in this fragment must look like E-{owner}-001");
    }
    require_text("source", &evidence.source)?;
    require_text("result", &evidence.result)?;
    optional_text("environment", &evidence.environment)?;
    optional_text("command", &evidence.command)?;
    if !is_date(&evidence.date) {
        bail!("date {:?} must be YYYY-MM-DD", evidence.date);
    }
    match evidence.kind {
        EvidenceKind::RealEffect | EvidenceKind::Visual
            if evidence.environment.trim().is_empty() =>
        {
            bail!(
                "{} evidence must record its environment",
                evidence.kind.as_str()
            )
        }
        EvidenceKind::RealEffect | EvidenceKind::Argv | EvidenceKind::ModeledEffect
            if evidence.command.trim().is_empty() =>
        {
            bail!(
                "{} evidence must record its command",
                evidence.kind.as_str()
            )
        }
        _ => Ok(()),
    }
}

fn require_text(field: &str, value: &str) -> Result<()> {
    if value.trim().is_empty() {
        bail!("{field} must not be empty");
    }
    optional_text(field, value)
}

fn optional_text(field: &str, value: &str) -> Result<()> {
    if value.chars().any(char::is_control) {
        bail!("{field} must not contain control characters");
    }
    Ok(())
}

fn is_owner(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 3
        && bytes[0].is_ascii_uppercase()
        && bytes[1].is_ascii_digit()
        && bytes[2].is_ascii_digit()
}

fn is_segment(value: &str) -> bool {
    let mut bytes = value.bytes();
    bytes.next().is_some_and(|byte| byte.is_ascii_lowercase())
        && bytes.all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
}

fn is_dotted_id(value: &str) -> bool {
    value.split('.').count() >= 2 && value.split('.').all(is_segment)
}

fn is_date(value: &str) -> bool {
    let parts: Vec<&str> = value.split('-').collect();
    let number = |text: &str, width: usize| {
        (text.len() == width && text.bytes().all(|byte| byte.is_ascii_digit()))
            .then(|| text.parse::<u32>().ok())
            .flatten()
    };
    matches!(
        parts.as_slice(),
        [year, month, day]
            if number(year, 4).is_some()
                && number(month, 2).is_some_and(|month| (1..=12).contains(&month))
                && number(day, 2).is_some_and(|day| (1..=31).contains(&day))
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};
    use std::path::PathBuf;

    fn repo_root() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
    }

    fn shipped_registry() -> PackagesRoot {
        PackagesRoot::load(&repo_root().join("packages.json")).unwrap()
    }

    fn shipped_texts() -> (String, Vec<(String, String)>) {
        let base = fs::read_to_string(repo_root().join(LEDGER_FILE)).unwrap();
        (
            base,
            read_fragment_texts(&repo_root().join(FRAGMENT_DIR)).unwrap(),
        )
    }

    fn shipped_values() -> (Value, Vec<(String, Value)>) {
        let (base, fragments) = shipped_texts();
        (
            serde_json::from_str(&base).unwrap(),
            fragments
                .into_iter()
                .map(|(name, text)| (name, serde_json::from_str(&text).unwrap()))
                .collect(),
        )
    }

    fn validate(base: &Value, fragments: &[(String, Value)]) -> Result<CapabilityLedger> {
        let texts: Vec<(String, String)> = fragments
            .iter()
            .map(|(name, value)| (name.clone(), value.to_string()))
            .collect();
        CapabilityLedger::from_texts(&base.to_string(), &texts, &shipped_registry())
    }

    fn error_of(base: &Value, fragments: &[(String, Value)]) -> String {
        format!("{:#}", validate(base, fragments).unwrap_err())
    }

    fn fragment_mut<'a>(fragments: &'a mut [(String, Value)], name: &str) -> &'a mut Value {
        &mut fragments
            .iter_mut()
            .find(|(fragment, _)| fragment.ends_with(name))
            .unwrap()
            .1
    }

    struct TempDir(PathBuf);

    impl TempDir {
        fn new(label: &str) -> Self {
            let path = std::env::temp_dir().join(format!(
                "hss-capabilities-{label}-{}-{:?}",
                std::process::id(),
                std::thread::current().id()
            ));
            let _ = fs::remove_dir_all(&path);
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn shipped_ledger_covers_every_option_none_state_and_generic_package() {
        let registry = shipped_registry();
        let ledger = CapabilityLedger::load(&repo_root(), &registry)
            .unwrap()
            .expect("capabilities.json is shipped");
        assert_eq!(ledger.options.len(), 73);
        assert_eq!(
            ledger.none_states.keys().cloned().collect::<Vec<_>>(),
            ["agent", "dock", "gui_editor", "tui_file_manager"]
        );
        assert_eq!(
            ledger.generic_packages.len(),
            generic_packages(&registry).len()
        );
        for package in ["noto-fonts", "rose-pine-cursor", "qalculate-gtk", "ffmpeg"] {
            assert!(ledger.generic_packages.contains_key(package), "{package}");
        }
        for role in ROLE_ORDER {
            for option in &registry.roles[role].options {
                let record = ledger.option(role, &option.package).unwrap();
                assert!(!record.summary.is_empty());
            }
        }
        assert!(ledger.option("dock", "nwg-panel").is_some());
        assert!(ledger.option("bar", "nwg-panel").is_some());
        assert!(ledger.option("browser", "nwg-panel").is_none());
    }

    #[test]
    fn missing_base_document_means_no_ledger() {
        let dir = TempDir::new("missing");
        fs::create_dir_all(dir.0.join(FRAGMENT_DIR)).unwrap();
        fs::write(dir.0.join(FRAGMENT_DIR).join("d01-panels.json"), "{}").unwrap();
        assert!(
            CapabilityLedger::load(&dir.0, &shipped_registry())
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn loader_reads_sorted_json_fragments_and_ignores_other_files() {
        let dir = TempDir::new("loader");
        let fragments = dir.0.join(FRAGMENT_DIR);
        fs::create_dir_all(&fragments).unwrap();
        fs::copy(repo_root().join(LEDGER_FILE), dir.0.join(LEDGER_FILE)).unwrap();
        for entry in fs::read_dir(repo_root().join(FRAGMENT_DIR)).unwrap() {
            let entry = entry.unwrap();
            fs::copy(entry.path(), fragments.join(entry.file_name())).unwrap();
        }
        fs::write(fragments.join("README.md"), "not a fragment").unwrap();
        fs::write(fragments.join(".hidden.json"), "not json").unwrap();
        fs::write(fragments.join("d03-notifications.json.bak"), "not json").unwrap();
        let registry = shipped_registry();
        assert!(CapabilityLedger::load(&dir.0, &registry).unwrap().is_some());

        fs::write(fragments.join("zz-extra.json"), "{").unwrap();
        let error = format!(
            "{:#}",
            CapabilityLedger::load(&dir.0, &registry).unwrap_err()
        );
        assert!(error.contains("capabilities.d/zz-extra.json"), "{error}");

        fs::remove_file(fragments.join("zz-extra.json")).unwrap();
        fs::remove_file(fragments.join("d02-launchers.json")).unwrap();
        let error = format!(
            "{:#}",
            CapabilityLedger::load(&dir.0, &registry).unwrap_err()
        );
        assert!(
            error.contains("missing role options: launcher/bemenu"),
            "{error}"
        );
    }

    #[test]
    fn duplicates_across_and_within_fragments_are_rejected() {
        let (base, mut fragments) = shipped_values();
        let option = fragment_mut(&mut fragments, "d03-notifications.json")["options"]
            ["notifications/fnott"]
            .clone();
        fragment_mut(&mut fragments, "d07-session-auxiliary.json")["options"]["notifications/fnott"] =
            option;
        let error = error_of(&base, &fragments);
        assert!(
            error.contains(
                "option notifications/fnott is defined in both capabilities.d/d03-notifications.json and capabilities.d/d07-session-auxiliary.json"
            ),
            "{error}"
        );

        let (base, mut fragments) = shipped_values();
        let generic = fragment_mut(&mut fragments, "d07-session-auxiliary.json")
            ["generic_packages"]["ffmpeg"]
            .clone();
        fragment_mut(&mut fragments, "d01-panels.json")["generic_packages"]["ffmpeg"] = generic;
        assert!(error_of(&base, &fragments).contains("generic package ffmpeg is defined in both"));

        let (base, mut fragments) = shipped_values();
        let none = fragment_mut(&mut fragments, "d01-panels.json")["none_states"]["dock"].clone();
        fragment_mut(&mut fragments, "d02-launchers.json")["none_states"]["dock"] = none;
        assert!(error_of(&base, &fragments).contains("None state dock is defined in both"));

        let (base, mut fragments) = shipped_values();
        fragment_mut(&mut fragments, "d02-launchers.json")["owner"] = json!("D01");
        assert!(
            error_of(&base, &fragments).contains(
                "fragment owner D01 is defined in both capabilities.d/d01-panels.json and capabilities.d/d02-launchers.json"
            )
        );

        let (base, fragments) = shipped_texts();
        let mut texts = fragments.clone();
        let (_, text) = texts
            .iter_mut()
            .find(|(name, _)| name.ends_with("d03-notifications.json"))
            .unwrap();
        let value: Value = serde_json::from_str(text).unwrap();
        let record = value["options"]["notifications/fnott"].to_string();
        *text = text.replacen(
            "\"options\": {",
            &format!("\"options\": {{\n    \"notifications/fnott\": {record},"),
            1,
        );
        let error = format!(
            "{:#}",
            CapabilityLedger::from_texts(&base, &texts, &shipped_registry()).unwrap_err()
        );
        assert!(
            error.contains("duplicate key \"notifications/fnott\""),
            "{error}"
        );
    }

    #[test]
    fn coverage_must_match_the_catalog_exactly() {
        let (base, mut fragments) = shipped_values();
        fragment_mut(&mut fragments, "d06-applications.json")["options"]
            .as_object_mut()
            .unwrap()
            .remove("browser/firefox");
        assert!(error_of(&base, &fragments).contains("missing role options: browser/firefox"));

        let (base, mut fragments) = shipped_values();
        let record =
            fragment_mut(&mut fragments, "d06-applications.json")["options"]["browser/firefox"]
                .clone();
        fragment_mut(&mut fragments, "d06-applications.json")["options"]["browser/netscape"] =
            record;
        assert!(error_of(&base, &fragments).contains("unknown role options: browser/netscape"));

        let (base, mut fragments) = shipped_values();
        fragment_mut(&mut fragments, "d05-terminal-workspace.json")["none_states"]
            .as_object_mut()
            .unwrap()
            .remove("agent");
        assert!(error_of(&base, &fragments).contains("missing None states: agent"));

        let (base, mut fragments) = shipped_values();
        fragment_mut(&mut fragments, "d01-panels.json")["none_states"]["bar"] =
            json!({"behavior": "No bar", "theme": "no member units"});
        assert!(error_of(&base, &fragments).contains("unknown None states: bar"));

        let (base, mut fragments) = shipped_values();
        fragment_mut(&mut fragments, "d07-session-auxiliary.json")["generic_packages"]
            .as_object_mut()
            .unwrap()
            .remove("noto-fonts");
        assert!(error_of(&base, &fragments).contains("missing generic packages: noto-fonts"));

        let (base, mut fragments) = shipped_values();
        fragment_mut(&mut fragments, "d07-session-auxiliary.json")["generic_packages"]["kitty"] =
            json!({"class": "themed-interface", "owner": "D07", "reason": "Role option"});
        assert!(error_of(&base, &fragments).contains("unknown generic packages: kitty"));
    }

    #[test]
    fn generic_theme_records_are_limited_to_themed_interfaces() {
        let generic = |theme: Value| {
            json!({"class": "themed-interface", "owner": "D07", "reason": "Archive manager",
                "theme": theme})
        };
        let partial = json!({"support": "partial", "units": ["qt6ct"], "note": "Global mapping"});

        let (base, mut fragments) = shipped_values();
        let packages =
            &mut fragment_mut(&mut fragments, "d07-session-auxiliary.json")["generic_packages"];
        packages["ark"] = generic(partial.clone());
        let ledger = validate(&base, &fragments).unwrap();
        let theme = ledger.generic_packages["ark"].theme.as_ref().unwrap();
        assert_eq!(theme.support, CapabilitySupport::Partial);

        let (base, mut fragments) = shipped_values();
        let packages =
            &mut fragment_mut(&mut fragments, "d07-session-auxiliary.json")["generic_packages"];
        packages["noto-fonts"]["theme"] = partial;
        let error = error_of(&base, &fragments);
        assert!(
            error.contains(
                "generic package noto-fonts: theme is only valid for themed-interface packages"
            ),
            "{error}"
        );

        let (base, mut fragments) = shipped_values();
        let packages =
            &mut fragment_mut(&mut fragments, "d07-session-auxiliary.json")["generic_packages"];
        packages["ark"] = generic(json!({"support": "supported", "units": ["Qt6CT"]}));
        let error = error_of(&base, &fragments);
        assert!(
            error.contains("theme unit \"Qt6CT\" is not a valid unit ID"),
            "{error}"
        );
    }

    #[test]
    fn vocabulary_fields_and_versions_are_strict() {
        let (base, mut fragments) = shipped_values();
        fragment_mut(&mut fragments, "d03-notifications.json")["options"]["notifications/mako"]["support"] =
            json!("great");
        assert!(error_of(&base, &fragments).contains("unknown option support \"great\""));

        let (base, mut fragments) = shipped_values();
        fragment_mut(&mut fragments, "d03-notifications.json")["options"]["notifications/mako"]["family"] =
            json!("motif");
        assert!(error_of(&base, &fragments).contains("unknown family \"motif\""));

        let (base, mut fragments) = shipped_values();
        fragment_mut(&mut fragments, "d03-notifications.json")["options"]["notifications/mako"]["colour"] =
            json!("blue");
        assert!(error_of(&base, &fragments).contains("unknown field `colour`"));

        let (base, mut fragments) = shipped_values();
        fragment_mut(&mut fragments, "d03-notifications.json")["schema_version"] = json!(2);
        assert!(error_of(&base, &fragments).contains("schema_version 2 is not supported"));

        let (mut base, fragments) = shipped_values();
        base["schema_version"] = json!(2);
        assert!(error_of(&base, &fragments).contains("schema_version 2 is not supported"));

        let (mut base, fragments) = shipped_values();
        base["vocabulary"]["option_support"]
            .as_object_mut()
            .unwrap()
            .remove("limited");
        assert!(error_of(&base, &fragments).contains("vocabulary.option_support"));

        let (mut base, fragments) = shipped_values();
        base["options"] = json!({});
        assert!(error_of(&base, &fragments).contains("unknown field `options`"));

        let (base, mut fragments) = shipped_values();
        fragment_mut(&mut fragments, "d03-notifications.json")["owner"] = json!("notifications");
        assert!(error_of(&base, &fragments).contains("owner \"notifications\""));
    }

    /// Synthetic IDs keep the fixture independent of the shipped D03 records.
    const FIXTURE_CAPABILITY: &str = "notifications.fixture_dnd";

    /// The shipped ledger with notifications/fnott reduced to one required fixture
    /// capability, so its support label depends only on `capability`.
    fn fnott_with(capability: Value, support: &str) -> (Value, Vec<(String, Value)>) {
        let (base, mut fragments) = shipped_values();
        let fragment = fragment_mut(&mut fragments, "d03-notifications.json");
        fragment["capabilities"][FIXTURE_CAPABILITY] = json!({
            "domain": "notifications",
            "requirement": "required",
            "outcome": "Ordinary popups are suppressed and DND reads back as enabled",
            "failure_states": ["unsupported", "unavailable", "failed"],
            "actions": ["notifications.dnd.set", "notifications.dnd.toggle"]
        });
        fragment["evidence"]["E-D03-900"] = json!({
            "kind": "documentation",
            "source": "fnott(1), fnott 1.8",
            "date": "2026-10-20",
            "result": "No do-not-disturb control is documented"
        });
        // Replace the shipped record so only the fixture capability decides the label.
        let option = &mut fragment["options"]["notifications/fnott"];
        option["support"] = json!(support);
        option["limitations"] = json!(["Fnott has no native do-not-disturb control."]);
        option["theme"] = json!({"support": "supported", "units": ["fnott"]});
        option["capabilities"] = json!({ FIXTURE_CAPABILITY: capability });
        (base, fragments)
    }

    #[test]
    fn references_and_support_labels_must_be_consistent() {
        let unsupported = json!({"support": "unsupported", "mechanism": "none",
            "evidence": ["E-D03-900"], "note": "No native DND"});
        let (base, fragments) = fnott_with(unsupported.clone(), "limited");
        let ledger = validate(&base, &fragments).unwrap();
        assert_eq!(
            ledger.option("notifications", "fnott").unwrap().support,
            OptionSupport::Limited
        );

        let (base, fragments) = fnott_with(unsupported.clone(), "full");
        assert!(error_of(&base, &fragments).contains("full support conflicts"));

        let (base, mut fragments) = fnott_with(unsupported.clone(), "limited");
        fragment_mut(&mut fragments, "d03-notifications.json")["options"]["notifications/fnott"]
            ["limitations"] = json!([]);
        assert!(error_of(&base, &fragments).contains("at least one user-facing limitation"));

        let supported = json!({"support": "supported", "mechanism": "native-cli",
            "evidence": ["E-D03-900"]});
        let (base, fragments) = fnott_with(supported.clone(), "limited");
        assert!(error_of(&base, &fragments).contains("limited support needs"));
        let (base, fragments) = fnott_with(supported, "full");
        validate(&base, &fragments).unwrap();

        let (base, fragments) = fnott_with(
            json!({"support": "supported", "mechanism": "native-cli", "evidence": []}),
            "unverified",
        );
        assert!(error_of(&base, &fragments).contains("without evidence"));

        let (base, fragments) = fnott_with(
            json!({"support": "partial", "mechanism": "none", "evidence": ["E-D03-900"],
                "note": "Inherited from the terminal"}),
            "limited",
        );
        assert!(error_of(&base, &fragments).contains(
            "capability notifications.fixture_dnd is marked partial without a native mechanism"
        ));

        let (base, mut fragments) = fnott_with(
            json!({"support": "supported", "mechanism": "native-cli", "evidence": ["E-D03-900"]}),
            "full",
        );
        fragment_mut(&mut fragments, "d03-notifications.json")["options"]["notifications/fnott"]
            ["theme"] = json!({"support": "partial", "note": "Dark/light only"});
        let error = error_of(&base, &fragments);
        assert!(
            error.contains("conflicts with an unsupported or partial theme"),
            "{error}"
        );

        let (base, fragments) = fnott_with(
            json!({"support": "supported", "mechanism": "native-cli", "evidence": ["E-D03-404"]}),
            "unverified",
        );
        assert!(error_of(&base, &fragments).contains("undefined evidence E-D03-404"));

        let (base, mut fragments) = fnott_with(unsupported.clone(), "limited");
        fragment_mut(&mut fragments, "d03-notifications.json")["capabilities"]
            .as_object_mut()
            .unwrap()
            .remove(FIXTURE_CAPABILITY);
        assert!(
            error_of(&base, &fragments)
                .contains("capability notifications.fixture_dnd is not defined by any fragment")
        );

        let (base, mut fragments) = fnott_with(unsupported.clone(), "limited");
        let evidence =
            fragment_mut(&mut fragments, "d03-notifications.json")["evidence"]["E-D03-900"].clone();
        fragment_mut(&mut fragments, "d04-devices.json")["evidence"]["E-D03-900"] = evidence;
        assert!(
            error_of(&base, &fragments)
                .contains("evidence IDs in this fragment must look like E-D04-001")
        );

        let (base, mut fragments) = fnott_with(unsupported, "limited");
        fragment_mut(&mut fragments, "d03-notifications.json")["capabilities"]
            [FIXTURE_CAPABILITY]["actions"] = json!(["Notifications.DND"]);
        assert!(error_of(&base, &fragments).contains("action \"Notifications.DND\""));
    }

    #[test]
    fn evidence_records_follow_the_brief() {
        let unsupported = json!({"support": "unsupported", "mechanism": "none",
            "evidence": ["E-D03-900"], "note": "No native DND"});
        let (base, mut fragments) = fnott_with(unsupported, "limited");
        let mut set = |field: &str, value: &str| {
            fragment_mut(&mut fragments, "d03-notifications.json")["evidence"]["E-D03-900"]
                [field] = json!(value);
            validate(&base, &fragments).map_err(|error| format!("{error:#}"))
        };
        let error = set("kind", "real-effect").unwrap_err();
        assert!(
            error.contains("real-effect evidence must record its environment"),
            "{error}"
        );
        let error = set("environment", "Arch Linux ARM chroot, headless sway").unwrap_err();
        assert!(error.contains("must record its command"), "{error}");
        set("command", "fnott --help").unwrap();
        let error = set("date", "2026-13-01").unwrap_err();
        assert!(error.contains("must be YYYY-MM-DD"), "{error}");
        set("date", "2026-10-20").unwrap();
    }
}
